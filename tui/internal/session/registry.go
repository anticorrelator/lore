// Package session implements the TUI's half of the _sessions/ coordination
// substrate: the per-instance registry, the request queue (per-file rows with
// atomic-rename claim), and journal emission through the sole-writer script.
//
// The mechanics here are pure (no bubbletea): the main package drives them
// from the 5s poll tick and turns their results into messages. See
// docs/session-substrate.md for the substrate contract these types conform to.
package session

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// LivenessTTL is the window within which an instance file's mtime must fall
// for the instance to count as alive. A hard-killed process leaves no cleanup
// debt: its file simply ages out of snapshots. Carried over from the retired
// .lore-session machinery.
const LivenessTTL = 30 * time.Second

// Session is one live session nested under an instance registry row.
type Session struct {
	Slug      string `json:"slug"`
	Type      string `json:"type"`      // spec|implement|chat
	Initiator string `json:"initiator"` // agent|human
	Started   string `json:"started"`   // ISO 8601 UTC
}

// Instance is one live TUI instance's registry row, stored at
// instances/<name>.json.
type Instance struct {
	Name             string    `json:"name"`
	PID              int       `json:"pid"`
	Repo             string    `json:"repo"`
	Started          string    `json:"started"`           // ISO 8601 UTC
	InitiatorDefault string    `json:"initiator_default"` // "human" in v1
	Sessions         []Session `json:"sessions"`
}

// InstancesDir is the registry directory under a _sessions/ root.
func InstancesDir(sessionsDir string) string {
	return filepath.Join(sessionsDir, "instances")
}

// instancePath is the registry file for one instance name.
func instancePath(sessionsDir, name string) string {
	return filepath.Join(InstancesDir(sessionsDir), name+".json")
}

// WriteInstance writes an instance's own registry file via tmp+rename so a
// concurrent reader never observes a torn row. The instance is the sole writer
// of its own file, so no lock is needed.
func WriteInstance(sessionsDir string, inst Instance) error {
	dir := InstancesDir(sessionsDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create instances dir: %w", err)
	}
	data, err := json.Marshal(inst)
	if err != nil {
		return fmt.Errorf("marshal instance %q: %w", inst.Name, err)
	}
	return atomicWrite(instancePath(sessionsDir, inst.Name), data)
}

// Heartbeat bumps the instance file's mtime to signal liveness. When the file
// is absent (first tick, or a hard-killed predecessor was never present) it
// rewrites the full row from inst so the instance re-registers rather than
// silently dropping out of snapshots.
func Heartbeat(sessionsDir string, inst Instance) error {
	now := time.Now()
	err := os.Chtimes(instancePath(sessionsDir, inst.Name), now, now)
	if errors.Is(err, os.ErrNotExist) {
		return WriteInstance(sessionsDir, inst)
	}
	return err
}

// RemoveInstance deletes the instance's registry file. Idempotent: a missing
// file is not an error (a hard kill may have raced a graceful teardown).
func RemoveInstance(sessionsDir, name string) error {
	err := os.Remove(instancePath(sessionsDir, name))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// ListInstances returns every live instance: it globs instances/*.json, drops
// files whose mtime is older than LivenessTTL, and excludes torn/corrupt rows
// with a warning to stderr rather than aborting. The result is a full snapshot
// — callers replace state wholesale, never merge.
func ListInstances(sessionsDir string) []Instance {
	matches, err := filepath.Glob(filepath.Join(InstancesDir(sessionsDir), "*.json"))
	if err != nil {
		return nil
	}
	var out []Instance
	for _, path := range matches {
		fi, err := os.Stat(path)
		if err != nil {
			continue
		}
		if time.Since(fi.ModTime()) > LivenessTTL {
			continue // stale — aged out
		}
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var inst Instance
		if err := json.Unmarshal(data, &inst); err != nil {
			fmt.Fprintf(os.Stderr, "[session] warning: %s corrupt — %v\n", path, err)
			continue
		}
		out = append(out, inst)
	}
	return out
}

// InstanceLive reports whether the named instance has a fresh (within-TTL)
// registry file. The queue's reclamation rules reuse this signal rather than
// growing a second TTL mechanism.
func InstanceLive(sessionsDir, name string) bool {
	if name == "" {
		return false
	}
	fi, err := os.Stat(instancePath(sessionsDir, name))
	if err != nil {
		return false
	}
	return time.Since(fi.ModTime()) <= LivenessTTL
}

// nowISO is the substrate's timestamp form: ISO 8601 UTC at second precision.
func nowISO() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05Z")
}

// atomicWrite writes data to a pid-suffixed tmp file in the destination's
// directory, then renames it over the destination. Rename on one filesystem is
// atomic, so a reader sees either the old file or the new one, never a partial
// write.
func atomicWrite(dest string, data []byte) error {
	dir := filepath.Dir(dest)
	tmp := filepath.Join(dir, fmt.Sprintf(".%s.tmp.%d", filepath.Base(dest), os.Getpid()))
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("write tmp: %w", err)
	}
	if err := os.Rename(tmp, dest); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("rename into place: %w", err)
	}
	return nil
}
