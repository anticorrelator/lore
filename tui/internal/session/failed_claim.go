package session

import (
	"os"
	"path/filepath"
)

// ArchiveFailedClaim retains the original intent and full failure before taking
// a deterministic refusal out of circulation. The journal uses request_abandoned.
func ArchiveFailedClaim(dir string, req Request) error {
	if err := os.MkdirAll(filepath.Join(dir, "requests", "abandoned"), 0755); err != nil {
		return err
	}
	if err := writeRow(filepath.Join(dir, "requests", "abandoned", req.RequestID+".json"), req); err != nil {
		return err
	}
	return DeleteClaimed(dir, req.RequestID)
}

// ArchiveRejectedPending atomically removes an unlaunchable intent from claim
// circulation. The archive retains it for repair without inventing an attempt.
func ArchiveRejectedPending(dir string, req Request) (bool, error) {
	dest := filepath.Join(dir, "requests", "abandoned", req.RequestID+".json")
	if err := os.MkdirAll(filepath.Dir(dest), 0755); err != nil {
		return false, err
	}
	if err := os.Rename(pendingPath(dir, req.RequestID), dest); err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	if err := writeRow(dest, req); err != nil {
		return true, err
	}
	return true, nil
}
