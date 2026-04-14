package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/followup"
	"github.com/anticorrelator/lore/tui/internal/work"
)

func TestClassifyStartupState_BothPresent(t *testing.T) {
	dir := t.TempDir()
	workDir := filepath.Join(dir, "_work")
	os.MkdirAll(workDir, 0755)
	os.WriteFile(filepath.Join(dir, "_manifest.json"), []byte("{}"), 0644)
	os.WriteFile(filepath.Join(workDir, "_index.json"), []byte("[]"), 0644)

	cfg := config.Config{KnowledgeDir: dir, WorkDir: workDir}
	if got := classifyStartupState(cfg); got != stateWork {
		t.Errorf("both markers present: got %d, want stateWork (%d)", got, stateWork)
	}
}

func TestClassifyStartupState_ManifestMissing(t *testing.T) {
	dir := t.TempDir()
	workDir := filepath.Join(dir, "_work")
	os.MkdirAll(workDir, 0755)
	// No _manifest.json
	os.WriteFile(filepath.Join(workDir, "_index.json"), []byte("[]"), 0644)

	cfg := config.Config{KnowledgeDir: dir, WorkDir: workDir}
	if got := classifyStartupState(cfg); got != stateOnboarding {
		t.Errorf("manifest missing: got %d, want stateOnboarding (%d)", got, stateOnboarding)
	}
}

func TestClassifyStartupState_IndexMissing(t *testing.T) {
	dir := t.TempDir()
	workDir := filepath.Join(dir, "_work")
	os.MkdirAll(workDir, 0755)
	os.WriteFile(filepath.Join(dir, "_manifest.json"), []byte("{}"), 0644)
	// No _index.json

	cfg := config.Config{KnowledgeDir: dir, WorkDir: workDir}
	if got := classifyStartupState(cfg); got != stateOnboarding {
		t.Errorf("index missing: got %d, want stateOnboarding (%d)", got, stateOnboarding)
	}
}

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

// --- handlePanelRouting tests ---

// noopCallbacks returns a panelCallbacks where every field is a no-op.
// Tests override only the fields they care about.
func noopCallbacks() panelCallbacks {
	return panelCallbacks{
		currentSlug:  func() string { return "" },
		loadDetail:   func(string) tea.Cmd { return nil },
		specPanelFn:  func() (work.SpecPanelModel, bool) { return work.SpecPanelModel{}, false },
		listUpdate:   func(tea.Msg) (tea.Cmd, string, string) { return nil, "", "" },
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

// --- leaveFollowups / ListDismissedMsg tests ---

func TestHandleIndexPollTickExcludesCheckFollowupDetailMtimeInStateWork(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	m.config.KnowledgeDir = t.TempDir()
	m.config.WorkDir = t.TempDir()
	m.indexPath = "/dev/null"

	_, cmd := m.handleIndexPollTick()
	if cmd == nil {
		t.Fatal("expected non-nil cmd from handleIndexPollTick")
	}
	msg := cmd()
	batch, ok := msg.(tea.BatchMsg)
	if !ok {
		t.Fatalf("expected tea.BatchMsg, got %T", msg)
	}

	for _, c := range batch {
		if c == nil {
			continue
		}
		result := c()
		if _, ok := result.(followupDetailMtimeCheckedMsg); ok {
			t.Error("unexpected followupDetailMtimeCheckedMsg in batch when stateWork")
		}
	}
}

func TestHandleIndexPollTickIncludesCheckFollowupDetailMtimeInStateFollowUps(t *testing.T) {
	fuItems := []followup.FollowUpItem{
		{ID: "fu-123", Title: "Test FU", Status: "open"},
	}
	m := minimalModel(stateFollowUps, nil, fuItems)
	m.config.KnowledgeDir = t.TempDir()
	m.config.WorkDir = t.TempDir()
	m.indexPath = "/dev/null"

	_, cmd := m.handleIndexPollTick()
	if cmd == nil {
		t.Fatal("expected non-nil cmd from handleIndexPollTick")
	}
	msg := cmd()
	batch, ok := msg.(tea.BatchMsg)
	if !ok {
		t.Fatalf("expected tea.BatchMsg, got %T", msg)
	}

	foundFollowupDetailMtime := false
	for _, c := range batch {
		if c == nil {
			continue
		}
		result := c()
		if _, ok := result.(followupDetailMtimeCheckedMsg); ok {
			foundFollowupDetailMtime = true
			break
		}
	}
	if !foundFollowupDetailMtime {
		t.Error("expected followupDetailMtimeCheckedMsg in batch when stateFollowUps with currentID set")
	}
}

func TestListDismissedMsgTransitionsToStateWork(t *testing.T) {
	m := minimalModel(stateFollowUps, nil, nil)
	m.config.WorkDir = t.TempDir()

	next, cmd := m.Update(followup.ListDismissedMsg{})

	nm := next.(model)
	if nm.state != stateWork {
		t.Errorf("state = %v, want stateWork", nm.state)
	}
	if cmd == nil {
		t.Fatal("expected non-nil cmd from ListDismissedMsg")
	}
	msg := cmd()
	if _, ok := msg.(workItemsLoadedMsg); !ok {
		t.Errorf("cmd() produced %T, want workItemsLoadedMsg", msg)
	}
}

func TestLeaveFollowupsTransitionsState(t *testing.T) {
	m := minimalModel(stateFollowUps, nil, nil)
	m.config.WorkDir = t.TempDir()

	cmd := m.leaveFollowups()

	if m.state != stateWork {
		t.Errorf("state = %v, want stateWork", m.state)
	}
	if cmd == nil {
		t.Fatal("expected non-nil cmd from leaveFollowups()")
	}
	msg := cmd()
	if _, ok := msg.(workItemsLoadedMsg); !ok {
		t.Errorf("cmd() produced %T, want workItemsLoadedMsg", msg)
	}
}

func TestLoadDetailCacheHitStillRevalidatesSelectedItem(t *testing.T) {
	workDir := t.TempDir()
	slug := "new-item"
	itemDir := filepath.Join(workDir, slug)
	if err := os.MkdirAll(itemDir, 0755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}

	metaJSON := `{
		"slug":"new-item",
		"title":"New Item",
		"status":"active",
		"branches":[],
		"tags":[],
		"related_work":[],
		"created":"2026-04-08T12:00:00Z",
		"updated":"2026-04-08T12:00:00Z"
	}`
	if err := os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(metaJSON), 0644); err != nil {
		t.Fatalf("WriteFile _meta.json: %v", err)
	}
	if err := os.WriteFile(filepath.Join(itemDir, "notes.md"), []byte("fresh notes"), 0644); err != nil {
		t.Fatalf("WriteFile notes.md: %v", err)
	}

	m := minimalModel(stateWork, []work.WorkItem{{Slug: slug, Title: "New Item", Status: "active"}}, nil)
	m.config.WorkDir = workDir
	m.width = 120
	m.height = 40
	m.detailCache = map[string]*work.WorkItemDetail{
		slug: {
			Slug:         slug,
			Title:        "New Item",
			Status:       "active",
			Branches:     []string{},
			Tags:         []string{},
			RelatedWork:  []string{},
			NotesContent: nil, // stale background cache entry
		},
	}

	m, cmd := m.loadDetail(slug)
	if cmd == nil {
		t.Fatal("loadDetail() should queue a fresh load even on cache hit")
	}
	if got := m.detail.Detail(); got == nil || got.NotesContent != nil {
		t.Fatalf("cache seed should be shown immediately; got detail=%+v", got)
	}

	msg := cmd()
	loaded, ok := msg.(work.DetailLoadedMsg)
	if !ok {
		t.Fatalf("cmd() returned %T, want work.DetailLoadedMsg", msg)
	}
	if loaded.Err != nil {
		t.Fatalf("fresh load returned error: %v", loaded.Err)
	}
	if loaded.Detail == nil || loaded.Detail.NotesContent == nil || *loaded.Detail.NotesContent != "fresh notes" {
		t.Fatalf("fresh load did not pick up on-disk notes: %+v", loaded.Detail)
	}

	next, _ := m.Update(loaded)
	updated := next.(model)
	if got := updated.detail.Detail(); got == nil || got.NotesContent == nil || *got.NotesContent != "fresh notes" {
		t.Fatalf("selected detail model did not refresh after DetailLoadedMsg: %+v", got)
	}
	if got := updated.detailCache[slug]; got == nil || got.NotesContent == nil || *got.NotesContent != "fresh notes" {
		t.Fatalf("detail cache did not refresh after DetailLoadedMsg: %+v", got)
	}
}

// --- handleFollowupDetailMtimeChecked tests ---

func TestHandleFollowupDetailMtimeCheckedRejectsStaleID(t *testing.T) {
	fuItems := []followup.FollowUpItem{
		{ID: "fu-current", Title: "Current FU", Status: "open"},
	}
	m := minimalModel(stateFollowUps, nil, fuItems)
	m.config.KnowledgeDir = t.TempDir()
	m.followupDetail.SetID("fu-current") //nolint:errcheck

	// Send a msg with a different (stale) ID.
	staleMsg := followupDetailMtimeCheckedMsg{
		id:    "fu-stale",
		mtime: time.Now(),
	}
	_, cmd := m.handleFollowupDetailMtimeChecked(staleMsg)
	if cmd != nil {
		t.Errorf("expected nil cmd for stale msg.id, got non-nil")
	}
}

func TestHandleFollowupDetailMtimeCheckedMtimeChangeProducesDetailLoadedMsg(t *testing.T) {
	knowledgeDir := t.TempDir()
	id := "fu-watch"

	// Create the minimal _meta.json so LoadFollowUpDetail succeeds.
	fuDir := knowledgeDir + "/_followups/" + id
	if err := os.MkdirAll(fuDir, 0755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	metaJSON := `{"id":"fu-watch","title":"Watch FU","status":"open","source":"test","attachments":[],"suggested_actions":[]}`
	if err := os.WriteFile(fuDir+"/_meta.json", []byte(metaJSON), 0644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	fuItems := []followup.FollowUpItem{
		{ID: id, Title: "Watch FU", Status: "open"},
	}
	m := minimalModel(stateFollowUps, nil, fuItems)
	m.config.KnowledgeDir = knowledgeDir
	m.followupDetail.SetID(id) //nolint:errcheck

	// Establish a non-zero baseline mtime so the handler sees a change.
	baseline := time.Now().Add(-time.Second)
	m.lastFollowupDetailMtime = baseline

	newMtime := time.Now()
	msg := followupDetailMtimeCheckedMsg{id: id, mtime: newMtime}
	nm, cmd := m.handleFollowupDetailMtimeChecked(msg)

	if cmd == nil {
		t.Fatal("expected non-nil cmd on mtime change")
	}
	result := cmd()
	if _, ok := result.(followup.DetailLoadedMsg); !ok {
		t.Errorf("cmd() produced %T, want followup.DetailLoadedMsg", result)
	}
	if nm.lastFollowupDetailMtime != newMtime {
		t.Errorf("lastFollowupDetailMtime not updated: got %v, want %v", nm.lastFollowupDetailMtime, newMtime)
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

// --- Posting flow tests ---

// modelWithLoadedFollowup builds a stateFollowUps model with the Comments tab active
// and a follow-up detail loaded with the given ProposedReview.
func modelWithLoadedFollowup(t *testing.T, id string, review *followup.ProposedReview, selectedCount int) model {
	t.Helper()
	m := minimalModel(stateFollowUps, nil, nil)
	m.state = stateFollowUps
	m.focusedPanel = panelRight
	m.width = 120
	m.height = 40

	// Build a detail with ProposedComments.
	detail := &followup.FollowUpDetail{
		ID:               id,
		Title:            "Test Follow-Up",
		Status:           "reviewed",
		Source:           "pr-review",
		Attachments:      []followup.Attachment{},
		SuggestedActions: []followup.SuggestedAction{},
		ProposedComments: review,
	}

	// Inject the loaded detail into the followupDetail model.
	fd, _ := m.followupDetail.Update(followup.DetailLoadedMsg{ID: id, Detail: detail})
	m.followupDetail = fd

	// Set the detail's ID so CurrentID() returns it.
	_ = m.followupDetail.SetID(id)
	// Re-inject since SetID resets state.
	fd, _ = m.followupDetail.Update(followup.DetailLoadedMsg{ID: id, Detail: detail})
	m.followupDetail = fd

	// Activate the Comments tab.
	for i := 0; i < 10; i++ {
		if m.followupDetail.ActiveTab() == followup.TabComments {
			break
		}
		fd, _ := m.followupDetail.Update(tea.KeyMsg{Type: tea.KeyTab})
		m.followupDetail = fd
	}

	return m
}

func TestPKeyTriggersConfirmModalWithSelectedComments(t *testing.T) {
	review := &followup.ProposedReview{
		PR: 42, Owner: "anticorrelator", Repo: "lore", HeadSHA: "abc123",
		Comments: []followup.ProposedComment{
			{ID: "c1", Path: "a.go", Line: 1, Body: "A.", Severity: "high", Selected: true},
			{ID: "c2", Path: "b.go", Line: 2, Body: "B.", Severity: "low", Selected: false},
		},
	}
	m := modelWithLoadedFollowup(t, "test-fu", review, 1)

	if m.followupDetail.ActiveTab() != followup.TabComments {
		t.Fatalf("pre-condition: active tab should be TabComments, got %v", m.followupDetail.ActiveTab())
	}
	if m.followupDetail.SelectedCount() != 1 {
		t.Fatalf("pre-condition: SelectedCount = %d, want 1", m.followupDetail.SelectedCount())
	}

	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'P'}})
	nm := next.(model)

	if nm.confirmAction != "post_review" {
		t.Errorf("confirmAction = %q, want %q", nm.confirmAction, "post_review")
	}
	if nm.confirmCount != 1 {
		t.Errorf("confirmCount = %d, want 1", nm.confirmCount)
	}
	if nm.confirmSlug != "test-fu" {
		t.Errorf("confirmSlug = %q, want %q", nm.confirmSlug, "test-fu")
	}
}

func TestPKeyWithZeroSelectedSetsFlashErr(t *testing.T) {
	review := &followup.ProposedReview{
		PR: 42, Owner: "anticorrelator", Repo: "lore", HeadSHA: "abc123",
		Comments: []followup.ProposedComment{
			{ID: "c1", Path: "a.go", Line: 1, Body: "A.", Severity: "high", Selected: false},
		},
	}
	m := modelWithLoadedFollowup(t, "test-fu-zero", review, 0)

	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'P'}})
	nm := next.(model)

	if nm.confirmAction != "" {
		t.Errorf("confirmAction should not be set when no comments selected, got %q", nm.confirmAction)
	}
	if nm.flashErr == "" {
		t.Error("flashErr should be set when no comments selected")
	}
}

func TestPKeyWithoutPRMetadataSetsFlashErr(t *testing.T) {
	// Missing owner/repo/pr/sha → no valid metadata.
	review := &followup.ProposedReview{
		PR: 0, Owner: "", Repo: "", HeadSHA: "",
		Comments: []followup.ProposedComment{
			{ID: "c1", Path: "a.go", Line: 1, Body: "A.", Severity: "high", Selected: true},
		},
	}
	m := modelWithLoadedFollowup(t, "test-fu-nometa", review, 1)

	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'P'}})
	nm := next.(model)

	if nm.confirmAction != "" {
		t.Errorf("confirmAction should not be set without PR metadata, got %q", nm.confirmAction)
	}
	if nm.flashErr == "" {
		t.Error("flashErr should be set when PR metadata is missing")
	}
}

func TestPostReviewCompleteMsgHandledCorrectly(t *testing.T) {
	m := minimalModel(stateFollowUps, nil, nil)
	m.config.KnowledgeDir = t.TempDir()

	// PostReviewCompleteMsg with no error should set flashErr to success message
	// and emit a cmd to reload the detail.
	next, cmd := m.Update(followup.PostReviewCompleteMsg{ID: "fu-1", PostedCount: 2, Err: nil})
	nm := next.(model)

	if !strings.Contains(nm.flashErr, "2") {
		t.Errorf("flashErr should contain posted count on success, got %q", nm.flashErr)
	}
	if cmd == nil {
		t.Error("PostReviewCompleteMsg should emit a cmd (reload detail)")
	}
}

func TestPostReviewCompleteMsgWithErrorSetsFlashErr(t *testing.T) {
	m := minimalModel(stateFollowUps, nil, nil)
	m.config.KnowledgeDir = t.TempDir()

	next, _ := m.Update(followup.PostReviewCompleteMsg{
		ID: "fu-1", PostedCount: 0, Err: fmt.Errorf("auth failed"),
	})
	nm := next.(model)

	if nm.flashErr == "" {
		t.Error("flashErr should be set on PostReviewCompleteMsg error")
	}
	if !strings.Contains(nm.flashErr, "auth failed") {
		t.Errorf("flashErr = %q, want it to contain 'auth failed'", nm.flashErr)
	}
}

func TestPostReviewCompleteFlashVariants(t *testing.T) {
	cases := []struct {
		name    string
		msg     followup.PostReviewCompleteMsg
		want    string
	}{
		{
			name: "plain posted count",
			msg:  followup.PostReviewCompleteMsg{ID: "fu-1", PostedCount: 5},
			want: "Posted 5 comments — marked reviewed",
		},
		{
			name: "dropped only",
			msg:  followup.PostReviewCompleteMsg{ID: "fu-1", PostedCount: 4, Dropped: 1},
			want: "Posted 4 (1 dropped) — marked reviewed",
		},
		{
			name: "dropped and shifted",
			msg:  followup.PostReviewCompleteMsg{ID: "fu-1", PostedCount: 3, Dropped: 1, Shifted: 2},
			want: "Posted 3 (1 dropped, 2 shifted) — marked reviewed",
		},
		{
			name: "renamed only",
			msg:  followup.PostReviewCompleteMsg{ID: "fu-1", PostedCount: 2, Renamed: 1},
			want: "Posted 2 (1 renamed) — marked reviewed",
		},
		{
			name: "all non-zero",
			msg:  followup.PostReviewCompleteMsg{ID: "fu-1", PostedCount: 1, Dropped: 1, Shifted: 1, Renamed: 1},
			want: "Posted 1 (1 dropped, 1 shifted, 1 renamed) — marked reviewed",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := minimalModel(stateFollowUps, nil, nil)
			m.config.KnowledgeDir = t.TempDir()

			next, _ := m.Update(tc.msg)
			nm := next.(model)

			if nm.flashErr != tc.want {
				t.Errorf("flashErr = %q, want %q", nm.flashErr, tc.want)
			}
		})
	}
}

// --- terminalMode sync integration tests ---
//
// Each test below covers one of the 6 followup selection paths and verifies
// that terminalMode is synced to true when a spec panel is pre-registered for
// the target follow-up ID. Tests dispatch messages directly to model.Update so
// they exercise the real routing logic end-to-end.

// fuModelWithSpecPanel returns a stateFollowUps model with a spec panel
// pre-registered for id. The list is seeded with fuItems so cursor navigation works.
func fuModelWithSpecPanel(fuItems []followup.FollowUpItem, id string) model {
	m := minimalModel(stateFollowUps, nil, fuItems)
	m.focusedPanel = panelLeft
	m.setSpecPanel(id, work.NewSpecPanelModel(id))
	return m
}

// TestFollowupSelectedMsgSyncsTerminalMode verifies that FollowUpSelectedMsg
// (path 1: Enter key) sets terminalMode=true when a spec panel exists.
func TestFollowupSelectedMsgSyncsTerminalMode(t *testing.T) {
	id := "fu-with-panel"
	fuItems := []followup.FollowUpItem{
		{ID: id, Title: "Panel FU", Status: "open"},
	}
	m := fuModelWithSpecPanel(fuItems, id)
	m.terminalMode = false

	next, _ := m.Update(followup.FollowUpSelectedMsg{Item: fuItems[0]})
	nm := next.(model)

	if !nm.terminalMode {
		t.Error("terminalMode should be true after FollowUpSelectedMsg when spec panel exists")
	}
}

// TestFollowupSelectedMsgNoSpecPanelLeavesTerminalModeOff verifies that
// FollowUpSelectedMsg does not set terminalMode when no spec panel is registered.
func TestFollowupSelectedMsgNoSpecPanelLeavesTerminalModeOff(t *testing.T) {
	id := "fu-no-panel"
	fuItems := []followup.FollowUpItem{
		{ID: id, Title: "No-Panel FU", Status: "open"},
	}
	m := minimalModel(stateFollowUps, nil, fuItems)
	m.terminalMode = false

	next, _ := m.Update(followup.FollowUpSelectedMsg{Item: fuItems[0]})
	nm := next.(model)

	if nm.terminalMode {
		t.Error("terminalMode should remain false after FollowUpSelectedMsg when no spec panel")
	}
}

// TestIndexLoadedMsgSyncsTerminalMode verifies that IndexLoadedMsg (path 3:
// initial load/reload) sets terminalMode=true when the first visible item has
// a pre-registered spec panel.
func TestIndexLoadedMsgSyncsTerminalMode(t *testing.T) {
	id := "fu-indexed"
	fuItems := []followup.FollowUpItem{
		{ID: id, Title: "Indexed FU", Status: "open"},
	}
	// Start with an empty list (no current ID) so IndexLoadedMsg sees a new item.
	m := minimalModel(stateFollowUps, nil, nil)
	m.setSpecPanel(id, work.NewSpecPanelModel(id))
	m.terminalMode = false

	next, _ := m.Update(followup.IndexLoadedMsg{Items: fuItems, Err: nil})
	nm := next.(model)

	if !nm.terminalMode {
		t.Error("terminalMode should be true after IndexLoadedMsg when spec panel exists for first item")
	}
}

// TestLoadDetailMsgSyncsTerminalMode verifies that LoadDetailMsg (path 4:
// hover-prefetch) sets terminalMode=true when a spec panel exists for the target ID.
func TestLoadDetailMsgSyncsTerminalMode(t *testing.T) {
	id := "fu-hover"
	fuItems := []followup.FollowUpItem{
		{ID: id, Title: "Hover FU", Status: "open"},
	}
	m := fuModelWithSpecPanel(fuItems, id)
	m.terminalMode = false

	next, _ := m.Update(followup.LoadDetailMsg{ID: id})
	nm := next.(model)

	if !nm.terminalMode {
		t.Error("terminalMode should be true after LoadDetailMsg when spec panel exists")
	}
}

// TestLoadDetailMsgNoSpecPanelLeavesTerminalModeOff verifies that LoadDetailMsg
// does not set terminalMode when no spec panel is registered for the target ID.
func TestLoadDetailMsgNoSpecPanelLeavesTerminalModeOff(t *testing.T) {
	id := "fu-hover-no-panel"
	fuItems := []followup.FollowUpItem{
		{ID: id, Title: "Hover No-Panel FU", Status: "open"},
	}
	m := minimalModel(stateFollowUps, nil, fuItems)
	m.terminalMode = false

	next, _ := m.Update(followup.LoadDetailMsg{ID: id})
	nm := next.(model)

	if nm.terminalMode {
		t.Error("terminalMode should remain false after LoadDetailMsg when no spec panel")
	}
}

// TestFollowupLeftPanelKeySyncsTerminalMode verifies that a j/k key press on
// the left panel (path 6) syncs terminalMode when the new cursor item has a
// pre-registered spec panel. The list has two items; cursor starts on item[0]
// (no panel) and j moves to item[1] (has panel).
func TestFollowupLeftPanelKeySyncsTerminalMode(t *testing.T) {
	idNone := "fu-no-panel-left"
	idPanel := "fu-with-panel-left"
	fuItems := []followup.FollowUpItem{
		{ID: idNone, Title: "No Panel FU", Status: "open"},
		{ID: idPanel, Title: "Panel FU", Status: "open"},
	}
	m := minimalModel(stateFollowUps, nil, fuItems)
	m.setSpecPanel(idPanel, work.NewSpecPanelModel(idPanel))
	m.focusedPanel = panelLeft
	m.terminalMode = false
	// Cursor starts at 0 (idNone); pressing j moves it to 1 (idPanel).

	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("j")})
	nm := next.(model)

	if !nm.terminalMode {
		t.Error("terminalMode should be true after j key moves cursor to item with spec panel")
	}
}

// TestFollowupLeftPanelKeyNoSpecPanelLeavesTerminalModeOff verifies that a j/k
// key press does not set terminalMode when the new item has no spec panel.
func TestFollowupLeftPanelKeyNoSpecPanelLeavesTerminalModeOff(t *testing.T) {
	id1 := "fu-a"
	id2 := "fu-b"
	fuItems := []followup.FollowUpItem{
		{ID: id1, Title: "FU A", Status: "open"},
		{ID: id2, Title: "FU B", Status: "open"},
	}
	m := minimalModel(stateFollowUps, nil, fuItems)
	m.focusedPanel = panelLeft
	m.terminalMode = false

	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("j")})
	nm := next.(model)

	if nm.terminalMode {
		t.Error("terminalMode should remain false after j key when new item has no spec panel")
	}
}

// --- loadFollowupDetail unit tests ---

// cmdContainsMouseEnable reports whether cmd, when executed, produces a BatchMsg
// that contains tea.EnableMouseCellMotion (identified by the returned msg type name).
func cmdContainsMouseEnable(cmd tea.Cmd) bool {
	if cmd == nil {
		return false
	}
	msg := cmd()
	batch, ok := msg.(tea.BatchMsg)
	if !ok {
		// Single cmd — check directly.
		return fmt.Sprintf("%T", msg) == "tea.enableMouseCellMotionMsg"
	}
	for _, c := range batch {
		if c == nil {
			continue
		}
		if fmt.Sprintf("%T", c()) == "tea.enableMouseCellMotionMsg" {
			return true
		}
	}
	return false
}

// TestLoadFollowupDetailSyncsTerminalMode tests loadFollowupDetail directly for
// three cases: (a) spec panel + panelRight → terminalMode=true, cmd contains
// EnableMouseCellMotion; (b) no spec panel → terminalMode=false, cmd does not
// contain EnableMouseCellMotion; (c) spec panel + panelLeft → terminalMode=true,
// cmd is NOT a batch (no EnableMouseCellMotion injected).
func TestLoadFollowupDetailSyncsTerminalMode(t *testing.T) {
	const id = "fu-test"
	panel := work.NewSpecPanelModel(id)

	t.Run("spec_panel_right_focus", func(t *testing.T) {
		m := minimalModel(stateFollowUps, nil, nil)
		m.focusedPanel = panelRight
		m.setSpecPanel(id, panel)

		cmd := m.loadFollowupDetail(id)

		if !m.terminalMode {
			t.Error("terminalMode should be true when spec panel exists")
		}
		if m.lastFollowupDetailMtime != (time.Time{}) {
			t.Error("lastFollowupDetailMtime should be reset to zero")
		}
		if !cmdContainsMouseEnable(cmd) {
			t.Error("cmd should contain EnableMouseCellMotion when terminalMode && focusedPanel==panelRight")
		}
	})

	t.Run("no_spec_panel", func(t *testing.T) {
		m := minimalModel(stateFollowUps, nil, nil)
		m.focusedPanel = panelRight
		m.terminalMode = true // pre-set; should be cleared

		cmd := m.loadFollowupDetail(id)

		if m.terminalMode {
			t.Error("terminalMode should be false when no spec panel exists")
		}
		if m.lastFollowupDetailMtime != (time.Time{}) {
			t.Error("lastFollowupDetailMtime should be reset to zero")
		}
		if cmdContainsMouseEnable(cmd) {
			t.Error("cmd should not contain EnableMouseCellMotion when no spec panel")
		}
	})

	t.Run("spec_panel_left_focus", func(t *testing.T) {
		m := minimalModel(stateFollowUps, nil, nil)
		m.focusedPanel = panelLeft
		m.setSpecPanel(id, panel)

		cmd := m.loadFollowupDetail(id)

		if !m.terminalMode {
			t.Error("terminalMode should be true when spec panel exists")
		}
		if m.lastFollowupDetailMtime != (time.Time{}) {
			t.Error("lastFollowupDetailMtime should be reset to zero")
		}
		// When focus is on the left panel, EnableMouseCellMotion should NOT be batched.
		if cmdContainsMouseEnable(cmd) {
			t.Error("cmd should not contain EnableMouseCellMotion when focusedPanel==panelLeft")
		}
	})
}

// --- Edit-mode guard integration tests ---

// followupModelWithEditingActive constructs a stateFollowUps model with
// followupDetail in inline edit mode (reviewCards.editing == true).
func followupModelWithEditingActive(t *testing.T) model {
	t.Helper()
	review := &followup.ProposedReview{
		PR:      1,
		Owner:   "o",
		Repo:    "r",
		HeadSHA: "abc",
		Comments: []followup.ProposedComment{
			{ID: "c1", Path: "f.go", Line: 1, Body: "original body", Severity: "medium"},
		},
	}
	m := minimalModel(stateFollowUps, nil, nil)
	m.width = 120
	m.height = 40
	m.focusedPanel = panelRight

	// Build a loaded detail with ProposedComments.
	detail := &followup.FollowUpDetail{
		ID:               "test-fu",
		Title:            "Test FU",
		Status:           "open",
		Attachments:      []followup.Attachment{},
		SuggestedActions: []followup.SuggestedAction{},
		ProposedComments: review,
	}

	// Feed the detail to the followupDetail model via DetailLoadedMsg.
	m.followupDetail.SetID("test-fu")
	next, _ := m.Update(followup.DetailLoadedMsg{ID: "test-fu", Detail: detail})
	m = next.(model)

	// Send 'e' to enter edit mode on the first inline comment.
	next, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'e'}})
	m = next.(model)

	if !m.followupDetail.IsEditing() {
		t.Fatal("setup: followupDetail should be in edit mode after 'e' key")
	}
	return m
}

func TestEditModeGuardEscDoesNotShiftPanelFocus(t *testing.T) {
	m := followupModelWithEditingActive(t)

	// Esc during editing should NOT move focus to panelLeft.
	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	nm := next.(model)

	if nm.focusedPanel != panelRight {
		t.Errorf("Esc during editing: focusedPanel = %v, want panelRight", nm.focusedPanel)
	}
	// Editing should be cancelled.
	if nm.followupDetail.IsEditing() {
		t.Error("Esc during editing: IsEditing should be false after Esc")
	}
}

func TestEditModeGuardEscShiftsFocusWhenNotEditing(t *testing.T) {
	m := minimalModel(stateFollowUps, nil, nil)
	m.focusedPanel = panelRight

	// Esc when not editing should move focus to panelLeft.
	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	nm := next.(model)

	if nm.focusedPanel != panelLeft {
		t.Errorf("Esc when not editing: focusedPanel = %v, want panelLeft", nm.focusedPanel)
	}
}

// --- P key confirmTitle event type tests ---

// followupModelWithReview builds a stateFollowUps model with a loaded
// ProposedReview sidecar, panelRight focus, and the given event type.
// Comments tab is the default when only ProposedComments are present.
func followupModelWithReview(t *testing.T, eventType string, selectedCount int) model {
	t.Helper()
	comments := make([]followup.ProposedComment, selectedCount)
	for i := range comments {
		comments[i] = followup.ProposedComment{
			ID: fmt.Sprintf("c%d", i), Path: "f.go", Line: i + 1,
			Body: "body", Severity: "medium", Selected: true,
		}
	}
	review := &followup.ProposedReview{
		PR: 99, Owner: "o", Repo: "r", HeadSHA: "abc",
		ReviewEvent: eventType,
		Comments:    comments,
	}
	m := minimalModel(stateFollowUps, nil, nil)
	m.width = 120
	m.height = 40
	m.focusedPanel = panelRight

	detail := &followup.FollowUpDetail{
		ID: "fu-1", Title: "Test FU", Status: "open",
		Attachments:      []followup.Attachment{},
		SuggestedActions: []followup.SuggestedAction{},
		ProposedComments: review,
	}
	m.followupDetail.SetID("fu-1")
	next, _ := m.Update(followup.DetailLoadedMsg{ID: "fu-1", Detail: detail})
	m = next.(model)

	if m.followupDetail.ActiveTab() != followup.TabComments {
		t.Fatalf("setup: expected TabComments to be active, got %v", m.followupDetail.ActiveTab())
	}
	return m
}

func TestPKeyConfirmTitleContainsDefaultCOMMENT(t *testing.T) {
	m := followupModelWithReview(t, "COMMENT", 2)

	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'P'}})
	nm := next.(model)

	if nm.confirmAction != "post_review" {
		t.Fatalf("confirmAction = %q, want %q", nm.confirmAction, "post_review")
	}
	if !strings.Contains(nm.confirmTitle, "COMMENT") {
		t.Errorf("confirmTitle = %q, want it to contain COMMENT", nm.confirmTitle)
	}
	if !strings.Contains(nm.confirmTitle, "99") {
		t.Errorf("confirmTitle = %q, want it to contain PR number 99", nm.confirmTitle)
	}
}

func TestPKeyConfirmTitleInterpolatesAPPROVE(t *testing.T) {
	m := followupModelWithReview(t, "APPROVE", 1)

	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'P'}})
	nm := next.(model)

	if nm.confirmAction != "post_review" {
		t.Fatalf("confirmAction = %q, want %q", nm.confirmAction, "post_review")
	}
	if !strings.Contains(nm.confirmTitle, "APPROVE") {
		t.Errorf("confirmTitle = %q, want it to contain APPROVE", nm.confirmTitle)
	}
}

func TestPKeyConfirmTitleInterpolatesREQUESTCHANGES(t *testing.T) {
	m := followupModelWithReview(t, "REQUEST_CHANGES", 3)

	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'P'}})
	nm := next.(model)

	if nm.confirmAction != "post_review" {
		t.Fatalf("confirmAction = %q, want %q", nm.confirmAction, "post_review")
	}
	if !strings.Contains(nm.confirmTitle, "REQUEST_CHANGES") {
		t.Errorf("confirmTitle = %q, want it to contain REQUEST_CHANGES", nm.confirmTitle)
	}
}

func TestPKeyNoopWhenNoCommentsSelected(t *testing.T) {
	m := followupModelWithReview(t, "COMMENT", 0)
	// Mark all comments unselected (none were added above since selectedCount=0).
	// confirmAction should not be set.
	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'P'}})
	nm := next.(model)

	if nm.confirmAction != "" {
		t.Errorf("confirmAction = %q, want empty (no selected comments)", nm.confirmAction)
	}
	if nm.flashErr == "" {
		t.Error("P with no selected comments should set flashErr")
	}
}

func TestEditModeGuardGlobalShortcutsSuppressedDuringEditing(t *testing.T) {
	m := followupModelWithEditingActive(t)

	// 'w' should NOT leave stateFollowUps during editing.
	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'w'}})
	nm := next.(model)
	if nm.state != stateFollowUps {
		t.Errorf("w during editing: state changed to %v, want stateFollowUps", nm.state)
	}

	// '?' should NOT open help during editing.
	next, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'?'}})
	nm = next.(model)
	if nm.showHelp {
		t.Error("? during editing: showHelp was set, want suppressed")
	}
}

func TestEditModeGuardTabDoesNotShiftPanelFocusDuringEditing(t *testing.T) {
	m := followupModelWithEditingActive(t)

	// Tab during editing should not move focus to left panel.
	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyTab})
	nm := next.(model)

	if nm.focusedPanel != panelRight {
		t.Errorf("tab during editing: focusedPanel = %v, want panelRight", nm.focusedPanel)
	}
	// Still editing after tab.
	if !nm.followupDetail.IsEditing() {
		t.Error("tab during editing: IsEditing should still be true")
	}
}

// --- Lens Findings Tab p key (promote with findings) tests ---

// followupModelWithLensFindings builds a stateFollowUps model loaded with a
// lens-findings sidecar. The Findings tab is the default when only LensFindings
// are present. If selectAll is true, all findings are pre-selected.
func followupModelWithLensFindings(t *testing.T, selectAll bool) model {
	t.Helper()
	findings := []followup.LensFinding{
		{
			Severity: "blocking", Title: "Missing check", File: "main.go", Line: 10,
			Body: "Error ignored.", Lens: "correctness", Disposition: "action",
			Rationale: "Could cause data loss.", Selected: selectAll,
		},
		{
			Severity: "suggestion", Title: "Extract helper", File: "util.go", Line: 55,
			Body: "Refactor opportunity.", Lens: "clarity", Disposition: "action",
			Rationale: "", Selected: selectAll,
		},
	}
	lensReview := &followup.LensReview{PR: 7, WorkItem: "test-wi", Findings: findings}
	detail := &followup.FollowUpDetail{
		ID:               "fu-lens",
		Title:            "Lens Test FU",
		Status:           "open",
		Attachments:      []followup.Attachment{},
		SuggestedActions: []followup.SuggestedAction{},
		LensFindings:     lensReview,
	}
	m := minimalModel(stateFollowUps, nil, nil)
	m.width = 120
	m.height = 40
	m.focusedPanel = panelRight
	m.followupDetail.SetID("fu-lens")
	next, _ := m.Update(followup.DetailLoadedMsg{ID: "fu-lens", Detail: detail})
	m = next.(model)
	if m.followupDetail.ActiveTab() != followup.TabTriage {
		t.Fatalf("setup: expected TabTriage to be active, got %v", m.followupDetail.ActiveTab())
	}
	return m
}

// TestFindingsTabPKeyEmitsPromoteRequestMsgWithFindings checks that pressing p
// on the Findings tab with selected findings produces a PromoteRequestMsg
// carrying non-empty FindingsJSON.
func TestFindingsTabPKeyEmitsPromoteRequestMsgWithFindings(t *testing.T) {
	m := followupModelWithLensFindings(t, true) // all findings selected

	var captured followup.PromoteRequestMsg
	next, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'p'}})
	_ = next

	if cmd == nil {
		t.Fatal("p key: expected a non-nil Cmd, got nil")
	}
	msg := cmd()
	pm, ok := msg.(followup.PromoteRequestMsg)
	if !ok {
		t.Fatalf("p key: cmd() returned %T, want PromoteRequestMsg", msg)
	}
	captured = pm
	if captured.ID != "fu-lens" {
		t.Errorf("PromoteRequestMsg.ID = %q, want %q", captured.ID, "fu-lens")
	}
	if captured.FindingsJSON == "" {
		t.Error("PromoteRequestMsg.FindingsJSON is empty — expected marshaled findings")
	}
	if !strings.Contains(captured.FindingsJSON, "main.go") {
		t.Errorf("FindingsJSON = %q, want it to contain 'main.go'", captured.FindingsJSON)
	}
}

// TestFindingsTabPKeyEmitsPromoteRequestMsgWithEmptyFindingsWhenNoneSelected checks
// that p with no selected findings still emits PromoteRequestMsg but with empty FindingsJSON.
func TestFindingsTabPKeyEmitsPromoteRequestMsgWithEmptyFindingsWhenNoneSelected(t *testing.T) {
	m := followupModelWithLensFindings(t, false) // no findings selected

	next, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'p'}})
	_ = next

	if cmd == nil {
		t.Fatal("p key: expected a non-nil Cmd, got nil")
	}
	msg := cmd()
	pm, ok := msg.(followup.PromoteRequestMsg)
	if !ok {
		t.Fatalf("p key: cmd() returned %T, want PromoteRequestMsg", msg)
	}
	if pm.ID != "fu-lens" {
		t.Errorf("PromoteRequestMsg.ID = %q, want %q", pm.ID, "fu-lens")
	}
	if pm.FindingsJSON != "" {
		t.Errorf("PromoteRequestMsg.FindingsJSON = %q, want empty (none selected)", pm.FindingsJSON)
	}
}

// TestPromoteRequestMsgWithFindingsJSONDispatchesToRunPromote checks that the
// top-level Update handler for PromoteRequestMsg returns a non-nil Cmd when
// FindingsJSON is set.
func TestPromoteRequestMsgWithFindingsJSONDispatchesToRunPromote(t *testing.T) {
	m := minimalModel(stateFollowUps, nil, nil)

	msg := followup.PromoteRequestMsg{ID: "fu-1", FindingsJSON: `[{"severity":"blocking","file":"a.go"}]`}
	_, cmd := m.Update(msg)

	if cmd == nil {
		t.Fatal("PromoteRequestMsg with FindingsJSON: expected non-nil Cmd from runPromoteFollowUp")
	}
}

// TestStateOnboardingRendersWelcomeScreen verifies that a model in stateOnboarding
// renders the welcome/onboarding screen rather than the split-pane work view.
func TestStateOnboardingRendersWelcomeScreen(t *testing.T) {
	m := minimalModel(stateOnboarding, nil, nil)
	m.config.ProjectDir = "/tmp/my-repo"
	m.config.RepoIdentifier = "my-repo"
	m.width = 80
	m.height = 24

	out := m.View()

	// Should contain the repo name.
	if !strings.Contains(out, "my-repo") {
		t.Errorf("onboarding view should contain repo name 'my-repo', got:\n%s", out)
	}
	// Should contain the Enter hint.
	if !strings.Contains(out, "Press Enter to initialize") {
		t.Errorf("onboarding view should contain 'Press Enter to initialize', got:\n%s", out)
	}
	// Should contain the quit hint.
	if !strings.Contains(out, "Press q to quit") {
		t.Errorf("onboarding view should contain 'Press q to quit', got:\n%s", out)
	}
	// Should NOT contain split-pane elements (tab indicator with "work" and "follow-ups").
	if strings.Contains(out, "follow-ups") {
		t.Errorf("onboarding view should NOT render the split-pane tab indicator, but found 'follow-ups'")
	}
}

// TestStateOnboardingEnterDispatchesInit verifies that pressing Enter in
// stateOnboarding sets initLoading=true and returns a non-nil Cmd (runInit).
func TestStateOnboardingEnterDispatchesInit(t *testing.T) {
	m := minimalModel(stateOnboarding, nil, nil)
	m.config.ProjectDir = "/tmp/my-repo"
	m.width = 80
	m.height = 24

	next, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	updated := next.(model)

	if !updated.initLoading {
		t.Error("Enter in stateOnboarding should set initLoading=true")
	}
	if cmd == nil {
		t.Error("Enter in stateOnboarding should return a non-nil Cmd (runInit)")
	}
	if updated.state != stateOnboarding {
		t.Errorf("state should remain stateOnboarding, got %v", updated.state)
	}
}

// TestStateOnboardingEnterWhileLoadingIsNoop verifies that pressing Enter
// while initLoading is already true is a no-op (no duplicate init).
func TestStateOnboardingEnterWhileLoadingIsNoop(t *testing.T) {
	m := minimalModel(stateOnboarding, nil, nil)
	m.config.ProjectDir = "/tmp/my-repo"
	m.initLoading = true

	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if cmd != nil {
		t.Error("Enter while initLoading=true should return nil Cmd, got non-nil")
	}
}

// TestInitFinishedMsgSuccessTransitionsToStateWork verifies that a successful
// initFinishedMsg transitions the model from stateOnboarding to stateWork.
func TestInitFinishedMsgSuccessTransitionsToStateWork(t *testing.T) {
	m := minimalModel(stateOnboarding, nil, nil)
	m.config.ProjectDir = "/tmp/my-repo"
	m.config.WorkDir = t.TempDir()
	m.initLoading = true

	next, cmd := m.Update(initFinishedMsg{Err: nil})
	updated := next.(model)

	if updated.state != stateWork {
		t.Errorf("state should transition to stateWork, got %v", updated.state)
	}
	if updated.initLoading {
		t.Error("initLoading should be false after successful init")
	}
	if cmd == nil {
		t.Error("successful initFinishedMsg should return a non-nil Cmd (tea.Batch of loadWorkItems, etc.)")
	}
}

// TestInitFinishedMsgErrorStaysInOnboarding verifies that an initFinishedMsg
// with an error keeps the model in stateOnboarding and sets flashErr.
func TestInitFinishedMsgErrorStaysInOnboarding(t *testing.T) {
	m := minimalModel(stateOnboarding, nil, nil)
	m.config.ProjectDir = "/tmp/my-repo"
	m.initLoading = true

	testErr := fmt.Errorf("init-repo.sh failed")
	next, cmd := m.Update(initFinishedMsg{Err: testErr})
	updated := next.(model)

	if updated.state != stateOnboarding {
		t.Errorf("state should remain stateOnboarding on error, got %v", updated.state)
	}
	if updated.initLoading {
		t.Error("initLoading should be false after error")
	}
	if updated.flashErr == "" {
		t.Error("flashErr should be set on init error")
	}
	if !strings.Contains(updated.flashErr, "init failed") {
		t.Errorf("flashErr = %q, want it to contain 'init failed'", updated.flashErr)
	}
	if cmd != nil {
		t.Error("initFinishedMsg with error should return nil Cmd")
	}
}

// TestStateOnboardingLoadingRendersInitializing verifies that when initLoading
// is true, the onboarding view shows "Initializing..." instead of "Press Enter".
func TestStateOnboardingLoadingRendersInitializing(t *testing.T) {
	m := minimalModel(stateOnboarding, nil, nil)
	m.config.ProjectDir = "/tmp/my-repo"
	m.width = 80
	m.height = 24
	m.initLoading = true

	out := m.View()

	if !strings.Contains(out, "Initializing...") {
		t.Errorf("onboarding view with initLoading should contain 'Initializing...', got:\n%s", out)
	}
	if strings.Contains(out, "Press Enter to initialize") {
		t.Errorf("onboarding view with initLoading should NOT contain 'Press Enter to initialize'")
	}
}

// TestStateNoRepoRendersMessage verifies that a model in stateNoRepo renders
// the directory name and "not inside a git repository" message.
func TestStateNoRepoRendersMessage(t *testing.T) {
	m := minimalModel(stateNoRepo, nil, nil)
	m.config.ProjectDir = "/home/user/myproject"
	m.width = 80
	m.height = 24

	out := m.View()

	if !strings.Contains(out, "myproject") {
		t.Errorf("no-repo view should contain directory name 'myproject', got:\n%s", out)
	}
	if !strings.Contains(out, "Not inside a git repository") {
		t.Errorf("no-repo view should contain 'Not inside a git repository', got:\n%s", out)
	}
	if !strings.Contains(out, "Press q to quit") {
		t.Errorf("no-repo view should contain 'Press q to quit', got:\n%s", out)
	}
}

// TestStateNoRepoInitReturnsNil verifies that Init() returns nil for stateNoRepo
// (no background commands should be started).
func TestStateNoRepoInitReturnsNil(t *testing.T) {
	m := minimalModel(stateNoRepo, nil, nil)
	cmd := m.Init()
	if cmd != nil {
		t.Error("Init() in stateNoRepo should return nil Cmd")
	}
}

// TestStateNoRepoKeyHandling verifies that q triggers quit and other keys are
// consumed silently (no Cmd returned, state unchanged).
func TestStateNoRepoKeyHandling(t *testing.T) {
	m := minimalModel(stateNoRepo, nil, nil)

	// q should return tea.Quit
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("q")})
	if cmd == nil {
		t.Error("q key in stateNoRepo should return a non-nil Cmd (tea.Quit)")
	}

	// ctrl+c should return tea.Quit
	_, cmd = m.Update(tea.KeyMsg{Type: tea.KeyCtrlC})
	if cmd == nil {
		t.Error("ctrl+c in stateNoRepo should return a non-nil Cmd (tea.Quit)")
	}

	// an unrelated key (e.g. 'j') should be consumed silently
	next, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("j")})
	if cmd != nil {
		t.Error("unrelated key in stateNoRepo should return nil Cmd")
	}
	if next.(model).state != stateNoRepo {
		t.Error("state should remain stateNoRepo after unrelated key")
	}
}
