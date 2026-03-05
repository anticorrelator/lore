package work

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
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
	m.tabs = m.buildTabs()

	// Expected: Meta, Plan, Notes, Research, Context
	wantLabels := []string{"Meta", "Plan", "Notes", "Research", "Context"}
	if len(m.tabs) != len(wantLabels) {
		t.Fatalf("got %d tabs, want %d: %v", len(m.tabs), len(wantLabels), m.tabs)
	}
	for i, want := range wantLabels {
		if m.tabs[i].label != want {
			t.Errorf("tab[%d].label = %q, want %q", i, m.tabs[i].label, want)
		}
	}
	// Extra tabs should have TabFile id and correct extraIndex
	if m.tabs[3].id != TabFile {
		t.Errorf("tab[3].id = %v, want TabFile", m.tabs[3].id)
	}
	if m.tabs[3].extraIndex != 0 {
		t.Errorf("tab[3].extraIndex = %d, want 0", m.tabs[3].extraIndex)
	}
	if m.tabs[4].extraIndex != 1 {
		t.Errorf("tab[4].extraIndex = %d, want 1", m.tabs[4].extraIndex)
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
			m.tabs = m.buildTabs()

			if len(m.tabs) != len(tt.wantTabs) {
				t.Fatalf("got %d tabs, want %d", len(m.tabs), len(tt.wantTabs))
			}
			for i, want := range tt.wantTabs {
				if m.tabs[i].id != want {
					t.Errorf("tab[%d] = %v, want %v", i, m.tabs[i].id, want)
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
	m.tabs = m.buildTabs()
	m.activeTab = 0

	// Tab forward through all tabs
	for i := 0; i < len(m.tabs); i++ {
		if m.ActiveTab() != m.tabs[m.activeTab].id {
			t.Fatalf("step %d: ActiveTab mismatch", i)
		}
		m, _ = m.Update(tea.KeyMsg{Type: tea.KeyTab})
	}

	// Should wrap around to first tab
	if m.activeTab != 0 {
		t.Errorf("after full cycle, activeTab = %d, want 0", m.activeTab)
	}

	// Shift-Tab should go to last tab
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyShiftTab})
	if m.activeTab != len(m.tabs)-1 {
		t.Errorf("after shift-tab from 0, activeTab = %d, want %d", m.activeTab, len(m.tabs)-1)
	}
}

func TestDetailModelBackToList(t *testing.T) {
	m := NewDetailModel("", "test")
	m.loading = false
	m.detail = &WorkItemDetail{}
	m.tabs = m.buildTabs()

	// Esc should produce BackToListMsg
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEsc})
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
	if len(m.tabs) == 0 {
		t.Error("tabs should be built after loading")
	}
}
