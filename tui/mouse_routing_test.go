package main

// Regression tests for split-pane mouse sensitivity: tab-bar clicks must hit
// the row the tab bar actually renders on (the TopBottom content-start
// arithmetic was off by one — the workspace indicator line consumes one row
// of the top panel's budget), and wheel events must scroll the panel under
// the pointer regardless of which panel holds focus.

import (
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// planDetailModel builds a stateWork model in the given layout with a loaded
// detail carrying plan content, so the detail view renders a Meta + Plan tab bar.
func planDetailModel(t *testing.T, layout config.LayoutMode) model {
	t.Helper()
	items := []work.WorkItem{{Slug: "item-1", Title: "Item One"}}
	m := minimalModel(stateWork, items, nil)
	m.layoutMode = layout
	m.detail = work.NewDetailModel("", "item-1")
	m, _ = updateModel(t, m, tea.WindowSizeMsg{Width: 120, Height: 40})
	// Blank-line-separated numbered lines so renderMarkdown keeps one block
	// per line and the plan tab has real overflow to scroll.
	var planB strings.Builder
	for i := 0; i < 60; i++ {
		fmt.Fprintf(&planB, "plan line %d\n\n", i)
	}
	plan := planB.String()
	m, _ = updateModel(t, m, work.DetailLoadedMsg{
		Slug:   "item-1",
		Detail: &work.WorkItemDetail{Slug: "item-1", Title: "Item One", PlanContent: &plan},
	})
	return m
}

// findInView locates the first rendered row/column of needle in the composed
// view (ANSI-stripped). The column is a display column (mouse-coordinate
// space), not a byte offset — border runes like '│' are multi-byte.
func findInView(t *testing.T, m model, needle string) (row, col int) {
	t.Helper()
	for y, line := range strings.Split(stripANSI(m.viewContent()), "\n") {
		if x := strings.Index(line, needle); x >= 0 {
			return y, lipgloss.Width(line[:x])
		}
	}
	t.Fatalf("%q not found in rendered view", needle)
	return 0, 0
}

// TestTabBarClickActivatesTabAtRenderedRow pins the tab-bar hit-test to the
// row the bar actually renders on, in both layouts. A drifted content-start
// (e.g. the TopBottom +4 off-by-one) makes this click land on empty space
// and leaves the Meta tab active.
func TestTabBarClickActivatesTabAtRenderedRow(t *testing.T) {
	for name, layout := range map[string]config.LayoutMode{
		"top/bottom": config.LayoutTopBottom,
		"left/right": config.LayoutLeftRight,
	} {
		t.Run(name, func(t *testing.T) {
			m := planDetailModel(t, layout)
			row, col := findInView(t, m, "Plan")

			nm, _ := updateModel(t, m, tea.MouseClickMsg{Button: tea.MouseLeft, X: col + 1, Y: row})
			if nm.focusedPanel != panelRight {
				t.Fatalf("click on the detail panel should focus it, got %v", nm.focusedPanel)
			}
			if got := nm.detail.ActiveTab(); got != work.TabPlan {
				t.Errorf("click on rendered Plan label activated tab %v, want TabPlan", got)
			}
		})
	}
}

// TestWheelScrollsPanelUnderPointer pins pointer-positional wheel routing:
// with the list focused, wheeling over the detail panel scrolls the detail
// (focus unchanged), and with the detail focused, wheeling over the list
// moves the list cursor.
func TestWheelScrollsPanelUnderPointer(t *testing.T) {
	t.Run("wheel over detail while list focused", func(t *testing.T) {
		m := planDetailModel(t, config.LayoutTopBottom)
		// Activate the Plan tab (scrollable) via keyboard, then focus the list.
		row, col := findInView(t, m, "Plan")
		m, _ = updateModel(t, m, tea.MouseClickMsg{Button: tea.MouseLeft, X: col + 1, Y: row})
		m.focusedPanel = panelLeft

		before := m.viewContent()
		nm, _ := updateModel(t, m, tea.MouseWheelMsg{Button: tea.MouseWheelDown, X: 60, Y: row + 4})
		if nm.focusedPanel != panelLeft {
			t.Errorf("wheel must not move focus, got %v", nm.focusedPanel)
		}
		if nm.viewContent() == before {
			t.Error("wheel over the detail panel did not scroll it")
		}
	})

	t.Run("wheel over list while detail focused", func(t *testing.T) {
		items := []work.WorkItem{
			{Slug: "item-1", Title: "Item One"},
			{Slug: "item-2", Title: "Item Two"},
		}
		m := minimalModel(stateWork, items, nil)
		m.layoutMode = config.LayoutTopBottom
		m, _ = updateModel(t, m, tea.WindowSizeMsg{Width: 120, Height: 40})
		m.focusedPanel = panelRight

		if got := m.list.CurrentSlug(); got != "item-1" {
			t.Fatalf("initial cursor on %q, want item-1", got)
		}
		nm, _ := updateModel(t, m, tea.MouseWheelMsg{Button: tea.MouseWheelDown, X: 10, Y: 3})
		if got := nm.list.CurrentSlug(); got != "item-2" {
			t.Errorf("wheel over the list left cursor on %q, want item-2", got)
		}
		if nm.focusedPanel != panelRight {
			t.Errorf("wheel must not move focus, got %v", nm.focusedPanel)
		}
	})
}

// terminalModel builds a stateWork model with a spec panel on item-1 whose
// emulator holds more output than the panel height, in terminal mode.
func terminalModel(t *testing.T) model {
	t.Helper()
	items := []work.WorkItem{{Slug: "item-1", Title: "Item One"}}
	m := minimalModel(stateWork, items, nil)
	m.layoutMode = config.LayoutTopBottom
	m.setSpecPanel("item-1", work.NewSpecPanelModel("item-1"))
	m, _ = updateModel(t, m, tea.WindowSizeMsg{Width: 120, Height: 40})
	var out strings.Builder
	for i := 0; i < 100; i++ {
		fmt.Fprintf(&out, "output line %02d\r\n", i)
	}
	m, _ = updateModel(t, m, work.TerminalOutputMsg{Slug: "item-1", Data: []byte(out.String())})
	m.terminalMode = true
	return m
}

// TestWheelScrollsTerminalScrollback pins wheel routing to the spec panel's
// scrollback in terminal mode: both with the terminal focused (attached) and
// with the list focused while the terminal stays visible (detached) — the
// state Esc-Esc now leaves behind.
func TestWheelScrollsTerminalScrollback(t *testing.T) {
	for name, focus := range map[string]panelFocus{
		"attached (terminal focused)": panelRight,
		"detached (list focused)":     panelLeft,
	} {
		t.Run(name, func(t *testing.T) {
			m := terminalModel(t)
			m.focusedPanel = focus

			panel, ok := m.currentSpecPanel()
			if !ok {
				t.Fatal("no spec panel on current item")
			}
			before := panel.View()

			nm, _ := updateModel(t, m, tea.MouseWheelMsg{Button: tea.MouseWheelUp, X: 60, Y: 20})
			panel, ok = nm.currentSpecPanel()
			if !ok {
				t.Fatal("spec panel gone after wheel")
			}
			if panel.View() == before {
				t.Error("wheel up over the terminal did not scroll its scrollback")
			}
			if nm.focusedPanel != focus {
				t.Errorf("wheel moved focus: %v -> %v", focus, nm.focusedPanel)
			}
			if !nm.terminalMode {
				t.Error("wheel must not leave terminal mode")
			}

			// Wheel down at the live edge returns to the live view.
			nm2, _ := updateModel(t, nm, tea.MouseWheelMsg{Button: tea.MouseWheelDown, X: 60, Y: 20})
			panel, _ = nm2.currentSpecPanel()
			if panel.View() != before {
				t.Error("wheel down did not return to the live view")
			}
		})
	}
}
