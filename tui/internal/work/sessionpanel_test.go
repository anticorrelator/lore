package work

import (
	"os"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
)

func TestQuiescenceTickEmitsNeedsInputAfterThreshold(t *testing.T) {
	m := NewSessionPanelModel("test")
	// Simulate output arriving 6 seconds ago (past the 5s threshold).
	m.lastOutputTime = time.Now().Add(-6 * time.Second)
	m.needsInput = false

	m, cmd := m.Update(QuiescenceTickMsg{Slug: "test"})

	if !m.needsInput {
		t.Fatal("expected needsInput to be true after quiescence threshold")
	}
	if cmd == nil {
		t.Fatal("expected a batched command (NeedsInputChangedMsg + re-arm tick)")
	}
	// Execute the batched commands and check for NeedsInputChangedMsg.
	cmds := extractBatchCmds(cmd)
	foundChanged := false
	for _, c := range cmds {
		msg := c()
		if changed, ok := msg.(NeedsInputChangedMsg); ok {
			foundChanged = true
			if !changed.NeedsInput {
				t.Error("expected NeedsInputChangedMsg.NeedsInput to be true")
			}
			if changed.Slug != "test" {
				t.Errorf("expected slug 'test', got %q", changed.Slug)
			}
		}
	}
	if !foundChanged {
		t.Fatal("expected NeedsInputChangedMsg in batched commands")
	}
}

func TestQuiescenceTickNoEmitBeforeThreshold(t *testing.T) {
	m := NewSessionPanelModel("test")
	// Simulate output arriving 2 seconds ago (within the 5s threshold).
	m.lastOutputTime = time.Now().Add(-2 * time.Second)
	m.needsInput = false

	m, cmd := m.Update(QuiescenceTickMsg{Slug: "test"})

	if m.needsInput {
		t.Fatal("expected needsInput to remain false before threshold")
	}
	if cmd == nil {
		t.Fatal("expected re-arm tick command")
	}
	// The returned cmd should be a tick re-arm, not a batch with NeedsInputChangedMsg.
	msg := cmd()
	if _, ok := msg.(NeedsInputChangedMsg); ok {
		t.Fatal("should not emit NeedsInputChangedMsg before threshold")
	}
}

func TestOutputClearsNeedsInput(t *testing.T) {
	m := NewSessionPanelModel("test")
	m.lastOutputTime = time.Now().Add(-10 * time.Second)
	m.needsInput = true

	m, cmd := m.Update(TerminalOutputMsg{Slug: "test", Data: []byte("output")})

	if m.needsInput {
		t.Fatal("expected needsInput to be cleared on new output")
	}
	if m.lastOutputTime.IsZero() {
		t.Fatal("expected lastOutputTime to be updated")
	}
	// Should have a command that emits NeedsInputChangedMsg{NeedsInput: false}.
	if cmd == nil {
		t.Fatal("expected command with NeedsInputChangedMsg")
	}
	// The TerminalOutputMsg handler uses tea.Batch when clearing needsInput.
	cmds := extractBatchCmds(cmd)
	foundCleared := false
	for _, c := range cmds {
		msg := c()
		if changed, ok := msg.(NeedsInputChangedMsg); ok {
			foundCleared = true
			if changed.NeedsInput {
				t.Error("expected NeedsInputChangedMsg.NeedsInput to be false")
			}
		}
	}
	if !foundCleared {
		t.Fatal("expected NeedsInputChangedMsg{NeedsInput: false} in commands")
	}
}

// TestBuildInitialPrompt is a table over descriptor Types covering every prompt
// construction path: chat (/work and /followup-discuss, with --finding and
// extra-context variants), implement (/implement, with --yes and -- context
// variants), and spec (/spec, with short/--yes/-- context variants).
func TestBuildInitialPrompt(t *testing.T) {
	tests := []struct {
		name string
		desc SessionDescriptor
		want string
	}{
		{
			name: "followup chat uses /followup-discuss prefix",
			desc: SessionDescriptor{Type: SessionChat, Slug: "my-followup", FollowupMode: true, FindingIndex: -1},
			want: "/followup-discuss my-followup",
		},
		{
			name: "followup chat with extraContext appends it",
			desc: SessionDescriptor{Type: SessionChat, Slug: "my-followup", ExtraContext: "extra info", FollowupMode: true, FindingIndex: -1},
			want: "/followup-discuss my-followup: extra info",
		},
		{
			name: "followup chat with findingIndex inserts --finding after the ID",
			desc: SessionDescriptor{Type: SessionChat, Slug: "my-followup", FollowupMode: true, FindingIndex: 3},
			want: "/followup-discuss my-followup --finding 3",
		},
		{
			name: "followup chat with findingIndex and extraContext",
			desc: SessionDescriptor{Type: SessionChat, Slug: "my-followup", ExtraContext: "some context", FollowupMode: true, FindingIndex: 0},
			want: "/followup-discuss my-followup --finding 0: some context",
		},
		{
			name: "regular chat uses /work with slug",
			desc: SessionDescriptor{Type: SessionChat, Slug: "some-slug", FindingIndex: -1},
			want: "/work some-slug",
		},
		{
			name: "regular chat with extraContext appends it",
			desc: SessionDescriptor{Type: SessionChat, Slug: "some-slug", ExtraContext: "more context", FindingIndex: -1},
			want: "/work some-slug: more context",
		},
		{
			name: "implement uses /implement with slug",
			desc: SessionDescriptor{Type: SessionImplement, Slug: "my-impl", FindingIndex: -1},
			want: "/implement my-impl",
		},
		{
			name: "implement with skipConfirm appends --yes",
			desc: SessionDescriptor{Type: SessionImplement, Slug: "my-impl", SkipConfirm: true, FindingIndex: -1},
			want: "/implement my-impl --yes",
		},
		{
			name: "implement with extraContext appends -- separator",
			desc: SessionDescriptor{Type: SessionImplement, Slug: "my-impl", ExtraContext: "ship it", FindingIndex: -1},
			want: "/implement my-impl -- ship it",
		},
		{
			name: "implement with skipConfirm and extraContext",
			desc: SessionDescriptor{Type: SessionImplement, Slug: "my-impl", SkipConfirm: true, ExtraContext: "ship it", FindingIndex: -1},
			want: "/implement my-impl --yes -- ship it",
		},
		{
			name: "spec uses /spec prefix",
			desc: SessionDescriptor{Type: SessionSpec, Slug: "my-spec", FindingIndex: -1},
			want: "/spec my-spec",
		},
		{
			name: "spec short includes short keyword",
			desc: SessionDescriptor{Type: SessionSpec, Slug: "my-spec", ShortMode: true, FindingIndex: -1},
			want: "/spec short my-spec",
		},
		{
			name: "spec with skipConfirm appends --yes",
			desc: SessionDescriptor{Type: SessionSpec, Slug: "my-spec", SkipConfirm: true, FindingIndex: -1},
			want: "/spec my-spec --yes",
		},
		{
			name: "spec with extraContext appends -- separator",
			desc: SessionDescriptor{Type: SessionSpec, Slug: "my-spec", ExtraContext: "some extra", FindingIndex: -1},
			want: "/spec my-spec -- some extra",
		},
		{
			name: "worker emits the brief verbatim, no skill invocation",
			desc: SessionDescriptor{Type: SessionWorker, Slug: "impl-foo--w1", ExtraContext: "You are worker-1. Do the thing.", FindingIndex: -1},
			want: "You are worker-1. Do the thing.",
		},
		{
			name: "worker with empty brief returns empty, never falls to /spec",
			desc: SessionDescriptor{Type: SessionWorker, Slug: "impl-foo--w1", FindingIndex: -1},
			want: "",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := buildInitialPrompt(tc.desc); got != tc.want {
				t.Errorf("buildInitialPrompt(%+v) = %q, want %q", tc.desc, got, tc.want)
			}
		})
	}
}

// TestAppendFindingContext covers the finding-scoped prompt building logic.
func TestAppendFindingContext(t *testing.T) {
	sidecar := `{
		"pr": 42,
		"work_item": "test-work",
		"findings": [
			{
				"severity": "blocking",
				"title": "Missing error check",
				"file": "main.go",
				"line": 10,
				"body": "This ignores the error return value.",
				"lens": "correctness",
				"disposition": "action",
				"rationale": "Silent data loss."
			},
			{
				"severity": "suggestion",
				"title": "Extract helper",
				"file": "utils.go",
				"line": 0,
				"body": "Could be a helper.",
				"lens": "clarity",
				"disposition": "deferred",
				"rationale": ""
			}
		]
	}`
	base := "# Followup Context\n\n**Title:** My Followup\n"

	t.Run("finding index 0 — full fields", func(t *testing.T) {
		out := appendFindingContext(base, []byte(sidecar), 0)
		if out == "" {
			t.Fatal("expected non-empty output for valid index 0")
		}
		if !strings.Contains(out, "**Finding Index:** 0 of 2") {
			t.Errorf("expected finding index header, got: %q", out)
		}
		if !strings.Contains(out, "**Title:** Missing error check") {
			t.Error("expected finding title")
		}
		if !strings.Contains(out, "**Severity:** blocking") {
			t.Error("expected severity")
		}
		if !strings.Contains(out, "**Disposition:** action") {
			t.Error("expected disposition")
		}
		if !strings.Contains(out, "**Rationale:** Silent data loss.") {
			t.Error("expected rationale")
		}
		if !strings.Contains(out, "**File:** main.go:10") {
			t.Error("expected file with line number")
		}
		if !strings.Contains(out, "**Lens:** correctness") {
			t.Error("expected lens")
		}
		if !strings.Contains(out, "This ignores the error return value.") {
			t.Error("expected body text")
		}
		// Base prompt should be preserved.
		if !strings.HasPrefix(out, base) {
			t.Error("output should begin with base prompt")
		}
	})

	t.Run("finding index 1 — zero line, empty rationale", func(t *testing.T) {
		out := appendFindingContext(base, []byte(sidecar), 1)
		if out == "" {
			t.Fatal("expected non-empty output for valid index 1")
		}
		if !strings.Contains(out, "**Finding Index:** 1 of 2") {
			t.Error("expected finding index header")
		}
		if !strings.Contains(out, "**File:** utils.go") {
			t.Error("expected file without line suffix for line=0")
		}
		if strings.Contains(out, "utils.go:0") {
			t.Error("should not include :0 suffix for zero line")
		}
		if strings.Contains(out, "**Rationale:**") {
			t.Error("should omit Rationale line when empty")
		}
	})

	t.Run("out of range index returns empty string", func(t *testing.T) {
		out := appendFindingContext(base, []byte(sidecar), 99)
		if out != "" {
			t.Errorf("expected empty string for out-of-range index, got %q", out)
		}
	})

	t.Run("malformed JSON returns empty string", func(t *testing.T) {
		out := appendFindingContext(base, []byte("not json"), 0)
		if out != "" {
			t.Errorf("expected empty string for malformed JSON, got %q", out)
		}
	})

	t.Run("negative index returns empty string", func(t *testing.T) {
		out := appendFindingContext(base, []byte(sidecar), -1)
		if out != "" {
			t.Errorf("expected empty string for negative index, got %q", out)
		}
	})
}

// --- Esc gesture tests ----------------------------------------------------
//
// The terminal panel forwards a single Esc to the PTY (so harnesses like
// Claude Code can use it to interrupt running work) and detaches focus only
// on a second Esc within escDetachWindow with no intervening non-Esc key.
// See SessionPanelModel.handleEscKey.

// firstCmdMsg runs cmd and returns the first message it emits, unwrapping a
// tea.BatchMsg if present. Returns nil for a nil cmd.
func firstCmdMsg(cmd tea.Cmd) tea.Msg {
	if cmd == nil {
		return nil
	}
	msg := cmd()
	if batch, ok := msg.(tea.BatchMsg); ok && len(batch) > 0 {
		return batch[0]()
	}
	return msg
}

func TestSpecPanelSingleEscForwardsAndDoesNotDetach(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	defer w.Close()

	m := NewSessionPanelModel("test")
	m.ptmx = w

	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})

	if msg := firstCmdMsg(cmd); msg != nil {
		if _, ok := msg.(TerminalDetachMsg); ok {
			t.Fatal("single Esc emitted TerminalDetachMsg; expected forward without detach")
		}
	}
	if m.lastEscTime.IsZero() {
		t.Errorf("lastEscTime should be armed after first Esc")
	}

	// Verify \x1b reached the PTY.
	if err := r.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 1)
	n, err := r.Read(buf)
	if err != nil || n != 1 || buf[0] != 0x1b {
		t.Fatalf("expected 0x1b forwarded to PTY; got n=%d err=%v buf=%v", n, err, buf)
	}
}

func TestSpecPanelDoubleEscDetaches(t *testing.T) {
	m := NewSessionPanelModel("test")
	// Leave m.ptmx nil — handleEscKey skips the write but still arms/fires.

	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})

	msg := firstCmdMsg(cmd)
	detach, ok := msg.(TerminalDetachMsg)
	if !ok {
		t.Fatalf("expected TerminalDetachMsg from second Esc; got %T", msg)
	}
	if detach.Slug != "test" {
		t.Errorf("detach slug: expected %q, got %q", "test", detach.Slug)
	}
	if !m.lastEscTime.IsZero() {
		t.Errorf("lastEscTime should be cleared after detach fires")
	}
}

func TestSpecPanelEscOutsideWindowForwardsAgain(t *testing.T) {
	m := NewSessionPanelModel("test")

	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	// Backdate the arm so the next Esc falls outside the window.
	m.lastEscTime = m.lastEscTime.Add(-2 * escDetachWindow)

	_, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if msg := firstCmdMsg(cmd); msg != nil {
		if _, ok := msg.(TerminalDetachMsg); ok {
			t.Fatal("Esc after window expired produced detach; expected re-arm and forward")
		}
	}
}

func TestSpecPanelInterveningKeyClearsEscArm(t *testing.T) {
	m := NewSessionPanelModel("test")

	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	// A non-Esc key arriving between the two Escs should clear the arm so the
	// follow-up Esc is treated as a fresh single press, not a detach.
	m, _ = m.Update(tea.KeyPressMsg{Code: 'a', Text: "a"})
	if !m.lastEscTime.IsZero() {
		t.Errorf("non-Esc key should clear lastEscTime; got %v", m.lastEscTime)
	}

	_, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if msg := firstCmdMsg(cmd); msg != nil {
		if _, ok := msg.(TerminalDetachMsg); ok {
			t.Fatal("Esc after intervening key produced detach; expected forward")
		}
	}
}

// --- Close-request hold + closed-panel input refusal ---------------------

// TestMarkCloseRequestedFlipsBadge: the held-open badge is off on a fresh panel,
// flips on with MarkCloseRequested, and is distinct from done (the harness of a
// held-open session is still live).
func TestMarkCloseRequestedFlipsBadge(t *testing.T) {
	m := NewSessionPanelModel("demo")
	if m.CloseRequested() {
		t.Fatal("fresh panel should not be close-requested")
	}
	m = m.MarkCloseRequested()
	if !m.CloseRequested() {
		t.Fatal("MarkCloseRequested should set the badge")
	}
	if m.IsDone() {
		t.Fatal("a held-open close-requested panel must not read as done")
	}
}

// TestQuiescentForCloseScreenGate is the teardown-readiness truth table: a
// finished process is always safe to close; a running-but-idle session is safe
// only when it is NOT sitting at an interactive prompt (the screen gate).
func TestQuiescentForCloseScreenGate(t *testing.T) {
	donePanel, _ := NewSessionPanelModel("demo").Update(StreamCompleteMsg{Slug: "demo"})
	idle := NewSessionPanelModel("demo")
	idle.needsInput = true
	running := NewSessionPanelModel("demo") // needsInput false, not done

	cases := []struct {
		name        string
		panel       SessionPanelModel
		interactive bool
		want        bool
	}{
		{"done ignores interactive flag", donePanel, true, true},
		{"idle, no prompt → close", idle, false, true},
		{"idle at interactive prompt → hold", idle, true, false},
		{"running → wait", running, false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.panel.QuiescentForClose(tc.interactive); got != tc.want {
				t.Errorf("QuiescentForClose(%v) = %v, want %v", tc.interactive, got, tc.want)
			}
		})
	}
}

// TestClosedPanelRefusesInputVisibly: keystrokes and paste to a torn-down (done)
// session emit ClosedPanelInputMsg — the host's status-line notice — instead of
// writing into a dead PTY, while ctrl+\ still dismisses the panel and scrollback
// keys still navigate retained history.
func TestClosedPanelRefusesInputVisibly(t *testing.T) {
	closed := func() SessionPanelModel {
		m, _ := NewSessionPanelModel("demo").Update(StreamCompleteMsg{Slug: "demo"})
		return m
	}

	t.Run("printable key refused", func(t *testing.T) {
		_, cmd := closed().Update(tea.KeyPressMsg{Code: 'a', Text: "a"})
		msg, ok := firstCmdMsg(cmd).(ClosedPanelInputMsg)
		if !ok {
			t.Fatalf("expected ClosedPanelInputMsg, got %T", firstCmdMsg(cmd))
		}
		if msg.Slug != "demo" {
			t.Errorf("notice slug = %q, want demo", msg.Slug)
		}
	})

	t.Run("esc refused", func(t *testing.T) {
		_, cmd := closed().Update(tea.KeyPressMsg{Code: tea.KeyEscape})
		if _, ok := firstCmdMsg(cmd).(ClosedPanelInputMsg); !ok {
			t.Fatalf("expected ClosedPanelInputMsg for esc, got %T", firstCmdMsg(cmd))
		}
	})

	t.Run("paste refused", func(t *testing.T) {
		_, cmd := closed().Update(tea.PasteMsg{Content: "hello"})
		if _, ok := firstCmdMsg(cmd).(ClosedPanelInputMsg); !ok {
			t.Fatalf("expected ClosedPanelInputMsg for paste, got %T", firstCmdMsg(cmd))
		}
	})

	t.Run("ctrl+backslash still dismisses", func(t *testing.T) {
		_, cmd := closed().Update(tea.KeyPressMsg{Code: '\\', Mod: tea.ModCtrl})
		if _, ok := firstCmdMsg(cmd).(TerminalTerminateMsg); !ok {
			t.Fatalf("expected TerminalTerminateMsg for ctrl+\\, got %T", firstCmdMsg(cmd))
		}
	})

	t.Run("scrollback key still navigates", func(t *testing.T) {
		m := closed()
		m.height = 5
		m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyPgUp, Mod: tea.ModShift})
		if _, ok := firstCmdMsg(cmd).(ClosedPanelInputMsg); ok {
			t.Fatal("scrollback navigation on a closed panel should not be refused as input")
		}
		_ = m
	})
}

// extractBatchCmds extracts individual commands from a tea.Batch result.
// It runs the outer cmd and checks if the result is a tea.BatchMsg ([]tea.Cmd).
// Falls back to returning the single cmd if it's not a batch.
func extractBatchCmds(cmd tea.Cmd) []tea.Cmd {
	if cmd == nil {
		return nil
	}
	msg := cmd()
	if batch, ok := msg.(tea.BatchMsg); ok {
		return []tea.Cmd(batch)
	}
	// Not a batch — wrap the original cmd as a single-element slice.
	return []tea.Cmd{cmd}
}
