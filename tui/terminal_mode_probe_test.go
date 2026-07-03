package main

// Throwaway probe for the axis D terminal-mode behavior inventory
// (work item tui-design-exploration-pass). Drives the real Update path
// with a fake spec panel to corroborate code-traced matrix cells,
// primarily in the "terminal active-but-unfocused" state. Untracked
// prototype file — not part of the regular suite.

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/work"
)

// activeUnfocusedModel: stateWork, spec panel on item-1, cursor on item-1,
// terminalMode true, focus on the left list — the state the app lands in
// after launching a spec from the confirm modal (sessionLaunchedFromModal).
func activeUnfocusedModel() model {
	m := workContractModel()
	m.setSpecPanel("item-1", work.NewSpecPanelModel("item-1"))
	m.terminalMode = true
	m.focusedPanel = panelLeft
	return m
}

func isQuitCmd(cmd tea.Cmd) bool {
	if cmd == nil {
		return false
	}
	_, ok := cmd().(tea.QuitMsg)
	return ok
}

func TestProbeActiveUnfocusedAdvertisedHints(t *testing.T) {
	m := activeUnfocusedModel()
	if got := m.keymapContext(); got != kmWorkList {
		t.Fatalf("active-unfocused context = %v, want kmWorkList", got)
	}
	hints := stripANSI(strings.Join(m.statusBarHints(kmWorkList), " · "))
	for _, want := range []string{"q quit", "? help", "K knowledge", "S settings", "f follow-ups"} {
		if !strings.Contains(hints, want) {
			t.Errorf("status bar does not advertise %q (hints: %s)", want, hints)
		}
	}
}

func TestProbeActiveUnfocusedDeadKeys(t *testing.T) {
	t.Run("q does not quit", func(t *testing.T) {
		nm, cmd := updateModel(t, activeUnfocusedModel(), press('q'))
		if isQuitCmd(cmd) {
			t.Error("q quit the app despite terminalMode guard")
		}
		if nm.state != stateWork {
			t.Errorf("state changed to %v", nm.state)
		}
	})
	t.Run("? does not open help", func(t *testing.T) {
		nm, _ := updateModel(t, activeUnfocusedModel(), press('?'))
		if nm.showHelp {
			t.Error("help opened")
		}
	})
	t.Run("K does not open knowledge browser", func(t *testing.T) {
		nm, _ := updateModel(t, activeUnfocusedModel(), press('K'))
		if nm.state != stateWork {
			t.Errorf("state = %v", nm.state)
		}
	})
	t.Run("S does not open settings", func(t *testing.T) {
		nm, _ := updateModel(t, activeUnfocusedModel(), press('S'))
		if nm.settingsActive {
			t.Error("settings modal opened")
		}
	})
	t.Run("f does not open follow-ups", func(t *testing.T) {
		nm, _ := updateModel(t, activeUnfocusedModel(), press('f'))
		if nm.state != stateWork {
			t.Errorf("state = %v", nm.state)
		}
	})
	t.Run("ctrl+t does not toggle from left focus", func(t *testing.T) {
		nm, _ := updateModel(t, activeUnfocusedModel(), press('t', tea.ModCtrl))
		if !nm.terminalMode {
			t.Error("ctrl+t toggled terminalMode from the left panel")
		}
	})
}

func TestProbeActiveUnfocusedLiveKeys(t *testing.T) {
	t.Run("ctrl+c terminates subprocess instead of quitting", func(t *testing.T) {
		_, cmd := updateModel(t, activeUnfocusedModel(), press('c', tea.ModCtrl))
		if cmd == nil {
			t.Fatal("ctrl+c produced no command")
		}
		msg := cmd()
		tm, ok := msg.(work.TerminalTerminateMsg)
		if !ok {
			t.Fatalf("ctrl+c produced %T, want work.TerminalTerminateMsg", msg)
		}
		if tm.Slug != "item-1" {
			t.Errorf("terminate slug = %q", tm.Slug)
		}
	})
	t.Run("t switches to settlement", func(t *testing.T) {
		nm, _ := updateModel(t, activeUnfocusedModel(), press('t'))
		if nm.state != stateSettlement {
			t.Errorf("state = %v, want stateSettlement", nm.state)
		}
		if nm.terminalMode {
			t.Error("terminalMode not reset")
		}
	})
	t.Run("/ opens search popup", func(t *testing.T) {
		nm, _ := updateModel(t, activeUnfocusedModel(), press('/'))
		if !nm.popupActive {
			t.Error("popup did not open")
		}
	})
	t.Run("A opens archive confirm modal", func(t *testing.T) {
		nm, _ := updateModel(t, activeUnfocusedModel(), press('A'))
		if nm.confirmAction != "archive" {
			t.Errorf("confirmAction = %q", nm.confirmAction)
		}
	})
	t.Run("s attaches focus to running terminal", func(t *testing.T) {
		m := activeUnfocusedModel()
		nm, cmd := updateModel(t, m, press('s'))
		if cmd == nil {
			t.Fatal("s produced no command")
		}
		nm, _ = updateModel(t, nm, cmd())
		if nm.focusedPanel != panelRight || !nm.terminalMode {
			t.Errorf("s did not attach: focus=%v terminalMode=%v", nm.focusedPanel, nm.terminalMode)
		}
	})
}

// TestProbeCtrlTChoiceLostOnCursorMove: ctrl+t selects detail view, but
// loadDetail re-derives terminalMode from hasSpecPanel on every cursor
// change, so navigating away and back silently reverts to terminal view.
func TestProbeCtrlTChoiceLostOnCursorMove(t *testing.T) {
	m := workContractModel()
	m.setSpecPanel("item-1", work.NewSpecPanelModel("item-1"))
	m.terminalMode = true
	m.focusedPanel = panelRight

	m, _ = updateModel(t, m, press('t', tea.ModCtrl)) // choose detail view
	if m.terminalMode {
		t.Fatal("ctrl+t did not switch to detail")
	}
	m, _ = updateModel(t, m, press(tea.KeyEscape)) // back to list
	if m.focusedPanel != panelLeft {
		t.Fatal("esc did not return focus to list")
	}
	m, _ = updateModel(t, m, press('j')) // item-2 (no panel)
	if m.terminalMode {
		t.Fatal("terminalMode true on item without panel")
	}
	m, _ = updateModel(t, m, press('k')) // back to item-1
	if !m.terminalMode {
		t.Error("expected auto-derive to re-enable terminalMode (ctrl+t choice lost)")
	}
}

// TestProbeDetachResetsTerminalMode: Esc-Esc detach flips the right panel
// back to detail view (terminalMode=false), not just focus.
func TestProbeDetachResetsTerminalMode(t *testing.T) {
	m := workContractModel()
	m.setSpecPanel("item-1", work.NewSpecPanelModel("item-1"))
	m.terminalMode = true
	m.focusedPanel = panelRight
	nm, _ := updateModel(t, m, work.TerminalDetachMsg{Slug: "item-1"})
	if nm.focusedPanel != panelLeft {
		t.Error("detach did not move focus to list")
	}
	if nm.terminalMode {
		t.Error("detach left terminalMode true")
	}
}

func TestProbeFollowupActiveUnfocused(t *testing.T) {
	fuModel := func() model {
		m := followupContractModel()
		m.width = 120
		m.height = 40
		m.setSpecPanel("fu-1", work.NewSpecPanelModel("fu-1"))
		m.terminalMode = true
		m.focusedPanel = panelLeft
		return m
	}
	t.Run("w does not return to work list", func(t *testing.T) {
		nm, _ := updateModel(t, fuModel(), press('w'))
		if nm.state != stateFollowUps {
			t.Errorf("state = %v", nm.state)
		}
	})
	t.Run("Esc still exits via list dismiss", func(t *testing.T) {
		nm, cmd := updateModel(t, fuModel(), press(tea.KeyEscape))
		if cmd == nil {
			t.Skip("no command — Esc dead in this state")
		}
		msg := cmd()
		nm, _ = updateModel(t, nm, msg)
		_ = nm
	})
	t.Run("q does not quit", func(t *testing.T) {
		_, cmd := updateModel(t, fuModel(), press('q'))
		if isQuitCmd(cmd) {
			t.Error("q quit the app")
		}
	})
}
