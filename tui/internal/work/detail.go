package work

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// ExtraFile holds the name and content of a non-canonical document found in a
// work item directory (any .md file that isn't plan.md, notes.md, or
// execution-log.md).
type ExtraFile struct {
	Name    string `json:"name"` // filename without the .md extension
	Content string `json:"content"`
}

// WorkItemDetail holds the full detail of a single work item, as returned by
// `lore work show <slug> --json`.
type WorkItemDetail struct {
	Slug            string       `json:"slug"`
	Title           string       `json:"title"`
	Status          string       `json:"status"`
	Branches        []string     `json:"branches"`
	Tags            []string     `json:"tags"`
	Project         string       `json:"project"`
	RelatedWork     []string     `json:"related_work"`
	BlockedBy       []string     `json:"blocked_by"`
	Issue           string       `json:"issue"`
	PR              string       `json:"pr"`
	Created         string       `json:"created"`
	Updated         string       `json:"updated"`
	PlanContent     *string      `json:"plan_content"`
	NotesContent    *string      `json:"notes_content"`
	HasExecutionLog bool         `json:"has_execution_log"`
	HasTasks        bool         `json:"has_tasks"`
	TasksContent    *TasksFile   `json:"tasks_content,omitempty"`
	ExecLogContent  *string      `json:"exec_log_content,omitempty"`
	ExtraFiles      []ExtraFile  `json:"extra_files,omitempty"`
	Review          *ReviewState `json:"review,omitempty"` // nil = ungated
	Malformed       bool         `json:"malformed,omitempty"`
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
	Slug        string       `json:"slug"`
	Title       string       `json:"title"`
	Status      string       `json:"status"`
	Branches    []string     `json:"branches"`
	Tags        []string     `json:"tags"`
	Project     string       `json:"project"`
	RelatedWork []string     `json:"related_work"`
	BlockedBy   []string     `json:"blocked_by"`
	Issue       string       `json:"issue"`
	PR          string       `json:"pr"`
	Created     string       `json:"created"`
	Updated     string       `json:"updated"`
	Review      *ReviewState `json:"review"`
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
		// Malformed _meta.json — return a stub so the TUI can still render the item.
		detail := &WorkItemDetail{
			Slug:        slug,
			Title:       "[malformed] " + slug,
			Branches:    []string{},
			Tags:        []string{},
			RelatedWork: []string{},
			BlockedBy:   []string{},
			Malformed:   true,
		}

		// Still attempt to read sibling files on the stub.
		if data, err := os.ReadFile(filepath.Join(itemDir, "plan.md")); err == nil {
			s := string(data)
			detail.PlanContent = &s
		}
		if data, err := os.ReadFile(filepath.Join(itemDir, "notes.md")); err == nil {
			s := string(data)
			detail.NotesContent = &s
		}
		if data, err := os.ReadFile(filepath.Join(itemDir, "tasks.json")); err == nil {
			detail.HasTasks = true
			var tf TasksFile
			if err := json.Unmarshal(data, &tf); err == nil {
				detail.TasksContent = &tf
			}
		}
		if data, err := os.ReadFile(filepath.Join(itemDir, "execution-log.md")); err == nil {
			detail.HasExecutionLog = true
			s := string(data)
			detail.ExecLogContent = &s
		}
		canonical := map[string]bool{
			"plan.md":          true,
			"notes.md":         true,
			"execution-log.md": true,
		}
		if entries, err := os.ReadDir(itemDir); err == nil {
			for _, entry := range entries {
				name := entry.Name()
				if entry.IsDir() || !strings.HasSuffix(name, ".md") || strings.HasPrefix(name, "_") {
					continue
				}
				if canonical[name] {
					continue
				}
				if data, err := os.ReadFile(filepath.Join(itemDir, name)); err == nil {
					detail.ExtraFiles = append(detail.ExtraFiles, ExtraFile{
						Name:    strings.TrimSuffix(name, ".md"),
						Content: string(data),
					})
				}
			}
		}

		return detail, nil
	}

	// Ensure slices are non-nil (match subprocess behavior: empty array, not null)
	if meta.Branches == nil {
		meta.Branches = []string{}
	}
	if meta.Tags == nil {
		meta.Tags = []string{}
	}
	if meta.RelatedWork == nil {
		meta.RelatedWork = []string{}
	}
	if meta.BlockedBy == nil {
		meta.BlockedBy = []string{}
	}

	detail := &WorkItemDetail{
		Slug:        slug,
		Title:       meta.Title,
		Status:      meta.Status,
		Branches:    meta.Branches,
		Tags:        meta.Tags,
		Project:     meta.Project,
		RelatedWork: meta.RelatedWork,
		BlockedBy:   meta.BlockedBy,
		Issue:       meta.Issue,
		PR:          meta.PR,
		Created:     meta.Created,
		Updated:     meta.Updated,
		Review:      meta.Review,
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

	// Scan for any additional .md files not already handled above.
	// os.ReadDir returns entries in lexicographic order, so tab order is stable.
	canonical := map[string]bool{
		"plan.md":          true,
		"notes.md":         true,
		"execution-log.md": true,
	}
	if entries, err := os.ReadDir(itemDir); err == nil {
		for _, entry := range entries {
			name := entry.Name()
			if entry.IsDir() || !strings.HasSuffix(name, ".md") || strings.HasPrefix(name, "_") {
				continue
			}
			if canonical[name] {
				continue
			}
			if data, err := os.ReadFile(filepath.Join(itemDir, name)); err == nil {
				detail.ExtraFiles = append(detail.ExtraFiles, ExtraFile{
					Name:    strings.TrimSuffix(name, ".md"),
					Content: string(data),
				})
			}
		}
	}

	return detail, nil
}

// LoadWorkItemDetail reads work item detail directly from disk.
func LoadWorkItemDetail(workDir, slug string) (*WorkItemDetail, error) {
	return loadWorkItemDetailDirect(workDir, slug)
}

// projectMeta mirrors the _projects/<slug>/_meta.json schema, which differs
// from a work item's: identity plus a free-text anchor, no branches/tags/PR.
type projectMeta struct {
	Slug    string `json:"slug"`
	Title   string `json:"title"`
	Status  string `json:"status"`
	Anchor  string `json:"anchor"`
	Created string `json:"created"`
	Updated string `json:"updated"`
}

// ProjectDetail holds a project home's rendered content: identity and anchor
// from _meta.json, the overview.md body, and any freeform project documents.
// It is the project-mode analogue of WorkItemDetail — a distinct shape because
// the home _meta.json schema and tab set differ from a work item's.
type ProjectDetail struct {
	Slug    string
	Title   string
	Status  string
	Anchor  string
	Created string
	Updated string
	// HomeExists is true when _projects/<slug>/_meta.json was found. A labeled
	// project with no home dir (HomeExists false) renders the describe hint.
	HomeExists bool
	// Overview is overview.md's content, nil when absent. describe-project.sh
	// deletes overview.md when its body empties, so absence is a contract; the
	// overview tab then shows the describe hint rather than a blank pane.
	Overview *string
	// Docs are the home's freeform .md documents (every .md except overview.md),
	// each rendered as its own tab through the shared markdown pipeline.
	Docs []ExtraFile
}

// ProjectHome is the project home directory _work/_projects/<slug>/ — the
// single composition point for the path. Detail loads, freshness polls, and
// the coordination sidecar all resolve through it.
func ProjectHome(workDir, slug string) string {
	return filepath.Join(workDir, "_projects", slug)
}

// LoadProjectDetail reads a project home at _projects/<slug>/ into a
// ProjectDetail. A missing home dir (labeled project with no record) or an
// empty slug (the ungrouped bucket) is not an error — both return a detail with
// HomeExists false so the caller renders an honest empty state. All disk reads
// live here so callers invoke it inside a tea.Cmd and the DetailModel stays
// headless-testable.
func LoadProjectDetail(workDir, slug string) (*ProjectDetail, error) {
	pd := &ProjectDetail{Slug: slug}
	if slug == "" {
		return pd, nil // ungrouped bucket: no project, no home to read
	}

	homeDir := ProjectHome(workDir, slug)
	metaBytes, err := os.ReadFile(filepath.Join(homeDir, "_meta.json"))
	if err != nil {
		return pd, nil // labeled project with no home dir yet
	}

	var meta projectMeta
	if err := json.Unmarshal(metaBytes, &meta); err != nil {
		return nil, fmt.Errorf("reading _meta.json for project %s: %w", slug, err)
	}
	pd.HomeExists = true
	pd.Title = meta.Title
	pd.Status = meta.Status
	pd.Anchor = meta.Anchor
	pd.Created = meta.Created
	pd.Updated = meta.Updated

	if data, err := os.ReadFile(filepath.Join(homeDir, "overview.md")); err == nil {
		s := string(data)
		pd.Overview = &s
	}

	// Every other .md file is a project document, one tab each. Skip overview.md
	// (the primary tab) and _-prefixed files (_meta.json and any internal marker).
	// os.ReadDir returns lexicographic order, so tab order is stable.
	if entries, err := os.ReadDir(homeDir); err == nil {
		for _, entry := range entries {
			name := entry.Name()
			if entry.IsDir() || !strings.HasSuffix(name, ".md") || strings.HasPrefix(name, "_") {
				continue
			}
			if name == "overview.md" {
				continue
			}
			if data, err := os.ReadFile(filepath.Join(homeDir, name)); err == nil {
				pd.Docs = append(pd.Docs, ExtraFile{
					Name:    strings.TrimSuffix(name, ".md"),
					Content: string(data),
				})
			}
		}
	}

	return pd, nil
}
