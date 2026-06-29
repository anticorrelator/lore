// Package settings: coordinator.go is the single editing/navigation
// coordinator for the configurator. It owns focus (which slot, and which
// control inside the compact embed, receives keystrokes), edit-mode entry
// (whether Enter/i/e and j/k reach the focused widget as editor input or act
// as navigation), navigation (slot stepping, container descent, the embed's
// flattened control list), and intent routing (translating each FieldIntent
// a widget emits into the model's write surface).
//
// The coordinator's boundary stops at routing: commit MECHANISMS remain
// polymorphic on SettingsModel — immediate/draft-buffered intents go through
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
// focused yet. Called on the first navigation keystroke; under the compact
// embed it also auto-enters the limited container so j/k land on the first
// real child row instead of an invisible top-level container.
func (c *coordinator) ensureInitialFocus() {
	if c.focusIdx >= 0 || len(c.m.allWidgetSlots()) == 0 {
		return
	}
	c.focusIdx = 0
	_ = c.m.allWidgetSlots()[0].Focus()
	c.autoEnterCompactEmbed()
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
			c.autoEnterCompactEmbed()
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

// autoEnterCompactEmbed enters the limited container under the compact-embed
// profile so navigation starts on the first real child row. Without this,
// the embed receives keys while focus sits on an invisible top-level
// container, making j/k appear unwired.
func (c *coordinator) autoEnterCompactEmbed() {
	if !c.m.compactEmbedActive() {
		return
	}
	panel, ok := c.m.limitedWidget().(*ClosedObjectSubPanel)
	if !ok || len(panel.children) == 0 {
		return
	}
	panel.focused = true
	panel.entered = true
	controls := c.compactEmbedControls(panel)
	if len(controls) > 0 {
		hasFocus := false
		for _, control := range controls {
			if control.Focused() {
				hasFocus = true
				break
			}
		}
		if !hasFocus {
			_ = controls[0].Focus()
		}
		return
	}
	if panel.cursor < 0 || panel.cursor >= len(panel.children) {
		panel.cursor = 0
	}
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

func (c *coordinator) replaceFocusedControl(w FieldWidget) {
	if c.m.compactEmbedActive() {
		if c.replaceCompactControl(w) {
			return
		}
	}
	c.replaceFocused(w)
}

// focusedCompactControl returns the focused control within the compact
// embed's flattened control list, or nil when the embed isn't active or no
// control holds focus.
func (c *coordinator) focusedCompactControl() FieldWidget {
	if !c.m.compactEmbedActive() {
		return nil
	}
	panel, ok := c.m.limitedWidget().(*ClosedObjectSubPanel)
	if !ok {
		return nil
	}
	for _, control := range c.compactEmbedControls(panel) {
		if control.Focused() {
			return control
		}
	}
	return nil
}

func (c *coordinator) replaceCompactControl(updated FieldWidget) bool {
	panel, ok := c.m.limitedWidget().(*ClosedObjectSubPanel)
	if !ok || updated == nil {
		return false
	}
	return replacePanelChildByDotPath(panel, updated)
}

func replacePanelChildByDotPath(panel *ClosedObjectSubPanel, updated FieldWidget) bool {
	for i, child := range panel.children {
		if child.DotPath() == updated.DotPath() {
			panel.children[i] = updated
			return true
		}
		if childPanel, ok := child.(*ClosedObjectSubPanel); ok {
			if replacePanelChildByDotPath(childPanel, updated) {
				return true
			}
		}
	}
	return false
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
	if c.stepCompactEmbedNavigation(delta) {
		c.ensureFocusedVisible()
		return
	}
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

// stepCompactEmbedNavigation moves focus through the embed's flattened
// control list. Reports true when the compact embed consumed the step.
func (c *coordinator) stepCompactEmbedNavigation(delta int) bool {
	if !c.m.compactEmbedActive() {
		return false
	}
	panel, ok := c.m.limitedWidget().(*ClosedObjectSubPanel)
	if !ok {
		return false
	}
	controls := c.compactEmbedControls(panel)
	if len(controls) == 0 {
		return true
	}
	current := -1
	for i, control := range controls {
		if control.Focused() {
			current = i
			break
		}
	}
	if current < 0 {
		current = 0
		_ = controls[current].Focus()
		return true
	}
	next := current + delta
	if next < 0 {
		next = 0
	}
	if next >= len(controls) {
		next = len(controls) - 1
	}
	if next == current {
		return true
	}
	if intent := controls[current].Blur(); intent != nil {
		c.routeIntent(intent)
	}
	_ = controls[next].Focus()
	panel.focused = true
	panel.entered = true
	return true
}

// compactEmbedControls flattens the limited panel's leaf controls into the
// compact embed's navigation order. The order mirrors the compact layout:
// simple leaves first, the harness-selection selector after its sibling
// leaves, and active-hours controls last (they render as the deferred
// windows block at the bottom of the embed).
func (c *coordinator) compactEmbedControls(panel *ClosedObjectSubPanel) []FieldWidget {
	var controls []FieldWidget
	var deferred []FieldWidget
	var walk func(w FieldWidget)
	walk = func(w FieldWidget) {
		if childPanel, ok := w.(*ClosedObjectSubPanel); ok {
			var localDeferred []FieldWidget
			for _, child := range childPanel.children {
				if childPanel.dotPath == "settlement.active_hours" {
					deferred = append(deferred, child)
					continue
				}
				if childPanel.dotPath == "settlement.harness_selection" && child.DotPath() == "settlement.harness_selection.eligible_frameworks" {
					localDeferred = append(localDeferred, child)
					continue
				}
				walk(child)
			}
			controls = append(controls, localDeferred...)
			return
		}
		controls = append(controls, w)
	}
	for _, child := range panel.children {
		walk(child)
	}
	controls = append(controls, deferred...)
	return controls
}

// focusOffset shifts focus by delta (+1 / -1), blurring the current focused
// widget and focusing the new one. Returns the FieldIntent emitted by the
// blurred widget (typically IntentDiscard for a draft-buffered widget that
// had a pending draft). Wraps at the ends.
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
	w := c.focusedWidget()
	if compactFocused := c.focusedCompactControl(); compactFocused != nil {
		w = compactFocused
	}
	return widgetConsumesNavRunes(w)
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
