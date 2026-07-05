// Package inputmsg is the single home for the message classes every focused
// text input must receive regardless of how its host intercepts keys.
//
// The lore TUI's modals and inline editors all follow an intercept-then-default
// pattern: known keys are dispatched in a switch before a default branch
// forwards the rest to the focused textarea/textinput. That pattern has a
// message-type blind spot: bracketed paste arrives as tea.PasteMsg — not a
// key press — so a host that gates its intercept block on tea.KeyPressMsg
// silently drops pasted text into whatever routing lies beyond the modal.
//
// Contract for any host that owns a focused text input:
//
//  1. Route tea.PasteMsg to the input via ForwardPaste BEFORE the key-press
//     intercept block.
//  2. For multiline inputs (textarea), recognize the newline chord via
//     IsNewlineChord instead of hand-rolled key strings, so every surface
//     honors the same chords.
//
// paste_contract_test.go (tui package) walks every input-owning surface and
// fails if a new modal forgets either half of this contract.
package inputmsg

import (
	tea "charm.land/bubbletea/v2"
)

// Updatable is any Elm-style sub-model whose Update returns its own concrete
// type — bubbles' textarea.Model and textinput.Model both satisfy it, as do
// the lore TUI's own sub-models.
type Updatable[M any] interface {
	Update(msg tea.Msg) (M, tea.Cmd)
}

// ForwardPaste routes a bracketed-paste message to the focused text input.
// It reports false (without touching the input) for every other message
// type, so callers can invoke it unconditionally at the top of their
// intercept block:
//
//	if cmd, ok := inputmsg.ForwardPaste(&m.someInput, msg); ok {
//	    return m, cmd
//	}
func ForwardPaste[M Updatable[M]](input *M, msg tea.Msg) (tea.Cmd, bool) {
	if _, ok := msg.(tea.PasteMsg); !ok {
		return nil, false
	}
	var cmd tea.Cmd
	*input, cmd = (*input).Update(msg)
	return cmd, true
}

// IsNewlineChord reports whether the key press is the insert-newline chord
// for multiline text inputs: Shift+Enter, with Alt+Enter as the universal
// fallback for terminals that cannot report shift-modified Enter (only
// kitty-protocol terminals disambiguate it from plain Enter).
func IsNewlineChord(k tea.KeyPressMsg) bool {
	s := k.String()
	return s == "shift+enter" || s == "alt+enter"
}
