package main

import (
	"crypto/sha256"
	"fmt"
	"time"

	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

func (m model) hostSpawnName(requestID string) string {
	sum := sha256.Sum256([]byte(m.instanceName + "\x00" + requestID))
	return fmt.Sprintf("spawn-%x", sum[:16])
}
func (m model) hostSpawnCheckpoint(requestID string, checkpointIDs ...string) func(work.SessionDescriptor, string, string, string, int) error {
	// A separate instance row avoids concurrent spawns overwriting one another.
	// It has the same PID/host/source fences, and is recoverable before the normal
	// SessionProcessStartedMsg is received or its registry write finishes.
	row := m.instanceRow()
	checkpointID := requestID
	if len(checkpointIDs) > 0 {
		checkpointID = checkpointIDs[0]
	}
	row.Name = m.hostSpawnName(checkpointID)
	row.Role = "session-host-spawn"
	// The checkpoint names the checkout its launch was seeded from, which a
	// store host takes per request; its own row names no checkout.
	sourceDir := row.ProjectDir
	// The session's own start time, which its pane's generation was computed
	// from, so a session adopted from this row keeps that generation.
	started := row.Started
	for _, pending := range m.pendingSpawns {
		if pending.checkpointID != checkpointID {
			continue
		}
		if pending.sourceDir != "" {
			sourceDir = pending.sourceDir
		}
		if !pending.started.IsZero() {
			started = pending.started.UTC().Format("2006-01-02T15:04:05Z")
		}
	}
	return func(d work.SessionDescriptor, harness, id, tmux string, pid int) error {
		row.Revision = time.Now().UnixNano()
		row.Sessions = []session.Session{{Slug: d.Slug, Type: sessionType(d.Type), Initiator: d.Initiator, Started: started, RequestID: requestID, Harness: harness, SessionID: id, Tmux: tmux, PID: pid, Worktree: cloneWorktreeIdentity(d.Worktree), WorktreeID: d.WorktreeID, ExecutionDir: d.ExecutionDir, SourceDir: sourceDir, AutoClose: d.AutoClose}}
		if err := session.WriteInstance(m.sessionsDir, row); err != nil {
			return err
		}
		return m.clearHostAllocation(requestID)
	}
}
func (m model) clearHostSpawn(requestID string) error {
	return session.RemoveInstance(m.sessionsDir, m.hostSpawnName(requestID))
}
