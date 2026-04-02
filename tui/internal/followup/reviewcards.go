package followup

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/anticorrelator/lore/tui/internal/render"
)

// WriteSidecarMsg is sent after an async write of proposed-comments.json completes.
type WriteSidecarMsg struct {
	Err error
}

// WriteSidecarCmd writes the full ProposedReview back to proposed-comments.json.
func WriteSidecarCmd(knowledgeDir, followupID string, review *ProposedReview) tea.Cmd {
	return func() tea.Msg {
		itemDir := filepath.Join(knowledgeDir, "_followups", followupID)
		data, err := json.MarshalIndent(review, "", "  ")
		if err != nil {
			return WriteSidecarMsg{Err: fmt.Errorf("marshaling sidecar: %w", err)}
		}
		if err := os.WriteFile(filepath.Join(itemDir, "proposed-comments.json"), data, 0644); err != nil {
			return WriteSidecarMsg{Err: fmt.Errorf("writing sidecar: %w", err)}
		}
		return WriteSidecarMsg{}
	}
}

// ReviewCardsModel is the Bubble Tea model for proposed review comments.
// It renders comment cards with cursor navigation and selection toggling,
// following the budget-based windowing pattern from TasksModel.
type ReviewCardsModel struct {
	review       *ProposedReview
	comments     []ProposedComment
	cursor       int
	width        int
	height       int
	knowledgeDir string
	followupID   string
	writeErr     error
}

// NewReviewCardsModel creates a ReviewCardsModel from a loaded ProposedReview.
// Pass nil if no sidecar is present — the model renders an empty state.
func NewReviewCardsModel(knowledgeDir, followupID string, review *ProposedReview) ReviewCardsModel {
	m := ReviewCardsModel{
		knowledgeDir: knowledgeDir,
		followupID:   followupID,
		review:       review,
	}
	if review != nil {
		m.comments = review.Comments
	}
	return m
}

// IsEmpty returns true when there are no proposed comments.
func (m ReviewCardsModel) IsEmpty() bool {
	return len(m.comments) == 0
}

// SelectedCount returns the number of comments currently selected for posting.
func (m ReviewCardsModel) SelectedCount() int {
	n := 0
	for _, c := range m.comments {
		if c.Selected {
			n++
		}
	}
	return n
}

// TotalCount returns the total number of proposed comments.
func (m ReviewCardsModel) TotalCount() int {
	return len(m.comments)
}

func (m ReviewCardsModel) Init() tea.Cmd {
	return nil
}

func (m ReviewCardsModel) Update(msg tea.Msg) (ReviewCardsModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

	case WriteSidecarMsg:
		m.writeErr = msg.Err

	case tea.KeyMsg:
		switch msg.String() {
		case "j", "down":
			if m.cursor < len(m.comments)-1 {
				m.cursor++
			}
		case "k", "up":
			if m.cursor > 0 {
				m.cursor--
			}
		case "g", "home":
			m.cursor = 0
		case "G", "end":
			if len(m.comments) > 0 {
				m.cursor = len(m.comments) - 1
			}
		case " ", "x", "enter":
			// Toggle selection on the current comment.
			if m.cursor >= 0 && m.cursor < len(m.comments) {
				m.comments[m.cursor].Selected = !m.comments[m.cursor].Selected
				// Sync back to the review so the sidecar write is consistent.
				if m.review != nil && m.cursor < len(m.review.Comments) {
					m.review.Comments[m.cursor].Selected = m.comments[m.cursor].Selected
				}
				return m, WriteSidecarCmd(m.knowledgeDir, m.followupID, m.review)
			}
		}
	}
	return m, nil
}

func (m ReviewCardsModel) View() string {
	if m.IsEmpty() {
		return lipgloss.NewStyle().Foreground(lipgloss.Color("8")).Render("  No proposed comments.")
	}

	dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	selectedBg := lipgloss.NewStyle().Background(lipgloss.Color("237")).Bold(true)
	pathStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("6"))
	sevHigh := lipgloss.NewStyle().Foreground(lipgloss.Color("1")).Bold(true)
	sevMed := lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	sevLow := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))

	var b strings.Builder

	// Header: selection count
	b.WriteString(dimStyle.Render(fmt.Sprintf("  %d/%d selected", m.SelectedCount(), m.TotalCount())))
	b.WriteString("\n\n")

	// Budget-based windowing: compute how many cards fit in the available height.
	budget := m.height - 3 // account for header lines
	if budget < 1 {
		budget = 1<<31 - 1
	}

	// Pre-compute card heights.
	heights := make([]int, len(m.comments))
	for i := range m.comments {
		heights[i] = m.cardHeight(i)
	}

	// Walk outward from cursor.
	offset := m.cursor
	end := m.cursor + 1
	used := heights[m.cursor]

	lo, hi := m.cursor-1, m.cursor+1
	for used < budget {
		addedAny := false
		if hi < len(m.comments) && used+heights[hi] <= budget {
			used += heights[hi]
			end = hi + 1
			hi++
			addedAny = true
		}
		if lo >= 0 && used+heights[lo] <= budget {
			used += heights[lo]
			offset = lo
			lo--
			addedAny = true
		}
		if !addedAny {
			break
		}
	}

	for i := offset; i < end; i++ {
		c := m.comments[i]

		// Checkbox
		check := "[ ]"
		if c.Selected {
			check = "[x]"
		}

		// Severity coloring
		var sevStr string
		switch c.Severity {
		case "high", "critical":
			sevStr = sevHigh.Render(c.Severity)
		case "medium":
			sevStr = sevMed.Render(c.Severity)
		default:
			sevStr = sevLow.Render(c.Severity)
		}

		// First line: checkbox + path:line + severity
		line1 := fmt.Sprintf("  %s %s:%d  %s",
			check,
			pathStyle.Render(c.Path),
			c.Line,
			sevStr,
		)

		// Body: word-wrap the full text to the available width.
		bodyW := m.width - 8 // 6 indent + 2 margin
		bodyLines := m.wrapBody(c.Body, bodyW)

		var card strings.Builder
		if i == m.cursor {
			card.WriteString(selectedBg.Render(line1))
			card.WriteByte('\n')
			for _, bl := range bodyLines {
				card.WriteString(selectedBg.Render(dimStyle.Render("      "+bl)))
				card.WriteByte('\n')
			}
		} else {
			card.WriteString(line1)
			card.WriteByte('\n')
			for _, bl := range bodyLines {
				card.WriteString(dimStyle.Render("      " + bl))
				card.WriteByte('\n')
			}
		}

		b.WriteString(card.String())
	}

	if m.writeErr != nil {
		b.WriteString("\n")
		b.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("1")).Render(
			fmt.Sprintf("  Write error: %v", m.writeErr)))
		b.WriteString("\n")
	}

	return b.String()
}

// cardHeight returns the number of terminal lines a single card renders.
func (m ReviewCardsModel) cardHeight(idx int) int {
	bodyW := m.width - 8
	bodyLines := m.wrapBody(m.comments[idx].Body, bodyW)
	return 1 + len(bodyLines) // header + wrapped body lines
}

// wrapBody splits the comment body into word-wrapped lines.
func (m ReviewCardsModel) wrapBody(body string, width int) []string {
	if width <= 0 {
		width = 72
	}
	// Split body into paragraphs (source lines), then wrap each.
	var out []string
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			out = append(out, "")
			continue
		}
		out = append(out, render.WordWrapRaw(line, width)...)
	}
	if len(out) == 0 {
		out = []string{""}
	}
	return out
}

