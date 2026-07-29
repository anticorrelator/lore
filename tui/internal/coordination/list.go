package coordination

import (
	"fmt"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/collection"
	"github.com/anticorrelator/lore/tui/internal/style"
)

// ArcSelectedMsg is emitted when Enter lands on an arc row. The host focuses
// the detail panel and loads the arc.
type ArcSelectedMsg struct {
	Slug string
}

var listColumns = []collection.Column{
	{Key: "arc", Title: "ARC", Width: 24, Priority: 0, Flex: true},
	{Key: "project", Title: "PROJECT", Width: 18, Priority: 2},
	{Key: "items", Title: "ITEMS", Width: 6, Priority: 1},
}

// noProjectCell is what an arc with no project label shows in the PROJECT
// column. Project is a label an arc may simply not carry.
const noProjectCell = "—"

// ListModel is the arc list panel: a collection.List consumer backed by a
// host-supplied arc set. Arcs render as flat rows under section headers, so
// the cursor rests only on arcs — collection.List skips headers by
// construction.
type ListModel struct {
	arcs []Arc
	// showArchived reveals the Archived section. Archived arcs are the
	// majority of the store and would drown the live set by default.
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

// ShowArchived reports whether the Archived section is revealed.
func (m ListModel) ShowArchived() bool { return m.showArchived }

// refreshRows rebuilds the row set: one header per non-empty section, then
// that section's arcs in scan order.
func (m *ListModel) refreshRows() {
	sections := []struct {
		label string
		match func(Arc) bool
	}{
		{SectionActive, func(a Arc) bool { return a.Status == StatusActive }},
		{SectionComplete, func(a Arc) bool { return a.Status == StatusClosed }},
	}
	if m.showArchived {
		sections = append(sections, struct {
			label string
			match func(Arc) bool
		}{"Archived", func(a Arc) bool { return a.Status == StatusArchived }})
	}

	var rows []collection.Row
	for _, section := range sections {
		var members []Arc
		for _, a := range m.arcs {
			if section.match(a) {
				members = append(members, a)
			}
		}
		if len(members) == 0 {
			continue
		}
		rows = append(rows, collection.Row{
			Header: true,
			Title:  collection.Cell{Text: fmt.Sprintf("%s (%d)", section.label, len(members))},
		})
		for _, a := range members {
			rows = append(rows, arcRow(a))
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
// the columnar table, Title+Meta for the stacked narrow layout.
func arcRow(a Arc) collection.Row {
	project := collection.Cell{Text: a.Project, Style: style.Dim}
	if a.Project == "" {
		project.Text = noProjectCell
	}
	meta := []collection.Cell{{Text: fmt.Sprintf("%d items", a.Items), Style: style.Dim}}
	if a.Title != "" && a.Title != a.Slug {
		meta = append(meta, collection.Cell{Text: a.Title, Style: style.Dim})
	}
	return collection.Row{
		ID: a.Slug,
		Cells: []collection.Cell{
			{Text: a.Slug},
			project,
			{Text: fmt.Sprintf("%d", a.Items), Style: style.Dim},
		},
		Title: collection.Cell{Text: a.Slug},
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
			// Section headers are dividers, not destinations: step past one so
			// the cursor always names an arc and the detail never loses its
			// selection mid-list.
			if row, ok := m.list.CurrentRow(); ok && row.Header {
				before := m.list.Cursor()
				l, cmd2 := m.list.Update(msg)
				m.list = l
				cmd = tea.Batch(cmd, cmd2)
				if m.list.Cursor() == before {
					// The first row is a header, so moving up ran out of list.
					m.list.CursorToFirstItem()
				}
			}
			return m, cmd
		}
	}
	l, cmd := m.list.Update(msg)
	m.list = l
	return m, cmd
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

// Count is the number of arcs currently listed — the live set unless the
// archived section is revealed. It feeds the tab indicator, which should read
// as "arcs in front of you", not "records on disk".
func (m ListModel) Count() int {
	n := 0
	for _, a := range m.arcs {
		if a.Status == StatusArchived && !m.showArchived {
			continue
		}
		n++
	}
	return n
}

// Arcs returns the full arc set, including archived arcs.
func (m ListModel) Arcs() []Arc { return m.arcs }
