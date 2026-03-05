package work

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"
)

// sessionFileName is the name of the lock file written inside each work-item directory.
const sessionFileName = ".lore-session"

// sessionStaleTTL is the duration after which a session file is considered stale.
const sessionStaleTTL = 30 * time.Second

// SessionInfo describes an active TUI session operating on a work item.
type SessionInfo struct {
	PID      int       `json:"pid"`
	Mode     string    `json:"mode"`
	Slug     string    `json:"slug"`
	Started  time.Time `json:"started"`
	LastSeen time.Time `json:"last_seen"`
}

// sessionPath returns the path to the session file for the given slug.
func sessionPath(workDir, slug string) string {
	return filepath.Join(workDir, slug, sessionFileName)
}

// WriteSession creates a new session lock file for the given work item.
func WriteSession(workDir, slug, mode string) error {
	now := time.Now()
	info := SessionInfo{
		PID:      os.Getpid(),
		Mode:     mode,
		Slug:     slug,
		Started:  now,
		LastSeen: now,
	}
	data, err := json.Marshal(info)
	if err != nil {
		return err
	}
	return os.WriteFile(sessionPath(workDir, slug), data, 0644)
}

// TouchSession updates the mtime of the session file to signal liveness.
// Returns nil if the file does not exist (idempotent).
func TouchSession(workDir, slug string) error {
	p := sessionPath(workDir, slug)
	now := time.Now()
	err := os.Chtimes(p, now, now)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// ClearSession removes the session lock file.
// Returns nil if the file does not exist (idempotent).
func ClearSession(workDir, slug string) error {
	err := os.Remove(sessionPath(workDir, slug))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// ReadSession reads and validates a session lock file.
// Returns nil, false if the file is missing, stale (mtime > 30s), or malformed.
func ReadSession(workDir, slug string) (*SessionInfo, bool) {
	p := sessionPath(workDir, slug)
	fi, err := os.Stat(p)
	if err != nil {
		return nil, false
	}
	if time.Since(fi.ModTime()) > sessionStaleTTL {
		return nil, false
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return nil, false
	}
	var info SessionInfo
	if err := json.Unmarshal(data, &info); err != nil {
		return nil, false
	}
	return &info, true
}

// ListActiveSessions returns all non-stale sessions in the work directory,
// keyed by slug. Never returns nil.
func ListActiveSessions(workDir string) map[string]SessionInfo {
	result := make(map[string]SessionInfo)
	matches, err := filepath.Glob(filepath.Join(workDir, "*", sessionFileName))
	if err != nil {
		return result
	}
	for _, match := range matches {
		// Extract slug: the directory name between workDir and sessionFileName.
		slug := filepath.Base(filepath.Dir(match))
		if info, ok := ReadSession(workDir, slug); ok {
			result[slug] = *info
		}
	}
	return result
}
