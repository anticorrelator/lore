package work

import (
	tea "charm.land/bubbletea/v2"
)

// SessionDescriptor is the shape a generalized session-spawn Cmd consumes: the
// session Type plus the target item and its launch context. The human confirm
// modal and the agent request queue both build one and hand it to a single
// spawn path, so spawning is defined once regardless of who initiated it.
//
// The forward fields (Type, Slug, Title, ExtraContext, Initiator) are the
// durable contract. The flags below them are a bounded compatibility shim over
// the current StartTerminalCmd; they and StartSessionShimCmd are removed when
// the generalized spawn Cmd lands and callers pass the descriptor straight
// through. Prompt composition stays in buildInitialPrompt — these flags only
// select which branch of it runs.
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
}

// vars returns the LORE_SESSION_* assignments for a populated identity. Empty
// fields are omitted so a partially-populated identity never exports a blank
// var (a downstream `[ -n "$LORE_SESSION_INSTANCE" ]` gate stays meaningful).
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
	return out
}

// StartSessionShimCmd maps a descriptor onto the existing StartTerminalCmd. It
// is the single spawn path for both the human-modal and queue routes. Chat
// descriptors take the chat prompt branch; spec and implement descriptors take
// the spec branch (a real implement prompt arrives with the generalized spawn
// Cmd, which also retires this shim).
func StartSessionShimCmd(d SessionDescriptor, projectDir string, width, height int, knowledgeDir string, sessionEnv SessionEnv) tea.Cmd {
	chatMode := d.Type == "chat"
	return StartTerminalCmd(
		d.Slug,
		d.Title,
		projectDir,
		width,
		height,
		d.ExtraContext,
		d.ShortMode,
		chatMode,
		d.SkipConfirm,
		d.FollowupMode,
		knowledgeDir,
		d.FindingIndex,
		sessionEnv,
	)
}
