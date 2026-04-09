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

	tea "github.com/charmbracelet/bubbletea"
	"github.com/creack/pty"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/followup"
	"github.com/anticorrelator/lore/tui/internal/knowledge"
	"github.com/anticorrelator/lore/tui/internal/search"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// handlePanelRouting handles shared mouse-focus routing and tab/esc/ctrl+t key
// handling for split-pane states (stateWork and stateFollowUps). It mutates m
// in place and returns a command and a bool indicating whether the message was
// consumed. If consumed is false the caller must handle the message itself.
// Entity-specific action keys (s, c, p, d, …) are NOT handled here.
func handlePanelRouting(m *model, msg tea.Msg, cb panelCallbacks) (tea.Cmd, bool) {
	switch msg := msg.(type) {
	case tea.MouseMsg:
		isClick := msg.Action == tea.MouseActionPress && msg.Button == tea.MouseButtonLeft && !msg.Shift
		if isClick {
			if m.layoutMode == config.LayoutLeftRight {
				xBoundary := leftPanelWidth + 2
				if msg.X < xBoundary {
					m.focusedPanel = panelLeft
				} else {
					m.focusedPanel = panelRight
				}
			} else {
				topH := m.topPanelHeight()
				if msg.Y <= 1+topH {
					m.focusedPanel = panelLeft
				} else {
					m.focusedPanel = panelRight
				}
			}
		}
		switch m.focusedPanel {
		case panelLeft:
			cmd, prevID, newID := cb.listUpdate(msg)
			if newID != "" && newID != prevID {
				detailCmd := cb.loadDetail(newID)
				return tea.Batch(cmd, detailCmd), true
			}
			return cmd, true
		default: // panelRight
			if m.terminalMode {
				id := cb.currentSlug()
				if m.specPanels != nil {
					if panel, ok := m.specPanels[id]; ok {
						sm, cmd := panel.Update(msg)
						m.specPanels[id] = sm
						return cmd, true
					}
				}
			}
			if cb.setContentStart != nil {
				cb.setContentStart()
			}
			cmd := cb.detailUpdate(msg)
			return cmd, true
		}

	case tea.KeyMsg:
		switch msg.String() {
		case "esc":
			if m.focusedPanel == panelRight && !m.terminalMode {
				m.focusedPanel = panelLeft
				return nil, true
			}
		case "ctrl+t":
			if m.focusedPanel == panelRight {
				if m.terminalMode {
					m.terminalMode = false
					return nil, true
				}
				if panel, ok := cb.specPanelFn(); ok && (panel.Ptmx() != nil || panel.IsDone()) {
					m.terminalMode = true
					return tea.EnableMouseCellMotion, true
				}
			}
		case "tab":
			if m.focusedPanel == panelLeft {
				m.focusedPanel = panelRight
				return nil, true
			}
		}
	}
	return nil, false
}

func (m model) Init() tea.Cmd {
	if m.state == stateOnboarding || m.state == stateNoRepo {
		return nil
	}
	return tea.Batch(
		loadWorkItems(m.config.WorkDir),
		loadPRStatus(),
		indexPollTick(),
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

	msg = translateCSIu(msg)

	// Help modal: intercept all keys; Esc or ? closes it.
	if m.showHelp {
		if km, ok := msg.(tea.KeyMsg); ok {
			if km.String() == "esc" || km.String() == "?" {
				m.showHelp = false
			}
			return m, nil
		}
		// Non-key messages (e.g. window resize) fall through.
	}

	// Confirm modal for archive/delete: intercept all keys.
	if m.confirmAction != "" {
		if km, ok := msg.(tea.KeyMsg); ok {
			switch km.String() {
			case "y", "enter":
				action := m.confirmAction
				slug := m.confirmSlug
				count := m.confirmCount
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
					return m, runPostReview(m.config.KnowledgeDir, slug, count)
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
		if _, ok := msg.(shiftEnterMsg); ok {
			m.sessionConfirmInput.InsertRune('\n')
			return m, nil
		}
		if km, ok := msg.(tea.KeyMsg); ok {
			switch km.String() {
			case "alt+enter":
				m.sessionConfirmInput.InsertRune('\n')
				return m, nil
			case "enter":
				extraContext := strings.TrimSpace(m.sessionConfirmInput.Value())
				m.sessionConfirmActive = false
				m.disableKittyKeyboard()
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
				m.disableKittyKeyboard()
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
		if _, ok := msg.(shiftEnterMsg); ok {
			m.aiInput.InsertRune('\n')
			return m, nil
		}
		if km, ok := msg.(tea.KeyMsg); ok {
			switch km.String() {
			case "alt+enter":
				m.aiInput.InsertRune('\n')
				return m, nil
			case "enter":
				prompt := strings.TrimSpace(m.aiInput.Value())
				m.aiInputActive = false
				m.disableKittyKeyboard()
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
				m.disableKittyKeyboard()
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
		if _, ok := msg.(tea.KeyMsg); ok {
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

	case tea.MouseMsg:
		// Centralized click routing: main.go owns all panel geometry,
		// so mouse events are routed here before reaching sub-models.
		switch m.state {
		case stateWork:
			cb := panelCallbacks{
				currentSlug: func() string { return m.list.CurrentSlug() },
				loadDetail: func(slug string) tea.Cmd {
					var cmd tea.Cmd
					m, cmd = m.loadDetail(slug)
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
				setContentStart: func() {
					if m.layoutMode == config.LayoutLeftRight {
						m.detail.SetContentStart(2, leftPanelWidth+5)
					} else {
						m.detail.SetContentStart(m.topPanelHeight()+4, 3)
					}
				},
			}
			cmd, _ := handlePanelRouting(&m, msg, cb)
			return m, cmd
		case stateKnowledge:
			// Browser uses the same leftPanelWidth split as stateWork LayoutLeftRight.
			isClick := msg.Action == tea.MouseActionPress && msg.Button == tea.MouseButtonLeft && !msg.Shift
			if isClick {
				xBoundary := leftPanelWidth + 2
				if msg.X < xBoundary {
					m.browser.FocusLeft()
				} else {
					m.browser.FocusRight()
				}
			}
			bm, cmd := m.browser.Update(msg)
			m.browser = bm
			return m, cmd
		case stateFollowUps:
			cb := panelCallbacks{
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
				setContentStart: func() {
					if m.layoutMode == config.LayoutLeftRight {
						m.followupDetail.SetContentStart(2, leftPanelWidth+5)
					} else {
						m.followupDetail.SetContentStart(m.topPanelHeight()+4, 3)
					}
				},
			}
			cmd, _ := handlePanelRouting(&m, msg, cb)
			return m, cmd
		}

	case tea.KeyMsg:
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

		switch msg.String() {
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
				return m, nil
			}
		case "q":
			if (m.state == stateWork || m.state == stateFollowUps) && !m.terminalMode {
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
				items := m.list.Items()
				cur := m.list.Cursor()
				if cur < len(items) {
					item := items[cur]
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
				items := m.list.Items()
				cur := m.list.Cursor()
				if cur < len(items) {
					item := items[cur]
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
				m.enableKittyKeyboard()
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

				if m.state == stateWork {
					m.list.SetCompactMode(m.layoutMode == config.LayoutLeftRight)

					// Re-apply dimensions to list
					listW := leftPanelWidth
					listH := m.innerHeight()
					if m.layoutMode == config.LayoutTopBottom {
						listW = m.topPanelWidth()
						listH = m.topPanelHeight()
					}
					m.list, _ = m.list.Update(tea.WindowSizeMsg{Width: listW, Height: listH})

					// Re-apply dimensions to detail and all open spec panels.
					m.detail, _ = m.detail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
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
				} else {
					// stateFollowUps: re-apply dimensions to followup models and open spec panels.
					m.followupList.SetCompactMode(m.layoutMode == config.LayoutLeftRight)
					fuListW, fuListH := followupListDims(m)
					m.followupList, _ = m.followupList.Update(tea.WindowSizeMsg{Width: fuListW, Height: fuListH})
					m.followupDetail, _ = m.followupDetail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
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
			if (m.state == stateWork || m.state == stateFollowUps) && !m.terminalMode {
				m.prevState = m.state
				m.state = stateKnowledge
				m.browser = knowledge.NewBrowserModel(m.config.KnowledgeDir)
				m.browser, _ = m.browser.Update(tea.WindowSizeMsg{Width: m.width, Height: m.height})
				return m, knowledge.LoadManifestCmd(m.config.KnowledgeDir)
			}
		case "f":
			if m.state == stateWork && !m.terminalMode {
				m.state = stateFollowUps
				m.followupList = followup.NewListModel(nil)
				m.followupList.SetCompactMode(m.layoutMode == config.LayoutLeftRight)
				fuListW, fuListH := followupListDims(m)
				m.followupList, _ = m.followupList.Update(tea.WindowSizeMsg{Width: fuListW, Height: fuListH})
				m.followupDetail = followup.NewDetailModel(m.config.KnowledgeDir)
				m.followupDetail, _ = m.followupDetail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
				m.lastFollowupDetailMtime = time.Time{}
				m.focusedPanel = panelLeft
				return m, followup.LoadIndexCmd(m.config.KnowledgeDir)
			}
		case "w":
			if m.state == stateFollowUps && !m.terminalMode {
				cmd := m.leaveFollowups()
				return m, cmd
			}
		case "esc":
			// Esc from right panel (detail mode only): back to list.
			// In terminal mode, esc falls through to spec panel which sends TerminalDetachMsg.
			if (m.state == stateWork || m.state == stateFollowUps) && m.focusedPanel == panelRight && !m.terminalMode {
				m.focusedPanel = panelLeft
				return m, nil
			}
		case "ctrl+t":
			// ctrl+t toggles the right panel between detail and terminal, like a tab.
			// Handled here (before route-to-active-view) so it is never forwarded to the PTY.
			if (m.state == stateWork || m.state == stateFollowUps) && m.focusedPanel == panelRight {
				if m.terminalMode {
					m.terminalMode = false
					return m, nil
				}
				var specPanelFn func() (work.SpecPanelModel, bool)
				if m.state == stateFollowUps {
					specPanelFn = m.currentFollowupPanel
				} else {
					specPanelFn = m.currentSpecPanel
				}
				if panel, ok := specPanelFn(); ok && (panel.Ptmx() != nil || panel.IsDone()) {
					m.terminalMode = true
					return m, tea.EnableMouseCellMotion
				}
			}
		case "tab":
			// Tab moves focus left→right only. When on the right panel, Tab
			// falls through to the detail view so it can cycle through tabs.
			if (m.state == stateWork || m.state == stateFollowUps) && m.focusedPanel == panelLeft {
				m.focusedPanel = panelRight
				return m, nil
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
		case "P":
			if m.state == stateFollowUps && m.focusedPanel == panelRight && !m.terminalMode {
				if m.followupDetail.ActiveTab() != followup.TabComments {
					m.flashErr = "P: switch to Comments tab to post"
					break
				}
				selectedCount := m.followupDetail.SelectedCount()
				if selectedCount == 0 {
					m.flashErr = "P: no comments selected"
					break
				}
				if !m.followupDetail.HasPRMetadata() {
					m.flashErr = "P: sidecar missing PR metadata"
					break
				}
				prNumber := m.followupDetail.PRNumber()
				eventType := m.followupDetail.ReviewEvent()
				m.confirmAction = "post_review"
				m.confirmSlug = m.followupDetail.CurrentID()
				m.confirmTitle = fmt.Sprintf("Post %d comments to PR #%d as %s?", selectedCount, prNumber, eventType)
				m.confirmCount = selectedCount
				return m, nil
			}
		}

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

		// Send constrained sizes to sub-models (inner height excludes borders + status bar).
		// In top/bottom layout, list gets full width and topPanelHeight.
		listW := leftPanelWidth
		listH := m.innerHeight()
		if m.layoutMode == config.LayoutTopBottom {
			listW = m.topPanelWidth()
			listH = m.topPanelHeight()
		}
		lm, lcmd := m.list.Update(tea.WindowSizeMsg{Width: listW, Height: listH})
		m.list = lm

		// Size detail — reduced when current item has a spec panel open.
		var dcmd tea.Cmd
		m.detail, dcmd = m.detail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
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

		bm, bcmd := m.browser.Update(msg)
		m.browser = bm
		fuListW, fuListH := followupListDims(m)
		fl, _ := m.followupList.Update(tea.WindowSizeMsg{Width: fuListW, Height: fuListH})
		m.followupList = fl
		fd, _ := m.followupDetail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
		m.followupDetail = fd
		m.popup.SetSize(msg.Width, msg.Height)

		return m, tea.Batch(lcmd, dcmd, bcmd)

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
		m.list = work.NewListModel(msg.items)
		m.list.SetCompactMode(m.layoutMode == config.LayoutLeftRight)
		// Re-apply current window dimensions — the new model starts with height=0
		// and any previously received WindowSizeMsg was dispatched to the old model.
		listW := leftPanelWidth
		listH := m.innerHeight()
		if m.layoutMode == config.LayoutTopBottom {
			listW = m.topPanelWidth()
			listH = m.topPanelHeight()
		}
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
		if m.state != stateWork && m.state != stateFollowUps {
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
			m.followupList.SetCompactMode(m.layoutMode == config.LayoutLeftRight)
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

	case followup.ExternalEditDoneMsg:
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
		} else {
			m.flashErr = fmt.Sprintf("Posted %d comments", msg.PostedCount)
		}
		// Reload detail to reflect updated sidecar state.
		m.followupDetail.PreserveTab()
		m.lastFollowupDetailMtime = time.Time{}
		m.followupDetail.ClearID()
		loadCmd := m.followupDetail.SetID(msg.ID)
		return m, loadCmd

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

	// Route to active view
	switch m.state {
	case stateWork:
		if m.focusedPanel == panelRight && m.terminalMode {
			// Route to the spec panel (terminal mode) for the currently selected work item.
			slug := m.list.CurrentSlug()
			if m.specPanels != nil {
				if panel, ok := m.specPanels[slug]; ok {
					sm, cmd := panel.Update(msg)
					m.specPanels[slug] = sm
					return m, cmd
				}
			}
			// No panel for current item — fall back to detail.
			m.terminalMode = false
			dm, cmd := m.detail.Update(msg)
			m.detail = dm
			return m, cmd
		}
		if m.focusedPanel == panelLeft {
			prevSlug := m.list.CurrentSlug()
			lm, cmd := m.list.Update(msg)
			m.list = lm
			newSlug := m.list.CurrentSlug()
			if newSlug != "" && newSlug != prevSlug {
				var detailCmd tea.Cmd
				m, detailCmd = m.loadDetail(newSlug)
				return m, tea.Batch(cmd, detailCmd)
			}
			return m, cmd
		}
		dm, cmd := m.detail.Update(msg)
		m.detail = dm
		return m, cmd
	case stateKnowledge:
		bm, cmd := m.browser.Update(msg)
		m.browser = bm
		return m, cmd
	case stateFollowUps:
		if m.focusedPanel == panelRight && m.terminalMode {
			// Route to the spec panel (terminal mode) for the currently selected follow-up.
			id := m.followupDetail.CurrentID()
			if m.specPanels != nil {
				if panel, ok := m.specPanels[id]; ok {
					sm, cmd := panel.Update(msg)
					m.specPanels[id] = sm
					return m, cmd
				}
			}
			// No panel for current follow-up — fall back to detail.
			m.terminalMode = false
			fd, cmd := m.followupDetail.Update(msg)
			m.followupDetail = fd
			return m, cmd
		}
		if m.focusedPanel == panelLeft {
			prevID := m.followupList.CurrentID()
			fl, cmd := m.followupList.Update(msg)
			m.followupList = fl
			newID := m.followupList.CurrentID()
			if newID != "" && newID != prevID {
				return m, tea.Batch(cmd, m.loadFollowupDetail(newID))
			}
			return m, cmd
		}
		fd, cmd := m.followupDetail.Update(msg)
		m.followupDetail = fd
		return m, cmd
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
// When arriving at an item that has an active terminal and right-panel focus,
// it also re-emits tea.EnableMouseCellMotion to restore app-level mouse tracking.
func (m *model) loadFollowupDetail(id string) tea.Cmd {
	m.lastFollowupDetailMtime = time.Time{}
	m.terminalMode = m.hasSpecPanel(id)
	loadCmd := m.followupDetail.SetID(id)
	if m.terminalMode && m.focusedPanel == panelRight {
		return tea.Batch(loadCmd, tea.EnableMouseCellMotion)
	}
	return loadCmd
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

	if m.terminalMode && m.focusedPanel == panelRight {
		return m, tea.Batch(initCmd, tea.EnableMouseCellMotion)
	}
	return m, initCmd
}
