package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

func answerPanel(t *testing.T, rows []string, attachPTY bool) (work.SessionPanelModel, *os.File) {
	t.Helper()
	panel := work.NewSessionPanelModel("demo")
	panel, _ = panel.Update(tea.WindowSizeMsg{Width: 120, Height: 12})
	stream := "\x1b[2J\x1b[H" + strings.Join(rows, "\r\n")
	panel, _ = panel.Update(work.TerminalOutputMsg{Slug: "demo", Data: []byte(stream)})
	if !attachPTY {
		return panel, nil
	}
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { reader.Close(); writer.Close() })
	return panel.SetPtmx(writer, nil, nil), reader
}

func plantAnswerRequest(t *testing.T, sessionsDir string, request session.AnswerRequest) {
	t.Helper()
	dir := session.AnswerRequestsDir(sessionsDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, request.RequestID+".json"), data, 0o644); err != nil {
		t.Fatal(err)
	}
}

func seedAnswerRequest(t *testing.T, rows []string, attachPTY bool, request session.AnswerRequest) (model, string, *os.File) {
	t.Helper()
	m, sessionsDir := baseSessionModel(t)
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	m.localSessions = map[string]liveSession{"demo": {typ: "implement", initiator: "agent", started: time.Now()}}
	panel, reader := answerPanel(t, rows, attachPTY)
	m.sessionPanels = map[string]work.SessionPanelModel{"demo": panel}
	plantAnswerRequest(t, sessionsDir, request)
	return m, sessionsDir, reader
}

func assertNoPTYBytes(t *testing.T, reader *os.File) {
	t.Helper()
	if reader == nil {
		return
	}
	if err := reader.SetReadDeadline(time.Now().Add(30 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 32)
	n, err := reader.Read(buf)
	if n != 0 || err == nil {
		t.Fatalf("pre-write refusal reached PTY: n=%d err=%v bytes=%q", n, err, buf[:n])
	}
}

func answerRequest(id string, option int, expect string) session.AnswerRequest {
	return session.AnswerRequest{
		RequestID: id, Slug: "demo", TargetInstance: "me", Option: option, Expect: expect,
	}
}

func TestAnswerGuardRefusalsWriteNoPTYBytes(t *testing.T) {
	cases := []struct {
		name        string
		rows        []string
		request     session.AnswerRequest
		hasContract bool
		attachPTY   bool
		wantReason  string
	}{
		{"not modal", ccComposerRows, answerRequest("not-modal", 1, "shortcuts"), true, true, answerReasonNotModal},
		{"expect mismatch", ccOptionSelectRows, answerRequest("expect", 1, "different modal"), true, true, answerReasonExpectMismatch},
		{"option unavailable", ccOptionSelectRows, answerRequest("option", 9, "Choose the next step"), true, true, answerReasonOptionUnavailable},
		{"no contract", ccOptionSelectRows, answerRequest("contract", 1, "Choose the next step"), false, true, answerReasonNoContract},
		{"PTY error", ccOptionSelectRows, answerRequest("pty", 2, "Choose the next step"), true, false, answerReasonError},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m, sessionsDir, reader := seedAnswerRequest(t, tc.rows, tc.attachPTY, tc.request)
			m, cmd := m.handleAnswerRequestScanResolved(answerRequestScanMsg{matched: []session.AnswerRequest{tc.request}}, "claude-code", tc.hasContract, nil)
			if len(m.pendingAnswerVerify) != 0 {
				t.Fatalf("refusal created verification state: %+v", m.pendingAnswerVerify)
			}
			runJournalCmds(t, cmd)
			assertNoPTYBytes(t, reader)
			if _, err := os.Stat(filepath.Join(session.AnswerRequestsDir(sessionsDir), tc.request.RequestID+".json")); !os.IsNotExist(err) {
				t.Fatal("refusal did not consume request before journaling")
			}
			rows := readEventRows(t, m.config.KnowledgeDir)
			if len(rows) != 1 || rows[0].Event != session.EventAnswerRefused || rows[0].Reason != tc.wantReason {
				t.Fatalf("events = %+v, want one answer_refused reason=%s", rows, tc.wantReason)
			}
			if rows[0].Option != tc.request.Option || rows[0].RequestID != tc.request.RequestID {
				t.Fatalf("refusal identity = %+v", rows[0])
			}
		})
	}
}

func TestAnswerWritesOnceAndConfirmsOnlyAfterExpectationDisappears(t *testing.T) {
	request := answerRequest("answer-2", 2, "Choose the next step")
	m, sessionsDir, reader := seedAnswerRequest(t, ccOptionSelectRows, true, request)
	m, cmd := m.handleAnswerRequestScanResolved(answerRequestScanMsg{matched: []session.AnswerRequest{request}}, "claude-code", true, nil)
	runJournalCmds(t, cmd)
	if _, ok := m.pendingAnswerVerify[request.RequestID]; !ok {
		t.Fatal("successful write did not create verification state")
	}
	if got := readEventRows(t, m.config.KnowledgeDir); len(got) != 0 {
		t.Fatalf("write alone claimed an outcome: %+v", got)
	}
	if _, err := os.Stat(filepath.Join(session.AnswerRequestsDir(sessionsDir), request.RequestID+".json")); !os.IsNotExist(err) {
		t.Fatal("gate-passing request was not deleted")
	}
	if err := reader.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 32)
	n, err := reader.Read(buf)
	if err != nil || string(buf[:n]) != "\x1b[B\r" {
		t.Fatalf("PTY bytes = %q err=%v, want Down+Enter", buf[:n], err)
	}

	panel, _ := answerPanel(t, ccComposerRows, false)
	m.sessionPanels["demo"] = panel
	m, cmds := m.advanceAnswerVerifications()
	for _, verifyCmd := range cmds {
		runJournalCmds(t, verifyCmd)
	}
	rows := readEventRows(t, m.config.KnowledgeDir)
	if len(rows) != 1 || rows[0].Event != session.EventAnswered || rows[0].Option != 2 {
		t.Fatalf("events = %+v, want one answered option=2", rows)
	}
	if _, ok := m.pendingAnswerVerify[request.RequestID]; ok {
		t.Fatal("confirmed answer retained verification state")
	}
}

func TestAnswerConfirmationTimeoutRefusesWithoutReplay(t *testing.T) {
	request := answerRequest("unconfirmed", 2, "Choose the next step")
	m, _, reader := seedAnswerRequest(t, ccOptionSelectRows, true, request)
	m, cmd := m.handleAnswerRequestScanResolved(answerRequestScanMsg{matched: []session.AnswerRequest{request}}, "claude-code", true, nil)
	runJournalCmds(t, cmd)
	pending := m.pendingAnswerVerify[request.RequestID]
	pending.writtenAt = time.Now().Add(-time.Hour)
	m.pendingAnswerVerify[request.RequestID] = pending
	m.answerVerifyGrace = time.Second

	m, cmds := m.advanceAnswerVerifications()
	for _, verifyCmd := range cmds {
		runJournalCmds(t, verifyCmd)
	}
	if err := reader.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 32)
	n, err := reader.Read(buf)
	if err != nil || string(buf[:n]) != "\x1b[B\r" {
		t.Fatalf("initial answer bytes = %q err=%v", buf[:n], err)
	}
	assertNoPTYBytes(t, reader)
	rows := readEventRows(t, m.config.KnowledgeDir)
	if len(rows) != 1 || rows[0].Event != session.EventAnswerRefused || rows[0].Reason != answerReasonUnconfirmed {
		t.Fatalf("events = %+v, want one answer_refused unconfirmed", rows)
	}
}

func TestAnswerPanelDisappearanceRefusesUnconfirmed(t *testing.T) {
	request := answerRequest("panel-gone", 2, "Choose the next step")
	m, _, reader := seedAnswerRequest(t, ccOptionSelectRows, true, request)
	m, cmd := m.handleAnswerRequestScanResolved(answerRequestScanMsg{matched: []session.AnswerRequest{request}}, "claude-code", true, nil)
	runJournalCmds(t, cmd)
	delete(m.sessionPanels, "demo")
	m, cmds := m.advanceAnswerVerifications()
	for _, verifyCmd := range cmds {
		runJournalCmds(t, verifyCmd)
	}
	if err := reader.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 32)
	n, err := reader.Read(buf)
	if err != nil || string(buf[:n]) != "\x1b[B\r" {
		t.Fatalf("initial answer bytes = %q err=%v", buf[:n], err)
	}
	rows := readEventRows(t, m.config.KnowledgeDir)
	if len(rows) != 1 || rows[0].Event != session.EventAnswerRefused || rows[0].Reason != answerReasonUnconfirmed {
		t.Fatalf("events = %+v, want one answer_refused unconfirmed", rows)
	}
}

func TestOptionDeltaUsesRenderedRowOrderNotNumericDifference(t *testing.T) {
	state, ok := classifyScreen("codex", work.ScreenSnapshot{Rows: cxOptionSelectRows})
	if !ok || !state.interactive {
		t.Fatal("codex option fixture is not interactive")
	}
	if delta, available := optionDelta(state, 4); !available || delta != 1 {
		t.Fatalf("option 2 -> 4 delta = %d available=%v, want one rendered row down", delta, available)
	}
}

func TestAnswerConsumeFailureKeepsNoReplayLatch(t *testing.T) {
	m := model{pendingAnswer: map[string]bool{"answer-1": true}}
	m, _ = m.handleAnswerConsumed(answerConsumedMsg{requestID: "answer-1", err: errors.New("delete failed")})
	if !m.pendingAnswer["answer-1"] {
		t.Fatal("consume failure cleared the no-replay latch")
	}
	m, _ = m.handleAnswerConsumed(answerConsumedMsg{requestID: "answer-1"})
	if m.pendingAnswer["answer-1"] {
		t.Fatal("successful consume retained request latch")
	}
}
