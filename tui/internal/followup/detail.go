package followup

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/anticorrelator/lore/tui/internal/render"
)

// FollowUpDetail holds the full content of a single follow-up artifact.
type FollowUpDetail struct {
	ID               string            `json:"id"`
	Title            string            `json:"title"`
	Status           string            `json:"status"`
	Severity         string            `json:"severity"`
	Source           string            `json:"source"`
	Attachments      []Attachment      `json:"attachments"`
	SuggestedActions []SuggestedAction `json:"suggested_actions"`
	Created          string            `json:"created"`
	Updated          string            `json:"updated"`
	PromotedTo       string            `json:"promoted_to"`
	FindingContent   string            // contents of finding.md
}

// DetailLoadedMsg is sent when detail loading finishes.
type DetailLoadedMsg struct {
	ID     string
	Detail *FollowUpDetail
	Err    error
}

// followUpMeta mirrors the _meta.json schema for a follow-up item.
type followUpMeta struct {
	ID               string            `json:"id"`
	Title            string            `json:"title"`
	Status           string            `json:"status"`
	Severity         string            `json:"severity"`
	Source           string            `json:"source"`
	Attachments      []Attachment      `json:"attachments"`
	SuggestedActions []SuggestedAction `json:"suggested_actions"`
	Created          string            `json:"created"`
	Updated          string            `json:"updated"`
	PromotedTo       string            `json:"promoted_to"`
}

// LoadFollowUpDetail reads a single follow-up's _meta.json and finding.md
// from disk and returns a FollowUpDetail.
func LoadFollowUpDetail(knowledgeDir, id string) (*FollowUpDetail, error) {
	itemDir := filepath.Join(knowledgeDir, "_followups", id)
	metaPath := filepath.Join(itemDir, "_meta.json")

	metaBytes, err := os.ReadFile(metaPath)
	if err != nil {
		return nil, fmt.Errorf("reading _meta.json for %s: %w", id, err)
	}

	var meta followUpMeta
	if err := json.Unmarshal(metaBytes, &meta); err != nil {
		return nil, fmt.Errorf("parsing _meta.json for %s: %w", id, err)
	}

	if meta.Attachments == nil {
		meta.Attachments = []Attachment{}
	}
	if meta.SuggestedActions == nil {
		meta.SuggestedActions = []SuggestedAction{}
	}

	detail := &FollowUpDetail{
		ID:               meta.ID,
		Title:            meta.Title,
		Status:           meta.Status,
		Severity:         meta.Severity,
		Source:           meta.Source,
		Attachments:      meta.Attachments,
		SuggestedActions: meta.SuggestedActions,
		Created:          meta.Created,
		Updated:          meta.Updated,
		PromotedTo:       meta.PromotedTo,
	}

	if data, err := os.ReadFile(filepath.Join(itemDir, "finding.md")); err == nil {
		detail.FindingContent = string(data)
	}

	return detail, nil
}

// DetailModel is the Bubble Tea model for the follow-up detail pane.
type DetailModel struct {
	knowledgeDir string
	id           string
	detail       *FollowUpDetail
	loading      bool
	err          error
	viewport     viewport.Model
	width        int
	height       int
}

// NewDetailModel creates a DetailModel. Call LoadDetail to populate it.
func NewDetailModel(knowledgeDir string) DetailModel {
	return DetailModel{
		knowledgeDir: knowledgeDir,
	}
}

// LoadDetail returns a Cmd that reads a follow-up from disk.
func LoadDetail(knowledgeDir, id string) tea.Cmd {
	return func() tea.Msg {
		detail, err := LoadFollowUpDetail(knowledgeDir, id)
		return DetailLoadedMsg{ID: id, Detail: detail, Err: err}
	}
}

func (m DetailModel) Init() tea.Cmd {
	return nil
}

func (m DetailModel) Update(msg tea.Msg) (DetailModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.viewport.Width = msg.Width
		m.viewport.Height = msg.Height - headerHeight(m.detail)
		if m.detail != nil {
			m.viewport.SetContent(m.renderFinding())
		}

	case DetailLoadedMsg:
		if msg.ID == m.id {
			m.loading = false
			if msg.Err != nil {
				m.err = msg.Err
			} else {
				m.detail = msg.Detail
				m.viewport.Width = m.width
				m.viewport.Height = m.height - headerHeight(m.detail)
				m.viewport.SetContent(m.renderFinding())
			}
		}
		return m, nil

	case tea.KeyMsg:
		var cmd tea.Cmd
		m.viewport, cmd = m.viewport.Update(msg)
		return m, cmd

	case tea.MouseMsg:
		var cmd tea.Cmd
		m.viewport, cmd = m.viewport.Update(msg)
		return m, cmd
	}
	return m, nil
}

// CurrentID returns the ID currently loaded (or being loaded) in this model.
func (m DetailModel) CurrentID() string {
	return m.id
}

// Status returns the status of the currently loaded follow-up, or "" if none is loaded.
func (m DetailModel) Status() string {
	if m.detail == nil {
		return ""
	}
	return m.detail.Status
}

// Title returns the title of the currently loaded follow-up, or "" if none is loaded.
func (m DetailModel) Title() string {
	if m.detail == nil {
		return ""
	}
	return m.detail.Title
}

// Source returns the source of the currently loaded follow-up, or "" if none is loaded.
func (m DetailModel) Source() string {
	if m.detail == nil {
		return ""
	}
	return m.detail.Source
}

// Severity returns the severity of the currently loaded follow-up, or "" if none is loaded.
func (m DetailModel) Severity() string {
	if m.detail == nil {
		return ""
	}
	return m.detail.Severity
}

// FindingExcerpt returns up to the first 3 non-empty, non-heading lines of the finding
// content, joined by spaces. Returns "" if no finding is loaded.
func (m DetailModel) FindingExcerpt() string {
	if m.detail == nil || m.detail.FindingContent == "" {
		return ""
	}
	var parts []string
	for _, line := range strings.Split(m.detail.FindingContent, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts = append(parts, line)
		if len(parts) == 3 {
			break
		}
	}
	return strings.Join(parts, " ")
}

// ClearID resets the current ID so that a subsequent SetID with the same value
// will trigger a reload. Used after actions that change the item's on-disk state.
func (m *DetailModel) ClearID() {
	m.id = ""
	m.detail = nil
}

// SetID sets the follow-up ID and returns a Cmd to load it.
func (m *DetailModel) SetID(id string) tea.Cmd {
	if m.id == id {
		return nil
	}
	m.id = id
	m.loading = true
	m.err = nil
	m.detail = nil
	m.viewport.SetContent("")
	return LoadDetail(m.knowledgeDir, id)
}

// headerHeight returns the number of lines used by the metadata header.
func headerHeight(detail *FollowUpDetail) int {
	if detail == nil {
		return 2
	}
	h := 3 // status/severity row + source row + blank
	if len(detail.Attachments) > 0 {
		h++
	}
	if len(detail.SuggestedActions) > 0 {
		h += 2 // label + actions
	}
	return h
}

func (m DetailModel) renderHeader() string {
	if m.detail == nil {
		return ""
	}

	dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	labelStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("6"))

	var b strings.Builder

	// Status + severity
	glyph, glyphColor := statusGlyph(m.detail.Status)
	statusStr := lipgloss.NewStyle().Foreground(glyphColor).Render(glyph + " " + m.detail.Status)
	sevColor := severityColor(m.detail.Severity)
	sevStr := lipgloss.NewStyle().Foreground(sevColor).Render(m.detail.Severity)
	b.WriteString(statusStr + dimStyle.Render("  ") + sevStr)
	b.WriteString("\n")

	// Source
	if m.detail.Source != "" {
		b.WriteString(dimStyle.Render("source: " + m.detail.Source))
		b.WriteString("\n")
	}

	// Attachments
	if len(m.detail.Attachments) > 0 {
		parts := make([]string, 0, len(m.detail.Attachments))
		for _, a := range m.detail.Attachments {
			parts = append(parts, a.Type+":"+a.Ref)
		}
		b.WriteString(dimStyle.Render("attached: "+strings.Join(parts, ", ")))
		b.WriteString("\n")
	}

	// Suggested actions
	if len(m.detail.SuggestedActions) > 0 {
		b.WriteString(labelStyle.Render("suggested:"))
		b.WriteString("\n")
		for _, action := range m.detail.SuggestedActions {
			b.WriteString("  " + dimStyle.Render("• "+action.Type))
			b.WriteString("\n")
		}
	}

	// Promoted-to reference
	if m.detail.PromotedTo != "" {
		b.WriteString(dimStyle.Render("promoted → "+m.detail.PromotedTo))
		b.WriteString("\n")
	}

	b.WriteString("\n")
	return b.String()
}

func (m DetailModel) renderFinding() string {
	if m.detail == nil {
		return ""
	}
	width := m.width
	if width <= 0 {
		width = 80
	}
	return render.Markdown(m.detail.FindingContent, width)
}

func (m DetailModel) View() string {
	if m.loading || m.id == "" {
		if m.id == "" {
			return lipgloss.NewStyle().Foreground(lipgloss.Color("8")).Render("  No follow-up selected.")
		}
		return lipgloss.NewStyle().Foreground(lipgloss.Color("8")).Render("  Loading…")
	}
	if m.err != nil {
		return fmt.Sprintf("Error: %v\n", m.err)
	}
	if m.detail == nil {
		return ""
	}
	return m.renderHeader() + m.viewport.View()
}
