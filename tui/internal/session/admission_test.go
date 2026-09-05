package session

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestAdmissionUnknownCapabilityAndRetryDelay(t *testing.T) {
	now := time.Now().UTC()
	req := Request{RequiredRuntimeCapabilities: []string{"unsupported-future-payload"}}
	if claimableBy(req, "me", "", "", now) {
		t.Fatal("unknown payload claimed")
	}
	req.RequiredRuntimeCapabilities = RuntimeCapabilities()
	if !claimableBy(req, "me", "", "", now) {
		t.Fatal("supported payload refused")
	}
	at := now.Format(time.RFC3339)
	req.Attempts, req.LastAttemptAt = 1, &at
	if claimableBy(req, "me", "", "", now) {
		t.Fatal("identical immediate retry")
	}
	if !claimableBy(req, "me", "", "", now.Add(3*time.Second)) {
		t.Fatal("transient retry never eligible")
	}
	for _, value := range []string{"", "bad", "2020-01-01T00:00:00Z"} {
		if vintageOK("2026-09-01T00:00:00Z", value) {
			t.Fatalf("invalid/older vintage passed: %q", value)
		}
	}
}

func TestAdmissionRefusalNeverClaimsAndRetainsIntent(t *testing.T) {
	dir := t.TempDir()
	req := Request{RequestID: "request-1", Type: "worker", Slug: StrPtr("task--w1"), TargetInstance: StrPtr("me"), ExtraContext: json.RawMessage(`{"position_preparation":{"nested":"original intent"}}`)}
	plantPending(t, dir, req)
	reason := "python /full/path/python3: nested missing yaml and denied /full/state/path"
	result, err := QueueTickForHostAdmission(dir, "me", "", "", "", map[string]bool{"me": true}, noPlan, nil, time.Now(), ReclaimAfter, func(Request) error { return fmt.Errorf("%s", reason) })
	if err != nil {
		t.Fatal(err)
	}
	if result.Claimed != nil || len(ScanPending(dir)) != 0 || len(result.Abandoned) != 1 {
		t.Fatalf("refusal claimed or remained pending: %+v", result)
	}
	data, err := os.ReadFile(filepath.Join(dir, "requests", "abandoned", "request-1.json"))
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
	if result.Abandoned[0].Slug != "task--w1" {
		t.Fatal("refusal cannot join managed handle")
	}
	second, err := QueueTickForHostAdmission(dir, "me", "", "", "", nil, noPlan, nil, time.Now(), ReclaimAfter, func(Request) error { t.Fatal("deterministic probe repeated"); return nil })
	if err != nil || second.Claimed != nil {
		t.Fatalf("second tick: %+v %v", second, err)
	}
}

type temporaryAdmission struct{}

func (temporaryAdmission) Error() string   { return "temporary probe resource exhaustion" }
func (temporaryAdmission) Retryable() bool { return true }
func TestTransientAdmissionPreservesPending(t *testing.T) {
	dir := t.TempDir()
	plantPending(t, dir, Request{RequestID: "transient", Type: "worker"})
	result, err := QueueTickForHostAdmission(dir, "me", "", "", "", nil, noPlan, nil, time.Now(), ReclaimAfter, func(Request) error { return temporaryAdmission{} })
	if err != nil || result.Claimed != nil || len(ScanPending(dir)) != 1 || len(result.Abandoned) != 0 || len(result.Diagnostics) != 1 {
		t.Fatalf("temporary probe discarded intent or claimed: %+v %v", result, err)
	}
}
