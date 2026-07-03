package work

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
)

// WorkItem represents a single work item from _index.json.
type WorkItem struct {
	Slug            string   `json:"slug"`
	Title           string   `json:"title"`
	Status          string   `json:"status"`
	Branches        []string `json:"branches"`
	Tags            []string `json:"tags"`
	Project         string   `json:"project"` // "" = ungrouped
	Created         string   `json:"created"`
	Updated         string   `json:"updated"`
	Issue           string   `json:"issue"`
	PR              string   `json:"pr"`
	HasPlanDoc      bool     `json:"has_plan_doc"`
	HasExecutionLog bool     `json:"has_execution_log"`
	HasTasks        bool     `json:"-"` // inferred from tasks.json presence
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
