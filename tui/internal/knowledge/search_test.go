package knowledge

import (
	"regexp"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/style"
)

// lipgloss v2 always emits ANSI from Style.Render (profile degradation
// happens in the program writer), so text assertions strip SGR first and
// color-routing assertions use style getters instead of rendered substrings.
var knowledgeANSIPattern = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func stripANSI(s string) string {
	return knowledgeANSIPattern.ReplaceAllString(s, "")
}

// searchWithResults builds a sized search model holding three ranked results
// with raw scores, cursor on the first.
func searchWithResults(t *testing.T) SearchModel {
	t.Helper()
	m := NewSearchModel()
	m, _ = m.Update(tea.WindowSizeMsg{Width: 100, Height: 40})
	m.lastQuery = "alpha"
	m.results = []KnowledgeSearchResult{
		{Heading: "First Result", Category: "conventions", Score: -3.4, Snippet: "first snippet body"},
		{Heading: "Second Result", Category: "gotchas", Score: -5.1, Snippet: "second snippet body"},
		{Heading: "Third Result", Category: "principles", Score: -7.9},
	}
	m.cursor = 0
	return m
}

func TestSearchCounterShowsPositionAndTotal(t *testing.T) {
	m := searchWithResults(t)
	if view := stripANSI(m.View()); !strings.Contains(view, "1/3") {
		t.Errorf("view should show the 1/3 match counter:\n%s", view)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
	if view := stripANSI(m.View()); !strings.Contains(view, "2/3") {
		t.Errorf("counter should track the highlighted position (2/3):\n%s", view)
	}
}

func TestSearchNoRawScoresSurface(t *testing.T) {
	m := searchWithResults(t)
	view := stripANSI(m.View())
	if rawScore := regexp.MustCompile(`\[-?\d+\.\d+\]`); rawScore.MatchString(view) {
		t.Errorf("raw score numerals must not surface; rank is conveyed by order:\n%s", view)
	}
	for _, s := range []string{"-3.4", "-5.1", "-7.9"} {
		if strings.Contains(view, s) {
			t.Errorf("raw score %s must not surface:\n%s", s, view)
		}
	}
}

func TestSearchKeepsHighlightedResultPreview(t *testing.T) {
	m := searchWithResults(t)
	view := stripANSI(m.View())
	if !strings.Contains(view, "first snippet body") {
		t.Errorf("highlighted result should preview its snippet:\n%s", view)
	}
	if strings.Contains(view, "second snippet body") {
		t.Errorf("non-highlighted results should not preview snippets:\n%s", view)
	}
}

func TestSearchResultRowsKeepHeadingAndCategory(t *testing.T) {
	m := searchWithResults(t)
	view := stripANSI(m.View())
	for _, s := range []string{"First Result", "conventions", "Second Result", "gotchas"} {
		if !strings.Contains(view, s) {
			t.Errorf("view should contain %q:\n%s", s, view)
		}
	}
}

func TestSearchStylesRouteThroughPaletteRoles(t *testing.T) {
	if got := searchTitleStyle.GetForeground(); got != style.ColorAccent {
		t.Errorf("search title foreground = %v, want style.ColorAccent", got)
	}
	if got := searchCategoryStyle.GetForeground(); got != style.ColorCategory {
		t.Errorf("search category foreground = %v, want style.ColorCategory", got)
	}
	if got := searchSelectedStyle.GetBackground(); got != style.ColorSelectionBg {
		t.Errorf("search selection background = %v, want style.ColorSelectionBg", got)
	}
}

// TestSearchPasteReachesInput locks the inputmsg contract (see
// internal/inputmsg): bracketed paste must land in the search textinput.
// The knowledge browser routes all non-key messages to the search panel
// while search is active — this guards that path end to end.
func TestSearchPasteReachesInput(t *testing.T) {
	m := NewSearchModel()
	m, _ = m.Update(tea.PasteMsg{Content: "retrieval protocol"})
	if got := m.input.Value(); got != "retrieval protocol" {
		t.Errorf("input = %q, want pasted text", got)
	}
}
