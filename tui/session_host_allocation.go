package main

import (
	"context"
	"encoding/json"
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
	return filepath.Join(m.sessionsDir, "hosts", m.hostKey, "allocations", id+".json")
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
func (m model) recoverHostAllocations() error {
	paths, err := filepath.Glob(filepath.Join(m.sessionsDir, "hosts", m.hostKey, "allocations", "*.json"))
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
		if owner.HostKey == m.hostKey && owner.ProjectDir == m.normalizedProjectDir {
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

		if !launched[a.RequestID] {
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
				if _, err = worktree.CleanupSessionCheckout(context.Background(), *a.Quarantined); err != nil {
					return err
				}
			}
		}

		if err = m.clearHostAllocation(a.RequestID); err != nil {
			return err
		}
	}
	return nil
}
