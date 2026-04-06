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

// ProposedComment represents a single review comment from the proposed-comments.json sidecar.
type ProposedComment struct {
	ID         string   `json:"id"`
	Path       string   `json:"path"`
	Line       int      `json:"line"`
	Side       string   `json:"side"`
	Body       string   `json:"body"`
	Selected   bool     `json:"selected"`
	Severity   string   `json:"severity"`
	Lenses     []string `json:"lenses"`
	Confidence float64  `json:"confidence"`
}

// ProposedReview is the top-level wrapper for the proposed-comments.json sidecar.
// It carries PR metadata alongside the proposed comments so the posting script
// can resolve the target without re-deriving it.
type ProposedReview struct {
	PR       int               `json:"pr"`
	Owner    string            `json:"owner"`
	Repo     string            `json:"repo"`
	HeadSHA  string            `json:"head_sha"`
	Comments []ProposedComment `json:"comments"`
}

// FollowUpDetail holds the full content of a single follow-up artifact.
type FollowUpDetail struct {
	ID               string            `json:"id"`
	Title            string            `json:"title"`
	Status           string            `json:"status"`
	Author           string            `json:"author"`
	Source           string            `json:"source"`
	Attachments      []Attachment      `json:"attachments"`
	SuggestedActions []SuggestedAction `json:"suggested_actions"`
	Created          string            `json:"created"`
	Updated          string            `json:"updated"`
	PromotedTo       string            `json:"promoted_to"`
	FindingContent   string            // contents of finding.md
	ProposedComments *ProposedReview   // from proposed-comments.json sidecar (nil when absent)
	Malformed        bool              `json:"malformed,omitempty"`
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
	Author           string            `json:"author"`
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
		// Malformed _meta.json — return a stub so the TUI can still render the item.
		detail := &FollowUpDetail{
			ID:               id,
			Title:            "[malformed] " + id,
			Attachments:      []Attachment{},
			SuggestedActions: []SuggestedAction{},
			Malformed:        true,
		}
		if data, err := os.ReadFile(filepath.Join(itemDir, "finding.md")); err == nil {
			detail.FindingContent = string(data)
		}
		return detail, nil
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
		Author:           meta.Author,
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

	// Load proposed-comments.json sidecar when present. Missing or malformed
	// sidecar is not an error — the field stays nil.
	// The sidecar may be either a ProposedReview wrapper object or a bare
	// JSON array of comments (the format produced by /pr-review).
	//
	// Three-case zero-comment sidecar rule (D19):
	//   1. Wrapper with valid PR metadata (Owner, Repo, PR>0, HeadSHA non-empty)
	//      and len(Comments)==0 → keep ProposedComments (tab stays, shows empty state).
	//   2. Wrapper without valid metadata and len(Comments)==0 → nil (tab disappears).
	//   3. Bare array with len(comments)==0 → nil (tab disappears).
	if sidecarBytes, err := os.ReadFile(filepath.Join(itemDir, "proposed-comments.json")); err == nil {
		var review ProposedReview
		if json.Unmarshal(sidecarBytes, &review) == nil {
			hasValidMeta := review.Owner != "" && review.Repo != "" && review.PR > 0 && review.HeadSHA != ""
			if len(review.Comments) > 0 || hasValidMeta {
				// Case 1: non-empty comments, or wrapper with valid PR metadata.
				detail.ProposedComments = &review
			}
			// Case 2: wrapper without valid metadata and zero comments — leave nil.
		} else {
			// Try bare array of comments.
			var comments []ProposedComment
			if json.Unmarshal(sidecarBytes, &comments) == nil && len(comments) > 0 {
				// Case 3 (non-empty): bare array with comments.
				detail.ProposedComments = &ProposedReview{Comments: comments}
			}
			// Case 3 (empty): bare array with zero comments — leave nil.
		}
	}

	return detail, nil
}

// Tab identifies a detail view tab.
type Tab int

const (
	TabMeta     Tab = iota
	TabFinding
	TabComments
)

// tabInfo holds display metadata for a tab.
type tabInfo struct {
	id    Tab
	label string
}

// DetailModel is the Bubble Tea model for the follow-up detail pane.
type DetailModel struct {
	knowledgeDir  string
	id            string
	detail        *FollowUpDetail
	loading       bool
	err           error
	viewport      viewport.Model
	reviewCards   *ReviewCardsModel
	tabs          []tabInfo
	activeTab     int
	savedTab      int // 1-indexed tab index to restore after reload; 0 = not set
	contentStartY int
	contentStartX int
	width         int
	height        int
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
		cw := m.contentWidth()
		ch := m.contentHeight()
		m.viewport.Width = cw
		m.viewport.Height = ch
		if m.detail != nil {
			m.viewport.SetContent(m.renderFinding())
		}
		if m.reviewCards != nil {
			rc := *m.reviewCards
			rc, _ = rc.Update(tea.WindowSizeMsg{Width: cw, Height: ch})
			m.reviewCards = &rc
		}

	case WriteSidecarMsg:
		if m.reviewCards != nil {
			rc := *m.reviewCards
			rc, _ = rc.Update(msg)
			m.reviewCards = &rc
		}
		return m, nil

	case ExternalEditDoneMsg:
		if m.reviewCards != nil {
			rc := *m.reviewCards
			var cmd tea.Cmd
			rc, cmd = rc.Update(msg)
			m.reviewCards = &rc
			return m, cmd
		}
		return m, nil

	case DetailLoadedMsg:
		if msg.ID == m.id {
			m.loading = false
			if msg.Err != nil {
				m.err = msg.Err
			} else {
				m.detail = msg.Detail
				cw := m.contentWidth()
				ch := m.contentHeight()

				// Initialize ReviewCardsModel when sidecar is present.
				if m.detail.ProposedComments != nil {
					rc := NewReviewCardsModel(m.knowledgeDir, m.id, m.detail.ProposedComments)
					rc, _ = rc.Update(tea.WindowSizeMsg{Width: cw, Height: ch})
					m.reviewCards = &rc
				} else {
					m.reviewCards = nil
				}

				m.tabs = m.buildTabs()
				if m.savedTab > 0 {
					restored := m.savedTab - 1
					if restored >= len(m.tabs) {
						restored = len(m.tabs) - 1
					}
					m.activeTab = restored
					m.savedTab = 0
				} else {
					m.activeTab = m.tabIndexFor(TabFinding)
				}

				m.viewport.Width = cw
				m.viewport.Height = ch
				m.viewport.SetContent(m.renderFinding())
			}
		}
		return m, nil

	case tea.KeyMsg:
		switch msg.String() {
		case "tab":
			if len(m.tabs) > 0 {
				m.activeTab = (m.activeTab + 1) % len(m.tabs)
			}
			return m, nil
		case "shift+tab":
			if len(m.tabs) > 0 {
				m.activeTab = (m.activeTab - 1 + len(m.tabs)) % len(m.tabs)
			}
			return m, nil
		}
		switch m.ActiveTab() {
		case TabComments:
			if m.reviewCards != nil {
				rc := *m.reviewCards
				var cmd tea.Cmd
				rc, cmd = rc.Update(msg)
				m.reviewCards = &rc
				return m, cmd
			}
		case TabFinding:
			var cmd tea.Cmd
			m.viewport, cmd = m.viewport.Update(msg)
			return m, cmd
		}
		return m, nil

	case tea.MouseMsg:
		// Tab bar click hit-test: only switch tabs on left-click press.
		if msg.Action == tea.MouseActionPress && msg.Button == tea.MouseButtonLeft {
			tabBarY := m.contentStartY + 1
			if msg.Y == tabBarY && len(m.tabs) > 0 {
				// Tab bar format: "  " + [" label "] + " " + [" label "] + ...
				// Each label rendered with Padding(0,1) so visual width = len(label)+2.
				x := m.contentStartX + 2 // "  " indent
				for i, tab := range m.tabs {
					tabW := len(tab.label) + 2 // padding(0,1) adds 1 char each side
					if msg.X >= x && msg.X < x+tabW {
						m.activeTab = i
						return m, nil
					}
					x += tabW + 1 // +1 for the " " separator between tabs
				}
			}
		}
		// Forward mouse to active tab for scroll handling.
		var cmd tea.Cmd
		switch m.ActiveTab() {
		case TabFinding:
			m.viewport, cmd = m.viewport.Update(msg)
		case TabComments:
			if m.reviewCards != nil {
				rc := *m.reviewCards
				rc, cmd = rc.Update(msg)
				m.reviewCards = &rc
			}
		}
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

// SelectedCount returns the number of currently selected proposed comments, or 0 if none loaded.
func (m DetailModel) SelectedCount() int {
	if m.reviewCards == nil {
		return 0
	}
	return m.reviewCards.SelectedCount()
}

// HasPRMetadata returns true when the loaded sidecar has complete PR posting metadata.
func (m DetailModel) HasPRMetadata() bool {
	if m.detail == nil || m.detail.ProposedComments == nil {
		return false
	}
	r := m.detail.ProposedComments
	return r.Owner != "" && r.Repo != "" && r.PR > 0 && r.HeadSHA != ""
}

// PRNumber returns the PR number from the loaded sidecar, or 0 if unavailable.
func (m DetailModel) PRNumber() int {
	if m.detail == nil || m.detail.ProposedComments == nil {
		return 0
	}
	return m.detail.ProposedComments.PR
}

// ActiveTab returns the currently active tab ID.
func (m DetailModel) ActiveTab() Tab {
	if m.activeTab < len(m.tabs) {
		return m.tabs[m.activeTab].id
	}
	return TabMeta
}

// tabIndexFor searches m.tabs for the given ID and returns its index (or 0 if not found).
func (m DetailModel) tabIndexFor(id Tab) int {
	for i, tab := range m.tabs {
		if tab.id == id {
			return i
		}
	}
	return 0
}

// PreserveTab snapshots the current active tab so it can be restored after a
// reload. The value is stored 1-indexed so that zero means "no tab saved".
func (m *DetailModel) PreserveTab() {
	m.savedTab = m.activeTab + 1
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
	m.reviewCards = nil
	m.tabs = nil
	m.activeTab = 0
	m.savedTab = 0
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
	m.reviewCards = nil
	m.tabs = nil
	m.activeTab = 0
	m.savedTab = 0
	m.viewport.SetContent("")
	return LoadDetail(m.knowledgeDir, id)
}

// buildTabs creates the visible tab list based on what content is available.
// TabComments is included only when the ReviewCardsModel is present.
func (m DetailModel) buildTabs() []tabInfo {
	tabs := []tabInfo{
		{id: TabMeta, label: "Meta"},
		{id: TabFinding, label: "Finding"},
	}
	if m.reviewCards != nil {
		tabs = append(tabs, tabInfo{id: TabComments, label: "Comments"})
	}
	return tabs
}

// SetContentStart stores the absolute terminal coordinates of the first row
// of the detail view's output. Called by the parent when layout changes.
func (m *DetailModel) SetContentStart(y, x int) {
	m.contentStartY = y
	m.contentStartX = x
}

func (m DetailModel) contentHeight() int {
	// overhead: blank(1) + tabbar(1) + blank(1) = 3
	h := m.height - 3
	if h < 5 {
		h = 5
	}
	return h
}

func (m DetailModel) contentWidth() int {
	w := m.width - 4
	if w < 20 {
		w = 20
	}
	return w
}


func (m DetailModel) renderMetaTab() string {
	if m.detail == nil {
		return ""
	}

	dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	labelStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("6"))

	var b strings.Builder

	// Status
	glyph, glyphColor := statusGlyph(m.detail.Status)
	statusStr := lipgloss.NewStyle().Foreground(glyphColor).Render(glyph + " " + m.detail.Status)
	b.WriteString(statusStr)
	b.WriteString("\n")

	// Author
	if m.detail.Author != "" {
		b.WriteString(dimStyle.Render("author: " + m.detail.Author))
		b.WriteString("\n")
	}

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

func (m DetailModel) renderTabBar() string {
	activeStyle := lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("0")).
		Background(lipgloss.Color("4")).
		Padding(0, 1)

	inactiveStyle := lipgloss.NewStyle().
		Foreground(lipgloss.Color("7")).
		Background(lipgloss.Color("238")).
		Padding(0, 1)

	var parts []string
	for i, tab := range m.tabs {
		if i == m.activeTab {
			parts = append(parts, activeStyle.Render(tab.label))
		} else {
			parts = append(parts, inactiveStyle.Render(tab.label))
		}
	}

	return "  " + strings.Join(parts, " ")
}

func (m DetailModel) renderFinding() string {
	if m.detail == nil {
		return ""
	}
	width := m.contentWidth()
	if width <= 0 {
		width = 80
	}
	return render.Markdown(m.detail.FindingContent, width)
}

func (m DetailModel) renderTabContent() string {
	switch m.ActiveTab() {
	case TabMeta:
		return m.renderMetaTab()
	case TabComments:
		if m.reviewCards != nil {
			return m.reviewCards.View()
		}
		return ""
	default: // TabFinding
		return m.viewport.View()
	}
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
	return "\n" + m.renderTabBar() + "\n\n" + m.renderTabContent()
}
