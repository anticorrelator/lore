package main

// Axis C mockups: competing settlement-panel candidates rendered through the
// mockup-dump harness (see mockup_dump_test.go for the extension contract).
//
//	LORE_MOCKUP_DUMP=1 go test -run TestMockupDumpAxisC -v
//
// Two variants:
//
//   - cand-settlement-drillin: keeps the status-quo horizontal split
//     (operational status + queue above, compact settings dock below) but
//     drops the capped selected-claim block in favor of Enter/v drill-in
//     frames that show a claim or verdict in full.
//   - cand-settlement-reweighted: re-weights the dashboard around a k9s-style
//     health header and a posture line of one-key toggles; durable settlement
//     config leaves the panel for the global settings modal, leases collapse
//     to a health-line count, and contradicted verdicts render loud while
//     confirmations recede.
//
// Every frame is composed from fixture data plus the shared style tokens and
// host chrome (tab indicator, border title, status-bar grammar), so the
// captures stay pixel-comparable with mock-base-settlement.ans.

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/settings"
	"github.com/anticorrelator/lore/tui/internal/settlement"
	"github.com/anticorrelator/lore/tui/internal/style"
)

// ---------------------------------------------------------------------------
// Shared fixture data
// ---------------------------------------------------------------------------

// axisCSettlementStatus extends the baseline settlement fixture with enough
// queue items and verdicts to exercise scrolling regions, loud/quiet verdict
// treatment, and drill-in detail fields.
func axisCSettlementStatus() settlement.Status {
	st := mockupSettlementStatus()
	st.Items = append(st.Items,
		settlement.Item{
			ID: "cl-esc-focus-return", WorkItem: "tui-design-exploration-pass",
			ClaimID: "esc-focus-return",
			Claim:   "Esc on the settings side returns focus to the queue side unless a leaf editor is consuming runes",
			Status:  "pending",
		},
		settlement.Item{
			ID: "cl-hooks-parallel", WorkItem: "session-hooks",
			ClaimID: "hooks-parallel-load",
			Claim:   "SessionStart hooks load knowledge and work items in parallel",
			Status:  "pending",
		},
		settlement.Item{
			ID: "cl-ratchet-shrinks", WorkItem: "style-tokens",
			ClaimID: "ratchet-only-shrinks",
			Claim:   "The inline color ratchet allowlist only ever shrinks; new literals fail the style test",
			Status:  "ready",
		},
	)
	st.Queue = settlement.Queue{Total: 7, Ready: 2, Pending: 2, Running: 1, Complete: 1, Blocked: 1}
	st.RecentSettled = append(st.RecentSettled,
		settlement.LastSettled{
			ClaimID: "capture-gate-4cond",
			Claim:   "The capture gate requires all four conditions before writing an entry",
			VerdictLabel: "contradicted",
			VerdictSummary: "Auditor found the orientation gate path writes entries with only two of " +
				"the four conditions satisfied; skills/remember/SKILL.md step 2 documents the " +
				"orientation gate as an alternative, not an addition.",
			SourceFile: "skills/remember/SKILL.md", LineRange: "88-104",
			SettledAt:         mockupTimeAgo(36 * time.Hour),
			RunRef:            "_scorecards/runs/run-9c2f11ab.json",
			VerdictRef:        "_work/capture-gate-audit/verdicts/run-9c2f11ab.md",
			CorrectionOutcome: settlement.CorrectionOutcome{Status: "applied", TargetEntry: "conventions/capture-gate-has-two-alternative-entry-paths.md"},
		},
		settlement.LastSettled{
			ClaimID:           "drift-dedupe-window",
			Claim:             "Drift sweep dedupes already-settled claims within the concordance window",
			VerdictLabel:      "verified",
			CorrectionOutcome: settlement.CorrectionOutcome{Status: "applied"},
		},
	)
	return st
}

// ---------------------------------------------------------------------------
// Frame chrome shared by every axis C variant
// ---------------------------------------------------------------------------

// axisCFrame wraps variant body lines in the settlement panel's host chrome —
// tab indicator, bordered frame with title annotation, and the status-bar
// hint grammar — mirroring viewSettlement's geometry so captures compare
// cell-for-cell with the baseline.
func axisCFrame(m model, bodyLines []string, annot string, annotW int, hints []string) string {
	w := m.width
	contentH := m.innerHeight() - 1
	innerW := w - 2
	borderS := borderFocusedS

	var b strings.Builder
	b.WriteString(renderTabIndicator(stateSettlement, len(m.list.Items()), m.followupList.FollowUpCount(), m.settlement.Count(), w))
	b.WriteString("\n")
	b.WriteString(borderS.Render(style.DockBorder.TopLeft))
	b.WriteString(renderBorderTitleWithAnnot(style.TitleName.Render("Settlement"), innerW, borderS, annot, annotW))
	b.WriteString(borderS.Render(style.DockBorder.TopRight))
	b.WriteString("\n")
	for i := 0; i < contentH; i++ {
		line := ""
		if i < len(bodyLines) {
			line = " " + bodyLines[i]
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

	bar := "  " + strings.Join(hints, style.Separator.Render("  ·  "))
	if barW := lipgloss.Width(bar); barW < w {
		bar += strings.Repeat(" ", w-barW)
	}
	b.WriteString(style.Dim.Render(bar))
	return b.String()
}

// axisCRule renders the labeled section rule ("─ Label ───…") the settlement
// panel uses to separate regions.
func axisCRule(label string, width int) string {
	text := " " + label + " "
	if width <= lipgloss.Width(text)+2 {
		return style.SubsectionTitle.Render(label)
	}
	return style.SectionRule.Render("─") +
		style.SubsectionTitle.Render(text) +
		style.SectionRule.Render(strings.Repeat("─", width-lipgloss.Width(text)-1))
}

var (
	axisCSelectedS = lipgloss.NewStyle().Background(style.ColorSelectionBg).Bold(true)
	axisCLoudS     = style.StatusError.Bold(true)
)

func axisCStatusStyle(status string) lipgloss.Style {
	switch status {
	case "ready":
		return style.StatusReady
	case "running":
		return style.StatusActive
	case "blocked", "failed":
		return style.StatusError
	}
	return lipgloss.NewStyle()
}

// axisCQueueRow renders one queue row: status badge, claim id column, claim
// text. Selected rows render unstyled content inside the selection background
// so the row-wide highlight is not reset mid-line by per-cell colors.
func axisCQueueRow(item settlement.Item, width int, selected bool) string {
	badge := fmt.Sprintf("%-10s", "["+item.Status+"]")
	id := fmt.Sprintf("%-22s", item.ClaimID)
	tail := item.Claim
	if item.BlockedReason != "" {
		tail += "  ·  blocked: " + item.BlockedReason
	}
	if selected {
		return axisCSelectedS.Render(style.Truncate("> "+badge+" "+id+" "+tail, width))
	}
	return style.Truncate("  "+axisCStatusStyle(item.Status).Render(badge)+" "+id+" "+tail, width)
}

// axisCVerdictLine renders one verdict-log line. Contradictions and audit
// errors read loud (error color, ! marker); confirmations recede into dim.
func axisCVerdictLine(v settlement.LastSettled, width int) string {
	label := v.VerdictLabel
	outcome := ""
	switch v.CorrectionOutcome.Status {
	case "applied":
		outcome = " → applied"
	case "skipped":
		outcome = " → skip"
		if v.CorrectionOutcome.Reason != "" {
			outcome += ":" + v.CorrectionOutcome.Reason
		}
	}
	if label == "contradicted" || label == "audit error" {
		head := axisCLoudS.Render("! " + fmt.Sprintf("%-22s", label+outcome))
		return style.Truncate(head+"  "+v.Claim, width)
	}
	return style.Truncate(style.Dim.Render("  "+fmt.Sprintf("%-22s", label+outcome)+"  "+v.Claim), width)
}

// kvLine renders a dim right-padded key followed by its value, for aligned
// key:value dashboard blocks.
func kvLine(key, value string, keyW int) string {
	pad := keyW - lipgloss.Width(key+":")
	if pad < 1 {
		pad = 1
	}
	return style.Dim.Render(key+":") + strings.Repeat(" ", pad) + value
}

// twoCol joins two prepared cells at a fixed left-column width.
func twoCol(left, right string, leftW int) string {
	pad := leftW - lipgloss.Width(left)
	if pad < 1 {
		pad = 1
	}
	return left + strings.Repeat(" ", pad) + right
}

// wrapIndent word-wraps text under a fixed-width label column, indenting
// continuation lines to the content column — the drill-in replacement for
// mid-sentence truncation.
func wrapIndent(label, text string, labelW, width int) []string {
	head := style.Dim.Render(label+":") + strings.Repeat(" ", labelW-lipgloss.Width(label+":"))
	indent := strings.Repeat(" ", labelW)
	avail := width - labelW
	if avail < 16 {
		return []string{style.Truncate(head+text, width)}
	}
	var lines []string
	current := ""
	for _, word := range strings.Fields(text) {
		candidate := current
		if candidate != "" {
			candidate += " "
		}
		candidate += word
		if lipgloss.Width(candidate) > avail && current != "" {
			lines = append(lines, current)
			current = word
			continue
		}
		current = candidate
	}
	if current != "" {
		lines = append(lines, current)
	}
	out := make([]string, 0, len(lines))
	for i, l := range lines {
		if i == 0 {
			out = append(out, head+l)
		} else {
			out = append(out, indent+l)
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// Variant 1: drill-in (status-quo-adjacent)
// ---------------------------------------------------------------------------

// axisCFixtureStore is a fixture SettingsStore: reads return the fixture
// document, writes are accepted and dropped.
type axisCFixtureStore struct{ doc map[string]any }

func (s axisCFixtureStore) LoadAll() (map[string]any, error) { return s.doc, nil }
func (s axisCFixtureStore) Patch(string, any) error          { return nil }
func (s axisCFixtureStore) Delete(string) error              { return nil }

type axisCNoopRunner struct{}

func (axisCNoopRunner) Run(string, ...string) (string, string, error) { return "", "", nil }

// axisCSettingsPanel builds the settlement compact-embed settings panel the
// same way the host does, but against the repo schema and a fixture store so
// the dock renders real engine rows without touching ~/.lore.
func axisCSettingsPanel(t *testing.T) *settings.SettingsModel {
	t.Helper()
	store := axisCFixtureStore{doc: map[string]any{
		"tui_launch_framework": "claude-code",
		"harnesses":            map[string]any{"claude-code": map[string]any{"args": []any{}}},
		"settlement": map[string]any{
			"enabled":                              true,
			"max_concurrency":                      float64(2),
			"batch_size":                           float64(12),
			"batch_recompute_min_interval_seconds": float64(60),
			"lease_ttl_seconds":                    float64(900),
			"executor_timeout_seconds":             float64(1800),
			"active_hours": map[string]any{
				"enabled":  true,
				"timezone": "America/Los_Angeles",
				"ranges": []any{map[string]any{
					"days":  []any{"mon", "tue", "wed", "thu", "fri"},
					"start": "09:00", "end": "18:00",
				}},
			},
			"harness_selection": map[string]any{
				"mode":                "first_eligible",
				"eligible_frameworks": []any{"claude-code", "codex"},
			},
		},
	}}
	panel, err := settings.NewSettingsModel(settings.SettingsModelOptions{
		SchemaPath:       "../adapters/settings.schema.json",
		CapabilitiesPath: "../adapters/capabilities.json",
		Store:            store,
		Runner:           axisCNoopRunner{},
		EnableScript:     "/fixture/enable.sh",
		DisableScript:    "/fixture/disable.sh",
		Registry:         settings.NewWidgetRegistry(),
	})
	if panel == nil {
		t.Fatalf("building fixture settlement settings panel: %v", err)
	}
	panel.LimitToDotPath("settlement")
	panel.SetCompactEmbed(true)
	return panel
}

// axisCHeaderLines mirrors the current operational-status header so the
// drill-in variant stays visually status-quo-adjacent above the queue.
func axisCHeaderLines(width int) []string {
	return []string{
		axisCRule("Operational status", width),
		"state: " + style.StatusReady.Render("enabled") + "  |  budget: ok  |  runtime left: 40m/60m",
		"queue: ready 2, pending 2, running 1, total 7  |  leases: 1 active",
		"harness: claude-code (auto), concurrency 2  |  next: process next ready",
	}
}

func axisCDrillinRoot(t *testing.T) string {
	st := axisCSettlementStatus()
	m := newMockupModel(t, stateSettlement, config.LayoutTopBottom,
		mockupWidth, mockupHeight, mockupWorkItems(), mockupFollowupItems())
	m = withSettlementStatus(m, st)
	m.settlementSettingsPanel = axisCSettingsPanel(t)

	bodyW := m.width - 2 - 1
	contentH := m.innerHeight() - 1

	lines := axisCHeaderLines(bodyW)
	lines = append(lines, "", axisCRule("Settlement queue", bodyW))
	for i, item := range st.Items {
		lines = append(lines, axisCQueueRow(item, bodyW, i == 0))
	}
	lines = append(lines, "", axisCRule("Recent verdicts", bodyW))
	for i, v := range st.RecentSettled {
		if i == 4 {
			lines = append(lines, style.Dim.Render(fmt.Sprintf("  ... %d more verdicts", len(st.RecentSettled)-i)))
			break
		}
		lines = append(lines, axisCVerdictLine(v, bodyW))
	}
	lines = append(lines, "", axisCRule("Active leases", bodyW))
	lines = append(lines, style.Truncate("- lease-01 item cl-meta-single-block via claude-code owner settle-1 pid 4242 expires in 12m", bodyW))

	// Bottom dock: real engine-rendered compact settlement settings.
	dockH := settlementSettingsMaxHeight(contentH)
	dock := trimTrailingBlankLines(strings.Split(m.settlementSettingsInlineView(bodyW, dockH), "\n"))
	if len(dock) > dockH {
		dock = dock[:dockH]
	}
	filler := contentH - len(lines) - len(dock) - 1
	for i := 0; i < filler; i++ {
		lines = append(lines, "")
	}
	lines = append(lines, renderSettlementSeparator(bodyW))
	lines = append(lines, dock...)

	annot, annotW := annotSettlementFocus.renderSelected(0)
	hints := []string{"j/k queue", "enter claim", "v verdicts", "p process once", "e disable", "l settings", "w work", "f follow-ups", "? help"}
	return axisCFrame(m, lines, annot, annotW, hints)
}

func axisCDrillinClaim(t *testing.T) string {
	st := axisCSettlementStatus()
	m := newMockupModel(t, stateSettlement, config.LayoutTopBottom,
		mockupWidth, mockupHeight, mockupWorkItems(), mockupFollowupItems())
	m = withSettlementStatus(m, st)

	bodyW := m.width - 2 - 1
	labelW := 12
	sel := st.Items[0]

	lines := []string{
		axisCRule("Claim 1 of 7 — "+sel.ClaimID, bodyW),
		kvLine("status", style.StatusActive.Render("[running]")+"  attempt 1  ·  via claude-code", labelW),
		kvLine("work item", sel.WorkItem, labelW),
		kvLine("producer", "worker  ·  task task-3  ·  protocol slot implement-step-5", labelW),
		"",
	}
	lines = append(lines, wrapIndent("claim", sel.Claim, labelW, bodyW)...)
	lines = append(lines, "")
	lines = append(lines, kvLine("evidence", sel.SourceFile+":"+sel.LineRange, labelW))
	lines = append(lines, wrapIndent("falsifier", sel.Falsifier, labelW, bodyW)...)
	lines = append(lines, "")
	lines = append(lines, kvLine("lease", "lease-01  ·  owner settle-1  ·  pid 4242  ·  expires in 12m", labelW))
	lines = append(lines, kvLine("next", "auditor verdict pending — lease renews on heartbeat", labelW))
	lines = append(lines, "")
	lines = append(lines, axisCRule("Snippet under audit", bodyW))
	lines = append(lines,
		style.Dim.Render("  META=\"<!-- learned: $DATE_TODAY | confidence: $CONFIDENCE | source: $SOURCE\""),
		style.Dim.Render("  if [[ -n \"$RELATED_FILES\" ]]; then"),
		style.Dim.Render("    META=\"$META | related_files: $RELATED_FILES\""),
		style.Dim.Render("  fi"),
	)

	annot, annotW := annotSpec{key: "esc", states: []string{"back"}}.renderSelected(0)
	hints := []string{"esc back", "j/k next/prev claim", "p process this", "? help"}
	return axisCFrame(m, lines, annot, annotW, hints)
}

func axisCDrillinVerdict(t *testing.T) string {
	st := axisCSettlementStatus()
	m := newMockupModel(t, stateSettlement, config.LayoutTopBottom,
		mockupWidth, mockupHeight, mockupWorkItems(), mockupFollowupItems())
	m = withSettlementStatus(m, st)

	bodyW := m.width - 2 - 1
	labelW := 12
	v := st.RecentSettled[3] // capture-gate-4cond: contradicted, correction applied

	lines := []string{
		axisCRule("Verdict 4 of 5 — "+v.ClaimID, bodyW),
		kvLine("verdict", axisCLoudS.Render("contradicted")+"  ·  settled "+v.SettledAt, labelW),
		kvLine("evidence", v.SourceFile+":"+v.LineRange, labelW),
		"",
	}
	lines = append(lines, wrapIndent("claim", v.Claim, labelW, bodyW)...)
	lines = append(lines, "")
	lines = append(lines, wrapIndent("summary", v.VerdictSummary, labelW, bodyW)...)
	lines = append(lines, "")
	lines = append(lines, axisCRule("Correction", bodyW))
	lines = append(lines, kvLine("outcome", style.StatusReady.Render("applied"), labelW))
	lines = append(lines, kvLine("target", v.CorrectionOutcome.TargetEntry, labelW))
	lines = append(lines, "")
	lines = append(lines, axisCRule("Artifacts", bodyW))
	lines = append(lines, kvLine("run", v.RunRef, labelW))
	lines = append(lines, kvLine("verdict", v.VerdictRef, labelW))

	annot, annotW := annotSpec{key: "esc", states: []string{"back"}}.renderSelected(0)
	hints := []string{"esc back", "j/k next/prev verdict", "o open verdict file", "? help"}
	return axisCFrame(m, lines, annot, annotW, hints)
}

// ---------------------------------------------------------------------------
// Variant 2: re-weighted dashboard with operational/durable config split
// ---------------------------------------------------------------------------

type axisCPosture struct {
	model    string
	paused   bool
	schedule string
	inWindow bool
}

// axisCHealthLines renders the promoted health header: an aligned two-column
// key:value block capped at four lines, with leases folded to a count.
func axisCHealthLines(width int, degraded bool) []string {
	keyW := 10
	colW := 78
	budget := "ok  ·  jobs 14/20  ·  runtime 40m/60m"
	leases := "1 active"
	requeue := "1 today  ·  0 failed"
	drain := "~9/h  ·  est. clear 47m"
	if degraded {
		budget = style.StatusWarn.Render("low") + "  ·  jobs 2/20  ·  runtime 6m/60m"
		leases = axisCLoudS.Render("1 stuck") + "  ·  1 active"
		requeue = style.StatusWarn.Render("4 today  ·  2 failed")
		drain = style.StatusWarn.Render("~1/h  ·  est. clear 7h")
	}
	return []string{
		axisCRule("Health", width),
		twoCol(kvLine("queue", "2 ready  ·  2 pending  ·  1 running  ·  1 blocked  ·  7 total", keyW), kvLine("drain", drain, keyW), colW),
		twoCol(kvLine("oldest", "3d pending (index-regen-on-missing)", keyW), kvLine("requeue", requeue, keyW), colW),
		twoCol(kvLine("budget", budget, keyW), kvLine("leases", leases, keyW), colW),
	}
}

// axisCPostureLine renders the one-key operational toggles with their state
// visible in place — the operational half of the config split.
func axisCPostureLine(p axisCPosture, width int) string {
	key := func(k string) string { return style.KeyHint.Render("[" + k + "]") }
	pausedVal := style.StatusReady.Render("no")
	if p.paused {
		pausedVal = axisCLoudS.Render("YES")
	}
	scheduleVal := style.StatusReady.Render(p.schedule + "  (in window)")
	if !p.inWindow {
		scheduleVal = style.StatusWarn.Render(p.schedule + "  (out of window)")
	}
	return style.Truncate(strings.Join([]string{
		key("m") + " " + style.Dim.Render("auditor model:") + " " + p.model,
		key("p") + " " + style.Dim.Render("paused:") + " " + pausedVal,
		key("s") + " " + style.Dim.Render("schedule:") + " " + scheduleVal,
	}, "      "), width)
}

func axisCReweightedBody(t *testing.T, degraded bool) string {
	st := axisCSettlementStatus()
	posture := axisCPosture{model: "sonnet-5", schedule: "active 09:00–18:00 PT", inWindow: true}
	if degraded {
		posture = axisCPosture{model: "haiku-4.5", paused: true, schedule: "active 09:00–18:00 PT", inWindow: false}
	}
	m := newMockupModel(t, stateSettlement, config.LayoutTopBottom,
		mockupWidth, mockupHeight, mockupWorkItems(), mockupFollowupItems())
	m = withSettlementStatus(m, st)

	bodyW := m.width - 2 - 1

	lines := axisCHealthLines(bodyW, degraded)
	lines = append(lines, "", axisCRule("Posture", bodyW))
	lines = append(lines, axisCPostureLine(posture, bodyW))
	lines = append(lines, "", axisCRule("Queue", bodyW))
	for i, item := range st.Items {
		lines = append(lines, axisCQueueRow(item, bodyW, i == 0))
	}
	lines = append(lines, "", axisCRule("Verdicts", bodyW))
	// Contradictions surface first and loud; confirmations follow, quiet.
	ordered := make([]settlement.LastSettled, 0, len(st.RecentSettled))
	for _, v := range st.RecentSettled {
		if v.VerdictLabel == "contradicted" {
			ordered = append(ordered, v)
		}
	}
	for _, v := range st.RecentSettled {
		if v.VerdictLabel != "contradicted" {
			ordered = append(ordered, v)
		}
	}
	for _, v := range ordered {
		lines = append(lines, axisCVerdictLine(v, bodyW))
	}
	if degraded {
		lines = append(lines, "", axisCRule("Stuck lease", bodyW))
		lines = append(lines, axisCLoudS.Render(style.Truncate("! lease-01  item cl-meta-single-block  ·  owner settle-1  ·  pid 4242  ·  expired 22m ago  ·  r requeue", bodyW)))
	}

	annot, annotW := annotSpec{key: "j/k", states: []string{"queue"}}.renderSelected(0)
	hints := []string{"j/k queue", "enter claim", "v verdicts", "m model tier", "p pause", "s schedule", "S settings", "w work", "f follow-ups", "? help"}
	return axisCFrame(m, lines, annot, annotW, hints)
}

// ---------------------------------------------------------------------------
// Dump entry points
// ---------------------------------------------------------------------------

func TestMockupDumpAxisC(t *testing.T) {
	requireMockupDump(t)

	t.Run("cand-settlement-drillin", func(t *testing.T) {
		dumpMockup(t, "cand-settlement-drillin", func(t *testing.T) string {
			return axisCDrillinRoot(t)
		})
	})
	t.Run("cand-settlement-drillin-claim", func(t *testing.T) {
		dumpMockup(t, "cand-settlement-drillin-claim", func(t *testing.T) string {
			return axisCDrillinClaim(t)
		})
	})
	t.Run("cand-settlement-drillin-verdict", func(t *testing.T) {
		dumpMockup(t, "cand-settlement-drillin-verdict", func(t *testing.T) string {
			return axisCDrillinVerdict(t)
		})
	})
	t.Run("cand-settlement-reweighted", func(t *testing.T) {
		dumpMockup(t, "cand-settlement-reweighted", func(t *testing.T) string {
			return axisCReweightedBody(t, false)
		})
	})
	t.Run("cand-settlement-reweighted-attention", func(t *testing.T) {
		dumpMockup(t, "cand-settlement-reweighted-attention", func(t *testing.T) string {
			return axisCReweightedBody(t, true)
		})
	})
}
