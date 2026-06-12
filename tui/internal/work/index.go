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
