package work

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// WorkItemDetail holds the full detail of a single work item, as returned by
// `lore work show <slug> --json`.
type WorkItemDetail struct {
	Slug            string     `json:"slug"`
	Title           string     `json:"title"`
	Status          string     `json:"status"`
	Branches        []string   `json:"branches"`
	Tags            []string   `json:"tags"`
	Issue           string     `json:"issue"`
	PR              string     `json:"pr"`
	Created         string     `json:"created"`
	Updated         string     `json:"updated"`
	PlanContent     *string    `json:"plan_content"`
	NotesContent    *string    `json:"notes_content"`
	HasExecutionLog bool       `json:"has_execution_log"`
	HasTasks        bool       `json:"has_tasks"`
	TasksContent    *TasksFile `json:"tasks_content,omitempty"`
	ExecLogContent  *string    `json:"exec_log_content,omitempty"`
}

// SearchLocation identifies a navigable position within a detail view tab.
type SearchLocation struct {
	TabID        Tab
	TabLabel     string
	Label        string
	Subtitle     string
	EntryIdx     int
	ScrollOffset int
}

// workItemMeta mirrors the _meta.json schema for a work item.
type workItemMeta struct {
	Slug     string   `json:"slug"`
	Title    string   `json:"title"`
	Status   string   `json:"status"`
	Branches []string `json:"branches"`
	Tags     []string `json:"tags"`
	Issue    string   `json:"issue"`
	PR       string   `json:"pr"`
	Created  string   `json:"created"`
	Updated  string   `json:"updated"`
}

// loadWorkItemDetailDirect reads work item files directly from disk,
// bypassing the subprocess call. Returns the same WorkItemDetail structure
// that LoadWorkItemDetail produces.
func loadWorkItemDetailDirect(workDir, slug string) (*WorkItemDetail, error) {
	itemDir := filepath.Join(workDir, slug)
	// If the item has been archived, fall back to the _archive subdirectory.
	if _, err := os.Stat(filepath.Join(itemDir, "_meta.json")); os.IsNotExist(err) {
		archiveDir := filepath.Join(workDir, "_archive", slug)
		if _, aerr := os.Stat(filepath.Join(archiveDir, "_meta.json")); aerr == nil {
			itemDir = archiveDir
		}
	}
	metaPath := filepath.Join(itemDir, "_meta.json")

	metaBytes, err := os.ReadFile(metaPath)
	if err != nil {
		return nil, fmt.Errorf("reading _meta.json for %s: %w", slug, err)
	}

	var meta workItemMeta
	if err := json.Unmarshal(metaBytes, &meta); err != nil {
		return nil, fmt.Errorf("parsing _meta.json for %s: %w", slug, err)
	}

	// Ensure slices are non-nil (match subprocess behavior: empty array, not null)
	if meta.Branches == nil {
		meta.Branches = []string{}
	}
	if meta.Tags == nil {
		meta.Tags = []string{}
	}

	detail := &WorkItemDetail{
		Slug:     slug,
		Title:    meta.Title,
		Status:   meta.Status,
		Branches: meta.Branches,
		Tags:     meta.Tags,
		Issue:    meta.Issue,
		PR:       meta.PR,
		Created:  meta.Created,
		Updated:  meta.Updated,
	}

	// Read optional content files — nil when absent
	if data, err := os.ReadFile(filepath.Join(itemDir, "plan.md")); err == nil {
		s := string(data)
		detail.PlanContent = &s
	}
	if data, err := os.ReadFile(filepath.Join(itemDir, "notes.md")); err == nil {
		s := string(data)
		detail.NotesContent = &s
	}

	// tasks.json — read + parse in goroutine so event loop does zero disk I/O
	if data, err := os.ReadFile(filepath.Join(itemDir, "tasks.json")); err == nil {
		detail.HasTasks = true
		var tf TasksFile
		if err := json.Unmarshal(data, &tf); err == nil {
			detail.TasksContent = &tf
		}
	}

	// execution-log.md — read raw bytes in goroutine; parsing is cheap string work
	if data, err := os.ReadFile(filepath.Join(itemDir, "execution-log.md")); err == nil {
		detail.HasExecutionLog = true
		s := string(data)
		detail.ExecLogContent = &s
	}

	return detail, nil
}

// LoadWorkItemDetail reads work item detail directly from disk.
func LoadWorkItemDetail(workDir, slug string) (*WorkItemDetail, error) {
	return loadWorkItemDetailDirect(workDir, slug)
}
