package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
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
	// closeModalHoldDefault bounds how long a close blocked by an open interactive
	// prompt (a permission/approval modal) waits before acting. It is deliberately
	// longer than the interrupt grace: its purpose is to let a human mid-answer
	// finish the prompt. Once it elapses the close acts by authority — an explicit
	// close proceeds down the exit ladder, a protocol-terminus close refuses
	// (close_failed) and leaves the session alive.
	closeModalHoldDefault = 30 * time.Second
)

// close_failed reason tokens — the terminal a consumed close-request emits when a
// teardown does not (or must not) complete. interactive-prompt: a
// protocol-terminus close hit an open modal and refused, leaving the session
// alive. rung-exhausted: the exit ladder ran every rung and the harness process
// was still alive. error: an operational failure during teardown.
const (
	closeFailedInteractivePrompt = "interactive-prompt"
	closeFailedRungExhausted     = "rung-exhausted"
	closeFailedError             = "error"
)

// errCloseLadderExhausted marks a teardown that ran every exit-ladder rung and
// still could not confirm the harness process gone (it outlived SIGKILL — a
// zombie or uninterruptible-sleep edge). It routes the consumed close-request to
// a close_failed reason=rung-exhausted terminal instead of a false `closed`.
var errCloseLadderExhausted = errors.New("exit ladder exhausted: harness process alive after SIGKILL")

// pendingCloseState is the ladder-side record of one consumed close-request
// awaiting teardown. requestID and reason come from the consumed row: requestID
// is threaded onto the terminal journal row so a close requester has one match
// key, and reason splits modal-blocked handling by authority (an explicit close
// acts; a protocol-terminus close refuses). consumedAt bounds the modal-hold
// grace; interruptedAt is set only when a still-generating session had the
// interrupt (ESC) injected and bounds the post-interrupt wait (zero = never
// interrupted).
type pendingCloseState struct {
	requestID     string
	reason        string
	consumedAt    time.Time
	interruptedAt time.Time
}

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
// back up. A nil proc means there is nothing to terminate. The returned error is
// non-nil only when teardown could not confirm the process gone: a SIGKILL that
// itself failed while the process is still alive (wrapped), or a process that
// outlived the full ladder (errCloseLadderExhausted). The caller turns a non-nil
// error into a close_failed terminal rather than a false `closed`.
func runCloseLadder(proc harnessProc, ptmx io.Writer, exitSeq string, exitSupported bool, framework string, grace, poll time.Duration) (closeRung, error) {
	if proc == nil {
		return rungNone, nil
	}
	if exitSupported && ptmx != nil {
		_, _ = ptmx.Write([]byte(exitSeq))
		if waitExit(proc, grace, poll) {
			return rungGraceful, nil
		}
	} else if !exitSupported {
		fmt.Fprintf(os.Stderr, "[lore] degraded: graceful_exit_sequence skipped (capability=none on framework=%s); session close escalates to SIGTERM\n", framework)
	}
	_ = proc.Terminate()
	if waitExit(proc, grace, poll) {
		return rungSIGTERM, nil
	}
	if err := proc.Kill(); err != nil && proc.Alive() {
		return rungKill, fmt.Errorf("SIGKILL failed: %w", err)
	}
	if proc.Alive() {
		return rungKill, errCloseLadderExhausted
	}
	return rungKill, nil
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
// session's harness process; rung is the escalation step it reached. requestID is
// the consumed close-request's id, threaded through so the terminal journal row
// (closed on success, close_failed on err) carries it as a match key. err is
// non-nil only when teardown could not confirm the process gone.
type closeLadderDoneMsg struct {
	slug      string
	rung      closeRung
	err       error
	requestID string
}

// --- Cmds ---

// sessionIDIndex maps each hosted session's harness id to its slug, skipping
// sessions with no id binding. It is the lookup a session-addressed close-request
// resolves through: two slugless sessions both key at "" in localSessions, but
// their ids are distinct, so the id is the only handle that tells them apart.
func sessionIDIndex(localSessions map[string]liveSession) map[string]string {
	idx := make(map[string]string, len(localSessions))
	for slug, ls := range localSessions {
		if ls.sessionID != "" {
			idx[ls.sessionID] = slug
		}
	}
	return idx
}

// resolveCloseTargetSlug decides which hosted slug a close-request tears down.
// A row carrying a session_id addresses one specific session: match it against
// each hosted session's id by exact-or-leading-prefix (a coordinator may pass a
// short prefix) and key teardown off that session's slug. A row without a
// session_id — every legacy row — keys off its slug unchanged. A session-addressed
// row whose id matches no hosted session and carries no slug resolves to nothing
// (ok=false): tearing down the empty-slug session for it would be the very
// wrong-session close the id exists to prevent.
func resolveCloseTargetSlug(cr session.CloseRequest, idToSlug map[string]string) (string, bool) {
	if cr.SessionID != "" {
		for id, slug := range idToSlug {
			if strings.HasPrefix(id, cr.SessionID) {
				return slug, true
			}
		}
		if cr.Slug == "" {
			return "", false
		}
	}
	return cr.Slug, true
}

// scanCloseRequestsCmd reads close-requests/ and returns the rows addressed to
// this instance (target_instance == myName) for a session it currently hosts.
// BOTH filters must hold: a row for another instance, or for a session this
// instance does not host, is left untouched (neither returned nor deleted). A
// row's target session is its session_id when present (see resolveCloseTargetSlug),
// else its slug. hosted and idToSlug are snapshotted at Cmd-build time, mirroring
// queueTickCmd's plan-doc snapshot.
func scanCloseRequestsCmd(sessionsDir, myName string, hosted map[string]bool, idToSlug map[string]string) tea.Cmd {
	return func() tea.Msg {
		var matched []session.CloseRequest
		for _, cr := range session.ScanCloseRequests(sessionsDir) {
			if cr.RequestID == "" || cr.TargetInstance != myName {
				continue
			}
			slug, ok := resolveCloseTargetSlug(cr, idToSlug)
			if !ok || !hosted[slug] {
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
func (m model) closeLadderCmd(slug string, panel work.SessionPanelModel, requestID string) tea.Cmd {
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
		rung, err := runCloseLadder(proc, ptmx, exitSeq, exitSupported, framework, grace, poll)
		return closeLadderDoneMsg{slug: slug, rung: rung, err: err, requestID: requestID}
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
	idToSlug := sessionIDIndex(m.localSessions)
	var cmds []tea.Cmd
	for _, cr := range msg.matched {
		// A session-addressed row keys off the id-resolved slug, not cr.Slug, so a
		// slugless close reaches the one session it named. ok=false means the
		// addressed session is no longer tracked here (torn down since the scan);
		// consume the now-orphan row and move on.
		slug, ok := resolveCloseTargetSlug(cr, idToSlug)
		if !ok {
			cmds = append(cmds, deleteCloseRequestCmd(m.sessionsDir, cr.RequestID))
			continue
		}
		if _, pending := m.pendingClose[slug]; pending {
			continue // already consumed this session's close-request; awaiting quiescence
		}
		cmds = append(cmds, deleteCloseRequestCmd(m.sessionsDir, cr.RequestID))

		// Protocol-terminus is the only reason still gated by initiator/auto_close.
		// Every explicit close acts with full discretion (falls through to teardown).
		if cr.Reason == closeReasonProtocolTerminus {
			if ls, tracked := m.localSessions[slug]; tracked && !shouldAutoClose(ls) {
				// Held open at terminus: badge the panel, keep running.
				if panel, ok := m.sessionPanels[slug]; ok {
					m.sessionPanels[slug] = panel.MarkCloseRequested()
				}
				continue
			}
		}

		if m.pendingClose == nil {
			m.pendingClose = make(map[string]pendingCloseState)
		}
		pc := pendingCloseState{
			requestID:  cr.RequestID,
			reason:     cr.Reason,
			consumedAt: time.Now(),
		}

		// Interrupt-escalation rung: a session bound for teardown that is still
		// generating gets the interrupt byte injected now, so its turn ends and the
		// quiescence-gated ladder can proceed. Idle sessions need no interrupt.
		// Best-effort: a missing PTY leaves the ladder to force teardown after the
		// bounded grace.
		if panel, ok := m.sessionPanels[slug]; ok && sessionGenerating(panel) {
			_ = panel.Interrupt()
			pc.interruptedAt = time.Now()
		}
		m.pendingClose[slug] = pc
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

// modalHold is how long advanceCloseLadders holds a close blocked by an open
// interactive prompt before acting by authority. Seam: a zero closeModalHold
// field falls back to closeModalHoldDefault; tests inject a small value.
func (m model) modalHold() time.Duration {
	if m.closeModalHold > 0 {
		return m.closeModalHold
	}
	return closeModalHoldDefault
}

// interactivePrompt reports whether a non-done panel is blocked on an interactive
// prompt (permission/approval or option-select). It routes through the atInteractivePromptFn
// seam when set (tests), otherwise reads the live screen via atInteractivePrompt.
func (m model) interactivePrompt(panel work.SessionPanelModel) bool {
	if m.atInteractivePromptFn != nil {
		return m.atInteractivePromptFn(panel)
	}
	return atInteractivePrompt(panel)
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
	for slug, pc := range m.pendingClose {
		panel, ok := m.sessionPanels[slug]
		if !ok {
			// Panel already gone: a concurrent teardown (StreamComplete, quit,
			// Ctrl+\) removed it and journaled the session's own `closed`. Drop the
			// entry with no second terminal — that `closed` is the one terminal.
			delete(m.pendingClose, slug)
			continue
		}
		// A running session paused on an interactive prompt reads as quiescent
		// but must not be torn down mid-prompt; the screen classification tells
		// the two apart. Skip the read for a finished process — teardown is
		// unconditionally safe there and QuiescentForClose short-circuits on it.
		interactive := false
		if !panel.IsDone() {
			interactive = m.interactivePrompt(panel)
		}
		if !panel.QuiescentForClose(interactive) {
			if interactive {
				// Blocked on an open modal. Hold up to the modal-hold bound so a human
				// mid-answer can finish; a prompt that clears re-reads as safe next
				// tick and closes normally.
				if time.Since(pc.consumedAt) < m.modalHold() {
					continue
				}
				// Bound elapsed: act by authority. A protocol-terminus close refuses
				// loudly — journal close_failed and leave the session alive (no
				// teardown). An explicit close always acts: it falls through to the
				// exit ladder. No bytes are injected either way — the send-readiness
				// gate is untouched.
				if pc.reason == closeReasonProtocolTerminus {
					delete(m.pendingClose, slug)
					cmds = append(cmds, m.closeFailedCmd(slug, pc.requestID, closeFailedInteractivePrompt, m.localSessions[slug]))
					continue
				}
			} else {
				// Mid-turn. An interrupted session whose bounded grace has elapsed
				// proceeds down the ladder anyway — the interrupt did not end the turn,
				// so SIGTERM→KILL will (a --yes turn may never quiesce). Everything
				// else keeps waiting.
				if pc.interruptedAt.IsZero() || time.Since(pc.interruptedAt) < m.interruptGrace() {
					continue
				}
			}
		}
		delete(m.pendingClose, slug)
		cmds = append(cmds, m.closeLadderCmd(slug, panel, pc.requestID))
	}
	return m, cmds
}

// atInteractivePrompt reports whether the panel's live screen shows an
// interactive prompt — the state the close ladder must not tear down through. It
// resolves the active harness's screen matcher (the same one the injection
// readiness gate uses) and reads a ScreenSnapshot; on any failure (no framework,
// no interaction contract, snapshot error) it returns
// false so a screen we cannot classify never blocks a close indefinitely. It
// reads the shared terminal backend, so callers must invoke it on the Bubble Tea
// goroutine (advanceCloseLadders' two callers both do).
func atInteractivePrompt(panel work.SessionPanelModel) bool {
	framework, err := config.ResolveTUILaunchFramework()
	if err != nil {
		return false
	}
	if _, ok := screenMatchers[framework]; !ok {
		return false
	}
	snap, err := panel.ScreenState()
	if err != nil {
		return false
	}
	return interactivePromptState(framework, snap)
}

// closeFailedCmd journals one close_failed row for a consumed close-request that
// did not tear the session down. request_id is required by the writer, so it is
// carried from the consumed close-request; session_type/initiator come from the
// live session (empty when it is no longer tracked, which the writer tolerates).
func (m model) closeFailedCmd(slug, requestID, reason string, ls liveSession) tea.Cmd {
	return journalCmd(m.eventScript, m.config.KnowledgeDir, session.Event{
		Event:         session.EventCloseFailed,
		ActorInstance: session.StrPtr(m.instanceName),
		Slug:          slug,
		SessionType:   ls.typ,
		Initiator:     ls.initiator,
		RequestID:     requestID,
		Reason:        reason,
	})
}

// handleCloseLadderDone finishes teardown after the exit ladder ran: it cleans up
// the panel and marks it done, then emits the consumed close-request's single
// terminal. A ladder that confirmed the process gone journals `closed` (carrying
// the close request_id); a ladder that could not confirm it gone journals
// `close_failed` instead — never both. Both drop the slug from this instance's
// registry, so the StreamCompleteMsg the killed process later produces re-enters
// teardown as a no-op (endLocalSession* is guarded on localSessions membership),
// keeping the terminal exactly-once.
func (m model) handleCloseLadderDone(msg closeLadderDoneMsg) (model, tea.Cmd) {
	slug := msg.slug
	if m.sessionPanels != nil {
		if panel, ok := m.sessionPanels[slug]; ok {
			sm := panel.Cleanup()
			sm, _ = sm.Update(work.StreamCompleteMsg{Slug: slug}) // sets done
			m.sessionPanels[slug] = sm
		}
	}
	m.list, _ = m.list.Update(work.SessionStatusMsg{Slug: slug, Done: true})

	var termCmds []tea.Cmd
	if msg.err != nil {
		m.flashErr = compactErr("session close", msg.err)
		reason := closeFailedError
		if errors.Is(msg.err, errCloseLadderExhausted) {
			reason = closeFailedRungExhausted
		}
		m, termCmds = m.endLocalSessionFailed(slug, msg.requestID, reason)
	} else {
		m, termCmds = m.endLocalSessionClosed(slug, msg.requestID)
	}
	cmds := append([]tea.Cmd(nil), termCmds...)
	if m.state == stateFollowUps {
		cmds = append(cmds, followup.LoadIndexCmd(m.config.KnowledgeDir))
	} else {
		cmds = append(cmds, loadWorkItems(m.config.WorkDir))
	}
	return m, tea.Batch(cmds...)
}
