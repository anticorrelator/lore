package settlement

import (
	"strings"
	"testing"

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
	st, err := ParseStatus([]byte(`{
		"enabled": true,
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
	if got := NewModel().ReplaceStatus(st).Count(); got != 76 {
		t.Fatalf("Count = %d, want backlog size", got)
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
	view := m.SetSize(100, 30).View()
	if strings.Contains(view, "old") {
		t.Fatalf("view contains stale first snapshot data: %s", view)
	}
}

func TestModelReadableViewCapsQueuePreview(t *testing.T) {
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

	view := NewModel().ReplaceStatus(st).SetSize(120, 9).View()
	if !strings.Contains(view, "next: process once or wait for processor") {
		t.Fatalf("status should keep the next action readable, got:\n%s", view)
	}
	if !strings.Contains(view, "queue: ready 0, pending 5, running 0, total 5") {
		t.Fatalf("status should use the compact queue label, got:\n%s", view)
	}
	if strings.Contains(view, "complete ") || strings.Contains(view, "failed ") || strings.Contains(view, "blocked ") {
		t.Fatalf("compact queue label should drop complete/failed/blocked segments, got:\n%s", view)
	}
	if strings.Contains(view, "rate ") {
		t.Fatalf("status should omit launch rate from the summary row, got:\n%s", view)
	}
	if !strings.Contains(view, "Recent verdicts") || !strings.Contains(view, "no settled claims yet") {
		t.Fatalf("compact queue preview should include stable last-settled placeholder, got:\n%s", view)
	}
	if !strings.Contains(view, "... 4 more") || strings.Contains(view, "item-2") {
		t.Fatalf("compact queue preview should reserve room below the queue, got:\n%s", view)
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
	if !strings.Contains(view, "verified  verified claim text") {
		t.Fatalf("legacy (no outcome) row should render without suffix, got:\n%s", view)
	}
}

func TestCountIncludesRunningClaims(t *testing.T) {
	st, err := ParseStatus([]byte(`{
		"enabled": true,
		"queue": {"ready": 0, "pending": 0, "running": 3, "total": 3},
		"batch": {"backlog_size": 76}
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	if got := NewModel().ReplaceStatus(st).Count(); got != 3 {
		t.Fatalf("Count = %d, want 3 (running claims are active queue depth)", got)
	}
}

func TestCountFallsBackToBacklogWhenQueueIdle(t *testing.T) {
	st, err := ParseStatus([]byte(`{
		"enabled": true,
		"queue": {"ready": 0, "pending": 0, "running": 0, "total": 0},
		"batch": {"backlog_size": 76}
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	if got := NewModel().ReplaceStatus(st).Count(); got != 76 {
		t.Fatalf("Count = %d, want backlog fallback 76", got)
	}
}

func TestFormatLastSettledWrapsLongClaim(t *testing.T) {
	long := "alpha bravo charlie delta echo foxtrot golf hotel india juliet"
	lines := formatLastSettled(&LastSettled{VerdictLabel: "verified", Claim: long}, 40, styles())
	if len(lines) < 2 {
		t.Fatalf("long claim should wrap onto continuation lines, got %d line(s): %q", len(lines), lines)
	}
	joined := strings.Join(lines, "\n")
	if strings.Contains(joined, "…") {
		t.Fatalf("wrapped verdict must not be truncated mid-content, got:\n%s", joined)
	}
	for _, word := range strings.Fields(long) {
		if !strings.Contains(joined, word) {
			t.Fatalf("wrapped verdict lost word %q, got:\n%s", word, joined)
		}
	}
	indent := strings.Repeat(" ", len("- verified  "))
	if !strings.HasPrefix(lines[1], indent) {
		t.Fatalf("continuation lines should carry a hanging indent, got %q", lines[1])
	}
	for _, line := range lines {
		if lipgloss.Width(line) > 40 {
			t.Fatalf("wrapped line exceeds width: %q", line)
		}
	}
}

func TestTightVerdictBlockDropsWholeVerdicts(t *testing.T) {
	st, err := ParseStatus([]byte(`{
		"enabled": true,
		"queue": {"total": 0},
		"terminal_items": [
			{"id": "t1", "claim_id": "claim-a", "claim": "alpha bravo charlie delta echo foxtrot golf hotel india juliet", "status": "completed", "verdict": {"verdict": "verified", "evidence": "matched"}},
			{"id": "t2", "claim_id": "claim-b", "claim": "kilo lima mike november oscar papa quebec romeo sierra tango", "status": "completed", "verdict": {"verdict": "verified", "evidence": "matched"}},
			{"id": "t3", "claim_id": "claim-c", "claim": "uniform victor whiskey xray yankee zulu omega sigma theta iota", "status": "completed", "verdict": {"verdict": "verified", "evidence": "matched"}}
		]
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}

	// width 44 -> bodyW 40 (each verdict wraps to ~3 lines); height 13 leaves a
	// 4-line budget after the region rules, so only the first verdict fits whole.
	view := NewModel().ReplaceStatus(st).SetSize(44, 13).View()
	idx := strings.Index(view, "Recent verdicts")
	if idx < 0 {
		t.Fatalf("missing Recent verdicts section, got:\n%s", view)
	}
	block := view[idx:]
	if !strings.Contains(block, "... 2 more verdicts") {
		t.Fatalf("overflowing verdicts should collapse into a whole-verdict marker, got:\n%s", block)
	}
	if !strings.Contains(block, "delta") || !strings.Contains(block, "juliet") {
		t.Fatalf("the shown verdict must be complete, got:\n%s", block)
	}
	if strings.Contains(block, "kilo") || strings.Contains(block, "uniform") {
		t.Fatalf("dropped verdicts must be dropped whole, not partially wrapped, got:\n%s", block)
	}
	if strings.Contains(block, "…") {
		t.Fatalf("verdict block must not contain mid-content truncation, got:\n%s", block)
	}
	if statusH := 13; len(strings.Split(view, "\n")) > statusH {
		t.Fatalf("view exceeds the host clip height %d, so a verdict could be cut mid-wrap:\n%s", statusH, view)
	}
}

func TestModelRendersLastSettledBetweenQueueAndLeases(t *testing.T) {
	st, err := ParseStatus([]byte(`{
		"enabled": true,
		"queue": {"pending": 1, "running": 1, "completed": 1, "total": 3},
		"items": [{"id": "item-1", "status": "pending", "work_item": "settlement-operational-closure"}],
		"last_settled": {"id": "item-0", "claim_id": "claim-done", "claim": "the queue renders settled verdicts as plain outcomes", "status": "completed", "verdict_label": "verified", "verdict_summary": "evidence matched the claim"},
		"leases": [{"id": "lease-1", "item_id": "item-2", "worker_id": "proc-a"}]
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}

	view := stripANSI(NewModel().ReplaceStatus(st).SetSize(120, 20).View())
	queueIdx := strings.Index(view, "Settlement queue")
	lastIdx := strings.Index(view, "Recent verdicts")
	leaseIdx := strings.Index(view, "Active leases")
	if queueIdx < 0 || lastIdx < 0 || leaseIdx < 0 {
		t.Fatalf("expected queue, last-settled, and lease sections, got:\n%s", view)
	}
	if !(queueIdx < lastIdx && lastIdx < leaseIdx) {
		t.Fatalf("last-settled section should sit between queue and leases, got:\n%s", view)
	}
	if !strings.Contains(view, "verified  the queue renders settled verdicts as plain outcomes") {
		t.Fatalf("last-settled verdict summary missing, got:\n%s", view)
	}
	if strings.Contains(view, "claim-done") || strings.Contains(view, "evidence matched the claim") {
		t.Fatalf("last-settled view should hide ids and evidence detail, got:\n%s", view)
	}
}

func TestViewSeparatesRegionsWithLabeledRules(t *testing.T) {
	st, err := ParseStatus([]byte(`{
		"enabled": true,
		"queue": {"pending": 1, "total": 1},
		"items": [{"id": "item-1", "status": "pending"}],
		"last_settled": {"id": "item-0", "claim_id": "claim-z", "status": "completed", "verdict_label": "verified"},
		"leases": [{"id": "lease-1", "item_id": "item-1"}]
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}

	view := stripANSI(NewModel().ReplaceStatus(st).SetSize(100, 24).View())
	rules := []string{
		"─ Operational status ─",
		"─ Settlement queue ─",
		"─ Selected claim ─",
		"─ Recent verdicts ─",
		"─ Active leases ─",
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

	// Empty sections are omitted entirely, rule included.
	st.Leases = nil
	view = stripANSI(NewModel().ReplaceStatus(st).SetSize(100, 24).View())
	if strings.Contains(view, "Active leases") {
		t.Fatalf("empty lease region should be omitted, got:\n%s", view)
	}
}

func TestDefaultPlaceholdersRenderDistinctFromDisabledState(t *testing.T) {
	st, err := ParseStatus([]byte(`{
		"enabled": false,
		"queue": {"total": 0}
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}

	view := NewModel().ReplaceStatus(st).SetSize(120, 20).View()
	disabled := style.StatusWarn.Render("disabled")
	placeholder := style.StatusDisabled.Render("default")
	if disabled == "disabled" || placeholder == "default" {
		t.Fatal("status tokens should style their output even without a TTY")
	}
	if !strings.Contains(view, disabled) {
		t.Fatalf("disabled state should carry the attention status token, got:\n%s", view)
	}
	for _, want := range []string{placeholder, style.StatusDisabled.Render("unknown"), style.StatusDisabled.Render("unlimited")} {
		if !strings.Contains(view, want) {
			t.Fatalf("default-unset placeholder %q should carry the disabled/default-unset token, got:\n%s", stripANSI(want), view)
		}
	}

	st.Enabled = true
	view = NewModel().ReplaceStatus(st).SetSize(120, 20).View()
	if !strings.Contains(view, style.StatusReady.Render("enabled")) {
		t.Fatalf("enabled state should carry the ready status token, got:\n%s", view)
	}
}

func TestLeaseRegionIsReservedWithinHeightBudget(t *testing.T) {
	st, err := ParseStatus([]byte(`{
		"enabled": true,
		"queue": {"total": 0},
		"terminal_items": [
			{"id": "t1", "claim_id": "claim-a", "claim": "alpha bravo charlie delta echo foxtrot golf hotel india juliet", "status": "completed", "verdict": {"verdict": "verified", "evidence": "matched"}},
			{"id": "t2", "claim_id": "claim-b", "claim": "kilo lima mike november oscar papa quebec romeo sierra tango", "status": "completed", "verdict": {"verdict": "verified", "evidence": "matched"}},
			{"id": "t3", "claim_id": "claim-c", "claim": "uniform victor whiskey xray yankee zulu omega sigma theta iota", "status": "completed", "verdict": {"verdict": "verified", "evidence": "matched"}}
		],
		"leases": [{"id": "lease-1", "item_id": "item-9", "worker_id": "proc-a"}]
	}`))
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}

	// The lease block is reserved before the verdict budget, so the whole
	// view must fit the host clip height with the lease region intact and
	// overflowing verdicts dropped whole.
	height := 17
	view := stripANSI(NewModel().ReplaceStatus(st).SetSize(44, height).View())
	if got := len(strings.Split(view, "\n")); got > height {
		t.Fatalf("view has %d lines, exceeding the host clip height %d:\n%s", got, height, view)
	}
	if !strings.Contains(view, "lease-1") {
		t.Fatalf("lease region should survive the verdict budget, got:\n%s", view)
	}
	if !strings.Contains(view, "... 2 more verdicts") {
		t.Fatalf("overflowing verdicts should collapse into a whole-verdict marker, got:\n%s", view)
	}
	if strings.Contains(view, "kilo") || strings.Contains(view, "uniform") {
		t.Fatalf("dropped verdicts must be dropped whole, got:\n%s", view)
	}
	if strings.Index(view, "Active leases") < strings.Index(view, "more verdicts") {
		t.Fatalf("lease region should sit below the verdict region, got:\n%s", view)
	}
}
