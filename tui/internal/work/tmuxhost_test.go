package work

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestTmuxLaunchCapabilityContractHarnessMatrix(t *testing.T) {
	t.Setenv("TERM", "operator-term")
	t.Setenv("COLORTERM", "operator-value")
	t.Setenv("TMUX", "stale")
	t.Setenv("TMUX_PANE", "%99")

	fixtures := []struct {
		framework string
		binary    string
	}{
		{"claude-code", "claude"},
		{"codex", "codex"},
		{"opencode", "opencode"},
	}
	for _, fixture := range fixtures {
		t.Run(fixture.framework, func(t *testing.T) {
			args := tmuxSessionArgs("lore-test-session", "/tmp/session-worktree", 80, 24,
				[]string{"LORE_FRAMEWORK=" + fixture.framework, "COLORTERM=wrong"},
				fixture.binary, []string{"--fixture"})
			joined := strings.Join(args, "\x00")
			for _, stale := range []string{"TERM=operator-term", "COLORTERM=operator-value", "COLORTERM=wrong", "TMUX=stale", "TMUX_PANE=%99"} {
				if strings.Contains(joined, stale) {
					t.Errorf("tmux args leaked %q: %v", stale, args)
				}
			}
			if strings.Count(joined, "COLORTERM=truecolor") != 1 {
				t.Errorf("tmux args COLORTERM count = %d, want 1: %v", strings.Count(joined, "COLORTERM=truecolor"), args)
			}
			if !strings.Contains(joined, "LORE_FRAMEWORK="+fixture.framework) {
				t.Errorf("tmux args lost framework identity: %v", args)
			}
			if !strings.Contains(joined, "new-session\x00-d\x00-s\x00lore-test-session\x00-x\x0080\x00-y\x0024\x00-c\x00/tmp/session-worktree") {
				t.Errorf("tmux args did not pin the pane cwd: %v", args)
			}
			wantTail := []string{"--", fixture.binary, "--fixture"}
			if !slices.Equal(args[len(args)-len(wantTail):], wantTail) {
				t.Errorf("tmux command tail = %v, want %v", args[len(args)-len(wantTail):], wantTail)
			}
		})
	}
}

func TestTmuxCapabilityPinsPreserveExistingOptions(t *testing.T) {
	wantPins := [][2]string{
		{"default-terminal", "tmux-256color"},
		{"escape-time", "0"},
		{"exit-empty", "on"},
		{"history-limit", fmt.Sprint(tmuxHistoryLimit)},
		{"prefix", "none"},
		{"prefix2", "none"},
		{"status", "off"},
		{"remain-on-exit", "off"},
		{"window-size", "latest"},
	}
	got := tmuxOptionPins()
	if len(got) != len(wantPins)*5 {
		t.Fatalf("option pin args = %v", got)
	}
	for i, pin := range wantPins {
		if !slices.Equal(got[i*5:i*5+5], []string{"set", "-g", pin[0], pin[1], ";"}) {
			t.Errorf("pin %d = %v, want %v", i, got[i*5:i*5+5], pin)
		}
	}
	if got := tmuxRGBFeaturePin(); !slices.Equal(got, []string{"set", "-as", "terminal-features", ",*:RGB", ";"}) {
		t.Errorf("RGB feature pin = %v", got)
	}
}

func TestTmuxMirrorOpenArgsKeepStateCaptureAndPipeAtomic(t *testing.T) {
	got := tmuxMirrorOpenArgs("lore-remote", "/tmp/lore-tui-mirror-ab12/stream")
	want := []string{
		"-L", "lore-tui",
		"display-message", "-p", "-t", "lore-remote", tmuxMirrorStateFormat, ";",
		"capture-pane", "-p", "-e", "-S", "-", "-t", "lore-remote", ";",
		"pipe-pane", "-O", "-t", "lore-remote", "cat > /tmp/lore-tui-mirror-ab12/stream",
	}
	if !slices.Equal(got, want) {
		t.Fatalf("mirror open args = %#v, want %#v", got, want)
	}
	if strings.Contains(strings.Join(got, " "), "attach") {
		t.Fatalf("mirror observation attached a tmux client: %v", got)
	}
}

func TestParseTmuxMirrorOpenOutputSeparatesStateAndDisplayRows(t *testing.T) {
	state, rows, err := parseTmuxMirrorOpenOutput([]byte("4 2 80 24 1 133\nfirst\r\n\x1b[31msecond\x1b[0m\n"))
	if err != nil {
		t.Fatal(err)
	}
	wantState := (TmuxMirrorPaneState{CursorX: 4, CursorY: 2, Width: 80, Height: 24, Alternate: true, HistorySize: 133})
	if state != wantState {
		t.Fatalf("state = %+v, want %+v", state, wantState)
	}
	if !slices.Equal(rows, []string{"first", "\x1b[31msecond\x1b[0m"}) {
		t.Fatalf("rows = %#v", rows)
	}
}

func TestTmuxMirrorWriteAndDetachArgs(t *testing.T) {
	text := "Enter literal text with spaces"
	if got := tmuxMirrorLiteralArgs("remote", text); !slices.Equal(got, []string{"-L", "lore-tui", "send-keys", "-t", "remote", "-l", text}) {
		t.Errorf("literal args = %#v", got)
	}
	if got := tmuxMirrorKeyArgs("remote", "Enter"); !slices.Equal(got, []string{"-L", "lore-tui", "send-keys", "-t", "remote", "Enter"}) {
		t.Errorf("key args = %#v", got)
	}
	if got := tmuxMirrorDetachArgs("remote"); !slices.Equal(got, []string{"-L", "lore-tui", "pipe-pane", "-t", "remote"}) {
		t.Errorf("detach args = %#v", got)
	}
}

func TestOpenTmuxMirrorSeedsThenStreamsFromFIFO(t *testing.T) {
	dir := t.TempDir()
	fake := filepath.Join(dir, "tmux")
	script := `#!/bin/sh
last=""
for arg in "$@"; do last="$arg"; done
fifo=${last#cat > }
(printf 'live-bytes' > "$fifo") &
printf '2 1 10 3 0 7\nseed-one\nseed-two\nseed-three\n'
`
	if err := os.WriteFile(fake, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	transport, state, rows, err := openTmuxMirror("remote")
	if err != nil {
		t.Fatal(err)
	}
	path := transport.path
	defer transport.closeLocal()
	if state.Width != 10 || state.Height != 3 || !slices.Equal(rows, []string{"seed-one", "seed-two", "seed-three"}) {
		t.Fatalf("open result state=%+v rows=%#v", state, rows)
	}
	select {
	case chunk, ok := <-transport.output:
		if !ok || string(chunk) != "live-bytes" {
			t.Fatalf("stream chunk = %q ok=%v", chunk, ok)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for mirror FIFO bytes")
	}
	transport.closeLocal()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("FIFO remains after local cleanup: %v", err)
	}
}

func TestOpenTmuxMirrorDetachesOwnedPipeWhenStateParsingFails(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(dir, "tmux.log")
	fake := filepath.Join(dir, "tmux")
	script := `#!/bin/sh
printf '%s\n' "$*" >> "$TMUX_LOG"
case "$*" in
  *display-message*)
    last=""
    for arg in "$@"; do last="$arg"; done
    fifo=${last#cat > }
    (printf 'unread' > "$fifo") &
    printf 'malformed-state\n'
    ;;
esac
`
	if err := os.WriteFile(fake, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("TMUX_LOG", logPath)

	transport, _, _, err := openTmuxMirror("remote")
	if err == nil {
		if transport != nil {
			transport.closeLocal()
		}
		t.Fatal("malformed state unexpectedly opened a mirror")
	}
	logData, readErr := os.ReadFile(logPath)
	if readErr != nil {
		t.Fatal(readErr)
	}
	lines := strings.Split(strings.TrimSpace(string(logData)), "\n")
	if len(lines) != 2 {
		t.Fatalf("tmux calls = %#v, want open then detach", lines)
	}
	if !strings.Contains(lines[0], "display-message -p -t remote") || !strings.Contains(lines[0], "capture-pane -p -e -S - -t remote") || !strings.Contains(lines[0], "pipe-pane -O -t remote") {
		t.Fatalf("first call was not atomic mirror open: %q", lines[0])
	}
	if lines[1] != "-L lore-tui pipe-pane -t remote" {
		t.Fatalf("failed open cleanup = %q, want no-command detach", lines[1])
	}
}
