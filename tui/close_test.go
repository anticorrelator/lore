package main

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

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
// blocks on a real wait.
func fastLadder(proc harnessProc, ptmx io.Writer, exitSeq string, exitSupported bool, framework string) closeRung {
	return runCloseLadder(proc, ptmx, exitSeq, exitSupported, framework, 5*time.Millisecond, time.Millisecond)
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

	msg := scanCloseRequestsCmd(sessionsDir, myName, hosted)().(closeRequestScanMsg)
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

// TestAdvanceCloseLadders_QuiescenceWaitOrdering: a consumed close-request for a
// mid-turn panel dispatches no ladder (it waits); the same slug dispatches
// exactly one ladder once the panel reports quiescent, and is cleared from
// pendingClose so teardown fires at most once.
func TestAdvanceCloseLadders_QuiescenceWaitOrdering(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.sessionPanels = map[string]work.SessionPanelModel{"demo": work.NewSessionPanelModel("demo")}
	m.pendingClose = map[string]bool{"demo": true}

	// Mid-turn: not quiescent → no dispatch, still pending.
	m, cmds := m.advanceCloseLadders()
	if len(cmds) != 0 {
		t.Fatalf("dispatched %d ladders while mid-turn, want 0", len(cmds))
	}
	if !m.pendingClose["demo"] {
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
	if m.pendingClose["demo"] {
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
	if !m.pendingClose["demo"] {
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

// TestHandleCloseRequestScan_InitiatorGate: a consumed close-request tears down
// an agent session (marked pendingClose, no badge) but holds a human session
// open (panel badged close-requested, never marked pendingClose). Both rows are
// consumed regardless.
func TestHandleCloseRequestScan_InitiatorGate(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.localSessions = map[string]liveSession{
		"agent-item": {typ: "spec", initiator: "agent", started: time.Now()},
		"human-item": {typ: "spec", initiator: "human", started: time.Now()},
	}
	m.sessionPanels = map[string]work.SessionPanelModel{
		"agent-item": work.NewSessionPanelModel("agent-item"),
		"human-item": work.NewSessionPanelModel("human-item"),
	}

	m, cmd := m.handleCloseRequestScan(closeRequestScanMsg{matched: []session.CloseRequest{
		{RequestID: "c-agent", Slug: "agent-item", TargetInstance: "me"},
		{RequestID: "c-human", Slug: "human-item", TargetInstance: "me"},
	}})
	if cmd == nil {
		t.Fatal("expected delete Cmds for the consumed rows")
	}

	if !m.pendingClose["agent-item"] {
		t.Error("agent session should be marked pending-close (auto-close)")
	}
	if m.pendingClose["human-item"] {
		t.Error("human session must not be scheduled for teardown")
	}
	if m.sessionPanels["human-item"].CloseRequested() != true {
		t.Error("human session panel should carry the close-requested badge")
	}
	if m.sessionPanels["agent-item"].CloseRequested() {
		t.Error("agent session panel should not be badged — it tears down")
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
