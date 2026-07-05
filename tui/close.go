package main

import (
	"fmt"
	"io"
	"os"
	"syscall"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/followup"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// closeGraceDefault bounds how long each ladder rung waits for the harness
// process to exit before escalating; closePollDefault is the liveness re-check
// interval within that window. Production uses these; tests inject smaller
// values through the model seams.
const (
	closeGraceDefault = 5 * time.Second
	closePollDefault  = 100 * time.Millisecond
)

// closeRung names the ladder step a teardown reached — useful for tests and for
// asserting monotonic escalation (a session never regresses to a lower rung).
type closeRung int

const (
	rungNone     closeRung = iota // no process to terminate (never started / reaped)
	rungGraceful                  // exited after the capability-supplied exit sequence
	rungSIGTERM                   // exited after SIGTERM within the grace window
	rungKill                      // required Process.Kill()
)

// harnessProc is the process-control surface the close ladder drives. The
// concrete osProc wraps *os.Process; tests inject a scriptable fake so
// SIGTERM→Kill escalation is exercised without a live subprocess.
type harnessProc interface {
	Terminate() error // deliver SIGTERM
	Kill() error      // deliver SIGKILL
	Alive() bool      // whether the process has yet to exit
}

// osProc adapts a live *os.Process to harnessProc. Alive uses the standard Unix
// signal-0 liveness probe (an error means the process is gone).
type osProc struct{ p *os.Process }

func (o osProc) Terminate() error { return o.p.Signal(syscall.SIGTERM) }
func (o osProc) Kill() error      { return o.p.Kill() }
func (o osProc) Alive() bool      { return o.p.Signal(syscall.Signal(0)) == nil }

// runCloseLadder drives the D5 exit ladder against proc and returns the rung it
// reached:
//
//  1. graceful — write the capability-supplied exit sequence to ptmx, then wait
//     grace for the process to leave. Skipped with an explicit degradation
//     notice when no capability supplies a sequence (the v1 reality: no harness
//     declares one, so teardown always starts at SIGTERM). Never hardcodes a
//     per-harness string.
//  2. SIGTERM — signal the process, wait grace for it to leave.
//  3. Kill — final fallback.
//
// Escalation is strictly monotonic: the ladder only moves down a rung, never
// back up. A nil proc means there is nothing to terminate.
func runCloseLadder(proc harnessProc, ptmx io.Writer, exitSeq string, exitSupported bool, framework string, grace, poll time.Duration) closeRung {
	if proc == nil {
		return rungNone
	}
	if exitSupported && ptmx != nil {
		_, _ = ptmx.Write([]byte(exitSeq))
		if waitExit(proc, grace, poll) {
			return rungGraceful
		}
	} else if !exitSupported {
		fmt.Fprintf(os.Stderr, "[lore] degraded: graceful_exit_sequence skipped (capability=none on framework=%s); session close escalates to SIGTERM\n", framework)
	}
	_ = proc.Terminate()
	if waitExit(proc, grace, poll) {
		return rungSIGTERM
	}
	_ = proc.Kill()
	return rungKill
}

// waitExit polls proc.Alive at poll intervals until it reports exited or grace
// elapses. A non-positive grace is a zero-wait check (escalate immediately);
// poll is floored at 1ms so a zero value never spins.
func waitExit(proc harnessProc, grace, poll time.Duration) bool {
	if poll <= 0 {
		poll = time.Millisecond
	}
	deadline := time.Now().Add(grace)
	for {
		if !proc.Alive() {
			return true
		}
		if !time.Now().Before(deadline) {
			return false
		}
		time.Sleep(poll)
	}
}

// --- messages ---

// closeRequestScanMsg carries the close-requests addressed to this instance for
// a slug it hosts, discovered on the poll tick.
type closeRequestScanMsg struct {
	matched []session.CloseRequest
}

// closeRequestDeletedMsg reports the outcome of consuming (deleting) one matched
// close-request row.
type closeRequestDeletedMsg struct {
	requestID string
	err       error
}

// closeLadderDoneMsg reports that the D5 exit ladder finished terminating a
// session's harness process; rung is the escalation step it reached.
type closeLadderDoneMsg struct {
	slug string
	rung closeRung
	err  error
}

// --- Cmds ---

// scanCloseRequestsCmd reads close-requests/ and returns the rows addressed to
// this instance (target_instance == myName) for a slug it currently hosts.
// BOTH filters must hold: a row for another instance, or for a slug this
// instance does not host, is left untouched (neither returned nor deleted).
// hosted is snapshotted at Cmd-build time, mirroring queueTickCmd's plan-doc
// snapshot.
func scanCloseRequestsCmd(sessionsDir, myName string, hosted map[string]bool) tea.Cmd {
	return func() tea.Msg {
		var matched []session.CloseRequest
		for _, cr := range session.ScanCloseRequests(sessionsDir) {
			if cr.RequestID == "" || cr.TargetInstance != myName {
				continue
			}
			if !hosted[cr.Slug] {
				continue
			}
			matched = append(matched, cr)
		}
		return closeRequestScanMsg{matched: matched}
	}
}

// deleteCloseRequestCmd consumes one matched row by deleting it. The delete is
// the durable consume; the journal (close_requested → closed) carries the
// history, so deleting before teardown completes is safe.
func deleteCloseRequestCmd(sessionsDir, requestID string) tea.Cmd {
	return func() tea.Msg {
		return closeRequestDeletedMsg{requestID: requestID, err: session.DeleteCloseRequest(sessionsDir, requestID)}
	}
}

// closeLadderCmd resolves the active harness's graceful-exit capability, then
// runs the D5 exit ladder against the panel's process. The ladder's process
// operations are side effects, so they run inside the Cmd, never in Update.
func (m model) closeLadderCmd(slug string, panel work.SpecPanelModel) tea.Cmd {
	grace := m.closeGrace
	if grace <= 0 {
		grace = closeGraceDefault
	}
	poll := m.closePoll
	if poll <= 0 {
		poll = closePollDefault
	}
	return func() tea.Msg {
		framework, ferr := config.ResolveTUILaunchFramework()
		exitSeq, exitSupported := "", false
		if ferr == nil {
			if seq, ok, err := config.HarnessGracefulExitSequence(framework); err == nil {
				exitSeq, exitSupported = seq, ok
			}
		}
		var proc harnessProc
		if p := panel.Process(); p != nil {
			proc = osProc{p: p}
		}
		var ptmx io.Writer
		if f := panel.Ptmx(); f != nil {
			ptmx = f
		}
		rung := runCloseLadder(proc, ptmx, exitSeq, exitSupported, framework, grace, poll)
		return closeLadderDoneMsg{slug: slug, rung: rung}
	}
}

// --- handlers ---

// handleCloseRequestScan consumes each matched close-request: it marks the slug
// awaiting-close (so a re-scan before the delete lands does not double-process),
// deletes the row, then dispatches the ladder for any slug already quiescent.
func (m model) handleCloseRequestScan(msg closeRequestScanMsg) (model, tea.Cmd) {
	if len(msg.matched) == 0 {
		return m, nil
	}
	var cmds []tea.Cmd
	for _, cr := range msg.matched {
		if m.pendingClose[cr.Slug] {
			continue // already consumed this slug's close-request; awaiting quiescence
		}
		if m.pendingClose == nil {
			m.pendingClose = make(map[string]bool)
		}
		m.pendingClose[cr.Slug] = true
		cmds = append(cmds, deleteCloseRequestCmd(m.sessionsDir, cr.RequestID))
	}
	var advCmds []tea.Cmd
	m, advCmds = m.advanceCloseLadders()
	cmds = append(cmds, advCmds...)
	if len(cmds) == 0 {
		return m, nil
	}
	return m, tea.Batch(cmds...)
}

// handleCloseRequestDeleted surfaces a failed row delete. The pendingClose entry
// is left in place — the ladder still fires on quiescence, and the journal
// carries teardown history regardless of whether the row could be removed.
func (m model) handleCloseRequestDeleted(msg closeRequestDeletedMsg) (model, tea.Cmd) {
	if msg.err != nil {
		m.flashErr = compactErr("close-request", msg.err)
	}
	return m, nil
}

// advanceCloseLadders dispatches the D5 exit ladder for every slug with a
// consumed close-request whose panel now reports quiescent. A dispatched slug is
// removed from pendingClose so its ladder fires at most once; slugs still
// mid-turn stay and are re-evaluated on the next poll tick (worst-case 5s
// surfacing latency, the documented poll-heartbeat bound).
func (m model) advanceCloseLadders() (model, []tea.Cmd) {
	if len(m.pendingClose) == 0 {
		return m, nil
	}
	var cmds []tea.Cmd
	for slug := range m.pendingClose {
		panel, ok := m.specPanels[slug]
		if !ok {
			delete(m.pendingClose, slug) // panel already gone; nothing to tear down
			continue
		}
		if !panel.QuiescentForClose() {
			continue // mid-turn — wait for quiescence
		}
		delete(m.pendingClose, slug)
		cmds = append(cmds, m.closeLadderCmd(slug, panel))
	}
	return m, cmds
}

// handleCloseLadderDone finishes teardown after the ladder terminated the
// harness process: it cleans up the panel, marks it done, and ends the local
// session — which rewrites this instance's registry row without the slug and
// journals `closed` through item 1's machinery. The StreamCompleteMsg the killed
// process later produces re-enters the same teardown, but endLocalSession is
// guarded on localSessions membership so `closed` is journaled exactly once.
func (m model) handleCloseLadderDone(msg closeLadderDoneMsg) (model, tea.Cmd) {
	if msg.err != nil {
		m.flashErr = compactErr("session close", msg.err)
	}
	slug := msg.slug
	if m.specPanels != nil {
		if panel, ok := m.specPanels[slug]; ok {
			sm := panel.Cleanup()
			sm, _ = sm.Update(work.StreamCompleteMsg{Slug: slug}) // sets done
			m.specPanels[slug] = sm
		}
	}
	m.list, _ = m.list.Update(work.SpecStatusMsg{Slug: slug, Done: true})
	m, sessCmds := m.endLocalSession(slug)
	cmds := append([]tea.Cmd(nil), sessCmds...)
	if m.state == stateFollowUps {
		cmds = append(cmds, followup.LoadIndexCmd(m.config.KnowledgeDir))
	} else {
		cmds = append(cmds, loadWorkItems(m.config.WorkDir))
	}
	return m, tea.Batch(cmds...)
}
