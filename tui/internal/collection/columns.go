// Package collection provides the shared building blocks for the TUI's
// list+detail surfaces: a list core with cursor/scroll/filter state and a
// responsive columnar⇄stacked render engine, and a descriptor-driven tab
// host. Components are body-only — View methods return content strings and
// the host wraps them in panel chrome (borders, titles, key hints).
package collection

import "sort"

// Column describes one cell of a columnar list row.
type Column struct {
	// Key is the column's stable identity.
	Key string
	// Title is the header text.
	Title string
	// Width is the column's content width in terminal cells; for Flex
	// columns it is the minimum width.
	Width int
	// Priority orders columns for elision as the panel narrows:
	// priority-0 columns are kept longest, higher values drop sooner.
	// Ties keep input order.
	Priority int
	// Flex marks a column that absorbs spare width left over after
	// selection.
	Flex bool
}

// ColumnSlot is a selected column resolved to a concrete render width.
type ColumnSlot struct {
	Column
	// Index is the column's position in the input slice, which is also
	// the Row.Cells index it consumes.
	Index int
	// RenderWidth is Width plus any flex share.
	RenderWidth int
}

// Every row starts with a two-cell lead (cursor marker / indent) and
// columns are separated by a two-cell gap, matching the work and followup
// tables this engine replaces.
const (
	rowLead   = 2
	columnGap = 2
)

// LayoutMode selects between the columnar table and the stacked two-line
// card layout.
type LayoutMode int

const (
	ModeColumnar LayoutMode = iota
	ModeStacked
)

// DefaultStackedBelow is the panel width below which the list renders the
// stacked layout when the consumer does not set its own threshold. Chosen
// between the 40-cell split-pane left panel (stacked) and full-width
// terminals (columnar).
const DefaultStackedBelow = 60

// ModeFor returns the layout mode for a panel width: stacked below the
// threshold, columnar at or above it.
func ModeFor(width, stackedBelow int) LayoutMode {
	if width < stackedBelow {
		return ModeStacked
	}
	return ModeColumnar
}

// SelectColumns returns the indices, in input order, of the columns that
// fit within width. Columns are admitted by ascending Priority (input
// order breaks ties) and admission stops at the first column that does not
// fit, so the set selected at a narrower width is always a subset of the
// set selected at a wider width.
func SelectColumns(width int, cols []Column) []int {
	order := make([]int, len(cols))
	for i := range order {
		order[i] = i
	}
	sort.SliceStable(order, func(a, b int) bool {
		return cols[order[a]].Priority < cols[order[b]].Priority
	})

	used := 0
	chosen := make([]int, 0, len(cols))
	for _, idx := range order {
		// Total row width if this column is admitted: lead + content +
		// one gap per already-admitted column.
		total := rowLead + used + cols[idx].Width + columnGap*len(chosen)
		if total > width {
			break
		}
		used += cols[idx].Width
		chosen = append(chosen, idx)
	}
	sort.Ints(chosen)
	return chosen
}

// minTotalWidth returns the row width needed to render exactly the chosen
// columns at their declared widths: lead + content + inter-column gaps.
// Zero when no columns are chosen.
func minTotalWidth(cols []Column, chosen []int) int {
	if len(chosen) == 0 {
		return 0
	}
	total := rowLead + columnGap*(len(chosen)-1)
	for _, idx := range chosen {
		total += cols[idx].Width
	}
	return total
}

// FitColumns selects the columns that fit within width and distributes the
// spare width across the selected Flex columns — evenly, remainder to the
// first — returning render slots in input order.
func FitColumns(width int, cols []Column) []ColumnSlot {
	chosen := SelectColumns(width, cols)
	slots := make([]ColumnSlot, len(chosen))
	flexCount := 0
	for i, idx := range chosen {
		slots[i] = ColumnSlot{Column: cols[idx], Index: idx, RenderWidth: cols[idx].Width}
		if cols[idx].Flex {
			flexCount++
		}
	}
	if flexCount == 0 {
		return slots
	}
	spare := width - minTotalWidth(cols, chosen)
	if spare <= 0 {
		return slots
	}
	share, rem := spare/flexCount, spare%flexCount
	for i := range slots {
		if !slots[i].Flex {
			continue
		}
		slots[i].RenderWidth += share + rem
		rem = 0
	}
	return slots
}
