package followup

import (
	"fmt"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/collection"
	"github.com/anticorrelator/lore/tui/internal/style"

	"github.com/anticorrelator/lore/tui/internal/work"
)

// FollowUpSelectedMsg is sent when the user presses Enter on a follow-up item.
type FollowUpSelectedMsg struct {
	Item FollowUpItem
}

// LoadDetailMsg is sent when the cursor moves to a new item (hover-prefetch).
type LoadDetailMsg struct {
	ID string
}

// FollowUpFilterMode controls which follow-up items are shown in the list.
type FollowUpFilterMode int

const (
	// FilterOpen shows only open/pending follow-ups (default).
	FilterOpen FollowUpFilterMode = iota
	// FilterClosed shows reviewed, promoted, and dismissed follow-ups.
	FilterClosed
)

// listColumns is the follow-up table's column set. The slug absorbs spare
// width; lower-priority columns drop as the panel narrows.
var listColumns = []collection.Column{
	{Key: "slug", Title: "SLUG", Width: 16, Priority: 0, Flex: true},
	{Key: "status", Title: "STATUS", Width: 9, Priority: 1},
	{Key: "source", Title: "SOURCE", Width: 14, Priority: 3},
	{Key: "pr", Title: "PR", Width: 8, Priority: 5},
	{Key: "work", Title: "WORK ITEM", Width: 20, Priority: 4},
	{Key: "updated", Title: "UPDATED", Width: 10, Priority: 2},
}

// ListModel is the Bubble Tea model for the follow-up list panel.
type ListModel struct {
	allItems   []FollowUpItem
	filterMode FollowUpFilterMode
	list       collection.List
}

// NewListModel creates a follow-up list model from pre-loaded items.
func NewListModel(items []FollowUpItem) ListModel {
	m := ListModel{
		allItems: items,
		list:     collection.NewList(listColumns),
	}
	m.list.SetOnCursorChange(func(id string) tea.Cmd {
		return func() tea.Msg { return LoadDetailMsg{ID: id} }
	})
	m.refreshRows()
	return m
}

// SetItems replaces the item list (used on live-reload).
func (m *ListModel) SetItems(items []FollowUpItem) {
	m.allItems = items
	m.refreshRows()
}

// refreshRows rebuilds the collection rows (and the select hook's item
// snapshot) from the current items and filter mode.
func (m *ListModel) refreshRows() {
	items := m.visibleItems()
	rows := make([]collection.Row, len(items))
	for i, item := range items {
		rows[i] = itemRow(item)
	}

	label := "active"
	if m.filterMode == FilterClosed {
		label = "closed"
	}
	m.list.SetEmptyText(fmt.Sprintf("  No %s follow-ups.  (ctrl+a to switch)", label))

	m.list.SetOnSelect(func(r collection.Row) tea.Cmd {
		for _, item := range items {
			if item.ID == r.ID {
				return func() tea.Msg { return FollowUpSelectedMsg{Item: item} }
			}
		}
		return nil
	})
	m.list.SetRows(rows)
}

// itemRow maps a follow-up item to a collection row: cells parallel to
// listColumns for the columnar table, Title+Meta for the stacked layout.
func itemRow(item FollowUpItem) collection.Row {
	glyph, glyphStyle := statusGlyph(item.Status)

	pr := item.PRRef()
	if pr == "" {
		pr = "--"
	}
	wi := item.WorkItemRef()
	if wi == "" {
		wi = "--"
	}
	updated := work.FormatRelativeTime(item.Updated)
	if updated == item.Updated {
		updated = "--"
	}

	row := collection.Row{
		ID: item.ID,
		Cells: []collection.Cell{
			{Text: item.ID},
			{Text: glyph + " " + item.Status, Style: glyphStyle},
			{Text: item.Source, Style: style.Dim},
			{Text: pr, Style: style.Dim},
			{Text: wi, Style: style.Dim},
			{Text: updated, Style: style.Dim},
		},
		Title: collection.Cell{Text: item.ID},
		Meta: []collection.Cell{
			{Text: glyph, Style: glyphStyle},
			{Text: style.Truncate(item.Source, 20), Style: style.Dim},
		},
	}
	if updated != "--" {
		row.Meta = append(row.Meta, collection.Cell{Text: updated, Style: style.Dim})
	}
	if p := item.PRRef(); p != "" {
		row.Meta = append(row.Meta, collection.Cell{Text: p, Style: style.Dim})
	}
	if w := item.WorkItemRef(); w != "" {
		row.Meta = append(row.Meta, collection.Cell{Text: w, Style: style.Dim})
	}
	return row
}

// visibleItems returns follow-up items matching the current filter mode.
func (m ListModel) visibleItems() []FollowUpItem {
	var out []FollowUpItem
	for _, item := range m.allItems {
		if m.filterMode == FilterClosed {
			if item.Status == "reviewed" || item.Status == "promoted" || item.Status == "dismissed" {
				out = append(out, item)
			}
		} else {
			if item.Status == "open" || item.Status == "pending" {
				out = append(out, item)
			}
		}
	}
	return out
}

// GetFilterMode returns the current filter mode.
func (m ListModel) GetFilterMode() FollowUpFilterMode {
	return m.filterMode
}

// Items returns the currently visible (filtered) follow-up items.
func (m ListModel) Items() []FollowUpItem {
	return m.visibleItems()
}

// FollowUpCount returns the number of currently visible (filtered) follow-up items.
func (m ListModel) FollowUpCount() int {
	return len(m.visibleItems())
}

// Cursor returns the current cursor position.
func (m ListModel) Cursor() int {
	return m.list.Cursor()
}

// CurrentID returns the ID of the currently highlighted item, or "" if empty.
func (m ListModel) CurrentID() string {
	return m.list.CurrentID()
}

// CurrentItem returns the currently highlighted item and whether one exists.
func (m ListModel) CurrentItem() (FollowUpItem, bool) {
	items := m.visibleItems()
	cursor := m.list.Cursor()
	if len(items) == 0 || cursor >= len(items) {
		return FollowUpItem{}, false
	}
	return items[cursor], true
}

func (m ListModel) Init() tea.Cmd {
	return nil
}

func (m ListModel) Update(msg tea.Msg) (ListModel, tea.Cmd) {
	if key, ok := msg.(tea.KeyPressMsg); ok {
		switch key.String() {
		case "ctrl+a":
			if m.filterMode == FilterOpen {
				m.filterMode = FilterClosed
			} else {
				m.filterMode = FilterOpen
			}
			m.refreshRows()
			m.list.CursorToFirstItem()
			return m, nil
		case "esc":
			return m, func() tea.Msg { return ListDismissedMsg{} }
		}
	}
	l, cmd := m.list.Update(msg)
	m.list = l
	return m, cmd
}

// statusGlyph returns a short indicator and the status-ramp style for the
// follow-up status.
func statusGlyph(status string) (string, lipgloss.Style) {
	switch status {
	case "open", "pending":
		return "○", style.StatusActive
	case "reviewed":
		return "◎", style.StatusModified
	case "promoted":
		return "●", style.StatusReady
	case "dismissed":
		return "✗", style.StatusDone
	default:
		return "?", style.StatusDone
	}
}

// SetCursorByID moves the cursor to the item with the given ID if it is visible.
func (m *ListModel) SetCursorByID(id string) {
	m.list.SetCursorByID(id)
}

func (m ListModel) View() string {
	return m.list.View()
}
