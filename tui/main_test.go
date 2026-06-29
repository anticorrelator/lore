package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/followup"
	"github.com/anticorrelator/lore/tui/internal/knowledge"
	"github.com/anticorrelator/lore/tui/internal/settlement"
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

// --- Keybind contract tests ---
//
// These verify that every keybind advertised in a modal's render function
// dispatches correctly through the modal's real Update path when delivered
// as a native bubbletea v2 KeyPressMsg. If a keybind is added to a modal's
// UI but the dispatch switch can't match it, these tests fail — catching the
// regression before it ships.
//
// Enable surface: bubbletea v2 always requests basic Kitty keyboard
// disambiguation from the terminal (its renderer ORs in flag 1 regardless of
// View.KeyboardEnhancements), so Shift+Enter and Alt-modified keys arrive as
// native key presses with no app-level enable sequence. The app intentionally
// relies on that default; TestRootViewTerminalModes pins it.

// TestRootViewTerminalModes verifies the root View() applies the terminal
// modes at its single wrapping point: alt screen, cell-motion mouse, and the
// intentionally zero-value KeyboardEnhancements (v2's default Kitty
// disambiguation is what delivers Shift+Enter to the modals; the struct
// fields only add key release/repeat reporting this app does not use).
func TestRootViewTerminalModes(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	m.width = 80
	m.height = 24
	v := m.View()
	if !v.AltScreen {
		t.Error("root view must set AltScreen")
	}
	if v.MouseMode != tea.MouseModeCellMotion {
		t.Errorf("root view must request cell-motion mouse mode, got %v", v.MouseMode)
	}
	if v.KeyboardEnhancements != (tea.KeyboardEnhancements{}) {
		t.Errorf("KeyboardEnhancements should stay zero (reliance on v2 default disambiguation), got %+v", v.KeyboardEnhancements)
	}
}

// specConfirmModel builds a model with the spec-confirm modal open and a
// focused textarea, mirroring handleSpecRequest.
func specConfirmModel() model {
	m := minimalModel(stateWork, nil, nil)
	m.width = 100
	m.height = 40
	ta := newModalTextarea()
	ta.Focus()
	m.sessionConfirmInput = ta
	m.sessionConfirmActive = true
	m.sessionConfirmSlug = "test-item"
	m.sessionConfirmTitle = "test-item"
	m.sessionConfirmFindingIndex = -1
	return m
}

// updateModel runs m.Update and re-asserts the concrete model type.
func updateModel(t *testing.T, m model, msg tea.Msg) (model, tea.Cmd) {
	t.Helper()
	um, cmd := m.Update(msg)
	nm, ok := um.(model)
	if !ok {
		t.Fatalf("Update returned %T, want model", um)
	}
	return nm, cmd
}

// press is the single shared v2-native key constructor for keybind contract
// tests. Unmodified printable runes carry Text (matching real terminal
// input); special keys (tea.KeyEnter, tea.KeyEscape, …) and modified keys
// carry none. A future key-API migration changes this one helper.
func press(code rune, mods ...tea.KeyMod) tea.KeyPressMsg {
	k := tea.KeyPressMsg{Code: code}
	for _, mod := range mods {
		k.Mod |= mod
	}
	if k.Mod == 0 && unicode.IsPrint(code) {
		k.Text = string(code)
	}
	return k
}

// TestSpecConfirmModalKeybindContract verifies the keybinds displayed in
// renderSpecConfirmModal (Enter, Esc, Shift+Enter, Alt+1, Alt+2) against the
// modal's actual dispatch in Update.
func TestSpecConfirmModalKeybindContract(t *testing.T) {
	t.Run("Shift+Enter (newline)", func(t *testing.T) {
		m := specConfirmModel()
		nm, _ := updateModel(t, m, press(tea.KeyEnter, tea.ModShift))
		if got := nm.sessionConfirmInput.Value(); got != "\n" {
			t.Errorf("expected newline in textarea, got %q", got)
		}
		if !nm.sessionConfirmActive {
			t.Error("modal should stay open")
		}
	})
	t.Run("Alt+Enter (newline)", func(t *testing.T) {
		m := specConfirmModel()
		nm, _ := updateModel(t, m, press(tea.KeyEnter, tea.ModAlt))
		if got := nm.sessionConfirmInput.Value(); got != "\n" {
			t.Errorf("expected newline in textarea, got %q", got)
		}
	})
	t.Run("Enter (launch)", func(t *testing.T) {
		m := specConfirmModel()
		nm, cmd := updateModel(t, m, press(tea.KeyEnter))
		if nm.sessionConfirmActive {
			t.Error("modal should close on Enter")
		}
		if cmd == nil {
			t.Error("Enter should dispatch the launch command")
		}
		if !nm.hasSpecPanel("test-item") {
			t.Error("Enter should pre-create the spec panel")
		}
	})
	t.Run("Esc (cancel)", func(t *testing.T) {
		m := specConfirmModel()
		nm, _ := updateModel(t, m, press(tea.KeyEscape))
		if nm.sessionConfirmActive {
			t.Error("modal should close on Esc")
		}
	})
	t.Run("Alt+1 (toggle short mode)", func(t *testing.T) {
		m := specConfirmModel()
		before := m.sessionConfirmShortMode
		nm, _ := updateModel(t, m, press('1', tea.ModAlt))
		if nm.sessionConfirmShortMode == before {
			t.Error("Alt+1 should toggle short mode")
		}
	})
	t.Run("Alt+2 (toggle skip confirm)", func(t *testing.T) {
		m := specConfirmModel()
		before := m.sessionConfirmSkipConfirm
		nm, _ := updateModel(t, m, press('2', tea.ModAlt))
		if nm.sessionConfirmSkipConfirm == before {
			t.Error("Alt+2 should toggle skip confirm")
		}
	})
}

// TestAIModalKeybindContract verifies keybinds used by the AI input modal
// (Enter, Esc, Shift+Enter, Alt+Enter, typed characters).
func TestAIModalKeybindContract(t *testing.T) {
	aiModel := func() model {
		m := minimalModel(stateWork, nil, nil)
		m.width = 100
		m.height = 40
		ta := newModalTextarea()
		ta.Focus()
		m.aiInput = ta
		m.aiInputActive = true
		return m
	}
	t.Run("Shift+Enter (newline)", func(t *testing.T) {
		nm, _ := updateModel(t, aiModel(), press(tea.KeyEnter, tea.ModShift))
		if got := nm.aiInput.Value(); got != "\n" {
			t.Errorf("expected newline in textarea, got %q", got)
		}
	})
	t.Run("Alt+Enter (newline)", func(t *testing.T) {
		nm, _ := updateModel(t, aiModel(), press(tea.KeyEnter, tea.ModAlt))
		if got := nm.aiInput.Value(); got != "\n" {
			t.Errorf("expected newline in textarea, got %q", got)
		}
	})
	t.Run("Enter on empty input (close, no-op)", func(t *testing.T) {
		nm, cmd := updateModel(t, aiModel(), press(tea.KeyEnter))
		if nm.aiInputActive {
			t.Error("modal should close on Enter")
		}
		if cmd != nil {
			t.Error("empty prompt should not dispatch a command")
		}
	})
	t.Run("Esc (cancel)", func(t *testing.T) {
		nm, _ := updateModel(t, aiModel(), press(tea.KeyEscape))
		if nm.aiInputActive {
			t.Error("modal should close on Esc")
		}
	})
	t.Run("typed characters reach textarea", func(t *testing.T) {
		m := aiModel()
		for _, c := range "hi" {
			m, _ = updateModel(t, m, press(c))
		}
		if got := m.aiInput.Value(); got != "hi" {
			t.Errorf("expected %q in textarea, got %q", "hi", got)
		}
	})
}

// TestTypedCharactersInKittyMode verifies that regular character input
// reaches the modal textarea as native v2 key presses. This guards the
// "modal freezes because typed characters don't reach the textarea"
// regression that the v1 CSI u translation layer existed to fix.
func TestTypedCharactersInKittyMode(t *testing.T) {
	chars := "abcdefghijklmnopqrstuvwxyz0123456789 "
	for _, c := range chars {
		t.Run(fmt.Sprintf("char_%c", c), func(t *testing.T) {
			m := specConfirmModel()
			key := press(c)
			nm, _ := updateModel(t, m, key)
			if got := nm.sessionConfirmInput.Value(); got != string(c) {
				t.Errorf("char %c: expected %q in textarea, got %q", c, string(c), got)
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
		settlement:     settlement.NewModel(),
		specPanels:     make(map[string]work.SpecPanelModel),
	}
}

func setupFakeLoreData(t *testing.T, settingsJSON string) string {
	t.Helper()

	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	repoRoot := filepath.Clean(filepath.Join(wd, ".."))
	if _, err := os.Stat(filepath.Join(repoRoot, "adapters", "settings.schema.json")); err != nil {
		t.Fatalf("expected repo root at %s but settings.schema.json missing: %v", repoRoot, err)
	}

	dataDir := t.TempDir()
	if err := os.Symlink(filepath.Join(repoRoot, "scripts"), filepath.Join(dataDir, "scripts")); err != nil {
		t.Fatal(err)
	}
	configDir := filepath.Join(dataDir, "config")
	if err := os.MkdirAll(configDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(configDir, "settings.json"), []byte(settingsJSON), 0644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LORE_DATA_DIR", dataDir)
	t.Setenv("LORE_FRAMEWORK", "")
	return dataDir
}

func TestBuildPaneConfigStateWorkEmptyList(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	cfg := m.buildPaneConfig()

	if cfg.state != stateWork {
		t.Errorf("state = %v, want stateWork", cfg.state)
	}
	// listTitle is pre-rendered with the title tokens; compare the visible text.
	if got := stripANSI(cfg.listTitle); got != "Active" {
		t.Errorf("listTitle = %q, want %q", got, "Active")
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
	// listTitle is pre-rendered with the title tokens; compare the visible text.
	if got := stripANSI(cfg.listTitle); got != "Open" {
		t.Errorf("listTitle = %q, want %q", got, "Open")
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

func TestBuildPaneConfigIncludesSettlementCount(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	st, err := settlement.ParseStatus([]byte(`{
		"enabled": true,
		"queue": {"ready": 2, "pending": 3, "running": 1}
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	m.settlement = m.settlement.ReplaceStatus(st)

	cfg := m.buildPaneConfig()
	// Count is active queue depth: ready + pending + running.
	if cfg.settlementCount != 6 {
		t.Errorf("settlementCount = %d, want 6", cfg.settlementCount)
	}
}

func TestSettlementRootNavigationFromListViews(t *testing.T) {
	tests := []struct {
		name  string
		state appState
	}{
		{name: "work", state: stateWork},
		{name: "followups", state: stateFollowUps},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			m := minimalModel(tc.state, []work.WorkItem{{Slug: "work-1", Title: "Work 1"}}, nil)
			m.focusedPanel = panelLeft

			next, cmd := m.Update(tea.KeyPressMsg{Code: 't', Text: "t"})
			nm := next.(model)
			if nm.state != stateSettlement {
				t.Fatalf("state = %v, want stateSettlement", nm.state)
			}
			if nm.terminalMode {
				t.Fatal("terminalMode should remain disabled when entering settlement")
			}
			if nm.focusedPanel != panelLeft {
				t.Fatalf("focusedPanel = %v, want panelLeft", nm.focusedPanel)
			}
			if cmd == nil {
				t.Fatal("expected settlement status reload command")
			}
		})
	}
}

func TestSettlementRootNavigationIgnoredInTerminalMode(t *testing.T) {
	m := minimalModel(stateWork, []work.WorkItem{{Slug: "work-1", Title: "Work 1"}}, nil)
	m.terminalMode = true
	m.focusedPanel = panelRight
	m.setSpecPanel("work-1", work.NewSpecPanelModel("work-1"))

	next, _ := m.Update(tea.KeyPressMsg{Code: 't', Text: "t"})
	nm := next.(model)
	if nm.state != stateWork {
		t.Fatalf("state = %v, want stateWork", nm.state)
	}
	if !nm.terminalMode {
		t.Fatal("terminalMode should stay enabled so t can route to the terminal")
	}
	if nm.focusedPanel != panelRight {
		t.Fatalf("focusedPanel = %v, want panelRight", nm.focusedPanel)
	}
}

func TestSettlementRootNavigationAllowedWhenTerminalNotFocused(t *testing.T) {
	m := minimalModel(stateWork, []work.WorkItem{{Slug: "work-1", Title: "Work 1"}}, nil)
	m.terminalMode = true
	m.focusedPanel = panelLeft
	m.setSpecPanel("work-1", work.NewSpecPanelModel("work-1"))

	next, cmd := m.Update(tea.KeyPressMsg{Code: 't', Text: "t"})
	nm := next.(model)
	if nm.state != stateSettlement {
		t.Fatalf("state = %v, want stateSettlement", nm.state)
	}
	if nm.terminalMode {
		t.Fatal("terminalMode should be disabled after leaving the work view")
	}
	if nm.focusedPanel != panelLeft {
		t.Fatalf("focusedPanel = %v, want panelLeft", nm.focusedPanel)
	}
	if cmd == nil {
		t.Fatal("expected settlement status reload command")
	}
}

func TestSettlementEnableActionRefreshesInlineSettingsPanel(t *testing.T) {
	setupFakeLoreData(t, `{
		"version": 1,
		"tui_launch_framework": "claude-code",
		"settlement": {"enabled": false}
	}`)

	m := minimalModel(stateSettlement, nil, nil)
	m.ensureSettlementSettingsPanel()
	if m.settlementSettingsPanel == nil {
		t.Fatal("expected settlement settings panel")
	}
	before := stripANSI(m.settlementSettingsPanel.View())
	if !strings.Contains(before, "[ ] enabled") {
		t.Fatalf("setup should render settlement disabled, got:\n%s", before)
	}

	if err := config.SettingsPatch("settlement.enabled", true); err != nil {
		t.Fatalf("SettingsPatch: %v", err)
	}
	result, err := settlement.ParseActionResult("enable", []byte(`{"ok": true, "message": "enabled"}`))
	if err != nil {
		t.Fatalf("ParseActionResult: %v", err)
	}

	next, _ := m.Update(settlementActionCompleteMsg{action: "enable", result: result})
	nm := next.(model)
	if nm.settlementSettingsPanel == nil {
		t.Fatal("expected settlement settings panel after refresh")
	}
	after := stripANSI(nm.settlementSettingsPanel.View())
	if !strings.Contains(after, "[x] enabled") {
		t.Fatalf("enable action should refresh inline settings view, got:\n%s", after)
	}
}

func TestSettlementActionKeybindsReturnCommands(t *testing.T) {
	tests := []struct {
		key string
	}{
		{key: "p"},
		{key: "e"},
	}
	for _, tc := range tests {
		t.Run(tc.key, func(t *testing.T) {
			m := minimalModel(stateSettlement, nil, nil)
			next, cmd := m.Update(tea.KeyPressMsg{Code: []rune(tc.key)[0], Text: tc.key})
			if next.(model).state != stateSettlement {
				t.Fatalf("state changed unexpectedly")
			}
			if cmd == nil {
				t.Fatalf("expected command for key %q", tc.key)
			}
		})
	}
}

func TestSettlementVNoLongerOpensConfigModal(t *testing.T) {
	m := minimalModel(stateSettlement, nil, nil)
	next, cmd := m.Update(tea.KeyPressMsg{Code: 'v', Text: "v"})
	nm := next.(model)
	if nm.settingsActive {
		t.Fatalf("v should not open a settlement config overlay")
	}
	if cmd != nil {
		t.Fatalf("v should not dispatch a command")
	}
}

func TestSettlementEscLeavesInlineSettingsPanel(t *testing.T) {
	m := minimalModel(stateSettlement, nil, nil)
	m.focusedPanel = panelRight

	next, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	nm := next.(model)
	if cmd != nil {
		t.Fatalf("esc leaving inline settings should not dispatch a command")
	}
	if nm.focusedPanel != panelLeft {
		t.Fatalf("focusedPanel = %v, want panelLeft", nm.focusedPanel)
	}
}

// newSettlementEmbedModel builds a stateSettlement model with a real inline
// settings panel (backed by fixture lore data) and right-panel focus, for
// pinning the host's inline-settlement key dispatch in update.go.
func newSettlementEmbedModel(t *testing.T) model {
	t.Helper()
	setupFakeLoreData(t, `{
		"version": 1,
		"tui_launch_framework": "claude-code",
		"settlement": {
			"enabled": true,
			"active_hours": {
				"enabled": true,
				"timezone": "local",
				"ranges": [{"days": ["mon"], "start": "09:00", "end": "17:00"}]
			}
		}
	}`)
	m := minimalModel(stateSettlement, nil, nil)
	m.focusedPanel = panelRight
	m.ensureSettlementSettingsPanel()
	if m.settlementSettingsPanel == nil {
		t.Fatalf("expected settlement settings panel, flashErr=%q", m.flashErr)
	}
	return m
}

// driveSettlementEmbedIntoEditing navigates the inline embed to its last
// control (the active-hours windows editor, which navigation clamps to) and
// enters edit mode, so the focused editor consumes runes. Every key goes
// through the host Update path, exercising the real dispatch.
func driveSettlementEmbedIntoEditing(t *testing.T, m model) model {
	t.Helper()
	for i := 0; i < 20; i++ {
		m, _ = updateModel(t, m, press('j'))
	}
	m, _ = updateModel(t, m, press(tea.KeyEnter))
	if !m.settlementSettingsPanel.FocusConsumesRunes() {
		t.Fatal("expected the windows editor to be editing and consuming runes")
	}
	return m
}

func TestSettlementEscWithIdleEmbedReturnsFocusToStatusSide(t *testing.T) {
	m := newSettlementEmbedModel(t)
	if m.settlementSettingsPanel.FocusConsumesRunes() {
		t.Fatal("freshly opened embed should not consume runes")
	}

	nm, _ := updateModel(t, m, press(tea.KeyEscape))
	if nm.focusedPanel != panelLeft {
		t.Fatalf("focusedPanel = %v, want panelLeft", nm.focusedPanel)
	}
	if nm.settlementSettingsPanel.Closed() {
		t.Fatal("Esc must return focus to the status side, not close the embed")
	}
}

func TestSettlementHWithIdleEmbedReturnsFocusToStatusSide(t *testing.T) {
	m := newSettlementEmbedModel(t)
	nm, _ := updateModel(t, m, press('h'))
	if nm.focusedPanel != panelLeft {
		t.Fatalf("focusedPanel = %v, want panelLeft", nm.focusedPanel)
	}
}

func TestSettlementEscForwardedToConsumingEditorBeforeFocusReturn(t *testing.T) {
	m := newSettlementEmbedModel(t)
	m = driveSettlementEmbedIntoEditing(t, m)

	// First Esc: the consuming editor receives it (discarding the edit);
	// focus stays on the settings side.
	m, _ = updateModel(t, m, press(tea.KeyEscape))
	if m.focusedPanel != panelRight {
		t.Fatalf("focusedPanel = %v, want panelRight while the editor consumed Esc", m.focusedPanel)
	}
	if m.settlementSettingsPanel.FocusConsumesRunes() {
		t.Fatal("first Esc should exit the editor's edit mode")
	}

	// Second Esc: nothing consumes runes — focus returns to the status side.
	m, _ = updateModel(t, m, press(tea.KeyEscape))
	if m.focusedPanel != panelLeft {
		t.Fatalf("focusedPanel = %v, want panelLeft after second Esc", m.focusedPanel)
	}
}

func TestSettlementQGatedByFocusConsumesRunes(t *testing.T) {
	t.Run("consuming editor swallows q", func(t *testing.T) {
		m := newSettlementEmbedModel(t)
		m = driveSettlementEmbedIntoEditing(t, m)

		nm, cmd := updateModel(t, m, press('q'))
		if cmd != nil {
			t.Fatal("q must route to the consuming editor, not quit")
		}
		if nm.state != stateSettlement || nm.focusedPanel != panelRight {
			t.Fatalf("state/focus changed: state=%v focus=%v", nm.state, nm.focusedPanel)
		}
		if !nm.settlementSettingsPanel.FocusConsumesRunes() {
			t.Fatal("editor should still be editing after q")
		}
	})
	t.Run("idle embed lets q quit", func(t *testing.T) {
		m := newSettlementEmbedModel(t)
		_, cmd := updateModel(t, m, press('q'))
		if cmd == nil {
			t.Fatal("expected quit command from q on an idle embed")
		}
		if _, ok := cmd().(tea.QuitMsg); !ok {
			t.Fatalf("expected tea.QuitMsg, got %T", cmd())
		}
	})
}

func TestSettlementBodyUsesHorizontalSplit(t *testing.T) {
	m := minimalModel(stateSettlement, nil, nil)
	m.width = 140
	m.height = 36
	st, err := settlement.ParseStatus([]byte(`{
		"enabled": true,
		"queue": {"pending": 5, "total": 5},
		"items": [
			{"id": "item-1", "status": "pending", "work_item": "settlement-operational-closure"},
			{"id": "item-2", "status": "pending", "work_item": "settlement-operational-closure"},
			{"id": "item-3", "status": "pending", "work_item": "settlement-operational-closure"},
			{"id": "item-4", "status": "pending", "work_item": "settlement-operational-closure"},
			{"id": "item-5", "status": "pending", "work_item": "settlement-operational-closure"}
		],
		"harness": {"mode": "random", "selected": "claude-code", "concurrency": 1}
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	m.settlement = m.settlement.ReplaceStatus(st)

	lines := m.renderSettlementBodyLines(120, 24)
	joined := strings.Join(lines, "\n")
	if !strings.Contains(joined, "Settings") {
		t.Fatalf("settlement body should include horizontal settings separator, got:\n%s", joined)
	}
	if strings.Contains(joined, "│") {
		t.Fatalf("settlement body should not use a vertical split, got:\n%s", joined)
	}
	settingsIdx := -1
	for i, line := range lines {
		if strings.Contains(line, "Settings") {
			settingsIdx = i
			break
		}
	}
	if settingsIdx < 0 || settingsIdx < len(lines)/2 {
		t.Fatalf("settings separator should be pinned near the bottom after the queue/status area, idx=%d:\n%s", settingsIdx, joined)
	}
	if len(lines) != 24 {
		t.Fatalf("settlement body should fill the full panel height, len=%d:\n%s", len(lines), joined)
	}
	if strings.TrimSpace(lines[len(lines)-1]) == "" {
		t.Fatalf("settings dock should end at the bottom of the settlement body:\n%s", joined)
	}
}

func TestSettlementActionCompleteShowsNoDispatchReason(t *testing.T) {
	m := minimalModel(stateSettlement, nil, nil)
	result, err := settlement.ParseActionResult("process", []byte(`{"dispatched": false, "ok": true, "reason": "disabled"}`))
	if err != nil {
		t.Fatalf("ParseActionResult: %v", err)
	}

	next, cmd := m.Update(settlementActionCompleteMsg{action: "process", result: result})
	nm := next.(model)

	if nm.flashErr != "[settlement] not dispatched: disabled" {
		t.Fatalf("flashErr = %q", nm.flashErr)
	}
	if cmd == nil {
		t.Fatal("expected status reload command after settlement action")
	}
}

func TestSettlementStatusLoadedAutoProcessesReadyQueue(t *testing.T) {
	m := minimalModel(stateSettlement, nil, nil)
	status := settlement.Status{
		Available: true,
		Enabled:   true,
		Queue:     settlement.Queue{Pending: 3, Total: 3},
		Harness:   settlement.Harness{Concurrency: 1, ActiveLeases: 0},
	}

	next, cmd := m.Update(settlementStatusLoadedMsg{status: status})
	nm := next.(model)

	if !nm.settlementProcessInFlight {
		t.Fatal("ready settlement queue should start an automatic process command")
	}
	if cmd == nil {
		t.Fatal("expected automatic process command")
	}
}

func TestSettlementStatusLoadedAutoProcessesDrainedBatchBacklog(t *testing.T) {
	m := minimalModel(stateSettlement, nil, nil)
	status := settlement.Status{
		Available: true,
		Enabled:   true,
		Queue:     settlement.Queue{Pending: 0, Running: 0, Total: 0},
		Batch:     settlement.Batch{BacklogSize: 76},
		Harness:   settlement.Harness{Concurrency: 1, ActiveLeases: 0},
	}

	next, cmd := m.Update(settlementStatusLoadedMsg{status: status})
	nm := next.(model)

	if !nm.settlementProcessInFlight {
		t.Fatal("drained active batch with backlog should start an automatic process command")
	}
	if cmd == nil {
		t.Fatal("expected automatic process command")
	}
}

func TestSettlementStatusLoadedDoesNotAutoProcessWhileLeaseActive(t *testing.T) {
	m := minimalModel(stateSettlement, nil, nil)
	status := settlement.Status{
		Available: true,
		Enabled:   true,
		Queue:     settlement.Queue{Pending: 3, Running: 1, Total: 4},
		Harness:   settlement.Harness{Concurrency: 1, ActiveLeases: 1},
	}

	next, cmd := m.Update(settlementStatusLoadedMsg{status: status})
	nm := next.(model)

	if nm.settlementProcessInFlight {
		t.Fatal("active lease at concurrency should not start another process command")
	}
	if cmd != nil {
		t.Fatal("did not expect automatic process command")
	}
}

func TestAutomaticSettlementProcessCompletionDoesNotTightLoop(t *testing.T) {
	m := minimalModel(stateSettlement, nil, nil)
	m.settlementProcessInFlight = true
	result, err := settlement.ParseActionResult("process", []byte(`{"dispatched": true, "ok": true}`))
	if err != nil {
		t.Fatalf("ParseActionResult: %v", err)
	}

	next, cmd := m.Update(settlementActionCompleteMsg{action: "process", automatic: true, result: result})
	nm := next.(model)

	if nm.settlementProcessInFlight {
		t.Fatal("automatic process completion should clear in-flight flag")
	}
	if cmd != nil {
		t.Fatal("automatic completion should wait for the next status poll, not immediately reload and relaunch")
	}
	if nm.flashErr != "" {
		t.Fatalf("automatic completion should not spam the status bar, got %q", nm.flashErr)
	}
}

func TestSettlementInFlightFailsafeClearsStuckFlag(t *testing.T) {
	// Regression: a subprocess goroutine that never returned would leave
	// settlementProcessInFlight=true forever, gating every subsequent
	// auto-process tick. The failsafe must clear it after the ceiling.
	m := minimalModel(stateSettlement, nil, nil)
	m.settlementProcessInFlight = true
	m.settlementProcessStartedAt = time.Now().Add(-(settlementInFlightCeiling + time.Minute))

	nm, recovered := m.settlementInFlightFailsafe()
	if !recovered {
		t.Fatal("expected failsafe to fire on a flag stuck past the ceiling")
	}
	if nm.settlementProcessInFlight {
		t.Fatal("failsafe should clear settlementProcessInFlight")
	}
	if !nm.settlementProcessStartedAt.IsZero() {
		t.Fatal("failsafe should reset the started-at timestamp")
	}
	if nm.flashErr == "" {
		t.Fatal("failsafe should surface a flash error so the user sees recovery")
	}
}

func TestSettlementInFlightFailsafeLeavesRecentInFlightAlone(t *testing.T) {
	// The failsafe must NOT fire while a subprocess is still legitimately
	// running — otherwise we'd dispatch a second process that races the
	// first for the queue lock.
	m := minimalModel(stateSettlement, nil, nil)
	m.settlementProcessInFlight = true
	m.settlementProcessStartedAt = time.Now().Add(-30 * time.Second) // well within ceiling

	nm, recovered := m.settlementInFlightFailsafe()
	if recovered {
		t.Fatal("failsafe should not fire for a recently-started subprocess")
	}
	if !nm.settlementProcessInFlight {
		t.Fatal("failsafe should leave the in-flight flag set")
	}
	if nm.flashErr != "" {
		t.Fatalf("failsafe should not flash for healthy in-flight, got %q", nm.flashErr)
	}
}

func TestSettlementInFlightFailsafeRecoversFromMissingTimestamp(t *testing.T) {
	// Defensive: if InFlight is true but the timestamp was never set
	// (e.g. older state from a code path we missed), the failsafe must
	// still recover rather than leaving the loop permanently gated.
	m := minimalModel(stateSettlement, nil, nil)
	m.settlementProcessInFlight = true
	// settlementProcessStartedAt is intentionally left zero.

	nm, recovered := m.settlementInFlightFailsafe()
	if !recovered {
		t.Fatal("expected failsafe to fire when timestamp was never set")
	}
	if nm.settlementProcessInFlight {
		t.Fatal("failsafe should clear the flag when timestamp is zero")
	}
}

func TestSettlementInFlightFailsafeNoOpWhenNotInFlight(t *testing.T) {
	m := minimalModel(stateSettlement, nil, nil)
	// settlementProcessInFlight intentionally false.

	nm, recovered := m.settlementInFlightFailsafe()
	if recovered {
		t.Fatal("failsafe should never fire when no subprocess is in flight")
	}
	if nm.flashErr != "" {
		t.Fatalf("failsafe should not flash when not in flight, got %q", nm.flashErr)
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

	msg := tea.MouseClickMsg{
		Button: tea.MouseLeft,
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

	msg := tea.MouseClickMsg{
		Button: tea.MouseLeft,
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

	msg := tea.MouseClickMsg{
		Button: tea.MouseLeft,
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

	msg := tea.KeyPressMsg{Code: tea.KeyTab}
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

	msg := tea.KeyPressMsg{Code: tea.KeyTab}
	_, consumed := handlePanelRouting(&m, msg, noopCallbacks())
	if consumed {
		t.Error("tab when already on right should not be consumed")
	}
}

func TestHandlePanelRoutingEscFocusesLeft(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	m.focusedPanel = panelRight
	m.terminalMode = false

	msg := tea.KeyPressMsg{Code: tea.KeyEscape}
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

	msg := tea.KeyPressMsg{Code: tea.KeyEscape}
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

	keyMsg := tea.KeyPressMsg{Code: 't', Mod: tea.ModCtrl}
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

	msg := tea.KeyPressMsg{Code: 't', Mod: tea.ModCtrl}
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
		msg := tea.KeyPressMsg{Code: []rune(key)[0], Text: key}
		if key == "enter" {
			msg = tea.KeyPressMsg{Code: tea.KeyEnter}
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
		fd, _ := m.followupDetail.Update(tea.KeyPressMsg{Code: tea.KeyTab})
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

	next, _ := m.Update(tea.KeyPressMsg{Code: 'P', Text: "P"})
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

	next, _ := m.Update(tea.KeyPressMsg{Code: 'P', Text: "P"})
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

	next, _ := m.Update(tea.KeyPressMsg{Code: 'P', Text: "P"})
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
		name string
		msg  followup.PostReviewCompleteMsg
		want string
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

	next, _ := m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
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

	next, _ := m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	nm := next.(model)

	if nm.terminalMode {
		t.Error("terminalMode should remain false after j key when new item has no spec panel")
	}
}

// --- loadFollowupDetail unit tests ---

// TestLoadFollowupDetailSyncsTerminalMode tests loadFollowupDetail directly:
// terminalMode tracks spec-panel existence and the mtime baseline resets.
// (Mouse tracking is persistent root-view state under bubbletea v2, so no
// re-enable command is expected in any case.)
func TestLoadFollowupDetailSyncsTerminalMode(t *testing.T) {
	const id = "fu-test"
	panel := work.NewSpecPanelModel(id)

	t.Run("spec_panel", func(t *testing.T) {
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
		if cmd == nil {
			t.Error("loadFollowupDetail should return the detail load command")
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
		if cmd == nil {
			t.Error("loadFollowupDetail should return the detail load command")
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

	// Activate the Comments tab so 'e' routes to the review card editor.
	for i := 0; i < 10; i++ {
		if m.followupDetail.ActiveTab() == followup.TabComments {
			break
		}
		fd, _ := m.followupDetail.Update(tea.KeyPressMsg{Code: tea.KeyTab})
		m.followupDetail = fd
	}

	// Send 'e' to enter edit mode on the first inline comment.
	next, _ = m.Update(tea.KeyPressMsg{Code: 'e', Text: "e"})
	m = next.(model)

	if !m.followupDetail.IsEditing() {
		t.Fatal("setup: followupDetail should be in edit mode after 'e' key")
	}
	return m
}

func TestEditModeGuardEscDoesNotShiftPanelFocus(t *testing.T) {
	m := followupModelWithEditingActive(t)

	// Esc during editing should NOT move focus to panelLeft.
	next, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
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
	next, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
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

	// Activate the Comments tab (TabFinding is the default now).
	for i := 0; i < 10; i++ {
		if m.followupDetail.ActiveTab() == followup.TabComments {
			break
		}
		fd, _ := m.followupDetail.Update(tea.KeyPressMsg{Code: tea.KeyTab})
		m.followupDetail = fd
	}
	if m.followupDetail.ActiveTab() != followup.TabComments {
		t.Fatalf("setup: expected TabComments to be active, got %v", m.followupDetail.ActiveTab())
	}
	return m
}

func TestPKeyConfirmTitleContainsDefaultCOMMENT(t *testing.T) {
	m := followupModelWithReview(t, "COMMENT", 2)

	next, _ := m.Update(tea.KeyPressMsg{Code: 'P', Text: "P"})
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

	next, _ := m.Update(tea.KeyPressMsg{Code: 'P', Text: "P"})
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

	next, _ := m.Update(tea.KeyPressMsg{Code: 'P', Text: "P"})
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
	next, _ := m.Update(tea.KeyPressMsg{Code: 'P', Text: "P"})
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
	next, _ := m.Update(tea.KeyPressMsg{Code: 'w', Text: "w"})
	nm := next.(model)
	if nm.state != stateFollowUps {
		t.Errorf("w during editing: state changed to %v, want stateFollowUps", nm.state)
	}

	// '?' should NOT open help during editing.
	next, _ = m.Update(tea.KeyPressMsg{Code: '?', Text: "?"})
	nm = next.(model)
	if nm.showHelp {
		t.Error("? during editing: showHelp was set, want suppressed")
	}
}

func TestEditModeGuardTabDoesNotShiftPanelFocusDuringEditing(t *testing.T) {
	m := followupModelWithEditingActive(t)

	// Tab during editing should not move focus to left panel.
	next, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyTab})
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
			Body: "Error ignored.", Lens: "correctness",
			Grounding: "Could cause data loss.", Selected: selectAll,
		},
		{
			Severity: "suggestion", Title: "Extract helper", File: "util.go", Line: 55,
			Body: "Refactor opportunity.", Lens: "clarity",
			Grounding: "", Selected: selectAll,
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

	// Activate the Triage tab (TabFinding is the default now).
	for i := 0; i < 10; i++ {
		if m.followupDetail.ActiveTab() == followup.TabTriage {
			break
		}
		fd, _ := m.followupDetail.Update(tea.KeyPressMsg{Code: tea.KeyTab})
		m.followupDetail = fd
	}
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
	next, cmd := m.Update(tea.KeyPressMsg{Code: 'p', Text: "p"})
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

	next, cmd := m.Update(tea.KeyPressMsg{Code: 'p', Text: "p"})
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

	out := m.viewContent()

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

	next, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
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

	_, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})

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

	out := m.viewContent()

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

	out := m.viewContent()

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
	_, cmd := m.Update(tea.KeyPressMsg{Code: 'q', Text: "q"})
	if cmd == nil {
		t.Error("q key in stateNoRepo should return a non-nil Cmd (tea.Quit)")
	}

	// ctrl+c should return tea.Quit
	_, cmd = m.Update(tea.KeyPressMsg{Code: 'c', Mod: tea.ModCtrl})
	if cmd == nil {
		t.Error("ctrl+c in stateNoRepo should return a non-nil Cmd (tea.Quit)")
	}

	// an unrelated key (e.g. 'j') should be consumed silently
	next, cmd := m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if cmd != nil {
		t.Error("unrelated key in stateNoRepo should return nil Cmd")
	}
	if next.(model).state != stateNoRepo {
		t.Error("state should remain stateNoRepo after unrelated key")
	}
}

// TestDoctorResultMsgPopulatesBanner verifies that a non-empty banner from
// runDoctor is stored on the model so the status bar can render it.
func TestDoctorResultMsgPopulatesBanner(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	banner := "lore doctor: 1 issue(s) detected — run 'lore doctor' for details"

	next, cmd := m.Update(doctorResultMsg{banner: banner})
	nm := next.(model)

	if nm.doctorBanner != banner {
		t.Errorf("doctorBanner = %q, want %q", nm.doctorBanner, banner)
	}
	if cmd != nil {
		t.Error("doctorResultMsg should not return a follow-up Cmd")
	}
}

// TestDoctorResultMsgClearsBannerOnClean verifies that an empty banner from a
// later clean run replaces a prior drift banner (so a heal-then-relaunch
// cycle clears the warning).
func TestDoctorResultMsgClearsBannerOnClean(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	m.doctorBanner = "stale drift message"

	next, _ := m.Update(doctorResultMsg{})
	nm := next.(model)

	if nm.doctorBanner != "" {
		t.Errorf("doctorBanner = %q, want empty after clean result", nm.doctorBanner)
	}
}

// TestDoctorBannerSurvivesKeyPress verifies the contract that drift is a
// standing condition, not a transient error. Pressing a key clears flashErr
// but must not clear doctorBanner.
func TestDoctorBannerSurvivesKeyPress(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	m.doctorBanner = "lore doctor: 2 issue(s) detected — run 'lore doctor' for details"
	m.flashErr = "transient failure"

	next, _ := m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	nm := next.(model)

	if nm.flashErr != "" {
		t.Errorf("flashErr should clear on key press, got %q", nm.flashErr)
	}
	if nm.doctorBanner == "" {
		t.Error("doctorBanner must survive key press (drift is standing condition)")
	}
}

// TestStatusBarFlashErrTakesPrecedenceOverDoctorBanner verifies the status
// bar precedence: flashErr (red) outranks doctorBanner (amber) so transient
// action failures are visible immediately.
func TestStatusBarFlashErrTakesPrecedenceOverDoctorBanner(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	m.width = 200
	m.height = 40
	m.flashErr = "transient-fail-marker"
	m.doctorBanner = "doctor-banner-marker"

	bar := m.renderStatusBar(m.width)
	if !strings.Contains(bar, "transient-fail-marker") {
		t.Errorf("status bar should contain flashErr when both set; got %q", bar)
	}
	if strings.Contains(bar, "doctor-banner-marker") {
		t.Errorf("status bar must not show doctorBanner while flashErr is set; got %q", bar)
	}
}

// TestStatusBarRendersDoctorBannerWhenNoFlashErr verifies the amber drift
// indicator appears when there is no higher-priority signal to render.
func TestStatusBarRendersDoctorBannerWhenNoFlashErr(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	m.width = 200
	m.height = 40
	m.doctorBanner = "doctor-banner-marker"

	bar := m.renderStatusBar(m.width)
	if !strings.Contains(bar, "doctor-banner-marker") {
		t.Errorf("status bar should contain doctorBanner when flashErr empty; got %q", bar)
	}
}

// === Hint↔handler keybind contract tests ===
//
// Every key advertised on a display surface (status bar hint set, help modal
// row, panel border annotation) gets a subtest named by its hint text that
// drives the key through the real model.Update path and asserts a minimal
// observable effect. Deleting a handler makes the matching test fail.

// workContractModel builds a stateWork model with two items and a loaded
// detail (Meta/Plan/Notes tabs) for status-bar contract tests.
func workContractModel() model {
	items := []work.WorkItem{
		{Slug: "item-1", Title: "Item One"},
		{Slug: "item-2", Title: "Item Two"},
	}
	m := minimalModel(stateWork, items, nil)
	m.width = 120
	m.height = 40
	plan := "# Plan\n\nbody"
	notes := "notes"
	m.detail = work.NewDetailModel("", "item-1")
	m.detail, _ = m.detail.Update(work.DetailLoadedMsg{Slug: "item-1", Detail: &work.WorkItemDetail{
		Slug: "item-1", Title: "Item One", Status: "active",
		PlanContent: &plan, NotesContent: &notes,
	}})
	return m
}

// TestConfirmModalKeybindContract verifies the keybinds displayed in
// renderConfirmModal ("y / Enter confirm", "any key cancel", and post_review's
// "n / Esc cancel") against the confirm interception in Update.
func TestConfirmModalKeybindContract(t *testing.T) {
	actions := []string{"archive", "unarchive", "delete", "dismiss", "delete_followup", "post_review"}
	confirmModel := func(action string) model {
		m := minimalModel(stateWork, nil, nil)
		m.confirmAction = action
		m.confirmSlug = "slug-x"
		m.confirmTitle = "Title X"
		return m
	}
	for _, action := range actions {
		t.Run(action+"/y (confirm)", func(t *testing.T) {
			nm, cmd := updateModel(t, confirmModel(action), press('y'))
			if nm.confirmAction != "" {
				t.Error("confirm modal should close on y")
			}
			if cmd == nil {
				t.Error("y should dispatch the confirmed action command")
			}
		})
		t.Run(action+"/Enter (confirm)", func(t *testing.T) {
			nm, cmd := updateModel(t, confirmModel(action), press(tea.KeyEnter))
			if nm.confirmAction != "" {
				t.Error("confirm modal should close on Enter")
			}
			if cmd == nil {
				t.Error("Enter should dispatch the confirmed action command")
			}
		})
		t.Run(action+"/any key (cancel)", func(t *testing.T) {
			nm, cmd := updateModel(t, confirmModel(action), press('z'))
			if nm.confirmAction != "" {
				t.Error("confirm modal should close on any other key")
			}
			if cmd != nil {
				t.Error("cancel must not dispatch an action command")
			}
		})
	}
	t.Run("post_review/n / Esc (cancel)", func(t *testing.T) {
		for _, k := range []tea.KeyPressMsg{press('n'), press(tea.KeyEscape)} {
			nm, cmd := updateModel(t, confirmModel("post_review"), k)
			if nm.confirmAction != "" {
				t.Errorf("confirm modal should close on %v", k)
			}
			if cmd != nil {
				t.Errorf("%v must not dispatch the post command", k)
			}
		}
	})
}

// TestHelpModalKeybindContract verifies "? this help" opens the modal from
// every advertising state and "Press ? or Esc to close" closes it.
func TestHelpModalKeybindContract(t *testing.T) {
	states := []struct {
		name  string
		state appState
	}{
		{"work", stateWork},
		{"followups", stateFollowUps},
		{"settlement", stateSettlement},
		{"knowledge", stateKnowledge},
	}
	for _, tc := range states {
		t.Run(tc.name+"/? (open help)", func(t *testing.T) {
			nm, _ := updateModel(t, minimalModel(tc.state, nil, nil), press('?'))
			if !nm.showHelp {
				t.Error("? should open the help modal")
			}
		})
	}
	t.Run("? (close)", func(t *testing.T) {
		m := minimalModel(stateWork, nil, nil)
		m.showHelp = true
		nm, _ := updateModel(t, m, press('?'))
		if nm.showHelp {
			t.Error("? should close the help modal")
		}
	})
	t.Run("Esc (close)", func(t *testing.T) {
		m := minimalModel(stateWork, nil, nil)
		m.showHelp = true
		nm, _ := updateModel(t, m, press(tea.KeyEscape))
		if nm.showHelp {
			t.Error("Esc should close the help modal")
		}
	})
	t.Run("other keys swallowed while open", func(t *testing.T) {
		m := workContractModel()
		m.showHelp = true
		nm, cmd := updateModel(t, m, press('q'))
		if !nm.showHelp {
			t.Error("q must not close the help modal")
		}
		if cmd != nil {
			t.Error("swallowed keys must not dispatch commands")
		}
		if nm.list.Cursor() != 0 {
			t.Error("swallowed keys must not reach the list")
		}
	})
	t.Run("scroll keys stay inside the modal", func(t *testing.T) {
		m := workContractModel()
		m.showHelp = true
		nm, _ := updateModel(t, m, press('j'))
		if !nm.showHelp {
			t.Error("j must not close the help modal")
		}
		if nm.list.Cursor() != 0 {
			t.Error("j must scroll the help viewport, not the list")
		}
	})

	// Scroll contract: open at a 20-row terminal so the keybinding list
	// overflows the viewport and every advertised scroll key is meaningful.
	scrollableHelp := func(t *testing.T) model {
		t.Helper()
		m := minimalModel(stateWork, nil, nil)
		m.width = 100
		m.height = 20
		nm, _ := updateModel(t, m, press('?'))
		if !nm.showHelp {
			t.Fatal("? should open the help modal")
		}
		if nm.helpViewport.AtBottom() {
			t.Fatal("help content should overflow the viewport at height 20")
		}
		return nm
	}
	t.Run("? (open: viewport capped to terminal height)", func(t *testing.T) {
		nm := scrollableHelp(t)
		if got, want := nm.helpViewport.Height(), nm.height-helpModalChrome; got != want {
			t.Errorf("viewport height = %d, want terminal-capped %d", got, want)
		}
		if !nm.helpViewport.AtTop() {
			t.Error("help should open scrolled to top")
		}
	})
	t.Run("j (scroll down)", func(t *testing.T) {
		nm, _ := updateModel(t, scrollableHelp(t), press('j'))
		if nm.helpViewport.YOffset() != 1 {
			t.Errorf("j should scroll down one line, offset = %d", nm.helpViewport.YOffset())
		}
	})
	t.Run("down (scroll down)", func(t *testing.T) {
		nm, _ := updateModel(t, scrollableHelp(t), press(tea.KeyDown))
		if nm.helpViewport.YOffset() != 1 {
			t.Errorf("down should scroll down one line, offset = %d", nm.helpViewport.YOffset())
		}
	})
	t.Run("k (scroll up)", func(t *testing.T) {
		m, _ := updateModel(t, scrollableHelp(t), press('j'))
		nm, _ := updateModel(t, m, press('k'))
		if nm.helpViewport.YOffset() != 0 {
			t.Errorf("k should scroll back up, offset = %d", nm.helpViewport.YOffset())
		}
	})
	t.Run("up (scroll up)", func(t *testing.T) {
		m, _ := updateModel(t, scrollableHelp(t), press('j'))
		nm, _ := updateModel(t, m, press(tea.KeyUp))
		if nm.helpViewport.YOffset() != 0 {
			t.Errorf("up should scroll back up, offset = %d", nm.helpViewport.YOffset())
		}
	})
	t.Run("pgdn (page down)", func(t *testing.T) {
		nm, _ := updateModel(t, scrollableHelp(t), press(tea.KeyPgDown))
		if got, want := nm.helpViewport.YOffset(), nm.helpViewport.Height(); got != want {
			t.Errorf("pgdn should advance one page, offset = %d, want %d", got, want)
		}
	})
	t.Run("pgup (page up)", func(t *testing.T) {
		m, _ := updateModel(t, scrollableHelp(t), press(tea.KeyPgDown))
		nm, _ := updateModel(t, m, press(tea.KeyPgUp))
		if nm.helpViewport.YOffset() != 0 {
			t.Errorf("pgup should return one page up, offset = %d", nm.helpViewport.YOffset())
		}
	})
	t.Run("G (jump to bottom)", func(t *testing.T) {
		nm, _ := updateModel(t, scrollableHelp(t), press('G'))
		if !nm.helpViewport.AtBottom() {
			t.Error("G should jump to bottom")
		}
	})
	t.Run("g (jump to top)", func(t *testing.T) {
		m, _ := updateModel(t, scrollableHelp(t), press('G'))
		nm, _ := updateModel(t, m, press('g'))
		if !nm.helpViewport.AtTop() {
			t.Error("g should jump back to top")
		}
	})
	t.Run("Esc (close while scrolled)", func(t *testing.T) {
		m, _ := updateModel(t, scrollableHelp(t), press('G'))
		nm, _ := updateModel(t, m, press(tea.KeyEscape))
		if nm.showHelp {
			t.Error("Esc should close the help modal")
		}
	})
	t.Run("resize re-caps the viewport", func(t *testing.T) {
		m := scrollableHelp(t)
		nm, _ := updateModel(t, m, tea.WindowSizeMsg{Width: 100, Height: 14})
		if got, want := nm.helpViewport.Height(), 14-helpModalChrome; got != want {
			t.Errorf("viewport height after shrink = %d, want %d", got, want)
		}
	})
	t.Run("help modal renders over knowledge browser", func(t *testing.T) {
		m := minimalModel(stateKnowledge, nil, nil)
		m.width = 120
		m.height = 40
		m.showHelp = true
		out := stripANSI(m.viewContent())
		if !strings.Contains(out, "Keyboard Shortcuts") {
			t.Error("help modal opened from stateKnowledge must actually render")
		}
	})
}

// TestWorkListStatusBarKeybindContract verifies the stateWork panelLeft
// status-bar hint set: "j/k navigate · Enter open · s spec · c chat ·
// f follow-ups · t settlement · K knowledge · S settings · q quit · ? help"
// plus the help-modal-only Work List rows (N, L, ctrl+a) and the
// "ctrl+a active · archived" border annotation. f and t are also advertised
// per-section in the tab indicator (TestTabIndicatorAdvertisesSectionKeys).
func TestWorkListStatusBarKeybindContract(t *testing.T) {
	t.Run("j/k (navigate)", func(t *testing.T) {
		m := workContractModel()
		nm, _ := updateModel(t, m, press('j'))
		if nm.list.Cursor() != 1 {
			t.Fatalf("j should move cursor down, got %d", nm.list.Cursor())
		}
		nm, _ = updateModel(t, nm, press('k'))
		if nm.list.Cursor() != 0 {
			t.Fatalf("k should move cursor up, got %d", nm.list.Cursor())
		}
	})
	t.Run("Enter (open)", func(t *testing.T) {
		m := workContractModel()
		nm, cmd := updateModel(t, m, press(tea.KeyEnter))
		if cmd == nil {
			t.Fatal("Enter should emit a selection command")
		}
		msg := cmd()
		if _, ok := msg.(work.ItemSelectedMsg); !ok {
			t.Fatalf("Enter produced %T, want work.ItemSelectedMsg", msg)
		}
		nm, _ = updateModel(t, nm, msg)
		if nm.focusedPanel != panelRight {
			t.Error("opening an item should focus the detail panel")
		}
	})
	t.Run("s (spec)", func(t *testing.T) {
		m := workContractModel()
		nm, cmd := updateModel(t, m, press('s'))
		if cmd == nil {
			t.Fatal("s should emit a spec request")
		}
		msg := cmd()
		if _, ok := msg.(work.SpecRequestMsg); !ok {
			t.Fatalf("s produced %T, want work.SpecRequestMsg", msg)
		}
		nm, _ = updateModel(t, nm, msg)
		if !nm.sessionConfirmActive || nm.sessionConfirmChatMode {
			t.Error("spec request should open the spec confirm modal in spec mode")
		}
	})
	t.Run("c (chat)", func(t *testing.T) {
		m := workContractModel()
		nm, cmd := updateModel(t, m, press('c'))
		if cmd == nil {
			t.Fatal("c should emit a chat request")
		}
		msg := cmd()
		if _, ok := msg.(work.ChatRequestMsg); !ok {
			t.Fatalf("c produced %T, want work.ChatRequestMsg", msg)
		}
		nm, _ = updateModel(t, nm, msg)
		if !nm.sessionConfirmActive || !nm.sessionConfirmChatMode {
			t.Error("chat request should open the confirm modal in chat mode")
		}
	})
	t.Run("K (knowledge)", func(t *testing.T) {
		nm, cmd := updateModel(t, workContractModel(), press('K'))
		if nm.state != stateKnowledge {
			t.Error("K should enter the knowledge browser")
		}
		if cmd == nil {
			t.Error("K should dispatch the manifest load")
		}
	})
	t.Run("q (quit)", func(t *testing.T) {
		_, cmd := updateModel(t, workContractModel(), press('q'))
		if cmd == nil {
			t.Fatal("q should quit")
		}
		if _, ok := cmd().(tea.QuitMsg); !ok {
			t.Error("q should dispatch tea.Quit")
		}
	})
	t.Run("N (create work items with AI)", func(t *testing.T) {
		nm, _ := updateModel(t, workContractModel(), press('N'))
		if !nm.aiInputActive {
			t.Error("N should open the AI work-item modal")
		}
	})
	t.Run("L (toggle layout)", func(t *testing.T) {
		m := workContractModel()
		before := m.layoutMode
		nm, _ := updateModel(t, m, press('L'))
		if nm.layoutMode == before {
			t.Error("L should toggle the layout mode")
		}
	})
	t.Run("ctrl+a (active · archived)", func(t *testing.T) {
		m := workContractModel()
		nm, _ := updateModel(t, m, press('a', tea.ModCtrl))
		if nm.list.GetFilterMode() != work.FilterArchived {
			t.Error("ctrl+a should switch the list to the archived filter")
		}
		nm, _ = updateModel(t, nm, press('a', tea.ModCtrl))
		if nm.list.GetFilterMode() != work.FilterActive {
			t.Error("ctrl+a should toggle back to the active filter")
		}
	})
	t.Run("f (follow-ups)", func(t *testing.T) {
		nm, cmd := updateModel(t, workContractModel(), press('f'))
		if nm.state != stateFollowUps {
			t.Error("f should switch to the follow-ups view")
		}
		if cmd == nil {
			t.Error("f should dispatch the follow-up index load")
		}
	})
	t.Run("t (settlement)", func(t *testing.T) {
		nm, _ := updateModel(t, workContractModel(), press('t'))
		if nm.state != stateSettlement {
			t.Error("t should switch to the settlement panel")
		}
	})
	t.Run("l (open)", func(t *testing.T) {
		nm, _ := updateModel(t, workContractModel(), press('l'))
		if nm.focusedPanel != panelRight {
			t.Error("l should enter the detail panel (parity with tab)")
		}
	})
	t.Run("A (archive / unarchive)", func(t *testing.T) {
		nm, _ := updateModel(t, workContractModel(), press('A'))
		if nm.confirmAction != "archive" {
			t.Errorf("A should open the archive confirm modal, got %q", nm.confirmAction)
		}
	})
	t.Run("D (delete)", func(t *testing.T) {
		nm, _ := updateModel(t, workContractModel(), press('D'))
		if nm.confirmAction != "delete" {
			t.Errorf("D should open the delete confirm modal, got %q", nm.confirmAction)
		}
	})
}

// TestWorkDetailStatusBarKeybindContract verifies the stateWork panelRight
// hint set: "s spec · c chat · Tab/Shift-Tab cycle tabs · j/k scroll ·
// h/Esc back to list · ? help".
func TestWorkDetailStatusBarKeybindContract(t *testing.T) {
	detailModel := func() model {
		m := workContractModel()
		m.focusedPanel = panelRight
		return m
	}
	t.Run("Tab/Shift-Tab (cycle tabs)", func(t *testing.T) {
		m := detailModel()
		before := m.detail.ActiveTab()
		nm, _ := updateModel(t, m, press(tea.KeyTab))
		if nm.detail.ActiveTab() == before {
			t.Fatal("Tab should cycle the detail tab")
		}
		nm, _ = updateModel(t, nm, press(tea.KeyTab, tea.ModShift))
		if nm.detail.ActiveTab() != before {
			t.Fatal("Shift-Tab should cycle back")
		}
	})
	t.Run("s (spec)", func(t *testing.T) {
		nm, cmd := updateModel(t, detailModel(), press('s'))
		if cmd == nil {
			t.Fatal("s should emit a spec request from the detail panel")
		}
		msg := cmd()
		if _, ok := msg.(work.SpecRequestMsg); !ok {
			t.Fatalf("s produced %T, want work.SpecRequestMsg", msg)
		}
		nm, _ = updateModel(t, nm, msg)
		if !nm.sessionConfirmActive {
			t.Error("spec request should open the confirm modal")
		}
	})
	t.Run("c (chat)", func(t *testing.T) {
		nm, cmd := updateModel(t, detailModel(), press('c'))
		if cmd == nil {
			t.Fatal("c should emit a chat request from the detail panel")
		}
		msg := cmd()
		if _, ok := msg.(work.ChatRequestMsg); !ok {
			t.Fatalf("c produced %T, want work.ChatRequestMsg", msg)
		}
		nm, _ = updateModel(t, nm, msg)
		if !nm.sessionConfirmActive || !nm.sessionConfirmChatMode {
			t.Error("chat request should open the confirm modal in chat mode")
		}
	})
	t.Run("h (back to list)", func(t *testing.T) {
		nm, _ := updateModel(t, detailModel(), press('h'))
		if nm.focusedPanel != panelLeft {
			t.Error("h should refocus the list panel")
		}
	})
	t.Run("Esc (back to list)", func(t *testing.T) {
		nm, _ := updateModel(t, detailModel(), press(tea.KeyEscape))
		if nm.focusedPanel != panelLeft {
			t.Error("Esc should refocus the list panel")
		}
	})
}

// TestTerminalModeStatusBarKeybindContract verifies the terminal-mode hint
// set: "ctrl+t detail · Esc back to list (forwarded) · Ctrl+c terminate".
func TestTerminalModeStatusBarKeybindContract(t *testing.T) {
	terminalModel := func() model {
		m := workContractModel()
		m.focusedPanel = panelRight
		m.terminalMode = true
		m.setSpecPanel("item-1", work.NewSpecPanelModel("item-1"))
		return m
	}
	t.Run("ctrl+t (detail)", func(t *testing.T) {
		nm, _ := updateModel(t, terminalModel(), press('t', tea.ModCtrl))
		if nm.terminalMode {
			t.Error("ctrl+t should switch back to detail view")
		}
	})
	t.Run("Ctrl+c (terminate)", func(t *testing.T) {
		_, cmd := updateModel(t, terminalModel(), press('c', tea.ModCtrl))
		if cmd == nil {
			t.Fatal("ctrl+c should dispatch a terminate command")
		}
		msg := cmd()
		tm, ok := msg.(work.TerminalTerminateMsg)
		if !ok {
			t.Fatalf("ctrl+c produced %T, want work.TerminalTerminateMsg", msg)
		}
		if tm.Slug != "item-1" {
			t.Errorf("terminate slug = %q, want item-1", tm.Slug)
		}
	})
	t.Run("Esc (forwarded to subprocess, focus kept)", func(t *testing.T) {
		nm, _ := updateModel(t, terminalModel(), press(tea.KeyEscape))
		if nm.focusedPanel != panelRight || !nm.terminalMode {
			t.Error("a single Esc in terminal mode must stay focused on the terminal (forwarded to the PTY)")
		}
	})
}

// followupContractModel builds a stateFollowUps model with two open items.
func followupContractModel() model {
	items := []followup.FollowUpItem{
		{ID: "fu-1", Title: "FU One", Status: "open"},
		{ID: "fu-2", Title: "FU Two", Status: "open"},
	}
	return minimalModel(stateFollowUps, nil, items)
}

// TestFollowupListStatusBarKeybindContract verifies the stateFollowUps
// panelLeft hint set: "j/k navigate · Enter detail · A dismiss · D delete ·
// w work list · Esc exit · ? help" plus the "ctrl+a open · closed" border
// annotation.
func TestFollowupListStatusBarKeybindContract(t *testing.T) {
	t.Run("j/k (navigate)", func(t *testing.T) {
		m := followupContractModel()
		nm, _ := updateModel(t, m, press('j'))
		if nm.followupList.CurrentID() != "fu-2" {
			t.Fatalf("j should move to fu-2, got %q", nm.followupList.CurrentID())
		}
		nm, _ = updateModel(t, nm, press('k'))
		if nm.followupList.CurrentID() != "fu-1" {
			t.Fatalf("k should move back to fu-1, got %q", nm.followupList.CurrentID())
		}
	})
	t.Run("Enter (detail)", func(t *testing.T) {
		m := followupContractModel()
		nm, cmd := updateModel(t, m, press(tea.KeyEnter))
		if cmd == nil {
			t.Fatal("Enter should emit a selection command")
		}
		msg := cmd()
		if _, ok := msg.(followup.FollowUpSelectedMsg); !ok {
			t.Fatalf("Enter produced %T, want followup.FollowUpSelectedMsg", msg)
		}
		nm, _ = updateModel(t, nm, msg)
		if nm.focusedPanel != panelRight {
			t.Error("selecting a follow-up should focus the detail panel")
		}
	})
	t.Run("A (dismiss)", func(t *testing.T) {
		nm, _ := updateModel(t, followupContractModel(), press('A'))
		if nm.confirmAction != "dismiss" {
			t.Errorf("A should open the dismiss confirm modal, got %q", nm.confirmAction)
		}
	})
	t.Run("D (delete)", func(t *testing.T) {
		nm, _ := updateModel(t, followupContractModel(), press('D'))
		if nm.confirmAction != "delete_followup" {
			t.Errorf("D should open the delete confirm modal, got %q", nm.confirmAction)
		}
	})
	t.Run("w (work list)", func(t *testing.T) {
		nm, _ := updateModel(t, followupContractModel(), press('w'))
		if nm.state != stateWork {
			t.Error("w should return to the work list")
		}
	})
	t.Run("Esc (exit)", func(t *testing.T) {
		m := followupContractModel()
		nm, cmd := updateModel(t, m, press(tea.KeyEscape))
		if cmd == nil {
			t.Fatal("Esc should emit the list-dismissed command")
		}
		msg := cmd()
		if _, ok := msg.(followup.ListDismissedMsg); !ok {
			t.Fatalf("Esc produced %T, want followup.ListDismissedMsg", msg)
		}
		nm, _ = updateModel(t, nm, msg)
		if nm.state != stateWork {
			t.Error("dismissing the list should return to the work view")
		}
	})
	t.Run("ctrl+a (open · closed)", func(t *testing.T) {
		m := followupContractModel()
		nm, _ := updateModel(t, m, press('a', tea.ModCtrl))
		if nm.followupList.GetFilterMode() != followup.FilterClosed {
			t.Error("ctrl+a should switch the follow-up list to the closed filter")
		}
	})
	t.Run("t (settlement)", func(t *testing.T) {
		nm, _ := updateModel(t, followupContractModel(), press('t'))
		if nm.state != stateSettlement {
			t.Error("t should switch to the settlement panel")
		}
	})
	t.Run("l (detail)", func(t *testing.T) {
		nm, _ := updateModel(t, followupContractModel(), press('l'))
		if nm.focusedPanel != panelRight {
			t.Error("l should focus the detail panel (parity with tab)")
		}
	})
}

// TestFollowupDetailStatusBarKeybindContract verifies the stateFollowUps
// panelRight (detail) hint set: "p promote · d dismiss · c chat ·
// h/Esc back to list".
func TestFollowupDetailStatusBarKeybindContract(t *testing.T) {
	detailModel := func(t *testing.T) model {
		t.Helper()
		m := followupContractModel()
		m.focusedPanel = panelRight
		detail := &followup.FollowUpDetail{ID: "fu-1", Title: "FU One", Status: "open"}
		_ = m.followupDetail.SetID("fu-1")
		fd, _ := m.followupDetail.Update(followup.DetailLoadedMsg{ID: "fu-1", Detail: detail})
		m.followupDetail = fd
		return m
	}
	t.Run("p (promote)", func(t *testing.T) {
		_, cmd := updateModel(t, detailModel(t), press('p'))
		if cmd == nil {
			t.Fatal("p should emit a promote request")
		}
		if msg := cmd(); func() bool { _, ok := msg.(followup.PromoteRequestMsg); return !ok }() {
			t.Fatalf("p produced wrong message type")
		}
	})
	t.Run("d (dismiss)", func(t *testing.T) {
		_, cmd := updateModel(t, detailModel(t), press('d'))
		if cmd == nil {
			t.Fatal("d should emit a dismiss request")
		}
		if _, ok := cmd().(followup.DismissRequestMsg); !ok {
			t.Fatal("d produced wrong message type")
		}
	})
	t.Run("c (chat)", func(t *testing.T) {
		m := detailModel(t)
		nm, cmd := updateModel(t, m, press('c'))
		if cmd == nil {
			t.Fatal("c should emit a chat request")
		}
		msg := cmd()
		if _, ok := msg.(followup.FollowupChatRequestMsg); !ok {
			t.Fatalf("c produced %T, want followup.FollowupChatRequestMsg", msg)
		}
		nm, _ = updateModel(t, nm, msg)
		if !nm.sessionConfirmActive || !nm.sessionConfirmChatMode {
			t.Error("chat request should open the confirm modal in chat mode")
		}
	})
	t.Run("h (back to list)", func(t *testing.T) {
		nm, _ := updateModel(t, detailModel(t), press('h'))
		if nm.focusedPanel != panelLeft {
			t.Error("h should refocus the list panel")
		}
	})
	t.Run("Esc (back to list)", func(t *testing.T) {
		nm, _ := updateModel(t, detailModel(t), press(tea.KeyEscape))
		if nm.focusedPanel != panelLeft {
			t.Error("Esc should refocus the list panel")
		}
	})
}

// settlementContractModel builds a stateSettlement model with two queue items.
func settlementContractModel(t *testing.T) model {
	t.Helper()
	m := minimalModel(stateSettlement, nil, nil)
	m.width = 120
	m.height = 40
	st, err := settlement.ParseStatus([]byte(`{
		"enabled": true,
		"queue": {"pending": 2, "total": 2},
		"items": [
			{"id": "claim-aaa", "claim_id": "claim-aaa", "status": "pending", "work_item": "wi", "claim": "first claim text"},
			{"id": "claim-bbb", "claim_id": "claim-bbb", "status": "pending", "work_item": "wi", "claim": "second claim text"}
		],
		"harness": {"mode": "random", "selected": "claude-code", "concurrency": 1}
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	m.settlement = m.settlement.ReplaceStatus(st).SetSize(110, 30)
	return m
}

// TestSettlementStatusBarKeybindContract verifies the stateSettlement
// panelLeft hint set: "j/k queue · p process once · e enable/disable ·
// l settings · w work · f follow-ups · ? help" (p/e command dispatch is
// pinned by TestSettlementActionKeybindsReturnCommands).
func TestSettlementStatusBarKeybindContract(t *testing.T) {
	t.Run("j/k (queue)", func(t *testing.T) {
		m := settlementContractModel(t)
		if !strings.Contains(stripANSI(m.settlement.View()), "> [pending] first claim text") {
			t.Fatalf("precondition: cursor should start on the first queue item:\n%s", stripANSI(m.settlement.View()))
		}
		nm, _ := updateModel(t, m, press('j'))
		if !strings.Contains(stripANSI(nm.settlement.View()), "> [pending] second claim text") {
			t.Fatalf("j should move the queue cursor to the second item:\n%s", stripANSI(nm.settlement.View()))
		}
		nm, _ = updateModel(t, nm, press('k'))
		if !strings.Contains(stripANSI(nm.settlement.View()), "> [pending] first claim text") {
			t.Error("k should move the queue cursor back to the first item")
		}
	})
	t.Run("l (settings)", func(t *testing.T) {
		nm, _ := updateModel(t, settlementContractModel(t), press('l'))
		if nm.focusedPanel != panelRight {
			t.Error("l should focus the inline settings side")
		}
	})
	t.Run("w (work)", func(t *testing.T) {
		nm, cmd := updateModel(t, settlementContractModel(t), press('w'))
		if nm.state != stateWork {
			t.Error("w should return to the work view")
		}
		if cmd == nil {
			t.Error("w should reload work items")
		}
	})
	t.Run("f (follow-ups)", func(t *testing.T) {
		nm, _ := updateModel(t, settlementContractModel(t), press('f'))
		if nm.state != stateFollowUps {
			t.Error("f should switch to the follow-ups view")
		}
	})
	t.Run("? (help)", func(t *testing.T) {
		nm, _ := updateModel(t, settlementContractModel(t), press('?'))
		if !nm.showHelp {
			t.Error("? should open the help modal")
		}
	})
}

// TestSettlementBorderAnnotationAdvertisesJK verifies the settlement panel
// title annotation shows "j/k queue" with the status side focused and
// "j/k settings" with the settings side focused (third hint surface beside
// the status bar and the help modal).
func TestSettlementBorderAnnotationAdvertisesJK(t *testing.T) {
	m := settlementContractModel(t)
	out := stripANSI(m.viewSettlement())
	if !strings.Contains(out, "j/k  queue") {
		t.Errorf("panelLeft border annotation should advertise j/k queue:\n%s", out)
	}
	m.focusedPanel = panelRight
	out = stripANSI(m.viewSettlement())
	if !strings.Contains(out, "j/k  settings") {
		t.Errorf("panelRight border annotation should advertise j/k settings:\n%s", out)
	}
}

// TestTabIndicatorAdvertisesSectionKeys verifies the tab row prefixes every
// inactive section with its switch key (w / f / t) and shows no key on the
// active section. Key dispatch is pinned by the status-bar contract tests;
// this pins the display side of the three-surface sync.
func TestTabIndicatorAdvertisesSectionKeys(t *testing.T) {
	cases := []struct {
		name    string
		state   appState
		want    []string
		notWant []string
	}{
		{"work", stateWork, []string{"work (1)", "f follow-ups (2)", "t settlement (3)"}, []string{"w work"}},
		{"followups", stateFollowUps, []string{"w work (1)", "t settlement (3)"}, []string{"f follow-ups"}},
		{"settlement", stateSettlement, []string{"w work (1)", "f follow-ups (2)"}, []string{"t settlement"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := stripANSI(renderTabIndicator(tc.state, 1, 2, 3, 80))
			for _, want := range tc.want {
				if !strings.Contains(out, want) {
					t.Errorf("tab indicator missing %q:\n%s", want, out)
				}
			}
			for _, notWant := range tc.notWant {
				if strings.Contains(out, notWant) {
					t.Errorf("active section must not advertise a switch key %q:\n%s", notWant, out)
				}
			}
		})
	}
}

// TestRoundedBordersEverywhere verifies every docked panel and nested modal
// input renders the one rounded DockBorder shape — no hand-drawn square
// corners remain in any compositor output.
func TestRoundedBordersEverywhere(t *testing.T) {
	assertRounded := func(t *testing.T, out string) {
		t.Helper()
		for _, corner := range []string{"╭", "╮", "╰", "╯"} {
			if !strings.Contains(out, corner) {
				t.Errorf("output missing rounded corner %q", corner)
			}
		}
		for _, corner := range []string{"┌", "┐", "└", "┘"} {
			if strings.Contains(out, corner) {
				t.Errorf("output still contains square corner %q:\n%s", corner, out)
			}
		}
	}
	t.Run("work side-by-side", func(t *testing.T) {
		assertRounded(t, stripANSI(workContractModel().viewContent()))
	})
	t.Run("work top-bottom", func(t *testing.T) {
		m := workContractModel()
		m.layoutMode = config.LayoutTopBottom
		assertRounded(t, stripANSI(m.viewContent()))
	})
	t.Run("settlement", func(t *testing.T) {
		assertRounded(t, stripANSI(settlementContractModel(t).viewSettlement()))
	})
	t.Run("spec confirm modal nested input", func(t *testing.T) {
		assertRounded(t, stripANSI(specConfirmModel().renderSpecConfirmModal()))
	})
	t.Run("ai modal nested input", func(t *testing.T) {
		m := minimalModel(stateWork, nil, nil)
		m.width = 100
		m.height = 40
		m.aiInput = newModalTextarea()
		m.aiInputActive = true
		assertRounded(t, stripANSI(m.renderAIModal()))
	})
	t.Run("help modal", func(t *testing.T) {
		m := minimalModel(stateWork, nil, nil)
		m.width = 120
		m.height = 50
		m.showHelp = true
		m.sizeHelpViewport()
		assertRounded(t, stripANSI(m.renderHelpModal()))
	})
}

// TestSettlementSelectedClaimBlockFollowsCursor pins the compact selected-claim
// block: bounded (heading + ≤4 lines), follows j/k, omitted when empty.
func TestSettlementSelectedClaimBlockFollowsCursor(t *testing.T) {
	m := settlementContractModel(t)
	view := stripANSI(m.settlement.View())
	if !strings.Contains(view, "Selected claim") {
		t.Fatalf("selected-claim block should render for the cursor item:\n%s", view)
	}
	if !strings.Contains(view, "- claim-aaa") {
		t.Fatalf("selected-claim block should show the first claim id:\n%s", view)
	}
	nm, _ := updateModel(t, m, press('j'))
	view = stripANSI(nm.settlement.View())
	if !strings.Contains(view, "- claim-bbb") {
		t.Fatalf("selected-claim block should follow the cursor to claim-bbb:\n%s", view)
	}

	// Bounded: between the "Selected claim" heading and the next section
	// heading there are at most 4 detail lines.
	lines := strings.Split(view, "\n")
	start := -1
	for i, l := range lines {
		if strings.Contains(l, "Selected claim") {
			start = i
			break
		}
	}
	if start < 0 {
		t.Fatal("missing Selected claim heading")
	}
	count := 0
	for _, l := range lines[start+1:] {
		if strings.Contains(l, "Recent verdicts") {
			break
		}
		count++
	}
	if count > 4 {
		t.Errorf("selected-claim block must stay within 4 lines, got %d:\n%s", count, view)
	}

	// Omitted when the queue is empty.
	empty := minimalModel(stateSettlement, nil, nil)
	st, err := settlement.ParseStatus([]byte(`{"enabled": true, "queue": {"total": 0}, "items": [], "harness": {"concurrency": 1}}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	empty.settlement = empty.settlement.ReplaceStatus(st).SetSize(110, 30)
	if strings.Contains(stripANSI(empty.settlement.View()), "Selected claim") {
		t.Error("selected-claim block must be omitted when nothing is selected")
	}
}

// TestSettlementSettingsKeybindContract verifies the stateSettlement
// panelRight hint set against the inline settings dispatch: "j/k settings ·
// Enter edit/commit · h status · S all settings", and pins the advertised
// Esc semantics verbatim: Esc forwards to an actively-editing editor first,
// else refocuses the status side.
func TestSettlementSettingsKeybindContract(t *testing.T) {
	rightModel := func(t *testing.T) model {
		t.Helper()
		setupFakeLoreData(t, `{"version": 1, "tui_launch_framework": "claude-code", "settlement": {"enabled": false}}`)
		m := settlementContractModel(t)
		m.focusedPanel = panelRight
		m.ensureSettlementSettingsPanel()
		if m.settlementSettingsPanel == nil {
			t.Fatal("expected inline settlement settings panel")
		}
		return m
	}
	t.Run("j/k (settings)", func(t *testing.T) {
		m := rightModel(t)
		before := m.settlementSettingsPanel.View()
		nm, _ := updateModel(t, m, press('j'))
		if nm.settlementSettingsPanel.View() == before {
			t.Error("j should move focus inside the inline settings panel")
		}
	})
	t.Run("Enter (edit/commit)", func(t *testing.T) {
		m := rightModel(t)
		// Install focus first so Enter lands on a widget.
		nm, _ := updateModel(t, m, press('j'))
		_, cmd := updateModel(t, nm, press(tea.KeyEnter))
		if cmd == nil {
			t.Error("Enter should reach the inline settings panel and refresh settlement status")
		}
	})
	t.Run("h (status)", func(t *testing.T) {
		nm, _ := updateModel(t, rightModel(t), press('h'))
		if nm.focusedPanel != panelLeft {
			t.Error("h should refocus the status side")
		}
	})
	t.Run("S (all settings)", func(t *testing.T) {
		nm, _ := updateModel(t, rightModel(t), press('S'))
		if !nm.settingsActive {
			t.Error("S should open the full settings configurator")
		}
	})
	t.Run("Esc (refocuses status side when not editing)", func(t *testing.T) {
		m := rightModel(t)
		if m.settlementSettingsPanel.FocusConsumesRunes() {
			t.Fatal("precondition: panel should not start in an editing state")
		}
		nm, _ := updateModel(t, m, press(tea.KeyEscape))
		if nm.focusedPanel != panelLeft {
			t.Error("Esc with no active editor should refocus the status side")
		}
	})
	t.Run("Esc (forwards to an actively-editing editor first)", func(t *testing.T) {
		m := rightModel(t)
		// Drive the panel into a leaf edit mode: walk rows pressing Enter
		// until the focused widget consumes runes (a string/number editor).
		for i := 0; i < 40 && !m.settlementSettingsPanel.FocusConsumesRunes(); i++ {
			key := press(tea.KeyEnter)
			if i%2 == 1 {
				key = press('j')
			}
			m, _ = updateModel(t, m, key)
			if m.focusedPanel != panelRight {
				// Defensive: stay on the settings side while walking.
				m.focusedPanel = panelRight
			}
		}
		if !m.settlementSettingsPanel.FocusConsumesRunes() {
			t.Fatal("could not drive the inline settings panel into an editing state")
		}
		nm, _ := updateModel(t, m, press(tea.KeyEscape))
		if nm.focusedPanel != panelRight {
			t.Error("Esc while an editor is active must forward to the editor, not refocus the status side")
		}
	})
}

// TestSettingsModalStatusBarKeybindContract verifies the settings-configurator
// status-bar hint set rendered while the modal is open ("j/k navigate ·
// Enter/Space commit · u unset · PgUp/PgDn scroll · Esc close") reaches the
// panel through the modal interception, plus the global quit escape hatches.
// Widget-level commit/unset semantics are pinned by the internal/settings
// package tests.
func TestSettingsModalStatusBarKeybindContract(t *testing.T) {
	settingsModel := func(t *testing.T) model {
		t.Helper()
		setupFakeLoreData(t, `{"version": 1, "tui_launch_framework": "claude-code"}`)
		m := workContractModel()
		nm, _ := updateModel(t, m, press('S'))
		if !nm.settingsActive || nm.settingsPanel == nil {
			t.Fatal("S should open the settings configurator")
		}
		return nm
	}
	t.Run("S / Ctrl+, (open)", func(t *testing.T) {
		_ = settingsModel(t) // S
		setupFakeLoreData(t, `{"version": 1}`)
		nm, _ := updateModel(t, workContractModel(), press(',', tea.ModCtrl))
		if !nm.settingsActive {
			t.Error("ctrl+, should open the settings configurator")
		}
	})
	t.Run("j/k (navigate)", func(t *testing.T) {
		m := settingsModel(t)
		before := m.settingsPanel.View()
		nm, _ := updateModel(t, m, press('j'))
		if !nm.settingsActive {
			t.Fatal("j must not close the modal")
		}
		if nm.settingsPanel.View() == before {
			t.Error("j should move focus inside the settings panel")
		}
	})
	t.Run("PgDn (scroll)", func(t *testing.T) {
		m := settingsModel(t)
		nm, _ := updateModel(t, m, press(tea.KeyPgDown))
		if !nm.settingsActive {
			t.Error("PgDn must scroll, not close the modal")
		}
	})
	t.Run("Esc (close)", func(t *testing.T) {
		m := settingsModel(t)
		nm, _ := updateModel(t, m, press(tea.KeyEscape))
		if nm.settingsActive {
			t.Error("Esc should close the settings configurator")
		}
	})
	t.Run("q (quit when not editing)", func(t *testing.T) {
		m := settingsModel(t)
		_, cmd := updateModel(t, m, press('q'))
		if cmd == nil {
			t.Fatal("q should quit while no text widget is focused")
		}
		if _, ok := cmd().(tea.QuitMsg); !ok {
			t.Error("q should dispatch tea.Quit")
		}
	})
	t.Run("ctrl+c / ctrl+d (quit)", func(t *testing.T) {
		for _, k := range []tea.KeyPressMsg{press('c', tea.ModCtrl), press('d', tea.ModCtrl)} {
			_, cmd := updateModel(t, settingsModel(t), k)
			if cmd == nil {
				t.Fatalf("%v should quit from the settings modal", k)
			}
			if _, ok := cmd().(tea.QuitMsg); !ok {
				t.Errorf("%v should dispatch tea.Quit", k)
			}
		}
	})
}

// TestOnboardingStatusBarKeybindContract verifies the onboarding hint set
// ("Enter initialize · q quit"); Enter dispatch is pinned by
// TestStateOnboardingEnterDispatchesInit.
func TestOnboardingStatusBarKeybindContract(t *testing.T) {
	t.Run("q (quit)", func(t *testing.T) {
		m := minimalModel(stateOnboarding, nil, nil)
		_, cmd := updateModel(t, m, press('q'))
		if cmd == nil {
			t.Fatal("q should quit from onboarding")
		}
		if _, ok := cmd().(tea.QuitMsg); !ok {
			t.Error("q should dispatch tea.Quit")
		}
	})
}

// TestKnowledgeGlobalKeybindContract verifies the help modal's Global rows
// from the knowledge browser: "q quit" (except while the search input owns
// letters) and "S settings configurator" (which must actually render).
// Tree navigation keys are pinned in internal/knowledge browser tests.
func TestKnowledgeGlobalKeybindContract(t *testing.T) {
	knowledgeModel := func() model {
		m := minimalModel(stateKnowledge, nil, nil)
		m.width = 120
		m.height = 40
		m.browser = knowledge.NewBrowserModel("")
		return m
	}
	t.Run("q (quit)", func(t *testing.T) {
		_, cmd := updateModel(t, knowledgeModel(), press('q'))
		if cmd == nil {
			t.Fatal("q should quit from the knowledge browser")
		}
		if _, ok := cmd().(tea.QuitMsg); !ok {
			t.Error("q should dispatch tea.Quit")
		}
	})
	t.Run("q (typed into active search, no quit)", func(t *testing.T) {
		m := knowledgeModel()
		nm, _ := updateModel(t, m, press('/'))
		if !nm.browser.SearchActive() {
			t.Fatal("/ should activate the browser search panel")
		}
		nm, cmd := updateModel(t, nm, press('q'))
		if !nm.browser.SearchActive() {
			t.Error("q while searching must stay in the search input")
		}
		if cmd != nil {
			if _, ok := cmd().(tea.QuitMsg); ok {
				t.Error("q while searching must not quit")
			}
		}
	})
	t.Run("S (settings configurator renders over browser)", func(t *testing.T) {
		setupFakeLoreData(t, `{"version": 1}`)
		nm, _ := updateModel(t, knowledgeModel(), press('S'))
		if !nm.settingsActive {
			t.Fatal("S should open the settings configurator from the knowledge browser")
		}
		out := stripANSI(nm.viewContent())
		if !strings.Contains(out, "Settings") {
			t.Error("settings modal opened from stateKnowledge must actually render")
		}
	})
}

// TestStatusBarAdvertisesLForDetailEntry pins the hint text the new l binding's
// contract tests are named after ("l (open)" / "l (detail)" above): the work
// and follow-up list status bars advertise l/Enter for detail entry.
func TestStatusBarAdvertisesLForDetailEntry(t *testing.T) {
	m := workContractModel()
	bar := stripANSI(m.renderStatusBar(m.width))
	if !strings.Contains(bar, "l/Enter open") {
		t.Errorf("work list status bar should advertise l/Enter open:\n%s", bar)
	}
	fm := followupContractModel()
	fm.width = 120
	bar = stripANSI(fm.renderStatusBar(fm.width))
	if !strings.Contains(bar, "l/Enter detail") {
		t.Errorf("follow-up list status bar should advertise l/Enter detail:\n%s", bar)
	}
}

// TestSettlementEditingStatusBarOmitsDeadHHint pins the settlement editing
// hint context: while an embedded editor consumes runes, h reaches neither
// the focus gate (which requires no consuming editor) nor the editor (the key
// falls through to a global switch with no settlement h case), so the status
// bar must not advertise it; Enter/Esc are the reachable keys.
func TestSettlementEditingStatusBarOmitsDeadHHint(t *testing.T) {
	m := newSettlementEmbedModel(t)
	m.width = 120
	bar := stripANSI(m.renderStatusBar(m.width))
	if !strings.Contains(bar, "h status") {
		t.Fatalf("idle embed should advertise h status:\n%s", bar)
	}
	m = driveSettlementEmbedIntoEditing(t, m)
	bar = stripANSI(m.renderStatusBar(m.width))
	if strings.Contains(bar, "h status") {
		t.Errorf("editing embed must not advertise the dead h key:\n%s", bar)
	}
	if !strings.Contains(bar, "Enter commit") || !strings.Contains(bar, "Esc cancel") {
		t.Errorf("editing embed should advertise Enter commit and Esc cancel:\n%s", bar)
	}
}

// TestHelpContentProjectsKeymapRegistry spot-checks the help modal against
// the registry's help-visible projection: every help section title renders in
// registry order, and help-only rows (work-list N) appear.
func TestHelpContentProjectsKeymapRegistry(t *testing.T) {
	out := stripANSI(helpContent())
	wants := []string{
		"Follow-Ups", "Triage Tab", "Comments Tab", "Follow-Up Detail",
		"Work List", "Work Detail", "Settlement", "Settlement Settings",
		"Knowledge Browser", "Spec Panel (terminal mode)", "Global",
		"l / Enter", "create work items with AI",
	}
	pos := -1
	for _, want := range wants {
		idx := strings.Index(out, want)
		if idx < 0 {
			t.Errorf("help content missing %q", want)
			continue
		}
		if want == "l / Enter" || want == "create work items with AI" {
			continue // row content, not ordered section titles
		}
		if idx < pos {
			t.Errorf("help section %q out of registry order", want)
		}
		pos = idx
	}
}
