package main

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/followup"
)

func (m model) View() string {
	if m.err != nil {
		return fmt.Sprintf("Error: %v\n\nPress q to quit.\n", m.err)
	}

	if m.state == stateNoRepo {
		return m.viewNoRepo()
	}

	if m.state == stateOnboarding {
		return m.viewOnboarding()
	}

	if m.state == stateKnowledge {
		return m.browser.View()
	}

	var base string
	if m.state == stateSettlement {
		base = m.viewSettlement()
	} else {
		cfg := m.buildPaneConfig()
		if m.layoutMode == config.LayoutTopBottom {
			base = m.viewTopBottom(cfg)
		} else {
			base = m.viewSideBySide(cfg)
		}
	}

	if m.popupActive {
		return lipgloss.Place(m.width, m.height-1, lipgloss.Center, lipgloss.Center, m.popup.View())
	}
	if m.sessionConfirmActive {
		return m.renderSpecConfirmModal()
	}
	if m.aiInputActive {
		return m.renderAIModal()
	}
	if m.confirmAction != "" {
		return m.renderConfirmModal()
	}
	if m.showHelp {
		return m.renderHelpModal()
	}
	if m.settingsActive && m.settingsPanel != nil {
		return m.renderSettingsModal()
	}
	return base
}

// viewOnboarding renders a full-screen centered welcome view for first-time initialization.
func (m model) viewOnboarding() string {
	titleS := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("4"))
	dimS := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))

	repoName := m.config.RepoIdentifier
	title := titleS.Render(repoName)

	var action string
	if m.initLoading {
		action = dimS.Render("Initializing...")
	} else {
		action = dimS.Render("Press Enter to initialize")
	}
	quit := dimS.Render("Press q to quit")

	content := title + "\n\n" + action + "\n" + quit
	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, content)
}

// viewNoRepo renders a full-screen centered view when the TUI is launched outside a git repository.
func (m model) viewNoRepo() string {
	titleS := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("4"))
	dimS := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))

	dirName := filepath.Base(m.config.ProjectDir)
	title := titleS.Render(dirName)
	line1 := dimS.Render("Not inside a git repository")
	line2 := dimS.Render("Navigate to a git repo and relaunch")
	quit := dimS.Render("Press q to quit")

	content := title + "\n\n" + line1 + "\n" + line2 + "\n\n" + quit
	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, content)
}

// truncateLine clips s to at most maxW visual columns, appending "…" if needed.
func truncateLine(s string, maxW int) string {
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

// renderTabIndicator renders a full-width tab row showing "work (N) · follow-ups (N)".
// The active tab is highlighted; the inactive tab is dimmed. Width is the total line width.
// Only the key to switch to the inactive view is shown (f when in work view, w when in follow-ups view).
func renderTabIndicator(activeTab appState, workCount, followupCount, settlementCount, width int) string {
	activeS := lipgloss.NewStyle().Foreground(lipgloss.Color("252")).Bold(true)
	inactiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("238"))
	sepS := lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
	hintS := lipgloss.NewStyle().Foreground(lipgloss.Color("240"))

	var workS, followupS, settlementS lipgloss.Style
	var hint string
	switch activeTab {
	case stateFollowUps:
		workS, followupS, settlementS = inactiveS, activeS, inactiveS
		hint = "w  "
	case stateSettlement:
		workS, followupS, settlementS = inactiveS, inactiveS, activeS
		hint = "w/f"
	default:
		workS, followupS, settlementS = activeS, inactiveS, inactiveS
		hint = "f  "
	}

	workLabel := fmt.Sprintf("work (%d)", workCount)
	followupLabel := fmt.Sprintf("follow-ups (%d)", followupCount)
	settlementLabel := fmt.Sprintf("settlement (%d)", settlementCount)
	sep := sepS.Render(" · ")

	line := "  " + hintS.Render(hint+"  ") + workS.Render(workLabel) + sep + followupS.Render(followupLabel) + sep + settlementS.Render(settlementLabel)
	lineW := lipgloss.Width(line)
	if lineW < width {
		line += strings.Repeat(" ", width-lineW)
	}
	return line
}

func (m model) viewSettlement() string {
	w := m.width
	if w <= 0 {
		w = 80
	}
	contentH := m.innerHeight() - 1
	if contentH < 1 {
		contentH = 1
	}
	innerW := w - 2
	if innerW < 24 {
		innerW = 24
	}
	borderS := lipgloss.NewStyle().Foreground(lipgloss.Color("4"))
	titleS := lipgloss.NewStyle().Foreground(lipgloss.Color("4")).Bold(true)
	bodyW := innerW - 1 // outer row renderer adds one leading space
	if bodyW < 1 {
		bodyW = 1
	}
	lines := m.renderSettlementBodyLines(bodyW, contentH)

	var b strings.Builder
	b.WriteString(renderTabIndicator(stateSettlement, len(m.list.Items()), m.followupList.FollowUpCount(), m.settlement.Count(), w))
	b.WriteString("\n")
	b.WriteString(borderS.Render("┌"))
	b.WriteString(renderBorderTitle("Settlement", innerW, titleS, borderS))
	b.WriteString(borderS.Render("┐"))
	b.WriteString("\n")
	for i := 0; i < contentH; i++ {
		line := ""
		if i < len(lines) {
			line = " " + lines[i]
		}
		lineW := lipgloss.Width(line)
		if lineW > innerW {
			line = truncateLine(line, innerW)
		} else if lineW < innerW {
			line += strings.Repeat(" ", innerW-lineW)
		}
		b.WriteString(borderS.Render("│"))
		b.WriteString(line)
		b.WriteString(borderS.Render("│"))
		b.WriteString("\n")
	}
	b.WriteString(borderS.Render("└"))
	b.WriteString(borderS.Render(strings.Repeat("─", innerW)))
	b.WriteString(borderS.Render("┘"))
	b.WriteString("\n")
	b.WriteString(m.renderStatusBar(w))
	return b.String()
}

func (m model) renderSettlementBodyLines(width, height int) []string {
	if height <= 0 {
		return nil
	}
	settingsMaxH := settlementSettingsMaxHeight(height)
	settingsLines := trimTrailingBlankLines(strings.Split(m.settlementSettingsInlineView(width, settingsMaxH), "\n"))
	if len(settingsLines) > settingsMaxH {
		settingsLines = settingsLines[:settingsMaxH]
	}
	settingsBlockH := 0
	if len(settingsLines) > 0 {
		settingsBlockH = len(settingsLines) + 1
	}

	statusH := height - settingsBlockH
	if statusH < 1 {
		statusH = 1
	}
	statusLines := strings.Split(m.settlement.SetSize(width, statusH).View(), "\n")
	out := make([]string, 0, height)
	for i := 0; i < len(statusLines) && i < statusH && len(out) < height; i++ {
		out = append(out, fitLine(statusLines[i], width))
	}
	for len(out) < statusH && len(out) < height {
		out = append(out, strings.Repeat(" ", width))
	}
	if len(settingsLines) > 0 && len(out) < height {
		out = append(out, renderSettlementSeparator(width))
		for i := 0; i < len(settingsLines) && len(out) < height; i++ {
			out = append(out, fitLine(settingsLines[i], width))
		}
	}
	return out
}

func settlementSettingsMaxHeight(height int) int {
	if height < 8 {
		return 2
	}
	maxH := height / 3
	if maxH < 4 {
		maxH = 4
	}
	if maxH > 10 {
		maxH = 10
	}
	return maxH
}

func renderSettlementSeparator(width int) string {
	label := " Settings "
	if width <= lipgloss.Width(label)+2 {
		return lipgloss.NewStyle().Foreground(lipgloss.Color("238")).Render(strings.Repeat("─", width))
	}
	left := "─"
	right := strings.Repeat("─", width-lipgloss.Width(label)-1)
	return lipgloss.NewStyle().Foreground(lipgloss.Color("238")).Render(left) +
		lipgloss.NewStyle().Foreground(lipgloss.Color("7")).Bold(true).Render(label) +
		lipgloss.NewStyle().Foreground(lipgloss.Color("238")).Render(right)
}

func renderSettlementRule(width int) string {
	if width < 1 {
		return ""
	}
	return lipgloss.NewStyle().Foreground(lipgloss.Color("238")).Render(strings.Repeat("─", width))
}

func (m model) settlementSettingsInlineView(width, height int) string {
	if m.settlementSettingsPanel == nil {
		return lipgloss.NewStyle().Foreground(lipgloss.Color("8")).Render("settlement settings unavailable")
	}
	if width < 24 {
		width = 24
	}
	if height < 1 {
		height = 1
	}
	m.settlementSettingsPanel.SetSize(width, height)
	return m.settlementSettingsPanel.View()
}

func fitLine(line string, width int) string {
	if width < 1 {
		return ""
	}
	lineW := lipgloss.Width(line)
	if lineW > width {
		return truncateLine(line, width)
	}
	if lineW < width {
		return line + strings.Repeat(" ", width-lineW)
	}
	return line
}

func trimTrailingBlankLines(lines []string) []string {
	end := len(lines)
	for end > 0 && strings.TrimSpace(lines[end-1]) == "" {
		end--
	}
	return lines[:end]
}

// renderBorderTitle renders "─ Title ──────────" filling exactly width chars.
func renderBorderTitle(title string, width int, titleS, borderS lipgloss.Style) string {
	prefix := borderS.Render("─ ")
	rendered := titleS.Render(title)
	usedW := 2 + lipgloss.Width(rendered) // "─ " + title
	remaining := width - usedW
	if remaining < 0 {
		remaining = 0
	}
	return prefix + rendered + borderS.Render(strings.Repeat("─", remaining))
}

// renderBorderTitleWithAnnot renders "─ Title ─── annot ─" filling exactly width chars.
// annot is a pre-rendered string (may contain ANSI codes); annotW is its visual width.
func renderBorderTitleWithAnnot(title string, width int, titleS, borderS lipgloss.Style, annot string, annotW int) string {
	prefix := borderS.Render("─ ")
	rendered := titleS.Render(title)
	usedLeft := 2 + lipgloss.Width(rendered) // "─ " + title
	// Right side: " " + annot + " ─" = annotW + 3 visual chars
	rightSlot := annotW + 3
	middle := width - usedLeft - rightSlot
	if middle < 1 {
		middle = 1
	}
	return prefix + rendered + borderS.Render(strings.Repeat("─", middle)) + borderS.Render(" ") + annot + borderS.Render(" ─")
}

// viewSideBySide renders a side-by-side split pane using the entity-neutral paneConfig.
// It replaces viewSplitPane (stateWork) and viewFollowUpsSideBySide (stateFollowUps).
func (m model) viewSideBySide(cfg paneConfig) string {
	contentH := m.innerHeight() - 1 // 1 line reserved for tab indicator
	leftInner := leftPanelWidth
	rightInner := m.rightPanelWidth()

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

	// Truncate detail title to fit the right panel.
	rightTitle := cfg.detailTitle
	maxTitleW := rightInner - 6
	if lipgloss.Width(rightTitle) > maxTitleW && maxTitleW > 3 {
		runes := []rune(rightTitle)
		rightTitle = string(runes[:maxTitleW-1]) + "…"
	}

	// Right panel annotation: show "ctrl+t  detail · terminal" when a spec session exists.
	var rightBorderTitle string
	if cfg.hasSpecPanel {
		activeS := lipgloss.NewStyle().Foreground(lipgloss.Color("252"))
		inactiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("238"))
		sepS := lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
		var detailS, terminalS lipgloss.Style
		if m.terminalMode {
			detailS, terminalS = inactiveS, activeS
		} else {
			detailS, terminalS = activeS, inactiveS
		}
		termLabel := "terminal"
		termLabelW := 8
		if cfg.specPanel.IsDone() {
			termLabel = "terminal (done)"
			termLabelW = 15
		}
		modeAnnot := sepS.Render("ctrl+t  ") + detailS.Render("detail") + sepS.Render(" · ") + terminalS.Render(termLabel)
		modeAnnotW := 8 + 6 + 3 + termLabelW // "ctrl+t  " + "detail" + " · " + termLabel
		rightBorderTitle = renderBorderTitleWithAnnot(rightTitle, rightInner, rightTitleS, rightBS, modeAnnot, modeAnnotW)
	} else {
		rightBorderTitle = renderBorderTitle(rightTitle, rightInner, rightTitleS, rightBS)
	}

	topRow := leftBS.Render("┌") +
		renderBorderTitleWithAnnot(cfg.listTitle, leftInner, leftTitleS, leftBS, cfg.filterAnnot, cfg.filterAnnotW) +
		leftBS.Render("┐") +
		rightBS.Render("┌") +
		rightBorderTitle +
		rightBS.Render("┐")

	bottomRow := leftBS.Render("└") +
		leftBS.Render(strings.Repeat("─", leftInner)) +
		leftBS.Render("┘") +
		rightBS.Render("└") +
		rightBS.Render(strings.Repeat("─", rightInner)) +
		rightBS.Render("┘")

	leftLines := strings.Split(cfg.listView, "\n")

	// Right panel content: terminal mode shows spec panel, otherwise detail view.
	var rightLines []string
	if m.terminalMode && cfg.hasSpecPanel {
		rightLines = strings.Split(cfg.specPanel.View(), "\n")
	} else {
		rightLines = strings.Split(cfg.detailView, "\n")
	}

	leftBorderChar := leftBS.Render("│")
	rightBorderChar := rightBS.Render("│")

	var b strings.Builder
	b.WriteString(renderTabIndicator(cfg.state, cfg.listItemCount, cfg.fuItemCount, cfg.settlementCount, m.width))
	b.WriteString("\n")
	b.WriteString(topRow)
	b.WriteString("\n")
	for i := 0; i < contentH; i++ {
		left := ""
		if i < len(leftLines) {
			left = leftLines[i]
		}
		var right string
		if i < len(rightLines) {
			if m.terminalMode && cfg.hasSpecPanel {
				right = " " + rightLines[i] // 1-char left buffer; right buffer from padding
			} else {
				right = "  " + rightLines[i]
			}
		} else {
			right = "  "
		}

		lW := lipgloss.Width(left)
		if lW > leftInner {
			left = truncateLine(left, leftInner)
		} else if lW < leftInner {
			left += strings.Repeat(" ", leftInner-lW)
		}
		rW := lipgloss.Width(right)
		if rW > rightInner {
			right = truncateLine(right, rightInner)
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
	b.WriteString("\n")
	b.WriteString(m.renderStatusBar(m.width))
	return b.String()
}

// viewTopBottom renders a stacked top/bottom split using the entity-neutral paneConfig.
// It replaces viewSplitPaneTopBottom (stateWork) and viewFollowUpsTopBottom (stateFollowUps).
func (m model) viewTopBottom(cfg paneConfig) string {
	if m.width <= 0 || m.height <= 0 {
		return ""
	}
	topH := m.topPanelHeight() - 1 // 1 line reserved for tab indicator
	bottomH := m.detailPanelHeight()
	panelW := m.topPanelWidth()

	activeBorderColor := lipgloss.Color("4")     // blue
	inactiveBorderColor := lipgloss.Color("238") // dim

	topBorderColor := inactiveBorderColor
	bottomBorderColor := inactiveBorderColor
	if m.focusedPanel == panelLeft {
		topBorderColor = activeBorderColor
	}
	if m.focusedPanel == panelRight {
		bottomBorderColor = activeBorderColor
	}

	topBS := lipgloss.NewStyle().Foreground(topBorderColor)
	bottomBS := lipgloss.NewStyle().Foreground(bottomBorderColor)

	topTitleFg := lipgloss.Color("7")
	if m.focusedPanel == panelLeft {
		topTitleFg = activeBorderColor
	}
	bottomTitleFg := lipgloss.Color("7")
	if m.focusedPanel == panelRight {
		bottomTitleFg = activeBorderColor
	}
	topTitleS := lipgloss.NewStyle().Foreground(topTitleFg).Bold(m.focusedPanel == panelLeft)
	bottomTitleS := lipgloss.NewStyle().Foreground(bottomTitleFg).Bold(m.focusedPanel == panelRight)

	// Truncate detail title to fit the bottom panel.
	bottomTitle := cfg.detailTitle
	maxTitleW := panelW - 6
	if lipgloss.Width(bottomTitle) > maxTitleW && maxTitleW > 3 {
		runes := []rune(bottomTitle)
		bottomTitle = string(runes[:maxTitleW-1]) + "…"
	}

	topBorderChar := topBS.Render("│")
	bottomBorderChar := bottomBS.Render("│")

	topLines := strings.Split(cfg.listView, "\n")

	// Bottom panel content: terminal mode shows spec panel, otherwise detail view.
	var bottomLines []string
	if m.terminalMode && cfg.hasSpecPanel {
		bottomLines = strings.Split(cfg.specPanel.View(), "\n")
	} else {
		bottomLines = strings.Split(cfg.detailView, "\n")
	}

	padLine := func(line string) string {
		w := lipgloss.Width(line)
		if w > panelW {
			return truncateLine(line, panelW)
		}
		if w < panelW {
			return line + strings.Repeat(" ", panelW-w)
		}
		return line
	}

	// Bottom panel annotation: show "ctrl+t  detail · terminal" when a spec session exists.
	var bottomBorderTitle string
	if cfg.hasSpecPanel {
		activeS := lipgloss.NewStyle().Foreground(lipgloss.Color("252"))
		inactiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("238"))
		sepS := lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
		var detailS, terminalS lipgloss.Style
		if m.terminalMode {
			detailS, terminalS = inactiveS, activeS
		} else {
			detailS, terminalS = activeS, inactiveS
		}
		termLabel := "terminal"
		termLabelW := 8
		if cfg.specPanel.IsDone() {
			termLabel = "terminal (done)"
			termLabelW = 15
		}
		modeAnnot := sepS.Render("ctrl+t  ") + detailS.Render("detail") + sepS.Render(" · ") + terminalS.Render(termLabel)
		modeAnnotW := 8 + 6 + 3 + termLabelW // "ctrl+t  " + "detail" + " · " + termLabel
		bottomBorderTitle = renderBorderTitleWithAnnot(bottomTitle, panelW, bottomTitleS, bottomBS, modeAnnot, modeAnnotW)
	} else {
		bottomBorderTitle = renderBorderTitle(bottomTitle, panelW, bottomTitleS, bottomBS)
	}

	var b strings.Builder
	b.WriteString(renderTabIndicator(cfg.state, cfg.listItemCount, cfg.fuItemCount, cfg.settlementCount, m.width))
	b.WriteString("\n")

	// === Top panel (list) ===
	b.WriteString(topBS.Render("┌"))
	b.WriteString(renderBorderTitleWithAnnot(cfg.listTitle, panelW, topTitleS, topBS, cfg.filterAnnot, cfg.filterAnnotW))
	b.WriteString(topBS.Render("┐"))
	b.WriteString("\n")
	for i := 0; i < topH; i++ {
		line := ""
		if i < len(topLines) {
			line = topLines[i]
		}
		b.WriteString(topBorderChar)
		b.WriteString(padLine(line))
		b.WriteString(topBorderChar)
		b.WriteString("\n")
	}
	b.WriteString(topBS.Render("└"))
	b.WriteString(topBS.Render(strings.Repeat("─", panelW)))
	b.WriteString(topBS.Render("┘"))
	b.WriteString("\n")

	// === Bottom panel (detail or terminal) ===
	b.WriteString(bottomBS.Render("┌"))
	b.WriteString(bottomBorderTitle)
	b.WriteString(bottomBS.Render("┐"))
	b.WriteString("\n")
	for i := 0; i < bottomH; i++ {
		var content string
		if i < len(bottomLines) {
			if m.terminalMode && cfg.hasSpecPanel {
				content = " " + bottomLines[i] // 1-char left buffer; right buffer from padding
			} else {
				content = "  " + bottomLines[i]
			}
		} else {
			content = "  "
		}
		b.WriteString(bottomBorderChar)
		b.WriteString(padLine(content))
		b.WriteString(bottomBorderChar)
		b.WriteString("\n")
	}
	b.WriteString(bottomBS.Render("└"))
	b.WriteString(bottomBS.Render(strings.Repeat("─", panelW)))
	b.WriteString(bottomBS.Render("┘"))
	b.WriteString("\n")

	b.WriteString(m.renderStatusBar(m.width))
	return b.String()
}

// followupListDims returns the width and height to pass to followupList based on layoutMode.
func followupListDims(m model) (int, int) {
	if m.layoutMode == config.LayoutTopBottom {
		return m.topPanelWidth(), m.listPanelHeight()
	}
	return leftPanelWidth, m.listPanelHeight()
}

// renderStatusBar renders a single-line context-sensitive keybinding hint bar.
func (m model) renderStatusBar(width int) string {
	dimS := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	keyS := lipgloss.NewStyle().Foreground(lipgloss.Color("7")).Bold(true)
	sepS := lipgloss.NewStyle().Foreground(lipgloss.Color("238"))

	sep := sepS.Render("  ·  ")
	hint := func(key, desc string) string {
		return keyS.Render(key) + " " + dimS.Render(desc)
	}

	var hints []string
	// Modal overlays steal hint context from the underlying state. The
	// settings configurator renders its hints here (below the modal box,
	// same slot as the work/follow-up views) instead of inlining them in
	// the modal body.
	if m.settingsActive && m.settingsPanel != nil {
		hints = []string{
			hint("j/k", "navigate"),
			hint("Enter/Space", "commit"),
			hint("u", "unset"),
			hint("PgUp/PgDn", "scroll"),
			hint("Esc", "close"),
		}
		bar := "  " + strings.Join(hints, sep)
		barW := lipgloss.Width(bar)
		if barW < width {
			bar += strings.Repeat(" ", width-barW)
		}
		return dimS.Render(bar)
	}
	switch m.state {
	case stateOnboarding:
		if m.initLoading {
			hints = []string{dimS.Render("Initializing...")}
		} else {
			hints = []string{
				hint("Enter", "initialize"),
				hint("q", "quit"),
			}
		}
	case stateWork:
		if m.focusedPanel == panelLeft {
			hints = []string{
				hint("j/k", "navigate"),
				hint("Enter", "open"),
				hint("s", "spec"),
				hint("c", "chat"),
				hint("K", "knowledge"),
				hint("S", "settings"),
				hint("q", "quit"),
				hint("?", "help"),
			}
		} else if m.terminalMode {
			// terminal mode: keys go to PTY
			hints = []string{
				hint("ctrl+t", "detail"),
				hint("Esc", "back to list"),
				hint("Ctrl+c", "terminate"),
			}
		} else {
			// panelRight — detail view (content tabs)
			hints = []string{
				hint("s", "spec"),
				hint("c", "chat"),
				hint("Tab/Shift-Tab", "cycle tabs"),
				hint("j/k", "scroll"),
				hint("h/Esc", "back to list"),
				hint("?", "help"),
			}
		}
	case stateKnowledge:
		hints = []string{
			hint("j/k", "navigate"),
			hint("l/Enter", "detail"),
			hint("h/Esc", "tree"),
			hint("/", "search"),
			hint("Esc", "exit"),
			hint("?", "help"),
		}
	case stateSettlement:
		if m.focusedPanel == panelRight {
			hints = []string{
				hint("j/k", "settings"),
				hint("Enter", "edit/commit"),
				hint("h", "status"),
				hint("S", "all settings"),
				hint("?", "help"),
			}
		} else {
			toggleLabel := "enable"
			if m.settlement.Status().Enabled {
				toggleLabel = "disable"
			}
			hints = []string{
				hint("p", "process once"),
				hint("e", toggleLabel),
				hint("l", "settings"),
				hint("w", "work"),
				hint("f", "follow-ups"),
				hint("?", "help"),
			}
		}
	case stateFollowUps:
		if m.focusedPanel == panelLeft {
			hints = []string{
				hint("j/k", "navigate"),
				hint("Enter", "detail"),
				hint("A", "dismiss"),
				hint("D", "delete"),
				hint("w", "work list"),
				hint("Esc", "exit"),
				hint("?", "help"),
			}
		} else if m.terminalMode {
			hints = []string{
				hint("ctrl+t", "detail"),
				hint("Esc", "back to list"),
				hint("Ctrl+c", "terminate"),
			}
		} else if m.followupDetail.ActiveTab() == followup.TabTriage && m.followupDetail.ActionMenuOpen() {
			hints = []string{
				hint("c", "chat"),
				hint("d", "disposition"),
				hint("e", "edit"),
				hint("Esc", "cancel"),
			}
		} else if m.followupDetail.ActiveTab() == followup.TabTriage {
			hints = []string{
				hint("j/k", "navigate"),
				hint("space/x", "toggle"),
				hint("a", "all"),
				hint("Enter", "actions"),
				hint("p", "promote"),
				hint("Tab/Shift-Tab", "cycle tabs"),
				hint("h/Esc", "back to list"),
				hint("?", "help"),
			}
		} else if m.followupDetail.ActiveTab() == followup.TabComments {
			hints = []string{
				hint("a", "all"),
				hint("y", "copy"),
				hint("E", "editor"),
				hint("P", "post"),
				hint("g", "summarize"),
				hint("Tab/Shift-Tab", "cycle tabs"),
				hint("h/Esc", "back to list"),
				hint("?", "help"),
			}
		} else {
			hints = []string{
				hint("Tab/Shift-Tab", "cycle tabs"),
				hint("p", "promote"),
				hint("d", "dismiss"),
				hint("c", "chat"),
				hint("j/k", "scroll"),
				hint("h/Esc", "back to list"),
				hint("?", "help"),
			}
		}
	}

	if m.flashErr != "" {
		errS := lipgloss.NewStyle().Foreground(lipgloss.Color("1")).Bold(true)
		bar := "  " + errS.Render(m.flashErr)
		barW := lipgloss.Width(bar)
		if barW < width {
			bar += strings.Repeat(" ", width-barW)
		}
		return bar
	}

	if m.aiLoading {
		aiS := lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
		bar := "  " + aiS.Render("Creating work items...")
		barW := lipgloss.Width(bar)
		if barW < width {
			bar += strings.Repeat(" ", width-barW)
		}
		return bar
	}

	bar := "  " + strings.Join(hints, sep)
	barW := lipgloss.Width(bar)
	if barW < width {
		bar += strings.Repeat(" ", width-barW)
	}
	return dimS.Render(bar)
}
