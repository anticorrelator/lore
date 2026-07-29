package coordination

import (
	"fmt"
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

// BucketAt places the arc's Recency in a bucket. It is the same predicate the
// list headers, the closed-arc fold, and the quit-time archive offer use, so
// the three cannot disagree about what "older than a week" means.
func (a Arc) BucketAt(now time.Time) Bucket { return bucketOf(a.Recency(), now) }

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

// closedRamp fades a closed arc's row as its close recedes. It is indexed on
// the same bucket that drives the headers and the fold, so a row's dimness and
// its position always tell the same story.
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
	// showArchived reveals the Archived section and the closed arcs that have
	// aged out of the recency buckets. Both are filed away, in the sense the
	// key means; unfolded they would drown the live set.
	showArchived bool
	// skipped counts store records the scan could not use.
	skipped int
	list    collection.List
}

// NewListModel builds an empty arc list.
func NewListModel() ListModel {
	m := ListModel{list: collection.NewList(listColumns)}
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

// ShowArchived reports whether the archived arcs and the folded closed arcs
// are revealed.
func (m ListModel) ShowArchived() bool { return m.showArchived }

// visibleArcs returns the arcs the list currently shows. A live arc is always
// visible, however old — an arc still open past a week is the thing this view
// exists to keep in front of you. A closed arc folds away once it ages out of
// the recency buckets, and an archived arc is hidden until the toggle reveals
// it. Both the rendered rows and the tab count read from here so they cannot
// disagree.
func (m ListModel) visibleArcs(now time.Time) []Arc {
	var visible []Arc
	for _, a := range m.arcs {
		switch a.Status {
		case StatusArchived:
			if !m.showArchived {
				continue
			}
		case StatusClosed:
			if !m.showArchived && a.BucketAt(now) == BucketOlder {
				continue
			}
		}
		visible = append(visible, a)
	}
	return visible
}

// foldedCount counts the closed arcs the fold is currently hiding.
func (m ListModel) foldedCount(now time.Time) int {
	if m.showArchived {
		return 0
	}
	n := 0
	for _, a := range m.arcs {
		if a.Status == StatusClosed && a.BucketAt(now) == BucketOlder {
			n++
		}
	}
	return n
}

// refreshRows rebuilds the row set: the recency buckets newest-first, each
// under a counted header, then the archived arcs under their own terminal
// header. Arcs keep scan order within a bucket, which is already recency
// order. The Older header carries the fold notice when closed arcs are hidden,
// so rows never vanish without something pointing at the key that returns them.
func (m *ListModel) refreshRows() {
	now := time.Now()
	buckets := map[Bucket][]Arc{}
	var archived []Arc
	for _, a := range m.visibleArcs(now) {
		if a.Status == StatusArchived {
			archived = append(archived, a)
			continue
		}
		b := a.BucketAt(now)
		buckets[b] = append(buckets[b], a)
	}
	folded := m.foldedCount(now)

	var rows []collection.Row
	for _, b := range []Bucket{BucketToday, BucketThisWeek, BucketOlder} {
		members := buckets[b]
		notice := ""
		if b == BucketOlder && folded > 0 {
			notice = fmt.Sprintf(" · %d closed hidden — ctrl+a", folded)
		}
		if len(members) == 0 && notice == "" {
			continue
		}
		header := b.Label()
		if len(members) > 0 {
			header += fmt.Sprintf(" (%d)", len(members))
		}
		rows = append(rows, collection.Row{
			Header: true,
			Title:  collection.Cell{Text: header + notice},
		})
		for _, a := range members {
			rows = append(rows, arcRow(a, b))
		}
	}
	if len(archived) > 0 {
		rows = append(rows, collection.Row{
			Header: true,
			Title:  collection.Cell{Text: fmt.Sprintf("Archived (%d)", len(archived))},
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
// direction runs out of list. The Older header can be the last row when it
// carries a fold notice and no visible members, and the engine's cursor moves
// clamp at both ends, so a downward step that lands there cannot be recovered
// by jumping to the top — that would throw the cursor across the whole list on
// one keypress. Looping rather than stepping once also holds when two headers
// end up adjacent.
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

// ClosedArcs returns the arcs whose declared status is closed — the set the
// quit-time archive offer draws from. Already-archived arcs are excluded;
// there is nothing left to offer for them.
func (m ListModel) ClosedArcs() []Arc {
	var closed []Arc
	for _, a := range m.arcs {
		if a.Status == StatusClosed {
			closed = append(closed, a)
		}
	}
	return closed
}

// Count is the number of arcs currently listed. It feeds the tab indicator,
// which should read as "arcs in front of you", not "records on disk".
func (m ListModel) Count() int { return len(m.visibleArcs(time.Now())) }

// Arcs returns the full arc set, including archived arcs.
func (m ListModel) Arcs() []Arc { return m.arcs }
