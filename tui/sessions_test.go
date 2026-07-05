package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// baseSessionModel builds a minimal model wired for the session substrate at a
// temp store, with one work item that has a plan doc.
func baseSessionModel(t *testing.T) (model, string) {
	t.Helper()
	kdir := t.TempDir()
	sessionsDir := filepath.Join(kdir, "_sessions")
	m := model{
		state:        stateWork,
		layoutMode:   config.LayoutTopBottom,
		width:        120,
		height:       40,
		list:         work.NewListModel([]work.WorkItem{{Slug: "demo", HasPlanDoc: true}}),
		config:       config.Config{KnowledgeDir: kdir, ProjectDir: kdir},
		instanceName: "me",
		sessionsDir:  sessionsDir,
		eventScript:  "", // journal Cmds are constructed but not run in this test
	}
	return m, sessionsDir
}

// TestAgentClaimSpawnsWithoutStealingFocus is the TUI half of the closed loop: a
// planted request is claimed on a queue tick, a session panel is created, the
// spawn is marked agent-initiated, and focus is left untouched.
func TestAgentClaimSpawnsWithoutStealingFocus(t *testing.T) {
	m, sessionsDir := baseSessionModel(t)
	if err := session.WritePending(sessionsDir, session.Request{
		RequestID: "req-1", Type: "spec", Slug: strPtr("demo"), Initiator: "agent",
	}); err != nil {
		t.Fatal(err)
	}

	msg, ok := m.queueTickCmd()().(queueTickResultMsg)
	if !ok {
		t.Fatal("queueTickCmd did not return a queueTickResultMsg")
	}
	if msg.err != nil {
		t.Fatalf("queue tick error: %v", msg.err)
	}
	if msg.result.Claimed == nil || msg.result.Claimed.RequestID != "req-1" {
		t.Fatalf("request not claimed: %+v", msg.result.Claimed)
	}

	m, _ = m.handleQueueTickResult(msg)

	if _, ok := m.specPanels["demo"]; !ok {
		t.Fatal("no spec panel created for the claimed request")
	}
	meta, ok := m.pendingSpawns["demo"]
	if !ok {
		t.Fatal("claimed session not recorded in pendingSpawns")
	}
	if meta.initiator != "agent" || meta.requestID != "req-1" {
		t.Fatalf("pending spawn metadata wrong: %+v", meta)
	}
	if m.terminalMode {
		t.Error("agent spawn stole focus (terminalMode=true)")
	}
	if m.focusedPanel != panelLeft {
		t.Error("agent spawn moved focus off the list")
	}

	// The claim is durable: the claimed row carries this instance's name.
	claimed, err := session.ReadClaimed(sessionsDir, "req-1")
	if err != nil {
		t.Fatalf("ReadClaimed: %v", err)
	}
	if claimed.ClaimedBy == nil || *claimed.ClaimedBy != "me" {
		t.Fatalf("claim metadata not written: %+v", claimed)
	}
}

// TestSpecProcessStartedPromotesQueueSession verifies the started handler moves a
// pending agent spawn into the live session set and does not steal focus.
func TestSpecProcessStartedPromotesQueueSession(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.pendingSpawns = map[string]liveSession{
		"demo": {typ: "spec", initiator: "agent", requestID: "req-1"},
	}
	m, _ = m.handleSpecProcessStarted(work.SpecProcessStartedMsg{Slug: "demo"})

	if _, pending := m.pendingSpawns["demo"]; pending {
		t.Error("pending spawn was not consumed")
	}
	ls, ok := m.localSessions["demo"]
	if !ok {
		t.Fatal("session not promoted into localSessions")
	}
	if ls.initiator != "agent" || ls.typ != "spec" {
		t.Fatalf("promoted session metadata wrong: %+v", ls)
	}
	if m.terminalMode {
		t.Error("agent spawn stole focus on process start")
	}
}

// TestSpawnFromRequestThreadsAutoClose verifies the per-request auto_close
// override rides from the queue row through to the live session's metadata,
// where the close ladder reads it.
func TestSpawnFromRequestThreadsAutoClose(t *testing.T) {
	m, _ := baseSessionModel(t)
	hold := false
	m, _ = m.spawnFromRequest(session.Request{
		RequestID: "req-hold", Type: "implement", Slug: strPtr("demo"),
		Initiator: "agent", AutoClose: &hold,
	})
	meta, ok := m.pendingSpawns["demo"]
	if !ok {
		t.Fatal("spawn metadata not recorded")
	}
	if meta.autoClose == nil || *meta.autoClose != false {
		t.Fatalf("autoClose override not threaded onto the session: %+v", meta.autoClose)
	}
}

func strPtr(s string) *string { return &s }

// repoScriptPath resolves a repo script to an absolute path for tests that
// exercise the real journal appender.
func repoScriptPath(t *testing.T, name string) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("..", "scripts", name))
	if err != nil {
		t.Fatalf("resolve script path: %v", err)
	}
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("script not found (%s): %v", p, err)
	}
	return p
}

// runJournalCmds executes cmd, following tea.Batch fan-out, and fails on any
// journal emission error. Leaf Cmds run sequentially so the on-disk row order is
// deterministic.
func runJournalCmds(t *testing.T, cmd tea.Cmd) {
	t.Helper()
	if cmd == nil {
		return
	}
	switch msg := cmd().(type) {
	case tea.BatchMsg:
		for _, c := range msg {
			runJournalCmds(t, c)
		}
	case journalResultMsg:
		if msg.err != nil {
			t.Fatalf("journal emission failed: %v", msg.err)
		}
	}
}

// readEventTypes returns the `event` field of every events.jsonl row, in order.
func readEventTypes(t *testing.T, kdir string) []string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(kdir, "_sessions", "events.jsonl"))
	if err != nil {
		return nil
	}
	var types []string
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if line == "" {
			continue
		}
		var row struct {
			Event string `json:"event"`
		}
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			t.Fatalf("bad events.jsonl row %q: %v", line, err)
		}
		types = append(types, row.Event)
	}
	return types
}

// sessionModelWithRealScript wires a model to the real appender with one live
// local session ("demo") so needs-input transitions can be journaled end-to-end.
func sessionModelWithRealScript(t *testing.T) model {
	t.Helper()
	m, _ := baseSessionModel(t)
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	m.localSessions = map[string]liveSession{
		"demo": {typ: "spec", initiator: "human", started: time.Now()},
	}
	return m
}

// TestIdleEventFor covers the transition-row builder: it carries the running
// instance and session identity but no request_id (these are session-transition
// events, not queue-lifecycle events).
func TestIdleEventFor(t *testing.T) {
	m, _ := baseSessionModel(t)
	ls := liveSession{typ: "implement", initiator: "agent"}
	ev := m.idleEventFor("demo", session.EventNeedsInput, ls)
	if ev.Event != session.EventNeedsInput {
		t.Errorf("event = %q, want %q", ev.Event, session.EventNeedsInput)
	}
	if ev.ActorInstance == nil || *ev.ActorInstance != "me" {
		t.Errorf("actor_instance = %v, want me", ev.ActorInstance)
	}
	if ev.Slug != "demo" || ev.SessionType != "implement" || ev.Initiator != "agent" {
		t.Errorf("identity wrong: %+v", ev)
	}
	if ev.RequestID != "" {
		t.Errorf("transition event must not carry request_id, got %q", ev.RequestID)
	}
}

// TestNeedsInputChangedJournalsTransitions is the end-to-end trace through the
// real appender: entering needs-input lands quiescent + needs_input, a repeated
// same-state tick re-emits nothing (edge guard), and resuming lands resumed.
func TestNeedsInputChangedJournalsTransitions(t *testing.T) {
	m := sessionModelWithRealScript(t)
	kdir := m.config.KnowledgeDir

	// Enter idle: the panel's single quiescence signal grounds both events.
	var cmd tea.Cmd
	m, cmd = m.handleNeedsInputChanged(work.NeedsInputChangedMsg{Slug: "demo", NeedsInput: true})
	if !m.sessionIdle["demo"] {
		t.Fatal("sessionIdle not set on enter")
	}
	runJournalCmds(t, cmd)
	got := readEventTypes(t, kdir)
	if len(got) != 2 {
		t.Fatalf("enter emitted %v, want two events", got)
	}
	seen := map[string]bool{got[0]: true, got[1]: true}
	if !seen[session.EventQuiescent] || !seen[session.EventNeedsInput] {
		t.Fatalf("enter events = %v, want quiescent + needs_input", got)
	}

	// Repeated enter tick in the same state: guard suppresses re-emission.
	m, cmd = m.handleNeedsInputChanged(work.NeedsInputChangedMsg{Slug: "demo", NeedsInput: true})
	if cmd != nil {
		t.Fatal("repeated needs-input tick re-emitted")
	}
	if n := len(readEventTypes(t, kdir)); n != 2 {
		t.Fatalf("guard failed: events grew to %d", n)
	}

	// Leave idle: resumed.
	m, cmd = m.handleNeedsInputChanged(work.NeedsInputChangedMsg{Slug: "demo", NeedsInput: false})
	if m.sessionIdle["demo"] {
		t.Fatal("sessionIdle not cleared on resume")
	}
	runJournalCmds(t, cmd)
	got = readEventTypes(t, kdir)
	if len(got) != 3 || got[2] != session.EventResumed {
		t.Fatalf("resume events = %v, want trailing resumed", got)
	}

	// Repeated leave tick: guard suppresses again.
	_, cmd = m.handleNeedsInputChanged(work.NeedsInputChangedMsg{Slug: "demo", NeedsInput: false})
	if cmd != nil {
		t.Fatal("repeated resume tick re-emitted")
	}
}

// TestNeedsInputChangedUntrackedSlug: a transition for a slug this instance does
// not own is never journaled (no identity to attribute it to).
func TestNeedsInputChangedUntrackedSlug(t *testing.T) {
	m := sessionModelWithRealScript(t)
	_, cmd := m.handleNeedsInputChanged(work.NeedsInputChangedMsg{Slug: "ghost", NeedsInput: true})
	if cmd != nil {
		t.Fatal("emitted for a slug not in localSessions")
	}
}

// TestEndLocalSessionClearsIdleGuard: closing a session drops its idle-guard
// entry so a later session reusing the slug starts from a clean edge.
func TestEndLocalSessionClearsIdleGuard(t *testing.T) {
	m := sessionModelWithRealScript(t)
	m.sessionIdle = map[string]bool{"demo": true}
	m, _ = m.endLocalSession("demo")
	if _, ok := m.sessionIdle["demo"]; ok {
		t.Fatal("idle guard not cleared on session end")
	}
}

// TestTabIndicatorIdentityRendering covers the chrome bullet: the "<repo> · name"
// identity right-aligns into the tab row when it fits and is dropped (never
// wrapped) when the row is too narrow, at every width the row itself stays
// exactly `width` visible columns.
func TestTabIndicatorIdentityRendering(t *testing.T) {
	identity := "github.com/x/y · amber-otter"
	idW := lipgloss.Width(identity)
	// baseW is the width of the tab sections alone; the row never truncates below
	// it, so identity fitting is judged against baseW, not the raw width.
	baseW := lipgloss.Width(strings.TrimRight(stripANSI(renderTabIndicator(stateWork, 1, 2, 3, 200, "")), " "))
	for _, width := range []int{60, 80, 120, 200} {
		out := stripANSI(renderTabIndicator(stateWork, 1, 2, 3, width, identity))
		wantW := width
		if baseW > width {
			wantW = baseW
		}
		if lipgloss.Width(out) != wantW {
			t.Fatalf("width %d: row width = %d, want %d", width, lipgloss.Width(out), wantW)
		}
		if baseW+1+idW <= width {
			if !strings.HasSuffix(out, identity) {
				t.Errorf("width %d: identity should be right-aligned, got %q", width, out)
			}
		} else if strings.Contains(out, "amber-otter") {
			t.Errorf("width %d: identity should have been dropped, got %q", width, out)
		}
	}
}
