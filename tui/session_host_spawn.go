package main

import (
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

func (m model) hostSpawnName(requestID string) string {
	sum := sha256.Sum256([]byte(m.instanceName + "\x00" + requestID))
	return fmt.Sprintf("spawn-%x", sum[:16])
}
func (m model) hostSpawnCheckpoint(requestID string) func(work.SessionDescriptor, string, string, string, int) error {
	// A separate instance row avoids concurrent spawns overwriting one another.
	// It has the same PID/host/source fences, and is recoverable before the normal
	// SessionProcessStartedMsg is received or its registry write finishes.
	row := m.instanceRow()
	row.Name = m.hostSpawnName(requestID)
	row.Role = "session-host-spawn"
	return func(d work.SessionDescriptor, harness, id, tmux string, pid int) error {
		row.Revision = time.Now().UnixNano()
		row.Sessions = []session.Session{{Slug: d.Slug, Type: sessionType(d.Type), Initiator: d.Initiator, Started: row.Started, RequestID: requestID, Harness: harness, SessionID: id, Tmux: tmux, PID: pid, Worktree: cloneWorktreeIdentity(d.Worktree), WorktreeID: d.WorktreeID, ExecutionDir: d.ExecutionDir, SourceDir: row.ProjectDir, AutoClose: d.AutoClose}}
		if err := session.WriteInstance(m.sessionsDir, row); err != nil {
			return err
		}
		return m.clearHostAllocation(requestID)
	}
}
func (m model) clearHostSpawn(requestID string) error {
	err := os.Remove(filepath.Join(session.InstancesDir(m.sessionsDir), m.hostSpawnName(requestID)+".json"))
	if os.IsNotExist(err) {
		return nil
	}
	return err
}
