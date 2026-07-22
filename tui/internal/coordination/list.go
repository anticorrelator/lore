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
	{Key: "items", Title: "ITEMS", Width: 6, Priority: 1},
}

// ListModel is the arc list panel: a collection.List consumer backed by a
// host-supplied arc set. Every row is an item, never a header, so the cursor
// always rests on a selectable arc and detail sync never stalls.
type ListModel struct {
	arcs []Arc
	list collection.List
}

// NewListModel builds an empty arc list.
func NewListModel() ListModel {
	m := ListModel{list: collection.NewList(listColumns)}
	m.list.SetEmptyText("  No coordination arcs.\n\n  A project becomes an arc when its home\n  gains a coordination.md ledger.")
	m.list.SetOnSelect(func(r collection.Row) tea.Cmd {
		if r.Header || r.ID == "" {
			return nil
		}
		slug := r.ID
		return func() tea.Msg { return ArcSelectedMsg{Slug: slug} }
	})
	return m
}

// SetArcs replaces the arc set, preserving the cursor by slug.
func (m *ListModel) SetArcs(arcs []Arc) {
	m.arcs = arcs
	rows := make([]collection.Row, 0, len(arcs))
	for _, a := range arcs {
		rows = append(rows, collection.Row{
			ID: a.Slug,
			Cells: []collection.Cell{
				{Text: a.Slug},
				{Text: fmt.Sprintf("%d", a.Members), Style: style.Dim},
			},
			Title: collection.Cell{Text: a.Slug},
			Meta:  []collection.Cell{{Text: fmt.Sprintf("%d items", a.Members), Style: style.Dim}},
		})
	}
	m.list.SetRows(rows)
}

func (m ListModel) Init() tea.Cmd { return nil }

func (m ListModel) Update(msg tea.Msg) (ListModel, tea.Cmd) {
	l, cmd := m.list.Update(msg)
	m.list = l
	return m, cmd
}

func (m ListModel) View() string { return m.list.View() }

// CurrentSlug returns the arc slug under the cursor, or "" on an empty list.
func (m ListModel) CurrentSlug() string { return m.list.CurrentID() }

// Count is the number of arcs.
func (m ListModel) Count() int { return len(m.arcs) }
