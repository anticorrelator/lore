package board

import (
	"sort"
	"strings"

	"github.com/mattn/go-runewidth"
)

const labelColumnWidth = 38

// RenderedRow pairs one formatted line with the stream identity used to place it.
type RenderedRow struct {
	Arc      string
	StreamID string
	Line     string
}

type graph struct {
	ids       []string
	byID      map[string]Row
	deps      map[string][]string
	children  map[string][]string
	dangling  map[string][]string
	cyclic    map[string]bool
	declIndex map[string]int
}

// Render draws rows as deterministic DAG rails constrained to width display
// cells. It is a pure projection: repeated calls with the same inputs return
// the same lines and retain no lane state.
func Render(rows []Row, width int) []string {
	rendered := RenderRows(rows, width)
	lines := make([]string, len(rendered))
	for i, row := range rendered {
		lines[i] = row.Line
	}
	return lines
}

// RenderRows returns identities in exactly the same topological order as the
// formatted lines, so interactive callers never reconstruct renderer order.
func RenderRows(rows []Row, width int) []RenderedRow {
	g := buildGraph(rows)
	order := g.topologicalOrder()
	if width <= 0 {
		out := make([]RenderedRow, 0, len(order))
		for _, id := range order {
			row := g.byID[id]
			out = append(out, RenderedRow{Arc: row.Arc, StreamID: id})
		}
		return out
	}
	lanes := []string{}
	freedOnPreviousRow := map[int]bool{}
	placed := map[string]bool{}
	out := make([]RenderedRow, 0, len(order))

	for _, id := range order {
		row := g.byID[id]
		incoming := laneIndexes(lanes, id)
		col := -1
		if len(incoming) > 0 {
			col = incoming[0]
		} else {
			excluded := map[int]bool(nil)
			if len(g.deps[id]) == 0 {
				excluded = freedOnPreviousRow
			}
			col = claimLane(&lanes, excluded)
		}

		for _, lane := range incoming {
			lanes[lane] = ""
		}

		spawned := []int{}
		firstChild := true
		for _, child := range g.children[id] {
			if placed[child] {
				continue
			}
			if firstChild && lanes[col] == "" {
				lanes[col] = child
				firstChild = false
				continue
			}
			firstChild = false
			lane := claimLane(&lanes, nil)
			lanes[lane] = child
			spawned = append(spawned, lane)
		}

		rail := drawRail(lanes, col, incoming, spawned, statusGlyph(row.Status))
		out = append(out, RenderedRow{
			Arc: row.Arc, StreamID: id,
			Line: formatLine(rail, len(lanes), row, g, width),
		})
		placed[id] = true

		freedOnPreviousRow = map[int]bool{}
		for _, lane := range append(append([]int{}, incoming...), col) {
			if lanes[lane] == "" {
				freedOnPreviousRow[lane] = true
			}
		}
	}
	return out
}

func uniqueRows(rows []Row) []Row {
	seen := make(map[string]bool, len(rows))
	unique := make([]Row, 0, len(rows))
	for _, row := range rows {
		if seen[row.StreamID] {
			continue
		}
		seen[row.StreamID] = true
		unique = append(unique, row)
	}
	return unique
}

func buildGraph(rows []Row) graph {
	rows = uniqueRows(rows)
	g := graph{
		byID:      make(map[string]Row, len(rows)),
		deps:      make(map[string][]string, len(rows)),
		children:  make(map[string][]string, len(rows)),
		dangling:  make(map[string][]string),
		cyclic:    make(map[string]bool),
		declIndex: make(map[string]int, len(rows)),
	}
	for _, row := range rows {
		g.declIndex[row.StreamID] = len(g.ids)
		g.ids = append(g.ids, row.StreamID)
		g.byID[row.StreamID] = row
	}
	for _, id := range g.ids {
		for _, dependency := range g.byID[id].DependsOn {
			if _, ok := g.byID[dependency]; !ok {
				g.dangling[id] = append(g.dangling[id], dependency)
				continue
			}
			g.deps[id] = append(g.deps[id], dependency)
		}
	}
	g.breakCycles()
	for _, id := range g.ids {
		for _, dependency := range g.deps[id] {
			g.children[dependency] = append(g.children[dependency], id)
		}
	}
	return g
}

// breakCycles drops each declaration-order DFS back edge. The stack slice from
// its target through its source is the cycle membership advertised by the row
// badges; all other dependency edges remain intact for the Kahn ordering.
func (g *graph) breakCycles() {
	state := make(map[string]uint8, len(g.ids))
	stack := make([]string, 0, len(g.ids))
	var visit func(string)
	visit = func(id string) {
		state[id] = 1
		stack = append(stack, id)
		kept := make([]string, 0, len(g.deps[id]))
		for _, dependency := range g.deps[id] {
			switch state[dependency] {
			case 0:
				visit(dependency)
				kept = append(kept, dependency)
			case 1:
				for i := len(stack) - 1; i >= 0; i-- {
					g.cyclic[stack[i]] = true
					if stack[i] == dependency {
						break
					}
				}
				// This is the deterministic break: do not retain the back edge.
			case 2:
				kept = append(kept, dependency)
			}
		}
		g.deps[id] = kept
		stack = stack[:len(stack)-1]
		state[id] = 2
	}
	for _, id := range g.ids {
		if state[id] == 0 {
			visit(id)
		}
	}
}

func (g graph) topologicalOrder() []string {
	indegree := make(map[string]int, len(g.ids))
	for _, id := range g.ids {
		indegree[id] = len(g.deps[id])
	}
	ready := make([]string, 0, len(g.ids))
	for _, id := range g.ids {
		if indegree[id] == 0 {
			ready = append(ready, id)
		}
	}
	order := make([]string, 0, len(g.ids))
	for len(ready) > 0 {
		id := ready[0]
		ready = ready[1:]
		order = append(order, id)
		for _, child := range g.children[id] {
			indegree[child]--
			if indegree[child] == 0 {
				ready = append(ready, child)
				sort.SliceStable(ready, func(i, j int) bool {
					return g.declIndex[ready[i]] < g.declIndex[ready[j]]
				})
			}
		}
	}
	return order
}

func laneIndexes(lanes []string, target string) []int {
	var indexes []int
	for i, lane := range lanes {
		if lane == target {
			indexes = append(indexes, i)
		}
	}
	return indexes
}

func claimLane(lanes *[]string, excluded map[int]bool) int {
	for i, target := range *lanes {
		if target == "" && !excluded[i] {
			return i
		}
	}
	*lanes = append(*lanes, "")
	return len(*lanes) - 1
}

func statusGlyph(status string) string {
	switch status {
	case "done":
		return "✓"
	case "in-flight":
		return "●"
	case "pending":
		return "○"
	case "blocked-on-input":
		return "▲"
	case "dropped":
		return "✕"
	default:
		if strings.HasPrefix(status, "blocked-on:") {
			return "◈"
		}
		return "?"
	}
}

func statusText(status string) string {
	return status
}

func drawRail(lanes []string, col int, incoming, spawned []int, glyph string) string {
	touched := map[int]bool{col: true}
	for _, lane := range incoming {
		touched[lane] = true
	}
	for _, lane := range spawned {
		touched[lane] = true
	}
	lo, hi := col, col
	for lane := range touched {
		if lane < lo {
			lo = lane
		}
		if lane > hi {
			hi = lane
		}
	}
	incomingSet := indexSet(incoming)
	spawnedSet := indexSet(spawned)
	cells := make([]string, len(lanes))
	for i := range lanes {
		switch {
		case i == col:
			cells[i] = glyph
		case incomingSet[i] && i > col:
			cells[i] = "╯"
		case incomingSet[i]:
			cells[i] = "╰"
		case spawnedSet[i] && i > col:
			cells[i] = "╮"
		case spawnedSet[i]:
			cells[i] = "╭"
		case lo < i && i < hi && lanes[i] != "":
			cells[i] = "┿"
		case lo < i && i < hi:
			cells[i] = "─"
		case lanes[i] != "":
			cells[i] = "│"
		default:
			cells[i] = " "
		}
	}
	var line strings.Builder
	for i, cell := range cells {
		line.WriteString(cell)
		if i+1 < len(cells) {
			if lo <= i && i < hi {
				line.WriteString("─")
			} else {
				line.WriteByte(' ')
			}
		}
	}
	return line.String()
}

func indexSet(indexes []int) map[int]bool {
	set := make(map[int]bool, len(indexes))
	for _, index := range indexes {
		set[index] = true
	}
	return set
}

func formatLine(rail string, laneCount int, row Row, g graph, width int) string {
	gutterWidth := max(2*laneCount-1, 8)
	prefix := " " + runewidth.FillRight(rail, gutterWidth) + "  " +
		runewidth.FillRight(row.StreamID, 5) + " "

	suffix := "  " + statusText(row.Status)
	if row.Tree == "read-only" {
		suffix += " ·ro"
	}
	if row.Gate != "" {
		suffix += " gate:" + row.Gate
	}
	if row.Verdict != "" {
		suffix += " verdict:" + row.Verdict
	}
	if waits := unresolvedDependencies(row, g.byID); len(waits) > 0 {
		suffix += "  waits: " + strings.Join(waits, ", ")
	}
	for _, dependency := range g.dangling[row.StreamID] {
		suffix += "  ⚠ dep?" + dependency
	}
	if g.cyclic[row.StreamID] {
		suffix += "  ⟳ cycle"
	}

	labelWidth := min(labelColumnWidth, max(0, width-runewidth.StringWidth(prefix)-runewidth.StringWidth(suffix)))
	label := runewidth.FillRight(runewidth.Truncate(row.Label, labelWidth, ""), labelWidth)
	return runewidth.Truncate(prefix+label+suffix, width, "")
}

func unresolvedDependencies(row Row, byID map[string]Row) []string {
	var unresolved []string
	for _, dependency := range row.DependsOn {
		predecessor, ok := byID[dependency]
		if ok && predecessor.Status != "done" {
			unresolved = append(unresolved, dependency)
		}
	}
	return unresolved
}
