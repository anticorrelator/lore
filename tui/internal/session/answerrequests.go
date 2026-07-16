package session

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

// AnswerRequest is one expectation-guarded numbered modal choice addressed to
// the instance hosting Slug. Unknown fields are tolerated for forward-compatible
// queue rows; the consumer validates the live screen before writing any keys.
type AnswerRequest struct {
	RequestID      string `json:"request_id"`
	Slug           string `json:"slug"`
	TargetInstance string `json:"target_instance"`
	Option         int    `json:"option"`
	Expect         string `json:"expect"`
	RequestedBy    string `json:"requested_by"`
	RequestedAt    string `json:"requested_at"`
}

// AnswerRequestsDir is the answer-request surface under a _sessions/ directory.
func AnswerRequestsDir(sessionsDir string) string {
	return filepath.Join(sessionsDir, "answer-requests")
}

func answerRequestPath(sessionsDir, id string) string {
	return filepath.Join(AnswerRequestsDir(sessionsDir), id+".json")
}

// ScanAnswerRequests reads valid rows and discards scan diagnostics.
func ScanAnswerRequests(sessionsDir string) []AnswerRequest {
	rows, _ := ScanAnswerRequestsWithDiagnostics(sessionsDir)
	return rows
}

// ScanAnswerRequestsWithDiagnostics returns valid rows and corrupt-row exclusions.
func ScanAnswerRequestsWithDiagnostics(sessionsDir string) ([]AnswerRequest, []Diagnostic) {
	matches, err := filepath.Glob(filepath.Join(AnswerRequestsDir(sessionsDir), "*.json"))
	if err != nil {
		return nil, nil
	}
	var out []AnswerRequest
	var diagnostics []Diagnostic
	for _, path := range matches {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var request AnswerRequest
		if err := json.Unmarshal(data, &request); err != nil {
			diagnostics = append(diagnostics, corruptDiagnostic("answer-request", path, err))
			continue
		}
		out = append(out, request)
	}
	return out, diagnostics
}

// DeleteAnswerRequest removes a consumed row. Missing files are already consumed.
func DeleteAnswerRequest(sessionsDir, requestID string) error {
	err := os.Remove(answerRequestPath(sessionsDir, requestID))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}
