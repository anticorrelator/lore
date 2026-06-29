package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime/debug"
	"strings"
	"time"

	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"github.com/creack/pty"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/followup"
	"github.com/anticorrelator/lore/tui/internal/knowledge"
	"github.com/anticorrelator/lore/tui/internal/search"
	"github.com/anticorrelator/lore/tui/internal/settlement"
	"github.com/anticorrelator/lore/tui/internal/work"
)

func compactErr(prefix string, err error) string {
	msg := fmt.Sprintf("%s: %v", prefix, err)
	msg = strings.TrimSpace(msg)
	if len(msg) > 100 {
		msg = msg[:100]
	}
	return msg
}

// handlePanelRouting handles shared mouse-focus routing and tab/l/esc/h/ctrl+t
// key handling for split-pane states. It mutates m in place and returns a
// command and a bool indicating whether the message was consumed. If consumed
// is false the caller must handle the message itself (route-to-active falls
// back to routeFocusedPanel). Entity-specific action keys (s, c, p, d, …) are
// NOT handled here.
func handlePanelRouting(m *model, msg tea.Msg, cb panelCallbacks) (tea.Cmd, bool) {
	switch msg := msg.(type) {
	case tea.MouseMsg:
		click, isClick := msg.(tea.MouseClickMsg)
		isClick = isClick && click.Button == tea.MouseLeft && !click.Mod.Contains(tea.ModShift)
		if isClick {
			switch {
			case cb.focusClick != nil:
				cb.focusClick(click.X, click.Y)
			case m.layoutMode == config.LayoutLeftRight:
				if click.X < leftPanelWidth+2 {
					m.focusedPanel = panelLeft
				} else {
					m.focusedPanel = panelRight
				}
			default:
				if click.Y <= 1+m.topPanelHeight() {
					m.focusedPanel = panelLeft
				} else {
					m.focusedPanel = panelRight
				}
			}
		}
		return routeFocusedPanel(m, msg, cb), true

	case tea.KeyPressMsg:
		switch msg.String() {
		case "esc", "h":
			// Back to list from the detail panel, as the "h/Esc back to
			// list" status-bar hint advertises. In terminal mode both fall
			// through to the spec panel: a single Esc is forwarded to the
			// PTY (so e.g. Claude Code's "esc to interrupt" works) and
			// emits TerminalDetachMsg only on a double-Esc gesture; h is
			// ordinary typed input there.
			if m.focusedPanel == panelRight && !m.terminalMode {
				m.focusedPanel = panelLeft
				return nil, true
			}
		case "ctrl+t":
			// Toggles the right panel between detail and terminal, like a
			// tab. Consumed here so it is never forwarded to the PTY.
			if m.focusedPanel == panelRight {
				if m.terminalMode {
					m.terminalMode = false
					return nil, true
				}
				if panel, ok := cb.specPanelFn(); ok && (panel.Ptmx() != nil || panel.IsDone()) {
					m.terminalMode = true
					return nil, true
				}
			}
		case "tab", "l":
			// Tab and l both move focus left→right, matching the settlement
			// and knowledge panels' h/l vocabulary. When on the right panel
			// neither is consumed: Tab falls through to the detail view so it
			// can cycle tabs; l is ordinary input there (and reaches the PTY
			// in terminal mode).
			if m.focusedPanel == panelLeft {
				m.focusedPanel = panelRight
				return nil, true
			}
		}
	}
	return nil, false
}

// routeFocusedPanel forwards msg to the focused panel's sub-model: the list
// (loading detail when the cursor lands on a new row — this diff is what
// drives detail load on filter toggles, which move the cursor without firing
// the list's onCursorChange hook), the spec panel in terminal mode, or the
// detail view.
func routeFocusedPanel(m *model, msg tea.Msg, cb panelCallbacks) tea.Cmd {
	if m.focusedPanel == panelLeft {
		cmd, prevID, newID := cb.listUpdate(msg)
		if newID != "" && newID != prevID {
			return tea.Batch(cmd, cb.loadDetail(newID))
		}
		return cmd
	}
	if m.terminalMode {
		id := cb.currentSlug()
		if m.specPanels != nil {
			if panel, ok := m.specPanels[id]; ok {
				sm, cmd := panel.Update(msg)
				m.specPanels[id] = sm
				return cmd
			}
		}
		// No panel for the current item — fall back to detail.
		m.terminalMode = false
	}
	if cb.setContentStart != nil {
		cb.setContentStart()
	}
	return cb.detailUpdate(msg)
}

func (m model) Init() tea.Cmd {
	if m.state == stateOnboarding || m.state == stateNoRepo {
		return nil
	}
	return tea.Batch(
		loadWorkItems(m.config.WorkDir),
		loadPRStatus(),
		loadSettlementStatus(),
		indexPollTick(),
		followup.LoadIndexCmd(m.config.KnowledgeDir),
		runDoctor(),
	)
}

func (m model) Update(msg tea.Msg) (_ tea.Model, _ tea.Cmd) {
	defer func() {
		if r := recover(); r != nil {
			crashLog := filepath.Join(os.TempDir(), "lore-tui-crash.log")
			stack := fmt.Sprintf("panic in Update(%T): %v\n\n%s", msg, r, debug.Stack())
			_ = os.WriteFile(crashLog, []byte(stack), 0644)
			panic(r)
		}
	}()

	// Help modal: intercept all keys; Esc or ? closes it, scroll keys move
	// the help viewport, everything else is swallowed.
	if m.showHelp {
		if km, ok := msg.(tea.KeyPressMsg); ok {
			switch km.String() {
			case "esc", "?":
				m.showHelp = false
			case "g":
				m.helpViewport.GotoTop()
			case "G":
				m.helpViewport.GotoBottom()
			case "j", "down", "k", "up", "pgup", "pgdown":
				var cmd tea.Cmd
				m.helpViewport, cmd = m.helpViewport.Update(msg)
				return m, cmd
			}
			return m, nil
		}
		// Non-key messages (e.g. window resize) fall through.
	}

	// Settings configurator modal: intercept all keys, route to sub-model.
	// Per D2 the sub-model owns navigation; the host only catches the
	// close signal it raises (Closed() flips true on top-level Esc with no
	// active draft). Per D10, drafts are discarded at modal close — the
	// next open rebuilds the panel from disk state below.
	if m.settingsActive && m.settingsPanel != nil {
		if km, ok := msg.(tea.KeyPressMsg); ok {
			// Global quit shortcuts must escape the modal so the TUI
			// behaves consistently with every other view (the main
			// key-block at line ~534 below). 'q' is letter input for
			// text-entry widgets, so we only quit when the focused
			// widget does not consume runes; ctrl+c / ctrl+d are
			// control codes that no widget claims, so they always quit.
			switch km.String() {
			case "ctrl+c", "ctrl+d":
				m.cleanupAllSubprocesses()
				return m, tea.Quit
			case "q":
				if !m.settingsPanel.FocusConsumesRunes() {
					m.cleanupAllSubprocesses()
					return m, tea.Quit
				}
			}
			panel, cmd := m.settingsPanel.Update(msg)
			m.settingsPanel = panel
			if m.settingsPanel.Closed() {
				m.settingsActive = false
				m.focusedPanel = m.settingsPriorFocus
				// Mark the panel for rebuild on next open. Keeping the
				// pointer alive lets any in-flight tea.Cmd (e.g. an
				// agent-toggle shell-out result) still find a target;
				// the rebuild on next open honors D10's discard rule.
				m.settingsPanel = nil
				m.settlementSettingsPanel = nil
				m.ensureSettlementSettingsPanel()
			}
			return m, cmd
		}
		// Non-key messages still route through the panel so async results
		// (agentToggleResultMsg from ToggleAgent) reach Update.
		panel, cmd := m.settingsPanel.Update(msg)
		m.settingsPanel = panel
		return m, cmd
	}

	// Confirm modal for archive/delete: intercept all keys.
	if m.confirmAction != "" {
		if km, ok := msg.(tea.KeyPressMsg); ok {
			switch km.String() {
			case "y", "enter":
				action := m.confirmAction
				slug := m.confirmSlug
				m.confirmAction = ""
				m.confirmSlug = ""
				m.confirmTitle = ""
				m.confirmCount = 0
				if action == "delete" {
					return m, runDelete(slug)
				}
				if action == "dismiss" {
					return m, runDismissFollowUp(slug)
				}
				if action == "delete_followup" {
					return m, runDeleteFollowUp(slug)
				}
				if action == "post_review" {
					return m, runPostReview(m.config.KnowledgeDir, slug)
				}
				return m, runArchive(slug, action == "unarchive")
			default:
				// Any other key cancels.
				m.confirmAction = ""
				m.confirmSlug = ""
				m.confirmTitle = ""
				m.confirmCount = 0
			}
			return m, nil
		}
	}

	// Spec confirm modal: intercept all keys before launching subprocess.
	if m.sessionConfirmActive {
		if km, ok := msg.(tea.KeyPressMsg); ok {
			switch km.String() {
			case "shift+enter", "alt+enter":
				m.sessionConfirmInput.InsertRune('\n')
				return m, nil
			case "enter":
				extraContext := strings.TrimSpace(m.sessionConfirmInput.Value())
				m.sessionConfirmActive = false
				slug := m.sessionConfirmSlug
				// Mark item as speccing in the list.
				m.list, _ = m.list.Update(work.SpecStatusMsg{Slug: slug})
				// Create spec panel sized to the panel slot it occupies (detailPanelHeight).
				specH := m.detailPanelHeight()
				specW := m.rightPanelWidth() - 2 // 1-char buffer on each side
				panel := work.NewSpecPanelModel(slug)
				panel, _ = panel.Update(tea.WindowSizeMsg{Width: specW, Height: specH})
				m.setSpecPanel(slug, panel)
				m.detail, _ = m.detail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
				m.sessionLaunchedFromModal = m.state == stateWork
				findingIndex := m.sessionConfirmFindingIndex
				m.sessionConfirmFindingIndex = -1
				return m, work.StartTerminalCmd(slug, m.sessionConfirmTitle, m.config.ProjectDir, specW, specH, extraContext, m.sessionConfirmShortMode, m.sessionConfirmChatMode, m.sessionConfirmSkipConfirm, m.sessionConfirmFollowupMode, m.config.KnowledgeDir, findingIndex)
			case "esc", "ctrl+c":
				m.sessionConfirmActive = false
				return m, nil
			case "alt+1":
				if !m.sessionConfirmChatMode {
					m.sessionConfirmShortMode = !m.sessionConfirmShortMode
				}
				return m, nil
			case "alt+2":
				if !m.sessionConfirmChatMode {
					m.sessionConfirmSkipConfirm = !m.sessionConfirmSkipConfirm
				}
				return m, nil
			default:
				var taCmd tea.Cmd
				m.sessionConfirmInput, taCmd = m.sessionConfirmInput.Update(msg)
				return m, taCmd
			}
		}
		// Non-key messages fall through.
	}

	// AI modal: intercept all keys when the input is active.
	if m.aiInputActive {
		if km, ok := msg.(tea.KeyPressMsg); ok {
			switch km.String() {
			case "shift+enter", "alt+enter":
				m.aiInput.InsertRune('\n')
				return m, nil
			case "enter":
				prompt := strings.TrimSpace(m.aiInput.Value())
				m.aiInputActive = false
				if prompt == "" {
					return m, nil
				}
				m.aiLoading = true
				m.aiDots = 0
				ctx, cancel := context.WithCancel(context.Background())
				m.aiCtx = ctx
				m.aiCancel = cancel
				return m, tea.Batch(runWorkAI(ctx, prompt), aiTick())
			case "esc", "ctrl+c":
				m.aiInputActive = false
				return m, nil
			default:
				var taCmd tea.Cmd
				m.aiInput, taCmd = m.aiInput.Update(msg)
				return m, taCmd
			}
		}
		// Non-key messages (window resize etc.) fall through to normal handling.
	}

	// Popup overlay: route all key messages to popup when active.
	if m.popupActive {
		if _, ok := msg.(tea.KeyPressMsg); ok {
			var cmd tea.Cmd
			m.popup, cmd = m.popup.Update(msg)

			// Debounced subprocess search when input changes.
			newQuery := m.popup.InputValue()
			if newQuery != m.popupLastQuery {
				m.popupLastQuery = newQuery
				m.popupDebounce++
				if len(newQuery) < 2 {
					// Short query: revert to full work item list.
					m.popup.SetItems(buildWorkItemPopupItems(m.list.Items()))
				} else {
					id := m.popupDebounce
					q := newQuery
					searchCmd := tea.Tick(200*time.Millisecond, func(time.Time) tea.Msg {
						_ = id
						return runPopupSearch(q)
					})
					return m, tea.Batch(cmd, searchCmd)
				}
			}

			return m, cmd
		}
		// Non-key messages (PopupDismissedMsg, PopupSelectedMsg, resize) fall through.
	}

	switch msg := msg.(type) {
	case initFinishedMsg:
		m.initLoading = false
		if msg.Err != nil {
			m.flashErr = fmt.Sprintf("init failed: %v", msg.Err)
			return m, nil
		}
		m.state = stateWork
		return m, tea.Batch(
			loadWorkItems(m.config.WorkDir),
			loadPRStatus(),
			loadSettlementStatus(),
			indexPollTick(),
		)

	case workAIFinishedMsg:
		m.aiLoading = false
		m.aiCancel = nil
		if msg.Err != nil {
			errStr := fmt.Sprintf("ai failed: %v", msg.Err)
			if len(errStr) > 80 {
				errStr = errStr[:80]
			}
			m.flashErr = errStr
		} else if msg.Output != "" {
			// Surface the last non-empty line (e.g. "Created: ...") as a brief status.
			lines := strings.Split(strings.TrimSpace(msg.Output), "\n")
			last := ""
			for i := len(lines) - 1; i >= 0; i-- {
				if strings.TrimSpace(lines[i]) != "" {
					last = strings.TrimSpace(lines[i])
					break
				}
			}
			if last != "" {
				if len(last) > 80 {
					last = last[:80]
				}
				m.flashErr = last
			}
		}
		// Reload the work item list to pick up newly created items.
		return m, loadWorkItems(m.config.WorkDir)

	case work.ArchiveRequestMsg:
		return m, runArchive(msg.Slug, msg.Unarchive)

	case work.ArchiveFinishedMsg:
		if msg.Err != nil {
			m.flashErr = fmt.Sprintf("archive failed: %v", msg.Err)
		}
		return m, loadWorkItems(m.config.WorkDir)

	case work.DeleteRequestMsg:
		return m, runDelete(msg.Slug)

	case work.DeleteFinishedMsg:
		if msg.Err != nil {
			m.flashErr = fmt.Sprintf("delete failed: %v", msg.Err)
		}
		return m, loadWorkItems(m.config.WorkDir)

	case aiTickMsg:
		if m.aiLoading {
			m.aiDots = (m.aiDots + 1) % 4
			return m, aiTick()
		}

	case indexPollTickMsg:
		return m.handleIndexPollTick()

	case indexMtimeCheckedMsg:
		return m.handleIndexMtimeChecked(msg)

	case followupIndexMtimeCheckedMsg:
		return m.handleFollowupIndexMtimeChecked(msg)

	case activeSessionsCheckedMsg:
		return m.handleActiveSessionsChecked(msg)

	case planMtimeCheckedMsg:
		return m.handlePlanMtimeChecked(msg)

	case planContentReadMsg:
		return m.handlePlanContentRead(msg)

	case detailMtimeCheckedMsg:
		return m.handleDetailMtimeChecked(msg)

	case followupDetailMtimeCheckedMsg:
		return m.handleFollowupDetailMtimeChecked(msg)

	case tea.KeyPressMsg:
		// Clear any transient flash error on the next key press.
		m.flashErr = ""

		// No-repo state: only accept q, ctrl+c, ctrl+d (quit).
		if m.state == stateNoRepo {
			switch msg.String() {
			case "q", "ctrl+c", "ctrl+d":
				return m, tea.Quit
			default:
				return m, nil
			}
		}

		// Onboarding state: only accept Enter (init), q, ctrl+c, ctrl+d (quit).
		if m.state == stateOnboarding {
			switch msg.String() {
			case "enter":
				if !m.initLoading {
					m.initLoading = true
					return m, runInit(m.config.ProjectDir)
				}
				return m, nil
			case "q", "ctrl+c", "ctrl+d":
				return m, tea.Quit
			default:
				return m, nil
			}
		}

		// Edit-mode guard: when the follow-up detail has an active inline textarea,
		// skip all global shortcuts (except ctrl+c and ctrl+d) and route directly
		// to the detail model so every keystroke reaches the textarea.
		if m.state == stateFollowUps && m.followupDetail.IsEditing() {
			key := msg.String()
			if key != "ctrl+c" && key != "ctrl+d" {
				var cmd tea.Cmd
				m.followupDetail, cmd = m.followupDetail.Update(msg)
				return m, cmd
			}
		}

		if m.state == stateSettlement && !m.terminalMode {
			key := msg.String()
			if m.focusedPanel == panelLeft && (key == "l" || key == "tab") {
				m.ensureSettlementSettingsPanel()
				m.focusedPanel = panelRight
				return m, nil
			}
			if m.focusedPanel == panelRight {
				m.ensureSettlementSettingsPanel()
				consumesRunes := m.settlementSettingsPanel != nil && m.settlementSettingsPanel.FocusConsumesRunes()
				switch key {
				case "esc":
					if consumesRunes {
						return m.updateInlineSettlementSettings(msg)
					}
					m.focusedPanel = panelLeft
					return m, nil
				case "h":
					if !consumesRunes {
						m.focusedPanel = panelLeft
						return m, nil
					}
				case "q", "?", "K", "S", "ctrl+,":
					if !consumesRunes {
						break
					}
					return m.updateInlineSettlementSettings(msg)
				case "ctrl+c", "ctrl+d":
					break
				default:
					return m.updateInlineSettlementSettings(msg)
				}
			}
		}

		switch msg.String() {
		case "t":
			if (m.state == stateWork || m.state == stateFollowUps) && !(m.terminalMode && m.focusedPanel == panelRight) {
				m.state = stateSettlement
				m.terminalMode = false
				m.focusedPanel = panelLeft
				m.ensureSettlementSettingsPanel()
				return m, loadSettlementStatus()
			}
		case "ctrl+c":
			// In terminal mode, ctrl+c terminates the terminal panel only,
			// but still cancel any background AI subprocess.
			if m.terminalMode && (m.state == stateWork || m.state == stateFollowUps) {
				if m.aiCancel != nil {
					m.aiCancel()
					m.aiCancel = nil
				}
				var slug string
				if m.state == stateFollowUps {
					slug = m.followupDetail.CurrentID()
				} else {
					slug = m.list.CurrentSlug()
				}
				return m, func() tea.Msg { return work.TerminalTerminateMsg{Slug: slug} }
			}
			m.cleanupAllSubprocesses()
			return m, tea.Quit
		case "ctrl+d":
			m.cleanupAllSubprocesses()
			return m, tea.Quit
		case "?":
			if !m.terminalMode {
				m.showHelp = true
				m.helpViewport = viewport.New()
				m.sizeHelpViewport()
				return m, nil
			}
		case "q":
			if (m.state == stateWork || m.state == stateFollowUps || m.state == stateSettlement) && !m.terminalMode {
				m.cleanupAllSubprocesses()
				return m, tea.Quit
			}
			// Knowledge browser: q quits as the help modal's Global section
			// advertises, except while the search input owns letter keys.
			if m.state == stateKnowledge && !m.browser.SearchActive() {
				m.cleanupAllSubprocesses()
				return m, tea.Quit
			}
		case "A":
			// A opens dismiss confirmation modal for follow-ups (left panel only, dismissable statuses).
			if m.state == stateFollowUps && m.focusedPanel == panelLeft {
				if item, ok := m.followupList.CurrentItem(); ok {
					status := item.Status
					if status == "open" || status == "pending" || status == "reviewed" {
						title := item.Title
						if title == "" {
							title = item.ID
						}
						m.confirmAction = "dismiss"
						m.confirmSlug = item.ID
						m.confirmTitle = title
						return m, nil
					}
				}
			}
			// A opens archive/unarchive confirmation modal (left panel only).
			if m.state == stateWork && m.focusedPanel == panelLeft {
				if item, ok := m.list.CurrentItem(); ok {
					title := item.Title
					if title == "" {
						title = item.Slug
					}
					if item.Status == "archived" {
						m.confirmAction = "unarchive"
					} else {
						m.confirmAction = "archive"
					}
					m.confirmSlug = item.Slug
					m.confirmTitle = title
					return m, nil
				}
			}
		case "D":
			// D opens delete confirmation modal for follow-ups (left panel only).
			if m.state == stateFollowUps && m.focusedPanel == panelLeft {
				if item, ok := m.followupList.CurrentItem(); ok {
					title := item.Title
					if title == "" {
						title = item.ID
					}
					m.confirmAction = "delete_followup"
					m.confirmSlug = item.ID
					m.confirmTitle = title
					return m, nil
				}
			}
			// D opens delete confirmation modal (left panel only).
			if m.state == stateWork && m.focusedPanel == panelLeft {
				if item, ok := m.list.CurrentItem(); ok {
					title := item.Title
					if title == "" {
						title = item.Slug
					}
					m.confirmAction = "delete"
					m.confirmSlug = item.Slug
					m.confirmTitle = title
					return m, nil
				}
			}
		case "N":
			// N opens the AI work item prompt (left panel only).
			if m.state == stateWork && m.focusedPanel == panelLeft {
				ta := newModalTextarea()
				focusCmd := ta.Focus()
				m.aiInput = ta
				m.aiInputActive = true
				return m, focusCmd
			}
		case "L":
			// L toggles layout between left/right and top/bottom (left panel only).
			if (m.state == stateWork || m.state == stateFollowUps) && m.focusedPanel == panelLeft {
				if m.layoutMode == config.LayoutLeftRight {
					m.layoutMode = config.LayoutTopBottom
				} else {
					m.layoutMode = config.LayoutLeftRight
				}

				// Re-apply dimensions to both workspaces (the inactive one
				// must not accumulate stale sizes) and all open spec panels.
				m.workPanelCallbacks().resize()
				m.followupPanelCallbacks().resize()
				m.resizeSpecPanels()

				// Persist preference asynchronously
				prefs := config.Prefs{Layout: m.layoutMode}
				return m, func() tea.Msg {
					_ = config.SavePrefs(prefs)
					return nil
				}
			}
		case "/":
			if m.state == stateWork && m.focusedPanel == panelLeft {
				items := buildWorkItemPopupItems(m.list.Items())
				m.popup = search.New(items, "Search Work Items")
				m.popup.SetSize(m.width, m.height)
				m.popupActive = true
				m.popupCtx = contextList
				return m, m.popup.Init()
			}
			if m.state == stateWork && m.focusedPanel == panelRight && !m.terminalMode && m.detail.Detail() != nil {
				locs := m.detail.BuildSearchIndex()
				items := make([]search.PopupItem, len(locs))
				for i, loc := range locs {
					items[i] = search.PopupItem{
						ID:       fmt.Sprintf("%d", i),
						Label:    loc.Label,
						Subtitle: loc.TabLabel,
						Data:     loc,
					}
				}
				m.popup = search.New(items, "Search Detail")
				m.popup.SetSize(m.width, m.height)
				m.popupActive = true
				m.popupCtx = contextDetail
				return m, m.popup.Init()
			}
			if m.state == stateFollowUps && m.focusedPanel == panelLeft {
				items := buildFollowupPopupItems(m.followupList.Items())
				m.popup = search.New(items, "Search Follow-ups")
				m.popup.SetSize(m.width, m.height)
				m.popupActive = true
				m.popupCtx = contextFollowups
				return m, m.popup.Init()
			}
			// stateKnowledge / no match: no-op.
		case "K":
			if (m.state == stateWork || m.state == stateFollowUps || m.state == stateSettlement) && !m.terminalMode {
				m.prevState = m.state
				m.state = stateKnowledge
				m.browser = knowledge.NewBrowserModel(m.config.KnowledgeDir)
				m.browser, _ = m.browser.Update(tea.WindowSizeMsg{Width: m.width, Height: m.height})
				return m, knowledge.LoadManifestCmd(m.config.KnowledgeDir)
			}
		case "ctrl+,", "S":
			// Open the settings configurator modal. Two openers are bound:
			// `Ctrl+,` (idiomatic on terminals that deliver it) and capital
			// `S` (universally reliable fallback — `s` lowercase is /spec).
			// Available from any non-terminal split-pane state. Per D10 we
			// rebuild a fresh panel each open so previously-discarded
			// drafts cannot leak across sessions; if init fails, surface a
			// flash error so the user sees something instead of silence.
			if (m.state == stateWork || m.state == stateFollowUps || m.state == stateKnowledge || m.state == stateSettlement) && !m.terminalMode {
				return m.openSettingsModal("")
			}
		case "f":
			if (m.state == stateWork || m.state == stateSettlement) && !m.terminalMode {
				m.state = stateFollowUps
				// Preserve items already loaded by the background poll so the
				// counter and list don't flicker to 0 while the reload is in flight.
				if len(m.followupList.Items()) == 0 {
					m.followupList = followup.NewListModel(nil)
				}
				m.followupDetail = followup.NewDetailModel(m.config.KnowledgeDir)
				m.followupPanelCallbacks().resize()
				m.lastFollowupDetailMtime = time.Time{}
				m.focusedPanel = panelLeft
				return m, followup.LoadIndexCmd(m.config.KnowledgeDir)
			}
		case "w":
			if m.state == stateFollowUps && !m.terminalMode {
				cmd := m.leaveFollowups()
				return m, cmd
			}
			if m.state == stateSettlement {
				m.state = stateWork
				return m, loadWorkItems(m.config.WorkDir)
			}
		case "s":
			if m.state == stateWork && m.focusedPanel == panelRight && !m.terminalMode {
				if slug := m.list.CurrentSlug(); slug != "" {
					return m, func() tea.Msg { return work.SpecRequestMsg{Slug: slug} }
				}
			}
		case "c":
			if m.state == stateWork && m.focusedPanel == panelRight && !m.terminalMode {
				if slug := m.list.CurrentSlug(); slug != "" {
					title := slug
					for _, item := range m.list.Items() {
						if item.Slug == slug {
							title = item.Title
							break
						}
					}
					return m, func() tea.Msg { return work.ChatRequestMsg{Slug: slug, Title: title} }
				}
			}
			if m.state == stateFollowUps && !m.terminalMode {
				if item, ok := m.followupList.CurrentItem(); ok {
					msg := followup.FollowupChatRequestMsg{
						ID:             item.ID,
						Title:          item.Title,
						Source:         item.Source,
						FindingExcerpt: m.followupDetail.FindingExcerpt(),
						FindingIndex:   -1,
					}
					return m, func() tea.Msg { return msg }
				}
			}
		case "p":
			if m.state == stateSettlement {
				m.settlementProcessInFlight = true
				m.settlementProcessStartedAt = time.Now()
				return m, runSettlementAction("process")
			}
			if m.state == stateFollowUps && m.focusedPanel == panelRight && !m.terminalMode {
				id := m.followupDetail.CurrentID()
				status := m.followupDetail.Status()
				if id == "" {
					break
				}
				switch status {
				case "open", "pending", "reviewed":
					findingsJSON := m.followupDetail.SelectedLensFindingsJSON()
					return m, func() tea.Msg {
						return followup.PromoteRequestMsg{ID: id, FindingsJSON: findingsJSON}
					}
				default:
					m.flashErr = fmt.Sprintf("cannot promote: follow-up is already %s", status)
				}
			}
		case "d":
			if m.state == stateFollowUps && m.focusedPanel == panelRight && !m.terminalMode {
				id := m.followupDetail.CurrentID()
				status := m.followupDetail.Status()
				if id == "" {
					break
				}
				switch status {
				case "open", "pending", "reviewed":
					return m, func() tea.Msg { return followup.DismissRequestMsg{ID: id} }
				default:
					m.flashErr = fmt.Sprintf("cannot dismiss: follow-up is already %s", status)
				}
			}
		case "e":
			if m.state == stateSettlement {
				action := "enable"
				if m.settlement.Status().Enabled {
					action = "disable"
				}
				return m, runSettlementAction(action)
			}
		case "P":
			if m.state == stateFollowUps && m.focusedPanel == panelRight && !m.terminalMode {
				if m.followupDetail.ActiveTab() != followup.TabComments {
					m.flashErr = "P: switch to Comments tab to post"
					break
				}
				selectedCount := m.followupDetail.SelectedCount()
				eventType := m.followupDetail.ReviewEvent()
				// A review with zero inline comments is still postable as a
				// clean APPROVE, or when a general review body is selected.
				// Only a true no-op (COMMENT/REQUEST_CHANGES with neither
				// comments nor a body) is blocked.
				if selectedCount == 0 && eventType != "APPROVE" && !m.followupDetail.HasReviewBody() {
					m.flashErr = "P: nothing to post — select a comment, add a review body, or set the event to Approve (2)"
					break
				}
				if !m.followupDetail.HasPRMetadata() {
					m.flashErr = "P: sidecar missing PR metadata"
					break
				}
				prNumber := m.followupDetail.PRNumber()
				m.confirmAction = "post_review"
				m.confirmSlug = m.followupDetail.CurrentID()
				if selectedCount == 0 {
					m.confirmTitle = fmt.Sprintf("Post review to PR #%d as %s (no inline comments)?", prNumber, eventType)
				} else {
					m.confirmTitle = fmt.Sprintf("Post %d comments to PR #%d as %s?", selectedCount, prNumber, eventType)
				}
				m.confirmCount = selectedCount
				return m, nil
			}
		}

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

		// Re-size the settings modal viewport on terminal resize so long
		// content scrolls correctly when the user grows/shrinks the window.
		if m.settingsActive {
			m.sizeSettingsPanel()
		}

		// Re-size the help viewport so the modal keeps fitting the terminal.
		if m.showHelp {
			m.sizeHelpViewport()
		}

		// Fan constrained sizes out to every workspace, active and inactive —
		// inactive sub-models must not accumulate stale dimensions.
		wcmd := m.workPanelCallbacks().resize()
		fcmd := m.followupPanelCallbacks().resize()
		bcmd := m.knowledgePanelCallbacks().resize()
		m.resizeSpecPanels()

		m.settlement = m.settlement.SetSize(msg.Width-2, msg.Height-4)
		if m.settlementSettingsPanel != nil {
			m.settlementSettingsPanel.SetSize(msg.Width/2, msg.Height-4)
		}
		m.popup.SetSize(msg.Width, msg.Height)

		return m, tea.Batch(wcmd, fcmd, bcmd)

	case workItemsLoadedMsg:
		if msg.err != nil {
			// Discard transient JSON parse errors (mid-write race on _index.json)
			// and keep the existing list intact.
			var syntaxErr *json.SyntaxError
			var typeErr *json.UnmarshalTypeError
			if errors.As(msg.err, &syntaxErr) || errors.As(msg.err, &typeErr) {
				return m, nil
			}
			m.err = fmt.Errorf("failed to load work items: %w", msg.err)
			return m, nil
		}
		prevSlug := m.list.CurrentSlug()
		prevCollapsed := m.list.CollapsedProjects()
		m.list = work.NewListModel(msg.items)
		// Collapse state is session-local: carry it across index reloads,
		// like the cursor restore below.
		m.list.SetCollapsedProjects(prevCollapsed)
		// Re-apply current window dimensions — the new model starts with height=0
		// and any previously received WindowSizeMsg was dispatched to the old model.
		listW, listH := m.listDims()
		m.list, _ = m.list.Update(tea.WindowSizeMsg{Width: listW, Height: listH})
		// Restore cursor to the previously selected item after rebuild.
		m.list.SetCursorBySlug(prevSlug)

		// Re-apply any active spec status indicators to the new list model.
		for slug := range m.specPanels {
			m.list, _ = m.list.Update(work.SpecStatusMsg{Slug: slug})
		}

		var cmds []tea.Cmd
		currentSlug := m.list.CurrentSlug()

		if m.lastIndexMtime.IsZero() {
			// Initial load: full cache clear, preload all items.
			m.detailCache = make(map[string]*work.WorkItemDetail)
			if currentSlug != "" {
				m.detail = work.NewDetailModel(m.config.WorkDir, currentSlug)
				m.detail, _ = m.detail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
				cmds = append(cmds, m.detail.Init())
			}
			for _, item := range msg.items {
				cmds = append(cmds, work.LoadDetail(m.config.WorkDir, item.Slug))
			}
		} else {
			// Auto-refresh: only re-fetch changed items and the currently-viewed item.
			// Remove stale cache entries for items no longer in the index.
			newSlugs := make(map[string]bool, len(msg.items))
			for _, item := range msg.items {
				newSlugs[item.Slug] = true
			}
			for slug := range m.detailCache {
				if !newSlugs[slug] {
					delete(m.detailCache, slug)
				}
			}
			for _, item := range msg.items {
				cached := m.detailCache[item.Slug]
				if item.Slug == currentSlug || cached == nil || cached.Updated != item.Updated {
					cmds = append(cmds, work.LoadDetail(m.config.WorkDir, item.Slug))
				}
			}
		}
		return m, tea.Batch(cmds...)

	case prStatusLoadedMsg:
		lm, cmd := m.list.Update(work.PRStatusMsg{
			Statuses: msg.statuses,
			Err:      msg.err,
		})
		m.list = lm
		return m, cmd

	case settlementStatusLoadedMsg:
		if msg.err != nil {
			m.settlement = m.settlement.ReplaceStatus(settlement.Unavailable(compactErr("settlement status", msg.err)))
			return m, nil
		}
		m.settlement = m.settlement.ReplaceStatus(msg.status)
		if m.shouldAutoProcessSettlement(msg.status) {
			m.settlementProcessInFlight = true
			m.settlementProcessStartedAt = time.Now()
			return m, runAutomaticSettlementProcess()
		}
		return m, nil

	case doctorResultMsg:
		// Persist (or clear) the drift banner. The status bar renders it
		// only when flashErr is empty so transient user-facing errors keep
		// precedence; the banner survives key presses (unlike flashErr)
		// because install drift is a standing condition, not a transient.
		m.doctorBanner = msg.banner
		return m, nil

	case settlementActionCompleteMsg:
		if msg.action == "process" {
			m.settlementProcessInFlight = false
			m.settlementProcessStartedAt = time.Time{}
		}
		if msg.err != nil {
			if !msg.automatic {
				m.flashErr = compactErr("settlement "+msg.action, msg.err)
				return m, loadSettlementStatus()
			}
			return m, nil
		}
		if msg.result.Status != nil {
			m.settlement = m.settlement.ReplaceStatus(*msg.result.Status)
		}
		if msg.action == "enable" || msg.action == "disable" {
			m.refreshSettlementSettingsPanel()
		}
		if msg.automatic {
			return m, nil
		}
		message := msg.result.Message
		if message == "" {
			message = msg.action + " complete"
		}
		m.flashErr = "[settlement] " + message
		return m, loadSettlementStatus()

	case work.SpecRequestMsg:
		return m.handleSpecRequest(msg)

	case work.ChatRequestMsg:
		return m.handleChatRequest(msg)

	case followup.FollowupChatRequestMsg:
		return m.handleFollowupChatRequest(msg)

	case work.SpecProcessStartedMsg:
		return m.handleSpecProcessStarted(msg)

	case work.TerminalOutputMsg:
		return m.handleTerminalOutput(msg)

	case work.QuiescenceTickMsg:
		return m.handleQuiescenceTick(msg)

	case work.NeedsInputChangedMsg:
		return m.handleNeedsInputChanged(msg)

	case work.StreamCompleteMsg:
		return m.handleStreamComplete(msg)

	case work.StreamErrorMsg:
		return m.handleStreamError(msg)

	case work.TerminalDetachMsg:
		return m.handleTerminalDetach(msg)

	case work.TerminalTerminateMsg:
		return m.handleTerminalTerminate(msg)

	case work.ItemSelectedMsg:
		// Enter on list item: load detail and shift focus to right panel
		m.focusedPanel = panelRight
		return m.loadDetail(msg.Item.Slug)

	case work.LoadDetailMsg:
		// Hover-prefetch emitted by the list's onCursorChange hook.
		return m.loadDetail(msg.Slug)

	case work.DetailLoadedMsg:
		// Cache the raw detail for instant revisit (renderMarkdown is synchronous and fast)
		if msg.Err == nil && msg.Detail != nil && m.detailCache != nil {
			m.detailCache[msg.Slug] = msg.Detail
		}
		dm, cmd := m.detail.Update(msg)
		m.detail = dm
		return m, cmd

	case work.BackToListMsg:
		// In split-pane, just shift focus back to left
		m.focusedPanel = panelLeft
		return m, nil

	case search.PopupDismissedMsg:
		m.popupActive = false
		return m, nil

	case search.PopupSelectedMsg:
		m.popupActive = false
		switch m.popupCtx {
		case contextList:
			slug := msg.Item.ID
			m.list.SetCursorBySlug(slug)
			return m.loadDetail(slug)
		case contextDetail:
			if loc, ok := msg.Item.Data.(work.SearchLocation); ok {
				m.detail.JumpTo(loc)
			}
			return m, nil
		case contextFollowups:
			id := msg.Item.ID
			m.followupList.SetCursorByID(id)
			m.focusedPanel = panelRight
			return m, m.loadFollowupDetail(id)
		}

	case popupSearchResultMsg:
		// Only accept results for the current query to ignore stale debounced searches.
		if m.popupActive && msg.query == m.popupLastQuery {
			m.popup.SetItems(msg.items)
		}
		return m, nil

	case knowledge.BrowserDismissedMsg:
		m.state = m.prevState
		if m.state != stateWork && m.state != stateFollowUps && m.state != stateSettlement {
			m.state = stateWork
		}
		return m, nil

	case followup.ListDismissedMsg:
		cmd := m.leaveFollowups()
		return m, cmd

	case followup.FollowUpSelectedMsg:
		m.focusedPanel = panelRight
		return m, m.loadFollowupDetail(msg.Item.ID)

	case followup.LoadDetailMsg:
		return m, m.loadFollowupDetail(msg.ID)

	case followup.PromoteRequestMsg:
		return m, runPromoteFollowUp(msg.ID, msg.FindingsJSON)

	case followup.DismissRequestMsg:
		return m, runDismissFollowUp(msg.ID)

	case followup.IndexLoadedMsg:
		if msg.Err == nil {
			prevID := m.followupDetail.CurrentID()
			m.followupList.SetItems(msg.Items)
			// Always sync detail to the current list item after reload.
			// This handles: initial load (detail empty), post-dismiss/promote
			// (dismissed item gone, cursor moved to next), and live-reload.
			if curID := m.followupList.CurrentID(); curID != "" && curID != prevID {
				return m, m.loadFollowupDetail(curID)
			}
			// Same ID but content may have changed (e.g. status update) — force reload.
			if curID := m.followupList.CurrentID(); curID != "" && curID == prevID {
				m.followupDetail.ClearID()
				return m, m.loadFollowupDetail(curID)
			}
			// No visible items remain — clear the detail panel.
			if m.followupList.CurrentID() == "" {
				m.followupDetail.ClearID()
			}
		}
		return m, nil

	case followup.DetailLoadedMsg:
		fd, cmd := m.followupDetail.Update(msg)
		m.followupDetail = fd
		return m, cmd

	case followup.MergeStatusLoadedMsg:
		fd, cmd := m.followupDetail.Update(msg)
		m.followupDetail = fd
		return m, cmd

	case followup.ExternalEditDoneMsg:
		fd, cmd := m.followupDetail.Update(msg)
		m.followupDetail = fd
		return m, cmd

	case followup.SummaryRequestMsg:
		followupID := msg.FollowupID
		selectionHash := msg.SelectionHash
		return m, func() tea.Msg {
			cmd := exec.Command("lore", "followup", "summarize", followupID) //nolint:gosec
			var stderr strings.Builder
			cmd.Stderr = &stderr
			out, err := cmd.Output()
			if err != nil {
				return followup.SummaryGeneratedMsg{
					SelectionHash: selectionHash,
					Err:           fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String())),
				}
			}
			return followup.SummaryGeneratedMsg{
				Text:          strings.TrimSpace(string(out)),
				SelectionHash: selectionHash,
			}
		}

	case followup.SummaryGeneratedMsg:
		fd, cmd := m.followupDetail.Update(msg)
		m.followupDetail = fd
		return m, cmd

	case followup.ActionCompleteMsg:
		if msg.Err != nil {
			m.flashErr = fmt.Sprintf("%s failed: %v", msg.Action, msg.Err)
		}
		// Reload index; cursor position is preserved by ListModel.SetItems clamping.
		return m, followup.LoadIndexCmd(m.config.KnowledgeDir)

	case followup.PostReviewCompleteMsg:
		if msg.Err != nil {
			m.flashErr = fmt.Sprintf("post failed: %v", msg.Err)
			// Reload detail to reflect any partial state.
			m.followupDetail.PreserveTab()
			m.lastFollowupDetailMtime = time.Time{}
			m.followupDetail.ClearID()
			return m, m.followupDetail.SetID(msg.ID)
		}
		if msg.Dropped+msg.Shifted+msg.Renamed+msg.Appended > 0 {
			var clauses []string
			if msg.Dropped > 0 {
				clauses = append(clauses, fmt.Sprintf("%d dropped", msg.Dropped))
			}
			if msg.Shifted > 0 {
				clauses = append(clauses, fmt.Sprintf("%d shifted", msg.Shifted))
			}
			if msg.Renamed > 0 {
				clauses = append(clauses, fmt.Sprintf("%d renamed", msg.Renamed))
			}
			if msg.Appended > 0 {
				clauses = append(clauses, fmt.Sprintf("%d moved to body", msg.Appended))
			}
			m.flashErr = fmt.Sprintf("Posted %d (%s) — marked reviewed", msg.PostedCount, strings.Join(clauses, ", "))
		} else {
			if msg.PostedCount == 0 {
				m.flashErr = "Review posted — marked reviewed"
			} else {
				m.flashErr = fmt.Sprintf("Posted %d comments — marked reviewed", msg.PostedCount)
			}
		}
		// Mark the followup reviewed so it moves out of the pending filter;
		// the resulting ActionCompleteMsg triggers an index reload which refreshes the detail.
		return m, runMarkFollowUpReviewed(msg.ID)

	case followup.ExternalEditRequestMsg:
		editor := os.Getenv("EDITOR")
		if editor == "" {
			// $EDITOR not set — nothing to do; ReviewCardsModel already set flashMsg.
			return m, nil
		}
		tmpFile, err := os.CreateTemp("", "lore-comment-*.md")
		if err != nil {
			return m, func() tea.Msg {
				return followup.ExternalEditDoneMsg{Err: err}
			}
		}
		tmpPath := tmpFile.Name()
		if _, writeErr := tmpFile.WriteString(msg.Body); writeErr != nil {
			_ = tmpFile.Close()
			_ = os.Remove(tmpPath)
			return m, func() tea.Msg {
				return followup.ExternalEditDoneMsg{Err: writeErr}
			}
		}
		_ = tmpFile.Close()
		cmd := exec.Command(editor, tmpPath) //nolint:gosec
		backingIdx := msg.BackingIdx
		return m, tea.ExecProcess(cmd, func(err error) tea.Msg {
			if err != nil {
				_ = os.Remove(tmpPath)
				return followup.ExternalEditDoneMsg{Err: err}
			}
			content, readErr := os.ReadFile(tmpPath)
			_ = os.Remove(tmpPath)
			if readErr != nil {
				return followup.ExternalEditDoneMsg{Err: readErr}
			}
			return followup.ExternalEditDoneMsg{BackingIdx: backingIdx, NewBody: string(content)}
		})

	case knowledge.ManifestLoadedMsg:
		bm, cmd := m.browser.Update(msg)
		m.browser = bm
		return m, cmd

	case knowledge.EntryLoadedMsg:
		bm, cmd := m.browser.Update(msg)
		m.browser = bm
		return m, cmd
	}

	// Route to active view. Work and follow-ups share the split-pane seam:
	// handlePanelRouting consumes mouse focus and tab/esc/h/ctrl+t, and
	// routeFocusedPanel forwards everything else to the focused sub-model.
	switch m.state {
	case stateWork:
		cb := m.workPanelCallbacks()
		if cmd, consumed := handlePanelRouting(&m, msg, cb); consumed {
			return m, cmd
		}
		return m, routeFocusedPanel(&m, msg, cb)
	case stateFollowUps:
		cb := m.followupPanelCallbacks()
		if cmd, consumed := handlePanelRouting(&m, msg, cb); consumed {
			return m, cmd
		}
		return m, routeFocusedPanel(&m, msg, cb)
	case stateKnowledge:
		// Only mouse routing goes through the seam (focus clicks delegate to
		// the browser); keys and async results reach browser.Update directly
		// so the browser keeps its own focus and tree handling.
		if _, ok := msg.(tea.MouseMsg); ok {
			cmd, _ := handlePanelRouting(&m, msg, m.knowledgePanelCallbacks())
			return m, cmd
		}
		bm, cmd := m.browser.Update(msg)
		m.browser = bm
		return m, cmd
	case stateSettlement:
		sm, cmd := m.settlement.Update(msg)
		m.settlement = sm
		return m, cmd
	}

	return m, nil
}

// resizeSpecPanels re-applies the spec panel slot size to every open spec
// panel and propagates it to each panel's PTY.
func (m *model) resizeSpecPanels() {
	specH := m.detailPanelHeight()
	specW := m.rightPanelWidth() - 2
	for slug, panel := range m.specPanels {
		sm, _ := panel.Update(tea.WindowSizeMsg{Width: specW, Height: specH})
		if ptmx := sm.Ptmx(); ptmx != nil {
			_ = pty.Setsize(ptmx, &pty.Winsize{
				Rows: uint16(specH),
				Cols: uint16(specW),
			})
		}
		m.specPanels[slug] = sm
	}
}

func (m *model) ensureSettlementSettingsPanel() {
	if m.settlementSettingsPanel != nil {
		return
	}
	panel, err := initSettlementSettingsPanel()
	if panel != nil {
		m.settlementSettingsPanel = panel
		return
	}
	if err != nil {
		m.flashErr = fmt.Sprintf("settings: %v", err)
	} else {
		m.flashErr = "settings: panel unavailable"
	}
}

func (m *model) refreshSettlementSettingsPanel() {
	m.settlementSettingsPanel = nil
	m.ensureSettlementSettingsPanel()
}

func (m model) updateInlineSettlementSettings(msg tea.KeyPressMsg) (model, tea.Cmd) {
	m.ensureSettlementSettingsPanel()
	if m.settlementSettingsPanel == nil {
		return m, nil
	}
	panel, cmd := m.settlementSettingsPanel.Update(msg)
	m.settlementSettingsPanel = panel
	switch msg.String() {
	case "enter", "space", "u":
		cmd = batchCmd(cmd, loadSettlementStatus())
	}
	return m, cmd
}

// settlementInFlightCeiling is the model-level belt to commands.go's
// CommandContext suspenders. If the subprocess goroutine never returns
// settlementActionCompleteMsg (e.g. the kill itself wedges, or the
// goroutine leaks for an unrelated reason), settlementProcessInFlight
// would stay true forever and gate every subsequent auto-process tick.
// This ceiling must comfortably exceed settlementSubprocessTimeout so
// the normal cancel-and-kill path fires first under typical hangs.
const settlementInFlightCeiling = 12 * time.Minute

// settlementInFlightFailsafe clears a stuck settlementProcessInFlight
// flag and surfaces a flash error so the user knows auto-process
// recovered. Called from handleIndexPollTick so every 5s tick re-checks.
// Returns the (possibly mutated) model and whether a recovery fired.
func (m model) settlementInFlightFailsafe() (model, bool) {
	if !m.settlementProcessInFlight {
		return m, false
	}
	if m.settlementProcessStartedAt.IsZero() {
		// Defensive: flag is true but timestamp was never set. Clear it
		// so we don't deadlock the auto-process loop.
		m.settlementProcessInFlight = false
		m.flashErr = "[settlement] in-flight flag had no timestamp — cleared"
		return m, true
	}
	if time.Since(m.settlementProcessStartedAt) <= settlementInFlightCeiling {
		return m, false
	}
	m.settlementProcessInFlight = false
	m.settlementProcessStartedAt = time.Time{}
	m.flashErr = fmt.Sprintf("[settlement] subprocess flag stuck >%s — cleared (auto-process resuming)", settlementInFlightCeiling)
	return m, true
}

func (m model) shouldAutoProcessSettlement(st settlement.Status) bool {
	if m.settlementProcessInFlight {
		return false
	}
	if !st.Available || !st.Enabled {
		return false
	}
	if st.BlockedReason != "" || st.Harness.BlockedReason != "" {
		return false
	}
	if st.Queue.Ready+st.Queue.Pending <= 0 && !(st.Queue.Running == 0 && st.Batch.BacklogSize > 0) {
		return false
	}
	concurrency := st.Harness.Concurrency
	if concurrency <= 0 {
		concurrency = 1
	}
	active := st.Harness.ActiveLeases
	if active == 0 {
		active = len(st.Leases)
	}
	return active < concurrency
}

func batchCmd(a, b tea.Cmd) tea.Cmd {
	if a == nil {
		return b
	}
	if b == nil {
		return a
	}
	return tea.Batch(a, b)
}

func (m model) openSettingsModal(focusDotPath string) (model, tea.Cmd) {
	panel, err := initSettingsPanel()
	if panel != nil {
		if focusDotPath != "" {
			panel.FocusDotPath(focusDotPath)
		}
		m.settingsPanel = panel
		m.settingsActive = true
		m.settingsPriorFocus = m.focusedPanel
		m.sizeSettingsPanel()
		return m, m.settingsPanel.Init()
	}
	if err != nil {
		m.flashErr = fmt.Sprintf("settings: %v", err)
	} else {
		m.flashErr = "settings: panel unavailable"
	}
	return m, nil
}

// leaveFollowups transitions the model from stateFollowUps back to stateWork
// and reloads the work item list so it reflects any changes made while in followup view.
func (m *model) leaveFollowups() tea.Cmd {
	m.state = stateWork
	return loadWorkItems(m.config.WorkDir)
}

// loadFollowupDetail is the single chokepoint for all followup navigation paths.
// It resets the mtime baseline, syncs terminalMode, and initiates the detail load.
func (m *model) loadFollowupDetail(id string) tea.Cmd {
	m.lastFollowupDetailMtime = time.Time{}
	m.terminalMode = m.hasSpecPanel(id)
	return m.followupDetail.SetID(id)
}

// loadDetail creates a fresh DetailModel for slug, applies current dimensions,
// seeds it from the detail cache when available, and revalidates from disk in
// the background so newly created items can't get stuck on a stale cache entry.
// renderMarkdown is synchronous and fast (<1ms), so cached content is instant.
func (m model) loadDetail(slug string) (model, tea.Cmd) {
	m.lastPlanMtime = time.Time{}   // reset so new item's plan.md gets a fresh baseline
	m.lastDetailMtime = time.Time{} // reset so new item's detail files get a fresh baseline
	m.detail = work.NewDetailModel(m.config.WorkDir, slug)
	m.detail, _ = m.detail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
	m.terminalMode = m.hasSpecPanel(slug)

	var initCmd tea.Cmd
	if m.detailCache != nil {
		if cached, ok := m.detailCache[slug]; ok {
			dm, _ := m.detail.Update(work.DetailLoadedMsg{Slug: slug, Detail: cached})
			m.detail = dm
			// Auto-refresh can cache a brand-new item before its sidecar files have
			// settled. Revalidate on selection so the active detail model always gets
			// a fresh DetailLoadedMsg.
			initCmd = m.detail.Init()
		} else {
			initCmd = m.detail.Init()
		}
	} else {
		initCmd = m.detail.Init()
	}

	return m, initCmd
}
