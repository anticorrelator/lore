package followup

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func testLensReview() *LensReview {
	return &LensReview{
		PR:       42,
		WorkItem: "test-work-item",
		Findings: []LensFinding{
			{
				Severity:  "blocking",
				Title:     "Missing error check",
				File:      "main.go",
				Line:      10,
				Body:      "This function call ignores the error return value.",
				Lens:      "correctness",
				Grounding: "Error could cause silent data loss.",
			},
			{
				Severity: "suggestion",
				Title:    "Consider extracting helper",
				File:     "utils/helper.go",
				Line:     55,
				Body:     "This block could be simplified into a helper function.",
				Lens:     "clarity",
				Selected: true,
			},
			{
				Severity:  "question",
				Title:     "Is this intentional?",
				File:      "config.go",
				Line:      0,
				Body:      "The default timeout is very high.",
				Lens:      "security",
				Grounding: "Might be intentional for batch processing.",
			},
			{
				Severity: "suggestion",
				Title:    "Deferred nit",
				File:     "api.go",
				Line:     20,
				Body:     "Minor naming nit.",
				Lens:     "interface-clarity",
				Selected: true,
			},
		},
	}
}

func TestLensFindingsEmptyState(t *testing.T) {
	review := &LensReview{PR: 1, Findings: []LensFinding{}}
	m := NewLensFindingsModel("", "", review)
	m.SetSize(80, 40)

	out := m.View()
	if !strings.Contains(out, "No lens findings.") {
		t.Errorf("empty state should show 'No lens findings.', got: %q", out)
	}
}

func TestLensFindingsViewShowsFileAndLine(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

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
}

func TestLensFindingsViewOmitsZeroLine(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	out := m.View()
	// config.go has line=0, should render without :0 suffix.
	if strings.Contains(out, "config.go:0") {
		t.Error("View should not show :0 for line=0 findings")
	}
	if !strings.Contains(out, "config.go") {
		t.Error("View should still show config.go file path")
	}
}

func TestLensFindingsViewNoDispositionIndicators(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	out := m.View()
	for _, indicator := range []string{"[act]", "[ok]", "[def]"} {
		if strings.Contains(out, indicator) {
			t.Errorf("View should not contain removed disposition indicator %q", indicator)
		}
	}
}

func TestLensFindingsViewShowsLens(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	out := m.View()
	if !strings.Contains(out, "[correctness]") {
		t.Error("View should contain lens tag [correctness]")
	}
	if !strings.Contains(out, "[clarity]") {
		t.Error("View should contain lens tag [clarity]")
	}
}

func TestLensFindingsViewShowsGrounding(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	out := m.View()
	if !strings.Contains(out, "grounding:") {
		t.Error("View should contain grounding line when non-empty")
	}
	if !strings.Contains(out, "silent data loss") {
		t.Error("View should contain grounding text")
	}
}

func TestLensFindingsViewShowsHeader(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	out := m.View()
	// testLensReview has findings[1] and [3] pre-selected.
	if !strings.Contains(out, "2/4 selected") {
		t.Errorf("View header should show '2/4 selected', got: %q", out)
	}
}

func TestLensFindingsCursorNavigation(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	if m.cursor != 0 {
		t.Fatalf("initial cursor = %d, want 0", m.cursor)
	}

	// j moves down
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	if m.cursor != 1 {
		t.Errorf("after j: cursor = %d, want 1", m.cursor)
	}

	// k moves up
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'k'}})
	if m.cursor != 0 {
		t.Errorf("after k: cursor = %d, want 0", m.cursor)
	}

	// k at top stays at 0
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'k'}})
	if m.cursor != 0 {
		t.Errorf("k at top: cursor = %d, want 0", m.cursor)
	}

	// G goes to end
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'G'}})
	if m.cursor != 3 {
		t.Errorf("after G: cursor = %d, want 3", m.cursor)
	}

	// j at bottom stays at end
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	if m.cursor != 3 {
		t.Errorf("j at bottom: cursor = %d, want 3", m.cursor)
	}

	// g goes to start
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'g'}})
	if m.cursor != 0 {
		t.Errorf("after g: cursor = %d, want 0", m.cursor)
	}
}


func TestLensFindingsWindowSizeMsg(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())

	m, _ = m.Update(tea.WindowSizeMsg{Width: 100, Height: 50})
	if m.width != 100 || m.height != 50 {
		t.Errorf("after WindowSizeMsg: width=%d height=%d, want 100x50", m.width, m.height)
	}
}

func TestLensFindingsSetSize(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(120, 60)
	if m.width != 120 || m.height != 60 {
		t.Errorf("after SetSize: width=%d height=%d, want 120x60", m.width, m.height)
	}
}

func TestLensFindingsSpaceTogglesSelection(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	if m.findings[0].Selected {
		t.Fatal("finding 0 should start unselected")
	}

	// space selects
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{' '}})
	if !m.findings[0].Selected {
		t.Error("finding 0 should be selected after space")
	}
	// review should be synced
	if !m.review.Findings[0].Selected {
		t.Error("review.Findings[0].Selected should sync with toggle")
	}

	// space deselects
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{' '}})
	if m.findings[0].Selected {
		t.Error("finding 0 should be deselected after second space")
	}
}

func TestLensFindingsXTogglesSelection(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'x'}})
	if !m.findings[0].Selected {
		t.Error("x should select finding 0")
	}
}

func TestLensFindingsEnterTogglesSelection(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	// finding[0] starts unselected
	if m.findings[0].Selected {
		t.Fatal("finding 0 should start unselected")
	}

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if !m.findings[0].Selected {
		t.Error("enter should toggle finding 0 to selected")
	}
	if !m.review.Findings[0].Selected {
		t.Error("review.Findings[0].Selected should be synced")
	}
	// Menu should NOT open on enter.
	if m.actionMenuOpen {
		t.Error("enter should not open action menu")
	}

	// Second enter deselects.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if m.findings[0].Selected {
		t.Error("second enter should deselect finding 0")
	}
}

func TestLensFindingsEscClosesActionMenu(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	// Open menu directly
	m.actionMenuOpen = true

	// Esc should close it
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if m.actionMenuOpen {
		t.Error("esc should close the action menu")
	}
}

func TestLensFindingsJDismissesMenuAndNavigates(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	m.actionMenuOpen = true

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	if m.actionMenuOpen {
		t.Error("j should dismiss the action menu")
	}
	if m.cursor != 1 {
		t.Errorf("j should move cursor to 1 after dismissing menu, got %d", m.cursor)
	}
}

func TestLensFindingsKDismissesMenuAtTop(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	m.actionMenuOpen = true

	// k at top: dismisses menu, cursor stays at 0
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'k'}})
	if m.actionMenuOpen {
		t.Error("k should dismiss the action menu")
	}
	if m.cursor != 0 {
		t.Errorf("k at top should keep cursor at 0, got %d", m.cursor)
	}
}

func TestLensFindingsMenuSwallowsOtherKeys(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	m.actionMenuOpen = true
	selBefore := m.findings[0].Selected

	// space should be swallowed (no selection toggle)
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{' '}})
	if !m.actionMenuOpen {
		t.Error("space should be swallowed, menu should remain open")
	}
	if m.findings[0].Selected != selBefore {
		t.Error("space should not toggle selection while menu is open")
	}
}

func TestLensFindingsDKeySwallowedInMenu(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	m.actionMenuOpen = true
	selBefore := m.findings[0].Selected

	// 'd' no longer opens a disposition sub-menu; it is swallowed
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'d'}})
	if !m.actionMenuOpen {
		t.Error("d should be swallowed (menu should remain open)")
	}
	if m.findings[0].Selected != selBefore {
		t.Error("d should not change selection")
	}
}

func TestLensFindingsViewMainMenuRow(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	m.actionMenuOpen = true

	out := m.View()
	if !strings.Contains(out, "(c)hat") {
		t.Error("main menu row should contain '(c)hat'")
	}
	if !strings.Contains(out, "(e)dit") {
		t.Error("main menu row should contain '(e)dit'")
	}
	// Disposition option should NOT appear
	if strings.Contains(out, "(d)isposition") {
		t.Error("main menu should not show '(d)isposition'")
	}
	if strings.Contains(out, "(a)ction") {
		t.Error("main menu should not show disposition sub-menu options")
	}
}

func TestLensFindingsViewNoMenuRowWhenClosed(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	out := m.View()
	if strings.Contains(out, "(c)hat") {
		t.Error("menu row should not appear when menu is closed")
	}
	if strings.Contains(out, "(a)ction") {
		t.Error("menu row should not appear when menu is closed")
	}
}

func TestLensFindingsCardHeightIncludesMenuRow(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	heightClosed := m.cardHeight(0)

	// Open the menu directly
	m.actionMenuOpen = true
	heightOpen := m.cardHeight(0)

	if heightOpen != heightClosed+1 {
		t.Errorf("cardHeight with menu open should be +1, got closed=%d open=%d", heightClosed, heightOpen)
	}

	// Non-cursor card height should be unaffected
	heightNonCursor := m.cardHeight(1)
	heightNonCursorClosed := heightClosed // compare against pre-open baseline for idx 1
	_ = heightNonCursorClosed
	if m.cursor != 0 {
		t.Fatal("cursor should still be 0")
	}
	// idx 1 (non-cursor) should not gain the extra row
	m2 := NewLensFindingsModel("", "", testLensReview())
	m2.SetSize(80, 40)
	heightIdx1Closed := m2.cardHeight(1)
	if heightNonCursor != heightIdx1Closed {
		t.Errorf("non-cursor cardHeight should be unchanged by menu open: closed=%d open=%d", heightIdx1Closed, heightNonCursor)
	}
}

func TestLensFindingsSelectedCount(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	// testLensReview has findings[1] and [3] pre-selected via Selected: true in fixture.
	if m.selectedCount() != 2 {
		t.Errorf("initial selectedCount = %d, want 2", m.selectedCount())
	}

	// Toggle idx 0: select it → 3 selected.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{' '}})
	// Move to idx 1 and toggle: deselect it → back to 2 selected.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{' '}})

	if m.selectedCount() != 2 {
		t.Errorf("selectedCount = %d, want 2", m.selectedCount())
	}
}

func TestLensFindingsBulkSelectAll(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	// a selects all
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'a'}})
	if m.selectedCount() != len(m.findings) {
		t.Errorf("after a: selectedCount = %d, want %d", m.selectedCount(), len(m.findings))
	}
	for i, f := range m.findings {
		if !f.Selected {
			t.Errorf("findings[%d].Selected should be true after select-all", i)
		}
	}
	for i, f := range m.review.Findings {
		if !f.Selected {
			t.Errorf("review.Findings[%d].Selected not synced after select-all", i)
		}
	}
}

func TestLensFindingsBulkDeselectAllWhenAllSelected(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	// First a selects all
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'a'}})
	if m.selectedCount() != len(m.findings) {
		t.Fatalf("expected all selected after first a, got %d", m.selectedCount())
	}

	// Second a deselects all
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'a'}})
	if m.selectedCount() != 0 {
		t.Errorf("after a (deselect all): selectedCount = %d, want 0", m.selectedCount())
	}
}


func TestLensFindingsViewShowsCheckboxes(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	out := m.View()
	// findings[0] and [2] start unselected.
	if !strings.Contains(out, "[ ]") {
		t.Error("View should show unchecked checkbox '[ ]' for unselected findings")
	}
	// findings[1] and [3] start selected per fixture.
	if !strings.Contains(out, "[x]") {
		t.Error("View should show '[x]' for selected findings")
	}
}

func TestLensFindingsViewShowsCheckedAfterSelect(t *testing.T) {
	review := testLensReview()
	review.Findings[0].Selected = true
	m := NewLensFindingsModel("", "", review)
	m.SetSize(80, 40)

	out := m.View()
	if !strings.Contains(out, "[x]") {
		t.Error("View should show '[x]' for selected finding")
	}
	if !strings.Contains(out, "[ ]") {
		t.Error("View should still show '[ ]' for unselected findings")
	}
}

func TestLensFindingsViewSelectionHeaderCount(t *testing.T) {
	review := testLensReview()
	// Clear the pre-selected state from the fixture, then select exactly [0] and [2].
	for i := range review.Findings {
		review.Findings[i].Selected = false
	}
	review.Findings[0].Selected = true
	review.Findings[2].Selected = true
	m := NewLensFindingsModel("", "", review)
	m.SetSize(80, 40)

	out := m.View()
	if !strings.Contains(out, "2/4 selected") {
		t.Errorf("View header should show '2/4 selected', got: %q", out)
	}
}

// TestLensFindingsSelectedLensFindingsReadsFromSidecar verifies that
// SelectedLensFindings returns findings whose Selected field was set in the
// sidecar (no pre-seeding logic).
func TestLensFindingsSelectedLensFindingsReadsFromSidecar(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())

	selected := m.SelectedLensFindings()

	// testLensReview fixture has findings[1] and [3] pre-selected.
	if len(selected) != 2 {
		t.Fatalf("SelectedLensFindings() returned %d findings, want 2", len(selected))
	}
}
