package search

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// SearchResult represents a single search result from `lore work search --json`.
type SearchResult struct {
	Heading  string  `json:"heading"`
	Category string  `json:"category"`
	Path     string  `json:"path"`
	Score    float64 `json:"score"`
	Snippet  string  `json:"snippet"`
	Slug     string  `json:"slug"`
	Source   string  `json:"source"`
	Type     string  `json:"type"`
	Updated  string  `json:"updated"`
}

// SearchResultSelectedMsg is sent when the user selects a search result.
type SearchResultSelectedMsg struct {
	Slug string
}

// SearchDismissedMsg is sent when the user dismisses search.
type SearchDismissedMsg struct{}

// searchResultsMsg is sent when search results arrive.
type searchResultsMsg struct {
	results []SearchResult
	query   string
	err     error
}

// PanelModel is the Bubble Tea model for the search panel.
type PanelModel struct {
	input      textinput.Model
	results    []SearchResult
	cursor     int
	lastQuery  string
	searching  bool
	err        error
	width      int
	height     int
	debounceID int // monotonic ID to ignore stale results
}

// NewPanelModel creates a search panel.
func NewPanelModel() PanelModel {
	ti := textinput.New()
	ti.Placeholder = "Search work items..."
	ti.Focus()
	ti.CharLimit = 200
	ti.Width = 60

	return PanelModel{
		input:  ti,
		cursor: -1, // no result selected initially
	}
}

func (m PanelModel) Init() tea.Cmd {
	return textinput.Blink
}

func (m PanelModel) Update(msg tea.Msg) (PanelModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.input.Width = msg.Width - 6

	case searchResultsMsg:
		// Only accept results for the current query
		if msg.query == m.lastQuery {
			m.searching = false
			m.err = msg.err
			if msg.err == nil {
				m.results = msg.results
			}
			if len(m.results) > 0 {
				m.cursor = 0
			} else {
				m.cursor = -1
			}
		}

	case tea.KeyMsg:
		switch msg.String() {
		case "esc":
			return m, func() tea.Msg { return SearchDismissedMsg{} }
		case "enter":
			if m.cursor >= 0 && m.cursor < len(m.results) {
				slug := extractSlug(m.results[m.cursor])
				if slug != "" {
					return m, func() tea.Msg { return SearchResultSelectedMsg{Slug: slug} }
				}
			}
		case "down", "ctrl+n":
			if len(m.results) > 0 {
				m.cursor++
				if m.cursor >= len(m.results) {
					m.cursor = len(m.results) - 1
				}
			}
			return m, nil
		case "up", "ctrl+p":
			if m.cursor > 0 {
				m.cursor--
			}
			return m, nil
		}
	}

	// Update text input
	var inputCmd tea.Cmd
	m.input, inputCmd = m.input.Update(msg)

	// Debounced search on input change
	var searchCmd tea.Cmd
	newQuery := m.input.Value()
	if newQuery != m.lastQuery {
		m.lastQuery = newQuery
		m.debounceID++
		if len(newQuery) >= 2 {
			m.searching = true
			id := m.debounceID
			query := newQuery
			searchCmd = tea.Tick(200*time.Millisecond, func(t time.Time) tea.Msg {
				_ = id // capture for closure, used for stale detection
				return executeSearch(query)
			})
		} else {
			m.results = nil
			m.cursor = -1
			m.searching = false
		}
	}

	return m, tea.Batch(inputCmd, searchCmd)
}

func (m PanelModel) View() string {
	var b strings.Builder

	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("4"))
	dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	selectedStyle := lipgloss.NewStyle().Background(lipgloss.Color("237")).Bold(true)
	scoreStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	categoryStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("5"))

	b.WriteString("\n")
	b.WriteString("  ")
	b.WriteString(titleStyle.Render("Search Work Items"))
	b.WriteString("\n\n")

	// Input field
	b.WriteString("  ")
	b.WriteString(m.input.View())
	b.WriteString("\n\n")

	if m.searching {
		b.WriteString("  ")
		b.WriteString(dimStyle.Render("Searching..."))
		b.WriteString("\n")
	} else if m.err != nil {
		b.WriteString("  ")
		b.WriteString(dimStyle.Render(fmt.Sprintf("Error: %v", m.err)))
		b.WriteString("\n")
	} else if m.lastQuery != "" && len(m.lastQuery) >= 2 && len(m.results) == 0 {
		b.WriteString("  ")
		b.WriteString(dimStyle.Render("No results found."))
		b.WriteString("\n")
	} else if len(m.results) > 0 {
		// Results list
		maxVisible := m.height - 8
		if maxVisible < 3 {
			maxVisible = len(m.results)
		}

		offset := 0
		if m.cursor >= maxVisible {
			offset = m.cursor - maxVisible + 1
		}

		end := offset + maxVisible
		if end > len(m.results) {
			end = len(m.results)
		}

		for i := offset; i < end; i++ {
			r := m.results[i]

			heading := r.Heading
			if heading == "" {
				heading = r.Slug
			}

			score := scoreStyle.Render(fmt.Sprintf("[%.1f]", r.Score))
			category := categoryStyle.Render(r.Category)

			row := fmt.Sprintf("  %s %s  %s", score, heading, category)

			if i == m.cursor {
				row = selectedStyle.Render(row)
			}

			b.WriteString(row)
			b.WriteString("\n")

			// Show snippet for selected result
			if i == m.cursor && r.Snippet != "" {
				snippet := strings.TrimSpace(r.Snippet)
				if len(snippet) > 120 {
					snippet = snippet[:117] + "..."
				}
				b.WriteString("    ")
				b.WriteString(dimStyle.Render(snippet))
				b.WriteString("\n")
			}
		}
	} else if m.lastQuery == "" || len(m.lastQuery) < 2 {
		b.WriteString("  ")
		b.WriteString(dimStyle.Render("Type at least 2 characters to search."))
		b.WriteString("\n")
	}

	// Footer
	b.WriteString("\n")
	footer := dimStyle.Render("  Enter select  |  Esc cancel  |  ↑/↓ navigate")
	b.WriteString(footer)

	return b.String()
}

func executeSearch(query string) tea.Msg {
	cmd := exec.Command("lore", "work", "search", query, "--json")
	out, err := cmd.Output()
	if err != nil {
		return searchResultsMsg{query: query, err: err}
	}

	var results []SearchResult
	if err := json.Unmarshal(out, &results); err != nil {
		return searchResultsMsg{query: query, err: err}
	}

	return searchResultsMsg{query: query, results: results}
}

// extractSlug gets the work item slug from a search result.
// The slug field may be directly available, or we extract from the path.
func extractSlug(r SearchResult) string {
	if r.Slug != "" {
		return r.Slug
	}
	// Try to extract from path: _work/<slug>/...
	parts := strings.Split(r.Path, "/")
	for i, p := range parts {
		if p == "_work" && i+1 < len(parts) {
			return parts[i+1]
		}
	}
	return ""
}
