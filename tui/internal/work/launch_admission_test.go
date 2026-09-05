package work

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestLaunchPreflightUsesCustomHomeAndActualAccess(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CODEX_HOME", filepath.Join(root, "custom"))
	if err := preflightHarness("codex", "/bin/sh"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "custom", "sessions")); err != nil {
		t.Fatal(err)
	}
	// A kernel-owned read-only filesystem refuses real creation even for root.
	t.Setenv("CODEX_HOME", "/dev/null/sessions")
	err := preflightHarness("codex", "/bin/sh")
	if !IsLaunchAdmissionError(err) || !strings.Contains(err.Error(), "/dev/null/sessions") {
		t.Fatalf("missing full refusal: %v", err)
	}
	if IsLaunchAdmissionError(errors.New("temporary PTY allocation exhaustion")) {
		t.Fatal("transient error classified deterministic")
	}
}

func TestPositionPythonProvesImportsAndRetainsDiagnostics(t *testing.T) {
	root := t.TempDir()
	first, second := filepath.Join(root, "bad"), filepath.Join(root, "good")
	for _, dir := range []string{first, second} {
		if err := os.MkdirAll(dir, 0755); err != nil {
			t.Fatal(err)
		}
	}
	bad := "#!/bin/sh\necho 'ModuleNotFoundError: No module named yaml; nested cause remains' >&2\nexit 1\n"
	good := "#!/bin/sh\ncase \"$2\" in *'import yaml, position_compile, packet_builder'*) exit 0;; *) exit 7;; esac\n"
	if err := os.WriteFile(filepath.Join(first, "python3"), []byte(bad), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(second, "python3"), []byte(good), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LORE_PYTHON", "")
	t.Setenv("PATH", first+string(os.PathListSeparator)+second)
	got, err := positionPython(root)
	if err != nil || got != filepath.Join(second, "python3") {
		t.Fatalf("selection=%s err=%v", got, err)
	}
	t.Setenv("PATH", first)
	_, err = positionPython(root)
	if !IsLaunchAdmissionError(err) || !strings.Contains(err.Error(), filepath.Join(first, "python3")) || !strings.Contains(err.Error(), "nested cause remains") {
		t.Fatalf("diagnostics lost: %v", err)
	}
}

func TestLaunchStatePermissionDenialAndTransientResource(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("permission denial fixture requires unprivileged process")
	}
	root := t.TempDir()
	state := filepath.Join(root, "sessions")
	if err := os.Mkdir(state, 0500); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(state, 0700)
	t.Setenv("CODEX_HOME", root)
	err := preflightHarness("codex", "/bin/sh")
	if !errors.Is(err, os.ErrPermission) || !IsLaunchAdmissionError(err) || !strings.Contains(err.Error(), state) {
		t.Fatalf("actual access refusal missing: %v", err)
	}
	temporary := &LaunchAdmissionError{fmt.Errorf("open state: %w", syscall.EMFILE)}
	if !temporary.Retryable() || IsLaunchAdmissionError(temporary) {
		t.Fatal("transient resource exhaustion marked deterministic")
	}
}

func TestPositionPythonFallsBackToActuallyImportableInterpreter(t *testing.T) {
	python, err := exec.LookPath("python3")
	if err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command(python, "-c", "import yaml").CombinedOutput(); err != nil {
		t.Fatalf("fixture requires available PyYAML interpreter: %v %s", err, out)
	}
	root := t.TempDir()
	for _, dir := range []string{"bad", "good", "scripts"} {
		if err := os.Mkdir(filepath.Join(root, dir), 0755); err != nil {
			t.Fatal(err)
		}
	}
	// -S demonstrably excludes installed site packages from the first interpreter.
	bad := "#!/bin/sh\nexec '" + strings.ReplaceAll(python, "'", "'\"'\"'") + "' -S \"$@\"\n"
	if err := os.WriteFile(filepath.Join(root, "bad", "python3"), []byte(bad), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(python, filepath.Join(root, "good", "python3")); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"position_compile.py", "packet_builder.py"} {
		if err := os.WriteFile(filepath.Join(root, "scripts", name), []byte("import yaml\n"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("LORE_PYTHON", "")
	t.Setenv("PATH", filepath.Join(root, "bad")+string(os.PathListSeparator)+filepath.Join(root, "good"))
	got, err := positionPython(root)
	if err != nil || got != filepath.Join(root, "good", "python3") {
		t.Fatalf("actual interpreter fallback=%s: %v", got, err)
	}
}
