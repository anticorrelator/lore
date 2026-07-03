package work

import (
	"fmt"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/collection"
	"github.com/anticorrelator/lore/tui/internal/style"

	"github.com/anticorrelator/lore/tui/internal/gh"
)

// PRStatusMsg is sent when the background PR loader completes.
type PRStatusMsg struct {
	Statuses map[string]gh.PRStatus
	Err      error
}

// ItemSelectedMsg is sent when the user presses Enter on an item.
type ItemSelectedMsg struct {
	Item WorkItem
}

// LoadDetailMsg is sent when the cursor moves to a new item (hover-prefetch).
type LoadDetailMsg struct {
	Slug string
}

// SpecRequestMsg is sent when the user presses 's' to open the spec panel for an item.
type SpecRequestMsg struct {
	Slug string
}

// ChatRequestMsg is sent when the user presses 'c' to open a chat session about an item.
type ChatRequestMsg struct {
	Slug  string
	Title string
}

// ArchiveRequestMsg is sent when the user confirms an archive/unarchive action.
type ArchiveRequestMsg struct {
	Slug      string
	Unarchive bool
}

// ArchiveFinishedMsg is sent when the archive/unarchive command completes.
type ArchiveFinishedMsg struct {
	Err error
}

// DeleteRequestMsg is sent when the user confirms a delete action.
type DeleteRequestMsg struct {
	Slug string
}

// DeleteFinishedMsg is sent when the delete command completes.
type DeleteFinishedMsg struct {
	Err error
}

// AssignFinishedMsg is sent when the workstream-assign command
// (`lore work set --project`) completes.
type AssignFinishedMsg struct {
	Slug  string
	Label string
	Err   error
}

// SpecStatusMsg is dispatched from main.go to update the list's spec indicator.
// Done=true clears the indicator; otherwise sets specActiveSlug and specNeedsInput.
type SpecStatusMsg struct {
	Slug       string
	NeedsInput bool
	Done       bool
}

// ExternalSessionMsg carries the set of slugs with active sessions from other TUI instances.
type ExternalSessionMsg struct {
	Slugs map[string]bool
}

// specTickMsg drives the animated dots on the speccing status line.
type specTickMsg struct{}

func specTick() tea.Cmd {
	return tea.Tick(400*time.Millisecond, func(time.Time) tea.Msg { return specTickMsg{} })
}

// FilterMode controls which work items are shown in the list.
type FilterMode int

const (
	FilterActive   FilterMode = iota // show only active items
	FilterArchived                   // show only archived items
)

// headerIDPrefix namespaces project-header row IDs so they can never collide
// with an item slug (slugs contain no colon).
const headerIDPrefix = "project:"

// listColumns is the work table's column set. The slug absorbs spare width;
// lower-priority columns drop as the panel narrows.
var listColumns = []collection.Column{
	{Key: "dot", Title: " ", Width: 1, Priority: 1},
	{Key: "slug", Title: "SLUG", Width: 20, Priority: 0, Flex: true},
	{Key: "readiness", Title: "READINESS", Width: 12, Priority: 2},
	{Key: "issue", Title: "ISSUE", Width: 8, Priority: 4},
	{Key: "pr", Title: "PR", Width: 10, Priority: 5},
	{Key: "updated", Title: "UPDATED", Width: 12, Priority: 3},
}

// ListModel is the Bubble Tea model for the work item list panel.
type ListModel struct {
	allItems            []WorkItem
	filterMode          FilterMode
	collapsed           map[string]bool // project → collapsed (session-local, not persisted)
	prStatus            map[string]gh.PRStatus
	prLoaded            bool
	specActiveSlugs     map[string]bool // all slugs currently speccing
	specNeedsInputSlugs map[string]bool // slugs with active input prompt
	specDots            int
	externalActiveSlugs map[string]bool // slugs with sessions from other TUI instances
	list                collection.List
}

// visibleItems returns the filtered slice of items based on filterMode.
func (m ListModel) visibleItems() []WorkItem {
	var out []WorkItem
	for _, item := range m.allItems {
		if m.filterMode == FilterArchived {
			if item.Status == "archived" {
				out = append(out, item)
			}
		} else {
			if item.Status != "archived" {
				out = append(out, item)
			}
		}
	}
	return out
}

// NewListModel creates a list model from pre-loaded work items. All groups
// start expanded; the cursor starts on the first item row (past any leading
// group header) so an item is selected from the first frame.
func NewListModel(items []WorkItem) ListModel {
	m := ListModel{
		allItems:   items,
		filterMode: FilterActive,
		collapsed:  make(map[string]bool),
		list:       collection.NewList(listColumns),
	}
	m.list.SetOnCursorChange(func(id string) tea.Cmd {
		return func() tea.Msg { return LoadDetailMsg{Slug: id} }
	})
	m.refreshRows()
	return m
}

// refreshRows rebuilds the collection rows from the current items and
// indicator state, preserving the cursor by row ID — including header rows,
// which List.SetRows alone would not preserve.
func (m *ListModel) refreshRows() {
	var cur string
	if r, ok := m.list.CurrentRow(); ok {
		cur = r.ID
	}

	groups := GroupByProject(m.visibleItems())
	hasLabeledGroup := false
	for _, g := range groups {
		if g.Project != "" {
			hasLabeledGroup = true
			break
		}
	}

	var rows []collection.Row
	rollups := make(map[string]string)
	for _, g := range groups {
		// The ungrouped tail gets a header only alongside labeled groups; an
		// ungrouped-only list stays flat.
		hasHeader := g.Project != "" || hasLabeledGroup
		if hasHeader {
			arrow := "▼"
			if m.collapsed[g.Project] {
				arrow = "▶"
			}
			label, st := g.Project, groupHeaderStyle
			if g.Project == "" {
				label, st = "ungrouped", ungroupedHeaderStyle
			}
			id := headerIDPrefix + g.Project
			rollups[id] = groupRollup(g.Items)
			rows = append(rows, collection.Row{
				ID:     id,
				Header: true,
				Title: collection.Cell{
					Text:  fmt.Sprintf("%s %s (%d)", arrow, label, len(g.Items)),
					Style: st,
				},
			})
		}
		for _, it := range g.Items {
			row := m.itemRow(it)
			row.Hidden = hasHeader && m.collapsed[g.Project]
			rows = append(rows, row)
		}
	}
	m.list.SetDecorator(newListDecorator(rollups))

	label := "active"
	if m.filterMode == FilterArchived {
		label = "archived"
	}
	m.list.SetEmptyText(fmt.Sprintf("  No %s work items.  (ctrl+a to switch)", label))

	m.list.SetRows(rows)
	if cur != "" {
		m.list.SetCursorByID(cur)
	}
}

// itemRow maps a work item to a collection row: cells parallel to
// listColumns for the columnar table, Title+Meta for the stacked layout.
func (m ListModel) itemRow(item WorkItem) collection.Row {
	dot := " "
	if m.specNeedsInputSlugs[item.Slug] {
		dot = "●"
	}

	prText, prStyle := m.prBadgeParts(item.PR)

	issueStr := "--"
	if item.Issue != "" {
		issueStr = extractURLRef(item.Issue)
	}

	readiness := m.readinessCell(item)

	name := item.Title
	if name == "" {
		name = item.Slug
	}

	return collection.Row{
		ID: item.Slug,
		Cells: []collection.Cell{
			{Text: dot, Style: needsInputStyle},
			{Text: item.Slug},
			readiness,
			{Text: issueStr, Style: style.Dim},
			{Text: prText, Style: prStyle},
			{Text: FormatRelativeTime(item.Updated)},
		},
		Title: collection.Cell{Text: m.stackedGlyph(item) + name},
		Meta: []collection.Cell{
			readiness,
			{Text: issueStr, Style: style.Dim},
		},
	}
}

// readinessCell returns the readiness column content: animated "speccing"
// while a local spec session is active, dim "◆ active" for an external
// session, otherwise the readiness label on the status ramp. Local speccing
// wins over external so one slug never shows conflicting indicators.
func (m ListModel) readinessCell(item WorkItem) collection.Cell {
	switch {
	case m.specActiveSlugs[item.Slug]:
		dots := strings.Repeat(".", m.specDots)
		return collection.Cell{Text: "speccing" + dots + strings.Repeat(" ", 3-len(dots)), Style: style.StatusActive}
	case m.externalActiveSlugs[item.Slug]:
		return collection.Cell{Text: "◆ active", Style: style.Dim}
	default:
		label, st := readinessLabel(item)
		return collection.Cell{Text: label, Style: st}
	}
}

// stackedGlyph returns the title-line indicator prefix for the stacked
// layout: ● (amber) only when a local spec session waits for input, dim ◆
// when another TUI instance owns the session.
func (m ListModel) stackedGlyph(item WorkItem) string {
	if m.specActiveSlugs[item.Slug] && m.specNeedsInputSlugs[item.Slug] {
		return "● "
	}
	if !m.specActiveSlugs[item.Slug] && m.externalActiveSlugs[item.Slug] {
		return "◆ "
	}
	return ""
}

// newListDecorator builds the work list's single decorator: header rows get
// the right-aligned rollup rewrite, item rows the stacked-glyph coloring.
// rollups is keyed by header row ID; refreshRows rebuilds both together so
// the decorator never outlives the rows it annotates.
func newListDecorator(rollups map[string]string) collection.RowDecorator {
	return func(row collection.Row, selected bool, lines []string) []string {
		if row.Header {
			return decorateHeaderRollup(row, selected, lines, rollups)
		}
		return decorateStackedGlyph(row, selected, lines)
	}
}

// groupRollup summarizes one project group for its header's right-aligned
// segment: the readiness distribution plus the freshest member's recency.
func groupRollup(items []WorkItem) string {
	var ready, tasks, spec, archived int
	freshest := ""
	for _, it := range items {
		switch {
		case it.Status == "archived":
			archived++
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
	if archived > 0 {
		parts = append(parts, fmt.Sprintf("%d archived", archived))
	}
	parts = append(parts, FormatRelativeTime(freshest))
	return strings.Join(parts, " · ")
}

// decorateHeaderRollup right-aligns a group's dim rollup on unselected header
// lines. Selected headers pass through untouched: the engine's row-wide
// selection background must wrap unstyled content (lipgloss v2 clears the
// background at inner SGR resets). The panel width is recovered from the
// engine-padded incoming line, and the rebuilt line is exactly that wide;
// when name and rollup can't fit with a gap between them the line is left as
// rendered, so narrow panels degrade to the plain header.
func decorateHeaderRollup(row collection.Row, selected bool, lines []string, rollups map[string]string) []string {
	if selected || len(lines) == 0 {
		return lines
	}
	rollup := rollups[row.ID]
	if rollup == "" {
		return lines
	}
	width := lipgloss.Width(lines[0])
	name := row.Title.Text
	pad := width - 2 - lipgloss.Width(name) - lipgloss.Width(rollup) - 2
	if pad < 1 {
		return lines
	}
	lines[0] = "  " + row.Title.Style.Render(name) +
		strings.Repeat(" ", pad) + style.Dim.Render(rollup) + "  "
	return lines
}

// decorateStackedGlyph colors the stacked title-line glyph on unselected
// rows. Selected rows keep plain text — the selection background must wrap
// unstyled content (lipgloss v2 clears the background at inner SGR resets).
// Columnar lines never match: their glyph sits inside an already-styled dot
// cell, so the plain "● "/"◆ " prefix only occurs on stacked title lines.
func decorateStackedGlyph(row collection.Row, selected bool, lines []string) []string {
	if selected || row.Header || len(lines) == 0 {
		return lines
	}
	line := lines[0]
	if len(line) < 2 {
		return lines
	}
	rest := line[2:]
	switch {
	case strings.HasPrefix(rest, "● "):
		lines[0] = line[:2] + needsInputStyle.Render("●") + rest[len("●"):]
	case strings.HasPrefix(rest, "◆ "):
		lines[0] = line[:2] + style.Dim.Render("◆") + rest[len("◆"):]
	}
	return lines
}

// GetFilterMode returns the current filter mode.
func (m ListModel) GetFilterMode() FilterMode {
	return m.filterMode
}

func (m ListModel) Init() tea.Cmd {
	return nil
}

func (m ListModel) Update(msg tea.Msg) (ListModel, tea.Cmd) {
	switch msg := msg.(type) {
	case PRStatusMsg:
		m.prLoaded = true
		if msg.Err == nil {
			m.prStatus = msg.Statuses
		}
		m.refreshRows()
		return m, nil

	case SpecStatusMsg:
		if m.specActiveSlugs == nil {
			m.specActiveSlugs = make(map[string]bool)
			m.specNeedsInputSlugs = make(map[string]bool)
		}
		var cmd tea.Cmd
		if msg.Done {
			delete(m.specActiveSlugs, msg.Slug)
			delete(m.specNeedsInputSlugs, msg.Slug)
			if len(m.specActiveSlugs) == 0 {
				m.specDots = 0
			}
		} else {
			wasEmpty := len(m.specActiveSlugs) == 0
			m.specActiveSlugs[msg.Slug] = true
			m.specNeedsInputSlugs[msg.Slug] = msg.NeedsInput
			if wasEmpty {
				cmd = specTick()
			}
		}
		m.refreshRows()
		return m, cmd

	case specTickMsg:
		if len(m.specActiveSlugs) > 0 {
			m.specDots = (m.specDots + 1) % 4
			m.refreshRows()
			return m, specTick()
		}
		return m, nil

	case ExternalSessionMsg:
		m.externalActiveSlugs = msg.Slugs
		m.refreshRows()
		return m, nil

	case tea.KeyPressMsg:
		switch msg.String() {
		case "ctrl+a":
			if m.filterMode == FilterActive {
				m.filterMode = FilterArchived
			} else {
				m.filterMode = FilterActive
			}
			m.refreshRows()
			m.list.CursorToFirstItem()
			return m, nil
		case "s":
			if item, ok := m.CurrentItem(); ok {
				return m, func() tea.Msg {
					return SpecRequestMsg{Slug: item.Slug}
				}
			}
			return m, nil
		case "c":
			if item, ok := m.CurrentItem(); ok {
				return m, func() tea.Msg {
					return ChatRequestMsg{Slug: item.Slug, Title: item.Title}
				}
			}
			return m, nil
		case "enter":
			if r, ok := m.list.CurrentRow(); ok && r.Header {
				project := strings.TrimPrefix(r.ID, headerIDPrefix)
				if m.collapsed == nil {
					m.collapsed = make(map[string]bool)
				}
				m.collapsed[project] = !m.collapsed[project]
				m.refreshRows()
				return m, nil
			}
			if item, ok := m.CurrentItem(); ok {
				return m, func() tea.Msg {
					return ItemSelectedMsg{Item: item}
				}
			}
			return m, nil
		}
	}

	l, cmd := m.list.Update(msg)
	m.list = l
	return m, cmd
}

// Items returns the currently visible (filtered) work items in display
// (grouped) order. Collapse state does not affect the result.
func (m ListModel) Items() []WorkItem {
	var out []WorkItem
	for _, g := range GroupByProject(m.visibleItems()) {
		out = append(out, g.Items...)
	}
	return out
}

// Cursor returns the current cursor row position.
func (m ListModel) Cursor() int {
	return m.list.Cursor()
}

// CurrentItem returns the work item under the cursor, or false when the
// cursor is on a group header or the list is empty.
func (m ListModel) CurrentItem() (WorkItem, bool) {
	slug := m.list.CurrentID()
	if slug == "" {
		return WorkItem{}, false
	}
	for _, item := range m.allItems {
		if item.Slug == slug {
			return item, true
		}
	}
	return WorkItem{}, false
}

// CurrentSlug returns the slug of the currently highlighted item, or "" when
// the list is empty or the cursor is on a group header.
func (m ListModel) CurrentSlug() string {
	return m.list.CurrentID()
}

// SetCursorBySlug moves the cursor to the item with the given slug.
// Returns true if found, false if not (cursor resets to the first item row).
func (m *ListModel) SetCursorBySlug(slug string) bool {
	if m.list.SetCursorByID(slug) {
		return true
	}
	m.list.CursorToFirstItem()
	return false
}

// ProjectLabels returns the distinct project labels across all loaded items
// (active and archived), sorted — the option set for the assign prompt.
func (m ListModel) ProjectLabels() []string {
	return ProjectLabels(m.allItems)
}

// CollapsedProjects returns the session's collapsed-project set so a rebuilt
// model can inherit it across index reloads.
func (m ListModel) CollapsedProjects() map[string]bool {
	return m.collapsed
}

// SetCollapsedProjects replaces the collapsed-project set (no-op for nil).
func (m *ListModel) SetCollapsedProjects(collapsed map[string]bool) {
	if collapsed != nil {
		m.collapsed = collapsed
		m.refreshRows()
	}
}

func (m ListModel) View() string {
	return m.list.View()
}

// needsInputStyle flags a spec session waiting for user input. ColorAttention
// rather than StatusWarn: the dot marks an active process needing a human,
// not a readiness state. Hoisted so render paths never allocate per frame.
var needsInputStyle = lipgloss.NewStyle().Foreground(style.ColorAttention)

// prMergedStyle keeps GitHub's merged-purple for the PR badge; the status
// ramp has no merged role, and StatusDone (dim) would make merged PRs read
// like the dim "--" placeholder for no PR at all.
var prMergedStyle = lipgloss.NewStyle().Foreground(style.ColorMerged)

// groupHeaderStyle renders project group header rows; hoisted per the
// allocate-once rule (style.go).
var groupHeaderStyle = lipgloss.NewStyle().Foreground(style.ColorAccent).Bold(true)

// ungroupedHeaderStyle renders the pseudo-group header over unassigned items
// dim rather than accent, so it can't be mistaken for a real project named
// "ungrouped".
var ungroupedHeaderStyle = lipgloss.NewStyle().Foreground(style.ColorDim).Bold(true)

// readinessLabel returns the readiness label and its status-ramp style for a
// work item. Archived items use the done style; "needs spec" uses the
// disabled style (dim italic) so unstarted items read differently from
// archived ones, which share the same dim foreground.
func readinessLabel(item WorkItem) (string, lipgloss.Style) {
	switch {
	case item.Status == "archived":
		return "archived", style.StatusDone
	case item.HasTasks:
		return "ready", style.StatusReady
	case item.HasPlanDoc:
		return "needs tasks", style.StatusWarn
	default:
		return "needs spec", style.StatusDisabled
	}
}

// extractURLRef extracts a short "#number" reference from a GitHub URL or plain value.
func extractURLRef(s string) string {
	if !strings.HasPrefix(s, "http") {
		if !strings.HasPrefix(s, "#") {
			return "#" + s
		}
		return s
	}
	s = strings.TrimRight(s, "/")
	parts := strings.Split(s, "/")
	if len(parts) > 0 {
		if last := parts[len(parts)-1]; last != "" {
			return "#" + last
		}
	}
	return s
}

// prBadgeParts returns the PR badge text and its style for a work item's PR
// field — the cell-shaped form consumed by itemRow.
func (m ListModel) prBadgeParts(prField string) (string, lipgloss.Style) {
	if prField == "" {
		return "--", style.Dim
	}

	if !m.prLoaded {
		return "...", style.StatusWarn
	}

	ps, ok := m.prStatus[prField]
	if !ok {
		return "--", style.Dim
	}

	label := fmt.Sprintf("#%d", ps.Number)
	switch ps.State {
	case "OPEN":
		badge := label
		if ps.ReviewDecision == "APPROVED" {
			badge += " ✓"
		} else if ps.ReviewDecision == "CHANGES_REQUESTED" {
			badge += " ✗"
		}
		return badge, style.StatusReady
	case "MERGED":
		return label + " ●", prMergedStyle
	case "CLOSED":
		return label + " ✗", style.StatusError
	}

	return label, lipgloss.Style{}
}

// prBadge renders the PR badge truncated to width.
func (m ListModel) prBadge(prField string, width int) string {
	text, st := m.prBadgeParts(prField)
	return st.Render(style.Truncate(text, width))
}

func FormatRelativeTime(iso string) string {
	t, err := time.Parse(time.RFC3339, iso)
	if err != nil {
		// Try date-only
		t, err = time.Parse("2006-01-02", iso)
		if err != nil {
			return iso
		}
	}

	now := time.Now()
	diff := now.Sub(t)

	switch {
	case diff < time.Minute:
		return "just now"
	case diff < time.Hour:
		m := int(diff.Minutes())
		return fmt.Sprintf("%dm ago", m)
	case diff < 24*time.Hour:
		h := int(diff.Hours())
		return fmt.Sprintf("%dh ago", h)
	case diff < 30*24*time.Hour:
		d := int(diff.Hours() / 24)
		return fmt.Sprintf("%dd ago", d)
	case diff < 365*24*time.Hour:
		mo := int(diff.Hours() / 24 / 30)
		return fmt.Sprintf("%dmo ago", mo)
	default:
		y := int(diff.Hours() / 24 / 365)
		return fmt.Sprintf("%dy ago", y)
	}
}
