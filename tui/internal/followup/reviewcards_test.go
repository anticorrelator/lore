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

// --- Bulk action tests ---

func TestReviewCardsBulkSelectAllFromPartial(t *testing.T) {
	review := testReview() // starts with comment 0 selected, 1 and 2 not
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	// 'a' with some unselected → select all.
	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'a'}})
	for i, c := range m.comments {
		if !c.Selected {
			t.Errorf("after a (select all): comment %d not selected", i)
		}
	}
	if cmd == nil {
		t.Error("select-all should emit WriteSidecarCmd")
	}
}

func TestReviewCardsBulkDeselectAllWhenAllSelected(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	// Select all first.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'a'}})
	// Confirm all selected.
	if m.SelectedCount() != 3 {
		t.Fatalf("expected all selected after first a, got %d", m.SelectedCount())
	}

	// 'a' again with all selected → deselect all.
	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'a'}})
	if m.SelectedCount() != 0 {
		t.Errorf("after a (deselect all): SelectedCount = %d, want 0", m.SelectedCount())
	}
	if cmd == nil {
		t.Error("deselect-all should emit WriteSidecarCmd")
	}
}

func TestReviewCardsBulkInvert(t *testing.T) {
	review := testReview() // comment 0 selected, 1 and 2 not
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'i'}})

	// After invert: 0 unselected, 1 and 2 selected.
	if m.comments[0].Selected {
		t.Error("after i: comment 0 should be unselected (was selected)")
	}
	if !m.comments[1].Selected {
		t.Error("after i: comment 1 should be selected (was unselected)")
	}
	if !m.comments[2].Selected {
		t.Error("after i: comment 2 should be selected (was unselected)")
	}
	if cmd == nil {
		t.Error("invert should emit WriteSidecarCmd")
	}
}

func TestReviewCardsBulkSCycleHigh(t *testing.T) {
	review := testReview() // comments: high, medium, low
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	// First S press: cycle to 1 = select high/critical.
	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}})
	if m.sevSelectCycle != 1 {
		t.Errorf("sevSelectCycle = %d, want 1", m.sevSelectCycle)
	}
	if !m.comments[0].Selected { // high
		t.Error("high comment should be selected after S cycle 1")
	}
	if m.comments[1].Selected { // medium
		t.Error("medium comment should not be selected after S cycle 1")
	}
	if m.comments[2].Selected { // low
		t.Error("low comment should not be selected after S cycle 1")
	}
	if cmd == nil {
		t.Error("S should emit WriteSidecarCmd")
	}
}

func TestReviewCardsBulkSCycleMedium(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	// Two S presses: cycle to 2 = select medium.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}})
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}})
	if m.sevSelectCycle != 2 {
		t.Errorf("sevSelectCycle = %d, want 2", m.sevSelectCycle)
	}
	if m.comments[0].Selected { // high
		t.Error("high comment should not be selected after S cycle 2")
	}
	if !m.comments[1].Selected { // medium
		t.Error("medium comment should be selected after S cycle 2")
	}
	if m.comments[2].Selected { // low
		t.Error("low comment should not be selected after S cycle 2")
	}
}

func TestReviewCardsBulkSCycleLow(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	// Three S presses: cycle to 3 = select low.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}})
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}})
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}})
	if m.sevSelectCycle != 3 {
		t.Errorf("sevSelectCycle = %d, want 3", m.sevSelectCycle)
	}
	if m.comments[0].Selected { // high
		t.Error("high comment should not be selected after S cycle 3")
	}
	if m.comments[1].Selected { // medium
		t.Error("medium comment should not be selected after S cycle 3")
	}
	if !m.comments[2].Selected { // low
		t.Error("low comment should be selected after S cycle 3")
	}
}

func TestReviewCardsBulkSCycleWrapsToAll(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	// Four S presses: cycle wraps back to 0 = select all.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}})
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}})
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}})
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}})
	if m.sevSelectCycle != 0 {
		t.Errorf("sevSelectCycle after 4 S presses = %d, want 0", m.sevSelectCycle)
	}
	if m.SelectedCount() != 3 {
		t.Errorf("after S cycle 0 (all): SelectedCount = %d, want 3", m.SelectedCount())
	}
}

func TestReviewCardsSevSelectCycleResetsOnDeletion(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	// Advance cycle to 2.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}})
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}})
	if m.sevSelectCycle != 2 {
		t.Fatalf("pre-condition: sevSelectCycle = %d, want 2", m.sevSelectCycle)
	}

	// Delete current comment via double-press D.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'D'}})
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'D'}})

	if m.sevSelectCycle != 0 {
		t.Errorf("sevSelectCycle after deletion = %d, want 0", m.sevSelectCycle)
	}
}

func TestReviewCardsBulkOpNoopOnEmpty(t *testing.T) {
	m := NewReviewCardsModel("", "", nil)

	// All bulk ops on empty model should not panic and return no cmd.
	m, cmdA := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'a'}})
	m, cmdI := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'i'}})
	m, cmdS := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}})

	if cmdA != nil {
		t.Error("'a' on empty model should not emit cmd")
	}
	if cmdI != nil {
		t.Error("'i' on empty model should not emit cmd")
	}
	if cmdS != nil {
		t.Error("'S' on empty model should not emit cmd")
	}
}

func TestReviewCardsBulkWritesThroughToBothArrays(t *testing.T) {
	review := testReview() // comment 0 selected, rest not
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	// Select all — must sync m.comments and m.review.Comments.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'a'}})

	for i := range m.comments {
		if !m.comments[i].Selected {
			t.Errorf("m.comments[%d].Selected not updated after select-all", i)
		}
		if !m.review.Comments[i].Selected {
			t.Errorf("m.review.Comments[%d].Selected not synced after select-all", i)
		}
	}

	// Invert — both arrays must reflect the flip.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'i'}})
	for i := range m.comments {
		if m.comments[i].Selected {
			t.Errorf("m.comments[%d].Selected not inverted", i)
		}
		if m.review.Comments[i].Selected {
			t.Errorf("m.review.Comments[%d].Selected not synced after invert", i)
		}
	}
}

// --- Deletion tests ---

func TestReviewCardsDFirstPressArmsConfirm(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'D'}})
	if !m.deleteConfirm {
		t.Error("first D press should arm deleteConfirm")
	}
	if cmd != nil {
		t.Error("first D press should not emit a cmd (no write yet)")
	}
}

func TestReviewCardsDDoublePressDeletesComment(t *testing.T) {
	review := testReview() // 3 comments
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40
	initialCount := m.TotalCount()

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'D'}})
	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'D'}})

	if m.TotalCount() != initialCount-1 {
		t.Errorf("after D,D: TotalCount = %d, want %d", m.TotalCount(), initialCount-1)
	}
	if m.deleteConfirm {
		t.Error("deleteConfirm should be cleared after confirmed deletion")
	}
	if cmd == nil {
		t.Error("D,D should emit WriteSidecarCmd")
	}
}

func TestReviewCardsDThenOtherKeyCancels(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	// Arm deletion.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'D'}})
	if !m.deleteConfirm {
		t.Fatal("pre-condition: deleteConfirm should be armed")
	}

	// Any other key cancels.
	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	if m.deleteConfirm {
		t.Error("non-D key should cancel deleteConfirm")
	}
	if m.TotalCount() != 3 {
		t.Error("non-D key should not delete the comment")
	}
	if cmd != nil {
		t.Error("cancelled deletion should not emit a cmd")
	}
}

func TestReviewCardsDeletionClampsCursor(t *testing.T) {
	review := testReview() // 3 comments
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40
	// Move cursor to last item.
	m.cursor = 2

	// Delete last item.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'D'}})
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'D'}})

	if m.cursor >= m.TotalCount() {
		t.Errorf("cursor %d should be clamped below TotalCount %d", m.cursor, m.TotalCount())
	}
}

func TestReviewCardsDeletionOnLastCommentWritesEmptySidecar(t *testing.T) {
	// Only one comment — deleting it should leave an empty sidecar.
	review := &ProposedReview{
		PR:      1,
		Owner:   "o",
		Repo:    "r",
		HeadSHA: "sha",
		Comments: []ProposedComment{
			{ID: "c1", Path: "a.go", Line: 1, Body: "Only comment.", Severity: "low"},
		},
	}
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'D'}})
	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'D'}})

	if m.TotalCount() != 0 {
		t.Errorf("TotalCount after deleting last comment = %d, want 0", m.TotalCount())
	}
	// WriteSidecarCmd should still be emitted (D9: write empty sidecar).
	if cmd == nil {
		t.Error("deleting last comment should emit WriteSidecarCmd for empty sidecar")
	}
}

func TestReviewCardsDeletionOnEmptyNoops(t *testing.T) {
	m := NewReviewCardsModel("", "", nil)

	// D on empty model should not panic and should not arm deleteConfirm.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'D'}})
	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'D'}})

	if cmd != nil {
		t.Error("D,D on empty model should not emit cmd")
	}
	_ = m
}

func TestReviewCardsDeletionSyncsReviewComments(t *testing.T) {
	review := testReview() // 3 comments; delete comment at cursor 0
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	// Capture the path of comment 0 before deletion.
	deletedPath := m.comments[0].Path

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'D'}})
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'D'}})

	// Both m.comments and m.review.Comments should be updated.
	if len(m.comments) != 2 {
		t.Fatalf("m.comments length = %d, want 2", len(m.comments))
	}
	if len(m.review.Comments) != 2 {
		t.Fatalf("m.review.Comments length = %d, want 2", len(m.review.Comments))
	}
	// The deleted comment's path should no longer appear.
	for _, c := range m.comments {
		if c.Path == deletedPath {
			t.Errorf("deleted comment path %q still in m.comments", deletedPath)
		}
	}
	for _, c := range m.review.Comments {
		if c.Path == deletedPath {
			t.Errorf("deleted comment path %q still in m.review.Comments", deletedPath)
		}
	}
}

// --- Filtering tests ---

// --- Clipboard tests ---

func TestReviewCardsYCopiesBodyViaInjectedFn(t *testing.T) {
	review := testReview() // cursor starts at 0 (body: "Consider using a constant here.")
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	var copied string
	m.clipboardWriteFn = func(s string) error {
		copied = s
		return nil
	}

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})

	if copied != review.Comments[0].Body {
		t.Errorf("y: copied = %q, want %q", copied, review.Comments[0].Body)
	}
	if m.flashMsg != "Copied to clipboard" {
		t.Errorf("flashMsg = %q, want %q", m.flashMsg, "Copied to clipboard")
	}
}

func TestReviewCardsYCopyFailureSetsFlashMsg(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	m.clipboardWriteFn = func(s string) error {
		return fmt.Errorf("clipboard unavailable")
	}

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})

	if !strings.Contains(m.flashMsg, "Copy failed") {
		t.Errorf("flashMsg on error = %q, want it to contain 'Copy failed'", m.flashMsg)
	}
	if !strings.Contains(m.flashMsg, "clipboard unavailable") {
		t.Errorf("flashMsg on error = %q, should contain error message", m.flashMsg)
	}
}

func TestReviewCardsFlashMsgClearsOnNextKeypress(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	m.clipboardWriteFn = func(s string) error { return nil }

	// y sets flashMsg.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})
	if m.flashMsg == "" {
		t.Fatal("pre-condition: flashMsg should be set after y")
	}

	// Any next keypress clears it.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	if m.flashMsg != "" {
		t.Errorf("flashMsg not cleared on next keypress, got: %q", m.flashMsg)
	}
}

func TestReviewCardsFlashMsgAppearsInView(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	m.clipboardWriteFn = func(s string) error { return nil }

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})
	out := m.View()

	if !strings.Contains(out, "Copied to clipboard") {
		t.Errorf("View should show flash message, got:\n%s", out)
	}
}

func TestReviewCardsYOnEmptyNoops(t *testing.T) {
	m := NewReviewCardsModel("", "", nil)

	var called bool
	m.clipboardWriteFn = func(s string) error {
		called = true
		return nil
	}

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})
	if called {
		t.Error("y on empty model should not call clipboardWriteFn")
	}
}

// testReviewWithSeverities returns a ProposedReview with comments covering high,
// critical, medium, low, and an unknown severity, for filter testing.
func testReviewWithSeverities() *ProposedReview {
	return &ProposedReview{
		PR:      1,
		Owner:   "o",
		Repo:    "r",
		HeadSHA: "sha",
		Comments: []ProposedComment{
			{ID: "h1", Path: "a.go", Line: 1, Body: "High.", Severity: "high"},
			{ID: "c1", Path: "b.go", Line: 2, Body: "Critical.", Severity: "critical"},
			{ID: "m1", Path: "c.go", Line: 3, Body: "Medium.", Severity: "medium"},
			{ID: "l1", Path: "d.go", Line: 4, Body: "Low.", Severity: "low"},
			{ID: "u1", Path: "e.go", Line: 5, Body: "Unknown.", Severity: "info"},
		},
	}
}

func TestReviewCardsFFilterCyclesConstants(t *testing.T) {
	review := testReviewWithSeverities()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	if m.severityFilter != FilterAll {
		t.Fatalf("initial severityFilter = %d, want FilterAll(%d)", m.severityFilter, FilterAll)
	}

	// f → FilterHigh
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'f'}})
	if m.severityFilter != FilterHigh {
		t.Errorf("after 1x f: severityFilter = %d, want FilterHigh(%d)", m.severityFilter, FilterHigh)
	}

	// f → FilterMedium
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'f'}})
	if m.severityFilter != FilterMedium {
		t.Errorf("after 2x f: severityFilter = %d, want FilterMedium(%d)", m.severityFilter, FilterMedium)
	}

	// f → FilterLow
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'f'}})
	if m.severityFilter != FilterLow {
		t.Errorf("after 3x f: severityFilter = %d, want FilterLow(%d)", m.severityFilter, FilterLow)
	}

	// f → FilterAll (wraps)
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'f'}})
	if m.severityFilter != FilterAll {
		t.Errorf("after 4x f: severityFilter = %d, want FilterAll(%d)", m.severityFilter, FilterAll)
	}
}

func TestReviewCardsVisibleCommentsFilterAll(t *testing.T) {
	review := testReviewWithSeverities()
	m := NewReviewCardsModel("", "", review)

	visible := m.visibleComments()
	if len(visible) != 5 {
		t.Errorf("FilterAll: visibleComments len = %d, want 5", len(visible))
	}
	// All indices should be present in order.
	for i, idx := range visible {
		if idx != i {
			t.Errorf("FilterAll: visible[%d] = %d, want %d", i, idx, i)
		}
	}
}

func TestReviewCardsVisibleCommentsFilterHighMatchesHighAndCritical(t *testing.T) {
	review := testReviewWithSeverities() // indices: 0=high, 1=critical, 2=medium, 3=low, 4=info(unknown)
	m := NewReviewCardsModel("", "", review)
	m.severityFilter = FilterHigh

	visible := m.visibleComments()
	// FilterHigh should match high(0), critical(1), and unknown(4, always visible).
	expectedIndices := map[int]bool{0: true, 1: true, 4: true}
	if len(visible) != len(expectedIndices) {
		t.Errorf("FilterHigh: visibleComments len = %d, want %d; got indices %v", len(visible), len(expectedIndices), visible)
	}
	for _, idx := range visible {
		if !expectedIndices[idx] {
			t.Errorf("FilterHigh: unexpected index %d in visible", idx)
		}
	}
}

func TestReviewCardsVisibleCommentsFilterMedium(t *testing.T) {
	review := testReviewWithSeverities()
	m := NewReviewCardsModel("", "", review)
	m.severityFilter = FilterMedium

	visible := m.visibleComments()
	// FilterMedium: medium(2) + unknown(4).
	expectedIndices := map[int]bool{2: true, 4: true}
	if len(visible) != len(expectedIndices) {
		t.Errorf("FilterMedium: visibleComments len = %d, want %d; got %v", len(visible), len(expectedIndices), visible)
	}
	for _, idx := range visible {
		if !expectedIndices[idx] {
			t.Errorf("FilterMedium: unexpected index %d", idx)
		}
	}
}

func TestReviewCardsVisibleCommentsFilterLow(t *testing.T) {
	review := testReviewWithSeverities()
	m := NewReviewCardsModel("", "", review)
	m.severityFilter = FilterLow

	visible := m.visibleComments()
	// FilterLow: low(3) + unknown(4).
	expectedIndices := map[int]bool{3: true, 4: true}
	if len(visible) != len(expectedIndices) {
		t.Errorf("FilterLow: visibleComments len = %d, want %d; got %v", len(visible), len(expectedIndices), visible)
	}
	for _, idx := range visible {
		if !expectedIndices[idx] {
			t.Errorf("FilterLow: unexpected index %d", idx)
		}
	}
}

func TestReviewCardsUnknownSeverityAlwaysVisible(t *testing.T) {
	// A comment with an unrecognized severity should be visible under every filter.
	review := &ProposedReview{
		Comments: []ProposedComment{
			{ID: "u1", Path: "a.go", Line: 1, Body: "Unknown sev.", Severity: "info"},
		},
	}
	m := NewReviewCardsModel("", "", review)

	for _, filter := range []SeverityFilter{FilterAll, FilterHigh, FilterMedium, FilterLow} {
		m.severityFilter = filter
		visible := m.visibleComments()
		if len(visible) != 1 {
			t.Errorf("filter=%d: unknown severity comment should always be visible, got %v", filter, visible)
		}
	}
}

func TestReviewCardsFResetsCursorToZero(t *testing.T) {
	review := testReviewWithSeverities()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40
	m.cursor = 3 // move to some non-zero position

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'f'}})
	if m.cursor != 0 {
		t.Errorf("after f: cursor = %d, want 0", m.cursor)
	}
}

func TestReviewCardsSelectionToggleUsesBackingIndex(t *testing.T) {
	// Filter to high only; cursor 0 points to high(0), cursor 1 points to critical(1) (visible).
	// Actually with testReviewWithSeverities: FilterHigh visible = [0, 1, 4].
	// cursor=1 → backingIdx=1 (critical comment).
	review := testReviewWithSeverities()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40
	m.severityFilter = FilterHigh
	m.cursor = 1 // visible[1] = backing index 1 (critical)

	if m.comments[1].Selected {
		t.Fatal("pre-condition: critical comment should start unselected")
	}

	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{' '}})
	// cursor=1 under FilterHigh → backingIdx=1
	if !m.comments[1].Selected {
		t.Error("toggle via filter: comments[1] (critical) should be selected")
	}
	if cmd == nil {
		t.Error("toggle should emit WriteSidecarCmd")
	}
}

func TestReviewCardsEmptyFilterResultRendersMessage(t *testing.T) {
	// A review with only high comments; FilterLow produces no visible comments.
	review := &ProposedReview{
		Comments: []ProposedComment{
			{ID: "h1", Path: "a.go", Line: 1, Body: "High only.", Severity: "high"},
		},
	}
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40
	m.severityFilter = FilterLow

	out := m.View()
	// With no visible comments under the filter, the view should render an empty/message state.
	// Either the standard "No proposed comments" or a filter-specific message.
	if strings.Contains(out, "High only.") {
		t.Error("filtered-out comment body should not appear in View output")
	}
}

// --- External editor integration tests ---

func TestReviewCardsEEmitsRequestMsgWithCorrectBackingIdx(t *testing.T) {
	t.Setenv("EDITOR", "vim")
	review := testReview() // 3 comments; cursor=0 → backingIdx=0
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40
	m.cursor = 1 // cursor 1 → backingIdx 1 (no filter active)

	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'E'}})
	if cmd == nil {
		t.Fatal("E should emit a command")
	}
	if !m.editing {
		t.Error("editing should be set to true after E press")
	}

	msg := cmd()
	reqMsg, ok := msg.(ExternalEditRequestMsg)
	if !ok {
		t.Fatalf("E cmd returned %T, want ExternalEditRequestMsg", msg)
	}
	if reqMsg.BackingIdx != 1 {
		t.Errorf("BackingIdx = %d, want 1", reqMsg.BackingIdx)
	}
	if reqMsg.Body != review.Comments[1].Body {
		t.Errorf("Body = %q, want %q", reqMsg.Body, review.Comments[1].Body)
	}
}

func TestReviewCardsExternalEditDoneMsgUpdatesBodyAndWritesSidecar(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40
	m.editing = true // simulate editor open

	newBody := "Updated comment body."
	m, cmd := m.Update(ExternalEditDoneMsg{BackingIdx: 0, NewBody: newBody})

	if m.editing {
		t.Error("editing should be false after ExternalEditDoneMsg")
	}
	if m.comments[0].Body != newBody {
		t.Errorf("m.comments[0].Body = %q, want %q", m.comments[0].Body, newBody)
	}
	if m.review.Comments[0].Body != newBody {
		t.Errorf("m.review.Comments[0].Body = %q, want %q", m.review.Comments[0].Body, newBody)
	}
	if cmd == nil {
		t.Error("ExternalEditDoneMsg with changed body should emit WriteSidecarCmd")
	}
}

func TestReviewCardsExternalEditDoneMsgWithErrSetsFlashMsg(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.editing = true

	m, cmd := m.Update(ExternalEditDoneMsg{Err: fmt.Errorf("editor crashed")})

	if m.editing {
		t.Error("editing should be false after ExternalEditDoneMsg with error")
	}
	if !strings.Contains(m.flashMsg, "editor crashed") {
		t.Errorf("flashMsg = %q, want it to contain 'editor crashed'", m.flashMsg)
	}
	if cmd != nil {
		t.Error("ExternalEditDoneMsg with error should not emit WriteSidecarCmd")
	}
}

func TestReviewCardsExternalEditDoneMsgUnchangedBodySkipsWrite(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.editing = true
	originalBody := m.comments[0].Body

	m, cmd := m.Update(ExternalEditDoneMsg{BackingIdx: 0, NewBody: originalBody})

	if cmd != nil {
		t.Error("ExternalEditDoneMsg with unchanged body should not emit WriteSidecarCmd")
	}
}

func TestReviewCardsEDuringEditingIsNoop(t *testing.T) {
	t.Setenv("EDITOR", "vim")
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40
	m.editing = true // already editing

	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'E'}})
	if cmd != nil {
		t.Error("E during editing should be a no-op (no cmd)")
	}
}

func TestReviewCardsEOnEmptyListIsNoop(t *testing.T) {
	t.Setenv("EDITOR", "vim")
	m := NewReviewCardsModel("", "", nil)

	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'E'}})
	if cmd != nil {
		t.Error("E on empty list should be a no-op")
	}
}

func TestReviewCardsEWhenEditorUnsetSetsFlashMsg(t *testing.T) {
	t.Setenv("EDITOR", "")
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'E'}})
	if cmd != nil {
		t.Error("E with EDITOR unset should not emit a cmd")
	}
	if m.flashMsg == "" {
		t.Error("E with EDITOR unset should set flashMsg")
	}
	if m.editing {
		t.Error("editing should not be set when EDITOR is unset")
	}
}
