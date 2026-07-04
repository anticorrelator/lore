// Package settings: container.go is the single container navigation
// contract. The three container widgets (AdvancedSection,
// ClosedObjectSubPanel, HarnessBlockPanel) embed containerBase and route
// their navigation gestures through its helpers, so the explicit-enter
// vocabulary — Enter descends one level, j/k steps within an entered level,
// Tab/Shift-Tab leaves-and-advances, Esc backs out one level — is defined
// once. Containers differ only in how they store children; everything else
// here operates on a `children []FieldWidget` snapshot.
package settings

import (
	tea "charm.land/bubbletea/v2"
)

// NavRuneConsumer is implemented by container widgets that need to delegate
// the j/k-vs-focus-step decision to a currently-active inner widget rather
// than answering for themselves. Container widgets (HarnessBlockPanel,
// ClosedObjectSubPanel) implement this so j/k typed into a child that is
// actively editing reaches the child rather than jumping focus to the next
// slot.
//
// Leaf widgets that toggle between an editing mode and a navigating mode
// (TextInput, NumericInput, ListEditor, OpenKeysetKVEditor) also implement
// this — they consume runes only while a draft is being typed; in nav mode
// they let j/k pass through for settings-level navigation.
type NavRuneConsumer interface {
	ConsumesNavRunes() bool
}

// NavStepper is implemented by container widgets that own multiple
// navigable rows. NavStep advances the container's internal cursor by
// `delta` (+1 forward, -1 backward) and returns:
//
//   - moved=true when the cursor moved one row internally, with `intent`
//     carrying any leave intent the just-blurred child wants to surface
//     (commit/reject/discard). The coordinator routes the intent and stops —
//     focusIdx (the top-level slot) does NOT change, so the containing
//     section frame keeps its bright rail.
//   - moved=false when the cursor is at the boundary (first row on -1,
//     last row on +1). The coordinator then advances focus to the next/prev
//     top-level slot via focusOffset.
type NavStepper interface {
	NavStep(delta int) (moved bool, intent *FieldIntent)
}

// NestedNavigator is implemented by container widgets whose children are only
// active after the user explicitly enters the container with Enter. It lets
// parent containers avoid recursive descent until each level has been opened.
type NestedNavigator interface {
	Entered() bool
}

// InnerFocusRanger is implemented by container widgets that render multiple
// navigable children and need the host viewport to track the *inner* cursor
// rather than the whole container. Returns (top, bottom) line indices of
// the inner-cursor child's region within the widget's own View() output
// (NOT within the rendered slot — the layout engine adds the section-frame
// offset).
//
// Without this, a HarnessBlockPanel taller than the viewport would have
// ensureFocusedVisible pin the panel's bottom (because the slot as a whole
// exceeds the viewport), leaving the user's actual cursor — at the top of
// the panel — off-screen.
//
// Returning (-1, -1) means "no inner cursor info; fall back to the slot's
// whole y-range" (e.g. the panel isn't focused).
type InnerFocusRanger interface {
	InnerFocusYRange() (int, int)
}

// widgetConsumesNavRunes is the single definition of the typing-vs-navigation
// decision for one widget: widgets that implement NavRuneConsumer answer for
// themselves (containers delegate to their focused child; two-mode leaves
// answer per their edit mode); everything else never consumes nav runes.
func widgetConsumesNavRunes(w FieldWidget) bool {
	if w == nil {
		return false
	}
	if cc, ok := w.(NavRuneConsumer); ok {
		return cc.ConsumesNavRunes()
	}
	return false
}

// containerBase carries the shared focus state of a container widget and
// implements the explicit-enter navigation contract over a children
// snapshot. Embedding promotes cursor/focused/entered, so containers (and
// their tests) keep addressing those fields directly.
type containerBase struct {
	cursor  int
	focused bool
	entered bool
}

// Entered satisfies NestedNavigator for every embedding container.
func (b *containerBase) Entered() bool { return b.entered }

// Focused satisfies the FieldWidget focus accessor for every embedding
// container.
func (b *containerBase) Focused() bool { return b.focused }

// consumesNavRunes delegates the j/k typing-vs-navigation decision to the
// child at the cursor. Before the container is entered no child is active,
// so navigation always wins.
func (b *containerBase) consumesNavRunes(children []FieldWidget) bool {
	if !b.entered || b.cursor < 0 || b.cursor >= len(children) {
		return false
	}
	return widgetConsumesNavRunes(children[b.cursor])
}

// enter opens the container one level: marks it entered and focuses the
// cursor child. Returns the child's Focus cmd.
func (b *containerBase) enter(children []FieldWidget) tea.Cmd {
	b.entered = true
	if b.cursor < 0 {
		b.cursor = 0
	}
	if b.cursor < len(children) {
		return children[b.cursor].Focus()
	}
	return nil
}

// blur clears focus state and blurs the cursor child, propagating any leave
// intent the child wants to surface.
func (b *containerBase) blur(children []FieldWidget) *FieldIntent {
	b.focused = false
	b.entered = false
	if b.cursor >= 0 && b.cursor < len(children) && children[b.cursor].Focused() {
		return children[b.cursor].Blur()
	}
	return nil
}

// navStep advances the cursor by delta within an entered container,
// blurring the previously-focused child and focusing the new one. Returns
// (false, nil) at the boundary so the coordinator can hop to the next
// top-level slot.
//
// Recursive descent: when the cursor child is itself an entered NavStepper
// (a nested container), the step is delegated to the child first; only when
// the child reports a boundary does this container's own cursor advance.
// Without this, panels nested inside panels would be unreachable past their
// first child after the nested panel was opened.
func (b *containerBase) navStep(children []FieldWidget, delta int) (bool, *FieldIntent) {
	if !b.focused || !b.entered || len(children) == 0 {
		return false, nil
	}
	if b.cursor >= 0 && b.cursor < len(children) {
		if cs, ok := children[b.cursor].(NavStepper); ok {
			if nn, ok := children[b.cursor].(NestedNavigator); ok && nn.Entered() {
				if moved, intent := cs.NavStep(delta); moved {
					return true, intent
				}
			}
		}
	}
	next := b.cursor + delta
	if next < 0 || next >= len(children) {
		return false, nil
	}
	intent := children[b.cursor].Blur()
	b.cursor = next
	_ = children[b.cursor].Focus()
	return true, intent
}

// tabStep is the Tab/Shift-Tab gesture: leave the cursor child via Blur and
// advance the cursor by delta, clamping at the container's ends. Returns the
// blurred child's intent for the host to route.
func (b *containerBase) tabStep(children []FieldWidget, delta int) *FieldIntent {
	if b.cursor < 0 || b.cursor >= len(children) {
		return nil
	}
	intent := children[b.cursor].Blur()
	next := b.cursor + delta
	if next >= 0 && next < len(children) {
		b.cursor = next
		_ = children[b.cursor].Focus()
	}
	return intent
}

// escStep is the Esc gesture for an entered container: forward Esc to the
// cursor child first. If the child consumes it by emitting an intent (e.g.
// IntentDiscard reverting a draft) that intent propagates unchanged; if the
// child is a still-entered nested container, it backed out one of its own
// levels and this container stays entered. Otherwise the child is blurred
// and this container exits its entered level — surfacing the child's
// IntentDiscard when a draft was reverted, or IntentNavigate when Esc only
// backed out of a nesting level (so committed leaf values are never treated
// as cleared/reverted).
func (b *containerBase) escStep(dotPath string, child FieldWidget, replace func(FieldWidget), msg tea.Msg) (tea.Cmd, *FieldIntent) {
	updated, cmd, intent := child.Update(msg)
	replace(updated)
	if intent != nil {
		return cmd, intent
	}
	if nested, ok := updated.(NestedNavigator); ok && nested.Entered() {
		return cmd, nil
	}
	if blurIntent := updated.Blur(); blurIntent != nil {
		b.entered = false
		return cmd, blurIntent
	}
	b.entered = false
	return cmd, &FieldIntent{DotPath: dotPath, Status: IntentNavigate}
}
