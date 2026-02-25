package work

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadIndex(t *testing.T) {
	// Create a temp work directory with _index.json
	tmpDir := t.TempDir()

	indexJSON := `{
		"version": 1,
		"repo": "test",
		"last_updated": "2026-02-24T00:00:00Z",
		"plans": [
			{
				"slug": "older-item",
				"title": "Older Item",
				"status": "active",
				"branches": ["main"],
				"tags": ["test"],
				"created": "2026-01-01T00:00:00Z",
				"updated": "2026-01-15T00:00:00Z",
				"issue": "",
				"pr": "42",
				"has_plan_doc": true,
				"has_execution_log": false
			},
			{
				"slug": "newer-item",
				"title": "Newer Item",
				"status": "active",
				"branches": ["feature-branch"],
				"tags": [],
				"created": "2026-02-01T00:00:00Z",
				"updated": "2026-02-20T00:00:00Z",
				"issue": "7",
				"pr": "",
				"has_plan_doc": false,
				"has_execution_log": true
			}
		]
	}`

	if err := os.WriteFile(filepath.Join(tmpDir, "_index.json"), []byte(indexJSON), 0644); err != nil {
		t.Fatal(err)
	}

	// Create a tasks.json for newer-item
	newerDir := filepath.Join(tmpDir, "newer-item")
	if err := os.MkdirAll(newerDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(newerDir, "tasks.json"), []byte(`{}`), 0644); err != nil {
		t.Fatal(err)
	}

	items, err := LoadIndex(tmpDir)
	if err != nil {
		t.Fatalf("LoadIndex failed: %v", err)
	}

	if len(items) != 2 {
		t.Fatalf("expected 2 items, got %d", len(items))
	}

	// Should be sorted by updated descending — newer-item first
	if items[0].Slug != "newer-item" {
		t.Errorf("expected first item to be newer-item, got %s", items[0].Slug)
	}
	if items[1].Slug != "older-item" {
		t.Errorf("expected second item to be older-item, got %s", items[1].Slug)
	}

	// Check all fields on newer-item
	ni := items[0]
	if ni.Title != "Newer Item" {
		t.Errorf("title: got %q, want %q", ni.Title, "Newer Item")
	}
	if ni.Status != "active" {
		t.Errorf("status: got %q, want %q", ni.Status, "active")
	}
	if len(ni.Branches) != 1 || ni.Branches[0] != "feature-branch" {
		t.Errorf("branches: got %v, want [feature-branch]", ni.Branches)
	}
	if len(ni.Tags) != 0 {
		t.Errorf("tags: got %v, want []", ni.Tags)
	}
	if ni.Issue != "7" {
		t.Errorf("issue: got %q, want %q", ni.Issue, "7")
	}
	if ni.PR != "" {
		t.Errorf("pr: got %q, want %q", ni.PR, "")
	}
	if ni.HasPlanDoc {
		t.Error("has_plan_doc: got true, want false")
	}
	if !ni.HasExecutionLog {
		t.Error("has_execution_log: got false, want true")
	}
	if !ni.HasTasks {
		t.Error("has_tasks: got false, want true (tasks.json exists)")
	}

	// Check older-item has_tasks is false (no tasks.json)
	oi := items[1]
	if oi.HasTasks {
		t.Error("older-item has_tasks: got true, want false (no tasks.json)")
	}
	if oi.PR != "42" {
		t.Errorf("older-item pr: got %q, want %q", oi.PR, "42")
	}
}

func TestLoadIndexMissing(t *testing.T) {
	_, err := LoadIndex(t.TempDir())
	if err == nil {
		t.Error("expected error for missing _index.json")
	}
}

func TestLoadIndexInvalidJSON(t *testing.T) {
	tmpDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(tmpDir, "_index.json"), []byte("not json"), 0644); err != nil {
		t.Fatal(err)
	}
	_, err := LoadIndex(tmpDir)
	if err == nil {
		t.Error("expected error for invalid JSON")
	}
}
