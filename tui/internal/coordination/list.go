package coordination

import (
	"fmt"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/collection"
	"github.com/anticorrelator/lore/tui/internal/coordination/board"
	"github.com/anticorrelator/lore/tui/internal/style"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// ArcSelectedMsg is emitted when Enter lands on an arc row. The host focuses
// the detail panel and loads the arc.
type ArcSelectedMsg struct {
	Slug string
}

// AttentionSelectedMsg is emitted when Enter lands on a cross-arc attention
// row. The host resolves both identities without widening either one.
type AttentionSelectedMsg struct {
	Bucket   board.AttentionBucket
	Arc      string
	StreamID string
}

var listColumns = []collection.Column{
	{Key: "arc", Title: "ARC", Width: 24, Priority: 0, Flex: true},
	{Key: "state", Title: "STATE", Width: 8, Priority: 1},
	{Key: "age", Title: "AGE", Width: 8, Priority: 1},
	{Key: "items", Title: "ITEMS", Width: 6, Priority: 2},
	{Key: "project", Title: "PROJECT", Width: 18, Priority: 3},
}

var attentionColumns = []collection.Column{
	{Key: "attention", Title: "ATTENTION", Width: 36, Priority: 0, Flex: true},
	{Key: "status", Title: "STATUS", Width: 16, Priority: 1},
	{Key: "gate", Title: "GATE", Width: 14, Priority: 1},
}

var attentionColumnsWithVerdict = []collection.Column{
	{Key: "attention", Title: "ATTENTION", Width: 36, Priority: 0, Flex: true},
	{Key: "status", Title: "STATUS", Width: 16, Priority: 1},
	{Key: "gate", Title: "GATE", Width: 14, Priority: 1},
	{Key: "verdict", Title: "VERDICT", Width: 16, Priority: 2},
}

const staleAttentionAfter = 7 * 24 * time.Hour

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
	coverage        string
	archiveCoverage string
	arcs            []Arc
	// showArchived reveals the Archived section. Archived arcs are filed away,
	// in the sense the key means; listed by default they would drown the live
	// set.
	showArchived bool
	// skipped counts store records the scan could not use.
	skipped int
	list    collection.List

	attention               collection.List
	attentionData           board.Attention
	attentionRows           map[string]board.AttentionRow
	staleAttentionID        string
	attentionLoaded         bool
	attentionErr            string
	attentionFocused        bool
	attentionActivity       map[string]string
	attentionActivityLoaded bool
	staleExpanded           map[board.AttentionBucket]bool
	width                   int
	height                  int
}

// NewListModel builds an empty arc list.
func NewListModel() ListModel {
	m := ListModel{
		list:              collection.NewList(listColumns),
		attention:         collection.NewList(attentionColumns),
		attentionData:     make(board.Attention),
		attentionRows:     make(map[string]board.AttentionRow),
		attentionActivity: make(map[string]string),
		staleExpanded:     make(map[board.AttentionBucket]bool),
		width:             80,
		height:            30,
	}
	m.list.SetDecorator(decorateHeaderRule)
	m.list.SetOnSelect(func(r collection.Row) tea.Cmd {
		if r.Header || r.ID == "" {
			return nil
		}
		slug := r.ID
		return func() tea.Msg { return ArcSelectedMsg{Slug: slug} }
	})
	m.attention.SetDecorator(decorateAttentionRow)
	m.attention.SetOnSelect(func(r collection.Row) tea.Cmd {
		bucket, arc, streamID, ok := parseAttentionID(r.ID)
		if r.Header || !ok {
			return nil
		}
		return func() tea.Msg {
			return AttentionSelectedMsg{Bucket: bucket, Arc: arc, StreamID: streamID}
		}
	})
	m.refreshRows()
	m.refreshAttentionRows()
	m.resizeLists()
	return m
}

// SetArcs replaces the arc set, preserving the cursor by slug. skipped is the
// scan's unusable-record count, surfaced in the empty text.
func (m *ListModel) SetArcs(arcs []Arc, skipped int) {
	m.arcs = arcs
	m.skipped = skipped
	m.refreshRows()
}

// SetAttention replaces the sparse action projection. The attention cursor is
// preserved by bucket, arc, and stream identity independently of the arc list.
// If its row disappeared, one stale row retains that identity until the user
// moves elsewhere or a later refresh restores it.
func (m *ListModel) SetAttention(attention board.Attention, err error) {
	if err != nil {
		m.attentionErr = err.Error()
		m.refreshAttentionRows()
		return
	}
	selectedID := m.attention.CurrentID()
	selected, hadSelected := m.attentionRows[selectedID]

	m.attentionLoaded = true
	m.attentionErr = ""
	m.staleAttentionID = ""
	m.attentionData = make(board.Attention, len(board.AttentionBucketOrder))
	m.attentionRows = make(map[string]board.AttentionRow)
	if err != nil {
		m.attentionErr = err.Error()
	} else {
		for _, bucket := range board.AttentionBucketOrder {
			m.attentionData[bucket] = append([]board.AttentionRow(nil), attention[bucket]...)
			for _, row := range attention[bucket] {
				m.attentionRows[attentionID(row)] = row
			}
		}
	}
	if hadSelected {
		if _, ok := m.attentionRows[selectedID]; !ok {
			m.attentionRows[selectedID] = selected
			m.attentionData[selected.Bucket] = append(m.attentionData[selected.Bucket], selected)
			m.staleAttentionID = selectedID
		}
	}
	m.refreshAttentionRows()
}

// SetAttentionActivity supplies the latest journal instant for each arc from
// the host's existing coordination-body journal read. A missing arc key is an
// explicit no-event state once this setter has been called.
func (m *ListModel) SetAttentionActivity(activity map[string]string) {
	m.attentionActivityLoaded = true
	m.attentionActivity = make(map[string]string, len(activity))
	for arc, instant := range activity {
		m.attentionActivity[arc] = instant
	}
	m.refreshAttentionRows()
}

// AttentionFocused reports which collection owns j/k and Enter in the top pane.
func (m ListModel) AttentionFocused() bool { return m.attentionFocused }

// ShowArcs returns the top pane to its primary arc listing without changing
// either collection's cursor.
func (m *ListModel) ShowArcs() { m.attentionFocused = false }

// Title is the top pane's title. The default arc-list state carries the sparse
// attention rollup at zero row cost; the swapped state names its own listing.
func (m ListModel) Title() string {
	if m.attentionFocused {
		return "Attention"
	}
	labels := map[board.AttentionBucket]string{
		board.ActNow: "act now", board.NeedsJudgment: "judgment",
		board.Waiting: "waiting", board.Reconcile: "reconcile",
	}
	var parts []string
	for _, bucket := range board.AttentionBucketOrder {
		if n := len(m.attentionData[bucket]); n > 0 {
			parts = append(parts, fmt.Sprintf("%d %s", n, labels[bucket]))
		}
	}
	if len(parts) == 0 {
		return "Coordination"
	}
	return "Coordination — ⚠ " + strings.Join(parts, " · ")
}

// CurrentAttention returns the exact attention identity under its cursor.
func (m ListModel) CurrentAttention() (board.AttentionBucket, string, string, bool) {
	return parseAttentionID(m.attention.CurrentID())
}

// SetCursorBySlug moves the arc cursor only when the arc is currently visible.
// A miss leaves the cursor unchanged so callers cannot land on a neighbor.
func (m *ListModel) SetCursorBySlug(slug string) bool { return m.list.SetCursorByID(slug) }

func attentionID(row board.AttentionRow) string {
	return string(row.Bucket) + "\x1f" + row.Arc + "\x1f" + row.StreamID
}

func parseAttentionID(id string) (board.AttentionBucket, string, string, bool) {
	parts := strings.SplitN(id, "\x1f", 3)
	if len(parts) != 3 || parts[0] == "" || parts[1] == "" || parts[2] == "" {
		return "", "", "", false
	}
	return board.AttentionBucket(parts[0]), parts[1], parts[2], true
}

func attentionBucketLabel(bucket board.AttentionBucket) string {
	switch bucket {
	case board.ActNow:
		return "Act now"
	case board.NeedsJudgment:
		return "Needs judgment"
	case board.Waiting:
		return "Waiting"
	case board.Reconcile:
		return "Reconcile"
	default:
		return explicit(string(bucket))
	}
}

func (m *ListModel) refreshAttentionRows() { m.refreshAttentionRowsAt(time.Now()) }

func (m *ListModel) refreshAttentionRowsAt(now time.Time) {
	var rows []collection.Row
	showVerdict := false
	for _, bucket := range board.AttentionBucketOrder {
		members := m.attentionData[bucket]
		label := attentionBucketLabel(bucket)
		switch {
		case m.attentionErr != "":
			label += " · unknown"
		case !m.attentionLoaded:
			label += " · loading"
		case len(members) == 0:
			label += " · none"
		default:
			label += fmt.Sprintf(" (%d)", len(members))
		}
		rows = append(rows, collection.Row{Header: true, Title: collection.Cell{Text: label, Style: sectionHeaderStyle}})
		var stale []board.AttentionRow
		for _, row := range members {
			if m.attentionRowIsStale(row, now) {
				stale = append(stale, row)
				continue
			}
			if verdictRevealsColumn(row.Verdict) {
				showVerdict = true
			}
			rows = append(rows, m.attentionRow(row, m.attentionErr != "" || attentionID(row) == m.staleAttentionID, false))
		}
		if len(stale) > 0 {
			expanded := m.staleExpanded[bucket]
			glyph := "▸"
			if expanded {
				glyph = "▾"
			}
			rows = append(rows, collection.Row{
				ID: staleFoldID(bucket), Title: collection.Cell{Text: fmt.Sprintf("%s stale (%d)", glyph, len(stale)), Style: style.Dim},
				Cells: []collection.Cell{{Text: fmt.Sprintf("%s stale (%d)", glyph, len(stale)), Style: style.Dim}},
			})
			if expanded {
				for _, row := range stale {
					if verdictRevealsColumn(row.Verdict) {
						showVerdict = true
					}
					rows = append(rows, m.attentionRow(row, m.attentionErr != "" || attentionID(row) == m.staleAttentionID, true))
				}
			}
		}
	}
	if showVerdict {
		for i := range rows {
			if _, _, _, ok := parseAttentionID(rows[i].ID); ok && len(rows[i].Cells) == len(attentionColumns) {
				rows[i].Cells = append(rows[i].Cells, collection.Cell{Text: unknown, Style: style.Dim})
				rows[i].Meta = append(rows[i].Meta, collection.Cell{Text: unknown, Style: style.Dim})
			}
		}
		m.attention.SetColumns(attentionColumnsWithVerdict)
	} else {
		for i := range rows {
			if _, _, _, ok := parseAttentionID(rows[i].ID); ok {
				rows[i].Cells = rows[i].Cells[:min(len(rows[i].Cells), len(attentionColumns))]
				rows[i].Meta = rows[i].Meta[:min(len(rows[i].Meta), len(attentionColumns)-1)]
			}
		}
		m.attention.SetColumns(attentionColumns)
	}
	m.attention.SetRows(rows)
}

func verdictRevealsColumn(verdict string) bool {
	verdict = strings.TrimSpace(verdict)
	return verdict != "" && verdict != "—"
}

func staleFoldID(bucket board.AttentionBucket) string { return "stale\x1f" + string(bucket) }

func parseStaleFoldID(id string) (board.AttentionBucket, bool) {
	if !strings.HasPrefix(id, "stale\x1f") {
		return "", false
	}
	bucket := board.AttentionBucket(strings.TrimPrefix(id, "stale\x1f"))
	return bucket, bucket != ""
}

func (m ListModel) attentionRowIsStale(row board.AttentionRow, now time.Time) bool {
	if !m.attentionActivityLoaded {
		return false
	}
	at, ok := parseInstant(m.attentionActivity[row.Arc])
	return !ok || at.Before(now.Add(-staleAttentionAfter))
}

func (m ListModel) attentionAge(arc string) string {
	if !m.attentionActivityLoaded {
		return "loading"
	}
	instant := m.attentionActivity[arc]
	if _, ok := parseInstant(instant); !ok {
		return unknown
	}
	return work.FormatRelativeTime(instant)
}

func (m ListModel) attentionRow(row board.AttentionRow, missing, dormant bool) collection.Row {
	label := explicit(row.Label)
	if label == unknown {
		label = explicit(row.Title)
	}
	title := fmt.Sprintf("%s · %s · %s", label, explicit(row.Arc), m.attentionAge(row.Arc))
	status := explicit(row.Status)
	gate := explicit(row.Gate)
	verdict := explicit(row.Verdict)
	if missing {
		title += " · stale/unknown target"
	}
	if dormant {
		title += " · stale"
	}
	cells := []collection.Cell{{Text: title}, {Text: status, Style: style.Dim}, {Text: gate, Style: style.Dim}}
	meta := []collection.Cell{{Text: status, Style: style.Dim}, {Text: gate, Style: style.Dim}}
	if strings.TrimSpace(row.Verdict) != "" {
		cells = append(cells, collection.Cell{Text: verdict, Style: style.Dim})
		meta = append(meta, collection.Cell{Text: verdict, Style: style.Dim})
	}
	return collection.Row{
		ID:    attentionID(row),
		Cells: cells,
		Title: collection.Cell{Text: title},
		Meta:  meta,
	}
}

func decorateAttentionRow(row collection.Row, selected bool, lines []string) []string {
	if row.Header {
		return lines
	}
	gate := ""
	if len(row.Meta) > 1 {
		gate = row.Meta[1].Text
	}
	styled := make([]string, len(lines))
	copy(styled, lines)
	for i, line := range styled {
		switch gate {
		case "hold":
			styled[i] = holdStyle.Render(line)
		case "flag":
			styled[i] = flagStyle.Render(line)
		}
		if !selected {
			_, arc, _, ok := parseAttentionID(row.ID)
			if ok {
				suffixAt := strings.Index(row.Title.Text, " · "+arc+" · ")
				if suffixAt >= 0 {
					suffix := row.Title.Text[suffixAt:]
					styled[i] = strings.Replace(styled[i], suffix, style.Dim.Render(suffix), 1)
				}
			}
		}
	}
	return styled
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
	if size, ok := msg.(tea.WindowSizeMsg); ok {
		m.width, m.height = size.Width, size.Height
		m.resizeLists()
		return m, nil
	}
	if km, ok := msg.(tea.KeyPressMsg); ok {
		switch km.String() {
		case "a":
			m.attentionFocused = !m.attentionFocused
			return m, nil
		case "h", "esc":
			if m.attentionFocused {
				m.attentionFocused = false
				return m, nil
			}
		case "enter":
			if m.attentionFocused {
				if bucket, ok := parseStaleFoldID(m.attention.CurrentID()); ok {
					m.staleExpanded[bucket] = !m.staleExpanded[bucket]
					m.refreshAttentionRows()
					return m, nil
				}
			}
		case "ctrl+a":
			m.showArchived = !m.showArchived
			m.refreshRows()
			m.list.CursorToFirstItem()
			return m, nil
		case "j", "down", "k", "up":
			if m.attentionFocused {
				attention, cmd := m.attention.Update(msg)
				m.attention = attention
				return m, tea.Batch(cmd, m.skipAttentionHeaders(msg))
			}
			l, cmd := m.list.Update(msg)
			m.list = l
			return m, tea.Batch(cmd, m.skipHeaders(msg))
		}
	}
	if m.attentionFocused {
		attention, cmd := m.attention.Update(msg)
		m.attention = attention
		return m, cmd
	}
	l, cmd := m.list.Update(msg)
	m.list = l
	return m, cmd
}

func (m *ListModel) resizeLists() {
	m.attention.SetSize(m.width, max(1, m.height))
	m.list.SetSize(m.width, max(1, m.height))
}

func (m *ListModel) skipAttentionHeaders(travel tea.Msg) tea.Cmd {
	var cmds []tea.Cmd
	step := func(msg tea.Msg) bool {
		before := m.attention.Cursor()
		attention, cmd := m.attention.Update(msg)
		m.attention = attention
		cmds = append(cmds, cmd)
		return m.attention.Cursor() != before
	}
	onHeader := func() bool {
		row, ok := m.attention.CurrentRow()
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

func (m ListModel) View() string {
	body := m.viewContent()
	if m.showArchived && m.archiveCoverage != "" {
		body = style.Dim.Render(m.archiveCoverage) + "\n" + body
	}
	if m.coverage != "" {
		return style.Dim.Render(m.coverage) + "\n" + body
	}
	return body
}

func (m ListModel) viewContent() string {
	if m.attentionFocused {
		if m.attentionErr != "" {
			return style.Dim.Render("  Attention unknown — "+m.attentionErr) + "\n" + m.attention.View()
		}
		return m.attention.View()
	}
	return m.list.View()
}

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

func (m *ListModel) SetCoverage(value string) { m.coverage = value }

func (m *ListModel) SetArchiveCoverage(value string) { m.archiveCoverage = value }
