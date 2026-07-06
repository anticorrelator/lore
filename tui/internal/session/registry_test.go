package session

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestWriteAndListInstance(t *testing.T) {
	dir := t.TempDir()
	inst := Instance{
		Name: "amber-otter", PID: 4242, Repo: "github.com/x/y",
		Started: "2026-07-05T00:00:00Z", InitiatorDefault: "human",
		Sessions: []Session{{Slug: "s1", Type: "spec", Initiator: "human", Started: "2026-07-05T00:00:01Z"}},
	}
	if err := WriteInstance(dir, inst); err != nil {
		t.Fatalf("WriteInstance: %v", err)
	}
	got := ListInstances(dir)
	if len(got) != 1 {
		t.Fatalf("ListInstances len = %d, want 1", len(got))
	}
	if got[0].Name != inst.Name || got[0].PID != inst.PID || len(got[0].Sessions) != 1 {
		t.Fatalf("roundtrip mismatch: %+v", got[0])
	}
	if got[0].Sessions[0].Slug != "s1" {
		t.Fatalf("session slug = %q", got[0].Sessions[0].Slug)
	}
}

// TestBuildIdentityRoundTripAndDegradation guards the additive build-vintage
// fields: they round-trip when present, and a row written by an older binary
// (no build_sha/build_time keys at all) still parses, reading as vintage-unknown
// (empty strings) rather than being rejected.
func TestBuildIdentityRoundTripAndDegradation(t *testing.T) {
	dir := t.TempDir()
	stamped := Instance{
		Name: "amber-otter", PID: 7, Started: "2026-07-06T00:00:00Z",
		BuildSHA: "1dfdd89", BuildTime: "2026-07-06T02:12:38Z",
	}
	if err := WriteInstance(dir, stamped); err != nil {
		t.Fatal(err)
	}
	got := ListInstances(dir)
	if len(got) != 1 || got[0].BuildSHA != "1dfdd89" || got[0].BuildTime != "2026-07-06T02:12:38Z" {
		t.Fatalf("build identity did not round-trip: %+v", got)
	}

	// A legacy row with no build fields decodes as vintage-unknown, not an error.
	legacy := filepath.Join(InstancesDir(dir), "legacy-instance.json")
	if err := os.WriteFile(legacy, []byte(`{"name":"legacy-instance","pid":9,"started":"2026-07-06T00:00:00Z","sessions":[]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, inst := range ListInstances(dir) {
		if inst.Name == "legacy-instance" && (inst.BuildSHA != "" || inst.BuildTime != "") {
			t.Fatalf("legacy row should read as vintage-unknown, got %+v", inst)
		}
	}
}

func TestListInstancesDropsStaleByMtime(t *testing.T) {
	dir := t.TempDir()
	if err := WriteInstance(dir, Instance{Name: "swift-heron", PID: 1}); err != nil {
		t.Fatal(err)
	}
	// Age the file past the TTL.
	old := time.Now().Add(-2 * LivenessTTL)
	if err := os.Chtimes(instancePath(dir, "swift-heron"), old, old); err != nil {
		t.Fatal(err)
	}
	if got := ListInstances(dir); len(got) != 0 {
		t.Fatalf("stale instance not dropped: %+v", got)
	}
	if InstanceLive(dir, "swift-heron") {
		t.Fatal("InstanceLive reported a stale instance as live")
	}
}

func TestListInstancesExcludesCorruptRow(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(InstancesDir(dir), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(instancePath(dir, "broken"), []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := WriteInstance(dir, Instance{Name: "good-one", PID: 2}); err != nil {
		t.Fatal(err)
	}
	got := ListInstances(dir)
	if len(got) != 1 || got[0].Name != "good-one" {
		t.Fatalf("corrupt row not excluded cleanly: %+v", got)
	}
}

func TestHeartbeatRecreatesMissingFile(t *testing.T) {
	dir := t.TempDir()
	inst := Instance{Name: "calm-cedar", PID: 3}
	// Heartbeat with no prior file must recreate it rather than error.
	if err := Heartbeat(dir, inst); err != nil {
		t.Fatalf("Heartbeat recreate: %v", err)
	}
	if !InstanceLive(dir, "calm-cedar") {
		t.Fatal("Heartbeat did not create a live instance file")
	}
}

func TestRemoveInstanceIdempotent(t *testing.T) {
	dir := t.TempDir()
	if err := WriteInstance(dir, Instance{Name: "jade-comet", PID: 4}); err != nil {
		t.Fatal(err)
	}
	if err := RemoveInstance(dir, "jade-comet"); err != nil {
		t.Fatalf("RemoveInstance: %v", err)
	}
	// Second remove is a no-op, not an error.
	if err := RemoveInstance(dir, "jade-comet"); err != nil {
		t.Fatalf("RemoveInstance second call: %v", err)
	}
}

func TestAtomicWriteLeavesNoTmp(t *testing.T) {
	dir := t.TempDir()
	if err := WriteInstance(dir, Instance{Name: "olive-fjord", PID: 5}); err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(InstancesDir(dir))
	for _, e := range entries {
		if filepath.Ext(e.Name()) == ".tmp" || e.Name()[0] == '.' {
			t.Fatalf("leftover tmp file: %s", e.Name())
		}
	}
}
