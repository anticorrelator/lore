// harness.go hosts the two harness-specific widgets the configurator modal
// renders that the type-driven dispatch (widgets.go) cannot synthesize from
// schema kind alone:
//
//   - PrimaryRadio (D8): single-select radio at the top of the modal backed
//     by `tui_launch_framework`. The closed set is enumerated from
//     adapters/capabilities.json `.frameworks` at construction time and
//     passed in as primitive `[]string` options — the widget itself does no
//     schema or capabilities I/O. Selection is structurally bounded by
//     `len(options)`; an unlisted candidate cannot be emitted (D6 closed-set
//     enforcement is also re-asserted at the SettingsModel layer per task 4).
//
//   - HarnessBlockPanel (D9): renders one `harnesses.<name>` block (args,
//     harness-local roles, harness-local ceremonies). Nil role/ceremony
//     children are still supported for legacy tests and migration views, but
//     production materializes both editors so harness defaults are editable
//     directly. Tab/Shift-Tab cycles between sub-fields and uses the child's
//     Blur() to discard any draft buffer per D10.
//
// Both widgets implement FieldWidget so the host SettingsModel can dispatch
// uniformly. Per D3 and the lipgloss O(n)-per-frame gotcha, every
// lipgloss.Style is cached as a struct field at construction.

package settings

import (
	"fmt"
	"sort"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

// ----------------------------------------------------------------------------
// PrimaryRadio — single-select radio for tui_launch_framework. Immediate-commit.
// ----------------------------------------------------------------------------

// PrimaryRadio renders a horizontal radio group whose options are the
// `.frameworks` keyset from adapters/capabilities.json. The widget itself
// does not read capabilities.json — the host SettingsModel enumerates the
// keyset and passes it in via the constructor. This keeps the widget
// pure-render and trivially testable from a fixture.
//
// Closed-set rejection is structural: the cursor is bounded by
// `len(options)`, and Update only ever emits an option at the cursor
// position. An out-of-set value cannot be produced by any keystroke
// sequence — a non-trivial guarantee for a settings field whose loader
// rejects unknown framework ids hard.
type PrimaryRadio struct {
	dotPath string
	options []string
	labels  []string
	current int // index of the currently committed value, or -1 when absent
	cursor  int
	focused bool

	activeStyle   lipgloss.Style
	inactiveStyle lipgloss.Style
	cursorStyle   lipgloss.Style
}

// NewPrimaryRadio constructs a radio over the given options. labels is
// parallel to options; pass nil to use options as their own display strings.
// current is the currently-committed option (e.g. read from
// settings.tui_launch_framework); pass "" to start with no selection.
func NewPrimaryRadio(dotPath string, options, labels []string, current string) *PrimaryRadio {
	if labels == nil {
		labels = options
	}
	cur := -1
	for i, o := range options {
		if o == current {
			cur = i
			break
		}
	}
	cursor := cur
	if cursor < 0 {
		cursor = 0
	}
	return &PrimaryRadio{
		dotPath:       dotPath,
		options:       append([]string(nil), options...),
		labels:        append([]string(nil), labels...),
		current:       cur,
		cursor:        cursor,
		activeStyle:   lipgloss.NewStyle().Foreground(lipgloss.Color("4")).Bold(true),
		inactiveStyle: lipgloss.NewStyle().Foreground(lipgloss.Color("8")),
		cursorStyle:   lipgloss.NewStyle().Foreground(lipgloss.Color("0")).Background(lipgloss.Color("4")).Bold(true),
	}
}

func (r *PrimaryRadio) Init() tea.Cmd      { return nil }
func (r *PrimaryRadio) DotPath() string    { return r.dotPath }
func (r *PrimaryRadio) Focused() bool      { return r.focused }
func (r *PrimaryRadio) Focus() tea.Cmd     { r.focused = true; return nil }
func (r *PrimaryRadio) Blur() *FieldIntent { r.focused = false; return nil }

// Options returns the closed set the radio enumerates. Used by tests and by
// SettingsModel when it needs to surface the candidate list in error messages.
func (r *PrimaryRadio) Options() []string { return append([]string(nil), r.options...) }

func (r *PrimaryRadio) Update(msg tea.Msg) (FieldWidget, tea.Cmd, *FieldIntent) {
	if !r.focused {
		return r, nil, nil
	}
	key, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return r, nil, nil
	}
	switch key.String() {
	case "left", "h":
		if r.cursor > 0 {
			r.cursor--
		}
	case "right", "l":
		if r.cursor < len(r.options)-1 {
			r.cursor++
		}
	case "enter", "space":
		if r.cursor < 0 || r.cursor >= len(r.options) {
			return r, nil, nil
		}
		r.current = r.cursor
		return r, nil, &FieldIntent{
			DotPath: r.dotPath,
			Value:   r.options[r.cursor],
			Status:  IntentCommit,
		}
	}
	return r, nil, nil
}

func (r *PrimaryRadio) View() string {
	var b strings.Builder
	for i, label := range r.labels {
		marker := "( )"
		if i == r.current {
			marker = "(•)"
		}
		token := fmt.Sprintf("%s %s", marker, label)
		switch {
		case i == r.cursor && r.focused:
			b.WriteString(r.cursorStyle.Render(token))
		case i == r.current:
			b.WriteString(r.activeStyle.Render(token))
		default:
			b.WriteString(r.inactiveStyle.Render(token))
		}
		if i < len(r.labels)-1 {
			b.WriteString("   ")
		}
	}
	return b.String()
}

// ----------------------------------------------------------------------------
// HarnessBlockPanel — renders one harnesses.<name> block. Per D9, distinguishes
// absent / explicit-empty / explicit non-empty for each overlay field and
// renders effective vs. override side-by-side.
// ----------------------------------------------------------------------------

// HarnessEffective carries the *resolved* values for a harness overlay — i.e.
// the effective roles map and ceremonies map after the parent overlay has
// been overlaid with the local override (or with nothing, when absent). The
// host SettingsModel computes this once per harness at modal open and passes
// it in; the widget renders it side-by-side with the override per D9.
//
// Computing effective state inside the widget would require it to know about
// parent overlay precedence rules and schema defaults — couplings that
// belong in SettingsModel, not the widget layer.
type HarnessEffective struct {
	// Roles is the resolved role-id -> capability-id mapping for this
	// harness. Empty when no roles are defined at any layer.
	Roles map[string]string
	// Ceremonies is the resolved ceremony-id -> []advisor-id mapping for
	// this harness. Empty when no ceremonies are defined at any layer.
	Ceremonies map[string][]string
}

// HarnessBlockPanel groups the sub-widgets for a single harnesses.<name>
// block: per-harness enabled toggle (always present, first in tab order),
// required `args` (always present), and harness-local `roles` and
// `ceremonies` editors. Passing nil for roles/ceremonies still renders a
// compact legacy fallback view, but the production settings panel passes real
// widgets for both so users can edit harness-specific defaults without hand
// editing settings.json.
type HarnessBlockPanel struct {
	name       string // harness id, e.g. "claude-code"
	dotPath    string // "harnesses.<name>"
	enabled    *harnessEnabledToggle
	args       FieldWidget
	roles      FieldWidget // production: non-nil harness-local defaults editor
	ceremonies FieldWidget // production: non-nil harness-local defaults editor
	effective  HarnessEffective

	cursor  int // 0=enabled, 1=args, 2=roles (skipped if nil), 3=ceremonies (if non-nil)
	focused bool
	entered bool

	headerStyle    lipgloss.Style
	overrideStyle  lipgloss.Style
	effectiveStyle lipgloss.Style
	dimStyle       lipgloss.Style
	emptyStyle     lipgloss.Style
}

// HarnessToggler is the callback the embedded enabled-toggle invokes when
// the user flips the per-harness enabled state. The host (package main)
// supplies a closure that calls SettingsModel.ToggleHarness, which in turn
// shells out to scripts/harness-toggle/{enable,disable}.sh. Defining the
// signature here keeps the widget free of any model.go coupling.
type HarnessToggler func(framework string, enabled bool) tea.Cmd

// NewHarnessBlockPanel constructs a panel for the named harness. args MUST be
// non-nil (the schema requires it). roles and ceremonies SHOULD be non-nil in
// production because those values are harness-local defaults. Nil remains a
// legacy fallback display for older tests/fixtures.
//
// `enabled` is the current per-harness enabled state (read by the host from
// `harnesses.<name>.enabled`; absence ≡ true per the schema's default-on
// semantic). `toggle` is the host-supplied callback that fires the
// harness-toggle shell-out; pass nil only in tests that don't exercise the
// toggle path.
func NewHarnessBlockPanel(name string, enabled bool, toggle HarnessToggler, args, roles, ceremonies FieldWidget, effective HarnessEffective) *HarnessBlockPanel {
	return &HarnessBlockPanel{
		name:           name,
		dotPath:        "harnesses." + name,
		enabled:        newHarnessEnabledToggle(name, enabled, toggle),
		args:           args,
		roles:          roles,
		ceremonies:     ceremonies,
		effective:      effective,
		headerStyle:    lipgloss.NewStyle().Foreground(lipgloss.Color("4")).Bold(true),
		overrideStyle:  lipgloss.NewStyle().Foreground(lipgloss.Color("4")),
		effectiveStyle: lipgloss.NewStyle().Foreground(lipgloss.Color("7")),
		dimStyle:       lipgloss.NewStyle().Foreground(lipgloss.Color("8")),
		emptyStyle:     lipgloss.NewStyle().Foreground(lipgloss.Color("3")),
	}
}

// SetEnabled updates the embedded enabled-toggle's visible state. Called by
// SettingsModel.harnessToggleResultMsg handler so the rendered checkbox
// reconciles with the disk state after a toggle resolves (or rolls back
// on shell-out error).
func (h *HarnessBlockPanel) SetEnabled(enabled bool) {
	if h.enabled != nil {
		h.enabled.current = enabled
	}
}

// Enabled reports the embedded toggle's current visible state. Used by the
// host to compute "any harness disabled" indicators in the modal title.
func (h *HarnessBlockPanel) Enabled() bool {
	if h.enabled == nil {
		return true
	}
	return h.enabled.current
}

// Framework returns the harness id this panel was constructed for. Used by
// the host's harnessToggleResultMsg handler to find the right panel slot
// when a toggle resolves.
func (h *HarnessBlockPanel) Framework() string { return h.name }

func (h *HarnessBlockPanel) Init() tea.Cmd   { return nil }
func (h *HarnessBlockPanel) DotPath() string { return h.dotPath }
func (h *HarnessBlockPanel) Focused() bool   { return h.focused }
func (h *HarnessBlockPanel) Entered() bool   { return h.entered }

// ConsumesNavRunes (NavRuneConsumer) — delegate to the currently-focused
// child so the model's j/k routing reflects the *effective* focused widget
// rather than the container. The model's hierarchical navigation uses
// NavStep (below) only after the panel has been entered; this method
// governs the typing-vs-navigating decision for j/k. When the cursor
// child is in active edit/typing mode, j/k must reach the child as literal
// input, so we report `true`. In every other case (toggle child, scalar row
// selected but not editing, list/kv editor in nav mode), we report `false`
// and the model invokes NavStep instead.
//
// Recursive composition: terminal widgets that don't implement the
// interface fall through to the model-side type switch
// (TextInput/NumericInput).
func (h *HarnessBlockPanel) ConsumesNavRunes() bool {
	if !h.entered {
		return false
	}
	c, _ := h.childAt(h.cursor)
	if c == nil {
		return false
	}
	if cc, ok := c.(NavRuneConsumer); ok {
		return cc.ConsumesNavRunes()
	}
	switch c.(type) {
	case *TextInput, *NumericInput:
		return false
	}
	return false
}

// NavStep advances the panel's internal cursor by `delta` (+1 forward,
// -1 backward), blurring the previously-focused child (per D10 this may
// surface an IntentDiscard for a draft-buffered child) and focusing the
// new child. Returns (false, nil) when the cursor is already at the
// boundary so the model can hop to the next top-level slot via
// focusOffset; the section rail brightness on the rendered panel only
// changes when focusIdx changes, so a successful NavStep keeps the user
// visually anchored in the same harness section even as the inner row
// changes.
//
// Recursive descent: when the currently-focused child is itself a
// NavStepper, we delegate the step to it first and only advance our own
// cursor on its boundary. Today's harness children (enabled toggle,
// ListEditor args, OpenKeysetKVEditor overlays) are all leaf widgets, but
// keeping the descent symmetric with ClosedObjectSubPanel.NavStep means a
// future nested panel under a harness block can't reintroduce the
// "fields-are-not-reachable" failure mode we just fixed there.
func (h *HarnessBlockPanel) NavStep(delta int) (bool, *FieldIntent) {
	if !h.focused || !h.entered {
		return false, nil
	}
	children := h.children()
	if len(children) == 0 {
		return false, nil
	}
	if h.cursor >= 0 && h.cursor < len(children) {
		if cs, ok := children[h.cursor].(NavStepper); ok {
			if nn, ok := children[h.cursor].(NestedNavigator); ok && nn.Entered() {
				if moved, intent := cs.NavStep(delta); moved {
					return true, intent
				}
			}
		}
	}
	next := h.cursor + delta
	if next < 0 || next >= len(children) {
		return false, nil
	}
	intent := children[h.cursor].Blur()
	h.cursor = next
	_ = children[h.cursor].Focus()
	return true, intent
}

// childAt returns the FieldWidget at logical cursor index, skipping nil
// (absent) overlays. Returns (nil, -1) when the cursor is out of range.
//
// The mapping is: 0 → enabled toggle, 1 → args, 2 → roles (if non-nil),
// 3 → ceremonies (if non-nil). Absent overlays are skipped.
func (h *HarnessBlockPanel) childAt(idx int) (FieldWidget, int) {
	children := h.children()
	if idx < 0 || idx >= len(children) {
		return nil, -1
	}
	return children[idx], idx
}

// children returns the navigable child widgets in display order, skipping
// absent overlays. The slice is rebuilt each call rather than cached — the
// underlying child set is small (≤4) and rebuilds avoid invalidation
// concerns when the host swaps a nil overlay for a real widget.
func (h *HarnessBlockPanel) children() []FieldWidget {
	out := make([]FieldWidget, 0, 4)
	if h.enabled != nil {
		out = append(out, h.enabled)
	}
	if h.args != nil {
		out = append(out, h.args)
	}
	if h.roles != nil {
		out = append(out, h.roles)
	}
	if h.ceremonies != nil {
		out = append(out, h.ceremonies)
	}
	return out
}

func (h *HarnessBlockPanel) Focus() tea.Cmd {
	h.focused = true
	h.entered = false
	return nil
}

// Blur on the panel blurs the focused child and propagates any IntentDiscard
// the child wants to emit (per D10's tab/focus = discard). For an absent
// overlay this is a no-op — there is no child to blur.
func (h *HarnessBlockPanel) Blur() *FieldIntent {
	h.focused = false
	h.entered = false
	if c, _ := h.childAt(h.cursor); c != nil && c.Focused() {
		return c.Blur()
	}
	return nil
}

func (h *HarnessBlockPanel) Update(msg tea.Msg) (FieldWidget, tea.Cmd, *FieldIntent) {
	if !h.focused {
		return h, nil, nil
	}
	children := h.children()
	if len(children) == 0 {
		return h, nil, nil
	}
	if key, ok := msg.(tea.KeyPressMsg); ok {
		switch key.String() {
		case "enter":
			if !h.entered {
				h.entered = true
				if c, _ := h.childAt(h.cursor); c != nil {
					return h, c.Focus(), nil
				}
				return h, nil, nil
			}
		case "tab":
			if !h.entered {
				return h, nil, nil
			}
			// Tab = discard the focused child's draft, advance cursor.
			// Per D9: this is the load-bearing path that must NOT
			// emit IntentCommit on an absent overlay. Because absent
			// overlays are skipped entirely (no child to traverse),
			// there is no path here that can synthesize a write.
			intent := children[h.cursor].Blur()
			if h.cursor < len(children)-1 {
				h.cursor++
				_ = children[h.cursor].Focus()
			}
			return h, nil, intent
		case "shift+tab":
			if !h.entered {
				return h, nil, nil
			}
			intent := children[h.cursor].Blur()
			if h.cursor > 0 {
				h.cursor--
				_ = children[h.cursor].Focus()
			}
			return h, nil, intent
		case "esc":
			if !h.entered {
				return h, nil, nil
			}
			child, cmd, intent := children[h.cursor].Update(msg)
			h.replaceChildAt(h.cursor, child)
			if intent != nil {
				return h, cmd, intent
			}
			if nested, ok := child.(NestedNavigator); ok && nested.Entered() {
				return h, cmd, nil
			}
			if blurIntent := child.Blur(); blurIntent != nil {
				h.entered = false
				return h, cmd, blurIntent
			}
			h.entered = false
			return h, cmd, &FieldIntent{DotPath: h.dotPath, Status: IntentNavigate}
		}
	}
	if !h.entered {
		return h, nil, nil
	}
	child, cmd, intent := children[h.cursor].Update(msg)
	// Re-anchor the child slot the children() list was built from. This is
	// safe because children() preserves the order args → roles → ceremonies
	// and we know which slot was at h.cursor.
	h.replaceChildAt(h.cursor, child)
	return h, cmd, intent
}

// replaceChildAt updates the underlying field corresponding to the logical
// cursor position. Mirrors children() ordering (enabled → args → roles →
// ceremonies, skipping nil).
func (h *HarnessBlockPanel) replaceChildAt(idx int, w FieldWidget) {
	pos := 0
	if h.enabled != nil {
		if pos == idx {
			if t, ok := w.(*harnessEnabledToggle); ok {
				h.enabled = t
			}
			return
		}
		pos++
	}
	if h.args != nil {
		if pos == idx {
			h.args = w
			return
		}
		pos++
	}
	if h.roles != nil {
		if pos == idx {
			h.roles = w
			return
		}
		pos++
	}
	if h.ceremonies != nil {
		if pos == idx {
			h.ceremonies = w
			return
		}
	}
}

func (h *HarnessBlockPanel) View() string {
	return strings.TrimRight(h.viewBuilder().String(), "\n")
}

// viewBuilder renders the panel into a strings.Builder so InnerFocusYRange
// can run the same render path and count line offsets. Splitting it out is
// the cheapest way to keep the rendering authoritative for both View() and
// the y-range computation — re-implementing the layout in two places would
// be a drift hazard.
func (h *HarnessBlockPanel) viewBuilder() *strings.Builder {
	var b strings.Builder
	b.WriteString(h.headerStyle.Render("▼ harnesses." + h.name))
	b.WriteByte('\n')

	// enabled toggle — always first, always present.
	if h.enabled != nil {
		b.WriteString("  ")
		b.WriteString(h.enabled.View())
		b.WriteByte('\n')
	}

	// args row — always present.
	if h.args != nil {
		b.WriteString("  ")
		b.WriteString(h.args.View())
		b.WriteByte('\n')
	}

	b.WriteString(h.renderHarnessSetting("roles", h.roles, h.formatEffectiveRoles()))
	b.WriteByte('\n')
	b.WriteString(h.renderHarnessSetting("ceremonies", h.ceremonies, h.formatEffectiveCeremonies()))
	return &b
}

// InnerFocusYRange returns the inclusive [top, bottom] line offsets of the
// currently-focused child *within this panel's rendered View()*. Returns
// (-1, -1) when the panel has no children, isn't focused, or the cursor
// points past the children list.
//
// The model's computeFocusedYRange uses this when the focused top-level
// slot is a HarnessBlockPanel: without the inner range, a panel taller
// than the viewport would scroll the panel's *bottom* into view while the
// user's actual cursor sits at the top, leaving the focused row off-screen.
//
// Implementation: re-render the panel structure while tracking newline
// offsets at each child boundary. We use `strings.Count(..., "\n")`
// directly (NOT model.go's `lineCount` which returns count+1 for trailing-
// newline strings) — for prefix-line-counting we want "the line index of
// the next character to write", which equals the count of newlines so far.
// The +1 form would shift every range down by 1, dropping the first line
// of the focused slot off the visible window.
func (h *HarnessBlockPanel) InnerFocusYRange() (int, int) {
	if !h.focused || !h.entered {
		return -1, -1
	}
	children := h.children()
	if len(children) == 0 || h.cursor < 0 || h.cursor >= len(children) {
		return -1, -1
	}

	var b strings.Builder
	// Slot order MUST mirror viewBuilder's emit order: header, enabled,
	// args, roles overlay (rendered even when absent), ceremonies overlay.
	b.WriteString(h.headerStyle.Render("▼ harnesses." + h.name))
	b.WriteByte('\n')

	// nextLine returns the 0-indexed line index of the next character to
	// be written. Equals the count of newlines emitted so far.
	nextLine := func() int { return strings.Count(b.String(), "\n") }

	// emit writes one slot's content and returns the [top, bottom] line
	// range it occupies within the resulting view. Always terminates with
	// a newline so the following slot starts on a fresh line.
	emit := func(content string) (top, bottom int) {
		top = nextLine()
		b.WriteString(content)
		// Number of additional lines content adds beyond the starting line.
		// "abc" adds 0 (single line), "abc\ndef" adds 1, "a\nb\nc" adds 2.
		// If content already ends with \n, the final newline produces an
		// empty trailing visual line — bottom should be the line BEFORE it.
		additional := strings.Count(content, "\n")
		if strings.HasSuffix(content, "\n") {
			additional--
		}
		if additional < 0 {
			additional = 0
		}
		bottom = top + additional
		// Terminate this slot so the next one starts cleanly.
		if !strings.HasSuffix(content, "\n") {
			b.WriteByte('\n')
		}
		return top, bottom
	}

	logical := 0
	if h.enabled != nil {
		top, bottom := emit("  " + h.enabled.View())
		if logical == h.cursor {
			return top, bottom
		}
		logical++
	}
	if h.args != nil {
		top, bottom := emit("  " + h.args.View())
		if logical == h.cursor {
			return top, bottom
		}
		logical++
	}
	if h.roles != nil {
		top, bottom := emit(h.renderHarnessSetting("roles", h.roles, h.formatEffectiveRoles()))
		if logical == h.cursor {
			return top, bottom
		}
		logical++
	} else {
		// Absent overlays still occupy vertical space (the "(inherited)"
		// row is always rendered). Walk the layout but don't claim a logical
		// slot — absent overlays aren't navigable.
		emit(h.renderHarnessSetting("roles", nil, h.formatEffectiveRoles()))
	}
	if h.ceremonies != nil {
		top, bottom := emit(h.renderHarnessSetting("ceremonies", h.ceremonies, h.formatEffectiveCeremonies()))
		if logical == h.cursor {
			return top, bottom
		}
	}
	return -1, -1
}

// renderHarnessSetting renders one harness-local map. For the normal
// production path (widget != nil) the output is deliberately compact: the
// editor already carries the useful controls, and showing a second "effective"
// column would repeat the same information for no gain. The nil branch keeps a
// small legacy fallback display for older settings snapshots.
func (h *HarnessBlockPanel) renderHarnessSetting(label string, widget FieldWidget, effective string) string {
	var b strings.Builder
	b.WriteString("  ")
	b.WriteString(h.headerStyle.Render(label + ":"))
	b.WriteByte('\n')
	if widget == nil {
		b.WriteString("    ")
		b.WriteString(h.dimStyle.Render("(inherited)"))
		b.WriteByte('\n')
		b.WriteString("    effective: ")
		if effective == "" {
			b.WriteString(h.emptyStyle.Render("<empty>"))
		} else {
			b.WriteString(h.effectiveStyle.Render(effective))
		}
	} else {
		b.WriteString("    ")
		b.WriteString(h.overrideStyle.Render(indent(widget.View(), "    ")))
	}
	return b.String()
}

// formatEffectiveRoles renders the resolved roles map as a compact one-liner.
// Empty map → "" (the renderOverlay caller surfaces "<empty>" in that case so
// the empty-vs-populated distinction stays visible in the right column).
func (h *HarnessBlockPanel) formatEffectiveRoles() string {
	if len(h.effective.Roles) == 0 {
		return ""
	}
	keys := make([]string, 0, len(h.effective.Roles))
	for k := range h.effective.Roles {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s=%s", k, h.effective.Roles[k]))
	}
	return strings.Join(parts, ", ")
}

// formatEffectiveCeremonies renders the resolved ceremonies map as a compact
// one-liner. Per-ceremony advisor lists join with `+`, ceremony entries
// join with `, `.
func (h *HarnessBlockPanel) formatEffectiveCeremonies() string {
	if len(h.effective.Ceremonies) == 0 {
		return ""
	}
	keys := make([]string, 0, len(h.effective.Ceremonies))
	for k := range h.effective.Ceremonies {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		advisors := h.effective.Ceremonies[k]
		parts = append(parts, fmt.Sprintf("%s=[%s]", k, strings.Join(advisors, "+")))
	}
	return strings.Join(parts, ", ")
}

// indent re-indents a multi-line widget view so subsequent lines align under
// the first line's content column. Bubble Tea widgets render with their own
// internal '\n's; without re-indenting them we'd get hanging lines that
// break the two-column layout's visual alignment.
func indent(s, leading string) string {
	if !strings.Contains(s, "\n") {
		return s
	}
	pad := strings.Repeat(" ", len(leading))
	parts := strings.Split(s, "\n")
	for i := 1; i < len(parts); i++ {
		parts[i] = pad + parts[i]
	}
	return strings.Join(parts, "\n")
}

// ----------------------------------------------------------------------------
// harnessEnabledToggle — per-harness enable/disable widget embedded inside
// HarnessBlockPanel.
//
// Behavior parity with the retired global agentToggleWidget (issue: the
// global toggle's UI was misleading — users read it as per-harness):
//   - Space / Enter / x flips the visible bool optimistically and fires the
//     supplied HarnessToggler callback. The callback is expected to return a
//     tea.Cmd that runs the harness-toggle shell-out asynchronously.
//   - Update returns no FieldIntent. The shell-out path bypasses the generic
//     IntentCommit routing entirely; SettingsModel.routeCommit treats a
//     stray IntentCommit on `harnesses.<fw>.enabled` as a programming error.
//   - Lock state lives on SettingsModel (per-framework); the widget itself
//     does not gate keystrokes — the model's lock map suppresses the cmd.
type harnessEnabledToggle struct {
	framework string
	dotPath   string
	current   bool
	focused   bool
	toggle    HarnessToggler

	checkStyle   lipgloss.Style
	uncheckStyle lipgloss.Style
	focusStyle   lipgloss.Style
}

func newHarnessEnabledToggle(framework string, current bool, toggle HarnessToggler) *harnessEnabledToggle {
	return &harnessEnabledToggle{
		framework:    framework,
		dotPath:      "harnesses." + framework + ".enabled",
		current:      current,
		toggle:       toggle,
		checkStyle:   lipgloss.NewStyle().Foreground(lipgloss.Color("2")).Bold(true),
		uncheckStyle: lipgloss.NewStyle().Foreground(lipgloss.Color("8")),
		focusStyle:   lipgloss.NewStyle().Foreground(lipgloss.Color("0")).Background(lipgloss.Color("4")).Bold(true),
	}
}

func (t *harnessEnabledToggle) Init() tea.Cmd      { return nil }
func (t *harnessEnabledToggle) DotPath() string    { return t.dotPath }
func (t *harnessEnabledToggle) Focused() bool      { return t.focused }
func (t *harnessEnabledToggle) Focus() tea.Cmd     { t.focused = true; return nil }
func (t *harnessEnabledToggle) Blur() *FieldIntent { t.focused = false; return nil }

func (t *harnessEnabledToggle) Update(msg tea.Msg) (FieldWidget, tea.Cmd, *FieldIntent) {
	if !t.focused {
		return t, nil, nil
	}
	key, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return t, nil, nil
	}
	switch key.String() {
	case "space", "enter", "x":
		next := !t.current
		if t.toggle != nil {
			cmd := t.toggle(t.framework, next)
			if cmd == nil {
				return t, nil, nil
			}
			t.current = next
			return t, cmd, nil
		}
	}
	return t, nil, nil
}

func (t *harnessEnabledToggle) View() string {
	box := "[ ]"
	state := "disabled"
	style := t.uncheckStyle
	if t.current {
		box = "[x]"
		state = "enabled"
		style = t.checkStyle
	}
	token := fmt.Sprintf("%s integration (%s)", box, state)
	if t.focused {
		return t.focusStyle.Render("> " + token + " — space/enter to toggle")
	}
	return "  " + style.Render(token)
}
