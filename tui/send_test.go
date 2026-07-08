package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// Post-inject composer fixtures. The submitted shapes mirror a real claude-code
// screen after a trailing CR takes (empty prompt + spinner / empty-ready again);
// the pending shape carries a "[Pasted text #N]" chip inside the composer band —
// the paste-collapse swallow signature. These model the states the operator's
// live rebuild will confirm against a real ~1100-char send.
var (
	ccPasteChipComposerRows = []string{
		"  earlier transcript line",
		rule,
		"❯ [Pasted text #1 +42 lines]",
		rule,
		"  ? for shortcuts",
	}
	// A chip that has already been submitted scrolls up into the transcript above
	// the composer band; the empty composer sits below it. Region scoping must NOT
	// read this as pending.
	ccSentChipHistoryRows = []string{
		"> [Pasted text #1 +42 lines]",
		"✶ Musing… (3s · thinking)",
		rule,
		"❯ ",
		rule,
		"  ? for shortcuts",
	}
	ccGeneratingRows = []string{
		"✶ Musing… (12s · esc to interrupt)",
		"  building the reply",
	}
)

// TestObserveSend covers the deferred-outcome classifier over fake snapshots: the
// held-payload chip reads pending regardless of the quiescence edge, a generating
// session or an empty-ready composer reads submitted, and anything else (unknown
// framework, unclassifiable rows) reads unobservable so the caller waits.
func TestObserveSend(t *testing.T) {
	cases := []struct {
		name      string
		framework string
		quiescent bool
		rows      []string
		ansi      string
		want      sendObs
	}{
		{"pending-chip-quiescent", "claude-code", true, ccPasteChipComposerRows, "", obsPending},
		// The swallow leaves the chip up even before the quiescence timer trips, so
		// the pending read must not depend on the needs_input edge.
		{"pending-chip-not-yet-quiescent", "claude-code", false, ccPasteChipComposerRows, "", obsPending},
		{"submitted-generating", "claude-code", false, ccGeneratingRows, "", obsSubmitted},
		{"submitted-empty-ready", "claude-code", true, ccComposerRows, "", obsSubmitted},
		{"submitted-faint-placeholder", "claude-code", true, ccGhostRows, ccGhostANSI, obsSubmitted},
		{"pending-real-held-input", "claude-code", true, ccHeldRows, ccHeldANSI, obsPending},
		// A sent chip in the transcript above an empty composer is submitted, not
		// pending (region scoping excludes the history).
		{"submitted-sent-chip-in-history", "claude-code", false, ccSentChipHistoryRows, "", obsSubmitted},
		{"unobservable-quiescent-no-signature", "claude-code", true, []string{"partial", "repaint"}, "", obsUnobservable},
		{"unknown-framework", "ghostwriter", true, ccComposerRows, "", obsUnobservable},
		// codex has no pending matcher: it degrades to the generating/empty-ready
		// signals (a composer-ready screen reads submitted).
		{"codex-degrades-to-composer-signal", "codex", true, cxComposerRows, "", obsSubmitted},
	}
	for _, c := range cases {
		snap := work.ScreenSnapshot{Rows: c.rows, ANSI: c.ansi}
		got := observeSend(c.framework, c.quiescent, snap)
		if got != c.want {
			t.Errorf("%s: observeSend = %v, want %v", c.name, got, c.want)
		}
	}
}

// TestCcComposerPending_ScopesToComposerRegion pins the region scoping: a chip in
// the composer band is a held payload, but the same chip scrolled into the
// transcript above the band is a sent message, not pending.
func TestCcComposerPending_ScopesToComposerRegion(t *testing.T) {
	if !ccComposerPending(ccPasteChipComposerRows) {
		t.Error("a chip inside the composer band should read pending")
	}
	if ccComposerPending(ccSentChipHistoryRows) {
		t.Error("a chip above the composer band (submitted) must not read pending")
	}
	if ccComposerPending(ccComposerRows) {
		t.Error("an empty-ready composer must not read pending")
	}
}

// seedSendVerify builds a model wired to the real appender with one pending send
// verification for slug "demo" injected `age` ago, plus a live session so the
// outcome row carries session_type/initiator.
func seedSendVerify(t *testing.T, age time.Duration) (model, string) {
	t.Helper()
	m, _ := baseSessionModel(t)
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	m.localSessions = map[string]liveSession{"demo": {typ: "spec", initiator: "agent", started: time.Now()}}
	m.sessionPanels = map[string]work.SessionPanelModel{"demo": work.NewSessionPanelModel("demo")}
	m.pendingSendVerify = map[string]pendingSendState{
		"s1": {slug: "demo", requestID: "s1", submitSeq: "\r", injectedAt: time.Now().Add(-age)},
	}
	return m, m.config.KnowledgeDir
}

// TestAdvanceSendVerifications_SubmittedJournalsSent: a confirmed submission
// journals exactly one `sent` row carrying the request id and clears the entry.
func TestAdvanceSendVerifications_SubmittedJournalsSent(t *testing.T) {
	m, kdir := seedSendVerify(t, 0)
	m.observeSendFn = func(work.SessionPanelModel) sendObs { return obsSubmitted }

	m, cmds := m.advanceSendVerifications()
	if _, pending := m.pendingSendVerify["s1"]; pending {
		t.Fatal("verify entry not cleared after a confirmed submission")
	}
	for _, c := range cmds {
		runJournalCmds(t, c)
	}
	rows := readEventRows(t, kdir)
	if len(rows) != 1 || rows[0].Event != session.EventSent {
		t.Fatalf("events = %+v, want exactly [sent]", rows)
	}
	if rows[0].RequestID != "s1" {
		t.Errorf("sent row request_id = %q, want s1", rows[0].RequestID)
	}
}

// TestAdvanceSendVerifications_RetryThenSubmitted: a still-pending composer
// replays the submit sequence once (no terminal, entry retained + marked retried),
// and the next tick's confirmed submission journals `sent`.
func TestAdvanceSendVerifications_RetryThenSubmitted(t *testing.T) {
	m, kdir := seedSendVerify(t, 0)
	obs := []sendObs{obsPending, obsSubmitted}
	i := 0
	m.observeSendFn = func(work.SessionPanelModel) sendObs {
		o := obs[i]
		i++
		return o
	}

	// Tick 1: pending → retry, no terminal yet.
	m, cmds := m.advanceSendVerifications()
	if len(cmds) != 0 {
		t.Fatalf("retry tick dispatched %d journal cmds, want 0", len(cmds))
	}
	ps, pending := m.pendingSendVerify["s1"]
	if !pending {
		t.Fatal("verify entry cleared on the retry tick (should wait for the retry to settle)")
	}
	if !ps.retried {
		t.Fatal("submit sequence not marked replayed after a pending observation")
	}

	// Tick 2: submitted → sent.
	m, cmds = m.advanceSendVerifications()
	if _, pending := m.pendingSendVerify["s1"]; pending {
		t.Fatal("verify entry not cleared after submission confirmed post-retry")
	}
	for _, c := range cmds {
		runJournalCmds(t, c)
	}
	if got := readEventTypes(t, kdir); len(got) != 1 || got[0] != session.EventSent {
		t.Fatalf("events = %v, want exactly [sent]", got)
	}
}

// TestAdvanceSendVerifications_RetryThenUnsubmitted: the retry is spent once — a
// composer still holding the payload on the tick after the replay journals
// send_refused reason=unsubmitted (exactly one terminal), never a second retry.
func TestAdvanceSendVerifications_RetryThenUnsubmitted(t *testing.T) {
	m, kdir := seedSendVerify(t, 0)
	m.observeSendFn = func(work.SessionPanelModel) sendObs { return obsPending }

	// Tick 1: pending, first sighting → retry, keep waiting.
	m, cmds := m.advanceSendVerifications()
	if len(cmds) != 0 {
		t.Fatalf("first pending tick dispatched %d cmds, want 0 (retry only)", len(cmds))
	}
	if !m.pendingSendVerify["s1"].retried {
		t.Fatal("first pending observation should replay the submit sequence")
	}

	// Tick 2: still pending after the retry → truthful refusal.
	m, cmds = m.advanceSendVerifications()
	if _, pending := m.pendingSendVerify["s1"]; pending {
		t.Fatal("verify entry not cleared after the retry failed")
	}
	for _, c := range cmds {
		runJournalCmds(t, c)
	}
	rows := readEventRows(t, kdir)
	if len(rows) != 1 || rows[0].Event != session.EventSendRefused {
		t.Fatalf("events = %+v, want exactly [send_refused]", rows)
	}
	if rows[0].Reason != sendReasonUnsubmitted {
		t.Errorf("refusal reason = %q, want %q", rows[0].Reason, sendReasonUnsubmitted)
	}
	if rows[0].RequestID != "s1" {
		t.Errorf("refusal row request_id = %q, want s1", rows[0].RequestID)
	}
}

// TestAdvanceSendVerifications_UnobservableDeadline: an unclassifiable screen
// waits within the grace, then journals send_refused reason=unsubmitted once the
// grace elapses.
func TestAdvanceSendVerifications_UnobservableDeadline(t *testing.T) {
	// Within grace: no terminal, entry retained.
	m, _ := seedSendVerify(t, 0)
	m.sendVerifyGrace = time.Hour
	m.observeSendFn = func(work.SessionPanelModel) sendObs { return obsUnobservable }
	m, cmds := m.advanceSendVerifications()
	if len(cmds) != 0 {
		t.Fatalf("unobservable-within-grace dispatched %d cmds, want 0", len(cmds))
	}
	if _, pending := m.pendingSendVerify["s1"]; !pending {
		t.Fatal("verify entry dropped before the grace elapsed")
	}

	// Grace elapsed: journal unsubmitted.
	m2, kdir := seedSendVerify(t, 2*time.Hour)
	m2.sendVerifyGrace = time.Hour
	m2.observeSendFn = func(work.SessionPanelModel) sendObs { return obsUnobservable }
	m2, cmds = m2.advanceSendVerifications()
	if _, pending := m2.pendingSendVerify["s1"]; pending {
		t.Fatal("verify entry not cleared after the grace elapsed")
	}
	for _, c := range cmds {
		runJournalCmds(t, c)
	}
	rows := readEventRows(t, kdir)
	if len(rows) != 1 || rows[0].Event != session.EventSendRefused || rows[0].Reason != sendReasonUnsubmitted {
		t.Fatalf("events = %+v, want exactly [send_refused unsubmitted]", rows)
	}
}

// TestAdvanceSendVerifications_PanelGoneJournalsUnsubmitted: a raced teardown that
// removes the panel before the outcome resolves still emits one terminal
// (send_refused reason=unsubmitted) so a `--wait` requester never hangs.
func TestAdvanceSendVerifications_PanelGoneJournalsUnsubmitted(t *testing.T) {
	m, kdir := seedSendVerify(t, 0)
	delete(m.sessionPanels, "demo") // panel torn down

	m, cmds := m.advanceSendVerifications()
	if _, pending := m.pendingSendVerify["s1"]; pending {
		t.Fatal("verify entry not cleared when the panel vanished")
	}
	for _, c := range cmds {
		runJournalCmds(t, c)
	}
	rows := readEventRows(t, kdir)
	if len(rows) != 1 || rows[0].Event != session.EventSendRefused || rows[0].Reason != sendReasonUnsubmitted {
		t.Fatalf("events = %+v, want exactly [send_refused unsubmitted]", rows)
	}
}

// plantSendRequest writes a send-request row for the refusal-path consume test.
func plantSendRequest(t *testing.T, sessionsDir string, sr session.SendRequest) {
	t.Helper()
	dir := session.SendRequestsDir(sessionsDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(sr)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, sr.RequestID+".json"), data, 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestHandleSendRequestScan_RefusalConsumesImmediately: a gate refusal (here a
// backendless panel whose screen cannot be read / whose harness has no contract)
// deletes the request file and journals its send_refused row in one consume — no
// verify entry is created, so the immediate-terminal path is preserved for the
// paths this phase does not change.
func TestHandleSendRequestScan_RefusalConsumesImmediately(t *testing.T) {
	m, sessionsDir := baseSessionModel(t)
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	kdir := m.config.KnowledgeDir
	m.localSessions = map[string]liveSession{"demo": {typ: "spec", initiator: "agent", started: time.Now()}}
	m.sessionPanels = map[string]work.SessionPanelModel{"demo": work.NewSessionPanelModel("demo")}
	plantSendRequest(t, sessionsDir, session.SendRequest{RequestID: "s1", Slug: "demo", TargetInstance: "me", Body: "hi"})

	m, cmd := m.handleSendRequestScan(sendRequestScanMsg{matched: []session.SendRequest{
		{RequestID: "s1", Slug: "demo", TargetInstance: "me", Body: "hi"},
	}})
	if len(m.pendingSendVerify) != 0 {
		t.Fatalf("a refusal created a deferred verify entry: %+v", m.pendingSendVerify)
	}
	runJournalCmds(t, cmd)

	// The consume deletes the request file (delete-before-journal) and lands one
	// send_refused row.
	if _, err := os.Stat(filepath.Join(session.SendRequestsDir(sessionsDir), "s1.json")); !os.IsNotExist(err) {
		t.Error("refusal did not delete the request file")
	}
	rows := readEventRows(t, kdir)
	if len(rows) != 1 || rows[0].Event != session.EventSendRefused {
		t.Fatalf("events = %+v, want exactly [send_refused]", rows)
	}
	if rows[0].RequestID != "s1" {
		t.Errorf("refusal row request_id = %q, want s1", rows[0].RequestID)
	}
}
