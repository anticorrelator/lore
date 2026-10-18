package work

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/anticorrelator/lore/tui/internal/config"
)

// tmuxBinary is resolved from PATH by exec at spawn time; TmuxAvailable's LookPath
// probe is what gates every use, so a bare name is safe here.
const tmuxBinary = "tmux"

// tmuxHistoryLimit is the modest per-pane scrollback lore pins. Scrollback across
// recovery is an accepted loss (reattach redraws the visible screen only), so this
// bounds pane memory rather than preserving history.
const tmuxHistoryLimit = 5000

// TmuxAvailable reports whether tmux hosting is active for this process and a
// one-line detail for the startup notice. It is the D3 host-capability gate: an
// explicit `LORE_TUI_TMUX=off` opt-out wins, then tmux must be on PATH and answer
// `tmux -V`. tmux presence varies per host, not per harness, so this is a runtime
// probe rather than a capabilities.json row. When it returns false the caller
// spawns direct-PTY exactly as before, announced once.
func TmuxAvailable() (bool, string) {
	if strings.EqualFold(strings.TrimSpace(os.Getenv("LORE_TUI_TMUX")), "off") {
		return false, "LORE_TUI_TMUX=off"
	}
	path, err := exec.LookPath(tmuxBinary)
	if err != nil {
		return false, "tmux not found on PATH"
	}
	out, err := exec.Command(path, "-V").Output()
	if err != nil {
		return false, "tmux -V failed"
	}
	return true, strings.TrimSpace(string(out))
}

// TmuxSessionName is the tmux session hosting a slug for an instance:
// `lore-<instance>-<slug>`. instance and slug are already constrained to
// [a-z0-9-], which avoids tmux's `:` and `.` name restrictions. Recorded on the
// registry row at spawn and treated as opaque after adoption.
func TmuxSessionName(instance, slug string) string {
	return "lore-" + instance + "-" + slug
}

// TmuxSessionNameSlugless is the tmux session name for a slugless session (a
// chat/work session carrying no work-item slug): it mirrors the
// `lore-<instance>-<slug>` scheme with a generated `chat-<short-id>` suffix in
// the slug position, so slugless sessions host under tmux and adopt back exactly
// like slugged ones. The suffix is [a-z0-9-] (hex), keeping the tmux name free of
// tmux's `:`/`.` restrictions. The name is minted once here and carried onto the
// registry row (SessionProcessStartedMsg.Tmux); adoption re-attaches by that
// recorded name, never by the empty slug. A CSPRNG failure degrades to a
// timestamp-free fixed suffix, still unique enough within one instance's live set
// because concurrent slugless sessions already share the empty-slug map key.
func TmuxSessionNameSlugless(instance string) string {
	b := make([]byte, 4)
	if _, err := rand.Read(b); err != nil {
		return "lore-" + instance + "-chat-00000000"
	}
	return "lore-" + instance + "-chat-" + hex.EncodeToString(b)
}

// tmuxOptionPins is the D2 pinned-option sequence applied at session creation, as
// tmux command arguments with literal ";" separators. Each pin removes a specific
// screen-state-contract hazard and the set matches the one Phase 1 re-verified the
// harness signatures against on this server:
//   - default-terminal tmux-256color: the pane's TERM must be deterministic for the
//     contract to transfer (Phase 1 ran where it was the default; it is not
//     everywhere).
//   - escape-time 0: no ESC coalescing.
//   - exit-empty on: pane death → session death → attach-client EOF, so the existing
//     StreamComplete/done teardown fires unchanged for tmux-hosted sessions.
//   - history-limit: modest, bounds pane memory.
//   - prefix none AND prefix2 none: both key tables cleared so no C-b/C-a byte in an
//     injected payload or keystroke is intercepted instead of reaching the harness.
//   - status off: no status line synthesising a row that breaks bottom-region
//     signature anchors.
//   - remain-on-exit off: a dead pane must not linger and strand done-detection.
//   - window-size latest: for a window with no size of its own, the active client
//     dictates dimensions so pty.Setsize resize forwarding keeps working. Every
//     window lore creates or re-attaches gets its own manual size
//     (pinTmuxWindowSize), which this global option does not override; it still
//     governs windows created before that pin, and older lore-tui builds keep
//     re-applying it.
//
// Set globally (`set -g`) before new-session so history-limit and default-terminal
// are in force when the pane spawns; re-applying on an already-running server is an
// idempotent no-op.
func tmuxOptionPins() []string {
	pins := [][2]string{
		{"default-terminal", "tmux-256color"},
		{"escape-time", "0"},
		{"exit-empty", "on"},
		{"history-limit", strconv.Itoa(tmuxHistoryLimit)},
		{"prefix", "none"},
		{"prefix2", "none"},
		{"status", "off"},
		{"remain-on-exit", "off"},
		{"window-size", "latest"},
	}
	var out []string
	for _, p := range pins {
		out = append(out, "set", "-g", p[0], p[1], ";")
	}
	return out
}

func tmuxRGBFeaturePin() []string {
	return []string{"set", "-as", "terminal-features", ",*:RGB", ";"}
}

// tmuxOwnedPaneVars are the variables tmux itself sets in every pane, overriding
// whatever the launching client passes: the terminal type from default-terminal,
// the terminal program and its version, tmux's nesting markers, the default shell,
// and the pane's working directory.
var tmuxOwnedPaneVars = []string{"TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TMUX", "TMUX_PANE", "SHELL", "PWD"}

// tmuxPaneEnvScript starts the harness from an empty environment: the values tmux
// gave this pane for its own variables, then the launcher's KEY=VAL list and the
// harness command passed as arguments. tmux builds a pane's environment from the
// server's global environment, which is whatever the client that started the
// shared server had, and -e can add to that but never remove from it. Starting
// from nothing is the only way the pane gets exactly the launcher's environment.
// Each step execs, so the pane pid tmux reports is the harness process.
var tmuxPaneEnvScript = func() string {
	script := "exec /usr/bin/env -i"
	for _, name := range tmuxOwnedPaneVars {
		script += " ${" + name + "+\"" + name + "=$" + name + "\"}"
	}
	return script + ` "$@"`
}()

// tmuxPaneEnv is the complete environment a new pane's harness runs with, as
// KEY=VAL entries: the process environment plus the session extras
// (LORE_FRAMEWORK, LORE_SESSION_*), with later entries winning. Variables tmux owns
// in the pane are left out so tmux's values stand, as they always have, and
// COLORTERM is replaced with the capability this embedder actually provides.
func tmuxPaneEnv(extras []string) []string {
	var out []string
	add := func(kv string) {
		key, _, ok := strings.Cut(kv, "=")
		if !ok || key == "" || key == "COLORTERM" || slices.Contains(tmuxOwnedPaneVars, key) {
			return
		}
		out = append(out, kv)
	}
	for _, kv := range os.Environ() {
		add(kv)
	}
	for _, kv := range extras {
		add(kv)
	}
	return append(out, "COLORTERM=truecolor")
}

// createTmuxSession creates the detached, option-pinned tmux session that hosts
// the harness and returns its pane PID (the harness process, captured via
// new-session's -P -F so the close ladder can later signal it directly rather than
// the attach client). env is the per-session extra environment; harnessBin/args is
// the exact command the direct-PTY path would have run. The new window is pinned
// at cols x rows (pinTmuxWindowSize) before it is returned; a session that was
// created but could not be pinned or identified is killed and an error returned.
func createTmuxSession(name, worktreeDir string, cols, rows int, env []string, harnessBin string, harnessArgs []string) (int, error) {
	if strings.Contains(harnessBin, "=") {
		// env(1) would read the path as one more assignment and run the next argument instead.
		return 0, fmt.Errorf("tmux new-session: harness path %q contains '='", harnessBin)
	}
	args := tmuxSessionArgs(name, worktreeDir, cols, rows, env, harnessBin, harnessArgs)

	cmd := exec.Command(tmuxBinary, args...)
	out, err := cmd.Output()
	if err != nil {
		// No kill here: a failed new-session made nothing, and the name may
		// belong to another live session ("duplicate session").
		return 0, fmt.Errorf("tmux new-session: %w", err)
	}
	pid, perr := strconv.Atoi(strings.TrimSpace(string(out)))
	if perr != nil {
		killTmuxSession(name)
		return 0, fmt.Errorf("parse pane pid %q: %w", strings.TrimSpace(string(out)), perr)
	}
	// Its own invocation, not one more command in the new-session chain: tmux
	// splits a command line at every literal ";" argument, and harness arguments
	// may contain one.
	if err := pinTmuxWindowSize(name, cols, rows); err != nil {
		killTmuxSession(name)
		return 0, err
	}
	return pid, nil
}

// pinTmuxWindowSize resizes the session's window to cols x rows with
// resize-window, which also sets that window's own window-size option to
// manual. From then on no attach client changes the window's size, whatever its
// own size, flags or activity, and neither does a later `set -g window-size
// latest` from another lore-tui, so the harness keeps one size however many
// viewers attach. The global window-size latest pin stays for windows created
// before this pin existed. The size is the caller's: the session's creator and
// whoever re-attaches it pass the size their own client and screen reader use.
func pinTmuxWindowSize(name string, cols, rows int) error {
	if cols < 1 || rows < 1 {
		return fmt.Errorf("tmux resize-window %s: invalid size %dx%d", name, cols, rows)
	}
	out, err := exec.Command(tmuxBinary, tmuxWindowPinArgs(name, cols, rows)...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("tmux resize-window %s to %dx%d: %w: %s", name, cols, rows, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// tmuxWindowPinArgs targets the session's current window by exact session name
// ("=name:"), so a pin never lands on another session whose name the target
// merely prefixes.
func tmuxWindowPinArgs(name string, cols, rows int) []string {
	return []string{"-L", config.TmuxServer(), "resize-window", "-t", "=" + name + ":",
		"-x", strconv.Itoa(cols), "-y", strconv.Itoa(rows)}
}

func tmuxSessionArgs(name, worktreeDir string, cols, rows int, env []string, harnessBin string, harnessArgs []string) []string {
	args := []string{"-L", config.TmuxServer(), "-f", "/dev/null"}
	args = append(args, tmuxOptionPins()...)
	args = append(args, tmuxRGBFeaturePin()...)
	args = append(args, "new-session", "-d", "-s", name, "-x", strconv.Itoa(cols), "-y", strconv.Itoa(rows), "-c", worktreeDir)
	args = append(args, "-P", "-F", "#{pane_pid}", "--", "/bin/sh", "-c", tmuxPaneEnvScript, "lore-pane")
	args = append(args, tmuxPaneEnv(env)...)
	args = append(args, harnessBin)
	args = append(args, harnessArgs...)
	return args
}

// tmuxAttachCommand builds the `tmux attach-session` client that runs under the
// panel's PTY. Its stdout is the pane's redraw stream the libghostty emulator
// consumes; its stdin carries keystrokes and injection into the pane. Killing this
// process detaches the client and leaves the pane (harness) running — that is the
// D8 quit-detach mechanism, not a session kill.
func tmuxAttachCommand(name string) *exec.Cmd {
	cmd := exec.Command(tmuxBinary, "-L", config.TmuxServer(), "attach-session", "-t", name)
	cmd.Env = os.Environ()
	return cmd
}

// killTmuxSession tears down a tmux session on the dedicated server. Best-effort:
// used to reclaim a just-created detached session that could not be pinned or
// whose attach client failed to start, so it is not left orphaned with no client
// and no registry row. The exact-name target matters when the session has
// already died: a plain target would then match a longer live name by prefix.
func killTmuxSession(name string) {
	_ = exec.Command(tmuxBinary, "-L", config.TmuxServer(), "kill-session", "-t", "="+name).Run()
}

// TmuxHasSession reports whether the named tmux session is still alive on the
// dedicated server — the adoption scan's liveness filter for whether a dead
// instance's recorded session can be reattached or must be journaled closed.
func TmuxHasSession(name string) bool {
	if name == "" {
		return false
	}
	return exec.Command(tmuxBinary, "-L", config.TmuxServer(), "has-session", "-t", name).Run() == nil
}

// tmuxPanePID re-queries the pane PID of a live session — used on adoption, where
// the original spawn's captured pane PID died with the crashed TUI's memory but the
// tmux session (and its harness) survived.
func tmuxPanePID(name string) (int, error) {
	out, err := exec.Command(tmuxBinary, "-L", config.TmuxServer(),
		"list-panes", "-t", name, "-F", "#{pane_pid}").Output()
	if err != nil {
		return 0, fmt.Errorf("tmux list-panes: %w", err)
	}
	line := strings.TrimSpace(string(out))
	if i := strings.IndexByte(line, '\n'); i >= 0 {
		line = line[:i] // first pane hosts the harness
	}
	pid, perr := strconv.Atoi(line)
	if perr != nil {
		return 0, fmt.Errorf("parse pane pid %q: %w", line, perr)
	}
	return pid, nil
}

// TmuxPanePID returns the current harness pane PID for persisted ownership
// validation during startup adoption.
func TmuxPanePID(name string) (int, error) { return tmuxPanePID(name) }

// TmuxPaneCWD returns the current directory of the session's harness pane.
// Recovery uses it to prove the surviving process still occupies its persisted
// worktree before transferring ownership to a new TUI instance.
func TmuxPaneCWD(name string) (string, error) {
	out, err := exec.Command(tmuxBinary, "-L", config.TmuxServer(),
		"list-panes", "-t", name, "-F", "#{pane_current_path}").Output()
	if err != nil {
		return "", fmt.Errorf("tmux list-panes cwd: %w", err)
	}
	cwd := strings.TrimSpace(string(out))
	if cwd == "" {
		return "", fmt.Errorf("tmux list-panes cwd: empty pane path")
	}
	return cwd, nil
}

// captureTmuxPaneHistory returns the pane's retained history plus its visible
// screen as display rows, preserving ANSI attributes. A tmux attach client
// redraws a fixed terminal screen, so the outer libghostty emulator cannot
// reconstruct tmux's history from that redraw stream; capture-pane is the
// authoritative read side for scrollback on a tmux-hosted session.
func captureTmuxPaneHistory(name string) ([]string, error) {
	if name == "" {
		return nil, fmt.Errorf("capture tmux history: empty session name")
	}
	return captureTmuxPaneHistoryOn(nil, name)
}

// captureTmuxPaneHistoryOn is captureTmuxPaneHistory against a target under the
// given environment; a nil env is this process's own.
func captureTmuxPaneHistoryOn(env []string, target string) ([]string, error) {
	cmd := exec.Command(tmuxBinary, "-L", config.TmuxServer(),
		"capture-pane", "-p", "-e", "-S", "-", "-t", target)
	cmd.Env = env
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("tmux capture-pane: %w", err)
	}
	text := strings.ReplaceAll(string(out), "\r\n", "\n")
	lines := strings.Split(text, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	return lines, nil
}

// viewerTerm is the terminal a viewer's tmux client is told it runs in: the
// panel's emulator understands xterm-256color, and tmux refuses to attach a
// client whose TERM it has no usable terminfo for.
const viewerTerm = "xterm-256color"

// viewerTmuxEnv is the environment of every tmux command a viewer runs. A viewer
// is a separate process from the store host that owns the session, so it finds
// the host's tmux server under the TMUX_TMPDIR the login's supervisor recorded,
// not its own (config.SupervisorTmuxTmpdir); with no record it keeps its own.
func viewerTmuxEnv() []string {
	dir, recorded := config.SupervisorTmuxTmpdir()
	var env []string
	for _, kv := range os.Environ() {
		key, _, _ := strings.Cut(kv, "=")
		if key == "TERM" || (recorded && key == "TMUX_TMPDIR") {
			continue
		}
		env = append(env, kv)
	}
	env = append(env, "TERM="+viewerTerm)
	if recorded && dir != "" {
		env = append(env, "TMUX_TMPDIR="+dir)
	}
	return env
}

// ViewerSessionAlive reports whether the named session is live on the store
// hosts' tmux server, found the way a viewer finds it.
func ViewerSessionAlive(name string) bool {
	return tmuxSessionAliveOn(viewerTmuxEnv(), name)
}

func tmuxSessionAliveOn(env []string, name string) bool {
	if name == "" {
		return false
	}
	cmd := exec.Command(tmuxBinary, "-L", config.TmuxServer(), "has-session", "-t", "="+name)
	cmd.Env = env
	return cmd.Run() == nil
}

var tmuxVersionNumber = regexp.MustCompile(`(\d+)\.(\d+)`)

// tmuxHasClientFlags reports whether a `tmux -V` line names a tmux whose
// attach-session takes -f client flags, which arrived in 3.2. A line with no
// version number, such as a build from master, is taken to be current.
func tmuxHasClientFlags(version string) bool {
	m := tmuxVersionNumber.FindStringSubmatch(version)
	if m == nil {
		return true
	}
	major, _ := strconv.Atoi(m[1])
	minor, _ := strconv.Atoi(m[2])
	return major > 3 || (major == 3 && minor >= 2)
}

func tmuxVersionOn(env []string) string {
	cmd := exec.Command(tmuxBinary, "-V")
	cmd.Env = env
	out, _ := cmd.Output()
	return strings.TrimSpace(string(out))
}

// viewerAttachArgs is a viewer's read-write client. ignore-size keeps the client
// out of the window's size for windows that predate the per-window pin; on a
// pinned window no client affects the size either way.
func viewerAttachArgs(name string, ignoreSize bool) []string {
	args := []string{"-L", config.TmuxServer(), "attach-session"}
	if ignoreSize {
		args = append(args, "-f", "ignore-size")
	}
	return append(args, "-t", "="+name)
}
