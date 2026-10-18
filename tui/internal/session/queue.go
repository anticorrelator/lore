package session

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/anticorrelator/lore/tui/internal/config"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/anticorrelator/lore/tui/internal/worktree"
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

// Placement stance tokens name the strongest placement axis the enqueuing writer
// put on a request row, in descending precedence. The current writer writes only
// StanceRequiredDir and StancePreferredDir; rows from an older writer may carry
// the others. The token is descriptive: the claim pass never reads it.
const (
	StanceRequiredDir  = "required_dir"
	StanceTargeted     = "targeted"
	StancePreferredDir = "preferred_dir"
	StanceAny          = "any"
)

// Request is one queue row (pending or claimed). Nullable fields are pointers so
// an absent field, an explicit JSON null, and a present value stay distinct;
// numeric attempts stays an int so a strict decoder rejects a quoted "0".
type Request struct {
	Route          *config.Route   `json:"route,omitempty"`
	HostKey        string          `json:"host_key,omitempty"`
	RequestID      string          `json:"request_id"`
	Type           string          `json:"type"` // spec|implement|chat|worker
	Slug           *string         `json:"slug"`
	TargetInstance *string         `json:"target_instance"`
	Initiator      string          `json:"initiator"` // agent|human
	RequestedBy    string          `json:"requested_by"`
	RequestedAt    string          `json:"requested_at"`
	Attempts       int             `json:"attempts"`
	ExtraContext   json.RawMessage `json:"extra_context,omitempty"`
	LastError      *string         `json:"last_error,omitempty"`
	LastAttemptAt  *string         `json:"last_attempt_at,omitempty"`

	// AutoClose overrides the initiator-based auto-close gate at the TUI exit
	// ladder: nil defers to the initiator (agent auto-closes, human holds open),
	// a set value forces the outcome (a coordinator holds an agent session open,
	// or a human opts a session into auto-close). Pointer so absent stays
	// distinct from an explicit false.
	AutoClose *bool `json:"auto_close,omitempty"`

	// RoutingOverrides is a per-dispatch role→model map the claiming instance
	// exports as LORE_MODEL_<ROLE> env into the spawned session's PTY — riding
	// the resolver's top-of-precedence env layer so a coordinator's routing
	// judgment wins over settings policy with zero resolver changes. Absent
	// (omit-when-empty) leaves every role resolving against settings as before.
	RoutingOverrides map[string]string `json:"routing_overrides,omitempty"`

	// MinVintage is an optional minimum build vintage (ISO 8601 UTC timestamp) the
	// claiming host must meet: a host whose BuildTime is older leaves the row
	// pending. Filtered read-side at claim. Absent (omit-when-empty) imposes no
	// requirement; a host of unknown vintage cannot satisfy an explicit floor.
	// Pointer so absent stays distinct from an explicit value.
	MinVintage                  *string  `json:"min_vintage,omitempty"`
	RequiredRuntimeCapabilities []string `json:"required_runtime_capabilities,omitempty"`

	// Track is the spec depth selector carried to the descriptor's ShortMode
	// ("short" → short-track /spec). Valid only on a spec request (enforced at
	// enqueue). Absent (omit-when-empty) leaves the full track. Pointer so absent
	// stays distinct from an explicit value.
	Track *string `json:"track,omitempty"`

	// Model is the per-dispatch lead-model override composed into the spawn as the
	// harness's `--model` flag (the session lead is the top-level agent). Opaque
	// here — the value is validated only for non-emptiness at enqueue, never
	// against a model list (the candidate set is coordinator policy, not schema).
	// Absent (omit-when-empty) leaves the lead on the harness/settings default.
	Model *string `json:"model,omitempty"`

	// Framework is the per-request launch framework override. Opaque here — the
	// enqueue writer validates against the framework registry; the reader preserves
	// the supplied value and lets the spawn path decide how to consume it. Pointer
	// so absent stays distinct from an explicit value.
	Framework *string `json:"framework,omitempty"`

	// WorktreeIdentity is the complete versioned identity of the isolated tree
	// the harness must run in. Optional on disk for rolling schema compatibility;
	// fresh requests without one are allocated before launch, while a supplied
	// invalid identity is refused before process spawn.
	WorktreeIdentity *worktree.Identity `json:"worktree_identity,omitempty"`

	// WorktreeID and ExecutionDir are the manager-owned placement tuple for a
	// coordinated writer. They are optional only for rolling compatibility and
	// must be consumed all-or-nothing: WorktreeID names the manager registry row,
	// while ExecutionDir is the exact child cwd validated against that row and
	// WorktreeIdentity. Neither selects the source checkout; Checkout does.
	WorktreeID   *string `json:"worktree_id,omitempty"`
	ExecutionDir *string `json:"execution_dir,omitempty"`

	// PreferProjectDir is the physically-resolved checkout the caller named with
	// --prefer-dir or --prefer-cwd. The session is seeded from it when the row
	// carries no RequiredProjectDir (see Checkout). Absent (omit-when-empty) when
	// the caller named none. Pointer so absent stays distinct from an explicit
	// value.
	PreferProjectDir *string `json:"prefer_project_dir,omitempty"`

	// RequiredProjectDir is the physically-resolved checkout the row's work item
	// declares. It wins over PreferProjectDir in Checkout. Absent
	// (omit-when-empty) when the row names no declared checkout. Pointer so absent
	// stays distinct from an explicit value.
	RequiredProjectDir *string `json:"required_project_dir,omitempty"`

	// PlacementStance names the strongest placement axis on this row (see the
	// Stance tokens). It is carried for the journal, so a recorded request states
	// its stance instead of leaving the absence of other fields to imply it.
	// Pointer so absent stays distinct from an explicit value.
	PlacementStance *string `json:"placement_stance,omitempty"`

	// RequiredTargetRef is the branch the declared source checkout was on when the
	// request was enqueued (a full symbolic ref, e.g. refs/heads/main). Worktree
	// creation compares it against the branch it captures and refuses a mismatch
	// before writing anything to disk. Verification only — it never selects which
	// checkout a session is seeded from. Pointer so absent stays distinct from an
	// explicit value.
	RequiredTargetRef *string `json:"required_target_ref,omitempty"`

	// SkipConfirm overrides the queue-spawn autonomy default: nil defers to that
	// default (skip confirmation gates — autonomous), a set value forces the
	// outcome (true autonomous, false gated so every confirmation gate becomes a
	// coordinator send window). Pointer so absent stays distinct from explicit
	// false, preserving the historical always-true queue-spawn behavior.
	SkipConfirm *bool `json:"skip_confirm,omitempty"`

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

// SessionSlug returns the session identity a claimed request must use. New
// unscoped chat requests persist this slug at enqueue; the derivation here keeps
// legacy pending/claimed rows with a null slug addressable when a newer TUI
// claims them. Explicit slugs — including every worker's <item>--w<n> identity —
// are returned byte-for-byte.
func (r Request) SessionSlug() string {
	if slug := r.SlugValue(); slug != "" || r.Type != "chat" {
		return slug
	}
	suffix := r.RequestID
	if i := strings.LastIndexByte(suffix, '-'); i >= 0 {
		suffix = suffix[i+1:]
	}
	if suffix == "" {
		return ""
	}
	return "chat-" + strings.ToLower(suffix)
}

// TargetValue returns the instance the row was addressed to, or "" when it
// names none.
func (r Request) TargetValue() string {
	if r.TargetInstance == nil {
		return ""
	}
	return *r.TargetInstance
}

// MinVintageValue returns the minimum-vintage requirement or "" for none.
func (r Request) MinVintageValue() string {
	if r.MinVintage == nil {
		return ""
	}
	return *r.MinVintage
}

// TrackValue returns the spec track selector or "" when absent.
func (r Request) TrackValue() string {
	if r.Track == nil {
		return ""
	}
	return *r.Track
}

// ModelValue returns the lead-model override or "" when absent.
func (r Request) ModelValue() string {
	if r.Model == nil {
		return ""
	}
	return *r.Model
}

// FrameworkValue returns the launch framework override or "" when absent.
func (r Request) FrameworkValue() string {
	if r.Framework == nil {
		return ""
	}
	return *r.Framework
}

// WorktreeIDValue returns the manager-owned worktree id or "" when absent.
func (r Request) WorktreeIDValue() string {
	if r.WorktreeID == nil {
		return ""
	}
	return *r.WorktreeID
}

// ExecutionDirValue returns the hard child cwd or "" when absent.
func (r Request) ExecutionDirValue() string {
	if r.ExecutionDir == nil {
		return ""
	}
	return *r.ExecutionDir
}

// PreferProjectDirValue returns the soft project-dir preference or "" when absent.
func (r Request) PreferProjectDirValue() string {
	if r.PreferProjectDir == nil {
		return ""
	}
	return *r.PreferProjectDir
}

// RequiredProjectDirValue returns the hard project-dir requirement or "" when absent.
func (r Request) RequiredProjectDirValue() string {
	if r.RequiredProjectDir == nil {
		return ""
	}
	return *r.RequiredProjectDir
}

// PlacementStanceValue returns the placement stance token or "" when absent.
func (r Request) PlacementStanceValue() string {
	if r.PlacementStance == nil {
		return ""
	}
	return *r.PlacementStance
}

// Checkout is the source checkout the row names: its required_project_dir, else
// its prefer_project_dir, else "". A store host seeds the session from it.
func (r Request) Checkout() string {
	if dir := r.RequiredProjectDirValue(); dir != "" {
		return dir
	}
	return r.PreferProjectDirValue()
}

// RequiredTargetRefValue returns the required source branch or "" when absent.
func (r Request) RequiredTargetRefValue() string {
	if r.RequiredTargetRef == nil {
		return ""
	}
	return *r.RequiredTargetRef
}

// ExtraContextText extracts a free-text launch context from the request's
// extra_context object, or "" when absent. It reads a "prompt" or "text" key, or
// "dispatch_guidance" — the key session-request.sh wraps a plain-text/file
// --context in. A worker session's whole brief arrives this way (the chaperone
// points --context at a plain brief file), so surfacing dispatch_guidance is what
// carries the brief to buildInitialPrompt. Prompt composition proper is the spawn
// Cmd's job; this only surfaces the string it appends.
func (r Request) ExtraContextText() string {
	if len(r.ExtraContext) == 0 {
		return ""
	}
	var obj struct {
		Prompt           string `json:"prompt"`
		Text             string `json:"text"`
		DispatchGuidance string `json:"dispatch_guidance"`
	}
	if err := json.Unmarshal(r.ExtraContext, &obj); err != nil {
		return ""
	}
	if obj.Prompt != "" {
		return obj.Prompt
	}
	if obj.Text != "" {
		return obj.Text
	}
	return obj.DispatchGuidance
}

// PositionContext retains preparation or a published reference for validation at spawn.
func (r Request) PositionContext() json.RawMessage {
	var obj map[string]json.RawMessage
	if json.Unmarshal(r.ExtraContext, &obj) != nil {
		return nil
	}
	for _, key := range []string{"position_preparation", "position_dispatch"} {
		if _, ok := obj[key]; ok {
			return append(json.RawMessage(nil), r.ExtraContext...)
		}
	}
	return nil
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

// ScanPending reads every valid pending row and discards scan diagnostics.
func ScanPending(sessionsDir string) []Request {
	rows, _ := ScanPendingWithDiagnostics(sessionsDir)
	return rows
}

// ScanPendingWithDiagnostics returns valid pending rows and corrupt exclusions.
func ScanPendingWithDiagnostics(sessionsDir string) ([]Request, []Diagnostic) {
	return scanDir(PendingDir(sessionsDir), "queue-pending")
}

// ClaimedRow pairs a claimed request with its file mtime — the incomplete-claim
// reclaim rule keys off the file mtime, not a body field.
type ClaimedRow struct {
	Request Request
	ModTime time.Time
}

// ScanClaimed reads every claimed row with its file mtime.
func ScanClaimed(sessionsDir string) []ClaimedRow {
	rows, _ := ScanClaimedWithDiagnostics(sessionsDir)
	return rows
}

// ScanClaimedWithDiagnostics returns valid claimed rows and corrupt exclusions.
func ScanClaimedWithDiagnostics(sessionsDir string) ([]ClaimedRow, []Diagnostic) {
	matches, err := filepath.Glob(filepath.Join(ClaimedDir(sessionsDir), "*.json"))
	if err != nil {
		return nil, nil
	}
	var out []ClaimedRow
	var diagnostics []Diagnostic
	for _, path := range matches {
		fi, err := os.Stat(path)
		if err != nil {
			continue
		}
		req, diagnostic, ok := readRow(path, "queue-claimed")
		if !ok {
			if diagnostic != nil {
				diagnostics = append(diagnostics, *diagnostic)
			}
			continue
		}
		out = append(out, ClaimedRow{Request: req, ModTime: fi.ModTime()})
	}
	return out, diagnostics
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
	req, _, ok := readRow(claimedPath(sessionsDir, id), "queue-claimed")
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
	req, _, ok := readRow(claimedPath(sessionsDir, id), "queue-claimed")
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

// TransitionEvent names one durable queue transition QueueTickForStoreHost
// performed, so the caller can emit the matching journal row after the fact.
type TransitionEvent struct {
	Slug        string
	SessionType string
	Initiator   string
	RequestID   string
	Reason      string // reclaim/abandon reason; "" when not applicable
}

// QueueTickResult reports every durable change one QueueTickForStoreHost pass
// made. The caller journals Reclaimed/Abandoned, then journals `claimed` and
// spawns from Claimed when it is non-nil.
type QueueTickResult struct {
	Reclaimed   []TransitionEvent
	Abandoned   []TransitionEvent
	Claimed     *Request
	Diagnostics []Diagnostic
}

// QueueTickForStoreHost performs one queue pass for the store host myName, which
// holds hostKey and serves every checkout of one store. It reads only rows
// carrying hostKey, and claims such a row whatever instance it names:
//
//  1. Reclaim sweep: claimed rows whose claim never completed (missing
//     claimed_by/claimed_at, file older than reclaimAfter), whose claimer is no
//     longer live (claimed_at older than reclaimAfter), or whose claimer is a
//     dead predecessor of this host are returned to pending.
//  2. Claim/abandon: a pending row is skipped while it needs a runtime
//     capability this build lacks, a vintage this host does not meet, or a
//     retry backoff that has not elapsed. A row that has reached MaxAttempts is
//     abandoned instead of claimed. An implement row waits for its plan doc, and
//     a row whose slug is already live here waits for it to free. Before the
//     claim, scope refuses a row whose checkout does not belong to the store or
//     that names none, and admit runs after that check; a refusal archives the
//     row, unless it is retryable, which leaves the row pending. The first
//     eligible row is claimed by atomic rename and its claim metadata is written.
//
// Every step's durable state change completes before it is reported, so the
// caller's journal append (which follows) can never precede the state it
// records. liveInstances is the set of instance names with fresh registry
// files; hasPlanDoc reports whether a slug has a plan doc (implement gate);
// slugLive reports whether a slug already has a live/in-flight session on this
// host (the eviction guard: claiming such a row would silently replace a
// running session, so the request is left pending until the slug frees). A nil
// slugLive imposes no such gate. myVintage is this host's build vintage
// (BuildTime, ISO 8601 UTC); "" means vintage-unknown, which cannot satisfy an
// explicit floor.
func QueueTickForStoreHost(sessionsDir, myName, myVintage, hostKey string, scope StoreScope, liveInstances map[string]bool, hasPlanDoc func(string) bool, slugLive func(string) bool, now time.Time, reclaimAfter time.Duration, admit func(Request) error) (QueueTickResult, error) {
	var res QueueTickResult
	if hostKey == "" {
		return res, errors.New("a store host claims only rows carrying its host key, and has none")
	}
	var err error
	res.Abandoned, err = recoverRejectedPending(sessionsDir)
	if err != nil {
		return res, err
	}

	claimedRows, claimedDiagnostics := ScanClaimedWithDiagnostics(sessionsDir)
	res.Diagnostics = append(res.Diagnostics, claimedDiagnostics...)
	for _, row := range claimedRows {
		if row.Request.HostKey != hostKey {
			continue
		}
		reason, reclaim := reclaimReason(row, liveInstances, now, reclaimAfter)
		if row.Request.ClaimedBy != nil && *row.Request.ClaimedBy != myName && !liveInstances[*row.Request.ClaimedBy] {
			reason, reclaim = "host-predecessor-dead", true
		}
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

	pendingRows, pendingDiagnostics := ScanPendingWithDiagnostics(sessionsDir)
	res.Diagnostics = append(res.Diagnostics, pendingDiagnostics...)
	for _, req := range pendingRows {
		if req.HostKey != hostKey {
			continue
		}
		if !claimable(req, myVintage, now) {
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
		// A worker request carries the derived slug <work-item-slug>--w<n>, which
		// has no plan doc of its own — it is intentionally NOT plan-gated here (do
		// not add "worker" to the gate above keyed on the derived slug; the base
		// work item's plan is guaranteed by the dispatcher). The eviction guard
		// below keys on that derived slug, distinct from the base slug, so a live
		// base session never blocks its workers and two workers never collide.
		if s := req.SessionSlug(); s != "" && slugLive != nil && slugLive(s) {
			continue // eviction guard: a session for this slug is already live here;
			// claiming would silently replace it, so leave the row pending until it frees
		}
		_, refusal := scope.Checkout(req)
		if refusal == nil && admit != nil {
			refusal = admit(req)
		}
		if refusal != nil {
			reason := "host admission: " + refusal.Error()
			var temporary interface{ Retryable() bool }
			if errors.As(refusal, &temporary) && temporary.Retryable() {
				res.Diagnostics = append(res.Diagnostics, Diagnostic{Source: "session-admission", Path: pendingPath(sessionsDir, req.RequestID), Message: reason})
				continue
			}
			req.LastError = &reason
			won, archiveErr := ArchiveRejectedPending(sessionsDir, req)
			if archiveErr != nil {
				return res, archiveErr
			}
			if won {
				res.Abandoned = append(res.Abandoned, TransitionEvent{RequestID: req.RequestID, Reason: reason, Slug: req.SessionSlug(), SessionType: req.Type, Initiator: req.Initiator})
			}
			continue
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

// claimable reports whether a host of build vintage myVintage may attempt this
// pending row at time now: the build supports every runtime capability the row
// requires, an option-bearing route meets a known vintage, the host satisfies
// any min_vintage floor, and a retried row has waited out its backoff.
func claimable(req Request, myVintage string, now time.Time) bool {
	for _, required := range req.RequiredRuntimeCapabilities {
		supported := false
		for _, capability := range RuntimeCapabilities() {
			if required == capability {
				supported = true
			}
		}
		if !supported {
			return false
		}
	}
	if req.Route != nil && len(req.Route.Options) > 0 {
		if _, err := time.Parse("2006-01-02T15:04:05Z", myVintage); err != nil {
			return false
		}
	}
	if !vintageOK(req.MinVintageValue(), myVintage) {
		return false
	}
	if req.Attempts > 0 && req.LastAttemptAt != nil {
		if at, ok := parseVintage(*req.LastAttemptAt); ok {
			delay := time.Duration(1<<min(req.Attempts, 5)) * time.Second
			if now.Sub(at) < delay {
				return false
			}
		}
	}
	return true
}

// StoreScope is what a store host needs to decide whether a row's checkout
// belongs to its store.
type StoreScope struct {
	// KnowledgeDir is the store directory, physically resolved.
	KnowledgeDir string
	// Pinned is set when the host was started with LORE_KNOWLEDGE_DIR naming
	// this store. resolve-repo.sh answers that pin for every directory, so a
	// pinned store skips the resolution check.
	Pinned bool
	// Resolver is the path of resolve-repo.sh.
	Resolver string
}

// retryableAdmission marks an admission failure caused by the host rather than
// the row, so the row stays pending instead of being archived.
type retryableAdmission struct{ error }

func (retryableAdmission) Retryable() bool { return true }

func (e retryableAdmission) Unwrap() error { return e.error }

// Checkout returns the physically resolved checkout req names, or an error
// saying why it does not belong to this store. A checkout belongs to the store
// when it is the top level of an existing git checkout, lies outside the store
// directory (so in neither _sessions/worktrees nor _coordination/worktrees),
// and resolve-repo.sh, run without LORE_KNOWLEDGE_DIR, resolves it to this
// store; a pinned store skips that last clause. A failure to run git or the
// resolver at all is the host's fault and is retryable; every other failure is
// a refusal of the row.
func (s StoreScope) Checkout(req Request) (string, error) {
	named := req.Checkout()
	if named == "" {
		return "", errors.New("the request names no checkout of this store (no required_project_dir or prefer_project_dir)")
	}
	if !filepath.IsAbs(named) {
		return "", fmt.Errorf("checkout %q is not an absolute path", named)
	}
	dir := config.NormalizeProjectDir(named)
	if st, err := os.Stat(dir); err != nil {
		return "", fmt.Errorf("checkout %q does not exist", named)
	} else if !st.IsDir() {
		return "", fmt.Errorf("checkout %q is not a directory", named)
	}
	store := config.NormalizeProjectDir(s.KnowledgeDir)
	if dir == store || strings.HasPrefix(dir, store+string(filepath.Separator)) {
		return "", fmt.Errorf("checkout %q lies inside knowledge store %s", named, store)
	}
	out, err := exec.Command("git", "-C", dir, "rev-parse", "--show-toplevel").Output()
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return "", fmt.Errorf("checkout %q is not a git checkout", named)
	}
	if err != nil {
		return "", retryableAdmission{fmt.Errorf("inspect checkout %q: %w", named, err)}
	}
	if top := config.NormalizeProjectDir(strings.TrimSpace(string(out))); top != dir {
		return "", fmt.Errorf("checkout %q is not the top level of its git checkout (%s is)", named, top)
	}
	if s.Pinned {
		return dir, nil
	}
	cmd := exec.Command("bash", s.Resolver, dir)
	cmd.Dir = dir
	cmd.Env = []string{}
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "LORE_KNOWLEDGE_DIR=") {
			cmd.Env = append(cmd.Env, kv)
		}
	}
	out, err = cmd.Output()
	if err != nil {
		return "", retryableAdmission{fmt.Errorf("resolve the knowledge store of checkout %q: %w", named, err)}
	}
	if resolved := config.NormalizeProjectDir(strings.TrimSpace(string(out))); resolved != store {
		return "", fmt.Errorf("checkout %q belongs to knowledge store %s, not %s", named, resolved, store)
	}
	return dir, nil
}

// vintageOK requires known, parseable runtime evidence when a floor is present.
// Requests without a floor retain unrestricted vintage compatibility.
func vintageOK(minVintage, myVintage string) bool {
	if minVintage == "" {
		return true
	}
	minT, ok1 := parseVintage(minVintage)
	myT, ok2 := parseVintage(myVintage)
	if !ok1 || !ok2 {
		return false
	}
	return !myT.Before(minT)
}

// parseVintage parses a vintage timestamp in the substrate's canonical UTC form
// or RFC 3339, reporting ok=false on any other shape so callers can degrade.
func parseVintage(s string) (time.Time, bool) {
	if t, err := time.Parse("2006-01-02T15:04:05Z", s); err == nil {
		return t, true
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t, true
	}
	return time.Time{}, false
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
func scanDir(dir, source string) ([]Request, []Diagnostic) {
	matches, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return nil, nil
	}
	var out []Request
	var diagnostics []Diagnostic
	for _, path := range matches {
		if req, diagnostic, ok := readRow(path, source); ok {
			out = append(out, req)
		} else if diagnostic != nil {
			diagnostics = append(diagnostics, *diagnostic)
		}
	}
	return out, diagnostics
}

// readRow decodes one request file and reports corruption to its caller.
func readRow(path, source string) (Request, *Diagnostic, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Request{}, nil, false
	}
	var rawFields map[string]json.RawMessage
	if err := json.Unmarshal(data, &rawFields); err != nil {
		diagnostic := corruptDiagnostic(source, path, err)
		return Request{}, &diagnostic, false
	}
	var req Request
	if err := json.Unmarshal(data, &req); err != nil {
		diagnostic := corruptDiagnostic(source, path, err)
		return Request{}, &diagnostic, false
	}
	if req.MinVintage != nil && *req.MinVintage != "" {
		if _, err := time.Parse("2006-01-02T15:04:05Z", *req.MinVintage); err != nil {
			diagnostic := corruptDiagnostic(source, path, fmt.Errorf("invalid min_vintage: %w", err))
			return Request{}, &diagnostic, false
		}
	}
	if routeRaw, present := rawFields["route"]; present {
		if string(routeRaw) == "null" {
			diagnostic := corruptDiagnostic(source, path, errors.New("canonical route must not be null"))
			return Request{}, &diagnostic, false
		}
		var routeValue any
		if err := json.Unmarshal(routeRaw, &routeValue); err != nil {
			diagnostic := corruptDiagnostic(source, path, err)
			return Request{}, &diagnostic, false
		}
		route, err := config.ParseCanonicalRoute(routeValue)
		if err != nil {
			diagnostic := corruptDiagnostic(source, path, fmt.Errorf("invalid route: %w", err))
			return Request{}, &diagnostic, false
		}
		if (req.Framework == nil) != (req.Model == nil) {
			diagnostic := corruptDiagnostic(source, path, errors.New("canonical route requires complete framework/model projections"))
			return Request{}, &diagnostic, false
		}
		if req.Framework != nil && (*req.Framework != route.Framework || *req.Model != route.Model) {
			diagnostic := corruptDiagnostic(source, path, errors.New("canonical route disagrees with framework/model projections"))
			return Request{}, &diagnostic, false
		}
		req.Route = &route
	} else if req.Framework != nil || req.Model != nil {
		if req.Framework == nil || req.Model == nil {
			diagnostic := corruptDiagnostic(source, path, errors.New("legacy route requires framework and model together"))
			return Request{}, &diagnostic, false
		}
		route, err := config.ParseCanonicalRoute(map[string]any{"framework": *req.Framework, "model": *req.Model})
		if err != nil {
			diagnostic := corruptDiagnostic(source, path, fmt.Errorf("invalid legacy route: %w", err))
			return Request{}, &diagnostic, false
		}
		req.Route = &route
	} else {
		diagnostic := corruptDiagnostic(source, path, errors.New("request has no canonical route or complete legacy framework/model pair; re-enqueue it"))
		return Request{}, &diagnostic, false
	}
	return req, nil, true
}

// writeRow marshals and atomically writes a request file.
func writeRow(path string, req Request) error {
	data, err := json.Marshal(req)
	if err != nil {
		return fmt.Errorf("marshal request %q: %w", req.RequestID, err)
	}
	return atomicWrite(path, data)
}
