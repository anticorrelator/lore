package session

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestHostRecoveryScopesFreshDeadAndAbandonedClaims(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	rows := []Instance{
		{Name: "dead", PID: 0, Repo: "repo", HostKey: "host", Role: "session-host", ProjectDir: "/source"},
		{Name: "other-source", PID: 0, Repo: "repo", HostKey: "host", Role: "session-host", ProjectDir: "/other"},
		{Name: "other-host", PID: 0, Repo: "repo", HostKey: "other", Role: "session-host", ProjectDir: "/source"},
		{Name: "alive", PID: os.Getpid(), Repo: "repo", HostKey: "host", Role: "session-host", ProjectDir: "/source"},
		{Name: "claim", PID: 0, Repo: "repo", HostKey: "host", Role: "session-host", ProjectDir: "/source"},
	}
	for _, r := range rows {
		if err := WriteInstance(dir, r); err != nil {
			t.Fatal(err)
		}
	}
	old := filepath.Join(InstancesDir(dir), "claim.json")
	if err := os.Rename(old, old+".adopting.0"); err != nil {
		t.Fatal(err)
	}
	got, err := ScanHostAdoptable(dir, "host", "/source", "self")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("exact scoped recovery=%+v", got)
	}
	names := map[string]bool{}
	for _, r := range got {
		names[r.Name] = true
	}
	if !names["dead"] || !names["claim"] {
		t.Fatal(names)
	}
	// Even old manifests belong exclusively to the host route.
	for _, r := range rows {
		p := instancePath(dir, r.Name)
		_ = os.Chtimes(p, now.Add(-2*LivenessTTL), now.Add(-2*LivenessTTL))
	}
	if got := ScanAdoptable(dir, "repo", "legacy", now); len(got) != 0 {
		t.Fatalf("legacy stole host ownership: %+v", got)
	}
}

func TestHostQueueRetargetsAndLegacyDeclines(t *testing.T) {
	stageRouteScripts(t)
	dir := t.TempDir()
	now := time.Now()
	req := Request{Framework: StrPtr("claude-code"), Model: StrPtr("fixture-model"), RequestID: "r-host", Type: "worker", Slug: StrPtr("item--w123"), Initiator: "agent", HostKey: "host", TargetInstance: StrPtr("dead"), RequestedAt: now.UTC().Format(time.RFC3339)}
	if err := WritePending(dir, req); err != nil {
		t.Fatal(err)
	}
	yes := func(string) bool { return true }
	no := func(string) bool { return false }
	got, err := QueueTick(dir, "legacy", "", "/source", nil, yes, no, now, ReclaimAfter)
	if err != nil {
		t.Fatal(err)
	}
	if got.Claimed != nil {
		t.Fatal("legacy claimed managed request")
	}
	got, err = QueueTickForHost(dir, "fresh", "", "/source", "host", nil, yes, no, now, ReclaimAfter)
	if err != nil {
		t.Fatal(err)
	}
	if got.Claimed == nil {
		t.Fatalf("retarget claim=%+v", got)
	}
	got, err = QueueTickForHost(dir, "new-generation", "", "/source", "host", nil, yes, no, now, ReclaimAfter)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Reclaimed) != 1 || got.Claimed == nil {
		t.Fatalf("fresh dead predecessor not reclaimed: %+v", got)
	}
}

func TestHostRegistryRejectsLateSnapshot(t *testing.T) {
	dir := t.TempDir()
	newer := Instance{Name: "host", HostKey: "key", Revision: 2, Sessions: []Session{{Slug: "worker"}}}
	if err := WriteInstance(dir, newer); err != nil {
		t.Fatal(err)
	}
	old := newer
	old.Revision = 1
	old.Sessions = nil
	if err := WriteInstance(dir, old); !errors.Is(err, ErrStaleInstance) {
		t.Fatal(err)
	}
	rows, err := OwnershipInstances(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || len(rows[0].Sessions) != 1 {
		t.Fatalf("late snapshot lost durable session: %+v", rows)
	}
}
