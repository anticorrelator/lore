package work

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// tmuxBinary is resolved from PATH by exec at spawn time; TmuxAvailable's LookPath
// probe is what gates every use, so a bare name is safe here.
const tmuxBinary = "tmux"

// tmuxServerLabel is the dedicated tmux server socket lore sessions live on
// (`tmux -L lore-tui`), isolated from the user's default server so no user
// tmux.conf option can invalidate the screen-state contract the injection/peek
// stack was probed against.
const tmuxServerLabel = "lore-tui"

// tmuxHistoryLimit is the modest per-pane scrollback lore pins. Scrollback across
// recovery is an accepted loss (reattach redraws the visible screen only), so this
// bounds pane memory rather than preserving history.
const tmuxHistoryLimit = 5000

const tmuxMirrorStateFormat = "#{cursor_x} #{cursor_y} #{pane_width} #{pane_height} #{alternate_on} #{history_size}"

// TmuxMirrorPaneState is sampled immediately before a mirror's captured rows.
type TmuxMirrorPaneState struct {
	CursorX, CursorY int
	Width, Height    int
	Alternate        bool
	HistorySize      int
}

// tmuxMirrorTransport owns only one generation's local FIFO reader. Whether
// the corresponding tmux pipe may be detached is tracked by SessionPanelModel.
type tmuxMirrorTransport struct {
	dir    string
	path   string
	reader *os.File
	output <-chan []byte
	done   chan struct{}
	once   sync.Once
}

func tmuxMirrorOpenArgs(name, fifo string) []string {
	return []string{
		"-L", tmuxServerLabel,
		"display-message", "-p", "-t", name, tmuxMirrorStateFormat, ";",
		"capture-pane", "-p", "-e", "-S", "-", "-t", name, ";",
		"pipe-pane", "-O", "-t", name, "cat > " + fifo,
	}
}

func tmuxMirrorGeometryArgs(name string) []string {
	return []string{"-L", tmuxServerLabel, "display-message", "-p", "-t", name, "#{pane_width} #{pane_height}"}
}

func tmuxMirrorLiteralArgs(name, text string) []string {
	return []string{"-L", tmuxServerLabel, "send-keys", "-t", name, "-l", text}
}

func tmuxMirrorKeyArgs(name, key string) []string {
	return []string{"-L", tmuxServerLabel, "send-keys", "-t", name, key}
}

func tmuxMirrorDetachArgs(name string) []string {
	return []string{"-L", tmuxServerLabel, "pipe-pane", "-t", name}
}

func parseTmuxMirrorOpenOutput(out []byte) (TmuxMirrorPaneState, []string, error) {
	lineEnd := bytes.IndexByte(out, '\n')
	if lineEnd < 0 {
		return TmuxMirrorPaneState{}, nil, fmt.Errorf("tmux mirror state: missing state line")
	}
	var state TmuxMirrorPaneState
	var alternate int
	stateLine := strings.TrimSuffix(string(out[:lineEnd]), "\r")
	if n, err := fmt.Sscanf(stateLine, "%d %d %d %d %d %d",
		&state.CursorX, &state.CursorY, &state.Width, &state.Height, &alternate, &state.HistorySize); err != nil || n != 6 {
		if err == nil {
			err = fmt.Errorf("read %d fields", n)
		}
		return TmuxMirrorPaneState{}, nil, fmt.Errorf("parse tmux mirror state %q: %w", stateLine, err)
	}
	if state.Width < 1 || state.Height < 1 || state.CursorX < 0 || state.CursorY < 0 || (alternate != 0 && alternate != 1) {
		return TmuxMirrorPaneState{}, nil, fmt.Errorf("invalid tmux mirror state %q", stateLine)
	}
	state.Alternate = alternate == 1

	capture := strings.ReplaceAll(string(out[lineEnd+1:]), "\r\n", "\n")
	rows := strings.Split(capture, "\n")
	if len(rows) > 0 && rows[len(rows)-1] == "" {
		rows = rows[:len(rows)-1]
	}
	return state, rows, nil
}

func openTmuxMirror(name string) (*tmuxMirrorTransport, TmuxMirrorPaneState, []string, error) {
	if name == "" {
		return nil, TmuxMirrorPaneState{}, nil, fmt.Errorf("open tmux mirror: empty session name")
	}
	dir, err := os.MkdirTemp("/tmp", "lore-tui-mirror-")
	if err != nil {
		return nil, TmuxMirrorPaneState{}, nil, fmt.Errorf("create tmux mirror directory: %w", err)
	}
	fifo := dir + "/stream"
	cleanup := func() {
		_ = os.Remove(fifo)
		_ = os.Remove(dir)
	}
	if strings.Contains(fifo, "#{") {
		cleanup()
		return nil, TmuxMirrorPaneState{}, nil, fmt.Errorf("unsafe tmux mirror FIFO path %q", fifo)
	}
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		cleanup()
		return nil, TmuxMirrorPaneState{}, nil, fmt.Errorf("create tmux mirror FIFO: %w", err)
	}

	type readerResult struct {
		file *os.File
		err  error
	}
	readerReady := make(chan readerResult, 1)
	go func() {
		reader, openErr := os.Open(fifo)
		readerReady <- readerResult{file: reader, err: openErr}
	}()
	unblockReader := func() readerResult {
		for {
			select {
			case result := <-readerReady:
				return result
			default:
			}
			writer, _ := os.OpenFile(fifo, os.O_WRONLY|syscall.O_NONBLOCK, 0)
			if writer != nil {
				_ = writer.Close()
				return <-readerReady
			}
			time.Sleep(time.Millisecond)
		}
	}
	out, err := exec.Command(tmuxBinary, tmuxMirrorOpenArgs(name, fifo)...).Output()
	if err != nil {
		result := unblockReader()
		if result.file != nil {
			_ = result.file.Close()
		}
		cleanup()
		return nil, TmuxMirrorPaneState{}, nil, fmt.Errorf("tmux mirror open: %w", err)
	}
	var result readerResult
	select {
	case result = <-readerReady:
	case <-time.After(5 * time.Second):
		result = unblockReader()
		if result.file != nil {
			_ = result.file.Close()
		}
		cleanup()
		return nil, TmuxMirrorPaneState{}, nil, fmt.Errorf("tmux mirror FIFO writer did not connect")
	}
	if result.err != nil {
		cleanup()
		return nil, TmuxMirrorPaneState{}, nil, fmt.Errorf("open tmux mirror FIFO: %w", result.err)
	}
	reader := result.file
	state, rows, err := parseTmuxMirrorOpenOutput(out)
	if err != nil {
		detachErr := detachTmuxMirror(name)
		_ = reader.Close()
		cleanup()
		if detachErr != nil {
			return nil, TmuxMirrorPaneState{}, nil, errors.Join(err, detachErr)
		}
		return nil, TmuxMirrorPaneState{}, nil, err
	}
	done := make(chan struct{})
	transport := &tmuxMirrorTransport{dir: dir, path: fifo, reader: reader, done: done}
	transport.output = tmuxMirrorReader(reader, done)
	return transport, state, rows, nil
}

func tmuxMirrorReader(reader io.Reader, done <-chan struct{}) <-chan []byte {
	output := make(chan []byte, 64)
	go func() {
		defer close(output)
		buf := make([]byte, 32*1024)
		for {
			n, err := reader.Read(buf)
			if n > 0 {
				chunk := append([]byte(nil), buf[:n]...)
				select {
				case output <- chunk:
				case <-done:
					return
				}
			}
			if err != nil || n == 0 {
				return
			}
		}
	}()
	return output
}

func (t *tmuxMirrorTransport) closeLocal() {
	if t == nil {
		return
	}
	t.once.Do(func() {
		close(t.done)
		if t.reader != nil {
			_ = t.reader.Close()
		}
		_ = os.Remove(t.path)
		_ = os.Remove(t.dir)
	})
}

func tmuxMirrorGeometry(name string) (int, int, error) {
	out, err := exec.Command(tmuxBinary, tmuxMirrorGeometryArgs(name)...).Output()
	if err != nil {
		return 0, 0, fmt.Errorf("tmux mirror geometry: %w", err)
	}
	var width, height int
	if n, scanErr := fmt.Sscanf(strings.TrimSpace(string(out)), "%d %d", &width, &height); scanErr != nil || n != 2 || width < 1 || height < 1 {
		if scanErr == nil {
			scanErr = fmt.Errorf("invalid dimensions")
		}
		return 0, 0, fmt.Errorf("parse tmux mirror geometry %q: %w", strings.TrimSpace(string(out)), scanErr)
	}
	return width, height, nil
}

func sendTmuxMirrorLiteral(name, text string) error {
	if text == "" {
		return nil
	}
	if err := exec.Command(tmuxBinary, tmuxMirrorLiteralArgs(name, text)...).Run(); err != nil {
		return fmt.Errorf("tmux mirror send text: %w", err)
	}
	return nil
}

func sendTmuxMirrorKey(name, key string) error {
	if key == "" {
		return nil
	}
	if err := exec.Command(tmuxBinary, tmuxMirrorKeyArgs(name, key)...).Run(); err != nil {
		return fmt.Errorf("tmux mirror send key: %w", err)
	}
	return nil
}

func detachTmuxMirror(name string) error {
	if name == "" {
		return nil
	}
	if err := exec.Command(tmuxBinary, tmuxMirrorDetachArgs(name)...).Run(); err != nil {
		return fmt.Errorf("tmux mirror detach: %w", err)
	}
	return nil
}

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
//   - window-size latest: the sole attached client dictates dimensions so pty.Setsize
//     resize forwarding keeps working.
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

// tmuxPaneEnv builds the `-e KEY=VAL` argument pairs for a new pane's environment.
// It carries the process base env plus the session extras (LORE_FRAMEWORK,
// LORE_SESSION_*) explicitly rather than relying on tmux server-env inheritance:
// the server is shared across every lore TUI on the host, so an inherited pane env
// would be whichever instance happened to start the server. TERM and the
// tmux-owned TMUX/TMUX_PANE vars are dropped so default-terminal wins and tmux's
// own nesting markers are not shadowed by a stale value. COLORTERM is replaced
// with the capability this embedder actually provides.
func tmuxPaneEnv(extras []string) []string {
	var out []string
	for _, kv := range os.Environ() {
		key := kv
		if i := strings.IndexByte(kv, '='); i >= 0 {
			key = kv[:i]
		}
		switch key {
		case "TERM", "COLORTERM", "TMUX", "TMUX_PANE":
			continue
		}
		out = append(out, "-e", kv)
	}
	for _, kv := range extras {
		if strings.HasPrefix(kv, "COLORTERM=") {
			continue
		}
		out = append(out, "-e", kv)
	}
	out = append(out, "-e", "COLORTERM=truecolor")
	return out
}

// createTmuxSession creates the detached, option-pinned tmux session that hosts
// the harness and returns its pane PID (the harness process, captured via
// new-session's -P -F so the close ladder can later signal it directly rather than
// the attach client). env is the per-session extra environment; harnessBin/args is
// the exact command the direct-PTY path would have run.
func createTmuxSession(name, worktreeDir string, cols, rows int, env []string, harnessBin string, harnessArgs []string) (int, error) {
	args := tmuxSessionArgs(name, worktreeDir, cols, rows, env, harnessBin, harnessArgs)

	cmd := exec.Command(tmuxBinary, args...)
	out, err := cmd.Output()
	if err != nil {
		return 0, fmt.Errorf("tmux new-session: %w", err)
	}
	pid, perr := strconv.Atoi(strings.TrimSpace(string(out)))
	if perr != nil {
		return 0, fmt.Errorf("parse pane pid %q: %w", strings.TrimSpace(string(out)), perr)
	}
	return pid, nil
}

func tmuxSessionArgs(name, worktreeDir string, cols, rows int, env []string, harnessBin string, harnessArgs []string) []string {
	args := []string{"-L", tmuxServerLabel, "-f", "/dev/null"}
	args = append(args, tmuxOptionPins()...)
	args = append(args, tmuxRGBFeaturePin()...)
	args = append(args, "new-session", "-d", "-s", name, "-x", strconv.Itoa(cols), "-y", strconv.Itoa(rows), "-c", worktreeDir)
	args = append(args, tmuxPaneEnv(env)...)
	args = append(args, "-P", "-F", "#{pane_pid}", "--", harnessBin)
	args = append(args, harnessArgs...)
	return args
}

// tmuxAttachCommand builds the `tmux attach-session` client that runs under the
// panel's PTY. Its stdout is the pane's redraw stream the libghostty emulator
// consumes; its stdin carries keystrokes and injection into the pane. Killing this
// process detaches the client and leaves the pane (harness) running — that is the
// D8 quit-detach mechanism, not a session kill.
func tmuxAttachCommand(name string) *exec.Cmd {
	cmd := exec.Command(tmuxBinary, "-L", tmuxServerLabel, "attach-session", "-t", name)
	cmd.Env = os.Environ()
	return cmd
}

// killTmuxSession tears down a tmux session on the dedicated server. Best-effort:
// used to reclaim a just-created detached session whose attach client failed to
// start, so it is not left orphaned with no client and no registry row.
func killTmuxSession(name string) {
	_ = exec.Command(tmuxBinary, "-L", tmuxServerLabel, "kill-session", "-t", name).Run()
}

// TmuxHasSession reports whether the named tmux session is still alive on the
// dedicated server — the adoption scan's liveness filter for whether a dead
// instance's recorded session can be reattached or must be journaled closed.
func TmuxHasSession(name string) bool {
	if name == "" {
		return false
	}
	return exec.Command(tmuxBinary, "-L", tmuxServerLabel, "has-session", "-t", name).Run() == nil
}

// tmuxPanePID re-queries the pane PID of a live session — used on adoption, where
// the original spawn's captured pane PID died with the crashed TUI's memory but the
// tmux session (and its harness) survived.
func tmuxPanePID(name string) (int, error) {
	out, err := exec.Command(tmuxBinary, "-L", tmuxServerLabel,
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
	out, err := exec.Command(tmuxBinary, "-L", tmuxServerLabel,
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
	out, err := exec.Command(tmuxBinary, "-L", tmuxServerLabel,
		"capture-pane", "-p", "-e", "-S", "-", "-t", name).Output()
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
