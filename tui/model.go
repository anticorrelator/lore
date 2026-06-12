package main

import (
	"context"
	"fmt"
	"time"

	"charm.land/bubbles/v2/textarea"
	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/followup"
	"github.com/anticorrelator/lore/tui/internal/knowledge"
	"github.com/anticorrelator/lore/tui/internal/search"
	"github.com/anticorrelator/lore/tui/internal/settings"
	"github.com/anticorrelator/lore/tui/internal/settlement"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// appState tracks which view is active.
type appState int

const (
	stateWork appState = iota
	stateKnowledge
	stateFollowUps
	stateSettlement
	stateOnboarding
	stateNoRepo
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

// listPanelHeight returns the height of the rendered list area in the current
// layout. The views reserve 1 line for the tab indicator above the top panel,
// so the list's scroll window must match rendered rows exactly or the cursor
// can advance past the last visible row.
func (m model) listPanelHeight() int {
	if m.layoutMode == config.LayoutTopBottom {
		h := m.topPanelHeight() - 1
		if h < 1 {
			h = 1
		}
		return h
	}
	h := m.innerHeight() - 1
	if h < 1 {
		h = 1
	}
	return h
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
	settlement     settlement.Model
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

	sessionConfirmActive       bool
	sessionConfirmSlug         string
	sessionConfirmTitle        string
	sessionConfirmInput        textarea.Model
	sessionConfirmShortMode    bool
	sessionConfirmSkipConfirm  bool
	sessionConfirmChatMode     bool
	sessionConfirmFollowupMode bool
	sessionConfirmFindingIndex int
	sessionLaunchedFromModal   bool

	showHelp bool
	// helpViewport scrolls the help modal's keybinding list when it exceeds
	// the terminal height. Rebuilt on each open; re-sized on WindowSizeMsg.
	helpViewport viewport.Model

	// settingsActive flips the configurator modal on top of the current
	// view. settingsPanel is the schema-driven sub-model that owns the
	// modal body (D2 body-vs-chrome split). settingsPriorFocus snapshots
	// the panel focus at modal-open time so Esc-close can restore it.
	settingsActive     bool
	settingsPanel      *settings.SettingsModel
	settingsPriorFocus panelFocus

	// settlementSettingsPanel is the schema-backed settlement subtree editor
	// embedded directly in the settlement view.
	settlementSettingsPanel   *settings.SettingsModel
	settlementProcessInFlight bool
	// settlementProcessStartedAt is set when settlementProcessInFlight flips
	// true and cleared when it flips back. The failsafe in
	// settlementInFlightFailsafe (called from handleIndexPollTick) uses this
	// to detect a stuck flag — i.e. a subprocess goroutine that never
	// returned, despite the CommandContext timeout in commands.go — and
	// reset the flag so auto-process can resume. Zero value means not in flight.
	settlementProcessStartedAt time.Time

	// Confirm modal for archive/delete actions.
	confirmAction string // "archive", "unarchive", "delete", "post_review", etc.; empty = inactive
	confirmSlug   string
	confirmTitle  string
	confirmCount  int // used by post_review to capture SelectedCount at dispatch time

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

	// lastFollowupDetailMtime is the mtime of the currently selected follow-up's detail file from the last poll.
	lastFollowupDetailMtime time.Time

	// flashErr holds a transient error message shown in the status bar.
	// It is cleared on the next key press.
	flashErr string

	// doctorBanner holds a one-line install-drift summary from
	// `lore doctor --quiet` (e.g. "lore doctor: 1 issue(s) detected — run
	// 'lore doctor' for details"). Populated asynchronously by runDoctor on
	// Init when doctor's exit code is non-zero; empty when clean or
	// throttled-no-rerun. Shown in the status bar with lower precedence
	// than flashErr and aiLoading. Persists until the next TUI launch
	// re-evaluates (no key press clears it — drift is a standing condition,
	// not a transient error).
	doctorBanner string

	// initLoading is true while the background initialization command is running
	// during the onboarding flow.
	initLoading bool
}

// panelCallbacks abstracts entity-specific operations for shared routing helpers.
// Callers build this via closures that capture *model so mutations are visible
// to the helper. setContentStart may be nil (followup path omits it).
type panelCallbacks struct {
	currentSlug     func() string
	loadDetail      func(id string) tea.Cmd
	specPanelFn     func() (work.SpecPanelModel, bool)
	listUpdate      func(msg tea.Msg) (tea.Cmd, string, string) // returns cmd, prevID, newID
	detailUpdate    func(msg tea.Msg) tea.Cmd
	setContentStart func() // nil for followup
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
}

// paneConfig carries all state-varying inputs the compositor functions need.
// buildPaneConfig() constructs one per render cycle; the compositor functions
// (viewSideBySide, viewTopBottom) consume it without touching m directly.
type paneConfig struct {
	// listView is the pre-rendered left/top panel (list of items).
	listView string
	// detailView is the pre-rendered right/bottom panel in non-terminal mode.
	detailView string
	// specPanel is the active spec panel for the selected item (if any).
	specPanel work.SpecPanelModel
	// hasSpecPanel reports whether specPanel is valid.
	hasSpecPanel bool
	// listTitle is the title shown in the list panel border (e.g. "Active (3)").
	listTitle string
	// detailTitle is the title shown in the detail panel border (e.g. item title or "Detail").
	detailTitle string
	// filterAnnot is the pre-rendered filter annotation string (may contain ANSI codes).
	filterAnnot string
	// filterAnnotW is the visual width of filterAnnot (ANSI-stripped character count).
	filterAnnotW int
	// state is the active appState, used by renderTabIndicator.
	state appState
	// listItemCount is the count passed to renderTabIndicator for the work tab.
	listItemCount int
	// fuItemCount is the count passed to renderTabIndicator for the follow-ups tab.
	fuItemCount int
	// settlementCount is the pending/ready count passed to renderTabIndicator.
	settlementCount int
}

// buildPaneConfig constructs a paneConfig from the current model state.
// It switches on m.state and populates the config from the appropriate sub-models.
func (m model) buildPaneConfig() paneConfig {
	tabActiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("252"))
	tabInactiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("238"))
	tabSepS := lipgloss.NewStyle().Foreground(lipgloss.Color("240"))

	listItemCount := len(m.list.Items())
	fuItemCount := m.followupList.FollowUpCount()
	settlementCount := m.settlement.Count()

	switch m.state {
	case stateFollowUps:
		modeLabel := "Open"
		if m.followupList.GetFilterMode() == followup.FilterClosed {
			modeLabel = "Closed"
		}
		listTitle := modeLabel
		if items := m.followupList.Items(); len(items) > 0 {
			listTitle = fmt.Sprintf("%s (%d)", modeLabel, len(items))
		}
		detailTitle := "Detail"
		if t := m.followupDetail.Title(); t != "" {
			detailTitle = t
		}

		var openTabS, closedTabS lipgloss.Style
		if m.followupList.GetFilterMode() == followup.FilterClosed {
			openTabS, closedTabS = tabInactiveS, tabActiveS
		} else {
			openTabS, closedTabS = tabActiveS, tabInactiveS
		}
		filterAnnot := tabSepS.Render("ctrl+a  ") + openTabS.Render("open") + tabSepS.Render(" · ") + closedTabS.Render("closed")
		filterAnnotW := 8 + 4 + 3 + 6 // "ctrl+a  " + "open" + " · " + "closed"

		specPanel, hasSpecPanel := m.currentFollowupPanel()
		return paneConfig{
			listView:        m.followupList.View(),
			detailView:      m.followupDetail.View(),
			specPanel:       specPanel,
			hasSpecPanel:    hasSpecPanel,
			listTitle:       listTitle,
			detailTitle:     detailTitle,
			filterAnnot:     filterAnnot,
			filterAnnotW:    filterAnnotW,
			state:           stateFollowUps,
			listItemCount:   listItemCount,
			fuItemCount:     fuItemCount,
			settlementCount: settlementCount,
		}
	default: // stateWork
		modeLabel := "Active"
		if m.list.GetFilterMode() == work.FilterArchived {
			modeLabel = "Archived"
		}
		listTitle := modeLabel
		if items := m.list.Items(); len(items) > 0 {
			listTitle = fmt.Sprintf("%s (%d)", modeLabel, len(items))
		}

		var activeTabS, archivedTabS lipgloss.Style
		if m.list.GetFilterMode() == work.FilterArchived {
			activeTabS, archivedTabS = tabInactiveS, tabActiveS
		} else {
			activeTabS, archivedTabS = tabActiveS, tabInactiveS
		}
		filterAnnot := tabSepS.Render("ctrl+a  ") + activeTabS.Render("active") + tabSepS.Render(" · ") + archivedTabS.Render("archived")
		filterAnnotW := 8 + 6 + 3 + 8 // "ctrl+a  " + "active" + " · " + "archived"

		detailTitle := "Detail"
		if d := m.detail.Detail(); d != nil {
			detailTitle = d.Title
		} else if slug := m.list.CurrentSlug(); slug != "" {
			detailTitle = slug
		}

		specPanel, hasSpecPanel := m.currentSpecPanel()
		return paneConfig{
			listView:        m.list.View(),
			detailView:      m.detail.View(),
			specPanel:       specPanel,
			hasSpecPanel:    hasSpecPanel,
			listTitle:       listTitle,
			detailTitle:     detailTitle,
			filterAnnot:     filterAnnot,
			filterAnnotW:    filterAnnotW,
			state:           stateWork,
			listItemCount:   listItemCount,
			fuItemCount:     fuItemCount,
			settlementCount: settlementCount,
		}
	}
}
