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

// DispositionFilter controls which findings are visible by disposition.
type DispositionFilter int

const (
	DispFilterAll      DispositionFilter = 0
	DispFilterAction   DispositionFilter = 1
	DispFilterAccepted DispositionFilter = 2
	DispFilterDeferred DispositionFilter = 3
	DispFilterOpen     DispositionFilter = 4
)

// LensFindingsModel is the Bubble Tea model for lens review findings.
// It renders finding cards with cursor navigation and disposition filtering,
// following the budget-based windowing pattern from ReviewCardsModel.
type LensFindingsModel struct {
	review          *LensReview
	findings        []LensFinding
	cursor          int
	width           int
	height          int
	filter          DispositionFilter
	knowledgeDir    string
	followupID      string
	sevSelectCycle  int // tracks S-cycle position: 0=all, 1=blocking, 2=suggestion, 3=question
}

// NewLensFindingsModel creates a LensFindingsModel from a loaded LensReview.
// knowledgeDir and followupID are required for write-back via WriteLensSidecarCmd.
// Caller ensures review is non-nil.
func NewLensFindingsModel(knowledgeDir, followupID string, review *LensReview) LensFindingsModel {
	m := LensFindingsModel{
		review:       review,
		findings:     review.Findings,
		knowledgeDir: knowledgeDir,
		followupID:   followupID,
	}
	return m
}

// SetSize updates the available rendering dimensions.
func (m *LensFindingsModel) SetSize(w, h int) {
	m.width = w
	m.height = h
}

func (m LensFindingsModel) Init() tea.Cmd {
	return nil
}

// visibleFindings returns indices into m.findings matching the current filter.
func (m LensFindingsModel) visibleFindings() []int {
	out := make([]int, 0, len(m.findings))
	for i, f := range m.findings {
		var visible bool
		switch m.filter {
		case DispFilterAction:
			visible = f.Disposition == "action"
		case DispFilterAccepted:
			visible = f.Disposition == "accepted"
		case DispFilterDeferred:
			visible = f.Disposition == "deferred"
		case DispFilterOpen:
			visible = f.Disposition == "open"
		default:
			visible = true
		}
		// Unknown dispositions are always visible under a named filter.
		if m.filter != DispFilterAll {
			switch f.Disposition {
			case "action", "accepted", "deferred", "open":
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

func (m LensFindingsModel) Update(msg tea.Msg) (LensFindingsModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

	case tea.KeyMsg:
		visible := m.visibleFindings()
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
		case "f":
			// Cycle disposition filter: all → action → accepted → deferred → open → all.
			m.filter = DispositionFilter((int(m.filter) + 1) % 5)
			m.cursor = 0
		case " ", "x", "enter":
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
		case "i":
			// Invert all selections.
			if m.review != nil {
				for i := range m.findings {
					m.findings[i].Selected = !m.findings[i].Selected
					if i < len(m.review.Findings) {
						m.review.Findings[i].Selected = m.findings[i].Selected
					}
				}
				return m, WriteLensSidecarCmd(m.knowledgeDir, m.followupID, m.review)
			}
		case "S":
			// Advance severity-select cycle (0=all, 1=blocking, 2=suggestion, 3=question).
			if m.review != nil {
				m.sevSelectCycle = (m.sevSelectCycle + 1) % 4
				for i := range m.findings {
					var selected bool
					switch m.sevSelectCycle {
					case 0:
						selected = true
					case 1:
						selected = m.findings[i].Severity == "blocking"
					case 2:
						selected = m.findings[i].Severity == "suggestion"
					case 3:
						selected = m.findings[i].Severity == "question"
					}
					m.findings[i].Selected = selected
				}
				for i := range m.review.Findings {
					m.review.Findings[i].Selected = m.findings[i].Selected
				}
				return m, WriteLensSidecarCmd(m.knowledgeDir, m.followupID, m.review)
			}
		}
	}
	return m, nil
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

	// Header: selection count + filter
	filterLabel := "all"
	switch m.filter {
	case DispFilterAction:
		filterLabel = "action"
	case DispFilterAccepted:
		filterLabel = "accepted"
	case DispFilterDeferred:
		filterLabel = "deferred"
	case DispFilterOpen:
		filterLabel = "open"
	}
	header := fmt.Sprintf("  %d/%d selected | %d visible | filter: %s", m.selectedCount(), len(m.findings), len(visible), filterLabel)
	b.WriteString(dimStyle.Render(header))
	b.WriteString("\n\n")

	if len(visible) == 0 {
		b.WriteString(dimStyle.Render("  No findings match filter."))
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
func (m LensFindingsModel) cardHeight(idx int) int {
	bodyW := m.width - 8
	bodyLines := m.wrapBody(m.findings[idx].Body, bodyW)
	h := 1 + len(bodyLines) // header + body
	if m.findings[idx].Rationale != "" {
		h += len(m.wrapBody("rationale: "+m.findings[idx].Rationale, bodyW))
	}
	return h
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
