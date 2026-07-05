package main

// Axis B mockups: detail-pane human digest & tab treatment. Two competing
// variants, rendered through the shared mockup-dump harness
// (mockup_dump_test.go):
//
//   - digest-tab: the tab bar keeps its own-line pill grammar; a Digest tab
//     lands first, human tabs (Plan, Notes, extra documents) precede agent
//     tabs (Tasks, Exec Log), Meta drops to last, and extra-document tabs
//     beyond the first two collapse into a "+N more" pill.
//   - overview-border: the tab bar moves into the panel's top border as
//     lazygit-style segments; the landing Overview segment fuses the digest
//     with a compact metadata block (absorbing the Meta tab), and all extra
//     documents collapse into one "Files (N)" segment whose body is a picker
//     with a preview of the highlighted document.
//
// Both variants extract intent / narrative / architecture sections from
// plan.md tolerantly: headings match case-insensitively at any level, and a
// plan without those sections degrades to the full rendered document (shown
// by the *-degraded frames). Work items stay bags of files — nothing here
// assumes /spec output structure.
//
// Render:
//
//	LORE_MOCKUP_DUMP=1 go test -run TestMockupDumpAxisB -v

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/render"
	"github.com/anticorrelator/lore/tui/internal/style"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

// axisBRichDetail extends the shared baseline detail fixture with an exec log
// and five extra documents, enough to exercise the auto-tab overflow
// treatments in both variants.
func axisBRichDetail() *work.WorkItemDetail {
	d := mockupWorkDetail()
	execLog := "## 2026-06-29T10:00:00Z | worker-1\n\nTransport detection landed.\n"
	d.HasExecutionLog = true
	d.ExecLogContent = &execLog
	d.ExtraFiles = []work.ExtraFile{
		{Name: "design", Content: "# Design\n\nRefresh exchange is single-flighted behind a mutex keyed by the\nrefresh token, so a burst of 401s produces one network call.\n\n- transport owns detection\n- client owns replay policy\n"},
		{Name: "evidence", Content: "# Evidence\n\nfile:line anchored claims for the refresh flow.\n"},
		{Name: "capture-notes", Content: "# Capture Notes\n\nCandidate captures for the token refresh knowledge entries.\n"},
		{Name: "review-findings", Content: "# Review Findings\n\nSelf-review findings, pre-triage.\n"},
		{Name: "spike-log", Content: "# Spike Log\n\nNotes from the oauth refresh spike.\n"},
	}
	return d
}

// axisBLooseDetail is a loose work item for the D4 degraded path: a freeform
// plan with none of the digest sections, no tasks, no exec log.
func axisBLooseDetail() *work.WorkItemDetail {
	plan := `# Drift sweep batching

Loose running notes; no spec pass yet.

Batching the drift sweep means the settle queue only sees one candidate
bundle per repo per day. Tried chunking by category first; directory
prefix groups read better because correction PRs stay reviewable.

Open question: measure candidate bundle sizes before committing to a
chunk cap.
`
	notes := "## 2026-06-20\n\nInitial sweep takes 40s on the big repo; fine unbatched for now.\n"
	return &work.WorkItemDetail{
		Slug:         "drift-sweep-batching",
		Title:        "Drift sweep batching",
		Status:       "active",
		Branches:     []string{},
		Tags:         []string{},
		Created:      mockupTimeAgo(252 * time.Hour),
		Updated:      mockupTimeAgo(252 * time.Hour),
		PlanContent:  &plan,
		NotesContent: &notes,
	}
}

// ---------------------------------------------------------------------------
// Tolerant digest extraction (shared by both variants)
// ---------------------------------------------------------------------------

// digestSection is one extracted plan section, in canonical display order.
type digestSection struct {
	label string
	body  string
}

// axisBHeading parses an ATX heading, returning level 0 for non-headings.
func axisBHeading(line string) (int, string) {
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
		level, text := axisBHeading(lines[i])
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
				if lv, _ := axisBHeading(lines[j]); lv > 0 && lv <= level {
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

// ---------------------------------------------------------------------------
// Shared rendering pieces
// ---------------------------------------------------------------------------

var (
	axisBSlugS    = lipgloss.NewStyle().Foreground(style.ColorTextBright).Bold(true)
	axisBMetaKeyS = lipgloss.NewStyle().Foreground(style.ColorMetaKey)
)

// axisBSectionRule renders "─ Label ────…" filling width, in the shared
// section-framing tokens.
func axisBSectionRule(label string, width int) string {
	title := " " + label + " "
	fill := width - lipgloss.Width(title) - 1
	if fill < 1 {
		fill = 1
	}
	return style.SectionRule.Render("─") +
		style.SubsectionTitle.Render(title) +
		style.SectionRule.Render(strings.Repeat("─", fill))
}

// axisBStatusBadge renders "● status" through the shared status ramp.
func axisBStatusBadge(status string) string {
	s := style.StatusDone
	switch status {
	case "active":
		s = style.StatusActive
	case "archived":
		s = style.StatusDone
	}
	return s.Render("● " + status)
}

// axisBFileLabel mirrors the detail view's extra-file label derivation:
// hyphens/underscores to spaces, words title-cased.
func axisBFileLabel(name string) string {
	name = strings.ReplaceAll(name, "-", " ")
	name = strings.ReplaceAll(name, "_", " ")
	words := strings.Fields(name)
	for i, w := range words {
		words[i] = strings.ToUpper(w[:1]) + w[1:]
	}
	return strings.Join(words, " ")
}

// axisBDigestSectionsView renders the extracted sections, or the degraded
// full-plan fallback when none are present.
func axisBDigestSectionsView(d *work.WorkItemDetail, width int) string {
	var b strings.Builder
	if d.PlanContent == nil {
		b.WriteString(style.Dim.Render("No plan document — nothing to digest."))
		b.WriteString("\n")
		return b.String()
	}
	sections := extractDigestSections(*d.PlanContent)
	if len(sections) == 0 {
		b.WriteString(style.Dim.Render("plan.md has no intent / narrative / architecture sections — showing the full plan"))
		b.WriteString("\n\n")
		b.WriteString(render.Markdown(*d.PlanContent, width))
		return b.String()
	}
	for _, s := range sections {
		b.WriteString(axisBSectionRule(s.label, width))
		b.WriteString("\n")
		b.WriteString(render.Markdown(s.body, width))
		b.WriteString("\n")
	}
	return b.String()
}

// ---------------------------------------------------------------------------
// Variant 1: digest-tab (pill bar, Digest first, Meta last, "+N more")
// ---------------------------------------------------------------------------

// axisBPillBar renders the reordered pill bar. Extra-document tabs beyond
// the first two collapse into a "+N more" pill sitting where the collapsed
// tabs would be; agent tabs (Tasks, Exec Log) and Meta trail.
func axisBPillBar(d *work.WorkItemDetail, active string) string {
	labels := []string{"Digest"}
	if d.PlanContent != nil {
		labels = append(labels, "Plan")
	}
	labels = append(labels, "Notes")
	visible := d.ExtraFiles
	overflow := 0
	if len(visible) > 2 {
		overflow = len(visible) - 2
		visible = visible[:2]
	}
	for _, ef := range visible {
		labels = append(labels, axisBFileLabel(ef.Name))
	}
	if overflow > 0 {
		labels = append(labels, fmt.Sprintf("+%d more", overflow))
	}
	if d.HasTasks {
		labels = append(labels, "Tasks")
	}
	if d.HasExecutionLog {
		labels = append(labels, "Exec Log")
	}
	labels = append(labels, "Meta")

	parts := make([]string, len(labels))
	for i, l := range labels {
		if l == active {
			parts[i] = style.ActiveTab.Render(l)
		} else {
			parts[i] = style.InactiveTab.Render(l)
		}
	}
	return " " + strings.Join(parts, " ")
}

// axisBDigestTabBody composes the variant-1 detail body: the standard
// blank / pill bar / blank prelude, then a one-line identity strip (full
// slug, status, updated — the human-value meta) above the digest sections.
func axisBDigestTabBody(d *work.WorkItemDetail, panelW int) string {
	contentW := panelW - 4

	identity := axisBSlugS.Render(d.Slug) +
		"   " + axisBStatusBadge(d.Status) +
		"   " + style.Dim.Render("updated "+work.FormatRelativeTime(d.Updated))

	var b strings.Builder
	b.WriteString("\n")
	b.WriteString(axisBPillBar(d, "Digest"))
	b.WriteString("\n\n")
	b.WriteString(identity)
	b.WriteString("\n\n")
	b.WriteString(axisBDigestSectionsView(d, contentW))
	return b.String()
}

// renderAxisBDigestTab builds the full frame: real model, real compositor,
// candidate body injected through paneConfig.detailView.
func renderAxisBDigestTab(t *testing.T, d *work.WorkItemDetail) string {
	m := newMockupModel(t, stateWork, config.LayoutTopBottom,
		mockupWidth, mockupHeight, mockupWorkItems(), mockupFollowupItems())
	m = withPRStatuses(m, mockupPRStatuses())
	m = withWorkDetail(t, m, d)
	m.focusedPanel = panelRight
	cfg := m.buildPaneConfig()
	cfg.detailView = axisBDigestTabBody(d, m.rightPanelWidth())
	return m.viewTopBottom(cfg)
}

// ---------------------------------------------------------------------------
// Variant 2: overview-border (border segments, Overview absorbs Meta,
// Files (N) group segment with picker body)
// ---------------------------------------------------------------------------

// axisBBorderSegments composes the segment run for the bottom panel's top
// border: Overview · Plan · Notes · Files (N) · Tasks · Exec Log, active
// segment as the single filled pill, counts in the title-count token.
func axisBBorderSegments(d *work.WorkItemDetail, active string) string {
	type seg struct{ label, count string }
	segs := []seg{{"Overview", ""}}
	if d.PlanContent != nil {
		segs = append(segs, seg{"Plan", ""})
	}
	segs = append(segs, seg{"Notes", ""})
	if n := len(d.ExtraFiles); n > 0 {
		segs = append(segs, seg{"Files", fmt.Sprintf("(%d)", n)})
	}
	if d.HasTasks {
		segs = append(segs, seg{"Tasks", ""})
	}
	if d.HasExecutionLog {
		segs = append(segs, seg{"Exec Log", ""})
	}

	parts := make([]string, len(segs))
	for i, s := range segs {
		label := s.label
		if s.count != "" {
			label += " " + s.count
		}
		if s.label == active {
			parts[i] = style.ActiveTab.Render(label)
		} else {
			p := style.Dim.Render(s.label)
			if s.count != "" {
				p += " " + style.TitleCount.Render(s.count)
			}
			parts[i] = p
		}
	}
	return strings.Join(parts, annotDimS.Render(" · "))
}

// axisBViewTopBottomBorderTabs mirrors viewTopBottom's frame but puts the
// tab segments in the bottom panel's top border (replacing the item-title
// run) and drops the in-body tab bar, returning those rows to content.
func axisBViewTopBottomBorderTabs(m model, cfg paneConfig, d *work.WorkItemDetail, activeSeg, body string) string {
	topH := m.topPanelHeight() - 1
	bottomH := m.detailPanelHeight()
	panelW := m.topPanelWidth()

	topBS := borderBlurS
	bottomBS := borderFocusedS

	padLine := func(line string) string {
		w := lipgloss.Width(line)
		if w > panelW {
			return style.Truncate(line, panelW)
		}
		return line + strings.Repeat(" ", panelW-w)
	}

	segRun := axisBBorderSegments(d, activeSeg)
	annot := tabKeyS.Render("tab") + annotDimS.Render("  cycle")
	borderTop := renderBorderTitleWithAnnot(segRun, panelW, bottomBS, annot, lipgloss.Width("tab  cycle"))

	topLines := strings.Split(cfg.listView, "\n")
	bottomLines := strings.Split(body, "\n")

	var b strings.Builder
	b.WriteString(renderTabIndicator(cfg.state, cfg.listItemCount, cfg.fuItemCount, cfg.settlementCount, m.width, m.tabIdentity()))
	b.WriteString("\n")

	b.WriteString(topBS.Render(style.DockBorder.TopLeft))
	b.WriteString(renderBorderTitleWithAnnot(cfg.listTitle, panelW, topBS, cfg.filterAnnot, cfg.filterAnnotW))
	b.WriteString(topBS.Render(style.DockBorder.TopRight))
	b.WriteString("\n")
	for i := 0; i < topH; i++ {
		line := ""
		if i < len(topLines) {
			line = topLines[i]
		}
		b.WriteString(topBS.Render(style.DockBorder.Left))
		b.WriteString(padLine(line))
		b.WriteString(topBS.Render(style.DockBorder.Left))
		b.WriteString("\n")
	}
	b.WriteString(topBS.Render(style.DockBorder.BottomLeft))
	b.WriteString(topBS.Render(strings.Repeat(style.DockBorder.Bottom, panelW)))
	b.WriteString(topBS.Render(style.DockBorder.BottomRight))
	b.WriteString("\n")

	b.WriteString(bottomBS.Render(style.DockBorder.TopLeft))
	b.WriteString(borderTop)
	b.WriteString(bottomBS.Render(style.DockBorder.TopRight))
	b.WriteString("\n")
	for i := 0; i < bottomH; i++ {
		content := "  "
		if i < len(bottomLines) {
			content = "  " + bottomLines[i]
		}
		b.WriteString(bottomBS.Render(style.DockBorder.Left))
		b.WriteString(padLine(content))
		b.WriteString(bottomBS.Render(style.DockBorder.Left))
		b.WriteString("\n")
	}
	b.WriteString(bottomBS.Render(style.DockBorder.BottomLeft))
	b.WriteString(bottomBS.Render(strings.Repeat(style.DockBorder.Bottom, panelW)))
	b.WriteString(bottomBS.Render(style.DockBorder.BottomRight))
	b.WriteString("\n")

	b.WriteString(m.renderStatusBar(m.width))
	return b.String()
}

// axisBOverviewBody renders the Overview segment: the full metadata the Meta
// tab used to own, compacted into three key:value lines (slug first, always
// untruncated), then the digest sections.
func axisBOverviewBody(d *work.WorkItemDetail, panelW int) string {
	contentW := panelW - 4
	kv := func(key, val string) string {
		if val == "" {
			val = style.Dim.Render("--")
		}
		return axisBMetaKeyS.Render(key+":") + " " + val
	}
	sep := style.Separator.Render("   ·   ")

	line1 := axisBSlugS.Render(d.Slug) + "   " + axisBStatusBadge(d.Status) +
		"   " + style.Dim.Render("updated "+work.FormatRelativeTime(d.Updated)+" · created "+d.Created)
	line2 := kv("project", d.Project) + sep + kv("branches", strings.Join(d.Branches, ", ")) +
		sep + kv("tags", strings.Join(d.Tags, ", "))
	line3 := kv("issue", d.Issue) + sep + kv("pr", d.PR)

	var b strings.Builder
	b.WriteString("\n")
	b.WriteString(line1)
	b.WriteString("\n")
	b.WriteString(line2)
	b.WriteString("\n")
	b.WriteString(line3)
	b.WriteString("\n\n")
	b.WriteString(axisBDigestSectionsView(d, contentW))
	return b.String()
}

// axisBFilesPickerBody renders the Files segment: a picker over the extra
// documents with a markdown preview of the highlighted one — the overflow
// story for unbounded auto-tabs.
func axisBFilesPickerBody(d *work.WorkItemDetail, panelW int) string {
	contentW := panelW - 4
	selectedS := lipgloss.NewStyle().Background(style.ColorSelectionBg)

	var b strings.Builder
	b.WriteString("\n")
	b.WriteString(style.Dim.Render(fmt.Sprintf("%d documents — j/k select · enter open", len(d.ExtraFiles))))
	b.WriteString("\n\n")
	for i, ef := range d.ExtraFiles {
		lineCount := strings.Count(ef.Content, "\n") + 1
		count := fmt.Sprintf("%d lines", lineCount)
		var row string
		if i == 0 {
			// Selection is one row-wide background over unstyled content.
			plain := fmt.Sprintf("▸ %-24s %s", axisBFileLabel(ef.Name), count)
			row = selectedS.Render(plain + strings.Repeat(" ", max(0, contentW-lipgloss.Width(plain))))
		} else {
			row = fmt.Sprintf("  %-24s ", axisBFileLabel(ef.Name)) + style.Dim.Render(count)
		}
		b.WriteString(row)
		b.WriteString("\n")
	}
	b.WriteString("\n")
	b.WriteString(axisBSectionRule("preview: "+axisBFileLabel(d.ExtraFiles[0].Name), contentW))
	b.WriteString("\n")
	b.WriteString(render.Markdown(d.ExtraFiles[0].Content, contentW))
	return b.String()
}

// renderAxisBOverviewBorder builds a variant-2 frame with the given active
// segment and body.
func renderAxisBOverviewBorder(t *testing.T, d *work.WorkItemDetail, activeSeg string, body func(*work.WorkItemDetail, int) string) string {
	m := newMockupModel(t, stateWork, config.LayoutTopBottom,
		mockupWidth, mockupHeight, mockupWorkItems(), mockupFollowupItems())
	m = withPRStatuses(m, mockupPRStatuses())
	m = withWorkDetail(t, m, d)
	m.focusedPanel = panelRight
	cfg := m.buildPaneConfig()
	return axisBViewTopBottomBorderTabs(m, cfg, d, activeSeg, body(d, m.rightPanelWidth()))
}

// ---------------------------------------------------------------------------
// Dumps
// ---------------------------------------------------------------------------

func TestMockupDumpAxisB(t *testing.T) {
	requireMockupDump(t)

	t.Run("cand-detail-digest-tab", func(t *testing.T) {
		dumpMockup(t, "cand-detail-digest-tab", func(t *testing.T) string {
			return renderAxisBDigestTab(t, axisBRichDetail())
		})
	})

	t.Run("cand-detail-digest-tab-degraded", func(t *testing.T) {
		dumpMockup(t, "cand-detail-digest-tab-degraded", func(t *testing.T) string {
			return renderAxisBDigestTab(t, axisBLooseDetail())
		})
	})

	t.Run("cand-detail-overview-border", func(t *testing.T) {
		dumpMockup(t, "cand-detail-overview-border", func(t *testing.T) string {
			return renderAxisBOverviewBorder(t, axisBRichDetail(), "Overview", axisBOverviewBody)
		})
	})

	t.Run("cand-detail-overview-border-files", func(t *testing.T) {
		dumpMockup(t, "cand-detail-overview-border-files", func(t *testing.T) string {
			return renderAxisBOverviewBorder(t, axisBRichDetail(), "Files", axisBFilesPickerBody)
		})
	})

	t.Run("cand-detail-overview-border-degraded", func(t *testing.T) {
		dumpMockup(t, "cand-detail-overview-border-degraded", func(t *testing.T) string {
			return renderAxisBOverviewBorder(t, axisBLooseDetail(), "Overview", axisBOverviewBody)
		})
	})
}
