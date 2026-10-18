package session

import (
	"encoding/json"
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
		{Name: "dead", PID: 0, Repo: "repo", HostKey: "host", Role: "session-host"},
		{Name: "legacy-checkout", PID: 0, Repo: "repo", HostKey: "host", Role: "session-host", ProjectDir: "/other"},
		{Name: "migrated", PID: 0, Repo: "repo", HostKey: "old", Role: "session-host", ProjectDir: "/source"},
		{Name: "other-host", PID: 0, Repo: "repo", HostKey: "other", Role: "session-host"},
		{Name: "alive", PID: os.Getpid(), Repo: "repo", HostKey: "host", Role: "session-host"},
		{Name: "claim", PID: 0, Repo: "repo", HostKey: "host", Role: "session-host"},
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
	got, err := ScanHostAdoptable(dir, map[string]bool{"host": true, "old": true}, "self")
	if err != nil {
		t.Fatal(err)
	}
	names := map[string]bool{}
	for _, r := range got {
		names[r.Name] = true
	}
	// Key alone scopes a store host's recovery: a row's checkout is not compared.
	if len(got) != 4 || !names["dead"] || !names["legacy-checkout"] || !names["migrated"] || !names["claim"] {
		t.Fatalf("key-set recovery = %v", names)
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

// writeRawInstance writes a registry row exactly as given, bypassing the
// runtime stamp WriteInstance applies, the way another runtime or an older
// binary would have left it.
func writeRawInstance(t *testing.T, dir, name string, row map[string]any) {
	t.Helper()
	row["name"] = name
	b, err := json.Marshal(row)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(InstancesDir(dir), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(instancePath(dir, name), b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestStoreHostRecoveryAdoptionIsFencedByRuntime(t *testing.T) {
	dir := t.TempDir()
	session := []map[string]any{{"slug": "s", "type": "worker", "initiator": "agent", "started": "2026-10-18T00:00:00Z"}}
	for name, row := range map[string]map[string]any{
		"tui-default":    {"pid": 0, "repo": "repo", "runtime": "", "sessions": session},
		"tui-unstamped":  {"pid": 0, "repo": "repo", "sessions": session},
		"tui-dev":        {"pid": 0, "repo": "repo", "runtime": "dev", "sessions": session},
		"host-default":   {"pid": 0, "repo": "repo", "host_key": "key", "role": "session-host", "runtime": "", "sessions": session},
		"host-unstamped": {"pid": 0, "repo": "repo", "host_key": "key", "role": "session-host", "sessions": session},
		"host-dev":       {"pid": 0, "repo": "repo", "host_key": "key", "role": "session-host", "runtime": "dev", "sessions": session},
	} {
		writeRawInstance(t, dir, name, row)
	}
	names := func(rows []Instance) map[string]bool {
		out := map[string]bool{}
		for _, r := range rows {
			out[r.Name] = true
		}
		return out
	}
	keys := map[string]bool{"key": true}

	t.Setenv("LORE_SESSION_RUNTIME", "")
	if got := names(ScanAdoptable(dir, "repo", "self", time.Now())); len(got) != 2 || !got["tui-default"] || !got["tui-unstamped"] {
		t.Fatalf("default runtime TUI adoption = %v", got)
	}
	hostRows, err := ScanHostAdoptable(dir, keys, "self")
	if got := names(hostRows); err != nil || len(got) != 2 || !got["host-default"] || !got["host-unstamped"] {
		t.Fatalf("default runtime host adoption = %v, %v", got, err)
	}

	t.Setenv("LORE_SESSION_RUNTIME", "dev")
	if got := names(ScanAdoptable(dir, "repo", "self", time.Now())); len(got) != 1 || !got["tui-dev"] {
		t.Fatalf("named runtime TUI adoption = %v", got)
	}
	hostRows, err = ScanHostAdoptable(dir, keys, "self")
	if got := names(hostRows); err != nil || len(got) != 1 || !got["host-dev"] {
		t.Fatalf("named runtime host adoption = %v, %v", got, err)
	}
}

func TestStoreHostRecoveryKeySetFollowsMigrationRecords(t *testing.T) {
	dir := t.TempDir()
	record := func(key string, body string) {
		t.Helper()
		path := filepath.Join(dir, "hosts", key, "migrated.json")
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	record("old1", `{"schema_version":1,"from":"old1","to":"store","at":"2026-10-18T00:00:00Z"}`)
	record("old2", `{"schema_version":1,"from":"old2","to":"another-store","at":"2026-10-18T00:00:00Z"}`)
	record("old3", `{"schema_version":1,"to":"store"}`)
	record("old4", `not json`)

	t.Setenv("LORE_SESSION_RUNTIME", "")
	keys, err := HostRecoveryKeys(dir, "store")
	if err != nil || len(keys) != 2 || !keys["store"] || !keys["old1"] {
		t.Fatalf("default runtime key set = %v, %v", keys, err)
	}
	// A named runtime never adopts legacy keys, whose records carry no runtime.
	t.Setenv("LORE_SESSION_RUNTIME", "dev")
	keys, err = HostRecoveryKeys(dir, "store")
	if err != nil || len(keys) != 1 || !keys["store"] {
		t.Fatalf("named runtime key set = %v, %v", keys, err)
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

func TestStoreHostKeyMatchesTheSupervisorsKey(t *testing.T) {
	// Vectors from sha256(path [+ "\0runtime\0" + name]).hexdigest()[:24].
	const store = "/Users/x/.lore/repos/github.com/acme/proj"
	if got := StoreHostKey(store, ""); got != "9f9b6c167bb9e00ed2f278a5" {
		t.Fatalf("default runtime key = %s", got)
	}
	if got := StoreHostKey(store, "dev"); got != "c624135ebc28ead6d60d7001" {
		t.Fatalf("named runtime key = %s", got)
	}
}
