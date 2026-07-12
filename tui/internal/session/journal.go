package session

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"syscall"
)

// Event is one row appended to _sessions/events.jsonl. event_id, ts, and links
// are stamped by the sole-writer script when absent, so emitters leave them
// empty; the closed event vocabulary is validated there too. Queue-lifecycle
// events (requested, claimed, spawned, spawn_failed, request_reclaimed,
// request_abandoned, request_cancelled) MUST carry a non-empty RequestID.
type Event struct {
	EventID        string            `json:"event_id,omitempty"`
	TS             string            `json:"ts,omitempty"`
	Event          string            `json:"event"`
	ActorInstance  *string           `json:"actor_instance,omitempty"`
	TargetInstance *string           `json:"target_instance,omitempty"`
	Slug           string            `json:"slug,omitempty"`
	SessionType    string            `json:"session_type,omitempty"`
	Initiator      string            `json:"initiator,omitempty"`
	RequestID      string            `json:"request_id,omitempty"`
	Reason         string            `json:"reason,omitempty"`
	Links          map[string]string `json:"links,omitempty"`
	Spend          json.RawMessage   `json:"spend,omitempty"`
}

// The closed set of event names, mirrored from the writer script and the
// substrate contract. Used for cheap client-side classification only; the
// script remains the sole validator.
const (
	EventRequested        = "requested"
	EventClaimed          = "claimed"
	EventSpawned          = "spawned"
	EventNeedsInput       = "needs_input"
	EventQuiescent        = "quiescent"
	EventResumed          = "resumed"
	EventModalBlocked     = "modal_blocked"
	EventRecovered        = "recovered"
	EventClosed           = "closed"
	EventOrphaned         = "orphaned"
	EventStepCompleted    = "step_completed"
	EventTerminusReached  = "terminus_reached"
	EventHarnessTurnEnded = "harness_turn_ended"
	EventSpawnFailed      = "spawn_failed"
	EventReclaimed        = "request_reclaimed"
	EventAbandoned        = "request_abandoned"
	EventCancelled        = "request_cancelled"
	EventSendRequested    = "send_requested"
	EventSent             = "sent"
	EventSendRefused      = "send_refused"
	EventCloseRequested   = "close_requested"
	EventCloseFailed      = "close_failed"

	// Work-item review events — a third class the writer keys to a work-item
	// slug (not a request_id), so a row carrying one of these MUST set Slug.
	EventReviewFlagged  = "review_flagged"
	EventReviewHeld     = "review_held"
	EventReviewNotified = "review_notified"
	EventReviewReleased = "review_released"
)

// AppendEvent emits one journal row by piping it into the sole-writer script
// `session-event-append.sh` (scriptPath), targeting the store at kdir. The
// script validates, stamps provenance, and appends; a non-zero exit is returned
// as an error naming the offending field so the caller can surface it.
func AppendEvent(scriptPath, kdir string, ev Event) error {
	row, err := json.Marshal(ev)
	if err != nil {
		return fmt.Errorf("marshal event: %w", err)
	}
	cmd := exec.Command("bash", scriptPath, "--kdir", kdir)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Stdin = bytes.NewReader(row)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("session-event-append failed (%s): %s", err, strings.TrimSpace(out.String()))
	}
	return nil
}

// StrPtr returns a pointer to s, or nil when s is empty — the shape the nullable
// actor_instance/target_instance fields want.
func StrPtr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}
