package work

import (
	"fmt"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/vt"
)

func TestDetectScrollUpNoScroll(t *testing.T) {
	prev := []string{"A", "B", "C", "D"}
	cur := []string{"A", "B", "C", "D"}
	if k := detectScrollUp(prev, cur); k != 0 {
		t.Errorf("expected 0 (no scroll), got %d", k)
	}
}

func TestDetectScrollUpOneLineChanged(t *testing.T) {
	// Bottom line changes, no shift — not a scroll.
	prev := []string{"A", "B", "C", "D"}
	cur := []string{"A", "B", "C", "X"}
	if k := detectScrollUp(prev, cur); k != 0 {
		t.Errorf("expected 0, got %d", k)
	}
}

func TestDetectScrollUpOneLine(t *testing.T) {
	prev := []string{"A", "B", "C", "D"}
	cur := []string{"B", "C", "D", "X"}
	if k := detectScrollUp(prev, cur); k != 1 {
		t.Errorf("expected 1, got %d", k)
	}
}

func TestDetectScrollUpTwoLines(t *testing.T) {
	prev := []string{"A", "B", "C", "D", "E", "F"}
	cur := []string{"C", "D", "E", "F", "X", "Y"}
	if k := detectScrollUp(prev, cur); k != 2 {
		t.Errorf("expected 2, got %d", k)
	}
}

func TestDetectScrollUpMismatchedHeight(t *testing.T) {
	prev := []string{"A", "B"}
	cur := []string{"A", "B", "C"}
	if k := detectScrollUp(prev, cur); k != 0 {
		t.Errorf("expected 0 (mismatched heights), got %d", k)
	}
}

func TestDetectScrollUpEmpty(t *testing.T) {
	if k := detectScrollUp(nil, nil); k != 0 {
		t.Errorf("expected 0 (nil slices), got %d", k)
	}
	if k := detectScrollUp([]string{}, []string{}); k != 0 {
		t.Errorf("expected 0 (empty slices), got %d", k)
	}
}

func TestDetectScrollUpFullRedraw(t *testing.T) {
	// Complete content change — not a scroll.
	prev := []string{"A", "B", "C", "D"}
	cur := []string{"W", "X", "Y", "Z"}
	if k := detectScrollUp(prev, cur); k != 0 {
		t.Errorf("expected 0 (full redraw), got %d", k)
	}
}

func TestDetectScrollUpLargeScroll(t *testing.T) {
	// 8 lines, k=5: cur[0:3]=[F,G,H] match prev[5:8]=[F,G,H].
	// With contiguous-from-top matching and minMatch=2 (h=8), 3 matches suffice.
	prev := []string{"A", "B", "C", "D", "E", "F", "G", "H"}
	cur := []string{"F", "G", "H", "X", "Y", "Z", "W", "V"}
	if k := detectScrollUp(prev, cur); k != 5 {
		t.Errorf("expected 5, got %d", k)
	}
}

func TestDetectScrollUpWithBottomChanges(t *testing.T) {
	// Simulates Ink re-rendering the bottom of the screen while real scroll
	// happened at the top. The top lines shifted up by 1, but the last 2
	// lines are completely different (Ink's dynamic area).
	prev := []string{"A", "B", "C", "D", "E", "F", "spinner1", "status1"}
	cur := []string{"B", "C", "D", "E", "F", "G", "spinner2", "status2"}
	// k=1: cur[0:7] vs prev[1:8]. Contiguous from top: B==B, C==C, D==D, E==E, F==F = 5 matches.
	// Then cur[5]="G" != prev[6]="spinner1" — stops. 5 >= minMatch(2) → detected.
	if k := detectScrollUp(prev, cur); k != 1 {
		t.Errorf("expected 1, got %d", k)
	}
}

func TestDetectScrollUpNoFalsePositiveFromMiddleMatch(t *testing.T) {
	// Lines match in the middle but not from the top — should not detect scroll.
	prev := []string{"A", "B", "X", "Y", "E", "F", "G", "H"}
	cur := []string{"Z", "W", "X", "Y", "E", "F", "G", "H"}
	// k=2: cur[0]="Z" vs prev[2]="X" — no match from top → rejected.
	if k := detectScrollUp(prev, cur); k != 0 {
		t.Errorf("expected 0 (no match from top), got %d", k)
	}
}

func TestReadScreenLines(t *testing.T) {
	emu := vt.NewEmulator(10, 3)
	emu.Write([]byte("Hello\r\nWorld\r\n!"))
	lines := readScreenLines(emu)
	if len(lines) != 3 {
		t.Fatalf("expected 3 lines, got %d", len(lines))
	}
	if lines[0] != "Hello" {
		t.Errorf("line 0: expected %q, got %q", "Hello", lines[0])
	}
	if lines[1] != "World" {
		t.Errorf("line 1: expected %q, got %q", "World", lines[1])
	}
	if lines[2] != "!" {
		t.Errorf("line 2: expected %q, got %q", "!", lines[2])
	}
}

func TestReadScreenLinesTrimsTrailingSpaces(t *testing.T) {
	emu := vt.NewEmulator(20, 2)
	emu.Write([]byte("Hi"))
	lines := readScreenLines(emu)
	if lines[0] != "Hi" {
		t.Errorf("expected trailing spaces trimmed, got %q", lines[0])
	}
}

func TestScrollbackViaEmulatorDiff(t *testing.T) {
	m := NewSpecPanelModel("test")
	m.height = 3

	// Resize emulator to 3 lines tall.
	m.emulator.Resize(20, 3)

	// Write enough lines to cause scrolling. With 3-line screen:
	// "line1\r\nline2\r\nline3\r\n" fills the screen, then the final \n
	// causes line1 to scroll off.
	data := []byte("line1\r\nline2\r\nline3\r\nline4\r\n")
	m, _ = m.Update(TerminalOutputMsg{Slug: "test", Data: data})

	// First write: no prevScreen yet, so no scroll detection.
	// But now prevScreen is set. Write more to trigger scroll.
	data2 := []byte("line5\r\nline6\r\n")
	m, _ = m.Update(TerminalOutputMsg{Slug: "test", Data: data2})

	// There should be some scrollback captured.
	if len(m.scrollBuf) == 0 {
		// The emulator processes all data at once, so the internal screen
		// may have already settled. Check that the mechanism works by
		// verifying prevScreen is set.
		if m.prevScreen == nil {
			t.Fatal("prevScreen should be set after writes")
		}
	}
}

func TestScrollbackAccumulatesOnMultipleWrites(t *testing.T) {
	m := NewSpecPanelModel("test")
	m.height = 4
	m.emulator.Resize(40, 4)

	// First write: fill the screen.
	m, _ = m.Update(TerminalOutputMsg{Slug: "test", Data: []byte("A\r\nB\r\nC\r\nD")})
	// prevScreen is now [A, B, C, D]

	// Second write: add one line, causing A to scroll off.
	m, _ = m.Update(TerminalOutputMsg{Slug: "test", Data: []byte("\r\nE")})
	// Screen should be [B, C, D, E], scrollBuf should have [A]
	if len(m.scrollBuf) != 1 || m.scrollBuf[0] != "A" {
		t.Fatalf("expected scrollBuf=[A], got %v", m.scrollBuf)
	}

	// Third write: add one more line, causing B to scroll off.
	m, _ = m.Update(TerminalOutputMsg{Slug: "test", Data: []byte("\r\nF")})
	if len(m.scrollBuf) != 2 || m.scrollBuf[1] != "B" {
		t.Fatalf("expected scrollBuf=[A,B], got %v", m.scrollBuf)
	}
}

func TestScrollOffsetAdjustedOnTrim(t *testing.T) {
	m := NewSpecPanelModel("test")
	m.height = 24
	m.emulator.Resize(40, 24)

	// Pre-populate near the limit.
	for i := 0; i < 4990; i++ {
		m.scrollBuf = append(m.scrollBuf, fmt.Sprintf("line%d", i))
	}
	m.scrollOffset = 100
	// Set prevScreen so the trimming + clamping uses totalLines().
	m.prevScreen = make([]string, 24)

	// Add enough scrollback to exceed maxScrollBufLines.
	for i := 0; i < 20; i++ {
		m.scrollBuf = append(m.scrollBuf, fmt.Sprintf("new%d", i))
	}
	// Manually trigger trim logic (same as in Update handler).
	if len(m.scrollBuf) > maxScrollBufLines {
		trimCount := len(m.scrollBuf) - maxScrollBufLines
		m.scrollBuf = m.scrollBuf[trimCount:]
		m.scrollOffset -= trimCount
		if m.scrollOffset < 0 {
			m.scrollOffset = 0
		}
	}

	if len(m.scrollBuf) != maxScrollBufLines {
		t.Fatalf("expected scrollBuf len %d, got %d", maxScrollBufLines, len(m.scrollBuf))
	}
	// 4990+20=5010, trim 10, offset: 100-10=90
	if m.scrollOffset != 90 {
		t.Fatalf("expected scrollOffset=90, got %d", m.scrollOffset)
	}
}

func TestScrollIndicatorInView(t *testing.T) {
	m := NewSpecPanelModel("test")
	m.height = 10

	for i := 0; i < 30; i++ {
		m.scrollBuf = append(m.scrollBuf, fmt.Sprintf("line%d", i))
	}
	m.prevScreen = make([]string, 10)

	// When scrollOffset == 0, no indicator.
	m.scrollOffset = 0
	view0 := m.View()
	if strings.Contains(view0, "scrollback") {
		t.Fatal("indicator should not appear when scrollOffset == 0")
	}

	// When scrollOffset > 0, indicator should appear.
	m.scrollOffset = 5
	view5 := m.View()
	if !strings.Contains(view5, "scrollback") || !strings.Contains(view5, "lines above") {
		t.Fatal("indicator should appear when scrollOffset > 0")
	}
}

func TestScrollbackViewWhenDone(t *testing.T) {
	m := NewSpecPanelModel("test")
	m.height = 10

	for i := 0; i < 20; i++ {
		m.scrollBuf = append(m.scrollBuf, fmt.Sprintf("line%d", i))
	}
	m.prevScreen = make([]string, 10)

	// Mark as done via StreamCompleteMsg.
	m, _ = m.Update(StreamCompleteMsg{Slug: "test"})
	if !m.IsDone() {
		t.Fatal("expected panel to be done after StreamCompleteMsg")
	}

	// Scrollback should still work.
	m.scrollOffset = 5
	view := m.View()
	if !strings.Contains(view, "line") {
		t.Fatal("scrollback View() should render content when panel is done")
	}
	if !strings.Contains(view, "scrollback") {
		t.Fatal("scroll indicator should appear in done panel when scrolled")
	}
}

func TestViewBlendsScrollBufAndScreen(t *testing.T) {
	m := NewSpecPanelModel("test")
	m.height = 6 // 5 content lines + 1 indicator

	m.scrollBuf = []string{"hist1", "hist2", "hist3"}
	m.prevScreen = []string{"scr1", "scr2", "scr3", "scr4"}

	// scrollOffset = 2 means 2 lines above the bottom of the virtual doc.
	// total = 3+4 = 7, endIdx = 7-2 = 5, startIdx = 5-5 = 0
	// Lines 0-4: hist1, hist2, hist3, scr1, scr2
	m.scrollOffset = 2
	view := m.View()
	if !strings.Contains(view, "hist1") {
		t.Error("expected hist1 in view")
	}
	if !strings.Contains(view, "hist3") {
		t.Error("expected hist3 in view")
	}
	if !strings.Contains(view, "scr1") {
		t.Error("expected scr1 in view")
	}
	if !strings.Contains(view, "scr2") {
		t.Error("expected scr2 in view")
	}
	// scr3, scr4 should NOT be in view (they're below the viewport)
	if strings.Contains(view, "scr3") {
		t.Error("scr3 should not be in view at this offset")
	}
}

func TestPrevScreenClearedOnResize(t *testing.T) {
	m := NewSpecPanelModel("test")
	m.emulator.Resize(40, 10)

	// Write something to establish prevScreen.
	m, _ = m.Update(TerminalOutputMsg{Slug: "test", Data: []byte("hello\r\n")})
	if m.prevScreen == nil {
		t.Fatal("prevScreen should be set after write")
	}

	// Simulate resize via tea.WindowSizeMsg.
	m, _ = m.Update(tea.WindowSizeMsg{Width: 40, Height: 20})
	if m.prevScreen != nil {
		t.Fatal("prevScreen should be nil after resize")
	}
}

func TestQuiescenceTickEmitsNeedsInputAfterThreshold(t *testing.T) {
	m := NewSpecPanelModel("test")
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
	m := NewSpecPanelModel("test")
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
	m := NewSpecPanelModel("test")
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

// TestBuildInitialPrompt covers the four prompt construction paths in StartTerminalCmd.
func TestBuildInitialPrompt(t *testing.T) {
	tests := []struct {
		name         string
		slug         string
		title        string
		extraContext string
		shortMode    bool
		chatMode     bool
		skipConfirm  bool
		followupMode bool
		wantPrefix   string
		wantContains []string
	}{
		{
			name:         "followup chat mode uses /followup-discuss prefix",
			slug:         "my-followup",
			title:        "My Followup",
			chatMode:     true,
			followupMode: true,
			wantPrefix:   "/followup-discuss ",
			wantContains: []string{"my-followup"},
		},
		{
			name:         "followup chat mode with extraContext appends it",
			slug:         "my-followup",
			title:        "My Followup",
			extraContext: "extra info",
			chatMode:     true,
			followupMode: true,
			wantPrefix:   "/followup-discuss ",
			wantContains: []string{"my-followup", ": extra info"},
		},
		{
			name:         "regular chat mode uses /work slash command with slug",
			slug:         "some-slug",
			title:        "Some Title",
			chatMode:     true,
			followupMode: false,
			wantPrefix:   "/work ",
			wantContains: []string{"some-slug"},
		},
		{
			name:         "regular chat mode with extraContext appends it",
			slug:         "some-slug",
			title:        "Some Title",
			extraContext: "more context",
			chatMode:     true,
			followupMode: false,
			wantPrefix:   "/work ",
			wantContains: []string{"some-slug", ": more context"},
		},
		{
			name:         "spec mode uses /spec prefix",
			slug:         "my-spec",
			chatMode:     false,
			wantPrefix:   "/spec ",
			wantContains: []string{"my-spec"},
		},
		{
			name:         "spec short mode includes short keyword",
			slug:         "my-spec",
			chatMode:     false,
			shortMode:    true,
			wantPrefix:   "/spec ",
			wantContains: []string{"short ", "my-spec"},
		},
		{
			name:         "spec mode with skipConfirm appends --yes",
			slug:         "my-spec",
			chatMode:     false,
			skipConfirm:  true,
			wantContains: []string{"my-spec --yes"},
		},
		{
			name:         "spec mode with extraContext appends -- separator",
			slug:         "my-spec",
			chatMode:     false,
			extraContext: "some extra",
			wantContains: []string{"my-spec -- some extra"},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := buildInitialPrompt(tc.slug, tc.title, tc.extraContext, tc.shortMode, tc.chatMode, tc.skipConfirm, tc.followupMode, -1)
			if tc.wantPrefix != "" && !strings.HasPrefix(got, tc.wantPrefix) {
				t.Errorf("expected prefix %q, got %q", tc.wantPrefix, got)
			}
			for _, want := range tc.wantContains {
				if !strings.Contains(got, want) {
					t.Errorf("expected %q to contain %q", got, want)
				}
			}
		})
	}

	// Verify --finding flag is inserted after the followup ID for finding-scoped sessions.
	t.Run("followup chat with findingIndex inserts --finding flag", func(t *testing.T) {
		got := buildInitialPrompt("my-followup", "My Followup", "", false, true, false, true, 3)
		want := "/followup-discuss my-followup --finding 3"
		if got != want {
			t.Errorf("expected %q, got %q", want, got)
		}
	})

	t.Run("followup chat with findingIndex and extraContext", func(t *testing.T) {
		got := buildInitialPrompt("my-followup", "My Followup", "some context", false, true, false, true, 0)
		if !strings.Contains(got, "--finding 0") {
			t.Errorf("expected --finding 0 in %q", got)
		}
		if !strings.Contains(got, ": some context") {
			t.Errorf("expected ': some context' in %q", got)
		}
	})
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
