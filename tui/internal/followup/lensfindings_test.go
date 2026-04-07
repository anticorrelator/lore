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
				Severity:    "blocking",
				Title:       "Missing error check",
				File:        "main.go",
				Line:        10,
				Body:        "This function call ignores the error return value.",
				Lens:        "correctness",
				Disposition: "action",
				Rationale:   "Error could cause silent data loss.",
			},
			{
				Severity:    "suggestion",
				Title:       "Consider extracting helper",
				File:        "utils/helper.go",
				Line:        55,
				Body:        "This block could be simplified into a helper function.",
				Lens:        "clarity",
				Disposition: "accepted",
				Rationale:   "",
			},
			{
				Severity:    "question",
				Title:       "Is this intentional?",
				File:        "config.go",
				Line:        0,
				Body:        "The default timeout is very high.",
				Lens:        "security",
				Disposition: "open",
				Rationale:   "Might be intentional for batch processing.",
			},
			{
				Severity:    "suggestion",
				Title:       "Deferred nit",
				File:        "api.go",
				Line:        20,
				Body:        "Minor naming nit.",
				Lens:        "interface-clarity",
				Disposition: "deferred",
				Rationale:   "",
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

func TestLensFindingsViewShowsDispositionIndicators(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	out := m.View()
	if !strings.Contains(out, "[act]") {
		t.Error("View should contain [act] disposition indicator")
	}
	if !strings.Contains(out, "[ok]") {
		t.Error("View should contain [ok] disposition indicator")
	}
	if !strings.Contains(out, "[?]") {
		t.Error("View should contain [?] disposition indicator")
	}
	if !strings.Contains(out, "[def]") {
		t.Error("View should contain [def] disposition indicator")
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

func TestLensFindingsViewShowsRationale(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	out := m.View()
	if !strings.Contains(out, "rationale:") {
		t.Error("View should contain rationale line when non-empty")
	}
	if !strings.Contains(out, "silent data loss") {
		t.Error("View should contain rationale text")
	}
}

func TestLensFindingsViewShowsHeader(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	out := m.View()
	// accepted and deferred are pre-seeded, so 2/4 start selected.
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

func TestLensFindingsEnterOpensActionMenu(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if !m.actionMenuOpen {
		t.Error("enter should open the action menu")
	}
	if m.actionMenu != actionMenuMain {
		t.Errorf("enter should set actionMenu=actionMenuMain, got %v", m.actionMenu)
	}
	// Selection should NOT be toggled.
	if m.findings[0].Selected {
		t.Error("enter should not toggle finding selection")
	}
}

func TestLensFindingsEscClosesActionMenu(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	// Open menu
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if !m.actionMenuOpen {
		t.Fatal("expected menu to be open after enter")
	}

	// Esc should close it
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if m.actionMenuOpen {
		t.Error("esc should close the action menu")
	}
	if m.actionMenu != actionMenuNone {
		t.Errorf("esc should set actionMenu=actionMenuNone, got %v", m.actionMenu)
	}
}

func TestLensFindingsJDismissesMenuAndNavigates(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if !m.actionMenuOpen {
		t.Fatal("expected menu to be open")
	}

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

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if !m.actionMenuOpen {
		t.Fatal("expected menu to be open")
	}

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

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if !m.actionMenuOpen {
		t.Fatal("expected menu to be open")
	}
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

func TestLensFindingsDKeyOpensDispositionSubMenu(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	// Open main menu
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if m.actionMenu != actionMenuMain {
		t.Fatal("expected actionMenuMain after enter")
	}

	// Press d to open disposition sub-menu
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'d'}})
	if m.actionMenu != actionMenuDisposition {
		t.Errorf("d should transition to actionMenuDisposition, got %v", m.actionMenu)
	}
	if !m.actionMenuOpen {
		t.Error("menu should remain open after d")
	}
}

func TestLensFindingsDispositionSubMenuAction(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)
	// cursor is at finding[0] (action disposition, unselected)

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'d'}})
	if m.actionMenu != actionMenuDisposition {
		t.Fatal("expected disposition sub-menu")
	}

	// a → action, selected=false
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'a'}})
	if m.actionMenuOpen {
		t.Error("menu should close after disposition set")
	}
	if m.findings[0].Disposition != "action" {
		t.Errorf("disposition should be 'action', got %q", m.findings[0].Disposition)
	}
	if m.findings[0].Selected {
		t.Error("selected should be false for action disposition")
	}
	if m.review.Findings[0].Disposition != "action" {
		t.Error("review.Findings[0].Disposition should be synced")
	}
	if m.review.Findings[0].Selected {
		t.Error("review.Findings[0].Selected should be synced (false for action)")
	}
}

func TestLensFindingsDispositionSubMenuDeferred(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'d'}})

	// d → deferred, selected=true
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'d'}})
	if m.actionMenuOpen {
		t.Error("menu should close after disposition set")
	}
	if m.findings[0].Disposition != "deferred" {
		t.Errorf("disposition should be 'deferred', got %q", m.findings[0].Disposition)
	}
	if !m.findings[0].Selected {
		t.Error("selected should be true for deferred disposition")
	}
}

func TestLensFindingsDispositionSubMenuAccepted(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'d'}})

	// enter → accepted (ok/confirm), selected=true
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if m.actionMenuOpen {
		t.Error("menu should close after disposition set")
	}
	if m.findings[0].Disposition != "accepted" {
		t.Errorf("enter should set disposition to 'accepted', got %q", m.findings[0].Disposition)
	}
	if !m.findings[0].Selected {
		t.Error("selected should be true for accepted disposition")
	}
}

func TestLensFindingsDispositionSubMenuQuestionMark(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'d'}})

	// ? → open, selected=false
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'?'}})
	if m.actionMenuOpen {
		t.Error("menu should close after disposition set")
	}
	if m.findings[0].Disposition != "open" {
		t.Errorf("? should set disposition to 'open', got %q", m.findings[0].Disposition)
	}
	if m.findings[0].Selected {
		t.Error("selected should be false for open disposition")
	}
}

func TestLensFindingsDispositionSubMenuEscBackToMain(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'d'}})
	if m.actionMenu != actionMenuDisposition {
		t.Fatal("expected disposition sub-menu")
	}

	// esc should go back to main menu, not close entirely
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if m.actionMenu != actionMenuMain {
		t.Errorf("esc from disposition sub-menu should return to main, got %v", m.actionMenu)
	}
	if !m.actionMenuOpen {
		t.Error("menu should still be open after esc from disposition sub-menu")
	}
}

func TestLensFindingsDispositionSubMenuSwallowsUnknownKeys(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)
	origDisp := m.findings[0].Disposition

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'d'}})

	// Unknown key — should be swallowed, menu stays open
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'z'}})
	if !m.actionMenuOpen {
		t.Error("unknown key should be swallowed, menu should remain open")
	}
	if m.findings[0].Disposition != origDisp {
		t.Error("unknown key should not change disposition")
	}
}

func TestLensFindingsViewMainMenuRow(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	// Open action menu
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if !m.actionMenuOpen {
		t.Fatal("expected menu to be open")
	}

	out := m.View()
	if !strings.Contains(out, "(c)hat") {
		t.Error("main menu row should contain '(c)hat'")
	}
	if !strings.Contains(out, "(d)isposition") {
		t.Error("main menu row should contain '(d)isposition'")
	}
	if !strings.Contains(out, "(e)dit") {
		t.Error("main menu row should contain '(e)dit'")
	}
	// Disposition sub-menu labels should NOT appear
	if strings.Contains(out, "(a)ction") {
		t.Error("main menu should not show disposition sub-menu options")
	}
}

func TestLensFindingsViewDispositionMenuRow(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	// Open main menu then disposition sub-menu
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'d'}})
	if m.actionMenu != actionMenuDisposition {
		t.Fatal("expected disposition sub-menu")
	}

	out := m.View()
	if !strings.Contains(out, "(a)ction") {
		t.Error("disposition menu row should contain '(a)ction'")
	}
	if !strings.Contains(out, "(d)efer") {
		t.Error("disposition menu row should contain '(d)efer'")
	}
	if !strings.Contains(out, "(?)open") {
		t.Error("disposition menu row should contain '(?)open'")
	}
	// Main menu labels should NOT appear
	if strings.Contains(out, "(c)hat") {
		t.Error("disposition sub-menu should not show main menu options")
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

	// Open the menu
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
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

	// accepted (idx 1) and deferred (idx 3) are pre-seeded; action (idx 0) and open (idx 2) are not.
	if m.selectedCount() != 2 {
		t.Errorf("initial selectedCount = %d, want 2 (pre-seeded accepted+deferred)", m.selectedCount())
	}

	// Toggle action (idx 0): select it → 3 selected.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{' '}})
	// Move to accepted (idx 1) and toggle: deselect it → back to 2 selected.
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
	// action and open findings start unselected.
	if !strings.Contains(out, "[ ]") {
		t.Error("View should show unchecked checkbox '[ ]' for unselected findings")
	}
	// accepted and deferred are pre-seeded selected.
	if !strings.Contains(out, "[x]") {
		t.Error("View should show '[x]' for pre-seeded accepted/deferred findings")
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
	review.Findings[0].Selected = true
	review.Findings[2].Selected = true
	m := NewLensFindingsModel("", "", review)
	m.SetSize(80, 40)

	out := m.View()
	if !strings.Contains(out, "2/4 selected") {
		t.Errorf("View header should show '2/4 selected', got: %q", out)
	}
}

// --- pre-seeding behavior ---

// TestLensFindingsPreSeedFreshReview verifies that accepted and deferred
// findings start selected, while action and open findings start unselected,
// when no prior user selections exist.
func TestLensFindingsPreSeedFreshReview(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())

	// testLensReview fixture: [0]=action, [1]=accepted, [2]=open, [3]=deferred
	for _, f := range m.findings {
		switch f.Disposition {
		case "accepted", "deferred":
			if !f.Selected {
				t.Errorf("finding with disposition %q should be pre-selected, got Selected=false", f.Disposition)
			}
		case "action", "open":
			if f.Selected {
				t.Errorf("finding with disposition %q should not be pre-selected, got Selected=true", f.Disposition)
			}
		}
	}
}

// TestLensFindingsPreSeedSkippedWhenSelectionsExist verifies that when at
// least one finding is already selected, pre-seeding is skipped and all
// selections are preserved as-is.
func TestLensFindingsPreSeedSkippedWhenSelectionsExist(t *testing.T) {
	review := testLensReview()
	// Pre-set only the action finding (not a disposition that would be pre-seeded).
	review.Findings[0].Selected = true // action

	m := NewLensFindingsModel("", "", review)

	// action finding should remain selected (it was pre-set).
	if !m.findings[0].Selected {
		t.Error("pre-set action finding should remain selected")
	}
	// accepted finding should NOT be pre-seeded (existing selections present).
	if m.findings[1].Selected {
		t.Error("accepted finding should not be auto-selected when existing selections present")
	}
	// deferred finding should NOT be pre-seeded.
	if m.findings[3].Selected {
		t.Error("deferred finding should not be auto-selected when existing selections present")
	}
}

// TestLensFindingsPreSeedFlowsToSelectedLensFindings verifies that pre-seeded
// selections are visible to SelectedLensFindings() without any user interaction,
// confirming the pre-seeding flows through to the promotion payload.
func TestLensFindingsPreSeedFlowsToSelectedLensFindings(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())

	selected := m.SelectedLensFindings()

	// Should contain exactly the accepted and deferred findings.
	if len(selected) != 2 {
		t.Fatalf("SelectedLensFindings() returned %d findings, want 2 (accepted + deferred)", len(selected))
	}
	for _, f := range selected {
		if f.Disposition != "accepted" && f.Disposition != "deferred" {
			t.Errorf("SelectedLensFindings() returned unexpected disposition %q", f.Disposition)
		}
	}
}
