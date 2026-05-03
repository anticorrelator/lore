package followup

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/atotto/clipboard"
	"github.com/charmbracelet/bubbles/textarea"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/anticorrelator/lore/tui/internal/gh"
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

// PostOutcome records the remap result for a single comment after posting.
type PostOutcome struct {
	RemapStatus  string  `json:"remap_status"`
	FinalStatus  string  `json:"final_status"`
	OriginalLine int     `json:"original_line"`
	PostedLine   *int    `json:"posted_line,omitempty"`
	PostedPath   *string `json:"posted_path,omitempty"`
	Message      string  `json:"message,omitempty"`
	PostedAt     string  `json:"posted_at,omitempty"`
}

// LastPost summarises the most recent post-proposed-review.sh run.
type LastPost struct {
	At          string `json:"at"`
	CurrentHead string `json:"current_head"`
	Posted      int    `json:"posted"`
	Dropped     int    `json:"dropped"`
	Shifted     int    `json:"shifted"`
	Renamed     int    `json:"renamed"`
	Appended    int    `json:"appended,omitempty"`
}

// PostReviewCompleteMsg is sent after post-proposed-review.sh finishes.
type PostReviewCompleteMsg struct {
	ID          string
	PostedCount int
	Dropped     int
	Shifted     int
	Renamed     int
	Appended    int
	Err         error
}

// MergeStatusLoadedMsg is sent when an async merge-status fetch completes.
// FollowupID lets the parent discard cross-item responses.
// RequestSeq lets the parent discard stale same-item responses.
type MergeStatusLoadedMsg struct {
	FollowupID string
	RequestSeq uint64
	Status     gh.MergeStatus
	Err        error
}

// SummaryRequestMsg is emitted when the user presses `g` to generate a thematic summary.
// FollowupID and SelectionHash are forwarded to tui/update.go which spawns the CLI command.
type SummaryRequestMsg struct {
	FollowupID    string
	SelectionHash string
}

// SummaryGeneratedMsg is returned after `lore followup summarize` completes.
// On error, Err is set and Text is empty; on success, Text is the markdown output.
type SummaryGeneratedMsg struct {
	Text          string
	SelectionHash string
	Err           error
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
		itemDir, err := ResolveDir(knowledgeDir, followupID)
		if err != nil {
			return WriteSidecarMsg{Err: fmt.Errorf("resolving followup dir: %w", err)}
		}
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
	review              *ProposedReview
	comments            []ProposedComment
	cursor              int
	width               int
	height              int
	knowledgeDir        string
	followupID          string
	writeErr            error
	flashMsg            string               // transient feedback rendered in Comments tab view, cleared on next keypress
	clipboardWriteFn    func(string) error   // injectable clipboard seam (D17)
	externalEditing     bool                 // true while ExternalEditRequestMsg is pending (prevents re-entrant E press)
	editing             bool                 // true while inline textarea edit is active (lowercase e)
	editInput           textarea.Model       // textarea for inline body editing
	editIdx             int                  // backing index of the comment being edited inline
	generatingSummary   bool                 // true while `lore followup summarize` is in flight
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
		if review.ReviewEvent == "" {
			review.ReviewEvent = "COMMENT"
		}
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

// IsEditing returns true when inline textarea editing is active.
// Used by the parent model to suppress global key shortcuts.
func (m ReviewCardsModel) IsEditing() bool {
	return m.editing
}

// ReviewEvent returns the review event type stored in the sidecar (e.g. "COMMENT", "APPROVE", "REQUEST_CHANGES").
// Returns an empty string when no review is loaded.
func (m ReviewCardsModel) ReviewEvent() string {
	if m.review == nil {
		return ""
	}
	return m.review.ReviewEvent
}

// hasGeneralCard returns true when a general comment card should be rendered
// at the top of the card list. When true, cursor == -1 selects that card.
func (m ReviewCardsModel) hasGeneralCard() bool {
	return m.review != nil
}

// generalCardHeight returns the number of terminal lines the general comment card renders.
func (m ReviewCardsModel) generalCardHeight() int {
	if m.review == nil {
		return 0
	}
	if m.review.ReviewBody == "" {
		return 2 // header + placeholder line
	}
	bodyW := m.width - 8
	bodyLines := m.wrapBody(m.review.ReviewBody, bodyW)
	return 1 + len(bodyLines)
}

// visibleComments returns the indices of all comments.
func (m ReviewCardsModel) visibleComments() []int {
	out := make([]int, len(m.comments))
	for i := range m.comments {
		out[i] = i
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
		if m.editing {
			w := m.width - 8
			if w < 20 {
				w = 20
			}
			m.editInput.SetWidth(w)
		}

	case WriteSidecarMsg:
		m.writeErr = msg.Err

	case SummaryGeneratedMsg:
		m.generatingSummary = false
		if msg.Err != nil {
			m.flashMsg = fmt.Sprintf("Summary error: %v", msg.Err)
			return m, nil
		}
		if m.review != nil {
			m.review.ReviewBody = spliceSummary(m.review.ReviewBody, msg.Text)
			m.review.SummaryGeneratedAt = time.Now().UTC().Format(time.RFC3339)
			m.review.SummarySelectionHash = msg.SelectionHash
		}
		return m, WriteSidecarCmd(m.knowledgeDir, m.followupID, m.review)

	case ExternalEditDoneMsg:
		m.externalEditing = false
		if msg.Err != nil {
			m.flashMsg = fmt.Sprintf("Editor error: %v", msg.Err)
			return m, nil
		}
		if msg.BackingIdx == -1 {
			// General comment card: write to ReviewBody.
			if m.review == nil || msg.NewBody == m.review.ReviewBody {
				return m, nil
			}
			m.review.ReviewBody = msg.NewBody
			return m, WriteSidecarCmd(m.knowledgeDir, m.followupID, m.review)
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

		// Edit-mode routing: when inline textarea is active, intercept Enter/Esc/Alt+Enter;
		// all other keys are forwarded to editInput so the textarea handles them.
		if m.editing {
			switch msg.String() {
			case "enter":
				// Save: sync textarea value back to the model.
				newBody := m.editInput.Value()
				if m.editIdx == -1 {
					// General comment card.
					m.review.ReviewBody = newBody
				} else {
					m.comments[m.editIdx].Body = newBody
					if m.review != nil && m.editIdx < len(m.review.Comments) {
						m.review.Comments[m.editIdx].Body = newBody
					}
				}
				m.editing = false
				return m, WriteSidecarCmd(m.knowledgeDir, m.followupID, m.review)
			case "esc":
				// Cancel: discard changes.
				m.editing = false
				return m, nil
			case "alt+enter":
				// Insert a literal newline into the textarea.
				m.editInput.InsertRune('\n')
				return m, nil
			default:
				var cmd tea.Cmd
				m.editInput, cmd = m.editInput.Update(msg)
				return m, cmd
			}
		}

		visible := m.visibleComments()
		switch msg.String() {
		case "j", "down":
			if m.cursor == -1 {
				// Move from general card to first inline comment.
				if len(visible) > 0 {
					m.cursor = 0
				}
			} else if m.cursor < len(visible)-1 {
				m.cursor++
			}
		case "k", "up":
			if m.cursor > 0 {
				m.cursor--
			} else if m.cursor == 0 && m.hasGeneralCard() {
				// Move up from first inline comment to general card.
				m.cursor = -1
			}
		case " ", "x", "enter":
			if m.cursor == -1 && m.hasGeneralCard() {
				// Toggle ReviewBodySelected on the general comment card.
				m.review.ReviewBodySelected = !m.review.ReviewBodySelected
				return m, WriteSidecarCmd(m.knowledgeDir, m.followupID, m.review)
			}
			// Toggle selection on the current inline comment (via backing index).
			if m.cursor >= 0 && m.cursor < len(visible) {
				backingIdx := visible[m.cursor]
				m.comments[backingIdx].Selected = !m.comments[backingIdx].Selected
				// Sync back to the review so the sidecar write is consistent.
				if m.review != nil && backingIdx < len(m.review.Comments) {
					m.review.Comments[backingIdx].Selected = m.comments[backingIdx].Selected
				}
				return m, WriteSidecarCmd(m.knowledgeDir, m.followupID, m.review)
			}
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
		case "e":
			// Enter inline textarea edit mode for the focused card body.
			if m.editing || m.externalEditing {
				break
			}
			if m.cursor == -1 && m.hasGeneralCard() {
				// Edit general comment (ReviewBody).
				ta := newInlineTextarea(m.width)
				ta.SetValue(m.review.ReviewBody)
				m.editInput = ta
				m.editIdx = -1
				m.editing = true
				return m, m.editInput.Focus()
			}
			if m.cursor < 0 || m.cursor >= len(visible) {
				break
			}
			backingIdx := visible[m.cursor]
			ta := newInlineTextarea(m.width)
			ta.SetValue(m.comments[backingIdx].Body)
			m.editInput = ta
			m.editIdx = backingIdx
			m.editing = true
			return m, m.editInput.Focus()
		case "1":
			if m.review != nil && m.review.ReviewEvent != "COMMENT" {
				m.review.ReviewEvent = "COMMENT"
				return m, WriteSidecarCmd(m.knowledgeDir, m.followupID, m.review)
			}
		case "2":
			if m.review != nil && m.review.ReviewEvent != "APPROVE" {
				m.review.ReviewEvent = "APPROVE"
				return m, WriteSidecarCmd(m.knowledgeDir, m.followupID, m.review)
			}
		case "3":
			if m.review != nil && m.review.ReviewEvent != "REQUEST_CHANGES" {
				m.review.ReviewEvent = "REQUEST_CHANGES"
				return m, WriteSidecarCmd(m.knowledgeDir, m.followupID, m.review)
			}
		case "E":
			// Open current comment body in external editor. cursor == -1 edits the
			// general review body (the same target as inline `e` on the general card).
			if m.externalEditing || m.editing {
				break
			}
			editor := os.Getenv("EDITOR")
			if editor == "" {
				m.flashMsg = "EDITOR not set"
				break
			}
			if m.cursor == -1 && m.hasGeneralCard() {
				m.externalEditing = true
				body := m.review.ReviewBody
				return m, func() tea.Msg {
					return ExternalEditRequestMsg{BackingIdx: -1, Body: body}
				}
			}
			if m.IsEmpty() || m.cursor < 0 || m.cursor >= len(visible) {
				break
			}
			backingIdx := visible[m.cursor]
			m.externalEditing = true
			return m, func() tea.Msg {
				return ExternalEditRequestMsg{BackingIdx: backingIdx, Body: m.comments[backingIdx].Body}
			}
		case "g":
			if m.generatingSummary {
				m.flashMsg = "summary already generating"
				break
			}
			if m.SelectedCount() == 0 {
				m.flashMsg = "No comments selected — nothing to summarize."
				break
			}
			m.generatingSummary = true
			hash := currentSelectionHash(m.comments)
			followupID := m.followupID
			return m, func() tea.Msg {
				return SummaryRequestMsg{FollowupID: followupID, SelectionHash: hash}
			}
		}
	}
	return m, nil
}

func (m ReviewCardsModel) View() string {
	if m.IsEmpty() && !m.hasGeneralCard() {
		return lipgloss.NewStyle().Foreground(lipgloss.Color("8")).Render("  No proposed comments.")
	}

	dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	selectedBg := lipgloss.NewStyle().Background(lipgloss.Color("237")).Bold(true)
	pathStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("6"))
	sevHigh := lipgloss.NewStyle().Foreground(lipgloss.Color("1")).Bold(true)
	sevMed := lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	sevLow := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	generalLabelStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("5")).Bold(true)

	visible := m.visibleComments()

	var b strings.Builder

	// Header: selection count. Merge-status badge is rendered by DetailModel
	// next to the tab bar so it is visible from any tab.
	b.WriteString(dimStyle.Render(fmt.Sprintf("  %d/%d selected", m.SelectedCount(), m.TotalCount())))
	b.WriteString("\n\n")

	// PR Review box — groups event type radio buttons and general comment card
	// inside a bordered box, visually separating them from inline comments.
	if m.hasGeneralCard() {
		var box strings.Builder

		// Event type radio buttons
		activeStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("4")).Bold(true)
		events := []struct {
			key, label, value string
		}{
			{"1", "Comment", "COMMENT"},
			{"2", "Approve", "APPROVE"},
			{"3", "Request Changes", "REQUEST_CHANGES"},
		}
		eventLine := "  "
		for i, ev := range events {
			radio := "○"
			label := dimStyle.Render(fmt.Sprintf("%s %s %s", radio, ev.key, ev.label))
			if m.review.ReviewEvent == ev.value {
				radio = "●"
				label = activeStyle.Render(fmt.Sprintf("%s %s %s", radio, ev.key, ev.label))
			}
			eventLine += label
			if i < len(events)-1 {
				eventLine += "   "
			}
		}
		box.WriteString(eventLine)
		box.WriteString("\n\n")

		// General comment card
		check := "[ ]"
		if m.review.ReviewBodySelected {
			check = "[x]"
		}
		editingGeneral := m.editing && m.editIdx == -1
		label := generalLabelStyle.Render("General Comment")
		summaryPresent := strings.Contains(m.review.ReviewBody, "<!-- lore-summary -->") &&
			strings.Contains(m.review.ReviewBody, "<!-- /lore-summary -->")
		if summaryPresent && m.review.SummarySelectionHash != "" &&
			currentSelectionHash(m.comments) != m.review.SummarySelectionHash {
			label += dimStyle.Render(" (stale)")
		}
		if editingGeneral {
			label = generalLabelStyle.Render("General Comment") + dimStyle.Render(" [editing — Enter to save, Esc to cancel]")
		}
		line1 := fmt.Sprintf("  %s %s", check, label)

		if m.cursor == -1 {
			box.WriteString(selectedBg.Render(line1))
			box.WriteByte('\n')
		} else {
			box.WriteString(line1)
			box.WriteByte('\n')
		}

		if m.generatingSummary {
			genLine := dimStyle.Render("    generating summary…")
			if m.cursor == -1 {
				box.WriteString(selectedBg.Render(genLine))
			} else {
				box.WriteString(genLine)
			}
			box.WriteByte('\n')
		}

		if editingGeneral {
			box.WriteString("      ")
			box.WriteString(m.editInput.View())
			box.WriteByte('\n')
		} else {
			bodyW := m.width - 12 // account for border + indent
			var bodyLines []string
			if m.review.ReviewBody == "" {
				bodyLines = []string{dimStyle.Render("      No general review comment — press e to add one")}
			} else {
				for _, bl := range m.wrapBody(m.review.ReviewBody, bodyW) {
					bodyLines = append(bodyLines, dimStyle.Render("      "+bl))
				}
			}
			// Cap the general body: when focused, show up to half the tab height;
			// when unfocused, collapse to a single indicator so inline cards stay
			// visible during navigation. Full content is always accessible via E
			// (external edit) or e (inline edit) once the card is focused.
			if len(bodyLines) > 0 {
				var maxBody int
				if m.cursor == -1 {
					maxBody = m.height / 2
					if maxBody < 3 {
						maxBody = 3
					}
				} else {
					maxBody = 1
				}
				if len(bodyLines) > maxBody {
					if maxBody == 1 {
						bodyLines = []string{dimStyle.Render(
							fmt.Sprintf("      … general comment written (%d lines) — ↑ to focus, E to view", len(bodyLines)))}
					} else {
						hidden := len(bodyLines) - (maxBody - 1)
						bodyLines = append(bodyLines[:maxBody-1],
							dimStyle.Render(fmt.Sprintf("      … %d more line(s) — press E to view full summary", hidden)))
					}
				}
			}
			if m.cursor == -1 {
				for _, bl := range bodyLines {
					box.WriteString(selectedBg.Render(bl))
					box.WriteByte('\n')
				}
			} else {
				for _, bl := range bodyLines {
					box.WriteString(bl)
					box.WriteByte('\n')
				}
			}
		}

		// Render the box with a rounded border
		boxW := m.width - 2
		if boxW < 20 {
			boxW = 20
		}
		borderStyle := lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.Color("8")).
			Width(boxW - 2) // subtract border width
		b.WriteString(borderStyle.Render(box.String()))
		b.WriteString("\n")
	}

	// When filter is active but no inline comments match, show a hint.
	if len(visible) == 0 {
		b.WriteString(dimStyle.Render("  No comments match filter."))
		b.WriteString("\n")
	} else {
		// Budget-based windowing: subtract the height of everything already rendered
		// (selection header + general-comment box) so a large general body — e.g.,
		// after `g` splices a thematic summary in — does not push inline cards off
		// the bottom without scrolling. When the general card has already claimed
		// the full height, still reserve enough for the cursor card so navigation
		// stays visible.
		headerHeight := lipgloss.Height(b.String())
		budget := m.height - headerHeight
		if budget < 1 {
			budget = 1
		}

		// Pre-compute card heights for visible comments only.
		heights := make([]int, len(visible))
		for i, backingIdx := range visible {
			heights[i] = m.cardHeight(backingIdx)
		}

		// When the general card is focused (cursor == -1), start the inline window from 0.
		cursorInVisible := m.cursor
		if cursorInVisible < 0 {
			cursorInVisible = 0
		}

		// Walk outward from cursor (position in visible slice).
		offset := cursorInVisible
		end := cursorInVisible + 1
		used := heights[cursorInVisible]

		lo, hi := cursorInVisible-1, cursorInVisible+1
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

			// Optional title line: [x] <severity> #<ordinal> — <title>
			var titleLine string
			if c.Title != "" {
				titleLine = fmt.Sprintf("  %s %s #%d \u2014 %s", check, sevStr, c.FindingOrdinal, c.Title)
			}

			// Location line: checkbox + path:line + severity [lenses] confidence%.
			// When a title line is present it already owns the checkbox, so align
			// with blanks here to avoid rendering two checkboxes per card.
			var lensToken, confToken string
			if len(c.Lenses) > 0 {
				lensToken = "  " + dimStyle.Render("["+strings.Join(c.Lenses, ",")+"]")
			}
			if c.Confidence > 0 {
				confToken = "  " + dimStyle.Render(fmt.Sprintf("%d%%", int(c.Confidence*100)))
			}
			locCheck := check
			if c.Title != "" {
				locCheck = "   "
			}
			line1 := fmt.Sprintf("  %s %s:%d  %s",
				locCheck,
				pathStyle.Render(c.Path),
				c.Line,
				sevStr,
			) + lensToken + confToken

			editingThis := m.editing && m.editIdx == backingIdx

			focused := m.cursor >= 0 && visPos == m.cursor

			var card strings.Builder
			if c.Title != "" {
				if focused {
					card.WriteString(selectedBg.Render(titleLine))
				} else {
					card.WriteString(titleLine)
				}
				card.WriteByte('\n')
			}
			if focused {
				headerLine := line1
				if editingThis {
					headerLine = line1 + dimStyle.Render(" [editing — Enter to save, Esc to cancel]")
				}
				card.WriteString(selectedBg.Render(headerLine))
				card.WriteByte('\n')
			} else {
				card.WriteString(line1)
				card.WriteByte('\n')
			}

			if editingThis {
				// Render inline textarea indented to match body.
				card.WriteString("      ")
				card.WriteString(m.editInput.View())
				card.WriteByte('\n')
			} else {
				// Body: word-wrap the full text to the available width.
				bodyW := m.width - 8 // 6 indent + 2 margin
				bodyLines := m.wrapBody(c.Body, bodyW)
				if focused {
					for _, bl := range bodyLines {
						card.WriteString(selectedBg.Render(dimStyle.Render("      " + bl)))
						card.WriteByte('\n')
					}
				} else {
					for _, bl := range bodyLines {
						card.WriteString(dimStyle.Render("      " + bl))
						card.WriteByte('\n')
					}
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


	return b.String()
}

// cardHeight returns the number of terminal lines a single card renders.
// When the card is being edited inline, returns header(1) + textarea height.
func (m ReviewCardsModel) cardHeight(idx int) int {
	titleLineCount := 0
	if m.comments[idx].Title != "" {
		titleLineCount = 1
	}
	if m.editing && m.editIdx == idx {
		return titleLineCount + 1 + m.editInput.Height()
	}
	bodyW := m.width - 8
	bodyLines := m.wrapBody(m.comments[idx].Body, bodyW)
	return titleLineCount + 1 + len(bodyLines) // title (optional) + header + wrapped body lines
}

// newInlineTextarea creates a textarea pre-configured for inline comment body editing.
func newInlineTextarea(width int) textarea.Model {
	ta := textarea.New()
	ta.Placeholder = ""
	ta.Prompt = " "
	ta.ShowLineNumbers = false
	ta.CharLimit = 0
	w := width - 8 // match body indent
	if w < 20 {
		w = 20
	}
	ta.SetWidth(w)
	ta.SetHeight(6)
	return ta
}

// currentSelectionHash returns a stable hex digest of the selected comment set.
// Hashes path:line:body for each selected comment (sorted) so the hash is
// independent of ordering and insensitive to severity/confidence changes.
func currentSelectionHash(cs []ProposedComment) string {
	var parts []string
	for _, c := range cs {
		if c.Selected {
			parts = append(parts, fmt.Sprintf("%s:%d:%s", c.Path, c.Line, c.Body))
		}
	}
	sort.Strings(parts)
	sum := sha256.Sum256([]byte(strings.Join(parts, "\n")))
	return hex.EncodeToString(sum[:])
}

// spliceSummary replaces the content between <!-- lore-summary --> and
// <!-- /lore-summary --> sentinels in body with newSummary. If the sentinel
// pair is absent, the block is appended. Prose outside the sentinels is preserved.
func spliceSummary(body, newSummary string) string {
	const open = "<!-- lore-summary -->"
	const close = "<!-- /lore-summary -->"
	block := "\n" + open + "\n" + newSummary + "\n" + close + "\n"
	if lo := strings.Index(body, open); lo >= 0 {
		if hi := strings.Index(body[lo:], close); hi >= 0 {
			hi += lo + len(close)
			return body[:lo] + block + body[hi:]
		}
	}
	return body + block
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

