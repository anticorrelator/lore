package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// liveSession is the metadata the TUI tracks for one local session: enough to
// write its registry row and to journal its lifecycle. requestID is set only for
// queue-claimed (agent) sessions.
type liveSession struct {
	typ       string // spec|implement|chat
	initiator string // agent|human
	requestID string
	started   time.Time
	// autoClose is the per-request auto-close override the close ladder consults:
	// nil defers to initiator (agent auto-closes, human holds open), a set value
	// forces the outcome. Carried from the request row at spawn.
	autoClose *bool
}

// --- messages ---

// sessionSnapshotMsg carries a full registry snapshot for external-session
// badging. It replaces badging state wholesale, never merges.
type sessionSnapshotMsg struct {
	instances []session.Instance
}

// queueTickResultMsg carries the durable transitions one queue pass performed.
type queueTickResultMsg struct {
	result session.QueueTickResult
	err    error
}

// instanceSyncedMsg reports the outcome of a registry write/heartbeat.
type instanceSyncedMsg struct {
	err error
}

// journalResultMsg reports the outcome of a journal append.
type journalResultMsg struct {
	err error
}

// --- Cmds ---

// readInstancesCmd reads the instance registry (a full snapshot).
func readInstancesCmd(sessionsDir string) tea.Cmd {
	return func() tea.Msg {
		return sessionSnapshotMsg{instances: session.ListInstances(sessionsDir)}
	}
}

// syncInstanceCmd heartbeats this instance's registry file, recreating it if a
// stale-reaper or first tick left it absent.
func (m model) syncInstanceCmd() tea.Cmd {
	dir := m.sessionsDir
	inst := m.instanceRow()
	return func() tea.Msg {
		return instanceSyncedMsg{err: session.Heartbeat(dir, inst)}
	}
}

// writeInstanceCmd rewrites this instance's registry file after its session set
// changed.
func (m model) writeInstanceCmd() tea.Cmd {
	dir := m.sessionsDir
	inst := m.instanceRow()
	return func() tea.Msg {
		return instanceSyncedMsg{err: session.WriteInstance(dir, inst)}
	}
}

// queueTickCmd runs one reclaim+claim pass. The live-instance set is read inside
// the Cmd; the plan-doc gate is snapshotted from the loaded work items now.
func (m model) queueTickCmd() tea.Cmd {
	dir := m.sessionsDir
	name := m.instanceName
	planDocs := make(map[string]bool)
	for _, it := range m.list.Items() {
		planDocs[it.Slug] = it.HasPlanDoc
	}
	return func() tea.Msg {
		live := make(map[string]bool)
		for _, inst := range session.ListInstances(dir) {
			live[inst.Name] = true
		}
		res, err := session.QueueTick(dir, name, live,
			func(slug string) bool { return planDocs[slug] },
			time.Now(), session.ReclaimAfter)
		return queueTickResultMsg{result: res, err: err}
	}
}

// journalCmd appends one event row via the sole-writer script.
func journalCmd(script, kdir string, ev session.Event) tea.Cmd {
	return func() tea.Msg {
		return journalResultMsg{err: session.AppendEvent(script, kdir, ev)}
	}
}

// emitSpawnedCmd deletes the claimed row then journals `spawned` — the delete is
// the durable terminal state, so it must land before the history row.
func emitSpawnedCmd(dir, script, kdir string, ev session.Event) tea.Cmd {
	return func() tea.Msg {
		if err := session.DeleteClaimed(dir, ev.RequestID); err != nil {
			return journalResultMsg{err: err}
		}
		return journalResultMsg{err: session.AppendEvent(script, kdir, ev)}
	}
}

// emitSpawnFailedCmd returns the request to pending with an incremented attempt
// count and a recorded reason, then journals `spawn_failed`. The return-to-
// pending is the durable transition and lands first.
func emitSpawnFailedCmd(dir, script, kdir, requestID, reason, actor string) tea.Cmd {
	return func() tea.Msg {
		req, err := session.ReadClaimed(dir, requestID)
		if err != nil {
			return journalResultMsg{err: err}
		}
		req.Attempts++
		at := time.Now().UTC().Format("2006-01-02T15:04:05Z")
		req.LastAttemptAt = &at
		req.LastError = &reason
		req.ClaimedBy = nil
		req.ClaimedAt = nil
		if err := session.ReturnToPending(dir, req); err != nil {
			return journalResultMsg{err: err}
		}
		ev := session.Event{
			Event:         session.EventSpawnFailed,
			ActorInstance: session.StrPtr(actor),
			Slug:          req.SlugValue(),
			SessionType:   req.Type,
			Initiator:     req.Initiator,
			RequestID:     requestID,
			Reason:        reason,
		}
		return journalResultMsg{err: session.AppendEvent(script, kdir, ev)}
	}
}

// --- handlers ---

// handleSessionSnapshot turns a registry snapshot into external-session badging
// for the list and detail views. Sessions on this instance are local and never
// badged as external.
func (m model) handleSessionSnapshot(msg sessionSnapshotMsg) (model, tea.Cmd) {
	external := make(map[string]work.ExternalSession)
	for _, inst := range msg.instances {
		if inst.Name == m.instanceName {
			continue
		}
		for _, s := range inst.Sessions {
			external[s.Slug] = work.ExternalSession{
				Instance:  inst.Name,
				Type:      s.Type,
				Initiator: s.Initiator,
			}
		}
	}
	m.list, _ = m.list.Update(work.ExternalSessionMsg{Sessions: external})
	currentSlug := m.list.CurrentSlug()
	if es, ok := external[currentSlug]; ok {
		m.detail, _ = m.detail.Update(work.DetailExternalSessionMsg{
			Active: true, Instance: es.Instance, Type: es.Type, Initiator: es.Initiator,
		})
	} else {
		m.detail, _ = m.detail.Update(work.DetailExternalSessionMsg{Active: false})
	}
	return m, nil
}

// handleQueueTickResult journals every durable queue transition and spawns the
// claimed request (if any). Reclaim/abandon durable changes already completed in
// the tick, so their journal rows follow safely.
func (m model) handleQueueTickResult(msg queueTickResultMsg) (model, tea.Cmd) {
	if msg.err != nil {
		m.flashErr = compactErr("session queue", msg.err)
	}
	script, kdir := m.eventScript, m.config.KnowledgeDir
	var cmds []tea.Cmd
	for _, ev := range msg.result.Reclaimed {
		cmds = append(cmds, journalCmd(script, kdir, session.Event{
			Event:         session.EventReclaimed,
			ActorInstance: session.StrPtr(m.instanceName),
			RequestID:     ev.RequestID,
			Reason:        ev.Reason,
		}))
	}
	for _, ev := range msg.result.Abandoned {
		cmds = append(cmds, journalCmd(script, kdir, session.Event{
			Event:         session.EventAbandoned,
			ActorInstance: session.StrPtr(m.instanceName),
			RequestID:     ev.RequestID,
			Reason:        ev.Reason,
		}))
	}
	if req := msg.result.Claimed; req != nil {
		cmds = append(cmds, journalCmd(script, kdir, session.Event{
			Event:          session.EventClaimed,
			ActorInstance:  session.StrPtr(m.instanceName),
			TargetInstance: req.TargetInstance,
			Slug:           req.SlugValue(),
			SessionType:    req.Type,
			Initiator:      req.Initiator,
			RequestID:      req.RequestID,
		}))
		var spawnCmd tea.Cmd
		m, spawnCmd = m.spawnFromRequest(*req)
		if spawnCmd != nil {
			cmds = append(cmds, spawnCmd)
		}
	}
	if len(cmds) == 0 {
		return m, nil
	}
	return m, tea.Batch(cmds...)
}

// spawnFromRequest maps a claimed request onto a session descriptor and drives
// the shared spawn path. Agent-initiated, so it never steals focus.
func (m model) spawnFromRequest(req session.Request) (model, tea.Cmd) {
	d := work.SessionDescriptor{
		Type:         req.Type,
		Slug:         req.SlugValue(),
		Title:        req.SlugValue(),
		ExtraContext: req.ExtraContextText(),
		Initiator:    req.Initiator,
		AutoClose:    req.AutoClose,
		SkipConfirm:  true,
		FindingIndex: -1,
	}
	return m.spawnSession(d, req.RequestID)
}

// spawnSession is the single spawn path for both the human confirm modal and the
// agent request queue. It pre-creates and sizes the panel, records the pending
// spawn's metadata for the SpecProcessStarted handler, and returns the spawn
// Cmd. Agent-initiated spawns are marked so the started handler never steals
// focus; human spawns keep the existing modal-return-focus behavior.
func (m model) spawnSession(d work.SessionDescriptor, requestID string) (model, tea.Cmd) {
	slug := d.Slug
	m.list, _ = m.list.Update(work.SpecStatusMsg{Slug: slug})
	specH := m.detailPanelHeight()
	specW := m.rightPanelWidth() - 2 // 1-char buffer on each side
	panel := work.NewSpecPanelModel(slug)
	panel, _ = panel.Update(tea.WindowSizeMsg{Width: specW, Height: specH})
	m.setSpecPanel(slug, panel)
	m.detail, _ = m.detail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})

	if m.pendingSpawns == nil {
		m.pendingSpawns = make(map[string]liveSession)
	}
	m.pendingSpawns[slug] = liveSession{
		typ:       sessionType(d.Type),
		initiator: d.Initiator,
		requestID: requestID,
		started:   time.Now(),
		autoClose: d.AutoClose,
	}
	if d.Initiator != "agent" {
		m.sessionLaunchedFromModal = m.state == stateWork
	}
	env := work.SessionEnv{Instance: m.instanceName, Slug: slug, Type: sessionType(d.Type)}
	return m, work.StartSessionShimCmd(d, m.config.ProjectDir, specW, specH, m.config.KnowledgeDir, env)
}

// instanceRow builds this instance's registry row from its live session set.
func (m model) instanceRow() session.Instance {
	sessions := make([]session.Session, 0, len(m.localSessions))
	for slug, ls := range m.localSessions {
		sessions = append(sessions, session.Session{
			Slug:      slug,
			Type:      ls.typ,
			Initiator: ls.initiator,
			Started:   ls.started.UTC().Format("2006-01-02T15:04:05Z"),
		})
	}
	return session.Instance{
		Name:             m.instanceName,
		PID:              os.Getpid(),
		Repo:             m.config.RepoIdentifier,
		Started:          m.instanceStartedISO,
		InitiatorDefault: "human",
		Sessions:         sessions,
	}
}

// closedEventFor builds the `closed` journal row for a torn-down local session,
// carrying the cheap teardown duration in spend.
func (m model) closedEventFor(slug string, ls liveSession) session.Event {
	dur := int(time.Since(ls.started).Seconds())
	if dur < 0 {
		dur = 0
	}
	return session.Event{
		Event:         session.EventClosed,
		ActorInstance: session.StrPtr(m.instanceName),
		Slug:          slug,
		SessionType:   ls.typ,
		Initiator:     ls.initiator,
		RequestID:     ls.requestID,
		Spend:         json.RawMessage(fmt.Sprintf(`{"duration_seconds":%d}`, dur)),
	}
}

// idleEventFor builds one of the running-session transition rows
// (needs_input/quiescent/resumed) for a local session. These carry the running
// instance and the session's identity but — unlike queue-lifecycle events — no
// request_id.
func (m model) idleEventFor(slug, event string, ls liveSession) session.Event {
	return session.Event{
		Event:         event,
		ActorInstance: session.StrPtr(m.instanceName),
		Slug:          slug,
		SessionType:   ls.typ,
		Initiator:     ls.initiator,
	}
}

// sessionType normalizes a descriptor Type onto the substrate's session_type
// enum, defaulting an unknown value to "spec".
func sessionType(t string) string {
	switch t {
	case "spec", "implement", "chat":
		return t
	default:
		return "spec"
	}
}
