package config

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestTmuxServerFollowsSessionRuntime(t *testing.T) {
	for _, tc := range []struct{ value, want string }{
		{"", "lore-tui"},
		{"dev", "lore-tui-dev"},
		{"ci-42", "lore-tui-ci-42"},
		{"abcdefghijklmnopqrstuvwxyz012345", "lore-tui-abcdefghijklmnopqrstuvwxyz012345"},
	} {
		t.Setenv(SessionRuntimeEnv, tc.value)
		if got := TmuxServer(); got != tc.want {
			t.Errorf("%s=%q: TmuxServer() = %q, want %q", SessionRuntimeEnv, tc.value, got, tc.want)
		}
	}
}

func TestSessionHostsDirSeparatesRuntimes(t *testing.T) {
	sessions := filepath.Join(t.TempDir(), "_sessions")
	t.Setenv(SessionRuntimeEnv, "")
	if got, want := SessionHostsDir(sessions), filepath.Join(sessions, "hosts"); got != want {
		t.Fatalf("production hosts dir = %q, want %q", got, want)
	}
	t.Setenv(SessionRuntimeEnv, "dev")
	if got, want := SessionHostsDir(sessions), filepath.Join(sessions, "runtimes", "dev", "hosts"); got != want {
		t.Fatalf("namespaced hosts dir = %q, want %q", got, want)
	}
}

// sessionScripts is the repository's scripts directory, two levels above this package.
func sessionScripts(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	scripts := filepath.Join(wd, "..", "..", "..", "scripts")
	if _, err := os.Stat(filepath.Join(scripts, "session_runtime.py")); err != nil {
		t.Fatalf("scripts directory not found at %s: %v", scripts, err)
	}
	return scripts
}

func TestLoginDirMatchesTheSupervisorsLoginDir(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 is not installed")
	}
	scripts := sessionScripts(t)
	home := t.TempDir()
	data := filepath.Join(t.TempDir(), "data")
	for _, tc := range []struct{ name, data, runtime, want string }{
		{"default", "", "", filepath.Join(home, ".lore", "session-runtime")},
		{"named runtime", "", "dev", filepath.Join(home, ".lore", "session-runtimes", "dev")},
		{"data dir", data, "", filepath.Join(data, "session-runtime")},
		{"data dir and runtime", data, "ci-7", filepath.Join(data, "session-runtimes", "ci-7")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("HOME", home)
			t.Setenv("LORE_DATA_DIR", tc.data)
			t.Setenv(SessionRuntimeEnv, tc.runtime)
			if got := LoginDir(); got != tc.want {
				t.Fatalf("LoginDir() = %q, want %q", got, tc.want)
			}
			out, err := exec.Command("python3", "-I", "-c",
				"import sys; sys.path.insert(0, sys.argv[1]); import session_runtime; print(session_runtime.login_dir())",
				scripts).CombinedOutput()
			if err != nil {
				t.Fatalf("python login_dir: %v: %s", err, out)
			}
			if python := strings.TrimSpace(string(out)); python != LoginDir() {
				t.Fatalf("LoginDir() = %q, but the supervisor's login_dir() = %q", LoginDir(), python)
			}
		})
	}
}

func TestSupervisorTmuxTmpdirReadsTheRecord(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("LORE_DATA_DIR", "")
	t.Setenv(SessionRuntimeEnv, "")
	login := LoginDir()
	write := func(t *testing.T, body string) {
		t.Helper()
		if err := os.MkdirAll(login, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(login, "supervisor.json"), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if dir, recorded := SupervisorTmuxTmpdir(); recorded || dir != "" {
		t.Fatalf("no record: got (%q, %v), want (\"\", false)", dir, recorded)
	}
	for _, tc := range []struct {
		name, body string
		dir        string
		recorded   bool
	}{
		{"recorded directory", `{"schema_version": 1, "pid": 1, "tmux_tmpdir": "/tmp/lore-sup"}`, "/tmp/lore-sup", true},
		{"recorded as unset", `{"schema_version": 1, "pid": 1, "tmux_tmpdir": null}`, "", true},
		{"recorded as empty", `{"tmux_tmpdir": ""}`, "", true},
		{"older record without the field", `{"schema_version": 1, "pid": 1}`, "", false},
		{"damaged record", `{"tmux_tmpdir": "/tmp/x"`, "", false},
		{"not an object", `["/tmp/x"]`, "", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			write(t, tc.body)
			if dir, recorded := SupervisorTmuxTmpdir(); dir != tc.dir || recorded != tc.recorded {
				t.Fatalf("SupervisorTmuxTmpdir() = (%q, %v), want (%q, %v)", dir, recorded, tc.dir, tc.recorded)
			}
		})
	}
}

// What a lore-tui does with the record must be what `lore session attach` does.
func TestSupervisorTmuxTmpdirAgreesWithSessionAttach(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 is not installed")
	}
	scripts := sessionScripts(t)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("LORE_DATA_DIR", "")
	t.Setenv(SessionRuntimeEnv, "")
	login := LoginDir()
	if err := os.MkdirAll(login, 0o755); err != nil {
		t.Fatal(err)
	}
	probe := `import importlib.util, sys
spec = importlib.util.spec_from_file_location("session_managed", sys.argv[1] + "/session-managed.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.attach_environment().get("TMUX_TMPDIR", "<unset>"))`
	for _, body := range []string{`{"tmux_tmpdir": "/tmp/lore-sup"}`, `{"tmux_tmpdir": null}`, `{"tmux_tmpdir": ""}`, `{"pid": 1}`, `{"tmux_tmpdir"`} {
		t.Run(body, func(t *testing.T) {
			if err := os.WriteFile(filepath.Join(login, "supervisor.json"), []byte(body), 0o644); err != nil {
				t.Fatal(err)
			}
			t.Setenv("TMUX_TMPDIR", "/tmp/caller-own")
			out, err := exec.Command("python3", "-I", "-c", probe, scripts).CombinedOutput()
			if err != nil {
				t.Fatalf("python attach_environment: %v: %s", err, out)
			}
			want := "/tmp/caller-own"
			if dir, recorded := SupervisorTmuxTmpdir(); recorded {
				want = dir
				if dir == "" {
					want = "<unset>"
				}
			}
			if python := strings.TrimSpace(string(out)); python != want {
				t.Fatalf("Go reading gives TMUX_TMPDIR %q, lore session attach uses %q", want, python)
			}
		})
	}
}

func TestSessionRuntimeRejectsInvalidNames(t *testing.T) {
	for _, value := range []string{"Dev", "dev_1", "../x", "a/b", "dev ", "abcdefghijklmnopqrstuvwxyz0123456"} {
		t.Setenv(SessionRuntimeEnv, value)
		if _, err := SessionRuntime(); err == nil {
			t.Errorf("%s=%q was accepted", SessionRuntimeEnv, value)
		}
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("TmuxServer() with %s=%q did not refuse", SessionRuntimeEnv, value)
				}
			}()
			_ = TmuxServer()
		}()
	}
}
