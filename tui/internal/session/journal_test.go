package session

import (
	"encoding/json"
	"math/rand"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"testing/quick"
)

// genEvent wraps Event with a generator that produces valid, roundtrip-safe rows
// for the property below.
type genEvent struct{ ev Event }

func (genEvent) Generate(r *rand.Rand, _ int) reflect.Value {
	events := []string{
		EventRequested, EventClaimed, EventSpawned, EventNeedsInput, EventQuiescent,
		EventResumed, EventClosed, EventStepCompleted, EventHarnessTurnEnded,
		EventSpawnFailed, EventReclaimed, EventAbandoned, EventCancelled,
		EventSendRequested, EventSent, EventSendRefused,
		EventReviewFlagged, EventReviewHeld, EventReviewNotified, EventReviewReleased,
	}
	tok := func() string { return string(rune('a'+r.Intn(26))) + string(rune('a'+r.Intn(26))) + "-x" }
	ev := Event{Event: events[r.Intn(len(events))]}
	if r.Intn(2) == 0 {
		ev.EventID = tok()
	}
	if r.Intn(2) == 0 {
		ev.TS = "2026-07-05T00:00:00Z"
	}
	if r.Intn(2) == 0 {
		ev.ActorInstance = StrPtr(tok())
	}
	if r.Intn(2) == 0 {
		ev.TargetInstance = StrPtr(tok())
	}
	if r.Intn(2) == 0 {
		ev.Slug = tok()
	}
	ev.SessionType = []string{"", "spec", "implement", "chat"}[r.Intn(4)]
	ev.Initiator = []string{"", "agent", "human"}[r.Intn(3)]
	if r.Intn(2) == 0 {
		ev.RequestID = tok()
	}
	if r.Intn(2) == 0 {
		ev.Reason = tok()
	}
	if r.Intn(2) == 0 {
		ev.Links = map[string]string{"work_item": tok()}
	}
	if r.Intn(2) == 0 {
		ev.Spend = json.RawMessage(`{"duration_seconds":5}`)
	}
	return reflect.ValueOf(genEvent{ev})
}

// TestEventRowRoundtrip is the serialization property: encoding an event row and
// decoding it back yields an equal value. Omit-when-empty optionals survive the
// trip because an absent field decodes to its zero value.
func TestEventRowRoundtrip(t *testing.T) {
	f := func(ge genEvent) bool {
		data, err := json.Marshal(ge.ev)
		if err != nil {
			return false
		}
		var back Event
		if err := json.Unmarshal(data, &back); err != nil {
			return false
		}
		return reflect.DeepEqual(ge.ev, back)
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 500}); err != nil {
		t.Error(err)
	}
}

// TestAppendEventThroughScript exercises the real sole-writer script end to end:
// a fixture `requested` row is appended and read back, confirming the Event
// shape conforms to the writer's contract and that provenance is stamped.
// Skipped when the script or jq is unavailable.
func TestAppendEventThroughScript(t *testing.T) {
	script := locateAppendScript(t)
	if script == "" {
		t.Skip("session-event-append.sh not found; skipping integration append")
	}
	kdir := t.TempDir()
	ev := Event{
		Event:         EventRequested,
		ActorInstance: StrPtr("amber-otter"),
		Slug:          "demo-slug",
		SessionType:   "spec",
		Initiator:     "agent",
		RequestID:     "20260705T000000Z-abcd1234",
	}
	if err := AppendEvent(script, kdir, ev); err != nil {
		t.Fatalf("AppendEvent: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(kdir, "_sessions", "events.jsonl"))
	if err != nil {
		t.Fatalf("read journal: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 1 {
		t.Fatalf("expected 1 journal row, got %d", len(lines))
	}
	var back Event
	if err := json.Unmarshal([]byte(lines[0]), &back); err != nil {
		t.Fatalf("decode journal row: %v", err)
	}
	if back.Event != EventRequested || back.RequestID != ev.RequestID {
		t.Fatalf("journal row mismatch: %+v", back)
	}
	if back.EventID == "" || back.TS == "" {
		t.Fatalf("writer did not stamp provenance: %+v", back)
	}
}

// TestScriptReviewVocabulary drives the real sole-writer script to cross-check
// the vocabulary the Go const block only mirrors: an out-of-set event is
// rejected, a work-item review event without a slug is rejected, and both
// close_requested and the review events (with a slug) are still accepted. It is
// the reject-path assertion the roundtrip property can't make — that test never
// calls the script, so an event added to the script alone would otherwise pass
// everything. close_requested is spelled as a literal because it has no Go
// const mirror; the point is to pin the script's behavior, not the mirror.
func TestScriptReviewVocabulary(t *testing.T) {
	script := locateAppendScript(t)
	if script == "" {
		t.Skip("session-event-append.sh not found; skipping vocabulary integration")
	}
	cases := []struct {
		name    string
		ev      Event
		wantErr bool
	}{
		{"out-of-set event rejected", Event{Event: "bogus_event", Slug: "demo-slug"}, true},
		{"review event without slug rejected", Event{Event: EventReviewFlagged}, true},
		{"review_held with slug accepted", Event{Event: EventReviewHeld, Slug: "demo-slug"}, false},
		{"review_released with slug accepted", Event{Event: EventReviewReleased, Slug: "demo-slug"}, false},
		{"close_requested with request_id accepted", Event{Event: "close_requested", RequestID: "20260705T000000Z-abcd1234"}, false},
		{"requested still accepted", Event{Event: EventRequested, RequestID: "20260705T000000Z-abcd1234"}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			kdir := t.TempDir()
			err := AppendEvent(script, kdir, tc.ev)
			rows := countJournalRows(t, kdir)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("event %q: expected rejection, got nil error", tc.ev.Event)
				}
				if rows != 0 {
					t.Fatalf("event %q: rejected row still left %d journal rows", tc.ev.Event, rows)
				}
				return
			}
			if err != nil {
				t.Fatalf("event %q: expected acceptance, got error: %v", tc.ev.Event, err)
			}
			if rows != 1 {
				t.Fatalf("event %q: accepted event wrote %d journal rows, want 1", tc.ev.Event, rows)
			}
		})
	}
}

// countJournalRows counts appended rows in the store's events journal. A missing
// journal counts as zero: the reject path fails validation before the script
// creates the _sessions directory, so a rejection leaves no file at all.
func countJournalRows(t *testing.T, kdir string) int {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(kdir, "_sessions", "events.jsonl"))
	if os.IsNotExist(err) {
		return 0
	}
	if err != nil {
		t.Fatalf("read journal: %v", err)
	}
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "" {
		return 0
	}
	return len(strings.Split(trimmed, "\n"))
}

func locateAppendScript(t *testing.T) string {
	t.Helper()
	candidates := []string{
		filepath.Join(os.Getenv("HOME"), ".lore/scripts/session-event-append.sh"),
		filepath.Join("..", "..", "..", "scripts", "session-event-append.sh"),
	}
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	return ""
}
