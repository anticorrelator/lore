package session

import (
	"encoding/json"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func strp(s string) *string { return &s }

func plantPending(t *testing.T, dir string, req Request) {
	t.Helper()
	if err := WritePending(dir, req); err != nil {
		t.Fatalf("WritePending %q: %v", req.RequestID, err)
	}
}

// TestClaimIsAtMostOnce is the core substrate invariant: under any number of
// racing claimers of one pending row, exactly one wins the atomic rename. Run
// many rounds with fresh rows to exercise the race repeatedly.
func TestClaimIsAtMostOnce(t *testing.T) {
	dir := t.TempDir()
	const rounds = 200
	const claimers = 8
	for r := 0; r < rounds; r++ {
		id := NewRequestID()
		plantPending(t, dir, Request{RequestID: id, Type: "spec", Slug: strp("s"), Initiator: "agent"})

		var wins int64
		var wg sync.WaitGroup
		start := make(chan struct{})
		for c := 0; c < claimers; c++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-start
				won, err := ClaimRequest(dir, id)
				if err != nil {
					t.Errorf("ClaimRequest error: %v", err)
					return
				}
				if won {
					atomic.AddInt64(&wins, 1)
				}
			}()
		}
		close(start)
		wg.Wait()
		if wins != 1 {
			t.Fatalf("round %d: %d claimers won, want exactly 1", r, wins)
		}
		// Clean up the claimed row for the next round.
		_ = DeleteClaimed(dir, id)
	}
}

func TestQueueTickTargeting(t *testing.T) {
	dir := t.TempDir()
	openReq := Request{RequestID: "open1", Type: "spec", Slug: strp("a"), Initiator: "agent"}
	targetedMine := Request{RequestID: "mine1", Type: "spec", Slug: strp("b"), Initiator: "agent", TargetInstance: strp("me")}
	targetedOther := Request{RequestID: "other1", Type: "spec", Slug: strp("c"), Initiator: "agent", TargetInstance: strp("someone-else")}

	// An open request is claimable by this instance.
	plantPending(t, dir, openReq)
	res, err := QueueTick(dir, "me", "", "", map[string]bool{"me": true}, noPlan, nil, time.Now(), ReclaimAfter)
	if err != nil {
		t.Fatal(err)
	}
	if res.Claimed == nil || res.Claimed.RequestID != "open1" {
		t.Fatalf("open request not claimed: %+v", res.Claimed)
	}
	_ = DeleteClaimed(dir, "open1")

	// A targeted request is claimable only by its named instance.
	plantPending(t, dir, targetedMine)
	res, _ = QueueTick(dir, "me", "", "", map[string]bool{"me": true}, noPlan, nil, time.Now(), ReclaimAfter)
	if res.Claimed == nil || res.Claimed.RequestID != "mine1" {
		t.Fatalf("targeted-to-me request not claimed: %+v", res.Claimed)
	}
	_ = DeleteClaimed(dir, "mine1")

	// A request targeted at another instance stays pending here.
	plantPending(t, dir, targetedOther)
	res, _ = QueueTick(dir, "me", "", "", map[string]bool{"me": true}, noPlan, nil, time.Now(), ReclaimAfter)
	if res.Claimed != nil {
		t.Fatalf("claimed a request targeted at another instance: %+v", res.Claimed)
	}
	if len(ScanPending(dir)) != 1 {
		t.Fatal("targeted-other request should remain pending")
	}
}

// TestQueueTickMinVintage exercises the read-side vintage filter mirroring the
// targeting filter: a request requiring a minimum vintage is claimed by an
// instance at-or-newer, skipped by an older one, and — the additive-degradation
// invariant — always claimed by a vintage-unknown instance.
func TestQueueTickMinVintage(t *testing.T) {
	const cutoff = "2026-07-06T00:00:00Z"
	newer := "2026-07-06T12:00:00Z"
	older := "2026-07-05T12:00:00Z"

	// A new-enough instance claims a min_vintage request.
	dir := t.TempDir()
	plantPending(t, dir, Request{RequestID: "v1", Type: "spec", Slug: strp("a"), Initiator: "agent", MinVintage: strp(cutoff)})
	res, err := QueueTick(dir, "me", newer, "", map[string]bool{"me": true}, noPlan, nil, time.Now(), ReclaimAfter)
	if err != nil {
		t.Fatal(err)
	}
	if res.Claimed == nil || res.Claimed.RequestID != "v1" {
		t.Fatalf("new-enough instance did not claim min_vintage request: %+v", res.Claimed)
	}

	// An older instance leaves the same request pending.
	dir = t.TempDir()
	plantPending(t, dir, Request{RequestID: "v2", Type: "spec", Slug: strp("b"), Initiator: "agent", MinVintage: strp(cutoff)})
	res, _ = QueueTick(dir, "me", older, "", map[string]bool{"me": true}, noPlan, nil, time.Now(), ReclaimAfter)
	if res.Claimed != nil {
		t.Fatalf("older instance claimed a request it is too old for: %+v", res.Claimed)
	}
	if len(ScanPending(dir)) != 1 {
		t.Fatal("min_vintage-gated request should remain pending for an older instance")
	}

	// A vintage-unknown instance ("" build time) is never rejected — additive
	// degradation: an old binary predating the field still claims.
	dir = t.TempDir()
	plantPending(t, dir, Request{RequestID: "v3", Type: "spec", Slug: strp("c"), Initiator: "agent", MinVintage: strp(cutoff)})
	res, _ = QueueTick(dir, "me", "", "", map[string]bool{"me": true}, noPlan, nil, time.Now(), ReclaimAfter)
	if res.Claimed == nil || res.Claimed.RequestID != "v3" {
		t.Fatalf("vintage-unknown instance was wrongly rejected by min_vintage: %+v", res.Claimed)
	}
}

// TestMinVintageRoundTrips guards the request-row amendment: min_vintage decodes
// into the pointer, and an absent field stays nil (omit-when-empty, so a marshal
// of a row without the requirement never emits the key).
func TestMinVintageRoundTrips(t *testing.T) {
	var req Request
	if err := json.Unmarshal([]byte(`{"request_id":"x","type":"spec","min_vintage":"2026-07-06T00:00:00Z"}`), &req); err != nil {
		t.Fatalf("decode min_vintage: %v", err)
	}
	if got := req.MinVintageValue(); got != "2026-07-06T00:00:00Z" {
		t.Fatalf("MinVintageValue = %q, want the decoded timestamp", got)
	}

	data, err := json.Marshal(Request{RequestID: "x", Type: "spec"})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(data), "min_vintage") {
		t.Errorf("absent min_vintage should be omitted, got %s", data)
	}
}

func TestQueueTickImplementGate(t *testing.T) {
	dir := t.TempDir()
	plantPending(t, dir, Request{RequestID: "impl1", Type: "implement", Slug: strp("needs-plan"), Initiator: "agent"})

	// Without a plan doc, an implement request is not claimed.
	res, _ := QueueTick(dir, "me", "", "", nil, func(string) bool { return false }, nil, time.Now(), ReclaimAfter)
	if res.Claimed != nil {
		t.Fatalf("implement claimed despite no plan doc: %+v", res.Claimed)
	}
	// With a plan doc, it becomes claimable.
	res, _ = QueueTick(dir, "me", "", "", nil, func(string) bool { return true }, nil, time.Now(), ReclaimAfter)
	if res.Claimed == nil || res.Claimed.RequestID != "impl1" {
		t.Fatalf("implement not claimed once plan doc present: %+v", res.Claimed)
	}
}

// TestQueueTickEvictionGuard: a pending request whose slug already has a live
// session on this instance is not claimed — claiming would silently replace the
// running session. The row stays pending and becomes claimable the moment the
// slug frees (slugLive reports false).
func TestQueueTickEvictionGuard(t *testing.T) {
	dir := t.TempDir()
	plantPending(t, dir, Request{RequestID: "impl-evict", Type: "spec", Slug: strp("busy-slug"), Initiator: "agent"})

	// The slug is live here: the claim is refused and the row stays pending.
	live := func(slug string) bool { return slug == "busy-slug" }
	res, _ := QueueTick(dir, "me", "", "", nil, noPlan, live, time.Now(), ReclaimAfter)
	if res.Claimed != nil {
		t.Fatalf("claimed a request whose slug is live — would evict the session: %+v", res.Claimed)
	}
	if len(ScanPending(dir)) != 1 {
		t.Fatal("eviction-guarded row should remain pending, not be consumed")
	}
	// Once the slug frees, the same row is claimable.
	res, _ = QueueTick(dir, "me", "", "", nil, noPlan, func(string) bool { return false }, time.Now(), ReclaimAfter)
	if res.Claimed == nil || res.Claimed.RequestID != "impl-evict" {
		t.Fatalf("row not claimed once the slug freed: %+v", res.Claimed)
	}
}

// TestQueueTickWorkerGates: a worker request carries the derived slug
// <work-item>--w<n>, distinct from the base work-item slug. It must be claimable
// while the base work item's own session is live (workers run concurrently with
// the lead), and it must NOT be plan-doc-gated (only implement is). Both follow
// from the derived slug being distinct — this pins that a base session going live
// never blocks its workers.
func TestQueueTickWorkerGates(t *testing.T) {
	dir := t.TempDir()
	plantPending(t, dir, Request{RequestID: "w1", Type: "worker", Slug: strp("impl-foo--w1"), Initiator: "agent"})

	// Base work item impl-foo is live; noPlan denies every plan-doc query. The
	// worker is still claimed: it is not implement (so not plan-gated) and its
	// derived slug is distinct from the live base slug (so not eviction-guarded).
	baseLive := func(slug string) bool { return slug == "impl-foo" }
	res, err := QueueTick(dir, "me", "", "", nil, noPlan, baseLive, time.Now(), ReclaimAfter)
	if err != nil {
		t.Fatal(err)
	}
	if res.Claimed == nil || res.Claimed.RequestID != "w1" {
		t.Fatalf("worker not claimed while base slug live / no plan doc: %+v", res.Claimed)
	}

	// The eviction guard still applies to the worker's own derived slug: a second
	// live session under that exact slug leaves an identical request pending.
	dir2 := t.TempDir()
	plantPending(t, dir2, Request{RequestID: "w1b", Type: "worker", Slug: strp("impl-foo--w1"), Initiator: "agent"})
	workerLive := func(slug string) bool { return slug == "impl-foo--w1" }
	res, _ = QueueTick(dir2, "me", "", "", nil, noPlan, workerLive, time.Now(), ReclaimAfter)
	if res.Claimed != nil {
		t.Fatalf("claimed a worker whose own derived slug is live — would evict it: %+v", res.Claimed)
	}
}

func TestQueueTickAbandonsAtAttemptCeiling(t *testing.T) {
	dir := t.TempDir()
	plantPending(t, dir, Request{RequestID: "dead1", Type: "spec", Slug: strp("x"), Initiator: "agent", Attempts: MaxAttempts})
	res, err := QueueTick(dir, "me", "", "", nil, noPlan, nil, time.Now(), ReclaimAfter)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Abandoned) != 1 || res.Abandoned[0].RequestID != "dead1" {
		t.Fatalf("attempts-ceiling row not abandoned: %+v", res.Abandoned)
	}
	if res.Claimed != nil {
		t.Fatal("abandoned row must not also be claimed")
	}
	if len(ScanPending(dir)) != 0 {
		t.Fatal("abandoned row should be deleted from pending")
	}
}

func TestQueueTickReclaimsIncompleteClaim(t *testing.T) {
	dir := t.TempDir()
	// A claimed row with no claim metadata, aged past the reclaim window. Target
	// it at another instance so it is reclaimed but not re-claimed here in the
	// same tick — isolating the reclaim transition under test.
	id := "incomplete1"
	if err := ClaimRequestFixture(t, dir, Request{RequestID: id, Type: "spec", Slug: strp("y"), Initiator: "agent", TargetInstance: strp("other")}); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-2 * ReclaimAfter)
	if err := os.Chtimes(claimedPath(dir, id), old, old); err != nil {
		t.Fatal(err)
	}
	res, err := QueueTick(dir, "me", "", "", nil, noPlan, nil, time.Now(), ReclaimAfter)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Reclaimed) != 1 || res.Reclaimed[0].Reason != ReasonIncompleteClaim {
		t.Fatalf("incomplete claim not reclaimed: %+v", res.Reclaimed)
	}
	// The row is back in pending carrying the reclaim reason and no claim fields.
	pend := ScanPending(dir)
	if len(pend) != 1 || pend[0].LastError == nil || *pend[0].LastError != ReasonIncompleteClaim {
		t.Fatalf("reclaimed row not returned to pending with reason: %+v", pend)
	}
	if pend[0].ClaimedBy != nil || pend[0].ClaimedAt != nil {
		t.Fatalf("reclaimed pending row still carries claim metadata: %+v", pend[0])
	}
}

func TestQueueTickReclaimsStaleClaimer(t *testing.T) {
	dir := t.TempDir()
	id := "stale1"
	// A completed claim whose claimer is dead and whose claim aged out.
	if err := ClaimRequestFixture(t, dir, Request{RequestID: id, Type: "spec", Slug: strp("z"), Initiator: "agent"}); err != nil {
		t.Fatal(err)
	}
	if _, err := WriteClaimMetadata(dir, id, "dead-instance"); err != nil {
		t.Fatal(err)
	}
	// Backdate claimed_at by rewriting the row.
	req, _ := ReadClaimed(dir, id)
	old := time.Now().Add(-2 * ReclaimAfter).UTC().Format("2006-01-02T15:04:05Z")
	req.ClaimedAt = &old
	if err := writeRow(claimedPath(dir, id), req); err != nil {
		t.Fatal(err)
	}
	// Claimer "dead-instance" is absent from the live set → reclaim.
	res, err := QueueTick(dir, "me", "", "", map[string]bool{"me": true}, noPlan, nil, time.Now(), ReclaimAfter)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Reclaimed) != 1 || res.Reclaimed[0].Reason != ReasonStaleInstance {
		t.Fatalf("stale claim not reclaimed: %+v", res.Reclaimed)
	}
}

func TestQueueTickLeavesLiveClaimerAlone(t *testing.T) {
	dir := t.TempDir()
	id := "live1"
	if err := ClaimRequestFixture(t, dir, Request{RequestID: id, Type: "spec", Slug: strp("z"), Initiator: "agent"}); err != nil {
		t.Fatal(err)
	}
	if _, err := WriteClaimMetadata(dir, id, "busy-instance"); err != nil {
		t.Fatal(err)
	}
	// The claimer is live → the claim must not be reclaimed even if aged.
	req, _ := ReadClaimed(dir, id)
	old := time.Now().Add(-2 * ReclaimAfter).UTC().Format("2006-01-02T15:04:05Z")
	req.ClaimedAt = &old
	_ = writeRow(claimedPath(dir, id), req)
	res, _ := QueueTick(dir, "me", "", "", map[string]bool{"me": true, "busy-instance": true}, noPlan, nil, time.Now(), ReclaimAfter)
	if len(res.Reclaimed) != 0 {
		t.Fatalf("reclaimed a live claimer's row: %+v", res.Reclaimed)
	}
}

func TestReturnToPendingBumpsAttempts(t *testing.T) {
	dir := t.TempDir()
	id := "retry1"
	if err := ClaimRequestFixture(t, dir, Request{RequestID: id, Type: "spec", Slug: strp("s"), Initiator: "agent", Attempts: 1}); err != nil {
		t.Fatal(err)
	}
	req, _ := ReadClaimed(dir, id)
	req.Attempts++
	reason := "pty_start_failed"
	req.LastError = &reason
	if err := ReturnToPending(dir, req); err != nil {
		t.Fatalf("ReturnToPending: %v", err)
	}
	pend := ScanPending(dir)
	if len(pend) != 1 || pend[0].Attempts != 2 {
		t.Fatalf("attempts not bumped on return: %+v", pend)
	}
	// The claimed row is gone (renamed away).
	if _, err := os.Stat(claimedPath(dir, id)); !os.IsNotExist(err) {
		t.Fatal("claimed row still present after ReturnToPending")
	}
}

// TestNumericFieldRejectsQuotedString guards the type-discipline contract: a
// strict decode of attempts rejects a quoted number rather than coercing it.
func TestNumericFieldRejectsQuotedString(t *testing.T) {
	var req Request
	if err := json.Unmarshal([]byte(`{"request_id":"x","type":"spec","attempts":"0"}`), &req); err == nil {
		t.Fatal("decoding attempts from a quoted string should fail")
	}
}

// TestExtraContextTextKeys pins the three keys ExtraContextText surfaces —
// "prompt" and "text" (explicit JSON callers) plus "dispatch_guidance", the key
// session-request.sh wraps a plain-text/file --context in. The last is
// load-bearing for worker sessions, whose whole brief arrives as a plain brief
// file. prompt wins over the others; an object with none returns "".
func TestExtraContextTextKeys(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want string
	}{
		{"prompt", `{"prompt":"p"}`, "p"},
		{"text", `{"text":"t"}`, "t"},
		{"dispatch_guidance", `{"dispatch_guidance":"the worker brief"}`, "the worker brief"},
		{"prompt wins over dispatch_guidance", `{"prompt":"p","dispatch_guidance":"g"}`, "p"},
		{"no recognized key", `{"other":"x"}`, ""},
		{"absent", ``, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := Request{}
			if tc.raw != "" {
				r.ExtraContext = json.RawMessage(tc.raw)
			}
			if got := r.ExtraContextText(); got != tc.want {
				t.Fatalf("ExtraContextText() = %q, want %q", got, tc.want)
			}
		})
	}
}

// TestRoutingOverridesRoundTrips guards the request-row amendment: routing_overrides
// decodes into the role→model map, and an absent field stays nil (omit-when-empty,
// so a marshal of an override-free row never emits the key).
func TestRoutingOverridesRoundTrips(t *testing.T) {
	var req Request
	if err := json.Unmarshal([]byte(`{"request_id":"x","type":"implement","routing_overrides":{"worker-mechanical":"haiku"}}`), &req); err != nil {
		t.Fatalf("decode routing_overrides: %v", err)
	}
	if got := req.RoutingOverrides["worker-mechanical"]; got != "haiku" {
		t.Fatalf("RoutingOverrides[worker-mechanical] = %q, want haiku", got)
	}

	data, err := json.Marshal(Request{RequestID: "x", Type: "spec"})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(data), "routing_overrides") {
		t.Errorf("absent overrides should be omitted, got %s", data)
	}
}

// TestDispatchFieldsRoundTrip guards the request-row amendment for the three
// dispatch-expressiveness fields: track, model, and skip_confirm each decode into
// their accessor/pointer, and an absent field stays absent on marshal
// (omit-when-empty), so a bare row never emits any of the three keys.
func TestDispatchFieldsRoundTrip(t *testing.T) {
	var req Request
	if err := json.Unmarshal([]byte(`{"request_id":"x","type":"spec","track":"short","model":"opus","skip_confirm":false}`), &req); err != nil {
		t.Fatalf("decode dispatch fields: %v", err)
	}
	if got := req.TrackValue(); got != "short" {
		t.Errorf("TrackValue = %q, want short", got)
	}
	if got := req.ModelValue(); got != "opus" {
		t.Errorf("ModelValue = %q, want opus", got)
	}
	if req.SkipConfirm == nil || *req.SkipConfirm != false {
		t.Errorf("SkipConfirm = %v, want a set false", req.SkipConfirm)
	}

	data, err := json.Marshal(Request{RequestID: "x", Type: "spec"})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	for _, key := range []string{"track", "model", "skip_confirm"} {
		if strings.Contains(string(data), key) {
			t.Errorf("absent %s should be omitted, got %s", key, data)
		}
	}
}

// TestSkipConfirmDistinguishesAbsentFromFalse guards the pointer semantics the
// queue-spawn default relies on: an absent skip_confirm decodes to nil (defers to
// the autonomous default), while an explicit false decodes to a set false (forces
// gated). Collapsing the two would silently flip a gated request to autonomous.
func TestSkipConfirmDistinguishesAbsentFromFalse(t *testing.T) {
	var absent Request
	if err := json.Unmarshal([]byte(`{"request_id":"x","type":"spec"}`), &absent); err != nil {
		t.Fatalf("decode absent: %v", err)
	}
	if absent.SkipConfirm != nil {
		t.Errorf("absent skip_confirm should decode to nil, got %v", *absent.SkipConfirm)
	}
	var explicit Request
	if err := json.Unmarshal([]byte(`{"request_id":"x","type":"spec","skip_confirm":false}`), &explicit); err != nil {
		t.Fatalf("decode explicit false: %v", err)
	}
	if explicit.SkipConfirm == nil {
		t.Fatal("explicit skip_confirm:false should decode to a set pointer, got nil")
	}
}

// TestQueueTickPreferProjectDir exercises the soft prefer_project_dir grace: a
// matching instance claims a preferring row immediately, a non-matching instance
// defers until the row ages past PreferMatchGrace (then claims), an unparseable
// requested_at degrades to claim-now (the preference only delays, never blocks),
// and a row with no preference is claimed immediately regardless of dir.
func TestQueueTickPreferProjectDir(t *testing.T) {
	const mine = "/work/mine"
	const other = "/work/other"
	now := time.Date(2026, 7, 13, 12, 0, 0, 0, time.UTC)
	iso := func(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05Z") }
	recent := iso(now.Add(-2 * time.Second)) // inside the 15s grace
	aged := iso(now.Add(-20 * time.Second))  // past the grace

	// A matching instance claims a preferring row immediately, inside the window.
	dir := t.TempDir()
	plantPending(t, dir, Request{RequestID: "p1", Type: "spec", Slug: strp("a"), Initiator: "agent",
		RequestedAt: recent, PreferProjectDir: strp(mine)})
	res, err := QueueTick(dir, "me", "", mine, map[string]bool{"me": true}, noPlan, nil, now, ReclaimAfter)
	if err != nil {
		t.Fatal(err)
	}
	if res.Claimed == nil || res.Claimed.RequestID != "p1" {
		t.Fatalf("matching instance did not claim preferring row immediately: %+v", res.Claimed)
	}

	// A non-matching instance leaves the same fresh row pending inside the window.
	dir = t.TempDir()
	plantPending(t, dir, Request{RequestID: "p2", Type: "spec", Slug: strp("b"), Initiator: "agent",
		RequestedAt: recent, PreferProjectDir: strp(mine)})
	res, _ = QueueTick(dir, "me", "", other, map[string]bool{"me": true}, noPlan, nil, now, ReclaimAfter)
	if res.Claimed != nil {
		t.Fatalf("non-matching instance claimed inside the grace window: %+v", res.Claimed)
	}
	if len(ScanPending(dir)) != 1 {
		t.Fatal("preferring row should remain pending for a non-matching instance inside the window")
	}

	// The same non-matching instance claims once the row has aged past the grace.
	dir = t.TempDir()
	plantPending(t, dir, Request{RequestID: "p3", Type: "spec", Slug: strp("c"), Initiator: "agent",
		RequestedAt: aged, PreferProjectDir: strp(mine)})
	res, _ = QueueTick(dir, "me", "", other, map[string]bool{"me": true}, noPlan, nil, now, ReclaimAfter)
	if res.Claimed == nil || res.Claimed.RequestID != "p3" {
		t.Fatalf("non-matching instance did not claim past the grace window: %+v", res.Claimed)
	}

	// An unparseable requested_at degrades to claim-now even for a non-matching
	// instance — the additive posture: a malformed timestamp never strands a row.
	dir = t.TempDir()
	plantPending(t, dir, Request{RequestID: "p4", Type: "spec", Slug: strp("d"), Initiator: "agent",
		RequestedAt: "not-a-timestamp", PreferProjectDir: strp(mine)})
	res, _ = QueueTick(dir, "me", "", other, map[string]bool{"me": true}, noPlan, nil, now, ReclaimAfter)
	if res.Claimed == nil || res.Claimed.RequestID != "p4" {
		t.Fatalf("unparseable requested_at did not degrade to claim-now: %+v", res.Claimed)
	}

	// A row with no preference is claimed immediately regardless of dir — today's
	// behavior is unchanged.
	dir = t.TempDir()
	plantPending(t, dir, Request{RequestID: "p5", Type: "spec", Slug: strp("e"), Initiator: "agent",
		RequestedAt: recent})
	res, _ = QueueTick(dir, "me", "", other, map[string]bool{"me": true}, noPlan, nil, now, ReclaimAfter)
	if res.Claimed == nil || res.Claimed.RequestID != "p5" {
		t.Fatalf("no-preference row was not claimed immediately: %+v", res.Claimed)
	}
}

// TestPreferProjectDirRoundTrips guards the request-row amendment: prefer_project_dir
// decodes into the pointer accessor, and an absent field is omitted on marshal.
func TestPreferProjectDirRoundTrips(t *testing.T) {
	var req Request
	if err := json.Unmarshal([]byte(`{"request_id":"x","type":"spec","prefer_project_dir":"/work/mine"}`), &req); err != nil {
		t.Fatalf("decode prefer_project_dir: %v", err)
	}
	if got := req.PreferProjectDirValue(); got != "/work/mine" {
		t.Fatalf("PreferProjectDirValue = %q, want the decoded path", got)
	}

	data, err := json.Marshal(Request{RequestID: "x", Type: "spec"})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(data), "prefer_project_dir") {
		t.Errorf("absent prefer_project_dir should be omitted, got %s", data)
	}
}

func TestWorktreeIdentityRoundTripsWithoutProjectionLoss(t *testing.T) {
	row := `{"request_id":"x","type":"spec","worktree_identity":{"version":1,"canonical_path":"/work/session","git_common_dir":"/repo/.git","git_dir":"/repo/.git/worktrees/session","epoch":"epoch-1","captured":{"canonical_path":"/repo","git_common_dir":"/repo/.git","git_dir":"/repo/.git","head_oid":"abc","index_digest":"index","worktree_digest":"tree"},"target_ref":"refs/heads/main","target_oid":"abc","state":"captured"}}`
	var req Request
	if err := json.Unmarshal([]byte(row), &req); err != nil {
		t.Fatalf("decode worktree_identity: %v", err)
	}
	if req.WorktreeIdentity == nil || req.WorktreeIdentity.CanonicalPath != "/work/session" || req.WorktreeIdentity.Epoch != "epoch-1" {
		t.Fatalf("worktree identity projection lost fields: %+v", req.WorktreeIdentity)
	}
	data, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var roundTripped map[string]json.RawMessage
	if err := json.Unmarshal(data, &roundTripped); err != nil {
		t.Fatalf("decode round trip: %v", err)
	}
	if got := string(roundTripped["worktree_identity"]); !strings.Contains(got, `"epoch":"epoch-1"`) || !strings.Contains(got, `"worktree_digest":"tree"`) {
		t.Fatalf("worktree identity did not survive round trip: %s", got)
	}
}

func noPlan(string) bool { return false }

// ClaimRequestFixture plants a pending row and renames it into claimed/ without
// writing claim metadata — the shape of an incomplete claim, and the setup other
// reclaim/metadata tests build on.
func ClaimRequestFixture(t *testing.T, dir string, req Request) error {
	t.Helper()
	if err := WritePending(dir, req); err != nil {
		return err
	}
	_, err := ClaimRequest(dir, req.RequestID)
	return err
}
