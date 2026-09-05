package work

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/anticorrelator/lore/tui/internal/config"
)

// LaunchAdmissionError means unchanged local dependencies or intent cannot
// succeed on an identical retry. The wrapped diagnostic is retained in full.
type LaunchAdmissionError struct{ Err error }

func (e *LaunchAdmissionError) Error() string { return e.Err.Error() }
func (e *LaunchAdmissionError) Unwrap() error { return e.Err }
func (e *LaunchAdmissionError) Retryable() bool {
	for _, cause := range []error{syscall.EAGAIN, syscall.ENOMEM, syscall.EMFILE, syscall.ENFILE, syscall.ENOSPC, syscall.ETIMEDOUT, context.DeadlineExceeded} {
		if errors.Is(e.Err, cause) {
			return true
		}
	}
	return false
}
func IsLaunchAdmissionError(err error) bool {
	var admission *LaunchAdmissionError
	return (errors.As(err, &admission) && !admission.Retryable()) || errors.Is(err, os.ErrPermission) || errors.Is(err, exec.ErrNotFound)
}

// positionPython tests imports with the inherited environment, rather than
// assuming the first python3 on PATH has the compiler's dependencies installed.
func positionPython(repo string) (string, error) {
	candidates := []string{os.Getenv("LORE_PYTHON"), filepath.Join(repo, ".venv", "bin", "python3")}
	for _, dir := range filepath.SplitList(os.Getenv("PATH")) {
		candidates = append(candidates, filepath.Join(dir, "python3"))
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	seen := map[string]bool{}
	var failures []string
	var transient error
	for _, candidate := range candidates {
		if candidate == "" || seen[candidate] {
			continue
		}
		seen[candidate] = true
		if _, err := os.Stat(candidate); err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", candidate, err))
			if (&LaunchAdmissionError{err}).Retryable() {
				transient = err
			}
			continue
		}
		cmd := exec.CommandContext(ctx, candidate, "-c", "import sys; sys.path.insert(0, sys.argv[1]); import yaml, position_compile, packet_builder", filepath.Join(repo, "scripts"))
		cmd.WaitDelay = time.Second
		output, err := cmd.CombinedOutput()
		if ctx.Err() != nil {
			transient = ctx.Err()
		}
		if err != nil && (&LaunchAdmissionError{err}).Retryable() {
			transient = err
		}
		if err == nil {
			return candidate, nil
		}
		failures = append(failures, fmt.Sprintf("%s: %v: %s", candidate, err, output))
	}
	if transient != nil {
		return "", &LaunchAdmissionError{fmt.Errorf("position Python probe temporarily unavailable: %w; probes: %s", transient, strings.Join(failures, "\n"))}
	}
	return "", &LaunchAdmissionError{fmt.Errorf("position Python dependencies (PyYAML/position_compile/packet_builder) unavailable; set LORE_PYTHON to a compatible interpreter; probes: %s", strings.Join(failures, "\n"))}
}

// probeWritableState performs the filesystem operations startup requires under
// this host's inherited permissions. Mode bits cannot establish sandbox access.
func probeWritableState(dir string) error {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	probe, err := os.MkdirTemp(dir, ".lore-launch-probe-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(probe)
	path := filepath.Join(probe, "state")
	if err := os.WriteFile(path, []byte("launch preflight\n"), 0600); err != nil {
		return err
	}
	if _, err := os.ReadFile(path); err != nil {
		return err
	}
	return os.Rename(path, filepath.Join(probe, "renamed"))
}

func preflightHarness(framework, binary string) error {
	if _, err := exec.LookPath(binary); err != nil {
		return &LaunchAdmissionError{fmt.Errorf("harness executable %s: %w", binary, err)}
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return &LaunchAdmissionError{err}
	}
	var state string
	switch framework {
	case "codex":
		state = os.Getenv("CODEX_HOME")
		if state == "" {
			state = filepath.Join(home, ".codex")
		}
	case "claude-code":
		state = os.Getenv("CLAUDE_CONFIG_DIR")
		if state == "" {
			state = filepath.Join(home, ".claude")
		}
	case "opencode":
		state = os.Getenv("XDG_DATA_HOME")
		if state == "" {
			state = filepath.Join(home, ".local", "share")
		}
		state = filepath.Join(state, "opencode")
	default:
		return &LaunchAdmissionError{fmt.Errorf("unsupported launch framework %q", framework)}
	}
	dirs := []string{state}
	if framework == "codex" {
		dirs = append(dirs, filepath.Join(state, "sessions"))
	}
	if framework == "claude-code" {
		dirs = append(dirs, filepath.Join(state, "projects"))
	}
	for _, dir := range dirs {
		if err := probeWritableState(dir); err != nil {
			return &LaunchAdmissionError{fmt.Errorf("harness %s state access at %s: %w", framework, dir, err)}
		}
	}
	return nil
}

// PreflightWorker checks executable and state access in the claiming process,
// before queue ownership is acquired. StartTerminalCmd checks again at launch.
func PreflightWorker(framework string, position bool) error {
	if framework == "" {
		var err error
		framework, err = config.ResolveTUILaunchFramework()
		if err != nil {
			return &LaunchAdmissionError{err}
		}
	}
	binary, err := config.HarnessBinary(framework)
	if err != nil {
		return &LaunchAdmissionError{err}
	}
	if err := preflightHarness(framework, binary); err != nil {
		return err
	}
	if position {
		repo, err := config.LoreRepoDir()
		if err != nil {
			return &LaunchAdmissionError{err}
		}
		if _, err := positionPython(repo); err != nil {
			return err
		}
	}
	return nil
}
