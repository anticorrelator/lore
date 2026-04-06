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

	// At top (cursor 0), pressing k moves to the general comment card (-1).
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'k'}})
	if m.cursor != -1 {
		t.Errorf("k at top: cursor = %d, want -1 (general card)", m.cursor)
	}
	// Pressing k again on the general card stays at -1.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'k'}})
	if m.cursor != -1 {
		t.Errorf("k at general card: cursor = %d, want -1 (no card above general)", m.cursor)
	}

	// Move to bottom.
	m.cursor = len(m.comments) - 1

	// At bottom, pressing j should stay at last index.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	if m.cursor != len(m.comments)-1 {
		t.Errorf("j at bottom: cursor = %d, want %d", m.cursor, len(m.comments)-1)
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

// --- Inline edit mode tests ---

// enterEditOnComment positions cursor on the first inline comment and presses e.
// cursor starts at 0 (first inline comment) when review is non-nil.
func enterEditOnComment(m ReviewCardsModel) (ReviewCardsModel, tea.Cmd) {
	return m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'e'}})
}

func TestReviewCardsEditModeEntersWithCorrectBody(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	m, _ = enterEditOnComment(m)

	if !m.editing {
		t.Fatal("e should set editing=true")
	}
	if m.editIdx != 0 {
		t.Errorf("editIdx = %d, want 0 (first comment)", m.editIdx)
	}
	if got := m.editInput.Value(); got != review.Comments[0].Body {
		t.Errorf("textarea value = %q, want %q", got, review.Comments[0].Body)
	}
}

func TestReviewCardsEditModeEnterSaves(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	m, _ = enterEditOnComment(m)

	// Simulate typing by setting the textarea value directly.
	m.editInput.SetValue("Updated body text")

	// Press Enter to save.
	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if m.editing {
		t.Error("Enter should clear editing flag")
	}
	if m.comments[0].Body != "Updated body text" {
		t.Errorf("comment body = %q, want %q", m.comments[0].Body, "Updated body text")
	}
	if m.review.Comments[0].Body != "Updated body text" {
		t.Errorf("review.Comments[0].Body = %q, want %q", m.review.Comments[0].Body, "Updated body text")
	}
	if cmd == nil {
		t.Error("Enter should emit WriteSidecarCmd")
	}
}

func TestReviewCardsEditModeEscCancels(t *testing.T) {
	review := testReview()
	originalBody := review.Comments[0].Body
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	m, _ = enterEditOnComment(m)
	m.editInput.SetValue("discarded content")

	// Press Esc to cancel.
	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEsc})

	if m.editing {
		t.Error("Esc should clear editing flag")
	}
	if m.comments[0].Body != originalBody {
		t.Errorf("cancel: body changed to %q, want %q", m.comments[0].Body, originalBody)
	}
	if cmd != nil {
		t.Error("Esc cancel should NOT emit WriteSidecarCmd")
	}
}

func TestReviewCardsEditModeSuppressesNavKeys(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	m, _ = enterEditOnComment(m)
	cursorBefore := m.cursor

	// j/k/g/G should not move cursor while editing.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	if m.cursor != cursorBefore {
		t.Errorf("j during edit: cursor moved to %d, want %d", m.cursor, cursorBefore)
	}
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'k'}})
	if m.cursor != cursorBefore {
		t.Errorf("k during edit: cursor moved to %d, want %d", m.cursor, cursorBefore)
	}
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'g'}})
	if m.cursor != cursorBefore {
		t.Errorf("g during edit: cursor moved to %d, want %d", m.cursor, cursorBefore)
	}
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'G'}})
	if m.cursor != cursorBefore {
		t.Errorf("G during edit: cursor moved to %d, want %d", m.cursor, cursorBefore)
	}
}

func TestReviewCardsEditModeSuppressesSelectionKeys(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	m, _ = enterEditOnComment(m)
	selectedBefore := m.comments[0].Selected

	// space/x should not toggle selection while editing; selection state is unchanged.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeySpace})
	if m.comments[0].Selected != selectedBefore {
		t.Error("space during edit should not toggle selection")
	}

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'x'}})
	if m.comments[0].Selected != selectedBefore {
		t.Error("x during edit should not toggle selection")
	}
}

func TestReviewCardsEditModeAltEnterInsertsNewline(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	m, _ = enterEditOnComment(m)
	m.editInput.SetValue("line1")

	// Alt+Enter should insert a newline (not save).
	// KeyMsg.String() == "alt+enter" for the alt+enter combination.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter, Alt: true})
	// Model should still be editing.
	if !m.editing {
		t.Error("alt+enter should not exit editing")
	}
}

func TestReviewCardsEditEOnEmptyIsNoop(t *testing.T) {
	// Model with no review (nil), no general card.
	m := NewReviewCardsModel("", "", nil)
	m.width = 80
	m.height = 40

	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'e'}})
	if m.editing {
		t.Error("e on nil review model should not enter edit mode")
	}
	if cmd != nil {
		t.Error("e on nil review model should not emit cmd")
	}
}

func TestReviewCardsEditModeViewShowsTextarea(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	m, _ = enterEditOnComment(m)

	out := m.View()
	if !strings.Contains(out, "editing") {
		t.Error("View should show editing indicator when in edit mode")
	}
}

func TestReviewCardsEnterTogglesSelectionWhenNotEditing(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	// cursor starts at 0 (first inline comment).
	selectedBefore := m.comments[0].Selected

	// Enter should toggle selection when not editing.
	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if m.comments[0].Selected == selectedBefore {
		t.Error("Enter should toggle selection when not editing")
	}
	if cmd == nil {
		t.Error("Enter should emit WriteSidecarCmd when toggling selection")
	}
}

// --- General comment card tests ---

func TestReviewCardsGeneralCardRendersAtTop(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	out := m.View()
	if !strings.Contains(out, "General Comment") {
		t.Error("View should contain 'General Comment' label")
	}
}

func TestReviewCardsGeneralCardPlaceholderWhenEmpty(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	out := m.View()
	if !strings.Contains(out, "No general review comment") {
		t.Error("View should show placeholder when ReviewBody is empty")
	}
}

func TestReviewCardsGeneralCardToggleSyncsReviewBodySelected(t *testing.T) {
	review := testReview()
	if review.ReviewBodySelected {
		t.Fatal("ReviewBodySelected should start false")
	}

	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	// Navigate to general card via k (up from cursor 0).
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'k'}})
	if m.cursor != -1 {
		t.Fatalf("k should move to general card (cursor -1), got %d", m.cursor)
	}

	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeySpace})
	if !m.review.ReviewBodySelected {
		t.Error("space on general card should set ReviewBodySelected=true")
	}
	if cmd == nil {
		t.Error("toggling general card should emit WriteSidecarCmd")
	}
}

func TestReviewCardsEditGeneralCardSavesToReviewBody(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	// Navigate to general card via k (up from cursor 0).
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'k'}})
	if m.cursor != -1 {
		t.Fatalf("k should move to general card (cursor -1), got %d", m.cursor)
	}

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'e'}})
	if !m.editing {
		t.Fatal("e on general card should enter edit mode")
	}
	if m.editIdx != -1 {
		t.Errorf("editIdx = %d, want -1 for general card", m.editIdx)
	}

	m.editInput.SetValue("Overall review summary.")
	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if m.editing {
		t.Error("Enter should exit editing")
	}
	if m.review.ReviewBody != "Overall review summary." {
		t.Errorf("review.ReviewBody = %q, want %q", m.review.ReviewBody, "Overall review summary.")
	}
	if cmd == nil {
		t.Error("Enter save on general card should emit WriteSidecarCmd")
	}
}

func TestReviewCardsGeneralCardUnselectedByDefault(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	if m.review.ReviewBodySelected {
		t.Error("general card should be unselected by default")
	}
	out := m.View()
	// The general card's checkbox should be [ ] not [x].
	if !strings.Contains(out, "[ ]") {
		t.Error("general card checkbox should show '[ ]' when unselected")
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

	// Deselect all — both arrays must reflect the flip.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'a'}})
	for i := range m.comments {
		if m.comments[i].Selected {
			t.Errorf("m.comments[%d].Selected not deselected", i)
		}
		if m.review.Comments[i].Selected {
			t.Errorf("m.review.Comments[%d].Selected not synced after deselect-all", i)
		}
	}
}


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

func TestReviewCardsVisibleCommentsReturnsAllIndices(t *testing.T) {
	review := testReviewWithSeverities()
	m := NewReviewCardsModel("", "", review)

	visible := m.visibleComments()
	if len(visible) != 5 {
		t.Errorf("visibleComments len = %d, want 5", len(visible))
	}
	for i, idx := range visible {
		if idx != i {
			t.Errorf("visible[%d] = %d, want %d", i, idx, i)
		}
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
	if !m.externalEditing {
		t.Error("externalEditing should be set to true after E press")
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
	m.externalEditing = true // simulate editor open

	newBody := "Updated comment body."
	m, cmd := m.Update(ExternalEditDoneMsg{BackingIdx: 0, NewBody: newBody})

	if m.externalEditing {
		t.Error("externalEditing should be false after ExternalEditDoneMsg")
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
	m.externalEditing = true

	m, cmd := m.Update(ExternalEditDoneMsg{Err: fmt.Errorf("editor crashed")})

	if m.externalEditing {
		t.Error("externalEditing should be false after ExternalEditDoneMsg with error")
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
	m.externalEditing = true
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
	m.externalEditing = true // already editing externally

	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'E'}})
	if cmd != nil {
		t.Error("E during externalEditing should be a no-op (no cmd)")
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
	if m.externalEditing {
		t.Error("externalEditing should not be set when EDITOR is unset")
	}
}

// --- ReviewEvent cycling tests ---

func TestNewReviewCardsModelNormalizesEmptyReviewEvent(t *testing.T) {
	review := testReview()
	review.ReviewEvent = ""

	m := NewReviewCardsModel("", "", review)

	if m.review.ReviewEvent != "COMMENT" {
		t.Errorf("NewReviewCardsModel should normalize empty ReviewEvent to COMMENT, got %q", m.review.ReviewEvent)
	}
}

func TestReviewCardsNumberKeysSelectEventType(t *testing.T) {
	review := testReview()
	review.ReviewEvent = "COMMENT"
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	// 1 on COMMENT is no-op (already selected)
	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'1'}})
	if m.review.ReviewEvent != "COMMENT" {
		t.Errorf("after 1: ReviewEvent = %q, want COMMENT", m.review.ReviewEvent)
	}
	if cmd != nil {
		t.Error("1 on already-selected COMMENT should not emit cmd")
	}

	// 2 selects APPROVE
	m, cmd = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'2'}})
	if m.review.ReviewEvent != "APPROVE" {
		t.Errorf("after 2: ReviewEvent = %q, want APPROVE", m.review.ReviewEvent)
	}
	if cmd == nil {
		t.Error("2 key should emit WriteSidecarCmd")
	}

	// 3 selects REQUEST_CHANGES
	m, cmd = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'3'}})
	if m.review.ReviewEvent != "REQUEST_CHANGES" {
		t.Errorf("after 3: ReviewEvent = %q, want REQUEST_CHANGES", m.review.ReviewEvent)
	}
	if cmd == nil {
		t.Error("3 key should emit WriteSidecarCmd")
	}

	// 1 switches back to COMMENT
	m, cmd = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'1'}})
	if m.review.ReviewEvent != "COMMENT" {
		t.Errorf("after 1 again: ReviewEvent = %q, want COMMENT", m.review.ReviewEvent)
	}
	if cmd == nil {
		t.Error("1 key should emit WriteSidecarCmd when switching from REQUEST_CHANGES")
	}
}

func TestReviewCardsReviewEventGetterReflectsSelectedValue(t *testing.T) {
	review := testReview()
	review.ReviewEvent = "COMMENT"
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	if m.ReviewEvent() != "COMMENT" {
		t.Errorf("ReviewEvent() = %q, want COMMENT", m.ReviewEvent())
	}

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'2'}})
	if m.ReviewEvent() != "APPROVE" {
		t.Errorf("ReviewEvent() after 2 = %q, want APPROVE", m.ReviewEvent())
	}
}

func TestReviewCardsNumberKeyNoopOnNilReview(t *testing.T) {
	m := NewReviewCardsModel("", "", nil)

	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'2'}})
	if cmd != nil {
		t.Error("2 on nil review should not emit cmd")
	}
	_ = m
}

func TestReviewCardsViewShowsLensAndConfidence(t *testing.T) {
	review := testReview()
	m := NewReviewCardsModel("", "", review)
	m.width = 80
	m.height = 40

	out := m.View()

	// Populated lenses and confidence should appear.
	if !strings.Contains(out, "[correctness]") {
		t.Error("View should contain [correctness] lens for comment c1")
	}
	if !strings.Contains(out, "90%") {
		t.Error("View should contain 90% confidence for comment c1")
	}
	if !strings.Contains(out, "[clarity]") {
		t.Error("View should contain [clarity] lens for comment c2")
	}
	if !strings.Contains(out, "70%") {
		t.Error("View should contain 70% confidence for comment c2")
	}
	if !strings.Contains(out, "[style]") {
		t.Error("View should contain [style] lens for comment c3")
	}

	// Empty/zero fields should be omitted.
	emptyReview := &ProposedReview{
		PR: 1,
		Comments: []ProposedComment{
			{
				ID:         "e1",
				Path:       "empty.go",
				Line:       1,
				Body:       "no lens or confidence",
				Selected:   true,
				Severity:   "low",
				Lenses:     nil,
				Confidence: 0,
			},
		},
	}
	m2 := NewReviewCardsModel("", "", emptyReview)
	m2.width = 80
	m2.height = 40
	out2 := m2.View()

	if strings.Contains(out2, "[]") {
		t.Error("View should not render empty [] for nil lenses")
	}
	if strings.Contains(out2, "0%") {
		t.Error("View should not render 0% for zero confidence")
	}
}
