package main

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/anticorrelator/lore/tui/internal/config"
)

const mainRuntimeProbeEnv = "LORE_TUI_TEST_MAIN_RUNTIME"

func TestMain(m *testing.M) {
	if value, ok := os.LookupEnv(mainRuntimeProbeEnv); ok {
		os.Setenv(config.SessionRuntimeEnv, value)
		main()
		os.Exit(0)
	}
	os.Setenv(config.SessionRuntimeEnv, "gotest-"+strconv.Itoa(os.Getpid()))
	code := m.Run()
	_ = exec.Command("tmux", "-L", config.TmuxServer(), "kill-server").Run()
	socketDir := os.Getenv("TMUX_TMPDIR")
	if socketDir == "" {
		socketDir = "/tmp"
	}
	_ = os.Remove(filepath.Join(socketDir, "tmux-"+strconv.Itoa(os.Getuid()), config.TmuxServer()))
	os.Exit(code)
}

func TestPackageTestsRunInTheirOwnRuntime(t *testing.T) {
	if got := config.TmuxServer(); got == "lore-tui" || !strings.HasPrefix(got, "lore-tui-gotest-") {
		t.Fatalf("package tests would share tmux server %q", got)
	}
}

func TestHostDirFollowsSessionRuntime(t *testing.T) {
	sessions := filepath.Join(t.TempDir(), "_sessions")
	m := model{sessionsDir: sessions, hostKey: "abc"}
	t.Setenv(config.SessionRuntimeEnv, "")
	if got, want := m.hostDir(), filepath.Join(sessions, "hosts", "abc"); got != want {
		t.Fatalf("production host dir = %q, want %q", got, want)
	}
	t.Setenv(config.SessionRuntimeEnv, "dev")
	if got, want := m.hostDir(), filepath.Join(sessions, "runtimes", "dev", "hosts", "abc"); got != want {
		t.Fatalf("namespaced host dir = %q, want %q", got, want)
	}
	if got := m.hostDeliveryPath("op"); got != filepath.Join(sessions, "runtimes", "dev", "hosts", "abc", "deliveries", "op.json") {
		t.Fatalf("delivery ledger outside the runtime's host dir: %q", got)
	}
	if got := m.hostAllocationPath("op"); got != filepath.Join(sessions, "runtimes", "dev", "hosts", "abc", "allocations", "op.json") {
		t.Fatalf("allocation checkpoint outside the runtime's host dir: %q", got)
	}
}

func TestBinaryRefusesInvalidSessionRuntimeBeforeStarting(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "--session-host")
	cmd.Env = append(os.Environ(), mainRuntimeProbeEnv+"=Not_Valid")
	out, err := cmd.CombinedOutput()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 2 {
		t.Fatalf("invalid runtime name was not refused with exit 2: %v\n%s", err, out)
	}
	if !strings.Contains(string(out), config.SessionRuntimeEnv) || strings.Contains(string(out), "invalid session host arguments") {
		t.Fatalf("refusal did not come from the runtime check:\n%s", out)
	}
}

func TestSessionHostRequiresRuntimeFlagToMatchSetting(t *testing.T) {
	dir := t.TempDir()
	ready := filepath.Join(dir, "hosts", "k", "ready.json")
	args := func(extra ...string) []string {
		return append([]string{"--scope", "store", "--host-key", "k", "--kdir", dir, "--ready-file", ready}, extra...)
	}
	for _, tc := range []struct {
		setting string
		extra   []string
	}{
		{"dev", nil},
		{"dev", []string{"--runtime", "other"}},
		{"", []string{"--runtime", "dev"}},
	} {
		t.Setenv(config.SessionRuntimeEnv, tc.setting)
		if code := sessionHostMain(args(tc.extra...)); code != 2 {
			t.Errorf("setting %q with %v: exit %d, want 2", tc.setting, tc.extra, code)
		}
	}
	if _, err := os.Stat(filepath.Dir(ready)); !os.IsNotExist(err) {
		t.Fatalf("refused host created its state directory: %v", err)
	}
}
