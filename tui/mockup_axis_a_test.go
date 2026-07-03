package main

// Axis A mockups: work-list legibility & workstream grouping candidates.
//
// Three competing variants, each rendered at the canonical 170×46 geometry
// in the top-bottom design center (list body = 9 lines: 1 column header +
// 8 rows):
//
//   rollup   — grouped sections kept, headers become composed objects:
//              workstream name left, dim readiness/recency rollup right.
//              Collapsed groups read as one-line workstream dashboards.
//              Captures: cand-worklist-rollup.ans (expanded),
//              cand-worklist-rollup-collapsed.ans (two groups folded).
//   rail     — no header rows at all: flat recency-sorted list with a
//              WORKSTREAM column, so all 8 viewport rows are items.
//              Capture: cand-worklist-rail.ans.
//   switcher — a one-line workstream selector strip above the table; "all"
//              shows the flat railed list, focusing a workstream filters
//              the list to it and drops the redundant column.
//              Captures: cand-worklist-switcher-all.ans,
//              cand-worklist-switcher-focus.ans.
//
// Candidate list bodies are built directly on the collection engine
// (columns, rows, RowDecorator — never a forked render path) and composed
// into the real app frame by overriding paneConfig.listView before
// viewTopBottom. Run:
//
//	LORE_MOCKUP_DUMP=1 go test -run 'TestMockupDumpAxisA' -v

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/collection"
	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/gh"
	"github.com/anticorrelator/lore/tui/internal/style"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// Axis A styles, hoisted per the allocate-once rule (style.go).
var (
	axisAGroupHeader     = lipgloss.NewStyle().Foreground(style.ColorAccent).Bold(true)
	axisAUngroupedHeader = lipgloss.NewStyle().Foreground(style.ColorDim).Bold(true)
	axisAStream          = lipgloss.NewStyle().Foreground(style.ColorCategory)
	axisAMerged          = lipgloss.NewStyle().Foreground(style.ColorMerged)
	axisAStripActive     = lipgloss.NewStyle().Foreground(style.ColorTextBright).Bold(true)
	axisAStripInactive   = lipgloss.NewStyle().Foreground(style.ColorChrome)
)

// axisAWorkItems is a denser fixture than the base set: 11 active items
// across three workstreams plus an ungrouped tail, recency-sorted like
// LoadIndex output, so the 8-row viewport visibly overflows.
func axisAWorkItems() []work.WorkItem {
	return []work.WorkItem{
		{
			Slug: "settlement-verdict-drill-in", Title: "Settlement verdict drill-in",
			Status: "active", Project: "settlement-trust",
			PR:         "https://github.com/example/repo/pull/148",
			Updated:    mockupTimeAgo(36 * time.Hour),
			HasPlanDoc: true, HasTasks: true,
		},
		{
			Slug: "worklist-workstream-grouping", Title: "Work list workstream grouping",
			Status: "active", Project: "tui-rework",
			Issue:      "205",
			Updated:    mockupTimeAgo(36 * time.Hour),
			HasPlanDoc: true, HasTasks: true,
		},
		{
			Slug: "auditor-cost-tier-toggle", Title: "Auditor cost tier toggle",
			Status: "active", Project: "settlement-trust",
			Updated:    mockupTimeAgo(60 * time.Hour),
			HasPlanDoc: true,
		},
		{
			Slug: "detail-pane-human-digest", Title: "Detail pane human digest",
			Status: "active", Project: "tui-rework",
			Updated: mockupTimeAgo(60 * time.Hour),
		},
		{
			Slug: "project-entity-records", Title: "Project entity-on-demand records",
			Status: "active", Project: "grouping",
			PR:         "https://github.com/example/repo/pull/152",
			Updated:    mockupTimeAgo(60 * time.Hour),
			HasPlanDoc: true, HasTasks: true,
		},
		{
			Slug: "capture-parity-harness", Title: "Capture parity harness",
			Status:     "active",
			Updated:    mockupTimeAgo(84 * time.Hour),
			HasPlanDoc: true, HasTasks: true,
		},
		{
			Slug: "claim-lease-expiry-sweep", Title: "Claim lease expiry sweep",
			Status: "active", Project: "settlement-trust",
			Updated: mockupTimeAgo(108 * time.Hour),
		},
		{
			Slug: "terminal-mode-key-routing", Title: "Terminal mode key routing",
			Status: "active", Project: "tui-rework",
			Updated:    mockupTimeAgo(108 * time.Hour),
			HasPlanDoc: true,
		},
		{
			Slug: "ungrouped-tail-header", Title: "Ungrouped tail header distinction",
			Status: "active", Project: "grouping",
			Updated:    mockupTimeAgo(132 * time.Hour),
			HasPlanDoc: true, HasTasks: true,
		},
		{
			Slug: "drift-sweep-batching", Title: "Drift sweep batching",
			Status:  "active",
			Updated: mockupTimeAgo(252 * time.Hour),
		},
		{
			Slug: "snippet-normalize-v2", Title: "Snippet normalize v2 recipe",
			Status:     "active",
			Updated:    mockupTimeAgo(300 * time.Hour),
			HasPlanDoc: true,
		},
	}
}

// axisADetail is the detail document for the item under the cursor in every
// axis A capture, so the bottom pane stays consistent across variants.
func axisADetail() *work.WorkItemDetail {
	plan := `# Settlement verdict drill-in

## Intent

Verdicts render as capped one-line summaries; sometimes the operator needs
the full verdict body to sense what the audit pipeline is doing.

## Narrative

Enter on a verdict row opens the full verdict document in the detail region,
replacing the 4-line cap with a scrollable view.
`
	return &work.WorkItemDetail{
		Slug:        "settlement-verdict-drill-in",
		Title:       "Settlement verdict drill-in",
		Status:      "active",
		Project:     "settlement-trust",
		PR:          "https://github.com/example/repo/pull/148",
		Created:     mockupTimeAgo(156 * time.Hour),
		Updated:     mockupTimeAgo(36 * time.Hour),
		PlanContent: &plan,
		HasTasks:    true,
	}
}

func axisAPRStatuses() map[string]gh.PRStatus {
	return map[string]gh.PRStatus{
		"https://github.com/example/repo/pull/148": {Number: 148, State: "OPEN", ReviewDecision: "APPROVED"},
		"https://github.com/example/repo/pull/152": {Number: 152, State: "MERGED"},
	}
}

// axisAReadiness mirrors the production readiness ramp for fixture rows.
func axisAReadiness(it work.WorkItem) collection.Cell {
	switch {
	case it.HasTasks:
		return collection.Cell{Text: "ready", Style: style.StatusReady}
	case it.HasPlanDoc:
		return collection.Cell{Text: "needs tasks", Style: style.StatusWarn}
	default:
		return collection.Cell{Text: "needs spec", Style: style.StatusDisabled}
	}
}

// axisAPRCell maps the fixture's two PR states to badge cells.
func axisAPRCell(it work.WorkItem) collection.Cell {
	switch it.PR {
	case "https://github.com/example/repo/pull/148":
		return collection.Cell{Text: "#148 ✓", Style: style.StatusReady}
	case "https://github.com/example/repo/pull/152":
		return collection.Cell{Text: "#152 ●", Style: axisAMerged}
	default:
		return collection.Cell{Text: "--", Style: style.Dim}
	}
}

func axisAIssueCell(it work.WorkItem) collection.Cell {
	if it.Issue == "" {
		return collection.Cell{Text: "--", Style: style.Dim}
	}
	return collection.Cell{Text: "#" + it.Issue, Style: style.Dim}
}

// axisABaseCells builds the incumbent column cells (dot, slug, readiness,
// issue, pr, updated) for one item.
func axisABaseCells(it work.WorkItem) []collection.Cell {
	return []collection.Cell{
		{Text: " "},
		{Text: it.Slug},
		axisAReadiness(it),
		axisAIssueCell(it),
		axisAPRCell(it),
		{Text: work.FormatRelativeTime(it.Updated)},
	}
}

// axisAColumns is the incumbent work-table column set.
func axisAColumns() []collection.Column {
	return []collection.Column{
		{Key: "dot", Title: " ", Width: 1, Priority: 1},
		{Key: "slug", Title: "SLUG", Width: 20, Priority: 0, Flex: true},
		{Key: "readiness", Title: "READINESS", Width: 12, Priority: 2},
		{Key: "issue", Title: "ISSUE", Width: 8, Priority: 4},
		{Key: "pr", Title: "PR", Width: 10, Priority: 5},
		{Key: "updated", Title: "UPDATED", Width: 12, Priority: 3},
	}
}

// axisARailColumns adds the WORKSTREAM column after the slug.
func axisARailColumns() []collection.Column {
	return []collection.Column{
		{Key: "dot", Title: " ", Width: 1, Priority: 1},
		{Key: "slug", Title: "SLUG", Width: 20, Priority: 0, Flex: true},
		{Key: "stream", Title: "WORKSTREAM", Width: 18, Priority: 2},
		{Key: "readiness", Title: "READINESS", Width: 12, Priority: 3},
		{Key: "issue", Title: "ISSUE", Width: 8, Priority: 5},
		{Key: "pr", Title: "PR", Width: 10, Priority: 6},
		{Key: "updated", Title: "UPDATED", Width: 12, Priority: 4},
	}
}

func axisARailCells(it work.WorkItem) []collection.Cell {
	stream := collection.Cell{Text: "—", Style: style.Dim}
	if it.Project != "" {
		stream = collection.Cell{Text: it.Project, Style: axisAStream}
	}
	return []collection.Cell{
		{Text: " "},
		{Text: it.Slug},
		stream,
		axisAReadiness(it),
		axisAIssueCell(it),
		axisAPRCell(it),
		{Text: work.FormatRelativeTime(it.Updated)},
	}
}

// axisARollup summarizes one group for its header's right-aligned segment:
// readiness distribution plus the freshest member's recency.
func axisARollup(items []work.WorkItem) string {
	var ready, tasks, spec int
	freshest := ""
	for _, it := range items {
		switch {
		case it.HasTasks:
			ready++
		case it.HasPlanDoc:
			tasks++
		default:
			spec++
		}
		if freshest == "" || it.Updated > freshest {
			freshest = it.Updated
		}
	}
	var parts []string
	if ready > 0 {
		parts = append(parts, fmt.Sprintf("%d ready", ready))
	}
	if tasks > 0 {
		parts = append(parts, fmt.Sprintf("%d needs tasks", tasks))
	}
	if spec > 0 {
		parts = append(parts, fmt.Sprintf("%d needs spec", spec))
	}
	parts = append(parts, work.FormatRelativeTime(freshest))
	return strings.Join(parts, " · ")
}

// axisARollupDecorator right-aligns each header's dim rollup segment. Only
// unselected headers are rewritten: selected rows keep the engine's single
// row-wide background over unstyled content, and item rows pass through
// untouched. The rebuilt line stays exactly panel-width.
func axisARollupDecorator(width int, rollups map[string]string) collection.RowDecorator {
	return func(row collection.Row, selected bool, lines []string) []string {
		if !row.Header || selected || len(lines) == 0 {
			return lines
		}
		rollup := rollups[row.ID]
		if rollup == "" {
			return lines
		}
		name := row.Title.Text
		pad := width - 2 - lipgloss.Width(name) - lipgloss.Width(rollup) - 2
		if pad < 1 {
			return lines
		}
		lines[0] = "  " + row.Title.Style.Render(name) +
			strings.Repeat(" ", pad) + style.Dim.Render(rollup) + "  "
		return lines
	}
}

// axisAGroupedRows builds header+item rows for the rollup variant, filling
// rollups keyed by header row ID as it goes.
func axisAGroupedRows(items []work.WorkItem, collapsed map[string]bool, rollups map[string]string) []collection.Row {
	var rows []collection.Row
	for _, g := range work.GroupByProject(items) {
		arrow := "▼"
		if collapsed[g.Project] {
			arrow = "▶"
		}
		label, st := g.Project, axisAGroupHeader
		if g.Project == "" {
			label, st = "ungrouped", axisAUngroupedHeader
		}
		id := "project:" + g.Project
		rollups[id] = axisARollup(g.Items)
		rows = append(rows, collection.Row{
			ID:     id,
			Header: true,
			Title: collection.Cell{
				Text:  fmt.Sprintf("%s %s (%d)", arrow, label, len(g.Items)),
				Style: st,
			},
		})
		for _, it := range g.Items {
			rows = append(rows, collection.Row{
				ID:     it.Slug,
				Cells:  axisABaseCells(it),
				Hidden: collapsed[g.Project],
			})
		}
	}
	return rows
}

// axisAStripLine renders the switcher variant's one-line workstream
// selector: "all" plus one segment per group, active segment bright.
func axisAStripLine(width int, items []work.WorkItem, active string) string {
	groups := work.GroupByProject(items)
	seg := func(label string, count int, isActive bool) string {
		text := fmt.Sprintf("%s (%d)", label, count)
		if isActive {
			return axisAStripActive.Render(text)
		}
		return axisAStripInactive.Render(text)
	}
	parts := []string{seg("all", len(items), active == "all")}
	for _, g := range groups {
		label := g.Project
		if label == "" {
			label = "ungrouped"
		}
		parts = append(parts, seg(label, len(g.Items), active == g.Project))
	}
	line := "  " + strings.Join(parts, style.Separator.Render(" · "))
	if pad := width - lipgloss.Width(line); pad > 0 {
		line += strings.Repeat(" ", pad)
	}
	return line
}

// axisAFrame builds the fixture model, swaps the candidate list body into
// the pane config, and composes the full top-bottom frame.
func axisAFrame(t *testing.T, listView string) string {
	t.Helper()
	m := newMockupModel(t, stateWork, config.LayoutTopBottom,
		mockupWidth, mockupHeight, axisAWorkItems(), mockupFollowupItems())
	m = withPRStatuses(m, axisAPRStatuses())
	m = withWorkDetail(t, m, axisADetail())
	cfg := m.buildPaneConfig()
	cfg.listView = listView
	return m.viewTopBottom(cfg)
}

// axisAList constructs a sized candidate list on the collection engine.
func axisAList(cols []collection.Column, rows []collection.Row, width, height int, cursorID string) collection.List {
	cl := collection.NewList(cols)
	cl.SetSize(width, height)
	cl.SetRows(rows)
	if cursorID != "" {
		cl.SetCursorByID(cursorID)
	}
	return cl
}

func TestMockupDumpAxisARollup(t *testing.T) {
	requireMockupDump(t)

	render := func(collapsed map[string]bool, name string) {
		dumpMockup(t, name, func(t *testing.T) string {
			m := newMockupModel(t, stateWork, config.LayoutTopBottom,
				mockupWidth, mockupHeight, axisAWorkItems(), mockupFollowupItems())
			width, height := m.topPanelWidth(), m.listPanelHeight()

			rollups := make(map[string]string)
			rows := axisAGroupedRows(axisAWorkItems(), collapsed, rollups)
			cl := axisAList(axisAColumns(), rows, width, height, "settlement-verdict-drill-in")
			cl.SetDecorator(axisARollupDecorator(width, rollups))
			return axisAFrame(t, cl.View())
		})
	}

	t.Run("cand-worklist-rollup", func(t *testing.T) {
		render(map[string]bool{}, "cand-worklist-rollup")
	})
	t.Run("cand-worklist-rollup-collapsed", func(t *testing.T) {
		render(map[string]bool{"tui-rework": true, "grouping": true},
			"cand-worklist-rollup-collapsed")
	})
}

func TestMockupDumpAxisARail(t *testing.T) {
	requireMockupDump(t)

	dumpMockup(t, "cand-worklist-rail", func(t *testing.T) string {
		m := newMockupModel(t, stateWork, config.LayoutTopBottom,
			mockupWidth, mockupHeight, axisAWorkItems(), mockupFollowupItems())
		width, height := m.topPanelWidth(), m.listPanelHeight()

		var rows []collection.Row
		for _, it := range axisAWorkItems() {
			rows = append(rows, collection.Row{ID: it.Slug, Cells: axisARailCells(it)})
		}
		cl := axisAList(axisARailColumns(), rows, width, height, "settlement-verdict-drill-in")
		return axisAFrame(t, cl.View())
	})
}

func TestMockupDumpAxisASwitcher(t *testing.T) {
	requireMockupDump(t)

	t.Run("cand-worklist-switcher-all", func(t *testing.T) {
		dumpMockup(t, "cand-worklist-switcher-all", func(t *testing.T) string {
			m := newMockupModel(t, stateWork, config.LayoutTopBottom,
				mockupWidth, mockupHeight, axisAWorkItems(), mockupFollowupItems())
			width, height := m.topPanelWidth(), m.listPanelHeight()

			var rows []collection.Row
			for _, it := range axisAWorkItems() {
				rows = append(rows, collection.Row{ID: it.Slug, Cells: axisARailCells(it)})
			}
			cl := axisAList(axisARailColumns(), rows, width, height-1, "settlement-verdict-drill-in")
			strip := axisAStripLine(width, axisAWorkItems(), "all")
			return axisAFrame(t, strip+"\n"+cl.View())
		})
	})

	t.Run("cand-worklist-switcher-focus", func(t *testing.T) {
		dumpMockup(t, "cand-worklist-switcher-focus", func(t *testing.T) string {
			m := newMockupModel(t, stateWork, config.LayoutTopBottom,
				mockupWidth, mockupHeight, axisAWorkItems(), mockupFollowupItems())
			width, height := m.topPanelWidth(), m.listPanelHeight()

			var rows []collection.Row
			for _, it := range axisAWorkItems() {
				if it.Project != "settlement-trust" {
					continue
				}
				rows = append(rows, collection.Row{ID: it.Slug, Cells: axisABaseCells(it)})
			}
			cl := axisAList(axisAColumns(), rows, width, height-1, "settlement-verdict-drill-in")
			strip := axisAStripLine(width, axisAWorkItems(), "settlement-trust")
			return axisAFrame(t, strip+"\n"+cl.View())
		})
	})
}
