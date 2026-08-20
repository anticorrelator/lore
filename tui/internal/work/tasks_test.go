package work

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

func TestTasksModelMouseScroll(t *testing.T) {
	tf := TasksFile{
		Phases: []Phase{
			{
				PhaseNumber: 1,
				PhaseName:   "Setup",
				Objective:   "Set things up",
				Tasks: []Task{
					{ID: "1.1", Subject: "Task A"},
					{ID: "1.2", Subject: "Task B"},
					{ID: "1.3", Subject: "Task C"},
				},
			},
			{
				PhaseNumber: 2,
				PhaseName:   "Build",
				Objective:   "Build things",
				Tasks: []Task{
					{ID: "2.1", Subject: "Task D"},
					{ID: "2.2", Subject: "Task E"},
					{ID: "2.3", Subject: "Task F"},
				},
			},
		},
	}

	m := newTasksModelFromFile(tf)
	m.height = 3 // force a scroll window smaller than the row count

	// Cursor starts at 0 (first phase header)
	if m.cursor != 0 {
		t.Fatalf("initial cursor = %d, want 0", m.cursor)
	}

	// Wheel down should advance cursor
	m, _ = m.Update(tea.MouseWheelMsg{Button: tea.MouseWheelDown})
	if m.cursor == 0 {
		t.Fatal("cursor did not advance after WheelDown")
	}
	afterDown := m.cursor

	// Wheel down again
	m, _ = m.Update(tea.MouseWheelMsg{Button: tea.MouseWheelDown})
	if m.cursor <= afterDown {
		t.Errorf("cursor did not advance further: got %d, was %d", m.cursor, afterDown)
	}

	// Wheel up should reverse
	beforeUp := m.cursor
	m, _ = m.Update(tea.MouseWheelMsg{Button: tea.MouseWheelUp})
	if m.cursor >= beforeUp {
		t.Errorf("cursor did not reverse after WheelUp: got %d, was %d", m.cursor, beforeUp)
	}

	// Wheel up back to start
	for i := 0; i < 20; i++ {
		m, _ = m.Update(tea.MouseWheelMsg{Button: tea.MouseWheelUp})
	}
	if m.cursor != 0 {
		t.Errorf("cursor should clamp at 0 after repeated WheelUp, got %d", m.cursor)
	}

	// Wheel down to the end
	for i := 0; i < 20; i++ {
		m, _ = m.Update(tea.MouseWheelMsg{Button: tea.MouseWheelDown})
	}
	visible := m.visibleRows()
	lastVisible := visible[len(visible)-1]
	if m.cursor != lastVisible {
		t.Errorf("cursor should clamp at last visible row (%d), got %d", lastVisible, m.cursor)
	}
}

func TestTasksModelPrefersTopLevelTasks(t *testing.T) {
	tf := TasksFile{
		Tasks: []Task{
			{ID: "task-1", Subject: "Task A"},
			{ID: "task-2", Subject: "Task B", BlockedBy: []string{"task-1"}},
		},
		Phases: []Phase{
			{PhaseNumber: 1, PhaseName: "Legacy", Tasks: []Task{{ID: "old-1", Subject: "Task Z"}}},
		},
	}

	m := newTasksModelFromFile(tf)
	if m.IsEmpty() {
		t.Fatal("model is empty for a flat tasks file")
	}
	if len(m.rows) != 2 {
		t.Fatalf("rows = %d, want 2 (the top-level tasks, not the phase fallback)", len(m.rows))
	}
	for _, row := range m.rows {
		if row.isPhase {
			t.Fatal("a flat tasks file rendered a phase header")
		}
	}
	if got := len(m.visibleRows()); got != 2 {
		t.Fatalf("visibleRows = %d, want 2 — flat tasks have no phase header to be hidden under", got)
	}
	view := m.View()
	if !strings.Contains(view, "Task A") || !strings.Contains(view, "Task B") {
		t.Fatalf("view omitted a flat task:\n%s", view)
	}
	if strings.Contains(view, "Task Z") {
		t.Fatalf("view rendered the phase fallback alongside top-level tasks:\n%s", view)
	}
}

func TestTasksModelNeitherShapeExplainsItself(t *testing.T) {
	m := newTasksModelFromFile(TasksFile{})
	if !m.IsEmpty() {
		t.Fatal("model is not empty for a tasks file declaring no units")
	}
	view := m.View()
	if !strings.Contains(view, "regen-tasks") {
		t.Fatalf("view does not say what to do:\n%s", view)
	}
}
