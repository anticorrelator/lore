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

// ImplementRequestMsg is sent when the user presses 'i' to run /implement for an
// item. The dispatch layers emit it unconditionally; the host applies the
// readiness gate (ready = has tasks and not archived) before launching.
type ImplementRequestMsg struct {
	Slug string
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

// ReleaseFinishedMsg is sent when the `lore work release` command completes.
type ReleaseFinishedMsg struct {
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

// SessionStatusMsg is dispatched from main.go to update the list's local
// active-session indicator. Done=true clears the indicator; otherwise it records
// the session as active for the slug and updates its needs-input state. Type is
// the session's spec|implement|chat kind, which selects the animated readiness
// label; an empty Type on a needs-input-only update preserves the recorded type.
type SessionStatusMsg struct {
	Slug       string
	Type       string
	NeedsInput bool
	Done       bool
}

// ExternalSession describes one active session on another TUI instance: who
// owns it, what kind it is, and who initiated it (agent vs human) — enough to
// badge it distinctly from a local session.
type ExternalSession struct {
	Instance  string
	Type      string // spec|implement|chat
	Initiator string // agent|human
}

// IsAgent reports whether the session was agent-initiated.
func (e ExternalSession) IsAgent() bool { return e.Initiator == "agent" }

// ExternalSessionMsg carries every slug with an active session on another TUI
// instance, keyed by slug. It is a full snapshot: the handler replaces its map
// wholesale rather than merging, since stale instances are already filtered out
// upstream.
type ExternalSessionMsg struct {
	Sessions map[string]ExternalSession
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
	allItems               []WorkItem
	filterMode             FilterMode
	collapsed              map[string]bool // project → collapsed (session-local, not persisted)
	prStatus               map[string]gh.PRStatus
	prLoaded               bool
	sessionActiveType      map[string]string // slug → active local session Type (spec|implement|chat)
	sessionNeedsInputSlugs map[string]bool   // slugs with active input prompt
	specDots               int
	externalSessions       map[string]ExternalSession // slug → session on another TUI instance
	list                   collection.List
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

	// Blockedness and ordering are derived fresh from the loaded items on every
	// rebuild: no session-local state, so the index-reload ListModel discard
	// needs no carry-over line for either.
	active := ActiveSlugs(m.allItems)
	groups := GroupByProject(m.visibleItems())
	hasLabeledGroup := false
	for _, g := range groups {
		if g.Project != "" {
			hasLabeledGroup = true
			break
		}
	}

	blockedBadges := make(map[string][]string)
	var rows []collection.Row
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
			rows = append(rows, collection.Row{
				ID:     headerIDPrefix + g.Project,
				Header: true,
				Title: collection.Cell{
					Text:  fmt.Sprintf("%s %s (%d)", arrow, label, len(g.Items)),
					Style: st,
				},
			})
		}
		for _, it := range orderGroupItems(g.Items, active) {
			if blockers := activeBlockers(it, active); len(blockers) > 0 {
				blockedBadges[it.Slug] = blockers
			}
			row := m.itemRow(it)
			row.Hidden = hasHeader && m.collapsed[g.Project]
			rows = append(rows, row)
		}
	}
	m.list.SetDecorator(newListDecorator(blockedBadges))

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
	if m.sessionNeedsInputSlugs[item.Slug] {
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

// readinessCell returns the readiness column content, in strict priority
// order: an animated per-type label while a local session is active
// ("speccing"/"implementing"/"chatting"), then a badge for an external session
// (amber "◆ agent" when agent-initiated, dim "◆ active" when human), then a
// review-gate badge (amber "⊘ held" for a hold, cyan "⚑ flagged" for a flag),
// otherwise the readiness label on the status ramp. Higher tiers win so one slug
// never shows conflicting indicators.
func (m ListModel) readinessCell(item WorkItem) collection.Cell {
	if typ, ok := m.sessionActiveType[item.Slug]; ok {
		return collection.Cell{Text: sessionActiveText(typ, m.specDots), Style: style.StatusActive}
	}
	if es, ok := m.externalSessions[item.Slug]; ok {
		if es.IsAgent() {
			return collection.Cell{Text: "◆ agent", Style: needsInputStyle}
		}
		return collection.Cell{Text: "◆ active", Style: style.Dim}
	}
	switch reviewMechanism(item) {
	case "hold":
		return collection.Cell{Text: "⊘ held", Style: reviewHeldStyle}
	case "flag":
		return collection.Cell{Text: "⚑ flagged", Style: reviewFlaggedStyle}
	}
	label, st := readinessLabel(item)
	return collection.Cell{Text: label, Style: st}
}

// activeStatusWidth is the fixed width of the animated active-session label,
// matched to the readiness column so the dots animate without shifting
// neighboring stacked-layout metadata, and so the longest verb ("implementing")
// never truncates mid-word.
const activeStatusWidth = 12

// sessionActiveText renders the animated active-session status for a session
// type: the type's verb followed by up to `dots` cycling dots, padded to a
// stable width. A full-width verb ("implementing") leaves no room for dots and
// renders static.
func sessionActiveText(typ string, dots int) string {
	label := sessionActiveLabel(typ)
	room := activeStatusWidth - len(label)
	if room < 0 {
		room = 0
	}
	if dots > room {
		dots = room
	}
	return label + strings.Repeat(".", dots) + strings.Repeat(" ", room-dots)
}

// sessionActiveLabel maps a session Type to its animated readiness verb. An
// unknown or empty type falls back to "speccing" — the historical label from
// before the indicator carried a type.
func sessionActiveLabel(typ string) string {
	switch typ {
	case SessionImplement:
		return "implementing"
	case SessionChat:
		return "chatting"
	case SessionWorker:
		return "working"
	default:
		return "speccing"
	}
}

// reviewMechanism returns the item's active review mechanism ("hold" | "flag"),
// or "" when ungated.
func reviewMechanism(item WorkItem) string {
	if item.Review == nil {
		return ""
	}
	return item.Review.Mechanism
}

// stackedGlyph returns the title-line indicator prefix for the stacked
// layout, in the same priority order as readinessCell: ● (amber) when a local
// spec session waits for input, ◈ (amber) when another instance runs an
// agent-initiated session, ◆ (dim) when it is a human session on another
// instance, then ⊘ (amber) for a review hold or ⚑ (cyan) for a review flag.
func (m ListModel) stackedGlyph(item WorkItem) string {
	_, active := m.sessionActiveType[item.Slug]
	if active && m.sessionNeedsInputSlugs[item.Slug] {
		return "● "
	}
	if !active {
		if es, ok := m.externalSessions[item.Slug]; ok {
			if es.IsAgent() {
				return "◈ "
			}
			return "◆ "
		}
		switch reviewMechanism(item) {
		case "hold":
			return "⊘ "
		case "flag":
			return "⚑ "
		}
	}
	return ""
}

// newListDecorator builds the work list's single decorator: header rows pass
// through the engine render untouched, item rows get the stacked-glyph coloring
// and, for currently-blocked items, a dim "⧗ after: <slug>" continuation line
// listing their still-active blockers (keyed by row ID / slug). The badge is
// derived per rebuild, so it lives in the closure rather than on ListModel.
func newListDecorator(blockedBadges map[string][]string) collection.RowDecorator {
	return func(row collection.Row, selected bool, lines []string) []string {
		if row.Header {
			return lines
		}
		lines = decorateStackedGlyph(row, selected, lines)
		if blockers, ok := blockedBadges[row.ID]; ok && len(blockers) > 0 {
			lines = append(lines, blockedBadgeLine(blockers, lines))
		}
		return lines
	}
}

// blockedBadgeLine renders the "⧗ after: <slug>[, ...]" continuation line under
// a blocked item, dim-italic per the tasks.go blocked-by grammar. Width is read
// from an already-padded sibling line so the plain badge truncates before
// styling, keeping the emitted line within the panel.
func blockedBadgeLine(blockers []string, lines []string) string {
	width := 0
	if len(lines) > 0 {
		width = lipgloss.Width(lines[0])
	}
	text := "    ⧗ after: " + strings.Join(blockers, ", ")
	if width > 0 {
		text = style.Truncate(text, width)
	}
	return blockedBadgeStyle.Render(text)
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
	case strings.HasPrefix(rest, "◈ "):
		lines[0] = line[:2] + needsInputStyle.Render("◈") + rest[len("◈"):]
	case strings.HasPrefix(rest, "◆ "):
		lines[0] = line[:2] + style.Dim.Render("◆") + rest[len("◆"):]
	case strings.HasPrefix(rest, "⊘ "):
		lines[0] = line[:2] + reviewHeldStyle.Render("⊘") + rest[len("⊘"):]
	case strings.HasPrefix(rest, "⚑ "):
		lines[0] = line[:2] + reviewFlaggedStyle.Render("⚑") + rest[len("⚑"):]
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

	case SessionStatusMsg:
		if m.sessionActiveType == nil {
			m.sessionActiveType = make(map[string]string)
			m.sessionNeedsInputSlugs = make(map[string]bool)
		}
		var cmd tea.Cmd
		if msg.Done {
			delete(m.sessionActiveType, msg.Slug)
			delete(m.sessionNeedsInputSlugs, msg.Slug)
			if len(m.sessionActiveType) == 0 {
				m.specDots = 0
			}
		} else {
			wasEmpty := len(m.sessionActiveType) == 0
			typ := msg.Type
			if typ == "" {
				// A needs-input-only update carries no Type; keep the one recorded
				// at launch so the label doesn't flip to the "speccing" fallback.
				typ = m.sessionActiveType[msg.Slug]
			}
			m.sessionActiveType[msg.Slug] = typ
			m.sessionNeedsInputSlugs[msg.Slug] = msg.NeedsInput
			if wasEmpty {
				cmd = specTick()
			}
		}
		m.refreshRows()
		return m, cmd

	case specTickMsg:
		if len(m.sessionActiveType) > 0 {
			m.specDots = (m.specDots + 1) % 4
			m.refreshRows()
			return m, specTick()
		}
		return m, nil

	case ExternalSessionMsg:
		m.externalSessions = msg.Sessions
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
		case "i":
			if item, ok := m.CurrentItem(); ok {
				return m, func() tea.Msg {
					return ImplementRequestMsg{Slug: item.Slug}
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

// reviewHeldStyle and reviewFlaggedStyle color the two review-gate badges by
// their palette roles (style.go): a hold is ColorAttention (blocked on a
// human), a flag is ColorModified (acted on, not yet finalized). Hoisted so
// the list decorator and detail meta tab never allocate per frame.
var (
	reviewHeldStyle    = lipgloss.NewStyle().Foreground(style.ColorAttention)
	reviewFlaggedStyle = lipgloss.NewStyle().Foreground(style.ColorModified)
)

// blockedBadgeStyle renders the work-item "⧗ after:" continuation line, reusing
// the tasks.go blocked-by grammar (ColorDim = ANSI 8, italic) so a blocked work
// item and a blocked task read the same. Hoisted per the allocate-once rule.
var blockedBadgeStyle = lipgloss.NewStyle().Foreground(style.ColorDim).Italic(true)

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
// archived ones, which share the same dim foreground. A spec-less item at
// ceremony depth 1 (a deliberate micro-dispatch, implemented directly) shows
// "direct" on the active style instead of "needs spec", so a rung-1 item under
// implementation never reads as unstarted.
func readinessLabel(item WorkItem) (string, lipgloss.Style) {
	switch {
	case item.Status == "archived":
		return "archived", style.StatusDone
	case item.HasTasks:
		return "ready", style.StatusReady
	case item.HasPlanDoc:
		return "needs tasks", style.StatusWarn
	case item.CeremonyDepth == 1:
		return "direct", style.StatusActive
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

// formatDwell renders how long ago an ISO-8601 instant was as a compact span
// ("just now", "5m", "3h", "4d") with no "ago" suffix — the review-gate dwell
// shown in the detail meta tab. Returns "" when iso is empty or unparseable.
func formatDwell(iso string) string {
	if iso == "" {
		return ""
	}
	t, err := time.Parse(time.RFC3339, iso)
	if err != nil {
		return ""
	}
	diff := time.Since(t)
	switch {
	case diff < time.Minute:
		return "just now"
	case diff < time.Hour:
		return fmt.Sprintf("%dm", int(diff.Minutes()))
	case diff < 24*time.Hour:
		return fmt.Sprintf("%dh", int(diff.Hours()))
	default:
		return fmt.Sprintf("%dd", int(diff.Hours()/24))
	}
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
