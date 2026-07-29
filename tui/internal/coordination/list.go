package coordination

import (
	"fmt"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/collection"
	"github.com/anticorrelator/lore/tui/internal/style"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// ArcSelectedMsg is emitted when Enter lands on an arc row. The host focuses
// the detail panel and loads the arc.
type ArcSelectedMsg struct {
	Slug string
}

var listColumns = []collection.Column{
	{Key: "arc", Title: "ARC", Width: 24, Priority: 0, Flex: true},
	{Key: "state", Title: "STATE", Width: 8, Priority: 1},
	{Key: "age", Title: "AGE", Width: 8, Priority: 1},
	{Key: "items", Title: "ITEMS", Width: 6, Priority: 2},
	{Key: "project", Title: "PROJECT", Width: 18, Priority: 3},
}

// noProjectCell is what an arc with no project label shows in the PROJECT
// column. Project is a label an arc may simply not carry.
const noProjectCell = "—"

// Bucket groups arcs by how recent their latest declared instant is.
type Bucket int

const (
	BucketToday Bucket = iota
	BucketThisWeek
	BucketOlder
)

// Label is the bucket's section header text.
func (b Bucket) Label() string {
	switch b {
	case BucketToday:
		return "Today"
	case BucketThisWeek:
		return "This week"
	}
	return "Older"
}

// bucketOf places a declared instant against local calendar days: today from
// local midnight, this week from local midnight six days back, older before
// that. An empty or unparseable instant buckets as older, which is also where
// it sorts. now is a parameter so the boundary can be exercised at fixed
// instants.
func bucketOf(recency string, now time.Time) Bucket {
	at, ok := parseInstant(recency)
	if !ok {
		return BucketOlder
	}
	midnight := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	switch {
	case !at.Before(midnight):
		return BucketToday
	case !at.Before(midnight.AddDate(0, 0, -6)):
		return BucketThisWeek
	}
	return BucketOlder
}

// BucketAt places the arc's Recency in a bucket. The headers and the row
// ordering share it, so a row's position and its age always tell the same
// story.
func (a Arc) BucketAt(now time.Time) Bucket { return bucketOf(a.Recency(), now) }

// AgedOutAt reports whether the arc's latest declared instant is both readable
// and more than a week old. It is deliberately stricter than BucketAt, which
// buckets an empty or unreadable instant as older: bucketing is a reversible
// placement, while the callers of this predicate write to the record. An arc
// whose record cannot say when it last moved has not been shown to be old.
//
// Status is not consulted here — the caller decides which states are eligible.
func (a Arc) AgedOutAt(now time.Time) bool {
	if _, ok := parseInstant(a.Recency()); !ok {
		return false
	}
	return a.BucketAt(now) == BucketOlder
}

// parseInstant reads a declared instant, accepting the record's RFC3339 form
// and the date-only form, matching what work.FormatRelativeTime tolerates.
func parseInstant(s string) (time.Time, bool) {
	if s == "" {
		return time.Time{}, false
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t, true
	}
	if t, err := time.Parse("2006-01-02", s); err == nil {
		return t, true
	}
	return time.Time{}, false
}

// stateLabel is the row's state badge text.
func stateLabel(status string) string {
	switch status {
	case StatusActive:
		return "live"
	case StatusClosed:
		return "closed"
	case StatusArchived:
		return "archived"
	}
	return status
}

// stateStyle colors the state badge. A live arc whose record declares nothing
// newer than a week ago is drawn in the warn color: it is open, unclosed, and
// worth a second look. The badge and the age are the whole cue — the record
// carries no field that could say whether work has actually stopped.
func stateStyle(status string, bucket Bucket) lipgloss.Style {
	switch status {
	case StatusActive:
		if bucket == BucketOlder {
			return style.StatusWarn
		}
		return style.StatusActive
	case StatusClosed:
		return closedRamp(bucket)
	case StatusArchived:
		return style.StatusDone
	}
	return style.Dim
}

// Ramp steps, hoisted per the allocate-once rule (style.go). The oldest step
// differs only by Faint, which terminals without SGR 2 render as the step
// above it; that tier is hidden by default, so the collapse costs nothing.
var (
	closedThisWeekStyle = lipgloss.NewStyle().Foreground(style.ColorChrome)
	closedOlderStyle    = lipgloss.NewStyle().Foreground(style.ColorChrome).Faint(true)
)

// List section-header styles, hoisted per the allocate-once rule (style.go).
// sectionHeaderStyle matches the work list's project headers so the two views
// delineate their sections at the same weight; headerRuleStyle draws the rule
// that carries the label out to the panel edge.
var (
	sectionHeaderStyle = lipgloss.NewStyle().Foreground(style.ColorAccent).Bold(true)
	headerRuleStyle    = lipgloss.NewStyle().Foreground(style.ColorChrome)
)

// headerRuleLead opens a header line, so the rule starts at the panel edge
// rather than at the column where arc rows begin.
const headerRuleLead = "── "

// decorateHeaderRule redraws an unselected header as a label on a rule spanning
// the panel: the boundary between two recency sections has to read as a
// boundary, not as another arc row. The width comes from the incoming line,
// which the engine has already padded to the panel width.
//
// A selected header passes through untouched so its selection background stays
// one unbroken run. So does a header too wide for its own rule — the engine's
// own truncated, styled line is the better answer at that width.
func decorateHeaderRule(row collection.Row, selected bool, lines []string) []string {
	if !row.Header || selected || len(lines) == 0 {
		return lines
	}
	label := row.Title.Text
	fill := lipgloss.Width(lines[0]) - lipgloss.Width(headerRuleLead) - lipgloss.Width(label) - 1
	if fill < 1 {
		return lines
	}
	decorated := make([]string, len(lines))
	copy(decorated, lines)
	decorated[0] = headerRuleStyle.Render(headerRuleLead) +
		sectionHeaderStyle.Render(label) + " " +
		headerRuleStyle.Render(strings.Repeat("─", fill))
	return decorated
}

// closedRamp fades a closed arc's row as its close recedes. It is indexed on
// the same bucket that drives the headers and the ordering, so a row's dimness
// and its position always tell the same story.
func closedRamp(bucket Bucket) lipgloss.Style {
	switch bucket {
	case BucketToday:
		return style.StatusDone
	case BucketThisWeek:
		return closedThisWeekStyle
	}
	return closedOlderStyle
}

// ListModel is the arc list panel: a collection.List consumer backed by a
// host-supplied arc set. Arcs render as flat rows under recency headers, so
// the cursor rests only on arcs — collection.List skips headers by
// construction.
type ListModel struct {
	arcs []Arc
	// showArchived reveals the Archived section. Archived arcs are filed away,
	// in the sense the key means; listed by default they would drown the live
	// set.
	showArchived bool
	// skipped counts store records the scan could not use.
	skipped int
	list    collection.List
}

// NewListModel builds an empty arc list.
func NewListModel() ListModel {
	m := ListModel{list: collection.NewList(listColumns)}
	m.list.SetDecorator(decorateHeaderRule)
	m.list.SetOnSelect(func(r collection.Row) tea.Cmd {
		if r.Header || r.ID == "" {
			return nil
		}
		slug := r.ID
		return func() tea.Msg { return ArcSelectedMsg{Slug: slug} }
	})
	m.refreshRows()
	return m
}

// SetArcs replaces the arc set, preserving the cursor by slug. skipped is the
// scan's unusable-record count, surfaced in the empty text.
func (m *ListModel) SetArcs(arcs []Arc, skipped int) {
	m.arcs = arcs
	m.skipped = skipped
	m.refreshRows()
}

// ShowArchived reports whether the archived arcs are revealed.
func (m ListModel) ShowArchived() bool { return m.showArchived }

// visibleArcs returns the arcs the list currently shows. Every bucket shows
// everything in it: a live arc is always visible, however old — an arc still
// open past a week is the thing this view exists to keep in front of you — and
// a closed arc stays listed until it archives. Only an archived arc is hidden,
// until the toggle reveals it. Both the rendered rows and the tab count read
// from here so they cannot disagree.
func (m ListModel) visibleArcs() []Arc {
	var visible []Arc
	for _, a := range m.arcs {
		if a.Status == StatusArchived && !m.showArchived {
			continue
		}
		visible = append(visible, a)
	}
	return visible
}

// refreshRows rebuilds the row set: the recency buckets newest-first, each
// under a counted header, then the archived arcs under their own terminal
// header. Arcs keep scan order within a bucket, which is already recency order.
// A header renders only with rows beneath it, so no section ever announces an
// emptiness.
func (m *ListModel) refreshRows() {
	now := time.Now()
	buckets := map[Bucket][]Arc{}
	var archived []Arc
	for _, a := range m.visibleArcs() {
		if a.Status == StatusArchived {
			archived = append(archived, a)
			continue
		}
		b := a.BucketAt(now)
		buckets[b] = append(buckets[b], a)
	}

	var rows []collection.Row
	for _, b := range []Bucket{BucketToday, BucketThisWeek, BucketOlder} {
		members := buckets[b]
		if len(members) == 0 {
			continue
		}
		rows = append(rows, collection.Row{
			Header: true,
			Title: collection.Cell{
				Text:  fmt.Sprintf("%s (%d)", b.Label(), len(members)),
				Style: sectionHeaderStyle,
			},
		})
		for _, a := range members {
			rows = append(rows, arcRow(a, b))
		}
	}
	if len(archived) > 0 {
		rows = append(rows, collection.Row{
			Header: true,
			Title: collection.Cell{
				Text:  fmt.Sprintf("Archived (%d)", len(archived)),
				Style: sectionHeaderStyle,
			},
		})
		for _, a := range archived {
			rows = append(rows, arcRow(a, a.BucketAt(now)))
		}
	}

	empty := "  No coordination arcs.\n\n  `lore arc open` starts one."
	if m.skipped > 0 {
		empty += fmt.Sprintf("\n\n  %d unreadable record(s) skipped.", m.skipped)
	}
	m.list.SetEmptyText(empty)
	m.list.SetRows(rows)
}

// arcRow maps an arc to a collection row: cells parallel to listColumns for
// the columnar table, Title+Meta for the stacked narrow layout. bucket styles
// the state badge and, for a closed arc, fades the whole row along the ramp.
func arcRow(a Arc, bucket Bucket) collection.Row {
	body := style.Dim
	slug := collection.Cell{Text: a.Slug}
	if a.Status == StatusClosed {
		body = closedRamp(bucket)
		slug.Style = body
	}
	project := collection.Cell{Text: a.Project, Style: body}
	if a.Project == "" {
		project.Text = noProjectCell
	}
	state := collection.Cell{Text: stateLabel(a.Status), Style: stateStyle(a.Status, bucket)}
	age := collection.Cell{Text: work.FormatRelativeTime(a.Recency()), Style: body}
	items := collection.Cell{Text: fmt.Sprintf("%d", a.Items), Style: body}

	meta := []collection.Cell{state, age, {Text: fmt.Sprintf("%d items", a.Items), Style: body}}
	if a.Title != "" && a.Title != a.Slug {
		meta = append(meta, collection.Cell{Text: a.Title, Style: style.Dim})
	}
	return collection.Row{
		ID:    a.Slug,
		Cells: []collection.Cell{slug, state, age, items, project},
		Title: slug,
		Meta:  meta,
	}
}

func (m ListModel) Init() tea.Cmd { return nil }

func (m ListModel) Update(msg tea.Msg) (ListModel, tea.Cmd) {
	if km, ok := msg.(tea.KeyPressMsg); ok {
		switch km.String() {
		case "ctrl+a":
			m.showArchived = !m.showArchived
			m.refreshRows()
			m.list.CursorToFirstItem()
			return m, nil
		case "j", "down", "k", "up":
			l, cmd := m.list.Update(msg)
			m.list = l
			return m, tea.Batch(cmd, m.skipHeaders(msg))
		}
	}
	l, cmd := m.list.Update(msg)
	m.list = l
	return m, cmd
}

// skipHeaders steps the cursor off a header row and returns the commands the
// moves produced. Headers are dividers, not destinations: the cursor must
// always name an arc so the detail never loses its selection mid-list.
//
// It keeps going in the direction of travel and reverses only when that
// direction runs out of list. The first row is always a header and the engine's
// cursor moves clamp at both ends, so an upward step that lands there has no
// further up to travel and is recovered by resuming downward — not by jumping
// across the whole list on one keypress. Looping rather than stepping once also
// holds when two headers end up adjacent.
func (m *ListModel) skipHeaders(travel tea.Msg) tea.Cmd {
	var cmds []tea.Cmd
	step := func(msg tea.Msg) bool {
		before := m.list.Cursor()
		l, cmd := m.list.Update(msg)
		m.list = l
		cmds = append(cmds, cmd)
		return m.list.Cursor() != before
	}
	onHeader := func() bool {
		row, ok := m.list.CurrentRow()
		return ok && row.Header
	}
	for onHeader() && step(travel) {
	}
	if onHeader() {
		back := reverseTravel(travel)
		for onHeader() && step(back) {
		}
	}
	return tea.Batch(cmds...)
}

// reverseTravel returns the cursor move opposite to a j/k/up/down key press.
func reverseTravel(msg tea.Msg) tea.Msg {
	if km, ok := msg.(tea.KeyPressMsg); ok {
		switch km.String() {
		case "j", "down":
			return tea.KeyPressMsg{Code: tea.KeyUp}
		case "k", "up":
			return tea.KeyPressMsg{Code: tea.KeyDown}
		}
	}
	return msg
}

func (m ListModel) View() string { return m.list.View() }

// CurrentSlug returns the arc slug under the cursor, or "" on an empty list.
func (m ListModel) CurrentSlug() string { return m.list.CurrentID() }

// ArcBySlug returns the arc with the given slug, searching the full set so an
// archived arc still resolves while the section is hidden.
func (m ListModel) ArcBySlug(slug string) (Arc, bool) {
	if slug == "" {
		return Arc{}, false
	}
	for _, a := range m.arcs {
		if a.Slug == slug {
			return a, true
		}
	}
	return Arc{}, false
}

// CurrentArc returns the arc under the cursor and whether one exists.
func (m ListModel) CurrentArc() (Arc, bool) { return m.ArcBySlug(m.CurrentSlug()) }

// Count is the number of arcs currently listed. It feeds the tab indicator,
// which should read as "arcs in front of you", not "records on disk".
func (m ListModel) Count() int { return len(m.visibleArcs()) }

// Arcs returns the full arc set, including archived arcs.
func (m ListModel) Arcs() []Arc { return m.arcs }
