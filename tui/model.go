package main

import (
	"context"
	"os"
	"time"

	"github.com/charmbracelet/bubbles/textarea"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/followup"
	"github.com/anticorrelator/lore/tui/internal/knowledge"
	"github.com/anticorrelator/lore/tui/internal/search"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// appState tracks which view is active.
type appState int

const (
	stateWork appState = iota
	stateKnowledge
	stateFollowUps
)

// panelFocus tracks which panel has keyboard focus in split-pane mode.
type panelFocus int

const (
	panelLeft panelFocus = iota
	panelRight
)

// popupContext distinguishes which handler processes PopupSelectedMsg.
type popupContext int

const (
	contextList      popupContext = iota // list-context: jump to work item
	contextDetail                        // detail-context: jump within detail view
	contextFollowups                     // followup-list-context: jump to follow-up item
)

const leftPanelWidth = 40

// innerHeight returns the usable inner content height: terminal minus top/bottom borders, status bar, and top padding.
func (m model) innerHeight() int {
	h := m.height - 4
	if h < 1 {
		h = 1
	}
	return h
}

// topPanelHeight returns the height of the top panel in top/bottom layout (25% of innerHeight, min 5).
func (m model) topPanelHeight() int {
	h := m.innerHeight() * 25 / 100
	if h < 5 {
		h = 5
	}
	return h
}

// topPanelWidth returns the inner content width for panels in top/bottom layout.
func (m model) topPanelWidth() int {
	return m.width - 2
}

// detailPanelHeight returns the inner content height available for the detail panel,
// accounting for layout mode. In left/right mode the detail gets the full innerHeight;
// in top/bottom mode it gets the remaining space below the top panel and separator.
func (m model) detailPanelHeight() int {
	if m.layoutMode == config.LayoutTopBottom {
		return m.innerHeight() - m.topPanelHeight() - 1
	}
	return m.innerHeight()
}

// rightPanelWidth returns the inner content width for the right (or bottom) panel.
// In left/right mode: 1(┌) + leftPanelWidth + 1(┐) + 1(┌) + rightPanelWidth + 1(┐) = m.width
// In top/bottom mode: returns topPanelWidth() since both panels span full width.
func (m model) rightPanelWidth() int {
	if m.layoutMode == config.LayoutTopBottom {
		return m.topPanelWidth()
	}
	w := m.width - leftPanelWidth - 4
	if w < 20 {
		w = 20
	}
	return w
}

type model struct {
	state          appState
	prevState      appState // state to return to when leaving knowledge browser
	focusedPanel   panelFocus
	layoutMode     config.LayoutMode
	list           work.ListModel
	detail         work.DetailModel
	browser        knowledge.BrowserModel
	followupList   followup.ListModel
	followupDetail followup.DetailModel
	config         config.Config
	width          int
	height         int
	err            error
	detailCache    map[string]*work.WorkItemDetail

	aiInputActive bool
	aiLoading     bool
	aiDots        int
	aiInput       textarea.Model
	aiCtx         context.Context
	aiCancel      context.CancelFunc

	// specPanels holds one SpecPanelModel per work item slug that is currently
	// speccing (or has just completed). The spec panel for the currently
	// selected list item is shown in the right panel when present.
	specPanels   map[string]work.SpecPanelModel
	terminalMode bool

	specConfirmActive      bool
	specConfirmSlug        string
	specConfirmTitle       string
	specConfirmInput       textarea.Model
	specConfirmShortMode   bool
	specConfirmSkipConfirm bool
	specConfirmChatMode    bool
	specLaunchedFromModal  bool

	showHelp bool

	// Confirm modal for archive/delete actions.
	confirmAction string // "archive", "unarchive", or "delete"; empty = inactive
	confirmSlug   string
	confirmTitle  string

	kittyModeActive bool // true while kitty keyboard protocol is enabled

	popup          search.PopupModel
	popupActive    bool
	popupCtx       popupContext
	popupLastQuery string
	popupDebounce  int

	// indexPath is the absolute path to _index.json, used for mtime polling.
	indexPath       string
	lastIndexMtime  time.Time
	lastPlanMtime   time.Time
	lastDetailMtime time.Time

	// lastFollowupIndexMtime is the mtime of _followup_index.json from the last poll.
	lastFollowupIndexMtime time.Time

	// flashErr holds a transient error message shown in the status bar.
	// It is cleared on the next key press.
	flashErr string
}

// currentSpecPanel returns the spec panel for the currently selected work item, if any.
func (m model) currentSpecPanel() (work.SpecPanelModel, bool) {
	if m.specPanels == nil {
		return work.SpecPanelModel{}, false
	}
	slug := m.list.CurrentSlug()
	if slug == "" {
		return work.SpecPanelModel{}, false
	}
	panel, ok := m.specPanels[slug]
	return panel, ok
}

// currentFollowupPanel returns the spec panel for the currently selected follow-up item, if any.
func (m model) currentFollowupPanel() (work.SpecPanelModel, bool) {
	if m.specPanels == nil {
		return work.SpecPanelModel{}, false
	}
	id := m.followupDetail.CurrentID()
	if id == "" {
		return work.SpecPanelModel{}, false
	}
	panel, ok := m.specPanels[id]
	return panel, ok
}

// hasSpecPanel reports whether a spec panel exists for the given slug.
func (m model) hasSpecPanel(slug string) bool {
	_, ok := m.specPanels[slug]
	return ok
}

// setSpecPanel stores or replaces the spec panel for the given slug.
func (m *model) setSpecPanel(slug string, panel work.SpecPanelModel) {
	if m.specPanels == nil {
		m.specPanels = make(map[string]work.SpecPanelModel)
	}
	m.specPanels[slug] = panel
}

// cleanupAllSubprocesses cancels any running AI command, cleans up all spec
// panels, and clears session locks. Call before quitting.
func (m *model) cleanupAllSubprocesses() {
	if m.aiCancel != nil {
		m.aiCancel()
		m.aiCancel = nil
	}
	for slug, panel := range m.specPanels {
		m.specPanels[slug] = panel.Cleanup()
		work.ClearSession(m.config.WorkDir, slug) //nolint:errcheck
	}
	m.disableKittyKeyboard()
}

// enableKittyKeyboard writes the kitty keyboard protocol enable sequence (mode 1)
// to stdout. No-op if kitty mode is already active.
func (m *model) enableKittyKeyboard() {
	if m.kittyModeActive {
		return
	}
	os.Stdout.WriteString("\x1b[>1u") //nolint:errcheck
	m.kittyModeActive = true
}

// disableKittyKeyboard writes the kitty keyboard protocol pop sequence to stdout.
// No-op if kitty mode is not active.
func (m *model) disableKittyKeyboard() {
	if !m.kittyModeActive {
		return
	}
	os.Stdout.WriteString("\x1b[<u") //nolint:errcheck
	m.kittyModeActive = false
}
