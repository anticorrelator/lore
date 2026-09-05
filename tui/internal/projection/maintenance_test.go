package projection

import (
	"context"
	"os/exec"
	"testing"
	"time"
)

func TestMaintenanceAdmissionBoundAndOldestRetry(t *testing.T) {
	root := t.TempDir()
	a, err := tryMaintenance(root, "a")
	if err != nil || a == nil {
		t.Fatalf("a: %v", err)
	}
	b, err := tryMaintenance(root, "b")
	if err != nil || b == nil {
		t.Fatalf("b: %v", err)
	}
	defer b.Close()
	for _, store := range []string{"c", "d", "e"} {
		lease, err := tryMaintenance(root, store)
		if err != nil || lease != nil {
			t.Fatalf("admitted above bound: %s %v", store, err)
		}
	}
	a.Close()
	if lease, err := tryMaintenance(root, "e"); err != nil || lease != nil {
		t.Fatal("newer store bypassed oldest waiting store")
	}
	for _, store := range []string{"c", "d", "e"} {
		lease, err := tryMaintenance(root, store)
		if err != nil || lease == nil {
			t.Fatalf("waiting store starved: %s %v", store, err)
		}
		lease.Close()
	}
}

func TestSnapshotProcessCancellationWithoutCapacity(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	cmd := exec.CommandContext(ctx, "sh", "-c", "sleep 30 & wait")
	start := time.Now()
	if _, err := SnapshotOutput(ctx, cmd, true); err == nil {
		t.Fatal("cancelled snapshot process succeeded")
	}
	if time.Since(start) > time.Second {
		t.Fatal("snapshot descendant survived cancellation")
	}
}

func TestMaintenanceAgedLiveTicketKeepsPriorityAndAbandonedExpires(t *testing.T) {
	root := t.TempDir()
	now := time.Unix(1000, 0)
	a, _ := tryMaintenanceAt(root, "a", now)
	defer a.Close()
	b, _ := tryMaintenanceAt(root, "b", now)
	defer b.Close()
	_, _ = tryMaintenanceAt(root, "live", now)
	_, _ = tryMaintenanceAt(root, "abandoned", now.Add(10*time.Second))
	_, _ = tryMaintenanceAt(root, "live", now.Add(25*time.Second))
	_, _ = tryMaintenanceAt(root, "new", now.Add(31*time.Second))
	a.Close()
	if lease, err := tryMaintenanceAt(root, "new", now.Add(31*time.Second)); err != nil || lease != nil {
		t.Fatal("aged live ticket lost its original priority")
	}
	live, err := tryMaintenanceAt(root, "live", now.Add(31*time.Second))
	if err != nil || live == nil {
		t.Fatalf("aged live ticket did not receive admission: %v", err)
	}
	live.Close()
	next, err := tryMaintenanceAt(root, "new", now.Add(41*time.Second))
	if err != nil || next == nil {
		t.Fatalf("abandoned ticket blocked admission: %v", err)
	}
	next.Close()
}
