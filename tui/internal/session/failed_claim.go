package session

import (
	"fmt"
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

// ArchiveRejectedPending saves the diagnosis before competing with claimers for
// the pending row. Only the winner can publish the terminal archive.
func ArchiveRejectedPending(dir string, req Request) (bool, error) {
	staging := filepath.Join(dir, "requests", "rejecting")
	if err := os.MkdirAll(staging, 0755); err != nil {
		return false, err
	}
	stage, err := os.MkdirTemp(staging, "refusal-")
	if err != nil {
		return false, err
	}
	if err := writeRow(filepath.Join(stage, "request.json"), req); err != nil {
		os.RemoveAll(stage)
		return false, err
	}
	if err := os.Rename(pendingPath(dir, req.RequestID), filepath.Join(stage, "original.json")); err != nil {
		os.RemoveAll(stage)
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	// A failed/interrupted final rename leaves both original intent and its
	// diagnosis in rejecting; the next queue pass completes this transition.
	err = finishRejectedPending(dir, stage, req)
	if os.IsNotExist(err) {
		return false, nil // a concurrent recovery pass completed it
	}
	return true, err
}

func finishRejectedPending(dir, stage string, req Request) error {
	dest := filepath.Join(dir, "requests", "abandoned", req.RequestID+".json")
	if err := os.MkdirAll(filepath.Dir(dest), 0755); err != nil {
		return err
	}
	if err := os.Rename(filepath.Join(stage, "request.json"), dest); err != nil {
		return err
	}
	os.RemoveAll(stage)
	return nil
}

func recoverRejectedPending(dir string) ([]TransitionEvent, error) {
	stages, err := os.ReadDir(filepath.Join(dir, "requests", "rejecting"))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var events []TransitionEvent
	for _, entry := range stages {
		if !entry.IsDir() {
			continue
		}
		stage := filepath.Join(dir, "requests", "rejecting", entry.Name())
		if _, err := os.Stat(filepath.Join(stage, "original.json")); os.IsNotExist(err) {
			continue // preparing, or another reader already completed it
		} else if err != nil {
			return events, err
		}
		req, diagnostic, ok := readRow(filepath.Join(stage, "request.json"), "session-admission")
		if !ok {
			if _, err := os.Stat(filepath.Join(stage, "request.json")); os.IsNotExist(err) {
				continue // another reader won the final rename
			}
			return events, fmt.Errorf("recover rejection: %v", diagnostic)
		}
		if err := finishRejectedPending(dir, stage, req); os.IsNotExist(err) {
			continue
		} else if err != nil {
			return events, err
		}
		reason := ""
		if req.LastError != nil {
			reason = *req.LastError
		}
		events = append(events, TransitionEvent{RequestID: req.RequestID, Reason: reason, Slug: req.SessionSlug(), SessionType: req.Type, Initiator: req.Initiator})
	}
	return events, nil
}
