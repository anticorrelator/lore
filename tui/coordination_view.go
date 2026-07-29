package main

import (
	"os"
	"path/filepath"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/coordination"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/sessionview"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// coordinationArcsScannedMsg carries one scan of the arc store: every usable
// record as its own row, plus the count of records the scan could not use.
type coordinationArcsScannedMsg struct {
	arcs    []coordination.Arc
	skipped int
}

// coordinationLedgerReadMsg carries one arc's coordination.md content plus the
// extracted ## Brief section, and — from the same read — the arc's report.md
// content. err leaves content empty so the Ledger tab renders the unreadable
// state explicitly; reportFound is true whenever report.md is present, even if
// unreadable. Closure is not part of this message: it is the arc record's
// declared status, which the host already holds.
type coordinationLedgerReadMsg struct {
	arc         string
	content     string
	brief       string
	briefFound  bool
	report      string
	reportFound bool
	err         error
}

// coordinationPinReadMsg carries one arc's derived pin state. Liveness is
// joined at read time against the registry TTL, never stored.
type coordinationPinReadMsg struct {
	arc    string
	status coordination.PinStatus
	pin    *coordination.Pin
	err    error
}

// scanArcStoreCmd reads the arc store off the UI thread. It is the view's
// sole arc source: one row per record, sectioned by the record's declared
// status. The scan rides every poll tick, so it stays a native read — one
// directory walk plus a small JSON parse per arc.
func (m model) scanArcStoreCmd() tea.Cmd {
	workDir := m.config.WorkDir
	return func() tea.Msg {
		arcs, skipped := coordination.ScanArcs(workDir)
		return coordinationArcsScannedMsg{arcs: arcs, skipped: skipped}
	}
}

// readArcLedgerCmd reads an arc's coordination.md and report.md off the UI
// thread and extracts the ledger's Brief. Reading both in one command yields a
// consistent snapshot. A present-but-unreadable report still reports
// reportFound so the detail renders its absence as a first-class dim state
// rather than dropping the tab.
func readArcLedgerCmd(workDir, arc string) tea.Cmd {
	return func() tea.Msg {
		dir := coordination.ArcDir(workDir, arc)
		msg := coordinationLedgerReadMsg{arc: arc}

		ledgerData, ledgerErr := os.ReadFile(filepath.Join(dir, "coordination.md"))
		if ledgerErr != nil {
			msg.err = ledgerErr
		} else {
			msg.content = string(ledgerData)
			msg.brief, msg.briefFound = work.ExtractSection(string(ledgerData), "Brief")
		}

		reportData, reportErr := os.ReadFile(filepath.Join(dir, "report.md"))
		switch {
		case reportErr == nil:
			msg.reportFound = true
			msg.report = string(reportData)
		case !os.IsNotExist(reportErr):
			msg.reportFound = true
		}
		return msg
	}
}

// readArcPinCmd reads the pin sidecar for the arc's project and derives its
// liveness by joining pin.instance against the registry's mtime TTL. The
// sidecar is project-scoped, so an arc with no project label has no pin home
// — reported as its own state rather than as an absent pin.
func (m model) readArcPinCmd(arc, project string) tea.Cmd {
	workDir := m.config.WorkDir
	sessionsDir := m.sessionsDir
	return func() tea.Msg {
		if project == "" {
			return coordinationPinReadMsg{arc: arc, status: coordination.PinNoProject}
		}
		pin, err := coordination.ReadPin(work.ProjectHome(workDir, project))
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
// cursor diff, not the raw index, drives detail sync. A same-identity scan
// still refreshes the joins, so membership edits land without a reselect.
//
// The same scan feeds the archive sweep, which rides the poll heartbeat from
// every application state so the tab count and the store agree whether or not
// the coordination tab is focused.
func (m model) handleCoordinationArcsScanned(msg coordinationArcsScannedMsg) (model, tea.Cmd) {
	m.coordinationList.SetArcs(msg.arcs, msg.skipped)
	sweep := m.startArcSweep(msg.arcs)
	if m.state == stateCoordination {
		if cur := m.coordinationList.CurrentSlug(); cur != m.coordinationDetail.Arc() {
			return m, tea.Batch(m.loadCoordinationDetail(cur), sweep)
		}
	}
	m.syncCoordinationArc()
	return m, sweep
}

// arcSweepSet returns the slugs this scan makes eligible for archiving: closed
// arcs more than a week past their latest declared instant that have not
// already been submitted this session.
//
// Two exclusions carry the binding constraints. A live arc is never eligible at
// any age — an arc still open past a week is exactly what the view exists to
// keep visible. An arc whose record declares no readable instant is never
// eligible either: archiving writes to the record, and an unreadable date is
// not evidence that the arc is old.
func (m model) arcSweepSet(arcs []coordination.Arc, now time.Time) []string {
	var slugs []string
	for _, a := range arcs {
		if a.Status != coordination.StatusClosed || !a.AgedOutAt(now) {
			continue
		}
		if m.arcSwept[a.Slug] {
			continue
		}
		slugs = append(slugs, a.Slug)
	}
	return slugs
}

// startArcSweep dispatches the archive for this scan's eligible arcs, returning
// nil when there is nothing to do. The write runs inside the returned command,
// off the update goroutine, and reports back as arcArchiveFinishedMsg.
//
// One sweep runs at a time and each slug is submitted at most once per session.
// The heartbeat rescans every few seconds while an arc stays closed until its
// archive lands, so an unguarded sweep would respawn the same subprocess on
// every tick. A slug whose archive failed stays in the submitted set: a refusal
// from `lore arc archive` is usually structural, so retrying it each tick would
// turn one readable error into an endless loop. The arc stays listed as closed,
// and the next launch retries it.
func (m *model) startArcSweep(arcs []coordination.Arc) tea.Cmd {
	if m.arcSweepInFlight {
		return nil
	}
	slugs := m.arcSweepSet(arcs, time.Now())
	if len(slugs) == 0 {
		return nil
	}
	if m.arcSwept == nil {
		m.arcSwept = make(map[string]bool, len(slugs))
	}
	for _, slug := range slugs {
		m.arcSwept[slug] = true
	}
	m.arcSweepInFlight = true
	return runArcArchive(slugs)
}

// handleCoordinationLedgerRead pushes a ledger read into the detail, dropping
// stale responses for a previously selected arc.
func (m model) handleCoordinationLedgerRead(msg coordinationLedgerReadMsg) (model, tea.Cmd) {
	if msg.arc != m.coordinationDetail.Arc() {
		return m, nil
	}
	if msg.err != nil {
		m.coordinationDetail.SetLedger("", "", false)
	} else {
		m.coordinationDetail.SetLedger(msg.content, msg.brief, msg.briefFound)
	}
	m.coordinationDetail.SetReport(msg.report, msg.reportFound)
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
	return m, tea.Batch(m.scanArcStoreCmd(), m.sessionsRefreshCmd())
}

// loadCoordinationDetail points the detail at the given arc, re-syncs the
// joins that derive from state already in memory, and kicks the disk reads
// (ledger + pin) so selection does not wait for the next poll tick.
func (m *model) loadCoordinationDetail(arc string) tea.Cmd {
	m.coordinationDetail.SetArc(arc)
	m.syncCoordinationArc()
	if arc == "" {
		return nil
	}
	project := ""
	if a, ok := m.coordinationList.ArcBySlug(arc); ok {
		project = a.Project
	}
	return tea.Batch(readArcLedgerCmd(m.config.WorkDir, arc), m.readArcPinCmd(arc, project))
}

// syncCoordinationArc pushes everything the selected arc's record decides:
// its closure and the two membership joins. All three read state already in
// memory, so they re-derive on any refresh without touching disk.
func (m *model) syncCoordinationArc() {
	arc, ok := m.coordinationList.ArcBySlug(m.coordinationDetail.Arc())
	m.coordinationDetail.SetClosed(ok && arc.Closed())
	m.syncCoordinationMembers()
	m.syncCoordinationSessions()
}

// syncCoordinationMembers joins the arc's declared members against the work
// index and pushes them into the detail, along with the index-wide active set
// their blocked state derives from. A member the index cannot resolve keeps
// its row, marked unresolved.
func (m *model) syncCoordinationMembers() {
	arc, ok := m.coordinationList.ArcBySlug(m.coordinationDetail.Arc())
	if !ok {
		m.coordinationDetail.SetMembers(nil, nil)
		return
	}
	items := m.list.Items()
	bySlug := make(map[string]work.WorkItem, len(items))
	for _, it := range items {
		bySlug[it.Slug] = it
	}
	members := make([]coordination.Member, 0, len(arc.Members))
	for _, slug := range arc.Members {
		if it, found := bySlug[slug]; found {
			members = append(members, coordination.Member{Slug: slug, Item: it, Resolved: true})
		} else {
			members = append(members, coordination.Member{Slug: slug})
		}
	}
	m.coordinationDetail.SetMembers(members, work.ActiveSlugs(items))
}

// syncCoordinationSessions recomputes the read-side session→arc join from the
// last substrate refresh and pushes the selected arc's rows into the detail.
// A session belongs to an arc when the arc declares its slug — or, for a
// derived-slug worker, its base item. Nothing is persisted; the join lives for
// one render generation.
func (m *model) syncCoordinationSessions() {
	arc, ok := m.coordinationList.ArcBySlug(m.coordinationDetail.Arc())
	if !ok {
		m.coordinationDetail.SetSessions(nil)
		return
	}
	member := make(map[string]bool, len(arc.Members))
	for _, slug := range arc.Members {
		member[slug] = true
	}
	var rows []sessionview.SessionRow
	for _, r := range m.sessionRows {
		if member[r.Slug] || (r.BaseItem != "" && member[r.BaseItem]) {
			rows = append(rows, r)
		}
	}
	m.coordinationDetail.SetSessions(rows)
}
