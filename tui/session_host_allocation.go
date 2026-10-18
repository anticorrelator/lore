package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
	"github.com/anticorrelator/lore/tui/internal/worktree"
)

type hostAllocation struct {
	RequestID   string                    `json:"request_id"`
	Slug        string                    `json:"slug"`
	Type        string                    `json:"session_type"`
	Intent      worktree.AllocationIntent `json:"intent"`
	Quarantined *worktree.Identity        `json:"quarantined,omitempty"`
	Outcome     *session.Event            `json:"outcome,omitempty"`
}

func (m model) hostAllocationPath(id string) string {
	return filepath.Join(m.hostDir(), "allocations", id+".json")
}
func (m model) clearHostAllocation(id string) error {
	err := os.Remove(m.hostAllocationPath(id))
	if os.IsNotExist(err) {
		return nil
	}
	return err
}
func (m model) hostAllocationCheckpoint(id string, d work.SessionDescriptor) func(worktree.AllocationIntent) error {
	return func(intent worktree.AllocationIntent) error {
		if m.hostKey == "" {
			return nil
		}
		return hostAtomicJSON(m.hostAllocationPath(id), hostAllocation{RequestID: id, Slug: d.Slug, Type: d.Type, Intent: intent})
	}
}

// recoverHostAllocations settles every allocation record at startup, before
// this process has launched anything. A record whose request a row of one of
// keys lists was launched, so it is cleared; any other record is a launch that
// never reached the harness, so its checkout is quarantined and removed.
func (m model) recoverHostAllocations(keys map[string]bool) error {
	return m.recoverHostAllocationsExcept(keys, nil)
}

// recoverHostAllocationsExcept is recoverHostAllocations for a host that is
// already serving: inFlight names requests whose launch this process is still
// running, whose records are not this pass's to settle.
func (m model) recoverHostAllocationsExcept(keys map[string]bool, inFlight func(requestID string) bool) error {
	paths, err := filepath.Glob(filepath.Join(m.hostDir(), "allocations", "*.json"))
	if err != nil {
		return err
	}
	if len(paths) == 0 {
		return nil
	}
	owners, err := session.OwnershipInstances(m.sessionsDir)
	if err != nil {
		return err
	}
	launched := map[string]bool{}
	for _, owner := range owners {
		// A store host's rows name no checkout; the key alone scopes them.
		if keys[owner.HostKey] {
			for _, s := range owner.Sessions {
				launched[s.RequestID] = true
			}
		}
	}
	for _, path := range paths {
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		var a hostAllocation
		if err = json.Unmarshal(b, &a); err != nil {
			return err
		}
		if inFlight != nil && inFlight(a.RequestID) {
			continue
		}
		if err = m.settleHostAllocation(path, a, launched[a.RequestID]); err != nil {
			return err
		}
	}
	return nil
}

func (m model) settleHostAllocation(path string, a hostAllocation, launched bool) error {
	var err error
	if !launched {
		if a.Quarantined == nil {
			if _, err = os.Lstat(a.Intent.Path); err == nil {
				identity, artifact, err := worktree.RecoverAllocation(context.Background(), a.Intent)
				if err != nil {
					return err
				}
				ev := worktreeOutcomeEvent(m.instanceName, a.Slug, liveSession{typ: a.Type, initiator: "agent"}, worktree.PublishOutcome{Kind: worktree.OutcomeWorktreeQuarantined, Identity: identity, Artifact: artifact, Reason: "interrupted before harness launch"})
				a.Quarantined = &identity
				a.Outcome = &ev
				if err = hostAtomicJSON(path, a); err != nil {
					return err
				}
			} else if !os.IsNotExist(err) {
				return err
			}
		}
		if a.Quarantined != nil && a.Outcome != nil {
			cmd, err := m.hostWorktreeOutcome(*a.Outcome, a.Quarantined.Epoch)
			if err != nil {
				return err
			}
			if result := cmd().(journalResultMsg); result.err != nil {
				return result.err
			}
			// A checkout whose content is not proven preserved stays on disk; the
			// sweep reports it as retained. Only a removal that started and failed
			// stops recovery.
			if _, err = worktree.CleanupSessionCheckout(context.Background(), *a.Quarantined); err != nil && !errors.Is(err, worktree.ErrContentUnproven) {
				return err
			}
		}
	}
	return m.clearHostAllocation(a.RequestID)
}
