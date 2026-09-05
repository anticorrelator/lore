package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync/atomic"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/coordination"
	"github.com/anticorrelator/lore/tui/internal/coordination/board"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/sessionview"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// coordinationArcsScannedMsg carries one scan of the arc store: every usable
// record as its own row, plus the count of records the scan could not use.
type coordinationArcsScannedMsg struct {
	arcs          []coordination.Arc
	skipped       int
	snapshot      *board.Snapshot
	err           error
	request       uint64
	selection     uint64
	arc           string
	documents     *coordinationLedgerReadMsg
	documentToken string
	packets       map[string]string
}

// coordinationLedgerReadMsg carries one arc's coordination.md content plus the
// extracted ## Brief section, and — from the same read — digest.md and
// report.md. err leaves content empty so the Ledger tab renders the unreadable
// state explicitly; document found flags remain true for present-but-unreadable
// files. Closure is not part of this message: it is the arc record's declared
// status, which the host already holds.
type coordinationLedgerReadMsg struct {
	arc         string
	content     string
	brief       string
	briefFound  bool
	report      string
	reportFound bool
	digest      string
	digestFound bool
	err         error
}

// coordinationBodyReadMsg carries one fresh board and ticker generation for
// the selected arc, plus per-arc activity derived from that same journal read.
// Packet bodies are present only for explicit references that remained inside
// the arc directory and were readable at this tick.
type coordinationBodyReadMsg struct {
	arc        string
	rows       []board.Row
	boardFound bool
	boardErr   error
	events     []session.Event
	activity   map[string]string
	packets    map[string]string
}

// coordinationAttentionReadMsg carries one fresh cross-arc action projection.
// All four buckets are present on success, including empty ones.
type coordinationAttentionReadMsg struct {
	attention board.Attention
	err       error
}

type coordinationReadState struct {
	inFlight atomic.Bool
	request  atomic.Uint64
}

type coordinationRetryMsg struct{}

func (m *model) scanArcStoreCmd() tea.Cmd {
	if m.coordinationRead == nil {
		m.coordinationRead = &coordinationReadState{}
	}
	gate := m.coordinationRead
	if !gate.inFlight.CompareAndSwap(false, true) {
		return nil
	}
	request := gate.request.Add(1)
	arc, selection := m.coordinationDetail.Arc(), m.coordinationSelection
	workDir, token := m.config.WorkDir, m.coordinationDocumentToken
	store := m.config.KnowledgeDir
	if store == "" {
		store = filepath.Dir(workDir)
	}
	return func() tea.Msg {
		defer gate.inFlight.Store(false)
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		snapshot, err := board.LoadSnapshot(ctx, store, arc)
		msg := coordinationArcsScannedMsg{snapshot: &snapshot, err: err, request: request, selection: selection, arc: arc}
		if err != nil {
			return msg
		}
		for _, a := range snapshot.Arcs {
			msg.arcs = append(msg.arcs, coordination.Arc{Slug: a.Slug, Title: a.Title, Status: a.Status, Project: a.Project,
				Members: a.Members, Opened: a.Opened, ClosedAt: a.ClosedAt})
		}
		sort.Slice(msg.arcs, func(i, j int) bool {
			if msg.arcs[i].Recency() == msg.arcs[j].Recency() {
				return msg.arcs[i].Slug > msg.arcs[j].Slug
			}
			return msg.arcs[i].Recency() > msg.arcs[j].Recency()
		})
		msg.skipped = snapshot.Skipped
		if arc != "" && snapshot.Details[arc].Loaded {
			paths := []string{"coordination.md", "digest.md", "report.md"}
			for _, row := range snapshot.Rows {
				if row.ReviewPacket != nil {
					paths = append(paths, *row.ReviewPacket)
				}
			}
			var signatures strings.Builder
			for _, path := range paths {
				info, err := os.Stat(filepath.Join(coordination.ArcDir(workDir, arc), path))
				if err != nil {
					fmt.Fprintf(&signatures, "%s:%v;", path, err)
				} else {
					fmt.Fprintf(&signatures, "%s:%d:%d;", path, info.Size(), info.ModTime().UnixNano())
				}
			}
			msg.documentToken = arc + signatures.String()
			if msg.documentToken != token {
				documents := readArcLedgerCmd(workDir, arc)().(coordinationLedgerReadMsg)
				msg.documents = &documents
				msg.packets = make(map[string]string)
				for _, row := range snapshot.Rows {
					if row.ReviewPacket != nil {
						if body, ok := coordination.ReadReviewPacket(workDir, arc, *row.ReviewPacket); ok {
							msg.packets[*row.ReviewPacket] = body
						}
					}
				}
			}
		}
		return msg
	}
}

// readArcLedgerCmd reads an arc's coordination.md, digest.md, and report.md off
// the UI thread and extracts the ledger's Brief. Reading all three in one
// command yields a consistent snapshot. Present-but-unreadable documents keep
// their found flag so detail can distinguish them from absent files.
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

		digestData, digestErr := os.ReadFile(filepath.Join(dir, "digest.md"))
		switch {
		case digestErr == nil:
			msg.digestFound = true
			msg.digest = string(digestData)
		case !os.IsNotExist(digestErr):
			msg.digestFound = true
		}
		return msg
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
	if msg.request != 0 {
		if m.coordinationRead != nil && msg.request < m.coordinationRead.request.Load() {
			return m, nil
		}
		if msg.selection != m.coordinationSelection {
			return m, m.scanArcStoreCmd()
		}
		if msg.err != nil {
			m.coordinationList.SetCoverage("stale — " + msg.err.Error())
			m.coordinationDetail.SetCoverage("stale — " + msg.err.Error())
			return m, tea.Tick(time.Second, func(time.Time) tea.Msg { return coordinationRetryMsg{} })
		}
		snapshot := msg.snapshot
		if snapshot.Epoch == m.coordinationEpoch && snapshot.Generation < m.coordinationGeneration {
			return m, nil
		}
		m.coordinationEpoch, m.coordinationGeneration = snapshot.Epoch, snapshot.Generation
		m.coordinationArchiveWanted = snapshot.ArchiveIdentity
		coverage := ""
		if snapshot.Coverage.State != "ready" {
			coverage = snapshot.Coverage.State + " — observed " + snapshot.Coverage.ObservedAt
		}
		if msg.arc != "" && !snapshot.Details[msg.arc].Loaded {
			coverage = "loading selected arc — showing last available state"
		}
		m.coordinationList.SetCoverage(coverage)
		m.coordinationDetail.SetCoverage(coverage)
		m.coordinationList.SetAttention(snapshot.Attention, nil)
		m.coordinationList.SetAttentionActivity(snapshot.Activity)
		if msg.arc != "" && snapshot.Details[msg.arc].Loaded {
			body := coordinationBodyReadMsg{arc: msg.arc, rows: snapshot.Rows, boardFound: snapshot.Found,
				events: snapshot.Details[msg.arc].Events, activity: snapshot.Activity}
			if detailError := snapshot.Details[msg.arc].Error; detailError != "" {
				body.boardErr = fmt.Errorf("%s", detailError)
			}
			if msg.documents != nil {
				body.packets = msg.packets
			}
			m, _ = m.handleCoordinationBodyRead(body)
		}
		if msg.documents != nil {
			m, _ = m.handleCoordinationLedgerRead(*msg.documents)
			m.coordinationDocumentToken = msg.documentToken
		}
	}
	active := work.ActiveSlugs(m.list.Items())
	for i := range msg.arcs {
		if msg.snapshot != nil {
			for _, member := range msg.arcs[i].Members {
				if active[member] {
					msg.arcs[i].Items++
				}
			}
		}
	}
	if m.coordinationList.ShowArchived() {
		msg.arcs = mergeCoordinationArchive(msg.arcs, m.coordinationArchived)
	}
	m.coordinationList.SetArcs(msg.arcs, msg.skipped)
	var activeMembers []string
	for _, arc := range msg.arcs {
		if arc.Status == coordination.StatusActive {
			activeMembers = append(activeMembers, arc.Members...)
		}
	}
	// The sessions workspace is a presentation over the same in-memory arc
	// scan. Only declared members of active arcs collapse; an empty/failed scan
	// passes an empty set and restores the complete listing.
	m.sessionsList.SetActiveArcMembers(activeMembers)
	if m.state == stateSessions {
		m.loadSessionsDetail(m.sessionsList.CurrentKey())
	}
	cmds := []tea.Cmd{m.startArcSweep(msg.arcs)}
	if m.coordinationList.ShowArchived() {
		cmds = append(cmds, m.loadCoordinationArchiveCmd())
	}
	if msg.snapshot != nil && ((msg.snapshot.Coverage.State == "catching-up" || msg.snapshot.Coverage.State == "rebuilding" || msg.snapshot.Coverage.State == "stale") || (msg.arc != "" && !msg.snapshot.Details[msg.arc].Loaded)) {
		cmds = append(cmds, tea.Tick(time.Second, func(time.Time) tea.Msg { return coordinationRetryMsg{} }))
	}
	if m.state == stateCoordination {
		if target := m.coordinationJump; target != nil {
			if _, ok := m.coordinationList.ArcBySlug(target.Arc); !ok {
				m.coordinationTargetIssue = fmt.Sprintf("attention target stale/unknown — arc %s is absent", target.Arc)
			}
			m.syncCoordinationArc()
			return m, tea.Batch(cmds...)
		}
		if cur := m.coordinationList.CurrentSlug(); cur != m.coordinationDetail.Arc() {
			cmds = append(cmds, m.loadCoordinationDetail(cur))
			return m, tea.Batch(cmds...)
		}
	}
	m.syncCoordinationArc()
	return m, tea.Batch(cmds...)
}

func (m model) handleCoordinationAttentionRead(msg coordinationAttentionReadMsg) (model, tea.Cmd) {
	m.coordinationList.SetAttention(msg.attention, msg.err)
	return m, nil
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
	return runArcArchiveVerified(m.config.WorkDir, slugs)
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
	m.coordinationDetail.SetDigest(msg.digest, msg.digestFound)
	return m, nil
}

// handleCoordinationBodyRead applies only the generation addressed to the
// currently selected arc; a late board subprocess or journal read is dropped.
func (m model) handleCoordinationBodyRead(msg coordinationBodyReadMsg) (model, tea.Cmd) {
	m.coordinationList.SetAttentionActivity(msg.activity)
	if msg.arc != m.coordinationDetail.Arc() {
		return m, nil
	}
	if target := m.coordinationJump; target != nil && target.Arc == msg.arc {
		if msg.boardErr != nil {
			m.coordinationDetail.SetBoard(nil, false, msg.boardErr)
			m.coordinationTargetIssue = fmt.Sprintf("attention target unknown — %s/%s could not be verified", target.Arc, target.StreamID)
		} else {
			found := false
			for _, row := range msg.rows {
				if row.Arc == target.Arc && row.StreamID == target.StreamID {
					found = true
					break
				}
			}
			if !found {
				if len(msg.rows) == 0 {
					m.coordinationDetail.SetBoard(nil, msg.boardFound, nil)
				}
				m.coordinationTargetIssue = fmt.Sprintf("attention target stale/unknown — stream %s is absent from arc %s", target.StreamID, target.Arc)
			} else {
				m.coordinationDetail.SetBoard(msg.rows, msg.boardFound, nil)
				if m.coordinationDetail.SelectStream(target.StreamID) {
					m.coordinationTargetIssue = ""
				}
			}
		}
		m.coordinationDetail.SetEvents(msg.events)
		if msg.packets != nil {
			m.coordinationDetail.SetReviewPackets(msg.packets)
		}
		return m, m.coordinationDetail.StartMarquee()
	}
	m.coordinationDetail.SetBoard(msg.rows, msg.boardFound, msg.boardErr)
	m.coordinationDetail.SetEvents(msg.events)
	if msg.packets != nil {
		m.coordinationDetail.SetReviewPackets(msg.packets)
	}
	return m, m.coordinationDetail.StartMarquee()
}

func (m model) handleCoordinationAttentionSelected(msg coordination.AttentionSelectedMsg) (model, tea.Cmd) {
	m.focusedPanel = panelRight
	m.coordinationList.ShowArcs()
	m.coordinationJump = &msg
	m.coordinationTargetIssue = ""
	m.coordinationDetail.SetBoard(nil, false, nil)
	if !m.coordinationList.SetCursorBySlug(msg.Arc) {
		m.coordinationTargetIssue = fmt.Sprintf("attention target stale/unknown — arc %s is not in the visible arc list", msg.Arc)
	}
	return m, m.loadCoordinationDetail(msg.Arc)
}

// handleCoordinationMemberSelected carries a declared stream target into work
// detail: it points the work list cursor at the member, loads its detail with
// the detail panel focused, and records the coordination view as the one-shot
// return target. The cursor set and the detail load are both explicit because
// the programmatic cursor move fires no onCursorChange hook.
func (m model) handleCoordinationMemberSelected(msg coordination.MemberSelectedMsg) (model, tea.Cmd) {
	m.coordinationDetail.StopMarquee()
	m.state = stateWork
	m.focusedPanel = panelRight
	m.returnToCoordination = true
	m.list.SetCursorBySlug(msg.Slug)
	return m.loadDetail(msg.Slug)
}

// handleCoordinationSessionSelected carries a declared stream target into the
// sessions workspace: it points the sessions list cursor at the row, loads its
// detail card, applies the sessions workspace's local-panel or remote-mirror
// routing, and records the coordination view as the one-shot return target. The
// cursor set is paired with an explicit detail load for the same reason the work
// path is.
func (m model) handleCoordinationSessionSelected(msg coordination.SessionSelectedMsg) (model, tea.Cmd) {
	m.coordinationDetail.StopMarquee()
	m.state = stateSessions
	m.returnToCoordination = true
	m.sessionsList.SetCursorByID(msg.RowID)
	m.loadSessionsDetail(msg.RowID)
	return m.handleSessionSelected(sessionview.SessionSelectedMsg{RowID: msg.RowID})
}

// returnToCoordinationView consumes the one-shot coordination return target:
// it re-enters the coordination workspace with the detail focused and refreshes
// the arc and session joins. Arc and stream selection survive
// because they live in coordination model fields and its setters are
// identity-preserving (SetArcs by slug, SetArc same-arc no-op).
func (m model) returnToCoordinationView() (model, tea.Cmd) {
	m.returnToCoordination = false
	m.state = stateCoordination
	m.terminalMode = false
	m.focusedPanel = panelRight
	return m, tea.Batch(m.scanArcStoreCmd(), m.sessionsRefreshCmd(), m.coordinationDetail.StartMarquee())
}

// loadCoordinationDetail points the detail at the given arc, re-syncs the
// joins that derive from state already in memory, and kicks the disk reads
// (ledger + integrated body) so selection does not wait for the next poll tick.
func (m *model) loadCoordinationDetail(arc string) tea.Cmd {
	m.coordinationSelection++
	m.coordinationDocumentToken = ""
	m.coordinationDetail.SetArc(arc)
	m.coordinationDetail.SetCoverage("loading")
	m.syncCoordinationArc()
	return m.scanArcStoreCmd()
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

type coordinationArchiveLoadedMsg struct {
	identity string
	arcs     []coordination.Arc
	err      error
}

func mergeCoordinationArchive(current, archived []coordination.Arc) []coordination.Arc {
	bySlug := make(map[string]coordination.Arc)
	for _, arc := range archived {
		bySlug[arc.Slug] = arc
	}
	for _, arc := range current {
		bySlug[arc.Slug] = arc
	}
	arcs := make([]coordination.Arc, 0, len(bySlug))
	for _, arc := range bySlug {
		arcs = append(arcs, arc)
	}
	sort.Slice(arcs, func(i, j int) bool {
		if arcs[i].Recency() == arcs[j].Recency() {
			return arcs[i].Slug > arcs[j].Slug
		}
		return arcs[i].Recency() > arcs[j].Recency()
	})
	return arcs
}

func (m *model) loadCoordinationArchiveCmd() tea.Cmd {
	if m.coordinationArchiveLoading {
		return nil
	}
	if m.coordinationArchiveWanted == "" {
		m.coordinationList.SetArchiveCoverage("loading archived arcs")
		return nil
	}
	if m.coordinationArchiveIdentity == m.coordinationArchiveWanted {
		m.coordinationList.SetArchiveCoverage("")
		m.coordinationList.SetArcs(mergeCoordinationArchive(m.coordinationList.Arcs(), m.coordinationArchived), 0)
		if cur := m.coordinationList.CurrentSlug(); cur != m.coordinationDetail.Arc() {
			return m.loadCoordinationDetail(cur)
		}
		return nil
	}
	m.coordinationArchiveLoading = true
	m.coordinationList.SetArchiveCoverage("loading archived arcs")
	identity, store := m.coordinationArchiveWanted, m.config.KnowledgeDir
	if store == "" {
		store = filepath.Dir(m.config.WorkDir)
	}
	return func() tea.Msg {
		msg := coordinationArchiveLoadedMsg{identity: identity}
		data, err := os.ReadFile(filepath.Join(store, "_coordination", "display-archive.json"))
		if err != nil {
			msg.err = err
			return msg
		}
		var catalog struct {
			Store    string             `json:"store"`
			Identity string             `json:"identity"`
			Arcs     []coordination.Arc `json:"arcs"`
		}
		err = json.Unmarshal(data, &catalog)
		resolved, _ := filepath.EvalSymlinks(store)
		resolved, _ = filepath.Abs(resolved)
		if err == nil && (catalog.Identity != identity || catalog.Store != resolved) {
			err = fmt.Errorf("archive catalog changed during read")
		}
		msg.arcs, msg.err = catalog.Arcs, err
		return msg
	}
}

func (m model) handleCoordinationArchiveLoaded(msg coordinationArchiveLoadedMsg) (model, tea.Cmd) {
	m.coordinationArchiveLoading = false
	if msg.identity != m.coordinationArchiveWanted {
		return m, nil
	}
	if msg.err != nil {
		m.coordinationList.SetArchiveCoverage("archive stale — " + msg.err.Error())
		return m, nil
	}
	m.coordinationArchiveIdentity, m.coordinationArchived = msg.identity, msg.arcs
	m.coordinationList.SetArchiveCoverage("")
	if m.coordinationList.ShowArchived() {
		var current []coordination.Arc
		for _, arc := range m.coordinationList.Arcs() {
			if arc.Status != coordination.StatusArchived {
				current = append(current, arc)
			}
		}
		m.coordinationList.SetArcs(mergeCoordinationArchive(current, msg.arcs), 0)
		if cur := m.coordinationList.CurrentSlug(); cur != m.coordinationDetail.Arc() {
			return m, m.loadCoordinationDetail(cur)
		}
	}
	return m, nil
}
