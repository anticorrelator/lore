package work

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// PaneExecFlag makes lore-tui the first process of a tmux pane:
// `lore-tui --pane-exec <spec>` reads the launch spec at <spec> and execs the
// harness it names. The tmux command that starts a pane therefore stays a few
// hundred bytes whatever the harness argv and environment hold; tmux refuses a
// client command of more than about 16 KB, and a position-bearing harness argv
// alone is larger than that.
const PaneExecFlag = "--pane-exec"

// paneLaunchSpec is the exact environment and argv a pane's harness starts
// with. Env holds no variable tmux owns in the pane (see tmuxOwnedPaneVars);
// PaneExec takes those from the pane itself.
type paneLaunchSpec struct {
	Env  []string `json:"env"`
	Argv []string `json:"argv"`
}

// newPaneLaunchSpec is the spec of a pane that runs harnessBin with
// harnessArgs under the launcher's environment plus env (see tmuxPaneEnv).
func newPaneLaunchSpec(env []string, harnessBin string, harnessArgs []string) paneLaunchSpec {
	return paneLaunchSpec{Env: tmuxPaneEnv(env), Argv: append([]string{harnessBin}, harnessArgs...)}
}

// paneExecutable is the program a new pane starts as: this binary, run with
// PaneExecFlag.
var paneExecutable = os.Executable

// paneSpecConsumedTimeout bounds how long a launch waits for the pane to read
// its spec before it treats the pane as never started.
const paneSpecConsumedTimeout = 10 * time.Second

// paneSpecStaleAfter is the age past which no launch can still be waiting for
// a spec, so a host may remove it.
const paneSpecStaleAfter = paneSpecConsumedTimeout + time.Minute

// paneLaunchDir is where a host writes its panes' launch specs:
// <temp dir>/lore-pane-launch/<host key>. A spec holds the session's whole
// environment, credentials included, so it lives outside the knowledge store,
// which is a git repository. A launcher with no host key uses "unkeyed", which
// no 24-hex host key can be.
func paneLaunchDir(hostKey string) string {
	if hostKey == "" {
		hostKey = "unkeyed"
	}
	return filepath.Join(os.TempDir(), "lore-pane-launch", hostKey)
}

// privateDir makes path a directory only this user can enter: it creates it
// with mode 0700, or checks that an existing one is a real directory (not a
// symlink) owned by this user and narrows its mode to 0700.
func privateDir(path string) error {
	if err := os.Mkdir(path, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("%s is not a directory", path)
	}
	if st, ok := info.Sys().(*syscall.Stat_t); !ok || int(st.Uid) != os.Getuid() {
		return fmt.Errorf("%s is not owned by this user", path)
	}
	if info.Mode().Perm() != 0o700 {
		return os.Chmod(path, 0o700)
	}
	return nil
}

// writePaneLaunchSpec writes spec to a new file in dir, readable only by this
// user, and returns its path. dir and its parent are made private directories
// first.
func writePaneLaunchSpec(dir string, spec paneLaunchSpec) (string, error) {
	b, err := json.Marshal(spec)
	if err != nil {
		return "", err
	}
	for _, d := range []string{filepath.Dir(dir), dir} {
		if err := privateDir(d); err != nil {
			return "", fmt.Errorf("pane launch spec directory: %w", err)
		}
	}
	f, err := os.CreateTemp(dir, "pane-*.json")
	if err != nil {
		return "", fmt.Errorf("pane launch spec: %w", err)
	}
	_, err = f.Write(b)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		_ = os.Remove(f.Name())
		return "", fmt.Errorf("pane launch spec: %w", err)
	}
	return f.Name(), nil
}

// SweepStalePaneLaunchSpecs removes the launch specs in the host's launch
// directory that no launch can still be waiting for (older than
// paneSpecStaleAfter at now). A host that dies between writing a spec and its
// pane reading it leaves one behind; the next host for its key runs this at
// start. A missing directory is nothing to sweep, and one that is not this
// user's directory is left alone and reported.
func SweepStalePaneLaunchSpecs(hostKey string, now time.Time) error {
	dir := paneLaunchDir(hostKey)
	info, err := os.Lstat(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if st, ok := info.Sys().(*syscall.Stat_t); !info.IsDir() || !ok || int(st.Uid) != os.Getuid() {
		return fmt.Errorf("%s is not this user's launch directory", dir)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	var errs []error
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasPrefix(name, "pane-") || !strings.HasSuffix(name, ".json") {
			continue
		}
		info, err := entry.Info()
		if err != nil || !info.Mode().IsRegular() || now.Sub(info.ModTime()) <= paneSpecStaleAfter {
			continue
		}
		if err := os.Remove(filepath.Join(dir, name)); err != nil && !errors.Is(err, os.ErrNotExist) {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

// waitPaneSpecConsumed reports whether the pane removed its spec, which it does
// once it has read it, before timeout elapses.
func waitPaneSpecConsumed(path string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for {
		if _, err := os.Lstat(path); errors.Is(err, os.ErrNotExist) {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// PaneExec replaces this process with the harness the launch spec in args
// names, and returns only when it cannot. The spec is removed once read. The
// harness gets exactly the spec's environment plus the values tmux gave this
// pane for its own variables: tmux starts a pane with the environment of
// whichever client started the shared server, and -e can add to that but never
// remove from it. Exec keeps this process's pid, so the pane pid tmux reports is
// the harness, and the harness path is never parsed, so any path is safe.
func PaneExec(args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: lore-tui %s <launch spec>", PaneExecFlag)
	}
	b, err := os.ReadFile(args[0])
	_ = os.Remove(args[0])
	if err != nil {
		return fmt.Errorf("read launch spec: %w", err)
	}
	var spec paneLaunchSpec
	if err := json.Unmarshal(b, &spec); err != nil {
		return fmt.Errorf("read launch spec %s: %w", args[0], err)
	}
	if len(spec.Argv) == 0 || spec.Argv[0] == "" {
		return fmt.Errorf("launch spec %s names no harness", args[0])
	}
	env := make([]string, 0, len(tmuxOwnedPaneVars)+len(spec.Env))
	for _, name := range tmuxOwnedPaneVars {
		if value, ok := os.LookupEnv(name); ok {
			env = append(env, name+"="+value)
		}
	}
	env = append(env, spec.Env...)
	path, err := lookPathIn(spec.Argv[0], envValue(spec.Env, "PATH"))
	if err != nil {
		return err
	}
	return fmt.Errorf("exec %s: %w", path, syscall.Exec(path, spec.Argv, env))
}

// lookPathIn resolves name the way execvp does under the harness's own PATH: a
// name with a slash is used as given, and an unset PATH searches /usr/bin:/bin.
func lookPathIn(name, path string) (string, error) {
	if strings.Contains(name, "/") {
		return name, nil
	}
	if path == "" {
		path = "/usr/bin:/bin"
	}
	for _, dir := range filepath.SplitList(path) {
		if dir == "" {
			dir = "."
		}
		candidate := filepath.Join(dir, name)
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("exec %s: not found in PATH %s", name, path)
}

// envValue is the value of key in a KEY=VAL list, the last entry winning.
func envValue(env []string, key string) string {
	value := ""
	for _, kv := range env {
		if k, v, ok := strings.Cut(kv, "="); ok && k == key {
			value = v
		}
	}
	return value
}
