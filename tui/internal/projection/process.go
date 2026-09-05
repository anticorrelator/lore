// Package projection bounds expensive read subprocesses across TUI instances.
package projection

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
)

// HostLimit is shared by board and work-evidence reads across project dirs.
// Two readers allow an interactive read alongside a background refresh.
const HostLimit = 2

// acquire waits within the caller's budget, before starting any subprocess.
// Kernel-held locks survive neither process exit nor a crash. Lock files stay
// in place: unlinking one would allow two processes to lock different inodes.
func acquire(ctx context.Context, dir string) (*os.File, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		for slot := 0; slot < HostLimit; slot++ {
			file, err := os.OpenFile(filepath.Join(dir, fmt.Sprintf("%d.lock", slot)), os.O_CREATE|os.O_RDWR, 0600)
			if err != nil {
				return nil, err
			}
			err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
			if err == nil {
				return file, nil
			}
			file.Close()
			if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EAGAIN) {
				return nil, err
			}
		}
		timer := time.NewTimer(50 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil, ctx.Err()
		case <-timer.C:
		}
	}
}

// Output includes lock wait in ctx's deadline and kills the process group on
// cancellation, so a shell's Python descendants cannot outlive the read.
func Output(ctx context.Context, cmd *exec.Cmd, combined bool) ([]byte, error) {
	// A fixed host-local location deliberately ignores project dirs and TMPDIR.
	// UID separates independent users without letting each TUI mint its own pool.
	dir := filepath.Join("/tmp", fmt.Sprintf("lore-projections-%d", os.Getuid()))
	lease, err := acquire(ctx, dir)
	if err != nil {
		return nil, fmt.Errorf("projection capacity: %w", err)
	}
	defer lease.Close()
	// Keep the lease in the child too: killing the TUI must not free capacity
	// while its already-running projection is still alive.
	cmd.ExtraFiles = append(cmd.ExtraFiles, lease)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		if errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}
		return err
	}
	cmd.WaitDelay = time.Second
	if combined {
		return cmd.CombinedOutput()
	}
	return cmd.Output()
}
