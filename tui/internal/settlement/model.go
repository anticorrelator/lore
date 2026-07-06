package settlement

import (
	"fmt"
	"strings"
	"time"

	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/style"
)

// DrillMode selects what the panel body shows: the root dashboard or a
// one-level drill-in. Drill-ins stay one level deep so Esc is always "back to
// the queue" — never an ambiguous multi-level pop.
type DrillMode int

const (
	DrillNone DrillMode = iota
	// DrillClaim shows the cursor-selected queue item in full (Enter opens,
	// j/k walk claims, Esc returns).
	DrillClaim
	// DrillVerdict shows one recent verdict in full (v opens, j/k walk
	// verdicts, Esc returns).
	DrillVerdict
)

// Model renders the settlement operational panel — health, posture, trust
// transition, queue (primary region), verdicts, stuck leases — through a
// viewport that owns vertical clipping and scrolling. The host renders View()
// from a discarded model copy, so scroll and drill-in state only change
// inside Update — never on the render path.
type Model struct {
	width         int
	height        int
	status        Status
	hasStatus     bool
	cursor        int
	mode          DrillMode
	verdictCursor int
	vp            viewport.Model
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
	m.clampVerdictCursor()
	if m.mode == DrillVerdict && len(m.orderedVerdicts()) == 0 {
		m.mode = DrillNone
	}
	m.syncContent()
	return m
}

func (m Model) Status() Status {
	return m.status
}

func (m Model) Drill() DrillMode {
	return m.mode
}

// Count is the settlement tab badge: what's waiting (queue.pending).
func (m Model) Count() int {
	if !m.hasStatus || !m.status.Available {
		return 0
	}
	return m.status.Queue.Pending
}

func (m Model) Update(msg tea.Msg) (Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.MouseWheelMsg:
		// Settlement has one scrollable panel; wheel mirrors j/k movement
		// without introducing focus or click semantics.
		switch msg.Button {
		case tea.MouseWheelDown:
			m.moveSelection(1)
		case tea.MouseWheelUp:
			m.moveSelection(-1)
		}

	case tea.KeyPressMsg:
		switch m.mode {
		case DrillClaim:
			switch msg.String() {
			case "esc":
				m.exitDrill()
			case "j", "down":
				m.moveSelection(1)
			case "k", "up":
				m.moveSelection(-1)
			case "pgdown":
				m.vp.HalfPageDown()
			case "pgup":
				m.vp.HalfPageUp()
			}
		case DrillVerdict:
			switch msg.String() {
			case "esc":
				m.exitDrill()
			case "j", "down":
				m.moveSelection(1)
			case "k", "up":
				m.moveSelection(-1)
			case "pgdown":
				m.vp.HalfPageDown()
			case "pgup":
				m.vp.HalfPageUp()
			}
		default:
			switch msg.String() {
			case "enter":
				if m.selectedItem() != nil {
					m.mode = DrillClaim
					m.syncContent()
					m.vp.GotoTop()
				}
			case "v":
				if len(m.orderedVerdicts()) > 0 {
					m.mode = DrillVerdict
					m.verdictCursor = 0
					m.syncContent()
					m.vp.GotoTop()
				}
			case "j", "down":
				m.moveSelection(1)
			case "k", "up":
				m.moveSelection(-1)
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

func (m *Model) moveSelection(delta int) {
	switch m.mode {
	case DrillClaim:
		m.setCursor(m.cursor + delta)
		m.vp.GotoTop()
	case DrillVerdict:
		m.setVerdictCursor(m.verdictCursor + delta)
	default:
		m.setCursor(m.cursor + delta)
	}
}

// exitDrill returns to the root dashboard and scrolls the queue cursor back
// into view so Esc lands where the operator left off.
func (m *Model) exitDrill() {
	m.mode = DrillNone
	m.vp.GotoTop()
	m.setCursor(m.cursor)
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

func (m *Model) setVerdictCursor(target int) {
	m.verdictCursor = target
	m.clampVerdictCursor()
	m.syncContent()
	m.vp.GotoTop()
}

// buildContent renders the active body — the root dashboard or a drill-in —
// without any height fitting; the viewport owns vertical clipping. Returns
// the content lines and the line index of the selected queue row (-1 when
// none is visible).
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

	switch m.mode {
	case DrillClaim:
		return m.claimDrillIn(bodyW, s), -1
	case DrillVerdict:
		return m.verdictDrillIn(bodyW, s), -1
	}

	lines := m.healthRegion(bodyW, s)
	lines = append(lines, m.postureRegion(bodyW, s)...)
	lines = append(lines, m.trustRegion(bodyW, s)...)
	queueLines, cursorOffset := m.queueRegion(bodyW, s)
	cursorLine := -1
	if cursorOffset >= 0 {
		cursorLine = len(lines) + cursorOffset
	}
	lines = append(lines, queueLines...)
	lines = append(lines, m.verdictRegion(bodyW, s)...)
	lines = append(lines, m.stuckLeaseRegion(bodyW, s)...)
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

// healthKeyW aligns the health block's key column.
const healthKeyW = 9

// healthRegion renders the promoted health header: a labeled rule plus a
// self-capped two-column key:value block (queue/drain, oldest/requeue,
// budget/leases). Cells backed by the feed's health block render placeholders
// only when the block is absent (older CLI).
func (m Model) healthRegion(width int, s styleSet) []string {
	st := m.status
	h := st.Health
	colW := width/2 + 4
	if colW < 40 {
		colW = 40
	}

	queueCell := fmt.Sprintf("%d ready · %d pending · %d running · %d blocked · %d total",
		st.Queue.Ready, st.Queue.Pending, st.Queue.Running, st.Queue.Blocked, st.Queue.Total)

	drain := s.placeholder.Render("n/a")
	oldest := s.placeholder.Render("n/a")
	requeue := s.placeholder.Render("n/a")
	if h.Present {
		// completions_24h counts ALL terminal non-invalidated runs (failed and
		// blocked included) — drain throughput, not a success count.
		drain = fmt.Sprintf("~%.1f/h · %d drained 24h", h.DrainRatePerHour, h.Completions24h)
		if h.HasOldestPending {
			oldest = humanizeSeconds(h.OldestPendingAgeSeconds) + " pending"
		} else {
			oldest = s.dim.Render("none pending")
		}
		requeue = fmt.Sprintf("%d today · %d failed", h.RequeuesToday, h.FailuresToday)
		if h.RequeuesToday > 0 || h.FailuresToday > 0 {
			requeue = s.attention.Render(requeue)
		}
	}

	budget := fmt.Sprintf("%d jobs", st.Usage.Started)
	if st.Usage.CapTotal > 0 || st.Usage.CapRemaining > 0 {
		budget += " · runtime " + durationLabel(st.Usage.CapRemaining, st.Usage.CapTotal, s)
	}

	leases := fmt.Sprintf("%d active", st.Harness.ActiveLeases)
	if st.StaleActiveLeases > 0 {
		leases = s.loud.Render(fmt.Sprintf("%d stuck", st.StaleActiveLeases)) + " · " + leases
	}

	lines := []string{
		regionRule("Health", width, s),
		twoCol(kvLine("queue", queueCell, healthKeyW, s), kvLine("drain", drain, healthKeyW, s), colW),
		twoCol(kvLine("oldest", oldest, healthKeyW, s), kvLine("requeue", requeue, healthKeyW, s), colW),
		twoCol(kvLine("budget", budget, healthKeyW, s), kvLine("leases", leases, healthKeyW, s), colW),
	}
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		out = append(out, style.Truncate(line, width))
	}
	return out
}

// postureRegion renders the one-key operational toggles with their state
// visible in place, the spot-sample budget dial beside them (the dial the
// retune verdict tunes), and the next-action / blocked line.
func (m Model) postureRegion(width int, s styleSet) []string {
	st := m.status
	key := func(k string) string { return s.key.Render("[" + k + "]") }

	pausedVal := style.StatusReady.Render("no")
	if !st.Enabled {
		pausedVal = s.loud.Render("YES")
	}

	model := st.AuditorModel
	if model == "" {
		model = s.placeholder.Render("role default")
	}

	parts := []string{
		key("p") + " " + s.dim.Render("paused:") + " " + pausedVal,
		key("s") + " " + s.dim.Render("schedule:") + " " + scheduleValue(st.ActiveHours, s),
		key("m") + " " + s.dim.Render("model:") + " " + model,
		key("x") + " " + s.dim.Render("process once"),
	}
	if st.Dispatch.SpotSample.Present {
		parts = append(parts, s.dim.Render("spot:")+" "+fmt.Sprintf("%d/%d wk",
			st.Dispatch.SpotSample.UsedThisWeek, st.Dispatch.SpotSample.WeeklyBudget))
	}

	lines := []string{
		"",
		regionRule("Posture", width, s),
		style.Truncate(strings.Join(parts, "    "), width),
	}
	if st.BlockedReason != "" {
		lines = append(lines, style.Truncate(s.attention.Render("blocked: "+readableNextAction(st.BlockedReason)), width))
	} else {
		next := readableNextAction(firstNonEmpty(st.NextAction, InferNextAction(st)))
		lines = append(lines, style.Truncate(s.dim.Render("next: "+next), width))
	}
	// A dead holder's expired-but-unreaped lease can hold the pipeline at
	// max_concurrency, which above reads as ordinary saturation. Name it so a
	// stall of this shape reads as a stall: the count is inflated by leases the
	// next process_once will reap.
	if st.StaleActiveLeases > 0 {
		lines = append(lines, style.Truncate(s.attention.Render(fmt.Sprintf(
			"stale leases: %d — reaping on next process", st.StaleActiveLeases)), width))
	}
	return lines
}

// scheduleValue renders the schedule posture: off, on in/out of window, on
// with no windows, or invalid timezone.
func scheduleValue(ah ActiveHours, s styleSet) string {
	if !ah.Present {
		return s.placeholder.Render("unknown")
	}
	if !ah.Enabled {
		return s.placeholder.Render("off")
	}
	if ah.Reason == "active_hours_invalid_timezone" {
		return s.loud.Render("on · invalid timezone")
	}
	if ah.Ranges == 0 {
		return style.StatusReady.Render("on · no windows")
	}
	if ah.Allowed {
		return style.StatusReady.Render("on · in window")
	}
	return s.attention.Render("on · out of window")
}

// trustRegion renders the trust-transition gauges the evaluation-window
// pre-registration names this panel as the live surface for: peer-verify
// volume (held/contradicted), trigger-pump liveness, and dormant-census
// posture. The spot-sample dial renders with the posture controls. Omitted
// entirely when the feed carries none of the sources (older CLI).
func (m Model) trustRegion(width int, s styleSet) []string {
	d := m.status.Dispatch
	if !d.VerifyVolume.Present && !d.Pump.Present && d.Mode == "" {
		return nil
	}
	lines := []string{"", regionRule("Trust transition", width, s)}

	if vv := d.VerifyVolume; vv.Present {
		held, contradicted := 0, 0
		if n := len(vv.Weeks); n > 0 {
			held = vv.Weeks[n-1].Held
			contradicted = vv.Weeks[n-1].Contradicted
		}
		contraCell := fmt.Sprintf("%d contradicted", contradicted)
		if contradicted > 0 {
			contraCell = s.loud.Render(contraCell)
		}
		cell := fmt.Sprintf("%d held · ", held) + contraCell +
			fmt.Sprintf(" last wk · avg %.1f/wk (%dw)", vv.WeeklyAverage, vv.WindowWeeks)
		lines = append(lines, style.Truncate(kvLine("verify", cell, healthKeyW, s), width))
	}

	pumpCell := ""
	if pump := d.Pump; pump.Present {
		switch {
		case pump.HasGap:
			pumpCell = "ran " + humanizeSeconds(pump.SecondsSinceLast) + " ago"
			if pump.SecondsSinceLast > 24*3600 {
				pumpCell = s.attention.Render(pumpCell + " (TUI closed?)")
			}
		default:
			pumpCell = s.dim.Render("never ran (TUI closed?)")
		}
	}
	censusCell := ""
	if d.Mode != "" {
		censusCell = "off"
		if d.CensusEnabled {
			censusCell = "on"
		}
		censusCell += " (" + d.Mode + ")"
	}
	switch {
	case pumpCell != "" && censusCell != "":
		colW := width/2 + 4
		if colW < 40 {
			colW = 40
		}
		lines = append(lines, style.Truncate(
			twoCol(kvLine("pump", pumpCell, healthKeyW, s), kvLine("census", censusCell, healthKeyW, s), colW), width))
	case pumpCell != "":
		lines = append(lines, style.Truncate(kvLine("pump", pumpCell, healthKeyW, s), width))
	case censusCell != "":
		lines = append(lines, style.Truncate(kvLine("census", censusCell, healthKeyW, s), width))
	}
	if len(lines) == 2 {
		return nil
	}
	return lines
}

// queueRegion renders every queue row under a labeled rule; the viewport
// scrolls rows beyond the visible window. The queue is the panel's primary
// region — nothing is previewed or capped. Returns the lines and the index of
// the cursor-selected row within them (-1 when the queue is empty).
func (m Model) queueRegion(width int, s styleSet) ([]string, int) {
	st := m.status
	lines := []string{"", regionRule("Queue", width, s)}
	if len(st.Items) == 0 {
		return append(lines, s.dim.Render("no visible items")), -1
	}
	cursorOffset := -1
	for i, item := range st.Items {
		if i == m.cursor {
			cursorOffset = len(lines)
		}
		lines = append(lines, formatQueueRow(item, width, i == m.cursor, s))
	}
	return lines, cursorOffset
}

// formatQueueRow renders one queue row: status badge, claim-id column, claim
// text. Selected rows render unstyled content inside the selection background
// so the row-wide highlight is not reset mid-line by per-cell colors.
func formatQueueRow(item Item, width int, selected bool, s styleSet) string {
	badge := fmt.Sprintf("%-10s", "["+stringDefault(item.Status, "pending")+"]")
	id := fmt.Sprintf("%-22s", firstNonEmpty(item.ClaimID, item.ID, "claim"))
	tail := item.Claim
	if item.BlockedReason != "" {
		tail += "  ·  blocked: " + item.BlockedReason
	} else if item.NextAction != "" {
		tail += "  ·  next: " + item.NextAction
	}
	if selected {
		return s.selected.Render(style.Truncate("> "+badge+" "+id+" "+tail, width))
	}
	return style.Truncate("  "+queueStatusStyle(item.Status).Render(badge)+" "+id+" "+tail, width)
}

// verdictRegion renders the recent-verdict log: contradictions first and
// loud, everything else dim, capped at four lines with an overflow marker.
// The full verdict text lives in the v drill-in.
func (m Model) verdictRegion(width int, s styleSet) []string {
	verdicts := m.orderedVerdicts()
	lines := []string{"", regionRule("Verdicts", width, s)}
	if len(verdicts) == 0 {
		return append(lines, s.dim.Render("no settled claims yet"))
	}
	limit := 4
	if len(verdicts) < limit {
		limit = len(verdicts)
	}
	for i := 0; i < limit; i++ {
		lines = append(lines, verdictLine(&verdicts[i], width, s))
	}
	if limit < len(verdicts) {
		lines = append(lines, s.dim.Render(fmt.Sprintf("... %d more verdicts", len(verdicts)-limit)))
	}
	return lines
}

// orderedVerdicts partitions recent verdicts contradictions-first; the same
// order backs the root region and the verdict drill-in so j/k in the drill-in
// matches the displayed order.
func (m Model) orderedVerdicts() []LastSettled {
	recent := m.status.RecentSettled
	if len(recent) == 0 && m.status.LastSettled != nil {
		recent = []LastSettled{*m.status.LastSettled}
	}
	out := make([]LastSettled, 0, len(recent))
	for _, v := range recent {
		if verdictLabel(&v) == "contradicted" {
			out = append(out, v)
		}
	}
	for _, v := range recent {
		if verdictLabel(&v) != "contradicted" {
			out = append(out, v)
		}
	}
	return out
}

// verdictLine renders one verdict-log line. Contradictions and audit errors
// read loud (error color, ! marker); everything else recedes into dim.
func verdictLine(v *LastSettled, width int, s styleSet) string {
	label := verdictLabel(v)
	outcome := correctionOutcomeSuffix(v.CorrectionOutcome)
	claim := firstNonEmpty(v.Claim, v.ClaimID, v.ID, "claim")
	if label == "contradicted" || label == "audit error" {
		head := s.loud.Render("! " + fmt.Sprintf("%-22s", label+outcome))
		return style.Truncate(head+"  "+claim, width)
	}
	return style.Truncate(s.dim.Render("  "+fmt.Sprintf("%-22s", label+outcome)+"  "+claim), width)
}

// stuckLeaseRegion auto-expands only when the feed reports stale active
// leases, showing whole expired-lease records loud. Whole records are
// budgeted (one line each) rather than clipped mid-record.
func (m Model) stuckLeaseRegion(width int, s styleSet) []string {
	st := m.status
	if st.StaleActiveLeases <= 0 {
		return nil
	}
	lines := []string{"", regionRule("Stuck lease", width, s)}
	now := time.Now().Unix()
	shown := 0
	for _, lease := range st.Leases {
		if lease.ExpiresAtEpoch > 0 && lease.ExpiresAtEpoch > now {
			continue
		}
		lines = append(lines, s.loud.Render(style.Truncate("! "+formatLease(lease, now), width)))
		shown++
	}
	if shown == 0 {
		// The count says stuck but no lease row identifies itself (alias gap
		// or partial feed) — surface the count rather than an empty region.
		lines = append(lines, s.loud.Render(fmt.Sprintf("! %d stale active lease(s) — records unavailable", st.StaleActiveLeases)))
	}
	return lines
}

func formatLease(lease Lease, nowEpoch int64) string {
	parts := []string{firstNonEmpty(lease.ID, lease.ItemID, "lease")}
	if lease.ItemID != "" {
		parts = append(parts, "item "+lease.ItemID)
	}
	if lease.WorkerID != "" {
		parts = append(parts, "owner "+lease.WorkerID)
	}
	if lease.Harness != "" {
		parts = append(parts, "via "+lease.Harness)
	}
	if lease.PID != 0 {
		parts = append(parts, fmt.Sprintf("pid %d", lease.PID))
	}
	switch {
	case lease.ExpiresAtEpoch > 0 && lease.ExpiresAtEpoch <= nowEpoch:
		parts = append(parts, "expired "+humanizeSeconds(int(nowEpoch-lease.ExpiresAtEpoch))+" ago")
	case lease.ExpiresAt != "":
		parts = append(parts, "expires "+lease.ExpiresAt)
	}
	return strings.Join(parts, "  ·  ")
}

// drillLabelW aligns the drill-in key column.
const drillLabelW = 12

// claimDrillIn renders the cursor-selected queue item in full — wrapped
// whole, nothing truncated mid-sentence.
func (m Model) claimDrillIn(width int, s styleSet) []string {
	sel := m.selectedItem()
	if sel == nil {
		return []string{s.dim.Render("no claim selected")}
	}
	id := firstNonEmpty(sel.ClaimID, sel.ID, "claim")
	head := fmt.Sprintf("Claim %d of %d — %s", m.cursor+1, len(m.status.Items), id)

	statusCell := queueStatusStyle(sel.Status).Render("[" + stringDefault(sel.Status, "pending") + "]")
	if sel.Attempts > 0 {
		statusCell += fmt.Sprintf("  ·  attempt %d", sel.Attempts)
	}
	if sel.Harness != "" {
		statusCell += "  ·  via " + sel.Harness
	}

	lines := []string{
		regionRule(head, width, s),
		kvLine("status", statusCell, drillLabelW, s),
	}
	if sel.WorkItem != "" {
		lines = append(lines, kvLine("work item", sel.WorkItem, drillLabelW, s))
	}
	if sel.ProducerRole != "" {
		producer := sel.ProducerRole
		if sel.TaskID != "" {
			producer += "  ·  task " + sel.TaskID
		}
		lines = append(lines, kvLine("producer", producer, drillLabelW, s))
	}
	if sel.Claim != "" {
		lines = append(lines, "")
		lines = append(lines, wrapIndent("claim", sel.Claim, drillLabelW, width, s)...)
	}
	source := sel.SourceFile
	if sel.LineRange != "" {
		source = strings.TrimSpace(source + ":" + sel.LineRange)
	}
	if source != "" || sel.Falsifier != "" {
		lines = append(lines, "")
	}
	if source != "" {
		lines = append(lines, kvLine("evidence", source, drillLabelW, s))
	}
	if sel.Falsifier != "" {
		lines = append(lines, wrapIndent("falsifier", sel.Falsifier, drillLabelW, width, s)...)
	}
	if sel.BlockedReason != "" {
		lines = append(lines, "", kvLine("blocked", s.attention.Render(sel.BlockedReason), drillLabelW, s))
	}
	return lines
}

// verdictDrillIn renders one recent verdict in full, with its correction
// outcome and artifact refs when present.
func (m Model) verdictDrillIn(width int, s styleSet) []string {
	verdicts := m.orderedVerdicts()
	if len(verdicts) == 0 {
		return []string{s.dim.Render("no settled claims yet")}
	}
	idx := m.verdictCursor
	if idx < 0 {
		idx = 0
	}
	if idx >= len(verdicts) {
		idx = len(verdicts) - 1
	}
	v := verdicts[idx]

	label := verdictLabel(&v)
	labelCell := verdictStyle(label).Render(label)
	if label == "contradicted" || label == "audit error" {
		labelCell = s.loud.Render(label)
	}
	if v.SettledAt != "" {
		labelCell += "  ·  settled " + v.SettledAt
	}

	id := firstNonEmpty(v.ClaimID, v.ID, "verdict")
	lines := []string{
		regionRule(fmt.Sprintf("Verdict %d of %d — %s", idx+1, len(verdicts), id), width, s),
		kvLine("verdict", labelCell, drillLabelW, s),
	}
	source := v.SourceFile
	if v.LineRange != "" {
		source = strings.TrimSpace(source + ":" + v.LineRange)
	}
	if source != "" {
		lines = append(lines, kvLine("evidence", source, drillLabelW, s))
	}
	if v.Claim != "" {
		lines = append(lines, "")
		lines = append(lines, wrapIndent("claim", v.Claim, drillLabelW, width, s)...)
	}
	if v.VerdictSummary != "" {
		lines = append(lines, "")
		lines = append(lines, wrapIndent("summary", v.VerdictSummary, drillLabelW, width, s)...)
	}
	if v.BlockedReason != "" {
		lines = append(lines, "", kvLine("blocked", s.attention.Render(v.BlockedReason), drillLabelW, s))
	}
	if v.CorrectionOutcome.Status != "" {
		lines = append(lines, "", regionRule("Correction", width, s))
		outcomeCell := v.CorrectionOutcome.Status
		switch v.CorrectionOutcome.Status {
		case "applied":
			outcomeCell = style.StatusReady.Render(outcomeCell)
		case "failed":
			outcomeCell = s.loud.Render(outcomeCell)
		}
		if v.CorrectionOutcome.Reason != "" && v.CorrectionOutcome.Reason != v.CorrectionOutcome.Status {
			outcomeCell += "  ·  " + v.CorrectionOutcome.Reason
		}
		lines = append(lines, kvLine("outcome", outcomeCell, drillLabelW, s))
		if v.CorrectionOutcome.TargetEntry != "" {
			lines = append(lines, kvLine("target", v.CorrectionOutcome.TargetEntry, drillLabelW, s))
		}
	}
	if v.RunRef != "" || v.VerdictRef != "" {
		lines = append(lines, "", regionRule("Artifacts", width, s))
		if v.RunRef != "" {
			lines = append(lines, kvLine("run", v.RunRef, drillLabelW, s))
		}
		if v.VerdictRef != "" {
			lines = append(lines, kvLine("verdict", v.VerdictRef, drillLabelW, s))
		}
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

func (m *Model) clampVerdictCursor() {
	max := len(m.orderedVerdicts()) - 1
	if max < 0 {
		m.verdictCursor = 0
		return
	}
	if m.verdictCursor < 0 {
		m.verdictCursor = 0
	}
	if m.verdictCursor > max {
		m.verdictCursor = max
	}
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
	loud        lipgloss.Style
}

// panelStyles is allocated once at package init; warn, selected, and loud
// compose widget-local Bold onto the canonical palette roles (no shared
// *style* primitive carries those compositions), the rest alias the canonical
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
	loud:        style.StatusError.Bold(true),
}

// noStyle is the identity style for values that render uncolored; allocated
// once so render paths never construct styles per frame.
var noStyle = lipgloss.NewStyle()

func styles() styleSet {
	return panelStyles
}

// regionRule renders a section header as a labeled horizontal rule
// (─ Label ───…) so each panel region reads as a visually distinct block.
func regionRule(label string, width int, s styleSet) string {
	text := " " + label + " "
	if width <= lipgloss.Width(text)+2 {
		return s.heading.Render(label)
	}
	return s.rule.Render("─") +
		s.heading.Render(text) +
		s.rule.Render(strings.Repeat("─", width-lipgloss.Width(text)-1))
}

// kvLine renders a dim right-padded key followed by its value, for aligned
// key:value dashboard blocks.
func kvLine(key, value string, keyW int, s styleSet) string {
	pad := keyW - lipgloss.Width(key+":")
	if pad < 1 {
		pad = 1
	}
	return s.dim.Render(key+":") + strings.Repeat(" ", pad) + value
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
func wrapIndent(label, text string, labelW, width int, s styleSet) []string {
	head := s.dim.Render(label+":") + strings.Repeat(" ", labelW-lipgloss.Width(label+":"))
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

// queueStatusStyle maps a queue-item status onto the shared status ramp;
// statuses outside the ramp render uncolored.
func queueStatusStyle(status string) lipgloss.Style {
	switch strings.ToLower(strings.TrimSpace(status)) {
	case "ready":
		return style.StatusReady
	case "running", "leased":
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

// humanizeSeconds renders an age in its largest useful unit (3d, 4h, 12m, 30s).
func humanizeSeconds(seconds int) string {
	if seconds < 0 {
		seconds = 0
	}
	switch {
	case seconds >= 86400:
		return fmt.Sprintf("%dd", seconds/86400)
	case seconds >= 3600:
		return fmt.Sprintf("%dh", seconds/3600)
	case seconds >= 60:
		return fmt.Sprintf("%dm", seconds/60)
	}
	return fmt.Sprintf("%ds", seconds)
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

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
