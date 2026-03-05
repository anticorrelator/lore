package work

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
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
	m, _ = m.Update(tea.MouseMsg{Button: tea.MouseButtonWheelDown})
	if m.cursor == 0 {
		t.Fatal("cursor did not advance after WheelDown")
	}
	afterDown := m.cursor

	// Wheel down again
	m, _ = m.Update(tea.MouseMsg{Button: tea.MouseButtonWheelDown})
	if m.cursor <= afterDown {
		t.Errorf("cursor did not advance further: got %d, was %d", m.cursor, afterDown)
	}

	// Wheel up should reverse
	beforeUp := m.cursor
	m, _ = m.Update(tea.MouseMsg{Button: tea.MouseButtonWheelUp})
	if m.cursor >= beforeUp {
		t.Errorf("cursor did not reverse after WheelUp: got %d, was %d", m.cursor, beforeUp)
	}

	// Wheel up back to start
	for i := 0; i < 20; i++ {
		m, _ = m.Update(tea.MouseMsg{Button: tea.MouseButtonWheelUp})
	}
	if m.cursor != 0 {
		t.Errorf("cursor should clamp at 0 after repeated WheelUp, got %d", m.cursor)
	}

	// Wheel down to the end
	for i := 0; i < 20; i++ {
		m, _ = m.Update(tea.MouseMsg{Button: tea.MouseButtonWheelDown})
	}
	visible := m.visibleRows()
	lastVisible := visible[len(visible)-1]
	if m.cursor != lastVisible {
		t.Errorf("cursor should clamp at last visible row (%d), got %d", lastVisible, m.cursor)
	}
}
