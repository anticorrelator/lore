package board

import (
	"regexp"
	"sort"
	"strings"

	"github.com/mattn/go-runewidth"
)

// RenderedLine is one physical line of a rendered stream. MetadataAt is the
// byte offset where the compact metadata suffix begins, or -1 when the line is
// entirely structural rail/identity/description text.
type RenderedLine struct {
	Text       string
	MetadataAt int
}

// RenderedRow pairs one stream identity with its single physical line.
type RenderedRow struct {
	Arc      string
	StreamID string
	Lines    []RenderedLine
	Overflow bool
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
	rendered := RenderRows(rows, width, 0)
	var lines []string
	for _, row := range rendered {
		for _, line := range row.Lines {
			lines = append(lines, line.Text)
		}
	}
	return lines
}

type preparedRow struct {
	row       Row
	rail      string
	laneCount int
}

const (
	marqueeStartDwellTicks = 15 // 3s at the detail model's 200ms cadence
	marqueeEndDwellTicks   = 10 // 2s at the detail model's 200ms cadence
)

// RenderRows returns identities in exactly the same topological order as the
// formatted lines, so interactive callers never reconstruct renderer order.
// Phase is elapsed 200ms ticks in the current marquee sweep. The renderer
// retains no lane or scroll state.
func RenderRows(rows []Row, width, phase int) []RenderedRow {
	g := buildGraph(rows)
	order := g.topologicalOrder()
	if width <= 0 {
		out := make([]RenderedRow, 0, len(order))
		for _, id := range order {
			row := g.byID[id]
			out = append(out, RenderedRow{
				Arc: row.Arc, StreamID: id,
				Lines: []RenderedLine{{Text: "", MetadataAt: -1}},
			})
		}
		return out
	}
	lanes := []string{}
	freedOnPreviousRow := map[int]bool{}
	placed := map[string]bool{}
	prepared := make([]preparedRow, 0, len(order))

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
		prepared = append(prepared, preparedRow{row: row, rail: rail, laneCount: len(lanes)})
		placed[id] = true

		freedOnPreviousRow = map[int]bool{}
		for _, lane := range append(append([]int{}, incoming...), col) {
			if lanes[lane] == "" {
				freedOnPreviousRow[lane] = true
			}
		}
	}

	maxOverflow := 0
	for _, item := range prepared {
		_, overflow := formatLine(item.rail, item.laneCount, item.row, g, width, 0)
		maxOverflow = max(maxOverflow, overflow)
	}
	progress := marqueeProgress(phase, maxOverflow)
	out := make([]RenderedRow, 0, len(prepared))
	for _, item := range prepared {
		line, overflow := formatLine(item.rail, item.laneCount, item.row, g, width, progress)
		out = append(out, RenderedRow{
			Arc: item.row.Arc, StreamID: item.row.StreamID,
			Lines: []RenderedLine{line}, Overflow: overflow > 0,
		})
	}
	return out
}

func marqueeProgress(phase, maxOverflow int) int {
	if phase < 0 || maxOverflow <= 0 {
		return 0
	}
	cycle := marqueeStartDwellTicks + maxOverflow + marqueeEndDwellTicks
	position := phase % cycle
	if position <= marqueeStartDwellTicks {
		return 0
	}
	return min(position-marqueeStartDwellTicks, maxOverflow)
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

var (
	wikilinkPattern        = regexp.MustCompile(`\[\[[^\]]+\]\]`)
	emptyLinkParensPattern = regexp.MustCompile(`\(\s*(?:,\s*)*\)`)
)

func displayLabel(label string) string {
	label = wikilinkPattern.ReplaceAllString(label, "")
	label = emptyLinkParensPattern.ReplaceAllString(label, "")
	return strings.Join(strings.Fields(label), " ")
}

func formatLine(rail string, laneCount int, row Row, g graph, width, offset int) (RenderedLine, int) {
	gutterWidth := max(2*laneCount-1, 8)
	prefix := " " + runewidth.FillRight(rail, gutterWidth) + "  " +
		runewidth.FillRight(row.StreamID, 5) + " "
	if runewidth.StringWidth(prefix) >= width {
		return RenderedLine{Text: runewidth.Truncate(prefix, max(0, width), ""), MetadataAt: -1}, 0
	}
	prefixWidth := runewidth.StringWidth(prefix)
	suffix := strings.Join(statusWords(row, g), " · ")
	if suffix == "" {
		window := max(0, width-prefixWidth)
		label, overflow := marqueeWindow(displayLabel(row.Label), window, offset)
		return RenderedLine{Text: prefix + label, MetadataAt: -1}, overflow
	}

	remaining := width - prefixWidth
	suffixWidth := runewidth.StringWidth(suffix)
	if remaining <= 3 {
		suffix = runewidth.Truncate(suffix, remaining, "…")
		return RenderedLine{Text: prefix + suffix, MetadataAt: len(prefix)}, 0
	}
	if suffixWidth+3 > remaining {
		suffix = runewidth.Truncate(suffix, max(1, remaining-3), "…")
		suffixWidth = runewidth.StringWidth(suffix)
	}
	labelWidth := max(1, remaining-suffixWidth-2)
	label, overflow := marqueeWindow(displayLabel(row.Label), labelWidth, offset)
	lead := prefix + runewidth.FillRight(label, labelWidth) + "  "
	return RenderedLine{Text: lead + suffix, MetadataAt: len(lead)}, overflow
}

func statusWords(row Row, g graph) []string {
	var words []string
	waits := unresolvedDependencies(row, g.byID)
	switch {
	case row.Status == "done":
		words = append(words, "done")
		switch row.Verdict {
		case "", "—", "-", "full":
		case "partial":
			words = append(words, "partial")
		case "none":
			words = append(words, "nothing landed")
		default:
			words = append(words, row.Verdict)
		}
	case row.Status == "in-flight":
		words = append(words, "running")
	case row.Status == "pending" && len(waits) > 0:
		words = append(words, "waiting on "+strings.Join(waits, ", "))
	case row.Status == "pending":
		words = append(words, "queued")
	case row.Status == "blocked-on-input":
		words = append(words, "needs you")
	case strings.HasPrefix(row.Status, "blocked-on:"):
		ref := strings.TrimSpace(strings.TrimPrefix(row.Status, "blocked-on:"))
		if ref == "" {
			ref = "unknown"
		}
		words = append(words, "waiting on "+ref)
	case row.Status == "dropped":
		words = append(words, "dropped")
	default:
		words = append(words, row.Status)
	}

	switch row.Gate {
	case "", "notify":
	case "hold":
		words = appendUnique(words, "needs you")
	case "flag":
		words = appendUnique(words, "flagged for your review")
	default:
		words = appendUnique(words, row.Gate)
	}
	for _, dependency := range g.dangling[row.StreamID] {
		words = append(words, "⚠ unknown step "+dependency)
	}
	if g.cyclic[row.StreamID] {
		words = append(words, "⟳ cycle")
	}
	if row.Live {
		words = appendUnique(words, "live")
	}
	return words
}

func appendUnique(values []string, value string) []string {
	for _, existing := range values {
		if existing == value {
			return values
		}
	}
	return append(values, value)
}

func marqueeWindow(text string, width, offset int) (string, int) {
	textWidth := runewidth.StringWidth(text)
	if textWidth <= width {
		return text, 0
	}
	if width <= 0 {
		return "", textWidth
	}
	if width == 1 {
		return "…", textWidth
	}
	overflow := textWidth - width + 1
	offset = min(max(0, offset), overflow)
	switch offset {
	case 0:
		return runewidth.Truncate(text, width-1, "") + "…", overflow
	case overflow:
		return "…" + runewidth.TruncateLeft(text, textWidth-(width-1), ""), overflow
	default:
		middle := runewidth.TruncateLeft(text, offset, "")
		middle = runewidth.Truncate(middle, max(0, width-2), "")
		return "…" + middle + "…", overflow
	}
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
