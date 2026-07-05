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

	ShortMode    bool
	SkipConfirm  bool
	FollowupMode bool
	FindingIndex int
}

// StartSessionShimCmd maps a descriptor onto the existing StartTerminalCmd. It
// is the single spawn path for both the human-modal and queue routes. Chat
// descriptors take the chat prompt branch; spec and implement descriptors take
// the spec branch (a real implement prompt arrives with the generalized spawn
// Cmd, which also retires this shim).
func StartSessionShimCmd(d SessionDescriptor, projectDir string, width, height int, knowledgeDir string) tea.Cmd {
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
	)
}
