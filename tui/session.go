package main

import (
	"fmt"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/followup"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
	"github.com/anticorrelator/lore/tui/internal/worktree"
)

// endLocalSession drops a torn-down session from this instance's registry row
// and returns the Cmds that persist the removal and journal `closed`. It is a
// no-op (nil Cmds) for a slug this instance was not tracking. The `closed` row
// carries the session's spawn request_id; the ladder-teardown caller overrides it
// with the consumed close request_id via endLocalSessionClosed.
func (m model) endLocalSession(slug string) (model, []tea.Cmd) {
	return m.endLocalSessionClosed(slug, "")
}

// endLocalSessionClosed is endLocalSession with the consumed close-request id
// stamped onto the `closed` row (empty leaves the spawn request_id), so a close
// requester has a uniform match key for a ladder-driven teardown.
func (m model) endLocalSessionClosed(slug, closeRequestID string) (model, []tea.Cmd) {
	ls, ok := m.localSessions[slug]
	if !ok {
		return m, nil
	}
	if ls.worktreeID != "" {
		if ls.worktreeDispositionPending {
			return m, nil
		}
		ls.worktreeDispositionPending = true
		m.localSessions[slug] = ls
		return m, []tea.Cmd{tea.Sequence(m.writeInstanceCmd(), m.quiesceManagedWorktreeCmd(slug, ls, closeRequestID))}
	}
	if ls.worktree != nil && ls.worktree.OwnsWorktree() {
		if ls.worktreeDispositionPending {
			return m, nil
		}
		pending := *ls.worktree
		if pending.State != worktree.StateTeardownPending {
			var err error
			pending, err = worktree.Transition(pending, worktree.StateTeardownPending)
			if err != nil {
				m.flashErr = compactErr("worktree teardown transition", err)
				return m, []tea.Cmd{journalCmd(m.eventScript, m.config.KnowledgeDir, worktreeOutcomeEvent(
					m.instanceName, slug, ls, worktree.PublishOutcome{
						Kind: worktree.OutcomeRestoreRefused, Identity: *ls.worktree,
						Expected: ls.worktree.Captured, Reason: err.Error(),
					},
				))}
			}
		}
		ls.worktree = cloneWorktreeIdentity(&pending)
		ls.worktreeDispositionPending = true
		m.localSessions[slug] = ls
		return m, []tea.Cmd{tea.Sequence(m.writeInstanceCmd(), m.disposeWorktreeCmd(slug, ls, closeRequestID))}
	}
	return m.finalizeLocalSessionClosed(slug, closeRequestID)
}

func (m model) finalizeLocalSessionClosed(slug, closeRequestID string) (model, []tea.Cmd) {
	ls, ok := m.localSessions[slug]
	if !ok {
		return m, nil
	}
	delete(m.localSessions, slug)
	delete(m.sessionIdle, slug)
	delete(m.sessionModalBlocked, slug)
	return m, []tea.Cmd{
		m.writeInstanceCmd(),
		m.closedSpendJournalCmd(slug, ls, closeRequestID),
	}
}

// endLocalSessionFailed journals `close_failed` without releasing the session's
// durable workspace ownership. The harness may still be running, so its registry
// row is rewritten as teardown-pending and remains recoverable by this or a later
// TUI instance.
func (m model) endLocalSessionFailed(slug, closeRequestID, reason string) (model, []tea.Cmd) {
	ls, ok := m.localSessions[slug]
	if !ok {
		return m, nil
	}
	requestID := closeRequestID
	if requestID == "" {
		requestID = ls.requestID
	}
	var refusalCmd tea.Cmd
	if ls.worktree != nil && ls.worktreeID == "" {
		pending := *ls.worktree
		if pending.State != worktree.StateTeardownPending {
			var err error
			pending, err = worktree.Transition(pending, worktree.StateTeardownPending)
			if err != nil {
				m.flashErr = compactErr("worktree teardown transition", err)
				refusalCmd = journalCmd(m.eventScript, m.config.KnowledgeDir, worktreeOutcomeEvent(
					m.instanceName, slug, ls, worktree.PublishOutcome{
						Kind: worktree.OutcomeRestoreRefused, Identity: *ls.worktree,
						Expected: ls.worktree.Captured, Reason: err.Error(),
					},
				))
			} else {
				ls.worktree = cloneWorktreeIdentity(&pending)
			}
		}
	}
	m.localSessions[slug] = ls
	cmds := []tea.Cmd{m.writeInstanceCmd()}
	if refusalCmd != nil {
		cmds = append(cmds, refusalCmd)
	}
	cmds = append(cmds, m.closeFailedCmd(slug, requestID, reason, ls))
	return m, cmds
}

func (m model) handleSpecRequest(msg work.SpecRequestMsg) (model, tea.Cmd) {
	// 's' on a work item: attach if a session already exists, else show the
	// confirmation modal before launching the spec subprocess.
	if m.hasSessionPanel(msg.Slug) {
		m.terminalMode = true
		m.setPreferDetail(msg.Slug, false)
		m.focusedPanel = panelRight
		return m, nil
	}
	ta := newModalTextarea()
	focusCmd := ta.Focus()
	m.sessionConfirmInput = ta
	m.sessionConfirmDescriptor = work.SessionDescriptor{
		Type:         work.SessionSpec,
		Slug:         msg.Slug,
		Title:        msg.Slug,
		Initiator:    "human",
		ShortMode:    true,
		SkipConfirm:  true,
		FindingIndex: -1,
	}
	m.sessionConfirmActive = true
	return m, focusCmd
}

func (m model) handleChatRequest(msg work.ChatRequestMsg) (model, tea.Cmd) {
	// 'c' on a work item: attach if a session exists, else open a chat confirm.
	if m.hasSessionPanel(msg.Slug) {
		m.focusedPanel = panelRight
		return m, nil
	}
	ta := newModalTextarea()
	focusCmd := ta.Focus()
	m.sessionConfirmInput = ta
	m.sessionConfirmDescriptor = work.SessionDescriptor{
		Type:         work.SessionChat,
		Slug:         msg.Slug,
		Title:        msg.Title,
		Initiator:    "human",
		FindingIndex: -1,
	}
	m.sessionConfirmActive = true
	return m, focusCmd
}

func (m model) handleImplementRequest(msg work.ImplementRequestMsg) (model, tea.Cmd) {
	// 'i' on a work item: attach if a session exists; otherwise gate on
	// readiness before opening the confirm modal. /implement consumes tasks.json,
	// so the human gate is stricter than the spec launch — an item with no tasks
	// (or an archived one) has nothing to implement.
	if m.hasSessionPanel(msg.Slug) {
		m.terminalMode = true
		m.setPreferDetail(msg.Slug, false)
		m.focusedPanel = panelRight
		return m, nil
	}
	item, ok := m.workItemBySlug(msg.Slug)
	if !ok || !item.HasTasks || item.Status == "archived" {
		m.flashErr = fmt.Sprintf("cannot implement %s: not ready — run /spec to generate tasks first", msg.Slug)
		return m, nil
	}
	ta := newModalTextarea()
	focusCmd := ta.Focus()
	m.sessionConfirmInput = ta
	m.sessionConfirmDescriptor = work.SessionDescriptor{
		Type:         work.SessionImplement,
		Slug:         msg.Slug,
		Title:        item.Title,
		Initiator:    "human",
		FindingIndex: -1,
	}
	m.sessionConfirmActive = true
	return m, focusCmd
}

func (m model) handleFollowupChatRequest(msg followup.FollowupChatRequestMsg) (model, tea.Cmd) {
	// 'c' on a follow-up item: open a chat session about the follow-up.
	if m.hasSessionPanel(msg.ID) {
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
	if msg.EditPrompt != "" {
		ta2.SetValue(msg.EditPrompt)
	}
	m.sessionConfirmInput = ta2
	m.sessionConfirmDescriptor = work.SessionDescriptor{
		Type:         work.SessionChat,
		Slug:         msg.ID,
		Title:        title,
		Initiator:    "human",
		FollowupMode: true,
		FindingIndex: msg.FindingIndex,
	}
	m.sessionConfirmActive = true
	return m, focusCmd2
}

// workItemBySlug returns the loaded work item for a slug from the list model,
// or false when no such item is loaded.
func (m model) workItemBySlug(slug string) (work.WorkItem, bool) {
	for _, it := range m.list.Items() {
		if it.Slug == slug {
			return it, true
		}
	}
	return work.WorkItem{}, false
}

// sessionTypeForSlug returns the session Type recorded for a slug across the
// live and pending session sets, defaulting to spec when unknown. Used to re-tag
// the list's active-session indicator after an index reload rebuilds the list
// model, so the per-type label survives the rebuild.
func (m model) sessionTypeForSlug(slug string) string {
	if ls, ok := m.localSessions[slug]; ok {
		return ls.typ
	}
	if ls, ok := m.pendingSpawns[slug]; ok {
		return ls.typ
	}
	return work.SessionSpec
}

func (m model) handleSessionProcessStarted(msg work.SessionProcessStartedMsg) (model, tea.Cmd) {
	// PTY subprocess launched — attach PTY to the pre-created spec panel and start polling.
	for _, notice := range msg.Notices {
		m = m.routeRuntimeNotices([]runtimeNotice{degradationNotice(notice.Code, notice.Message)})
	}
	slug := msg.Slug
	var panel work.SessionPanelModel
	if existing, ok := m.sessionPanels[slug]; ok && !existing.IsDone() {
		panel = existing
	} else {
		panel = work.NewSessionPanelModel(slug)
	}
	sm, cmd := panel.Update(msg) // SessionProcessStartedMsg sets ptmx + starts PollTerminalCmd
	m.setSessionPanel(slug, sm)
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
	// Stamp the spawn-time spend binding onto the live session so teardown can
	// probe this session's transcript (empty session id → duration-only close).
	// tmuxName marks a tmux-hosted session for the registry manifest and the
	// quit-detach branch; it is echoed back on the started message (empty for
	// direct-PTY).
	meta.sessionID = msg.SessionID
	meta.harness = msg.Harness
	meta.tmuxName = msg.Tmux
	meta.pid = msg.PID
	meta.worktreeID = msg.WorktreeID
	meta.executionDir = msg.ExecutionDir
	if !meta.adopted {
		meta.worktree = cloneWorktreeIdentity(&msg.Worktree)
	}
	if m.localSessions == nil {
		m.localSessions = make(map[string]liveSession)
	}
	delete(m.sessionModalBlocked, slug)
	m.localSessions[slug] = meta

	cmds := []tea.Cmd{cmd}
	switch {
	case meta.adopted:
		// Recovery: journal `recovered`, not `spawned` — this session already had a
		// `spawned` row under the dead instance. emitRecoveredCmd writes the durable
		// registry row (now listing the adopted session) before the journal row.
		cmds = append(cmds, emitRecoveredCmd(m.sessionsDir, m.eventScript, m.config.KnowledgeDir, m.instanceRow(), session.Event{
			Event:          session.EventRecovered,
			ActorInstance:  session.StrPtr(m.instanceName),
			TargetInstance: session.StrPtr(meta.adoptedFrom),
			Slug:           slug,
			SessionType:    meta.typ,
			Initiator:      meta.initiator,
			RequestID:      meta.requestID,
			Reason:         "adopted from " + meta.adoptedFrom,
		}))
	default:
		cmds = append(cmds, m.writeInstanceCmd())
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
	if m.sessionPanels != nil {
		if panel, ok := m.sessionPanels[slug]; ok {
			sm, panelCmd := panel.Update(msg)
			m.sessionPanels[slug] = sm
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
	if m.sessionPanels != nil {
		if panel, ok := m.sessionPanels[slug]; ok {
			sm, cmd := panel.Update(msg)
			m.sessionPanels[slug] = sm
			return m, cmd
		}
	}
	return m, nil
}

func (m model) handleNeedsInputChanged(msg work.NeedsInputChangedMsg) (model, tea.Cmd) {
	// A session panel's quiescence state changed — forward to list for indicator
	// update and journal the transition. The panel emits this message only on a
	// real edge; sessionIdle is the emit-site guard so an unchanged state (or an
	// untracked slug) never re-emits. Type carries the live session's kind so the
	// active label survives the needs-input update.
	m.list, _ = m.list.Update(work.SessionStatusMsg{Slug: msg.Slug, Type: m.localSessions[msg.Slug].typ, NeedsInput: msg.NeedsInput})

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
	if m.sessionPanels != nil {
		if panel, ok := m.sessionPanels[slug]; ok {
			sm := panel.Cleanup()
			sm, _ = sm.Update(msg) // sets done = true
			m.sessionPanels[slug] = sm
		}
	}
	// Do NOT force m.terminalMode = false — if we're in terminal mode for
	// this slug, keep it so the user can scroll through the output history.
	m.list, _ = m.list.Update(work.SessionStatusMsg{Slug: slug, Done: true})
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
	for _, notice := range msg.Notices {
		m = m.routeRuntimeNotices([]runtimeNotice{degradationNotice(notice.Code, notice.Message)})
	}
	slug := msg.Slug
	if m.sessionPanels != nil {
		if panel, ok := m.sessionPanels[slug]; ok {
			sm, _ := panel.Update(msg) // marks hasError+done
			sm = sm.Cleanup()
			m.sessionPanels[slug] = sm
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
	m.list, _ = m.list.Update(work.SessionStatusMsg{Slug: slug, Done: true})

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
	if m.sessionPanels != nil {
		if panel, ok := m.sessionPanels[slug]; ok {
			panel.Cleanup()
			delete(m.sessionPanels, slug)
		}
	}
	m.terminalMode = false

	m.list, _ = m.list.Update(work.SessionStatusMsg{Slug: slug, Done: true})
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
