// Package settings: layout.go is the single layout engine for the
// configurator body. One render path (renderBodyContent → renderedSlots)
// serves every host surface: each slot is wrapped in an open section frame
// (header rule + left rail) via renderSection; widgets render their own
// View() with descriptions and per-row chrome.
//
// computeFocusedYRange lives here because its line accounting MUST match
// what renderBodyContent emits; drift between the two desyncs
// scroll-to-focus.
package settings

import (
	"strings"

	"github.com/anticorrelator/lore/tui/internal/style"
)

// renderBodyContent builds the unwrapped body string. Pulled out of View() so
// the viewport can SetContent on the same string each render without re-
// computing inside the viewport's own render path.
//
// Sections are emitted via renderedSlots() so renderBodyContent and
// computeFocusedYRange share a single rendering path. If the section frame's
// line count diverges between the two, scroll-to-focus drifts (a regression
// codex's consult flagged for the prior side-by-side rendering paths).
func (m *SettingsModel) renderBodyContent() string {
	var b strings.Builder

	for i, slot := range m.renderedSlots() {
		if i > 0 {
			b.WriteString("\n\n")
		}
		b.WriteString(slot)
	}

	// Status line.
	if m.statusMsg != "" {
		b.WriteString("\n\n")
		if m.statusIsError {
			b.WriteString(style.SevBlocking.Render(m.statusMsg))
		} else {
			b.WriteString(style.Dim.Render(m.statusMsg))
		}
	}

	return strings.TrimRight(b.String(), "\n")
}

// renderedSlots returns one rendered string per focusable slot in
// allWidgetSlots() order. Each top section and each schema-driven top-level
// widget gets exactly one entry — the focus index from focusIdx maps directly
// to a position in this slice, which is what makes computeFocusedYRange
// possible without re-walking the rendering logic.
//
// Each slot is wrapped in an open section frame (header rule + left rail) by
// renderSection, EXCEPT for leaf schema-driven widgets (single-row inputs)
// which render bare.
func (m *SettingsModel) renderedSlots() []string {
	if m.limitDotPath != "" {
		w := m.limitedWidget()
		if w == nil {
			return nil
		}
		for _, ts := range m.topSections {
			if ts.widget.DotPath() == m.limitDotPath {
				return []string{m.renderSection(ts.name, ts.widget.View(), m.nav.focusIdx == 0)}
			}
		}
		title, body, framed := schemaSectionParts(w)
		if framed {
			return []string{m.renderSection(title, body, m.nav.focusIdx == 0)}
		}
		return []string{body}
	}

	out := make([]string, 0, len(m.topSections)+len(m.widgets))
	cursor := 0

	for _, ts := range m.topSections {
		focused := m.nav.focusIdx == cursor
		body := ts.widget.View()
		out = append(out, m.renderSection(ts.name, body, focused))
		cursor++
	}

	for _, w := range m.widgets {
		focused := m.nav.focusIdx == cursor
		title, body, framed := schemaSectionParts(w)
		if framed {
			out = append(out, m.renderSection(title, body, focused))
		} else {
			out = append(out, body)
		}
		cursor++
	}

	return out
}

// computeFocusedYRange returns the inclusive [top, bottom] line indices of
// the currently-focused slot within the rendered body. Returns (-1, -1) when
// nothing is focused. Used by ensureFocusedVisible to decide whether the
// viewport needs to scroll on focus change.
//
// Routes through renderedSlots() so the line counts MUST match what
// renderBodyContent emits — codex's consult flagged drift between these two
// paths as a load-bearing risk.
//
// Container widgets that implement InnerFocusRanger refine the result: when
// the focused slot is a multi-child container (HarnessBlockPanel today),
// the y-range narrows to the inner-cursor child's region within the slot.
// Without that refinement, a tall panel scrolls its bottom into view while
// the user's cursor sits at the top, leaving the focused row off-screen.
func (m *SettingsModel) computeFocusedYRange() (int, int) {
	if m.nav.focusIdx < 0 {
		return -1, -1
	}
	slots := m.renderedSlots()
	if m.nav.focusIdx >= len(slots) {
		return -1, -1
	}
	const sep = "\n\n" // joiner between slots (must match renderBodyContent)
	// Lines added by the joiner BETWEEN two non-empty slots = newline count - 1.
	// Each joiner "\n\n" carries 2 newline chars but only the inner gap counts
	// as new content (one blank line between slots) — the outer newlines are
	// the line terminators for the adjacent slots' content. Computing as
	// `strings.Count(sep, "\n")` would over-count by 1 per joiner, drifting
	// the focused y-range a line further down per preceding slot. With many
	// slots, that drift pushes the focused row off-screen and ensureFocusedVisible
	// pins the viewport to the wrong line — the user sees no cursor and pressing
	// k only retreats the over-shoot one slot at a time.
	gapLines := strings.Count(sep, "\n") - 1
	cursor := 0
	for i, slot := range slots {
		if i > 0 {
			cursor += gapLines
		}
		lines := lineCount(slot)
		if i == m.nav.focusIdx {
			// Refine for container widgets that report inner-cursor ranges.
			// Top sections are ALWAYS framed by renderSection, which prepends
			// exactly one header line before the widget's body — so the
			// slot-relative position of the widget's own line 0 is `cursor+1`.
			//
			// Schema-driven widgets at top level may render bare (unframed) per
			// schemaSectionParts; those don't implement InnerFocusRanger today,
			// so the +1 offset doesn't fire incorrectly. If a future bare widget
			// implements InnerFocusRanger, this branch would over-shift by 1 —
			// add a "framed" hint to renderedSlots if/when that case arises.
			if focused := m.nav.focusedWidget(); focused != nil {
				if r, ok := focused.(InnerFocusRanger); ok {
					if top, bottom := r.InnerFocusYRange(); top >= 0 {
						return cursor + m.focusedWidgetBodyOffset() + top, cursor + m.focusedWidgetBodyOffset() + bottom
					}
				}
			}
			return cursor, cursor + lines - 1
		}
		cursor += lines
	}
	return -1, -1
}

// lineCount returns the number of visual lines in s. Empty string is 0; a
// non-empty string has at least one line. Counts '\n' chars and adds 1 for
// the implicit trailing line. Used by computeFocusedYRange.
func lineCount(s string) int {
	if s == "" {
		return 0
	}
	return strings.Count(s, "\n") + 1
}

// focusedWidgetBodyOffset is the number of chrome lines renderSection
// prepends before the focused widget's own first line (the frame header).
func (m *SettingsModel) focusedWidgetBodyOffset() int {
	return 1
}

// schemaSectionParts extracts (title, body, framed) for a schema-driven
// top-level widget. Container widgets (ClosedObjectSubPanel via BodyViewer,
// OpenKeysetKVEditor, ListEditor) get a section frame whose header carries
// the field name; leaf widgets render bare so single-row inputs don't pay
// the chrome cost of a frame around one line.
//
// The title comes from the widget's first dot-path segment (top-level field
// name) — for nested sub-panels rendered inside a parent's body, the parent
// retains its existing label-rendering inside the frame body, untouched.
func schemaSectionParts(w FieldWidget) (title, body string, framed bool) {
	dotPath := w.DotPath()
	title = topLevelName(dotPath)
	if bv, ok := w.(BodyViewer); ok {
		return title, bv.ViewBody(), true
	}
	// Non-BodyViewer widgets render their full View(). Whether they get a
	// frame depends on whether they're container-shaped — we use a type
	// switch rather than a method so leaf widgets stay free of an interface
	// they have no business implementing.
	switch w.(type) {
	case *ListEditor:
		return title, w.View(), true
	}
	// Leaf widget (TextInput / NumericInput / ToggleRow / EnumSelector at
	// top level). Render bare; the section frame would be visual overhead
	// for a single row.
	return "", w.View(), false
}

// topLevelName returns the first segment of a dot-path, used as the section
// title for schema-driven top-level widgets. Empty string when dotPath is
// empty.
func topLevelName(dotPath string) string {
	if dotPath == "" {
		return ""
	}
	if idx := strings.IndexByte(dotPath, '.'); idx >= 0 {
		return dotPath[:idx]
	}
	return dotPath
}

// renderSection wraps `body` in an open section frame:
//
//	╭─ title ──────────────...
//	│ body line 1
//	│ body line 2
//
// The rail color tracks `focused`: dim by default, bright when this section
// holds the focused widget — so the user can see at a glance which section
// their keystrokes affect. The trailing rule fills the section header out to
// the body width pushed by SetSize, falling back to a 60-col default when the
// host hasn't sized the model yet.
//
// Per D3, every style is a package-init value from tui/internal/style — no
// lipgloss.Style is allocated here. Per the codex consult, this idiom replaces
// the old activeTab pill on top-section labels (which read like tab navigation
// rather than a section header).
func (m *SettingsModel) renderSection(title, body string, focused bool) string {
	rail := style.SectionRail
	if focused {
		rail = style.SectionRailActive
	}

	width := m.wrapWidth
	if width <= 0 {
		width = 60
	}

	// Header: ╭─ title ────...
	var header strings.Builder
	header.WriteString(rail.Render("╭─ "))
	header.WriteString(style.SectionTitle.Render(title))
	header.WriteByte(' ')
	// Fill the remainder with ─ characters. "╭─ " (3) + title runes + " " (1)
	// already consumed; clamp to ≥1 to avoid negative repeat counts on very
	// narrow widths.
	used := 3 + runeCount(title) + 1
	fillN := width - used
	if fillN < 1 {
		fillN = 1
	}
	header.WriteString(style.SectionRule.Render(strings.Repeat("─", fillN)))

	// Body: each line prefixed with rail glyph + space.
	railPrefix := rail.Render("│") + " "
	var b strings.Builder
	b.WriteString(header.String())
	if body != "" {
		for _, line := range strings.Split(body, "\n") {
			b.WriteByte('\n')
			b.WriteString(railPrefix)
			b.WriteString(line)
		}
	}
	return b.String()
}

// runeCount returns the rune count of s. Inlined here (rather than reaching
// into widgets.go's runeLen) so section framing stays decoupled from widget-
// internal rendering primitives.
func runeCount(s string) int {
	n := 0
	for range s {
		n++
	}
	return n
}
