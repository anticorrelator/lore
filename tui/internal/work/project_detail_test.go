package work

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/collection"
)

func TestProjectRowID(t *testing.T) {
	cases := []struct {
		id       string
		wantSlug string
		wantOK   bool
	}{
		{"project:coordination", "coordination", true},
		{"project:", "", true}, // ungrouped bucket header
		{"some-work-item", "", false},
		{"", "", false},
	}
	for _, tc := range cases {
		slug, ok := ProjectRowID(tc.id)
		if ok != tc.wantOK || slug != tc.wantSlug {
			t.Errorf("ProjectRowID(%q) = (%q, %v), want (%q, %v)", tc.id, slug, ok, tc.wantSlug, tc.wantOK)
		}
	}
}

// CurrentRowID surfaces header identity that CurrentSlug() deliberately blanks —
// the seam the host diffs on to drive project detail from a header cursor.
func TestListModelCurrentRowIDIncludesHeaders(t *testing.T) {
	items := []WorkItem{
		{Slug: "a", Title: "A", Status: "active", Project: "alpha"},
		{Slug: "b", Title: "B", Status: "active", Project: "beta"},
	}
	m := newTestListModel(items)

	// 'g' lands on the first visible row, which is a project header.
	m, _ = m.Update(tea.KeyPressMsg{Code: 'g', Text: "g"})

	rowID := m.CurrentRowID()
	if slug, ok := ProjectRowID(rowID); !ok || slug == "" {
		t.Fatalf("CurrentRowID() = %q, want a non-empty project header ID", rowID)
	}
	if s := m.CurrentSlug(); s != "" {
		t.Errorf("CurrentSlug() on a header = %q, want empty", s)
	}
}

func writeProjectHome(t *testing.T, workDir, slug string, meta, overview string, docs map[string]string) {
	t.Helper()
	home := filepath.Join(workDir, "_projects", slug)
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	if meta != "" {
		if err := os.WriteFile(filepath.Join(home, "_meta.json"), []byte(meta), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if overview != "" {
		if err := os.WriteFile(filepath.Join(home, "overview.md"), []byte(overview), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for name, content := range docs {
		if err := os.WriteFile(filepath.Join(home, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestLoadProjectDetailFullHome(t *testing.T) {
	workDir := t.TempDir()
	meta := `{"slug":"coordination","title":"Coordination","status":"active","anchor":"The coordination substrate","created":"2026-07-06T06:28:30Z","updated":"2026-07-06T06:28:30Z"}`
	writeProjectHome(t, workDir, "coordination", meta, "# Overview\n\nbody",
		map[string]string{"arc-one.md": "# Arc One", "notes-scratch.md": "scratch", "_internal.md": "hidden"})

	pd, err := LoadProjectDetail(workDir, "coordination")
	if err != nil {
		t.Fatalf("LoadProjectDetail: %v", err)
	}
	if !pd.HomeExists {
		t.Fatal("HomeExists = false, want true")
	}
	if pd.Title != "Coordination" || pd.Status != "active" || pd.Anchor != "The coordination substrate" {
		t.Errorf("meta = %+v, want title/status/anchor populated", pd)
	}
	if pd.Overview == nil || !strings.Contains(*pd.Overview, "body") {
		t.Errorf("Overview = %v, want overview.md body", pd.Overview)
	}
	// Docs: arc-one.md and notes-scratch.md, sorted; overview.md and _-prefixed excluded.
	if len(pd.Docs) != 2 {
		t.Fatalf("got %d docs, want 2: %+v", len(pd.Docs), pd.Docs)
	}
	if pd.Docs[0].Name != "arc-one" || pd.Docs[1].Name != "notes-scratch" {
		t.Errorf("doc names = [%q %q], want [arc-one notes-scratch]", pd.Docs[0].Name, pd.Docs[1].Name)
	}
}

func TestLoadProjectDetailLabelOnly(t *testing.T) {
	workDir := t.TempDir() // no _projects dir at all
	pd, err := LoadProjectDetail(workDir, "ghost")
	if err != nil {
		t.Fatalf("LoadProjectDetail: %v", err)
	}
	if pd.HomeExists {
		t.Error("HomeExists = true, want false for a labeled project with no home")
	}
	if pd.Overview != nil {
		t.Errorf("Overview = %v, want nil", pd.Overview)
	}
}

func TestLoadProjectDetailUngroupedBucket(t *testing.T) {
	pd, err := LoadProjectDetail(t.TempDir(), "")
	if err != nil {
		t.Fatalf("LoadProjectDetail(\"\"): %v", err)
	}
	if pd.HomeExists {
		t.Error("HomeExists = true, want false for the ungrouped bucket")
	}
}

func TestLoadProjectDetailMissingOverview(t *testing.T) {
	workDir := t.TempDir()
	meta := `{"slug":"p","title":"P","status":"active","anchor":"a"}`
	writeProjectHome(t, workDir, "p", meta, "", nil) // overview.md deleted-when-emptied contract

	pd, err := LoadProjectDetail(workDir, "p")
	if err != nil {
		t.Fatalf("LoadProjectDetail: %v", err)
	}
	if !pd.HomeExists {
		t.Fatal("HomeExists = false, want true")
	}
	if pd.Overview != nil {
		t.Errorf("Overview = %v, want nil when overview.md absent", pd.Overview)
	}
}

// newProjectDetailForTest replays loadProjectDetail's no-I/O sequence — the
// headless route for putting a constructed ProjectDetail on screen without disk
// reads (mirrors the no-I/O fixture route for work items).
func newProjectDetailForTest(slug string, pd *ProjectDetail) DetailModel {
	m := NewProjectDetailModel("", slug)
	m, _ = m.Update(tea.WindowSizeMsg{Width: 80, Height: 24})
	m, _ = m.Update(ProjectDetailLoadedMsg{Slug: slug, Detail: pd})
	return m
}

func TestProjectDetailModelTabs(t *testing.T) {
	overview := "# Overview"
	pd := &ProjectDetail{
		Slug: "coordination", Title: "Coordination", Status: "active",
		Anchor: "anchor", HomeExists: true, Overview: &overview,
		Docs: []ExtraFile{{Name: "arc-one", Content: "# Arc One"}},
	}
	m := newProjectDetailForTest("coordination", pd)

	if !m.IsProject() || m.ProjectSlug() != "coordination" {
		t.Fatalf("IsProject/ProjectSlug = %v/%q", m.IsProject(), m.ProjectSlug())
	}
	wantLabels := []string{"Overview", "Arc One", "Meta"}
	tabs := m.tabHost.Tabs()
	if len(tabs) != len(wantLabels) {
		t.Fatalf("got %d tabs %v, want %v", len(tabs), tabs, wantLabels)
	}
	for i, want := range wantLabels {
		if tabs[i].Label != want {
			t.Errorf("tab[%d].Label = %q, want %q", i, tabs[i].Label, want)
		}
	}
	if got := m.HeaderTitle(); got != "Coordination" {
		t.Errorf("HeaderTitle() = %q, want Coordination", got)
	}
	// Meta tab renders the project-shaped fields, not work-item ones.
	m.tabHost.SetActiveID(TabMeta.hostID())
	meta := m.renderTabContent(m.contentWidth(), m.contentHeight())
	if !strings.Contains(meta, "Anchor") || !strings.Contains(meta, "coordination") {
		t.Errorf("project meta tab missing fields:\n%s", meta)
	}
}

func TestProjectDetailEmptyStateNamesDescribe(t *testing.T) {
	// Labeled project with a home but no overview.md → Overview tab shows the hint.
	pd := &ProjectDetail{Slug: "p", Title: "P", Status: "active", HomeExists: true}
	m := newProjectDetailForTest("p", pd)

	body := m.renderTabContent(m.contentWidth(), m.contentHeight())
	if !strings.Contains(body, "lore work project describe") {
		t.Errorf("empty overview should name the describe command, got:\n%s", body)
	}
	// Only the Overview tab exists when there is no overview and no docs.
	if labels := tabLabels(m.tabHost.Tabs()); len(labels) != 2 || labels[0] != "Overview" || labels[1] != "Meta" {
		t.Errorf("tabs = %v, want [Overview Meta]", labels)
	}
}

func TestProjectDetailLabelOnlyShowsOverviewOnly(t *testing.T) {
	pd := &ProjectDetail{Slug: "ghost"} // no home
	m := newProjectDetailForTest("ghost", pd)

	labels := tabLabels(m.tabHost.Tabs())
	if len(labels) != 1 || labels[0] != "Overview" {
		t.Errorf("tabs = %v, want [Overview] only for a homeless project", labels)
	}
	body := m.renderTabContent(m.contentWidth(), m.contentHeight())
	if !strings.Contains(body, "lore work project describe") {
		t.Errorf("homeless project should name the describe command, got:\n%s", body)
	}
}

func TestProjectDetailUngroupedBucketHint(t *testing.T) {
	pd := &ProjectDetail{Slug: ""} // ungrouped bucket
	m := newProjectDetailForTest("", pd)

	body := m.renderTabContent(m.contentWidth(), m.contentHeight())
	if strings.Contains(body, "lore work project describe") {
		t.Errorf("ungrouped bucket must not name a describe target, got:\n%s", body)
	}
	if !strings.Contains(body, "ungrouped") && !strings.Contains(body, "Ungrouped") {
		t.Errorf("ungrouped bucket should say so, got:\n%s", body)
	}
}

func tabLabels(tabs []collection.Tab) []string {
	out := make([]string, len(tabs))
	for i, tb := range tabs {
		out[i] = tb.Label
	}
	return out
}
