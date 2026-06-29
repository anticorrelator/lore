package collection

import (
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/style"
)

// Cell pairs unstyled text with the style applied when its row is NOT
// selected. Selected rows always render the raw Text and receive one
// row-wide selection style, because lipgloss v2 clears a row background at
// any inner span's SGR reset.
type Cell struct {
	Text  string
	Style lipgloss.Style // zero value renders Text unstyled
}

// Row is one list entry. Cells feed the columnar layout (parallel to the
// list's column slice); Title and Meta feed the stacked two-line layout.
// Header rows (section headers, e.g. project groups) render as a single
// full-width Title line in both modes.
type Row struct {
	// ID is the row's stable identity, used for cursor preservation and
	// the onCursorChange hook. Header rows may leave it empty.
	ID     string
	Cells  []Cell
	Title  Cell
	Meta   []Cell
	Header bool
	// Hidden rows are skipped by navigation and rendering (e.g. members
	// of a collapsed group). Set-level filtering is done by the consumer
	// rebuilding rows.
	Hidden bool
}

// RowDecorator rewrites a row's assembled display lines — already padded
// to the panel width with selection styling applied. Consumers inject
// per-row treatments the core does not know about (badges, animated
// glyphs) without forking the render paths.
type RowDecorator func(row Row, selected bool, lines []string) []string

// Selection styles, hoisted per the allocate-once rule (style.go).
// rowSelected highlights the primary line, rowSelectedDim the stacked
// metadata line.
var (
	rowSelected    = lipgloss.NewStyle().Background(style.ColorSelectionBg).Bold(true)
	rowSelectedDim = lipgloss.NewStyle().Background(style.ColorSelectionBg)
)

// List is the shared list core: cursor, scroll windowing, and row
// visibility over a responsive columnar⇄stacked render engine. Update is
// pure — all effects are returned as tea.Cmd via the OnSelect and
// OnCursorChange hooks.
type List struct {
	rows   []Row
	cursor int
	width  int
	height int

	columns      []Column
	stackedBelow int
	emptyText    string

	decorate       RowDecorator
	onSelect       func(Row) tea.Cmd
	onCursorChange func(id string) tea.Cmd
}

// NewList creates a list rendering the given columns in columnar mode.
func NewList(columns []Column) List {
	return List{
		columns:      columns,
		stackedBelow: DefaultStackedBelow,
		emptyText:    "  No items.",
	}
}

// SetStackedBelow overrides the width threshold for the stacked layout.
func (l *List) SetStackedBelow(w int) { l.stackedBelow = w }

// SetEmptyText sets the message shown when no rows are visible.
func (l *List) SetEmptyText(s string) { l.emptyText = s }

// SetDecorator installs the row-decorator hook.
func (l *List) SetDecorator(d RowDecorator) { l.decorate = d }

// SetOnSelect installs the hook invoked when Enter lands on a row
// (including header rows — consumers branch on Row.Header).
func (l *List) SetOnSelect(fn func(Row) tea.Cmd) { l.onSelect = fn }

// SetOnCursorChange installs the hover hook, invoked with the row ID when
// the cursor lands on a different non-header row (e.g. detail prefetch).
func (l *List) SetOnCursorChange(fn func(id string) tea.Cmd) { l.onCursorChange = fn }

// SetSize sets the panel's inner dimensions.
func (l *List) SetSize(width, height int) {
	l.width = width
	l.height = height
}

// SetRows replaces the row set. The cursor stays on the row with the same
// ID when it is still present and visible; otherwise it resets to the
// first visible non-header row.
func (l *List) SetRows(rows []Row) {
	prevID := l.CurrentID()
	l.rows = rows
	if prevID != "" && l.SetCursorByID(prevID) {
		return
	}
	l.CursorToFirstItem()
}

// Rows returns the full row set, including hidden rows.
func (l List) Rows() []Row { return l.rows }

// Cursor returns the cursor's row index.
func (l List) Cursor() int { return l.cursor }

// CurrentRow returns the row under the cursor and whether one exists.
func (l List) CurrentRow() (Row, bool) {
	if l.cursor < 0 || l.cursor >= len(l.rows) {
		return Row{}, false
	}
	return l.rows[l.cursor], true
}

// CurrentID returns the ID of the row under the cursor, or "" when the
// list is empty or the cursor is on a header.
func (l List) CurrentID() string {
	if r, ok := l.CurrentRow(); ok && !r.Header {
		return r.ID
	}
	return ""
}

// SetCursorByID moves the cursor to the visible row with the given ID,
// reporting whether it was found. The cursor is unchanged on a miss.
func (l *List) SetCursorByID(id string) bool {
	for _, idx := range l.visibleIdxs() {
		if l.rows[idx].ID == id {
			l.cursor = idx
			return true
		}
	}
	return false
}

// CursorToFirstItem moves the cursor to the first visible non-header row,
// falling back to the first visible row, then 0.
func (l *List) CursorToFirstItem() {
	visible := l.visibleIdxs()
	for _, idx := range visible {
		if !l.rows[idx].Header {
			l.cursor = idx
			return
		}
	}
	if len(visible) > 0 {
		l.cursor = visible[0]
		return
	}
	l.cursor = 0
}

// visibleIdxs returns indices of rows not hidden.
func (l List) visibleIdxs() []int {
	idxs := make([]int, 0, len(l.rows))
	for i, r := range l.rows {
		if r.Hidden {
			continue
		}
		idxs = append(idxs, i)
	}
	return idxs
}

// nextVisible returns the next visible row index from current in the given
// direction, clamped at the ends. A current row that is not visible jumps
// to the nearest end.
func nextVisible(current, dir int, visible []int) int {
	if len(visible) == 0 {
		return current
	}
	pos := -1
	for i, idx := range visible {
		if idx == current {
			pos = i
			break
		}
	}
	if pos < 0 {
		if dir > 0 {
			return visible[0]
		}
		return visible[len(visible)-1]
	}
	next := pos + dir
	if next < 0 {
		next = 0
	}
	if next >= len(visible) {
		next = len(visible) - 1
	}
	return visible[next]
}

func (l List) Init() tea.Cmd {
	return nil
}

// Update handles sizing and navigation keys (j/k/up/down, g/G/home/end,
// enter). Consumer-specific keys (filter toggles, actions) belong in the
// consumer's Update before delegating here.
func (l List) Update(msg tea.Msg) (List, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		l.width = msg.Width
		l.height = msg.Height

	case tea.KeyPressMsg:
		visible := l.visibleIdxs()
		prev := l.cursor
		switch msg.String() {
		case "j", "down":
			l.cursor = nextVisible(l.cursor, 1, visible)
		case "k", "up":
			l.cursor = nextVisible(l.cursor, -1, visible)
		case "g", "home":
			if len(visible) > 0 {
				l.cursor = visible[0]
			}
		case "G", "end":
			if len(visible) > 0 {
				l.cursor = visible[len(visible)-1]
			}
		case "enter":
			if r, ok := l.CurrentRow(); ok && l.onSelect != nil {
				return l, l.onSelect(r)
			}
		}
		if l.cursor != prev && l.onCursorChange != nil {
			if r, ok := l.CurrentRow(); ok && !r.Header && r.ID != "" {
				return l, l.onCursorChange(r.ID)
			}
		}
	}
	return l, nil
}

// windowByBudget walks outward from the cursor position, greedily adding
// rows above and below until the rendered line budget is exhausted, and
// returns the half-open [offset, end) window into the visible positions.
// Row heights vary (headers vs stacked items), so the window is computed
// in rendered lines, not row counts. A cursor not in visible anchors the
// window at the top.
func windowByBudget(heights []int, cursorPos, budget int) (int, int) {
	if budget < 1 {
		budget = 1<<31 - 1 // unbounded when height not set
	}
	if cursorPos < 0 || cursorPos >= len(heights) {
		cursorPos = 0
	}

	offset := cursorPos
	end := cursorPos + 1
	used := heights[cursorPos]

	lo, hi := cursorPos-1, cursorPos+1
	for used < budget {
		addedAny := false
		if hi < len(heights) && used+heights[hi] <= budget {
			used += heights[hi]
			end = hi + 1
			hi++
			addedAny = true
		}
		if lo >= 0 && used+heights[lo] <= budget {
			used += heights[lo]
			offset = lo
			lo--
			addedAny = true
		}
		if !addedAny {
			break
		}
	}
	return offset, end
}

// padTo pads s with spaces to w visual columns (no-op when already wider).
func padTo(s string, w int) string {
	if d := w - lipgloss.Width(s); d > 0 {
		return s + strings.Repeat(" ", d)
	}
	return s
}

// View renders the list body: the columnar table at or above the stacked
// threshold, the stacked two-line layout below it. Body only — no chrome.
func (l List) View() string {
	visible := l.visibleIdxs()
	if len(visible) == 0 {
		return style.Dim.Render(l.emptyText) + "\n"
	}
	if ModeFor(l.width, l.stackedBelow) == ModeStacked {
		return l.viewStacked(visible)
	}
	return l.viewColumnar(visible)
}

// cursorPosIn returns the cursor's position within visible, or -1.
func (l List) cursorPosIn(visible []int) int {
	for i, idx := range visible {
		if idx == l.cursor {
			return i
		}
	}
	return -1
}

func (l List) viewColumnar(visible []int) string {
	width := l.width
	if width <= 0 {
		width = 80
	}
	slots := FitColumns(width, l.columns)

	var b strings.Builder

	titles := make([]string, len(slots))
	for i, slot := range slots {
		titles[i] = padTo(style.Truncate(slot.Title, slot.RenderWidth), slot.RenderWidth)
	}
	header := strings.Repeat(" ", rowLead) + strings.Join(titles, strings.Repeat(" ", columnGap))
	b.WriteString(style.SectionTitle.Render(header))
	b.WriteString("\n")

	heights := make([]int, len(visible))
	for i := range heights {
		heights[i] = 1
	}
	offset, end := windowByBudget(heights, l.cursorPosIn(visible), l.height-1)

	for vi := offset; vi < end; vi++ {
		idx := visible[vi]
		row := l.rows[idx]
		selected := idx == l.cursor

		var line string
		if row.Header {
			line = l.renderHeaderLine(row, selected, width)
		} else {
			line = l.renderColumnarRow(row, slots, selected, width)
		}
		lines := []string{line}
		if l.decorate != nil {
			lines = l.decorate(row, selected, lines)
		}
		b.WriteString(strings.Join(lines, "\n"))
		b.WriteString("\n")
	}

	return b.String()
}

// renderColumnarRow assembles one item row. Unselected rows style each
// cell individually; selected rows assemble unstyled cell text and apply
// the selection style once over the padded line.
func (l List) renderColumnarRow(row Row, slots []ColumnSlot, selected bool, width int) string {
	parts := make([]string, len(slots))
	for i, slot := range slots {
		var cell Cell
		if slot.Index < len(row.Cells) {
			cell = row.Cells[slot.Index]
		}
		text := style.Truncate(cell.Text, slot.RenderWidth)
		if selected {
			parts[i] = padTo(text, slot.RenderWidth)
		} else {
			parts[i] = padTo(cell.Style.Render(text), slot.RenderWidth)
		}
	}
	line := padTo(strings.Repeat(" ", rowLead)+strings.Join(parts, strings.Repeat(" ", columnGap)), width)
	if selected {
		return rowSelected.Render(line)
	}
	return line
}

// renderHeaderLine renders a section-header row as one full-width line in
// either layout mode, with a "> " marker when selected.
func (l List) renderHeaderLine(row Row, selected bool, width int) string {
	marker := "  "
	if selected {
		marker = "> "
	}
	line := padTo(marker+style.Truncate(row.Title.Text, max(0, width-rowLead)), width)
	if selected {
		return rowSelected.Render(line)
	}
	return row.Title.Style.Render(line)
}

func (l List) viewStacked(visible []int) string {
	width := l.width
	if width <= 0 {
		width = 40
	}

	var b strings.Builder

	heights := make([]int, len(visible))
	for i, idx := range visible {
		heights[i] = l.stackedRowHeight(l.rows[idx])
	}
	offset, end := windowByBudget(heights, l.cursorPosIn(visible), l.height)

	for vi := offset; vi < end; vi++ {
		idx := visible[vi]
		row := l.rows[idx]
		selected := idx == l.cursor

		var lines []string
		if row.Header {
			lines = []string{l.renderHeaderLine(row, selected, width)}
		} else {
			lines = l.renderStackedRow(row, selected, width)
		}
		if l.decorate != nil {
			lines = l.decorate(row, selected, lines)
		}
		b.WriteString(strings.Join(lines, "\n"))
		b.WriteString("\n")
	}

	return b.String()
}

// stackedRowHeight is 1 for headers and meta-less items, 2 for items with
// a metadata line.
func (l List) stackedRowHeight(row Row) int {
	if row.Header || len(row.Meta) == 0 {
		return 1
	}
	return 2
}

// renderStackedRow assembles the two-line card: a marker+title line and an
// indented metadata line with dim "·" separators. Selected rows assemble
// unstyled text and apply the selection styles once per line.
func (l List) renderStackedRow(row Row, selected bool, width int) []string {
	marker := "  "
	if selected {
		marker = "> "
	}
	title := style.Truncate(row.Title.Text, max(0, width-rowLead))
	line1 := padTo(marker+title, width)
	if selected {
		line1 = rowSelected.Render(line1)
	} else {
		line1 = row.Title.Style.Render(line1)
	}
	if len(row.Meta) == 0 {
		return []string{line1}
	}

	segs := make([]string, len(row.Meta))
	sep := " · "
	if !selected {
		sep = style.Dim.Render(sep)
	}
	for i, cell := range row.Meta {
		if selected {
			segs[i] = cell.Text
		} else {
			segs[i] = cell.Style.Render(cell.Text)
		}
	}
	line2 := padTo("    "+strings.Join(segs, sep), width)
	if selected {
		line2 = rowSelectedDim.Render(line2)
	}
	return []string{line1, line2}
}
