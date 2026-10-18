package work

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/anticorrelator/lore/tui/internal/config"
)

func TestMain(m *testing.M) {
	// A tmux pane a test started: this binary is the pane's first process, as
	// lore-tui is for its host's panes.
	if len(os.Args) > 1 && os.Args[1] == PaneExecFlag {
		fmt.Fprintln(os.Stderr, PaneExec(os.Args[2:]))
		os.Exit(127)
	}
	os.Exit(m.Run())
}

// privatePaneServer points this test's tmux calls at a server of its own: a
// short TMUX_TMPDIR under /tmp (a macOS socket path must fit 104 bytes) and its
// own runtime, set before the first tmux call and killed in cleanup.
func privatePaneServer(t *testing.T, label string) string {
	t.Helper()
	if _, err := exec.LookPath(tmuxBinary); err != nil {
		t.Skip("tmux is not installed")
	}
	root, err := os.MkdirTemp("/tmp", "lore-pane-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	if root, err = filepath.EvalSymlinks(root); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMUX_TMPDIR", root)
	t.Setenv(config.SessionRuntimeEnv, fmt.Sprintf("%s-%d", label, os.Getpid()))
	socket := filepath.Join(root, fmt.Sprintf("tmux-%d", os.Getuid()), config.TmuxServer())
	t.Cleanup(func() { _ = exec.Command(tmuxBinary, "-S", socket, "kill-server").Run() })
	return root
}

func waitForFile(t *testing.T, path string) []byte {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		data, err := os.ReadFile(path)
		if err == nil {
			return data
		}
		if time.Now().After(deadline) {
			t.Fatalf("the pane never wrote %s: %v", path, err)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// A position-bearing harness argv is larger than tmux accepts in one command
// ("command too long" past about 16 KB). The pane still starts, with the whole
// argv and environment, because neither rides the tmux command line.
func TestTmuxPaneLaunchCarriesAnArgvLargerThanTmuxAccepts(t *testing.T) {
	root := privatePaneServer(t, "panebig")
	work := filepath.Join(root, "worktree")
	if err := os.Mkdir(work, 0o755); err != nil {
		t.Fatal(err)
	}
	// Spaces, quotes, '=' and a trailing ';' too: tmux splits a command at any
	// argument that ends in ';'.
	big := strings.Repeat(`brief "x"='y' ; `, 1600) + ";"
	bigEnv := strings.Repeat("e", 8*1024)
	if len(big) < 20*1024 {
		t.Fatalf("fixture argument is only %d bytes", len(big))
	}
	argvOut, envOut, pidOut := filepath.Join(root, "argv.out"), filepath.Join(root, "env.out"), filepath.Join(root, "pid.out")
	script := `printf %s "$1" > "$2.tmp" && mv "$2.tmp" "$2"; printf %s "$LORE_BIG_ENV" > "$3.tmp" && mv "$3.tmp" "$3"; echo $$ > "$4.tmp" && mv "$4.tmp" "$4"; exec sleep 120`
	launch := filepath.Join(root, "launch")
	pid, err := createTmuxSession("lore-pane-big-argv", work, 80, 24, []string{"LORE_BIG_ENV=" + bigEnv},
		"/bin/sh", []string{"-c", script, "lore-probe", big, argvOut, envOut, pidOut}, launch)
	if err != nil {
		t.Fatalf("a %d-byte argument did not launch: %v", len(big), err)
	}
	if got := string(waitForFile(t, argvOut)); got != big {
		t.Errorf("the harness got a %d-byte argument, want the %d bytes sent", len(got), len(big))
	}
	if got := string(waitForFile(t, envOut)); got != bigEnv {
		t.Errorf("the harness got LORE_BIG_ENV of %d bytes, want %d", len(got), len(bigEnv))
	}
	if got := strings.TrimSpace(string(waitForFile(t, pidOut))); got != strconv.Itoa(pid) {
		t.Errorf("harness pid %s is not the pane pid %d that close and adoption signal", got, pid)
	}
	if specs, _ := filepath.Glob(filepath.Join(launch, "*")); len(specs) != 0 {
		t.Errorf("launch specs left after the pane started: %v", specs)
	}
}

// The harness path is exec'd as given, never read as an assignment or a shell
// word, so a path with '=' in it runs like any other.
func TestTmuxPaneLaunchRunsAHarnessWhosePathHasAnEqualsSign(t *testing.T) {
	root := privatePaneServer(t, "paneeq")
	dir := filepath.Join(root, "a=b")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	ran := filepath.Join(root, "ran.out")
	harness := filepath.Join(dir, "harness")
	if err := os.WriteFile(harness, []byte("#!/bin/sh\necho $$ > "+ran+".tmp && mv "+ran+".tmp "+ran+"\nexec sleep 120\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	pid, err := createTmuxSession("lore-pane-equals", root, 80, 24, nil, harness, nil, filepath.Join(root, "launch"))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(waitForFile(t, ran))); got != strconv.Itoa(pid) {
		t.Errorf("harness at %s ran as pid %s, want pane pid %d", harness, got, pid)
	}
}

// A pane whose spec is missing or names no harness exits with the reason
// instead of running anything.
func TestPaneExecRefusesAMissingOrEmptySpec(t *testing.T) {
	dir := t.TempDir()
	if err := PaneExec([]string{filepath.Join(dir, "missing.json")}); err == nil || !strings.Contains(err.Error(), "read launch spec") {
		t.Errorf("missing spec: err = %v", err)
	}
	empty, err := writePaneLaunchSpec(dir, paneLaunchSpec{Env: []string{"A=1"}})
	if err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(empty); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("spec mode = %v, %v; want 0600", info.Mode().Perm(), err)
	}
	if err := PaneExec([]string{empty}); err == nil || !strings.Contains(err.Error(), "names no harness") {
		t.Errorf("empty argv: err = %v", err)
	}
	if _, err := os.Stat(empty); !os.IsNotExist(err) {
		t.Errorf("a spec the pane read was not removed: %v", err)
	}
	if err := PaneExec(nil); err == nil {
		t.Error("no spec argument was accepted")
	}
}

// A bare harness name resolves on the harness's own PATH, as execvp under
// env -i did, not on the pane's.
func TestPaneExecResolvesABareHarnessOnTheSpecsPath(t *testing.T) {
	dir := t.TempDir()
	harness := filepath.Join(dir, "fake-harness")
	if err := os.WriteFile(harness, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got, err := lookPathIn("fake-harness", "/nonexistent:"+dir); err != nil || got != harness {
		t.Errorf("lookPathIn = %q, %v; want %q", got, err, harness)
	}
	if _, err := lookPathIn("fake-harness", "/nonexistent"); err == nil {
		t.Error("a harness off the spec's PATH was found")
	}
	if got, _ := lookPathIn("/abs/path=x/harness", ""); got != "/abs/path=x/harness" {
		t.Errorf("a path with a slash was resolved to %q", got)
	}
	if got := envValue([]string{"PATH=/a", "OTHER=1", "PATH=/b"}, "PATH"); got != "/b" {
		t.Errorf("envValue = %q, want the last entry", got)
	}
}
