package knowledge

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// BrowserDismissedMsg is sent when the user exits the knowledge browser.
type BrowserDismissedMsg struct{}

// panelFocus tracks which panel has keyboard focus in the browser split-pane.
type panelFocus int

const (
	panelLeft panelFocus = iota
	panelRight
)

// treeNode represents one row in the flat, always-expanded knowledge tree.
// Category headers (isCategory=true) are visual dividers; entry rows hold a
// pointer to the underlying KnowledgeEntry.
type treeNode struct {
	isCategory bool
	entry      *KnowledgeEntry // nil for category headers
	label      string          // display text (category name or entry title)
}

// buildTree creates a flat list of treeNode from a manifest.
// Categories are sorted by priority (same order as manifest.Categories),
// and entries within each category keep their manifest order.
func buildTree(manifest *Manifest) []treeNode {
	var nodes []treeNode
	for _, cat := range manifest.Categories {
		nodes = append(nodes, treeNode{
			isCategory: true,
			label:      cat.Name,
		})
		for i := range manifest.Entries {
			e := &manifest.Entries[i]
			if e.Category == cat.Name {
				nodes = append(nodes, treeNode{
					entry: e,
					label: e.Title,
				})
			}
		}
	}
	return nodes
}

// firstEntryIndex returns the index of the first non-category node, or 0.
func firstEntryIndex(nodes []treeNode) int {
	for i, n := range nodes {
		if !n.isCategory {
			return i
		}
	}
	return 0
}

// BrowserModel is the Bubble Tea model for the knowledge browser.
type BrowserModel struct {
	nodes        []treeNode
	cursor       int
	focusedPanel panelFocus
	searchActive bool
	manifest     *Manifest
	width        int
	height       int
	err          error
	loading      bool
	knowledgeDir string
	entryDetail  EntryModel
	searchPanel  SearchModel
}

// ManifestLoadedMsg is sent when the manifest finishes loading.
type ManifestLoadedMsg struct {
	Manifest *Manifest
	Err      error
}

// FocusLeft sets keyboard focus to the left (tree) panel.
func (m *BrowserModel) FocusLeft() { m.focusedPanel = panelLeft }

// FocusRight sets keyboard focus to the right (detail) panel.
func (m *BrowserModel) FocusRight() { m.focusedPanel = panelRight }

// NewBrowserModel creates a knowledge browser.
func NewBrowserModel(knowledgeDir string) BrowserModel {
	return BrowserModel{
		loading:      true,
		knowledgeDir: knowledgeDir,
	}
}

// LoadManifestCmd returns a command that loads the manifest.
func LoadManifestCmd(knowledgeDir string) tea.Cmd {
	return func() tea.Msg {
		m, err := LoadManifest(knowledgeDir)
		return ManifestLoadedMsg{Manifest: m, Err: err}
	}
}

func (m BrowserModel) Init() tea.Cmd {
	return nil
}

// leftPanelWidth is the fixed width of the tree panel (matches main.go).
const leftPanelWidth = 40

// rightPanelWidth returns the inner content width for the right panel.
func (m BrowserModel) rightPanelWidth() int {
	w := m.width - leftPanelWidth - 4
	if w < 20 {
		w = 20
	}
	return w
}

// innerHeight returns the usable content height (terminal minus borders + status bar).
func (m BrowserModel) innerHeight() int {
	h := m.height - 3
	if h < 1 {
		h = 1
	}
	return h
}

// loadCurrentEntry creates a fresh EntryModel for the node at m.cursor,
// applies constrained dimensions, and returns the LoadEntryCmd.
func (m *BrowserModel) loadCurrentEntry() tea.Cmd {
	if m.cursor >= len(m.nodes) || m.nodes[m.cursor].isCategory {
		return nil
	}
	entry := m.nodes[m.cursor].entry
	m.entryDetail = NewEntryModel(entry.Title)
	if m.width > 0 {
		m.entryDetail, _ = m.entryDetail.Update(tea.WindowSizeMsg{
			Width:  m.rightPanelWidth(),
			Height: m.innerHeight(),
		})
	}
	return LoadEntryCmd(m.knowledgeDir, entry.Path)
}

// nextEntry returns the index of the next non-category node after idx, or idx if none.
func nextEntry(nodes []treeNode, idx int) int {
	for i := idx + 1; i < len(nodes); i++ {
		if !nodes[i].isCategory {
			return i
		}
	}
	return idx
}

// prevEntry returns the index of the previous non-category node before idx, or idx if none.
func prevEntry(nodes []treeNode, idx int) int {
	for i := idx - 1; i >= 0; i-- {
		if !nodes[i].isCategory {
			return i
		}
	}
	return idx
}

// lastEntryIndex returns the index of the last non-category node, or 0.
func lastEntryIndex(nodes []treeNode) int {
	for i := len(nodes) - 1; i >= 0; i-- {
		if !nodes[i].isCategory {
			return i
		}
	}
	return 0
}

func (m BrowserModel) Update(msg tea.Msg) (BrowserModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		// Forward constrained sizes to sub-models
		detailSize := tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.innerHeight()}
		m.entryDetail, _ = m.entryDetail.Update(detailSize)
		if m.searchActive {
			m.searchPanel, _ = m.searchPanel.Update(detailSize)
		}

	case ManifestLoadedMsg:
		m.loading = false
		if msg.Err != nil {
			m.err = msg.Err
			return m, nil
		}
		m.manifest = msg.Manifest
		m.nodes = buildTree(msg.Manifest)
		m.cursor = firstEntryIndex(m.nodes)
		// Auto-load the first entry into the detail panel
		cmd := m.loadCurrentEntry()
		return m, cmd

	case EntryLoadedMsg:
		var cmd tea.Cmd
		m.entryDetail, cmd = m.entryDetail.Update(msg)
		return m, cmd

	case KnowledgeSearchDismissedMsg:
		m.searchActive = false
		return m, nil

	case KnowledgeSearchResultSelectedMsg:
		m.searchActive = false
		// Find the matching node and move cursor to it
		for i, n := range m.nodes {
			if !n.isCategory && n.entry != nil && n.entry.Path == msg.FilePath {
				m.cursor = i
				break
			}
		}
		cmd := m.loadCurrentEntry()
		return m, cmd

	case tea.MouseMsg:
		isClick := msg.Action == tea.MouseActionPress && msg.Button == tea.MouseButtonLeft
		if msg.X < leftPanelWidth+2 {
			// Left pane click: set focus and reverse-map Y to tree node index.
			if isClick {
				m.focusedPanel = panelLeft
			}
			contentH := m.innerHeight()

			// Build visual line → node index mapping (same logic as viewTree).
			type visualLine struct{ nodeIndex int }
			var allLines []visualLine
			for i, node := range m.nodes {
				if node.isCategory {
					allLines = append(allLines, visualLine{i})
				} else {
					allLines = append(allLines, visualLine{i}) // title line
					allLines = append(allLines, visualLine{i}) // metadata line
				}
			}

			// Compute scroll offset (same as viewTree).
			cursorVisualLine := 0
			for vi, vl := range allLines {
				if vl.nodeIndex == m.cursor {
					cursorVisualLine = vi
					break
				}
			}
			cursorEndLine := cursorVisualLine
			if m.cursor < len(m.nodes) && !m.nodes[m.cursor].isCategory {
				cursorEndLine = cursorVisualLine + 1
			}
			offset := 0
			if cursorEndLine >= contentH {
				offset = cursorEndLine - contentH + 1
			}

			// Map click Y to visual line index: Y=0 is top border, content starts at Y=1.
			clickedVisualLine := offset + (msg.Y - 1)
			if clickedVisualLine >= 0 && clickedVisualLine < len(allLines) {
				targetNode := allLines[clickedVisualLine].nodeIndex
				// Skip category headers — only select entry nodes.
				if targetNode < len(m.nodes) && !m.nodes[targetNode].isCategory {
					if targetNode != m.cursor {
						m.cursor = targetNode
						cmd := m.loadCurrentEntry()
						return m, cmd
					}
				}
			}
		} else {
			// Right pane: set focus on click, always forward to entry detail.
			if isClick {
				m.focusedPanel = panelRight
			}
			var cmd tea.Cmd
			m.entryDetail, cmd = m.entryDetail.Update(msg)
			return m, cmd
		}

	case tea.KeyMsg:
		// When search is active, route all keys to the search panel
		if m.searchActive {
			var cmd tea.Cmd
			m.searchPanel, cmd = m.searchPanel.Update(msg)
			return m, cmd
		}

		// Tree view key handling
		switch msg.String() {
		case "esc":
			if m.focusedPanel == panelRight {
				m.focusedPanel = panelLeft
				return m, nil
			}
			return m, func() tea.Msg { return BrowserDismissedMsg{} }
		case "j", "down":
			if m.focusedPanel == panelLeft {
				next := nextEntry(m.nodes, m.cursor)
				if next != m.cursor {
					m.cursor = next
					cmd := m.loadCurrentEntry()
					return m, cmd
				}
			} else {
				// Right panel: forward to entry detail (scroll)
				var cmd tea.Cmd
				m.entryDetail, cmd = m.entryDetail.Update(msg)
				return m, cmd
			}
		case "k", "up":
			if m.focusedPanel == panelLeft {
				prev := prevEntry(m.nodes, m.cursor)
				if prev != m.cursor {
					m.cursor = prev
					cmd := m.loadCurrentEntry()
					return m, cmd
				}
			} else {
				var cmd tea.Cmd
				m.entryDetail, cmd = m.entryDetail.Update(msg)
				return m, cmd
			}
		case "g", "home":
			if m.focusedPanel == panelLeft {
				first := firstEntryIndex(m.nodes)
				if first != m.cursor {
					m.cursor = first
					cmd := m.loadCurrentEntry()
					return m, cmd
				}
			}
		case "G", "end":
			if m.focusedPanel == panelLeft {
				last := lastEntryIndex(m.nodes)
				if last != m.cursor {
					m.cursor = last
					cmd := m.loadCurrentEntry()
					return m, cmd
				}
			}
		case "l":
			if m.focusedPanel == panelLeft {
				m.focusedPanel = panelRight
				return m, nil
			}
		case "h":
			if m.focusedPanel == panelRight {
				m.focusedPanel = panelLeft
				return m, nil
			}
		case "tab":
			if m.focusedPanel == panelLeft {
				m.focusedPanel = panelRight
			} else {
				m.focusedPanel = panelLeft
			}
			return m, nil
		case "/":
			m.searchActive = true
			m.searchPanel = NewSearchModel()
			// Apply constrained dimensions to the fresh search panel
			if m.width > 0 {
				m.searchPanel, _ = m.searchPanel.Update(tea.WindowSizeMsg{
					Width:  m.rightPanelWidth(),
					Height: m.innerHeight(),
				})
			}
			return m, m.searchPanel.Init()
		default:
			// Forward unhandled keys to entry detail when right panel is focused
			if m.focusedPanel == panelRight {
				var cmd tea.Cmd
				m.entryDetail, cmd = m.entryDetail.Update(msg)
				return m, cmd
			}
		}
	}

	// Route non-key messages to search panel when search is active
	if m.searchActive {
		var cmd tea.Cmd
		m.searchPanel, cmd = m.searchPanel.Update(msg)
		return m, cmd
	}

	return m, nil
}

func (m BrowserModel) View() string {
	if m.loading {
		return "\n  Loading knowledge store...\n"
	}

	if m.err != nil {
		dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
		return fmt.Sprintf("\n  Error: %v\n\n  %s\n", m.err,
			dimStyle.Render("Press Esc to go back."))
	}

	return m.viewSplit()
}

// viewTree renders the left panel: a flat, always-expanded knowledge tree.
// Category headers are cyan bold ending in "/"; entries are 2-line rows
// with "> " cursor prefix + title on line 1, dim metadata on line 2.
// All lines are padded to exactly leftPanelWidth visual columns.
func (m BrowserModel) viewTree() string {
	dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	catStyle := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("6"))
	selTitleStyle := lipgloss.NewStyle().Background(lipgloss.Color("237")).Bold(true)
	selMetaStyle := lipgloss.NewStyle().Background(lipgloss.Color("237"))
	confStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("3"))

	if len(m.nodes) == 0 {
		line := dimStyle.Render("  No knowledge entries.")
		return padLine(line, leftPanelWidth)
	}

	contentH := m.innerHeight()

	// Build visual lines: category = 1 line, entry = 2 lines (title + metadata).
	type visualLine struct {
		text      string
		nodeIndex int
	}
	var allLines []visualLine

	for i, node := range m.nodes {
		if node.isCategory {
			line := catStyle.Render("  " + node.label + "/")
			allLines = append(allLines, visualLine{text: padLine(line, leftPanelWidth), nodeIndex: i})
		} else {
			selected := i == m.cursor

			// Line 1: cursor prefix + title truncated to 38 chars
			cursorPrefix := "  "
			if selected {
				cursorPrefix = "> "
			}
			title := truncateText(node.label, leftPanelWidth-2)
			line1 := cursorPrefix + title
			line1 = padLine(line1, leftPanelWidth)

			// Line 2: dim metadata (confidence + learned date)
			var metaParts []string
			if node.entry != nil {
				if node.entry.Confidence != "" {
					metaParts = append(metaParts, confStyle.Render(node.entry.Confidence))
				}
				if node.entry.Learned != "" {
					metaParts = append(metaParts, dimStyle.Render(node.entry.Learned))
				}
			}
			line2 := "    " // 4-char indent for metadata
			if len(metaParts) > 0 {
				line2 += strings.Join(metaParts, " ")
			}
			line2 = padLine(line2, leftPanelWidth)

			if selected {
				line1 = selTitleStyle.Render(line1)
				line2 = selMetaStyle.Render(line2)
			}

			allLines = append(allLines, visualLine{text: line1, nodeIndex: i})
			allLines = append(allLines, visualLine{text: line2, nodeIndex: i})
		}
	}

	// Find the visual line index where the cursor's first line appears.
	cursorVisualLine := 0
	for vi, vl := range allLines {
		if vl.nodeIndex == m.cursor {
			cursorVisualLine = vi
			break
		}
	}

	// For entry nodes the cursor occupies 2 lines — ensure both are visible.
	cursorEndLine := cursorVisualLine
	if m.cursor < len(m.nodes) && !m.nodes[m.cursor].isCategory {
		cursorEndLine = cursorVisualLine + 1
	}

	// Scroll so the cursor is visible.
	offset := 0
	if cursorEndLine >= contentH {
		offset = cursorEndLine - contentH + 1
	}

	end := offset + contentH
	if end > len(allLines) {
		end = len(allLines)
	}

	var b strings.Builder
	for i := offset; i < end; i++ {
		b.WriteString(allLines[i].text)
		b.WriteString("\n")
	}

	return b.String()
}

// viewSplit assembles the full split-pane browser layout: top border, content rows
// line-by-line with lipgloss.Width padding, bottom border. The right panel shows
// searchPanel.View() when searchActive, otherwise entryDetail.View().
func (m BrowserModel) viewSplit() string {
	contentH := m.innerHeight()
	leftInner := leftPanelWidth
	rightInner := m.rightPanelWidth()

	// Focus-aware border colors
	activeBorderColor := lipgloss.Color("4")     // blue
	inactiveBorderColor := lipgloss.Color("238") // dim

	leftBorderColor := inactiveBorderColor
	rightBorderColor := inactiveBorderColor
	if m.focusedPanel == panelLeft {
		leftBorderColor = activeBorderColor
	}
	if m.focusedPanel == panelRight {
		rightBorderColor = activeBorderColor
	}

	leftBS := lipgloss.NewStyle().Foreground(leftBorderColor)
	rightBS := lipgloss.NewStyle().Foreground(rightBorderColor)

	leftTitleS := lipgloss.NewStyle().Foreground(leftBorderColor).Bold(m.focusedPanel == panelLeft)
	rightTitleS := lipgloss.NewStyle().Foreground(rightBorderColor).Bold(m.focusedPanel == panelRight)

	// Build panel titles
	leftTitle := "Knowledge"
	rightTitle := "Detail"
	if m.cursor >= 0 && m.cursor < len(m.nodes) && m.nodes[m.cursor].entry != nil {
		t := m.nodes[m.cursor].entry.Title
		maxW := rightInner - 6
		if lipgloss.Width(t) > maxW && maxW > 3 {
			runes := []rune(t)
			t = string(runes[:maxW-1]) + "…"
		}
		rightTitle = t
	}
	if m.searchActive {
		rightTitle = "Search"
	}

	// Top border
	topRow := leftBS.Render("┌") +
		renderBrowserBorderTitle(leftTitle, leftInner, leftTitleS, leftBS) +
		leftBS.Render("┐") +
		rightBS.Render("┌") +
		renderBrowserBorderTitle(rightTitle, rightInner, rightTitleS, rightBS) +
		rightBS.Render("┐")

	// Bottom border
	bottomRow := leftBS.Render("└") +
		leftBS.Render(strings.Repeat("─", leftInner)) +
		leftBS.Render("┘") +
		rightBS.Render("└") +
		rightBS.Render(strings.Repeat("─", rightInner)) +
		rightBS.Render("┘")

	// Get panel content
	leftView := m.viewTree()
	var rightView string
	if m.searchActive {
		rightView = m.searchPanel.View()
	} else {
		rightView = m.entryDetail.View()
	}

	leftLines := strings.Split(leftView, "\n")
	rightLines := strings.Split(rightView, "\n")

	leftBorderChar := leftBS.Render("│")
	rightBorderChar := rightBS.Render("│")

	var b strings.Builder
	b.WriteString(topRow)
	b.WriteString("\n")
	for i := 0; i < contentH; i++ {
		left := ""
		if i < len(leftLines) {
			left = leftLines[i]
		}
		right := "  " // 2-char left margin inside right panel
		if i < len(rightLines) {
			right = "  " + rightLines[i]
		}

		lW := lipgloss.Width(left)
		if lW > leftInner {
			left = truncateTreeLine(left, leftInner)
		} else if lW < leftInner {
			left += strings.Repeat(" ", leftInner-lW)
		}
		rW := lipgloss.Width(right)
		if rW > rightInner {
			right = truncateTreeLine(right, rightInner)
		} else if rW < rightInner {
			right += strings.Repeat(" ", rightInner-rW)
		}

		b.WriteString(leftBorderChar)
		b.WriteString(left)
		b.WriteString(leftBorderChar)
		b.WriteString(rightBorderChar)
		b.WriteString(right)
		b.WriteString(rightBorderChar)
		b.WriteString("\n")
	}
	b.WriteString(bottomRow)

	return b.String()
}

// renderBrowserBorderTitle renders "─ Title ──────────" filling exactly width chars.
func renderBrowserBorderTitle(title string, width int, titleS, borderS lipgloss.Style) string {
	prefix := borderS.Render("─ ")
	rendered := titleS.Render(title)
	usedW := 2 + lipgloss.Width(rendered) // "─ " + title
	remaining := width - usedW
	if remaining < 0 {
		remaining = 0
	}
	return prefix + rendered + borderS.Render(strings.Repeat("─", remaining))
}

// padLine pads or truncates a line to exactly width visual columns.
func padLine(s string, width int) string {
	w := lipgloss.Width(s)
	if w < width {
		return s + strings.Repeat(" ", width-w)
	}
	if w > width {
		return truncateTreeLine(s, width)
	}
	return s
}

// truncateTreeLine clips s to at most maxW visual columns, appending "…" if needed.
func truncateTreeLine(s string, maxW int) string {
	if lipgloss.Width(s) <= maxW {
		return s
	}
	runes := []rune(s)
	for i := len(runes) - 1; i >= 0; i-- {
		candidate := string(runes[:i]) + "…"
		if lipgloss.Width(candidate) <= maxW {
			return candidate
		}
	}
	return "…"
}

// truncateText truncates plain text to maxW visual columns.
func truncateText(s string, maxW int) string {
	if lipgloss.Width(s) <= maxW {
		return s
	}
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
