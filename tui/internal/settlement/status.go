package settlement

import (
	"encoding/json"
	"fmt"
	"strings"
)

// Status is the TUI's tolerant view of `lore settlement status --json`.
// The processor owns the durable schema; the TUI accepts documented fields and
// a few conservative aliases while replacing snapshots wholesale.
type Status struct {
	Available     bool
	Message       string
	Enabled       bool
	Queue         Queue
	Items         []Item
	Leases        []Lease
	Harness       Harness
	Usage         Usage
	Batch         Batch
	LastSettled   *LastSettled
	RecentSettled []LastSettled
	NextAction    string
	BlockedReason string
	UpdatedAt     string
}

type Queue struct {
	Total    int
	Ready    int
	Pending  int
	Running  int
	Complete int
	Failed   int
	Blocked  int
}

type Item struct {
	ID            string
	WorkItem      string
	ClaimID       string
	Claim         string
	SourceFile    string
	LineRange     string
	Falsifier     string
	TaskID        string
	ProducerRole  string
	Status        string
	Harness       string
	Attempts      int
	BlockedReason string
	NextAction    string
}

type Lease struct {
	ID        string
	ItemID    string
	WorkerID  string
	Harness   string
	PID       int
	ExpiresAt string
}

type Harness struct {
	Mode          string
	Selected      string
	Random        bool
	Concurrency   int
	LaunchRate    string
	CapTotal      int
	CapRemaining  int
	ActiveLeases  int
	BlockedReason string
}

type Usage struct {
	BudgetState   string
	CapTotal      int
	CapRemaining  int
	LaunchRate    string
	RateRemaining int
	Started       int
}

type Batch struct {
	ID           string
	Size         int
	BacklogSize  int
	Reason       string
	RecomputedAt string
}

type LastSettled struct {
	ID             string
	RunID          string
	WorkItem       string
	ClaimID        string
	Claim          string
	SourceFile     string
	LineRange      string
	Falsifier      string
	Status         string
	VerdictLabel   string
	VerdictSummary string
	Correction     string
	BlockedReason  string
	SettledAt      string
	RunRef         string
	VerdictRef     string
}

type ActionResult struct {
	Action     string
	OK         bool
	Dispatched *bool
	Reason     string
	Message    string
	Status     *Status
}

func Unavailable(message string) Status {
	return Status{Available: false, Message: message, NextAction: "waiting for settlement CLI"}
}

func ParseStatus(data []byte) (Status, error) {
	var root map[string]json.RawMessage
	if err := json.Unmarshal(data, &root); err != nil {
		return Status{}, err
	}
	st := Status{Available: true}
	st.Message = stringField(root, "message", "notice")
	st.Enabled = boolField(root, "enabled", "is_enabled")
	st.NextAction = stringField(root, "next_action", "nextAction")
	st.BlockedReason = stringField(root, "blocked_reason", "blockedReason", "next_blocked_reason")
	st.UpdatedAt = stringField(root, "updated_at", "updatedAt")

	if raw, ok := first(root, "queue", "totals", "counts"); ok {
		st.Queue = parseQueue(raw)
	}
	mergeQueueTopLevel(&st.Queue, root)
	st.Items = parseItems(root)
	st.Leases = parseLeases(root)
	st.Harness = parseHarness(root)
	st.Usage = parseUsage(root)
	st.Batch = parseBatch(root)
	st.RecentSettled = parseRecentSettled(root)
	st.LastSettled = parseLastSettled(root, st.RecentSettled)
	if st.Harness.ActiveLeases == 0 {
		st.Harness.ActiveLeases = len(st.Leases)
	}
	if st.Harness.CapRemaining == 0 && st.Usage.CapRemaining != 0 {
		st.Harness.CapRemaining = st.Usage.CapRemaining
	}
	if st.Queue.Total == 0 {
		st.Queue.Total = st.Queue.Ready + st.Queue.Pending + st.Queue.Running + st.Queue.Complete + st.Queue.Failed + st.Queue.Blocked
	}
	if st.Queue.Total == 0 && len(st.Items) > 0 {
		st.Queue = queueFromItems(st.Items)
	}
	if st.NextAction == "" {
		st.NextAction = InferNextAction(st)
	}
	return st, nil
}

func ParseActionResult(action string, data []byte) (ActionResult, error) {
	var root map[string]json.RawMessage
	if err := json.Unmarshal(data, &root); err != nil {
		return ActionResult{}, err
	}
	result := ActionResult{
		Action:  stringDefault(stringField(root, "action"), action),
		OK:      boolField(root, "ok", "success"),
		Reason:  stringField(root, "reason", "blocked_reason", "blockedReason"),
		Message: stringField(root, "message", "notice"),
	}
	if raw, ok := first(root, "dispatched"); ok {
		var dispatched bool
		if json.Unmarshal(raw, &dispatched) == nil {
			result.Dispatched = &dispatched
		}
	}
	if result.Message == "" && result.Dispatched != nil && !*result.Dispatched {
		if result.Reason != "" {
			result.Message = "not dispatched: " + result.Reason
		} else {
			result.Message = "not dispatched"
		}
	}
	if raw, ok := first(root, "status", "snapshot"); ok {
		if st, err := ParseStatus(raw); err == nil {
			result.Status = &st
		}
	} else if looksLikeStatus(root) {
		if st, err := ParseStatus(data); err == nil {
			result.Status = &st
		}
	}
	return result, nil
}

func InferNextAction(st Status) string {
	if !st.Available {
		return "waiting for settlement CLI"
	}
	if !st.Enabled {
		return "enable settlement before processing"
	}
	if st.BlockedReason != "" {
		return "blocked: " + st.BlockedReason
	}
	if st.Harness.BlockedReason != "" {
		return "blocked: " + st.Harness.BlockedReason
	}
	if st.Queue.Running > 0 {
		return "processor active"
	}
	if st.Queue.Ready+st.Queue.Pending > 0 || (st.Queue.Running == 0 && st.Batch.BacklogSize > 0) {
		return "process once or wait for processor"
	}
	return "idle"
}

func parseBatch(root map[string]json.RawMessage) Batch {
	raw, ok := first(root, "batch")
	if !ok {
		return Batch{}
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return Batch{}
	}
	return Batch{
		ID:           stringField(m, "id", "batch_id"),
		Size:         intField(m, "size"),
		BacklogSize:  intField(m, "backlog_size", "backlogSize"),
		Reason:       stringField(m, "recompute_reason", "reason"),
		RecomputedAt: stringField(m, "recomputed_at", "recomputedAt"),
	}
}

func parseQueue(raw json.RawMessage) Queue {
	var m map[string]json.RawMessage
	_ = json.Unmarshal(raw, &m)
	q := Queue{
		Total:    intField(m, "total"),
		Ready:    intField(m, "ready"),
		Pending:  intField(m, "pending", "queued", "waiting"),
		Running:  intField(m, "running", "active", "processing"),
		Complete: intField(m, "complete", "completed", "done"),
		Failed:   intField(m, "failed", "error"),
		Blocked:  intField(m, "blocked"),
	}
	if q.Total == 0 {
		q.Total = q.Ready + q.Pending + q.Running + q.Complete + q.Failed + q.Blocked
	}
	return q
}

func mergeQueueTopLevel(q *Queue, root map[string]json.RawMessage) {
	if q.Total == 0 {
		q.Total = intField(root, "total")
	}
	if q.Ready == 0 {
		q.Ready = intField(root, "ready")
	}
	if q.Pending == 0 {
		q.Pending = intField(root, "pending", "queued", "waiting")
	}
	if q.Running == 0 {
		q.Running = intField(root, "running", "active", "processing")
	}
	if q.Complete == 0 {
		q.Complete = intField(root, "complete", "completed", "done")
	}
	if q.Failed == 0 {
		q.Failed = intField(root, "failed", "error")
	}
	if q.Blocked == 0 {
		q.Blocked = intField(root, "blocked")
	}
}

func parseItems(root map[string]json.RawMessage) []Item {
	raw, ok := first(root, "items", "queue_items", "claims")
	if !ok {
		return nil
	}
	var rows []map[string]json.RawMessage
	if err := json.Unmarshal(raw, &rows); err != nil {
		return nil
	}
	items := make([]Item, 0, len(rows))
	for _, row := range rows {
		source := nestedMap(row, "source")
		items = append(items, Item{
			ID:            stringField(row, "id", "item_id"),
			WorkItem:      stringField(row, "work_item", "work_item_slug", "workItem"),
			ClaimID:       stringField(row, "claim_id", "claimId"),
			Claim:         stringField(row, "claim", "claim_text", "claimText"),
			SourceFile:    firstNonEmpty(stringField(row, "file"), stringField(source, "file")),
			LineRange:     firstNonEmpty(stringField(row, "line_range", "lineRange"), stringField(source, "line_range", "lineRange")),
			Falsifier:     stringField(row, "falsifier", "why_this_work_needs_it"),
			TaskID:        stringField(row, "task_id", "taskId"),
			ProducerRole:  stringField(row, "producer_role", "producerRole"),
			Status:        stringDefault(stringField(row, "status", "state"), "pending"),
			Harness:       stringField(row, "harness", "framework"),
			Attempts:      intField(row, "attempts", "try_count"),
			BlockedReason: stringField(row, "blocked_reason", "blockedReason"),
			NextAction:    stringField(row, "next_action", "nextAction"),
		})
	}
	return items
}

func parseLeases(root map[string]json.RawMessage) []Lease {
	raw, ok := first(root, "leases", "active_leases")
	if !ok {
		return nil
	}
	var rows []map[string]json.RawMessage
	if err := json.Unmarshal(raw, &rows); err != nil {
		return nil
	}
	leases := make([]Lease, 0, len(rows))
	for _, row := range rows {
		leases = append(leases, Lease{
			ID:        stringField(row, "id", "lease_id"),
			ItemID:    stringField(row, "item_id", "claim_id"),
			WorkerID:  stringField(row, "worker_id", "owner", "processor_id"),
			Harness:   stringField(row, "harness", "framework"),
			PID:       intField(row, "pid"),
			ExpiresAt: stringField(row, "expires_at", "expiresAt"),
		})
	}
	return leases
}

func parseHarness(root map[string]json.RawMessage) Harness {
	h := Harness{
		Mode:          stringField(root, "harness_mode", "mode"),
		Selected:      stringField(root, "selected_harness", "harness", "framework"),
		Random:        boolField(root, "random", "random_mode"),
		Concurrency:   intField(root, "concurrency", "max_concurrency"),
		LaunchRate:    formatRate(root, "launch_rate", "launch_rate_per_minute", "rate"),
		CapTotal:      intField(root, "runtime_seconds_total", "cap_total", "run_cap", "budget_cap"),
		CapRemaining:  intField(root, "runtime_seconds_remaining", "cap_remaining", "remaining_cap", "budget_remaining"),
		ActiveLeases:  intField(root, "active_leases", "lease_count"),
		BlockedReason: stringField(root, "harness_blocked_reason", "rate_blocked_reason"),
	}
	if raw, ok := first(root, "harness", "processor", "config", "controls"); ok {
		var m map[string]json.RawMessage
		if json.Unmarshal(raw, &m) == nil {
			if h.Mode == "" {
				h.Mode = stringField(m, "mode", "harness_mode")
			}
			if h.Selected == "" {
				h.Selected = stringField(m, "selected", "selected_harness", "harness", "framework")
			}
			if !h.Random {
				h.Random = boolField(m, "random", "random_mode")
			}
			if h.Concurrency == 0 {
				h.Concurrency = intField(m, "concurrency", "max_concurrency")
			}
			if h.LaunchRate == "" {
				h.LaunchRate = formatRate(m, "launch_rate", "launch_rate_per_minute", "rate")
			}
			if h.CapTotal == 0 {
				h.CapTotal = intField(m, "runtime_seconds_total", "cap_total", "run_cap", "budget_cap")
			}
			if h.CapRemaining == 0 {
				h.CapRemaining = intField(m, "runtime_seconds_remaining", "cap_remaining", "remaining_cap", "budget_remaining")
			}
			if h.ActiveLeases == 0 {
				h.ActiveLeases = intField(m, "active_leases", "lease_count")
			}
			if h.BlockedReason == "" {
				h.BlockedReason = stringField(m, "blocked_reason", "rate_blocked_reason")
			}
		}
	}
	return h
}

func parseUsage(root map[string]json.RawMessage) Usage {
	u := Usage{
		BudgetState:   stringField(root, "budget_state", "budget", "usage_state"),
		CapTotal:      intField(root, "runtime_seconds_total", "cap_total", "run_cap", "budget_cap"),
		CapRemaining:  intField(root, "runtime_seconds_remaining", "cap_remaining", "remaining_cap", "budget_remaining"),
		LaunchRate:    formatRate(root, "launch_rate", "launch_rate_per_minute", "rate"),
		RateRemaining: intField(root, "rate_remaining", "launches_remaining"),
		Started:       intField(root, "started", "started_count", "launched"),
	}
	if raw, ok := first(root, "usage", "budget", "limits"); ok {
		var m map[string]json.RawMessage
		if json.Unmarshal(raw, &m) == nil {
			if u.BudgetState == "" {
				u.BudgetState = stringField(m, "state", "budget_state", "status")
			}
			if u.CapTotal == 0 {
				u.CapTotal = intField(m, "runtime_seconds_total", "cap_total", "run_cap", "budget_cap")
			}
			if u.CapRemaining == 0 {
				u.CapRemaining = intField(m, "runtime_seconds_remaining", "cap_remaining", "remaining_cap", "budget_remaining")
			}
			if u.LaunchRate == "" {
				u.LaunchRate = formatRate(m, "launch_rate", "launch_rate_per_minute", "rate")
			}
			if u.RateRemaining == 0 {
				u.RateRemaining = intField(m, "rate_remaining", "launches_remaining")
			}
			if u.Started == 0 {
				u.Started = intField(m, "started", "started_count", "launched")
			}
		}
	}
	return u
}

func parseLastSettled(root map[string]json.RawMessage, recent []LastSettled) *LastSettled {
	if raw, ok := first(root, "last_settled", "lastSettled"); ok {
		var row map[string]json.RawMessage
		if json.Unmarshal(raw, &row) == nil {
			if settled := parseLastSettledRow(row); settled != nil {
				return settled
			}
		}
	}
	if len(recent) > 0 {
		return &recent[0]
	}
	return nil
}

func parseRecentSettled(root map[string]json.RawMessage) []LastSettled {
	if raw, ok := first(root, "terminal_items"); ok {
		var rows []map[string]json.RawMessage
		if json.Unmarshal(raw, &rows) == nil {
			out := make([]LastSettled, 0, len(rows))
			for _, row := range rows {
				if settled := parseLastSettledRow(row); settled != nil {
					out = append(out, *settled)
				}
			}
			return out
		}
	}
	return nil
}

func parseLastSettledRow(row map[string]json.RawMessage) *LastSettled {
	source := nestedMap(row, "source")
	settled := LastSettled{
		ID:             stringField(row, "id", "item_id"),
		RunID:          stringField(row, "run_id", "runId"),
		WorkItem:       stringField(row, "work_item", "work_item_slug", "workItem"),
		ClaimID:        stringField(row, "claim_id", "claimId"),
		Claim:          stringField(row, "claim", "claim_text", "claimText"),
		SourceFile:     firstNonEmpty(stringField(row, "file"), stringField(source, "file")),
		LineRange:      firstNonEmpty(stringField(row, "line_range", "lineRange"), stringField(source, "line_range", "lineRange")),
		Falsifier:      stringField(row, "falsifier", "why_this_work_needs_it"),
		Status:         stringField(row, "status", "state"),
		VerdictLabel:   stringField(row, "verdict_label", "label", "outcome"),
		VerdictSummary: stringField(row, "verdict_summary", "summary", "message", "evidence"),
		Correction:     stringField(row, "correction"),
		BlockedReason:  stringField(row, "blocked_reason", "blockedReason", "reason"),
		SettledAt:      stringField(row, "settled_at", "completed_at", "updated_at", "finished_at"),
		RunRef:         stringField(row, "run_ref"),
		VerdictRef:     stringField(row, "verdict_ref"),
	}
	if raw, ok := first(row, "result"); ok {
		var result map[string]json.RawMessage
		if json.Unmarshal(raw, &result) == nil {
			fillLastSettledFromMap(&settled, result)
			if verdictRaw, ok := first(result, "verdict"); ok {
				var verdict map[string]json.RawMessage
				if json.Unmarshal(verdictRaw, &verdict) == nil {
					fillLastSettledFromMap(&settled, verdict)
				}
			}
		}
	}
	if raw, ok := first(row, "verdict"); ok {
		var verdict map[string]json.RawMessage
		if json.Unmarshal(raw, &verdict) == nil {
			fillLastSettledFromMap(&settled, verdict)
		}
	}
	if settled.ID == "" && settled.RunID == "" && settled.WorkItem == "" && settled.ClaimID == "" && settled.Status == "" {
		return nil
	}
	return &settled
}

func fillLastSettledFromMap(settled *LastSettled, m map[string]json.RawMessage) {
	if settled.RunID == "" {
		settled.RunID = stringField(m, "run_id", "runId")
	}
	if settled.Claim == "" {
		settled.Claim = stringField(m, "claim", "claim_text", "claimText")
	}
	if settled.SourceFile == "" || settled.LineRange == "" {
		source := nestedMap(m, "source")
		if settled.SourceFile == "" {
			settled.SourceFile = firstNonEmpty(stringField(m, "file"), stringField(source, "file"))
		}
		if settled.LineRange == "" {
			settled.LineRange = firstNonEmpty(stringField(m, "line_range", "lineRange"), stringField(source, "line_range", "lineRange"))
		}
	}
	if settled.Falsifier == "" {
		settled.Falsifier = stringField(m, "falsifier", "why_this_work_needs_it")
	}
	if settled.VerdictLabel == "" {
		settled.VerdictLabel = stringField(m, "verdict_label", "label", "outcome", "verdict", "status")
	}
	if settled.VerdictSummary == "" {
		settled.VerdictSummary = stringField(m, "verdict_summary", "summary", "message", "evidence")
	}
	if settled.Correction == "" {
		settled.Correction = stringField(m, "correction")
	}
	if settled.BlockedReason == "" {
		settled.BlockedReason = stringField(m, "blocked_reason", "blockedReason", "reason")
	}
	if settled.SettledAt == "" {
		settled.SettledAt = stringField(m, "settled_at", "completed_at", "updated_at", "finished_at")
	}
	if settled.RunRef == "" {
		settled.RunRef = stringField(m, "run_ref")
	}
	if settled.VerdictRef == "" {
		settled.VerdictRef = stringField(m, "verdict_ref")
	}
}

func queueFromItems(items []Item) Queue {
	q := Queue{Total: len(items)}
	for _, item := range items {
		switch strings.ToLower(item.Status) {
		case "ready":
			q.Ready++
		case "running", "processing", "leased", "active":
			q.Running++
		case "complete", "completed", "done":
			q.Complete++
		case "failed", "error":
			q.Failed++
		case "blocked":
			q.Blocked++
		default:
			q.Pending++
		}
	}
	return q
}

func looksLikeStatus(root map[string]json.RawMessage) bool {
	for _, key := range []string{"enabled", "queue", "items", "leases"} {
		if _, ok := root[key]; ok {
			return true
		}
	}
	return false
}

func first(m map[string]json.RawMessage, keys ...string) (json.RawMessage, bool) {
	for _, key := range keys {
		if raw, ok := m[key]; ok && len(raw) > 0 && string(raw) != "null" {
			return raw, true
		}
	}
	return nil, false
}

func stringField(m map[string]json.RawMessage, keys ...string) string {
	raw, ok := first(m, keys...)
	if !ok {
		return ""
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var n json.Number
	if json.Unmarshal(raw, &n) == nil {
		return n.String()
	}
	return ""
}

func nestedMap(m map[string]json.RawMessage, keys ...string) map[string]json.RawMessage {
	raw, ok := first(m, keys...)
	if !ok {
		return nil
	}
	var out map[string]json.RawMessage
	if json.Unmarshal(raw, &out) == nil {
		return out
	}
	return nil
}

func boolField(m map[string]json.RawMessage, keys ...string) bool {
	raw, ok := first(m, keys...)
	if !ok {
		return false
	}
	var b bool
	if json.Unmarshal(raw, &b) == nil {
		return b
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		switch strings.ToLower(s) {
		case "true", "yes", "enabled", "on", "1":
			return true
		}
	}
	return false
}

func intField(m map[string]json.RawMessage, keys ...string) int {
	raw, ok := first(m, keys...)
	if !ok {
		return 0
	}
	var i int
	if json.Unmarshal(raw, &i) == nil {
		return i
	}
	var f float64
	if json.Unmarshal(raw, &f) == nil {
		return int(f)
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		var parsed int
		if _, err := fmt.Sscanf(s, "%d", &parsed); err == nil {
			return parsed
		}
	}
	return 0
}

func formatRate(m map[string]json.RawMessage, keys ...string) string {
	raw, ok := first(m, keys...)
	if !ok {
		return ""
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var i int
	if json.Unmarshal(raw, &i) == nil {
		return fmt.Sprintf("%d/min", i)
	}
	var f float64
	if json.Unmarshal(raw, &f) == nil {
		return fmt.Sprintf("%.2g/min", f)
	}
	return ""
}

func stringDefault(s, fallback string) string {
	if s != "" {
		return s
	}
	return fallback
}
