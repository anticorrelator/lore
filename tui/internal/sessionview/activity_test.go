package sessionview

import (
	"testing"

	"github.com/anticorrelator/lore/tui/internal/session"
)

func ev(name, actor, target, slug string) session.Event {
	e := session.Event{Event: name, Slug: slug}
	if actor != "" {
		e.ActorInstance = &actor
	}
	if target != "" {
		e.TargetInstance = &target
	}
	return e
}

// TestFoldEvents_ActivityLastWins verifies per-slug activity is matched by
// ordering: the last of needs_input/quiescent/resumed wins.
func TestFoldEvents_ActivityLastWins(t *testing.T) {
	got := FoldEvents(nil, []session.Event{
		ev(session.EventQuiescent, "inst-a", "", "foo"),
		ev(session.EventNeedsInput, "inst-a", "", "foo"),
		ev(session.EventResumed, "inst-a", "", "foo"),
	})
	a := got[ActivityKey{Instance: "inst-a", Slug: "foo"}]
	if a.NeedsInput || a.Quiescent {
		t.Errorf("resumed should clear needs-input and quiescent, got %+v", a)
	}

	got = FoldEvents(nil, []session.Event{
		ev(session.EventResumed, "inst-a", "", "foo"),
		ev(session.EventNeedsInput, "inst-a", "", "foo"),
	})
	if a := got[ActivityKey{Instance: "inst-a", Slug: "foo"}]; !a.NeedsInput {
		t.Errorf("last event (needs_input) should win, got %+v", a)
	}
}

// TestFoldEvents_ClosePendingMatchedByOrderingNotAdjacency verifies a
// close_requested with interleaved activity rows before its closed still clears
// only on the closed — the pair is matched by ordering per slug, never by the
// two rows being adjacent.
func TestFoldEvents_ClosePendingMatchedByOrderingNotAdjacency(t *testing.T) {
	events := []session.Event{
		ev(session.EventCloseRequested, "", "inst-a", "foo"),
		ev(session.EventNeedsInput, "inst-a", "", "foo"), // interleaved during teardown
		ev(session.EventQuiescent, "inst-a", "", "foo"),
	}
	got := FoldEvents(nil, events)
	if a := got[ActivityKey{Instance: "inst-a", Slug: "foo"}]; !a.ClosePending {
		t.Errorf("close should stay pending until closed arrives, got %+v", a)
	}

	got = FoldEvents(got, []session.Event{ev(session.EventClosed, "inst-a", "", "foo")})
	if _, present := got[ActivityKey{Instance: "inst-a", Slug: "foo"}]; present {
		t.Error("closed should drop the overlay entry (clears close-pending)")
	}
}

// TestFoldEvents_IncrementalAccumulation verifies a later fold builds on the
// prior map rather than starting fresh — the cursor-driven incremental read
// depends on this.
func TestFoldEvents_IncrementalAccumulation(t *testing.T) {
	first := FoldEvents(nil, []session.Event{ev(session.EventCloseRequested, "", "inst-a", "foo")})
	second := FoldEvents(first, []session.Event{ev(session.EventNeedsInput, "inst-b", "", "bar")})
	if !second[ActivityKey{Instance: "inst-a", Slug: "foo"}].ClosePending {
		t.Error("prior fold's close-pending should carry forward")
	}
	if !second[ActivityKey{Instance: "inst-b", Slug: "bar"}].NeedsInput {
		t.Error("new fold's needs-input should be present")
	}
	// The prior map must not be mutated.
	if _, leaked := first[ActivityKey{Instance: "inst-b", Slug: "bar"}]; leaked {
		t.Error("FoldEvents must not mutate the prev map")
	}
}

func TestNextAction_Precedence(t *testing.T) {
	if got := (Activity{NeedsInput: true, ClosePending: true}).NextAction(); got != "needs input" {
		t.Errorf("needs-input should outrank close-pending, got %q", got)
	}
	if got := (Activity{ClosePending: true}).NextAction(); got != "close pending" {
		t.Errorf("close-pending label, got %q", got)
	}
	if got := (Activity{Quiescent: true}).NextAction(); got != "" {
		t.Errorf("quiescent alone has no pending action, got %q", got)
	}
}
