package session

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// reapedPID returns a pid that is guaranteed dead: a child process run to
// completion and reaped, so syscall.Kill(pid, 0) yields ESRCH rather than treating
// a zombie as alive.
func reapedPID(t *testing.T) int {
	t.Helper()
	cmd := exec.Command("true")
	if err := cmd.Start(); err != nil {
		t.Fatalf("start true: %v", err)
	}
	pid := cmd.Process.Pid
	_ = cmd.Wait()
	return pid
}

// writeInstanceAged writes an instance row and backdates its mtime by age so
// ScanAdoptable's staleness check sees it as a corpse (age > TTL) or fresh
// (age < TTL) deterministically.
func writeInstanceAged(t *testing.T, dir string, inst Instance, age time.Duration) {
	t.Helper()
	if err := WriteInstance(dir, inst); err != nil {
		t.Fatalf("WriteInstance %s: %v", inst.Name, err)
	}
	when := time.Now().Add(-age)
	if err := os.Chtimes(instancePath(dir, inst.Name), when, when); err != nil {
		t.Fatalf("chtimes %s: %v", inst.Name, err)
	}
}

// TestScanAdoptable_FilterMatrix is the adoptability rule: a row is adoptable only
// when it is not self, names this repo, is mtime-stale, AND its PID is dead. Every
// other combination — self, wrong repo, fresh mtime, live PID — is excluded.
func TestScanAdoptable_FilterMatrix(t *testing.T) {
	dir := t.TempDir()
	const repo, self = "my-repo", "me"
	dead := reapedPID(t)
	live := os.Getpid()
	stale := 2 * LivenessTTL
	fresh := LivenessTTL / 2

	writeInstanceAged(t, dir, Instance{Name: "corpse", Repo: repo, PID: dead}, stale)            // adoptable
	writeInstanceAged(t, dir, Instance{Name: "me", Repo: repo, PID: dead}, stale)                // self → skip
	writeInstanceAged(t, dir, Instance{Name: "other-repo", Repo: "elsewhere", PID: dead}, stale) // wrong repo → skip
	writeInstanceAged(t, dir, Instance{Name: "fresh", Repo: repo, PID: dead}, fresh)             // heartbeating → skip
	writeInstanceAged(t, dir, Instance{Name: "alive", Repo: repo, PID: live}, stale)             // pid live → skip

	got := ScanAdoptable(dir, repo, self, time.Now())
	if len(got) != 1 || got[0].Name != "corpse" {
		names := make([]string, len(got))
		for i, g := range got {
			names[i] = g.Name
		}
		t.Fatalf("adoptable = %v, want exactly [corpse]", names)
	}
}

// TestClaimInstance_AtomicSingleWinner is the rename-as-claim atomicity property:
// of many goroutines racing to claim the same corpse, exactly one succeeds — the
// os.Rename source disappears for every loser.
func TestClaimInstance_AtomicSingleWinner(t *testing.T) {
	dir := t.TempDir()
	writeInstanceAged(t, dir, Instance{
		Name: "corpse", Repo: "r", PID: 1,
		Sessions: []Session{{Slug: "demo", Type: "spec", Initiator: "human", Started: "2026-07-06T00:00:00Z"}},
	}, 0)

	const racers = 12
	var wg sync.WaitGroup
	var mu sync.Mutex
	wins, claimPaths := 0, []string{}
	wg.Add(racers)
	for i := 0; i < racers; i++ {
		go func() {
			defer wg.Done()
			inst, claim, err := ClaimInstance(dir, "corpse")
			if err != nil {
				return // lost the race
			}
			mu.Lock()
			wins++
			claimPaths = append(claimPaths, claim)
			mu.Unlock()
			if len(inst.Sessions) != 1 || inst.Sessions[0].Slug != "demo" {
				t.Errorf("winner read wrong row: %+v", inst.Sessions)
			}
		}()
	}
	wg.Wait()
	if wins != 1 {
		t.Fatalf("claim winners = %d, want exactly 1", wins)
	}
	// The original .json is gone (renamed away) and DeleteClaim clears the corpse.
	if _, err := os.Stat(instancePath(dir, "corpse")); !os.IsNotExist(err) {
		t.Fatalf("claimed corpse .json still present: %v", err)
	}
	if err := DeleteClaim(claimPaths[0]); err != nil {
		t.Fatalf("DeleteClaim: %v", err)
	}
	if _, err := os.Stat(claimPaths[0]); !os.IsNotExist(err) {
		t.Fatalf("claim file still present after DeleteClaim: %v", err)
	}
	if err := DeleteClaim(claimPaths[0]); err != nil {
		t.Fatalf("DeleteClaim not idempotent: %v", err)
	}
}

// TestScanAdoptable_ClaimFilesInvisible: a claim-suffixed file left in the
// instances dir (e.g. by a crash mid-adoption) is never re-scanned as an adoptable
// row — the suffix keeps it out of the *.json glob.
func TestScanAdoptable_ClaimFilesInvisible(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(InstancesDir(dir), 0o755); err != nil {
		t.Fatal(err)
	}
	claim := filepath.Join(InstancesDir(dir), "corpse.json"+claimSuffix+".999")
	if err := os.WriteFile(claim, []byte(`{"name":"corpse","repo":"r","pid":1}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := ScanAdoptable(dir, "r", "me", time.Now()); len(got) != 0 {
		t.Fatalf("claim file surfaced as adoptable: %+v", got)
	}
}

// TestSessionRow_RecoveryFieldsRoundtrip: the additive recovery-manifest fields
// survive a marshal/unmarshal, and stay omitted when empty so an old reader and
// direct-PTY rows are unaffected.
func TestSessionRow_RecoveryFieldsRoundtrip(t *testing.T) {
	dir := t.TempDir()
	yes := true
	full := Instance{
		Name: "inst", Repo: "r", PID: 1,
		Sessions: []Session{{
			Slug: "demo", Type: "spec", Initiator: "human", Started: "2026-07-06T00:00:00Z",
			Tmux: "lore-inst-demo", SessionID: "uuid-1", Harness: "claude-code", AutoClose: &yes,
		}},
	}
	if err := WriteInstance(dir, full); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(instancePath(dir, "inst"))
	if err != nil {
		t.Fatal(err)
	}
	// Direct-PTY sessions omit the manifest fields entirely.
	bare := Instance{Name: "bare", Repo: "r", PID: 1, Sessions: []Session{{Slug: "d", Type: "chat", Initiator: "agent", Started: "x"}}}
	if err := WriteInstance(dir, bare); err != nil {
		t.Fatal(err)
	}
	bareData, _ := os.ReadFile(instancePath(dir, "bare"))
	for _, field := range []string{`"tmux"`, `"session_id"`, `"harness"`, `"auto_close"`} {
		if bytes.Contains(bareData, []byte(field)) {
			t.Errorf("bare row wrote %s despite empty value: %s", field, bareData)
		}
	}
	got := ScanAdoptable(dir, "r", "other", time.Now().Add(2*LivenessTTL))
	var round *Session
	for _, inst := range got {
		if inst.Name == "inst" {
			round = &inst.Sessions[0]
		}
	}
	if round == nil {
		t.Fatalf("full row not read back; raw=%s", data)
	}
	if round.Tmux != "lore-inst-demo" || round.SessionID != "uuid-1" || round.Harness != "claude-code" || round.AutoClose == nil || !*round.AutoClose {
		t.Fatalf("recovery fields did not round-trip: %+v", round)
	}
}
