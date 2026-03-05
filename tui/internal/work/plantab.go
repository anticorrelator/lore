package work

import (
	"regexp"
	"strings"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// PlanTabModel is the scrollable renderer for the Plan tab.
type PlanTabModel struct {
	viewport viewport.Model
	ready    bool
	empty    bool
}

// NewPlanTabModel constructs a PlanTabModel from optional content.
// Content is treated as empty when nil, blank, or whitespace-only.
func NewPlanTabModel(content *string, width, height int) PlanTabModel {
	if content == nil || strings.TrimSpace(*content) == "" {
		return PlanTabModel{empty: true}
	}
	rendered := renderMarkdown(*content, width)
	vp := viewport.New(width, height)
	vp.SetContent(rendered)
	return PlanTabModel{viewport: vp, ready: true}
}

func (m PlanTabModel) Update(msg tea.Msg) (PlanTabModel, tea.Cmd) {
	if m.empty {
		return m, nil
	}

	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.viewport.Width = msg.Width - 4
		m.viewport.Height = msg.Height - 7
	default:
		var cmd tea.Cmd
		m.viewport, cmd = m.viewport.Update(msg)
		return m, cmd
	}

	return m, nil
}

// IsEmpty returns whether there is no plan content.
func (m PlanTabModel) IsEmpty() bool {
	return m.empty
}

func (m PlanTabModel) View() string {
	if m.empty {
		dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
		return "  " + dimStyle.Render("No plan document.")
	}
	return m.viewport.View()
}

// Package-level compiled regexps for inline markdown parsing.
var (
	mdBoldRe     = regexp.MustCompile(`\*\*([^*\n]+)\*\*`)
	mdCodeRe     = regexp.MustCompile("`([^`\n]+)`")
	mdWikiLinkRe = regexp.MustCompile(`\[\[([^\]]+)\]\]`)
)

// wordWrapRaw splits text into lines of at most width bytes (word-boundary).
func wordWrapRaw(text string, width int) []string {
	if width <= 0 || len(text) <= width {
		return []string{text}
	}
	words := strings.Fields(text)
	if len(words) == 0 {
		return []string{""}
	}
	var lines []string
	cur := words[0]
	for _, w := range words[1:] {
		if len(cur)+1+len(w) <= width {
			cur += " " + w
		} else {
			lines = append(lines, cur)
			cur = w
		}
	}
	return append(lines, cur)
}

// renderMarkdown converts markdown to styled terminal output using a fast
// line-by-line approach. Handles headers, bullets, task checkboxes, bold,
// inline code, and wiki links. Runs in microseconds — safe to call
// synchronously on the Bubble Tea event loop.
func renderMarkdown(content string, width int) string {
	if width <= 0 {
		width = 80
	}

	h1Style   := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("12"))
	h2Style   := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("6"))
	h3Style   := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("7"))
	dimStyle  := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	codeStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("11"))
	boldStyle := lipgloss.NewStyle().Bold(true)

	applyInline := func(s string) string {
		s = mdBoldRe.ReplaceAllStringFunc(s, func(m string) string {
			return boldStyle.Render(m[2 : len(m)-2])
		})
		s = mdCodeRe.ReplaceAllStringFunc(s, func(m string) string {
			return codeStyle.Render(m[1 : len(m)-1])
		})
		s = mdWikiLinkRe.ReplaceAllStringFunc(s, func(m string) string {
			return dimStyle.Render(m)
		})
		return s
	}

	lines := strings.Split(content, "\n")
	var out strings.Builder
	out.Grow(len(content) + 512)

	inCodeBlock := false
	justWroteHeading := false
	for _, line := range lines {
		if strings.HasPrefix(line, "```") {
			inCodeBlock = !inCodeBlock
			justWroteHeading = false
			out.WriteString(dimStyle.Render(line) + "\n")
			continue
		}
		if inCodeBlock {
			out.WriteString(dimStyle.Render(line) + "\n")
			continue
		}

		// Absorb the blank line that typically follows a heading in source —
		// the heading already emits its own trailing blank line.
		if justWroteHeading && strings.TrimSpace(line) == "" {
			continue
		}
		justWroteHeading = false

		switch {
		case strings.HasPrefix(line, "#### "):
			out.WriteString("  " + h3Style.Render(line[5:]) + "\n\n")
			justWroteHeading = true
		case strings.HasPrefix(line, "### "):
			out.WriteString(h3Style.Render(line[4:]) + "\n\n")
			justWroteHeading = true
		case strings.HasPrefix(line, "## "):
			out.WriteString(h2Style.Render(line[3:]) + "\n\n")
			justWroteHeading = true
		case strings.HasPrefix(line, "# "):
			out.WriteString(h1Style.Render(line[2:]) + "\n\n")
			justWroteHeading = true
		default:
			stripped := strings.TrimLeft(line, " ")
			indent := line[:len(line)-len(stripped)]
			avail := width - len(indent) - 2
			switch {
			case strings.HasPrefix(stripped, "- [x] "),
				strings.HasPrefix(stripped, "- [X] "):
				for i, wl := range wordWrapRaw(stripped[6:], avail) {
					pfx := indent + "  "
					if i == 0 {
						pfx = indent + "✓ "
					}
					out.WriteString(dimStyle.Render(pfx+wl) + "\n")
				}
			case strings.HasPrefix(stripped, "- [ ] "):
				for i, wl := range wordWrapRaw(stripped[6:], avail) {
					if i == 0 {
						out.WriteString(indent + "○ " + applyInline(wl) + "\n")
					} else {
						out.WriteString(indent + "  " + applyInline(wl) + "\n")
					}
				}
			case strings.HasPrefix(stripped, "- "):
				for i, wl := range wordWrapRaw(stripped[2:], avail) {
					if i == 0 {
						out.WriteString(indent + "• " + applyInline(wl) + "\n")
					} else {
						out.WriteString(indent + "  " + applyInline(wl) + "\n")
					}
				}
			case strings.TrimSpace(line) == "---":
				out.WriteString(dimStyle.Render(strings.Repeat("─", 60)) + "\n")
			default:
				if strings.TrimSpace(line) == "" {
					out.WriteByte('\n')
				} else {
					for _, wl := range wordWrapRaw(line, width) {
						out.WriteString(applyInline(wl) + "\n")
					}
				}
			}
		}
	}

	return out.String()
}
