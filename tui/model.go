package main

import (
	"context"
	"fmt"
	"image/color"
	"time"

	"charm.land/bubbles/v2/textarea"
	"charm.land/bubbles/v2/textinput"
	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/followup"
	"github.com/anticorrelator/lore/tui/internal/knowledge"
	"github.com/anticorrelator/lore/tui/internal/search"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/sessionview"
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
	stateSessions
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

	// sessionsList / sessionsDetail back the first-class sessions workspace
	// (stateSessions): a list keyed by session identity and a read-only card
	// for rows with no local panel to attach. sessionActivity is the running
	// journal-derived overlay (needs-input / close-pending) folded from
	// sessionsJournalCursor forward on each substrate refresh. sessionsCount /
	// sessionsNeedsInput feed the tab-indicator announcement and stay current
	// from any state because the poll refreshes them whenever an instance
	// identity is resolved.
	sessionsList          sessionview.ListModel
	sessionsDetail        sessionview.DetailModel
	sessionActivity       map[sessionview.ActivityKey]sessionview.Activity
	sessionsJournalCursor int64
	sessionsCount         int
	sessionsNeedsInput    int

	aiInputActive bool
	aiLoading     bool
	aiDots        int
	aiInput       textarea.Model
	aiCtx         context.Context
	aiCancel      context.CancelFunc

	// Assign-workstream prompt (the 'a' verb on the work list).
	// assignLabelIdx indexes assignLabels when ↑/↓ filled the input (-1 =
	// free text); assignNearMatch holds an existing label close to the typed
	// one, pending confirmation; assignErr keeps a failed `lore work set`
	// visible inside the prompt so a failure never reads as success.
	assignActive    bool
	assignSlug      string
	assignInput     textinput.Model
	assignLabels    []string
	assignLabelIdx  int
	assignNearMatch string
	assignErr       string

	// sessionPanels holds one SessionPanelModel per work item slug that has a
	// live (or just-completed) session — spec, implement, or chat. The panel for
	// the currently selected list item is shown in the right panel when present.
	// Keyed by slug alone (one panel per subject): a second launch of any type
	// attaches to the existing panel rather than replacing it.
	sessionPanels      map[string]work.SessionPanelModel
	terminalMode       bool
	terminalForeground color.Color
	terminalBackground color.Color

	// preferDetailView records, per work slug / follow-up ID, that the user
	// explicitly switched the right panel to the detail view (ctrl+t) while a
	// session exists, so navigating back to the item shows detail instead of
	// auto-showing the terminal. Absent key = auto-show. Kept on model rather
	// than the list models so index-reload rebuilds don't reset it.
	preferDetailView map[string]bool

	// sessionConfirmActive gates the launch-confirmation modal; the textarea
	// holds its optional context input. sessionConfirmDescriptor is the sole mode
	// carrier — request handlers build it, the modal's checkboxes toggle its
	// ShortMode/SkipConfirm, and Enter stamps ExtraContext and hands it to
	// spawnSession. This mirrors the descriptor the agent queue builds, so the
	// human and agent launch paths share one shape.
	sessionConfirmActive     bool
	sessionConfirmInput      textarea.Model
	sessionConfirmDescriptor work.SessionDescriptor
	sessionLaunchedFromModal bool

	// Session substrate (_sessions/): this instance's identity, the substrate
	// root, and the journal appender path. localSessions is the authoritative
	// set of sessions this instance owns (written into its registry row);
	// pendingSpawns holds a session's metadata between claim/confirm and the
	// SpecProcessStarted that promotes it into localSessions.
	instanceName       string
	sessionsDir        string
	eventScript        string
	spendScript        string
	instanceStartedISO string
	// buildSHA/buildTime are this instance's build vintage, resolved once at
	// startup and stamped onto its registry row (see resolveBuildIdentity).
	// buildTime is the orderable quantity min_vintage filtering compares against.
	buildSHA  string
	buildTime string
	// normalizedProjectDir is config.ProjectDir resolved to a physical absolute
	// path once at startup (config.NormalizeProjectDir). It is stamped onto the
	// registry row and snapshotted into queueTickCmd as the match key a request's
	// prefer_project_dir compares against; config.ProjectDir stays the spawn cwd.
	normalizedProjectDir string
	// tmuxEnabled is the D3 host-capability gate resolved once at startup: when
	// true, sessions are hosted in tmux (survive crash/restart, adoptable); when
	// false (tmux absent or LORE_TUI_TMUX=off), spawning/close/quit behave exactly
	// as the direct-PTY path and no adoption scan runs.
	tmuxEnabled   bool
	localSessions map[string]liveSession
	pendingSpawns map[string]liveSession
	// sessionIdle records, per local session slug, whether we have already
	// journaled it as idle (quiescent/needs_input). It is the transition-edge
	// guard for the needs_input/quiescent/resumed events: emit only when the
	// incoming needs-input state differs from what we last journaled.
	sessionIdle map[string]bool
	// sessionModalBlocked records the last successfully classified modal state
	// for each local session. The heartbeat emits modal_blocked only on an
	// unlatched→modal edge; a classified clear deletes the latch so a later entry
	// can emit again. Unclassifiable snapshots leave the latch unchanged.
	sessionModalBlocked map[string]bool
	// pendingClose holds slugs with a consumed close-request awaiting teardown,
	// keyed by slug. Each entry carries the consumed request's identity (request
	// id + reason) and its timing state; the exit ladder fires once the panel's
	// quiescence predicate reports idle. A slug is removed the moment its ladder is
	// dispatched (or its close resolves to a close_failed terminal), so each
	// consumed close-request produces exactly one terminal journal row.
	pendingClose map[string]pendingCloseState
	// pendingSend and pendingPeek hold send/peek request ids whose consume is in
	// flight, so a re-scan before the async delete lands does not double-process
	// the same request. Keyed by request id (unlike pendingClose, which is keyed
	// by slug): multiple send/peek requests can target one slug. An entry is
	// cleared when its consume Cmd reports back.
	pendingSend map[string]bool
	pendingPeek map[string]bool
	// pendingSendVerify holds gate-passing sends whose paste reached the composer
	// but whose outcome is not yet journaled: the `sent` row defers until a
	// post-inject observation confirms the composer submitted. Keyed by request id.
	// Each entry carries what advanceSendVerifications needs to re-observe, replay
	// the submit sequence once, and journal the terminal (sent or send_refused
	// reason=unsubmitted). An entry is added after a successful inject and removed
	// the moment its terminal is journaled, so each consumed send produces exactly
	// one outcome row.
	pendingSendVerify map[string]pendingSendState
	// sendVerifyGrace bounds how long a deferred send waits for an unclassifiable
	// screen to resolve before journaling send_refused reason=unsubmitted. Seam: a
	// zero value falls back to sendVerifyGraceDefault; tests inject a small value.
	sendVerifyGrace time.Duration
	// observeSendFn classifies a post-inject panel screen (submitted / still
	// pending / unobservable) for the deferred-outcome loop. A nil value reads the
	// live screen via observeSend; tests inject a scripted result to drive the
	// retry-once and deadline transitions without a real emulator.
	observeSendFn func(work.SessionPanelModel) sendObs
	// closeGrace is the per-rung wait the close ladder allows a harness process
	// to exit before escalating (graceful→SIGTERM→Kill); closePoll is how often
	// it re-checks liveness within that window. Both are seams: zero values fall
	// back to closeGraceDefault/closePollDefault, and tests inject small values
	// so the ladder never blocks on a real 5s wait.
	closeGrace time.Duration
	closePoll  time.Duration
	// closeTerminusGrace bounds how long a generating protocol-terminus close
	// waits for natural quiescence before refusing teardown; closeExplicitGrace
	// is the courtesy wait before an explicit close injects ESC. Zero values use
	// the production defaults; tests inject short bounds.
	closeTerminusGrace time.Duration
	closeExplicitGrace time.Duration
	// closeModalHold bounds how long advanceCloseLadders holds a close blocked by
	// an open interactive prompt (a permission/approval modal) before acting. It is
	// a seam: a zero value falls back to closeModalHoldDefault; tests inject a small
	// value so the modal-hold split is exercised without a 30s wait.
	closeModalHold time.Duration
	// closeModalRetryCheckpoints are the three delays after modalHold at which a
	// protocol-terminus close records bounded retry progress. Zero uses the
	// production 30s/60s/120s schedule; tests inject shorter checkpoints.
	closeModalRetryCheckpoints [3]time.Duration
	// observeCloseFn injects one already-classified close observation in tests. A
	// nil value reads at most one live ScreenSnapshot and routes it through
	// classifyScreen before the close state machine advances.
	observeCloseFn func(work.SessionPanelModel) closeObservation
	// observeModalFn injects one already-classified modal observation in tests.
	// A nil value reads one live ScreenSnapshot and routes it through the shared
	// classifyScreen matcher set on the Bubble Tea goroutine.
	observeModalFn func(work.SessionPanelModel) modalObservation

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

	settlementProcessInFlight bool
	// settlementProcessStartedAt is set when settlementProcessInFlight flips
	// true and cleared when it flips back. The failsafe in
	// settlementInFlightFailsafe (called from handleIndexPollTick) uses this
	// to detect a stuck flag — i.e. a subprocess goroutine that never
	// returned, despite the CommandContext timeout in commands.go — and
	// reset the flag so auto-process can resume. Zero value means not in flight.
	settlementProcessStartedAt time.Time

	// lastSettlementPoll is the wall-clock time of the most recent settlement
	// status poll dispatched from handleIndexPollTick. While the panel is
	// hidden the poll drops to a slow heartbeat gated on this timestamp so the
	// trigger pump and auto-process dispatch keep firing without spawning the
	// subprocess pair every tick. Zero value forces the first tick to poll.
	lastSettlementPoll time.Time

	// Confirm modal for archive/delete actions.
	confirmAction string // "archive", "unarchive", "delete", "post_review", etc.; empty = inactive
	confirmSlug   string
	confirmTitle  string
	confirmCount  int // used by post_review to capture SelectedCount at dispatch time
	// confirmSessionID carries the harness session_id for a "close_session"
	// confirm whose target is slugless (addressed by --session).
	confirmSessionID string

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
	// lastProjectDetailMtime baselines the project-home freshness poll, reset on
	// each project-header selection so a home's first stat is a clean baseline.
	lastProjectDetailMtime time.Time

	// lastFollowupIndexMtime is the mtime of _followup_index.json from the last poll.
	lastFollowupIndexMtime time.Time

	// lastFollowupDetailMtime is the mtime of the currently selected follow-up's detail file from the last poll.
	lastFollowupDetailMtime time.Time

	// flashErr holds a transient error message shown in the status bar.
	// It is cleared on the next key press.
	flashErr string

	// statusNotice is a transient operator-degradation notice rendered in amber.
	// Like flashErr, it clears on the next key press.
	statusNotice string

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
	sessionPanelFn  func() (work.SessionPanelModel, bool)
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
		sessionPanelFn: func() (work.SessionPanelModel, bool) { return m.currentSessionPanel() },
		listUpdate: func(lmsg tea.Msg) (tea.Cmd, string, string) {
			// Diff on the raw row ID (headers included) so a cursor rest on a
			// project header drives loadDetail; CurrentSlug() blanks headers.
			prevID := m.list.CurrentRowID()
			lm, cmd := m.list.Update(lmsg)
			m.list = lm
			return cmd, prevID, m.list.CurrentRowID()
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
		sessionPanelFn: func() (work.SessionPanelModel, bool) { return m.currentFollowupPanel() },
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
		currentSlug:    func() string { return "" },
		loadDetail:     func(string) tea.Cmd { return nil },
		sessionPanelFn: func() (work.SessionPanelModel, bool) { return work.SessionPanelModel{}, false },
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

// sessionsPanelCallbacks builds the split-pane callbacks for the sessions
// workspace. It clones the work/follow-ups shape: the left panel is the sessions
// list, the right panel routes by the current row's session key — a locally-
// hosted row's live SessionPanelModel (attach/scrollback) or, for an external or
// in-flight row, the read-only detail card. currentSlug returns the panel-map
// key only for a local row, so the terminal-routing and ctrl+t seams reach the
// right panel exactly as they do for work.
func (m *model) sessionsPanelCallbacks() panelCallbacks {
	return panelCallbacks{
		currentSlug: func() string {
			if row, ok := m.sessionsList.CurrentSession(); ok && row.Local {
				return row.PanelKey
			}
			return ""
		},
		loadDetail: func(rowID string) tea.Cmd {
			return m.loadSessionsDetail(rowID)
		},
		sessionPanelFn: func() (work.SessionPanelModel, bool) { return m.currentSessionsPanel() },
		listUpdate: func(lmsg tea.Msg) (tea.Cmd, string, string) {
			prev := m.sessionsList.CurrentKey()
			lm, cmd := m.sessionsList.Update(lmsg)
			m.sessionsList = lm
			return cmd, prev, m.sessionsList.CurrentKey()
		},
		detailUpdate: func(dmsg tea.Msg) tea.Cmd {
			m.sessionsDetail, _ = m.sessionsDetail.Update(dmsg)
			return nil
		},
		// The read-only card does no tab hit-testing, so no content-start offset.
		resize: func() tea.Cmd {
			listW, listH := m.listDims()
			m.sessionsList, _ = m.sessionsList.Update(tea.WindowSizeMsg{Width: listW, Height: listH})
			m.sessionsDetail, _ = m.sessionsDetail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
			return nil
		},
	}
}

// currentSessionsPanel returns the live panel for the sessions list's current
// row when that row is locally hosted, mirroring currentSessionPanel for the
// work list but routing by the row's own session key rather than a work-item
// slug — the reachability the sessions view exists to provide.
func (m model) currentSessionsPanel() (work.SessionPanelModel, bool) {
	if m.sessionPanels == nil {
		return work.SessionPanelModel{}, false
	}
	row, ok := m.sessionsList.CurrentSession()
	if !ok || !row.Local {
		return work.SessionPanelModel{}, false
	}
	panel, ok := m.sessionPanels[row.PanelKey]
	return panel, ok
}

// loadSessionsDetail points the read-only card at the row under the cursor and
// derives terminalMode: a locally-hosted row with a live panel shows the panel
// (unless the user toggled to detail via ctrl+t); every other row shows the card.
func (m *model) loadSessionsDetail(rowID string) tea.Cmd {
	row, ok := m.sessionsList.SessionByID(rowID)
	m.sessionsDetail.SetSession(row, ok)
	hasPanel := ok && row.Local && m.hasSessionPanel(row.PanelKey)
	m.terminalMode = hasPanel && !m.preferDetailView[row.PanelKey]
	return nil
}

// currentSessionPanel returns the spec panel for the currently selected work item, if any.
func (m model) currentSessionPanel() (work.SessionPanelModel, bool) {
	if m.sessionPanels == nil {
		return work.SessionPanelModel{}, false
	}
	slug := m.list.CurrentSlug()
	if slug == "" {
		return work.SessionPanelModel{}, false
	}
	panel, ok := m.sessionPanels[slug]
	return panel, ok
}

// currentFollowupPanel returns the spec panel for the currently selected follow-up item, if any.
func (m model) currentFollowupPanel() (work.SessionPanelModel, bool) {
	if m.sessionPanels == nil {
		return work.SessionPanelModel{}, false
	}
	id := m.followupDetail.CurrentID()
	if id == "" {
		return work.SessionPanelModel{}, false
	}
	panel, ok := m.sessionPanels[id]
	return panel, ok
}

// hasSessionPanel reports whether a spec panel exists for the given slug.
func (m model) hasSessionPanel(slug string) bool {
	_, ok := m.sessionPanels[slug]
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

// setSessionPanel stores or replaces the spec panel for the given slug.
func (m *model) setSessionPanel(slug string, panel work.SessionPanelModel) {
	if m.sessionPanels == nil {
		m.sessionPanels = make(map[string]work.SessionPanelModel)
	}
	if pair, ok := work.NewTerminalColorPair(m.terminalForeground, m.terminalBackground); ok {
		panel = panel.WithTerminalColorPair(pair)
	}
	m.sessionPanels[slug] = panel
}

func (m *model) applyTerminalColorPair() {
	pair, ok := work.NewTerminalColorPair(m.terminalForeground, m.terminalBackground)
	if !ok {
		return
	}
	for slug, panel := range m.sessionPanels {
		m.sessionPanels[slug] = panel.WithTerminalColorPair(pair)
	}
}

// cleanupAllSubprocesses cancels any running AI command, cleans up all spec
// panels, and settles this instance's registry/journal state. Call before
// quitting. Journal and registry teardown are best-effort and synchronous here —
// the program is about to exit, so any Cmd returned alongside tea.Quit would not
// run; a missed close is recovered by the registry's mtime TTL rather than left as
// queue debt.
//
// D8 (quit detaches and preserves tmux-hosted sessions): panel Cleanup closes the
// PTY and kills the panel's subprocess, which for a tmux session is the attach
// client — killing it detaches and leaves the harness pane running. So tmux-hosted
// sessions are NOT journaled `closed` and their registry row is left on disk as the
// recovery manifest for the next start to adopt. Direct-PTY sessions keep the old
// kill + `closed` + row-removal behavior. When any tmux session survives, the row
// is rewritten to list only the survivors so the direct-PTY sessions just closed
// are not re-adopted (and double-closed) on the next start.
func (m *model) cleanupAllSubprocesses() {
	if m.aiCancel != nil {
		m.aiCancel()
		m.aiCancel = nil
	}
	for slug, panel := range m.sessionPanels {
		m.sessionPanels[slug] = panel.Cleanup()
	}
	anyTmuxSurvives := false
	for slug, ls := range m.localSessions {
		if ls.tmuxName != "" {
			anyTmuxSurvives = true
			continue // detach-and-preserve: no closed row, keep it on the manifest
		}
		_ = session.AppendEvent(m.eventScript, m.config.KnowledgeDir, m.closedEventFor(slug, ls))
		delete(m.localSessions, slug) // drop from the row we may rewrite below
	}
	if m.instanceName == "" || m.sessionsDir == "" {
		return
	}
	if anyTmuxSurvives {
		_ = session.WriteInstance(m.sessionsDir, m.instanceRow())
	} else {
		_ = session.RemoveInstance(m.sessionsDir, m.instanceName)
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
	// sessionPanel is the active spec panel for the selected item (if any).
	sessionPanel work.SessionPanelModel
	// hasSessionPanel reports whether sessionPanel is valid.
	hasSessionPanel bool
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
	// sessionsCount / sessionsNeedsInput feed the sessions tab section: the live
	// count and whether any session awaits input (the needs-input marker).
	sessionsCount      int
	sessionsNeedsInput int
}

// buildPaneConfig constructs a paneConfig from the current model state.
// It switches on m.state and populates the config from the appropriate sub-models.
func (m model) buildPaneConfig() paneConfig {
	listItemCount := len(m.list.Items())
	fuItemCount := m.followupList.FollowUpCount()
	settlementCount := m.settlement.Count()

	switch m.state {
	case stateSessions:
		listTitle := style.TitleName.Render("Sessions")
		if n := m.sessionsList.Count(); n > 0 {
			listTitle += " " + style.TitleCount.Render(fmt.Sprintf("(%d)", n))
		}
		detailTitle := m.sessionsDetail.Title()
		sessionPanel, hasSessionPanel := m.currentSessionsPanel()
		return paneConfig{
			listView:           m.sessionsList.View(),
			detailView:         m.sessionsDetail.View(),
			sessionPanel:       sessionPanel,
			hasSessionPanel:    hasSessionPanel,
			listTitle:          listTitle,
			detailTitle:        detailTitle,
			state:              stateSessions,
			listItemCount:      listItemCount,
			fuItemCount:        fuItemCount,
			settlementCount:    settlementCount,
			sessionsCount:      m.sessionsCount,
			sessionsNeedsInput: m.sessionsNeedsInput,
		}
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

		sessionPanel, hasSessionPanel := m.currentFollowupPanel()
		return paneConfig{
			listView:           m.followupList.View(),
			detailView:         m.followupDetail.View(),
			sessionPanel:       sessionPanel,
			hasSessionPanel:    hasSessionPanel,
			listTitle:          listTitle,
			detailTitle:        detailTitle,
			filterAnnot:        filterAnnot,
			filterAnnotW:       filterAnnotW,
			state:              stateFollowUps,
			listItemCount:      listItemCount,
			fuItemCount:        fuItemCount,
			settlementCount:    settlementCount,
			sessionsCount:      m.sessionsCount,
			sessionsNeedsInput: m.sessionsNeedsInput,
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
		if m.detail.IsProject() {
			if t := m.detail.HeaderTitle(); t != "" {
				detailTitle = t
			}
		} else if d := m.detail.Detail(); d != nil {
			detailTitle = d.Title
		} else if slug := m.list.CurrentSlug(); slug != "" {
			detailTitle = slug
		}

		sessionPanel, hasSessionPanel := m.currentSessionPanel()
		return paneConfig{
			listView:           m.list.View(),
			detailView:         m.detail.View(),
			sessionPanel:       sessionPanel,
			hasSessionPanel:    hasSessionPanel,
			listTitle:          listTitle,
			detailTitle:        detailTitle,
			filterAnnot:        filterAnnot,
			filterAnnotW:       filterAnnotW,
			state:              stateWork,
			listItemCount:      listItemCount,
			fuItemCount:        fuItemCount,
			settlementCount:    settlementCount,
			sessionsCount:      m.sessionsCount,
			sessionsNeedsInput: m.sessionsNeedsInput,
		}
	}
}
