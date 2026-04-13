package followup

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
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
	PR                 int               `json:"pr"`
	Owner              string            `json:"owner"`
	Repo               string            `json:"repo"`
	HeadSHA            string            `json:"head_sha"`
	Comments           []ProposedComment `json:"comments"`
	ReviewBody         string            `json:"review_body"`
	ReviewBodySelected bool              `json:"review_body_selected"`
	ReviewEvent        string            `json:"review_event"`
}

// UnmarshalJSON widens the accepted JSON shape for the "pr" field so that
// both a JSON number (42) and a digit-only JSON string ("42") decode to the
// same int value. Non-numeric strings return a clear error, never a silent zero.
func (r *ProposedReview) UnmarshalJSON(data []byte) error {
	type alias struct {
		PR                 json.RawMessage   `json:"pr"`
		Owner              string            `json:"owner"`
		Repo               string            `json:"repo"`
		HeadSHA            string            `json:"head_sha"`
		Comments           []ProposedComment `json:"comments"`
		ReviewBody         string            `json:"review_body"`
		ReviewBodySelected bool              `json:"review_body_selected"`
		ReviewEvent        string            `json:"review_event"`
	}
	var a alias
	if err := json.Unmarshal(data, &a); err != nil {
		return err
	}
	pr, err := decodePRField(a.PR)
	if err != nil {
		return err
	}
	r.PR = pr
	r.Owner = a.Owner
	r.Repo = a.Repo
	r.HeadSHA = a.HeadSHA
	r.Comments = a.Comments
	r.ReviewBody = a.ReviewBody
	r.ReviewBodySelected = a.ReviewBodySelected
	r.ReviewEvent = a.ReviewEvent
	return nil
}

// LensFinding represents a single finding from a PR review lens.
type LensFinding struct {
	Severity    string `json:"severity"`
	Title       string `json:"title"`
	File        string `json:"file"`
	Line        int    `json:"line"`
	Body        string `json:"body"`
	Lens        string `json:"lens"`
	Disposition string `json:"disposition"`
	Rationale   string `json:"rationale"`
	Selected    bool   `json:"selected,omitempty"`
}

// LensReview is the top-level wrapper for the lens-findings.json sidecar.
type LensReview struct {
	PR       int           `json:"pr"`
	WorkItem string        `json:"work_item"`
	Findings []LensFinding `json:"findings"`
}

// UnmarshalJSON widens the accepted JSON shape for the "pr" field so that
// both a JSON number (42) and a digit-only JSON string ("42") decode to the
// same int value. Non-numeric strings return a clear error, never a silent zero.
func (r *LensReview) UnmarshalJSON(data []byte) error {
	type alias struct {
		PR       json.RawMessage `json:"pr"`
		WorkItem string          `json:"work_item"`
		Findings []LensFinding   `json:"findings"`
	}
	var a alias
	if err := json.Unmarshal(data, &a); err != nil {
		return err
	}
	pr, err := decodePRField(a.PR)
	if err != nil {
		return err
	}
	r.PR = pr
	r.WorkItem = a.WorkItem
	r.Findings = a.Findings
	return nil
}

// decodePRField accepts a raw JSON value that is either a number or a
// digit-only quoted string and returns the corresponding int.
func decodePRField(raw json.RawMessage) (int, error) {
	if len(raw) == 0 {
		return 0, nil
	}
	if raw[0] == '"' {
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			return 0, err
		}
		n, err := strconv.Atoi(s)
		if err != nil {
			return 0, fmt.Errorf("pr: %q is not a valid int: %w", s, err)
		}
		return n, nil
	}
	var n int
	if err := json.Unmarshal(raw, &n); err != nil {
		return 0, err
	}
	return n, nil
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
	LensFindings     *LensReview       // from lens-findings.json sidecar (nil when absent)
	Malformed        bool              `json:"malformed,omitempty"`
	SidecarErrors    map[string]string // keyed by filename; populated only for present-but-malformed sidecars
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

	// Load proposed-comments.json sidecar when present. Missing sidecar is silent.
	// Malformed sidecar (neither wrapper nor bare-array decode succeeds) is non-fatal
	// but recorded in SidecarErrors so the TUI can surface a diagnostic.
	//
	// Three-case zero-comment sidecar rule (D19):
	//   1. Wrapper with valid PR metadata (Owner, Repo, PR>0, HeadSHA non-empty)
	//      and len(Comments)==0 → keep ProposedComments (tab stays, shows empty state).
	//   2. Wrapper without valid metadata and len(Comments)==0 → nil (tab disappears).
	//   3. Bare array with len(comments)==0 → nil (tab disappears).
	if sidecarBytes, err := os.ReadFile(filepath.Join(itemDir, "proposed-comments.json")); err == nil {
		var review ProposedReview
		if wrapperErr := json.Unmarshal(sidecarBytes, &review); wrapperErr == nil {
			hasValidMeta := review.Owner != "" && review.Repo != "" && review.PR > 0 && review.HeadSHA != ""
			if len(review.Comments) > 0 || hasValidMeta {
				// Case 1: non-empty comments, or wrapper with valid PR metadata.
				detail.ProposedComments = &review
			}
			// Case 2: wrapper without valid metadata and zero comments — leave nil.
		} else {
			// Try bare array of comments.
			var comments []ProposedComment
			bareErr := json.Unmarshal(sidecarBytes, &comments)
			if bareErr == nil && len(comments) > 0 {
				// Case 3 (non-empty): bare array with comments.
				detail.ProposedComments = &ProposedReview{Comments: comments}
			} else if bareErr != nil {
				// Both wrapper and bare-array decode failed — record diagnostic.
				if detail.SidecarErrors == nil {
					detail.SidecarErrors = make(map[string]string)
				}
				detail.SidecarErrors["proposed-comments.json"] = wrapperErr.Error()
			}
			// Case 3 (empty bare array): leave nil, no error.
		}
	}

	// Load lens-findings.json sidecar when present. Missing sidecar is silent.
	// Malformed sidecar is non-fatal but recorded in SidecarErrors.
	// Loader rules:
	//   1. File absent → nil.
	//   2. Valid JSON with len(findings) > 0 → populated.
	//   3. Valid JSON with len(findings) == 0 → nil.
	//   4. Malformed JSON → nil + SidecarErrors entry.
	if lfBytes, err := os.ReadFile(filepath.Join(itemDir, "lens-findings.json")); err == nil {
		var review LensReview
		if lfErr := json.Unmarshal(lfBytes, &review); lfErr != nil {
			if detail.SidecarErrors == nil {
				detail.SidecarErrors = make(map[string]string)
			}
			detail.SidecarErrors["lens-findings.json"] = lfErr.Error()
		} else if len(review.Findings) > 0 {
			detail.LensFindings = &review
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
	TabTriage
)

// tabInfo holds display metadata for a tab.
type tabInfo struct {
	id    Tab
	label string
}

// DetailModel is the Bubble Tea model for the follow-up detail pane.
type DetailModel struct {
	knowledgeDir          string
	id                    string
	detail                *FollowUpDetail
	loading               bool
	err                   error
	viewport              viewport.Model
	reviewCards           *ReviewCardsModel
	lensFindings          *LensFindingsModel
	tabs                  []tabInfo
	activeTab             int
	savedTabID            Tab // Tab ID to restore after reload; -1 = not set
	contentStartY         int
	contentStartX         int
	width                 int
	height                int
	mergeStatusRequestSeq uint64                                                                   // incremented on each dispatch; used to discard stale responses
	fetchMergeStatusCmd   func(followupID string, requestSeq uint64, owner, repo string, pr int) tea.Cmd // injectable for tests
}

// NewDetailModel creates a DetailModel. Call LoadDetail to populate it.
func NewDetailModel(knowledgeDir string) DetailModel {
	return DetailModel{
		knowledgeDir:        knowledgeDir,
		savedTabID:          -1,
		fetchMergeStatusCmd: FetchMergeStatusCmd,
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
		if m.lensFindings != nil {
			m.lensFindings.SetSize(cw, ch)
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

	case MergeStatusLoadedMsg:
		// Discard stale responses: cross-item (wrong followup) and same-item stale
		// (superseded by mtime polling or post-review reload that incremented requestSeq).
		if msg.FollowupID != m.id || msg.RequestSeq != m.mergeStatusRequestSeq {
			return m, nil
		}
		if m.reviewCards != nil {
			rc := *m.reviewCards
			rc, _ = rc.Update(msg)
			m.reviewCards = &rc
		}
		return m, nil

	case DetailLoadedMsg:
		var fetchCmd tea.Cmd
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

					// Dispatch async merge-status fetch when PR coordinates are available.
					owner := m.detail.ProposedComments.Owner
					repo := m.detail.ProposedComments.Repo
					pr := m.detail.ProposedComments.PR
					if pr > 0 && owner != "" && repo != "" {
						m.mergeStatusRequestSeq++
						fetchCmd = m.fetchMergeStatusCmd(m.id, m.mergeStatusRequestSeq, owner, repo, pr)
					}
				} else {
					m.reviewCards = nil
				}

				// Initialize LensFindingsModel when sidecar is present.
				if m.detail.LensFindings != nil {
					lf := NewLensFindingsModel(m.knowledgeDir, m.id, m.detail.LensFindings)
					lf.SetSize(cw, ch)
					m.lensFindings = &lf
				} else {
					m.lensFindings = nil
				}

				m.tabs = m.buildTabs()
				if m.savedTabID >= 0 {
					idx := m.tabIndexFor(m.savedTabID)
					// tabIndexFor returns 0 if not found; verify it actually matched.
					if idx > 0 || (len(m.tabs) > 0 && m.tabs[0].id == m.savedTabID) {
						m.activeTab = idx
					} else {
						m.activeTab = m.defaultTabIndex()
					}
					m.savedTabID = -1
				} else {
					m.activeTab = m.defaultTabIndex()
				}

				m.viewport.Width = cw
				m.viewport.Height = ch
				m.viewport.SetContent(m.renderFinding())
			}
		}
		return m, fetchCmd

	case tea.KeyMsg:
		switch msg.String() {
		case "tab":
			// Suppress tab cycling when the review cards textarea is active.
			if m.reviewCards != nil && m.reviewCards.IsEditing() {
				break
			}
			if len(m.tabs) > 0 {
				m.activeTab = (m.activeTab + 1) % len(m.tabs)
			}
			return m, nil
		case "shift+tab":
			// Suppress tab cycling when the review cards textarea is active.
			if m.reviewCards != nil && m.reviewCards.IsEditing() {
				break
			}
			if len(m.tabs) > 0 {
				m.activeTab = (m.activeTab - 1 + len(m.tabs)) % len(m.tabs)
			}
			return m, nil
		}
		switch m.ActiveTab() {
		case TabTriage:
			if m.lensFindings != nil {
				lf := *m.lensFindings
				var cmd tea.Cmd
				lf, cmd = lf.Update(msg)
				m.lensFindings = &lf
				return m, cmd
			}
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
		case TabTriage:
			if m.lensFindings != nil {
				lf := *m.lensFindings
				lf, cmd = lf.Update(msg)
				m.lensFindings = &lf
			}
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

// SelectedLensFindingsJSON returns a JSON array of selected lens findings,
// or "" if the Findings tab is not loaded or no findings are selected.
// Used by the parent to pass --findings-json to promote-followup.sh.
func (m DetailModel) SelectedLensFindingsJSON() string {
	if m.lensFindings == nil {
		return ""
	}
	selected := m.lensFindings.SelectedLensFindings()
	if len(selected) == 0 {
		return ""
	}
	data, err := json.Marshal(selected)
	if err != nil {
		return ""
	}
	return string(data)
}

// ActionMenuOpen returns true when the Triage tab's inline action menu is open.
// Used by the parent model to show action menu hints in the status bar.
func (m DetailModel) ActionMenuOpen() bool {
	if m.lensFindings == nil {
		return false
	}
	return m.lensFindings.ActionMenuOpen()
}

// IsEditing returns true when the review cards model has an inline textarea active.
// Used by the parent model to suppress global key shortcuts.
func (m DetailModel) IsEditing() bool {
	return m.reviewCards != nil && m.reviewCards.IsEditing()
}

// ReviewEvent returns the review event type from the review cards model
// (e.g. "COMMENT", "APPROVE", "REQUEST_CHANGES"). Returns "COMMENT" if no
// review cards model is loaded.
func (m DetailModel) ReviewEvent() string {
	if m.reviewCards == nil {
		return "COMMENT"
	}
	return m.reviewCards.ReviewEvent()
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

// PreserveTab snapshots the current active tab ID so it can be restored after
// a reload. On restore, the saved ID is looked up in the new tabs list; if not
// found, the default precedence applies.
func (m *DetailModel) PreserveTab() {
	m.savedTabID = m.ActiveTab()
}

// defaultTabIndex returns the tab index to use when no saved tab is set.
func (m DetailModel) defaultTabIndex() int {
	return m.tabIndexFor(TabFinding)
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
	m.lensFindings = nil
	m.tabs = nil
	m.activeTab = 0
	m.savedTabID = -1
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
	m.lensFindings = nil
	m.tabs = nil
	m.activeTab = 0
	m.savedTabID = -1
	m.viewport.SetContent("")
	return LoadDetail(m.knowledgeDir, id)
}

// buildTabs creates the visible tab list based on what content is available.
// Tab order: Meta | Finding | Triage | Comments. Absent tabs are omitted.
func (m DetailModel) buildTabs() []tabInfo {
	tabs := []tabInfo{
		{id: TabMeta, label: "Meta"},
		{id: TabFinding, label: "Finding"},
	}
	if m.lensFindings != nil {
		tabs = append(tabs, tabInfo{id: TabTriage, label: "Triage"})
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
	case TabTriage:
		if m.lensFindings != nil {
			return m.lensFindings.View()
		}
		return ""
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
