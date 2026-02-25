package work

import (
	"fmt"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/anticorrelator/lore/tui/internal/gh"
)

// PRStatusMsg is sent when the background PR loader completes.
type PRStatusMsg struct {
	Statuses map[string]gh.PRStatus
	Err      error
}

// ItemSelectedMsg is sent when the user presses Enter on an item.
type ItemSelectedMsg struct {
	Item WorkItem
}

// SpecRequestMsg is sent when the user presses 's' to open the spec panel for an item.
type SpecRequestMsg struct {
	Slug string
}

// ChatRequestMsg is sent when the user presses 'c' to open a chat session about an item.
type ChatRequestMsg struct {
	Slug  string
	Title string
}

// ArchiveRequestMsg is sent when the user confirms an archive/unarchive action.
type ArchiveRequestMsg struct {
	Slug      string
	Unarchive bool
}

// ArchiveFinishedMsg is sent when the archive/unarchive command completes.
type ArchiveFinishedMsg struct {
	Err error
}

// SpecStatusMsg is dispatched from main.go to update the list's spec indicator.
// Done=true clears the indicator; otherwise sets specActiveSlug and specNeedsInput.
type SpecStatusMsg struct {
	Slug       string
	NeedsInput bool
	Done       bool
}

// specTickMsg drives the animated dots on the speccing status line.
type specTickMsg struct{}

func specTick() tea.Cmd {
	return tea.Tick(400*time.Millisecond, func(time.Time) tea.Msg { return specTickMsg{} })
}

// FilterMode controls which work items are shown in the list.
type FilterMode int

const (
	FilterActive   FilterMode = iota // show only active items
	FilterArchived                   // show only archived items
)

// ListModel is the Bubble Tea model for the work item list panel.
type ListModel struct {
	allItems            []WorkItem
	filterMode          FilterMode
	cursor              int
	prStatus            map[string]gh.PRStatus
	prLoaded            bool
	compactMode         bool
	specActiveSlugs     map[string]bool // all slugs currently speccing
	specNeedsInputSlugs map[string]bool // slugs with active input prompt
	specDots            int
	confirmArchive      bool
	pendingArchiveSlug  string
	pendingArchiveTitle string
	pendingUnarchive    bool
	width               int
	height              int
	err                 error
}

// visibleItems returns the filtered slice of items based on filterMode.
func (m ListModel) visibleItems() []WorkItem {
	var out []WorkItem
	for _, item := range m.allItems {
		if m.filterMode == FilterArchived {
			if item.Status == "archived" {
				out = append(out, item)
			}
		} else {
			if item.Status != "archived" {
				out = append(out, item)
			}
		}
	}
	return out
}

// NewListModel creates a list model from pre-loaded work items.
func NewListModel(items []WorkItem) ListModel {
	return ListModel{
		allItems:   items,
		filterMode: FilterActive,
		cursor:     0,
		prStatus:   nil,
		prLoaded:   false,
	}
}

// FilterMode returns the current filter mode.
func (m ListModel) GetFilterMode() FilterMode {
	return m.filterMode
}

func (m ListModel) Init() tea.Cmd {
	return nil
}

func (m ListModel) Update(msg tea.Msg) (ListModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

	case PRStatusMsg:
		m.prLoaded = true
		if msg.Err == nil {
			m.prStatus = msg.Statuses
		}

	case SpecStatusMsg:
		if m.specActiveSlugs == nil {
			m.specActiveSlugs = make(map[string]bool)
			m.specNeedsInputSlugs = make(map[string]bool)
		}
		if msg.Done {
			delete(m.specActiveSlugs, msg.Slug)
			delete(m.specNeedsInputSlugs, msg.Slug)
			if len(m.specActiveSlugs) == 0 {
				m.specDots = 0
			}
		} else {
			wasEmpty := len(m.specActiveSlugs) == 0
			m.specActiveSlugs[msg.Slug] = true
			m.specNeedsInputSlugs[msg.Slug] = msg.NeedsInput
			if wasEmpty {
				return m, specTick()
			}
		}

	case specTickMsg:
		if len(m.specActiveSlugs) > 0 {
			m.specDots = (m.specDots + 1) % 4
			return m, specTick()
		}

	case tea.KeyMsg:
		// Confirm mode: intercept keys for the confirmation prompt
		if m.confirmArchive {
			switch msg.String() {
			case "y", "enter":
				slug := m.pendingArchiveSlug
				unarchive := m.pendingUnarchive
				m.confirmArchive = false
				m.pendingArchiveSlug = ""
				m.pendingArchiveTitle = ""
				m.pendingUnarchive = false
				return m, func() tea.Msg {
					return ArchiveRequestMsg{Slug: slug, Unarchive: unarchive}
				}
			default:
				// Any other key cancels (n, esc, etc.)
				m.confirmArchive = false
				m.pendingArchiveSlug = ""
				m.pendingArchiveTitle = ""
				m.pendingUnarchive = false
			}
			return m, nil
		}

		items := m.visibleItems()
		switch msg.String() {
		case "a":
			// Toggle between active and archived
			if m.filterMode == FilterActive {
				m.filterMode = FilterArchived
			} else {
				m.filterMode = FilterActive
			}
			m.cursor = 0
		case "A":
			if len(items) > 0 {
				item := items[m.cursor]
				m.confirmArchive = true
				m.pendingArchiveSlug = item.Slug
				m.pendingArchiveTitle = item.Title
				if m.pendingArchiveTitle == "" {
					m.pendingArchiveTitle = item.Slug
				}
				m.pendingUnarchive = m.filterMode == FilterArchived
			}
		case "j", "down":
			if m.cursor < len(items)-1 {
				m.cursor++
			}
		case "k", "up":
			if m.cursor > 0 {
				m.cursor--
			}
		case "g", "home":
			m.cursor = 0
		case "G", "end":
			if len(items) > 0 {
				m.cursor = len(items) - 1
			}
		case "s":
			if len(items) > 0 {
				slug := items[m.cursor].Slug
				return m, func() tea.Msg {
					return SpecRequestMsg{Slug: slug}
				}
			}
		case "c":
			if len(items) > 0 {
				item := items[m.cursor]
				return m, func() tea.Msg {
					return ChatRequestMsg{Slug: item.Slug, Title: item.Title}
				}
			}
		case "enter":
			if len(items) > 0 {
				item := items[m.cursor]
				return m, func() tea.Msg {
					return ItemSelectedMsg{Item: item}
				}
			}
		}
	}
	return m, nil
}

// Items returns the currently visible (filtered) work items.
func (m ListModel) Items() []WorkItem {
	return m.visibleItems()
}

// Cursor returns the current cursor position.
func (m ListModel) Cursor() int {
	return m.cursor
}

// CurrentSlug returns the slug of the currently highlighted item, or "" if empty.
func (m ListModel) CurrentSlug() string {
	items := m.visibleItems()
	if len(items) == 0 || m.cursor >= len(items) {
		return ""
	}
	return items[m.cursor].Slug
}

// SetCursorBySlug moves the cursor to the item with the given slug.
// Returns true if found, false if not (cursor resets to 0).
func (m *ListModel) SetCursorBySlug(slug string) bool {
	for i, item := range m.visibleItems() {
		if item.Slug == slug {
			m.cursor = i
			return true
		}
	}
	m.cursor = 0
	return false
}

// SetCompactMode enables or disables compact rendering (slug + status only).
func (m *ListModel) SetCompactMode(compact bool) {
	m.compactMode = compact
}

func (m ListModel) View() string {
	if m.err != nil {
		return fmt.Sprintf("Error loading work items: %v\n", m.err)
	}

	var content string
	if m.compactMode {
		content = m.viewCompact()
	} else {
		content = m.viewFull()
	}

	if m.confirmArchive {
		action := "Archive"
		if m.pendingUnarchive {
			action = "Unarchive"
		}
		promptStyle := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("3"))
		dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
		prompt := promptStyle.Render(fmt.Sprintf("%s \"%s\"?", action, m.pendingArchiveTitle)) +
			dimStyle.Render(" [y]es [n]o")
		content += "\n" + prompt
	}

	return content
}

// panelW is the inner width of the left panel (matches leftPanelWidth in main.go).
const panelW = 40

// viewCompact renders the compact split-pane list with two lines per item:
//   Line 1: "> Title"              (bold when selected)
//   Line 2: "    status · #issue"  (dim metadata)
func (m ListModel) viewCompact() string {
	items := m.visibleItems()

	var b strings.Builder

	if len(items) == 0 {
		dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
		label := "active"
		if m.filterMode == FilterArchived {
			label = "archived"
		}
		return dimStyle.Render(fmt.Sprintf("  No %s work items.  (a to switch)", label))
	}

	titleSelStyle := lipgloss.NewStyle().Background(lipgloss.Color("237")).Bold(true)
	infoSelStyle  := lipgloss.NewStyle().Background(lipgloss.Color("237"))

	// Each item occupies 2 lines; compute visible item count accordingly.
	visibleCount := m.height / 2
	if visibleCount < 1 {
		visibleCount = len(items)
	}

	// Scrolling: keep cursor visible
	offset := 0
	if m.cursor >= visibleCount {
		offset = m.cursor - visibleCount + 1
	}

	end := offset + visibleCount
	if end > len(items) {
		end = len(items)
	}

	for i := offset; i < end; i++ {
		item := items[i]
		selected := i == m.cursor

		cursor := "  "
		if selected {
			cursor = "> "
		}

		// Spec indicator: ◆ (amber) only when waiting for input, nothing when just running.
		specGlyph := ""
		if m.specActiveSlugs[item.Slug] && m.specNeedsInputSlugs[item.Slug] {
			specGlyph = lipgloss.NewStyle().Foreground(lipgloss.Color("214")).Render("◆") + " "
		}

		// Line 1: title (fall back to slug)
		name := item.Title
		if name == "" {
			name = item.Slug
		}
		glyphW := lipgloss.Width(specGlyph)
		line1 := cursor + specGlyph + truncate(name, panelW-2-glyphW)
		for lipgloss.Width(line1) < panelW {
			line1 += " "
		}

		// Line 2: status · issue
		info := m.buildInfoCompact(item)
		line2 := "    " + info
		for lipgloss.Width(line2) < panelW {
			line2 += " "
		}

		if selected {
			line1 = titleSelStyle.Render(line1)
			line2 = infoSelStyle.Render(line2)
		}

		b.WriteString(line1 + "\n")
		b.WriteString(line2 + "\n")
	}

	return b.String()
}

// readinessLabel returns the styled readiness label for a work item ("ready", "needs tasks", "needs spec").
// For archived items it returns a dim "archived" label.
func readinessLabel(item WorkItem) (string, string) {
	switch {
	case item.Status == "archived":
		return "archived", "8"
	case item.HasTasks:
		return "ready", "2"
	case item.HasPlanDoc:
		return "needs tasks", "3"
	default:
		return "needs spec", "8"
	}
}

// buildInfoCompact builds the status line for compact mode: readiness · issue.
// Issue is always shown ("--" when not set). No PR badge (space is reserved for slug on the same line).
func (m ListModel) buildInfoCompact(item WorkItem) string {
	dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	sep := dimStyle.Render(" · ")

	var parts []string

	// When this item is actively speccing, show animated status instead of readiness.
	if m.specActiveSlugs[item.Slug] {
		dots := strings.Repeat(".", m.specDots)
		specS := lipgloss.NewStyle().Foreground(lipgloss.Color("6"))
		parts = append(parts, specS.Render("speccing"+dots+strings.Repeat(" ", 3-len(dots))))
	} else {
		label, color := readinessLabel(item)
		parts = append(parts, lipgloss.NewStyle().Foreground(lipgloss.Color(color)).Render(label))
	}

	issueStr := "--"
	if item.Issue != "" {
		issueStr = extractURLRef(item.Issue)
	}
	parts = append(parts, dimStyle.Render(issueStr))

	return strings.Join(parts, sep)
}

// extractURLRef extracts a short "#number" reference from a GitHub URL or plain value.
func extractURLRef(s string) string {
	if !strings.HasPrefix(s, "http") {
		if !strings.HasPrefix(s, "#") {
			return "#" + s
		}
		return s
	}
	s = strings.TrimRight(s, "/")
	parts := strings.Split(s, "/")
	if len(parts) > 0 {
		if last := parts[len(parts)-1]; last != "" {
			return "#" + last
		}
	}
	return s
}

// viewFull renders the full-width table with all columns.
func (m ListModel) viewFull() string {
	var b strings.Builder

	// Column widths — no TITLE column; slug expands to fill available space.
	statusW := 12 // "needs tasks" = 11 chars
	issueW := 8   // "#12345" = 7 chars
	updatedW := 12
	prW := 10
	slugW := 50 // default; grows to fill terminal width

	// Adapt to terminal width: slug absorbs all spare space.
	// Fixed columns: status(12) + issue(8) + pr(10) + updated(12) + gaps(8) = 50
	if m.width > 0 {
		slugW = m.width - statusW - issueW - prW - updatedW - 8
		if slugW < 20 {
			slugW = 20
		}
	}

	// Styles
	headerStyle := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("4"))
	selectedStyle := lipgloss.NewStyle().Background(lipgloss.Color("237")).Bold(true)
	dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))

	// Header
	header := fmt.Sprintf("  %-*s  %-*s  %-*s  %-*s  %-*s",
		slugW, "SLUG",
		statusW, "READINESS",
		issueW, "ISSUE",
		prW, "PR",
		updatedW, "UPDATED",
	)
	b.WriteString(headerStyle.Render(header))
	b.WriteString("\n")

	items := m.visibleItems()

	// Visible rows (reserve 1 line for header — footer is in parent status bar)
	visibleRows := m.height - 1
	if visibleRows < 1 {
		visibleRows = len(items)
	}

	// Scrolling: keep cursor visible
	offset := 0
	if m.cursor >= visibleRows {
		offset = m.cursor - visibleRows + 1
	}

	end := offset + visibleRows
	if end > len(items) {
		end = len(items)
	}

	for i := offset; i < end; i++ {
		item := items[i]

		slug := truncate(item.Slug, slugW)
		updated := formatRelativeTime(item.Updated)
		updated = truncate(updated, updatedW)
		pr := m.prBadge(item.PR, prW)

		// Readiness label — replaced with animated "speccing" when active.
		var statusLabel string
		var statusColor string
		if m.specActiveSlugs[item.Slug] {
			dots := strings.Repeat(".", m.specDots)
			statusLabel = "speccing" + dots + strings.Repeat(" ", 3-len(dots))
			statusColor = "6" // cyan
		} else {
			statusLabel, statusColor = readinessLabel(item)
		}
		status := lipgloss.NewStyle().Foreground(lipgloss.Color(statusColor)).Render(truncate(statusLabel, statusW))

		// Issue number
		issueStr := "--"
		if item.Issue != "" {
			issueStr = extractURLRef(item.Issue)
		}
		issue := dimStyle.Render(truncate(issueStr, issueW))

		row := fmt.Sprintf("  %-*s  %s%s  %s%s  %s%s  %-*s",
			slugW, slug,
			status, strings.Repeat(" ", max(0, statusW-lipgloss.Width(status))),
			issue, strings.Repeat(" ", max(0, issueW-lipgloss.Width(issue))),
			pr, strings.Repeat(" ", max(0, prW-lipgloss.Width(pr))),
			updatedW, updated,
		)

		if i == m.cursor {
			row = selectedStyle.Render(row)
		}

		b.WriteString(row)
		b.WriteString("\n")
	}

	return b.String()
}

func (m ListModel) prBadge(prField string, width int) string {
	if prField == "" {
		return lipgloss.NewStyle().Foreground(lipgloss.Color("8")).Render(
			truncate("--", width),
		)
	}

	if !m.prLoaded {
		return lipgloss.NewStyle().Foreground(lipgloss.Color("3")).Render(
			truncate("...", width),
		)
	}

	if m.prStatus == nil {
		return lipgloss.NewStyle().Foreground(lipgloss.Color("8")).Render(
			truncate("--", width),
		)
	}

	ps, ok := m.prStatus[prField]
	if !ok {
		return lipgloss.NewStyle().Foreground(lipgloss.Color("8")).Render(
			truncate("--", width),
		)
	}

	label := fmt.Sprintf("#%d", ps.Number)
	switch ps.State {
	case "OPEN":
		badge := label
		if ps.ReviewDecision == "APPROVED" {
			badge += " ✓"
		} else if ps.ReviewDecision == "CHANGES_REQUESTED" {
			badge += " ✗"
		}
		return lipgloss.NewStyle().Foreground(lipgloss.Color("2")).Render(
			truncate(badge, width),
		)
	case "MERGED":
		return lipgloss.NewStyle().Foreground(lipgloss.Color("5")).Render(
			truncate(label+" ●", width),
		)
	case "CLOSED":
		return lipgloss.NewStyle().Foreground(lipgloss.Color("1")).Render(
			truncate(label+" ✗", width),
		)
	}

	return truncate(label, width)
}

func truncate(s string, maxW int) string {
	if lipgloss.Width(s) <= maxW {
		return s
	}
	// Simple rune-based truncation with ellipsis
	runes := []rune(s)
	if maxW <= 1 {
		return "…"
	}
	for i := len(runes) - 1; i >= 0; i-- {
		candidate := string(runes[:i]) + "…"
		if lipgloss.Width(candidate) <= maxW {
			return candidate
		}
	}
	return "…"
}

func formatRelativeTime(iso string) string {
	t, err := time.Parse(time.RFC3339, iso)
	if err != nil {
		// Try date-only
		t, err = time.Parse("2006-01-02", iso)
		if err != nil {
			return iso
		}
	}

	now := time.Now()
	diff := now.Sub(t)

	switch {
	case diff < time.Minute:
		return "just now"
	case diff < time.Hour:
		m := int(diff.Minutes())
		return fmt.Sprintf("%dm ago", m)
	case diff < 24*time.Hour:
		h := int(diff.Hours())
		return fmt.Sprintf("%dh ago", h)
	case diff < 30*24*time.Hour:
		d := int(diff.Hours() / 24)
		return fmt.Sprintf("%dd ago", d)
	case diff < 365*24*time.Hour:
		mo := int(diff.Hours() / 24 / 30)
		return fmt.Sprintf("%dmo ago", mo)
	default:
		y := int(diff.Hours() / 24 / 365)
		return fmt.Sprintf("%dy ago", y)
	}
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
