// Package sessionview renders the first-class sessions workspace: a list of
// every live session (local, cross-instance, and in-flight) keyed by session
// identity, plus a read-only detail card for rows with no local panel to attach.
// It is a consumer of the shared collection list+detail machinery and of the
// session substrate reads; it never writes the substrate.
package sessionview

import "github.com/anticorrelator/lore/tui/internal/session"

// Activity is the journal-derived state overlay for one (instance, slug)
// session. The registry row carries existence only — never activity — so this
// is the only source that surfaces a needs-input or close-pending session, the
// state the option-modal incident left invisible.
type Activity struct {
	NeedsInput   bool
	Quiescent    bool
	ClosePending bool
}

// ActivityKey identifies the session an activity overlay entry describes. It is
// (owning-instance, slug): the running instance for activity events, the target
// instance for a close request. A slugless session keys on an empty slug, so two
// co-resident slugless sessions on one instance share an entry — the known
// consumer-side collision this pass does not fix.
type ActivityKey struct {
	Instance string
	Slug     string
}

// NextAction names the operator's next required action for this session, or ""
// when none is pending. It is the badge label — the workflow-UI convention is to
// name the action, not the internal state ("needs input", not "quiescent").
// needs-input outranks close-pending: a blocked prompt is what stalls a close.
func (a Activity) NextAction() string {
	switch {
	case a.NeedsInput:
		return "needs input"
	case a.ClosePending:
		return "close pending"
	default:
		return ""
	}
}

// FoldEvents folds new journal rows into the running activity overlay, returning
// a fresh map (prev is not mutated). Activity is matched per (instance, slug) by
// ordering — the last of needs_input/quiescent/resumed for a slug wins — never
// by adjacency: teardown interleaves activity rows between close_requested and
// closed, so the pair is matched by a later `closed` clearing the entry, not by
// the two rows being consecutive.
func FoldEvents(prev map[ActivityKey]Activity, events []session.Event) map[ActivityKey]Activity {
	out := make(map[ActivityKey]Activity, len(prev)+len(events))
	for k, v := range prev {
		out[k] = v
	}
	for _, ev := range events {
		switch ev.Event {
		case session.EventNeedsInput:
			k := ActivityKey{Instance: actor(ev), Slug: ev.Slug}
			a := out[k]
			a.NeedsInput = true
			a.Quiescent = true
			out[k] = a
		case session.EventQuiescent:
			k := ActivityKey{Instance: actor(ev), Slug: ev.Slug}
			a := out[k]
			a.Quiescent = true
			out[k] = a
		case session.EventResumed:
			k := ActivityKey{Instance: actor(ev), Slug: ev.Slug}
			a := out[k]
			a.NeedsInput = false
			a.Quiescent = false
			out[k] = a
		case session.EventCloseRequested:
			k := ActivityKey{Instance: target(ev), Slug: ev.Slug}
			a := out[k]
			a.ClosePending = true
			out[k] = a
		case session.EventClosed, session.EventOrphaned:
			// The session ended: drop the whole overlay entry. close_requested
			// keyed on target_instance and closed on actor_instance name the same
			// owning instance, so the pending-close set clears here.
			delete(out, ActivityKey{Instance: actor(ev), Slug: ev.Slug})
			delete(out, ActivityKey{Instance: target(ev), Slug: ev.Slug})
		}
	}
	return out
}

func actor(ev session.Event) string {
	if ev.ActorInstance == nil {
		return ""
	}
	return *ev.ActorInstance
}

func target(ev session.Event) string {
	if ev.TargetInstance == nil {
		return ""
	}
	return *ev.TargetInstance
}
