package work

import (
	"regexp"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// NoteEntry represents a parsed session note entry.
type NoteEntry struct {
	Timestamp string
	Content   string
}

// NotesTabModel is the Bubble Tea model for the Notes tab.
type NotesTabModel struct {
	entries []NoteEntry
	cursor  int    // selected entry in the left pane
	scroll  int    // scroll offset for the right pane content
	width   int
	height  int
	empty   bool
}

var noteHeaderRe = regexp.MustCompile(`^## (\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2})?)`)

// NewNotesTabModel creates a notes tab from notes_content.
func NewNotesTabModel(notesContent *string, width, height int) NotesTabModel {
	if notesContent == nil || strings.TrimSpace(*notesContent) == "" {
		return NotesTabModel{empty: true, width: width, height: height}
	}

	entries := parseNotes(*notesContent)
	if len(entries) == 0 {
		return NotesTabModel{empty: true, width: width, height: height}
	}

	return NotesTabModel{
		entries: entries,
		cursor:  0,
		width:   width,
		height:  height,
	}
}

func parseNotes(content string) []NoteEntry {
	lines := strings.Split(content, "\n")
	var entries []NoteEntry
	var current *NoteEntry
	var contentLines []string

	for _, line := range lines {
		matches := noteHeaderRe.FindStringSubmatch(line)
		if matches != nil {
			if current != nil {
				current.Content = strings.TrimSpace(strings.Join(contentLines, "\n"))
				entries = append(entries, *current)
			}
			current = &NoteEntry{Timestamp: matches[1]}
			contentLines = nil
			continue
		}

		if current != nil {
			contentLines = append(contentLines, line)
		}
	}

	if current != nil {
		current.Content = strings.TrimSpace(strings.Join(contentLines, "\n"))
		entries = append(entries, *current)
	}

	return entries
}

func (m NotesTabModel) Init() tea.Cmd {
	return nil
}

func (m NotesTabModel) Update(msg tea.Msg) (NotesTabModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

	case tea.MouseMsg:
		switch msg.Button {
		case tea.MouseButtonWheelDown:
			// Clamp to max scroll: total content lines minus 1.
			if m.cursor >= 0 && m.cursor < len(m.entries) {
				contentLines := strings.Split(m.entries[m.cursor].Content, "\n")
				maxScroll := len(contentLines) - 1
				if maxScroll < 0 {
					maxScroll = 0
				}
				if m.scroll < maxScroll {
					m.scroll++
				}
			}
		case tea.MouseButtonWheelUp:
			if m.scroll > 0 {
				m.scroll--
			}
		}

	case tea.KeyMsg:
		switch msg.String() {
		case "j", "down":
			if m.cursor < len(m.entries)-1 {
				m.cursor++
				m.scroll = 0
			}
		case "k", "up":
			if m.cursor > 0 {
				m.cursor--
				m.scroll = 0
			}
		case "g", "home":
			m.cursor = 0
			m.scroll = 0
		case "G", "end":
			if len(m.entries) > 0 {
				m.cursor = len(m.entries) - 1
				m.scroll = 0
			}
		case "ctrl+d":
			// Scroll right pane down
			m.scroll++
		case "ctrl+u":
			// Scroll right pane up
			if m.scroll > 0 {
				m.scroll--
			}
		}
	}
	return m, nil
}

// IsEmpty returns whether there are no note entries.
func (m NotesTabModel) IsEmpty() bool {
	return m.empty
}

func (m NotesTabModel) View() string {
	if m.empty {
		dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
		return "  " + dimStyle.Render("No session notes.")
	}

	// Split into left (entry list) and right (content) panes
	leftWidth := 22 // enough for "YYYY-MM-DDTHH:MM"
	rightWidth := m.width - leftWidth - 5 // gap + padding
	if rightWidth < 30 {
		rightWidth = 30
	}

	viewHeight := m.height
	if viewHeight < 5 {
		viewHeight = 20
	}

	dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	selectedStyle := lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("4"))
	entryStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("7"))

	// Build left pane
	var leftLines []string
	for i, entry := range m.entries {
		ts := entry.Timestamp
		if i == m.cursor {
			leftLines = append(leftLines, selectedStyle.Render("> "+ts))
		} else {
			leftLines = append(leftLines, entryStyle.Render("  "+ts))
		}
	}

	// Build right pane — show selected entry content
	var rightLines []string
	if m.cursor >= 0 && m.cursor < len(m.entries) {
		entry := m.entries[m.cursor]
		contentLines := strings.Split(entry.Content, "\n")

		// Apply scroll
		start := m.scroll
		if start >= len(contentLines) {
			start = max(0, len(contentLines)-1)
		}

		for i := start; i < len(contentLines); i++ {
			// Word-wrap each source line to the available right-pane width
			for _, wl := range wordWrapRaw(contentLines[i], rightWidth) {
				rightLines = append(rightLines, wl)
				if len(rightLines) >= viewHeight {
					break
				}
			}
			if len(rightLines) >= viewHeight {
				break
			}
		}
	}

	// Combine panes
	var b strings.Builder
	maxLines := max(len(leftLines), len(rightLines))
	if maxLines > viewHeight {
		maxLines = viewHeight
	}

	separator := dimStyle.Render(" │ ")

	for i := 0; i < maxLines; i++ {
		left := ""
		if i < len(leftLines) {
			left = leftLines[i]
		}
		// Pad left to fixed width
		leftPad := leftWidth + 2 - lipgloss.Width(left)
		if leftPad < 0 {
			leftPad = 0
		}

		right := ""
		if i < len(rightLines) {
			right = rightLines[i]
		}

		b.WriteString("  ")
		b.WriteString(left)
		b.WriteString(strings.Repeat(" ", leftPad))
		b.WriteString(separator)
		b.WriteString(right)
		b.WriteString("\n")
	}

	return b.String()
}
