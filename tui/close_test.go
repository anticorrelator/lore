package main

import (
	"bytes"
	"context"
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
	"github.com/anticorrelator/lore/tui/internal/worktree"
)

func TestCloseDispositionStaleDestinationPreservesHostAndStreamMarkers(t *testing.T) {
	sourceDir := t.TempDir()
	for _, args := range [][]string{
		{"init", "-b", "main"},
		{"config", "user.email", "test@example.com"},
		{"config", "user.name", "Lore Test"},
	} {
		if out, err := exec.Command("git", append([]string{"-C", sourceDir}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v (%s)", args, err, out)
		}
	}
	hostMarker := filepath.Join(sourceDir, "host-marker.bin")
	if err := os.WriteFile(hostMarker, []byte{0x00, 0x41, 0xff, 0x0a}, 0o644); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("git", "-C", sourceDir, "add", "host-marker.bin").CombinedOutput(); err != nil {
		t.Fatalf("git add: %v (%s)", err, out)
	}
	if out, err := exec.Command("git", "-C", sourceDir, "commit", "-m", "seed").CombinedOutput(); err != nil {
		t.Fatalf("git commit: %v (%s)", err, out)
	}
	identity, err := worktree.Create(context.Background(), sourceDir, filepath.Join(t.TempDir(), "session-worktree"), "close-epoch")
	if err != nil {
		t.Fatalf("create session worktree: %v", err)
	}
	identity, err = worktree.Transition(identity, worktree.StateActive)
	if err != nil {
		t.Fatal(err)
	}

	hostBytes := []byte{0x42, 0x00, 0xfe, 0x0a}
	streamBytes := []byte{0x53, 0x00, 0xfd, 0x0a}
	if err := os.WriteFile(hostMarker, hostBytes, 0o644); err != nil {
		t.Fatal(err)
	}
	streamMarker := filepath.Join(identity.CanonicalPath, "stream-marker.bin")
	if err := os.WriteFile(streamMarker, streamBytes, 0o644); err != nil {
		t.Fatal(err)
	}

	m, _ := baseSessionModel(t)
	m.config.ProjectDir = sourceDir
	m.normalizedProjectDir = sourceDir
	ls := liveSession{typ: "implement", initiator: "agent", started: time.Now(), worktree: &identity}
	m.localSessions = map[string]liveSession{"demo": ls}
	m, closeCmds := m.endLocalSessionClosed("demo", "close-1")
	if len(closeCmds) != 1 || m.localSessions["demo"].worktree.State != worktree.StateTeardownPending {
		t.Fatalf("session close did not retain teardown-pending ownership: %+v", m.localSessions["demo"])
	}
	if _, duplicateCmds := m.endLocalSessionClosed("demo", ""); len(duplicateCmds) != 0 {
		t.Fatalf("concurrent stream completion scheduled a duplicate disposition: %d commands", len(duplicateCmds))
	}
	ls = m.localSessions["demo"]
	msg, ok := m.disposeWorktreeCmd("demo", ls, "close-1")().(worktreeDispositionMsg)
	if !ok {
		t.Fatalf("close disposition returned unexpected message")
	}
	if msg.err != nil || msg.outcome.Kind != worktree.OutcomeWorktreeQuarantined {
		t.Fatalf("stale close disposition = %+v err=%v, want worktree_quarantined", msg.outcome, msg.err)
	}
	if msg.outcome.Identity.State != worktree.StateQuarantined || msg.outcome.Artifact.Ref == "" || msg.outcome.Artifact.PatchPath == "" {
		t.Fatalf("quarantine artifact incomplete: %+v", msg.outcome)
	}
	m, outcomeCmd := m.handleWorktreeDisposition(msg)
	if outcomeCmd == nil {
		t.Fatal("quarantined close did not schedule outcome-before-release persistence")
	}
	if _, owned := m.localSessions["demo"]; owned {
		t.Fatal("terminal quarantine did not release registry ownership")
	}
	if got, err := os.ReadFile(hostMarker); err != nil || !bytes.Equal(got, hostBytes) {
		t.Fatalf("close disposition changed host marker: got %v err=%v want %v", got, err, hostBytes)
	}
	if got, err := os.ReadFile(streamMarker); err != nil || !bytes.Equal(got, streamBytes) {
		t.Fatalf("close disposition changed stream marker: got %v err=%v want %v", got, err, streamBytes)
	}
}

func TestManagedSessionCloseRoutesToQuiescenceWithoutLegacyPublish(t *testing.T) {
	identity := worktree.Identity{Version: worktree.IdentityVersion, State: worktree.StateActive}
	m, _ := baseSessionModel(t)
	m.localSessions = map[string]liveSession{"worker-1": {
		typ: "worker", initiator: "agent", started: time.Now(), worktree: &identity,
		worktreeID: "tree-1", executionDir: "/managed/tree-1", pid: 4242,
	}}
	m, cmds := m.endLocalSessionClosed("worker-1", "close-1")
	if len(cmds) != 1 {
		t.Fatalf("managed close scheduled %d commands, want registry write then quiesce sequence", len(cmds))
	}
	got := m.localSessions["worker-1"]
	if !got.worktreeDispositionPending || got.worktree.State != worktree.StateActive {
		t.Fatalf("managed close entered legacy guard publish lifecycle: %+v", got)
	}
}

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
	rung, _, _ := runCloseLadder(proc, ptmx, exitSeq, exitSupported, framework, 5*time.Millisecond, time.Millisecond)
	return rung
}

// panelWithInterruptCapture returns a live-looking panel whose PTY writes are
// captured in a temporary file, so close tests can distinguish "no interrupt"
// from a best-effort Interrupt call that failed for lack of a PTY.
func panelWithInterruptCapture(t *testing.T, slug string) (work.SessionPanelModel, *os.File) {
	t.Helper()
	ptmx, err := os.CreateTemp(t.TempDir(), "close-pty-*")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ptmx.Close() })
	panel, _ := work.NewSessionPanelModel(slug).Update(work.SessionProcessStartedMsg{
		Slug: slug,
		Ptmx: ptmx,
	})
	return panel, ptmx
}

func capturedPTYBytes(t *testing.T, ptmx *os.File) []byte {
	t.Helper()
	if err := ptmx.Sync(); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(ptmx.Name())
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestCloseReasonGraceDefaults(t *testing.T) {
	if got := (model{}).terminusGrace(); got != 2*time.Minute {
		t.Fatalf("terminus grace = %s, want 2m", got)
	}
	if got := (model{}).explicitGrace(); got != 2*time.Second {
		t.Fatalf("explicit grace = %s, want 2s", got)
	}
	if got := (model{}).modalRetryCheckpoints(); got != [3]time.Duration{30 * time.Second, 60 * time.Second, 120 * time.Second} {
		t.Fatalf("modal retry checkpoints = %v, want [30s 60s 2m]", got)
	}
}

// TestRunCloseLadder_DegradesToSIGTERM: with no capability sequence the ladder
// skips rung 1 with an explicit degradation notice, never touches the ptmx, and
// a process that exits on SIGTERM is never killed.
func TestRunCloseLadder_DegradesToSIGTERM(t *testing.T) {
	proc := &fakeProc{signalsBeforeExit: 1}
	var ptmx bytes.Buffer
	rung, notices, err := runCloseLadder(proc, &ptmx, "", false, "claude-code", 5*time.Millisecond, time.Millisecond)

	if rung != rungSIGTERM {
		t.Errorf("rung = %d, want rungSIGTERM (%d)", rung, rungSIGTERM)
	}
	if proc.termCalls != 1 || proc.killCalls != 0 {
		t.Errorf("signals = {term:%d kill:%d}, want exactly one SIGTERM", proc.termCalls, proc.killCalls)
	}
	if ptmx.Len() != 0 {
		t.Errorf("ptmx written %q with no capability sequence", ptmx.String())
	}
	if err != nil {
		t.Fatalf("runCloseLadder error: %v", err)
	}
	if len(notices) != 1 || notices[0].Class != operatorDegradation || notices[0].Code != "graceful-exit-unsupported" {
		t.Errorf("notices = %#v, want one graceful-exit operator degradation", notices)
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
	m.localSessions = map[string]liveSession{"demo": {typ: "spec", initiator: "human", started: time.Now()}}
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
	if got := m.localSessions["demo"].closeRequests; len(got) != 1 || got[0] != "c1" {
		t.Fatalf("consumed close request not recorded on live session: %v", got)
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
// generating session is never badged or held: it gets a natural-quiescence
// courtesy window, then ESC, then the existing bounded escalation path.
func TestHandleCloseRequestScan_ExplicitFullDiscretion(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.closeExplicitGrace = time.Hour
	m.localSessions = map[string]liveSession{
		"human-gen": {typ: "spec", initiator: "human", started: time.Now()},
		"agent-gen": {typ: "spec", initiator: "agent", started: time.Now()},
	}
	humanPanel, humanPTY := panelWithInterruptCapture(t, "human-gen")
	agentPanel, agentPTY := panelWithInterruptCapture(t, "agent-gen")
	m.sessionPanels = map[string]work.SessionPanelModel{
		"human-gen": humanPanel,
		"agent-gen": agentPanel,
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
		if !pc.interruptedAt.IsZero() {
			t.Errorf("%s: explicit close interrupted before the courtesy grace elapsed", slug)
		}
	}
	if got := capturedPTYBytes(t, humanPTY); len(got) != 0 {
		t.Fatalf("human explicit close wrote PTY bytes within courtesy grace: %v", got)
	}
	if got := capturedPTYBytes(t, agentPTY); len(got) != 0 {
		t.Fatalf("coordinator explicit close wrote PTY bytes within courtesy grace: %v", got)
	}

	// Expire the courtesy window: exactly one ESC per generating session, but no
	// force-teardown ladder until the existing post-interrupt grace expires.
	for slug, pc := range m.pendingClose {
		pc.consumedAt = time.Now().Add(-2 * time.Hour)
		m.pendingClose[slug] = pc
	}
	m, cmds := m.advanceCloseLadders()
	if len(cmds) != 0 {
		t.Fatalf("explicit close dispatched %d ladders in the ESC tick, want 0", len(cmds))
	}
	for slug, ptmx := range map[string]*os.File{"human-gen": humanPTY, "agent-gen": agentPTY} {
		if got := capturedPTYBytes(t, ptmx); !bytes.Equal(got, []byte{0x1b}) {
			t.Errorf("%s: PTY bytes after courtesy grace = %v, want one ESC", slug, got)
		}
		if m.pendingClose[slug].interruptedAt.IsZero() {
			t.Errorf("%s: interruptedAt not stamped after ESC", slug)
		}
	}

	for slug, pc := range m.pendingClose {
		pc.interruptedAt = time.Now().Add(-2 * time.Hour)
		m.pendingClose[slug] = pc
	}
	_, cmds = m.advanceCloseLadders()
	if len(cmds) != 2 {
		t.Fatalf("explicit close dispatched %d ladders after interrupt grace, want 2", len(cmds))
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
	if !m.pendingClose["agent-term"].interruptedAt.IsZero() {
		t.Error("generating protocol terminus must never enter the interrupt rung")
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

// TestProtocolTerminusSelfCloseDuringGeneratingTail is the shipped regression
// shape: a session consumes its own terminus close while still generating the
// post-tool tail. The request never writes ESC. Natural completion produces one
// correlated closed terminal; grace expiry produces one truthful refusal while
// leaving the session and panel intact.
func TestProtocolTerminusSelfCloseDuringGeneratingTail(t *testing.T) {
	t.Run("natural quiescence closes", func(t *testing.T) {
		m, _ := baseSessionModel(t)
		m.eventScript = repoScriptPath(t, "session-event-append.sh")
		kdir := m.config.KnowledgeDir
		panel, ptmx := panelWithInterruptCapture(t, "demo")
		m.localSessions = map[string]liveSession{
			"demo": {typ: "implement", initiator: "agent", started: time.Now()},
		}
		m.sessionPanels = map[string]work.SessionPanelModel{"demo": panel}

		m, _ = m.handleCloseRequestScan(closeRequestScanMsg{matched: []session.CloseRequest{{
			RequestID: "self-natural", Slug: "demo", TargetInstance: "me", Reason: closeReasonProtocolTerminus,
		}}})
		if got := capturedPTYBytes(t, ptmx); len(got) != 0 {
			t.Fatalf("self-close wrote interrupt bytes during its generating tail: %v", got)
		}
		if !m.pendingClose["demo"].interruptedAt.IsZero() {
			t.Fatal("self-close stamped interruptedAt during its generating tail")
		}

		panel, _ = m.sessionPanels["demo"].Update(work.StreamCompleteMsg{Slug: "demo"})
		m.sessionPanels["demo"] = panel
		m, cmds := m.advanceCloseLadders()
		if len(cmds) != 1 {
			t.Fatalf("natural completion dispatched %d ladder cmds, want 1", len(cmds))
		}
		msg := cmds[0]().(closeLadderDoneMsg)
		m, cmd := m.handleCloseLadderDone(msg)
		runJournalCmds(t, cmd)
		rows := readEventRows(t, kdir)
		if len(rows) != 1 || rows[0].Event != session.EventClosed || rows[0].RequestID != "self-natural" {
			t.Fatalf("natural self-close terminal = %+v, want one correlated closed", rows)
		}
		if got := rows[0].Links["close_requests"]; got != `["self-natural"]` {
			t.Fatalf("natural self-close links.close_requests = %q", got)
		}
	})

	t.Run("deadline refuses alive", func(t *testing.T) {
		m, _ := baseSessionModel(t)
		m.eventScript = repoScriptPath(t, "session-event-append.sh")
		kdir := m.config.KnowledgeDir
		m.closeTerminusGrace = time.Hour
		panel, ptmx := panelWithInterruptCapture(t, "demo")
		m.localSessions = map[string]liveSession{
			"demo": {typ: "implement", initiator: "agent", started: time.Now()},
		}
		m.sessionPanels = map[string]work.SessionPanelModel{"demo": panel}

		m, _ = m.handleCloseRequestScan(closeRequestScanMsg{matched: []session.CloseRequest{{
			RequestID: "self-expired", Slug: "demo", TargetInstance: "me", Reason: closeReasonProtocolTerminus,
		}}})
		plantCloseRequest(t, m.sessionsDir, session.CloseRequest{
			RequestID: "self-expired", Slug: "demo", TargetInstance: "me", Reason: closeReasonProtocolTerminus,
		})
		persisted := consumeCloseRequestCmd(m.sessionsDir, "self-expired", m.instanceRow())().(closeRequestDeletedMsg)
		if persisted.err != nil {
			t.Fatalf("persist consumed close request: %v", persisted.err)
		}
		pc := m.pendingClose["demo"]
		pc.consumedAt = time.Now().Add(-2 * time.Hour)
		m.pendingClose["demo"] = pc
		m, cmds := m.advanceCloseLadders()
		if len(cmds) != 1 {
			t.Fatalf("expired self-close emitted %d cmds, want one close_failed Cmd", len(cmds))
		}
		if _, pending := m.pendingClose["demo"]; pending {
			t.Fatal("expired self-close left pending state after its terminal decision")
		}
		if _, alive := m.localSessions["demo"]; !alive {
			t.Fatal("still-generating refusal removed localSessions entry")
		}
		if _, hosted := m.sessionPanels["demo"]; !hosted {
			t.Fatal("still-generating refusal removed sessionPanels entry")
		}
		if got := capturedPTYBytes(t, ptmx); len(got) != 0 {
			t.Fatalf("expired self-close wrote interrupt bytes: %v", got)
		}

		runJournalCmds(t, tea.Batch(cmds...))
		rows := readEventRows(t, kdir)
		if len(rows) != 1 || rows[0].Event != session.EventCloseFailed ||
			rows[0].Reason != closeFailedStillGenerating || rows[0].RequestID != "self-expired" {
			t.Fatalf("expired self-close terminal = %+v, want one close_failed/still-generating with request id", rows)
		}
		instances := session.ListInstances(m.sessionsDir)
		if len(instances) != 1 || len(instances[0].Sessions) != 1 ||
			len(instances[0].Sessions[0].CloseRequests) != 1 || instances[0].Sessions[0].CloseRequests[0] != "self-expired" {
			t.Fatalf("close_failed did not retain durable close_requests manifest: %+v", instances)
		}
	})
}

// TestCloseFailedThenExplicitRecoveryDeclaresBothRequests covers the recovery
// join itself: the failed request remains accumulated and the eventual explicit
// close declares both consumed ids while keeping the latest close id at the
// top-level request_id.
func TestCloseFailedThenExplicitRecoveryDeclaresBothRequests(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	kdir := m.config.KnowledgeDir
	ls := liveSession{typ: "implement", initiator: "agent", started: time.Now(),
		requestID: "spawn-1", closeRequests: []string{"term-failed", "explicit-recovery"}}
	m.localSessions = map[string]liveSession{"demo": ls}

	runJournalCmds(t, m.closeFailedCmd("demo", "term-failed", closeFailedStillGenerating, ls))
	var cmds []tea.Cmd
	m, cmds = m.endLocalSessionClosed("demo", "explicit-recovery")
	runJournalCmds(t, tea.Batch(cmds...))

	rows := readEventRows(t, kdir)
	if len(rows) != 2 || rows[0].Event != session.EventCloseFailed || rows[1].Event != session.EventClosed {
		t.Fatalf("recovery events = %+v, want [close_failed closed]", rows)
	}
	if rows[1].RequestID != "explicit-recovery" {
		t.Fatalf("recovery closed request_id = %q", rows[1].RequestID)
	}
	if got := rows[1].Links["close_requests"]; got != `["term-failed","explicit-recovery"]` {
		t.Fatalf("recovery closed.links.close_requests = %q", got)
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
	rung, _, err := runCloseLadder(proc, nil, "", false, "fw", 5*time.Millisecond, time.Millisecond)
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
	m.observeCloseFn = func(work.SessionPanelModel) closeObservation {
		return closeObservation{quiescent: true, screenKnown: true, screen: screenClass{interactive: true}}
	}
	m.closeModalHold = time.Hour // long bound so the "within hold" phase holds
	m.localSessions = map[string]liveSession{"demo": {typ: "spec", initiator: "human", started: time.Now(), closeRequests: []string{"cr-x"}}}
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
	if got := rows[0].Links["close_requests"]; got != `["cr-x"]` {
		t.Errorf("closed links.close_requests = %q, want [cr-x]", got)
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
	m.observeCloseFn = func(work.SessionPanelModel) closeObservation {
		return closeObservation{quiescent: true, screenKnown: true, screen: screenClass{interactive: true}}
	}
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

func TestAdvanceCloseLadders_TerminusModalRetryCheckpoints(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.observeCloseFn = func(work.SessionPanelModel) closeObservation {
		return closeObservation{quiescent: true, screenKnown: true, screen: screenClass{interactive: true}}
	}
	m.closeModalHold = time.Second
	m.closeModalRetryCheckpoints = [3]time.Duration{time.Second, 2 * time.Second, 3 * time.Second}
	m.localSessions = map[string]liveSession{"demo": {typ: "spec", initiator: "agent", started: time.Now()}}
	m.sessionPanels = map[string]work.SessionPanelModel{"demo": work.NewSessionPanelModel("demo")}

	for _, tc := range []struct {
		elapsed    time.Duration
		checkpoint int
	}{
		{1500 * time.Millisecond, 0},
		{2100 * time.Millisecond, 1},
		{3100 * time.Millisecond, 2},
	} {
		m.pendingClose = map[string]pendingCloseState{"demo": {
			requestID: "cr-retry", reason: closeReasonProtocolTerminus,
			consumedAt: time.Now().Add(-tc.elapsed),
		}}
		var cmds []tea.Cmd
		m, cmds = m.advanceCloseLadders()
		if len(cmds) != 0 {
			t.Fatalf("elapsed %s emitted %d commands before final checkpoint", tc.elapsed, len(cmds))
		}
		if got := m.pendingClose["demo"].modalRetryCheckpoint; got != tc.checkpoint {
			t.Fatalf("elapsed %s checkpoint = %d, want %d", tc.elapsed, got, tc.checkpoint)
		}
	}
}

func TestAdvanceCloseLadders_TerminusModalClearClosesDuringRetry(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	kdir := m.config.KnowledgeDir
	m.observeCloseFn = func(work.SessionPanelModel) closeObservation {
		return closeObservation{quiescent: true, screenKnown: true, screen: screenClass{composer: true}}
	}
	m.localSessions = map[string]liveSession{"demo": {typ: "spec", initiator: "agent", started: time.Now(), closeRequests: []string{"cr-clear"}}}
	m.sessionPanels = map[string]work.SessionPanelModel{"demo": work.NewSessionPanelModel("demo")}
	m.pendingClose = map[string]pendingCloseState{"demo": {
		requestID: "cr-clear", reason: closeReasonProtocolTerminus,
		consumedAt: time.Now().Add(-time.Minute), modalRetryCheckpoint: 1,
	}}

	m, cmds := m.advanceCloseLadders()
	if len(cmds) != 1 {
		t.Fatalf("classified clear dispatched %d ladders, want 1", len(cmds))
	}
	msg := cmds[0]().(closeLadderDoneMsg)
	m, cmd := m.handleCloseLadderDone(msg)
	runJournalCmds(t, cmd)
	rows := readEventRows(t, kdir)
	if len(rows) != 1 || rows[0].Event != session.EventClosed || rows[0].RequestID != "cr-clear" {
		t.Fatalf("events = %+v, want one closed for cr-clear", rows)
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
	m.observeCloseFn = func(work.SessionPanelModel) closeObservation {
		return classifyCloseObservation("claude-code", false, true, work.ScreenSnapshot{Rows: ccOptionSelectRows})
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
// reason=rung-exhausted, NOT `closed` (the double-terminal trap), retains the
// session's workspace ownership, and rewrites its mutable lifecycle state.
func TestHandleCloseLadderDone_ErrorJournalsCloseFailed(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	kdir := m.config.KnowledgeDir
	identity := &worktree.Identity{
		Version: worktree.IdentityVersion, CanonicalPath: "/tmp/session-tree",
		GitCommonDir: "/tmp/repo/.git", GitDir: "/tmp/repo/.git/worktrees/session-tree",
		Epoch: "close-test", TargetOID: "1111111111111111111111111111111111111111", State: worktree.StateActive,
		Captured: worktree.Generation{
			CanonicalPath: "/tmp/repo", GitCommonDir: "/tmp/repo/.git", GitDir: "/tmp/repo/.git",
			HeadOID: "1111111111111111111111111111111111111111", IndexDigest: "index", WorktreeDigest: "tree",
		},
	}
	m.localSessions = map[string]liveSession{"demo": {
		typ: "spec", initiator: "human", started: time.Now(), worktree: identity,
		closeRequests: []string{"cr-e"},
	}}
	panel, _ := work.NewSessionPanelModel("demo").Update(work.StreamCompleteMsg{Slug: "demo"})
	m.sessionPanels = map[string]work.SessionPanelModel{"demo": panel}

	m, cmd := m.handleCloseLadderDone(closeLadderDoneMsg{
		slug: "demo", rung: rungKill, err: errCloseLadderExhausted, requestID: "cr-e",
	})
	retained, ok := m.localSessions["demo"]
	if !ok || retained.worktree == nil {
		t.Fatal("failed teardown released durable worktree ownership")
	}
	if retained.worktree.State != worktree.StateTeardownPending {
		t.Fatalf("failed teardown lifecycle = %q, want teardown-pending", retained.worktree.State)
	}
	runJournalCmds(t, cmd)
	rows := readEventRows(t, kdir)
	if len(rows) != 1 || rows[0].Event != session.EventCloseFailed {
		t.Fatalf("events = %+v, want exactly [close_failed]", rows)
	}
	if rows[0].Reason != closeFailedRungExhausted || rows[0].RequestID != "cr-e" {
		t.Fatalf("close_failed row = %+v, want reason=rung-exhausted request_id=cr-e", rows[0])
	}

	instances := session.ListInstances(m.sessionsDir)
	if len(instances) != 1 || len(instances[0].Sessions) != 1 || instances[0].Sessions[0].Worktree == nil ||
		instances[0].Sessions[0].Worktree.State != worktree.StateTeardownPending {
		t.Fatalf("teardown-pending ownership was not fully rewritten: %+v", instances)
	}

	// A later process-death observation starts disposition but cannot emit a
	// second teardown terminal before that disposition reaches a terminal state.
	_, cmd = m.handleStreamComplete(work.StreamCompleteMsg{Slug: "demo"})
	runJournalCmds(t, cmd)
	rows = readEventRows(t, kdir)
	if len(rows) != 1 || rows[0].Event != session.EventCloseFailed || rows[0].RequestID != "cr-e" {
		t.Fatalf("later death emitted a second request terminal before disposition: %+v", rows)
	}
}
