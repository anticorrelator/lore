package main

import (
	"errors"
	"os"
	"path/filepath"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/followup"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// indexPollTickMsg fires every 5 seconds to trigger an mtime check on _index.json.
type indexPollTickMsg struct{}

// sessionMirrorCapturedMsg carries a client-less capture-pane snapshot of a
// remote tmux-hosted session's visible screen for the read-only mirror card.
type sessionMirrorCapturedMsg struct {
	rowID    string
	tmuxName string
	lines    []string
	err      error
}

// captureSessionMirrorCmd captures a remote session's visible tmux screen off the
// UI thread. rowID/tmuxName are snapshotted at Cmd-build time; the handler drops a
// snapshot whose row no longer matches, so a capture landing after the cursor
// moved never paints under the wrong session. The capture attaches no client and
// so cannot perturb the owning instance's screen-state contract.
func captureSessionMirrorCmd(rowID, tmuxName string) tea.Cmd {
	return func() tea.Msg {
		lines, err := work.CapturePaneScreen(tmuxName)
		return sessionMirrorCapturedMsg{rowID: rowID, tmuxName: tmuxName, lines: lines, err: err}
	}
}

// handleSessionMirrorCaptured pushes a fresh remote-screen snapshot into the
// read-only card. A capture error leaves the prior frame in place rather than
// blanking the mirror mid-session; SetMirror itself drops a stale-row snapshot,
// so pushing to both mirror consumers is safe — at most one displays the row.
func (m model) handleSessionMirrorCaptured(msg sessionMirrorCapturedMsg) (model, tea.Cmd) {
	if msg.err != nil {
		return m, nil
	}
	m.sessionsDetail.SetMirror(msg.rowID, msg.lines)
	m.coordinationDetail.SetMirror(msg.rowID, msg.lines)
	return m, nil
}

func indexPollTick() tea.Cmd {
	return tea.Tick(5*time.Second, func(time.Time) tea.Msg { return indexPollTickMsg{} })
}

// settlementHiddenPollInterval is the background heartbeat the settlement
// status poll drops to while its panel is hidden. It must never reach zero:
// auto-process dispatch and the trigger pump both ride the status result, so a
// stalled poll would halt the live drain. 60s matches the drain's own cadence,
// so a hidden badge is at most one heartbeat stale.
const settlementHiddenPollInterval = 60 * time.Second

// indexMtimeCheckedMsg carries the result of stat-ing the index file.
type indexMtimeCheckedMsg struct {
	mtime time.Time
	err   error
}

// checkIndexMtime returns a Cmd that stats the index file and sends the mtime back.
func checkIndexMtime(path string) tea.Cmd {
	return func() tea.Msg {
		info, err := os.Stat(path)
		if err != nil {
			return indexMtimeCheckedMsg{err: err}
		}
		return indexMtimeCheckedMsg{mtime: info.ModTime()}
	}
}

// planMtimeCheckedMsg carries the result of stat-ing a work item's plan.md.
type planMtimeCheckedMsg struct {
	slug  string
	mtime time.Time
	err   error
}

// detailMtimeCheckedMsg carries the result of stat-ing a work item's detail files.
type detailMtimeCheckedMsg struct {
	slug  string
	mtime time.Time
	err   error
}

// planContentReadMsg carries freshly-read plan.md content for an in-place refresh.
type planContentReadMsg struct {
	slug    string
	content string
}

// checkPlanMtime stats plan.md for the given slug and sends planMtimeCheckedMsg.
func checkPlanMtime(workDir, slug string) tea.Cmd {
	return func() tea.Msg {
		p := filepath.Join(workDir, slug, "plan.md")
		info, err := os.Stat(p)
		if err != nil {
			return planMtimeCheckedMsg{slug: slug, err: err}
		}
		return planMtimeCheckedMsg{slug: slug, mtime: info.ModTime()}
	}
}

// checkDetailMtime stats _meta.json, notes.md, execution-log.md, and tasks.json
// for the given slug and sends detailMtimeCheckedMsg with the most recent mtime.
func checkDetailMtime(workDir, slug string) tea.Cmd {
	return func() tea.Msg {
		dir := filepath.Join(workDir, slug)
		files := []string{"_meta.json", "notes.md", "execution-log.md", "tasks.json"}
		var maxMtime time.Time
		for _, f := range files {
			info, err := os.Stat(filepath.Join(dir, f))
			if err != nil {
				continue // file may not exist yet
			}
			if mt := info.ModTime(); mt.After(maxMtime) {
				maxMtime = mt
			}
		}
		if maxMtime.IsZero() {
			return detailMtimeCheckedMsg{slug: slug, err: errors.New("no detail files found")}
		}
		return detailMtimeCheckedMsg{slug: slug, mtime: maxMtime}
	}
}

// projectDetailMtimeCheckedMsg carries the result of stat-ing a project home's files.
type projectDetailMtimeCheckedMsg struct {
	slug  string
	mtime time.Time
	err   error
}

// checkProjectDetailMtime stats the files under _projects/<slug>/ and sends
// projectDetailMtimeCheckedMsg with the most recent mtime, so an external edit
// (or a doc added/removed) to the home refreshes the open detail within a tick.
func checkProjectDetailMtime(workDir, slug string) tea.Cmd {
	return func() tea.Msg {
		dir := work.ProjectHome(workDir, slug)
		entries, err := os.ReadDir(dir)
		if err != nil {
			return projectDetailMtimeCheckedMsg{slug: slug, err: err}
		}
		var maxMtime time.Time
		for _, entry := range entries {
			info, err := entry.Info()
			if err != nil {
				continue
			}
			if mt := info.ModTime(); mt.After(maxMtime) {
				maxMtime = mt
			}
		}
		if maxMtime.IsZero() {
			return projectDetailMtimeCheckedMsg{slug: slug, err: errors.New("no project home files found")}
		}
		return projectDetailMtimeCheckedMsg{slug: slug, mtime: maxMtime}
	}
}

// followupDetailMtimeCheckedMsg carries the result of stat-ing a follow-up item's detail file.
type followupDetailMtimeCheckedMsg struct {
	id    string
	mtime time.Time
	err   error
}

// followupIndexMtimeCheckedMsg carries the result of stat-ing _followup_index.json.
type followupIndexMtimeCheckedMsg struct {
	mtime time.Time
	err   error
}

// checkFollowupIndexMtime stats _followup_index.json and sends followupIndexMtimeCheckedMsg.
func checkFollowupIndexMtime(knowledgeDir string) tea.Cmd {
	return func() tea.Msg {
		p := filepath.Join(knowledgeDir, "_followup_index.json")
		info, err := os.Stat(p)
		if err != nil {
			return followupIndexMtimeCheckedMsg{err: err}
		}
		return followupIndexMtimeCheckedMsg{mtime: info.ModTime()}
	}
}

// checkFollowupDetailMtime stats sidecar files in the follow-up item's directory
// and sends followupDetailMtimeCheckedMsg with the most recent mtime.
func checkFollowupDetailMtime(knowledgeDir, id string) tea.Cmd {
	return func() tea.Msg {
		dir, err := followup.ResolveDir(knowledgeDir, id)
		if err != nil {
			return followupDetailMtimeCheckedMsg{id: id, err: err}
		}
		files := []string{"_meta.json", "finding.md", "lens-findings.json"}
		var maxMtime time.Time
		for _, f := range files {
			info, err := os.Stat(filepath.Join(dir, f))
			if err != nil {
				continue // file may not exist yet
			}
			if mt := info.ModTime(); mt.After(maxMtime) {
				maxMtime = mt
			}
		}
		if maxMtime.IsZero() {
			return followupDetailMtimeCheckedMsg{id: id, err: errors.New("no detail files found")}
		}
		return followupDetailMtimeCheckedMsg{id: id, mtime: maxMtime}
	}
}

// readPlanContent reads plan.md for the given slug and sends planContentReadMsg.
func readPlanContent(workDir, slug string) tea.Cmd {
	return func() tea.Msg {
		data, err := os.ReadFile(filepath.Join(workDir, slug, "plan.md"))
		if err != nil {
			return planContentReadMsg{slug: slug}
		}
		return planContentReadMsg{slug: slug, content: string(data)}
	}
}

// shouldPollSettlement decides whether this poll tick spawns the settlement
// status subprocess pair. Visible panel: every tick. Hidden panel: only once
// settlementHiddenPollInterval has elapsed since the last poll — and always on
// the first tick, when lastSettlementPoll is still zero. It never returns a
// standing false: the poll is the sole driver of auto-process dispatch and the
// trigger pump, so a hidden panel throttles it but must not stop it.
func (m model) shouldPollSettlement() bool {
	if m.state == stateSettlement {
		return true
	}
	if m.lastSettlementPoll.IsZero() {
		return true
	}
	return time.Since(m.lastSettlementPoll) >= settlementHiddenPollInterval
}

// handleIndexPollTick handles the periodic poll tick: schedules mtime checks, touches
// session files for active spec panels, and kicks off a new tick.
func (m model) handleIndexPollTick() (model, tea.Cmd) {
	// Defensive: clear a stuck settlementProcessInFlight flag if its
	// subprocess goroutine never returned. Without this, the auto-process
	// loop would be silently gated for the rest of the TUI session.
	m, _ = m.settlementInFlightFailsafe()
	cmds := []tea.Cmd{checkIndexMtime(m.indexPath), indexPollTick()}
	// Settlement status rides this heartbeat on a visibility-dependent cadence
	// (see shouldPollSettlement). The subprocess spawn and parse stay inside
	// loadSettlementStatus's Cmd; only the cadence bookkeeping lives here.
	if m.shouldPollSettlement() {
		m.lastSettlementPoll = time.Now()
		cmds = append(cmds, loadSettlementStatus())
	}
	// Poll plan.md and detail files for the current item on every tick.
	if slug := m.list.CurrentSlug(); slug != "" {
		cmds = append(cmds, checkPlanMtime(m.config.WorkDir, slug))
		cmds = append(cmds, checkDetailMtime(m.config.WorkDir, slug))
	}
	// When a project header drives the detail pane, ride the same heartbeat to
	// stat its home so overview.md edits refresh live. No home to stat for the
	// ungrouped bucket (empty slug), so it is skipped.
	if m.detail.IsProject() {
		if ps := m.detail.ProjectSlug(); ps != "" {
			cmds = append(cmds, checkProjectDetailMtime(m.config.WorkDir, ps))
		}
	}
	// Cross-instance read-only mirror: while a remote tmux-hosted session's card
	// is displayed, capture its visible screen on this same heartbeat. Visibility-
	// scoped — RemoteMirror returns false for a hidden card, a local panel, an
	// in-flight spawn, or a direct-PTY row — so the capture-pane subprocess cost is
	// proportional to what the user is actually watching. No second tick loop.
	if m.state == stateSessions && m.tmuxEnabled {
		if rowID, tmuxName, ok := m.sessionsDetail.RemoteMirror(); ok {
			cmds = append(cmds, captureSessionMirrorCmd(rowID, tmuxName))
		}
	}
	// Coordination arcs ride this same heartbeat: the existence fold is one
	// stat per project label (cheap from any state) so the tab count stays
	// current; ledger and pin reads are scoped to the selected arc while the
	// view is displayed, and the mirror capture to a displayed remote row.
	cmds = append(cmds, m.scanArcsCmd())
	if m.state == stateCoordination {
		if arc := m.coordinationList.CurrentSlug(); arc != "" {
			cmds = append(cmds, readArcLedgerCmd(m.config.WorkDir, arc), m.readArcPinCmd(arc))
		}
		if m.tmuxEnabled {
			if rowID, tmuxName, ok := m.coordinationDetail.RemoteMirror(); ok {
				cmds = append(cmds, captureSessionMirrorCmd(rowID, tmuxName))
			}
		}
	}
	// Always poll the follow-up index so the tab indicator reflects external
	// mutations even while the user is on the work tab.
	cmds = append(cmds, checkFollowupIndexMtime(m.config.KnowledgeDir))
	// Poll the current follow-up detail only while viewing it.
	if m.state == stateFollowUps {
		if id := m.followupList.CurrentID(); id != "" {
			cmds = append(cmds, checkFollowupDetailMtime(m.config.KnowledgeDir, id))
		}
	}
	// Session substrate: heartbeat our registry file, refresh the external-
	// session snapshot for badging, run one reclaim/claim queue pass, and scan
	// for close-requests addressed to us. Guarded on a resolved instance identity
	// (present only inside a real repo). The close scan rides this one heartbeat
	// — no second tick loop.
	if m.instanceName != "" {
		hosted := make(map[string]bool, len(m.localSessions))
		for slug := range m.localSessions {
			hosted[slug] = true
		}
		// The id→slug snapshot lets a session-addressed close-request resolve to the
		// exact session it named (see resolveCloseTargetSlug); snapshotted here at
		// Cmd-build time alongside hosted, read live inside the scan Cmd.
		closeIDToSlug := sessionIDIndex(m.localSessions)
		cmds = append(cmds, m.syncInstanceCmd(), readInstancesCmd(m.sessionsDir), m.queueTickCmd(),
			scanCloseRequestsCmd(m.sessionsDir, m.instanceName, hosted, closeIDToSlug),
			scanSendRequestsCmd(m.sessionsDir, m.instanceName, hosted),
			scanAnswerRequestsCmd(m.sessionsDir, m.instanceName, hosted),
			scanPeekRequestsCmd(m.sessionsDir, m.instanceName, hosted),
			m.sessionsRefreshCmd())
		// Re-evaluate any close-request already waiting on quiescence.
		var advCmds []tea.Cmd
		m, advCmds = m.advanceCloseLadders()
		cmds = append(cmds, advCmds...)
		// Re-observe any gate-passing send whose outcome is deferred until it can
		// confirm the composer submitted.
		var sendCmds []tea.Cmd
		m, sendCmds = m.advanceSendVerifications()
		cmds = append(cmds, sendCmds...)
		// Confirm modal answers only after a later screen no longer contains the
		// request's expectation. Answer keys are never replayed.
		var answerCmds []tea.Cmd
		m, answerCmds = m.advanceAnswerVerifications()
		cmds = append(cmds, answerCmds...)
		// Observe modal-entry edges on the same heartbeat and Bubble Tea goroutine
		// as the other screen consumers. The returned append commands do the disk
		// write asynchronously through the sole journal writer.
		var modalCmds []tea.Cmd
		m, modalCmds = m.advanceModalObservations()
		cmds = append(cmds, modalCmds...)
	}
	return m, tea.Batch(cmds...)
}

// handleIndexMtimeChecked compares the new index mtime against the last known value
// and triggers a work-item reload when the file has changed.
func (m model) handleIndexMtimeChecked(msg indexMtimeCheckedMsg) (model, tea.Cmd) {
	if msg.err != nil {
		return m, nil // skip on error, retry next tick
	}
	if m.lastIndexMtime.IsZero() {
		m.lastIndexMtime = msg.mtime // baseline initialization
		return m, nil
	}
	if !msg.mtime.Equal(m.lastIndexMtime) {
		m.lastIndexMtime = msg.mtime
		return m, loadWorkItems(m.config.WorkDir)
	}
	return m, nil
}

// handleFollowupIndexMtimeChecked compares the follow-up index mtime and reloads
// the follow-up index when the file has changed.
func (m model) handleFollowupIndexMtimeChecked(msg followupIndexMtimeCheckedMsg) (model, tea.Cmd) {
	if msg.err != nil {
		return m, nil // index may not exist yet; skip
	}
	if m.lastFollowupIndexMtime.IsZero() {
		m.lastFollowupIndexMtime = msg.mtime // baseline
		return m, nil
	}
	if !msg.mtime.Equal(m.lastFollowupIndexMtime) {
		m.lastFollowupIndexMtime = msg.mtime
		return m, followup.LoadIndexCmd(m.config.KnowledgeDir)
	}
	return m, nil
}

// handlePlanMtimeChecked compares plan.md mtime and triggers a content read when changed.
func (m model) handlePlanMtimeChecked(msg planMtimeCheckedMsg) (model, tea.Cmd) {
	if msg.err != nil || msg.slug != m.list.CurrentSlug() {
		return m, nil
	}
	prev := m.lastPlanMtime
	m.lastPlanMtime = msg.mtime
	if prev.IsZero() || !msg.mtime.Equal(prev) {
		// First appearance OR mtime changed — read and push to detail view.
		return m, readPlanContent(m.config.WorkDir, msg.slug)
	}
	return m, nil
}

// handlePlanContentRead pushes freshly-read plan.md content into the detail view.
func (m model) handlePlanContentRead(msg planContentReadMsg) (model, tea.Cmd) {
	if msg.slug != m.list.CurrentSlug() || msg.content == "" {
		return m, nil
	}
	// Invalidate cache so next full reload picks up the new content too.
	if m.detailCache != nil {
		delete(m.detailCache, msg.slug)
	}
	dm, cmd := m.detail.Update(work.DetailPlanRefreshedMsg{Slug: msg.slug, Content: msg.content})
	m.detail = dm
	return m, cmd
}

// handleFollowupDetailMtimeChecked compares the follow-up detail file mtime and triggers
// a detail reload when the file has changed.
func (m model) handleFollowupDetailMtimeChecked(msg followupDetailMtimeCheckedMsg) (model, tea.Cmd) {
	if msg.err != nil || msg.id != m.followupDetail.CurrentID() {
		return m, nil
	}
	if m.lastFollowupDetailMtime.IsZero() {
		m.lastFollowupDetailMtime = msg.mtime // baseline initialization
		return m, nil
	}
	if !msg.mtime.Equal(m.lastFollowupDetailMtime) {
		m.lastFollowupDetailMtime = msg.mtime
		m.followupDetail.PreserveTab()
		return m, followup.LoadDetail(m.config.KnowledgeDir, msg.id)
	}
	return m, nil
}

// handleDetailMtimeChecked compares the detail file mtime and triggers a full detail
// reload when any of the tracked files have changed.
func (m model) handleDetailMtimeChecked(msg detailMtimeCheckedMsg) (model, tea.Cmd) {
	if msg.err != nil || msg.slug != m.list.CurrentSlug() {
		return m, nil
	}
	if m.lastDetailMtime.IsZero() {
		m.lastDetailMtime = msg.mtime // baseline initialization
		return m, nil
	}
	if !msg.mtime.Equal(m.lastDetailMtime) {
		m.lastDetailMtime = msg.mtime
		// Preserve active tab across the reload.
		m.detail.PreserveTab()
		// Invalidate cache so the reload fetches fresh data.
		if m.detailCache != nil {
			delete(m.detailCache, msg.slug)
		}
		return m, work.LoadDetail(m.config.WorkDir, msg.slug)
	}
	return m, nil
}

// handleProjectDetailMtimeChecked compares the project home's mtime against the
// baseline and reloads the project detail (preserving the active tab) when it
// changed. Guarded on the current selection still being that project so a stale
// stat from a prior selection is ignored.
func (m model) handleProjectDetailMtimeChecked(msg projectDetailMtimeCheckedMsg) (model, tea.Cmd) {
	if msg.err != nil || !m.detail.IsProject() || msg.slug != m.detail.ProjectSlug() {
		return m, nil
	}
	if m.lastProjectDetailMtime.IsZero() {
		m.lastProjectDetailMtime = msg.mtime // baseline initialization
		return m, nil
	}
	if !msg.mtime.Equal(m.lastProjectDetailMtime) {
		m.lastProjectDetailMtime = msg.mtime
		m.detail.PreserveTab()
		return m, work.LoadProjectDetailCmd(m.config.WorkDir, msg.slug)
	}
	return m, nil
}
