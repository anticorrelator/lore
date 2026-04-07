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

// WriteLensSidecarMsg is sent after an async write of lens-findings.json completes.
type WriteLensSidecarMsg struct {
	Err error
}

// WriteLensSidecarCmd writes the full LensReview back to lens-findings.json.
func WriteLensSidecarCmd(knowledgeDir, followupID string, review *LensReview) tea.Cmd {
	return func() tea.Msg {
		itemDir := filepath.Join(knowledgeDir, "_followups", followupID)
		data, err := json.MarshalIndent(review, "", "  ")
		if err != nil {
			return WriteLensSidecarMsg{Err: fmt.Errorf("marshaling lens sidecar: %w", err)}
		}
		if err := os.WriteFile(filepath.Join(itemDir, "lens-findings.json"), data, 0644); err != nil {
			return WriteLensSidecarMsg{Err: fmt.Errorf("writing lens sidecar: %w", err)}
		}
		return WriteLensSidecarMsg{}
	}
}

// actionMenuMode tracks which layer of the inline action menu is active.
type actionMenuMode int

const (
	actionMenuNone        actionMenuMode = iota
	actionMenuMain                       // top-level menu (chat / disposition)
	actionMenuDisposition                // disposition sub-menu
)

// LensFindingsModel is the Bubble Tea model for lens review findings.
// It renders finding cards with cursor navigation,
// following the budget-based windowing pattern from ReviewCardsModel.
type LensFindingsModel struct {
	review         *LensReview
	findings       []LensFinding
	cursor         int
	width          int
	height         int
	knowledgeDir   string
	followupID     string
	actionMenuOpen bool
	actionMenu     actionMenuMode
}

// NewLensFindingsModel creates a LensFindingsModel from a loaded LensReview.
// knowledgeDir and followupID are required for write-back via WriteLensSidecarCmd.
// Caller ensures review is non-nil.
//
// Pre-seeding: when no finding is already selected (fresh review), accepted
// and deferred findings are pre-selected so they appear ready-to-promote by
// default. action, open, and unknown dispositions start unselected.
func NewLensFindingsModel(knowledgeDir, followupID string, review *LensReview) LensFindingsModel {
	if !hasExistingSelections(review.Findings) {
		for i := range review.Findings {
			switch review.Findings[i].Disposition {
			case "accepted", "deferred":
				review.Findings[i].Selected = true
			}
		}
	}
	m := LensFindingsModel{
		review:       review,
		findings:     review.Findings,
		knowledgeDir: knowledgeDir,
		followupID:   followupID,
	}
	return m
}

// hasExistingSelections reports whether any finding has Selected == true.
// Used to determine whether pre-seeding should be applied.
func hasExistingSelections(findings []LensFinding) bool {
	for _, f := range findings {
		if f.Selected {
			return true
		}
	}
	return false
}

// SetSize updates the available rendering dimensions.
func (m *LensFindingsModel) SetSize(w, h int) {
	m.width = w
	m.height = h
}

func (m LensFindingsModel) Init() tea.Cmd {
	return nil
}

// visibleFindings returns indices into m.findings (all findings are visible).
func (m LensFindingsModel) visibleFindings() []int {
	out := make([]int, len(m.findings))
	for i := range m.findings {
		out[i] = i
	}
	return out
}

func (m LensFindingsModel) Update(msg tea.Msg) (LensFindingsModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

	case tea.KeyMsg:
		visible := m.visibleFindings()

		// Action menu is open: intercept keys before normal navigation.
		if m.actionMenuOpen {
			if m.actionMenu == actionMenuDisposition {
				// Disposition sub-menu: set disposition and sync selection per state table.
				// State table: action→selected=false, accepted→selected=true,
				//              deferred→selected=true, open→selected=false.
				var newDisp string
				switch msg.String() {
				case "a":
					newDisp = "action"
				case "enter":
					// Enter confirms/accepts the current finding (ok).
					newDisp = "accepted"
				case "d":
					newDisp = "deferred"
				case "?":
					newDisp = "open"
				case "esc":
					// Back to main menu.
					m.actionMenu = actionMenuMain
					return m, nil
				default:
					// Swallow.
					return m, nil
				}
				if newDisp != "" && m.cursor >= 0 && m.cursor < len(visible) {
					backingIdx := visible[m.cursor]
					m.findings[backingIdx].Disposition = newDisp
					switch newDisp {
					case "accepted", "deferred":
						m.findings[backingIdx].Selected = true
					default:
						m.findings[backingIdx].Selected = false
					}
					if m.review != nil && backingIdx < len(m.review.Findings) {
						m.review.Findings[backingIdx].Disposition = newDisp
						m.review.Findings[backingIdx].Selected = m.findings[backingIdx].Selected
					}
					m.actionMenuOpen = false
					m.actionMenu = actionMenuNone
					return m, WriteLensSidecarCmd(m.knowledgeDir, m.followupID, m.review)
				}
				m.actionMenuOpen = false
				m.actionMenu = actionMenuNone
				return m, nil
			}

			// actionMenuMain layer.
			switch msg.String() {
			case "esc", "enter":
				m.actionMenuOpen = false
				m.actionMenu = actionMenuNone
			case "d":
				// Open disposition sub-menu.
				m.actionMenu = actionMenuDisposition
			case "c":
				// Chat about this finding (no pre-filled prompt).
				if m.cursor >= 0 && m.cursor < len(visible) {
					backingIdx := visible[m.cursor]
					m.actionMenuOpen = false
					m.actionMenu = actionMenuNone
					chatMsg := FollowupChatRequestMsg{
						ID:           m.followupID,
						FindingIndex: backingIdx,
						EditPrompt:   "",
					}
					return m, func() tea.Msg { return chatMsg }
				}
			case "e":
				// Chat about this finding with a pre-filled edit prompt.
				if m.cursor >= 0 && m.cursor < len(visible) {
					backingIdx := visible[m.cursor]
					f := m.findings[backingIdx]
					editPrompt := buildFindingEditPrompt(f)
					m.actionMenuOpen = false
					m.actionMenu = actionMenuNone
					chatMsg := FollowupChatRequestMsg{
						ID:           m.followupID,
						FindingIndex: backingIdx,
						EditPrompt:   editPrompt,
					}
					return m, func() tea.Msg { return chatMsg }
				}
			case "j", "down":
				m.actionMenuOpen = false
				m.actionMenu = actionMenuNone
				if m.cursor < len(visible)-1 {
					m.cursor++
				}
			case "k", "up":
				m.actionMenuOpen = false
				m.actionMenu = actionMenuNone
				if m.cursor > 0 {
					m.cursor--
				}
			}
			// All other keys are swallowed while menu is open.
			return m, nil
		}

		switch msg.String() {
		case "enter":
			// Open the action menu at the main layer.
			if m.cursor >= 0 && m.cursor < len(visible) {
				m.actionMenuOpen = true
				m.actionMenu = actionMenuMain
			}
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
		case " ", "x":
			// Toggle selection on the current finding (via backing index).
			if m.cursor >= 0 && m.cursor < len(visible) {
				backingIdx := visible[m.cursor]
				m.findings[backingIdx].Selected = !m.findings[backingIdx].Selected
				// Sync back to the review so the sidecar write is consistent.
				if m.review != nil && backingIdx < len(m.review.Findings) {
					m.review.Findings[backingIdx].Selected = m.findings[backingIdx].Selected
				}
				return m, WriteLensSidecarCmd(m.knowledgeDir, m.followupID, m.review)
			}
		case "a":
			// Toggle select-all / deselect-all over all findings.
			if m.review != nil {
				allSelected := m.selectedCount() == len(m.findings)
				target := !allSelected
				for i := range m.findings {
					m.findings[i].Selected = target
				}
				for i := range m.review.Findings {
					m.review.Findings[i].Selected = target
				}
				return m, WriteLensSidecarCmd(m.knowledgeDir, m.followupID, m.review)
			}
		case "c":
			// Discuss this finding: open a finding-scoped chat without a pre-filled prompt.
			if m.cursor >= 0 && m.cursor < len(visible) {
				backingIdx := visible[m.cursor]
				id := m.followupID
				return m, func() tea.Msg {
					return FollowupChatRequestMsg{
						ID:           id,
						FindingIndex: backingIdx,
						EditPrompt:   "",
					}
				}
			}
		case "e":
			// Edit prompt for this finding: open a finding-scoped chat with a pre-filled prompt.
			if m.cursor >= 0 && m.cursor < len(visible) {
				backingIdx := visible[m.cursor]
				f := m.findings[backingIdx]
				prompt := buildFindingEditPrompt(f)
				id := m.followupID
				return m, func() tea.Msg {
					return FollowupChatRequestMsg{
						ID:           id,
						FindingIndex: backingIdx,
						EditPrompt:   prompt,
					}
				}
			}
		}
	}
	return m, nil
}

// ActionMenuOpen returns true when the inline action menu is open.
func (m LensFindingsModel) ActionMenuOpen() bool {
	return m.actionMenuOpen
}

// selectedCount returns the number of findings currently selected.
func (m LensFindingsModel) selectedCount() int {
	n := 0
	for _, f := range m.findings {
		if f.Selected {
			n++
		}
	}
	return n
}

// SelectedLensFindings returns a copy of findings where Selected is true.
func (m LensFindingsModel) SelectedLensFindings() []LensFinding {
	out := make([]LensFinding, 0, len(m.findings))
	for _, f := range m.findings {
		if f.Selected {
			out = append(out, f)
		}
	}
	return out
}

// AllLensFindings returns a copy of all findings regardless of selection state.
func (m LensFindingsModel) AllLensFindings() []LensFinding {
	out := make([]LensFinding, len(m.findings))
	copy(out, m.findings)
	return out
}

func (m LensFindingsModel) View() string {
	if len(m.findings) == 0 {
		return lipgloss.NewStyle().Foreground(lipgloss.Color("8")).Render("  No lens findings.")
	}

	dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	selectedBg := lipgloss.NewStyle().Background(lipgloss.Color("237")).Bold(true)
	pathStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("6"))

	// Severity styles
	sevBlocking := lipgloss.NewStyle().Foreground(lipgloss.Color("1")).Bold(true)
	sevSuggestion := lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	sevQuestion := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))

	// Disposition styles
	dispAction := lipgloss.NewStyle().Foreground(lipgloss.Color("3"))   // yellow
	dispAccepted := lipgloss.NewStyle().Foreground(lipgloss.Color("2")) // green
	dispDeferred := lipgloss.NewStyle().Foreground(lipgloss.Color("8")) // dim
	dispOpen := lipgloss.NewStyle().Foreground(lipgloss.Color("6"))     // cyan

	visible := m.visibleFindings()

	var b strings.Builder

	// Header: selection count
	header := fmt.Sprintf("  %d/%d selected", m.selectedCount(), len(m.findings))
	b.WriteString(dimStyle.Render(header))
	b.WriteString("\n\n")

	if len(visible) == 0 {
		b.WriteString(dimStyle.Render("  No findings."))
		b.WriteString("\n")
	} else {
		// Budget-based windowing
		budget := m.height - 3
		if budget < 1 {
			budget = 1<<31 - 1
		}

		heights := make([]int, len(visible))
		for i, backingIdx := range visible {
			heights[i] = m.cardHeight(backingIdx)
		}

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
			f := m.findings[backingIdx]

			// Disposition indicator
			var dispStr string
			switch f.Disposition {
			case "action":
				dispStr = dispAction.Render("[act]")
			case "accepted":
				dispStr = dispAccepted.Render("[ok]")
			case "deferred":
				dispStr = dispDeferred.Render("[def]")
			case "open":
				dispStr = dispOpen.Render("[?]")
			default:
				dispStr = dimStyle.Render("[" + f.Disposition + "]")
			}

			// Severity coloring
			var sevStr string
			switch f.Severity {
			case "blocking":
				sevStr = sevBlocking.Render(f.Severity)
			case "suggestion":
				sevStr = sevSuggestion.Render(f.Severity)
			case "question":
				sevStr = sevQuestion.Render(f.Severity)
			default:
				sevStr = dimStyle.Render(f.Severity)
			}

			// File path with optional line
			filePart := pathStyle.Render(f.File)
			if f.Line > 0 {
				filePart = pathStyle.Render(fmt.Sprintf("%s:%d", f.File, f.Line))
			}

			// Lens tag
			lensStr := dimStyle.Render("[" + f.Lens + "]")

			// Checkbox
			check := "[ ]"
			if f.Selected {
				check = "[x]"
			}

			// Header line: checkbox [disp] file:line  severity  [lens]
			line1 := fmt.Sprintf("  %s %s %s  %s  %s", check, dispStr, filePart, sevStr, lensStr)

			// Body: word-wrap
			bodyW := m.width - 8
			bodyLines := m.wrapBody(f.Body, bodyW)

			// Rationale (optional)
			var rationaleLines []string
			if f.Rationale != "" {
				rationaleLines = m.wrapBody("rationale: "+f.Rationale, bodyW)
			}

			var card strings.Builder
			if visPos == m.cursor {
				card.WriteString(selectedBg.Render(line1))
				card.WriteByte('\n')
				for _, bl := range bodyLines {
					card.WriteString(selectedBg.Render(dimStyle.Render("      " + bl)))
					card.WriteByte('\n')
				}
				for _, rl := range rationaleLines {
					card.WriteString(selectedBg.Render(lipgloss.NewStyle().Foreground(lipgloss.Color("8")).Italic(true).Render("      " + rl)))
					card.WriteByte('\n')
				}
				if m.actionMenuOpen {
					accentStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("4"))
					var menuRow string
					switch m.actionMenu {
					case actionMenuDisposition:
						menuRow = fmt.Sprintf("  ↳ %s  %s  %s  %s",
							accentStyle.Render("(a)ction"),
							accentStyle.Render("ok"),
							accentStyle.Render("(d)efer"),
							accentStyle.Render("(?)open"),
						)
					default: // actionMenuMain
						menuRow = fmt.Sprintf("  ↳ %s  %s  %s",
							accentStyle.Render("(c)hat"),
							accentStyle.Render("(d)isposition"),
							accentStyle.Render("(e)dit & chat"),
						)
					}
					card.WriteString(menuRow)
					card.WriteByte('\n')
				}
			} else {
				card.WriteString(line1)
				card.WriteByte('\n')
				for _, bl := range bodyLines {
					card.WriteString(dimStyle.Render("      " + bl))
					card.WriteByte('\n')
				}
				for _, rl := range rationaleLines {
					card.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("8")).Italic(true).Render("      " + rl))
					card.WriteByte('\n')
				}
			}

			b.WriteString(card.String())
		}
	}

	return b.String()
}

// cardHeight returns the number of terminal lines a single card renders.
// The action menu row adds one line when the menu is open for the cursor card.
func (m LensFindingsModel) cardHeight(idx int) int {
	bodyW := m.width - 8
	bodyLines := m.wrapBody(m.findings[idx].Body, bodyW)
	h := 1 + len(bodyLines) // header + body
	if m.findings[idx].Rationale != "" {
		h += len(m.wrapBody("rationale: "+m.findings[idx].Rationale, bodyW))
	}
	if m.actionMenuOpen && idx == m.cursor {
		h++ // action menu row
	}
	return h
}

// buildFindingEditPrompt returns a default pre-filled prompt for the 'e' key handler.
// Format: "<title> [file:line]: <body excerpt>"
func buildFindingEditPrompt(f LensFinding) string {
	location := f.File
	if f.Line > 0 {
		location = fmt.Sprintf("%s:%d", f.File, f.Line)
	}
	excerpt := f.Body
	if len(excerpt) > 120 {
		excerpt = excerpt[:120] + "..."
	}
	if location != "" {
		return fmt.Sprintf("%s [%s]: %s", f.Title, location, excerpt)
	}
	return fmt.Sprintf("%s: %s", f.Title, excerpt)
}

// wrapBody splits text into word-wrapped lines.
func (m LensFindingsModel) wrapBody(body string, width int) []string {
	if width <= 0 {
		width = 72
	}
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
