package settlement

import (
	"fmt"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/style"
)

type Model struct {
	width     int
	height    int
	status    Status
	hasStatus bool
	cursor    int
	offset    int
}

func NewModel() Model {
	return Model{status: Unavailable("status not loaded")}
}

func (m Model) SetSize(width, height int) Model {
	m.width = width
	m.height = height
	m.clamp()
	return m
}

func (m Model) ReplaceStatus(status Status) Model {
	m.status = status
	m.hasStatus = true
	m.clamp()
	return m
}

func (m Model) Status() Status {
	return m.status
}

func (m Model) Count() int {
	if !m.hasStatus || !m.status.Available {
		return 0
	}
	count := m.status.Queue.Ready + m.status.Queue.Pending + m.status.Queue.Running
	if count == 0 {
		count = m.status.Batch.BacklogSize
	}
	return count
}

func (m Model) Update(msg tea.Msg) (Model, tea.Cmd) {
	if km, ok := msg.(tea.KeyPressMsg); ok {
		switch km.String() {
		case "j", "down":
			m.cursor++
		case "k", "up":
			m.cursor--
		case "pgdown":
			m.cursor += visibleItemRows(m.height) / 2
		case "pgup":
			m.cursor -= visibleItemRows(m.height) / 2
		case "home":
			m.cursor = 0
		case "end":
			m.cursor = len(m.status.Items) - 1
		}
	}
	m.clamp()
	return m, nil
}

func (m Model) View() string {
	w := m.width
	if w <= 0 {
		w = 80
	}
	bodyW := w - 4
	if bodyW < 24 {
		bodyW = 24
	}
	s := styles()
	st := m.status
	if !m.hasStatus || !st.Available {
		msg := stringDefault(st.Message, "settlement status unavailable")
		return wrapLines([]string{
			s.warn.Render("status unavailable"),
			msg,
			"",
			s.dim.Render("The panel will update when `lore settlement status --json` is available."),
		}, bodyW)
	}

	state := "enabled"
	if !st.Enabled {
		state = "disabled"
	}

	nextAction := readableNextAction(firstNonEmpty(st.BlockedReason, st.NextAction, InferNextAction(st)))
	lines := []string{
		s.heading.Render("Operational status"),
		strings.Join([]string{
			"state: " + state,
			"budget: " + stringDefault(st.Usage.BudgetState, "unknown"),
			"runtime left: " + durationLabel(st.Harness.CapRemaining, st.Harness.CapTotal),
		}, "  |  "),
		strings.Join([]string{
			"queue: " + queueLabel(st.Queue),
			"leases: " + fmt.Sprintf("%d active", st.Harness.ActiveLeases),
		}, "  |  "),
		strings.Join([]string{
			"harness: " + harnessLabel(st.Harness),
			"next: " + nextAction,
		}, "  |  "),
	}
	if st.BlockedReason != "" {
		lines = append(lines, "blocked "+st.BlockedReason)
	}
	lines = append(lines, "", s.heading.Render("Settlement queue"))
	if len(st.Items) == 0 {
		lines = append(lines, s.dim.Render("no visible items"))
	} else {
		visibleItems := m.visibleItems()
		for _, item := range visibleItems {
			line := formatItem(" ", item, bodyW, s)
			if m.itemIndex(item) == m.cursor {
				line = s.selected.Render(formatItem(">", item, bodyW, s))
			}
			lines = append(lines, line)
		}
		if end := m.offset + len(visibleItems); end < len(st.Items) {
			lines = append(lines, s.dim.Render(fmt.Sprintf("... %d more", len(st.Items)-end)))
		}
	}
	lines = append(lines, m.selectedClaimBlock(bodyW, s)...)
	lines = append(lines, s.heading.Render("Recent verdicts"))
	// The host clips the rendered body at the panel height (statusH), so the
	// verdict block must fit the remaining lines or a wrapped verdict would be
	// cut mid-wrap at the clip boundary. -1 means unbounded (height unknown).
	verdictBudget := -1
	if m.height > 0 {
		verdictBudget = m.height - len(lines)
		if verdictBudget < 0 {
			verdictBudget = 0
		}
	}
	lines = append(lines, formatRecentSettled(st, bodyW, verdictBudget, s)...)
	if len(st.Leases) > 0 {
		lines = append(lines, s.heading.Render("Active leases"))
		for _, lease := range compactLeases(st.Leases) {
			lines = append(lines, formatLease(lease, bodyW, s))
		}
	}
	return wrapLines(lines, bodyW)
}

func (m *Model) clamp() {
	max := len(m.status.Items) - 1
	if max < 0 {
		m.cursor = 0
		m.offset = 0
		return
	}
	if m.cursor < 0 {
		m.cursor = 0
	}
	if m.cursor > max {
		m.cursor = max
	}
	visible := visibleItemRows(m.height)
	if visible < 1 {
		visible = 1
	}
	if m.cursor < m.offset {
		m.offset = m.cursor
	}
	if m.cursor >= m.offset+visible {
		m.offset = m.cursor - visible + 1
	}
	if m.offset < 0 {
		m.offset = 0
	}
}

func (m Model) visibleItems() []Item {
	visible := visibleItemRows(m.height)
	if visible < 1 || visible > len(m.status.Items) {
		visible = len(m.status.Items)
	}
	end := m.offset + visible
	if end > len(m.status.Items) {
		end = len(m.status.Items)
	}
	return m.status.Items[m.offset:end]
}

func (m Model) itemIndex(item Item) int {
	for i, candidate := range m.status.Items {
		if candidate.ID == item.ID {
			return i
		}
	}
	return -1
}

// maxSelectedClaimLines bounds the selected-claim detail block so the panel
// stays a compact dashboard rather than a full status report.
const maxSelectedClaimLines = 4

// selectedClaimBlock renders the compact detail block for the cursor-selected
// queue item below the queue preview: a heading plus at most
// maxSelectedClaimLines truncated lines. Nil when nothing is selected so the
// empty section is omitted entirely.
func (m Model) selectedClaimBlock(width int, s styleSet) []string {
	sel := m.selectedItem()
	if sel == nil {
		return nil
	}
	block := formatSelectedClaim(sel, width, s)
	if len(block) > maxSelectedClaimLines {
		block = block[:maxSelectedClaimLines]
	}
	out := make([]string, 0, len(block)+2)
	out = append(out, "", s.heading.Render("Selected claim"))
	out = append(out, block...)
	return out
}

func (m Model) selectedItem() *Item {
	if len(m.status.Items) == 0 || m.cursor < 0 || m.cursor >= len(m.status.Items) {
		return nil
	}
	return &m.status.Items[m.cursor]
}

func visibleItemRows(height int) int {
	if height <= 0 {
		return 6
	}
	rows := height - 8
	if rows < 1 {
		return 1
	}
	if rows > 14 {
		return 14
	}
	return rows
}

type styleSet struct {
	heading  lipgloss.Style
	dim      lipgloss.Style
	warn     lipgloss.Style
	key      lipgloss.Style
	selected lipgloss.Style
}

// panelStyles is allocated once at package init; warn and selected are
// widget-local (no shared primitive carries those values), the rest alias
// the canonical primitives.
var panelStyles = styleSet{
	heading:  style.SubsectionTitle,
	dim:      style.Dim,
	warn:     lipgloss.NewStyle().Foreground(lipgloss.Color("3")).Bold(true),
	key:      style.KeyHint,
	selected: lipgloss.NewStyle().Background(lipgloss.Color("237")).Bold(true),
}

func styles() styleSet {
	return panelStyles
}

func row(label, value string) string {
	return fmt.Sprintf("%-15s %s", label+":", value)
}

func queueLabel(q Queue) string {
	return fmt.Sprintf("ready %d, pending %d, running %d, total %d",
		q.Ready, q.Pending, q.Running, q.Total)
}

func harnessLabel(h Harness) string {
	selected := stringDefault(h.Selected, "active")
	mode := stringDefault(h.Mode, "default")
	return fmt.Sprintf("%s (%s), concurrency %s", selected, mode, intLabel(h.Concurrency))
}

func readableNextAction(action string) string {
	action = strings.TrimSpace(action)
	switch action {
	case "":
		return "idle"
	case "budget_jobs_exhausted":
		return "budget jobs exhausted"
	case "budget_runtime_exhausted":
		return "budget runtime exhausted"
	}
	action = strings.TrimPrefix(action, "blocked: ")
	action = strings.ReplaceAll(action, "_", " ")
	return action
}

func compactLeases(leases []Lease) []Lease {
	if len(leases) <= 2 {
		return leases
	}
	return leases[:2]
}

func capLabel(remaining, total int) string {
	if total > 0 {
		return fmt.Sprintf("%d/%d", remaining, total)
	}
	if remaining > 0 {
		return fmt.Sprintf("%d", remaining)
	}
	return "unlimited"
}

func durationLabel(remaining, total int) string {
	format := func(seconds int) string {
		if seconds%60 == 0 {
			return fmt.Sprintf("%dm", seconds/60)
		}
		return fmt.Sprintf("%dm%02ds", seconds/60, seconds%60)
	}
	if total > 0 {
		return fmt.Sprintf("%s/%s", format(remaining), format(total))
	}
	if remaining > 0 {
		return format(remaining)
	}
	return "unlimited"
}

func yesNo(v bool) string {
	if v {
		return "yes"
	}
	return "no"
}

func intLabel(v int) string {
	if v == 0 {
		return "unlimited"
	}
	return fmt.Sprintf("%d", v)
}

func formatItem(marker string, item Item, width int, s styleSet) string {
	claim := firstNonEmpty(item.Claim, item.ClaimID, item.ID, "claim")
	parts := []string{marker}
	if item.Status != "" {
		parts = append(parts, "["+item.Status+"]")
	}
	parts = append(parts, claim)
	if item.BlockedReason != "" {
		parts = append(parts, "blocked: "+item.BlockedReason)
	} else if item.NextAction != "" {
		parts = append(parts, "next: "+item.NextAction)
	}
	return style.Truncate(strings.Join(parts, " "), width)
}

// formatRecentSettled renders up to four recent verdicts, packing only whole
// wrapped verdicts into budget (rendered lines; -1 = unbounded) so the host's
// statusH clip never lands mid-wrap. Verdicts that would overflow are dropped
// whole and summarized by the "... N more verdicts" marker.
func formatRecentSettled(st Status, width, budget int, s styleSet) []string {
	recent := st.RecentSettled
	if len(recent) == 0 && st.LastSettled != nil {
		recent = []LastSettled{*st.LastSettled}
	}
	if len(recent) == 0 {
		return []string{s.dim.Render("no settled claims yet")}
	}
	limit := 4
	if len(recent) < limit {
		limit = len(recent)
	}
	lines := make([]string, 0, limit*2)
	shown := 0
	for i := 0; i < limit; i++ {
		block := formatLastSettled(&recent[i], width, s)
		if budget >= 0 {
			need := len(lines) + len(block)
			if len(recent) > i+1 {
				need++ // reserve a line for the "... N more verdicts" marker
			}
			if need > budget {
				break
			}
		}
		lines = append(lines, block...)
		shown++
	}
	if shown < len(recent) {
		lines = append(lines, s.dim.Render(fmt.Sprintf("... %d more verdicts", len(recent)-shown)))
	}
	return lines
}

func formatSelectedClaim(item *Item, width int, s styleSet) []string {
	if item == nil {
		return []string{s.dim.Render("no claim selected")}
	}
	id := firstNonEmpty(item.ClaimID, item.ID, "selected claim")
	lines := []string{style.Truncate("- "+id+" ["+stringDefault(item.Status, "pending")+"] "+item.WorkItem, width)}
	if item.Claim != "" {
		lines = append(lines, wrapDetail("claim: ", item.Claim, width, s.dim)...)
	}
	source := item.SourceFile
	if item.LineRange != "" {
		source = strings.TrimSpace(source + ":" + item.LineRange)
	}
	if source != "" {
		lines = append(lines, style.Truncate(s.dim.Render("evidence target: "+source), width))
	}
	if item.Falsifier != "" {
		lines = append(lines, wrapDetail("falsifier: ", item.Falsifier, width, s.dim)...)
	}
	return lines
}

func formatLease(lease Lease, width int, s styleSet) string {
	id := firstNonEmpty(lease.ID, lease.ItemID, "lease")
	parts := []string{"-", id}
	if lease.ItemID != "" {
		parts = append(parts, "item "+lease.ItemID)
	}
	if lease.Harness != "" {
		parts = append(parts, "via "+lease.Harness)
	}
	if lease.WorkerID != "" {
		parts = append(parts, "owner "+lease.WorkerID)
	}
	if lease.PID != 0 {
		parts = append(parts, fmt.Sprintf("pid %d", lease.PID))
	}
	if lease.ExpiresAt != "" {
		parts = append(parts, "expires "+lease.ExpiresAt)
	}
	return style.Truncate(strings.Join(parts, " "), width)
}

func formatLastSettled(last *LastSettled, width int, s styleSet) []string {
	if last == nil {
		return []string{s.dim.Render("no settled claims yet")}
	}
	label := verdictLabel(last)
	claim := firstNonEmpty(last.Claim, last.ClaimID, last.ID, "claim")
	prefix := "- " + label + correctionOutcomeSuffix(last.CorrectionOutcome) + "  "
	return wrapDetail(prefix, claim, width, lipgloss.NewStyle())
}

func correctionOutcomeSuffix(outcome CorrectionOutcome) string {
	status := strings.TrimSpace(outcome.Status)
	if status == "" {
		return ""
	}
	switch status {
	case "applied":
		return " → applied"
	case "skipped":
		if reason := strings.TrimSpace(outcome.Reason); reason != "" {
			return " → skip:" + reason
		}
		return " → skip"
	case "failed":
		if reason := strings.TrimSpace(outcome.Reason); reason != "" {
			return " → fail:" + reason
		}
		return " → fail"
	}
	return " → " + status
}

func verdictLabel(last *LastSettled) string {
	label := strings.ToLower(strings.TrimSpace(last.VerdictLabel))
	switch label {
	case "verified", "unverified", "contradicted":
		return label
	case "error":
		return "audit error"
	case "blocked":
		return "blocked"
	}
	status := strings.ToLower(strings.TrimSpace(last.Status))
	switch status {
	case "failed":
		return "audit error"
	case "blocked":
		return "blocked"
	}
	return firstNonEmpty(label, status, "unknown")
}

func wrapDetail(prefix, text string, width int, render lipgloss.Style) []string {
	if width <= 0 {
		return []string{render.Render(prefix + text)}
	}
	available := width - lipgloss.Width(prefix)
	if available < 16 {
		return []string{style.Truncate(render.Render(prefix+text), width)}
	}
	words := strings.Fields(text)
	if len(words) == 0 {
		return nil
	}
	lines := []string{}
	current := prefix
	for _, word := range words {
		candidate := current
		if candidate != prefix {
			candidate += " "
		}
		candidate += word
		if lipgloss.Width(candidate) > width && current != prefix {
			lines = append(lines, render.Render(current))
			current = strings.Repeat(" ", lipgloss.Width(prefix)) + word
			continue
		}
		current = candidate
	}
	if strings.TrimSpace(current) != "" {
		lines = append(lines, render.Render(current))
	}
	return lines
}

func wrapLines(lines []string, width int) string {
	if width <= 0 {
		return strings.Join(lines, "\n")
	}
	out := make([]string, len(lines))
	for i, line := range lines {
		out[i] = style.Truncate(line, width)
	}
	return strings.Join(out, "\n")
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
