package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
	"github.com/anticorrelator/lore/tui/internal/worktree"
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

	if _, ok := m.sessionPanels["demo"]; !ok {
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
	m, _ = m.handleSessionProcessStarted(work.SessionProcessStartedMsg{Slug: "demo"})

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

// TestRequestFrameworkValue covers the queue row helper used by descriptor
// mapping: absent means no override, present preserves the framework id.
func TestRequestFrameworkValue(t *testing.T) {
	if got := (session.Request{}).FrameworkValue(); got != "" {
		t.Errorf("absent FrameworkValue() = %q, want empty", got)
	}
	if got := (session.Request{Framework: strPtr("codex")}).FrameworkValue(); got != "codex" {
		t.Errorf("FrameworkValue() = %q, want codex", got)
	}
}

// TestDescriptorFromRequestMapsDispatchFields asserts the additive request
// fields land on the descriptor: track "short" → ShortMode, model → Model,
// framework → Framework, and an explicit skip_confirm:false → SkipConfirm false
// (gated).
func TestDescriptorFromRequestMapsDispatchFields(t *testing.T) {
	gated := false
	identity := &worktree.Identity{Version: worktree.IdentityVersion, CanonicalPath: "/work/session", Epoch: "epoch-1", State: worktree.StateCaptured}
	d := descriptorFromRequest(session.Request{
		RequestID: "r", Type: "spec", Slug: strPtr("demo"), Initiator: "agent",
		Track: strPtr("short"), Model: strPtr("opus"), Framework: strPtr("codex"), SkipConfirm: &gated, WorktreeIdentity: identity,
		WorktreeID: strPtr("tree-1"), ExecutionDir: strPtr("/work/session"),
	})
	if !d.ShortMode {
		t.Error("track=short did not set ShortMode")
	}
	if d.Model != "opus" {
		t.Errorf("Model = %q, want opus", d.Model)
	}
	if d.Framework != "codex" {
		t.Errorf("Framework = %q, want codex", d.Framework)
	}
	if d.SkipConfirm {
		t.Error("skip_confirm=false did not set SkipConfirm gated (false)")
	}
	if d.Worktree != identity || d.Worktree.Epoch != "epoch-1" {
		t.Fatalf("worktree identity was not projected intact: %+v", d.Worktree)
	}
	if d.WorktreeID != "tree-1" || d.ExecutionDir != "/work/session" {
		t.Fatalf("managed placement was not projected intact: id=%q dir=%q", d.WorktreeID, d.ExecutionDir)
	}
}

// TestDescriptorFromRequestDefaults asserts the absent-field behavior: no track →
// full spec (ShortMode false), no model/framework → empty, and — the
// load-bearing one — absent skip_confirm preserves the historical queue-spawn
// autonomy (true).
func TestDescriptorFromRequestDefaults(t *testing.T) {
	d := descriptorFromRequest(session.Request{
		RequestID: "r", Type: "spec", Slug: strPtr("demo"), Initiator: "agent",
	})
	if d.ShortMode {
		t.Error("absent track should leave ShortMode false")
	}
	if d.Model != "" {
		t.Errorf("absent model should leave Model empty, got %q", d.Model)
	}
	if d.Framework != "" {
		t.Errorf("absent framework should leave Framework empty, got %q", d.Framework)
	}
	if !d.SkipConfirm {
		t.Error("absent skip_confirm must default to SkipConfirm true (queue-spawn autonomy)")
	}
}

func TestHumanModalSpawnDerivesCapturedWorktreeIdentity(t *testing.T) {
	source := t.TempDir()
	for _, args := range [][]string{
		{"init"},
		{"config", "user.email", "modal-test@example.invalid"},
		{"config", "user.name", "Modal Test"},
	} {
		cmd := exec.Command("git", args...)
		cmd.Dir = source
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	if err := os.WriteFile(filepath.Join(source, "marker"), []byte("host\n"), 0644); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("git", "add", "marker")
	cmd.Dir = source
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git add: %v: %s", err, out)
	}
	cmd = exec.Command("git", "commit", "-m", "fixture")
	cmd.Dir = source
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git commit: %v: %s", err, out)
	}

	var allocated work.SessionDescriptor
	marker := struct{}{}
	path := filepath.Join(t.TempDir(), "session-worktree")
	msg := allocateSessionWorktreeCmd(
		work.SessionDescriptor{Type: work.SessionChat, Slug: "modal", Initiator: "human"},
		source, path, "modal-epoch",
		func(d work.SessionDescriptor) tea.Msg { allocated = d; return marker },
	)()
	if _, ok := msg.(struct{}); !ok {
		t.Fatalf("allocation returned %T (%+v)", msg, msg)
	}
	expectedPath, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatalf("resolve derived path: %v", err)
	}
	if allocated.Worktree == nil || allocated.Worktree.State != worktree.StateCaptured || allocated.Worktree.CanonicalPath != expectedPath {
		t.Fatalf("derived worktree = %+v, want captured identity at %q", allocated.Worktree, expectedPath)
	}
	if err := worktree.ValidateIdentity(context.Background(), *allocated.Worktree); err != nil {
		t.Fatalf("derived identity is invalid: %v", err)
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
	m.sessionModalBlocked = map[string]bool{"demo": true}
	m, _ = m.endLocalSession("demo")
	if _, ok := m.sessionIdle["demo"]; ok {
		t.Fatal("idle guard not cleared on session end")
	}
	if _, ok := m.sessionModalBlocked["demo"]; ok {
		t.Fatal("modal guard not cleared on session end")
	}
}

// TestAdvanceModalObservationsJournalsEntries drives the heartbeat observation
// step through modal entry, persistence, an unobservable frame, classified
// clear, and re-entry. It uses the real sole writer so the row's mandatory
// reason and running-session identity are verified end to end.
func TestAdvanceModalObservationsJournalsEntries(t *testing.T) {
	m := sessionModelWithRealScript(t)
	m.sessionPanels = map[string]work.SessionPanelModel{"demo": {}}
	modalState, modalKnown := classifyScreen("claude-code", work.ScreenSnapshot{Rows: ccOptionSelectRows})
	clearState, clearKnown := classifyScreen("claude-code", work.ScreenSnapshot{Rows: ccComposerRows})
	if !modalKnown || !modalState.interactive || !clearKnown || clearState.interactive {
		t.Fatal("shared classifier fixtures do not provide modal and clear preconditions")
	}
	observations := []modalObservation{
		{known: modalKnown, blocked: modalState.interactive},
		{known: modalKnown, blocked: modalState.interactive},
		{},
		{known: clearKnown, blocked: clearState.interactive},
		{known: modalKnown, blocked: modalState.interactive},
	}
	m.observeModalFn = func(work.SessionPanelModel) modalObservation {
		obs := observations[0]
		observations = observations[1:]
		return obs
	}

	for i := 0; i < 5; i++ {
		var cmds []tea.Cmd
		m, cmds = m.advanceModalObservations()
		for _, cmd := range cmds {
			runJournalCmds(t, cmd)
		}
		if i == 2 && !m.sessionModalBlocked["demo"] {
			t.Fatal("unobservable frame cleared modal latch")
		}
	}

	data, err := os.ReadFile(filepath.Join(m.config.KnowledgeDir, "_sessions", "events.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 2 {
		t.Fatalf("modal entries emitted %d rows, want 2", len(lines))
	}
	for _, line := range lines {
		var ev session.Event
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			t.Fatal(err)
		}
		if ev.Event != session.EventModalBlocked || ev.Reason != "modal" || ev.Slug != "demo" {
			t.Fatalf("modal row = %+v", ev)
		}
		if ev.RequestID != "" {
			t.Fatalf("modal row carried request_id %q", ev.RequestID)
		}
	}
}

func TestHealthyCodexComposersEmitNoModalEvent(t *testing.T) {
	for _, tc := range []struct {
		name string
		rows []string
	}{
		{"approved suggestion", cxApproveSuggestionRows},
		{"current fast footer", cxComposerRows},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := sessionModelWithRealScript(t)
			m.sessionPanels = map[string]work.SessionPanelModel{"demo": {}}
			state, known := classifyScreen("codex", work.ScreenSnapshot{Rows: tc.rows})
			if !known || state.interactive || !state.composer {
				t.Fatalf("healthy composer classification = %+v known=%v", state, known)
			}
			m.observeModalFn = func(work.SessionPanelModel) modalObservation {
				return modalObservation{known: known, blocked: state.interactive}
			}
			m, cmds := m.advanceModalObservations()
			for _, cmd := range cmds {
				runJournalCmds(t, cmd)
			}
			if got := readEventTypes(t, m.config.KnowledgeDir); len(got) != 0 {
				t.Fatalf("healthy composer emitted modal journal rows: %v", got)
			}
			if m.sessionModalBlocked["demo"] {
				t.Fatal("healthy composer armed the modal latch")
			}
		})
	}
}

func normalizedEventRow(t *testing.T, kdir string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(kdir, "_sessions", "events.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	var row map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(data), &row); err != nil {
		t.Fatal(err)
	}
	delete(row, "event_id")
	delete(row, "ts")
	got, err := json.Marshal(row)
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func TestUnregisteredModalPathIsByteIdenticalToExistingJournalCommand(t *testing.T) {
	baseline := sessionModelWithRealScript(t)
	baselineCmd := journalCmd(baseline.eventScript, baseline.config.KnowledgeDir,
		baseline.modalBlockedEventFor("demo", baseline.localSessions["demo"]))
	runJournalCmds(t, baselineCmd)

	candidate := sessionModelWithRealScript(t)
	candidate.sessionPanels = map[string]work.SessionPanelModel{"demo": {}}
	signature := config.NumberedModalSignature{
		Kind: config.NumberedModalSignatureV1, Title: "Additional safety checks",
		Options: []config.ModalAnswerOption{{Number: 1, Label: "Retry"}, {Number: 2, Label: "Keep waiting"}},
	}
	candidate.observeModalFn = func(work.SessionPanelModel) modalObservation {
		return modalObservation{known: true, blocked: true, framework: "codex", numberedModal: &signature}
	}
	previousMatcher := matchModalAnswer
	matchModalAnswer = func(string, config.NumberedModalSignature) (config.ModalAnswerRegistration, bool) {
		return config.ModalAnswerRegistration{}, false
	}
	t.Cleanup(func() { matchModalAnswer = previousMatcher })
	candidate, cmds := candidate.advanceModalObservations()
	for _, cmd := range cmds {
		runJournalCmds(t, cmd)
	}
	if got, want := normalizedEventRow(t, candidate.config.KnowledgeDir), normalizedEventRow(t, baseline.config.KnowledgeDir); !bytes.Equal(got, want) {
		t.Fatalf("unregistered modal row changed:\n got %s\nwant %s", got, want)
	}
	if matches, _ := filepath.Glob(filepath.Join(candidate.sessionsDir, "answer-requests", "*.json")); len(matches) != 0 {
		t.Fatalf("unregistered modal created answer requests: %v", matches)
	}
}

func TestRegisteredModalJournalsBeforeAnswerEnqueue(t *testing.T) {
	m := sessionModelWithRealScript(t)
	m.sessionPanels = map[string]work.SessionPanelModel{"demo": {}}
	now := time.Now().UTC().Format(time.RFC3339)
	if err := session.WriteInstance(m.sessionsDir, session.Instance{
		Name: "me", PID: os.Getpid(), Repo: "test", Started: now, InitiatorDefault: "human",
		Sessions: []session.Session{{Slug: "demo", Type: "spec", Initiator: "human", Started: now}},
	}); err != nil {
		t.Fatal(err)
	}
	signature := config.NumberedModalSignature{
		Kind: config.NumberedModalSignatureV1, Title: "Additional safety checks",
		Options: []config.ModalAnswerOption{
			{Number: 1, Label: "Retry with a faster model"},
			{Number: 2, Label: "Keep waiting"},
			{Number: 3, Label: "Learn more"},
		},
	}
	registration := config.ModalAnswerRegistration{
		ID: "codex-additional-safety-checks-keep-waiting-v1", Enabled: true, Framework: "codex",
		Signature: signature, Answer: config.ModalAnswerChoice{Option: 2, Expect: "Additional safety checks"},
	}
	m.observeModalFn = func(work.SessionPanelModel) modalObservation {
		return modalObservation{known: true, blocked: true, framework: "codex", numberedModal: &signature}
	}
	previousMatcher := matchModalAnswer
	matchModalAnswer = func(string, config.NumberedModalSignature) (config.ModalAnswerRegistration, bool) {
		return registration, true
	}
	t.Cleanup(func() { matchModalAnswer = previousMatcher })
	m, cmds := m.advanceModalObservations()
	for _, cmd := range cmds {
		runJournalCmds(t, cmd)
	}
	if got := readEventTypes(t, m.config.KnowledgeDir); !slices.Equal(got, []string{session.EventModalBlocked, session.EventAnswerRequested}) {
		t.Fatalf("event order = %v", got)
	}
	requests := session.ScanAnswerRequests(m.sessionsDir)
	if len(requests) != 1 || requests[0].RegistrationID != registration.ID || requests[0].Option != 2 {
		t.Fatalf("answer requests = %+v", requests)
	}
}

// TestTabIndicatorIdentityRendering covers the chrome bullet: the "<repo> · name"
// identity right-aligns into the tab row with a two-cell edge gutter when it
// fits and is dropped (never wrapped) when the row is too narrow, at every
// width the row itself stays exactly `width` visible columns.
func TestTabIndicatorIdentityRendering(t *testing.T) {
	identity := "github.com/x/y · amber-otter"
	idW := lipgloss.Width(identity)
	// baseW is the width of the tab sections alone; the row never truncates below
	// it, so identity fitting is judged against baseW, not the raw width.
	baseW := lipgloss.Width(strings.TrimRight(stripANSI(renderTabIndicator(stateWork, 1, 2, 3, 4, 0, 200, "")), " "))
	for _, width := range []int{60, 80, 120, 200} {
		out := stripANSI(renderTabIndicator(stateWork, 1, 2, 3, 4, 0, width, identity))
		wantW := width
		if baseW > width {
			wantW = baseW
		}
		if lipgloss.Width(out) != wantW {
			t.Fatalf("width %d: row width = %d, want %d", width, lipgloss.Width(out), wantW)
		}
		if baseW+1+idW+tabIdentityRightPadding <= width {
			wantSuffix := identity + strings.Repeat(" ", tabIdentityRightPadding)
			if !strings.HasSuffix(out, wantSuffix) {
				t.Errorf("width %d: identity should have a %d-cell right gutter, got %q", width, tabIdentityRightPadding, out)
			}
		} else if strings.Contains(out, "amber-otter") {
			t.Errorf("width %d: identity should have been dropped, got %q", width, out)
		}
	}
}
