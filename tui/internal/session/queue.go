package session

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// ReclaimAfter is the age past which a claimed row is returned to pending when
// its claimer is dead (stale) or its claim never completed (incomplete). It is
// measured against claimed_at for a completed-but-stale claim and against the
// file mtime for an incomplete one.
const ReclaimAfter = 60 * time.Second

// MaxAttempts is the claim/spawn attempt ceiling. A pending row that reaches it
// is abandoned rather than claimed again; the journal row is its dead-letter.
const MaxAttempts = 3

// Reclaim reason strings carried on request_reclaimed journal rows.
const (
	ReasonStaleInstance   = "stale_instance"
	ReasonIncompleteClaim = "incomplete_claim"
)

// Request is one queue row (pending or claimed). Nullable fields are pointers so
// an absent field, an explicit JSON null, and a present value stay distinct;
// numeric attempts stays an int so a strict decoder rejects a quoted "0".
type Request struct {
	RequestID      string          `json:"request_id"`
	Type           string          `json:"type"` // spec|implement|chat
	Slug           *string         `json:"slug"`
	TargetInstance *string         `json:"target_instance"`
	Initiator      string          `json:"initiator"` // agent|human
	RequestedBy    string          `json:"requested_by"`
	RequestedAt    string          `json:"requested_at"`
	Attempts       int             `json:"attempts"`
	ExtraContext   json.RawMessage `json:"extra_context,omitempty"`
	LastError      *string         `json:"last_error,omitempty"`
	LastAttemptAt  *string         `json:"last_attempt_at,omitempty"`

	// Present only on a claimed row; a claim is not active until both are set.
	ClaimedBy *string `json:"claimed_by,omitempty"`
	ClaimedAt *string `json:"claimed_at,omitempty"`
}

// SlugValue returns the slug or "" when null/absent.
func (r Request) SlugValue() string {
	if r.Slug == nil {
		return ""
	}
	return *r.Slug
}

// TargetValue returns the target instance or "" for "any instance".
func (r Request) TargetValue() string {
	if r.TargetInstance == nil {
		return ""
	}
	return *r.TargetInstance
}

// ExtraContextText extracts a free-text launch context from the request's
// extra_context object (a "prompt" or "text" key), or "" when absent. Prompt
// composition proper is the spawn Cmd's job; this only surfaces the string it
// appends.
func (r Request) ExtraContextText() string {
	if len(r.ExtraContext) == 0 {
		return ""
	}
	var obj struct {
		Prompt string `json:"prompt"`
		Text   string `json:"text"`
	}
	if err := json.Unmarshal(r.ExtraContext, &obj); err != nil {
		return ""
	}
	if obj.Prompt != "" {
		return obj.Prompt
	}
	return obj.Text
}

// RequestsDir is the queue root under a _sessions/ directory.
func RequestsDir(sessionsDir string) string {
	return filepath.Join(sessionsDir, "requests")
}

// PendingDir holds one file per waiting request.
func PendingDir(sessionsDir string) string {
	return filepath.Join(RequestsDir(sessionsDir), "pending")
}

// ClaimedDir holds one file per request an instance has claimed.
func ClaimedDir(sessionsDir string) string {
	return filepath.Join(RequestsDir(sessionsDir), "claimed")
}

func pendingPath(sessionsDir, id string) string {
	return filepath.Join(PendingDir(sessionsDir), id+".json")
}
func claimedPath(sessionsDir, id string) string {
	return filepath.Join(ClaimedDir(sessionsDir), id+".json")
}

// NewRequestID returns a "<timestamp>-<random>" id, unique enough to double as
// the row's filename stem.
func NewRequestID() string {
	b := make([]byte, 4)
	_, _ = rand.Read(b)
	return time.Now().UTC().Format("20060102T150405Z") + "-" + hex.EncodeToString(b)
}

// WritePending writes a request row into pending/ via tmp+rename. It is the
// primitive behind both enqueue (item 2 / tests) and return-to-pending.
func WritePending(sessionsDir string, req Request) error {
	if err := os.MkdirAll(PendingDir(sessionsDir), 0o755); err != nil {
		return fmt.Errorf("create pending dir: %w", err)
	}
	data, err := json.Marshal(req)
	if err != nil {
		return fmt.Errorf("marshal request %q: %w", req.RequestID, err)
	}
	return atomicWrite(pendingPath(sessionsDir, req.RequestID), data)
}

// ScanPending reads every pending row, excluding torn/corrupt files with a
// warning rather than aborting the scan.
func ScanPending(sessionsDir string) []Request {
	return scanDir(PendingDir(sessionsDir))
}

// ClaimedRow pairs a claimed request with its file mtime — the incomplete-claim
// reclaim rule keys off the file mtime, not a body field.
type ClaimedRow struct {
	Request Request
	ModTime time.Time
}

// ScanClaimed reads every claimed row with its file mtime.
func ScanClaimed(sessionsDir string) []ClaimedRow {
	matches, err := filepath.Glob(filepath.Join(ClaimedDir(sessionsDir), "*.json"))
	if err != nil {
		return nil
	}
	var out []ClaimedRow
	for _, path := range matches {
		fi, err := os.Stat(path)
		if err != nil {
			continue
		}
		req, ok := readRow(path)
		if !ok {
			continue
		}
		out = append(out, ClaimedRow{Request: req, ModTime: fi.ModTime()})
	}
	return out
}

// ClaimRequest attempts to claim a pending row by renaming it into claimed/.
// Rename on one filesystem is atomic, so exactly one racing instance wins; a
// loser observes the row already gone and gets (false, nil). This rename is the
// sole at-most-once guard for the whole substrate.
func ClaimRequest(sessionsDir, id string) (bool, error) {
	if err := os.MkdirAll(ClaimedDir(sessionsDir), 0o755); err != nil {
		return false, fmt.Errorf("create claimed dir: %w", err)
	}
	err := os.Rename(pendingPath(sessionsDir, id), claimedPath(sessionsDir, id))
	if err == nil {
		return true, nil
	}
	if errors.Is(err, os.ErrNotExist) {
		return false, nil // lost the race — another instance claimed it
	}
	return false, err
}

// WriteClaimMetadata stamps claimed_by/claimed_at onto a freshly-claimed row and
// rewrites it in place (tmp+rename). Until both fields are present the claim is
// not active; this call is what makes it so. It returns the updated row.
func WriteClaimMetadata(sessionsDir, id, claimedBy string) (Request, error) {
	req, ok := readRow(claimedPath(sessionsDir, id))
	if !ok {
		return Request{}, fmt.Errorf("claimed row %q missing or corrupt", id)
	}
	by := claimedBy
	at := nowISO()
	req.ClaimedBy = &by
	req.ClaimedAt = &at
	if err := writeRow(claimedPath(sessionsDir, id), req); err != nil {
		return Request{}, err
	}
	return req, nil
}

// ReadClaimed reads a single claimed row.
func ReadClaimed(sessionsDir, id string) (Request, error) {
	req, ok := readRow(claimedPath(sessionsDir, id))
	if !ok {
		return Request{}, fmt.Errorf("claimed row %q missing or corrupt", id)
	}
	return req, nil
}

// DeleteClaimed removes a claimed row (the spawned terminal state).
func DeleteClaimed(sessionsDir, id string) error {
	err := os.Remove(claimedPath(sessionsDir, id))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// ReturnToPending moves a claimed row back to pending with an updated body. The
// body is written over the claimed file first, then the file is renamed into
// pending — the rename is atomic, so the row is never present in both dirs at
// once (and two racing reclaimers cannot both win it).
func ReturnToPending(sessionsDir string, req Request) error {
	if err := os.MkdirAll(PendingDir(sessionsDir), 0o755); err != nil {
		return fmt.Errorf("create pending dir: %w", err)
	}
	if err := writeRow(claimedPath(sessionsDir, req.RequestID), req); err != nil {
		return err
	}
	return os.Rename(claimedPath(sessionsDir, req.RequestID), pendingPath(sessionsDir, req.RequestID))
}

// AbandonPending deletes a pending row (the attempts-ceiling terminal state).
func AbandonPending(sessionsDir, id string) error {
	err := os.Remove(pendingPath(sessionsDir, id))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// TransitionEvent names one durable queue transition QueueTick performed, so the
// caller can emit the matching journal row after the fact.
type TransitionEvent struct {
	RequestID string
	Reason    string // reclaim/abandon reason; "" when not applicable
}

// QueueTickResult reports every durable change one QueueTick made. The caller
// journals Reclaimed/Abandoned, then journals `claimed` and spawns from Claimed
// when it is non-nil.
type QueueTickResult struct {
	Reclaimed []TransitionEvent
	Abandoned []TransitionEvent
	Claimed   *Request
}

// QueueTick performs one queue maintenance pass against the substrate at
// sessionsDir on behalf of instance myName:
//
//  1. Reclaim sweep: claimed rows whose claim never completed (missing
//     claimed_by/claimed_at, file older than reclaimAfter) or whose claimer is
//     no longer live (claimed_at older than reclaimAfter) are returned to
//     pending.
//  2. Claim/abandon: pending rows are filtered by targeting (target == myName or
//     any) and by the implement→hasPlanDoc gate; a row that has already reached
//     MaxAttempts is abandoned instead of claimed. The first eligible row is
//     claimed by atomic rename and its claim metadata is written.
//
// Every step's durable state change completes before it is reported, so the
// caller's journal append (which follows) can never precede the state it
// records. liveInstances is the set of instance names with fresh registry
// files; hasPlanDoc reports whether a slug has a plan doc (implement gate).
func QueueTick(
	sessionsDir, myName string,
	liveInstances map[string]bool,
	hasPlanDoc func(slug string) bool,
	now time.Time,
	reclaimAfter time.Duration,
) (QueueTickResult, error) {
	var res QueueTickResult

	for _, row := range ScanClaimed(sessionsDir) {
		reason, reclaim := reclaimReason(row, liveInstances, now, reclaimAfter)
		if !reclaim {
			continue
		}
		req := row.Request
		req.ClaimedBy = nil // a reclaimed row goes back to pending clean
		req.ClaimedAt = nil
		msg := reason
		req.LastError = &msg
		if err := ReturnToPending(sessionsDir, req); err != nil {
			return res, fmt.Errorf("reclaim %q: %w", req.RequestID, err)
		}
		res.Reclaimed = append(res.Reclaimed, TransitionEvent{RequestID: req.RequestID, Reason: reason})
	}

	for _, req := range ScanPending(sessionsDir) {
		if !claimableBy(req, myName) {
			continue
		}
		if req.Attempts >= MaxAttempts {
			if err := AbandonPending(sessionsDir, req.RequestID); err != nil {
				return res, fmt.Errorf("abandon %q: %w", req.RequestID, err)
			}
			reason := ""
			if req.LastError != nil {
				reason = *req.LastError
			}
			res.Abandoned = append(res.Abandoned, TransitionEvent{RequestID: req.RequestID, Reason: reason})
			continue
		}
		if req.Type == "implement" && !hasPlanDoc(req.SlugValue()) {
			continue // gated: implement needs a plan doc before it can be claimed
		}
		won, err := ClaimRequest(sessionsDir, req.RequestID)
		if err != nil {
			return res, fmt.Errorf("claim %q: %w", req.RequestID, err)
		}
		if !won {
			continue // lost the race; try the next eligible row
		}
		claimed, err := WriteClaimMetadata(sessionsDir, req.RequestID, myName)
		if err != nil {
			return res, fmt.Errorf("write claim metadata %q: %w", req.RequestID, err)
		}
		res.Claimed = &claimed
		break // one claim per tick is enough — sessions run minutes
	}

	return res, nil
}

// claimableBy reports whether an instance may attempt this pending row: a row is
// claimable when its target is this instance or unset (any).
func claimableBy(req Request, myName string) bool {
	target := req.TargetValue()
	return target == "" || target == myName
}

// reclaimReason classifies a claimed row for the reclamation sweep, returning
// the journal reason and whether it should be returned to pending.
func reclaimReason(row ClaimedRow, liveInstances map[string]bool, now time.Time, reclaimAfter time.Duration) (string, bool) {
	req := row.Request
	// Incomplete claim: metadata never written. Age off the file mtime.
	if req.ClaimedBy == nil || req.ClaimedAt == nil || *req.ClaimedBy == "" || *req.ClaimedAt == "" {
		if now.Sub(row.ModTime) > reclaimAfter {
			return ReasonIncompleteClaim, true
		}
		return "", false
	}
	// Completed claim: reclaim only when the claimer is gone AND the claim has
	// aged past the window (a live claimer is spawning; leave it alone).
	if liveInstances[*req.ClaimedBy] {
		return "", false
	}
	claimedAt, err := time.Parse("2006-01-02T15:04:05Z", *req.ClaimedAt)
	if err != nil {
		// Unparseable claimed_at on a dead claimer — treat like an aged claim.
		return ReasonStaleInstance, true
	}
	if now.Sub(claimedAt) > reclaimAfter {
		return ReasonStaleInstance, true
	}
	return "", false
}

// scanDir reads every *.json row in dir, skipping torn/corrupt files.
func scanDir(dir string) []Request {
	matches, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return nil
	}
	var out []Request
	for _, path := range matches {
		if req, ok := readRow(path); ok {
			out = append(out, req)
		}
	}
	return out
}

// readRow decodes one request file, warning-and-excluding on corruption.
func readRow(path string) (Request, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Request{}, false
	}
	var req Request
	if err := json.Unmarshal(data, &req); err != nil {
		fmt.Fprintf(os.Stderr, "[session] warning: %s corrupt — %v\n", path, err)
		return Request{}, false
	}
	return req, true
}

// writeRow marshals and atomically writes a request file.
func writeRow(path string, req Request) error {
	data, err := json.Marshal(req)
	if err != nil {
		return fmt.Errorf("marshal request %q: %w", req.RequestID, err)
	}
	return atomicWrite(path, data)
}
