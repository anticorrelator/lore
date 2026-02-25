package work

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ExecEntry represents a parsed execution log entry.
type ExecEntry struct {
	Timestamp string
	Source    string
	Content   string
}

// ExecLogModel is the Bubble Tea model for the Execution Log tab.
type ExecLogModel struct {
	entries  []ExecEntry
	cursor   int
	scroll   int // scroll offset within the selected entry's content
	width    int
	height   int
	empty    bool
}

var entryHeaderRe = regexp.MustCompile(`^## (\S+)\s*\|\s*source:\s*(\S+)`)

// NewExecLogModel reads and parses execution-log.md from the work dir.
// Falls back to _archive/<slug>/ if the active path does not exist.
func NewExecLogModel(workDir, slug string) ExecLogModel {
	path := filepath.Join(workDir, slug, "execution-log.md")
	if _, err := os.Stat(path); os.IsNotExist(err) {
		if archivePath := filepath.Join(workDir, "_archive", slug, "execution-log.md"); func() bool {
			_, e := os.Stat(archivePath); return e == nil
		}() {
			path = archivePath
		}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return ExecLogModel{empty: true}
	}

	entries := parseExecLog(string(data))
	if len(entries) == 0 {
		return ExecLogModel{empty: true}
	}

	return ExecLogModel{
		entries: entries,
		cursor:  0,
	}
}

func parseExecLog(content string) []ExecEntry {
	lines := strings.Split(content, "\n")
	var entries []ExecEntry
	var current *ExecEntry
	var contentLines []string

	for _, line := range lines {
		matches := entryHeaderRe.FindStringSubmatch(line)
		if matches != nil {
			// Save previous entry
			if current != nil {
				current.Content = strings.TrimSpace(strings.Join(contentLines, "\n"))
				entries = append(entries, *current)
			}
			current = &ExecEntry{
				Timestamp: matches[1],
				Source:    matches[2],
			}
			contentLines = nil
			continue
		}

		if current != nil {
			contentLines = append(contentLines, line)
		}
	}

	// Save last entry
	if current != nil {
		current.Content = strings.TrimSpace(strings.Join(contentLines, "\n"))
		entries = append(entries, *current)
	}

	return entries
}

// NewExecLogModelFromEntries builds an ExecLogModel from already-parsed entries
// (no file I/O — for use on the BubbleTea event loop).
func NewExecLogModelFromEntries(entries []ExecEntry) ExecLogModel {
	if len(entries) == 0 {
		return ExecLogModel{empty: true}
	}
	return ExecLogModel{entries: entries, cursor: 0}
}

func (m ExecLogModel) Init() tea.Cmd {
	return nil
}

func (m ExecLogModel) Update(msg tea.Msg) (ExecLogModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

	case tea.MouseMsg:
		switch msg.Button {
		case tea.MouseButtonWheelDown:
			if m.cursor < len(m.entries)-1 {
				m.cursor++
				m.scroll = 0
			}
		case tea.MouseButtonWheelUp:
			if m.cursor > 0 {
				m.cursor--
				m.scroll = 0
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
		}
	}
	return m, nil
}

// IsEmpty returns whether there are no exec log entries.
func (m ExecLogModel) IsEmpty() bool {
	return m.empty
}

func (m ExecLogModel) View() string {
	if m.empty {
		return "  No execution log."
	}

	var b strings.Builder

	dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	selectedBg := lipgloss.NewStyle().Background(lipgloss.Color("237")).Bold(true)
	timestampStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("7"))

	// Entry list with content (footer removed — status bar handles hints)
	visibleRows := m.height
	if visibleRows < 1 {
		visibleRows = len(m.entries)
	}

	offset := 0
	if m.cursor >= visibleRows {
		offset = m.cursor - visibleRows + 1
	}

	end := offset + visibleRows
	if end > len(m.entries) {
		end = len(m.entries)
	}

	for i := offset; i < end; i++ {
		entry := m.entries[i]

		badge := sourceBadge(entry.Source)
		ts := formatExecTimestamp(entry.Timestamp)
		header := fmt.Sprintf("  %s  %s  %s", badge, timestampStyle.Render(ts), dimStyle.Render(firstLine(entry.Content)))

		if i == m.cursor {
			header = selectedBg.Render(header)
		}

		b.WriteString(header)
		b.WriteString("\n")

		// Show full content for selected entry (word-wrapped)
		if i == m.cursor && entry.Content != "" {
			wrapW := m.width - 8 // account for "    " prefix + some margin
			if wrapW < 20 {
				wrapW = 20
			}
			for _, cl := range strings.Split(entry.Content, "\n") {
				for _, wl := range wordWrapRaw(cl, wrapW) {
					b.WriteString(dimStyle.Render("    " + wl))
					b.WriteString("\n")
				}
			}
			b.WriteString("\n")
		}
	}

	return b.String()
}

func sourceBadge(source string) string {
	var style lipgloss.Style
	switch source {
	case "spec-lead":
		style = lipgloss.NewStyle().Foreground(lipgloss.Color("4")).Bold(true)
	case "remember":
		style = lipgloss.NewStyle().Foreground(lipgloss.Color("2")).Bold(true)
	case "implement-lead":
		style = lipgloss.NewStyle().Foreground(lipgloss.Color("3")).Bold(true)
	case "manual":
		style = lipgloss.NewStyle().Foreground(lipgloss.Color("5")).Bold(true)
	default:
		style = lipgloss.NewStyle().Foreground(lipgloss.Color("8")).Bold(true)
	}
	return style.Render(fmt.Sprintf("[%s]", source))
}

func formatExecTimestamp(ts string) string {
	// Show date + time, trim timezone suffix for compactness
	if len(ts) > 19 {
		return ts[:10] + " " + ts[11:16]
	}
	return ts
}

func firstLine(s string) string {
	if idx := strings.IndexByte(s, '\n'); idx >= 0 {
		return s[:idx]
	}
	return s
}
