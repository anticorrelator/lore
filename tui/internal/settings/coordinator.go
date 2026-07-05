// Package settings: coordinator.go is the single editing/navigation
// coordinator for the configurator. It owns focus (which slot receives
// keystrokes), edit-mode entry (whether Enter/i/e and j/k reach the focused
// widget as editor input or act as navigation), navigation (slot stepping,
// container descent), and intent routing (translating each FieldIntent a
// widget emits into the model's write surface).
//
// The coordinator's boundary stops at routing: commit MECHANISMS remain
// polymorphic on SettingsModel — immediate and commit-on-leave intents go through
// routeCommit's validation + Patch, unset goes through routeUnset's Delete,
// and the per-harness enabled toggle bypasses intents entirely via the
// ToggleHarness shell-out (routeCommit rejects a stray IntentCommit on that
// path). The coordinator never writes settings itself.
package settings

import (
	"strings"

	tea "charm.land/bubbletea/v2"
)

// coordinator holds the focus cursor over SettingsModel's widget slots and
// implements every navigation gesture. It is constructed with the model at
// NewSettingsModel time and accesses model state (slots, limit path, layout
// profile, viewport) through the back-reference.
type coordinator struct {
	m *SettingsModel

	// focusIdx is -1 when nothing is focused; otherwise an index into the
	// combined topSections+widgets slot list (allWidgetSlots order).
	focusIdx int
}

// ensureInitialFocus installs focus on the first slot when nothing is
// focused yet. Called on the first navigation keystroke.
func (c *coordinator) ensureInitialFocus() {
	if c.focusIdx >= 0 || len(c.m.allWidgetSlots()) == 0 {
		return
	}
	c.focusIdx = 0
	_ = c.m.allWidgetSlots()[0].Focus()
	c.ensureFocusedVisible()
}

func (c *coordinator) focusedWidget() FieldWidget {
	all := c.m.allWidgetSlots()
	if c.focusIdx < 0 || c.focusIdx >= len(all) {
		return nil
	}
	return all[c.focusIdx]
}

// focusedDotPath returns the dot-path of the currently-focused widget, or ""
// when nothing is focused.
func (c *coordinator) focusedDotPath() string {
	w := c.focusedWidget()
	if w == nil {
		return ""
	}
	return w.DotPath()
}

// focusByDotPath moves focus to the widget with the matching dot-path. No-op
// when no widget matches (e.g., the path was excluded by a schema edit).
func (c *coordinator) focusByDotPath(dotPath string) {
	if c.m.limitDotPath != "" {
		if dotPath == c.m.limitDotPath && c.m.limitedWidget() != nil {
			c.focusIdx = 0
			_ = c.m.limitedWidget().Focus()
		} else {
			c.focusIdx = -1
		}
		return
	}
	all := c.m.allWidgetSlots()
	for i, w := range all {
		if w.DotPath() == dotPath {
			c.focusIdx = i
			_ = w.Focus()
			return
		}
	}
	c.focusIdx = -1
}

// replaceFocused updates the focused slot with a new widget value (Bubble
// Tea value-semantics dance: widgets return possibly-new values from
// Update). topSections vs widgets dispatch is handled internally.
func (c *coordinator) replaceFocused(w FieldWidget) {
	if c.m.limitDotPath != "" {
		for i, ts := range c.m.topSections {
			if ts.widget.DotPath() == c.m.limitDotPath {
				c.m.topSections[i].widget = w
				return
			}
		}
		for i, widget := range c.m.widgets {
			if widget.DotPath() == c.m.limitDotPath {
				c.m.widgets[i] = w
				return
			}
		}
		return
	}
	if c.focusIdx < 0 {
		return
	}
	if c.focusIdx < len(c.m.topSections) {
		c.m.topSections[c.focusIdx].widget = w
		return
	}
	idx := c.focusIdx - len(c.m.topSections)
	if idx < len(c.m.widgets) {
		c.m.widgets[idx] = w
	}
}

// stepRowNavigation advances focus by delta (+1 / -1) using hierarchical
// semantics:
//
//  1. At the outer boundary, j/k or tab move between top-level sections.
//  2. If the selected section has been entered with Enter, NavStep advances
//     within that container level. Nested containers only receive NavStep after
//     they have also been entered, so every Enter descends exactly one level.
//  3. If the focused leaf is actively editing, j/k are not intercepted here;
//     they are forwarded to the leaf as input.
func (c *coordinator) stepRowNavigation(delta int) {
	if stepper, ok := c.focusedWidget().(NavStepper); ok {
		if moved, intent := stepper.NavStep(delta); moved {
			if intent != nil {
				c.routeIntent(intent)
			}
			c.ensureFocusedVisible()
			return
		}
	}
	if c.m.limitDotPath != "" {
		c.ensureFocusedVisible()
		return
	}
	if intent := c.focusOffset(delta); intent != nil {
		c.routeIntent(intent)
	}
	c.ensureFocusedVisible()
}

// focusOffset shifts focus by delta (+1 / -1), blurring the current focused
// widget and focusing the new one. Returns the FieldIntent emitted by the
// blurred widget (commit/reject/discard when the widget has leave work).
// Wraps at the ends.
func (c *coordinator) focusOffset(delta int) *FieldIntent {
	if c.m.limitDotPath != "" {
		return nil
	}
	all := c.m.allWidgetSlots()
	if len(all) == 0 {
		return nil
	}
	var intent *FieldIntent
	if c.focusIdx >= 0 && c.focusIdx < len(all) {
		intent = all[c.focusIdx].Blur()
	}
	next := c.focusIdx + delta
	if next < 0 {
		next = len(all) - 1
	}
	if next >= len(all) {
		next = 0
	}
	c.focusIdx = next
	_ = all[next].Focus()
	return intent
}

// routeIntent translates a FieldIntent into the model's write surface per
// D5/D8/D9. Returns a tea.Cmd when the routing requires async work. The
// write mechanisms stay on SettingsModel (routeCommit / routeUnset) — the
// coordinator only dispatches.
func (c *coordinator) routeIntent(intent *FieldIntent) tea.Cmd {
	if intent == nil {
		return nil
	}
	switch intent.Status {
	case IntentCommit:
		return c.m.routeCommit(intent)
	case IntentReject:
		c.m.statusMsg = strings.Join(intent.Errors, "; ")
		c.m.statusIsError = true
		return nil
	case IntentUnset:
		c.m.routeUnset(intent)
		return nil
	case IntentDiscard:
		// No-op — widget already reverted its draft.
		return nil
	case IntentNavigate:
		// No-op — container navigation was consumed without clearing or
		// reverting any committed leaf value.
		return nil
	}
	return nil
}

// consumesNavRunes reports whether the focused widget is currently
// interpreting j/k as widget-internal input (typing or editor navigation).
// When true, j/k must NOT be intercepted for settings navigation — the
// keystrokes belong to the widget. The taxonomy:
//
//   - TextInput / NumericInput: consume only in edit mode. Focus alone is
//     row selection for navigation.
//   - ListEditor / OpenKeysetKVEditor: implement NavRuneConsumer with mode-
//     aware logic — consume only after Enter opens their editor mode. While
//     merely selected, they release j/k to settings navigation.
//   - Container widgets (HarnessBlockPanel, ClosedObjectSubPanel) implement
//     NavRuneConsumer by delegating to their currently-focused child, so
//     a TextInput nested inside a panel still gets its 'j' keystrokes once
//     it is in edit mode.
func (c *coordinator) consumesNavRunes() bool {
	return widgetConsumesNavRunes(c.focusedWidget())
}

// ensureFocusedVisible nudges the viewport so the currently-focused widget
// is within the visible window. No-op when the viewport hasn't been sized,
// when nothing is focused, or when focus is already in view.
func (c *coordinator) ensureFocusedVisible() {
	if !c.m.viewportInit || c.m.viewport.Height() <= 0 {
		return
	}
	top, bottom := c.m.computeFocusedYRange()
	if top < 0 {
		return
	}
	yo := c.m.viewport.YOffset()
	h := c.m.viewport.Height()
	if top < yo {
		c.m.viewport.SetYOffset(top)
	} else if bottom >= yo+h {
		c.m.viewport.SetYOffset(bottom - h + 1)
	}
}
