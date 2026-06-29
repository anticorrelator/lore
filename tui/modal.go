package main

import (
	"fmt"
	"strings"

	"charm.land/bubbles/v2/textarea"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/style"
)

// modalInnerW is the visible content width inside all modals.
const modalInnerW = 58

// modalStyles returns the shared style set used by all modals.
type modalStyleSet struct {
	title lipgloss.Style
	dim   lipgloss.Style
	key   lipgloss.Style
	sep   lipgloss.Style
}

// modalStyles is allocated once at package init; every field aliases the
// shared primitives (modal box chrome comes from style.BorderFocused).
var modalStyles = newModalStyles()

func newModalStyles() modalStyleSet {
	return modalStyleSet{
		title: style.SectionTitle,
		dim:   style.Dim,
		key:   style.KeyHint,
		sep:   style.Separator,
	}
}

// buildModalBox wraps title+body in the shared focused border box at modalInnerW width.
func buildModalBox(s modalStyleSet, title, body string) string {
	return buildModalBoxWidth(s, title, body, modalInnerW)
}

// buildModalBoxWidth is the variable-width variant. The settings configurator
// uses this to span more of the terminal so long harness blocks don't wrap;
// other modals stick with the buildModalBox default at modalInnerW.
func buildModalBoxWidth(s modalStyleSet, title, body string, width int) string {
	return style.BorderFocused.
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

	// Nested input keeps the one DockBorder shape and recedes via the dim
	// blur border.
	inputBox := style.BorderBlur.
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
	inputBox := style.BorderBlur.
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

// helpContent builds the keybinding list shown in the help modal: the keymap
// registry's help-visible projection, one section per registry section with a
// helpTitle, in registry order.
func helpContent() string {
	s := modalStyles
	sectionS := style.SubsectionTitle

	row := func(key, desc string) string {
		k := s.key.Render(fmt.Sprintf("  %-18s", key))
		return k + s.dim.Render(desc)
	}

	var sections []string
	for _, sec := range keymapRegistry {
		if sec.helpTitle == "" {
			continue
		}
		var rows []string
		for _, e := range sec.entries {
			if e.surfaces&surfHelp == 0 {
				continue
			}
			key, label := e.key, e.label
			if e.helpKey != "" {
				key = e.helpKey
			}
			if e.helpLabel != "" {
				label = e.helpLabel
			}
			rows = append(rows, row(key, label))
		}
		if len(rows) == 0 {
			continue
		}
		sections = append(sections, sectionS.Render(sec.helpTitle)+"\n"+strings.Join(rows, "\n"))
	}
	return strings.Join(sections, "\n\n")
}

// helpModalChrome is the number of rows the help modal consumes around the
// viewport: 2 border + title + blank-after-title + blank-before-footer +
// footer hint, plus the status-bar row placeModal reserves.
const helpModalChrome = 7

// sizeHelpViewport sizes the help viewport to its full content, capped so the
// modal box never exceeds the terminal height. Called on open and on resize.
func (m *model) sizeHelpViewport() {
	content := helpContent()
	h := lipgloss.Height(content)
	if maxH := m.height - helpModalChrome; m.height > 0 && h > maxH {
		h = max(maxH, 3)
	}
	m.helpViewport.SetWidth(lipgloss.Width(content))
	m.helpViewport.SetHeight(h)
	m.helpViewport.SetContent(content)
}

// renderHelpModal overlays a centered modal listing all keybindings, windowed
// through m.helpViewport so short terminals can scroll the full list.
func (m model) renderHelpModal() string {
	s := modalStyles

	footer := "  Press ? or Esc to close"
	if !m.helpViewport.AtTop() || !m.helpViewport.AtBottom() {
		footer = "  j/k scroll  ·  g/G top/bottom  ·  ? or Esc to close"
	}
	box := style.BorderFocused.
		Padding(0, 1).
		Render(s.title.Render("Keyboard Shortcuts") + "\n\n" + m.helpViewport.View() + "\n\n" +
			s.dim.Render(footer))

	return m.placeModal(box)
}
