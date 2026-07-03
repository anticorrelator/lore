package work

import (
	"strings"

	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/style"
)

// digestSection is one extracted plan section, in canonical display order.
type digestSection struct {
	label string
	body  string
}

// digestSlugStyle renders the identity line's slug: bright and bold, the
// human anchor that replaces the Meta tab's landing position.
var digestSlugStyle = lipgloss.NewStyle().Foreground(style.ColorTextBright).Bold(true)

// atxHeading parses an ATX heading, returning level 0 for non-headings.
func atxHeading(line string) (int, string) {
	trimmed := strings.TrimSpace(line)
	n := 0
	for n < len(trimmed) && trimmed[n] == '#' {
		n++
	}
	if n == 0 || n > 6 || n >= len(trimmed) || trimmed[n] != ' ' {
		return 0, ""
	}
	return n, strings.TrimSpace(trimmed[n:])
}

// extractDigestSections scans plan markdown for intent / narrative /
// architecture headings: case-insensitive substring match, any heading
// level, fenced code ignored. A section's body runs to the next heading at
// the same or higher level. Missing sections are absent from the result —
// absence is the caller's degrade signal, never an error.
func extractDigestSections(plan string) []digestSection {
	classify := func(heading string) (string, int, bool) {
		h := strings.ToLower(heading)
		switch {
		case strings.Contains(h, "intent"):
			return "Intent", 0, true
		case strings.Contains(h, "narrative"):
			return "Narrative", 1, true
		case strings.Contains(h, "architecture"), strings.Contains(h, "diagram"):
			return "Architecture", 2, true
		}
		return "", 0, false
	}

	lines := strings.Split(plan, "\n")
	found := map[int]digestSection{}
	inFence := false
	for i := 0; i < len(lines); {
		if strings.HasPrefix(strings.TrimSpace(lines[i]), "```") {
			inFence = !inFence
			i++
			continue
		}
		if inFence {
			i++
			continue
		}
		level, text := atxHeading(lines[i])
		if level == 0 {
			i++
			continue
		}
		label, order, ok := classify(text)
		if !ok {
			i++
			continue
		}
		j := i + 1
		bodyFence := false
		for j < len(lines) {
			if strings.HasPrefix(strings.TrimSpace(lines[j]), "```") {
				bodyFence = !bodyFence
				j++
				continue
			}
			if !bodyFence {
				if lv, _ := atxHeading(lines[j]); lv > 0 && lv <= level {
					break
				}
			}
			j++
		}
		if _, dup := found[order]; !dup {
			found[order] = digestSection{label: label, body: strings.TrimSpace(strings.Join(lines[i+1:j], "\n"))}
		}
		i = j
	}

	var out []digestSection
	for k := 0; k < 3; k++ {
		if s, ok := found[k]; ok {
			out = append(out, s)
		}
	}
	return out
}

// digestSectionRule renders "─ Label ────…" filling width, in the shared
// section-framing tokens.
func digestSectionRule(label string, width int) string {
	title := " " + label + " "
	fill := width - lipgloss.Width(title) - 1
	if fill < 1 {
		fill = 1
	}
	return style.SectionRule.Render("─") +
		style.SubsectionTitle.Render(title) +
		style.SectionRule.Render(strings.Repeat("─", fill))
}

// digestStatusBadge renders "● status" through the shared status ramp.
func digestStatusBadge(status string) string {
	s := style.StatusDone
	if status == "active" {
		s = style.StatusActive
	}
	return s.Render("● " + status)
}

// renderDigest composes the digest tab body: an identity line (full slug,
// status badge, relative updated) above the extracted plan sections.
// Degradation: any subset of sections renders; zero sections falls back to
// a dim notice plus the full rendered plan; no plan document at all yields
// a dim notice only.
func renderDigest(d *WorkItemDetail, width int) string {
	var b strings.Builder
	b.WriteString(digestSlugStyle.Render(d.Slug))
	b.WriteString("   " + digestStatusBadge(d.Status))
	b.WriteString("   " + style.Dim.Render("updated "+FormatRelativeTime(d.Updated)))
	b.WriteString("\n\n")

	if d.PlanContent == nil {
		b.WriteString(style.Dim.Render("No plan document — nothing to digest."))
		b.WriteString("\n")
		return b.String()
	}
	sections := extractDigestSections(*d.PlanContent)
	if len(sections) == 0 {
		b.WriteString(style.Dim.Render("plan.md has no intent / narrative / architecture sections — showing the full plan"))
		b.WriteString("\n\n")
		b.WriteString(renderMarkdown(*d.PlanContent, width))
		return b.String()
	}
	for _, s := range sections {
		b.WriteString(digestSectionRule(s.label, width))
		b.WriteString("\n")
		b.WriteString(renderMarkdown(s.body, width))
		b.WriteString("\n")
	}
	return b.String()
}

// DigestTabModel is the scrollable renderer for the Digest tab.
type DigestTabModel struct {
	viewport viewport.Model
	ready    bool
}

// NewDigestTabModel builds the digest body for a loaded detail.
func NewDigestTabModel(d *WorkItemDetail, width, height int) DigestTabModel {
	vp := viewport.New(viewport.WithWidth(width), viewport.WithHeight(height))
	vp.SetContent(renderDigest(d, width))
	return DigestTabModel{viewport: vp, ready: true}
}

func (m DigestTabModel) Update(msg tea.Msg) (DigestTabModel, tea.Cmd) {
	if !m.ready {
		return m, nil
	}
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		// Dimensions arrive already-inner: DetailModel.Update forwards
		// contentWidth/contentHeight (same convention as the plan tab).
		m.viewport.SetWidth(msg.Width)
		m.viewport.SetHeight(msg.Height)
		return m, nil
	}
	var cmd tea.Cmd
	m.viewport, cmd = m.viewport.Update(msg)
	return m, cmd
}

func (m DigestTabModel) View() string {
	if !m.ready {
		return ""
	}
	return m.viewport.View()
}
