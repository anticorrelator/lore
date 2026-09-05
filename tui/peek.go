package main

import (
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/session"
)

// peekResponseTTL bounds how long an orphaned peek-response survives before the
// owning instance garbage-collects it. The requester deletes its own response on
// read; this only reclaims responses whose requester timed out and exited.
const peekResponseTTL = 5 * time.Minute

// --- messages ---

// peekRequestScanMsg carries the peek-requests addressed to this instance for a
// slug it hosts, discovered on the poll tick.
type peekRequestScanMsg struct {
	matched     []session.PeekRequest
	diagnostics []session.Diagnostic
}

// peekRespondedMsg reports the outcome of responding to (and consuming) one
// matched peek-request.
type peekRespondedMsg struct {
	requestID string
	err       error
}

// --- Cmds ---

// scanPeekRequestsCmd garbage-collects stale peek-responses, then returns the
// peek-requests addressed to this instance for a slug it hosts. Both filters
// (target + hosted) must hold, mirroring the send/close scans.
func scanPeekRequestsCmd(sessionsDir, myName string, hosted map[string]bool, retarget ...bool) tea.Cmd {
	return func() tea.Msg {
		session.GCPeekResponses(sessionsDir, peekResponseTTL)
		var matched []session.PeekRequest
		rows, diagnostics := session.ScanPeekRequestsWithDiagnostics(sessionsDir)
		for _, pr := range rows {
			if pr.RequestID == "" || (pr.TargetInstance != myName && !hostRetarget(retarget)) {
				continue
			}
			if !hosted[pr.Slug] {
				continue
			}
			matched = append(matched, pr)
		}
		return peekRequestScanMsg{matched: matched, diagnostics: diagnostics}
	}
}

// respondPeekCmd writes the response file (tmp+atomic-rename) then deletes the
// request. The response lands before the consume so the polling requester never
// finds the request gone with no response to read.
func respondPeekCmd(sessionsDir, requestID string, resp session.PeekResponse) tea.Cmd {
	return func() tea.Msg {
		if err := session.WritePeekResponse(sessionsDir, resp); err != nil {
			return peekRespondedMsg{requestID: requestID, err: err}
		}
		return peekRespondedMsg{requestID: requestID, err: session.DeletePeekRequest(sessionsDir, requestID)}
	}
}

// --- handlers ---

// handlePeekRequestScan snapshots the panel's screen for each matched peek-
// request, classifies readiness with the same gate the send path uses, and
// dispatches the response write-back. The screen read runs here in Update.
func (m model) handlePeekRequestScan(msg peekRequestScanMsg) (model, tea.Cmd) {
	if m.peekHistory != nil {
		m.peekHistory.expire(time.Now())
	}
	diagnosticCmd := appendDiagnosticsCmd(m.sessionsDir, msg.diagnostics)
	if len(msg.matched) == 0 {
		return m, diagnosticCmd
	}
	var cmds []tea.Cmd
	if diagnosticCmd != nil {
		cmds = append(cmds, diagnosticCmd)
	}
	for _, pr := range msg.matched {
		if m.pendingPeek[pr.RequestID] {
			continue
		}
		_, ok := m.sessionPanels[pr.Slug]
		if !ok {
			continue
		}
		if m.pendingPeek == nil {
			m.pendingPeek = make(map[string]bool)
		}
		m.pendingPeek[pr.RequestID] = true

		if pr.Lines != 0 || pr.Before != "" || pr.MaxBytes != 0 || pr.Summary {
			var cmd tea.Cmd
			m, cmd = m.handleExtendedPeek(pr)
			cmds = append(cmds, cmd)
			continue
		}
		resp := m.peekSnapshot(pr.Slug, pr.RequestID, pr.Raw)

		cmds = append(cmds, respondPeekCmd(m.sessionsDir, pr.RequestID, resp))
	}
	if len(cmds) == 0 {
		return m, nil
	}
	return m, tea.Batch(cmds...)
}

// handlePeekResponded clears the in-flight guard and surfaces a failed response.
func (m model) handlePeekResponded(msg peekRespondedMsg) (model, tea.Cmd) {
	delete(m.pendingPeek, msg.requestID)
	if msg.err != nil {
		m.flashErr = compactErr("session peek", msg.err)
	}
	return m, nil
}

func (m model) peekSnapshot(slug, requestID string, raw bool) session.PeekResponse {
	panel := m.sessionPanels[slug]
	framework := m.sessionHarness(slug)
	now := time.Now()
	obs, snap, state := m.snapshotObservation(slug, now)
	resp := session.PeekResponse{RequestID: requestID, Slug: slug, CapturedAt: now.UTC().Format(time.RFC3339Nano), Framework: framework, Observation: obs, Ready: obs.CanAcceptInput, Rows: peekRows(framework, snap), Screen: session.PeekScreen{Source: "terminal-emulator", Width: int(snap.Columns), Height: len(snap.Rows), Scope: "viewport", Truncated: false}}
	if last := panel.LastOutputTime(); !last.IsZero() {
		resp.Screen.LastOutputAt = last.UTC().Format(time.RFC3339Nano)
	}
	resp.BlockedReason = obs.InputBlockedReason
	if !obs.Fresh {
		resp.BlockedReason = sendReasonInternal
	}

	if state.interactive {
		resp.Modal = &session.PeekModal{Signature: state.numberedModal, SelectedOption: state.selectedOption, Matcher: state.interactiveReason, Answerable: state.numberedModal != nil && state.selectedOption > 0}
		if state.numberedModal != nil {
			resp.Modal.Title = state.numberedModal.Title
			for _, option := range state.numberedModal.Options {
				resp.Modal.Options = append(resp.Modal.Options, session.PeekModalOption{Number: option.Number, Label: option.Label})
			}
		} else if framework == "opencode" {
			resp.Modal.Title = "Permission required"
			for _, label := range []string{"Allow once", "Allow always", "Reject"} {
				resp.Modal.Options = append(resp.Modal.Options, session.PeekModalOption{Label: label})
			}
		}
	}
	if raw {
		resp.ANSI = snap.ANSI
	}

	return resp
}
