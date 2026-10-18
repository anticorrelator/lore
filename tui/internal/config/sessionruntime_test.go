package config

import (
	"path/filepath"
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
