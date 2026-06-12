package work

import (
	"fmt"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

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

// listRow is a display row — either a project group header or a work item.
type listRow struct {
	isHeader    bool
	project     string // header: group label; item: the item's project ("" = ungrouped)
	memberCount int    // header only: visible (filtered) member count
	item        WorkItem
}

// ListModel is the Bubble Tea model for the work item list panel.
// The cursor indexes display rows (headers + items), not items.
type ListModel struct {
	allItems            []WorkItem
	filterMode          FilterMode
	cursor              int
	collapsed           map[string]bool // project → collapsed (session-local, not persisted)
	prStatus            map[string]gh.PRStatus
	prLoaded            bool
	compactMode         bool
	specActiveSlugs     map[string]bool // all slugs currently speccing
	specNeedsInputSlugs map[string]bool // slugs with active input prompt
	specDots            int
	externalActiveSlugs map[string]bool // slugs with sessions from other TUI instances
	width               int
	height              int
	err                 error
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
		prStatus:   nil,
		prLoaded:   false,
	}
	m.cursor = m.firstItemRow()
	return m
}

// rows derives the display rows from the filtered items: a header row per
// project section followed by its members, then the ungrouped items flat
// with no header. Collapsed members are still present — visibility is
// applied by visibleRowIdxs.
func (m ListModel) rows() []listRow {
	var rows []listRow
	for _, g := range GroupByProject(m.visibleItems()) {
		if g.Project != "" {
			rows = append(rows, listRow{isHeader: true, project: g.Project, memberCount: len(g.Items)})
		}
		for _, it := range g.Items {
			rows = append(rows, listRow{project: g.Project, item: it})
		}
	}
	return rows
}

// visibleRowIdxs returns indices of rows not hidden by a collapsed project.
func (m ListModel) visibleRowIdxs(rows []listRow) []int {
	idxs := make([]int, 0, len(rows))
	for i, r := range rows {
		if !r.isHeader && r.project != "" && m.collapsed[r.project] {
			continue
		}
		idxs = append(idxs, i)
	}
	return idxs
}

// firstItemRow returns the index of the first item row (skipping any leading
// group header), or 0 when the list is empty.
func (m ListModel) firstItemRow() int {
	for i, r := range m.rows() {
		if !r.isHeader {
			return i
		}
	}
	return 0
}

// nextVisible returns the next visible row index from current, in the given direction.
func (m ListModel) nextVisible(current, dir int, visible []int) int {
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
		// Current row not visible; jump to nearest end.
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

// FilterMode returns the current filter mode.
func (m ListModel) GetFilterMode() FilterMode {
	return m.filterMode
}

func (m ListModel) Init() tea.Cmd {
	return nil
}

func (m ListModel) Update(msg tea.Msg) (ListModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

	case PRStatusMsg:
		m.prLoaded = true
		if msg.Err == nil {
			m.prStatus = msg.Statuses
		}

	case SpecStatusMsg:
		if m.specActiveSlugs == nil {
			m.specActiveSlugs = make(map[string]bool)
			m.specNeedsInputSlugs = make(map[string]bool)
		}
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
				return m, specTick()
			}
		}

	case specTickMsg:
		if len(m.specActiveSlugs) > 0 {
			m.specDots = (m.specDots + 1) % 4
			return m, specTick()
		}

	case ExternalSessionMsg:
		m.externalActiveSlugs = msg.Slugs

	case tea.KeyPressMsg:
		rows := m.rows()
		visible := m.visibleRowIdxs(rows)
		switch msg.String() {
		case "ctrl+a":
			// Toggle between active and archived
			if m.filterMode == FilterActive {
				m.filterMode = FilterArchived
			} else {
				m.filterMode = FilterActive
			}
			m.cursor = m.firstItemRow()
		case "j", "down":
			m.cursor = m.nextVisible(m.cursor, 1, visible)
		case "k", "up":
			m.cursor = m.nextVisible(m.cursor, -1, visible)
		case "g", "home":
			if len(visible) > 0 {
				m.cursor = visible[0]
			} else {
				m.cursor = 0
			}
		case "G", "end":
			if len(visible) > 0 {
				m.cursor = visible[len(visible)-1]
			}
		case "s":
			if item, ok := m.CurrentItem(); ok {
				return m, func() tea.Msg {
					return SpecRequestMsg{Slug: item.Slug}
				}
			}
		case "c":
			if item, ok := m.CurrentItem(); ok {
				return m, func() tea.Msg {
					return ChatRequestMsg{Slug: item.Slug, Title: item.Title}
				}
			}
		case "enter":
			if m.cursor >= 0 && m.cursor < len(rows) {
				if row := rows[m.cursor]; row.isHeader {
					if m.collapsed == nil {
						m.collapsed = make(map[string]bool)
					}
					m.collapsed[row.project] = !m.collapsed[row.project]
				} else {
					item := row.item
					return m, func() tea.Msg {
						return ItemSelectedMsg{Item: item}
					}
				}
			}
		}
	}
	return m, nil
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
	return m.cursor
}

// CurrentItem returns the work item under the cursor, or false when the
// cursor is on a group header or the list is empty.
func (m ListModel) CurrentItem() (WorkItem, bool) {
	rows := m.rows()
	if m.cursor < 0 || m.cursor >= len(rows) || rows[m.cursor].isHeader {
		return WorkItem{}, false
	}
	return rows[m.cursor].item, true
}

// CurrentSlug returns the slug of the currently highlighted item, or "" when
// the list is empty or the cursor is on a group header.
func (m ListModel) CurrentSlug() string {
	if item, ok := m.CurrentItem(); ok {
		return item.Slug
	}
	return ""
}

// SetCursorBySlug moves the cursor to the item with the given slug.
// Returns true if found, false if not (cursor resets to the first item row).
func (m *ListModel) SetCursorBySlug(slug string) bool {
	for i, r := range m.rows() {
		if !r.isHeader && r.item.Slug == slug {
			m.cursor = i
			return true
		}
	}
	m.cursor = m.firstItemRow()
	return false
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
	}
}

// SetCompactMode enables or disables compact rendering (slug + status only).
func (m *ListModel) SetCompactMode(compact bool) {
	m.compactMode = compact
}

func (m ListModel) View() string {
	if m.err != nil {
		return fmt.Sprintf("Error loading work items: %v\n", m.err)
	}

	var content string
	if m.compactMode {
		content = m.viewCompact()
	} else {
		content = m.viewFull()
	}

	return content
}

// panelW is the inner width of the left panel (matches leftPanelWidth in main.go).
const panelW = 40

// needsInputStyle flags a spec session waiting for user input. ColorAttention
// rather than StatusWarn: the dot marks an active process needing a human,
// not a readiness state. Hoisted so render paths never allocate per frame.
var needsInputStyle = lipgloss.NewStyle().Foreground(style.ColorAttention)

// prMergedStyle keeps GitHub's merged-purple for the PR badge; the status
// ramp has no merged role, and StatusDone (dim) would make merged PRs read
// like the dim "--" placeholder for no PR at all.
var prMergedStyle = lipgloss.NewStyle().Foreground(style.ColorMerged)

// Selected-row styles, hoisted so viewCompact/viewTable never allocate per
// frame (allocate-once rule, style.go).
var (
	titleSelStyle = lipgloss.NewStyle().Background(style.ColorSelectionBg).Bold(true)
	infoSelStyle  = lipgloss.NewStyle().Background(style.ColorSelectionBg)
)

// windowByBudget walks outward from the cursor row, greedily adding rows
// above and below until the rendered line budget is exhausted, and returns
// the half-open [offset, end) window into visible. Same windowing as
// tasks.go: row heights vary (headers vs items, collapsed groups), so the
// window is computed in rendered lines, not row counts. visible must be
// non-empty; a cursor not in visible anchors the window at the top.
func windowByBudget(visible, heights []int, cursor, budget int) (int, int) {
	if budget < 1 {
		budget = 1<<31 - 1 // unbounded when height not set
	}

	cursorPos := 0
	for i, idx := range visible {
		if idx == cursor {
			cursorPos = i
			break
		}
	}

	// Always include the cursor row, then expand both directions greedily.
	offset := cursorPos
	end := cursorPos + 1
	used := heights[cursorPos]

	lo, hi := cursorPos-1, cursorPos+1
	for used < budget {
		addedAny := false
		if hi < len(visible) && used+heights[hi] <= budget {
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

// groupHeaderStyle renders project group header rows; hoisted per the
// allocate-once rule (style.go).
var groupHeaderStyle = lipgloss.NewStyle().Foreground(style.ColorAccent).Bold(true)

// renderGroupHeader renders a project group header row, padded to width:
//
//	"  ▼ project (n)"   (▶ when collapsed; n = visible member count)
func (m ListModel) renderGroupHeader(row listRow, selected bool, width int) string {
	arrow := "▼"
	if m.collapsed[row.project] {
		arrow = "▶"
	}
	cursor := "  "
	if selected {
		cursor = "> "
	}
	label := fmt.Sprintf("%s (%d)", row.project, row.memberCount)
	if maxW := width - 4; maxW > 0 {
		label = style.Truncate(label, maxW)
	}
	line := cursor + arrow + " " + label
	for lipgloss.Width(line) < width {
		line += " "
	}
	if selected {
		return titleSelStyle.Render(line)
	}
	return groupHeaderStyle.Render(line)
}

// viewCompact renders the compact split-pane list. Group headers occupy one
// line; items occupy two:
//
//	Line 1: "> Title"              (bold when selected)
//	Line 2: "    status · #issue"  (dim metadata)
func (m ListModel) viewCompact() string {
	rows := m.rows()
	visible := m.visibleRowIdxs(rows)

	var b strings.Builder

	if len(visible) == 0 {
		dimStyle := style.Dim
		label := "active"
		if m.filterMode == FilterArchived {
			label = "archived"
		}
		return dimStyle.Render(fmt.Sprintf("  No %s work items.  (ctrl+a to switch)", label))
	}

	heights := make([]int, len(visible))
	for i, idx := range visible {
		if rows[idx].isHeader {
			heights[i] = 1
		} else {
			heights[i] = 2
		}
	}
	offset, end := windowByBudget(visible, heights, m.cursor, m.height)

	for vi := offset; vi < end; vi++ {
		idx := visible[vi]
		row := rows[idx]
		selected := idx == m.cursor

		if row.isHeader {
			b.WriteString(m.renderGroupHeader(row, selected, panelW) + "\n")
			continue
		}
		item := row.item

		cursor := "  "
		if selected {
			cursor = "> "
		}

		// Spec indicator: ● (amber) only when waiting for input, nothing when just running.
		// External session indicator: dim ◆ when another TUI instance is working on this slug.
		specGlyph := ""
		if m.specActiveSlugs[item.Slug] && m.specNeedsInputSlugs[item.Slug] {
			specGlyph = needsInputStyle.Render("●") + " "
		} else if !m.specActiveSlugs[item.Slug] && m.externalActiveSlugs[item.Slug] {
			specGlyph = style.Dim.Render("◆") + " "
		}

		// Line 1: title (fall back to slug)
		name := item.Title
		if name == "" {
			name = item.Slug
		}
		glyphW := lipgloss.Width(specGlyph)
		line1 := cursor + specGlyph + style.Truncate(name, panelW-2-glyphW)
		for lipgloss.Width(line1) < panelW {
			line1 += " "
		}

		// Line 2: status · issue
		info := m.buildInfoCompact(item)
		line2 := "    " + info
		for lipgloss.Width(line2) < panelW {
			line2 += " "
		}

		if selected {
			line1 = titleSelStyle.Render(line1)
			line2 = infoSelStyle.Render(line2)
		}

		b.WriteString(line1 + "\n")
		b.WriteString(line2 + "\n")
	}

	return b.String()
}

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

// buildInfoCompact builds the status line for compact mode: readiness · issue.
// Issue is always shown ("--" when not set). No PR badge (space is reserved for slug on the same line).
func (m ListModel) buildInfoCompact(item WorkItem) string {
	dimStyle := style.Dim
	sep := dimStyle.Render(" · ")

	var parts []string

	// When this item is actively speccing, show animated status instead of readiness.
	// When another TUI has the session, show dim "active".
	if m.specActiveSlugs[item.Slug] {
		dots := strings.Repeat(".", m.specDots)
		parts = append(parts, style.StatusActive.Render("speccing"+dots+strings.Repeat(" ", 3-len(dots))))
	} else if m.externalActiveSlugs[item.Slug] {
		parts = append(parts, style.Dim.Render("active"))
	} else {
		label, st := readinessLabel(item)
		parts = append(parts, st.Render(label))
	}

	issueStr := "--"
	if item.Issue != "" {
		issueStr = extractURLRef(item.Issue)
	}
	parts = append(parts, dimStyle.Render(issueStr))

	return strings.Join(parts, sep)
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

// viewFull renders the full-width table with all columns.
func (m ListModel) viewFull() string {
	var b strings.Builder

	// Column widths — no TITLE column; slug expands to fill available space.
	dotW := 1
	statusW := 12 // "needs tasks" = 11 chars
	issueW := 8   // "#12345" = 7 chars
	updatedW := 12
	prW := 10
	slugW := 50 // default; grows to fill terminal width

	// Adapt to terminal width: slug absorbs all spare space.
	// Fixed columns: dot(1) + status(12) + issue(8) + pr(10) + updated(12) + gaps(12) = 55
	// Gaps: 6 pairs of "  " separators (leading + dot-slug gap + 4 inter-column) = 12 chars.
	if m.width > 0 {
		slugW = m.width - dotW - statusW - issueW - prW - updatedW - 12
		if slugW < 20 {
			slugW = 20
		}
	}

	// Styles
	headerStyle := style.SectionTitle
	selectedStyle := titleSelStyle
	dimStyle := style.Dim

	// Header
	header := fmt.Sprintf("  %-*s  %-*s  %-*s  %-*s  %-*s  %-*s",
		dotW, " ",
		slugW, "SLUG",
		statusW, "READINESS",
		issueW, "ISSUE",
		prW, "PR",
		updatedW, "UPDATED",
	)
	b.WriteString(headerStyle.Render(header))
	b.WriteString("\n")

	rows := m.rows()
	visible := m.visibleRowIdxs(rows)
	if len(visible) == 0 {
		return b.String()
	}

	// Every row is one line; reserve 1 for the column header — footer is in
	// the parent status bar.
	heights := make([]int, len(visible))
	for i := range heights {
		heights[i] = 1
	}
	offset, end := windowByBudget(visible, heights, m.cursor, m.height-1)

	for vi := offset; vi < end; vi++ {
		idx := visible[vi]
		if rows[idx].isHeader {
			b.WriteString(m.renderGroupHeader(rows[idx], idx == m.cursor, m.width))
			b.WriteString("\n")
			continue
		}
		item := rows[idx].item

		slug := style.Truncate(item.Slug, slugW)
		updated := FormatRelativeTime(item.Updated)
		updated = style.Truncate(updated, updatedW)
		pr := m.prBadge(item.PR, prW)

		// Dot column — shows ● (amber) when spec is waiting for input.
		var dotStr string
		if m.specNeedsInputSlugs[item.Slug] {
			dotStr = needsInputStyle.Render("●")
		} else {
			dotStr = " "
		}

		// Readiness label — animated "speccing" when active, or dim "◆ active"
		// for external sessions. Local speccing wins over external so one slug
		// never shows conflicting indicators.
		var status string
		if m.specActiveSlugs[item.Slug] {
			dots := strings.Repeat(".", m.specDots)
			status = style.StatusActive.Render(style.Truncate("speccing"+dots+strings.Repeat(" ", 3-len(dots)), statusW))
		} else if m.externalActiveSlugs[item.Slug] {
			status = style.Dim.Render(style.Truncate("◆ active", statusW))
		} else {
			label, st := readinessLabel(item)
			status = st.Render(style.Truncate(label, statusW))
		}

		// Issue number
		issueStr := "--"
		if item.Issue != "" {
			issueStr = extractURLRef(item.Issue)
		}
		issue := dimStyle.Render(style.Truncate(issueStr, issueW))

		row := fmt.Sprintf("  %s  %-*s  %s%s  %s%s  %s%s  %-*s",
			dotStr,
			slugW, slug,
			status, strings.Repeat(" ", max(0, statusW-lipgloss.Width(status))),
			issue, strings.Repeat(" ", max(0, issueW-lipgloss.Width(issue))),
			pr, strings.Repeat(" ", max(0, prW-lipgloss.Width(pr))),
			updatedW, updated,
		)

		if idx == m.cursor {
			row = selectedStyle.Render(row)
		}

		b.WriteString(row)
		b.WriteString("\n")
	}

	return b.String()
}

func (m ListModel) prBadge(prField string, width int) string {
	if prField == "" {
		return style.Dim.Render(style.Truncate("--", width))
	}

	if !m.prLoaded {
		return style.StatusWarn.Render(style.Truncate("...", width))
	}

	if m.prStatus == nil {
		return style.Dim.Render(style.Truncate("--", width))
	}

	ps, ok := m.prStatus[prField]
	if !ok {
		return style.Dim.Render(style.Truncate("--", width))
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
		return style.StatusReady.Render(style.Truncate(badge, width))
	case "MERGED":
		return prMergedStyle.Render(style.Truncate(label+" ●", width))
	case "CLOSED":
		return style.StatusError.Render(style.Truncate(label+" ✗", width))
	}

	return style.Truncate(label, width)
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

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
