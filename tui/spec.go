package main

import (
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/followup"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// endLocalSession drops a torn-down session from this instance's registry row
// and returns the Cmds that persist the removal and journal the close. It is a
// no-op (nil Cmds) for a slug this instance was not tracking.
func (m model) endLocalSession(slug string) (model, []tea.Cmd) {
	ls, ok := m.localSessions[slug]
	if !ok {
		return m, nil
	}
	delete(m.localSessions, slug)
	delete(m.sessionIdle, slug)
	return m, []tea.Cmd{
		m.writeInstanceCmd(),
		journalCmd(m.eventScript, m.config.KnowledgeDir, m.closedEventFor(slug, ls)),
	}
}

func (m model) handleSpecRequest(msg work.SpecRequestMsg) (model, tea.Cmd) {
	// 's' on list item: if spec already running, jump to terminal focus.
	// Otherwise show confirmation modal before launching subprocess.
	if m.hasSpecPanel(msg.Slug) {
		m.terminalMode = true
		m.setPreferDetail(msg.Slug, false)
		m.focusedPanel = panelRight
		return m, nil
	}
	ta := newModalTextarea()
	focusCmd := ta.Focus()
	m.sessionConfirmSlug = msg.Slug
	m.sessionConfirmTitle = msg.Slug
	m.sessionConfirmInput = ta
	m.sessionConfirmShortMode = true
	m.sessionConfirmSkipConfirm = true
	m.sessionConfirmChatMode = false
	m.sessionConfirmActive = true
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
	m.sessionConfirmSlug = msg.Slug
	m.sessionConfirmTitle = msg.Title
	m.sessionConfirmInput = ta
	m.sessionConfirmChatMode = true
	m.sessionConfirmFollowupMode = false
	m.sessionConfirmActive = true
	return m, focusCmd
}

func (m model) handleFollowupChatRequest(msg followup.FollowupChatRequestMsg) (model, tea.Cmd) {
	// 'c' on a follow-up item: open a chat session about the follow-up.
	if m.hasSpecPanel(msg.ID) {
		m.focusedPanel = panelRight
		return m, nil
	}
	// Title/Source may be empty when the message originates from LensFindingsModel
	// (which only knows the followup ID). Fill from the currently loaded detail.
	title := msg.Title
	if title == "" {
		title = m.followupDetail.Title()
	}
	ta2 := newModalTextarea()
	focusCmd2 := ta2.Focus()
	m.sessionConfirmSlug = msg.ID
	m.sessionConfirmTitle = title
	m.sessionConfirmShortMode = false
	m.sessionConfirmSkipConfirm = false
	m.sessionConfirmInput = ta2
	m.sessionConfirmChatMode = true
	m.sessionConfirmFollowupMode = true
	m.sessionConfirmFindingIndex = msg.FindingIndex
	m.sessionConfirmActive = true
	if msg.EditPrompt != "" {
		ta2.SetValue(msg.EditPrompt)
	}
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
	// A fresh session supersedes any detail preference left over from a
	// previous session on the same item — navigation should auto-show it.
	m.setPreferDetail(slug, false)

	// Promote the pending spawn into this instance's live session set and
	// register it. For a queue-claimed session, delete the claimed row and
	// journal `spawned` now that the process is up.
	meta, ok := m.pendingSpawns[slug]
	if !ok {
		meta = liveSession{typ: "spec", initiator: "human", started: time.Now()}
	}
	delete(m.pendingSpawns, slug)
	if m.localSessions == nil {
		m.localSessions = make(map[string]liveSession)
	}
	m.localSessions[slug] = meta

	cmds := []tea.Cmd{cmd, m.writeInstanceCmd()}
	if meta.requestID != "" {
		cmds = append(cmds, emitSpawnedCmd(m.sessionsDir, m.eventScript, m.config.KnowledgeDir, session.Event{
			Event:         session.EventSpawned,
			ActorInstance: session.StrPtr(m.instanceName),
			Slug:          slug,
			SessionType:   meta.typ,
			Initiator:     meta.initiator,
			RequestID:     meta.requestID,
		}))
	}

	// Agent-initiated spawns never steal focus — the request row is the recorded
	// intent, and interrupting the human to surface an agent's session inverts
	// who the terminal serves.
	if meta.initiator == "agent" {
		return m, tea.Batch(cmds...)
	}

	// Auto-enter terminal focus when session starts for the currently viewed item,
	// unless the spec was launched from the confirmation modal — in that case,
	// return focus to the listing view so the user stays oriented.
	if slug == m.list.CurrentSlug() {
		if m.sessionLaunchedFromModal {
			m.sessionLaunchedFromModal = false
			m.terminalMode = true
			m.focusedPanel = panelLeft
			return m, tea.Batch(cmds...)
		}
		m.terminalMode = true
		m.focusedPanel = panelRight
		return m, tea.Batch(cmds...)
	}
	// Auto-enter terminal focus for follow-up chat sessions.
	if m.state == stateFollowUps && slug == m.followupDetail.CurrentID() {
		m.terminalMode = true
		m.focusedPanel = panelRight
		return m, tea.Batch(cmds...)
	}
	return m, tea.Batch(cmds...)
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
	// Spec panel's quiescence state changed — forward to list for indicator update
	// and journal the transition. The panel emits this message only on a real
	// edge; sessionIdle is the emit-site guard so an unchanged state (or an
	// untracked slug) never re-emits.
	m.list, _ = m.list.Update(work.SpecStatusMsg{Slug: msg.Slug, NeedsInput: msg.NeedsInput})

	ls, tracked := m.localSessions[msg.Slug]
	if !tracked || m.sessionIdle[msg.Slug] == msg.NeedsInput {
		return m, nil
	}
	if m.sessionIdle == nil {
		m.sessionIdle = make(map[string]bool)
	}
	m.sessionIdle[msg.Slug] = msg.NeedsInput

	script, kdir := m.eventScript, m.config.KnowledgeDir
	if msg.NeedsInput {
		// The panel's single quiescence signal grounds both substrate events: the
		// session went idle and is now treated as awaiting input.
		return m, tea.Batch(
			journalCmd(script, kdir, m.idleEventFor(msg.Slug, session.EventQuiescent, ls)),
			journalCmd(script, kdir, m.idleEventFor(msg.Slug, session.EventNeedsInput, ls)),
		)
	}
	return m, journalCmd(script, kdir, m.idleEventFor(msg.Slug, session.EventResumed, ls))
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
	m, sessCmds := m.endLocalSession(slug)
	// Pre-size detail view and invalidate cache so it's ready when the user
	// exits terminal mode (or immediately if not in terminal mode).
	if m.list.CurrentSlug() == slug {
		m.detail, _ = m.detail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
		if m.detailCache != nil {
			delete(m.detailCache, slug)
		}
	}
	cmds := append([]tea.Cmd(nil), sessCmds...)
	if m.state == stateFollowUps {
		cmds = append(cmds, followup.LoadIndexCmd(m.config.KnowledgeDir))
	} else {
		cmds = append(cmds, loadWorkItems(m.config.WorkDir))
		if m.list.CurrentSlug() == slug {
			cmds = append(cmds, m.detail.Init()) // reload detail to show updated plan.md
		}
	}
	return m, tea.Batch(cmds...)
}

func (m model) handleStreamError(msg work.StreamErrorMsg) (model, tea.Cmd) {
	// PTY error — mark done with error, cleanup PTY. Still reload list in
	// case spec wrote partial files before failing.
	slug := msg.Slug
	if m.specPanels != nil {
		if panel, ok := m.specPanels[slug]; ok {
			sm, _ := panel.Update(msg) // marks hasError+done
			sm = sm.Cleanup()
			m.specPanels[slug] = sm
			if m.terminalMode && m.list.CurrentSlug() == slug {
				m.focusedPanel = panelRight
			}
			if m.terminalMode && m.state == stateFollowUps && m.followupDetail.CurrentID() == slug {
				m.focusedPanel = panelRight
			}
		}
	}
	if m.list.CurrentSlug() == slug || (m.state == stateFollowUps && m.followupDetail.CurrentID() == slug) {
		m.terminalMode = false
	}
	m.list, _ = m.list.Update(work.SpecStatusMsg{Slug: slug, Done: true})

	var cmds []tea.Cmd
	if meta, pending := m.pendingSpawns[slug]; pending {
		// The process never started: this is a spawn failure, not a session
		// close. For a queue-claimed request, return it to pending (attempts++)
		// and journal spawn_failed; a human spawn just drops.
		delete(m.pendingSpawns, slug)
		if meta.requestID != "" {
			reason := "pty_start_failed"
			if msg.Err != nil {
				reason = compactErr("spawn", msg.Err)
			}
			cmds = append(cmds, emitSpawnFailedCmd(m.sessionsDir, m.eventScript, m.config.KnowledgeDir, meta.requestID, reason, m.instanceName))
		}
	} else {
		var sessCmds []tea.Cmd
		m, sessCmds = m.endLocalSession(slug)
		cmds = append(cmds, sessCmds...)
	}

	if m.state == stateFollowUps {
		cmds = append(cmds, followup.LoadIndexCmd(m.config.KnowledgeDir))
	} else {
		cmds = append(cmds, loadWorkItems(m.config.WorkDir))
	}
	return m, tea.Batch(cmds...)
}

func (m model) handleTerminalDetach(_ work.TerminalDetachMsg) (model, tea.Cmd) {
	// Double-Esc from terminal focus detaches focus only: the list regains
	// the keyboard while the right panel keeps showing the terminal.
	m.focusedPanel = panelLeft
	return m, nil
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
	m.terminalMode = false

	m.list, _ = m.list.Update(work.SpecStatusMsg{Slug: slug, Done: true})
	m.detail, _ = m.detail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
	m, sessCmds := m.endLocalSession(slug)
	cmds := append([]tea.Cmd(nil), sessCmds...)
	if m.state == stateFollowUps {
		cmds = append(cmds, followup.LoadIndexCmd(m.config.KnowledgeDir))
	} else {
		cmds = append(cmds, loadWorkItems(m.config.WorkDir))
	}
	return m, tea.Batch(cmds...)
}
