package board

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func snapshotFixture(t *testing.T) (string, string) {
	t.Helper()
	root, err := filepath.Abs("../../../..")
	if err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	count := filepath.Join(bin, "launches")
	command := "#!/bin/sh\necho launch >> \"$LORE_TEST_LAUNCHES\"\nexec \"$LORE_TEST_SOURCE/cli/lore\" \"$@\"\n"
	if err := os.WriteFile(filepath.Join(bin, "lore"), []byte(command), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("LORE_TEST_LAUNCHES", count)
	t.Setenv("LORE_TEST_SOURCE", root)
	data := t.TempDir()
	_ = os.MkdirAll(filepath.Join(data, "config"), 0755)
	_ = os.WriteFile(filepath.Join(data, "config/settings.json"), []byte(`{"version":1,"coordination":{"max_concurrency":2}}`), 0644)
	t.Setenv("LORE_DATA_DIR", data)
	return root, count
}

func makeSnapshotStore(t *testing.T, name string) string {
	t.Helper()
	store := t.TempDir()
	arc := filepath.Join(store, "_work", "_arcs", name)
	if err := os.MkdirAll(arc, 0755); err != nil {
		t.Fatal(err)
	}
	_ = os.WriteFile(filepath.Join(arc, "_meta.json"), []byte(fmt.Sprintf(`{"status":"active","title":%q,"members":["x"]}`, name)), 0644)
	_ = os.WriteFile(filepath.Join(arc, "coordination.md"), []byte("| Stream | Step | Depends on | Tree | Status | Verdict |\n|---|---|---|---|---|---|\n| 1 | ready | — | writer | pending | — |\n"), 0644)
	return store
}

func launches(path string) int {
	data, _ := os.ReadFile(path)
	return strings.Count(string(data), "launch\n")
}

func burst(store, arc string, count int) ([]Snapshot, []error) {
	snapshots := make([]Snapshot, count)
	errs := make([]error, count)
	var wg sync.WaitGroup
	for i := range count {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			snapshots[i], errs[i] = LoadSnapshot(ctx, store, arc)
		}()
	}
	wg.Wait()
	return snapshots, errs
}

func TestSnapshotManyReadersDirectWarmPath(t *testing.T) {
	_, counter := snapshotFixture(t)
	for _, count := range []int{1, 5, 20} {
		store := makeSnapshotStore(t, "a")
		before := launches(counter)
		var usageBefore, usageAfter syscall.Rusage
		_ = syscall.Getrusage(syscall.RUSAGE_CHILDREN, &usageBefore)
		start := time.Now()
		burst(store, "a", count)
		cold := time.Since(start)
		snapshot, err := LoadSnapshot(context.Background(), store, "a")
		if err != nil || !snapshot.Found {
			t.Fatalf("cold: %+v %v", snapshot, err)
		}
		if got := launches(counter) - before; got != 1 {
			t.Fatalf("%d cold consumers launched %d updaters", count, got)
		}
		_ = syscall.Getrusage(syscall.RUSAGE_CHILDREN, &usageAfter)
		cpu := time.Duration(usageAfter.Utime.Nano() - usageBefore.Utime.Nano() + usageAfter.Stime.Nano() - usageBefore.Stime.Nano())
		start = time.Now()
		for range 5 {
			snaps, errs := burst(store, "a", count)
			for i, err := range errs {
				if err != nil || snaps[i].Generation != snapshot.Generation {
					t.Fatalf("warm consumer %d: %v", i, err)
				}
			}
		}
		warm := time.Since(start)
		if launches(counter) != before+1 {
			t.Fatal("unchanged direct reads launched a subprocess")
		}
		t.Logf("consumers=%d cold_launches=1 cold_wall=%s child_cpu=%s source_opens=%d source_bytes=%d warm_reads=%d warm_launches=0 warm_wall=%s", count, cold, cpu, snapshot.WorkCounts["source_opens"], snapshot.WorkCounts["source_bytes"], count*5, warm)
	}
}

func TestSnapshotMixedStoresAliasesAndBusyOwner(t *testing.T) {
	_, counter := snapshotFixture(t)
	stores := []string{makeSnapshotStore(t, "a"), makeSnapshotStore(t, "b"), makeSnapshotStore(t, "c")}
	alias := filepath.Join(t.TempDir(), "alias")
	if err := os.Symlink(stores[0], alias); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for i := range 30 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			store, arc := stores[0], "a"
			if i < 5 {
				store, arc = stores[1], "b"
			} else if i < 10 {
				store, arc = stores[2], "c"
			} else if i%2 == 0 {
				store = alias
			}
			_, _ = LoadSnapshot(context.Background(), store, arc)
		}()
	}
	wg.Wait()
	deadline := time.Now().Add(10 * time.Second)
	for i, store := range stores {
		for {
			snapshot, err := LoadSnapshot(context.Background(), store, string(rune('a'+i)))
			if err == nil && snapshot.Found {
				if len(snapshot.Arcs) != 1 || snapshot.Arcs[0].Slug != string(rune('a'+i)) {
					t.Fatalf("cross-store reuse: %+v", snapshot.Arcs)
				}
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("store %d starved: %v", i, err)
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
	if launches(counter) != 3 {
		t.Fatalf("mixed topology launched %d, want 3", launches(counter))
	}
	snapPath := filepath.Join(stores[0], "_coordination", "display.json")
	data, _ := os.ReadFile(snapPath)
	var raw map[string]any
	_ = json.Unmarshal(data, &raw)
	raw["next_update"] = 0
	data, _ = json.Marshal(raw)
	_ = os.WriteFile(snapPath, data, 0644)
	lease, err := os.OpenFile(filepath.Join(stores[0], "_coordination", "display.lock"), os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close()
	if err = syscall.Flock(int(lease.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	snapshots, errs := burst(alias, "a", 20)
	for i, err := range errs {
		if err != nil || !snapshots[i].Found {
			t.Fatalf("busy old snapshot: %v", err)
		}
	}
	b, err := LoadSnapshot(context.Background(), stores[1], "b")
	if err != nil || !b.Found {
		t.Fatalf("B blocked by A: %v", err)
	}
	if time.Since(start) > time.Second {
		t.Fatal("cached reads waited behind busy A")
	}
	if launches(counter) != 3 {
		t.Fatal("busy readers launched maintenance")
	}
}

func TestSnapshotCachedReadsBypassBothHostPools(t *testing.T) {
	_, counter := snapshotFixture(t)
	store := makeSnapshotStore(t, "a")
	if _, err := LoadSnapshot(context.Background(), store, "a"); err != nil {
		t.Fatal(err)
	}
	var held []*os.File
	for _, prefix := range []string{"lore-projections-", "lore-coordination-updaters-"} {
		root := filepath.Join("/tmp", fmt.Sprintf("%s%d", prefix, os.Getuid()))
		_ = os.MkdirAll(root, 0700)
		for slot := range 2 {
			file, err := os.OpenFile(filepath.Join(root, fmt.Sprintf("%d.lock", slot)), os.O_CREATE|os.O_RDWR, 0600)
			if err != nil {
				t.Fatal(err)
			}
			if err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
				file.Close()
				t.Log("host slot already occupied; cached readers must remain independent")
				continue
			}
			held = append(held, file)
			t.Cleanup(func() { file.Close() })
		}
	}
	start := time.Now()
	_, errs := burst(store, "a", 20)
	for _, err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if time.Since(start) > time.Second || launches(counter) != 1 {
		t.Fatal("cached reads entered a host pool")
	}
}

func TestSnapshotMalformedEventDoesNotPoisonOtherArcs(t *testing.T) {
	snapshotFixture(t)
	store := makeSnapshotStore(t, "a")
	sessions := filepath.Join(store, "_sessions")
	_ = os.MkdirAll(sessions, 0755)
	_ = os.WriteFile(filepath.Join(sessions, "events.jsonl"), []byte("{\"event\":\"closed\",\"slug\":\"x\",\"ts\":123}\n{\"event\":\"closed\",\"slug\":\"x\"}\n"), 0644)
	snapshot, err := LoadSnapshot(context.Background(), store, "a")
	if err != nil || !snapshot.Found || snapshot.Coverage.State != "degraded" || len(snapshot.Details["a"].Events) != 1 {
		t.Fatalf("typed row poisoned snapshot: %+v %v", snapshot, err)
	}
}

func TestSnapshotTwentyColdStoresEventuallyProgress(t *testing.T) {
	_, counter := snapshotFixture(t)
	stores := make([]string, 20)
	for i := range stores {
		stores[i] = makeSnapshotStore(t, "a")
	}
	var wg sync.WaitGroup
	for _, store := range stores {
		wg.Add(1)
		go func() { defer wg.Done(); _, _ = LoadSnapshot(context.Background(), store, "a") }()
	}
	wg.Wait()
	done := make(map[string]bool)
	deadline := time.Now().Add(15 * time.Second)
	for len(done) < len(stores) && time.Now().Before(deadline) {
		for _, store := range stores {
			if done[store] {
				continue
			}
			snapshot, err := LoadSnapshot(context.Background(), store, "a")
			if err == nil && snapshot.Found {
				done[store] = true
			}
		}
		if len(done) < len(stores) {
			time.Sleep(30 * time.Millisecond)
		}
	}
	if len(done) != 20 {
		t.Fatalf("cold stores starved: completed %d/20", len(done))
	}
	if launches(counter) != 20 {
		t.Fatalf("cold stores launched %d updaters, want 20", launches(counter))
	}
	t.Log("20 distinct stores: 20 independent maintenance launches; all progressed through two-slot admission")
}
