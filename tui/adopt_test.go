package main

import (
	"bufio"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

func readJSONLines(t *testing.T, path string) []map[string]any {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var rows []map[string]any
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		var row map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &row); err != nil {
			t.Fatal(err)
		}
		rows = append(rows, row)
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	return rows
}

// deadPID runs a child to completion and reaps it, yielding a pid that reads dead
// via signal-0 — the "owner is gone" half of the adoptability rule.
func deadPID(t *testing.T) int {
	t.Helper()
	cmd := exec.Command("true")
	if err := cmd.Start(); err != nil {
		t.Fatalf("start true: %v", err)
	}
	pid := cmd.Process.Pid
	_ = cmd.Wait()
	return pid
}

// plantCorpse writes a dead instance's registry row and backdates its mtime past
// the liveness TTL so the adoption scan treats it as a corpse.
func plantCorpse(t *testing.T, sessionsDir, name, repo string, pid int, sessions []session.Session) {
	t.Helper()
	inst := session.Instance{Name: name, Repo: repo, PID: pid, Started: "2026-07-06T00:00:00Z", Sessions: sessions}
	if err := session.WriteInstance(sessionsDir, inst); err != nil {
		t.Fatalf("write corpse: %v", err)
	}
	old := time.Now().Add(-2 * session.LivenessTTL)
	if err := os.Chtimes(filepath.Join(session.InstancesDir(sessionsDir), name+".json"), old, old); err != nil {
		t.Fatalf("backdate corpse: %v", err)
	}
}

// TestInstanceRow_PersistsRecoveryFields: the live session's tmux name and spend
// binding land on the registry row so a later instance can reattach and still
// probe token spend.
func TestInstanceRow_PersistsRecoveryFields(t *testing.T) {
	m, _ := baseSessionModel(t)
	yes := true
	m.localSessions = map[string]liveSession{
		"demo": {typ: "spec", initiator: "human", started: time.Now(),
			tmuxName: "lore-me-demo", requestID: "spawn-1", sessionID: "uuid-1", harness: "claude-code", autoClose: &yes,
			closeRequests: []string{"term-1", "explicit-2"}},
	}
	row := m.instanceRow()
	if len(row.Sessions) != 1 {
		t.Fatalf("expected 1 session, got %d", len(row.Sessions))
	}
	s := row.Sessions[0]
	if s.Tmux != "lore-me-demo" || s.SessionID != "uuid-1" || s.Harness != "claude-code" || s.AutoClose == nil || !*s.AutoClose {
		t.Fatalf("recovery fields not persisted onto row: %+v", s)
	}
	if s.RequestID != "spawn-1" {
		t.Fatalf("spawn request identity not persisted: %+v", s)
	}
	if len(s.CloseRequests) != 2 || s.CloseRequests[0] != "term-1" || s.CloseRequests[1] != "explicit-2" {
		t.Fatalf("close-request recovery manifest not persisted: %+v", s)
	}
}

// TestAdoptionScan_DeadSessionJournalsOrphaned covers the no-survivor recovery
// boundary, including persisted spawn identity and the protocol DUE.
func TestAdoptionScan_DeadSessionJournalsOrphaned(t *testing.T) {
	m, sessionsDir := baseSessionModel(t)
	kdir := m.config.KnowledgeDir
	m.config.RepoIdentifier = "my-repo"
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	plantCorpse(t, sessionsDir, "dead-inst", "my-repo", deadPID(t), []session.Session{
		{Slug: "demo", Type: "spec", Initiator: "human", Started: "2026-07-06T00:00:00Z",
			RequestID:     "spawn-1",
			CloseRequests: []string{"term-1", "explicit-2"}}, // no Tmux
	})

	msg := m.adoptionScanCmd()().(adoptionScanMsg)
	if len(msg.alive) != 0 {
		t.Fatalf("dead (no-tmux) session returned as alive: %+v", msg.alive)
	}
	if got := readEventTypes(t, kdir); len(got) != 1 || got[0] != session.EventOrphaned {
		t.Fatalf("events = %v, want exactly [orphaned]", got)
	}
	rows := readEventRows(t, kdir)
	if rows[0].RequestID != "spawn-1" || rows[0].Reason != "instance-death" || rows[0].TargetInstance == nil || *rows[0].TargetInstance != "dead-inst" {
		t.Fatalf("orphaned identity = %+v", rows[0])
	}
	var spend map[string]any
	if err := json.Unmarshal(rows[0].Spend, &spend); err != nil || spend["basis"] != "duration-only" {
		t.Fatalf("orphaned spend = %s err=%v", rows[0].Spend, err)
	}
	dueRows := readJSONLines(t, filepath.Join(kdir, "_scorecards", "retro-deferred-queue.jsonl"))
	if len(dueRows) != 1 || dueRows[0]["event_type"] != "session-orphaned" || dueRows[0]["stratum"] != "instance_death" || dueRows[0]["disposition"] != "unhandled" {
		t.Fatalf("orphan DUE rows = %+v", dueRows)
	}
	// The corpse and any claim file are gone (adoption doubles as corpse cleanup).
	leftover, _ := filepath.Glob(filepath.Join(session.InstancesDir(sessionsDir), "*"))
	if len(leftover) != 0 {
		t.Fatalf("corpse/claim files left behind: %v", leftover)
	}
}

func writeCloseRequestFixture(t *testing.T, sessionsDir string, cr session.CloseRequest) string {
	t.Helper()
	dir := session.CloseRequestsDir(sessionsDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, cr.RequestID+".json")
	data, err := json.Marshal(cr)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestRetireDeadTargetCloseRequests_AppendBeforeDeleteRetryIdempotent(t *testing.T) {
	m, sessionsDir := baseSessionModel(t)
	script, kdir := repoScriptPath(t, "session-event-append.sh"), m.config.KnowledgeDir
	cr := session.CloseRequest{RequestID: "close-1", Slug: "demo", TargetInstance: "dead-inst", Reason: "coordinator"}
	path := writeCloseRequestFixture(t, sessionsDir, cr)
	notices, diagnostics := retireDeadTargetCloseRequests(sessionsDir, script, kdir, "me", "dead-inst")
	if len(notices) != 0 || len(diagnostics) != 0 {
		t.Fatalf("retirement notices=%+v diagnostics=%+v", notices, diagnostics)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("request not deleted after append: %v", err)
	}
	writeCloseRequestFixture(t, sessionsDir, cr)
	retireDeadTargetCloseRequests(sessionsDir, script, kdir, "me", "dead-inst")
	rows := readEventRows(t, kdir)
	if len(rows) != 1 || rows[0].Event != session.EventCloseFailed || rows[0].Reason != closeFailedTargetInstanceDead || rows[0].TargetInstance == nil || *rows[0].TargetInstance != "dead-inst" {
		t.Fatalf("retirement rows = %+v", rows)
	}
}

// TestEmitRecoveredCmd_DurableBeforeJournal: the adopting instance's registry row
// (now listing the recovered session) is written before the `recovered` journal
// row, and both flow through the substrate (WriteInstance + the sole-writer
// script).
func TestEmitRecoveredCmd_DurableBeforeJournal(t *testing.T) {
	m, sessionsDir := baseSessionModel(t)
	kdir := m.config.KnowledgeDir
	script := repoScriptPath(t, "session-event-append.sh")
	inst := session.Instance{Name: "me", Repo: "r", PID: os.Getpid(), Started: "2026-07-06T00:00:00Z",
		Sessions: []session.Session{{Slug: "demo", Type: "spec", Initiator: "human", Started: "2026-07-06T00:00:00Z", Tmux: "lore-me-demo"}}}
	ev := session.Event{Event: session.EventRecovered, ActorInstance: session.StrPtr("me"),
		Slug: "demo", SessionType: "spec", Initiator: "human", Reason: "adopted from dead-inst"}

	res, ok := emitRecoveredCmd(sessionsDir, script, kdir, inst, ev)().(journalResultMsg)
	if !ok || res.err != nil {
		t.Fatalf("emitRecoveredCmd: ok=%v err=%v", ok, res.err)
	}
	// Durable row written with the session.
	found := false
	for _, got := range session.ListInstances(sessionsDir) {
		if got.Name == "me" && len(got.Sessions) == 1 && got.Sessions[0].Tmux == "lore-me-demo" {
			found = true
		}
	}
	if !found {
		t.Fatal("recovered row not written to the registry")
	}
	if got := readEventTypes(t, kdir); len(got) != 1 || got[0] != session.EventRecovered {
		t.Fatalf("events = %v, want exactly [recovered]", got)
	}
}

// TestCleanupAllSubprocesses_QuitDetachesTmux is D8: on quit, a tmux-hosted session
// is neither journaled `closed` nor removed from the manifest (the harness survives
// for adoption), while a direct-PTY session keeps the kill+closed behavior and is
// dropped from the row that is left on disk.
func TestCleanupAllSubprocesses_QuitDetachesTmux(t *testing.T) {
	m, sessionsDir := baseSessionModel(t)
	kdir := m.config.KnowledgeDir
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	m.localSessions = map[string]liveSession{
		"tmuxed": {typ: "spec", initiator: "human", started: time.Now(), tmuxName: "lore-me-tmuxed"},
		"direct": {typ: "chat", initiator: "agent", started: time.Now()},
	}
	m.sessionPanels = map[string]work.SessionPanelModel{
		"tmuxed": work.NewSessionPanelModel("tmuxed"),
		"direct": work.NewSessionPanelModel("direct"),
	}
	if err := session.WriteInstance(sessionsDir, m.instanceRow()); err != nil {
		t.Fatal(err)
	}

	m.cleanupAllSubprocesses()

	// Only the direct-PTY session is journaled closed.
	if got := readEventTypes(t, kdir); len(got) != 1 || got[0] != session.EventClosed {
		t.Fatalf("events = %v, want exactly [closed] (direct-PTY only)", got)
	}
	// The manifest survives (tmux session lives) and lists only the survivor.
	var me *session.Instance
	for _, inst := range session.ListInstances(sessionsDir) {
		if inst.Name == "me" {
			cp := inst
			me = &cp
		}
	}
	if me == nil {
		t.Fatal("registry row removed despite a surviving tmux session")
	}
	if len(me.Sessions) != 1 || me.Sessions[0].Slug != "tmuxed" {
		t.Fatalf("manifest should list only the surviving tmux session, got %+v", me.Sessions)
	}
}

// TestCleanupAllSubprocesses_RemovesRowWhenNoTmux: with only direct-PTY sessions,
// quit keeps today's behavior — journal closed and remove the registry row.
func TestCleanupAllSubprocesses_RemovesRowWhenNoTmux(t *testing.T) {
	m, sessionsDir := baseSessionModel(t)
	kdir := m.config.KnowledgeDir
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	m.localSessions = map[string]liveSession{
		"direct": {typ: "chat", initiator: "agent", started: time.Now()},
	}
	m.sessionPanels = map[string]work.SessionPanelModel{"direct": work.NewSessionPanelModel("direct")}
	if err := session.WriteInstance(sessionsDir, m.instanceRow()); err != nil {
		t.Fatal(err)
	}

	m.cleanupAllSubprocesses()

	if got := readEventTypes(t, kdir); len(got) != 1 || got[0] != session.EventClosed {
		t.Fatalf("events = %v, want exactly [closed]", got)
	}
	if _, err := os.Stat(filepath.Join(session.InstancesDir(sessionsDir), "me.json")); !os.IsNotExist(err) {
		t.Fatalf("registry row not removed for an all-direct-PTY quit: %v", err)
	}
}

// TestAdoptionScan_LiveTmuxReattaches is the end-to-end recovery path against a
// real tmux server: a corpse row referencing a live tmux session is detected as
// adoptable (not closed), and the attach Cmd re-queries the surviving pane PID and
// re-hosts the panel. Skipped without tmux.
func TestAdoptionScan_LiveTmuxReattaches(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not installed; skipping live adoption integration")
	}
	m, sessionsDir := baseSessionModel(t)
	m.config.RepoIdentifier = "my-repo"
	m.eventScript = repoScriptPath(t, "session-event-append.sh")

	// Stand up a real survivor session on the dedicated server (unique name so the
	// test never disturbs a live TUI's sessions).
	name := "lore-test-adopt-" + strconv.Itoa(os.Getpid())
	if out, err := exec.Command("tmux", "-L", "lore-tui", "-f", "/dev/null",
		"new-session", "-d", "-s", name, "--", "sleep", "300").CombinedOutput(); err != nil {
		t.Fatalf("create survivor session: %v (%s)", err, out)
	}
	t.Cleanup(func() { _ = exec.Command("tmux", "-L", "lore-tui", "kill-session", "-t", name).Run() })

	plantCorpse(t, sessionsDir, "dead-inst", "my-repo", deadPID(t), []session.Session{
		{Slug: "demo", Type: "spec", Initiator: "human", Started: "2026-07-06T00:00:00Z",
			Tmux: name, RequestID: "spawn-1", SessionID: "uuid-1", Harness: "claude-code",
			CloseRequests: []string{"term-1"}},
	})
	retiredPath := writeCloseRequestFixture(t, sessionsDir, session.CloseRequest{
		RequestID: "close-dead", Slug: "demo", TargetInstance: "dead-inst", Reason: "coordinator",
	})

	msg := m.adoptionScanCmd()().(adoptionScanMsg)
	if got := readEventTypes(t, m.config.KnowledgeDir); len(got) != 1 || got[0] != session.EventCloseFailed {
		t.Fatalf("survivor adoption must emit only dead-target retirement, got events %v", got)
	}
	if len(msg.alive) != 1 || msg.alive[0].slug != "demo" || msg.alive[0].tmuxName != name {
		t.Fatalf("live tmux session not returned as adoptable: %+v", msg.alive)
	}
	if msg.alive[0].requestID != "spawn-1" || msg.alive[0].sessionID != "uuid-1" || msg.alive[0].harness != "claude-code" {
		t.Fatalf("recovered spend binding lost: %+v", msg.alive[0])
	}
	if len(msg.alive[0].closeRequests) != 1 || msg.alive[0].closeRequests[0] != "term-1" {
		t.Fatalf("recovered close-request manifest lost: %+v", msg.alive[0])
	}
	if leftover, _ := filepath.Glob(filepath.Join(session.InstancesDir(sessionsDir), "*")); len(leftover) != 0 {
		t.Fatalf("corpse not cleaned up: %v", leftover)
	}
	if _, err := os.Stat(retiredPath); !os.IsNotExist(err) {
		t.Fatalf("dead-target request survived adoption: %v", err)
	}

	// The attach Cmd re-hosts the survivor: it re-queries the pane PID (the crashed
	// instance's captured one is gone) and reports the same tmux session.
	started, ok := work.AttachTerminalCmd("demo", name, "uuid-1", "claude-code", m.config.ProjectDir, 80, 24)().(work.SessionProcessStartedMsg)
	if !ok {
		t.Fatalf("attach did not start; session likely died mid-test")
	}
	if started.Ptmx != nil {
		defer started.Ptmx.Close()
	}
	if started.Tmux != name || started.PanePID <= 0 {
		t.Fatalf("attach lost the tmux binding: tmux=%q panePID=%d", started.Tmux, started.PanePID)
	}
	if started.SessionID != "uuid-1" || started.Harness != "claude-code" {
		t.Fatalf("attach dropped the recovered spend binding: %+v", started)
	}
}
