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

// treeNode represents one row in the flat knowledge tree.
// Category and subcategory headers (isCategory=true) are foldable group nodes;
// entry rows hold a pointer to the underlying KnowledgeEntry.
// The depth field encodes hierarchy level: 0 = top-level category,
// 1 = subcategory, 2+ = deeper nesting. Leaf entries have depth = parent+1.
type treeNode struct {
	isCategory bool
	depth      int             // hierarchy level: 0=category, 1=subcategory, ...
	folded     bool            // category/subcategory nodes: whether children are hidden
	isLast     bool            // entry nodes: last entry in its parent group (└── vs ├──)
	entry      *KnowledgeEntry // nil for category/subcategory headers
	label      string          // display text (category name, subcategory name, or entry title)
}

// buildTree creates a flat list of treeNode from a manifest.
// It parses each entry's Path to derive a hierarchical tree: top-level
// categories come from manifest.Categories (sorted by priority), and
// subdirectories within each category become subcategory nodes.
// Per D2: top-level categories start expanded, subcategories start folded.
func buildTree(manifest *Manifest) []treeNode {
	var nodes []treeNode
	for _, cat := range manifest.Categories {
		// Collect entries for this category
		var catEntries []*KnowledgeEntry
		for i := range manifest.Entries {
			if manifest.Entries[i].Category == cat.Name {
				catEntries = append(catEntries, &manifest.Entries[i])
			}
		}

		// Group entries by subdirectory path within the category.
		// e.g., path "conventions/skills/script-first.md" → subdir "skills"
		// Entries directly in the category dir have subdir "".
		type subdirGroup struct {
			subdir  string
			entries []*KnowledgeEntry
		}
		subdirOrder := []string{}
		subdirMap := map[string][]*KnowledgeEntry{}
		for _, e := range catEntries {
			// Strip category prefix and filename to get intermediate dirs
			rel := e.Path
			if strings.HasPrefix(rel, cat.Name+"/") {
				rel = rel[len(cat.Name)+1:]
			}
			parts := strings.Split(rel, "/")
			subdir := ""
			if len(parts) > 1 {
				// Everything except the filename is the subdirectory path
				subdir = strings.Join(parts[:len(parts)-1], "/")
			}
			if _, exists := subdirMap[subdir]; !exists {
				subdirOrder = append(subdirOrder, subdir)
			}
			subdirMap[subdir] = append(subdirMap[subdir], e)
		}

		hasSubdirs := false
		for _, sd := range subdirOrder {
			if sd != "" {
				hasSubdirs = true
				break
			}
		}

		// Top-level category node (depth 0, starts expanded)
		nodes = append(nodes, treeNode{
			isCategory: true,
			depth:      0,
			folded:     false,
			label:      cat.Name,
		})

		for si, subdir := range subdirOrder {
			entries := subdirMap[subdir]
			if subdir == "" {
				// Direct entries under the category (no subdirectory)
				firstEntry := len(nodes)
				for _, e := range entries {
					nodes = append(nodes, treeNode{
						depth: 1,
						entry: e,
						label: e.Title,
					})
				}
				// Mark last in group — but only if this is also the last subdir group
				if len(nodes) > firstEntry && (!hasSubdirs || si == len(subdirOrder)-1) {
					nodes[len(nodes)-1].isLast = true
				}
			} else {
				// Subcategory node (depth 1, starts folded per D2)
				isLastSubdir := si == len(subdirOrder)-1
				nodes = append(nodes, treeNode{
					isCategory: true,
					depth:      1,
					folded:     true,
					isLast:     isLastSubdir,
					label:      subdir,
				})
				firstEntry := len(nodes)
				for _, e := range entries {
					nodes = append(nodes, treeNode{
						depth: 2,
						entry: e,
						label: e.Title,
					})
				}
				if len(nodes) > firstEntry {
					nodes[len(nodes)-1].isLast = true
				}
			}
		}
	}
	return nodes
}

// toggleFold flips the folded state of the category node at idx.
// No-op if idx is out of range or not a category node.
func toggleFold(nodes []treeNode, idx int) {
	if idx >= 0 && idx < len(nodes) && nodes[idx].isCategory {
		nodes[idx].folded = !nodes[idx].folded
	}
}

// findParentCategory walks backwards from entryIdx to find the nearest
// preceding category/subcategory node at a shallower depth. Returns -1
// if no parent exists (e.g., for top-level category nodes at depth 0).
func findParentCategory(nodes []treeNode, entryIdx int) int {
	if entryIdx < 0 || entryIdx >= len(nodes) {
		return -1
	}
	myDepth := nodes[entryIdx].depth
	for i := entryIdx - 1; i >= 0; i-- {
		if nodes[i].isCategory && nodes[i].depth < myDepth {
			return i
		}
	}
	return -1
}

// expandAncestors unfolds all ancestor category/subcategory nodes of the
// node at idx, ensuring it becomes visible in the tree.
func expandAncestors(nodes []treeNode, idx int) {
	if idx < 0 || idx >= len(nodes) {
		return
	}
	targetDepth := nodes[idx].depth
	for i := idx - 1; i >= 0; i-- {
		if nodes[i].isCategory && nodes[i].depth < targetDepth {
			nodes[i].folded = false
			targetDepth = nodes[i].depth
			if targetDepth == 0 {
				break
			}
		}
	}
}

// isVisible returns whether the node at idx should be displayed.
// Top-level categories (depth 0) are always visible. All other nodes
// are hidden if any ancestor category/subcategory node is folded.
func isVisible(nodes []treeNode, idx int) bool {
	if idx < 0 || idx >= len(nodes) {
		return false
	}
	n := nodes[idx]
	if n.isCategory && n.depth == 0 {
		return true
	}
	// Walk backwards checking all ancestor category nodes.
	// An ancestor at depth d is any preceding isCategory node with depth < current node's depth.
	// If any ancestor is folded, this node is hidden.
	targetDepth := n.depth
	for i := idx - 1; i >= 0; i-- {
		if nodes[i].isCategory && nodes[i].depth < targetDepth {
			if nodes[i].folded {
				return false
			}
			// Move up to check the next ancestor level
			targetDepth = nodes[i].depth
			if targetDepth == 0 {
				break
			}
		}
	}
	return true
}

// firstVisible returns the index of the first visible node, or 0.
func firstVisible(nodes []treeNode) int {
	for i := range nodes {
		if isVisible(nodes, i) {
			return i
		}
	}
	return 0
}

// BrowserModel is the Bubble Tea model for the knowledge browser.
type BrowserModel struct {
	nodes        []treeNode
	cursor       int
	scrollOffset int // persisted scroll offset for the tree panel
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

// updateScrollOffset recalculates the persisted scroll offset so the cursor
// remains visible. Call this from Update after any cursor movement.
func (m *BrowserModel) updateScrollOffset() {
	contentH := m.innerHeight()

	// Count visible nodes up to and including the cursor position.
	cursorVisualLine := 0
	for i := 0; i < len(m.nodes); i++ {
		if !isVisible(m.nodes, i) {
			continue
		}
		if i == m.cursor {
			break
		}
		cursorVisualLine++
	}

	if cursorVisualLine < m.scrollOffset {
		m.scrollOffset = cursorVisualLine
	}
	if cursorVisualLine >= m.scrollOffset+contentH {
		m.scrollOffset = cursorVisualLine - contentH + 1
	}

	// Count total visible lines for clamping
	totalVisible := 0
	for i := range m.nodes {
		if isVisible(m.nodes, i) {
			totalVisible++
		}
	}
	maxOffset := totalVisible - contentH
	if maxOffset < 0 {
		maxOffset = 0
	}
	if m.scrollOffset > maxOffset {
		m.scrollOffset = maxOffset
	}
}

// nextVisible returns the index of the next visible node after idx, or idx if none.
func nextVisible(nodes []treeNode, idx int) int {
	for i := idx + 1; i < len(nodes); i++ {
		if isVisible(nodes, i) {
			return i
		}
	}
	return idx
}

// prevVisible returns the index of the previous visible node before idx, or idx if none.
func prevVisible(nodes []treeNode, idx int) int {
	for i := idx - 1; i >= 0; i-- {
		if isVisible(nodes, i) {
			return i
		}
	}
	return idx
}

// lastVisible returns the index of the last visible node, or 0.
func lastVisible(nodes []treeNode) int {
	for i := len(nodes) - 1; i >= 0; i-- {
		if isVisible(nodes, i) {
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
		m.cursor = firstVisible(m.nodes)
		m.updateScrollOffset()
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
				// Ensure all ancestor categories are expanded so the entry is visible
				expandAncestors(m.nodes, i)
				m.cursor = i
				break
			}
		}
		m.updateScrollOffset()
		cmd := m.loadCurrentEntry()
		return m, cmd

	case tea.MouseMsg:
		isClick := msg.Action == tea.MouseActionPress && msg.Button == tea.MouseButtonLeft
		if msg.X < leftPanelWidth+2 {
			// Left pane click: set focus and reverse-map Y to tree node index.
			if isClick {
				m.focusedPanel = panelLeft
			}

			// Build visual line → node index mapping: 1 line per visible node.
			type visualLine struct{ nodeIndex int }
			var allLines []visualLine
			for i := range m.nodes {
				if isVisible(m.nodes, i) {
					allLines = append(allLines, visualLine{i})
				}
			}

			// Map click Y to visual line index using persisted scroll offset.
			// Y=0 is top border, content starts at Y=1.
			clickedVisualLine := m.scrollOffset + (msg.Y - 1)
			if clickedVisualLine >= 0 && clickedVisualLine < len(allLines) {
				targetNode := allLines[clickedVisualLine].nodeIndex
				if targetNode < len(m.nodes) && targetNode != m.cursor {
					m.cursor = targetNode
					m.updateScrollOffset()
					if !m.nodes[targetNode].isCategory {
						cmd := m.loadCurrentEntry()
						return m, cmd
					}
					return m, nil
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
				next := nextVisible(m.nodes, m.cursor)
				if next != m.cursor {
					m.cursor = next
					m.updateScrollOffset()
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
				prev := prevVisible(m.nodes, m.cursor)
				if prev != m.cursor {
					m.cursor = prev
					m.updateScrollOffset()
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
				first := firstVisible(m.nodes)
				if first != m.cursor {
					m.cursor = first
					m.updateScrollOffset()
					cmd := m.loadCurrentEntry()
					return m, cmd
				}
			}
		case "G", "end":
			if m.focusedPanel == panelLeft {
				last := lastVisible(m.nodes)
				if last != m.cursor {
					m.cursor = last
					m.updateScrollOffset()
					cmd := m.loadCurrentEntry()
					return m, cmd
				}
			}
		case "enter", " ":
			if m.focusedPanel == panelLeft && m.cursor < len(m.nodes) {
				if m.nodes[m.cursor].isCategory {
					toggleFold(m.nodes, m.cursor)
					m.updateScrollOffset()
					return m, nil
				}
				cmd := m.loadCurrentEntry()
				return m, cmd
			}
		case "left":
			if m.focusedPanel == panelLeft && m.cursor < len(m.nodes) {
				if m.nodes[m.cursor].isCategory {
					if !m.nodes[m.cursor].folded {
						// Fold if expanded
						toggleFold(m.nodes, m.cursor)
					} else {
						// Already folded: move cursor to parent (if any)
						parent := findParentCategory(m.nodes, m.cursor)
						if parent >= 0 {
							m.cursor = parent
						}
					}
					m.updateScrollOffset()
					return m, nil
				}
				// Entry node: move cursor to parent category/subcategory
				parent := findParentCategory(m.nodes, m.cursor)
				if parent >= 0 {
					m.cursor = parent
				}
				m.updateScrollOffset()
				return m, nil
			}
		case "right":
			if m.focusedPanel == panelLeft && m.cursor < len(m.nodes) {
				if m.nodes[m.cursor].isCategory && m.nodes[m.cursor].folded {
					// Expand folded category and move cursor to first child entry
					toggleFold(m.nodes, m.cursor)
					next := nextVisible(m.nodes, m.cursor)
					if next != m.cursor {
						m.cursor = next
						m.updateScrollOffset()
						cmd := m.loadCurrentEntry()
						return m, cmd
					}
					m.updateScrollOffset()
					return m, nil
				}
				// Expanded category or entry: switch focus to right panel
				m.focusedPanel = panelRight
				return m, nil
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

// viewTree renders the left panel: a foldable knowledge tree with Unicode
// indent guides. Category headers show ▼/▶ fold indicators; entries show
// ├──/└── tree connectors. Each visible node is exactly one visual line,
// padded to leftPanelWidth columns.
func (m BrowserModel) viewTree() string {
	dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	catStyle := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("6"))
	selStyle := lipgloss.NewStyle().Background(lipgloss.Color("237")).Bold(true)

	if len(m.nodes) == 0 {
		line := dimStyle.Render("  No knowledge entries.")
		return padLine(line, leftPanelWidth)
	}

	contentH := m.innerHeight()

	// Build visual lines: 1 line per visible node.
	type visualLine struct {
		text      string
		nodeIndex int
	}
	var allLines []visualLine

	for i, node := range m.nodes {
		if !isVisible(m.nodes, i) {
			continue
		}

		selected := i == m.cursor

		// Depth-aware indentation: 2 spaces per depth level
		indent := strings.Repeat("  ", node.depth)

		if node.isCategory {
			// Category/subcategory: fold indicator + name + "/"
			indicator := "▼ "
			if node.folded {
				indicator = "▶ "
			}
			line := catStyle.Render(indent + indicator + node.label + "/")
			line = padLine(line, leftPanelWidth)
			if selected {
				line = selStyle.Render(line)
			}
			allLines = append(allLines, visualLine{text: line, nodeIndex: i})
		} else {
			// Entry: tree connector relative to parent depth
			connector := "├── "
			if node.isLast {
				connector = "└── "
			}
			prefixLen := len(indent) + len(connector)
			title := truncateText(node.label, leftPanelWidth-prefixLen)
			line := indent + connector + title
			line = padLine(line, leftPanelWidth)
			if selected {
				line = selStyle.Render(line)
			}
			allLines = append(allLines, visualLine{text: line, nodeIndex: i})
		}
	}

	// Find the visual line index where the cursor appears.
	cursorVisualLine := 0
	for vi, vl := range allLines {
		if vl.nodeIndex == m.cursor {
			cursorVisualLine = vi
			break
		}
	}

	// Use persisted scroll offset with bidirectional cursor tracking.
	offset := m.scrollOffset
	if cursorVisualLine < offset {
		offset = cursorVisualLine // cursor above viewport
	}
	if cursorVisualLine >= offset+contentH {
		offset = cursorVisualLine - contentH + 1 // cursor below viewport
	}
	// Clamp offset to valid range
	maxOffset := len(allLines) - contentH
	if maxOffset < 0 {
		maxOffset = 0
	}
	if offset > maxOffset {
		offset = maxOffset
	}

	end := offset + contentH
	if end > len(allLines) {
		end = len(allLines)
	}

	// Add scroll indicators when content overflows
	dimStyle2 := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	hasMore := end < len(allLines)
	hasLess := offset > 0

	var b strings.Builder
	for i := offset; i < end; i++ {
		line := allLines[i].text
		if i == offset && hasLess {
			line = replaceLastChar(line, leftPanelWidth, dimStyle2.Render("▲"))
		}
		if i == end-1 && hasMore {
			line = replaceLastChar(line, leftPanelWidth, dimStyle2.Render("▼"))
		}
		b.WriteString(line)
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

	leftTitleFg := lipgloss.Color("7")
	if m.focusedPanel == panelLeft {
		leftTitleFg = activeBorderColor
	}
	rightTitleFg := lipgloss.Color("7")
	if m.focusedPanel == panelRight {
		rightTitleFg = activeBorderColor
	}
	leftTitleS := lipgloss.NewStyle().Foreground(leftTitleFg).Bold(m.focusedPanel == panelLeft)
	rightTitleS := lipgloss.NewStyle().Foreground(rightTitleFg).Bold(m.focusedPanel == panelRight)

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

// replaceLastChar replaces the trailing padding of a line with a rendered
// indicator string, keeping the total visual width at targetWidth.
func replaceLastChar(line string, targetWidth int, indicator string) string {
	indW := lipgloss.Width(indicator)
	// Truncate line to make room for the indicator
	trimmed := truncateTreeLine(line, targetWidth-indW)
	trimmedW := lipgloss.Width(trimmed)
	gap := targetWidth - trimmedW - indW
	if gap < 0 {
		gap = 0
	}
	return trimmed + strings.Repeat(" ", gap) + indicator
}
