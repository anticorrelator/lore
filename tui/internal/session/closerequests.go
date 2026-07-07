package session

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// CloseRequest is one close-request row at close-requests/<request_id>.json,
// written by scripts/session-close.sh (bash) and read here (Go). Per the
// substrate contract the schema is {request_id, slug, target_instance, reason,
// requested_by, requested_at}, plus an optional session_id. Unlike the spawn
// queue there is no pending/claimed split: exactly one instance (the one whose
// registry runs the slug's session) is ever eligible, so there is no claim
// race — the owning instance consumes the row by deleting it after initiating
// teardown.
//
// Every field is a string, so a strict decoder has no numeric coercion to
// guard; unknown fields are tolerated (default json behavior) so a
// forward-extended writer never breaks this reader. An absent session_id
// (every row written before the field existed) decodes to "", which the
// consumer reads as the slug-key close-matching it always used.
type CloseRequest struct {
	RequestID      string `json:"request_id"`
	Slug           string `json:"slug"`
	TargetInstance string `json:"target_instance"`
	Reason         string `json:"reason"` // protocol_terminus|coordinator|human
	RequestedBy    string `json:"requested_by"`
	RequestedAt    string `json:"requested_at"`
	// SessionID, when set, names the exact harness session the close addresses —
	// the full id or the leading prefix a coordinator passed to `close --session`.
	// It is the only handle that disambiguates a slugless session, so the consumer
	// matches it against each hosted session's id before falling back to the slug.
	SessionID string `json:"session_id,omitempty"`
}

// CloseRequestsDir is the close-request surface under a _sessions/ directory.
func CloseRequestsDir(sessionsDir string) string {
	return filepath.Join(sessionsDir, "close-requests")
}

func closeRequestPath(sessionsDir, id string) string {
	return filepath.Join(CloseRequestsDir(sessionsDir), id+".json")
}

// ScanCloseRequests reads every close-request row, excluding torn/corrupt files
// with a warning to stderr rather than aborting the scan (reader contract: a
// malformed row is excluded-with-warning, never repaired or deleted-as-consume).
// An absent directory yields no rows and no error.
func ScanCloseRequests(sessionsDir string) []CloseRequest {
	matches, err := filepath.Glob(filepath.Join(CloseRequestsDir(sessionsDir), "*.json"))
	if err != nil {
		return nil
	}
	var out []CloseRequest
	for _, path := range matches {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var cr CloseRequest
		if err := json.Unmarshal(data, &cr); err != nil {
			fmt.Fprintf(os.Stderr, "[session] warning: %s corrupt — %v\n", path, err)
			continue
		}
		out = append(out, cr)
	}
	return out
}

// DeleteCloseRequest removes a consumed close-request row. Idempotent: a missing
// file is not an error (the owning instance is the sole consumer, but a crash
// could race a re-scan).
func DeleteCloseRequest(sessionsDir, requestID string) error {
	err := os.Remove(closeRequestPath(sessionsDir, requestID))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}
