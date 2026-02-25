package search

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// PopupItem represents a single item in the popup list.
type PopupItem struct {
	ID       string
	Label    string
	Subtitle string
	Data     interface{}
}

// PopupSelectedMsg is sent when the user selects a popup item.
type PopupSelectedMsg struct {
	Item PopupItem
}

// PopupDismissedMsg is sent when the user dismisses the popup.
type PopupDismissedMsg struct{}

// PopupModel is a reusable fuzzy-search popup overlay.
type PopupModel struct {
	input    textinput.Model
	title    string
	items    []PopupItem
	filtered []PopupItem
	cursor   int
	width    int
	height   int
}

// New creates a PopupModel with the given items and title.
func New(items []PopupItem, title string) PopupModel {
	ti := textinput.New()
	ti.Placeholder = "Type to filter..."
	ti.Focus()
	ti.CharLimit = 200
	ti.Width = 60

	m := PopupModel{
		input:    ti,
		title:    title,
		items:    items,
		filtered: items,
		cursor:   0,
	}
	return m
}

// Init returns the initial command for the popup.
func (m PopupModel) Init() tea.Cmd {
	return textinput.Blink
}

// filter updates m.filtered with items matching query via case-insensitive
// substring match against Label and Subtitle. Resets cursor to 0.
func (m *PopupModel) filter(query string) {
	if query == "" {
		m.filtered = m.items
	} else {
		q := strings.ToLower(query)
		var matched []PopupItem
		for _, item := range m.items {
			target := strings.ToLower(item.Label + item.Subtitle)
			if strings.Contains(target, q) {
				matched = append(matched, item)
			}
		}
		m.filtered = matched
	}
	m.cursor = 0
	if len(m.filtered) > 0 && m.cursor >= len(m.filtered) {
		m.cursor = len(m.filtered) - 1
	}
}

// SetSize updates the popup dimensions for resize propagation.
func (m *PopupModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	m.input.Width = w - 8
}

// InputValue returns the current textinput value.
func (m PopupModel) InputValue() string {
	return m.input.Value()
}

// SetItems replaces the popup's item list and re-applies filtering.
func (m *PopupModel) SetItems(items []PopupItem) {
	m.items = items
	m.filter(m.input.Value())
}

// Update handles key events for the popup. Esc dismisses, Enter selects,
// j/k (or down/up) navigate, and all other input goes to the textinput.
func (m PopupModel) Update(msg tea.Msg) (PopupModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "esc":
			return m, func() tea.Msg { return PopupDismissedMsg{} }

		case "enter":
			if len(m.filtered) > 0 && m.cursor >= 0 && m.cursor < len(m.filtered) {
				return m, func() tea.Msg { return PopupSelectedMsg{Item: m.filtered[m.cursor]} }
			}
			return m, nil

		case "down", "j":
			if len(m.filtered) > 0 {
				m.cursor++
				if m.cursor >= len(m.filtered) {
					m.cursor = len(m.filtered) - 1
				}
			}
			return m, nil

		case "up", "k":
			if m.cursor > 0 {
				m.cursor--
			}
			return m, nil
		}
	}

	// Pass all other messages to textinput.
	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)

	// Re-filter on input change.
	m.filter(m.input.Value())

	return m, cmd
}

// maxPopupResults is the maximum number of result rows shown in the popup.
const maxPopupResults = 10

// View renders the popup as a bordered box containing the title, text input,
// and filtered results list. The caller is responsible for centering via
// lipgloss.Place().
func (m PopupModel) View() string {
	// Styles consistent with main.go modal conventions.
	borderColor := lipgloss.Color("4")
	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(borderColor)
	dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	selectedStyle := lipgloss.NewStyle().Background(lipgloss.Color("237")).Bold(true)

	// Box width: fit within available space, cap at 80 for readability.
	boxW := m.width - 4
	if boxW > 80 {
		boxW = 80
	}
	if boxW < 30 {
		boxW = 30
	}

	var b strings.Builder

	// Title
	b.WriteString(titleStyle.Render(m.title))
	b.WriteString("\n")

	// Text input
	b.WriteString(m.input.View())
	b.WriteString("\n\n")

	// Results list
	if len(m.filtered) == 0 {
		b.WriteString(dimStyle.Render("(no results)"))
		b.WriteString("\n")
	} else {
		// Windowing: show up to maxPopupResults items centered on cursor.
		visible := maxPopupResults
		if visible > len(m.filtered) {
			visible = len(m.filtered)
		}

		offset := 0
		if m.cursor >= visible {
			offset = m.cursor - visible + 1
		}
		end := offset + visible
		if end > len(m.filtered) {
			end = len(m.filtered)
			offset = end - visible
			if offset < 0 {
				offset = 0
			}
		}

		for i := offset; i < end; i++ {
			item := m.filtered[i]

			label := item.Label
			subtitle := ""
			if item.Subtitle != "" {
				subtitle = "  " + dimStyle.Render(item.Subtitle)
			}

			row := fmt.Sprintf("  %s%s", label, subtitle)

			if i == m.cursor {
				row = selectedStyle.Render(row)
			}

			b.WriteString(row)
			b.WriteString("\n")
		}

		// Scroll indicators
		if offset > 0 || end < len(m.filtered) {
			hint := dimStyle.Render(fmt.Sprintf("  %d/%d", m.cursor+1, len(m.filtered)))
			b.WriteString(hint)
			b.WriteString("\n")
		}
	}

	// Footer
	b.WriteString("\n")
	footer := dimStyle.Render("Enter select  |  Esc cancel  |  j/k navigate")
	b.WriteString(footer)

	// Wrap in rounded border box
	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(borderColor).
		Padding(0, 1).
		Width(boxW).
		Render(b.String())

	return box
}
