package coordination

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Arc statuses as recorded in _meta.json. Any other value marks the record
// malformed; readers skip it rather than guessing a status for it.
const (
	StatusActive   = "active"
	StatusClosed   = "closed"
	StatusArchived = "archived"
)

// Arc is one row of the arc store. It mirrors the `lore arc list --json` row
// contract: every field is present on every row, with Project and ClosedAt
// normalized to "" when the record omits them. The record itself takes the
// opposite position — it omits those keys rather than writing empty values —
// so the normalization happens here, once, instead of in each consumer.
type Arc struct {
	Slug    string
	Title   string
	Status  string
	Project string
	// Members is the arc's declared membership. Item and session joins go
	// through it; an arc's project label says nothing about who belongs to it.
	Members []string
	// Items counts members that still resolve to an active work item.
	Items    int
	Opened   string
	ClosedAt string
}

// Closed reports whether the arc's declared status puts it past its close.
// This is the only closure signal — file timestamps never contribute, so a
// ledger appended after the close still reads as closed.
func (a Arc) Closed() bool {
	return a.Status == StatusClosed || a.Status == StatusArchived
}

// Recency is the latest instant the arc declares: its close if it has one,
// otherwise its open. It orders and buckets every arc whatever its status,
// and it says nothing about the arc's state — the declared status does that.
//
// Closed arcs need the close instant rather than the open: the arc-store
// migration backfilled `opened` at migration time while preserving each arc's
// real close, so most closed records declare a close that precedes their open.
func (a Arc) Recency() string {
	if a.ClosedAt != "" {
		return a.ClosedAt
	}
	return a.Opened
}

// arcRecord is the on-disk _meta.json shape. Project and ClosedAt are absent
// from records that have no value for them, so both decode to "".
type arcRecord struct {
	Slug     string   `json:"slug"`
	Title    string   `json:"title"`
	Status   string   `json:"status"`
	Project  string   `json:"project"`
	Members  []string `json:"members"`
	Opened   string   `json:"opened"`
	ClosedAt string   `json:"closed_at"`
}

// ArcDir is the arc's directory in the store — the single composition point
// for the path, holding _meta.json beside coordination.md and report.md.
func ArcDir(workDir, slug string) string {
	return filepath.Join(workDir, "_arcs", slug)
}

// validStatus reports whether a declared status is one the store records.
// Anything else marks the record malformed, and ScanArcs skips it rather than
// admitting a row whose status no reader can interpret.
func validStatus(status string) bool {
	switch status {
	case StatusActive, StatusClosed, StatusArchived:
		return true
	}
	return false
}

// ScanArcs reads every arc record under workDir/_arcs/ and returns the rows
// newest-first by (recency, slug), plus a count of records it could not use.
// Callers invoke it inside a tea.Cmd; it is the list's sole arc source.
//
// Skipped records are counted rather than logged: a malformed record is a
// fact about the store worth surfacing in the UI, and stderr is not visible
// behind a full-screen TUI. Entries whose name begins with "_" or "." are not
// arcs at all — the store keeps its own machine state under those names — so
// they are passed over without counting.
func ScanArcs(workDir string) (arcs []Arc, skipped int) {
	entries, err := os.ReadDir(filepath.Join(workDir, "_arcs"))
	if err != nil {
		return nil, 0
	}
	for _, entry := range entries {
		name := entry.Name()
		if !entry.IsDir() || strings.HasPrefix(name, "_") || strings.HasPrefix(name, ".") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(ArcDir(workDir, name), "_meta.json"))
		if err != nil {
			// A directory with no record is not an arc; anything else is a
			// record we should have been able to read.
			if !os.IsNotExist(err) {
				skipped++
			}
			continue
		}
		var rec arcRecord
		if err := json.Unmarshal(data, &rec); err != nil {
			skipped++
			continue
		}
		if !validStatus(rec.Status) {
			skipped++
			continue
		}
		slug := rec.Slug
		if slug == "" {
			slug = name
		}
		arcs = append(arcs, Arc{
			Slug:     slug,
			Title:    rec.Title,
			Status:   rec.Status,
			Project:  rec.Project,
			Members:  rec.Members,
			Items:    countActiveMembers(workDir, rec.Members),
			Opened:   rec.Opened,
			ClosedAt: rec.ClosedAt,
		})
	}
	sort.Slice(arcs, func(i, j int) bool {
		ri, rj := arcs[i].Recency(), arcs[j].Recency()
		if ri != rj {
			return ri > rj
		}
		return arcs[i].Slug > arcs[j].Slug
	})
	return arcs, skipped
}

// countActiveMembers counts members that still resolve to an active work item.
// A member that has been archived, or that resolves to nothing at all, is not
// work the arc still carries.
func countActiveMembers(workDir string, members []string) int {
	n := 0
	for _, member := range members {
		if member == "" {
			continue
		}
		if info, err := os.Stat(filepath.Join(workDir, member)); err == nil && info.IsDir() {
			n++
		}
	}
	return n
}
