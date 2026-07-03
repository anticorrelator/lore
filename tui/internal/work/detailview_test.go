package work

import (
	"testing"

	tea "charm.land/bubbletea/v2"
)

func TestExtraFileLabel(t *testing.T) {
	cases := []struct {
		input string
		want  string
	}{
		{"research", "Research"},
		{"my-research", "My Research"},
		{"background_context", "Background Context"},
		{"multi-word-file-name", "Multi Word File Name"},
	}
	for _, tc := range cases {
		got := extraFileLabel(tc.input)
		if got != tc.want {
			t.Errorf("extraFileLabel(%q) = %q, want %q", tc.input, got, tc.want)
		}
	}
}

func TestDetailModelExtraFileTabs(t *testing.T) {
	planContent := "# Plan"
	detail := WorkItemDetail{
		PlanContent: &planContent,
		ExtraFiles: []ExtraFile{
			{Name: "research", Content: "# Research"},
			{Name: "context", Content: "# Context"},
		},
	}
	m := NewDetailModel("", "test")
	m.detail = &detail
	m.tabHost.SetTabs(m.buildTabs())

	// Expected: Meta, Plan, Notes, Research, Context
	wantLabels := []string{"Meta", "Plan", "Notes", "Research", "Context"}
	if len(m.tabHost.Tabs()) != len(wantLabels) {
		t.Fatalf("got %d tabs, want %d: %v", len(m.tabHost.Tabs()), len(wantLabels), m.tabHost.Tabs())
	}
	for i, want := range wantLabels {
		if m.tabHost.Tabs()[i].Label != want {
			t.Errorf("tab[%d].Label = %q, want %q", i, m.tabHost.Tabs()[i].Label, want)
		}
	}
	// Extra tabs map to TabFile via their "file:<name>" host IDs, which
	// resolve to the matching extraViewports index.
	if got := tabFromHostID(m.tabHost.Tabs()[3].ID); got != TabFile {
		t.Errorf("tab[3] maps to %v, want TabFile", got)
	}
	if got := m.tabHost.Tabs()[3].ID; got != "file:research" {
		t.Errorf("tab[3].ID = %q, want %q", got, "file:research")
	}
	if got := m.tabHost.Tabs()[4].ID; got != "file:context" {
		t.Errorf("tab[4].ID = %q, want %q", got, "file:context")
	}
	m.tabHost.SetActiveID("file:context")
	if got := m.activeExtraIndex(); got != 1 {
		t.Errorf("activeExtraIndex() = %d, want 1", got)
	}
}

func TestDetailModelTabBuilding(t *testing.T) {
	planContent := "# Plan"
	tests := []struct {
		name     string
		detail   WorkItemDetail
		wantTabs []Tab
	}{
		{
			name: "all tabs visible",
			detail: WorkItemDetail{
				PlanContent:     &planContent,
				HasTasks:        true,
				HasExecutionLog: true,
			},
			wantTabs: []Tab{TabMeta, TabPlan, TabNotes, TabTasks, TabExecLog},
		},
		{
			name: "minimal tabs",
			detail: WorkItemDetail{
				PlanContent:     nil,
				HasTasks:        false,
				HasExecutionLog: false,
			},
			wantTabs: []Tab{TabMeta, TabNotes},
		},
		{
			name: "plan and exec log only",
			detail: WorkItemDetail{
				PlanContent:     &planContent,
				HasTasks:        false,
				HasExecutionLog: true,
			},
			wantTabs: []Tab{TabMeta, TabPlan, TabNotes, TabExecLog},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := NewDetailModel("", "test")
			m.detail = &tt.detail
			m.tabHost.SetTabs(m.buildTabs())

			if len(m.tabHost.Tabs()) != len(tt.wantTabs) {
				t.Fatalf("got %d tabs, want %d", len(m.tabHost.Tabs()), len(tt.wantTabs))
			}
			for i, want := range tt.wantTabs {
				if got := m.tabHost.Tabs()[i].ID; got != want.hostID() {
					t.Errorf("tab[%d] = %v, want %v", i, got, want.hostID())
				}
			}
		})
	}
}

func TestDetailModelTabCycling(t *testing.T) {
	planContent := "# Plan"
	m := NewDetailModel("", "test")
	m.detail = &WorkItemDetail{
		PlanContent:     &planContent,
		HasTasks:        true,
		HasExecutionLog: true,
	}
	m.loading = false
	m.tabHost.SetTabs(m.buildTabs())

	// Tab forward through all tabs
	for i := 0; i < len(m.tabHost.Tabs()); i++ {
		if m.ActiveTab() != tabFromHostID(m.tabHost.ActiveID()) {
			t.Fatalf("step %d: ActiveTab mismatch", i)
		}
		m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyTab})
	}

	// Should wrap around to first tab
	if m.tabHost.ActiveIndex() != 0 {
		t.Errorf("after full cycle, active index = %d, want 0", m.tabHost.ActiveIndex())
	}

	// Shift-Tab should go to last tab
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyTab, Mod: tea.ModShift})
	if m.tabHost.ActiveIndex() != len(m.tabHost.Tabs())-1 {
		t.Errorf("after shift-tab from 0, active index = %d, want %d", m.tabHost.ActiveIndex(), len(m.tabHost.Tabs())-1)
	}
}

func TestDetailModelBackToList(t *testing.T) {
	m := NewDetailModel("", "test")
	m.loading = false
	m.detail = &WorkItemDetail{}
	m.tabHost.SetTabs(m.buildTabs())

	// Esc should produce BackToListMsg
	_, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	if cmd == nil {
		t.Fatal("expected a command from Esc")
	}
	msg := cmd()
	if _, ok := msg.(BackToListMsg); !ok {
		t.Errorf("expected BackToListMsg, got %T", msg)
	}
}

func TestDetailModelLoadedMsg(t *testing.T) {
	planContent := "# Test"
	m := NewDetailModel("", "test")

	if !m.loading {
		t.Error("should start in loading state")
	}

	m, _ = m.Update(DetailLoadedMsg{
		Slug: "test",
		Detail: &WorkItemDetail{
			Slug:        "test",
			Title:       "Test Item",
			PlanContent: &planContent,
		},
	})

	if m.loading {
		t.Error("should no longer be loading after DetailLoadedMsg")
	}
	if m.detail == nil {
		t.Fatal("detail should be set")
	}
	if len(m.tabHost.Tabs()) == 0 {
		t.Error("tabs should be built after loading")
	}
}

func TestBuildSearchIndexFallbackNotes(t *testing.T) {
	t.Run("fallback notes produce single Notes (raw) SearchLocation", func(t *testing.T) {
		// Content that has no date headers but has meaningful text after stripping boilerplate.
		notesContent := "# Session Notes\n\nSome freeform text without date headers."
		m := NewDetailModel("", "test")
		m.detail = &WorkItemDetail{}
		m.notesTab = NewNotesTabModel(&notesContent, 80, 24)

		if !m.notesTab.fallback {
			t.Fatal("expected notesTab to be in fallback mode")
		}

		locs := m.BuildSearchIndex()
		var notesLocs []SearchLocation
		for _, l := range locs {
			if l.TabID == TabNotes {
				notesLocs = append(notesLocs, l)
			}
		}

		if len(notesLocs) != 1 {
			t.Fatalf("expected 1 notes SearchLocation, got %d", len(notesLocs))
		}
		if notesLocs[0].Label != "Notes (raw)" {
			t.Errorf("Label = %q, want %q", notesLocs[0].Label, "Notes (raw)")
		}
		if notesLocs[0].Subtitle != "Notes" {
			t.Errorf("Subtitle = %q, want %q", notesLocs[0].Subtitle, "Notes")
		}
		if notesLocs[0].EntryIdx != -1 {
			t.Errorf("EntryIdx = %d, want -1", notesLocs[0].EntryIdx)
		}
	})

	t.Run("empty notes produce no SearchLocation entries", func(t *testing.T) {
		m := NewDetailModel("", "test")
		m.detail = &WorkItemDetail{}
		m.notesTab = NewNotesTabModel(nil, 80, 24)

		if !m.notesTab.empty {
			t.Fatal("expected notesTab to be empty")
		}

		locs := m.BuildSearchIndex()
		for _, l := range locs {
			if l.TabID == TabNotes {
				t.Errorf("expected no TabNotes SearchLocation for empty notes, got %+v", l)
			}
		}
	})

	t.Run("dated notes produce per-entry SearchLocation entries", func(t *testing.T) {
		notesContent := "## 2026-03-24T10:00\nfirst\n## 2026-03-25T14:00\nsecond"
		m := NewDetailModel("", "test")
		m.detail = &WorkItemDetail{}
		m.notesTab = NewNotesTabModel(&notesContent, 80, 24)

		if m.notesTab.empty || m.notesTab.fallback {
			t.Fatal("expected notesTab to have dated entries")
		}

		locs := m.BuildSearchIndex()
		var notesLocs []SearchLocation
		for _, l := range locs {
			if l.TabID == TabNotes {
				notesLocs = append(notesLocs, l)
			}
		}

		if len(notesLocs) != 2 {
			t.Fatalf("expected 2 notes SearchLocations, got %d", len(notesLocs))
		}
		if notesLocs[0].Label != "2026-03-24T10:00" {
			t.Errorf("notesLocs[0].Label = %q, want %q", notesLocs[0].Label, "2026-03-24T10:00")
		}
		if notesLocs[0].EntryIdx != 0 {
			t.Errorf("notesLocs[0].EntryIdx = %d, want 0", notesLocs[0].EntryIdx)
		}
		if notesLocs[1].Label != "2026-03-25T14:00" {
			t.Errorf("notesLocs[1].Label = %q, want %q", notesLocs[1].Label, "2026-03-25T14:00")
		}
		if notesLocs[1].EntryIdx != 1 {
			t.Errorf("notesLocs[1].EntryIdx = %d, want 1", notesLocs[1].EntryIdx)
		}
	})

	t.Run("JumpTo fallback notes switches tab without setting cursor", func(t *testing.T) {
		notesContent := "# Session Notes\n\nFreeform content."
		m := NewDetailModel("", "test")
		m.detail = &WorkItemDetail{}
		m.tabHost.SetTabs(m.buildTabs())
		m.notesTab = NewNotesTabModel(&notesContent, 80, 24)
		m.tabHost.SetActiveID(TabMeta.hostID()) // start on Meta tab

		m.JumpTo(SearchLocation{TabID: TabNotes, Label: "Notes (raw)", EntryIdx: -1})

		// Should have switched to Notes tab
		if m.ActiveTab() != TabNotes {
			t.Errorf("ActiveTab() = %v, want TabNotes", m.ActiveTab())
		}
		// No cursor mutation needed — notesTab.cursor stays at default 0
		if m.notesTab.cursor != 0 {
			t.Errorf("notesTab.cursor = %d, want 0 (unchanged)", m.notesTab.cursor)
		}
	})
}

func TestDetailModelDimensionsAfterWindowThenLoad(t *testing.T) {
	// Simulate the initial-load sequence: WindowSizeMsg arrives before DetailLoadedMsg.
	// After both messages, contentWidth/contentHeight should reflect the window size,
	// not the fallback minimums (20 and 5).
	m := NewDetailModel("", "test")

	// Step 1: parent forwards WindowSizeMsg (as fixed by the initial-load path).
	m, _ = m.Update(tea.WindowSizeMsg{Width: 100, Height: 50})

	// Step 2: detail finishes loading.
	planContent := "# Plan"
	m, _ = m.Update(DetailLoadedMsg{
		Slug: "test",
		Detail: &WorkItemDetail{
			Slug:        "test",
			Title:       "Test Item",
			PlanContent: &planContent,
		},
	})

	// contentWidth = width - 4 = 96, contentHeight = height - 3 = 47
	if got, want := m.contentWidth(), 96; got != want {
		t.Errorf("contentWidth() = %d, want %d", got, want)
	}
	if got, want := m.contentHeight(), 47; got != want {
		t.Errorf("contentHeight() = %d, want %d", got, want)
	}
}

func TestDetailModelPlanViewportTracksResize(t *testing.T) {
	// Regression: DetailModel.Update forwards already-inner dimensions
	// (contentWidth/contentHeight) to tab models on resize. PlanTabModel
	// used to subtract chrome again (-4/-7), shrinking the plan viewport
	// after any terminal resize even though initial load sized correctly.
	m := NewDetailModel("", "test")
	m, _ = m.Update(tea.WindowSizeMsg{Width: 100, Height: 50})

	planContent := "# Plan\n\nSome plan body."
	m, _ = m.Update(DetailLoadedMsg{
		Slug: "test",
		Detail: &WorkItemDetail{
			Slug:        "test",
			Title:       "Test Item",
			PlanContent: &planContent,
		},
	})

	// Initial load sizes the plan viewport to the inner content box.
	if got, want := m.planTab.viewport.Width(), m.contentWidth(); got != want {
		t.Fatalf("after load: plan viewport width = %d, want %d", got, want)
	}
	if got, want := m.planTab.viewport.Height(), m.contentHeight(); got != want {
		t.Fatalf("after load: plan viewport height = %d, want %d", got, want)
	}

	// Terminal resize: the plan viewport must track the new inner box exactly.
	m, _ = m.Update(tea.WindowSizeMsg{Width: 120, Height: 60})
	if got, want := m.planTab.viewport.Width(), m.contentWidth(); got != want {
		t.Errorf("after resize: plan viewport width = %d, want %d (double-subtracted chrome?)", got, want)
	}
	if got, want := m.planTab.viewport.Height(), m.contentHeight(); got != want {
		t.Errorf("after resize: plan viewport height = %d, want %d (double-subtracted chrome?)", got, want)
	}

	// Resizing back must be lossless — repeated resizes must not drift.
	m, _ = m.Update(tea.WindowSizeMsg{Width: 100, Height: 50})
	if got, want := m.planTab.viewport.Width(), 96; got != want {
		t.Errorf("after resize back: plan viewport width = %d, want %d", got, want)
	}
	if got, want := m.planTab.viewport.Height(), 47; got != want {
		t.Errorf("after resize back: plan viewport height = %d, want %d", got, want)
	}
}
