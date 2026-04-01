package main

import (
	tea "github.com/charmbracelet/bubbletea"

	"github.com/anticorrelator/lore/tui/internal/followup"
	"github.com/anticorrelator/lore/tui/internal/work"
)

func (m model) handleSpecRequest(msg work.SpecRequestMsg) (model, tea.Cmd) {
	// 's' on list item: if spec already running, jump to terminal focus.
	// Otherwise show confirmation modal before launching subprocess.
	if m.hasSpecPanel(msg.Slug) {
		m.terminalMode = true
		m.focusedPanel = panelRight
		return m, tea.EnableMouseCellMotion
	}
	ta := newModalTextarea()
	focusCmd := ta.Focus()
	m.specConfirmSlug = msg.Slug
	m.specConfirmTitle = msg.Slug
	m.specConfirmInput = ta
	m.specConfirmShortMode = true
	m.specConfirmSkipConfirm = true
	m.specConfirmChatMode = false
	m.specConfirmActive = true
	m.enableKittyKeyboard()
	return m, focusCmd
}

func (m model) handleChatRequest(msg work.ChatRequestMsg) (model, tea.Cmd) {
	// 'c' on list item: open a chat session about the work item.
	if m.hasSpecPanel(msg.Slug) {
		m.focusedPanel = panelRight
		return m, nil
	}
	ta := newModalTextarea()
	focusCmd := ta.Focus()
	m.specConfirmSlug = msg.Slug
	m.specConfirmTitle = msg.Title
	m.specConfirmInput = ta
	m.specConfirmChatMode = true
	m.specConfirmActive = true
	m.enableKittyKeyboard()
	return m, focusCmd
}

func (m model) handleFollowupChatRequest(msg followup.FollowupChatRequestMsg) (model, tea.Cmd) {
	// 'c' on a follow-up item: open a chat session about the follow-up.
	if m.hasSpecPanel(msg.ID) {
		m.focusedPanel = panelRight
		return m, nil
	}
	ta2 := newModalTextarea()
	focusCmd2 := ta2.Focus()
	m.specConfirmSlug = msg.ID
	m.specConfirmTitle = msg.Title
	m.specConfirmShortMode = false
	m.specConfirmSkipConfirm = false
	m.specConfirmInput = ta2
	m.specConfirmChatMode = true
	m.specConfirmActive = true
	m.enableKittyKeyboard()
	return m, focusCmd2
}

func (m model) handleSpecProcessStarted(msg work.SpecProcessStartedMsg) (model, tea.Cmd) {
	// PTY subprocess launched — attach PTY to the pre-created spec panel and start polling.
	slug := msg.Slug
	var panel work.SpecPanelModel
	if existing, ok := m.specPanels[slug]; ok && !existing.IsDone() {
		panel = existing
	} else {
		panel = work.NewSpecPanelModel(slug)
	}
	sm, cmd := panel.Update(msg) // SpecProcessStartedMsg sets ptmx + starts PollTerminalCmd
	m.setSpecPanel(slug, sm)
	work.WriteSession(m.config.WorkDir, slug, "spec") //nolint:errcheck
	// Auto-enter terminal focus when session starts for the currently viewed item,
	// unless the spec was launched from the confirmation modal — in that case,
	// return focus to the listing view so the user stays oriented.
	if slug == m.list.CurrentSlug() {
		if m.specLaunchedFromModal {
			m.specLaunchedFromModal = false
			m.terminalMode = true
			m.focusedPanel = panelLeft
			return m, tea.Batch(cmd, tea.EnableMouseCellMotion)
		}
		m.terminalMode = true
		m.focusedPanel = panelRight
		return m, tea.Batch(cmd, tea.EnableMouseCellMotion)
	}
	// Auto-enter terminal focus for follow-up chat sessions.
	if m.state == stateFollowUps && slug == m.followupDetail.CurrentID() {
		m.terminalMode = true
		m.focusedPanel = panelRight
		return m, tea.Batch(cmd, tea.EnableMouseCellMotion)
	}
	return m, cmd
}

func (m model) handleTerminalOutput(msg work.TerminalOutputMsg) (model, tea.Cmd) {
	// Route output to the correct spec panel, then continue polling.
	// The panel may return a NeedsInputChangedMsg cmd if output clears quiescence.
	slug := msg.Slug
	if m.specPanels != nil {
		if panel, ok := m.specPanels[slug]; ok {
			sm, panelCmd := panel.Update(msg)
			m.specPanels[slug] = sm
			// Only re-arm polling if the panel hasn't completed — re-arming
			// on a closed channel creates a tight StreamCompleteMsg loop.
			var cmds []tea.Cmd
			if !sm.IsDone() {
				cmds = append(cmds, work.PollTerminalCmd(slug, sm.OutputChan()))
			}
			if panelCmd != nil {
				cmds = append(cmds, panelCmd)
			}
			if len(cmds) > 0 {
				return m, tea.Batch(cmds...)
			}
			return m, nil
		}
	}
	return m, nil
}

func (m model) handleQuiescenceTick(msg work.QuiescenceTickMsg) (model, tea.Cmd) {
	// Route quiescence tick to the correct spec panel.
	slug := msg.Slug
	if m.specPanels != nil {
		if panel, ok := m.specPanels[slug]; ok {
			sm, cmd := panel.Update(msg)
			m.specPanels[slug] = sm
			return m, cmd
		}
	}
	return m, nil
}

func (m model) handleNeedsInputChanged(msg work.NeedsInputChangedMsg) (model, tea.Cmd) {
	// Spec panel's quiescence state changed — forward to list for indicator update.
	m.list, _ = m.list.Update(work.SpecStatusMsg{Slug: msg.Slug, NeedsInput: msg.NeedsInput})
	return m, nil
}

func (m model) handleStreamComplete(msg work.StreamCompleteMsg) (model, tea.Cmd) {
	// PTY channel closed (subprocess exited normally). Clean up PTY resources
	// but keep the panel in the map so scrollback history remains accessible.
	slug := msg.Slug
	if m.specPanels != nil {
		if panel, ok := m.specPanels[slug]; ok {
			sm := panel.Cleanup()
			sm, _ = sm.Update(msg) // sets done = true
			m.specPanels[slug] = sm
		}
	}
	// Do NOT force m.terminalMode = false — if we're in terminal mode for
	// this slug, keep it so the user can scroll through the output history.
	m.list, _ = m.list.Update(work.SpecStatusMsg{Slug: slug, Done: true})
	work.ClearSession(m.config.WorkDir, slug) //nolint:errcheck
	// Pre-size detail view and invalidate cache so it's ready when the user
	// exits terminal mode (or immediately if not in terminal mode).
	if m.list.CurrentSlug() == slug {
		m.detail, _ = m.detail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
		if m.detailCache != nil {
			delete(m.detailCache, slug)
		}
	}
	var cmds []tea.Cmd
	cmds = append(cmds, loadWorkItems(m.config.WorkDir))
	if m.list.CurrentSlug() == slug {
		cmds = append(cmds, m.detail.Init()) // reload detail to show updated plan.md
	}
	work.ClearSession(m.config.WorkDir, slug) //nolint:errcheck
	return m, tea.Batch(cmds...)
}

func (m model) handleStreamError(msg work.StreamErrorMsg) (model, tea.Cmd) {
	// PTY error — mark done with error, cleanup PTY. Still reload list in
	// case spec wrote partial files before failing.
	slug := msg.Slug
	wasSpec := false
	if m.specPanels != nil {
		if panel, ok := m.specPanels[slug]; ok {
			sm, _ := panel.Update(msg) // marks hasError+done
			sm = sm.Cleanup()
			m.specPanels[slug] = sm
			if m.terminalMode && m.list.CurrentSlug() == slug {
				m.focusedPanel = panelRight
				wasSpec = true
			}
			if m.terminalMode && m.state == stateFollowUps && m.followupDetail.CurrentID() == slug {
				m.focusedPanel = panelRight
				wasSpec = true
			}
		}
	}
	if m.list.CurrentSlug() == slug || (m.state == stateFollowUps && m.followupDetail.CurrentID() == slug) {
		m.terminalMode = false
	}
	m.list, _ = m.list.Update(work.SpecStatusMsg{Slug: slug, Done: true})
	work.ClearSession(m.config.WorkDir, slug) //nolint:errcheck
	if wasSpec {
		return m, tea.Batch(tea.EnableMouseCellMotion, loadWorkItems(m.config.WorkDir))
	}
	return m, loadWorkItems(m.config.WorkDir)
}

func (m model) handleTerminalDetach(_ work.TerminalDetachMsg) (model, tea.Cmd) {
	// User pressed Esc from terminal focus — return to list view.
	m.focusedPanel = panelLeft
	m.terminalMode = false
	return m, tea.EnableMouseCellMotion
}

func (m model) handleTerminalTerminate(msg work.TerminalTerminateMsg) (model, tea.Cmd) {
	// User killed the subprocess (Ctrl+\\) — cleanup and remove the panel.
	// Reload list in case spec wrote files before being killed.
	slug := msg.Slug
	if m.specPanels != nil {
		if panel, ok := m.specPanels[slug]; ok {
			panel.Cleanup()
			delete(m.specPanels, slug)
		}
	}
	wasSpec := m.terminalMode
	m.terminalMode = false

	m.list, _ = m.list.Update(work.SpecStatusMsg{Slug: slug, Done: true})
	m.detail, _ = m.detail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
	work.ClearSession(m.config.WorkDir, slug) //nolint:errcheck
	if wasSpec {
		return m, tea.Batch(tea.EnableMouseCellMotion, loadWorkItems(m.config.WorkDir))
	}
	return m, loadWorkItems(m.config.WorkDir)
}
