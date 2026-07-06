package settlement

import (
	"fmt"
	"strconv"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/style"
)

// stripANSI removes SGR escape sequences; lipgloss v2 styles output even
// without a TTY, so plain-substring assertions must run on stripped text.
func stripANSI(s string) string {
	var b strings.Builder
	inEsc := false
	for _, r := range s {
		if r == 0x1b {
			inEsc = true
			continue
		}
		if inEsc {
			if r == 'm' {
				inEsc = false
			}
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

func TestParseStatusToleratesExpectedContract(t *testing.T) {
	data := []byte(`{
		"enabled": true,
		"queue": {"ready": 2, "pending": 1, "running": 1, "completed": 3, "failed": 1, "blocked": 1, "total": 8},
		"items": [
			{"id": "row-1", "work_item": "settlement-operational-closure", "claim_id": "claim-a", "task_id": "task-2", "producer_role": "worker", "status": "ready", "harness": "codex"},
			{"id": "row-2", "work_item": "settlement-operational-closure", "claim_id": "claim-b", "status": "blocked", "blocked_reason": "cap exhausted"}
		],
		"leases": [
			{"id": "lease-1", "item_id": "row-3", "worker_id": "proc-a", "harness": "codex", "pid": 1234, "expires_at": "2026-05-09T12:00:00Z"}
		],
		"harness": {"mode": "random", "selected": "codex", "random": true, "concurrency": 2, "launch_rate_per_minute": 6, "cap_remaining": 9, "cap_total": 10},
		"usage": {"state": "normal", "rate_remaining": 4, "started": 1},
		"batch": {"id": "batch-1", "size": 12, "backlog_size": 76, "recompute_reason": "process_once", "recomputed_at": "2026-05-11T05:10:23Z"},
		"last_settled": {"id": "row-0", "claim_id": "claim-z", "status": "completed", "result": {"verdict_label": "accepted", "summary": "claim held up"}},
		"next_action": "process once or wait"
	}`)

	st, err := ParseStatus(data)
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	if !st.Enabled {
		t.Fatalf("state parsed incorrectly: enabled=%v", st.Enabled)
	}
	if st.Queue.Total != 8 || st.Queue.Ready != 2 || st.Queue.Pending != 1 || st.Queue.Running != 1 {
		t.Fatalf("queue parsed incorrectly: %+v", st.Queue)
	}
	if st.Queue.Complete != 3 || st.Queue.Failed != 1 || st.Queue.Blocked != 1 {
		t.Fatalf("queue parser should tolerate legacy completed/failed/blocked keys, got %+v", st.Queue)
	}
	if len(st.Items) != 2 || st.Items[0].ClaimID != "claim-a" || st.Items[1].BlockedReason != "cap exhausted" {
		t.Fatalf("items parsed incorrectly: %+v", st.Items)
	}
	if len(st.Leases) != 1 || st.Leases[0].WorkerID != "proc-a" || st.Harness.ActiveLeases != 1 {
		t.Fatalf("leases parsed incorrectly: leases=%+v harness=%+v", st.Leases, st.Harness)
	}
	if st.Harness.Mode != "random" || !st.Harness.Random || st.Harness.Concurrency != 2 {
		t.Fatalf("harness parsed incorrectly: %+v", st.Harness)
	}
	if st.Usage.BudgetState != "normal" || st.Usage.RateRemaining != 4 {
		t.Fatalf("usage parsed incorrectly: %+v", st.Usage)
	}
	if st.Batch.ID != "batch-1" || st.Batch.BacklogSize != 76 {
		t.Fatalf("batch parsed incorrectly: %+v", st.Batch)
	}
	if st.LastSettled == nil || st.LastSettled.ClaimID != "claim-z" || st.LastSettled.VerdictLabel != "accepted" || st.LastSettled.VerdictSummary != "claim held up" {
		t.Fatalf("last_settled parsed incorrectly: %+v", st.LastSettled)
	}
}

func TestParseStatusCarriesTerminalVerdicts(t *testing.T) {
	data := []byte(`{
		"enabled": true,
		"terminal_items": [
			{
				"id": "terminal-1",
				"run_id": "run-1",
				"claim_id": "claim-a",
				"work_item": "wi",
				"status": "completed",
				"verdict": {"verdict": "contradicted", "evidence": "file changed", "correction": "update the claim"}
			},
			{
				"id": "terminal-2",
				"claim_id": "claim-b",
				"status": "completed",
				"result": {"verdict": {"verdict": "verified", "evidence": "fixture matched"}}
			}
		]
	}`)

	st, err := ParseStatus(data)
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	if len(st.RecentSettled) != 2 {
		t.Fatalf("RecentSettled len = %d, want 2", len(st.RecentSettled))
	}
	if st.LastSettled == nil || st.LastSettled.VerdictLabel != "contradicted" || st.LastSettled.VerdictSummary != "file changed" || st.LastSettled.Correction != "update the claim" {
		t.Fatalf("terminal verdict not parsed into LastSettled: %+v", st.LastSettled)
	}
}

func TestParseStatusInfersNextActionFromDrainedBatchBacklog(t *testing.T) {
	// The drained-batch backlog only implies dispatchable work under the
	// dormant census posture; event-driven queues do not auto-refill from it.
	st, err := ParseStatus([]byte(`{
		"enabled": true,
		"dispatch": {"mode": "census", "census_enabled": true},
		"queue": {"pending": 0, "running": 0, "total": 0},
		"batch": {"backlog_size": 76},
		"harness": {"concurrency": 1}
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	if st.NextAction != "process once or wait for processor" {
		t.Fatalf("NextAction = %q", st.NextAction)
	}
}

func TestParseStatusCarriesHealthAndTrustFields(t *testing.T) {
	st, err := ParseStatus([]byte(`{
		"enabled": true,
		"auditor_model": "sonnet",
		"stale_active_leases": 1,
		"health": {
			"drain_rate_per_hour": 8.5,
			"completions_24h": 204,
			"oldest_pending_age_seconds": 259200,
			"requeues_today": 1,
			"failures_today": 0
		},
		"active_hours": {"enabled": true, "allowed": false, "reason": "outside_active_hours", "timezone": "America/Los_Angeles", "ranges": [{"days": ["mon"], "start": "09:00", "end": "18:00"}]},
		"dispatch": {
			"mode": "event-driven",
			"census_enabled": false,
			"spot_sample": {"weekly_budget": 10, "used_this_week": 3},
			"verify_volume": {
				"window_weeks": 8,
				"weekly_average": 9.5,
				"current_week_events": 4,
				"weeks": [
					{"week_start": "2026-06-22T00:00:00Z", "events": 12, "held": 10, "contradicted": 2}
				]
			},
			"pump": {"last_ran_at": "2026-07-04T09:00:00Z", "seconds_since_last": 240}
		},
		"leases": [
			{"id": "lease-1", "item_id": "row-1", "holder": "pid-4242", "expires_at_epoch": 1780000000}
		]
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	if !st.Health.Present || st.Health.DrainRatePerHour != 8.5 || st.Health.Completions24h != 204 {
		t.Fatalf("health parsed incorrectly: %+v", st.Health)
	}
	if !st.Health.HasOldestPending || st.Health.OldestPendingAgeSeconds != 259200 {
		t.Fatalf("oldest pending parsed incorrectly: %+v", st.Health)
	}
	if st.Health.RequeuesToday != 1 || st.Health.FailuresToday != 0 {
		t.Fatalf("requeue/failure counters parsed incorrectly: %+v", st.Health)
	}
	if st.AuditorModel != "sonnet" || st.StaleActiveLeases != 1 {
		t.Fatalf("auditor_model/stale_active_leases parsed incorrectly: %q %d", st.AuditorModel, st.StaleActiveLeases)
	}
	if !st.ActiveHours.Present || !st.ActiveHours.Enabled || st.ActiveHours.Allowed || st.ActiveHours.Reason != "outside_active_hours" || st.ActiveHours.Ranges != 1 {
		t.Fatalf("active_hours parsed incorrectly: %+v", st.ActiveHours)
	}
	if !st.Dispatch.SpotSample.Present || st.Dispatch.SpotSample.WeeklyBudget != 10 || st.Dispatch.SpotSample.UsedThisWeek != 3 {
		t.Fatalf("spot_sample parsed incorrectly: %+v", st.Dispatch.SpotSample)
	}
	vv := st.Dispatch.VerifyVolume
	if !vv.Present || vv.WindowWeeks != 8 || vv.WeeklyAverage != 9.5 || vv.CurrentWeekEvents != 4 {
		t.Fatalf("verify_volume parsed incorrectly: %+v", vv)
	}
	if len(vv.Weeks) != 1 || vv.Weeks[0].Events != 12 || vv.Weeks[0].Held != 10 || vv.Weeks[0].Contradicted != 2 {
		t.Fatalf("verify_volume weeks split parsed incorrectly: %+v", vv.Weeks)
	}
	if !st.Dispatch.Pump.Present || !st.Dispatch.Pump.HasGap || st.Dispatch.Pump.SecondsSinceLast != 240 || st.Dispatch.Pump.LastRanAt != "2026-07-04T09:00:00Z" {
		t.Fatalf("pump parsed incorrectly: %+v", st.Dispatch.Pump)
	}
	if len(st.Leases) != 1 || st.Leases[0].WorkerID != "pid-4242" || st.Leases[0].ExpiresAtEpoch != 1780000000 {
		t.Fatalf("lease holder/expires_at_epoch aliases parsed incorrectly: %+v", st.Leases)
	}
}

func TestParseStatusNullOldestPendingAndAbsentPumpGap(t *testing.T) {
	st, err := ParseStatus([]byte(`{
		"enabled": true,
		"health": {"drain_rate_per_hour": 0, "completions_24h": 0, "oldest_pending_age_seconds": null, "requeues_today": 0, "failures_today": 0},
		"dispatch": {"mode": "event-driven", "census_enabled": false, "pump": {"last_ran_at": null, "seconds_since_last": null}}
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	if !st.Health.Present || st.Health.HasOldestPending {
		t.Fatalf("null oldest_pending_age_seconds must parse as no-pending, got %+v", st.Health)
	}
	if !st.Dispatch.Pump.Present || st.Dispatch.Pump.HasGap || st.Dispatch.Pump.LastRanAt != "" {
		t.Fatalf("null pump fields must parse as never-ran, got %+v", st.Dispatch.Pump)
	}
}

func TestParseStatusEventDrivenBacklogIsIdle(t *testing.T) {
	st, err := ParseStatus([]byte(`{
		"enabled": true,
		"queue": {"pending": 0, "running": 0, "total": 0},
		"batch": {"backlog_size": 76},
		"harness": {"concurrency": 1}
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	if st.Dispatch.CensusEnabled {
		t.Fatalf("absent dispatch block must parse as census_enabled=false")
	}
	if st.NextAction != "idle" {
		t.Fatalf("NextAction = %q, want idle (backlog is not dispatchable without the census)", st.NextAction)
	}
}

func TestParseStatusFallsBackToTerminalItemsForLastSettled(t *testing.T) {
	data := []byte(`{
		"enabled": true,
		"terminal_items": [
			{"id": "terminal-1", "claim_id": "claim-old", "status": "blocked", "result": {"verdict_label": "needs operator", "blocked_reason": "missing evidence"}}
		]
	}`)

	st, err := ParseStatus(data)
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	if st.LastSettled == nil {
		t.Fatal("expected terminal_items fallback to populate LastSettled")
	}
	if st.LastSettled.ID != "terminal-1" || st.LastSettled.ClaimID != "claim-old" {
		t.Fatalf("fallback identity parsed incorrectly: %+v", st.LastSettled)
	}
	if st.LastSettled.Status != "blocked" || st.LastSettled.VerdictLabel != "needs operator" || st.LastSettled.BlockedReason != "missing evidence" {
		t.Fatalf("fallback verdict parsed incorrectly: %+v", st.LastSettled)
	}
}

func TestParseActionResultWithNestedStatus(t *testing.T) {
	data := []byte(`{
		"action": "process",
		"ok": true,
		"message": "processed",
		"status": {"enabled": true, "queue": {"pending": 2}}
	}`)

	result, err := ParseActionResult("process", data)
	if err != nil {
		t.Fatalf("ParseActionResult: %v", err)
	}
	if result.Action != "process" || !result.OK || result.Message != "processed" {
		t.Fatalf("result parsed incorrectly: %+v", result)
	}
	if result.Status == nil || result.Status.Queue.Pending != 2 {
		t.Fatalf("nested status parsed incorrectly: %+v", result.Status)
	}
}

func TestParseActionResultSurfacesNoDispatchReason(t *testing.T) {
	data := []byte(`{"dispatched": false, "ok": true, "reason": "disabled"}`)

	result, err := ParseActionResult("process", data)
	if err != nil {
		t.Fatalf("ParseActionResult: %v", err)
	}
	if result.Action != "process" || !result.OK {
		t.Fatalf("result parsed incorrectly: %+v", result)
	}
	if result.Dispatched == nil || *result.Dispatched {
		t.Fatalf("expected dispatched=false, got %+v", result.Dispatched)
	}
	if result.Reason != "disabled" {
		t.Fatalf("reason = %q, want disabled", result.Reason)
	}
	if result.Message != "not dispatched: disabled" {
		t.Fatalf("message = %q", result.Message)
	}
}

func TestModelReplacesMultiInstanceSnapshots(t *testing.T) {
	m := NewModel()
	first, err := ParseStatus([]byte(`{
		"enabled": true,
		"queue": {"pending": 1},
		"items": [{"id": "old", "status": "ready"}],
		"leases": [{"id": "old-lease", "item_id": "old"}]
	}`))
	if err != nil {
		t.Fatalf("ParseStatus first: %v", err)
	}
	second, err := ParseStatus([]byte(`{
		"enabled": true,
		"queue": {"pending": 2},
		"items": [{"id": "new", "status": "ready"}, {"id": "new-2", "status": "pending"}],
		"leases": [{"id": "new-lease", "item_id": "new"}]
	}`))
	if err != nil {
		t.Fatalf("ParseStatus second: %v", err)
	}

	m = m.ReplaceStatus(first)
	m = m.ReplaceStatus(second)

	st := m.Status()
	if len(st.Items) != 2 || st.Items[0].ID != "new" {
		t.Fatalf("items should be replaced by second snapshot, got %+v", st.Items)
	}
	if len(st.Leases) != 1 || st.Leases[0].ID != "new-lease" {
		t.Fatalf("leases should be replaced by second snapshot, got %+v", st.Leases)
	}
	view := stripANSI(m.SetSize(100, 30).View())
	if strings.Contains(view, " old ") || strings.Contains(view, "old-lease") {
		t.Fatalf("view contains stale first snapshot data: %s", view)
	}
}

func TestModelReadableViewClipsViaViewport(t *testing.T) {
	st, err := ParseStatus([]byte(`{
		"enabled": true,
		"queue": {"pending": 5, "total": 5},
		"items": [
			{"id": "item-1", "status": "pending", "work_item": "settlement-operational-closure"},
			{"id": "item-2", "status": "pending", "work_item": "settlement-operational-closure"},
			{"id": "item-3", "status": "pending", "work_item": "settlement-operational-closure"},
			{"id": "item-4", "status": "pending", "work_item": "settlement-operational-closure"},
			{"id": "item-5", "status": "pending", "work_item": "settlement-operational-closure"}
		],
		"harness": {"mode": "random", "selected": "claude-code", "concurrency": 1, "cap_remaining": 30, "cap_total": 30},
		"usage": {"state": "ok"},
		"next_action": "process once or wait for processor"
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}

	m := NewModel().ReplaceStatus(st).SetSize(120, 9)
	view := stripANSI(m.View())
	if got := len(strings.Split(view, "\n")); got != 9 {
		t.Fatalf("viewport should clip the view to exactly 9 lines, got %d:\n%s", got, view)
	}
	if !strings.Contains(view, "next: process once or wait for processor") {
		t.Fatalf("posture should keep the next action readable, got:\n%s", view)
	}
	if !strings.Contains(view, "0 ready · 5 pending · 0 running · 0 blocked · 5 total") {
		t.Fatalf("health should render the queue summary cell, got:\n%s", view)
	}
	if strings.Contains(view, "no settled claims yet") {
		t.Fatalf("verdict placeholder should start below the 9-line fold, got:\n%s", view)
	}

	// The regions below the fold scroll into view instead of being squeezed
	// into a height budget.
	for i := 0; i < 4; i++ {
		m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyPgDown})
	}
	view = stripANSI(m.View())
	if got := len(strings.Split(view, "\n")); got != 9 {
		t.Fatalf("scrolled viewport should still clip to 9 lines, got %d:\n%s", got, view)
	}
	if !strings.Contains(view, "Verdicts") || !strings.Contains(view, "no settled claims yet") {
		t.Fatalf("scrolling should reveal the verdict region and placeholder, got:\n%s", view)
	}
}

func TestModelUsesTallStatusSpaceForQueuePreview(t *testing.T) {
	st, err := ParseStatus([]byte(`{
		"enabled": true,
		"queue": {"pending": 8, "total": 8},
		"items": [
			{"id": "item-1", "status": "pending"},
			{"id": "item-2", "status": "pending"},
			{"id": "item-3", "status": "pending"},
			{"id": "item-4", "status": "pending"},
			{"id": "item-5", "status": "pending"},
			{"id": "item-6", "status": "pending"},
			{"id": "item-7", "status": "pending"},
			{"id": "item-8", "status": "pending"}
		]
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}

	view := NewModel().ReplaceStatus(st).SetSize(120, 18).View()
	if !strings.Contains(view, "item-8") {
		t.Fatalf("tall settlement status area should expose more queue rows, got:\n%s", view)
	}
}

func TestParseStatusCarriesCorrectionOutcome(t *testing.T) {
	data := []byte(`{
		"enabled": true,
		"terminal_items": [
			{
				"id": "terminal-applied",
				"run_id": "run-1",
				"claim_id": "claim-a",
				"status": "completed",
				"verdict": {"verdict": "contradicted", "evidence": "drift", "correction": "fix"},
				"correction_outcome": {"status": "applied", "reason": "applied", "target_entry": "conventions/foo.md"}
			},
			{
				"id": "terminal-skipped",
				"run_id": "run-2",
				"claim_id": "claim-b",
				"status": "completed",
				"verdict": {"verdict": "contradicted", "evidence": "drift", "correction": "fix"},
				"correction_outcome": {"status": "skipped", "reason": "no_commons_target"}
			},
			{
				"id": "terminal-legacy",
				"run_id": "run-3",
				"claim_id": "claim-c",
				"status": "completed",
				"verdict": {"verdict": "verified", "evidence": "matched"}
			}
		]
	}`)

	st, err := ParseStatus(data)
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	if len(st.RecentSettled) != 3 {
		t.Fatalf("RecentSettled len = %d, want 3", len(st.RecentSettled))
	}
	applied := st.RecentSettled[0]
	if applied.CorrectionOutcome.Status != "applied" || applied.CorrectionOutcome.Reason != "applied" || applied.CorrectionOutcome.TargetEntry != "conventions/foo.md" {
		t.Fatalf("applied row parsed incorrectly: %+v", applied.CorrectionOutcome)
	}
	skipped := st.RecentSettled[1]
	if skipped.CorrectionOutcome.Status != "skipped" || skipped.CorrectionOutcome.Reason != "no_commons_target" {
		t.Fatalf("skipped row parsed incorrectly: %+v", skipped.CorrectionOutcome)
	}
	legacy := st.RecentSettled[2]
	if legacy.CorrectionOutcome != (CorrectionOutcome{}) {
		t.Fatalf("legacy row should have zero-value CorrectionOutcome, got %+v", legacy.CorrectionOutcome)
	}
}

func TestModelRendersCorrectionOutcomeSuffix(t *testing.T) {
	data := []byte(`{
		"enabled": true,
		"queue": {"total": 0},
		"terminal_items": [
			{"id": "t1", "claim_id": "claim-a", "claim": "applied claim text", "status": "completed", "verdict": {"verdict": "contradicted", "evidence": "drift"}, "correction_outcome": {"status": "applied", "reason": "applied", "target_entry": "conventions/x.md"}},
			{"id": "t2", "claim_id": "claim-b", "claim": "skipped claim text", "status": "completed", "verdict": {"verdict": "contradicted", "evidence": "drift"}, "correction_outcome": {"status": "skipped", "reason": "not_mechanically_applicable"}},
			{"id": "t3", "claim_id": "claim-c", "claim": "failed claim text", "status": "completed", "verdict": {"verdict": "contradicted", "evidence": "drift"}, "correction_outcome": {"status": "failed", "reason": "apply_unexpected_exit"}},
			{"id": "t4", "claim_id": "claim-d", "claim": "verified claim text", "status": "completed", "verdict": {"verdict": "verified", "evidence": "matched"}}
		]
	}`)
	st, err := ParseStatus(data)
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	view := stripANSI(NewModel().ReplaceStatus(st).SetSize(200, 30).View())
	if !strings.Contains(view, "contradicted → applied  applied claim text") {
		t.Fatalf("applied suffix missing, got:\n%s", view)
	}
	if !strings.Contains(view, "contradicted → skip:not_mechanically_applicable  skipped claim text") {
		t.Fatalf("skip suffix missing, got:\n%s", view)
	}
	if !strings.Contains(view, "contradicted → fail:apply_unexpected_exit  failed claim text") {
		t.Fatalf("fail suffix missing, got:\n%s", view)
	}
	// Legacy / non-contradicted lines must render without a suffix.
	if !strings.Contains(view, "verified claim text") || strings.Contains(view, "verified →") {
		t.Fatalf("legacy (no outcome) row should render without suffix, got:\n%s", view)
	}
}

func TestCountRendersPendingBadge(t *testing.T) {
	st, err := ParseStatus([]byte(`{
		"enabled": true,
		"queue": {"ready": 0, "pending": 3, "running": 2, "total": 5},
		"batch": {"backlog_size": 76}
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	if got := NewModel().ReplaceStatus(st).Count(); got != 3 {
		t.Fatalf("Count = %d, want queue.pending (what's waiting)", got)
	}

	idle, err := ParseStatus([]byte(`{
		"enabled": true,
		"queue": {"ready": 0, "pending": 0, "running": 0, "total": 0},
		"batch": {"backlog_size": 76}
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	if got := NewModel().ReplaceStatus(idle).Count(); got != 0 {
		t.Fatalf("Count = %d, want 0 (backlog is not pending work)", got)
	}
}

func TestWrapIndentWrapsWholeTextUnderLabelColumn(t *testing.T) {
	long := "alpha bravo charlie delta echo foxtrot golf hotel india juliet"
	lines := wrapIndent("falsifier", long, drillLabelW, 40, styles())
	if len(lines) < 2 {
		t.Fatalf("long text should wrap onto continuation lines, got %d line(s): %q", len(lines), lines)
	}
	joined := strings.Join(lines, "\n")
	if strings.Contains(joined, "…") {
		t.Fatalf("wrapped text must not be truncated mid-content, got:\n%s", joined)
	}
	for _, word := range strings.Fields(long) {
		if !strings.Contains(joined, word) {
			t.Fatalf("wrapped text lost word %q, got:\n%s", word, joined)
		}
	}
	indent := strings.Repeat(" ", drillLabelW)
	if !strings.HasPrefix(stripANSI(lines[1]), indent) {
		t.Fatalf("continuation lines should indent to the content column, got %q", lines[1])
	}
	for _, line := range lines {
		if lipgloss.Width(line) > 40 {
			t.Fatalf("wrapped line exceeds width: %q", line)
		}
	}
}

func drillStatus(t *testing.T) Status {
	t.Helper()
	st, err := ParseStatus([]byte(`{
		"enabled": true,
		"queue": {"pending": 2, "total": 2},
		"items": [
			{"id": "cl-1", "claim_id": "claim-one", "status": "pending", "work_item": "wi-1", "claim": "alpha bravo charlie delta echo foxtrot golf hotel india juliet", "falsifier": "kilo lima mike november oscar papa quebec romeo sierra tango", "file": "scripts/x.sh", "line_range": "10-20", "producer_role": "worker", "task_id": "task-3", "attempts": 1, "harness": "claude-code"},
			{"id": "cl-2", "claim_id": "claim-two", "status": "ready", "work_item": "wi-2", "claim": "second claim text"}
		],
		"terminal_items": [
			{"id": "t1", "claim_id": "verdict-verified", "claim": "verified claim body", "status": "completed", "verdict": {"verdict": "verified", "evidence": "matched"}},
			{"id": "t2", "claim_id": "verdict-contra", "claim": "contradicted claim body", "status": "completed", "verdict": {"verdict": "contradicted", "evidence": "uniform victor whiskey xray yankee zulu omega sigma theta iota", "correction": "fix"}, "correction_outcome": {"status": "applied", "target_entry": "conventions/foo.md"}, "run_ref": "_scorecards/runs/run-1.json", "verdict_ref": "_work/x/verdicts/run-1.md"}
		]
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	return st
}

func TestEnterOpensClaimDrillInAndEscReturnsInOnePress(t *testing.T) {
	m := NewModel().ReplaceStatus(drillStatus(t)).SetSize(60, 24)
	if m.Drill() != DrillNone {
		t.Fatal("model should start at the root dashboard")
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.Drill() != DrillClaim {
		t.Fatal("Enter on a queue row should open the claim drill-in")
	}
	view := stripANSI(m.View())
	if !strings.Contains(view, "Claim 1 of 2 — claim-one") {
		t.Fatalf("claim drill-in should show position and id, got:\n%s", view)
	}
	// Full wrapped text, nothing truncated: every word of the claim and
	// falsifier is present despite the narrow width.
	all := view
	for i := 0; i < 6; i++ {
		m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyPgDown})
		all += "\n" + stripANSI(m.View())
	}
	for _, word := range []string{"juliet", "tango", "scripts/x.sh:10-20", "wi-1", "worker", "task task-3"} {
		if !strings.Contains(all, word) {
			t.Fatalf("claim drill-in should render %q whole, got:\n%s", word, all)
		}
	}
	if strings.Contains(all, "…") {
		t.Fatalf("claim drill-in must not truncate mid-content, got:\n%s", all)
	}

	// j walks to the next claim inside the drill-in.
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if view := stripANSI(m.View()); !strings.Contains(view, "Claim 2 of 2 — claim-two") {
		t.Fatalf("j should walk to the next claim, got:\n%s", view)
	}

	// One Esc returns to the queue.
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if m.Drill() != DrillNone {
		t.Fatal("Esc should return to the queue in one press")
	}
	if view := stripANSI(m.View()); !strings.Contains(view, "─ Queue ─") {
		t.Fatalf("root dashboard should render after Esc, got:\n%s", view)
	}
}

func TestVerdictDrillInWalksVerdictsContradictionsFirst(t *testing.T) {
	m := NewModel().ReplaceStatus(drillStatus(t)).SetSize(60, 24)
	m, _ = m.Update(tea.KeyPressMsg{Code: 'v', Text: "v"})
	if m.Drill() != DrillVerdict {
		t.Fatal("v should open the verdict drill-in")
	}
	view := stripANSI(m.View())
	if !strings.Contains(view, "Verdict 1 of 2 — verdict-contra") {
		t.Fatalf("verdict drill-in should open on the first (contradicted-first) verdict, got:\n%s", view)
	}
	all := view
	for i := 0; i < 6; i++ {
		m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyPgDown})
		all += "\n" + stripANSI(m.View())
	}
	for _, want := range []string{"iota", "applied", "conventions/foo.md", "_scorecards/runs/run-1.json", "_work/x/verdicts/run-1.md"} {
		if !strings.Contains(all, want) {
			t.Fatalf("verdict drill-in should render %q, got:\n%s", want, all)
		}
	}

	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if view := stripANSI(m.View()); !strings.Contains(view, "Verdict 2 of 2 — verdict-verified") {
		t.Fatalf("j should walk to the next verdict, got:\n%s", view)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'k', Text: "k"})
	if view := stripANSI(m.View()); !strings.Contains(view, "Verdict 1 of 2 — verdict-contra") {
		t.Fatalf("k should walk back to the first verdict, got:\n%s", view)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if m.Drill() != DrillNone {
		t.Fatal("Esc should return to the queue in one press")
	}
}

func TestVerdictRegionRendersContradictionsFirstAndLoud(t *testing.T) {
	view := stripANSI(NewModel().ReplaceStatus(drillStatus(t)).SetSize(120, 30).View())
	contraIdx := strings.Index(view, "! contradicted")
	verifiedIdx := strings.Index(view, "verified")
	if contraIdx < 0 {
		t.Fatalf("contradicted verdicts should render loud with the ! marker, got:\n%s", view)
	}
	if verifiedIdx >= 0 && contraIdx > strings.Index(view, "verified claim body") {
		t.Fatalf("contradicted verdicts should render before confirmations, got:\n%s", view)
	}
	// Loud styling carries the error token; quiet lines are dim.
	styled := NewModel().ReplaceStatus(drillStatus(t)).SetSize(120, 30).View()
	loud := style.StatusError.Bold(true).Render("! " + fmt.Sprintf("%-22s", "contradicted → applied"))
	if !strings.Contains(styled, loud) {
		t.Fatalf("contradicted verdict line should carry StatusError.Bold, got:\n%s", styled)
	}
}

func TestViewSeparatesRegionsWithLabeledRules(t *testing.T) {
	st, err := ParseStatus([]byte(`{
		"enabled": true,
		"queue": {"pending": 1, "total": 1},
		"items": [{"id": "item-1", "status": "pending"}],
		"last_settled": {"id": "item-0", "claim_id": "claim-z", "status": "completed", "verdict_label": "verified"},
		"dispatch": {"mode": "event-driven", "census_enabled": false, "pump": {"last_ran_at": "2026-07-04T09:00:00Z", "seconds_since_last": 240}}
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}

	view := stripANSI(NewModel().ReplaceStatus(st).SetSize(100, 30).View())
	rules := []string{
		"─ Health ─",
		"─ Posture ─",
		"─ Trust transition ─",
		"─ Queue ─",
		"─ Verdicts ─",
	}
	prev := -1
	for _, rule := range rules {
		idx := strings.Index(view, rule)
		if idx < 0 {
			t.Fatalf("missing region rule %q, got:\n%s", rule, view)
		}
		if idx <= prev {
			t.Fatalf("region rule %q out of order, got:\n%s", rule, view)
		}
		prev = idx
	}
	// No stale leases: the stuck-lease region is omitted entirely.
	if strings.Contains(view, "Stuck lease") {
		t.Fatalf("stuck-lease region must be omitted when nothing is stale, got:\n%s", view)
	}
	// No settings dock at any height.
	if strings.Contains(view, "─ Settings ─") {
		t.Fatalf("panel body must not contain a settings dock, got:\n%s", view)
	}
}

func TestHealthCellsRenderLiveValuesWithoutPlaceholders(t *testing.T) {
	st, err := ParseStatus([]byte(`{
		"enabled": true,
		"queue": {"pending": 2, "total": 2},
		"usage": {"started": 4, "cap_total": 3600, "cap_remaining": 2400},
		"health": {"drain_rate_per_hour": 8.5, "completions_24h": 204, "oldest_pending_age_seconds": 259200, "requeues_today": 1, "failures_today": 0}
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	view := stripANSI(NewModel().ReplaceStatus(st).SetSize(120, 30).View())
	for _, want := range []string{"~8.5/h · 204 drained 24h", "3d pending", "1 today · 0 failed", "4 jobs · runtime 40m/60m"} {
		if !strings.Contains(view, want) {
			t.Fatalf("health cell %q missing, got:\n%s", want, view)
		}
	}
	if strings.Contains(view, "n/a") {
		t.Fatalf("no health cell may show a placeholder when the feed carries the health block, got:\n%s", view)
	}

	// Absent health block (older CLI): cells degrade to placeholders.
	older, err := ParseStatus([]byte(`{"enabled": true, "queue": {"pending": 2, "total": 2}}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	view = stripANSI(NewModel().ReplaceStatus(older).SetSize(120, 30).View())
	if !strings.Contains(view, "n/a") {
		t.Fatalf("health cells should show placeholders when the feed predates the health block, got:\n%s", view)
	}
}

func TestPostureLineRendersControlsAndSpotDial(t *testing.T) {
	st, err := ParseStatus([]byte(`{
		"enabled": true,
		"auditor_model": "sonnet",
		"active_hours": {"enabled": true, "allowed": true, "reason": "", "timezone": "local", "ranges": [{"days": ["mon"], "start": "09:00", "end": "18:00"}]},
		"dispatch": {"mode": "event-driven", "census_enabled": false, "spot_sample": {"weekly_budget": 10, "used_this_week": 3}}
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	view := stripANSI(NewModel().ReplaceStatus(st).SetSize(160, 30).View())
	for _, want := range []string{"[p] paused: no", "[s] schedule: on · in window", "[m] model: sonnet", "[x] process once", "spot: 3/10 wk"} {
		if !strings.Contains(view, want) {
			t.Fatalf("posture line missing %q, got:\n%s", want, view)
		}
	}

	// Paused (disabled) renders loud; unset model shows the role-default
	// placeholder; out-of-window schedule carries the warn state.
	st.Enabled = false
	st.AuditorModel = ""
	st.ActiveHours.Allowed = false
	st.ActiveHours.Reason = "outside_active_hours"
	view = stripANSI(NewModel().ReplaceStatus(st).SetSize(160, 30).View())
	for _, want := range []string{"[p] paused: YES", "[s] schedule: on · out of window", "[m] model: role default"} {
		if !strings.Contains(view, want) {
			t.Fatalf("degraded posture line missing %q, got:\n%s", want, view)
		}
	}
}

func TestTrustTransitionRendersGaugesFromFeed(t *testing.T) {
	st, err := ParseStatus([]byte(`{
		"enabled": true,
		"dispatch": {
			"mode": "event-driven",
			"census_enabled": false,
			"verify_volume": {"window_weeks": 8, "weekly_average": 9.5, "current_week_events": 4, "weeks": [{"week_start": "2026-06-22T00:00:00Z", "events": 12, "held": 10, "contradicted": 2}]},
			"pump": {"last_ran_at": "2026-07-04T09:00:00Z", "seconds_since_last": 240}
		}
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	view := stripANSI(NewModel().ReplaceStatus(st).SetSize(140, 30).View())
	for _, want := range []string{"10 held · 2 contradicted last wk · avg 9.5/wk (8w)", "ran 4m ago", "census:", "off (event-driven)"} {
		if !strings.Contains(view, want) {
			t.Fatalf("trust gauge %q missing, got:\n%s", want, view)
		}
	}

	// A never-ran pump reads as "TUI closed", not a zero gap.
	never, err := ParseStatus([]byte(`{
		"enabled": true,
		"dispatch": {"mode": "event-driven", "census_enabled": false, "pump": {"last_ran_at": null, "seconds_since_last": null}}
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	view = stripANSI(NewModel().ReplaceStatus(never).SetSize(140, 30).View())
	if !strings.Contains(view, "never ran (TUI closed?)") {
		t.Fatalf("never-ran pump should read as TUI closed, got:\n%s", view)
	}
}

func TestStuckLeaseRegionAutoExpandsOnStaleLeases(t *testing.T) {
	expired := time.Now().Add(-22 * time.Minute).Unix()
	data := fmt.Sprintf(`{
		"enabled": true,
		"stale_active_leases": 1,
		"leases": [{"id": "lease-01", "item_id": "cl-meta", "holder": "settle-1", "pid": 4242, "expires_at_epoch": %d}]
	}`, expired)
	st, err := ParseStatus([]byte(data))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	view := stripANSI(NewModel().ReplaceStatus(st).SetSize(140, 30).View())
	if !strings.Contains(view, "─ Stuck lease ─") {
		t.Fatalf("stale leases should auto-expand the stuck-lease region, got:\n%s", view)
	}
	for _, want := range []string{"! lease-01", "item cl-meta", "owner settle-1", "pid 4242", "expired 22m ago"} {
		if !strings.Contains(view, want) {
			t.Fatalf("stuck-lease record missing %q, got:\n%s", want, view)
		}
	}

	// Healthy leases stay collapsed into the health count.
	st.StaleActiveLeases = 0
	view = stripANSI(NewModel().ReplaceStatus(st).SetSize(140, 30).View())
	if strings.Contains(view, "Stuck lease") {
		t.Fatalf("stuck-lease region must collapse when nothing is stale, got:\n%s", view)
	}
}

func TestPostureLineNamesStaleLeasesUnderMaxConcurrency(t *testing.T) {
	// When a corpse lease holds the pipeline at max_concurrency, the posture
	// blocked line reads as ordinary saturation. The posture region must name
	// the stale leases in place so a stall of this shape reads as a stall.
	st, err := ParseStatus([]byte(`{
		"enabled": true,
		"blocked_reason": "max_concurrency_reached",
		"stale_active_leases": 1,
		"queue": {"pending": 584, "running": 1, "total": 585},
		"harness": {"concurrency": 1, "active_leases": 1}
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	view := stripANSI(NewModel().ReplaceStatus(st).SetSize(140, 30).View())
	if !strings.Contains(view, "stale leases: 1 — reaping on next process") {
		t.Fatalf("posture region should name stale leases holding max_concurrency, got:\n%s", view)
	}

	// No stale leases: the posture region stays quiet about reaping.
	st.StaleActiveLeases = 0
	view = stripANSI(NewModel().ReplaceStatus(st).SetSize(140, 30).View())
	if strings.Contains(view, "reaping on next process") {
		t.Fatalf("posture region must not mention reaping when nothing is stale, got:\n%s", view)
	}
}

func manyItemStatus(t *testing.T, n int) Status {
	t.Helper()
	var b strings.Builder
	b.WriteString(`{"enabled": true, "queue": {"pending": 12, "total": 12}, "items": [`)
	for i := 1; i <= n; i++ {
		if i > 1 {
			b.WriteString(",")
		}
		b.WriteString(`{"id": "item-` + strconv.Itoa(i) + `", "status": "pending"}`)
	}
	b.WriteString(`]}`)
	st, err := ParseStatus([]byte(b.String()))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	return st
}

func TestCursorFollowKeepsSelectedRowVisible(t *testing.T) {
	m := NewModel().ReplaceStatus(manyItemStatus(t, 12)).SetSize(120, 14)
	j := tea.KeyPressMsg{Code: 'j', Text: "j"}
	for i := 0; i < 11; i++ {
		m, _ = m.Update(j)
	}
	view := stripANSI(m.View())
	if got := len(strings.Split(view, "\n")); got != 14 {
		t.Fatalf("view should clip to 14 lines, got %d:\n%s", got, view)
	}
	if !strings.Contains(view, "> [pending]  item-12") {
		t.Fatalf("viewport should follow the cursor to the last queue row, got:\n%s", view)
	}

	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyHome})
	view = stripANSI(m.View())
	if !strings.Contains(view, "> [pending]  item-1 ") {
		t.Fatalf("home should select the first row and scroll it into view, got:\n%s", view)
	}
	if !strings.Contains(view, "Health") {
		t.Fatalf("home should scroll back to the top of the panel, got:\n%s", view)
	}
}

func TestPageScrollLeavesSelectionAnchored(t *testing.T) {
	m := NewModel().ReplaceStatus(manyItemStatus(t, 12)).SetSize(120, 10)
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyPgDown})
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyPgDown})
	// Paging scrolls the viewport without moving the selection, so the next
	// j advances from the first row, not from the scrolled position.
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	view := stripANSI(m.View())
	if !strings.Contains(view, "> [pending]  item-2 ") {
		t.Fatalf("selection should advance from item-1 to item-2 after paging, got:\n%s", view)
	}
}

func TestMouseWheelMovesQueueCursorAndViewport(t *testing.T) {
	m := NewModel().ReplaceStatus(manyItemStatus(t, 12)).SetSize(120, 10)
	startOffset := m.vp.YOffset()

	m, _ = m.Update(tea.MouseWheelMsg{Button: tea.MouseWheelDown})
	if m.cursor != 1 {
		t.Fatalf("wheel down should move queue cursor to item 2, cursor=%d", m.cursor)
	}

	for i := 0; i < 10; i++ {
		m, _ = m.Update(tea.MouseWheelMsg{Button: tea.MouseWheelDown})
	}
	if m.cursor != 11 {
		t.Fatalf("repeated wheel down should reach the last item, cursor=%d", m.cursor)
	}
	if m.vp.YOffset() <= startOffset {
		t.Fatalf("viewport offset should follow the wheeled cursor, got %d from %d", m.vp.YOffset(), startOffset)
	}

	m, _ = m.Update(tea.MouseWheelMsg{Button: tea.MouseWheelUp})
	if m.cursor != 10 {
		t.Fatalf("wheel up should move queue cursor back one row, cursor=%d", m.cursor)
	}
}

func TestEndSelectsLastQueueRow(t *testing.T) {
	m := NewModel().ReplaceStatus(manyItemStatus(t, 12)).SetSize(120, 10)
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnd})
	view := stripANSI(m.View())
	if !strings.Contains(view, "> [pending]  item-12") {
		t.Fatalf("end should select the last queue row and scroll it into view, got:\n%s", view)
	}
}

func TestVerdictCompactnessCapSummarizesOverflow(t *testing.T) {
	st, err := ParseStatus([]byte(`{
		"enabled": true,
		"queue": {"total": 0},
		"terminal_items": [
			{"id": "t1", "claim_id": "c1", "claim": "first", "status": "completed", "verdict": {"verdict": "verified", "evidence": "e"}},
			{"id": "t2", "claim_id": "c2", "claim": "second", "status": "completed", "verdict": {"verdict": "verified", "evidence": "e"}},
			{"id": "t3", "claim_id": "c3", "claim": "third", "status": "completed", "verdict": {"verdict": "verified", "evidence": "e"}},
			{"id": "t4", "claim_id": "c4", "claim": "fourth", "status": "completed", "verdict": {"verdict": "verified", "evidence": "e"}},
			{"id": "t5", "claim_id": "c5", "claim": "fifth", "status": "completed", "verdict": {"verdict": "verified", "evidence": "e"}},
			{"id": "t6", "claim_id": "c6", "claim": "sixth", "status": "completed", "verdict": {"verdict": "verified", "evidence": "e"}}
		]
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}

	view := stripANSI(NewModel().ReplaceStatus(st).SetSize(200, 40).View())
	if !strings.Contains(view, "... 2 more verdicts") {
		t.Fatalf("verdicts beyond the four-entry compactness cap should be summarized, got:\n%s", view)
	}
	if strings.Contains(view, "fifth") || strings.Contains(view, "sixth") {
		t.Fatalf("verdicts beyond the compactness cap should not render, got:\n%s", view)
	}
}
