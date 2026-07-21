package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anticorrelator/lore/tui/internal/worktree"
)

func TestWriteAndListInstance(t *testing.T) {
	dir := t.TempDir()
	inst := Instance{
		Name: "amber-otter", PID: 4242, Repo: "github.com/x/y",
		Started: "2026-07-05T00:00:00Z", InitiatorDefault: "human",
		Sessions: []Session{{Slug: "s1", Type: "spec", Initiator: "human", Started: "2026-07-05T00:00:01Z",
			CloseRequests: []string{"term-1", "explicit-2"}}},
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
	if closeRequests := got[0].Sessions[0].CloseRequests; len(closeRequests) != 2 ||
		closeRequests[0] != "term-1" || closeRequests[1] != "explicit-2" {
		t.Fatalf("session close_requests roundtrip = %v", closeRequests)
	}
}

func TestSessionWorktreeIdentityRoundTripAndLegacyOmission(t *testing.T) {
	dir := t.TempDir()
	identity := &worktree.Identity{
		Version:       worktree.IdentityVersion,
		CanonicalPath: "/repo/.git/lore-worktrees/session-1",
		GitCommonDir:  "/repo/.git",
		GitDir:        "/repo/.git/worktrees/session-1",
		Epoch:         "epoch-1",
		Captured: worktree.Generation{
			CanonicalPath:  "/repo",
			GitCommonDir:   "/repo/.git",
			GitDir:         "/repo/.git",
			HeadOID:        "1111111111111111111111111111111111111111",
			IndexDigest:    "index-a",
			WorktreeDigest: "tree-a",
		},
		TargetRef: "refs/heads/main",
		TargetOID: "1111111111111111111111111111111111111111",
		State:     worktree.StateActive,
	}
	inst := Instance{Name: "owner", Repo: "repo", PID: 1, Sessions: []Session{{
		Slug: "demo", Type: "implement", Started: "2026-07-21T00:00:00Z", Worktree: identity,
		WorktreeID: "tree-1", ExecutionDir: identity.CanonicalPath, PID: 4242, Tmux: "lore-owner-demo",
	}}}
	if err := WriteInstance(dir, inst); err != nil {
		t.Fatal(err)
	}
	got := ListInstances(dir)
	if len(got) != 1 || len(got[0].Sessions) != 1 || got[0].Sessions[0].Worktree == nil {
		t.Fatalf("worktree identity missing after registry roundtrip: %+v", got)
	}
	round := got[0].Sessions[0].Worktree
	if *round != *identity {
		t.Fatalf("worktree identity changed across registry roundtrip:\n got %+v\nwant %+v", *round, *identity)
	}
	managed := got[0].Sessions[0]
	if managed.WorktreeID != "tree-1" || managed.ExecutionDir != identity.CanonicalPath || managed.PID != 4242 || managed.Tmux != "lore-owner-demo" {
		t.Fatalf("independent manager/process ownership changed across registry roundtrip: %+v", managed)
	}

	legacy := Instance{Name: "legacy", Repo: "repo", PID: 2, Sessions: []Session{{Slug: "old", Type: "spec"}}}
	if err := WriteInstance(dir, legacy); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(instancePath(dir, "legacy"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), `"worktree"`) {
		t.Fatalf("legacy row unexpectedly serialized worktree identity: %s", data)
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

// TestRoutingFieldsRoundTripAndDegradation guards the instance-row enrichment:
// project_dir/framework round-trip through a write, and a row written by a
// pre-feature binary (neither field present) decodes as empty rather than erroring
// so downstream readers can render the unknown fallback.
func TestRoutingFieldsRoundTripAndDegradation(t *testing.T) {
	dir := t.TempDir()
	enriched := Instance{
		Name: "amber-otter", PID: 7, Started: "2026-07-06T00:00:00Z",
		ProjectDir: "/work/mine", Framework: "claude-code",
	}
	if err := WriteInstance(dir, enriched); err != nil {
		t.Fatal(err)
	}
	got := ListInstances(dir)
	if len(got) != 1 || got[0].ProjectDir != "/work/mine" || got[0].Framework != "claude-code" {
		t.Fatalf("routing fields did not round-trip: %+v", got)
	}

	// Absent fields are omitted on marshal (omit-when-empty).
	data, err := json.Marshal(Instance{Name: "bare", PID: 1})
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"project_dir", "framework"} {
		if strings.Contains(string(data), key) {
			t.Errorf("absent %s should be omitted, got %s", key, data)
		}
	}

	// A legacy row lacking both fields decodes cleanly as empty.
	legacy := filepath.Join(InstancesDir(dir), "legacy-instance.json")
	if err := os.WriteFile(legacy, []byte(`{"name":"legacy-instance","pid":9,"started":"2026-07-06T00:00:00Z","sessions":[]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, inst := range ListInstances(dir) {
		if inst.Name == "legacy-instance" && (inst.ProjectDir != "" || inst.Framework != "") {
			t.Fatalf("legacy row should read with empty routing fields, got %+v", inst)
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
