package session

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

// SendRequest is one send-request row at send-requests/<request_id>.json,
// written by scripts/session-send.sh (bash) and read here (Go). A send-request
// asks the one live instance running a slug to inject Body into that session's
// composer. Like close-requests there is no pending/claimed split: exactly one
// instance (the one whose registry hosts the slug) is ever eligible, so the
// owning instance consumes the row by deleting it after running the readiness
// gate. Unknown fields are tolerated so a forward-extended writer never breaks
// this reader.
type SendRequest struct {
	RequestID      string `json:"request_id"`
	Slug           string `json:"slug"`
	TargetInstance string `json:"target_instance"`
	Body           string `json:"body"`
	RequestedBy    string `json:"requested_by"`
	RequestedAt    string `json:"requested_at"`
}

// SendRequestsDir is the send-request surface under a _sessions/ directory.
func SendRequestsDir(sessionsDir string) string {
	return filepath.Join(sessionsDir, "send-requests")
}

func sendRequestPath(sessionsDir, id string) string {
	return filepath.Join(SendRequestsDir(sessionsDir), id+".json")
}

// ScanSendRequests reads every valid send-request row and discards scan
// diagnostics. An absent directory yields no rows and no error.
func ScanSendRequests(sessionsDir string) []SendRequest {
	rows, _ := ScanSendRequestsWithDiagnostics(sessionsDir)
	return rows
}

// ScanSendRequestsWithDiagnostics returns valid rows and corrupt-row exclusions.
func ScanSendRequestsWithDiagnostics(sessionsDir string) ([]SendRequest, []Diagnostic) {
	matches, err := filepath.Glob(filepath.Join(SendRequestsDir(sessionsDir), "*.json"))
	if err != nil {
		return nil, nil
	}
	var out []SendRequest
	var diagnostics []Diagnostic
	for _, path := range matches {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var sr SendRequest
		if err := json.Unmarshal(data, &sr); err != nil {
			diagnostics = append(diagnostics, corruptDiagnostic("send-request", path, err))
			continue
		}
		out = append(out, sr)
	}
	return out, diagnostics
}

// DeleteSendRequest removes a consumed send-request row. Idempotent: a missing
// file is not an error (the owning instance is the sole consumer, but a crash
// could race a re-scan).
func DeleteSendRequest(sessionsDir, requestID string) error {
	err := os.Remove(sendRequestPath(sessionsDir, requestID))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}
