package main

import (
	"fmt"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/followup"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// fakeCSIMsg simulates bubbletea's unexported unknownCSISequenceMsg,
// which is a []byte ([]uint8 under the hood). The reflect check in
// translateCSIu detects any []uint8 slice, so this plain []byte works.
type fakeCSIMsg []byte

func TestTranslateCSIuEnter(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[13u"))
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyEnter {
		t.Errorf("expected KeyEnter, got %v", km.Type)
	}
}

func TestTranslateCSIuEsc(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[27u"))
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyEscape {
		t.Errorf("expected KeyEscape, got %v", km.Type)
	}
}

func TestTranslateCSIuTab(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[9u"))
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyTab {
		t.Errorf("expected KeyTab, got %v", km.Type)
	}
}

func TestTranslateCSIuBackspace(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[127u"))
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyBackspace {
		t.Errorf("expected KeyBackspace, got %v", km.Type)
	}
}

func TestTranslateCSIuShiftEnter(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[13;2u"))
	got := translateCSIu(msg)
	if _, ok := got.(shiftEnterMsg); !ok {
		t.Fatalf("expected shiftEnterMsg, got %T", got)
	}
}

func TestTranslateCSIuAltEnter(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[13;3u"))
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyEnter {
		t.Errorf("expected KeyEnter, got %v", km.Type)
	}
	if !km.Alt {
		t.Errorf("expected Alt=true")
	}
}

func TestTranslateCSIuCtrlC(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[99;5u"))
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyCtrlC {
		t.Errorf("expected KeyCtrlC, got %v", km.Type)
	}
}

func TestTranslateCSIuCtrlD(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[100;5u"))
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyCtrlD {
		t.Errorf("expected KeyCtrlD, got %v", km.Type)
	}
}

func TestTranslateCSIuPrintableChar(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[97u"))
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyRunes {
		t.Errorf("expected KeyRunes, got %v", km.Type)
	}
	if len(km.Runes) != 1 || km.Runes[0] != 'a' {
		t.Errorf("expected Runes=['a'], got %v", km.Runes)
	}
}

func TestTranslateCSIuAltPrintable(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[49;3u"))
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyRunes {
		t.Errorf("expected KeyRunes, got %v", km.Type)
	}
	if !km.Alt {
		t.Errorf("expected Alt=true")
	}
	if len(km.Runes) != 1 || km.Runes[0] != '1' {
		t.Errorf("expected Runes=['1'], got %v", km.Runes)
	}
}

func TestTranslateCSIuSpace(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[32u"))
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyRunes {
		t.Errorf("expected KeyRunes, got %v", km.Type)
	}
	if len(km.Runes) != 1 || km.Runes[0] != ' ' {
		t.Errorf("expected Runes=[' '], got %v", km.Runes)
	}
}

func TestTranslateCSIuNonCSIPassthrough(t *testing.T) {
	msg := tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'a'}}
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyRunes || len(km.Runes) != 1 || km.Runes[0] != 'a' {
		t.Errorf("expected unchanged KeyMsg{Runes: ['a']}, got %v", km)
	}
}

func TestTranslateCSIuNonUFinalPassthrough(t *testing.T) {
	// CSI sequence that doesn't end in 'u' should pass through.
	msg := fakeCSIMsg([]byte("\x1b[13~"))
	got := translateCSIu(msg)
	if _, ok := got.(fakeCSIMsg); !ok {
		t.Fatalf("expected fakeCSIMsg passthrough, got %T", got)
	}
}

// --- Keybind contract tests ---
//
// These verify that every keybind advertised in a modal's render function
// produces the correct tea.Msg when sent as a kitty CSI u sequence.
// If a new keybind is added to a modal's UI but the CSI u parser can't
// translate it, these tests fail — catching the regression before it ships.

// csiuSeq builds a CSI u byte sequence: ESC [ <codepoint> [; <modifier>] u
func csiuSeq(codepoint int, modifier int) fakeCSIMsg {
	if modifier <= 1 {
		return fakeCSIMsg([]byte(fmt.Sprintf("\x1b[%du", codepoint)))
	}
	return fakeCSIMsg([]byte(fmt.Sprintf("\x1b[%d;%du", codepoint, modifier)))
}

// TestSpecConfirmModalKeybindContract verifies that the keybinds displayed in
// renderSpecConfirmModal (Alt+1, Alt+2, Enter, Esc, Shift+Enter) all produce
// the correct tea.Msg via translateCSIu.
func TestSpecConfirmModalKeybindContract(t *testing.T) {
	tests := []struct {
		label   string
		seq     fakeCSIMsg
		checkFn func(t *testing.T, msg tea.Msg)
	}{
		{
			label: "Enter (launch)",
			seq:   csiuSeq(13, 1),
			checkFn: func(t *testing.T, msg tea.Msg) {
				km := assertKeyMsg(t, msg)
				if km.Type != tea.KeyEnter {
					t.Errorf("expected KeyEnter, got %v", km.Type)
				}
			},
		},
		{
			label: "Esc (cancel)",
			seq:   csiuSeq(27, 1),
			checkFn: func(t *testing.T, msg tea.Msg) {
				km := assertKeyMsg(t, msg)
				if km.Type != tea.KeyEscape {
					t.Errorf("expected KeyEscape, got %v", km.Type)
				}
			},
		},
		{
			label: "Shift+Enter (newline)",
			seq:   csiuSeq(13, 2),
			checkFn: func(t *testing.T, msg tea.Msg) {
				if _, ok := msg.(shiftEnterMsg); !ok {
					t.Fatalf("expected shiftEnterMsg, got %T", msg)
				}
			},
		},
		{
			label: "Alt+1 (toggle short mode)",
			seq:   csiuSeq('1', 3),
			checkFn: func(t *testing.T, msg tea.Msg) {
				km := assertKeyMsg(t, msg)
				assertKeyString(t, km, "alt+1")
			},
		},
		{
			label: "Alt+2 (toggle skip confirm)",
			seq:   csiuSeq('2', 3),
			checkFn: func(t *testing.T, msg tea.Msg) {
				km := assertKeyMsg(t, msg)
				assertKeyString(t, km, "alt+2")
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.label, func(t *testing.T) {
			tt.checkFn(t, translateCSIu(tt.seq))
		})
	}
}

// TestAIModalKeybindContract verifies keybinds used by the AI input modal.
func TestAIModalKeybindContract(t *testing.T) {
	tests := []struct {
		label   string
		seq     fakeCSIMsg
		checkFn func(t *testing.T, msg tea.Msg)
	}{
		{
			label: "Enter (submit)",
			seq:   csiuSeq(13, 1),
			checkFn: func(t *testing.T, msg tea.Msg) {
				km := assertKeyMsg(t, msg)
				if km.Type != tea.KeyEnter {
					t.Errorf("expected KeyEnter, got %v", km.Type)
				}
			},
		},
		{
			label: "Esc (cancel)",
			seq:   csiuSeq(27, 1),
			checkFn: func(t *testing.T, msg tea.Msg) {
				km := assertKeyMsg(t, msg)
				if km.Type != tea.KeyEscape {
					t.Errorf("expected KeyEscape, got %v", km.Type)
				}
			},
		},
		{
			label: "Shift+Enter (newline)",
			seq:   csiuSeq(13, 2),
			checkFn: func(t *testing.T, msg tea.Msg) {
				if _, ok := msg.(shiftEnterMsg); !ok {
					t.Fatalf("expected shiftEnterMsg, got %T", msg)
				}
			},
		},
		{
			label: "Alt+Enter (newline)",
			seq:   csiuSeq(13, 3),
			checkFn: func(t *testing.T, msg tea.Msg) {
				km := assertKeyMsg(t, msg)
				if km.Type != tea.KeyEnter {
					t.Errorf("expected KeyEnter, got %v", km.Type)
				}
				if !km.Alt {
					t.Error("expected Alt=true")
				}
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.label, func(t *testing.T) {
			tt.checkFn(t, translateCSIu(tt.seq))
		})
	}
}

// TestTypedCharactersInKittyMode verifies that regular character input
// is correctly translated from CSI u to KeyRunes. This prevents the
// "modal freezes because typed characters don't reach the textarea" regression.
func TestTypedCharactersInKittyMode(t *testing.T) {
	chars := "abcdefghijklmnopqrstuvwxyz0123456789 "
	for _, c := range chars {
		t.Run(fmt.Sprintf("char_%c", c), func(t *testing.T) {
			got := translateCSIu(csiuSeq(int(c), 1))
			km := assertKeyMsg(t, got)
			if km.Type != tea.KeyRunes {
				t.Errorf("char %c: expected KeyRunes, got %v", c, km.Type)
			}
			if len(km.Runes) != 1 || km.Runes[0] != c {
				t.Errorf("char %c: expected rune %c, got %v", c, c, km.Runes)
			}
		})
	}
}

// --- buildPaneConfig tests ---

// minimalModel constructs the smallest model that buildPaneConfig can operate on.
func minimalModel(state appState, workItems []work.WorkItem, fuItems []followup.FollowUpItem) model {
	return model{
		state:          state,
		list:           work.NewListModel(workItems),
		detail:         work.NewDetailModel("", ""),
		followupList:   followup.NewListModel(fuItems),
		followupDetail: followup.NewDetailModel(""),
		specPanels:     make(map[string]work.SpecPanelModel),
	}
}

func TestBuildPaneConfigStateWorkEmptyList(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	cfg := m.buildPaneConfig()

	if cfg.state != stateWork {
		t.Errorf("state = %v, want stateWork", cfg.state)
	}
	if cfg.listTitle != "Active" {
		t.Errorf("listTitle = %q, want %q", cfg.listTitle, "Active")
	}
	if cfg.detailTitle != "Detail" {
		t.Errorf("detailTitle = %q, want %q", cfg.detailTitle, "Detail")
	}
	if cfg.listItemCount != 0 {
		t.Errorf("listItemCount = %d, want 0", cfg.listItemCount)
	}
	if cfg.fuItemCount != 0 {
		t.Errorf("fuItemCount = %d, want 0", cfg.fuItemCount)
	}
	if cfg.filterAnnotW != 25 {
		t.Errorf("filterAnnotW = %d, want 25", cfg.filterAnnotW)
	}
}

func TestBuildPaneConfigStateWorkWithItems(t *testing.T) {
	items := []work.WorkItem{
		{Slug: "item-1", Title: "Item One", Status: "active"},
		{Slug: "item-2", Title: "Item Two", Status: "active"},
	}
	m := minimalModel(stateWork, items, nil)
	cfg := m.buildPaneConfig()

	if cfg.state != stateWork {
		t.Errorf("state = %v, want stateWork", cfg.state)
	}
	// listTitle includes count when items present
	if !strings.Contains(cfg.listTitle, "2") {
		t.Errorf("listTitle = %q, want it to contain item count 2", cfg.listTitle)
	}
	if cfg.listItemCount != 2 {
		t.Errorf("listItemCount = %d, want 2", cfg.listItemCount)
	}
}

func TestBuildPaneConfigStateFollowUpsEmptyList(t *testing.T) {
	m := minimalModel(stateFollowUps, nil, nil)
	cfg := m.buildPaneConfig()

	if cfg.state != stateFollowUps {
		t.Errorf("state = %v, want stateFollowUps", cfg.state)
	}
	if cfg.listTitle != "Follow-ups" {
		t.Errorf("listTitle = %q, want %q", cfg.listTitle, "Follow-ups")
	}
	if cfg.detailTitle != "Detail" {
		t.Errorf("detailTitle = %q, want %q", cfg.detailTitle, "Detail")
	}
	if cfg.fuItemCount != 0 {
		t.Errorf("fuItemCount = %d, want 0", cfg.fuItemCount)
	}
	if cfg.filterAnnotW != 25 {
		t.Errorf("filterAnnotW = %d, want 25", cfg.filterAnnotW)
	}
}

func TestBuildPaneConfigStateFollowUpsWithItems(t *testing.T) {
	fuItems := []followup.FollowUpItem{
		{ID: "fu-1", Title: "Follow Up One", Status: "open"},
		{ID: "fu-2", Title: "Follow Up Two", Status: "pending"},
	}
	m := minimalModel(stateFollowUps, nil, fuItems)
	cfg := m.buildPaneConfig()

	if cfg.state != stateFollowUps {
		t.Errorf("state = %v, want stateFollowUps", cfg.state)
	}
	// listTitle includes count when items present
	if !strings.Contains(cfg.listTitle, "2") {
		t.Errorf("listTitle = %q, want it to contain item count 2", cfg.listTitle)
	}
	if cfg.fuItemCount != 2 {
		t.Errorf("fuItemCount = %d, want 2", cfg.fuItemCount)
	}
}

func TestBuildPaneConfigStatesDontCrossContaminate(t *testing.T) {
	workItems := []work.WorkItem{
		{Slug: "w-1", Title: "Work One", Status: "active"},
	}
	fuItems := []followup.FollowUpItem{
		{ID: "fu-1", Title: "FU One", Status: "open"},
		{ID: "fu-2", Title: "FU Two", Status: "open"},
	}

	mWork := minimalModel(stateWork, workItems, fuItems)
	cfgWork := mWork.buildPaneConfig()
	if cfgWork.state != stateWork {
		t.Errorf("stateWork model: state = %v", cfgWork.state)
	}
	// listItemCount reflects work items (1), fuItemCount reflects follow-ups (2)
	if cfgWork.listItemCount != 1 {
		t.Errorf("stateWork: listItemCount = %d, want 1", cfgWork.listItemCount)
	}
	if cfgWork.fuItemCount != 2 {
		t.Errorf("stateWork: fuItemCount = %d, want 2", cfgWork.fuItemCount)
	}

	mFU := minimalModel(stateFollowUps, workItems, fuItems)
	cfgFU := mFU.buildPaneConfig()
	if cfgFU.state != stateFollowUps {
		t.Errorf("stateFollowUps model: state = %v", cfgFU.state)
	}
	if cfgFU.listItemCount != 1 {
		t.Errorf("stateFollowUps: listItemCount = %d, want 1", cfgFU.listItemCount)
	}
	if cfgFU.fuItemCount != 2 {
		t.Errorf("stateFollowUps: fuItemCount = %d, want 2", cfgFU.fuItemCount)
	}
}

func TestBuildPaneConfigFilterAnnotWConsistentAcrossStates(t *testing.T) {
	mWork := minimalModel(stateWork, nil, nil)
	mFU := minimalModel(stateFollowUps, nil, nil)
	wW := mWork.buildPaneConfig().filterAnnotW
	wFU := mFU.buildPaneConfig().filterAnnotW
	if wW != wFU {
		t.Errorf("filterAnnotW differs: stateWork=%d stateFollowUps=%d", wW, wFU)
	}
}

// --- handlePanelRouting tests ---

// noopCallbacks returns a panelCallbacks where every field is a no-op.
// Tests override only the fields they care about.
func noopCallbacks() panelCallbacks {
	return panelCallbacks{
		currentSlug: func() string { return "" },
		loadDetail:  func(string) tea.Cmd { return nil },
		specPanelFn: func() (work.SpecPanelModel, bool) { return work.SpecPanelModel{}, false },
		listUpdate:  func(tea.Msg) (tea.Cmd, string, string) { return nil, "", "" },
		detailUpdate: func(tea.Msg) tea.Cmd { return nil },
	}
}

func TestHandlePanelRoutingMouseClickLeftPanel(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	m.layoutMode = config.LayoutLeftRight
	m.focusedPanel = panelRight // start on right, click should move to left
	m.width = 120
	m.height = 40

	msg := tea.MouseMsg{
		Action: tea.MouseActionPress,
		Button: tea.MouseButtonLeft,
		X:      10, // well within left panel (< leftPanelWidth+2 = 42)
		Y:      5,
	}
	_, consumed := handlePanelRouting(&m, msg, noopCallbacks())
	if !consumed {
		t.Error("expected mouse msg to be consumed")
	}
	if m.focusedPanel != panelLeft {
		t.Errorf("focusedPanel = %v, want panelLeft", m.focusedPanel)
	}
}

func TestHandlePanelRoutingMouseClickRightPanel(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	m.layoutMode = config.LayoutLeftRight
	m.focusedPanel = panelLeft
	m.width = 120
	m.height = 40

	msg := tea.MouseMsg{
		Action: tea.MouseActionPress,
		Button: tea.MouseButtonLeft,
		X:      60, // right of boundary (leftPanelWidth+2 = 42)
		Y:      5,
	}
	_, consumed := handlePanelRouting(&m, msg, noopCallbacks())
	if !consumed {
		t.Error("expected mouse msg to be consumed")
	}
	if m.focusedPanel != panelRight {
		t.Errorf("focusedPanel = %v, want panelRight", m.focusedPanel)
	}
}

func TestHandlePanelRoutingMouseClickTopBottomTopPanel(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	m.layoutMode = config.LayoutTopBottom
	m.focusedPanel = panelRight
	m.width = 120
	m.height = 40

	msg := tea.MouseMsg{
		Action: tea.MouseActionPress,
		Button: tea.MouseButtonLeft,
		X:      30,
		Y:      2, // within top panel (topPanelHeight ~= 10 for height=40)
	}
	_, consumed := handlePanelRouting(&m, msg, noopCallbacks())
	if !consumed {
		t.Error("expected mouse msg to be consumed")
	}
	if m.focusedPanel != panelLeft {
		t.Errorf("focusedPanel = %v, want panelLeft", m.focusedPanel)
	}
}

func TestHandlePanelRoutingTabFocusesRight(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	m.focusedPanel = panelLeft

	msg := tea.KeyMsg{Type: tea.KeyTab}
	_, consumed := handlePanelRouting(&m, msg, noopCallbacks())
	if !consumed {
		t.Error("tab should be consumed")
	}
	if m.focusedPanel != panelRight {
		t.Errorf("focusedPanel = %v, want panelRight", m.focusedPanel)
	}
}

func TestHandlePanelRoutingTabNotConsumedWhenOnRight(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	m.focusedPanel = panelRight

	msg := tea.KeyMsg{Type: tea.KeyTab}
	_, consumed := handlePanelRouting(&m, msg, noopCallbacks())
	if consumed {
		t.Error("tab when already on right should not be consumed")
	}
}

func TestHandlePanelRoutingEscFocusesLeft(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	m.focusedPanel = panelRight
	m.terminalMode = false

	msg := tea.KeyMsg{Type: tea.KeyEscape}
	_, consumed := handlePanelRouting(&m, msg, noopCallbacks())
	if !consumed {
		t.Error("esc should be consumed")
	}
	if m.focusedPanel != panelLeft {
		t.Errorf("focusedPanel = %v, want panelLeft", m.focusedPanel)
	}
}

func TestHandlePanelRoutingEscNotConsumedWhenOnLeft(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	m.focusedPanel = panelLeft

	msg := tea.KeyMsg{Type: tea.KeyEscape}
	_, consumed := handlePanelRouting(&m, msg, noopCallbacks())
	if consumed {
		t.Error("esc on left panel should not be consumed")
	}
}

func TestHandlePanelRoutingCtrlTTogglesTerminalMode(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	m.focusedPanel = panelRight
	m.terminalMode = false

	// specPanelFn returns a done panel — IsDone() = true satisfies the condition
	slug := "test-slug"
	m.setSpecPanel(slug, work.NewSpecPanelModel(slug))
	cb := noopCallbacks()
	cb.specPanelFn = func() (work.SpecPanelModel, bool) {
		panel := work.NewSpecPanelModel(slug)
		// Mark done so Ptmx() == nil path still qualifies via IsDone()
		sm, _ := panel.Update(work.StreamCompleteMsg{Slug: slug})
		return sm, true
	}

	keyMsg := tea.KeyMsg{Type: tea.KeyCtrlT}
	_, consumed := handlePanelRouting(&m, keyMsg, cb)
	if !consumed {
		t.Error("ctrl+t should be consumed when spec panel exists and is done")
	}
	if !m.terminalMode {
		t.Error("terminalMode should be true after ctrl+t with done spec panel")
	}
}

func TestHandlePanelRoutingCtrlTExitsTerminalMode(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	m.focusedPanel = panelRight
	m.terminalMode = true

	msg := tea.KeyMsg{Type: tea.KeyCtrlT}
	_, consumed := handlePanelRouting(&m, msg, noopCallbacks())
	if !consumed {
		t.Error("ctrl+t in terminal mode should be consumed")
	}
	if m.terminalMode {
		t.Error("terminalMode should be false after ctrl+t when already in terminal mode")
	}
}

func TestHandlePanelRoutingEntitySpecificKeyNotConsumed(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	m.focusedPanel = panelLeft

	// 's', 'c', 'p', 'd' are entity-specific and must NOT be consumed by handlePanelRouting
	for _, key := range []string{"s", "c", "p", "d", "enter"} {
		msg := tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(key)}
		if key == "enter" {
			msg = tea.KeyMsg{Type: tea.KeyEnter}
		}
		_, consumed := handlePanelRouting(&m, msg, noopCallbacks())
		if consumed {
			t.Errorf("key %q should not be consumed by handlePanelRouting", key)
		}
	}
}

// --- Test helpers ---

func assertKeyMsg(t *testing.T, msg tea.Msg) tea.KeyMsg {
	t.Helper()
	km, ok := msg.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", msg)
	}
	return km
}

func assertKeyString(t *testing.T, km tea.KeyMsg, want string) {
	t.Helper()
	if km.String() != want {
		t.Errorf("expected %q, got %q", want, km.String())
	}
}
