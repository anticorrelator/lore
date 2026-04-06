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
	if !strings.Contains(out, "0/4 selected") {
		t.Errorf("View header should show '0/4 selected', got: %q", out)
	}
	if !strings.Contains(out, "4 visible") {
		t.Errorf("View header should show '4 visible', got: %q", out)
	}
	if !strings.Contains(out, "filter: all") {
		t.Error("View header should show 'filter: all' by default")
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

func TestLensFindingsDispositionFilterCycling(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	if m.filter != DispFilterAll {
		t.Fatalf("initial filter = %d, want DispFilterAll", m.filter)
	}

	// First f: all → action
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'f'}})
	if m.filter != DispFilterAction {
		t.Errorf("after f: filter = %d, want DispFilterAction", m.filter)
	}
	visible := m.visibleFindings()
	if len(visible) != 1 {
		t.Errorf("action filter: %d visible, want 1", len(visible))
	}

	// Second f: action → accepted
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'f'}})
	if m.filter != DispFilterAccepted {
		t.Errorf("after f: filter = %d, want DispFilterAccepted", m.filter)
	}
	visible = m.visibleFindings()
	if len(visible) != 1 {
		t.Errorf("accepted filter: %d visible, want 1", len(visible))
	}

	// Third f: accepted → deferred
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'f'}})
	if m.filter != DispFilterDeferred {
		t.Errorf("after f: filter = %d, want DispFilterDeferred", m.filter)
	}

	// Fourth f: deferred → open
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'f'}})
	if m.filter != DispFilterOpen {
		t.Errorf("after f: filter = %d, want DispFilterOpen", m.filter)
	}

	// Fifth f: open → all
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'f'}})
	if m.filter != DispFilterAll {
		t.Errorf("after f: filter = %d, want DispFilterAll", m.filter)
	}
}

func TestLensFindingsFilterResetssCursor(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	// Move cursor to position 2
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	if m.cursor != 2 {
		t.Fatalf("cursor = %d, want 2", m.cursor)
	}

	// Filter cycling resets cursor to 0
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'f'}})
	if m.cursor != 0 {
		t.Errorf("after filter change: cursor = %d, want 0", m.cursor)
	}
}

func TestLensFindingsFilterHeaderLabel(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	// Filter to action
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'f'}})
	out := m.View()
	if !strings.Contains(out, "filter: action") {
		t.Errorf("View should show 'filter: action', got header in: %q", out)
	}
	if !strings.Contains(out, "1 visible") {
		t.Errorf("View should show '1 visible' for action filter, got: %q", out)
	}
}

func TestLensFindingsFilterNoMatch(t *testing.T) {
	// Create review with only "action" dispositions — filtering to "accepted" should show empty.
	review := &LensReview{
		PR: 1,
		Findings: []LensFinding{
			{Severity: "blocking", File: "a.go", Line: 1, Body: "test", Lens: "correctness", Disposition: "action"},
		},
	}
	m := NewLensFindingsModel("", "", review)
	m.SetSize(80, 40)

	// Cycle to accepted filter
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'f'}}) // action
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'f'}}) // accepted

	out := m.View()
	if !strings.Contains(out, "No findings match filter.") {
		t.Errorf("View should show 'No findings match filter.' when no matches, got: %q", out)
	}
}

func TestLensFindingsUnknownDispositionAlwaysVisible(t *testing.T) {
	review := &LensReview{
		PR: 1,
		Findings: []LensFinding{
			{Severity: "blocking", File: "a.go", Line: 1, Body: "test", Lens: "x", Disposition: "custom-unknown"},
		},
	}
	m := NewLensFindingsModel("", "", review)
	m.SetSize(80, 40)

	// Under any named filter, unknown disposition should still be visible.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'f'}}) // action
	visible := m.visibleFindings()
	if len(visible) != 1 {
		t.Errorf("unknown disposition should be visible under action filter, got %d visible", len(visible))
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

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if !m.findings[0].Selected {
		t.Error("enter should select finding 0")
	}
}

func TestLensFindingsSelectedCount(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	if m.selectedCount() != 0 {
		t.Errorf("initial selectedCount = %d, want 0", m.selectedCount())
	}

	// select finding 0 and 1
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{' '}})
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

func TestLensFindingsInvertSelection(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	// Select finding 0
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{' '}})
	if !m.findings[0].Selected {
		t.Fatal("findings[0] should be selected before invert")
	}

	// i inverts: 0 deselected, rest selected
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'i'}})
	if m.findings[0].Selected {
		t.Error("findings[0] should be deselected after invert")
	}
	if !m.findings[1].Selected {
		t.Error("findings[1] should be selected after invert")
	}
	if !m.findings[2].Selected {
		t.Error("findings[2] should be selected after invert")
	}
	if !m.findings[3].Selected {
		t.Error("findings[3] should be selected after invert")
	}
	// review should be synced
	for i, f := range m.review.Findings {
		if f.Selected != m.findings[i].Selected {
			t.Errorf("review.Findings[%d].Selected not synced after invert", i)
		}
	}
}

func TestLensFindingsSeveritySelectCycleBlocking(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	// S cycle 1: blocking only
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}})
	if !m.findings[0].Selected { // blocking
		t.Error("findings[0] (blocking) should be selected after S cycle 1")
	}
	if m.findings[1].Selected { // suggestion
		t.Error("findings[1] (suggestion) should not be selected after S cycle 1")
	}
	if m.findings[2].Selected { // question
		t.Error("findings[2] (question) should not be selected after S cycle 1")
	}
}

func TestLensFindingsSeveritySelectCycleSuggestion(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	// S cycle 2: suggestion only
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}}) // blocking
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}}) // suggestion
	if m.findings[0].Selected {                                          // blocking
		t.Error("findings[0] (blocking) should not be selected after S cycle 2")
	}
	if !m.findings[1].Selected { // suggestion
		t.Error("findings[1] (suggestion) should be selected after S cycle 2")
	}
	if m.findings[2].Selected { // question
		t.Error("findings[2] (question) should not be selected after S cycle 2")
	}
	if !m.findings[3].Selected { // suggestion
		t.Error("findings[3] (suggestion) should be selected after S cycle 2")
	}
}

func TestLensFindingsSeveritySelectCycleQuestion(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	// S cycle 3: question only
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}}) // blocking
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}}) // suggestion
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}}) // question
	if m.findings[0].Selected {                                          // blocking
		t.Error("findings[0] (blocking) should not be selected after S cycle 3")
	}
	if m.findings[1].Selected { // suggestion
		t.Error("findings[1] (suggestion) should not be selected after S cycle 3")
	}
	if !m.findings[2].Selected { // question
		t.Error("findings[2] (question) should be selected after S cycle 3")
	}
}

func TestLensFindingsSeveritySelectCycleAll(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	// S cycle 4 (wraps to 0): all selected
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}}) // blocking
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}}) // suggestion
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}}) // question
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}}) // all
	if m.selectedCount() != len(m.findings) {
		t.Errorf("after S cycle 0 (all): selectedCount = %d, want %d", m.selectedCount(), len(m.findings))
	}
}

func TestLensFindingsSCycleSyncsReview(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'S'}})
	for i, f := range m.review.Findings {
		if f.Selected != m.findings[i].Selected {
			t.Errorf("review.Findings[%d].Selected not synced after S", i)
		}
	}
}

func TestLensFindingsViewShowsUncheckedByDefault(t *testing.T) {
	m := NewLensFindingsModel("", "", testLensReview())
	m.SetSize(80, 40)

	out := m.View()
	if !strings.Contains(out, "[ ]") {
		t.Error("View should show unchecked checkbox '[ ]' for unselected findings")
	}
	// No findings selected by default, so [x] should not appear.
	if strings.Contains(out, "[x]") {
		t.Error("View should not show '[x]' when no findings are selected")
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
