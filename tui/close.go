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
	// closeTerminusGraceDefault is the cooperative window a self-requested
	// protocol terminus gets to finish its generating tail naturally. It never
	// authorizes interruption or process signals while generation continues.
	closeTerminusGraceDefault = 2 * time.Minute
	// closeExplicitGraceDefault is the short natural-quiescence courtesy window
	// before an explicit human/coordinator close injects ESC.
	closeExplicitGraceDefault = 2 * time.Second
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
// protocol-terminus close hit an open modal and refused. still-generating: its
// cooperative grace expired before the active turn ended. Both leave the
// session alive. rung-exhausted: the exit ladder ran every rung and the harness
// process was still alive. error: an operational failure during teardown.
const (
	closeFailedInteractivePrompt  = "interactive-prompt"
	closeFailedStillGenerating    = "still-generating"
	closeFailedRungExhausted      = "rung-exhausted"
	closeFailedError              = "error"
	closeFailedTargetInstanceDead = "target-instance-dead"
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
// grace; interruptedAt is set only after an explicit close's courtesy wait when
// a still-generating session had ESC injected. A protocol-terminus close never
// sets it.
type pendingCloseState struct {
	requestID     string
	reason        string
	consumedAt    time.Time
	interruptedAt time.Time
}

// appendCloseRequest records one consumed close-request exactly once while
// preserving first-consumed order. Empty ids are not declarations.
func appendCloseRequest(ids []string, requestID string) []string {
	if requestID == "" {
		return ids
	}
	for _, id := range ids {
		if id == requestID {
			return ids
		}
	}
	return append(ids, requestID)
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
func runCloseLadder(proc harnessProc, ptmx io.Writer, exitSeq string, exitSupported bool, framework string, grace, poll time.Duration) (closeRung, []runtimeNotice, error) {
	var notices []runtimeNotice
	if proc == nil {
		return rungNone, nil, nil
	}
	if exitSupported && ptmx != nil {
		_, _ = ptmx.Write([]byte(exitSeq))
		if waitExit(proc, grace, poll) {
			return rungGraceful, nil, nil
		}
	} else if !exitSupported {
		notices = append(notices, degradationNotice(
			"graceful-exit-unsupported",
			fmt.Sprintf("graceful exit unsupported for %s; session close escalated to SIGTERM", framework),
		))
	}
	_ = proc.Terminate()
	if waitExit(proc, grace, poll) {
		return rungSIGTERM, notices, nil
	}
	if err := proc.Kill(); err != nil && proc.Alive() {
		return rungKill, notices, fmt.Errorf("SIGKILL failed: %w", err)
	}
	if proc.Alive() {
		return rungKill, notices, errCloseLadderExhausted
	}
	return rungKill, notices, nil
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
	matched     []session.CloseRequest
	diagnostics []session.Diagnostic
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
	notices   []runtimeNotice
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
		rows, diagnostics := session.ScanCloseRequestsWithDiagnostics(sessionsDir)
		for _, cr := range rows {
			if cr.RequestID == "" || cr.TargetInstance != myName {
				continue
			}
			slug, ok := resolveCloseTargetSlug(cr, idToSlug)
			if !ok || !hosted[slug] {
				continue
			}
			matched = append(matched, cr)
		}
		return closeRequestScanMsg{matched: matched, diagnostics: diagnostics}
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

// consumeCloseRequestCmd durably records the updated recovery manifest after
// deleting a matched close-request. handleCloseRequestScan sequences these
// commands before any close action it dispatches in the same update.
func consumeCloseRequestCmd(sessionsDir, requestID string, inst session.Instance) tea.Cmd {
	return func() tea.Msg {
		deleteErr := session.DeleteCloseRequest(sessionsDir, requestID)
		writeErr := session.WriteInstance(sessionsDir, inst)
		return closeRequestDeletedMsg{requestID: requestID, err: errors.Join(deleteErr, writeErr)}
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
		rung, notices, err := runCloseLadder(proc, ptmx, exitSeq, exitSupported, framework, grace, poll)
		return closeLadderDoneMsg{slug: slug, rung: rung, err: err, requestID: requestID, notices: notices}
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
//     still-generating session gets a short natural-quiescence opportunity before
//     the interrupt-escalation rung. Never a silent no-op.
//   - protocol-terminus close (reason protocol_terminus, enqueued by a protocol's
//     own finalize step): the initiator/auto_close gate stands. An agent session
//     auto-closes; a human session (or auto_close=false) is held open with a "done"
//     panel badge, teardown available via keybind/verb or a later explicit close.
func (m model) handleCloseRequestScan(msg closeRequestScanMsg) (model, tea.Cmd) {
	diagnosticCmd := appendDiagnosticsCmd(m.sessionsDir, msg.diagnostics)
	if len(msg.matched) == 0 {
		return m, diagnosticCmd
	}
	idToSlug := sessionIDIndex(m.localSessions)
	var cmds []tea.Cmd
	if diagnosticCmd != nil {
		cmds = append(cmds, diagnosticCmd)
	}
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
		if ls, tracked := m.localSessions[slug]; tracked {
			ls.closeRequests = appendCloseRequest(ls.closeRequests, cr.RequestID)
			m.localSessions[slug] = ls
		}
		cmds = append(cmds, consumeCloseRequestCmd(m.sessionsDir, cr.RequestID, m.instanceRow()))

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
		m.pendingClose[slug] = pendingCloseState{
			requestID:  cr.RequestID,
			reason:     cr.Reason,
			consumedAt: time.Now(),
		}
	}
	var advCmds []tea.Cmd
	m, advCmds = m.advanceCloseLadders()
	cmds = append(cmds, advCmds...)
	if len(cmds) == 0 {
		return m, nil
	}
	return m, tea.Sequence(cmds...)
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

func (m model) terminusGrace() time.Duration {
	if m.closeTerminusGrace > 0 {
		return m.closeTerminusGrace
	}
	return closeTerminusGraceDefault
}

func (m model) explicitGrace() time.Duration {
	if m.closeExplicitGrace > 0 {
		return m.closeExplicitGrace
	}
	return closeExplicitGraceDefault
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

// observeClosePanel reads at most one ScreenSnapshot and routes it through the
// shared classifier. Lifecycle and timer-derived quiescence remain observable
// even when the framework or screen cannot be classified.
func observeClosePanel(panel work.SessionPanelModel) closeObservation {
	done, quiescent := panel.IsDone(), panel.NeedsInput()
	base := closeObservation{done: done, quiescent: quiescent}
	if done {
		return base
	}
	framework, err := config.ResolveTUILaunchFramework()
	if err != nil {
		return base
	}
	snap, err := panel.ScreenState()
	if err != nil {
		return base
	}
	return classifyCloseObservation(framework, done, quiescent, snap)
}

func (m model) observeClose(panel work.SessionPanelModel) closeObservation {
	if m.observeCloseFn != nil {
		return m.observeCloseFn(panel)
	}
	return observeClosePanel(panel)
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
		obs := m.observeClose(panel)
		if !obs.done {
			if obs.interactive() {
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
			} else if obs.generating() {
				if pc.reason == closeReasonProtocolTerminus {
					if time.Since(pc.consumedAt) < m.terminusGrace() {
						continue
					}
					delete(m.pendingClose, slug)
					cmds = append(cmds, m.closeFailedCmd(slug, pc.requestID, closeFailedStillGenerating, m.localSessions[slug]))
					continue
				}

				// Explicit authority first gives the turn a courtesy window to finish
				// naturally. Only after that bound may it inject ESC; the existing
				// interrupt grace then leads to the force-teardown ladder if needed.
				if pc.interruptedAt.IsZero() {
					if time.Since(pc.consumedAt) < m.explicitGrace() {
						continue
					}
					_ = panel.Interrupt()
					pc.interruptedAt = time.Now()
					m.pendingClose[slug] = pc
					continue
				}
				if time.Since(pc.interruptedAt) < m.interruptGrace() {
					continue
				}
			}
		}
		delete(m.pendingClose, slug)
		cmds = append(cmds, m.closeLadderCmd(slug, panel, pc.requestID))
	}
	return m, cmds
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
	m = m.routeRuntimeNotices(msg.notices)
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
