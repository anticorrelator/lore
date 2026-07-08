package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// TestTmuxProc_SignalsRealProcess: tmuxProc's Terminate delivers a real SIGTERM to
// its pane PID (not the attach client), the process actually dies, and Alive
// reports dead once the pid is freed. This is the D7 guarantee that under tmux the
// close ladder terminates the harness rather than detaching a viewer.
func TestTmuxProc_SignalsRealProcess(t *testing.T) {
	cmd := exec.Command("sleep", "30")
	if err := cmd.Start(); err != nil {
		t.Fatalf("start sleep: %v", err)
	}
	proc := tmuxProc{pid: cmd.Process.Pid}
	if !proc.Alive() {
		t.Fatal("freshly started process reads dead")
	}
	if err := proc.Terminate(); err != nil {
		t.Fatalf("Terminate: %v", err)
	}
	err := cmd.Wait() // reap so the pid is freed (a zombie would still read alive)
	if err == nil {
		t.Fatal("process survived SIGTERM")
	}
	if proc.Alive() {
		t.Error("pane process still signalable after SIGTERM + reap")
	}
}

// fakeProc is a scriptable harnessProc. It reports alive until
// signalsBeforeExit termination signals (Terminate/Kill each count once) have
// been delivered: 0 exits on its own (the graceful-exit path), 1 exits after
// SIGTERM, 2+ survives SIGTERM and requires Kill.
type fakeProc struct {
	termCalls         int
	killCalls         int
	aliveCalls        int
	signalsBeforeExit int
}

func (f *fakeProc) signals() int     { return f.termCalls + f.killCalls }
func (f *fakeProc) Terminate() error { f.termCalls++; return nil }
func (f *fakeProc) Kill() error      { f.killCalls++; return nil }
func (f *fakeProc) Alive() bool      { f.aliveCalls++; return f.signals() < f.signalsBeforeExit }

// fastLadder runs runCloseLadder with a tiny grace/poll so escalation never
// blocks on a real wait. The error return is exercised separately
// (TestRunCloseLadder_ExhaustedIsError); the rung-only cases discard it.
func fastLadder(proc harnessProc, ptmx io.Writer, exitSeq string, exitSupported bool, framework string) closeRung {
	rung, _ := runCloseLadder(proc, ptmx, exitSeq, exitSupported, framework, 5*time.Millisecond, time.Millisecond)
	return rung
}

// captureStderr redirects os.Stderr for the duration of fn and returns what was
// written — used to assert the explicit degradation notice.
func captureStderr(t *testing.T, fn func()) string {
	t.Helper()
	orig := os.Stderr
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stderr = w
	fn()
	_ = w.Close()
	os.Stderr = orig
	var buf bytes.Buffer
	_, _ = io.Copy(&buf, r)
	return buf.String()
}

// TestRunCloseLadder_DegradesToSIGTERM: with no capability sequence the ladder
// skips rung 1 with an explicit degradation notice, never touches the ptmx, and
// a process that exits on SIGTERM is never killed.
func TestRunCloseLadder_DegradesToSIGTERM(t *testing.T) {
	proc := &fakeProc{signalsBeforeExit: 1}
	var ptmx bytes.Buffer
	var rung closeRung
	out := captureStderr(t, func() {
		rung = fastLadder(proc, &ptmx, "", false, "claude-code")
	})

	if rung != rungSIGTERM {
		t.Errorf("rung = %d, want rungSIGTERM (%d)", rung, rungSIGTERM)
	}
	if proc.termCalls != 1 || proc.killCalls != 0 {
		t.Errorf("signals = {term:%d kill:%d}, want exactly one SIGTERM", proc.termCalls, proc.killCalls)
	}
	if ptmx.Len() != 0 {
		t.Errorf("ptmx written %q with no capability sequence", ptmx.String())
	}
	if !bytes.Contains([]byte(out), []byte("graceful_exit_sequence skipped")) ||
		!bytes.Contains([]byte(out), []byte("framework=claude-code")) {
		t.Errorf("missing degradation notice, stderr = %q", out)
	}
}

// TestRunCloseLadder_EscalatesToKill: a process that survives SIGTERM within the
// grace window is killed as the final fallback.
func TestRunCloseLadder_EscalatesToKill(t *testing.T) {
	proc := &fakeProc{signalsBeforeExit: 2} // survives SIGTERM
	rung := fastLadder(proc, nil, "", false, "claude-code")
	if rung != rungKill {
		t.Errorf("rung = %d, want rungKill (%d)", rung, rungKill)
	}
	if proc.termCalls != 1 || proc.killCalls != 1 {
		t.Errorf("signals = {term:%d kill:%d}, want SIGTERM then Kill", proc.termCalls, proc.killCalls)
	}
}

// TestRunCloseLadder_GracefulWhenCapability: when a capability sequence exists
// and the process exits after it is written, teardown stops at rung 1 — no
// SIGTERM, no Kill — and the ptmx received the sequence verbatim.
func TestRunCloseLadder_GracefulWhenCapability(t *testing.T) {
	proc := &fakeProc{signalsBeforeExit: 0} // exits from the graceful write alone
	var ptmx bytes.Buffer
	rung := fastLadder(proc, &ptmx, "\x1dq", true, "some-harness")
	if rung != rungGraceful {
		t.Errorf("rung = %d, want rungGraceful (%d)", rung, rungGraceful)
	}
	if proc.termCalls != 0 || proc.killCalls != 0 {
		t.Errorf("graceful exit still signalled: {term:%d kill:%d}", proc.termCalls, proc.killCalls)
	}
	if ptmx.String() != "\x1dq" {
		t.Errorf("ptmx = %q, want the capability sequence", ptmx.String())
	}
}

// TestRunCloseLadder_GracefulEscalatesToSIGTERM: a capability sequence that
// fails to make the process exit escalates to SIGTERM (monotonic step-down),
// proving rung 1 is not a dead end when it does not work.
func TestRunCloseLadder_GracefulEscalatesToSIGTERM(t *testing.T) {
	proc := &fakeProc{signalsBeforeExit: 1} // survives the graceful write, dies on SIGTERM
	var ptmx bytes.Buffer
	rung := fastLadder(proc, &ptmx, "\x1dq", true, "some-harness")
	if rung != rungSIGTERM {
		t.Errorf("rung = %d, want rungSIGTERM after graceful failed", rung)
	}
	if ptmx.String() != "\x1dq" {
		t.Errorf("ptmx = %q, want the sequence to have been attempted", ptmx.String())
	}
	if proc.killCalls != 0 {
		t.Errorf("process that exited on SIGTERM was still killed")
	}
}

// TestRunCloseLadder_NilProc: no attached process means nothing to terminate.
func TestRunCloseLadder_NilProc(t *testing.T) {
	if rung := fastLadder(nil, nil, "", false, "claude-code"); rung != rungNone {
		t.Errorf("rung = %d, want rungNone for a nil process", rung)
	}
}

// TestCloseLadder_Monotonic is the property form of the escalation invariant:
// across the (capability × process-stubbornness) matrix, the ladder never
// regresses — it only ever signals in the order graceful→SIGTERM→Kill, never
// kills a process that already exited, and never fires rung 1 without a
// capability sequence.
func TestCloseLadder_Monotonic(t *testing.T) {
	for _, exitSupported := range []bool{false, true} {
		for _, stubbornness := range []int{0, 1, 2} {
			proc := &fakeProc{signalsBeforeExit: stubbornness}
			var ptmx bytes.Buffer
			rung := fastLadder(proc, &ptmx, "seq", exitSupported, "fw")

			// Kill implies SIGTERM was tried first; SIGTERM implies no Kill.
			if proc.killCalls > 0 && proc.termCalls == 0 {
				t.Errorf("[cap=%v stub=%d] killed without a prior SIGTERM", exitSupported, stubbornness)
			}
			if rung == rungSIGTERM && proc.killCalls != 0 {
				t.Errorf("[cap=%v stub=%d] rung SIGTERM but process was killed", exitSupported, stubbornness)
			}
			if rung == rungGraceful && (proc.termCalls != 0 || proc.killCalls != 0) {
				t.Errorf("[cap=%v stub=%d] rung graceful but process was signalled", exitSupported, stubbornness)
			}
			// Rung 1 only fires from a capability sequence.
			if !exitSupported && rung == rungGraceful {
				t.Errorf("[cap=false stub=%d] reached graceful rung without a capability", stubbornness)
			}
			// Without a capability the ptmx is never written.
			if !exitSupported && ptmx.Len() != 0 {
				t.Errorf("[cap=false stub=%d] wrote ptmx %q without a capability", stubbornness, ptmx.String())
			}
			// At most one Terminate and one Kill (no thrashing).
			if proc.termCalls > 1 || proc.killCalls > 1 {
				t.Errorf("[cap=%v stub=%d] over-signalled {term:%d kill:%d}", exitSupported, stubbornness, proc.termCalls, proc.killCalls)
			}
		}
	}
}

// plantCloseRequest writes a close-request row into a store.
func plantCloseRequest(t *testing.T, sessionsDir string, cr session.CloseRequest) {
	t.Helper()
	dir := session.CloseRequestsDir(sessionsDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(cr)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, cr.RequestID+".json"), data, 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestScanCloseRequestsCmd_TargetingMatrix is the property form of the targeting
// rule: a row is matched only when target_instance == this instance AND the slug
// is one it hosts. Every other combination — wrong instance, unhosted slug,
// empty target, empty request_id — is left untouched.
func TestScanCloseRequestsCmd_TargetingMatrix(t *testing.T) {
	dir := t.TempDir()
	sessionsDir := filepath.Join(dir, "_sessions")
	const myName = "me"
	hosted := map[string]bool{"demo": true}

	type row struct {
		id        string
		slug      string
		target    string
		wantMatch bool
	}
	rows := []row{
		{"m1", "demo", "me", true},     // mine + hosted → match
		{"m2", "demo", "other", false}, // another instance → skip
		{"m3", "ghost", "me", false},   // hosted-by-nobody-here → skip
		{"m4", "demo", "", false},      // no target → skip
		{"m5", "", "demo", false},      // (empty request_id row, target me)
	}
	for _, r := range rows {
		target := r.target
		if r.id == "m5" {
			target = "me"
		}
		plantCloseRequest(t, sessionsDir, session.CloseRequest{
			RequestID: r.id, Slug: r.slug, TargetInstance: target,
		})
	}

	msg := scanCloseRequestsCmd(sessionsDir, myName, hosted, nil)().(closeRequestScanMsg)
	matched := map[string]bool{}
	for _, cr := range msg.matched {
		matched[cr.RequestID] = true
	}
	for _, r := range rows {
		if matched[r.id] != r.wantMatch {
			t.Errorf("row %q (slug=%q target=%q): matched=%v, want %v", r.id, r.slug, r.target, matched[r.id], r.wantMatch)
		}
	}
}

// TestScanCloseRequestsCmd_SessionIDTargeting: a row carrying a session_id is
// matched by resolving that id against the hosted sessions (exact id or leading
// prefix), not by its slug. A slugless row whose id names no hosted session is
// left untouched — the id is exactly what keeps it from colliding at the empty
// slug. A row without a session_id keeps the legacy slug-key match verbatim.
func TestScanCloseRequestsCmd_SessionIDTargeting(t *testing.T) {
	dir := t.TempDir()
	sessionsDir := filepath.Join(dir, "_sessions")
	const myName = "me"
	// One slugless session (id sessB…) and one slugged session (alpha, id sessA…).
	hosted := map[string]bool{"": true, "alpha": true}
	idToSlug := map[string]string{"sessB-full-id": "", "sessA-full-id": "alpha"}

	type row struct {
		id        string
		slug      string
		sessionID string
		wantMatch bool
	}
	rows := []row{
		{"exact", "", "sessB-full-id", true}, // full id → slugless session
		{"prefix", "", "sessB", true},        // leading prefix → slugless session
		{"nomatch", "", "sessX", false},      // id names nothing hosted; slugless → skip
		{"legacy-slugless", "", "", true},    // no id → legacy empty-slug match
		{"legacy-slug", "alpha", "", true},   // no id → legacy slug match
		{"id-to-slugged", "", "sessA", true}, // id resolves to the slugged session
	}
	for _, r := range rows {
		plantCloseRequest(t, sessionsDir, session.CloseRequest{
			RequestID: r.id, Slug: r.slug, SessionID: r.sessionID, TargetInstance: myName,
		})
	}

	msg := scanCloseRequestsCmd(sessionsDir, myName, hosted, idToSlug)().(closeRequestScanMsg)
	matched := map[string]bool{}
	for _, cr := range msg.matched {
		matched[cr.RequestID] = true
	}
	for _, r := range rows {
		if matched[r.id] != r.wantMatch {
			t.Errorf("row %q (slug=%q session_id=%q): matched=%v, want %v", r.id, r.slug, r.sessionID, matched[r.id], r.wantMatch)
		}
	}
}

// TestHandleCloseRequestScan_SessionIDDiscriminates: a close-request carrying a
// session_id tears down exactly the session that id names — keyed off that
// session's slug — even when a slugless session and a slugged session co-reside
// on one instance. The unaddressed session is never scheduled for teardown.
func TestHandleCloseRequestScan_SessionIDDiscriminates(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.localSessions = map[string]liveSession{
		"":      {typ: "chat", initiator: "agent", sessionID: "sessB-full", started: time.Now()},
		"alpha": {typ: "spec", initiator: "agent", sessionID: "sessA-full", started: time.Now()},
	}
	m.sessionPanels = map[string]work.SessionPanelModel{
		"":      work.NewSessionPanelModel(""),
		"alpha": work.NewSessionPanelModel("alpha"),
	}

	// Address the slugless session by an unambiguous leading prefix of its id.
	m, cmd := m.handleCloseRequestScan(closeRequestScanMsg{matched: []session.CloseRequest{
		{RequestID: "c1", Slug: "", SessionID: "sessB", TargetInstance: "me", Reason: "coordinator"},
	}})
	if cmd == nil {
		t.Fatal("expected a delete Cmd for the consumed row")
	}
	if _, pending := m.pendingClose[""]; !pending {
		t.Fatal("addressed slugless session was not scheduled for teardown")
	}
	if _, pending := m.pendingClose["alpha"]; pending {
		t.Fatal("unaddressed slugged session was scheduled for teardown by the slugless close")
	}
}

// TestHandleCloseRequestScan_UnmatchedSessionIDSparesSlugless: a session-addressed
// row whose id names no hosted session must not fall back to the empty-slug
// session — that fallback is the wrong-session close the id exists to prevent.
// The orphan row is still consumed (deleted), leaving no residue.
func TestHandleCloseRequestScan_UnmatchedSessionIDSparesSlugless(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.localSessions = map[string]liveSession{
		"": {typ: "chat", initiator: "agent", sessionID: "sessB-full", started: time.Now()},
	}
	m.sessionPanels = map[string]work.SessionPanelModel{
		"": work.NewSessionPanelModel(""),
	}

	m, cmd := m.handleCloseRequestScan(closeRequestScanMsg{matched: []session.CloseRequest{
		{RequestID: "c1", Slug: "", SessionID: "ghost", TargetInstance: "me", Reason: "coordinator"},
	}})
	if cmd == nil {
		t.Fatal("expected a delete Cmd consuming the orphan row")
	}
	if _, pending := m.pendingClose[""]; pending {
		t.Fatal("a session_id naming no hosted session tore down the wrong (empty-slug) session")
	}
}

// TestHandleCloseRequestScan_LegacySluglessRow: a legacy row (no session_id) with
// an empty slug keys off the empty-slug session exactly as it did before the
// field existed — the byte-for-byte backward-compatibility guarantee.
func TestHandleCloseRequestScan_LegacySluglessRow(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.localSessions = map[string]liveSession{
		"": {typ: "chat", initiator: "agent", started: time.Now()}, // no session id binding
	}
	m.sessionPanels = map[string]work.SessionPanelModel{
		"": work.NewSessionPanelModel(""),
	}

	m, cmd := m.handleCloseRequestScan(closeRequestScanMsg{matched: []session.CloseRequest{
		{RequestID: "c1", Slug: "", TargetInstance: "me", Reason: "coordinator"},
	}})
	if cmd == nil {
		t.Fatal("expected a delete Cmd for the consumed row")
	}
	if _, pending := m.pendingClose[""]; !pending {
		t.Fatal("legacy empty-slug close did not schedule teardown of the slugless session")
	}
}

// TestAdvanceCloseLadders_QuiescenceWaitOrdering: a consumed close-request for a
// mid-turn panel dispatches no ladder (it waits); the same slug dispatches
// exactly one ladder once the panel reports quiescent, and is cleared from
// pendingClose so teardown fires at most once.
func TestAdvanceCloseLadders_QuiescenceWaitOrdering(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.sessionPanels = map[string]work.SessionPanelModel{"demo": work.NewSessionPanelModel("demo")}
	m.pendingClose = map[string]pendingCloseState{"demo": {requestID: "c1", consumedAt: time.Now()}}

	// Mid-turn: not quiescent → no dispatch, still pending.
	m, cmds := m.advanceCloseLadders()
	if len(cmds) != 0 {
		t.Fatalf("dispatched %d ladders while mid-turn, want 0", len(cmds))
	}
	if _, pending := m.pendingClose["demo"]; !pending {
		t.Fatal("pendingClose cleared before quiescence")
	}

	// Quiescent (process finished): dispatch exactly one, clear the slug.
	panel, _ := m.sessionPanels["demo"].Update(work.StreamCompleteMsg{Slug: "demo"})
	m.sessionPanels["demo"] = panel
	if !panel.QuiescentForClose(false) {
		t.Fatal("panel not quiescent after StreamComplete")
	}
	m, cmds = m.advanceCloseLadders()
	if len(cmds) != 1 {
		t.Fatalf("dispatched %d ladders when quiescent, want 1", len(cmds))
	}
	if _, pending := m.pendingClose["demo"]; pending {
		t.Fatal("pendingClose not cleared after dispatch")
	}
}

// TestHandleCloseRequestScan_MarksAndDeletes: a matched scan marks the slug
// pending-close and returns a Cmd (the row delete); a re-scan of the same
// already-pending slug is a no-op (no duplicate work).
func TestHandleCloseRequestScan_MarksAndDeletes(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.sessionPanels = map[string]work.SessionPanelModel{"demo": work.NewSessionPanelModel("demo")}

	m, cmd := m.handleCloseRequestScan(closeRequestScanMsg{matched: []session.CloseRequest{
		{RequestID: "c1", Slug: "demo", TargetInstance: "me"},
	}})
	if _, pending := m.pendingClose["demo"]; !pending {
		t.Fatal("slug not marked pending-close")
	}
	if cmd == nil {
		t.Fatal("expected a delete Cmd for the consumed row")
	}

	// Re-scan of an already-pending slug: nothing new to do.
	_, cmd2 := m.handleCloseRequestScan(closeRequestScanMsg{matched: []session.CloseRequest{
		{RequestID: "c1", Slug: "demo", TargetInstance: "me"},
	}})
	if cmd2 != nil {
		t.Fatal("re-scan of an already-pending slug re-dispatched work")
	}
}

// TestShouldAutoClose_OverrideMatrix is the truth table of the auto-close gate:
// the per-request auto_close override wins when present, else the initiator
// decides (agent auto-closes, human holds), and an untracked session defaults to
// auto-close.
func TestShouldAutoClose_OverrideMatrix(t *testing.T) {
	yes, no := true, false
	cases := []struct {
		name string
		ls   liveSession
		want bool
	}{
		{"agent, no override → auto-close", liveSession{initiator: "agent"}, true},
		{"human, no override → hold", liveSession{initiator: "human"}, false},
		{"agent, override false → hold", liveSession{initiator: "agent", autoClose: &no}, false},
		{"human, override true → auto-close", liveSession{initiator: "human", autoClose: &yes}, true},
		{"empty initiator, no override → auto-close (default)", liveSession{}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := shouldAutoClose(tc.ls); got != tc.want {
				t.Errorf("shouldAutoClose(%+v) = %v, want %v", tc.ls, got, tc.want)
			}
		})
	}
}

// TestHandleCloseRequestScan_ExplicitFullDiscretion: an explicit close (reason
// human/coordinator) always schedules teardown, regardless of initiator. A
// generating session (human or agent) is marked pendingClose — never badged, never
// held — and is interrupted so its turn ends; the interrupt keeps it in pendingClose
// (advanceCloseLadders waits out the bounded grace) rather than dispatching mid-turn.
func TestHandleCloseRequestScan_ExplicitFullDiscretion(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.localSessions = map[string]liveSession{
		"human-gen": {typ: "spec", initiator: "human", started: time.Now()},
		"agent-gen": {typ: "spec", initiator: "agent", started: time.Now()},
	}
	// Fresh panels read as generating (not done, not awaiting input).
	m.sessionPanels = map[string]work.SessionPanelModel{
		"human-gen": work.NewSessionPanelModel("human-gen"),
		"agent-gen": work.NewSessionPanelModel("agent-gen"),
	}

	m, cmd := m.handleCloseRequestScan(closeRequestScanMsg{matched: []session.CloseRequest{
		{RequestID: "c-human", Slug: "human-gen", TargetInstance: "me", Reason: "human"},
		{RequestID: "c-agent", Slug: "agent-gen", TargetInstance: "me", Reason: "coordinator"},
	}})
	if cmd == nil {
		t.Fatal("expected delete Cmds for the consumed rows")
	}

	for _, slug := range []string{"human-gen", "agent-gen"} {
		pc, pending := m.pendingClose[slug]
		if !pending {
			t.Errorf("%s: explicit close should schedule teardown regardless of initiator", slug)
		}
		if m.sessionPanels[slug].CloseRequested() {
			t.Errorf("%s: explicit close must not badge/hold the session open", slug)
		}
		if pc.interruptedAt.IsZero() {
			t.Errorf("%s: generating session bound for teardown should be interrupted", slug)
		}
	}
}

// TestHandleCloseRequestScan_ProtocolTerminusGate: a protocol_terminus close keeps
// the initiator/auto_close gate. An agent session auto-closes (pendingClose, not
// badged); a human session and an auto_close=false session are held open (badged,
// not scheduled for teardown).
func TestHandleCloseRequestScan_ProtocolTerminusGate(t *testing.T) {
	m, _ := baseSessionModel(t)
	hold := false
	m.localSessions = map[string]liveSession{
		"agent-term": {typ: "spec", initiator: "agent", started: time.Now()},
		"human-term": {typ: "spec", initiator: "human", started: time.Now()},
		"hold-term":  {typ: "spec", initiator: "agent", autoClose: &hold, started: time.Now()},
	}
	m.sessionPanels = map[string]work.SessionPanelModel{
		"agent-term": work.NewSessionPanelModel("agent-term"),
		"human-term": work.NewSessionPanelModel("human-term"),
		"hold-term":  work.NewSessionPanelModel("hold-term"),
	}

	m, cmd := m.handleCloseRequestScan(closeRequestScanMsg{matched: []session.CloseRequest{
		{RequestID: "t-agent", Slug: "agent-term", TargetInstance: "me", Reason: "protocol_terminus"},
		{RequestID: "t-human", Slug: "human-term", TargetInstance: "me", Reason: "protocol_terminus"},
		{RequestID: "t-hold", Slug: "hold-term", TargetInstance: "me", Reason: "protocol_terminus"},
	}})
	if cmd == nil {
		t.Fatal("expected delete Cmds for the consumed rows")
	}

	if _, pending := m.pendingClose["agent-term"]; !pending {
		t.Error("agent session should auto-close at terminus")
	}
	if m.sessionPanels["agent-term"].CloseRequested() {
		t.Error("auto-closing agent session should not be badged")
	}
	if _, pending := m.pendingClose["human-term"]; pending {
		t.Error("human session must be held open at terminus, not torn down")
	}
	if !m.sessionPanels["human-term"].CloseRequested() {
		t.Error("human session should carry the held-open badge at terminus")
	}
	if _, pending := m.pendingClose["hold-term"]; pending {
		t.Error("auto_close=false session must be held open at terminus")
	}
	if !m.sessionPanels["hold-term"].CloseRequested() {
		t.Error("auto_close=false session should carry the held-open badge")
	}
}

// TestClosedPanelInputMsg_SetsStatusNotice is the contract for the closed-panel
// input notice: routing a ClosedPanelInputMsg through Update surfaces the
// "[lore] session closed" status-line flash rather than dropping the input.
func TestClosedPanelInputMsg_SetsStatusNotice(t *testing.T) {
	m, _ := baseSessionModel(t)
	um, _ := m.Update(work.ClosedPanelInputMsg{Slug: "demo", Key: "a"})
	nm, ok := um.(model)
	if !ok {
		t.Fatalf("Update returned %T, want model", um)
	}
	if !strings.Contains(nm.flashErr, "session closed") {
		t.Errorf("flashErr = %q, want a 'session closed' notice", nm.flashErr)
	}
}

// TestHandleCloseLadderDone_JournalsClosedExactlyOnce is the closed-emission
// end-to-end: finishing the ladder ends the local session (rewriting the
// registry without the slug and journaling `closed`), and the StreamCompleteMsg
// the killed process later produces re-enters teardown without a second `closed`
// row (endLocalSession is guarded on localSessions membership).
func TestHandleCloseLadderDone_JournalsClosedExactlyOnce(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	kdir := m.config.KnowledgeDir
	m.localSessions = map[string]liveSession{
		"demo": {typ: "spec", initiator: "human", started: time.Now()},
	}
	panel, _ := work.NewSessionPanelModel("demo").Update(work.StreamCompleteMsg{Slug: "demo"})
	m.sessionPanels = map[string]work.SessionPanelModel{"demo": panel}

	m, cmd := m.handleCloseLadderDone(closeLadderDoneMsg{slug: "demo", rung: rungSIGTERM})
	if _, ok := m.localSessions["demo"]; ok {
		t.Fatal("local session not cleared on teardown")
	}
	runJournalCmds(t, cmd)
	if got := readEventTypes(t, kdir); len(got) != 1 || got[0] != session.EventClosed {
		t.Fatalf("events = %v, want exactly [closed]", got)
	}

	// The killed process's StreamCompleteMsg re-enters teardown: no second close.
	_, cmd = m.handleStreamComplete(work.StreamCompleteMsg{Slug: "demo"})
	runJournalCmds(t, cmd)
	if got := readEventTypes(t, kdir); len(got) != 1 {
		t.Fatalf("closed journaled %d times, want exactly once: %v", len(got), got)
	}
}

// readEventRows returns every events.jsonl row decoded into a session.Event, in
// order, for assertions on reason/request_id (not just the event name).
func readEventRows(t *testing.T, kdir string) []session.Event {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(kdir, "_sessions", "events.jsonl"))
	if err != nil {
		return nil
	}
	var rows []session.Event
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if line == "" {
			continue
		}
		var ev session.Event
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			t.Fatalf("bad events.jsonl row %q: %v", line, err)
		}
		rows = append(rows, ev)
	}
	return rows
}

// TestRunCloseLadder_ExhaustedIsError: a process that outlives the full ladder
// (survives SIGTERM and SIGKILL) reaches rungKill but returns
// errCloseLadderExhausted, so the caller can journal close_failed rather than a
// false `closed`.
func TestRunCloseLadder_ExhaustedIsError(t *testing.T) {
	proc := &fakeProc{signalsBeforeExit: 99} // never exits
	rung, err := runCloseLadder(proc, nil, "", false, "fw", 5*time.Millisecond, time.Millisecond)
	if rung != rungKill {
		t.Errorf("rung = %d, want rungKill (%d)", rung, rungKill)
	}
	if !errors.Is(err, errCloseLadderExhausted) {
		t.Errorf("err = %v, want errCloseLadderExhausted", err)
	}
}

// TestAdvanceCloseLadders_ExplicitModalHold: an explicit close on a modal-blocked
// panel (interactive-prompt true, not done) holds within the modal-hold bound,
// then — once the bound elapses — proceeds down the exit ladder and journals a
// `closed` row carrying the consumed close request_id. No bytes are injected.
func TestAdvanceCloseLadders_ExplicitModalHold(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	kdir := m.config.KnowledgeDir
	m.atInteractivePromptFn = func(work.SessionPanelModel) bool { return true }
	m.closeModalHold = time.Hour // long bound so the "within hold" phase holds
	m.localSessions = map[string]liveSession{"demo": {typ: "spec", initiator: "human", started: time.Now()}}
	m.sessionPanels = map[string]work.SessionPanelModel{"demo": work.NewSessionPanelModel("demo")}

	// Within the hold: no dispatch, entry still pending, session still alive.
	m.pendingClose = map[string]pendingCloseState{"demo": {requestID: "cr-x", reason: "human", consumedAt: time.Now()}}
	m, cmds := m.advanceCloseLadders()
	if len(cmds) != 0 {
		t.Fatalf("dispatched %d ladders within the modal hold, want 0", len(cmds))
	}
	if _, pending := m.pendingClose["demo"]; !pending {
		t.Fatal("explicit close dropped from pendingClose within the hold")
	}

	// Bound elapsed (consumedAt in the past): dispatch the ladder exactly once.
	m.pendingClose = map[string]pendingCloseState{"demo": {requestID: "cr-x", reason: "human", consumedAt: time.Now().Add(-time.Hour)}}
	m, cmds = m.advanceCloseLadders()
	if len(cmds) != 1 {
		t.Fatalf("dispatched %d ladders after the hold elapsed, want 1", len(cmds))
	}
	if _, pending := m.pendingClose["demo"]; pending {
		t.Fatal("pendingClose not cleared after dispatch")
	}

	// Drive the ladder Cmd → handleCloseLadderDone → the closed terminal.
	msg, ok := cmds[0]().(closeLadderDoneMsg)
	if !ok {
		t.Fatalf("ladder Cmd returned %T, want closeLadderDoneMsg", cmds[0]())
	}
	if msg.requestID != "cr-x" {
		t.Errorf("ladder carried request_id %q, want cr-x", msg.requestID)
	}
	m, cmd := m.handleCloseLadderDone(msg)
	runJournalCmds(t, cmd)
	rows := readEventRows(t, kdir)
	if len(rows) != 1 || rows[0].Event != session.EventClosed {
		t.Fatalf("events = %+v, want exactly [closed]", rows)
	}
	if rows[0].RequestID != "cr-x" {
		t.Errorf("closed row request_id = %q, want the consumed close request_id cr-x", rows[0].RequestID)
	}
}

// TestAdvanceCloseLadders_TerminusModalRefuses: a protocol_terminus close on a
// modal-blocked panel, once the hold elapses, journals close_failed
// reason=interactive-prompt (carrying the consumed request_id) and leaves the
// session alive — no teardown, panel still hosted.
func TestAdvanceCloseLadders_TerminusModalRefuses(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	kdir := m.config.KnowledgeDir
	m.atInteractivePromptFn = func(work.SessionPanelModel) bool { return true }
	m.localSessions = map[string]liveSession{"demo": {typ: "spec", initiator: "agent", started: time.Now()}}
	m.sessionPanels = map[string]work.SessionPanelModel{"demo": work.NewSessionPanelModel("demo")}
	m.pendingClose = map[string]pendingCloseState{"demo": {
		requestID: "cr-t", reason: closeReasonProtocolTerminus, consumedAt: time.Now().Add(-time.Hour),
	}}

	m, cmds := m.advanceCloseLadders()
	if len(cmds) != 1 {
		t.Fatalf("terminus modal refuse dispatched %d cmds, want 1 (the close_failed)", len(cmds))
	}
	if _, pending := m.pendingClose["demo"]; pending {
		t.Fatal("terminus close not cleared from pendingClose after refusing")
	}
	// The session stays alive: still tracked, panel still hosted, not torn down.
	if _, alive := m.localSessions["demo"]; !alive {
		t.Fatal("terminus modal refuse must leave the session alive")
	}
	if _, hosted := m.sessionPanels["demo"]; !hosted {
		t.Fatal("terminus modal refuse must not tear down the panel")
	}

	runJournalCmds(t, tea.Batch(cmds...))
	rows := readEventRows(t, kdir)
	if len(rows) != 1 || rows[0].Event != session.EventCloseFailed {
		t.Fatalf("events = %+v, want exactly [close_failed]", rows)
	}
	if rows[0].Reason != closeFailedInteractivePrompt || rows[0].RequestID != "cr-t" {
		t.Fatalf("close_failed row = %+v, want reason=interactive-prompt request_id=cr-t", rows[0])
	}
}

// TestAdvanceCloseLadders_TerminusOptionSelectRefuses pins the live defect: an
// AskUserQuestion-style option-select modal must classify as an interactive
// prompt, so a protocol terminus close refuses with close_failed instead of
// silently consuming the close request and leaving no terminal outcome.
func TestAdvanceCloseLadders_TerminusOptionSelectRefuses(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	kdir := m.config.KnowledgeDir
	m.atInteractivePromptFn = func(work.SessionPanelModel) bool {
		return interactivePromptState("claude-code", work.ScreenSnapshot{Rows: ccOptionSelectRows})
	}
	m.localSessions = map[string]liveSession{"demo": {typ: "chat", initiator: "agent", started: time.Now()}}
	m.sessionPanels = map[string]work.SessionPanelModel{"demo": work.NewSessionPanelModel("demo")}
	m.pendingClose = map[string]pendingCloseState{"demo": {
		requestID: "cr-option", reason: closeReasonProtocolTerminus, consumedAt: time.Now().Add(-time.Hour),
	}}

	m, cmds := m.advanceCloseLadders()
	if len(cmds) != 1 {
		t.Fatalf("terminus option-select refuse dispatched %d cmds, want 1 close_failed", len(cmds))
	}
	if _, pending := m.pendingClose["demo"]; pending {
		t.Fatal("terminus option-select close not cleared from pendingClose after refusing")
	}
	if _, alive := m.localSessions["demo"]; !alive {
		t.Fatal("terminus option-select refuse must leave the session alive")
	}
	if _, hosted := m.sessionPanels["demo"]; !hosted {
		t.Fatal("terminus option-select refuse must not tear down the panel")
	}

	runJournalCmds(t, tea.Batch(cmds...))
	rows := readEventRows(t, kdir)
	if len(rows) != 1 || rows[0].Event != session.EventCloseFailed {
		t.Fatalf("events = %+v, want exactly [close_failed]", rows)
	}
	if rows[0].Reason != closeFailedInteractivePrompt || rows[0].RequestID != "cr-option" {
		t.Fatalf("close_failed row = %+v, want reason=interactive-prompt request_id=cr-option", rows[0])
	}
}

// TestHandleCloseLadderDone_ErrorJournalsCloseFailed: a ladder that could not
// confirm the process gone (errCloseLadderExhausted) emits close_failed
// reason=rung-exhausted, NOT `closed` (the double-terminal trap), drops the
// session, and a later StreamCompleteMsg adds no second terminal.
func TestHandleCloseLadderDone_ErrorJournalsCloseFailed(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	kdir := m.config.KnowledgeDir
	m.localSessions = map[string]liveSession{"demo": {typ: "spec", initiator: "human", started: time.Now()}}
	panel, _ := work.NewSessionPanelModel("demo").Update(work.StreamCompleteMsg{Slug: "demo"})
	m.sessionPanels = map[string]work.SessionPanelModel{"demo": panel}

	m, cmd := m.handleCloseLadderDone(closeLadderDoneMsg{
		slug: "demo", rung: rungKill, err: errCloseLadderExhausted, requestID: "cr-e",
	})
	if _, ok := m.localSessions["demo"]; ok {
		t.Fatal("failed teardown did not drop the session from localSessions")
	}
	runJournalCmds(t, cmd)
	rows := readEventRows(t, kdir)
	if len(rows) != 1 || rows[0].Event != session.EventCloseFailed {
		t.Fatalf("events = %+v, want exactly [close_failed]", rows)
	}
	if rows[0].Reason != closeFailedRungExhausted || rows[0].RequestID != "cr-e" {
		t.Fatalf("close_failed row = %+v, want reason=rung-exhausted request_id=cr-e", rows[0])
	}

	// StreamComplete re-entry: the dropped session yields no second terminal.
	_, cmd = m.handleStreamComplete(work.StreamCompleteMsg{Slug: "demo"})
	runJournalCmds(t, cmd)
	if rows := readEventRows(t, kdir); len(rows) != 1 {
		t.Fatalf("terminal journaled %d times, want exactly once: %+v", len(rows), rows)
	}
}
