package work

import (
	"crypto/rand"
	"fmt"
	"sort"
	"strings"
)

// Session type vocabulary — the on-disk spec|implement|chat strings shared
// across the request queue, the journal, and SessionDescriptor.Type. Named here
// so the prompt switch and sessionType() key off one source instead of scattered
// string literals; the strings themselves stay the durable substrate contract.
const (
	SessionSpec      = "spec"
	SessionImplement = "implement"
	SessionChat      = "chat"
)

// SpecTrackShort is the request `track` value that selects a short-track spec
// (buildInitialPrompt composes "/spec short"). It is the only track value with a
// descriptor effect — an absent or "full" track leaves ShortMode false. Named
// here so the request→descriptor mapping keys off one source, not a literal.
const SpecTrackShort = "short"

// SessionDescriptor is the shape the session-spawn Cmd (StartTerminalCmd)
// consumes: the session Type plus the target item and its launch context. The
// human confirm modal and the agent request queue both build one and hand it to
// that single spawn path, so spawning is defined once regardless of who
// initiated it.
//
// The forward fields (Type, Slug, Title, ExtraContext, Initiator) are the
// durable contract. The mode flags below them (ShortMode, SkipConfirm,
// FollowupMode, FindingIndex) select which branch of buildInitialPrompt runs.
type SessionDescriptor struct {
	Type         string // spec|implement|chat
	Slug         string
	Title        string
	ExtraContext string
	Initiator    string // agent|human

	// AutoClose is the per-request override the exit ladder consults: nil defers
	// to Initiator (agent auto-closes, human holds open), a set value forces the
	// outcome. Carried from the request row through to the live session.
	AutoClose *bool

	// RoutingOverrides is the per-dispatch role→model map carried from the
	// request row to the spawn, where it becomes LORE_MODEL_<ROLE> env on the
	// session's PTY (see SessionEnv). Empty for human-modal spawns.
	RoutingOverrides map[string]string

	// Model is the per-dispatch lead-model override: the top-level agent of a
	// spec/implement session is the session lead, so a model chosen at spawn is
	// lead selection. Composed into the launch command as the harness's universal
	// `--model` flag at StartTerminalCmd (the same flag model_routing.tiers aliases
	// feed). Distinct from RoutingOverrides, which routes *sub-agent* roles via env.
	// Empty injects no flag, leaving the lead on the harness/settings default.
	Model string

	ShortMode    bool
	SkipConfirm  bool
	FollowupMode bool
	FindingIndex int
}

// SessionEnv is the hosting-session identity exported into the harness child's
// environment at PTY spawn. A child — a protocol terminal verb, a hook, or the
// agent itself — reads LORE_SESSION_* to self-identify its session rather than
// inferring it from the slug. The zero value exports nothing (a launch with no
// session identity to advertise).
type SessionEnv struct {
	Instance string // LORE_SESSION_INSTANCE
	Slug     string // LORE_SESSION_SLUG
	Type     string // LORE_SESSION_TYPE: spec|implement|chat

	// RoutingOverrides is a per-dispatch role→model map exported as
	// LORE_MODEL_<ROLE> — the resolver's top-precedence env layer (tranche-1 D2:
	// per-run direction always wins). This is delivery only; no resolver change.
	RoutingOverrides map[string]string
}

// vars returns the LORE_SESSION_* assignments for a populated identity, followed
// by one LORE_MODEL_<ROLE> per routing override. Empty fields are omitted so a
// partially-populated identity never exports a blank var (a downstream
// `[ -n "$LORE_SESSION_INSTANCE" ]` gate stays meaningful).
func (s SessionEnv) vars() []string {
	var out []string
	if s.Instance != "" {
		out = append(out, "LORE_SESSION_INSTANCE="+s.Instance)
	}
	if s.Slug != "" {
		out = append(out, "LORE_SESSION_SLUG="+s.Slug)
	}
	if s.Type != "" {
		out = append(out, "LORE_SESSION_TYPE="+s.Type)
	}
	// Sort roles for a deterministic env order. Each role→model becomes
	// LORE_MODEL_<ROLE> with the role uppercased and hyphens mapped to
	// underscores — byte-identical to scripts/lib.sh resolve_model_for_role's
	// env_var construction, so a hyphenated class-qualified role (worker-mechanical
	// → LORE_MODEL_WORKER_MECHANICAL) names the same var the resolver reads.
	roles := make([]string, 0, len(s.RoutingOverrides))
	for role := range s.RoutingOverrides {
		roles = append(roles, role)
	}
	sort.Strings(roles)
	for _, role := range roles {
		model := s.RoutingOverrides[role]
		if role == "" || model == "" {
			continue // never export a blank var; the env layer reads "" as unset
		}
		out = append(out, "LORE_MODEL_"+modelEnvSuffix(role)+"="+model)
	}
	return out
}

// modelEnvSuffix maps a role id to the LORE_MODEL_ env-var suffix: uppercase and
// hyphens to underscores. Mirrors scripts/lib.sh (uppercase + `tr '-' '_'`) so a
// hyphenated role resolves to a valid shell identifier that the resolver's env
// layer reads back exactly.
func modelEnvSuffix(role string) string {
	return strings.ToUpper(strings.ReplaceAll(role, "-", "_"))
}

// newSessionID returns a random RFC-4122 v4 UUID. A harness that binds its
// session artifact by a spawn-provided id (claude-code's --session-id) both
// requires a valid UUID and names its transcript <uuid>.jsonl, so generating the
// id here makes the teardown transcript path deterministic. Returns "" if the
// system CSPRNG is unavailable, in which case the caller passes no --session-id
// and the session closes duration-only.
func newSessionID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return ""
	}
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant 10
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
