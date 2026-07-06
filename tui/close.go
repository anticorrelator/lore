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
	// closeInterruptGraceDefault bounds how long the interrupt-escalation rung
	// waits for an injected interrupt (ESC) to end a generating turn before it
	// proceeds down the exit ladder regardless. A --yes protocol run is one
	// unbroken turn, so the interrupt is the only signal that can end it; if it
	// does not take within this window the ladder escalates (SIGTERM→KILL) rather
	// than waiting on a boundary that never comes.
	closeInterruptGraceDefault = 5 * time.Second
)

// closeReasonProtocolTerminus is the close-request reason a protocol's own finalize
// step enqueues (session close --self --reason protocol_terminus). It is the only
// reason still gated by initiator/auto_close (hold-open vs auto-close at terminus);
// every other reason is an explicit close that acts with full discretion.
const closeReasonProtocolTerminus = "protocol_terminus"

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

// tmuxProc adapts a tmux pane PID to harnessProc. Under tmux the panel's own
// Process() is the attach client, so SIGTERM there would only detach a viewer
// while the harness runs on — the ladder must signal the pane process (the
// harness) directly. The graceful rung is unaffected: it still writes the exit
// sequence to the PTY, which travels through the attach client into the pane.
type tmuxProc struct{ pid int }

func (t tmuxProc) Terminate() error { return syscall.Kill(t.pid, syscall.SIGTERM) }
func (t tmuxProc) Kill() error      { return syscall.Kill(t.pid, syscall.SIGKILL) }
func (t tmuxProc) Alive() bool      { return syscall.Kill(t.pid, syscall.Signal(0)) == nil }

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
func (m model) closeLadderCmd(slug string, panel work.SessionPanelModel) tea.Cmd {
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
		// A tmux-hosted session's harness is the pane process, not the panel's
		// attach client — target the pane PID so escalation actually terminates the
		// harness instead of detaching a viewer.
		var proc harnessProc
		if pid := panel.PanePID(); pid != 0 {
			proc = tmuxProc{pid: pid}
		} else if p := panel.Process(); p != nil {
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

// shouldAutoClose decides what a consumed close-request does to a session: tear
// it down (true) or hold it open with a "done" badge (false). The per-request
// auto_close override wins when present; absent, the initiator gates it —
// agent-initiated sessions auto-close (the no-polling rationale stands), while
// human-initiated sessions hold open for reading, follow-ups, or an in-session
// closing-act retro. An untracked session (no liveSession) defaults to
// auto-close, matching the pre-gate behavior.
func shouldAutoClose(ls liveSession) bool {
	if ls.autoClose != nil {
		return *ls.autoClose
	}
	return ls.initiator == "agent"
}

// handleCloseRequestScan consumes each matched close-request. Consuming always
// deletes the row (the durable ack; the journal's close_requested already recorded
// intent). What follows branches on the request's reason:
//
//   - explicit close (reason human — the CLI default — or coordinator): full
//     discretion. Always schedule teardown, regardless of initiator or state; a
//     still-generating session gets the interrupt-escalation rung (ESC injected now
//     so its turn ends) before the quiescence-gated ladder. Never a silent no-op.
//   - protocol-terminus close (reason protocol_terminus, enqueued by a protocol's
//     own finalize step): the initiator/auto_close gate stands. An agent session
//     auto-closes; a human session (or auto_close=false) is held open with a "done"
//     panel badge, teardown available via keybind/verb or a later explicit close.
func (m model) handleCloseRequestScan(msg closeRequestScanMsg) (model, tea.Cmd) {
	if len(msg.matched) == 0 {
		return m, nil
	}
	var cmds []tea.Cmd
	for _, cr := range msg.matched {
		if m.pendingClose[cr.Slug] {
			continue // already consumed this slug's close-request; awaiting quiescence
		}
		cmds = append(cmds, deleteCloseRequestCmd(m.sessionsDir, cr.RequestID))

		// Protocol-terminus is the only reason still gated by initiator/auto_close.
		// Every explicit close acts with full discretion (falls through to teardown).
		if cr.Reason == closeReasonProtocolTerminus {
			if ls, tracked := m.localSessions[cr.Slug]; tracked && !shouldAutoClose(ls) {
				// Held open at terminus: badge the panel, keep running.
				if panel, ok := m.sessionPanels[cr.Slug]; ok {
					m.sessionPanels[cr.Slug] = panel.MarkCloseRequested()
				}
				continue
			}
		}

		if m.pendingClose == nil {
			m.pendingClose = make(map[string]bool)
		}
		m.pendingClose[cr.Slug] = true

		// Interrupt-escalation rung: a session bound for teardown that is still
		// generating gets the interrupt byte injected now, so its turn ends and the
		// quiescence-gated ladder can proceed. Idle sessions need no interrupt.
		// Best-effort: a missing PTY leaves the ladder to force teardown after the
		// bounded grace.
		if panel, ok := m.sessionPanels[cr.Slug]; ok && sessionGenerating(panel) {
			_ = panel.Interrupt()
			if m.interruptedClose == nil {
				m.interruptedClose = make(map[string]time.Time)
			}
			m.interruptedClose[cr.Slug] = time.Now()
		}
	}
	var advCmds []tea.Cmd
	m, advCmds = m.advanceCloseLadders()
	cmds = append(cmds, advCmds...)
	if len(cmds) == 0 {
		return m, nil
	}
	return m, tea.Batch(cmds...)
}

// sessionGenerating reports whether a hosted session is actively mid-turn
// (producing output), as opposed to idle/awaiting-input or finished. It is the
// interrupt-escalation trigger: a session bound for teardown while generating is
// interrupted before the ladder. A session paused on an interactive prompt reads as
// awaiting-input (NeedsInput), so it is not "generating" here — teardown of such a
// session is separately held by advanceCloseLadders' interactive-prompt guard.
func sessionGenerating(panel work.SessionPanelModel) bool {
	return !panel.IsDone() && !panel.NeedsInput()
}

// interruptGrace is how long advanceCloseLadders waits for an injected interrupt
// to end a generating turn before forcing teardown down the exit ladder. It
// reuses the closeGrace seam (tests inject a small value) and falls back to
// closeInterruptGraceDefault.
func (m model) interruptGrace() time.Duration {
	if m.closeGrace > 0 {
		return m.closeGrace
	}
	return closeInterruptGraceDefault
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
		panel, ok := m.sessionPanels[slug]
		if !ok {
			delete(m.pendingClose, slug) // panel already gone; nothing to tear down
			delete(m.interruptedClose, slug)
			continue
		}
		// A running session paused on an interactive prompt reads as quiescent
		// but must not be torn down mid-prompt; the screen classification tells
		// the two apart. Skip the read for a finished process — teardown is
		// unconditionally safe there and QuiescentForClose short-circuits on it.
		interactive := false
		if !panel.IsDone() {
			interactive = atInteractivePrompt(panel)
		}
		if !panel.QuiescentForClose(interactive) {
			// Mid-turn or mid-prompt. An interrupted session whose bounded grace has
			// elapsed proceeds down the ladder anyway — the interrupt did not end the
			// turn, so SIGTERM→KILL will (a --yes turn may never quiesce). Everything
			// else keeps waiting.
			t, interrupted := m.interruptedClose[slug]
			if !interrupted || time.Since(t) < m.interruptGrace() {
				continue
			}
		}
		delete(m.pendingClose, slug)
		delete(m.interruptedClose, slug)
		cmds = append(cmds, m.closeLadderCmd(slug, panel))
	}
	return m, cmds
}

// atInteractivePrompt reports whether the panel's live screen shows a
// permission/approval modal — the interactive-prompt state the close ladder must
// not tear down through. It resolves the active harness's screen matcher (the
// same one the injection readiness gate uses) and reads a ScreenSnapshot; on any
// failure (no framework, no interaction contract, snapshot error) it returns
// false so a screen we cannot classify never blocks a close indefinitely. It
// reads the shared terminal backend, so callers must invoke it on the Bubble Tea
// goroutine (advanceCloseLadders' two callers both do).
func atInteractivePrompt(panel work.SessionPanelModel) bool {
	framework, err := config.ResolveTUILaunchFramework()
	if err != nil {
		return false
	}
	mm, ok := screenMatchers[framework]
	if !ok {
		return false
	}
	snap, err := panel.ScreenState()
	if err != nil {
		return false
	}
	return mm.permission(gateRows(snap.Rows))
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
	if m.sessionPanels != nil {
		if panel, ok := m.sessionPanels[slug]; ok {
			sm := panel.Cleanup()
			sm, _ = sm.Update(work.StreamCompleteMsg{Slug: slug}) // sets done
			m.sessionPanels[slug] = sm
		}
	}
	m.list, _ = m.list.Update(work.SessionStatusMsg{Slug: slug, Done: true})
	m, sessCmds := m.endLocalSession(slug)
	cmds := append([]tea.Cmd(nil), sessCmds...)
	if m.state == stateFollowUps {
		cmds = append(cmds, followup.LoadIndexCmd(m.config.KnowledgeDir))
	} else {
		cmds = append(cmds, loadWorkItems(m.config.WorkDir))
	}
	return m, tea.Batch(cmds...)
}
