package work

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
)

// ReviewState is the active review-gate an item carries: the mechanism that
// gated it, when, and why. Nil for an ungated item. In _index.json it is the
// review_field projection from update-work-index.sh (mechanism / gated_at /
// reason only); read from a work item's _meta.json review block it is the same
// read-side subset (gate_id and packet stay out of the renderers' path).
type ReviewState struct {
	Mechanism string `json:"mechanism"` // "flag" | "hold"
	GatedAt   string `json:"gated_at"`
	Reason    string `json:"reason"`
}

// WorkItem represents a single work item from _index.json.
type WorkItem struct {
	Slug            string       `json:"slug"`
	Title           string       `json:"title"`
	Status          string       `json:"status"`
	Branches        []string     `json:"branches"`
	Tags            []string     `json:"tags"`
	Project         string       `json:"project"` // "" = ungrouped
	Created         string       `json:"created"`
	Updated         string       `json:"updated"`
	Issue           string       `json:"issue"`
	PR              string       `json:"pr"`
	Review          *ReviewState `json:"review"`     // nil = ungated
	BlockedBy       []string     `json:"blocked_by"` // slugs this item waits on; nil when unset
	CeremonyDepth   int          `json:"ceremony_depth"`
	HasPlanDoc      bool         `json:"has_plan_doc"`
	HasExecutionLog bool         `json:"has_execution_log"`
	HasTasks        bool         `json:"-"` // inferred from tasks.json presence
}

// indexFile is the top-level shape of _index.json.
type indexFile struct {
	Plans []WorkItem `json:"plans"`
}

// ProjectGroup is one section of a project-grouped item list: the project
// label ("" for the ungrouped tail) and its members in input order.
type ProjectGroup struct {
	Project string
	Items   []WorkItem
}

// GroupByProject buckets items into project sections: labeled sections
// first, the ungrouped ("") tail always last. Input order is preserved
// within each section, and labeled sections follow the position of their
// first member — so a recency-sorted input yields sections ordered by
// most-recent member, with a recency-sorted flat tail.
func GroupByProject(items []WorkItem) []ProjectGroup {
	var order []string
	buckets := make(map[string][]WorkItem)
	for _, item := range items {
		if _, seen := buckets[item.Project]; !seen && item.Project != "" {
			order = append(order, item.Project)
		}
		buckets[item.Project] = append(buckets[item.Project], item)
	}

	groups := make([]ProjectGroup, 0, len(order)+1)
	for _, p := range order {
		groups = append(groups, ProjectGroup{Project: p, Items: buckets[p]})
	}
	if tail, ok := buckets[""]; ok {
		groups = append(groups, ProjectGroup{Project: "", Items: tail})
	}
	return groups
}

// ActiveSlugs returns the set of loaded slugs whose item is still active
// (status != "archived"). It is the liveness test a blocker edge is measured
// against: a blocker counts only while its target is active; an archived or
// absent blocker is inert, so completion releases a blocked item with no edge
// bookkeeping.
func ActiveSlugs(items []WorkItem) map[string]bool {
	active := make(map[string]bool, len(items))
	for _, it := range items {
		if it.Status != "archived" {
			active[it.Slug] = true
		}
	}
	return active
}

// activeBlockers returns the item's blocker slugs that are still active among
// the given set — the slugs the "⧗ after:" badge lists, in BlockedBy order. An
// empty result means the item is currently unblocked (every blocker archived,
// dangling, or none declared).
func activeBlockers(item WorkItem, active map[string]bool) []string {
	var out []string
	for _, slug := range item.BlockedBy {
		if active[slug] {
			out = append(out, slug)
		}
	}
	return out
}

// orderGroupItems reorders one project group's items unblocked-first with a
// cycle-tolerant topo-ish bump: items with no active blocker keep their input
// (recency) order ahead of every blocked item, and within the blocked stratum
// each item is bumped after any blocker that shares the group, recency breaking
// ties. Blockedness is measured against active; blockers outside the group or
// already satisfied never move an item. A blocker cycle degrades to input order
// for the items it entangles rather than looping. Pure: the input slice is not
// mutated.
func orderGroupItems(items []WorkItem, active map[string]bool) []WorkItem {
	if len(items) < 2 {
		return items
	}

	// Stable unblocked-first partition, input (recency) order within each stratum.
	seq := make([]WorkItem, 0, len(items))
	var blocked []WorkItem
	for _, it := range items {
		if len(activeBlockers(it, active)) == 0 {
			seq = append(seq, it)
		} else {
			blocked = append(blocked, it)
		}
	}
	seq = append(seq, blocked...)

	member := make(map[string]bool, len(seq))
	for _, it := range seq {
		member[it.Slug] = true
	}
	// deps[slug] is the item's in-group active blockers — the only edges that
	// bump order; cross-group and self edges are excluded so they cannot loop.
	deps := make(map[string][]string, len(seq))
	for _, it := range seq {
		var ig []string
		for _, b := range activeBlockers(it, active) {
			if member[b] && b != it.Slug {
				ig = append(ig, b)
			}
		}
		deps[it.Slug] = ig
	}

	placed := make(map[string]bool, len(seq))
	out := make([]WorkItem, 0, len(seq))
	for len(out) < len(seq) {
		progressed := false
		for _, it := range seq {
			if placed[it.Slug] {
				continue
			}
			ready := true
			for _, b := range deps[it.Slug] {
				if !placed[b] {
					ready = false
					break
				}
			}
			if !ready {
				continue
			}
			out = append(out, it)
			placed[it.Slug] = true
			progressed = true
		}
		if !progressed {
			// A cycle leaves entangled items unplaced; flush them in seq order.
			for _, it := range seq {
				if !placed[it.Slug] {
					out = append(out, it)
					placed[it.Slug] = true
				}
			}
			break
		}
	}
	return out
}

// ProjectLabels returns the sorted set of distinct non-empty project labels
// across the given items (active and archived alike).
func ProjectLabels(items []WorkItem) []string {
	seen := make(map[string]bool)
	var labels []string
	for _, item := range items {
		if item.Project != "" && !seen[item.Project] {
			seen[item.Project] = true
			labels = append(labels, item.Project)
		}
	}
	sort.Strings(labels)
	return labels
}

// NearestLabel returns the existing label closest to the candidate when the
// two are similar enough to be a likely typo (mirroring the CLI's
// warn_near_project_label guard: similarity >= 0.8, exact matches excluded),
// or "" when no existing label is that close. Grouping matches exact labels
// only, so callers use a hit to ask for confirmation before writing.
func NearestLabel(candidate string, labels []string) string {
	best, bestSim := "", 0.0
	for _, label := range labels {
		if label == candidate {
			continue
		}
		if sim := labelSimilarity(candidate, label); sim >= 0.8 && sim > bestSim {
			best, bestSim = label, sim
		}
	}
	return best
}

// labelSimilarity is 1 - levenshtein(a,b)/max(len(a),len(b)), in [0,1].
func labelSimilarity(a, b string) float64 {
	ra, rb := []rune(a), []rune(b)
	if len(ra) == 0 && len(rb) == 0 {
		return 1
	}
	prev := make([]int, len(rb)+1)
	cur := make([]int, len(rb)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(ra); i++ {
		cur[0] = i
		for j := 1; j <= len(rb); j++ {
			cost := 1
			if ra[i-1] == rb[j-1] {
				cost = 0
			}
			cur[j] = min(prev[j]+1, cur[j-1]+1, prev[j-1]+cost)
		}
		prev, cur = cur, prev
	}
	dist := prev[len(rb)]
	return 1 - float64(dist)/float64(max(len(ra), len(rb)))
}

// LoadIndex reads _index.json from the given work directory and returns
// work items sorted by updated descending (most recent first).
// It also checks each item directory for tasks.json to set HasTasks.
func LoadIndex(workDir string) ([]WorkItem, error) {
	indexPath := filepath.Join(workDir, "_index.json")
	data, err := os.ReadFile(indexPath)
	if err != nil {
		return nil, err
	}

	var idx indexFile
	if err := json.Unmarshal(data, &idx); err != nil {
		return nil, err
	}

	// Infer HasTasks from tasks.json presence for active items
	for i := range idx.Plans {
		tasksPath := filepath.Join(workDir, idx.Plans[i].Slug, "tasks.json")
		if _, err := os.Stat(tasksPath); err == nil {
			idx.Plans[i].HasTasks = true
		}
	}

	// Track slugs already in index to avoid duplicates from _archive/
	indexed := make(map[string]bool, len(idx.Plans))
	for _, item := range idx.Plans {
		indexed[item.Slug] = true
	}

	// Scan _archive/ for items moved there (not present in _index.json)
	archiveDir := filepath.Join(workDir, "_archive")
	if entries, err := os.ReadDir(archiveDir); err == nil {
		for _, entry := range entries {
			if !entry.IsDir() || indexed[entry.Name()] {
				continue
			}
			slug := entry.Name()
			metaPath := filepath.Join(archiveDir, slug, "_meta.json")
			data, err := os.ReadFile(metaPath)
			if err != nil {
				continue
			}
			var meta workItemMeta
			if err := json.Unmarshal(data, &meta); err != nil {
				continue
			}
			idx.Plans = append(idx.Plans, WorkItem{
				Slug:     slug,
				Title:    meta.Title,
				Status:   "archived",
				Branches: meta.Branches,
				Tags:     meta.Tags,
				Project:  meta.Project,
				Issue:    meta.Issue,
				PR:       meta.PR,
				Created:  meta.Created,
				Updated:  meta.Updated,
			})
		}
	}

	// Sort by updated descending
	sort.Slice(idx.Plans, func(i, j int) bool {
		return idx.Plans[i].Updated > idx.Plans[j].Updated
	})

	return idx.Plans, nil
}
