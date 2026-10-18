package work

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/anticorrelator/lore/tui/internal/config"
)

func TestTmuxLaunchCapabilityContractHarnessMatrix(t *testing.T) {
	t.Setenv("TERM", "operator-term")
	t.Setenv("COLORTERM", "operator-value")
	t.Setenv("TMUX", "stale")
	t.Setenv("TMUX_PANE", "%99")
	t.Setenv("TERM_PROGRAM", "operator-terminal")
	t.Setenv("SHELL", "/operator/shell")
	t.Setenv("PANE_CONTRACT_CARRIED", "carried")

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
			for _, stale := range []string{"TERM=operator-term", "COLORTERM=operator-value", "COLORTERM=wrong", "TMUX=stale",
				"TMUX_PANE=%99", "TERM_PROGRAM=operator-terminal", "SHELL=/operator/shell"} {
				if strings.Contains(joined, stale) {
					t.Errorf("tmux args leaked %q", stale)
				}
			}
			if strings.Count(joined, "COLORTERM=truecolor") != 1 {
				t.Errorf("tmux args COLORTERM count = %d, want 1", strings.Count(joined, "COLORTERM=truecolor"))
			}
			if !strings.Contains(joined, "new-session\x00-d\x00-s\x00lore-test-session\x00-x\x0080\x00-y\x0024\x00-c\x00/tmp/session-worktree") {
				t.Errorf("tmux args did not pin the pane cwd")
			}
			// The pane's environment is set by its command, not by -e assignments
			// layered over whatever the tmux server started with.
			if n := strings.Count(joined, "\x00-e\x00"); n > 0 {
				t.Errorf("tmux args still layer %d -e assignments over the server environment", n)
			}
			separator := slices.Index(args, "--")
			if separator < 0 || len(args) < separator+5 || args[separator+1] != "/bin/sh" || args[separator+2] != "-c" ||
				!strings.Contains(args[separator+3], "/usr/bin/env -i") {
				t.Fatalf("pane command does not start from an empty environment: it begins %q", args[max(separator, 0):min(max(separator, 0)+3, len(args))])
			}
			command := args[separator+4:]
			wantTail := []string{fixture.binary, "--fixture"}
			if !slices.Equal(command[len(command)-len(wantTail):], wantTail) {
				t.Errorf("pane command tail = %v, want %v", command[len(command)-len(wantTail):], wantTail)
			}
			for _, want := range []string{"LORE_FRAMEWORK=" + fixture.framework, "PANE_CONTRACT_CARRIED=carried", "COLORTERM=truecolor"} {
				if !slices.Contains(command, want) {
					t.Errorf("pane command lost %q", want)
				}
			}
		})
	}
}

// A store host and a visible TUI share their runtime's tmux server, and tmux
// gives every new pane the environment of whichever client started that server.
// The pane must still get exactly the environment its launcher intends.
func TestTmuxPaneEnvironmentIgnoresTheServersStartupEnvironment(t *testing.T) {
	if _, err := exec.LookPath(tmuxBinary); err != nil {
		t.Skip("tmux is not installed")
	}
	// Short and private: a macOS socket path must fit 104 bytes.
	root, err := os.MkdirTemp("/tmp", "lore-pane-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	if root, err = filepath.EvalSymlinks(root); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMUX_TMPDIR", root)
	t.Setenv(config.SessionRuntimeEnv, fmt.Sprintf("panetest-%d", os.Getpid()))
	socket := filepath.Join(root, fmt.Sprintf("tmux-%d", os.Getuid()), config.TmuxServer())
	t.Cleanup(func() { _ = exec.Command(tmuxBinary, "-S", socket, "kill-server").Run() })
	for _, name := range []string{"LORE_KNOWLEDGE_DIR", "CLAUDE_CODE_CHILD_SESSION", "SERVER_STARTUP_ONLY"} {
		t.Setenv(name, "")
		os.Unsetenv(name)
	}
	t.Setenv("PANE_FIXTURE_CARRIED", "carried")

	first := exec.Command(tmuxBinary, "-L", config.TmuxServer(), "-f", "/dev/null", "new-session", "-d", "-s", "first-client", "sleep", "120")
	first.Env = append(os.Environ(), "LORE_KNOWLEDGE_DIR=/other/store", "CLAUDE_CODE_CHILD_SESSION=1", "SERVER_STARTUP_ONLY=leaked")
	if out, err := first.CombinedOutput(); err != nil {
		t.Fatalf("start the server from another client: %v: %s", err, out)
	}

	work := filepath.Join(root, "worktree")
	if err := os.Mkdir(work, 0o755); err != nil {
		t.Fatal(err)
	}
	envFile, pidFile := filepath.Join(root, "pane.env"), filepath.Join(root, "pane.pid")
	script := "echo $$ > " + pidFile + "; env > " + envFile + ".tmp; mv " + envFile + ".tmp " + envFile + "; exec sleep 120"
	pid, err := createTmuxSession("lore-pane-env-probe", work, 80, 24,
		[]string{"LORE_FRAMEWORK=claude-code", "LORE_SESSION_SLUG=pane-probe"}, "/bin/sh", []string{"-c", script})
	if err != nil {
		t.Fatal(err)
	}
	var data []byte
	deadline := time.Now().Add(10 * time.Second)
	for {
		if data, err = os.ReadFile(envFile); err == nil || time.Now().After(deadline) {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("the pane never wrote its environment: %v", err)
	}
	env := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if key, value, ok := strings.Cut(line, "="); ok {
			env[key] = value
		}
	}
	for _, name := range []string{"LORE_KNOWLEDGE_DIR", "CLAUDE_CODE_CHILD_SESSION", "SERVER_STARTUP_ONLY"} {
		if value, ok := env[name]; ok {
			t.Errorf("pane inherited %s=%s from the client that started the server", name, value)
		}
	}
	for name, want := range map[string]string{"PANE_FIXTURE_CARRIED": "carried", "LORE_FRAMEWORK": "claude-code",
		"LORE_SESSION_SLUG": "pane-probe", "TERM": "tmux-256color", "COLORTERM": "truecolor", "PWD": work} {
		if env[name] != want {
			t.Errorf("pane %s = %q, want %q", name, env[name], want)
		}
	}
	if !strings.HasPrefix(env["TMUX"], socket+",") || !strings.HasPrefix(env["TMUX_PANE"], "%") {
		t.Errorf("pane lost tmux's own markers: TMUX=%q TMUX_PANE=%q", env["TMUX"], env["TMUX_PANE"])
	}
	written, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(written)) != strconv.Itoa(pid) {
		t.Errorf("harness pid %s is not the pane pid %d that close and adoption signal", strings.TrimSpace(string(written)), pid)
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

func TestTmuxCommandsFollowSessionRuntime(t *testing.T) {
	t.Setenv(config.SessionRuntimeEnv, "dev")
	want := []string{"-L", "lore-tui-dev"}
	for name, args := range map[string][]string{
		"session": tmuxSessionArgs("s", "/tmp/w", 80, 24, nil, "codex", nil),
		"attach":  tmuxAttachCommand("s").Args[1:],
		"pin":     tmuxWindowPinArgs("s", 80, 24),
		"viewer":  viewerAttachArgs("s", true),
	} {
		if !slices.Equal(args[:2], want) {
			t.Errorf("%s args = %v, want server %v", name, args, want)
		}
	}

	dir := t.TempDir()
	logPath := filepath.Join(dir, "tmux.log")
	if err := os.WriteFile(filepath.Join(dir, "tmux"), []byte("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$TMUX_LOG\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("TMUX_LOG", logPath)
	t.Setenv("LORE_DATA_DIR", t.TempDir())
	TmuxHasSession("s")
	_, _ = TmuxPanePID("s")
	_, _ = TmuxPaneCWD("s")
	_, _ = captureTmuxPaneHistory("s")
	_, _ = CaptureTmuxHistory("s", 10, 100)
	killTmuxSession("s")
	_ = pinTmuxWindowSize("s", 80, 24)
	ViewerSessionAlive("s")
	_, _ = captureTmuxPaneHistoryOn(viewerTmuxEnv(), "=s:")
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 9 {
		t.Fatalf("tmux calls = %q, want 9", lines)
	}
	for _, line := range lines {
		if !strings.HasPrefix(line, "-L lore-tui-dev ") {
			t.Errorf("tmux call left the runtime's server: %q", line)
		}
	}
}
