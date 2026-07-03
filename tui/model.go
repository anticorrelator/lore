package main

import (
	"context"
	"fmt"
	"time"

	"charm.land/bubbles/v2/textarea"
	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/followup"
	"github.com/anticorrelator/lore/tui/internal/knowledge"
	"github.com/anticorrelator/lore/tui/internal/search"
	"github.com/anticorrelator/lore/tui/internal/settings"
	"github.com/anticorrelator/lore/tui/internal/settlement"
	"github.com/anticorrelator/lore/tui/internal/style"
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

// listDims returns the width and height to pass to a list panel sub-model
// (work or followup) based on layoutMode.
func (m model) listDims() (int, int) {
	if m.layoutMode == config.LayoutTopBottom {
		return m.topPanelWidth(), m.listPanelHeight()
	}
	return leftPanelWidth, m.listPanelHeight()
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

// panelAt maps absolute terminal coordinates to the split-pane panel that
// renders there: the boundary column in left/right layout, the boundary row
// (top panel's bottom border inclusive) in top/bottom layout. Used for mouse
// click focus routing and pointer-positional wheel routing.
func (m model) panelAt(x, y int) panelFocus {
	if m.layoutMode == config.LayoutLeftRight {
		if x < leftPanelWidth+2 {
			return panelLeft
		}
		return panelRight
	}
	if y <= 1+m.topPanelHeight() {
		return panelLeft
	}
	return panelRight
}

// rightPanelWidth returns the inner content width for the right (or bottom) panel.
// In left/right mode: 1(╭) + leftPanelWidth + 1(╮) + 1(╭) + rightPanelWidth + 1(╮) = m.width
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

	// preferDetailView records, per work slug / follow-up ID, that the user
	// explicitly switched the right panel to the detail view (ctrl+t) while a
	// session exists, so navigating back to the item shows detail instead of
	// auto-showing the terminal. Absent key = auto-show. Kept on model rather
	// than the list models so index-reload rebuilds don't reset it.
	preferDetailView map[string]bool

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

// panelCallbacks abstracts entity-specific operations for the shared
// split-pane helpers (handlePanelRouting, routeFocusedPanel) and the sizing
// fan-out. Callers build this via closures that capture *model so mutations
// are visible to the helper.
type panelCallbacks struct {
	currentSlug     func() string
	loadDetail      func(id string) tea.Cmd
	specPanelFn     func() (work.SpecPanelModel, bool)
	listUpdate      func(msg tea.Msg) (tea.Cmd, string, string) // returns cmd, prevID, newID
	detailUpdate    func(msg tea.Msg) tea.Cmd
	setContentStart func()         // nil when the detail view does no mouse hit-testing
	focusClick      func(x, y int) // nil = focus by host panel geometry (layoutMode split)
	resize          func() tea.Cmd // re-apply current layout dimensions to the sub-models
}

// workPanelCallbacks builds the split-pane callbacks for the work list+detail
// workspace. The closures capture m so mutations land on the model value the
// caller returns.
func (m *model) workPanelCallbacks() panelCallbacks {
	return panelCallbacks{
		currentSlug: func() string { return m.list.CurrentSlug() },
		loadDetail: func(slug string) tea.Cmd {
			var cmd tea.Cmd
			*m, cmd = m.loadDetail(slug)
			return cmd
		},
		specPanelFn: func() (work.SpecPanelModel, bool) { return m.currentSpecPanel() },
		listUpdate: func(lmsg tea.Msg) (tea.Cmd, string, string) {
			prevSlug := m.list.CurrentSlug()
			lm, cmd := m.list.Update(lmsg)
			m.list = lm
			return cmd, prevSlug, m.list.CurrentSlug()
		},
		detailUpdate: func(dmsg tea.Msg) tea.Cmd {
			var cmd tea.Cmd
			m.detail, cmd = m.detail.Update(dmsg)
			return cmd
		},
		// Set absolute position so detail can hit-test tab bar clicks.
		// TopBottom rows: indicator(1) + top border(1) + list content
		// (topPanelHeight-1; one line of the panel budget goes to the
		// indicator) + top bottom-border(1) + bottom top-border(1) ⇒ detail
		// content starts at topPanelHeight+3.
		setContentStart: func() {
			if m.layoutMode == config.LayoutLeftRight {
				m.detail.SetContentStart(2, leftPanelWidth+5)
			} else {
				m.detail.SetContentStart(m.topPanelHeight()+3, 3)
			}
		},
		resize: func() tea.Cmd {
			listW, listH := m.listDims()
			lm, lcmd := m.list.Update(tea.WindowSizeMsg{Width: listW, Height: listH})
			m.list = lm
			var dcmd tea.Cmd
			m.detail, dcmd = m.detail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
			return batchCmd(lcmd, dcmd)
		},
	}
}

// followupPanelCallbacks builds the split-pane callbacks for the follow-up
// list+detail workspace.
func (m *model) followupPanelCallbacks() panelCallbacks {
	return panelCallbacks{
		currentSlug: func() string { return m.followupDetail.CurrentID() },
		loadDetail: func(id string) tea.Cmd {
			return m.loadFollowupDetail(id)
		},
		specPanelFn: func() (work.SpecPanelModel, bool) { return m.currentFollowupPanel() },
		listUpdate: func(lmsg tea.Msg) (tea.Cmd, string, string) {
			prevID := m.followupList.CurrentID()
			fl, cmd := m.followupList.Update(lmsg)
			m.followupList = fl
			return cmd, prevID, m.followupList.CurrentID()
		},
		detailUpdate: func(dmsg tea.Msg) tea.Cmd {
			var cmd tea.Cmd
			m.followupDetail, cmd = m.followupDetail.Update(dmsg)
			return cmd
		},
		// Set absolute position so detail can hit-test tab bar clicks.
		// Same TopBottom row arithmetic as workPanelCallbacks: detail
		// content starts at topPanelHeight+3 (one line of the top panel's
		// budget is spent on the workspace indicator).
		setContentStart: func() {
			if m.layoutMode == config.LayoutLeftRight {
				m.followupDetail.SetContentStart(2, leftPanelWidth+5)
			} else {
				m.followupDetail.SetContentStart(m.topPanelHeight()+3, 3)
			}
		},
		resize: func() tea.Cmd {
			listW, listH := m.listDims()
			fl, lcmd := m.followupList.Update(tea.WindowSizeMsg{Width: listW, Height: listH})
			m.followupList = fl
			fd, dcmd := m.followupDetail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
			m.followupDetail = fd
			return batchCmd(lcmd, dcmd)
		},
	}
}

// knowledgePanelCallbacks adapts the knowledge browser onto the split-pane
// seam for mouse routing and sizing only. The browser keeps its own focus
// and tree behavior: clicks hand focus to the browser (FocusRight is
// readiness-gated internally) and every message is delegated to
// browser.Update unchanged.
func (m *model) knowledgePanelCallbacks() panelCallbacks {
	browserUpdate := func(msg tea.Msg) tea.Cmd {
		bm, cmd := m.browser.Update(msg)
		m.browser = bm
		return cmd
	}
	return panelCallbacks{
		currentSlug: func() string { return "" },
		loadDetail:  func(string) tea.Cmd { return nil },
		specPanelFn: func() (work.SpecPanelModel, bool) { return work.SpecPanelModel{}, false },
		listUpdate: func(lmsg tea.Msg) (tea.Cmd, string, string) {
			return browserUpdate(lmsg), "", ""
		},
		detailUpdate: browserUpdate,
		// The browser renders a fixed-width tree on the left in every host
		// layout mode, so clicks split on the same x boundary as the
		// left/right layout.
		focusClick: func(x, _ int) {
			if x < leftPanelWidth+2 {
				m.browser.FocusLeft()
			} else {
				m.browser.FocusRight()
			}
		},
		resize: func() tea.Cmd {
			return browserUpdate(tea.WindowSizeMsg{Width: m.width, Height: m.height})
		},
	}
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

// setPreferDetail records (prefer=true) or clears (prefer=false) the user's
// choice to keep the right panel on the detail view for the given work slug
// or follow-up ID.
func (m *model) setPreferDetail(key string, prefer bool) {
	if key == "" {
		return
	}
	if !prefer {
		delete(m.preferDetailView, key)
		return
	}
	if m.preferDetailView == nil {
		m.preferDetailView = make(map[string]bool)
	}
	m.preferDetailView[key] = true
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
	// listTitle is the pre-rendered title shown in the list panel border
	// (e.g. "Active (3)" composed from the TitleName/TitleCount tokens; may
	// contain ANSI codes).
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
	listItemCount := len(m.list.Items())
	fuItemCount := m.followupList.FollowUpCount()
	settlementCount := m.settlement.Count()

	switch m.state {
	case stateFollowUps:
		modeLabel := "Open"
		if m.followupList.GetFilterMode() == followup.FilterClosed {
			modeLabel = "Closed"
		}
		listTitle := style.TitleName.Render(modeLabel)
		if items := m.followupList.Items(); len(items) > 0 {
			listTitle += " " + style.TitleCount.Render(fmt.Sprintf("(%d)", len(items)))
		}
		detailTitle := "Detail"
		if t := m.followupDetail.Title(); t != "" {
			detailTitle = t
		}

		filterSel := 0
		if m.followupList.GetFilterMode() == followup.FilterClosed {
			filterSel = 1
		}
		filterAnnot, filterAnnotW := annotFollowupFilter.render(filterSel)

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
		listTitle := style.TitleName.Render(modeLabel)
		if items := m.list.Items(); len(items) > 0 {
			listTitle += " " + style.TitleCount.Render(fmt.Sprintf("(%d)", len(items)))
		}

		filterSel := 0
		if m.list.GetFilterMode() == work.FilterArchived {
			filterSel = 1
		}
		filterAnnot, filterAnnotW := annotWorkFilter.render(filterSel)

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
