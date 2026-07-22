package main

import (
	"os"
	"path/filepath"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/coordination"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/sessionview"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// coordinationArcsScannedMsg carries the arc fold: every project label whose
// home contains coordination.md, in the work list's recency order.
type coordinationArcsScannedMsg struct {
	arcs []coordination.Arc
}

// coordinationLedgerReadMsg carries one arc's coordination.md content plus the
// extracted ## Brief section. err leaves content empty so the Ledger tab
// renders the unreadable state explicitly.
type coordinationLedgerReadMsg struct {
	arc        string
	content    string
	brief      string
	briefFound bool
	err        error
}

// coordinationPinReadMsg carries one arc's derived pin state. Liveness is
// joined at read time against the registry TTL, never stored.
type coordinationPinReadMsg struct {
	arc    string
	status coordination.PinStatus
	pin    *coordination.Pin
	err    error
}

// scanArcsCmd folds the project groups against a coordination.md existence
// check. One stat per project label — cheap enough to ride every poll tick
// from any state, keeping the tab-indicator count current.
func (m model) scanArcsCmd() tea.Cmd {
	workDir := m.config.WorkDir
	items := m.list.Items()
	return func() tea.Msg {
		var arcs []coordination.Arc
		for _, g := range work.GroupByProject(items) {
			if g.Project == "" {
				continue
			}
			if _, err := os.Stat(filepath.Join(work.ProjectHome(workDir, g.Project), "coordination.md")); err == nil {
				arcs = append(arcs, coordination.Arc{Slug: g.Project, Members: len(g.Items)})
			}
		}
		return coordinationArcsScannedMsg{arcs: arcs}
	}
}

// readArcLedgerCmd reads an arc's coordination.md and extracts its Brief off
// the UI thread.
func readArcLedgerCmd(workDir, arc string) tea.Cmd {
	return func() tea.Msg {
		data, err := os.ReadFile(filepath.Join(work.ProjectHome(workDir, arc), "coordination.md"))
		if err != nil {
			return coordinationLedgerReadMsg{arc: arc, err: err}
		}
		brief, found := work.ExtractSection(string(data), "Brief")
		return coordinationLedgerReadMsg{arc: arc, content: string(data), brief: brief, briefFound: found}
	}
}

// readArcPinCmd reads an arc's pin sidecar and derives its liveness by joining
// pin.instance against the registry's mtime TTL.
func (m model) readArcPinCmd(arc string) tea.Cmd {
	workDir := m.config.WorkDir
	sessionsDir := m.sessionsDir
	return func() tea.Msg {
		pin, err := coordination.ReadPin(work.ProjectHome(workDir, arc))
		if err != nil {
			return coordinationPinReadMsg{arc: arc, err: err}
		}
		status := coordination.PinAbsent
		if pin != nil {
			if session.InstanceLive(sessionsDir, pin.Instance) {
				status = coordination.PinLive
			} else {
				status = coordination.PinDead
			}
		}
		return coordinationPinReadMsg{arc: arc, status: status, pin: pin}
	}
}

// handleCoordinationArcsScanned replaces the arc set (cursor preserved by
// slug) and re-syncs the detail when the selection identity changed — the
// cursor diff, not the raw index, drives detail sync.
func (m model) handleCoordinationArcsScanned(msg coordinationArcsScannedMsg) (model, tea.Cmd) {
	m.coordinationList.SetArcs(msg.arcs)
	if m.state == stateCoordination {
		if cur := m.coordinationList.CurrentSlug(); cur != m.coordinationDetail.Arc() {
			return m, m.loadCoordinationDetail(cur)
		}
	}
	return m, nil
}

// handleCoordinationLedgerRead pushes a ledger read into the detail, dropping
// stale responses for a previously selected arc.
func (m model) handleCoordinationLedgerRead(msg coordinationLedgerReadMsg) (model, tea.Cmd) {
	if msg.arc != m.coordinationDetail.Arc() {
		return m, nil
	}
	if msg.err != nil {
		m.coordinationDetail.SetLedger("", "", false)
		return m, nil
	}
	m.coordinationDetail.SetLedger(msg.content, msg.brief, msg.briefFound)
	return m, nil
}

// handleCoordinationPinRead pushes a derived pin state into the detail. An
// unreadable sidecar surfaces as its own state, never as silently-unpinned.
func (m model) handleCoordinationPinRead(msg coordinationPinReadMsg) (model, tea.Cmd) {
	if msg.arc != m.coordinationDetail.Arc() {
		return m, nil
	}
	if msg.err != nil {
		m.coordinationDetail.SetPinError(compactErr("pin sidecar", msg.err))
		return m, nil
	}
	m.coordinationDetail.SetPin(msg.status, msg.pin)
	return m, nil
}

// handleCoordinationMemberSelected carries an Items-tab drill-in into the work
// detail: it points the work list cursor at the member, loads its detail with
// the detail panel focused, and records the coordination view as the one-shot
// return target. The cursor set and the detail load are both explicit because
// the programmatic cursor move fires no onCursorChange hook.
func (m model) handleCoordinationMemberSelected(msg coordination.MemberSelectedMsg) (model, tea.Cmd) {
	m.state = stateWork
	m.focusedPanel = panelRight
	m.returnToCoordination = true
	m.list.SetCursorBySlug(msg.Slug)
	return m.loadDetail(msg.Slug)
}

// handleCoordinationSessionSelected carries a Sessions-tab drill-in into the
// sessions workspace: it points the sessions list cursor at the row, loads its
// detail card, applies the existing attach semantics (local live panel → terminal
// focus; otherwise the read-only card), and records the coordination view as the
// one-shot return target. The cursor set is paired with an explicit detail load
// for the same reason the work path is.
func (m model) handleCoordinationSessionSelected(msg coordination.SessionSelectedMsg) (model, tea.Cmd) {
	m.state = stateSessions
	m.returnToCoordination = true
	m.sessionsList.SetCursorByID(msg.RowID)
	m.loadSessionsDetail(msg.RowID)
	return m.handleSessionSelected(sessionview.SessionSelectedMsg{RowID: msg.RowID})
}

// returnToCoordinationView consumes the one-shot coordination return target:
// it re-enters the coordination workspace with the detail focused and refreshes
// the arc and session joins. Arc selection, active tab, and row cursors survive
// because they live in coordination model fields and its setters are
// identity-preserving (SetArcs by slug, SetArc same-arc no-op).
func (m model) returnToCoordinationView() (model, tea.Cmd) {
	m.returnToCoordination = false
	m.state = stateCoordination
	m.terminalMode = false
	m.focusedPanel = panelRight
	return m, tea.Batch(m.scanArcsCmd(), m.sessionsRefreshCmd())
}

// loadCoordinationDetail points the detail at the given arc, re-syncs the
// joins that derive from state already in memory, and kicks the disk reads
// (ledger + pin) so selection does not wait for the next poll tick.
func (m *model) loadCoordinationDetail(arc string) tea.Cmd {
	m.coordinationDetail.SetArc(arc)
	m.syncCoordinationMembers()
	m.syncCoordinationSessions()
	if arc == "" {
		return nil
	}
	return tea.Batch(readArcLedgerCmd(m.config.WorkDir, arc), m.readArcPinCmd(arc))
}

// syncCoordinationMembers pushes the selected arc's member items (and the
// index-wide active set their blocked state derives from) into the detail.
func (m *model) syncCoordinationMembers() {
	arc := m.coordinationDetail.Arc()
	if arc == "" {
		m.coordinationDetail.SetMembers(nil, nil)
		return
	}
	items := m.list.Items()
	var members []work.WorkItem
	for _, it := range items {
		if it.Project == arc {
			members = append(members, it)
		}
	}
	m.coordinationDetail.SetMembers(members, work.ActiveSlugs(items))
}

// syncCoordinationSessions recomputes the read-side session→arc join from the
// last substrate refresh and pushes the selected arc's rows into the detail.
// Nothing is persisted — the join lives for one render generation.
func (m *model) syncCoordinationSessions() {
	arc := m.coordinationDetail.Arc()
	if arc == "" {
		m.coordinationDetail.SetSessions(nil)
		return
	}
	var rows []sessionview.SessionRow
	for _, r := range m.sessionRows {
		if r.Project == arc {
			rows = append(rows, r)
		}
	}
	m.coordinationDetail.SetSessions(rows)
}
