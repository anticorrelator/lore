// Package settings: layout.go is the single layout engine for the
// configurator body. One render path (renderBodyContent → renderedSlots)
// serves every host surface; the differences between the full modal and the
// settlement embed are expressed as a layoutProfile, not as a parallel
// render family.
//
// Profile behaviors:
//
//   - layoutFull: each slot is wrapped in an open section frame (header rule
//
//   - left rail) via renderSection; widgets render their own View() with
//     descriptions and per-row chrome.
//
//   - layoutCompactEmbed: the limited subtree renders dense — simple leaves
//     are joined into labeled rows at the root (general:/batch:) or gridded
//     into fixed-width columns inside nested panels, descriptions and the
//     section frame are suppressed (the host supplies the title), and
//     complex editors (active-hours windows, framework selectors) stay
//     full-width. Validation and persistence are NOT forked — the profile
//     changes layout only.
//
// computeFocusedYRange lives here because its line accounting MUST match
// what renderBodyContent emits; drift between the two desyncs
// scroll-to-focus.
package settings

import (
	"fmt"
	"strings"

	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/style"
)

// layoutProfile selects how the one layout engine arranges the widget tree.
type layoutProfile int

const (
	// layoutFull is the configurator modal: section frames, descriptions,
	// one slot per top-level widget.
	layoutFull layoutProfile = iota
	// layoutCompactEmbed is the dense embedded surface (settlement dock):
	// gridded/joined leaves, suppressed descriptions, no section frame.
	layoutCompactEmbed
)

// compactEmbedActive reports whether the compact-embed profile is in effect.
// The profile only changes rendering for a limited subtree — without
// LimitToDotPath there is no embed host, so the full layout applies.
func (m *SettingsModel) compactEmbedActive() bool {
	return m.profile == layoutCompactEmbed && m.limitDotPath != ""
}

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
// which render bare, and EXCEPT under the compact-embed profile, where the
// single limited slot renders through the compact widget walk instead.
func (m *SettingsModel) renderedSlots() []string {
	if m.limitDotPath != "" {
		w := m.limitedWidget()
		if w == nil {
			return nil
		}
		if m.profile == layoutCompactEmbed {
			return []string{m.renderCompactWidget(w)}
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
			if focused := m.nav.focusedWidget(); focused != nil && m.profile != layoutCompactEmbed {
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
// The compact-embed profile has no frame, so the offset is zero.
func (m *SettingsModel) focusedWidgetBodyOffset() int {
	if m.compactEmbedActive() {
		return 0
	}
	return 1
}

// ----------------------------------------------------------------------------
// Full profile: section framing.
// ----------------------------------------------------------------------------

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

// ----------------------------------------------------------------------------
// Compact-embed profile: dense limited-subtree rendering.
// ----------------------------------------------------------------------------

// renderCompactWidget renders one widget under the compact-embed profile.
// This is the profile's recursive walk entry: containers flatten or grid
// their leaves, descriptions are suppressed, and complex editors keep their
// full-width render minus the description block.
func (m *SettingsModel) renderCompactWidget(w FieldWidget) string {
	switch typed := w.(type) {
	case *ClosedObjectSubPanel:
		return m.compactPanelView(typed, typed.dotPath == m.limitDotPath)
	case *ListEditor:
		if typed.selector && !typed.editing {
			return m.compactSelectorView(typed)
		}
		cp := *typed
		cp.description = ""
		return cp.View()
	case *ActiveHoursRangesEditor:
		if !typed.editing {
			return m.compactActiveHoursRangesView(typed)
		}
		cp := *typed
		cp.description = ""
		return cp.View()
	case *OpenKeysetKVEditor:
		cp := *typed
		cp.description = ""
		return cp.View()
	case *AdvancedSection:
		return typed.View()
	default:
		if cell, ok := m.compactLeafCell(w); ok {
			return cell
		}
		return w.View()
	}
}

// compactPanelView renders a ClosedObjectSubPanel for the compact-embed
// profile. The root panel (topLevel) joins simple leaves into labeled
// general:/batch: rows; nested panels grid their leaf cells into fixed
// columns under a one-line header.
func (m *SettingsModel) compactPanelView(p *ClosedObjectSubPanel, topLevel bool) string {
	if topLevel {
		return m.compactRootPanelView(p)
	}

	var lines []string
	labelText := compactLabel(p.dotPath, p.label)
	label := p.styles.subLabel.Render(labelText)
	if p.focused {
		state := "[enter]"
		if p.entered {
			state = "[active]"
		}
		label = p.styles.cursor.Render(labelText) + " " + p.styles.dim.Render(state)
	}
	lines = append(lines, label)

	var cells []string
	flushCells := func() {
		if len(cells) == 0 {
			return
		}
		lines = append(lines, m.compactGridRows(cells)...)
		cells = nil
	}

	for _, child := range p.children {
		if cell, ok := m.compactLeafCell(child); ok {
			cells = append(cells, cell)
			continue
		}
		flushCells()
		childView := m.renderCompactWidget(child)
		if childView != "" {
			_, isPanel := child.(*ClosedObjectSubPanel)
			if (topLevel || isPanel) && len(lines) > 0 && lines[len(lines)-1] != "" {
				lines = append(lines, "")
			}
			lines = append(lines, strings.Split(childView, "\n")...)
		}
	}
	flushCells()

	return strings.TrimRight(strings.Join(lines, "\n"), "\n")
}

// compactRootPanelView renders the limited subtree's root panel: simple
// leaves merge into a labeled "general:" row (settlement batch controls get
// their own "batch:" row), nested panels collapse to summary rows, and
// active-hours window groups defer to the bottom of the embed.
func (m *SettingsModel) compactRootPanelView(p *ClosedObjectSubPanel) string {
	var lines []string
	var deferred []string
	var cells []string
	var batchCells []string
	flushCells := func() {
		if len(cells) == 0 {
			return
		}
		lines = append(lines, "general: "+strings.Join(compactTrimCells(cells), "  |  "))
		cells = nil
	}
	flushBatchCells := func() {
		if len(batchCells) == 0 {
			return
		}
		lines = append(lines, "batch: "+strings.Join(compactTrimCells(batchCells), "  |  "))
		batchCells = nil
	}

	for _, child := range p.children {
		if cell, ok := m.compactLeafCell(child); ok {
			if p.dotPath == "settlement" && compactSettlementBatchControl(child.DotPath()) {
				batchCells = append(batchCells, cell)
				continue
			}
			cells = append(cells, cell)
			continue
		}
		flushCells()
		flushBatchCells()
		if panel, ok := child.(*ClosedObjectSubPanel); ok {
			panelLine, panelDeferred := m.compactPanelSummaryWithDeferredWindows(panel)
			if panelLine != "" {
				lines = append(lines, strings.Split(panelLine, "\n")...)
			}
			deferred = append(deferred, panelDeferred...)
			continue
		}
		childView := m.renderCompactWidget(child)
		if childView != "" {
			lines = append(lines, strings.Split(childView, "\n")...)
		}
	}
	flushCells()
	flushBatchCells()
	lines = append(lines, deferred...)

	return strings.TrimRight(strings.Join(lines, "\n"), "\n")
}

func compactSettlementBatchControl(dotPath string) bool {
	switch dotPath {
	case "settlement.batch_size", "settlement.batch_recompute_min_interval_seconds":
		return true
	default:
		return false
	}
}

func (m *SettingsModel) compactPanelSummaryWithDeferredWindows(p *ClosedObjectSubPanel) (string, []string) {
	labelText := compactLabel(p.dotPath, p.label)
	label := p.styles.subLabel.Render(labelText)
	if p.focused {
		state := "[enter]"
		if p.entered {
			state = "[active]"
		}
		label = p.styles.cursor.Render(labelText) + " " + p.styles.dim.Render(state)
	}

	parts := []string{}
	var expanded []string
	var deferred []string
	var deferredWindowControls []string
	for _, child := range p.children {
		if cell, ok := m.compactLeafCell(child); ok {
			if p.dotPath == "settlement.active_hours" {
				deferredWindowControls = append(deferredWindowControls, strings.TrimSpace(cell))
				continue
			}
			parts = append(parts, strings.TrimSpace(cell))
			continue
		}
		switch typed := child.(type) {
		case *ListEditor:
			if typed.selector && !typed.editing {
				if p.dotPath == "settlement.harness_selection" && !m.compactActiveHoursRangesEditing() {
					expanded = append(expanded, m.compactSelectorBlockLines(typed)...)
				} else {
					parts = append(parts, strings.TrimSpace(m.compactSelectorLine(typed)))
				}
				continue
			}
		case *ActiveHoursRangesEditor:
			if !typed.editing {
				if p.dotPath == "settlement.active_hours" {
					deferred = append(deferred, compactActiveHoursGroupLines(labelText, m.compactActiveHoursWindowLines(typed), deferredWindowControls)...)
				} else {
					parts = append(parts, strings.TrimSpace(m.compactActiveHoursRangesLine(typed)))
				}
				continue
			}
			if p.dotPath == "settlement.active_hours" {
				deferred = append(deferred, compactActiveHoursGroupLines(labelText, m.compactActiveHoursEditLines(typed), deferredWindowControls)...)
				continue
			}
		}
		childView := m.renderCompactWidget(child)
		if childView != "" {
			expanded = append(expanded, strings.Split(childView, "\n")...)
		}
	}

	if len(parts) == 0 && len(expanded) == 0 && len(deferred) > 0 {
		return "", deferred
	}

	line := labelText + ":"
	if len(parts) > 0 {
		line += " " + strings.Join(parts, "  |  ")
	}
	if p.focused {
		state := "[enter]"
		if p.entered {
			state = "[active]"
		}
		line = p.styles.cursor.Render(line) + " " + p.styles.dim.Render(state)
	} else {
		line = label + ": " + strings.Join(parts, "  |  ")
	}
	lines := []string{line}
	lines = append(lines, expanded...)
	return strings.TrimRight(strings.Join(lines, "\n"), "\n"), deferred
}

// compactActiveHoursRangesEditing reports whether the settlement active-hours
// windows editor is currently in edit mode anywhere in the limited subtree.
// While it is, unrelated selector blocks collapse to one-liners so the
// bounded editing viewport keeps its vertical allowance.
func (m *SettingsModel) compactActiveHoursRangesEditing() bool {
	panel, ok := m.limitedWidget().(*ClosedObjectSubPanel)
	if !ok {
		return false
	}
	var walk func(FieldWidget) bool
	walk = func(w FieldWidget) bool {
		switch typed := w.(type) {
		case *ActiveHoursRangesEditor:
			return typed.dotPath == "settlement.active_hours.ranges" && typed.editing
		case *ClosedObjectSubPanel:
			for _, child := range typed.children {
				if walk(child) {
					return true
				}
			}
		}
		return false
	}
	return walk(panel)
}

func (m *SettingsModel) compactGridRows(cells []string) []string {
	if len(cells) == 0 {
		return nil
	}
	width := m.wrapWidth
	if width <= 0 {
		width = 80
	}
	gap := 2
	preferredColW := 34
	cols := width / (preferredColW + gap)
	if cols < 1 {
		cols = 1
	}
	if cols > 3 {
		cols = 3
	}
	if len(cells) < cols {
		cols = len(cells)
	}
	colW := preferredColW
	if cols == 1 || width < preferredColW {
		cols = 1
		colW = width
	}

	var rows []string
	for i := 0; i < len(cells); i += cols {
		end := i + cols
		if end > len(cells) {
			end = len(cells)
		}
		parts := make([]string, 0, end-i)
		for _, cell := range cells[i:end] {
			parts = append(parts, compactFitCell(cell, colW))
		}
		rows = append(rows, strings.Join(parts, strings.Repeat(" ", gap)))
	}
	return rows
}

// compactLeafCell renders a simple leaf (toggle, scalar input, enum) as a
// one-line cell suitable for joining or gridding, or reports false when the
// widget is not a simple leaf.
func (m *SettingsModel) compactLeafCell(w FieldWidget) (string, bool) {
	switch typed := w.(type) {
	case *ToggleRow:
		marker := "[ ]"
		if typed.current {
			marker = "[x]"
		}
		cell := fmt.Sprintf("%s %s", marker, typed.styles.label.Render(compactLabel(typed.dotPath, typed.label)))
		if !typed.present && typed.allowUnset {
			cell += " " + typed.styles.dim.Render("(default)")
		}
		if typed.focused {
			cell = typed.styles.cursor.Render(cell)
		}
		return cell, true
	case *TextInput:
		indicator := " "
		if typed.draft != typed.committed {
			indicator = typed.styles.pending.Render("*")
		}
		display := typed.draft
		if display == "" && !typed.focused {
			display = typed.styles.dim.Render(compactEmptyValue(typed.present, typed.allowUnset))
		}
		cursor := ""
		if typed.focused && typed.editing {
			cursor = "_"
		}
		cell := fmt.Sprintf("%s %s: %s%s", indicator, typed.styles.label.Render(compactLabel(typed.dotPath, typed.label)), typed.styles.value.Render(display), cursor)
		if typed.focused && !typed.editing {
			cell = typed.styles.cursor.Render(cell) + " " + typed.styles.dim.Render("[edit]")
		}
		if len(typed.errors) > 0 {
			cell += " " + typed.styles.error.Render("!")
		}
		return cell, true
	case *NumericInput:
		indicator := " "
		if typed.draft != typed.committed {
			indicator = typed.styles.pending.Render("*")
		}
		display := typed.draft
		if display == "" && !typed.focused {
			display = typed.styles.dim.Render(compactEmptyValue(typed.present, typed.allowUnset))
		}
		cursor := ""
		if typed.focused && typed.editing {
			cursor = "_"
		}
		cell := fmt.Sprintf("%s %s: %s%s", indicator, typed.styles.label.Render(compactLabel(typed.dotPath, typed.label)), typed.styles.value.Render(display), cursor)
		if typed.focused && !typed.editing {
			cell = typed.styles.cursor.Render(cell) + " " + typed.styles.dim.Render("[edit]")
		}
		if len(typed.errors) > 0 {
			cell += " " + typed.styles.error.Render("!")
		}
		return cell, true
	case *EnumSelector:
		label := typed.fieldLabel
		if label == "" {
			label = pathLeaf(typed.dotPath)
		}
		label = compactLabel(typed.dotPath, label)
		value := ""
		if typed.current >= 0 && typed.current < len(typed.values) {
			value = typed.values[typed.current]
		} else {
			value = "<unset>"
		}
		cell := fmt.Sprintf("  %s: %s", typed.styles.label.Render(label), typed.styles.value.Render(value))
		if typed.focused {
			cell = typed.styles.cursor.Render(cell) + " " + typed.styles.dim.Render("[select]")
		}
		return cell, true
	default:
		return "", false
	}
}

func (m *SettingsModel) compactSelectorView(l *ListEditor) string {
	return compactFitCell(m.compactSelectorLine(l), compactWidth(m.wrapWidth))
}

func (m *SettingsModel) compactSelectorLine(l *ListEditor) string {
	label := compactLabel(l.dotPath, l.label)
	value := "none"
	if len(l.draft) > 0 {
		value = strings.Join(l.draft, ", ")
	}
	line := fmt.Sprintf("  %s: %s", l.styles.label.Render(label), l.styles.value.Render(value))
	if !l.present && l.allowUnset {
		line += " " + l.styles.dim.Render("(default)")
	}
	if l.focused {
		line = l.styles.cursor.Render(line) + " " + l.styles.dim.Render("[select]")
	}
	return line
}

func (m *SettingsModel) compactSelectorBlockLines(l *ListEditor) []string {
	label := compactLabel(l.dotPath, l.label)
	header := fmt.Sprintf("%s:", l.styles.label.Render(label))
	if !l.present && l.allowUnset {
		header += " " + l.styles.dim.Render("(default)")
	}
	if l.focused && !l.editing {
		header = l.styles.cursor.Render(header) + " " + l.styles.dim.Render("[select]")
	}
	lines := []string{header}
	for i, item := range l.allowed {
		marker := "[ ]"
		if stringSliceContains(l.draft, item) {
			marker = "[x]"
		}
		line := fmt.Sprintf("  %s %s", marker, item)
		if l.focused && l.editing && i == l.cursor {
			line = l.styles.cursor.Render(line)
		} else {
			line = l.styles.value.Render(line)
		}
		lines = append(lines, line)
	}
	if l.focused && l.editing {
		lines = append(lines, l.styles.dim.Render("  [Space toggle  Enter commit  Esc discard]"))
	}
	return lines
}

func (m *SettingsModel) compactActiveHoursRangesView(a *ActiveHoursRangesEditor) string {
	return strings.Join(compactFitLines(m.compactActiveHoursWindowLines(a), compactWidth(m.wrapWidth)), "\n")
}

func (m *SettingsModel) compactActiveHoursEditLines(a *ActiveHoursRangesEditor) []string {
	total := len(a.draft)
	header := fmt.Sprintf("%s: (%d windows)", a.styles.label.Render(compactLabel(a.dotPath, a.label)), total)
	if !a.present {
		header += " " + a.styles.dim.Render("(default)")
	}
	header += " " + a.styles.dim.Render("[editing]")

	lines := []string{header}
	if total == 0 {
		lines = append(lines, a.styles.dim.Render("  (no windows)"))
	} else {
		maxRows := compactActiveHoursEditWindowRows(m.viewport.Height())
		start, end := compactVisibleWindow(total, a.cursor, maxRows)
		if start > 0 {
			lines = append(lines, a.styles.dim.Render(fmt.Sprintf("  ... %d earlier", start)))
		}
		for i := start; i < end; i++ {
			r := a.draft[i]
			row := fmt.Sprintf("  %s %s  %s-%s", compactCursorMarker(i == a.cursor), daysLabel(r.Days), r.Start, r.End)
			if i == a.cursor {
				row += " " + a.styles.dim.Render(activeHoursFieldLabel(a.field))
				lines = append(lines, a.styles.cursor.Render(row))
				if a.field == 0 {
					lines = append(lines, a.styles.dim.Render("    "+activeHoursDaySelector(r.Days)))
				}
			} else {
				lines = append(lines, a.styles.value.Render(row))
			}
		}
		if end < total {
			lines = append(lines, a.styles.dim.Render(fmt.Sprintf("  ... %d later", total-end)))
		}
	}
	help := "  j/k field  h/l field  +/- time  1-7 days  a add  d delete  Enter save  Esc discard"
	lines = append(lines, a.styles.dim.Render(help))
	if len(a.errors) > 0 {
		lines = append(lines, a.styles.error.Render("  "+strings.Join(a.errors, "; ")))
	}
	return compactFitLines(lines, compactWidth(m.wrapWidth))
}

func compactActiveHoursEditWindowRows(height int) int {
	if height >= 11 {
		return 3
	}
	if height >= 8 {
		return 2
	}
	return 1
}

func compactVisibleWindow(total, cursor, maxRows int) (int, int) {
	if total <= 0 {
		return 0, 0
	}
	if maxRows < 1 {
		maxRows = 1
	}
	if maxRows > total {
		maxRows = total
	}
	if cursor < 0 {
		cursor = 0
	}
	if cursor >= total {
		cursor = total - 1
	}
	start := cursor - maxRows/2
	if start < 0 {
		start = 0
	}
	if start+maxRows > total {
		start = total - maxRows
	}
	return start, start + maxRows
}

func compactCursorMarker(active bool) string {
	if active {
		return ">"
	}
	return " "
}

func (m *SettingsModel) compactActiveHoursRangesLine(a *ActiveHoursRangesEditor) string {
	lines := m.compactActiveHoursWindowLines(a)
	if len(lines) == 0 {
		return ""
	}
	return lines[0]
}

func (m *SettingsModel) compactActiveHoursWindowLines(a *ActiveHoursRangesEditor) []string {
	label := compactLabel(a.dotPath, a.label)
	parts := make([]string, 0, len(a.draft))
	for _, r := range a.draft {
		parts = append(parts, fmt.Sprintf("%s %s-%s", daysLabel(r.Days), r.Start, r.End))
	}
	if len(parts) > 0 {
		lines := make([]string, 0, len(parts))
		prefix := fmt.Sprintf("%s: ", a.styles.label.Render(label))
		continuation := strings.Repeat(" ", lipgloss.Width(label)+2)
		for i, part := range parts {
			line := continuation + a.styles.value.Render(part)
			if i == 0 {
				line = prefix + a.styles.value.Render(part)
				if !a.present {
					line += " " + a.styles.dim.Render("(default)")
				}
				if a.focused {
					line = a.styles.cursor.Render(line) + " " + a.styles.dim.Render("[edit]")
				}
			}
			lines = append(lines, line)
		}
		return lines
	}
	line := fmt.Sprintf("%s: %s", a.styles.label.Render(label), a.styles.dim.Render("(all time)"))
	if a.focused {
		line = a.styles.cursor.Render(line) + " " + a.styles.dim.Render("[edit]")
	}
	return []string{line}
}

func compactActiveHoursGroupLines(groupLabel string, lines, controls []string) []string {
	if len(lines) == 0 {
		return lines
	}
	out := append([]string(nil), lines...)
	first := strings.TrimSpace(out[0])
	if len(controls) > 0 {
		if before, after, ok := strings.Cut(first, ": "); ok {
			first = strings.Join(controls, "  |  ") + "  |  " + before + ": " + after
		} else {
			first = first + "  |  " + strings.Join(controls, "  |  ")
		}
	}
	out[0] = groupLabel + ": " + first
	continuation := strings.Repeat(" ", lipgloss.Width(groupLabel)+2)
	for i := 1; i < len(out); i++ {
		out[i] = continuation + strings.TrimSpace(out[i])
	}
	return out
}

func compactEmptyValue(present, allowUnset bool) string {
	if !present && allowUnset {
		return "default"
	}
	return "<empty>"
}

func compactLabel(dotPath, fallback string) string {
	switch dotPath {
	case "settlement.max_concurrency":
		return "concurrency"
	case "settlement.batch_size":
		return "batch size"
	case "settlement.batch_recompute_min_interval_seconds":
		return "batch interval"
	case "settlement.lease_ttl_seconds":
		return "lease ttl"
	case "settlement.executor_timeout_seconds":
		return "timeout"
	case "settlement.active_hours":
		return "active hours"
	case "settlement.active_hours.enabled":
		return "enabled"
	case "settlement.active_hours.timezone":
		return "timezone"
	case "settlement.active_hours.ranges":
		return "windows"
	case "settlement.harness_selection":
		return "harness"
	case "settlement.harness_selection.mode":
		return "mode"
	case "settlement.harness_selection.eligible_frameworks":
		return "eligible"
	case "settlement.harness_selection.random_seed":
		return "seed"
	default:
		if fallback != "" {
			return fallback
		}
		return pathLeaf(dotPath)
	}
}

func compactFitCell(cell string, width int) string {
	if width <= 0 {
		return ""
	}
	styled := lipgloss.NewStyle().MaxWidth(width).Render(cell)
	cellW := lipgloss.Width(styled)
	if cellW < width {
		styled += strings.Repeat(" ", width-cellW)
	}
	return styled
}

func compactFitLines(lines []string, width int) []string {
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		out = append(out, compactFitCell(line, width))
	}
	return out
}

func compactTrimCells(cells []string) []string {
	out := make([]string, 0, len(cells))
	for _, cell := range cells {
		out = append(out, strings.TrimSpace(cell))
	}
	return out
}

func compactWidth(width int) int {
	if width <= 0 {
		return 80
	}
	return width
}

func pathLeaf(path string) string {
	if idx := strings.LastIndexByte(path, '.'); idx >= 0 && idx+1 < len(path) {
		return path[idx+1:]
	}
	return path
}
