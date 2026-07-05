package session

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// PeekRequest is one peek-request row at peek-requests/<request_id>.json,
// written by scripts/session-peek.sh (bash) and read here (Go). A peek-request
// asks the one live instance running a slug to snapshot that session's screen.
// Raw selects the ANSI variant in the response. Peek is a read, not a lifecycle
// transition, so it emits no journal events.
type PeekRequest struct {
	RequestID      string `json:"request_id"`
	Slug           string `json:"slug"`
	TargetInstance string `json:"target_instance"`
	Raw            bool   `json:"raw"`
	RequestedBy    string `json:"requested_by"`
	RequestedAt    string `json:"requested_at"`
}

// PeekResponse is the substrate's first addressed-response payload, written by
// the owning instance at peek-responses/<request_id>.json (tmp+atomic-rename)
// and consumed (deleted) by the requesting CLI. Rows are the plain-text screen
// rows from the same snapshot the readiness gate uses; Ready/BlockedReason carry
// that gate's classification. ANSI is populated only when the request set Raw.
type PeekResponse struct {
	RequestID     string   `json:"request_id"`
	Slug          string   `json:"slug"`
	CapturedAt    string   `json:"captured_at"`
	Ready         bool     `json:"ready"`
	BlockedReason string   `json:"blocked_reason,omitempty"`
	Rows          []string `json:"rows"`
	ANSI          string   `json:"ansi,omitempty"`
}

// PeekRequestsDir is the peek-request surface under a _sessions/ directory.
func PeekRequestsDir(sessionsDir string) string {
	return filepath.Join(sessionsDir, "peek-requests")
}

// PeekResponsesDir is the peek-response surface under a _sessions/ directory.
func PeekResponsesDir(sessionsDir string) string {
	return filepath.Join(sessionsDir, "peek-responses")
}

func peekRequestPath(sessionsDir, id string) string {
	return filepath.Join(PeekRequestsDir(sessionsDir), id+".json")
}

func peekResponsePath(sessionsDir, id string) string {
	return filepath.Join(PeekResponsesDir(sessionsDir), id+".json")
}

// ScanPeekRequests reads every peek-request row, excluding torn/corrupt files
// with a warning to stderr rather than aborting the scan. An absent directory
// yields no rows and no error.
func ScanPeekRequests(sessionsDir string) []PeekRequest {
	matches, err := filepath.Glob(filepath.Join(PeekRequestsDir(sessionsDir), "*.json"))
	if err != nil {
		return nil
	}
	var out []PeekRequest
	for _, path := range matches {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var pr PeekRequest
		if err := json.Unmarshal(data, &pr); err != nil {
			fmt.Fprintf(os.Stderr, "[session] warning: %s corrupt — %v\n", path, err)
			continue
		}
		out = append(out, pr)
	}
	return out
}

// DeletePeekRequest removes a consumed peek-request row. Idempotent.
func DeletePeekRequest(sessionsDir, requestID string) error {
	err := os.Remove(peekRequestPath(sessionsDir, requestID))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// WritePeekResponse writes one peek-response via tmp+atomic-rename so the
// polling requester never reads a torn row. The owning instance is the sole
// writer of a given response file; the requester is the sole reader-and-deleter.
func WritePeekResponse(sessionsDir string, resp PeekResponse) error {
	dir := PeekResponsesDir(sessionsDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	data, err := json.Marshal(resp)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".tmp."+resp.RequestID+".*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return err
	}
	return os.Rename(tmpName, peekResponsePath(sessionsDir, resp.RequestID))
}

// GCPeekResponses removes peek-responses older than maxAge by mtime. The
// requester deletes its own response on read (delete-on-read); this reclaims the
// rare orphan left when a requester timed out and exited before its response
// landed. Silently tolerates an absent directory and per-file stat/remove races.
func GCPeekResponses(sessionsDir string, maxAge time.Duration) {
	matches, err := filepath.Glob(filepath.Join(PeekResponsesDir(sessionsDir), "*.json"))
	if err != nil {
		return
	}
	cutoff := time.Now().Add(-maxAge)
	for _, path := range matches {
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		if info.ModTime().Before(cutoff) {
			os.Remove(path)
		}
	}
}
