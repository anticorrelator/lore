package followup

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

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

// StatusFilterMode controls which follow-up statuses are shown in the list.
type StatusFilterMode int

const (
	FilterActive   StatusFilterMode = iota // show open/pending follow-ups
	FilterArchived                         // show reviewed/promoted/dismissed follow-ups
)

// ListModel is the Bubble Tea model for the follow-up list panel.
type ListModel struct {
	allItems    []FollowUpItem
	filter      StatusFilterMode
	cursor      int
	compactMode bool
	width       int
	height      int
	err         error
}

// NewListModel creates a follow-up list model from pre-loaded items.
func NewListModel(items []FollowUpItem) ListModel {
	return ListModel{
		allItems: items,
		filter:   FilterActive,
		cursor:   0,
	}
}

// SetItems replaces the item list (used on live-reload).
func (m *ListModel) SetItems(items []FollowUpItem) {
	m.allItems = items
	if m.cursor >= len(m.visibleItems()) {
		m.cursor = 0
	}
}

// visibleItems returns items matching the current filter.
func (m ListModel) visibleItems() []FollowUpItem {
	var out []FollowUpItem
	for _, item := range m.allItems {
		switch m.filter {
		case FilterActive:
			if item.Status == "open" || item.Status == "pending" {
				out = append(out, item)
			}
		case FilterArchived:
			if item.Status == "reviewed" || item.Status == "promoted" || item.Status == "dismissed" {
				out = append(out, item)
			}
		}
	}
	return out
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
	return m.cursor
}

// CurrentID returns the ID of the currently highlighted item, or "" if empty.
func (m ListModel) CurrentID() string {
	items := m.visibleItems()
	if len(items) == 0 || m.cursor >= len(items) {
		return ""
	}
	return items[m.cursor].ID
}

// CurrentItem returns the currently highlighted item and whether one exists.
func (m ListModel) CurrentItem() (FollowUpItem, bool) {
	items := m.visibleItems()
	if len(items) == 0 || m.cursor >= len(items) {
		return FollowUpItem{}, false
	}
	return items[m.cursor], true
}

func (m ListModel) Init() tea.Cmd {
	return nil
}

func (m ListModel) Update(msg tea.Msg) (ListModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

	case tea.KeyMsg:
		items := m.visibleItems()
		prevCursor := m.cursor
		switch msg.String() {
		case "esc":
			return m, func() tea.Msg { return ListDismissedMsg{} }
		case "ctrl+a":
			// Toggle filter: active ↔ archived
			if m.filter == FilterActive {
				m.filter = FilterArchived
			} else {
				m.filter = FilterActive
			}
			m.cursor = 0
			items = m.visibleItems()
			if len(items) > 0 {
				return m, func() tea.Msg { return LoadDetailMsg{ID: items[0].ID} }
			}
			return m, nil

		case "j", "down":
			if m.cursor < len(items)-1 {
				m.cursor++
			}
		case "k", "up":
			if m.cursor > 0 {
				m.cursor--
			}
		case "g", "home":
			m.cursor = 0
		case "G", "end":
			if len(items) > 0 {
				m.cursor = len(items) - 1
			}
		case "enter":
			if len(items) > 0 {
				item := items[m.cursor]
				return m, func() tea.Msg {
					return FollowUpSelectedMsg{Item: item}
				}
			}
		}

		// Emit hover-prefetch when cursor moves
		if m.cursor != prevCursor && len(items) > 0 && m.cursor < len(items) {
			id := items[m.cursor].ID
			return m, func() tea.Msg { return LoadDetailMsg{ID: id} }
		}
	}
	return m, nil
}

// statusGlyph returns a short indicator for the follow-up status.
func statusGlyph(status string) (string, lipgloss.Color) {
	switch status {
	case "open", "pending":
		return "○", lipgloss.Color("4") // blue circle
	case "reviewed":
		return "◎", lipgloss.Color("6") // cyan
	case "promoted":
		return "●", lipgloss.Color("2") // green
	case "dismissed":
		return "✗", lipgloss.Color("8") // dim
	default:
		return "?", lipgloss.Color("8")
	}
}

// SetCursorByID moves the cursor to the item with the given ID if it is visible.
func (m *ListModel) SetCursorByID(id string) {
	for i, item := range m.visibleItems() {
		if item.ID == id {
			m.cursor = i
			return
		}
	}
}

// SetCompactMode enables or disables compact rendering.
func (m *ListModel) SetCompactMode(compact bool) {
	m.compactMode = compact
}

// GetFilterLabel returns a short display label for the current filter mode.
func (m ListModel) GetFilterLabel() string {
	return m.filterLabel()
}

// filterLabel returns a short display label for the current filter mode.
func (m ListModel) filterLabel() string {
	if m.filter == FilterArchived {
		return "archived"
	}
	return "active"
}

func (m ListModel) View() string {
	if m.err != nil {
		return fmt.Sprintf("Error loading follow-ups: %v\n", m.err)
	}

	if m.compactMode {
		return m.viewCompact()
	}
	return m.viewFull()
}

// viewFull renders the full-width columnar table with one row per item.
func (m ListModel) viewFull() string {
	var b strings.Builder

	// Column widths — ID absorbs spare space.
	statusW := 9  // "dismissed" = 9 chars
	sourceW := 14
	prW := 8
	workW := 20
	updatedW := 10
	idW := 30 // default; grows to fill terminal width

	// Adapt to terminal width: ID absorbs all spare space.
	// Fixed: status(9) + source(14) + pr(8) + work(20) + updated(10) + gaps(14) = 75
	// Gaps: 2 leading + 6 pairs of "  " separators = 14 chars.
	if m.width > 0 {
		idW = m.width - statusW - sourceW - prW - workW - updatedW - 14
		if idW < 16 {
			idW = 16
		}
	}

	// Styles
	headerStyle := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("4"))
	selectedStyle := lipgloss.NewStyle().Background(lipgloss.Color("237")).Bold(true)
	dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))

	// Header
	header := fmt.Sprintf("  %-*s  %-*s  %-*s  %-*s  %-*s  %-*s",
		idW, "ID",
		statusW, "STATUS",
		sourceW, "SOURCE",
		prW, "PR",
		workW, "WORK ITEM",
		updatedW, "UPDATED",
	)
	b.WriteString(headerStyle.Render(header))
	b.WriteString("\n")

	items := m.visibleItems()

	// Visible rows (reserve 1 line for header)
	visibleRows := m.height - 1
	if visibleRows < 1 {
		visibleRows = len(items)
	}

	// Scrolling: keep cursor visible
	offset := 0
	if m.cursor >= visibleRows {
		offset = m.cursor - visibleRows + 1
	}

	end := offset + visibleRows
	if end > len(items) {
		end = len(items)
	}

	for i := offset; i < end; i++ {
		item := items[i]

		// ID (title preferred, falls back to ID)
		idStr := item.Title
		if idStr == "" {
			idStr = item.ID
		}
		idStr = truncateFollowUp(idStr, idW)

		// Status with glyph
		glyph, glyphColor := statusGlyph(item.Status)
		statusStr := lipgloss.NewStyle().Foreground(glyphColor).Render(glyph + " " + truncateFollowUp(item.Status, statusW-2))

		// Source
		source := dimStyle.Render(truncateFollowUp(item.Source, sourceW))

		// PR ref
		prStr := "--"
		if pr := item.PRRef(); pr != "" {
			prStr = pr
		}
		prCell := dimStyle.Render(truncateFollowUp(prStr, prW))

		// Work item ref
		wiStr := "--"
		if wi := item.WorkItemRef(); wi != "" {
			wiStr = wi
		}
		wiCell := dimStyle.Render(truncateFollowUp(wiStr, workW))

		// Updated
		updated := work.FormatRelativeTime(item.Updated)
		if updated == item.Updated {
			updated = "--"
		}
		updatedCell := dimStyle.Render(truncateFollowUp(updated, updatedW))

		row := fmt.Sprintf("  %-*s  %s%s  %s%s  %s%s  %s%s  %s",
			idW, idStr,
			statusStr, strings.Repeat(" ", max(0, statusW-lipgloss.Width(statusStr))),
			source, strings.Repeat(" ", max(0, sourceW-lipgloss.Width(source))),
			prCell, strings.Repeat(" ", max(0, prW-lipgloss.Width(prCell))),
			wiCell, strings.Repeat(" ", max(0, workW-lipgloss.Width(wiCell))),
			updatedCell,
		)

		if i == m.cursor {
			row = selectedStyle.Render(row)
		}

		b.WriteString(row)
		b.WriteString("\n")
	}

	return b.String()
}

// viewCompact renders the compact split-pane list with two lines per item.
func (m ListModel) viewCompact() string {
	items := m.visibleItems()
	var b strings.Builder

	dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))

	if len(items) == 0 {
		b.WriteString(dimStyle.Render(fmt.Sprintf("  No %s follow-ups.  (ctrl+a to switch)", m.filterLabel())))
		b.WriteString("\n")
		return b.String()
	}

	titleSelStyle := lipgloss.NewStyle().Background(lipgloss.Color("237")).Bold(true)
	infoSelStyle := lipgloss.NewStyle().Background(lipgloss.Color("237"))

	// Compute panel width (default 40 for split-pane use)
	panelWidth := m.width
	if panelWidth <= 0 {
		panelWidth = 40
	}

	// Each item occupies 2 lines: title + metadata
	visibleCount := m.height / 2
	if visibleCount < 1 {
		visibleCount = len(items)
	}

	offset := 0
	if m.cursor >= visibleCount {
		offset = m.cursor - visibleCount + 1
	}

	end := offset + visibleCount
	if end > len(items) {
		end = len(items)
	}

	for i := offset; i < end; i++ {
		item := items[i]
		selected := i == m.cursor

		cursor := "  "
		if selected {
			cursor = "> "
		}

		// Title line
		titleAvail := panelWidth - 2 // 2 cursor chars
		title := item.Title
		if title == "" {
			title = item.ID
		}
		titleTrunc := truncateFollowUp(title, titleAvail)

		line1 := cursor + titleTrunc
		for lipgloss.Width(line1) < panelWidth {
			line1 += " "
		}

		// Metadata line: status glyph + source + relative time [+ PR ref] [+ work item ref]
		glyph, glyphColor := statusGlyph(item.Status)
		statusStr := lipgloss.NewStyle().Foreground(glyphColor).Render(glyph)
		sourceStr := dimStyle.Render(truncateFollowUp(item.Source, 20))
		sep := dimStyle.Render(" · ")
		line2 := "    " + statusStr + sep + sourceStr
		if relTime := work.FormatRelativeTime(item.Updated); relTime != "" && relTime != item.Updated {
			line2 += sep + dimStyle.Render(relTime)
		}
		if pr := item.PRRef(); pr != "" {
			line2 += sep + dimStyle.Render(pr)
		}
		if wi := item.WorkItemRef(); wi != "" {
			line2 += sep + dimStyle.Render(wi)
		}
		for lipgloss.Width(line2) < panelWidth {
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

// truncateFollowUp truncates s to maxW visible columns using an ellipsis.
func truncateFollowUp(s string, maxW int) string {
	if maxW <= 0 {
		return ""
	}
	if lipgloss.Width(s) <= maxW {
		return s
	}
	runes := []rune(s)
	if maxW <= 1 {
		return "…"
	}
	for i := len(runes) - 1; i >= 0; i-- {
		candidate := string(runes[:i]) + "…"
		if lipgloss.Width(candidate) <= maxW {
			return candidate
		}
	}
	return "…"
}
