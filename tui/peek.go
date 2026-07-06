package main

import (
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
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
	matched []session.PeekRequest
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
func scanPeekRequestsCmd(sessionsDir, myName string, hosted map[string]bool) tea.Cmd {
	return func() tea.Msg {
		session.GCPeekResponses(sessionsDir, peekResponseTTL)
		var matched []session.PeekRequest
		for _, pr := range session.ScanPeekRequests(sessionsDir) {
			if pr.RequestID == "" || pr.TargetInstance != myName {
				continue
			}
			if !hosted[pr.Slug] {
				continue
			}
			matched = append(matched, pr)
		}
		return peekRequestScanMsg{matched: matched}
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
	if len(msg.matched) == 0 {
		return m, nil
	}
	framework, ferr := config.ResolveTUILaunchFramework()
	hasContract := false
	if ferr == nil {
		if ok, err := config.HarnessSignatureContract(framework); err == nil {
			hasContract = ok
		}
	}
	var cmds []tea.Cmd
	for _, pr := range msg.matched {
		if m.pendingPeek[pr.RequestID] {
			continue
		}
		panel, ok := m.sessionPanels[pr.Slug]
		if !ok {
			continue
		}
		if m.pendingPeek == nil {
			m.pendingPeek = make(map[string]bool)
		}
		m.pendingPeek[pr.RequestID] = true

		resp := session.PeekResponse{
			RequestID:  pr.RequestID,
			Slug:       pr.Slug,
			CapturedAt: time.Now().UTC().Format("2006-01-02T15:04:05Z"),
		}
		if snap, serr := panel.ScreenState(); serr != nil {
			resp.Ready = false
			resp.BlockedReason = sendReasonInternal
		} else {
			ready, reason := false, sendReasonNoContract
			if ferr == nil {
				ready, reason = sendReadiness(framework, panel.NeedsInput(), hasContract, snap)
			}
			resp.Ready = ready
			resp.BlockedReason = reason
			resp.Rows = snap.Rows
			if pr.Raw {
				resp.ANSI = snap.ANSI
			}
			if reason == sendReasonNoContract {
				noteNoContract(framework)
			}
		}
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
