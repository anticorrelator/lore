// Package coordination backs the coordination-centric TUI view: an arc list
// read from the arc store at _work/_arcs/ and an integrated per-arc body with
// local document drill-ins. Disk reads are exposed as functions for callers to
// invoke inside tea.Cmd values.
package coordination

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"

	"github.com/anticorrelator/lore/tui/internal/session"
)

const JournalLimit = 8

// Pin is the sticky dispatch pin from _coordination.json (schema v1). Field
// types must match the sidecar exactly — the sole writer is
// scripts/coordinate-pin.sh, and the pin key is omitted entirely when cleared.
type Pin struct {
	Instance string `json:"instance"`
	PinnedAt string `json:"pinned_at"`
	PinnedBy string `json:"pinned_by,omitempty"`
}

type pinSidecar struct {
	SchemaVersion int  `json:"schema_version"`
	Pin           *Pin `json:"pin"`
}

// PinStatus is the derived pin state. Liveness is never stored in the
// sidecar: readers join Pin.Instance against the session registry's mtime TTL
// at read time. Absent, live, and dead are three distinct first-class states.
// PinNoProject is a fourth: the pin sidecar is project-scoped, so an arc with
// no project label has nowhere to carry one — which is different from having
// a pin home and finding it empty.
type PinStatus int

const (
	PinAbsent PinStatus = iota
	PinLive
	PinDead
	PinNoProject
)

// ReadPin reads the pin sidecar in the given project home. A missing sidecar
// or a sidecar with no pin key both return (nil, nil) — pin-less is a
// first-class state, not an error. A malformed sidecar returns the parse
// error so it surfaces instead of silently reading as unpinned.
func ReadPin(homeDir string) (*Pin, error) {
	data, err := os.ReadFile(filepath.Join(homeDir, "_coordination.json"))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var sc pinSidecar
	if err := json.Unmarshal(data, &sc); err != nil {
		return nil, err
	}
	return sc.Pin, nil
}

// FilterEvents returns the last limit journal rows belonging to a declared arc
// member. Direct spec/implementation sessions identify through Slug; worker
// sessions identify through links.work_item. Rows carrying neither key are not
// arc-addressable and are excluded.
func FilterEvents(events []session.Event, members []string, limit int) []session.Event {
	declared := make(map[string]bool, len(members))
	for _, member := range members {
		declared[member] = true
	}
	matched := make([]session.Event, 0, len(events))
	for _, event := range events {
		workItem := ""
		if event.Links != nil {
			workItem = event.Links["work_item"]
		}
		if !declared[event.Slug] && !declared[workItem] {
			continue
		}
		matched = append(matched, event)
	}
	if limit > 0 && len(matched) > limit {
		matched = matched[len(matched)-limit:]
	}
	return matched
}

// ReadReviewPacket opens one explicit arc-relative Markdown reference. Both
// lexical traversal and symlink escape are rejected before the file is read.
func ReadReviewPacket(workDir, arc, ref string) (string, bool) {
	if ref == "" || filepath.IsAbs(ref) || strings.ToLower(filepath.Ext(ref)) != ".md" {
		return "", false
	}
	clean := filepath.Clean(filepath.FromSlash(ref))
	if clean == "." || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return "", false
	}
	base, err := filepath.EvalSymlinks(ArcDir(workDir, arc))
	if err != nil {
		return "", false
	}
	target, err := filepath.EvalSymlinks(filepath.Join(base, clean))
	if err != nil {
		return "", false
	}
	rel, err := filepath.Rel(base, target)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", false
	}
	data, err := os.ReadFile(target)
	if err != nil {
		return "", false
	}
	return string(data), true
}
