package followup

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func testReview() *ProposedReview {
	return &ProposedReview{
		PR:      42,
		Owner:   "anticorrelator",
		Repo:    "lore",
		HeadSHA: "abc123",
		Comments: []ProposedComment{
			{
				ID:         "c1",
				Path:       "main.go",
				Line:       10,
				Body:       "Consider using a constant here.",
				Selected:   true,
				Severity:   "high",
				Lenses:     []string{"correctness"},
				Confidence: 0.9,
			},
			{
				ID:         "c2",
				Path:       "utils/helper.go",
				Line:       55,
				Body:       "This could be simplified.\nSecond line of body.",
				Selected:   false,
				Severity:   "medium",
				Lenses:     []string{"clarity"},
				Confidence: 0.7,
			},
			{
				ID:         "c3",
				Path:       "config.go",
				Line:       3,
				Body:       "Minor style nit.",
				Selected:   false,
				Severity:   "low",
				Lenses:     []string{"style"},
				Confidence: 0.5,
			},
		},
	}
}

func TestReviewCardsViewShowsPathAndLine(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	out := m.View()

	if !strings.Contains(out, "main.go") {
		t.Error("View should contain file path main.go")
	}
	if !strings.Contains(out, ":10") {
		t.Error("View should contain line number :10")
	}
	if !strings.Contains(out, "utils/helper.go") {
		t.Error("View should contain file path utils/helper.go")
	}
	if !strings.Contains(out, ":55") {
		t.Error("View should contain line number :55")
	}
}

func TestReviewCardsViewShowsBodyPreview(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	out := m.View()

	if !strings.Contains(out, "Consider using a constant here.") {
		t.Error("View should contain body for first comment")
	}
	// Multi-line body should show all lines (word-wrapped).
	if !strings.Contains(out, "This could be simplified.") {
		t.Error("View should contain first line of multi-line body")
	}
	if !strings.Contains(out, "Second line of body.") {
		t.Error("View should contain second line of multi-line body (word-wrapped)")
	}
}

func TestReviewCardsViewShowsSelectionGlyph(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	out := m.View()

	// First comment is selected → [x], others → [ ]
	if !strings.Contains(out, "[x]") {
		t.Error("View should contain [x] for selected comment")
	}
	if !strings.Contains(out, "[ ]") {
		t.Error("View should contain [ ] for unselected comment")
	}
}

func TestReviewCardsViewShowsSelectionCount(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	out := m.View()

	if !strings.Contains(out, "1/3 selected") {
		t.Errorf("View should show '1/3 selected', got:\n%s", out)
	}
}

func TestReviewCardsViewShowsSeverity(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	out := m.View()

	if !strings.Contains(out, "high") {
		t.Error("View should contain severity 'high'")
	}
	if !strings.Contains(out, "medium") {
		t.Error("View should contain severity 'medium'")
	}
	if !strings.Contains(out, "low") {
		t.Error("View should contain severity 'low'")
	}
}

func TestReviewCardsViewEmptyState(t *testing.T) {
	m := NewReviewCardsModel("", "", nil)
	out := m.View()

	if !strings.Contains(out, "No proposed comments") {
		t.Errorf("Empty state should show 'No proposed comments', got: %q", out)
	}
}

func TestReviewCardsViewWindowSizeMsgUpdatesLayout(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)

	// Send a window size message.
	updated, _ := m.Update(tea.WindowSizeMsg{Width: 60, Height: 20})

	if updated.width != 60 {
		t.Errorf("width = %d, want 60", updated.width)
	}
	if updated.height != 20 {
		t.Errorf("height = %d, want 20", updated.height)
	}

	// View should still render correctly at the new size.
	out := updated.View()
	if !strings.Contains(out, "main.go") {
		t.Error("View at new size should still contain file paths")
	}
}

func TestReviewCardsViewNarrowWidthWrapsBody(t *testing.T) {
	review := &ProposedReview{
		Comments: []ProposedComment{
			{
				ID:       "c1",
				Path:     "f.go",
				Line:     1,
				Body:     "This is a very long comment body that should be wrapped when the terminal width is narrow enough to require it.",
				Severity: "low",
			},
		},
	}
	m := NewReviewCardsModel("", "", review)
	m.width = 30
	m.height = 30

	out := m.View()

	// The full body text should appear across multiple wrapped lines.
	if !strings.Contains(out, "long") {
		t.Errorf("Narrow width should still show body text (word-wrapped), got:\n%s", out)
	}
	if !strings.Contains(out, "require it.") {
		t.Errorf("Wrapped body should contain all text, got:\n%s", out)
	}
}

// --- Navigation tests ---

func TestReviewCardsCursorDownJ(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	if m.cursor != 0 {
		t.Fatalf("initial cursor = %d, want 0", m.cursor)
	}

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	if m.cursor != 1 {
		t.Errorf("after j: cursor = %d, want 1", m.cursor)
	}

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	if m.cursor != 2 {
		t.Errorf("after j j: cursor = %d, want 2", m.cursor)
	}
}

func TestReviewCardsCursorUpK(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	// Move to last item first.
	m.cursor = 2

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'k'}})
	if m.cursor != 1 {
		t.Errorf("after k: cursor = %d, want 1", m.cursor)
	}

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'k'}})
	if m.cursor != 0 {
		t.Errorf("after k k: cursor = %d, want 0", m.cursor)
	}
}

func TestReviewCardsCursorClampsAtBoundaries(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	// At top, pressing k should stay at 0.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'k'}})
	if m.cursor != 0 {
		t.Errorf("k at top: cursor = %d, want 0", m.cursor)
	}

	// Move to bottom.
	m.cursor = len(m.comments) - 1

	// At bottom, pressing j should stay at last index.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	if m.cursor != len(m.comments)-1 {
		t.Errorf("j at bottom: cursor = %d, want %d", m.cursor, len(m.comments)-1)
	}
}

func TestReviewCardsCursorHomeEnd(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40
	m.cursor = 1

	// g goes to first.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'g'}})
	if m.cursor != 0 {
		t.Errorf("after g: cursor = %d, want 0", m.cursor)
	}

	// G goes to last.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'G'}})
	if m.cursor != 2 {
		t.Errorf("after G: cursor = %d, want 2", m.cursor)
	}
}

// --- Selection toggle tests ---

func TestReviewCardsToggleSelection(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	// First comment starts selected.
	if !m.comments[0].Selected {
		t.Fatal("comment 0 should start selected")
	}

	// Toggle with space — should deselect.
	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{' '}})
	if m.comments[0].Selected {
		t.Error("comment 0 should be deselected after space")
	}
	if cmd == nil {
		t.Error("toggle should emit a WriteSidecarCmd")
	}

	// Toggle again — should re-select.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{' '}})
	if !m.comments[0].Selected {
		t.Error("comment 0 should be selected after second space")
	}
}

func TestReviewCardsToggleXKey(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	// Second comment starts unselected.
	m.cursor = 1
	if m.comments[1].Selected {
		t.Fatal("comment 1 should start unselected")
	}

	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'x'}})
	if !m.comments[1].Selected {
		t.Error("comment 1 should be selected after x")
	}
	if cmd == nil {
		t.Error("toggle should emit a WriteSidecarCmd")
	}
}

func TestReviewCardsToggleSyncsReview(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	// Toggle comment 0 (starts selected → deselect).
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{' '}})

	// The review struct should also be updated.
	if m.review.Comments[0].Selected {
		t.Error("review.Comments[0].Selected should sync with toggle")
	}
}

func TestReviewCardsEmptyNoToggle(t *testing.T) {
	m := NewReviewCardsModel("", "", nil)

	// Toggle on empty model should not panic.
	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{' '}})
	if cmd != nil {
		t.Error("toggle on empty model should not emit a command")
	}
}

func TestReviewCardsSelectedCount(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)

	if m.SelectedCount() != 1 {
		t.Errorf("initial SelectedCount = %d, want 1", m.SelectedCount())
	}
	if m.TotalCount() != 3 {
		t.Errorf("TotalCount = %d, want 3", m.TotalCount())
	}

	// Select second comment.
	m.cursor = 1
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{' '}})
	if m.SelectedCount() != 2 {
		t.Errorf("after toggle: SelectedCount = %d, want 2", m.SelectedCount())
	}
}

func TestReviewCardsViewBudgetWindowingLimitsCards(t *testing.T) {
	// Create many comments but a very small height budget.
	var comments []ProposedComment
	for i := 0; i < 20; i++ {
		comments = append(comments, ProposedComment{
			ID:       "c" + string(rune('a'+i)),
			Path:     "file.go",
			Line:     i + 1,
			Body:     "Comment body",
			Severity: "low",
		})
	}
	review := &ProposedReview{Comments: comments}
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 9 // header (2 lines) + budget for ~3 cards (6 lines) = 8

	out := m.View()

	// Count how many "file.go:" occurrences appear — should be less than 20.
	count := strings.Count(out, "file.go:")
	if count >= 20 {
		t.Errorf("Budget windowing should limit visible cards, but all %d are shown", count)
	}
	if count == 0 {
		t.Error("At least one card should be visible")
	}
}

// --- WriteSidecarCmd tests ---

func TestWriteSidecarCmdRoundTrip(t *testing.T) {
	knowledgeDir := t.TempDir()
	followupID := "sidecar-roundtrip"
	itemDir := filepath.Join(knowledgeDir, "_followups", followupID)
	os.MkdirAll(itemDir, 0755)

	review := &ProposedReview{
		PR:      42,
		Owner:   "anticorrelator",
		Repo:    "lore",
		HeadSHA: "abc123",
		Comments: []ProposedComment{
			{ID: "c1", Path: "main.go", Line: 10, Body: "Fix this.", Selected: true, Severity: "high"},
			{ID: "c2", Path: "util.go", Line: 20, Body: "Simplify.", Selected: false, Severity: "low"},
		},
	}

	m := NewReviewCardsModel(knowledgeDir, followupID, review)
	m.width = 80
	m.height = 40

	// Toggle comment 1 (c2): false → true.
	m.cursor = 1
	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{' '}})
	if !m.comments[1].Selected {
		t.Fatal("comment 1 should be selected after toggle")
	}
	if cmd == nil {
		t.Fatal("toggle should return a WriteSidecarCmd")
	}

	// Execute the cmd to write the sidecar.
	msg := cmd()
	writeMsg, ok := msg.(WriteSidecarMsg)
	if !ok {
		t.Fatalf("cmd() returned %T, want WriteSidecarMsg", msg)
	}
	if writeMsg.Err != nil {
		t.Fatalf("WriteSidecarMsg.Err = %v", writeMsg.Err)
	}

	// Re-read the sidecar and verify the selected field flipped.
	sidecarPath := filepath.Join(itemDir, "proposed-comments.json")
	data, err := os.ReadFile(sidecarPath)
	if err != nil {
		t.Fatalf("reading sidecar: %v", err)
	}

	var reloaded ProposedReview
	if err := json.Unmarshal(data, &reloaded); err != nil {
		t.Fatalf("unmarshaling sidecar: %v", err)
	}

	if len(reloaded.Comments) != 2 {
		t.Fatalf("reloaded comments count = %d, want 2", len(reloaded.Comments))
	}
	if !reloaded.Comments[0].Selected {
		t.Error("reloaded comment 0 should still be selected")
	}
	if !reloaded.Comments[1].Selected {
		t.Error("reloaded comment 1 should now be selected (was toggled)")
	}
	if reloaded.PR != 42 {
		t.Errorf("PR metadata should be preserved, got %d", reloaded.PR)
	}
	if reloaded.HeadSHA != "abc123" {
		t.Errorf("HeadSHA should be preserved, got %q", reloaded.HeadSHA)
	}
}

func TestWriteSidecarCmdWriteFailure(t *testing.T) {
	// Use a non-existent path to trigger a write error.
	knowledgeDir := filepath.Join(t.TempDir(), "nonexistent", "deeply", "nested")
	followupID := "fail-write"

	review := &ProposedReview{
		Comments: []ProposedComment{
			{ID: "c1", Path: "a.go", Line: 1, Body: "Body.", Severity: "low"},
		},
	}

	cmd := WriteSidecarCmd(knowledgeDir, followupID, review)
	msg := cmd()
	writeMsg, ok := msg.(WriteSidecarMsg)
	if !ok {
		t.Fatalf("cmd() returned %T, want WriteSidecarMsg", msg)
	}
	if writeMsg.Err == nil {
		t.Fatal("expected error for write to nonexistent directory")
	}
}

func TestWriteSidecarMsgErrorAppearsInView(t *testing.T) {
	review := &ProposedReview{
		Comments: []ProposedComment{
			{ID: "c1", Path: "a.go", Line: 1, Body: "Body.", Severity: "low"},
		},
	}
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	// Simulate receiving a WriteSidecarMsg with an error.
	m, _ = m.Update(WriteSidecarMsg{Err: fmt.Errorf("disk full")})

	out := m.View()
	if !strings.Contains(out, "Write error") {
		t.Error("View should show write error indicator")
	}
	if !strings.Contains(out, "disk full") {
		t.Errorf("View should contain error message, got:\n%s", out)
	}
}
