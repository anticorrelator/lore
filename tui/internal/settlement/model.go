package settlement

import (
	"fmt"
	"strings"

	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/style"
)

// Model renders the settlement operational panel (header, queue,
// selected-claim, verdicts, leases) through a viewport that owns vertical
// clipping and scrolling. The host renders View() from a discarded model
// copy, so scroll state only changes inside Update — never on the render
// path.
type Model struct {
	width     int
	height    int
	status    Status
	hasStatus bool
	cursor    int
	vp        viewport.Model
}

func NewModel() Model {
	return Model{status: Unavailable("status not loaded"), vp: viewport.New()}
}

func (m Model) SetSize(width, height int) Model {
	m.width = width
	m.height = height
	m.clampCursor()
	m.syncContent()
	return m
}

func (m Model) ReplaceStatus(status Status) Model {
	m.status = status
	m.hasStatus = true
	m.clampCursor()
	m.syncContent()
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
			m.setCursor(m.cursor + 1)
		case "k", "up":
			m.setCursor(m.cursor - 1)
		case "pgdown":
			m.vp.HalfPageDown()
		case "pgup":
			m.vp.HalfPageUp()
		case "home":
			m.setCursor(0)
			m.vp.GotoTop()
		case "end":
			m.setCursor(len(m.status.Items) - 1)
		}
	}
	return m, nil
}

func (m Model) View() string {
	if m.height <= 0 {
		lines, _ := m.buildContent()
		return strings.Join(lines, "\n")
	}
	return m.vp.View()
}

// syncContent rebuilds the panel content into the viewport and returns the
// line index of the cursor-selected queue row (-1 when nothing is selected).
// The viewport clamps its own offset when content shrinks.
func (m *Model) syncContent() int {
	lines, cursorLine := m.buildContent()
	m.vp.SetWidth(bodyWidth(m.width))
	m.vp.SetHeight(m.height)
	m.vp.SetContentLines(lines)
	return cursorLine
}

// setCursor moves the queue selection and scrolls the viewport just far
// enough to keep the selected row visible.
func (m *Model) setCursor(target int) {
	m.cursor = target
	m.clampCursor()
	cursorLine := m.syncContent()
	if cursorLine < 0 || m.height <= 0 {
		return
	}
	if cursorLine < m.vp.YOffset() {
		m.vp.SetYOffset(cursorLine)
	} else if cursorLine >= m.vp.YOffset()+m.height {
		m.vp.SetYOffset(cursorLine - m.height + 1)
	}
}

// buildContent renders the full operational panel — header, queue,
// selected-claim, verdicts, leases — without any height fitting; the
// viewport owns vertical clipping. Returns the content lines and the line
// index of the selected queue row (-1 when nothing is selected).
func (m Model) buildContent() ([]string, int) {
	bodyW := bodyWidth(m.width)
	s := styles()
	st := m.status
	if !m.hasStatus || !st.Available {
		msg := stringDefault(st.Message, "settlement status unavailable")
		return []string{
			s.warn.Render("status unavailable"),
			style.Truncate(msg, bodyW),
			"",
			style.Truncate(s.dim.Render("The panel will update when `lore settlement status --json` is available."), bodyW),
		}, -1
	}

	lines := m.headerRegion(bodyW, s)
	queueLines, cursorOffset := m.queueRegion(bodyW, s)
	cursorLine := -1
	if cursorOffset >= 0 {
		cursorLine = len(lines) + cursorOffset
	}
	lines = append(lines, queueLines...)
	lines = append(lines, m.selectedClaimBlock(bodyW, s)...)
	lines = append(lines, "", regionRule("Recent verdicts", bodyW, s))
	lines = append(lines, formatRecentSettled(st, bodyW, s)...)
	lines = append(lines, leaseRegion(st, bodyW, s)...)
	return lines, cursorLine
}

// bodyWidth converts the host-provided panel width into the content line
// width, leaving room for the host's leading pad and border columns.
func bodyWidth(width int) int {
	if width <= 0 {
		width = 80
	}
	bodyW := width - 4
	if bodyW < 24 {
		bodyW = 24
	}
	return bodyW
}

// headerRegion renders the compact operational-status dashboard: a labeled
// rule plus a fixed three-row summary and an optional blocked row. State and
// placeholder values carry status-ramp colors so "enabled" reads ready,
// "disabled" demands attention, and default-unset values recede.
func (m Model) headerRegion(width int, s styleSet) []string {
	st := m.status
	state := s.ready.Render("enabled")
	if !st.Enabled {
		state = s.attention.Render("disabled")
	}
	nextAction := readableNextAction(firstNonEmpty(st.BlockedReason, st.NextAction, InferNextAction(st)))
	lines := []string{
		regionRule("Operational status", width, s),
		strings.Join([]string{
			"state: " + state,
			"budget: " + orPlaceholder(st.Usage.BudgetState, "unknown", s),
			"runtime left: " + durationLabel(st.Harness.CapRemaining, st.Harness.CapTotal, s),
		}, "  |  "),
		strings.Join([]string{
			"queue: " + queueLabel(st.Queue),
			"leases: " + fmt.Sprintf("%d active", st.Harness.ActiveLeases),
		}, "  |  "),
		strings.Join([]string{
			"harness: " + harnessLabel(st.Harness, s),
			"next: " + nextAction,
		}, "  |  "),
	}
	if st.BlockedReason != "" {
		lines = append(lines, s.attention.Render("blocked "+st.BlockedReason))
	}
	return lines
}

// queueRegion renders every queue row under a labeled rule; the viewport
// scrolls rows beyond the visible window. Returns the lines and the index of
// the cursor-selected row within them (-1 when the queue is empty).
func (m Model) queueRegion(width int, s styleSet) ([]string, int) {
	st := m.status
	lines := []string{"", regionRule("Settlement queue", width, s)}
	if len(st.Items) == 0 {
		return append(lines, s.dim.Render("no visible items")), -1
	}
	cursorOffset := -1
	for i, item := range st.Items {
		line := formatItem(" ", item, width, queueStatusStyle(item.Status))
		if i == m.cursor {
			// The selection background owns the row; inner status colors
			// would reset it mid-line, so the selected row renders unstyled
			// inside the highlight.
			line = s.selected.Render(formatItem(">", item, width, noStyle))
			cursorOffset = len(lines)
		}
		lines = append(lines, line)
	}
	return lines, cursorOffset
}

// leaseRegion renders the active-lease block (labeled rule plus at most two
// leases). Nil when no leases are held so the empty section is omitted.
func leaseRegion(st Status, width int, s styleSet) []string {
	if len(st.Leases) == 0 {
		return nil
	}
	lines := []string{"", regionRule("Active leases", width, s)}
	for _, lease := range compactLeases(st.Leases) {
		lines = append(lines, formatLease(lease, width, s))
	}
	return lines
}

func (m *Model) clampCursor() {
	max := len(m.status.Items) - 1
	if max < 0 {
		m.cursor = 0
		return
	}
	if m.cursor < 0 {
		m.cursor = 0
	}
	if m.cursor > max {
		m.cursor = max
	}
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
	out = append(out, "", regionRule("Selected claim", width, s))
	out = append(out, block...)
	return out
}

func (m Model) selectedItem() *Item {
	if len(m.status.Items) == 0 || m.cursor < 0 || m.cursor >= len(m.status.Items) {
		return nil
	}
	return &m.status.Items[m.cursor]
}

type styleSet struct {
	heading     lipgloss.Style
	rule        lipgloss.Style
	dim         lipgloss.Style
	warn        lipgloss.Style
	key         lipgloss.Style
	selected    lipgloss.Style
	ready       lipgloss.Style
	attention   lipgloss.Style
	placeholder lipgloss.Style
}

// panelStyles is allocated once at package init; warn and selected compose
// widget-local Bold onto the canonical palette roles (no shared *style*
// primitive carries those compositions), the rest alias the canonical
// primitives directly.
var panelStyles = styleSet{
	heading:     style.SubsectionTitle,
	rule:        style.SectionRule,
	dim:         style.Dim,
	warn:        lipgloss.NewStyle().Foreground(style.ColorWarn).Bold(true),
	key:         style.KeyHint,
	selected:    lipgloss.NewStyle().Background(style.ColorSelectionBg).Bold(true),
	ready:       style.StatusReady,
	attention:   style.StatusWarn,
	placeholder: style.StatusDisabled,
}

// noStyle is the identity style for values that render uncolored; allocated
// once so render paths never construct styles per frame.
var noStyle = lipgloss.NewStyle()

func styles() styleSet {
	return panelStyles
}

// regionRule renders a section header as a labeled horizontal rule
// (─ Label ───…) so each panel region reads as a visually distinct block,
// matching the host's Settings-dock separator idiom.
func regionRule(label string, width int, s styleSet) string {
	text := " " + label + " "
	if width <= lipgloss.Width(text)+2 {
		return s.heading.Render(label)
	}
	return s.rule.Render("─") +
		s.heading.Render(text) +
		s.rule.Render(strings.Repeat("─", width-lipgloss.Width(text)-1))
}

// queueStatusStyle maps a queue-item status onto the shared status ramp;
// statuses outside the ramp render uncolored.
func queueStatusStyle(status string) lipgloss.Style {
	switch strings.ToLower(strings.TrimSpace(status)) {
	case "ready":
		return style.StatusReady
	case "running":
		return style.StatusActive
	case "blocked", "failed":
		return style.StatusError
	case "completed", "settled":
		return style.StatusDone
	}
	return noStyle
}

// verdictStyle maps a normalized verdict label (verdictLabel output) onto the
// shared status ramp; unknown labels render uncolored.
func verdictStyle(label string) lipgloss.Style {
	switch label {
	case "verified":
		return style.StatusReady
	case "contradicted", "audit error":
		return style.StatusError
	case "unverified", "blocked":
		return style.StatusWarn
	}
	return noStyle
}

// orPlaceholder returns value when set, otherwise the fallback rendered in
// the default-unset style so placeholder values never read as configured
// ones (or as disabled state, which carries the attention color).
func orPlaceholder(value, fallback string, s styleSet) string {
	if value != "" {
		return value
	}
	return s.placeholder.Render(fallback)
}

func row(label, value string) string {
	return fmt.Sprintf("%-15s %s", label+":", value)
}

func queueLabel(q Queue) string {
	return fmt.Sprintf("ready %d, pending %d, running %d, total %d",
		q.Ready, q.Pending, q.Running, q.Total)
}

func harnessLabel(h Harness, s styleSet) string {
	selected := orPlaceholder(h.Selected, "active", s)
	mode := orPlaceholder(h.Mode, "default", s)
	return fmt.Sprintf("%s (%s), concurrency %s", selected, mode, intLabel(h.Concurrency, s))
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

func durationLabel(remaining, total int, s styleSet) string {
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
	return s.placeholder.Render("unlimited")
}

func yesNo(v bool) string {
	if v {
		return "yes"
	}
	return "no"
}

func intLabel(v int, s styleSet) string {
	if v == 0 {
		return s.placeholder.Render("unlimited")
	}
	return fmt.Sprintf("%d", v)
}

func formatItem(marker string, item Item, width int, statusS lipgloss.Style) string {
	claim := firstNonEmpty(item.Claim, item.ClaimID, item.ID, "claim")
	parts := []string{marker}
	if item.Status != "" {
		parts = append(parts, statusS.Render("["+item.Status+"]"))
	}
	parts = append(parts, claim)
	if item.BlockedReason != "" {
		parts = append(parts, "blocked: "+item.BlockedReason)
	} else if item.NextAction != "" {
		parts = append(parts, "next: "+item.NextAction)
	}
	return style.Truncate(strings.Join(parts, " "), width)
}

// formatRecentSettled renders up to four recent verdicts, wrapped whole;
// verdicts beyond that compactness cap are summarized by the
// "... N more verdicts" marker.
func formatRecentSettled(st Status, width int, s styleSet) []string {
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
	for i := 0; i < limit; i++ {
		lines = append(lines, formatLastSettled(&recent[i], width, s)...)
	}
	if limit < len(recent) {
		lines = append(lines, s.dim.Render(fmt.Sprintf("... %d more verdicts", len(recent)-limit)))
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
	prefix := "- " + verdictStyle(label).Render(label) + correctionOutcomeSuffix(last.CorrectionOutcome) + "  "
	return wrapDetail(prefix, claim, width, noStyle)
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

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
