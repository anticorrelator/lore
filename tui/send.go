package main

import (
	"errors"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// --- messages ---

// sendRequestScanMsg carries the send-requests addressed to this instance for a
// slug it hosts, discovered on the poll tick.
type sendRequestScanMsg struct {
	matched []session.SendRequest
}

// sendConsumedMsg reports the outcome of consuming (deleting + journaling) one
// matched send-request.
type sendConsumedMsg struct {
	requestID string
	err       error
}

// --- Cmds ---

// scanSendRequestsCmd reads send-requests/ and returns the rows addressed to
// this instance (target_instance == myName) for a slug it currently hosts —
// both filters must hold, mirroring scanCloseRequestsCmd. hosted is snapshotted
// at Cmd-build time.
func scanSendRequestsCmd(sessionsDir, myName string, hosted map[string]bool) tea.Cmd {
	return func() tea.Msg {
		var matched []session.SendRequest
		for _, sr := range session.ScanSendRequests(sessionsDir) {
			if sr.RequestID == "" || sr.TargetInstance != myName {
				continue
			}
			if !hosted[sr.Slug] {
				continue
			}
			matched = append(matched, sr)
		}
		return sendRequestScanMsg{matched: matched}
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

// --- handlers ---

// handleSendRequestScan runs the readiness gate for each matched send-request
// and either injects the message or refuses it, then dispatches the delete +
// journal consume. The gate reads the panel's live screen, so it runs here in
// Update (the Bubble Tea goroutine), never in the consume Cmd goroutine.
func (m model) handleSendRequestScan(msg sendRequestScanMsg) (model, tea.Cmd) {
	if len(msg.matched) == 0 {
		return m, nil
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
	for _, sr := range msg.matched {
		if m.pendingSend[sr.RequestID] {
			continue // consume already in flight for this request
		}
		panel, ok := m.sessionPanels[sr.Slug]
		if !ok {
			continue // slug no longer hosted here (raced teardown); leave the row
		}
		if m.pendingSend == nil {
			m.pendingSend = make(map[string]bool)
		}
		m.pendingSend[sr.RequestID] = true

		sent := false
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
					sent = true
					reason = ""
				}
			}
		}
		if reason == sendReasonNoContract {
			noteNoContract(framework)
		}
		ev := m.sendOutcomeEvent(sr, sent, reason)
		cmds = append(cmds, consumeSendCmd(m.sessionsDir, m.eventScript, m.config.KnowledgeDir, sr.RequestID, ev))
	}
	if len(cmds) == 0 {
		return m, nil
	}
	return m, tea.Batch(cmds...)
}

// handleSendConsumed clears the in-flight guard and surfaces a failed consume.
func (m model) handleSendConsumed(msg sendConsumedMsg) (model, tea.Cmd) {
	delete(m.pendingSend, msg.requestID)
	if msg.err != nil {
		m.flashErr = compactErr("session send", msg.err)
	}
	return m, nil
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
