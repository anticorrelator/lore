package main

import (
	"fmt"
	"path/filepath"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/settlement"
	"github.com/anticorrelator/lore/tui/internal/style"
)

// Chrome styles for the hand-drawn panel compositor, constructed once at
// package init (render paths must not allocate styles per frame). The docked
// panels draw the shared style.DockBorder runes inline so titles and key
// annotations can live in the top border; the focus colors are lifted from
// style.BorderFocused / style.BorderBlur so the hand-drawn path cannot drift
// from the lipgloss-rendered modal boxes.
var (
	borderFocusedS = lipgloss.NewStyle().Foreground(style.BorderFocused.GetBorderTopForeground())
	borderBlurS    = lipgloss.NewStyle().Foreground(style.BorderBlur.GetBorderTopForeground())

	// Tab-indicator parts: the active section pops, inactive sections and
	// separators recede, and each switch key reads one tier above its label.
	tabActiveS   = lipgloss.NewStyle().Foreground(style.ColorTextBright).Bold(true)
	tabInactiveS = lipgloss.NewStyle().Foreground(style.ColorChrome)
	tabKeyS      = lipgloss.NewStyle().Foreground(style.ColorDim)
	tabSepS      = lipgloss.NewStyle().Foreground(style.ColorChrome)

	// annotDimS is the receding part (keys, separators, unselected states) of
	// a border annotation; the selected state renders with style.TitleFilter.
	annotDimS = lipgloss.NewStyle().Foreground(style.ColorChrome)

	// doctorWarnS renders the doctor drift banner: ColorWarn (amber), distinct
	// from flashErr's red. Drift is a "you should look at this" signal, not an
	// "action failed" signal.
	doctorWarnS = lipgloss.NewStyle().Foreground(style.ColorWarn).Bold(true)
)

// View is the single wrapping point where terminal modes (alt screen, mouse)
// and keyboard enhancements are applied to the rendered frame. Keep mode flags
// here — scattering tea.NewView wrappers across call sites risks silently
// dropping one.
//
// KeyboardEnhancements is left at its zero value on purpose: bubbletea v2
// always requests basic Kitty key disambiguation (the renderer ORs in flag 1
// unconditionally), which is what delivers Shift+Enter and other modified
// keys to the modals. The struct fields only add key release/repeat and
// alternate-key reporting, which this app does not use.
func (m model) View() tea.View {
	v := tea.NewView(m.viewContent())
	v.AltScreen = true
	v.MouseMode = tea.MouseModeCellMotion
	return v
}

func (m model) viewContent() string {
	if m.err != nil {
		return fmt.Sprintf("Error: %v\n\nPress q to quit.\n", m.err)
	}

	if m.state == stateNoRepo {
		return m.viewNoRepo()
	}

	if m.state == stateOnboarding {
		return m.viewOnboarding()
	}

	// stateKnowledge composes into base (not an early return) so modal
	// overlays opened from the browser — help (?), settings (S) — actually
	// render; an early return here left those modals intercepting keys while
	// invisible.
	var base string
	if m.state == stateKnowledge {
		base = m.browser.View()
	} else if m.state == stateSettlement {
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
	if m.assignActive {
		return m.renderAssignModal()
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
	titleS := style.SectionTitle
	dimS := style.Dim

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
	titleS := style.SectionTitle
	dimS := style.Dim

	dirName := filepath.Base(m.config.ProjectDir)
	title := titleS.Render(dirName)
	line1 := dimS.Render("Not inside a git repository")
	line2 := dimS.Render("Navigate to a git repo and relaunch")
	quit := dimS.Render("Press q to quit")

	content := title + "\n\n" + line1 + "\n" + line2 + "\n\n" + quit
	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, content)
}

// renderTabIndicator renders a full-width section row showing
// "work (N) · follow-ups (N) · settlement (N)". The active section is
// highlighted; every other section is prefixed with the key that switches to
// it (w / f / t). The keys are routed in update.go and mirrored in the status
// bar and help modal — do not display a key here without all three.
func renderTabIndicator(activeTab appState, workCount, followupCount, settlementCount, width int) string {
	section := func(key, label string, count int, active bool) string {
		text := fmt.Sprintf("%s (%d)", label, count)
		if active {
			return tabActiveS.Render(text)
		}
		return tabKeyS.Render(key+" ") + tabInactiveS.Render(text)
	}
	sep := tabSepS.Render(" · ")

	line := "  " +
		section("w", "work", workCount, activeTab != stateFollowUps && activeTab != stateSettlement) + sep +
		section("f", "follow-ups", followupCount, activeTab == stateFollowUps) + sep +
		section("t", "settlement", settlementCount, activeTab == stateSettlement)
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
	borderS := borderFocusedS
	bodyW := innerW - 1 // outer row renderer adds one leading space
	if bodyW < 1 {
		bodyW = 1
	}
	lines := m.renderSettlementBodyLines(bodyW, contentH)

	var b strings.Builder
	b.WriteString(renderTabIndicator(stateSettlement, len(m.list.Items()), m.followupList.FollowUpCount(), m.settlement.Count(), w))
	b.WriteString("\n")
	// Border annotation: advertise what j/k currently walks — the queue at
	// the root, claims or verdicts inside a drill-in.
	annotSel := 0
	switch m.settlement.Drill() {
	case settlement.DrillClaim:
		annotSel = 1
	case settlement.DrillVerdict:
		annotSel = 2
	}
	annot, annotW := annotSettlementFocus.renderSelected(annotSel)
	b.WriteString(borderS.Render(style.DockBorder.TopLeft))
	b.WriteString(renderBorderTitleWithAnnot(style.TitleName.Render("Settlement"), innerW, borderS, annot, annotW))
	b.WriteString(borderS.Render(style.DockBorder.TopRight))
	b.WriteString("\n")
	for i := 0; i < contentH; i++ {
		line := ""
		if i < len(lines) {
			line = " " + lines[i]
		}
		lineW := lipgloss.Width(line)
		if lineW > innerW {
			line = style.Truncate(line, innerW)
		} else if lineW < innerW {
			line += strings.Repeat(" ", innerW-lineW)
		}
		b.WriteString(borderS.Render(style.DockBorder.Left))
		b.WriteString(line)
		b.WriteString(borderS.Render(style.DockBorder.Right))
		b.WriteString("\n")
	}
	b.WriteString(borderS.Render(style.DockBorder.BottomLeft))
	b.WriteString(borderS.Render(strings.Repeat(style.DockBorder.Bottom, innerW)))
	b.WriteString(borderS.Render(style.DockBorder.BottomRight))
	b.WriteString("\n")
	b.WriteString(m.renderStatusBar(w))
	return b.String()
}

// renderSettlementBodyLines renders the settlement sub-model at the full
// panel height, padding short content with blank rows so the outer panel
// stays full-height. The sub-model self-budgets its regions and scrolls
// overflow; the host clips blindly at height.
func (m model) renderSettlementBodyLines(width, height int) []string {
	if height <= 0 {
		return nil
	}
	statusLines := strings.Split(m.settlement.SetSize(width, height).View(), "\n")
	out := make([]string, 0, height)
	for i := 0; i < len(statusLines) && i < height; i++ {
		out = append(out, fitLine(statusLines[i], width))
	}
	for len(out) < height {
		out = append(out, strings.Repeat(" ", width))
	}
	return out
}

func fitLine(line string, width int) string {
	if width < 1 {
		return ""
	}
	lineW := lipgloss.Width(line)
	if lineW > width {
		return style.Truncate(line, width)
	}
	if lineW < width {
		return line + strings.Repeat(" ", width-lineW)
	}
	return line
}

// renderBorderTitle renders "─ Title ──────────" filling exactly width chars.
// title is pre-rendered (may contain ANSI codes).
func renderBorderTitle(title string, width int, borderS lipgloss.Style) string {
	prefix := borderS.Render(style.DockBorder.Top + " ")
	usedW := 2 + lipgloss.Width(title) // "─ " + title
	remaining := width - usedW
	if remaining < 0 {
		remaining = 0
	}
	return prefix + title + borderS.Render(strings.Repeat(style.DockBorder.Top, remaining))
}

// renderBorderTitleWithAnnot renders "─ Title ─── annot ─" filling exactly width chars.
// title and annot are pre-rendered strings (may contain ANSI codes); annotW is
// the annotation's visual width.
func renderBorderTitleWithAnnot(title string, width int, borderS lipgloss.Style, annot string, annotW int) string {
	prefix := borderS.Render(style.DockBorder.Top + " ")
	usedLeft := 2 + lipgloss.Width(title) // "─ " + title
	// Right side: " " + annot + " ─" = annotW + 3 visual chars
	rightSlot := annotW + 3
	middle := width - usedLeft - rightSlot
	if middle < 1 {
		middle = 1
	}
	return prefix + title + borderS.Render(strings.Repeat(style.DockBorder.Top, middle)) + borderS.Render(" ") + annot + borderS.Render(" "+style.DockBorder.Top)
}

// viewSideBySide renders a side-by-side split pane using the entity-neutral paneConfig.
// It replaces viewSplitPane (stateWork) and viewFollowUpsSideBySide (stateFollowUps).
func (m model) viewSideBySide(cfg paneConfig) string {
	contentH := m.innerHeight() - 1 // 1 line reserved for tab indicator
	leftInner := leftPanelWidth
	rightInner := m.rightPanelWidth()

	leftBS := borderBlurS
	rightBS := borderBlurS
	if m.focusedPanel == panelLeft {
		leftBS = borderFocusedS
	}
	if m.focusedPanel == panelRight {
		rightBS = borderFocusedS
	}

	// Truncate detail title to fit the right panel. Focus is signaled by the
	// border color alone, so the title renders with TitleName either way.
	rightTitle := cfg.detailTitle
	maxTitleW := rightInner - 6
	if maxTitleW > 3 {
		rightTitle = style.Truncate(rightTitle, maxTitleW)
	}
	rightTitleRendered := style.TitleName.Render(rightTitle)

	// Right panel annotation: show "ctrl+t  detail · terminal" when a spec session exists.
	var rightBorderTitle string
	if cfg.hasSpecPanel {
		modeSel := 0
		if m.terminalMode {
			modeSel = 1
		}
		modeAnnot, modeAnnotW := annotPanelMode(cfg.specPanel.IsDone()).render(modeSel)
		rightBorderTitle = renderBorderTitleWithAnnot(rightTitleRendered, rightInner, rightBS, modeAnnot, modeAnnotW)
	} else {
		rightBorderTitle = renderBorderTitle(rightTitleRendered, rightInner, rightBS)
	}

	topRow := leftBS.Render(style.DockBorder.TopLeft) +
		renderBorderTitleWithAnnot(cfg.listTitle, leftInner, leftBS, cfg.filterAnnot, cfg.filterAnnotW) +
		leftBS.Render(style.DockBorder.TopRight) +
		rightBS.Render(style.DockBorder.TopLeft) +
		rightBorderTitle +
		rightBS.Render(style.DockBorder.TopRight)

	bottomRow := leftBS.Render(style.DockBorder.BottomLeft) +
		leftBS.Render(strings.Repeat(style.DockBorder.Bottom, leftInner)) +
		leftBS.Render(style.DockBorder.BottomRight) +
		rightBS.Render(style.DockBorder.BottomLeft) +
		rightBS.Render(strings.Repeat(style.DockBorder.Bottom, rightInner)) +
		rightBS.Render(style.DockBorder.BottomRight)

	leftLines := strings.Split(cfg.listView, "\n")

	// Right panel content: terminal mode shows spec panel, otherwise detail view.
	var rightLines []string
	if m.terminalMode && cfg.hasSpecPanel {
		rightLines = strings.Split(cfg.specPanel.View(), "\n")
	} else {
		rightLines = strings.Split(cfg.detailView, "\n")
	}

	leftBorderChar := leftBS.Render(style.DockBorder.Left)
	rightBorderChar := rightBS.Render(style.DockBorder.Right)

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
			left = style.Truncate(left, leftInner)
		} else if lW < leftInner {
			left += strings.Repeat(" ", leftInner-lW)
		}
		rW := lipgloss.Width(right)
		if rW > rightInner {
			right = style.Truncate(right, rightInner)
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

	topBS := borderBlurS
	bottomBS := borderBlurS
	if m.focusedPanel == panelLeft {
		topBS = borderFocusedS
	}
	if m.focusedPanel == panelRight {
		bottomBS = borderFocusedS
	}

	// Truncate detail title to fit the bottom panel. Focus is signaled by the
	// border color alone, so the title renders with TitleName either way.
	bottomTitle := cfg.detailTitle
	maxTitleW := panelW - 6
	if maxTitleW > 3 {
		bottomTitle = style.Truncate(bottomTitle, maxTitleW)
	}
	bottomTitleRendered := style.TitleName.Render(bottomTitle)

	topBorderChar := topBS.Render(style.DockBorder.Left)
	bottomBorderChar := bottomBS.Render(style.DockBorder.Left)

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
			return style.Truncate(line, panelW)
		}
		if w < panelW {
			return line + strings.Repeat(" ", panelW-w)
		}
		return line
	}

	// Bottom panel annotation: show "ctrl+t  detail · terminal" when a spec session exists.
	var bottomBorderTitle string
	if cfg.hasSpecPanel {
		modeSel := 0
		if m.terminalMode {
			modeSel = 1
		}
		modeAnnot, modeAnnotW := annotPanelMode(cfg.specPanel.IsDone()).render(modeSel)
		bottomBorderTitle = renderBorderTitleWithAnnot(bottomTitleRendered, panelW, bottomBS, modeAnnot, modeAnnotW)
	} else {
		bottomBorderTitle = renderBorderTitle(bottomTitleRendered, panelW, bottomBS)
	}

	var b strings.Builder
	b.WriteString(renderTabIndicator(cfg.state, cfg.listItemCount, cfg.fuItemCount, cfg.settlementCount, m.width))
	b.WriteString("\n")

	// === Top panel (list) ===
	b.WriteString(topBS.Render(style.DockBorder.TopLeft))
	b.WriteString(renderBorderTitleWithAnnot(cfg.listTitle, panelW, topBS, cfg.filterAnnot, cfg.filterAnnotW))
	b.WriteString(topBS.Render(style.DockBorder.TopRight))
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
	b.WriteString(topBS.Render(style.DockBorder.BottomLeft))
	b.WriteString(topBS.Render(strings.Repeat(style.DockBorder.Bottom, panelW)))
	b.WriteString(topBS.Render(style.DockBorder.BottomRight))
	b.WriteString("\n")

	// === Bottom panel (detail or terminal) ===
	b.WriteString(bottomBS.Render(style.DockBorder.TopLeft))
	b.WriteString(bottomBorderTitle)
	b.WriteString(bottomBS.Render(style.DockBorder.TopRight))
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
	b.WriteString(bottomBS.Render(style.DockBorder.BottomLeft))
	b.WriteString(bottomBS.Render(strings.Repeat(style.DockBorder.Bottom, panelW)))
	b.WriteString(bottomBS.Render(style.DockBorder.BottomRight))
	b.WriteString("\n")

	b.WriteString(m.renderStatusBar(m.width))
	return b.String()
}

// renderStatusBar renders a single-line context-sensitive keybinding hint
// bar. Hint sets come from the keymap registry (keymap.go); this function
// owns only the override ladder, whose precedence is
// flashErr > doctorBanner > aiLoading > hints.
func (m model) renderStatusBar(width int) string {
	dimS := style.Dim
	sep := style.Separator.Render("  ·  ")

	pad := func(bar string) string {
		if barW := lipgloss.Width(bar); barW < width {
			bar += strings.Repeat(" ", width-barW)
		}
		return bar
	}

	// Settings configurator pre-case: the modal's hints replace the
	// underlying state's and return before the override ladder (the modal
	// hides whatever the flash/banner would refer to).
	if m.settingsActive && m.settingsPanel != nil {
		hints := m.settingsPanel.StatusHints()
		rendered := make([]string, 0, len(hints)+1)
		// Outcome flash first (saved/unset/undid confirmations, reject and
		// write errors) — the hints describe what keys do next; the flash
		// says what just happened. Both share the one status line.
		if flash, isErr := m.settingsPanel.StatusFlash(); flash != "" {
			if isErr {
				rendered = append(rendered, style.SevBlocking.Render(flash))
			} else {
				rendered = append(rendered, style.SevSuggestion.Render(flash))
			}
		}
		for _, hint := range hints {
			if hint.Key == "" {
				rendered = append(rendered, dimS.Render(hint.Label))
				continue
			}
			rendered = append(rendered, style.KeyHint.Render(hint.Key)+" "+dimS.Render(hint.Label))
		}
		return dimS.Render(pad("  " + strings.Join(rendered, sep)))
	}

	if m.flashErr != "" {
		return pad("  " + style.SevBlocking.Render(m.flashErr))
	}

	if m.doctorBanner != "" {
		return pad("  " + doctorWarnS.Render(m.doctorBanner))
	}

	if m.aiLoading {
		return pad("  " + style.SevSuggestion.Render("Creating work items..."))
	}

	return dimS.Render(pad("  " + strings.Join(m.statusBarHints(m.keymapContext()), sep)))
}
