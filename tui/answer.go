package main

import (
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/session"
)

const (
	answerReasonNotModal          = "not-modal"
	answerReasonExpectMismatch    = "expect-mismatch"
	answerReasonOptionUnavailable = "option-unavailable"
	answerReasonNoContract        = "no-contract"
	answerReasonError             = "error"
	answerReasonUnconfirmed       = "unconfirmed"
	answerVerifyGraceDefault      = 12 * time.Second
)

type answerRequestScanMsg struct {
	matched     []session.AnswerRequest
	diagnostics []session.Diagnostic
}

type answerConsumedMsg struct {
	requestID string
	err       error
}

type pendingAnswerState struct {
	slug      string
	requestID string
	option    int
	expect    string
	writtenAt time.Time
}

func scanAnswerRequestsCmd(sessionsDir, myName string, hosted map[string]bool) tea.Cmd {
	return func() tea.Msg {
		var matched []session.AnswerRequest
		rows, diagnostics := session.ScanAnswerRequestsWithDiagnostics(sessionsDir)
		for _, request := range rows {
			if request.RequestID == "" || request.TargetInstance != myName || !hosted[request.Slug] {
				continue
			}
			matched = append(matched, request)
		}
		return answerRequestScanMsg{matched: matched, diagnostics: diagnostics}
	}
}

func consumeAnswerCmd(sessionsDir, script, kdir, requestID string, event session.Event) tea.Cmd {
	return func() tea.Msg {
		if err := session.DeleteAnswerRequest(sessionsDir, requestID); err != nil {
			return answerConsumedMsg{requestID: requestID, err: err}
		}
		return answerConsumedMsg{requestID: requestID, err: session.AppendEvent(script, kdir, event)}
	}
}

func deleteAnswerRequestCmd(sessionsDir, requestID string) tea.Cmd {
	return func() tea.Msg {
		return answerConsumedMsg{requestID: requestID, err: session.DeleteAnswerRequest(sessionsDir, requestID)}
	}
}

func optionDelta(state screenClass, requested int) (int, bool) {
	selectedIndex, requestedIndex := -1, -1
	for i, option := range state.availableOptions {
		if option == state.selectedOption {
			selectedIndex = i
		}
		if option == requested {
			requestedIndex = i
		}
	}
	if selectedIndex < 0 || requestedIndex < 0 {
		return 0, false
	}
	return requestedIndex - selectedIndex, true
}

func (m model) handleAnswerRequestScan(msg answerRequestScanMsg) (model, tea.Cmd) {
	framework, resolveErr := config.ResolveTUILaunchFramework()
	hasContract := false
	contractErr := resolveErr
	if resolveErr == nil {
		hasContract, contractErr = config.HarnessSignatureContract(framework)
	}
	return m.handleAnswerRequestScanResolved(msg, framework, hasContract, contractErr)
}

// handleAnswerRequestScanResolved is the live consume path with framework
// resolution already performed. Keeping resolution outside the loop makes every
// request on a poll tick use the same capability contract.
func (m model) handleAnswerRequestScanResolved(msg answerRequestScanMsg, framework string, hasContract bool, contractErr error) (model, tea.Cmd) {
	diagnosticCmd := appendDiagnosticsCmd(m.sessionsDir, msg.diagnostics)
	if len(msg.matched) == 0 {
		return m, diagnosticCmd
	}
	var cmds []tea.Cmd
	if diagnosticCmd != nil {
		cmds = append(cmds, diagnosticCmd)
	}
	busySlugs := make(map[string]bool)
	for _, pending := range m.pendingAnswerVerify {
		busySlugs[pending.slug] = true
	}
	for _, request := range msg.matched {
		if m.pendingAnswer[request.RequestID] {
			continue
		}
		if _, verifying := m.pendingAnswerVerify[request.RequestID]; verifying || busySlugs[request.Slug] {
			continue
		}
		panel, ok := m.sessionPanels[request.Slug]
		if !ok {
			continue
		}
		if m.pendingAnswer == nil {
			m.pendingAnswer = make(map[string]bool)
		}
		m.pendingAnswer[request.RequestID] = true

		reason := ""
		wrote := false
		if contractErr != nil {
			reason = answerReasonError
		} else if !hasContract {
			reason = answerReasonNoContract
		} else if snap, err := panel.ScreenState(); err != nil {
			reason = answerReasonError
		} else if state, known := classifyScreen(framework, snap); !known {
			reason = answerReasonNoContract
		} else if !state.interactive {
			reason = answerReasonNotModal
		} else if request.Expect == "" || !strings.Contains(strings.Join(snap.Rows, "\n"), request.Expect) {
			reason = answerReasonExpectMismatch
		} else if delta, available := optionDelta(state, request.Option); !available {
			reason = answerReasonOptionUnavailable
		} else if err := panel.SelectModalOption(delta); err != nil {
			reason = answerReasonError
			m.flashErr = compactErr("session answer", err)
		} else {
			wrote = true
			if m.pendingAnswerVerify == nil {
				m.pendingAnswerVerify = make(map[string]pendingAnswerState)
			}
			m.pendingAnswerVerify[request.RequestID] = pendingAnswerState{
				slug: request.Slug, requestID: request.RequestID, option: request.Option,
				expect: request.Expect, writtenAt: time.Now(),
			}
			busySlugs[request.Slug] = true
		}

		if wrote {
			cmds = append(cmds, deleteAnswerRequestCmd(m.sessionsDir, request.RequestID))
			continue
		}
		if reason == answerReasonNoContract {
			m = m.routeRuntimeNotices([]runtimeNotice{noContractNotice(framework)})
		}
		cmds = append(cmds, consumeAnswerCmd(m.sessionsDir, m.eventScript, m.config.KnowledgeDir,
			request.RequestID, m.answerOutcomeEvent(request, false, reason)))
	}
	if len(cmds) == 0 {
		return m, nil
	}
	return m, tea.Batch(cmds...)
}

func (m model) handleAnswerConsumed(msg answerConsumedMsg) (model, tea.Cmd) {
	if msg.err != nil {
		// Keep the in-memory consume latch armed when deletion or journaling
		// fails. In particular, a modal key sequence must never be replayed just
		// because its durable request row could not be removed.
		m.flashErr = compactErr("session answer", msg.err)
		return m, nil
	}
	delete(m.pendingAnswer, msg.requestID)
	return m, nil
}

func (m model) answerVerifyGraceOr() time.Duration {
	if m.answerVerifyGrace > 0 {
		return m.answerVerifyGrace
	}
	return answerVerifyGraceDefault
}

func (m model) advanceAnswerVerifications() (model, []tea.Cmd) {
	if len(m.pendingAnswerVerify) == 0 {
		return m, nil
	}
	var cmds []tea.Cmd
	for requestID, pending := range m.pendingAnswerVerify {
		panel, ok := m.sessionPanels[pending.slug]
		if !ok {
			delete(m.pendingAnswerVerify, requestID)
			cmds = append(cmds, m.answerVerifyTerminalCmd(pending, false))
			continue
		}
		snap, err := panel.ScreenState()
		visible := err == nil && strings.Contains(strings.Join(snap.Rows, "\n"), pending.expect)
		if err == nil && !visible {
			delete(m.pendingAnswerVerify, requestID)
			cmds = append(cmds, m.answerVerifyTerminalCmd(pending, true))
			continue
		}
		if time.Since(pending.writtenAt) >= m.answerVerifyGraceOr() {
			delete(m.pendingAnswerVerify, requestID)
			cmds = append(cmds, m.answerVerifyTerminalCmd(pending, false))
		}
	}
	return m, cmds
}

func (m model) answerVerifyTerminalCmd(pending pendingAnswerState, confirmed bool) tea.Cmd {
	request := session.AnswerRequest{
		RequestID: pending.requestID, Slug: pending.slug, Option: pending.option,
	}
	reason := ""
	if !confirmed {
		reason = answerReasonUnconfirmed
	}
	return journalCmd(m.eventScript, m.config.KnowledgeDir, m.answerOutcomeEvent(request, confirmed, reason))
}

func (m model) answerOutcomeEvent(request session.AnswerRequest, answered bool, reason string) session.Event {
	event := session.Event{
		ActorInstance: session.StrPtr(m.instanceName), Slug: request.Slug,
		RequestID: request.RequestID, Option: request.Option,
	}
	if live, ok := m.localSessions[request.Slug]; ok {
		event.SessionType = live.typ
		event.Initiator = live.initiator
	}
	if answered {
		event.Event = session.EventAnswered
	} else {
		event.Event = session.EventAnswerRefused
		event.Reason = reason
	}
	return event
}
