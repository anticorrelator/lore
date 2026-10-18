package session

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestQueueUnknownCapabilityAndRetryDelay(t *testing.T) {
	q := newHostQueue(t)
	now := time.Now().UTC()
	live := map[string]bool{"me": true}
	q.plant(t, Request{RequestID: "future", Type: "worker", Slug: strp("item--w1"), Initiator: "agent", RequiredRuntimeCapabilities: []string{"unsupported-future-payload"}})
	if res := q.tick(t, "me", "", live, noPlan, nil, now); res.Claimed != nil {
		t.Fatal("unknown payload claimed")
	}
	q.dir = t.TempDir()
	q.plant(t, Request{RequestID: "known", Type: "worker", Slug: strp("item--w2"), Initiator: "agent", RequiredRuntimeCapabilities: RuntimeCapabilities()})
	if res := q.tick(t, "me", "", live, noPlan, nil, now); res.Claimed == nil {
		t.Fatal("supported payload refused")
	}
	at := now.Format(time.RFC3339)
	q.dir = t.TempDir()
	q.plant(t, Request{RequestID: "retry", Type: "worker", Slug: strp("item--w3"), Initiator: "agent", Attempts: 1, LastAttemptAt: &at})
	if res := q.tick(t, "me", "", live, noPlan, nil, now); res.Claimed != nil {
		t.Fatal("identical immediate retry")
	}
	if res := q.tick(t, "me", "", live, noPlan, nil, now.Add(3*time.Second)); res.Claimed == nil {
		t.Fatal("transient retry never eligible")
	}
	for _, value := range []string{"", "bad", "2020-01-01T00:00:00Z"} {
		if vintageOK("2026-09-01T00:00:00Z", value) {
			t.Fatalf("invalid/older vintage passed: %q", value)
		}
	}
}

func TestQueueAdmissionRefusalNeverClaimsAndRetainsIntent(t *testing.T) {
	q := newHostQueue(t)
	req := q.row(Request{RequestID: "request-1", Type: "worker", Slug: StrPtr("task--w1"), TargetInstance: StrPtr("old-window"), ExtraContext: json.RawMessage(`{"position_preparation":{"nested":"original intent"}}`)})
	plantPending(t, q.dir, req)
	reason := "python /full/path/python3: nested missing yaml and denied /full/state/path"
	result, err := QueueTickForStoreHost(q.dir, "me", "", q.key, q.scope, map[string]bool{"me": true}, noPlan, nil, time.Now(), ReclaimAfter, func(Request) error { return fmt.Errorf("%s", reason) })
	if err != nil {
		t.Fatal(err)
	}
	if result.Claimed != nil || len(ScanPending(q.dir)) != 0 || len(result.Abandoned) != 1 {
		t.Fatalf("refusal claimed or remained pending: %+v", result)
	}
	data, err := os.ReadFile(filepath.Join(q.dir, "requests", "abandoned", "request-1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var archived Request
	if err := json.Unmarshal(data, &archived); err != nil {
		t.Fatal(err)
	}
	if archived.Attempts != 0 || archived.ClaimedBy != nil || string(archived.ExtraContext) != string(req.ExtraContext) || archived.LastError == nil || *archived.LastError != "host admission: "+reason {
		t.Fatalf("intent/diagnostic lost: %+v", archived)
	}
	if archived.TargetValue() != "old-window" {
		t.Fatalf("archive rewrote the row's target_instance to %q", archived.TargetValue())
	}
	if result.Abandoned[0].Slug != "task--w1" {
		t.Fatal("refusal cannot join managed handle")
	}
	second, err := QueueTickForStoreHost(q.dir, "me", "", q.key, q.scope, nil, noPlan, nil, time.Now(), ReclaimAfter, func(Request) error { t.Fatal("deterministic probe repeated"); return nil })
	if err != nil || second.Claimed != nil {
		t.Fatalf("second tick: %+v %v", second, err)
	}
}

type temporaryAdmission struct{}

func (temporaryAdmission) Error() string   { return "temporary probe resource exhaustion" }
func (temporaryAdmission) Retryable() bool { return true }
func TestQueueTransientAdmissionPreservesPending(t *testing.T) {
	q := newHostQueue(t)
	q.plant(t, Request{RequestID: "transient", Type: "worker"})
	result, err := QueueTickForStoreHost(q.dir, "me", "", q.key, q.scope, nil, noPlan, nil, time.Now(), ReclaimAfter, func(Request) error { return temporaryAdmission{} })
	if err != nil || result.Claimed != nil || len(ScanPending(q.dir)) != 1 || len(result.Abandoned) != 0 || len(result.Diagnostics) != 1 {
		t.Fatalf("temporary probe discarded intent or claimed: %+v %v", result, err)
	}
}

func TestQueueRetryMinimumWithFractionalTimestamp(t *testing.T) {
	q := newHostQueue(t)
	at := time.Date(2026, 9, 5, 12, 0, 0, 999999999, time.UTC)
	stamp := at.Format(time.RFC3339Nano)
	for _, attempts := range []int{1, 2} {
		q.dir = t.TempDir()
		q.plant(t, Request{RequestID: "retry", Type: "spec", Slug: strp("s"), Initiator: "agent", Attempts: attempts, LastAttemptAt: &stamp})
		delay := time.Duration(1<<attempts) * time.Second
		if res := q.tick(t, "me", "", nil, noPlan, nil, at.Add(delay-time.Nanosecond)); res.Claimed != nil {
			t.Fatalf("attempt %d admitted before minimum delay", attempts)
		}
		if res := q.tick(t, "me", "", nil, noPlan, nil, at.Add(delay)); res.Claimed == nil {
			t.Fatalf("attempt %d refused at minimum delay", attempts)
		}
	}
}

func TestQueueAdmissionArchiveFailureRemainsRecoverable(t *testing.T) {
	q := newHostQueue(t)
	dir := q.dir
	req := q.row(Request{RequestID: "refused", Type: "worker", Framework: strp("claude-code"), Model: strp("fixture-model"), ExtraContext: json.RawMessage(`{"nested":"original"}`)})
	plantPending(t, dir, req)
	reason := "full nested refusal\npermission denied: /state/path"
	req.LastError = &reason
	bad := req
	bad.ExtraContext = json.RawMessage(`invalid json`)
	if won, err := ArchiveRejectedPending(dir, bad); won || err == nil {
		t.Fatalf("preparation failure won=%v err=%v", won, err)
	}
	if len(ScanPending(dir)) != 1 {
		t.Fatal("failed diagnosis write removed pending intent")
	}
	dest := filepath.Join(dir, "requests", "abandoned", req.RequestID+".json")
	if err := os.MkdirAll(dest, 0755); err != nil {
		t.Fatal(err)
	}
	if won, err := ArchiveRejectedPending(dir, req); !won || err == nil {
		t.Fatalf("forced final rename failure won=%v err=%v", won, err)
	}
	if len(ScanPending(dir)) != 0 || len(ScanClaimed(dir)) != 0 {
		t.Fatal("reserved rejection entered claim circulation")
	}
	stages, _ := filepath.Glob(filepath.Join(dir, "requests", "rejecting", "*", "request.json"))
	if len(stages) != 1 {
		t.Fatalf("missing recovery evidence: %v", stages)
	}
	saved, _, ok := readRow(stages[0], "test")
	if !ok || saved.LastError == nil || *saved.LastError != reason || saved.Attempts != 0 || string(saved.ExtraContext) != string(req.ExtraContext) {
		t.Fatalf("incomplete recovery evidence: %+v", saved)
	}
	if err := os.Remove(dest); err != nil {
		t.Fatal(err)
	}
	res, err := QueueTickForStoreHost(dir, "me", "", q.key, q.scope, nil, noPlan, nil, time.Now(), ReclaimAfter, func(Request) error { t.Fatal("reprobed reserved refusal"); return nil })
	if err != nil || res.Claimed != nil || len(res.Abandoned) != 1 || res.Abandoned[0].Reason != reason {
		t.Fatalf("recovery result=%+v err=%v", res, err)
	}
	archived, _, ok := readRow(dest, "test")
	if !ok || archived.LastError == nil || *archived.LastError != reason || archived.Attempts != 0 {
		t.Fatalf("bad archive: %+v", archived)
	}
}

func TestAdmissionRejectionLosesClaimRace(t *testing.T) {
	dir := t.TempDir()
	req := Request{RequestID: "race", Type: "worker"}
	plantPending(t, dir, req)
	if won, err := ClaimRequest(dir, req.RequestID); !won || err != nil {
		t.Fatalf("claim: %v %v", won, err)
	}
	req.LastError = StrPtr("refusal")
	if won, err := ArchiveRejectedPending(dir, req); won || err != nil {
		t.Fatalf("refusal stole claim: %v %v", won, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "requests", "abandoned", req.RequestID+".json")); !os.IsNotExist(err) {
		t.Fatalf("false terminal refusal: %v", err)
	}
	if rows := ScanClaimed(dir); len(rows) != 1 || rows[0].Request.LastError != nil {
		t.Fatalf("claim mutated: %+v", rows)
	}
}
