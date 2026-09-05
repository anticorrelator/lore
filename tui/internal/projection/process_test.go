package projection

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestLeaseChild(t *testing.T) {
	dir := os.Getenv("LORE_TEST_LEASE_DIR")
	if dir == "" {
		return
	}
	lease, err := acquire(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close()
	fmt.Println("ready")
	_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
}

func TestHostCapAcrossProcessesAndCrashReleasesLease(t *testing.T) {
	dir := t.TempDir()
	children := make([]*exec.Cmd, 0, HostLimit)
	for i := 0; i < HostLimit; i++ {
		cmd := exec.Command(os.Args[0], "-test.run=^TestLeaseChild$")
		cmd.Env = append(os.Environ(), "LORE_TEST_LEASE_DIR="+dir)
		input, err := cmd.StdinPipe()
		if err != nil {
			t.Fatal(err)
		}
		defer input.Close()
		output, err := cmd.StdoutPipe()
		if err != nil {
			t.Fatal(err)
		}
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = cmd.Process.Kill(); _ = cmd.Wait() })
		if line, err := bufio.NewReader(output).ReadString('\n'); err != nil || line != "ready\n" {
			t.Fatalf("child not ready: %q %v", line, err)
		}
		children = append(children, cmd)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if lease, err := acquire(ctx, dir); lease != nil || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("host cap exceeded: %v %v", lease, err)
	}
	_ = children[0].Process.Kill()
	_ = children[0].Wait()
	ctx, cancel = context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	lease, err := acquire(ctx, dir)
	if err != nil {
		t.Fatalf("crashed reader kept its lease: %v", err)
	}
	lease.Close()
}

func TestOutputCancellationKillsDescendants(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	cmd := exec.CommandContext(ctx, "sh", "-c", "sleep 30 & wait")
	start := time.Now()
	if _, err := Output(ctx, cmd, true); err == nil {
		t.Fatal("cancelled command succeeded")
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("descendant retained output pipes: %v", elapsed)
	}
}

func TestOutputAndStartFailureReleaseCapacity(t *testing.T) {
	ctx := context.Background()
	for i := 0; i < HostLimit+1; i++ {
		if _, err := Output(ctx, exec.CommandContext(ctx, "/does-not-exist"), false); err == nil {
			t.Fatal("missing command succeeded")
		}
	}
	out, err := Output(ctx, exec.CommandContext(ctx, "sh", "-c", "printf value"), false)
	if err != nil || string(out) != "value" {
		t.Fatalf("output = %q, %v", out, err)
	}
}

func TestProjectionLauncherChild(t *testing.T) {
	ready := os.Getenv("LORE_TEST_PROJECTION_READY")
	if ready == "" {
		return
	}
	cmd := exec.CommandContext(context.Background(), "sh", "-c", `echo $$ > "$1"; sleep 30`, "sh", ready)
	_, _ = Output(context.Background(), cmd, false)
}

func TestProjectionKeepsLeaseAfterLauncherDies(t *testing.T) {
	dir := filepath.Join("/tmp", fmt.Sprintf("lore-projections-%d", os.Getuid()))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	lease, err := acquire(ctx, dir)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close()
	ready := filepath.Join(t.TempDir(), "ready")
	launcher := exec.Command(os.Args[0], "-test.run=^TestProjectionLauncherChild$")
	launcher.Env = append(os.Environ(), "LORE_TEST_PROJECTION_READY="+ready)
	if err := launcher.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = launcher.Process.Kill(); _ = launcher.Wait() })
	var pid int
	for pid == 0 {
		if raw, err := os.ReadFile(ready); err == nil {
			pid, _ = strconv.Atoi(strings.TrimSpace(string(raw)))
		}
		if ctx.Err() != nil {
			t.Fatal("projection did not start")
		}
		time.Sleep(10 * time.Millisecond)
	}
	defer syscall.Kill(-pid, syscall.SIGKILL)
	_ = launcher.Process.Kill()
	_ = launcher.Wait()
	blocked, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if extra, err := acquire(blocked, dir); extra != nil || !errors.Is(err, context.DeadlineExceeded) {
		if extra != nil {
			extra.Close()
		}
		t.Fatalf("orphaned projection released capacity early: %v", err)
	}
}
