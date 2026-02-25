package knowledge

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

// KnowledgeSearchResult represents a single result from `lore search --type knowledge --json`.
type KnowledgeSearchResult struct {
	Heading             string  `json:"heading"`
	FilePath            string  `json:"file_path"`
	SourceType          string  `json:"source_type"`
	Category            string  `json:"category"`
	Confidence          string  `json:"confidence"`
	LearnedDate         string  `json:"learned_date"`
	StructuralImportance float64 `json:"structural_importance"`
	Score               float64 `json:"score"`
	Snippet             string  `json:"snippet"`
}

// KnowledgeSearchDismissedMsg is sent when the user exits knowledge search.
type KnowledgeSearchDismissedMsg struct{}

// KnowledgeSearchResultSelectedMsg is sent when the user selects a search result.
type KnowledgeSearchResultSelectedMsg struct {
	FilePath string
	Title    string
}

// knowledgeSearchResultsMsg is sent when search results arrive.
type knowledgeSearchResultsMsg struct {
	results []KnowledgeSearchResult
	query   string
	err     error
}

// SearchModel is the Bubble Tea model for knowledge search.
type SearchModel struct {
	input     textinput.Model
	results   []KnowledgeSearchResult
	cursor    int
	lastQuery string
	searching bool
	err       error
	width     int
	height    int
}

// NewSearchModel creates a knowledge search panel.
func NewSearchModel() SearchModel {
	ti := textinput.New()
	ti.Placeholder = "Search knowledge..."
	ti.Focus()
	ti.CharLimit = 200
	ti.Width = 60

	return SearchModel{
		input:  ti,
		cursor: -1,
	}
}

func (m SearchModel) Init() tea.Cmd {
	return textinput.Blink
}

func (m SearchModel) Update(msg tea.Msg) (SearchModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.input.Width = msg.Width - 6

	case knowledgeSearchResultsMsg:
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
			return m, func() tea.Msg { return KnowledgeSearchDismissedMsg{} }
		case "enter":
			if m.cursor >= 0 && m.cursor < len(m.results) {
				r := m.results[m.cursor]
				return m, func() tea.Msg {
					return KnowledgeSearchResultSelectedMsg{
						FilePath: r.FilePath,
						Title:    r.Heading,
					}
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
		if len(newQuery) >= 2 {
			m.searching = true
			query := newQuery
			searchCmd = tea.Tick(200*time.Millisecond, func(t time.Time) tea.Msg {
				return executeKnowledgeSearch(query)
			})
		} else {
			m.results = nil
			m.cursor = -1
			m.searching = false
		}
	}

	return m, tea.Batch(inputCmd, searchCmd)
}

func (m SearchModel) View() string {
	var b strings.Builder

	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("4"))
	dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	selectedStyle := lipgloss.NewStyle().Background(lipgloss.Color("237")).Bold(true)
	scoreStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	categoryStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("5"))

	b.WriteString("\n")
	b.WriteString("  ")
	b.WriteString(titleStyle.Render("Search Knowledge"))
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
				heading = r.FilePath
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
	footer := dimStyle.Render("  Enter select  |  Esc cancel  |  up/down navigate")
	b.WriteString(footer)

	return b.String()
}

func executeKnowledgeSearch(query string) tea.Msg {
	cmd := exec.Command("lore", "search", query, "--type", "knowledge", "--json")
	out, err := cmd.Output()
	if err != nil {
		return knowledgeSearchResultsMsg{query: query, err: err}
	}

	var results []KnowledgeSearchResult
	if err := json.Unmarshal(out, &results); err != nil {
		return knowledgeSearchResultsMsg{query: query, err: err}
	}

	return knowledgeSearchResultsMsg{query: query, results: results}
}
