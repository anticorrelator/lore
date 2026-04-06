package followup

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/atotto/clipboard"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/anticorrelator/lore/tui/internal/render"
)

// WriteSidecarMsg is sent after an async write of proposed-comments.json completes.
type WriteSidecarMsg struct {
	Err error
}

// ExternalEditRequestMsg is emitted by ReviewCardsModel when the user presses E
// to open the focused comment body in an external editor.
type ExternalEditRequestMsg struct {
	BackingIdx int    // index into review.Comments
	Body       string // current comment body to pre-populate the editor
}

// ExternalEditDoneMsg is returned by the tea.ExecProcess callback after the
// editor exits. NewBody is the full file content read back from the temp file.
type ExternalEditDoneMsg struct {
	BackingIdx int
	NewBody    string
	Err        error
}

// PostReviewCompleteMsg is sent after post-proposed-review.sh finishes.
type PostReviewCompleteMsg struct {
	ID          string
	PostedCount int
	Err         error
}

// SeverityFilter controls which comments are visible in the ReviewCardsModel.
type SeverityFilter int

const (
	FilterAll    SeverityFilter = 0 // show all comments
	FilterHigh   SeverityFilter = 1 // show high/critical only
	FilterMedium SeverityFilter = 2 // show medium only
	FilterLow    SeverityFilter = 3 // show low only
)

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
	review            *ProposedReview
	comments          []ProposedComment
	cursor            int
	width             int
	height            int
	knowledgeDir      string
	followupID        string
	writeErr          error
	deleteConfirm     bool                 // double-press deletion: true after first D press
	flashMsg          string               // transient feedback rendered in Comments tab view, cleared on next keypress
	sevSelectCycle    int                  // tracks S-cycle position: 0-3, resets on deletion/reload
	clipboardWriteFn  func(string) error   // injectable clipboard seam (D17)
	severityFilter    SeverityFilter       // active severity filter for visible comments
	editing           bool                 // true while ExternalEditRequestMsg is pending (prevents re-entrant E press)
}

// NewReviewCardsModel creates a ReviewCardsModel from a loaded ProposedReview.
// Pass nil if no sidecar is present — the model renders an empty state.
func NewReviewCardsModel(knowledgeDir, followupID string, review *ProposedReview) ReviewCardsModel {
	m := ReviewCardsModel{
		knowledgeDir:     knowledgeDir,
		followupID:       followupID,
		review:           review,
		clipboardWriteFn: clipboard.WriteAll,
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

// IsEditing returns true when an external editor session is in progress.
// A second E press while editing is a no-op.
func (m ReviewCardsModel) IsEditing() bool {
	return m.editing
}

// visibleComments returns the indices into m.comments that match the current severityFilter.
// Unknown severities are always visible regardless of active filter. FilterAll returns all indices.
func (m ReviewCardsModel) visibleComments() []int {
	out := make([]int, 0, len(m.comments))
	for i, c := range m.comments {
		var visible bool
		switch m.severityFilter {
		case FilterHigh:
			visible = c.Severity == "high" || c.Severity == "critical"
		case FilterMedium:
			visible = c.Severity == "medium"
		case FilterLow:
			visible = c.Severity == "low"
		default: // FilterAll or unknown filter value
			visible = true
		}
		// Unknown severity values are always visible even under a named filter.
		if m.severityFilter != FilterAll {
			switch c.Severity {
			case "high", "critical", "medium", "low":
				// already evaluated above
			default:
				visible = true
			}
		}
		if visible {
			out = append(out, i)
		}
	}
	return out
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

	case ExternalEditDoneMsg:
		m.editing = false
		if msg.Err != nil {
			m.flashMsg = fmt.Sprintf("Editor error: %v", msg.Err)
			return m, nil
		}
		if msg.BackingIdx >= len(m.comments) {
			m.flashMsg = "Comment was deleted during editing"
			return m, nil
		}
		if msg.NewBody == m.comments[msg.BackingIdx].Body {
			// No change — skip write.
			return m, nil
		}
		m.comments[msg.BackingIdx].Body = msg.NewBody
		if m.review != nil && msg.BackingIdx < len(m.review.Comments) {
			m.review.Comments[msg.BackingIdx].Body = msg.NewBody
		}
		return m, WriteSidecarCmd(m.knowledgeDir, m.followupID, m.review)

	case tea.KeyMsg:
		// Clear any transient flash message on every keypress.
		m.flashMsg = ""
		// Reset delete-confirm arm on any non-D key.
		if msg.String() != "D" {
			m.deleteConfirm = false
		}
		visible := m.visibleComments()
		switch msg.String() {
		case "j", "down":
			if m.cursor < len(visible)-1 {
				m.cursor++
			}
		case "k", "up":
			if m.cursor > 0 {
				m.cursor--
			}
		case "g", "home":
			m.cursor = 0
		case "G", "end":
			if len(visible) > 0 {
				m.cursor = len(visible) - 1
			}
		case " ", "x", "enter":
			// Toggle selection on the current comment (via backing index).
			if m.cursor >= 0 && m.cursor < len(visible) {
				backingIdx := visible[m.cursor]
				m.comments[backingIdx].Selected = !m.comments[backingIdx].Selected
				// Sync back to the review so the sidecar write is consistent.
				if m.review != nil && backingIdx < len(m.review.Comments) {
					m.review.Comments[backingIdx].Selected = m.comments[backingIdx].Selected
				}
				return m, WriteSidecarCmd(m.knowledgeDir, m.followupID, m.review)
			}
		case "D":
			if !m.deleteConfirm {
				// First D press: arm deletion.
				m.deleteConfirm = true
				m.flashMsg = "D to confirm delete"
			} else {
				// Second D press: confirm deletion via backing index.
				if m.cursor >= 0 && m.cursor < len(visible) {
					backingIdx := visible[m.cursor]
					m.comments = append(m.comments[:backingIdx], m.comments[backingIdx+1:]...)
					if m.review != nil && backingIdx < len(m.review.Comments) {
						m.review.Comments = append(m.review.Comments[:backingIdx], m.review.Comments[backingIdx+1:]...)
					}
					// Recompute visible after deletion and clamp cursor.
					newVisible := m.visibleComments()
					if m.cursor >= len(newVisible) && len(newVisible) > 0 {
						m.cursor = len(newVisible) - 1
					} else if len(newVisible) == 0 {
						m.cursor = 0
					}
				}
				m.deleteConfirm = false
				m.sevSelectCycle = 0
				if m.review != nil {
					return m, WriteSidecarCmd(m.knowledgeDir, m.followupID, m.review)
				}
			}
		case "f":
			// Cycle severity filter: FilterAll → FilterHigh → FilterMedium → FilterLow → FilterAll.
			m.severityFilter = SeverityFilter((int(m.severityFilter) + 1) % 4)
			m.cursor = 0
		case "a":
			// Toggle select-all / deselect-all over all comments.
			if m.review != nil {
				allSelected := m.SelectedCount() == len(m.comments)
				target := !allSelected
				for i := range m.comments {
					m.comments[i].Selected = target
				}
				for i := range m.review.Comments {
					m.review.Comments[i].Selected = target
				}
				return m, WriteSidecarCmd(m.knowledgeDir, m.followupID, m.review)
			}
		case "i":
			// Invert all selections.
			if m.review != nil {
				for i := range m.comments {
					m.comments[i].Selected = !m.comments[i].Selected
					// Sync using the already-inverted value rather than re-negating.
					// m.comments and m.review.Comments may share a backing array, so
					// a second !m.review.Comments[i].Selected would double-invert.
					if i < len(m.review.Comments) {
						m.review.Comments[i].Selected = m.comments[i].Selected
					}
				}
				return m, WriteSidecarCmd(m.knowledgeDir, m.followupID, m.review)
			}
		case "S":
			// Advance severity-select cycle (0=all, 1=high/critical, 2=medium, 3=low) per D12.
			if m.review != nil {
				m.sevSelectCycle = (m.sevSelectCycle + 1) % 4
				for i := range m.comments {
					var selected bool
					switch m.sevSelectCycle {
					case 0:
						selected = true
					case 1:
						selected = m.comments[i].Severity == "high" || m.comments[i].Severity == "critical"
					case 2:
						selected = m.comments[i].Severity == "medium"
					case 3:
						selected = m.comments[i].Severity == "low"
					}
					m.comments[i].Selected = selected
				}
				for i := range m.review.Comments {
					m.review.Comments[i].Selected = m.comments[i].Selected
				}
				return m, WriteSidecarCmd(m.knowledgeDir, m.followupID, m.review)
			}
		case "y":
			// Copy current comment body to clipboard (via backing index).
			if m.cursor >= 0 && m.cursor < len(visible) && m.clipboardWriteFn != nil {
				backingIdx := visible[m.cursor]
				if err := m.clipboardWriteFn(m.comments[backingIdx].Body); err != nil {
					m.flashMsg = fmt.Sprintf("Copy failed: %v", err)
				} else {
					m.flashMsg = "Copied to clipboard"
				}
			}
		case "E":
			// Open current comment body in external editor.
			if m.editing || m.IsEmpty() || m.cursor < 0 || m.cursor >= len(visible) {
				break
			}
			editor := os.Getenv("EDITOR")
			if editor == "" {
				m.flashMsg = "EDITOR not set"
				break
			}
			backingIdx := visible[m.cursor]
			m.editing = true
			return m, func() tea.Msg {
				return ExternalEditRequestMsg{BackingIdx: backingIdx, Body: m.comments[backingIdx].Body}
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

	visible := m.visibleComments()

	var b strings.Builder

	// Header: selection count + filter status
	header := fmt.Sprintf("  %d/%d selected", m.SelectedCount(), m.TotalCount())
	if m.severityFilter != FilterAll {
		var filterLabel string
		switch m.severityFilter {
		case FilterHigh:
			filterLabel = "high"
		case FilterMedium:
			filterLabel = "medium"
		case FilterLow:
			filterLabel = "low"
		}
		header += fmt.Sprintf(" | filter: %s", filterLabel)
	}
	b.WriteString(dimStyle.Render(header))
	b.WriteString("\n\n")

	// When filter is active but no comments match, show a hint.
	if len(visible) == 0 {
		b.WriteString(dimStyle.Render("  No comments match filter."))
		b.WriteString("\n")
	} else {
		// Budget-based windowing: compute how many cards fit in the available height.
		budget := m.height - 3 // account for header lines
		if budget < 1 {
			budget = 1<<31 - 1
		}

		// Pre-compute card heights for visible comments only.
		heights := make([]int, len(visible))
		for i, backingIdx := range visible {
			heights[i] = m.cardHeight(backingIdx)
		}

		// Walk outward from cursor (position in visible slice).
		offset := m.cursor
		end := m.cursor + 1
		used := heights[m.cursor]

		lo, hi := m.cursor-1, m.cursor+1
		for used < budget {
			addedAny := false
			if hi < len(visible) && used+heights[hi] <= budget {
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

		for visPos := offset; visPos < end; visPos++ {
			backingIdx := visible[visPos]
			c := m.comments[backingIdx]

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
			if visPos == m.cursor {
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
	}

	if m.writeErr != nil {
		b.WriteString("\n")
		b.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("1")).Render(
			fmt.Sprintf("  Write error: %v", m.writeErr)))
		b.WriteString("\n")
	}

	// Render transient flash message (clipboard feedback, etc.).
	if m.flashMsg != "" {
		b.WriteString("\n")
		b.WriteString(dimStyle.Render("  " + m.flashMsg))
		b.WriteString("\n")
	}

	// Render deleteConfirm hint when double-press deletion is armed.
	if m.deleteConfirm {
		b.WriteString("\n")
		b.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("1")).Render(
			"  Press D again to confirm deletion"))
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

