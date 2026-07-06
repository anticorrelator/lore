package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// TestCursorOnProjectHeaderDrivesProjectDetail exercises the D5 seam end to end:
// a key-driven cursor rest on a project header must flip the shared detail model
// into project mode via the host cursor-identity diff (CurrentRowID), and a
// ProjectDetailLoadedMsg must route to that model and render the overview.
func TestCursorOnProjectHeaderDrivesProjectDetail(t *testing.T) {
	workDir := t.TempDir()
	home := filepath.Join(workDir, "_projects", "alpha")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	meta := `{"slug":"alpha","title":"Alpha","status":"active","anchor":"the alpha anchor"}`
	if err := os.WriteFile(filepath.Join(home, "_meta.json"), []byte(meta), 0o644); err != nil {
		t.Fatal(err)
	}

	items := []work.WorkItem{
		{Slug: "a", Title: "A", Status: "active", Project: "alpha"},
		{Slug: "b", Title: "B", Status: "active", Project: "beta"},
	}
	m := minimalModel(stateWork, items, nil)
	m.config = config.Config{WorkDir: workDir}
	m, _ = updateModel(t, m, tea.WindowSizeMsg{Width: 120, Height: 40})
	m.focusedPanel = panelLeft

	// 'g' lands the cursor on the first project header. GroupByProject preserves
	// insertion order, so the first header is "alpha".
	m, cmd := updateModel(t, m, press('g'))
	if !m.detail.IsProject() {
		t.Fatal("cursor on a project header did not switch the detail model to project mode")
	}
	if got := m.detail.ProjectSlug(); got != "alpha" {
		t.Fatalf("ProjectSlug() = %q, want alpha", got)
	}
	if cmd == nil {
		t.Fatal("expected a project-load command from the header cursor move")
	}

	// The host routes ProjectDetailLoadedMsg to the project-mode detail model,
	// which renders overview.md through the shared markdown pipeline.
	overview := "# Alpha Overview\n\nthe alpha home body"
	pd := &work.ProjectDetail{Slug: "alpha", Title: "Alpha", Status: "active", HomeExists: true, Overview: &overview}
	m, _ = updateModel(t, m, work.ProjectDetailLoadedMsg{Slug: "alpha", Detail: pd})
	if body := m.detail.View(); !strings.Contains(body, "alpha home body") {
		t.Errorf("project detail did not render overview.md; got:\n%s", body)
	}
}

// TestProjectDetailPollGateReloadsOnMtimeChange verifies the freshness gate: the
// project home is polled only while a project drives the detail pane, and a home
// mtime change triggers a reload (baseline first, then change).
func TestProjectDetailPollGateReloadsOnMtimeChange(t *testing.T) {
	workDir := t.TempDir()
	m := minimalModel(stateWork, nil, nil)
	m.config = config.Config{WorkDir: workDir}
	m, _ = updateModel(t, m, tea.WindowSizeMsg{Width: 120, Height: 40})

	// A work-item detail must not be polled as a project.
	if m.detail.IsProject() {
		t.Fatal("fresh detail should not be in project mode")
	}

	// Put the model into project mode for "alpha".
	m2, _ := m.loadDetail("project:alpha")
	if !m2.detail.IsProject() || m2.detail.ProjectSlug() != "alpha" {
		t.Fatalf("loadDetail(project:alpha) did not enter project mode: %v/%q", m2.detail.IsProject(), m2.detail.ProjectSlug())
	}

	// First stat establishes the baseline (no reload).
	base := projectDetailMtimeCheckedMsg{slug: "alpha", mtime: time.Unix(1000, 0)}
	m2, cmd := m2.handleProjectDetailMtimeChecked(base)
	if cmd != nil {
		t.Fatal("baseline stat should not trigger a reload")
	}
	// A later mtime triggers a reload command.
	m2, cmd = m2.handleProjectDetailMtimeChecked(projectDetailMtimeCheckedMsg{slug: "alpha", mtime: time.Unix(2000, 0)})
	if cmd == nil {
		t.Fatal("changed mtime should trigger a project-detail reload")
	}
}
