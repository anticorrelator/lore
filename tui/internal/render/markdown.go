package render

import (
	"regexp"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// Package-level compiled regexps for inline markdown parsing.
var (
	mdBoldRe     = regexp.MustCompile(`\*\*([^*\n]+)\*\*`)
	mdCodeRe     = regexp.MustCompile("`([^`\n]+)`")
	mdWikiLinkRe = regexp.MustCompile(`\[\[([^\]]+)\]\]`)
)

// WordWrapRaw splits text into lines of at most width bytes (word-boundary).
func WordWrapRaw(text string, width int) []string {
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

// Markdown converts markdown to styled terminal output using a fast
// line-by-line approach. Handles headers, bullets, task checkboxes, bold,
// inline code, and wiki links. Runs in microseconds — safe to call
// synchronously on the Bubble Tea event loop.
func Markdown(content string, width int) string {
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
				for i, wl := range WordWrapRaw(stripped[6:], avail) {
					pfx := indent + "  "
					if i == 0 {
						pfx = indent + "✓ "
					}
					out.WriteString(dimStyle.Render(pfx+wl) + "\n")
				}
			case strings.HasPrefix(stripped, "- [ ] "):
				for i, wl := range WordWrapRaw(stripped[6:], avail) {
					if i == 0 {
						out.WriteString(indent + "○ " + applyInline(wl) + "\n")
					} else {
						out.WriteString(indent + "  " + applyInline(wl) + "\n")
					}
				}
			case strings.HasPrefix(stripped, "- "):
				for i, wl := range WordWrapRaw(stripped[2:], avail) {
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
					for _, wl := range WordWrapRaw(line, width) {
						out.WriteString(applyInline(wl) + "\n")
					}
				}
			}
		}
	}

	return out.String()
}
