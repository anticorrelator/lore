package main

import (
	"errors"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// sendVerifyGraceDefault bounds how long a deferred send waits for an
// unclassifiable post-inject screen to resolve before journaling
// send_refused reason=unsubmitted. It spans a couple of poll ticks (~5s each) so
// the common paths — submit confirmed, or one replay of the submit sequence —
// terminate well inside the default `session send --wait` budget (15s). Tests
// override it through the model seam.
const sendVerifyGraceDefault = 12 * time.Second

// --- messages ---

// sendRequestScanMsg carries the send-requests addressed to this instance for a
// slug it hosts, discovered on the poll tick.
type sendRequestScanMsg struct {
	matched     []session.SendRequest
	diagnostics []session.Diagnostic
}

// sendConsumedMsg reports the outcome of consuming (deleting) one matched
// send-request — either delete + immediate journal (a gate refusal) or a
// delete-only ack (a gate-passing inject whose outcome journal defers).
type sendConsumedMsg struct {
	requestID string
	err       error
}

// pendingSendState is the verification-side record of one gate-passing send whose
// paste reached the composer and whose outcome journal defers until observation.
// slug + requestID rebuild the outcome row (the requestID is the requester's
// match key); submitSeq is replayed once as the recovery submit; injectedAt bounds
// the unobservable wait; retried marks that the one submit-sequence replay is
// spent.
type pendingSendState struct {
	slug       string
	requestID  string
	submitSeq  string
	injectedAt time.Time
	retried    bool
}

// --- Cmds ---

// scanSendRequestsCmd reads send-requests/ and returns the rows addressed to
// this instance (target_instance == myName) for a slug it currently hosts —
// both filters must hold, mirroring scanCloseRequestsCmd. hosted is snapshotted
// at Cmd-build time.
func scanSendRequestsCmd(sessionsDir, myName string, hosted map[string]bool) tea.Cmd {
	return func() tea.Msg {
		var matched []session.SendRequest
		rows, diagnostics := session.ScanSendRequestsWithDiagnostics(sessionsDir)
		for _, sr := range rows {
			if sr.RequestID == "" || sr.TargetInstance != myName {
				continue
			}
			if !hosted[sr.Slug] {
				continue
			}
			matched = append(matched, sr)
		}
		return sendRequestScanMsg{matched: matched, diagnostics: diagnostics}
	}
}

// consumeSendCmd finalizes one send-request: it deletes the durable request file
// then appends the outcome event (sent | send_refused). The delete lands first
// so the journal row can never precede the consume it records — the durable-
// before-journal ordering the substrate integration relies on.
func consumeSendCmd(sessionsDir, script, kdir, requestID string, ev session.Event) tea.Cmd {
	return func() tea.Msg {
		if err := session.DeleteSendRequest(sessionsDir, requestID); err != nil {
			return sendConsumedMsg{requestID: requestID, err: err}
		}
		return sendConsumedMsg{requestID: requestID, err: session.AppendEvent(script, kdir, ev)}
	}
}

// deleteSendRequestCmd consumes a gate-passing send by deleting its request file
// with no journal row: the outcome (sent | send_refused reason=unsubmitted) is
// deferred to the verification loop. The delete is still the durable consume and
// lands before any outcome row, preserving the delete-before-journal ordering.
func deleteSendRequestCmd(sessionsDir, requestID string) tea.Cmd {
	return func() tea.Msg {
		return sendConsumedMsg{requestID: requestID, err: session.DeleteSendRequest(sessionsDir, requestID)}
	}
}

// --- handlers ---

// handleSendRequestScan runs the readiness gate for each matched send-request
// and either injects the message or refuses it, then dispatches the delete +
// journal consume. The gate reads the panel's live screen, so it runs here in
// Update (the Bubble Tea goroutine), never in the consume Cmd goroutine.
func (m model) handleSendRequestScan(msg sendRequestScanMsg) (model, tea.Cmd) {
	diagnosticCmd := appendDiagnosticsCmd(m.sessionsDir, msg.diagnostics)
	if len(msg.matched) == 0 {
		return m, diagnosticCmd
	}
	framework, ferr := config.ResolveTUILaunchFramework()
	hasContract := false
	submitSeq := ""
	if ferr == nil {
		if ok, err := config.HarnessSignatureContract(framework); err == nil {
			hasContract = ok
		}
		if seq, ok, err := config.HarnessSubmitSequence(framework); err == nil && ok {
			submitSeq = seq
		}
	}
	var cmds []tea.Cmd
	if diagnosticCmd != nil {
		cmds = append(cmds, diagnosticCmd)
	}
	for _, sr := range msg.matched {
		if m.pendingSend[sr.RequestID] {
			continue // consume already in flight for this request
		}
		if _, verifying := m.pendingSendVerify[sr.RequestID]; verifying {
			continue // injected already; its outcome is deferred to the verify loop
		}
		panel, ok := m.sessionPanels[sr.Slug]
		if !ok {
			continue // slug no longer hosted here (raced teardown); leave the row
		}
		if m.pendingSend == nil {
			m.pendingSend = make(map[string]bool)
		}
		m.pendingSend[sr.RequestID] = true

		injected := false
		reason := sendReasonNoContract
		if ferr != nil {
			// framework unresolved → no contract to gate against
		} else if snap, serr := panel.ScreenState(); serr != nil {
			reason = sendReasonInternal
		} else {
			var ready bool
			ready, reason = sendReadiness(framework, panel.NeedsInput(), hasContract, snap)
			if ready {
				if err := panel.InjectMessage(sr.Body, submitSeq, snap.BracketedPaste); err != nil {
					if errors.Is(err, work.ErrUnsafePayload) {
						reason = sendReasonUnsafe
					} else {
						reason = sendReasonInternal
						m.flashErr = compactErr("session send", err)
					}
				} else {
					injected = true
					reason = ""
				}
			}
		}

		if injected {
			// The paste reached the composer. Consume by deleting the row now, but
			// hold the outcome: `sent` means observed-submitted, so it defers until a
			// later tick confirms the composer submitted (or a bounded retry gives up
			// with send_refused reason=unsubmitted). The delete still lands first.
			if m.pendingSendVerify == nil {
				m.pendingSendVerify = make(map[string]pendingSendState)
			}
			m.pendingSendVerify[sr.RequestID] = pendingSendState{
				slug:       sr.Slug,
				requestID:  sr.RequestID,
				submitSeq:  submitSeq,
				injectedAt: time.Now(),
			}
			cmds = append(cmds, deleteSendRequestCmd(m.sessionsDir, sr.RequestID))
			continue
		}

		// A gate refusal (or an inject-time failure) is terminal now: no submission
		// to verify, so delete + journal the outcome in one consume, as before.
		if reason == sendReasonNoContract {
			m = m.routeRuntimeNotices([]runtimeNotice{noContractNotice(framework)})
		}
		ev := m.sendOutcomeEvent(sr, false, reason)
		cmds = append(cmds, consumeSendCmd(m.sessionsDir, m.eventScript, m.config.KnowledgeDir, sr.RequestID, ev))
	}
	if len(cmds) == 0 {
		return m, nil
	}
	return m, tea.Batch(cmds...)
}

// handleSendConsumed clears the in-flight guard and surfaces a failed consume.
// The verify entry (added at inject time) is untouched — it owns the deferred
// outcome regardless of whether the row delete itself succeeded.
func (m model) handleSendConsumed(msg sendConsumedMsg) (model, tea.Cmd) {
	delete(m.pendingSend, msg.requestID)
	if msg.err != nil {
		m.flashErr = compactErr("session send", msg.err)
	}
	return m, nil
}

// sendVerifyGrace is how long a deferred send waits for an unclassifiable
// post-inject screen before it journals send_refused reason=unsubmitted. Seam: a
// zero field falls back to sendVerifyGraceDefault; tests inject a small value.
func (m model) sendVerifyGraceOr() time.Duration {
	if m.sendVerifyGrace > 0 {
		return m.sendVerifyGrace
	}
	return sendVerifyGraceDefault
}

// observeSendState classifies a panel's post-inject screen. It routes through the
// observeSendFn seam when set (tests), otherwise resolves the active harness and
// reads the live screen — the panel needs_input edge plus a ScreenSnapshot fed
// through observeSend. Any failure (no framework, snapshot error) reads as
// unobservable so a screen we cannot classify never forces a premature terminal
// before the grace elapses.
func (m model) observeSendState(panel work.SessionPanelModel) sendObs {
	if m.observeSendFn != nil {
		return m.observeSendFn(panel)
	}
	framework, err := config.ResolveTUILaunchFramework()
	if err != nil {
		return obsUnobservable
	}
	snap, serr := panel.ScreenState()
	if serr != nil {
		return obsUnobservable
	}
	return observeSend(framework, panel.NeedsInput(), snap)
}

// advanceSendVerifications resolves every deferred send outcome on the poll tick.
// For each pending verification it re-observes the composer and either journals
// the terminal or waits. It reads the shared terminal backend (via ScreenState),
// so — like advanceCloseLadders — it runs on the Bubble Tea goroutine, never in a
// Cmd goroutine. Each resolved entry is dropped the moment its outcome row is
// dispatched, so every gate-passing send produces exactly one terminal.
func (m model) advanceSendVerifications() (model, []tea.Cmd) {
	if len(m.pendingSendVerify) == 0 {
		return m, nil
	}
	var cmds []tea.Cmd
	for reqID, ps := range m.pendingSendVerify {
		panel, ok := m.sessionPanels[ps.slug]
		if !ok {
			// Panel gone (raced teardown): the submission can no longer be observed,
			// so the honest terminal is send_refused reason=unsubmitted — the requester
			// gets one outcome rather than timing out.
			delete(m.pendingSendVerify, reqID)
			cmds = append(cmds, m.sendVerifyTerminalCmd(ps, false))
			continue
		}
		obs := m.observeSendState(panel)
		switch obs {
		case obsSubmitted:
			delete(m.pendingSendVerify, reqID)
			cmds = append(cmds, m.sendVerifyTerminalCmd(ps, true))
		case obsPending:
			if !ps.retried {
				// The composer still holds the payload: replay the submit sequence once
				// (a bare submit, no re-paste) to commit the already-present text — the
				// field-precedented recovery. Best-effort; a missing PTY leaves the
				// deadline to close it out.
				_ = panel.SubmitSequence(ps.submitSeq)
				ps.retried = true
				m.pendingSendVerify[reqID] = ps
				continue
			}
			// Retried and still holding content on a later tick: the submit did not
			// take. Journal the truthful refusal.
			delete(m.pendingSendVerify, reqID)
			cmds = append(cmds, m.sendVerifyTerminalCmd(ps, false))
		default: // obsUnobservable
			if time.Since(ps.injectedAt) >= m.sendVerifyGraceOr() {
				delete(m.pendingSendVerify, reqID)
				cmds = append(cmds, m.sendVerifyTerminalCmd(ps, false))
			}
		}
	}
	return m, cmds
}

// sendVerifyTerminalCmd journals a deferred send's single outcome row: `sent`
// (observed-submitted) or send_refused reason=unsubmitted. The request file is
// already deleted, so this appends only.
func (m model) sendVerifyTerminalCmd(ps pendingSendState, submitted bool) tea.Cmd {
	reason := ""
	if !submitted {
		reason = sendReasonUnsubmitted
	}
	ev := m.sendOutcomeEvent(session.SendRequest{Slug: ps.slug, RequestID: ps.requestID}, submitted, reason)
	return journalCmd(m.eventScript, m.config.KnowledgeDir, ev)
}

// sendOutcomeEvent builds the sent / send_refused journal row for one consumed
// send-request. Both carry the request_id (so `session send --wait` can match
// its outcome by id); a refusal carries the gate reason.
func (m model) sendOutcomeEvent(sr session.SendRequest, sent bool, reason string) session.Event {
	ev := session.Event{
		ActorInstance: session.StrPtr(m.instanceName),
		Slug:          sr.Slug,
		RequestID:     sr.RequestID,
	}
	if ls, ok := m.localSessions[sr.Slug]; ok {
		ev.SessionType = ls.typ
		ev.Initiator = ls.initiator
	}
	if sent {
		ev.Event = session.EventSent
	} else {
		ev.Event = session.EventSendRefused
		ev.Reason = reason
	}
	return ev
}
