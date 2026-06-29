package collection

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/style"
)

// stripANSI removes SGR escape sequences; lipgloss v2 styles output even
// without a TTY, so plain-substring assertions must run on stripped text.
func stripANSI(s string) string {
	var b strings.Builder
	inEsc := false
	for _, r := range s {
		if r == 0x1b {
			inEsc = true
			continue
		}
		if inEsc {
			if r == 'm' {
				inEsc = false
			}
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

func press(code rune, text string) tea.KeyPressMsg {
	return tea.KeyPressMsg{Code: code, Text: text}
}

func testColumns() []Column {
	return []Column{
		{Key: "slug", Title: "SLUG", Width: 20, Priority: 0, Flex: true},
		{Key: "status", Title: "STATUS", Width: 10, Priority: 0},
		{Key: "updated", Title: "UPDATED", Width: 8, Priority: 1},
	}
}

func itemRow(id string) Row {
	return Row{
		ID:    id,
		Cells: []Cell{{Text: id}, {Text: "open"}, {Text: "1d ago"}},
		Title: Cell{Text: id},
		Meta:  []Cell{{Text: "open"}, {Text: "1d ago"}},
	}
}

func newTestList(ids ...string) List {
	l := NewList(testColumns())
	rows := make([]Row, len(ids))
	for i, id := range ids {
		rows[i] = itemRow(id)
	}
	l.SetRows(rows)
	l.SetSize(120, 20)
	return l
}

func TestListNavigationSkipsHidden(t *testing.T) {
	l := NewList(testColumns())
	rows := []Row{
		{Header: true, Title: Cell{Text: "group (2)"}},
		itemRow("alpha"),
		itemRow("beta"),
		itemRow("gamma"),
	}
	rows[2].Hidden = true
	l.SetRows(rows)
	l.SetSize(120, 20)

	if l.Cursor() != 1 {
		t.Fatalf("initial cursor = %d, want 1 (first non-header row)", l.Cursor())
	}

	l, _ = l.Update(press('j', "j"))
	if l.Cursor() != 3 {
		t.Errorf("cursor after j = %d, want 3 (hidden row skipped)", l.Cursor())
	}

	l, _ = l.Update(press('k', "k"))
	if l.Cursor() != 1 {
		t.Errorf("cursor after k = %d, want 1 (hidden row skipped)", l.Cursor())
	}

	l, _ = l.Update(press('G', "G"))
	if l.Cursor() != 3 {
		t.Errorf("cursor after G = %d, want 3", l.Cursor())
	}

	l, _ = l.Update(press('g', "g"))
	if l.Cursor() != 0 {
		t.Errorf("cursor after g = %d, want 0 (first visible row)", l.Cursor())
	}
}

func TestListOnCursorChangeEmitsForItemsOnly(t *testing.T) {
	l := NewList(testColumns())
	l.SetRows([]Row{
		itemRow("alpha"),
		{Header: true, Title: Cell{Text: "group"}},
		itemRow("beta"),
	})
	l.SetSize(120, 20)

	var hovered []string
	l.SetOnCursorChange(func(id string) tea.Cmd {
		hovered = append(hovered, id)
		return func() tea.Msg { return id }
	})

	// alpha → header: cursor moves but no hover emission.
	l, cmd := l.Update(press('j', "j"))
	if l.Cursor() != 1 {
		t.Fatalf("cursor = %d, want 1", l.Cursor())
	}
	if cmd != nil || len(hovered) != 0 {
		t.Errorf("hover hook fired on header row: hovered=%v", hovered)
	}

	// header → beta: hover emission with the new row's ID.
	l, cmd = l.Update(press('j', "j"))
	if len(hovered) != 1 || hovered[0] != "beta" {
		t.Fatalf("hovered = %v, want [beta]", hovered)
	}
	if cmd == nil {
		t.Fatal("expected a hover Cmd, got nil")
	}
	if got := cmd(); got != "beta" {
		t.Errorf("hover cmd msg = %v, want beta", got)
	}

	// No movement at the bottom edge → no emission.
	l, cmd = l.Update(press('j', "j"))
	if cmd != nil || len(hovered) != 1 {
		t.Errorf("hover hook fired without cursor movement: hovered=%v", hovered)
	}
}

func TestListEnterInvokesOnSelect(t *testing.T) {
	l := newTestList("alpha", "beta")

	var selected []string
	l.SetOnSelect(func(r Row) tea.Cmd {
		selected = append(selected, r.ID)
		return func() tea.Msg { return r.ID }
	})

	l, cmd := l.Update(press('j', "j"))
	_ = cmd
	l, cmd = l.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if len(selected) != 1 || selected[0] != "beta" {
		t.Fatalf("selected = %v, want [beta]", selected)
	}
	if cmd == nil || cmd() != "beta" {
		t.Error("expected select Cmd carrying beta")
	}
}

func TestListSetRowsPreservesCursorByID(t *testing.T) {
	l := newTestList("alpha", "beta", "gamma")
	l, _ = l.Update(press('j', "j"))
	if l.CurrentID() != "beta" {
		t.Fatalf("CurrentID = %q, want beta", l.CurrentID())
	}

	// Reload with a row inserted before beta: cursor follows the ID.
	l.SetRows([]Row{itemRow("alpha"), itemRow("new"), itemRow("beta"), itemRow("gamma")})
	if l.CurrentID() != "beta" {
		t.Errorf("CurrentID after reload = %q, want beta", l.CurrentID())
	}

	// Reload without beta: cursor resets to the first non-header row.
	l.SetRows([]Row{{Header: true, Title: Cell{Text: "g"}}, itemRow("alpha"), itemRow("gamma")})
	if l.CurrentID() != "alpha" {
		t.Errorf("CurrentID after removal = %q, want alpha", l.CurrentID())
	}
}

func TestListColumnarRendersColumnTitles(t *testing.T) {
	l := newTestList("alpha", "beta")
	l.SetSize(120, 20)

	view := stripANSI(l.View())
	for _, title := range []string{"SLUG", "STATUS", "UPDATED"} {
		if !strings.Contains(view, title) {
			t.Errorf("columnar view at width 120 missing column title %q:\n%s", title, view)
		}
	}
	if !strings.Contains(view, "alpha") {
		t.Errorf("columnar view missing row content:\n%s", view)
	}
}

func TestListNarrowWidthRendersStacked(t *testing.T) {
	l := newTestList("alpha", "beta")
	l.SetSize(40, 20)

	view := stripANSI(l.View())
	if strings.Contains(view, "SLUG") {
		t.Errorf("stacked view at width 40 should not render column headers:\n%s", view)
	}
	if !strings.Contains(view, "> alpha") {
		t.Errorf("stacked view missing selected title line:\n%s", view)
	}
	if !strings.Contains(view, "open · 1d ago") {
		t.Errorf("stacked view missing metadata line:\n%s", view)
	}
}

func TestListColumnDropsAtIntermediateWidth(t *testing.T) {
	l := newTestList("alpha")
	// Width 36: slug(20)+status(10) fit (need 34); updated (priority 1,
	// needs 44) drops. Still columnar (>= DefaultStackedBelow is false)…
	// so use a threshold below the test width.
	l.SetStackedBelow(30)
	l.SetSize(36, 20)

	view := stripANSI(l.View())
	if !strings.Contains(view, "SLUG") || !strings.Contains(view, "STATUS") {
		t.Errorf("width 36 should keep priority-0 columns:\n%s", view)
	}
	if strings.Contains(view, "UPDATED") {
		t.Errorf("width 36 should drop the priority-1 column:\n%s", view)
	}
}

// TestListSelectedRowContentUnstyled is the in-lipgloss-v2 selection
// contract: the selected row is assembled from unstyled cell text (one
// row-wide style applied after assembly), while unselected rows carry
// per-cell styles. An inner SGR reset inside a background-styled row would
// clear the selection background mid-row.
func TestListSelectedRowContentUnstyled(t *testing.T) {
	l := NewList(testColumns())
	styled := lipgloss.NewStyle().Foreground(style.ColorSuccess)
	mkRow := func(id, status string) Row {
		return Row{
			ID:    id,
			Cells: []Cell{{Text: id}, {Text: status, Style: styled}, {Text: "1d ago", Style: style.Dim}},
		}
	}
	l.SetRows([]Row{mkRow("alpha", "open"), mkRow("gamma", "done")})
	l.SetSize(120, 20)

	view := l.View()
	var selectedLine, unselectedLine string
	for _, line := range strings.Split(view, "\n") {
		if strings.Contains(line, "alpha") {
			selectedLine = line
		}
		if strings.Contains(line, "gamma") {
			unselectedLine = line
		}
	}
	if selectedLine == "" || unselectedLine == "" {
		t.Fatalf("could not locate rendered rows in view:\n%s", view)
	}

	// Selected row: no escape sequences between its cells.
	i := strings.Index(selectedLine, "alpha")
	j := strings.Index(selectedLine, "open")
	if i < 0 || j < i {
		t.Fatalf("selected row cells out of order: %q", selectedLine)
	}
	if strings.Contains(selectedLine[i:j], "\x1b") {
		t.Errorf("selected row carries styled cell content (SGR between cells): %q", selectedLine)
	}

	// Unselected row: the status cell keeps its own style.
	i = strings.Index(unselectedLine, "gamma")
	j = strings.Index(unselectedLine, "done")
	if i < 0 || j < i {
		t.Fatalf("unselected row cells out of order: %q", unselectedLine)
	}
	if !strings.Contains(unselectedLine[i:j], "\x1b") {
		t.Errorf("unselected row lost its per-cell styling: %q", unselectedLine)
	}
}

func TestListWindowKeepsCursorVisible(t *testing.T) {
	ids := make([]string, 30)
	for i := range ids {
		ids[i] = "item-" + string(rune('a'+i%26)) + string(rune('0'+i/26))
	}
	l := newTestList(ids...)
	l.SetSize(120, 6) // 1 header line + 5 rows

	l, _ = l.Update(tea.KeyPressMsg{Code: tea.KeyEnd})
	view := stripANSI(l.View())
	if !strings.Contains(view, ids[len(ids)-1]) {
		t.Errorf("view after End does not include the last row:\n%s", view)
	}
	if strings.Contains(view, ids[0]+" ") {
		t.Errorf("view after End still shows the first row:\n%s", view)
	}
}

func TestListEmptyText(t *testing.T) {
	l := NewList(testColumns())
	l.SetEmptyText("  No follow-ups.  (ctrl+a to switch)")
	l.SetSize(120, 20)
	view := stripANSI(l.View())
	if !strings.Contains(view, "No follow-ups.") {
		t.Errorf("empty view missing empty text:\n%s", view)
	}
}

func TestListDecoratorRewritesLines(t *testing.T) {
	l := newTestList("alpha", "beta")
	l.SetDecorator(func(row Row, selected bool, lines []string) []string {
		if row.ID == "beta" {
			lines[0] = "DECORATED " + lines[0]
		}
		return lines
	})
	view := stripANSI(l.View())
	if !strings.Contains(view, "DECORATED") {
		t.Errorf("decorator output missing from view:\n%s", view)
	}
}
