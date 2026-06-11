package main

import (
	"fmt"

	"charm.land/bubbles/v2/textarea"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/style"
)

// modalInnerW is the visible content width inside all modals.
const modalInnerW = 58

// modalStyles returns the shared style set used by all modals.
type modalStyleSet struct {
	border lipgloss.Style
	title  lipgloss.Style
	dim    lipgloss.Style
	key    lipgloss.Style
	sep    lipgloss.Style
}

// modalStyles is allocated once at package init; border is modal-local
// chrome, the rest alias the shared primitives.
var modalStyles = newModalStyles()

func newModalStyles() modalStyleSet {
	return modalStyleSet{
		border: lipgloss.NewStyle().Foreground(lipgloss.Color("4")),
		title:  style.SectionTitle,
		dim:    style.Dim,
		key:    style.KeyHint,
		sep:    style.Separator,
	}
}

// buildModalBox wraps title+body in a rounded blue border box at modalInnerW width.
func buildModalBox(s modalStyleSet, title, body string) string {
	return buildModalBoxWidth(s, title, body, modalInnerW)
}

// buildModalBoxWidth is the variable-width variant. The settings configurator
// uses this to span more of the terminal so long harness blocks don't wrap;
// other modals stick with the buildModalBox default at modalInnerW.
func buildModalBoxWidth(s modalStyleSet, title, body string, width int) string {
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(s.border.GetForeground()).
		Width(width).
		Render(s.title.Render(title) + "\n" + body)
}

// placeModal centers box over the full screen with a status bar at the bottom.
func (m model) placeModal(box string) string {
	return lipgloss.Place(m.width, m.height-1,
		lipgloss.Center, lipgloss.Center,
		box,
		lipgloss.WithWhitespaceChars(" "),
	) + "\n" + m.renderStatusBar(m.width)
}

func newModalTextarea() textarea.Model {
	ta := textarea.New()
	ta.Placeholder = ""
	ta.Prompt = " "
	ta.ShowLineNumbers = false
	ta.CharLimit = 0
	ta.SetWidth(54)
	ta.SetHeight(4)
	return ta
}

// renderSpecConfirmModal shows a centered confirmation modal before launching the spec subprocess.
// Displays the slug, an optional context input, and enter/esc hints.
func (m model) renderSpecConfirmModal() string {
	s := modalStyles

	inputBox := lipgloss.NewStyle().
		Border(lipgloss.NormalBorder()).
		BorderForeground(lipgloss.Color("238")).
		Width(modalInnerW - 2).
		Render(m.sessionConfirmInput.View())
	hints := s.key.Render("Enter") + " " + s.dim.Render("start") +
		s.sep.Render("  ·  ") +
		s.key.Render("Shift+Enter") + " " + s.dim.Render("newline") +
		s.sep.Render("  ·  ") +
		s.key.Render("Esc") + " " + s.dim.Render("cancel")

	var title, body string
	if m.sessionConfirmChatMode {
		title = "Chat about " + m.sessionConfirmSlug + "?"
		body = "\n" + s.dim.Render(" opening message (optional):") +
			"\n" + inputBox + "\n\n " + hints + "\n"
	} else {
		title = "Run /spec for " + m.sessionConfirmSlug + "?"
		shortCheck := "[ ]"
		if m.sessionConfirmShortMode {
			shortCheck = "[x]"
		}
		skipCheck := "[ ]"
		if m.sessionConfirmSkipConfirm {
			skipCheck = "[x]"
		}
		checkboxes := " " + s.key.Render(shortCheck) + " " + s.dim.Render("Short mode") +
			"  " + s.sep.Render("(") + s.key.Render("Alt+1") + s.sep.Render(")") +
			"\n " + s.key.Render(skipCheck) + " " + s.dim.Render("Skip confirmations") +
			"  " + s.sep.Render("(") + s.key.Render("Alt+2") + s.sep.Render(")")
		body = "\n" + checkboxes + "\n\n" +
			s.dim.Render(fmt.Sprintf(" additional context for %s (optional):", config.HarnessDisplayName(""))) +
			"\n" + inputBox + "\n\n " + hints + "\n"
	}
	return m.placeModal(buildModalBox(s, title, body))
}

// renderAIModal shows a centered modal for the AI work-item creation prompt.
func (m model) renderAIModal() string {
	s := modalStyles
	inputBox := lipgloss.NewStyle().
		Border(lipgloss.NormalBorder()).
		BorderForeground(lipgloss.Color("238")).
		Width(modalInnerW - 2).
		Render(m.aiInput.View())
	hints := s.key.Render("Enter") + " " + s.dim.Render("run") +
		s.sep.Render("  ·  ") +
		s.key.Render("Shift+Enter") + " " + s.dim.Render("newline") +
		s.sep.Render("  ·  ") +
		s.key.Render("Esc") + " " + s.dim.Render("cancel")
	body := "\n" + s.dim.Render(" describe what work items to create:") +
		"\n" + inputBox + "\n\n " + hints + "\n"
	return m.placeModal(buildModalBox(s, "Add Work Items via AI", body))
}

// renderConfirmModal overlays a centered confirmation modal for archive/delete actions.
func (m model) renderConfirmModal() string {
	s := modalStyles

	var title, body string
	switch m.confirmAction {
	case "archive":
		title = "Archive Work Item"
		body = fmt.Sprintf("Archive %s?\n\n", s.key.Render(m.confirmTitle)) +
			s.key.Render("y / Enter") + s.dim.Render("  confirm") + "    " +
			s.key.Render("any key") + s.dim.Render("  cancel")
	case "unarchive":
		title = "Unarchive Work Item"
		body = fmt.Sprintf("Unarchive %s?\n\n", s.key.Render(m.confirmTitle)) +
			s.key.Render("y / Enter") + s.dim.Render("  confirm") + "    " +
			s.key.Render("any key") + s.dim.Render("  cancel")
	case "delete":
		warnS := style.SevBlocking
		title = warnS.Render("Delete Work Item")
		body = fmt.Sprintf("Permanently delete %s?\n\n", s.key.Render(m.confirmTitle)) +
			s.key.Render("y / Enter") + s.dim.Render("  confirm") + "    " +
			s.key.Render("any key") + s.dim.Render("  cancel")
	case "dismiss":
		title = "Dismiss Follow-up"
		body = fmt.Sprintf("Dismiss %s?\n\n", s.key.Render(m.confirmTitle)) +
			s.key.Render("y / Enter") + s.dim.Render("  confirm") + "    " +
			s.key.Render("any key") + s.dim.Render("  cancel")
	case "delete_followup":
		warnS := style.SevBlocking
		title = warnS.Render("Delete Follow-up")
		body = fmt.Sprintf("Permanently delete %s?\n\n", s.key.Render(m.confirmTitle)) +
			s.key.Render("y / Enter") + s.dim.Render("  confirm") + "    " +
			s.key.Render("any key") + s.dim.Render("  cancel")
	case "post_review":
		title = "Post Review Comments"
		body = fmt.Sprintf("%s\n\n", s.key.Render(m.confirmTitle)) +
			s.key.Render("y / Enter") + s.dim.Render("  confirm") + "    " +
			s.key.Render("n / Esc") + s.dim.Render("  cancel")
	}

	return m.placeModal(buildModalBox(s, title, body))
}

// renderHelpModal overlays a centered modal listing all keybindings.
func (m model) renderHelpModal() string {
	s := modalStyles
	sectionS := style.SubsectionTitle

	row := func(key, desc string) string {
		k := s.key.Render(fmt.Sprintf("  %-18s", key))
		return k + s.dim.Render(desc)
	}

	content := sectionS.Render("Follow-Ups") + "\n" +
		row("j / k", "navigate") + "\n" +
		row("Enter", "open detail") + "\n" +
		row("Tab / Shift-Tab", "cycle tabs") + "\n" +
		row("p", "promote to work item") + "\n" +
		row("d", "dismiss") + "\n" +
		row("A", "dismiss from list") + "\n" +
		row("D", "delete from list") + "\n" +
		row("c", "chat about follow-up") + "\n" +
		row("Esc", "exit follow-ups") + "\n" +
		"\n" +
		sectionS.Render("Triage Tab") + "\n" +
		row("space / x / Enter", "toggle selection") + "\n" +
		row("a", "select all / deselect all") + "\n" +
		row("p", "promote with selected findings") + "\n" +
		"\n" +
		sectionS.Render("Comments Tab") + "\n" +
		row("a", "select all / deselect all") + "\n" +
		row("y", "copy body to clipboard") + "\n" +
		row("E", "edit body in $EDITOR") + "\n" +
		row("D", "delete comment (confirm)") + "\n" +
		row("P", "post selected comments to PR") + "\n" +
		row("g", "generate thematic summary (LLM)") + "\n" +
		"\n" +
		sectionS.Render("Work List") + "\n" +
		row("j / k", "navigate") + "\n" +
		row("Enter", "open detail") + "\n" +
		row("s", "run spec") + "\n" +
		row("c", "chat about spec") + "\n" +
		row("N", "create work items with AI") + "\n" +
		row("L", "toggle layout") + "\n" +
		row("A", "archive / unarchive") + "\n" +
		row("D", "delete") + "\n" +
		row("ctrl+a", "toggle archived") + "\n" +
		row("K", "knowledge browser") + "\n" +
		row("t", "settlement panel") + "\n" +
		"\n" +
		sectionS.Render("Settlement") + "\n" +
		row("j / k", "navigate queue") + "\n" +
		row("p", "process one batch") + "\n" +
		row("e", "enable / disable") + "\n" +
		row("l / h", "settings / status") + "\n" +
		row("w / f", "work / follow-ups") + "\n" +
		"\n" +
		sectionS.Render("Work Detail") + "\n" +
		row("Tab / Shift-Tab", "cycle tabs") + "\n" +
		row("j / k", "scroll") + "\n" +
		row("h / Esc", "back to list") + "\n" +
		"\n" +
		sectionS.Render("Spec Panel (terminal mode)") + "\n" +
		row("scroll wheel", "scroll output") + "\n" +
		row("ctrl+t", "switch to detail view") + "\n" +
		row("Esc", "forward to subprocess (e.g. interrupt)") + "\n" +
		row("Esc Esc", "detach focus, back to list") + "\n" +
		row("Ctrl+c", "terminate subprocess") + "\n" +
		row("Ctrl+\\", "terminate subprocess") + "\n" +
		row("(all other keys)", "forwarded to subprocess") + "\n" +
		"\n" +
		sectionS.Render("Global") + "\n" +
		row("?", "this help") + "\n" +
		row("t", "settlement panel") + "\n" +
		row("S / Ctrl+,", "settings configurator") + "\n" +
		row("q / Ctrl+C / Ctrl+D", "quit")

	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(s.border.GetForeground()).
		Padding(0, 1).
		Render(s.title.Render("Keyboard Shortcuts") + "\n\n" + content + "\n\n" +
			s.dim.Render("  Press ? or Esc to close"))

	return m.placeModal(box)
}
