package work

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
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

// tmuxPaneEnv builds the `-e KEY=VAL` argument pairs for a new pane's environment.
// It carries the process base env plus the session extras (LORE_FRAMEWORK,
// LORE_SESSION_*) explicitly rather than relying on tmux server-env inheritance:
// the server is shared across every lore TUI on the host, so an inherited pane env
// would be whichever instance happened to start the server. TERM and the
// tmux-owned TMUX/TMUX_PANE vars are dropped so default-terminal wins and tmux's
// own nesting markers are not shadowed by a stale value.
func tmuxPaneEnv(extras []string) []string {
	var out []string
	for _, kv := range os.Environ() {
		key := kv
		if i := strings.IndexByte(kv, '='); i >= 0 {
			key = kv[:i]
		}
		switch key {
		case "TERM", "TMUX", "TMUX_PANE":
			continue
		}
		out = append(out, "-e", kv)
	}
	for _, kv := range extras {
		out = append(out, "-e", kv)
	}
	return out
}

// createTmuxSession creates the detached, option-pinned tmux session that hosts
// the harness and returns its pane PID (the harness process, captured via
// new-session's -P -F so the close ladder can later signal it directly rather than
// the attach client). env is the per-session extra environment; harnessBin/args is
// the exact command the direct-PTY path would have run.
func createTmuxSession(name string, cols, rows int, env []string, harnessBin string, harnessArgs []string) (int, error) {
	args := []string{"-L", tmuxServerLabel, "-f", "/dev/null"}
	args = append(args, tmuxOptionPins()...)
	args = append(args, "new-session", "-d", "-s", name, "-x", strconv.Itoa(cols), "-y", strconv.Itoa(rows))
	args = append(args, tmuxPaneEnv(env)...)
	args = append(args, "-P", "-F", "#{pane_pid}", "--", harnessBin)
	args = append(args, harnessArgs...)

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
