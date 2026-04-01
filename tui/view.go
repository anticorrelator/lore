package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/work"
)

func (m model) View() string {
	if m.err != nil {
		return fmt.Sprintf("Error: %v\n\nPress q to quit.\n", m.err)
	}

	var base string
	switch m.state {
	case stateWork:
		if m.layoutMode == config.LayoutTopBottom {
			base = m.viewSplitPaneTopBottom()
		} else {
			base = m.viewSplitPane()
		}
	case stateKnowledge:
		return m.browser.View()
	case stateFollowUps:
		base = m.viewFollowUps()
	default:
		return ""
	}

	if m.popupActive {
		return lipgloss.Place(m.width, m.height-1, lipgloss.Center, lipgloss.Center, m.popup.View())
	}
	if m.specConfirmActive {
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
	return base
}

// viewSplitPane renders the split-pane work view with lazygit-style box borders.
func (m model) viewSplitPane() string {
	contentH := m.innerHeight() - 1 // 1 line reserved for tab indicator
	leftInner := leftPanelWidth
	rightInner := m.rightPanelWidth()

	// Check whether the current item has an active spec panel.
	currentSpec, hasCurrentSpec := m.currentSpecPanel()

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

	// Title styles: blue+bold when focused, default-color (full-visibility) when not
	leftTitleFg := lipgloss.Color("7") // default bright — always visible
	if m.focusedPanel == panelLeft {
		leftTitleFg = activeBorderColor
	}
	rightTitleFg := lipgloss.Color("7")
	if m.focusedPanel == panelRight {
		rightTitleFg = activeBorderColor
	}
	leftTitleS := lipgloss.NewStyle().Foreground(leftTitleFg).Bold(m.focusedPanel == panelLeft)
	rightTitleS := lipgloss.NewStyle().Foreground(rightTitleFg).Bold(m.focusedPanel == panelRight)

	// Build panel titles (label reflects active/archived filter mode)
	modeLabel := "Active"
	if m.list.GetFilterMode() == work.FilterArchived {
		modeLabel = "Archived"
	}
	leftTitle := modeLabel
	if items := m.list.Items(); len(items) > 0 {
		leftTitle = fmt.Sprintf("%s (%d)", modeLabel, len(items))
	}
	rightTitle := "Detail"
	if d := m.detail.Detail(); d != nil {
		t := d.Title
		maxW := rightInner - 6
		if lipgloss.Width(t) > maxW && maxW > 3 {
			runes := []rune(t)
			t = string(runes[:maxW-1]) + "…"
		}
		rightTitle = t
	} else if slug := m.list.CurrentSlug(); slug != "" {
		rightTitle = slug
	}

	// Tab indicator for list panel: active · archived, highlight current mode.
	listTabActiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("252"))
	listTabInactiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("238"))
	listTabSepS := lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
	var listActiveTabS, listArchivedTabS lipgloss.Style
	if m.list.GetFilterMode() == work.FilterArchived {
		listActiveTabS, listArchivedTabS = listTabInactiveS, listTabActiveS
	} else {
		listActiveTabS, listArchivedTabS = listTabActiveS, listTabInactiveS
	}
	leftAnnot := listTabSepS.Render("ctrl+a  ") + listActiveTabS.Render("active") + listTabSepS.Render(" · ") + listArchivedTabS.Render("archived")
	leftAnnotW := 8 + 6 + 3 + 8 // "ctrl+a  " + "active" + " · " + "archived"

	// Right panel annotation: show "ctrl+t  detail · terminal" mode indicator when a spec session exists.
	var rightBorderTitle string
	if hasCurrentSpec {
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
		if currentSpec.IsDone() {
			termLabel = "terminal (done)"
			termLabelW = 15
		}
		modeAnnot := sepS.Render("ctrl+t  ") + detailS.Render("detail") + sepS.Render(" · ") + terminalS.Render(termLabel)
		modeAnnotW := 8 + 6 + 3 + termLabelW // "ctrl+t  " + "detail" + " · " + termLabel
		rightBorderTitle = renderBorderTitleWithAnnot(rightTitle, rightInner, rightTitleS, rightBS, modeAnnot, modeAnnotW)
	} else {
		rightBorderTitle = renderBorderTitle(rightTitle, rightInner, rightTitleS, rightBS)
	}

	// Top border: ┌─ Title ──── active · archived ─┐┌─ Title ──── ctrl+t  detail · terminal ─┐
	topRow := leftBS.Render("┌") +
		renderBorderTitleWithAnnot(leftTitle, leftInner, leftTitleS, leftBS, leftAnnot, leftAnnotW) +
		leftBS.Render("┐") +
		rightBS.Render("┌") +
		rightBorderTitle +
		rightBS.Render("┐")

	// Bottom border: └──────────────────────┘└──────────────────────────────────────┘
	bottomRow := leftBS.Render("└") +
		leftBS.Render(strings.Repeat("─", leftInner)) +
		leftBS.Render("┘") +
		rightBS.Render("└") +
		rightBS.Render(strings.Repeat("─", rightInner)) +
		rightBS.Render("┘")

	leftView := m.list.View()
	leftLines := strings.Split(leftView, "\n")

	// Right panel content: terminal mode shows spec panel, otherwise detail view.
	var rightLines []string
	if m.terminalMode && hasCurrentSpec {
		specView := currentSpec.View()
		rightLines = strings.Split(specView, "\n")
	} else {
		rightView := m.detail.View()
		rightLines = strings.Split(rightView, "\n")
	}

	leftBorderChar := leftBS.Render("│")
	rightBorderChar := rightBS.Render("│")

	var b strings.Builder
	b.WriteString(renderTabIndicator(m.state, len(m.list.Items()), m.followupList.FollowUpCount(), m.width))
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
			if m.terminalMode && hasCurrentSpec {
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

// viewSplitPaneTopBottom renders the stacked top/bottom layout: list on top, detail on bottom.
func (m model) viewSplitPaneTopBottom() string {
	if m.width <= 0 || m.height <= 0 {
		return ""
	}
	topH := m.topPanelHeight() - 1 // 1 line reserved for tab indicator
	bottomH := m.detailPanelHeight()
	panelW := m.topPanelWidth()

	// Check whether the current item has an active spec panel.
	currentSpecTB, hasCurrentSpecTB := m.currentSpecPanel()

	// Focus-aware border colors
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

	// Title styles: blue+bold when focused, default-color (full-visibility) when not
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

	// Build panel titles
	modeLabel := "Active"
	if m.list.GetFilterMode() == work.FilterArchived {
		modeLabel = "Archived"
	}
	topTitle := modeLabel
	if items := m.list.Items(); len(items) > 0 {
		topTitle = fmt.Sprintf("%s (%d)", modeLabel, len(items))
	}
	bottomTitle := "Detail"
	if d := m.detail.Detail(); d != nil {
		t := d.Title
		maxW := panelW - 6
		if lipgloss.Width(t) > maxW && maxW > 3 {
			runes := []rune(t)
			t = string(runes[:maxW-1]) + "…"
		}
		bottomTitle = t
	} else if slug := m.list.CurrentSlug(); slug != "" {
		bottomTitle = slug
	}

	topBorderChar := topBS.Render("│")
	bottomBorderChar := bottomBS.Render("│")

	topView := m.list.View()
	topLines := strings.Split(topView, "\n")

	// Bottom panel content: terminal mode shows spec panel, otherwise detail view.
	var bottomLines []string
	if m.terminalMode && hasCurrentSpecTB {
		specView := currentSpecTB.View()
		bottomLines = strings.Split(specView, "\n")
	} else {
		bottomView := m.detail.View()
		bottomLines = strings.Split(bottomView, "\n")
	}

	// padLine pads or truncates a content line to exactly panelW visual width.
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

	var b strings.Builder
	b.WriteString(renderTabIndicator(m.state, len(m.list.Items()), m.followupList.FollowUpCount(), m.width))
	b.WriteString("\n")

	// Tab indicator for top (list) panel: active · archived, highlight current mode.
	tbActiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("252"))
	tbInactiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("238"))
	tbSepS := lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
	var tbActiveTabS, tbArchivedTabS lipgloss.Style
	if m.list.GetFilterMode() == work.FilterArchived {
		tbActiveTabS, tbArchivedTabS = tbInactiveS, tbActiveS
	} else {
		tbActiveTabS, tbArchivedTabS = tbActiveS, tbInactiveS
	}
	topAnnot := tbSepS.Render("ctrl+a  ") + tbActiveTabS.Render("active") + tbSepS.Render(" · ") + tbArchivedTabS.Render("archived")
	topAnnotW := 8 + 6 + 3 + 8 // "ctrl+a  " + "active" + " · " + "archived"

	// === Top panel (list) ===
	b.WriteString(topBS.Render("┌"))
	b.WriteString(renderBorderTitleWithAnnot(topTitle, panelW, topTitleS, topBS, topAnnot, topAnnotW))
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
	// Bottom panel annotation: show "detail · terminal" mode indicator when a spec session exists.
	var bottomBorderTitle string
	if hasCurrentSpecTB {
		btActiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("252"))
		btInactiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("238"))
		btSepS := lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
		var btDetailS, btTerminalS lipgloss.Style
		if m.terminalMode {
			btDetailS, btTerminalS = btInactiveS, btActiveS
		} else {
			btDetailS, btTerminalS = btActiveS, btInactiveS
		}
		btTermLabel := "terminal"
		btTermLabelW := 8
		if currentSpecTB.IsDone() {
			btTermLabel = "terminal (done)"
			btTermLabelW = 15
		}
		btModeAnnot := btSepS.Render("ctrl+t  ") + btDetailS.Render("detail") + btSepS.Render(" · ") + btTerminalS.Render(btTermLabel)
		btModeAnnotW := 8 + 6 + 3 + btTermLabelW // "ctrl+t  " + "detail" + " · " + btTermLabel
		bottomBorderTitle = renderBorderTitleWithAnnot(bottomTitle, panelW, bottomTitleS, bottomBS, btModeAnnot, btModeAnnotW)
	} else {
		bottomBorderTitle = renderBorderTitle(bottomTitle, panelW, bottomTitleS, bottomBS)
	}
	b.WriteString(bottomBS.Render("┌"))
	b.WriteString(bottomBorderTitle)
	b.WriteString(bottomBS.Render("┐"))
	b.WriteString("\n")
	for i := 0; i < bottomH; i++ {
		var content string
		if i < len(bottomLines) {
			if m.terminalMode && hasCurrentSpecTB {
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
func renderTabIndicator(activeTab appState, workCount, followupCount, width int) string {
	activeS := lipgloss.NewStyle().Foreground(lipgloss.Color("252")).Bold(true)
	inactiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("238"))
	sepS := lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
	hintS := lipgloss.NewStyle().Foreground(lipgloss.Color("240"))

	var workS, followupS lipgloss.Style
	var hint string
	if activeTab == stateFollowUps {
		workS, followupS = inactiveS, activeS
		hint = "w  "
	} else {
		workS, followupS = activeS, inactiveS
		hint = "f  "
	}

	workLabel := fmt.Sprintf("work (%d)", workCount)
	followupLabel := fmt.Sprintf("follow-ups (%d)", followupCount)
	sep := sepS.Render(" · ")

	line := "  " + hintS.Render(hint) + workS.Render(workLabel) + sep + followupS.Render(followupLabel)
	lineW := 2 + 3 + len(workLabel) + 3 + len(followupLabel)
	if lineW < width {
		line += strings.Repeat(" ", width-lineW)
	}
	return line
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

func (m model) viewFollowUps() string {
	if m.layoutMode == config.LayoutTopBottom {
		return m.viewFollowUpsTopBottom()
	}
	return m.viewFollowUpsSideBySide()
}

// viewFollowUpsSideBySide renders the stateFollowUps split pane: follow-up list on the left,
// detail pane on the right, using the same compositor pattern as viewSplitPane.
func (m model) viewFollowUpsSideBySide() string {
	contentH := m.innerHeight() - 1 // 1 line reserved for tab indicator
	leftInner := leftPanelWidth
	rightInner := m.rightPanelWidth()

	activeBorderColor := lipgloss.Color("4")
	inactiveBorderColor := lipgloss.Color("238")

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

	leftTitle := "Follow-ups"
	if items := m.followupList.Items(); len(items) > 0 {
		leftTitle = fmt.Sprintf("Follow-ups (%d)", len(items))
	}
	rightTitle := "Detail"
	if t := m.followupDetail.Title(); t != "" {
		maxW := rightInner - 6
		if lipgloss.Width(t) > maxW && maxW > 3 {
			runes := []rune(t)
			t = string(runes[:maxW-1]) + "…"
		}
		rightTitle = t
	}

	// Filter annotation: ctrl+a  active · archived, highlight current
	fuTabActiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("252"))
	fuTabInactiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("238"))
	fuTabSepS := lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
	fuFilter := m.followupList.GetFilterLabel()
	fuActiveS := fuTabInactiveS
	if fuFilter == "active" {
		fuActiveS = fuTabActiveS
	}
	fuArchivedS := fuTabInactiveS
	if fuFilter == "archived" {
		fuArchivedS = fuTabActiveS
	}
	filterAnnot := fuTabSepS.Render("ctrl+a  ") + fuActiveS.Render("active") + fuTabSepS.Render(" · ") + fuArchivedS.Render("archived")
	filterAnnotW := 8 + 6 + 3 + 8 // "ctrl+a  " + "active" + " · " + "archived"

	// Right panel annotation: show "ctrl+t  detail · terminal" mode indicator when a spec session exists.
	currentFUSpec, hasCurrentFUSpec := m.currentFollowupPanel()
	var rightBorderTitle string
	if hasCurrentFUSpec {
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
		if currentFUSpec.IsDone() {
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
		renderBorderTitleWithAnnot(leftTitle, leftInner, leftTitleS, leftBS, filterAnnot, filterAnnotW) +
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

	leftLines := strings.Split(m.followupList.View(), "\n")

	// Right panel content: terminal mode shows spec panel, otherwise detail view.
	var rightLines []string
	if m.terminalMode && hasCurrentFUSpec {
		rightLines = strings.Split(currentFUSpec.View(), "\n")
	} else {
		rightLines = strings.Split(m.followupDetail.View(), "\n")
	}

	leftBorderChar := leftBS.Render("│")
	rightBorderChar := rightBS.Render("│")

	var b strings.Builder
	b.WriteString(renderTabIndicator(stateFollowUps, len(m.list.Items()), m.followupList.FollowUpCount(), m.width))
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
			if m.terminalMode && hasCurrentFUSpec {
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

// followupListDims returns the width and height to pass to followupList based on layoutMode.
func followupListDims(m model) (int, int) {
	if m.layoutMode == config.LayoutTopBottom {
		return m.topPanelWidth(), m.topPanelHeight()
	}
	return leftPanelWidth, m.innerHeight()
}

// viewFollowUpsTopBottom renders the stateFollowUps stacked layout: list on top, detail on bottom.
func (m model) viewFollowUpsTopBottom() string {
	if m.width <= 0 || m.height <= 0 {
		return ""
	}
	topH := m.topPanelHeight() - 1 // 1 line reserved for tab indicator
	bottomH := m.detailPanelHeight()
	panelW := m.topPanelWidth()

	activeBorderColor := lipgloss.Color("4")
	inactiveBorderColor := lipgloss.Color("238")

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

	topTitle := "Follow-ups"
	if items := m.followupList.Items(); len(items) > 0 {
		topTitle = fmt.Sprintf("Follow-ups (%d)", len(items))
	}
	bottomTitle := "Detail"
	if t := m.followupDetail.Title(); t != "" {
		maxW := panelW - 6
		if lipgloss.Width(t) > maxW && maxW > 3 {
			runes := []rune(t)
			t = string(runes[:maxW-1]) + "…"
		}
		bottomTitle = t
	}

	// Filter annotation for top panel: ctrl+a  active · archived, highlight current
	fuTabActiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("252"))
	fuTabInactiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("238"))
	fuTabSepS := lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
	fuFilter := m.followupList.GetFilterLabel()
	fuActiveS := fuTabInactiveS
	if fuFilter == "active" {
		fuActiveS = fuTabActiveS
	}
	fuArchivedS := fuTabInactiveS
	if fuFilter == "archived" {
		fuArchivedS = fuTabActiveS
	}
	filterAnnot := fuTabSepS.Render("ctrl+a  ") + fuActiveS.Render("active") + fuTabSepS.Render(" · ") + fuArchivedS.Render("archived")
	filterAnnotW := 8 + 6 + 3 + 8 // "ctrl+a  " + "active" + " · " + "archived"

	// Bottom panel annotation: show "ctrl+t  detail · terminal" when a spec session exists.
	currentFUSpecTB, hasCurrentFUSpecTB := m.currentFollowupPanel()
	var bottomBorderTitle string
	if hasCurrentFUSpecTB {
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
		if currentFUSpecTB.IsDone() {
			termLabel = "terminal (done)"
			termLabelW = 15
		}
		modeAnnot := sepS.Render("ctrl+t  ") + detailS.Render("detail") + sepS.Render(" · ") + terminalS.Render(termLabel)
		modeAnnotW := 8 + 6 + 3 + termLabelW // "ctrl+t  " + "detail" + " · " + termLabel
		bottomBorderTitle = renderBorderTitleWithAnnot(bottomTitle, panelW, bottomTitleS, bottomBS, modeAnnot, modeAnnotW)
	} else {
		bottomBorderTitle = renderBorderTitle(bottomTitle, panelW, bottomTitleS, bottomBS)
	}

	topBorderChar := topBS.Render("│")
	bottomBorderChar := bottomBS.Render("│")

	topLines := strings.Split(m.followupList.View(), "\n")

	// Bottom panel content: terminal mode shows spec panel, otherwise detail view.
	var bottomLines []string
	if m.terminalMode && hasCurrentFUSpecTB {
		bottomLines = strings.Split(currentFUSpecTB.View(), "\n")
	} else {
		bottomLines = strings.Split(m.followupDetail.View(), "\n")
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

	var b strings.Builder
	b.WriteString(renderTabIndicator(stateFollowUps, len(m.list.Items()), m.followupList.FollowUpCount(), m.width))
	b.WriteString("\n")

	// === Top panel (list) ===
	b.WriteString(topBS.Render("┌"))
	b.WriteString(renderBorderTitleWithAnnot(topTitle, panelW, topTitleS, topBS, filterAnnot, filterAnnotW))
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
			if m.terminalMode && hasCurrentFUSpecTB {
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
	switch m.state {
	case stateWork:
		if m.focusedPanel == panelLeft {
			hints = []string{
				hint("j/k", "navigate"),
				hint("Enter", "open"),
				hint("s", "spec"),
				hint("c", "chat"),
				hint("N", "AI add"),
				hint("L", "layout"),
				hint("K", "knowledge"),
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
	case stateFollowUps:
		if m.focusedPanel == panelLeft {
			hints = []string{
				hint("j/k", "navigate"),
				hint("ctrl+a", "active/archived"),
				hint("Enter", "detail"),
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
		} else {
			hints = []string{
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
