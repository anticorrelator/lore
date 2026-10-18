// Package coordination backs the coordination-centric TUI view: an arc list
// read from the arc store at _work/_arcs/ and an integrated per-arc body with
// local document drill-ins. Disk reads are exposed as functions for callers to
// invoke inside tea.Cmd values.
package coordination

import (
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/anticorrelator/lore/tui/internal/session"
)

const JournalLimit = 8

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

// LatestEventTimes derives each arc's most recent journal instant from the
// same event generation used by the selected arc detail. Membership follows
// FilterEvents: direct sessions identify through Slug and workers through
// links.work_item. Unparseable and absent timestamps remain absent rather than
// being invented from record mtimes or arc lifecycle fields.
func LatestEventTimes(events []session.Event, arcs []Arc) map[string]string {
	memberArcs := make(map[string][]string)
	for _, arc := range arcs {
		for _, member := range arc.Members {
			memberArcs[member] = append(memberArcs[member], arc.Slug)
		}
	}

	latest := make(map[string]string)
	latestAt := make(map[string]time.Time)
	for _, event := range events {
		keys := []string{event.Slug}
		if event.Links != nil && event.Links["work_item"] != "" && event.Links["work_item"] != event.Slug {
			keys = append(keys, event.Links["work_item"])
		}
		at, err := time.Parse(time.RFC3339, event.TS)
		if err != nil {
			continue
		}
		seen := make(map[string]bool)
		for _, key := range keys {
			for _, arc := range memberArcs[key] {
				if seen[arc] {
					continue
				}
				seen[arc] = true
				if previous, ok := latestAt[arc]; !ok || at.After(previous) {
					latestAt[arc] = at
					latest[arc] = event.TS
				}
			}
		}
	}
	return latest
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
