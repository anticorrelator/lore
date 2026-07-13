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
//
// The tmux/RequestID/SessionID/Harness/AutoClose/CloseRequests fields are the recovery
// manifest: additive, omit-when-empty, absent for direct-PTY sessions and for rows
// written by a binary predating them. Tmux is the hosting tmux session name — its
// presence is what a restarting TUI's adoption scan keys on to reattach a
// survivor. RequestID preserves the spawn identity; SessionID/Harness persist the spend-probe transcript binding so an
// adopting instance can still extract token spend at teardown; AutoClose persists
// the close-ladder override; CloseRequests preserves every consumed close-request
// id so the eventual closed row can declare the exact recovery correlation.
type Session struct {
	Slug      string `json:"slug"`
	Type      string `json:"type"`      // spec|implement|chat
	Initiator string `json:"initiator"` // agent|human
	Started   string `json:"started"`   // ISO 8601 UTC

	Tmux          string   `json:"tmux,omitempty"`
	RequestID     string   `json:"request_id,omitempty"`
	SessionID     string   `json:"session_id,omitempty"`
	Harness       string   `json:"harness,omitempty"`
	AutoClose     *bool    `json:"auto_close,omitempty"`
	CloseRequests []string `json:"close_requests,omitempty"`
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

	// Build identity ("vintage") — additive, omit-when-empty. BuildSHA is the
	// short git SHA embedded at build time (empty for go-run/dev builds);
	// BuildTime is the orderable vintage: the commit's committer-date for a
	// release build, the binary mtime for a dev build (both ISO 8601 UTC). A row
	// written by an older binary carries neither and reads as vintage-unknown —
	// never rejected by min_vintage filtering (degradation is additive, not
	// breaking). BuildTime, not BuildSHA, is the comparable quantity because a
	// SHA has no read-side ordering.
	BuildSHA  string `json:"build_sha,omitempty"`
	BuildTime string `json:"build_time,omitempty"`

	// Routing-visibility fields — additive, omit-when-empty. ProjectDir is this
	// instance's normalized (physically-resolved) project directory, immutable for
	// the process; it is the match key a request's prefer_project_dir compares
	// against. Framework is the launch framework the TUI resolves for untargeted
	// spawns (ResolveTUILaunchFramework), refreshed on every full-row write plus a
	// settings-commit trigger. Neither is a claim filter — both surface to a
	// coordinator's routing read (lore session list). A row written by a
	// pre-feature binary carries neither and renders as unknown downstream.
	ProjectDir string `json:"project_dir,omitempty"`
	Framework  string `json:"framework,omitempty"`
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

// ListInstances returns every live instance and discards scan diagnostics.
func ListInstances(sessionsDir string) []Instance {
	instances, _ := ListInstancesWithDiagnostics(sessionsDir)
	return instances
}

// ListInstancesWithDiagnostics returns a full live-instance snapshot plus any
// non-fatal corrupt-row exclusions observed while reading it.
func ListInstancesWithDiagnostics(sessionsDir string) ([]Instance, []Diagnostic) {
	matches, err := filepath.Glob(filepath.Join(InstancesDir(sessionsDir), "*.json"))
	if err != nil {
		return nil, nil
	}
	var out []Instance
	var diagnostics []Diagnostic
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
			diagnostics = append(diagnostics, corruptDiagnostic("instance-registry", path, err))
			continue
		}
		out = append(out, inst)
	}
	return out, diagnostics
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
