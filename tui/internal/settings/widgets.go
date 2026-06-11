// Package settings hosts the schema-driven configurator for ~/.lore/config/settings.json.
//
// widgets.go defines the FieldWidget surface the host model dispatches to for
// each schema-driven field. Per D10 (per-widget commit cadence + boundary
// contract): widgets emit FieldIntent values describing what the host should
// do; widgets do NOT call SettingsPatch/SettingsDelete themselves. That keeps
// the persistence boundary in one place (the host SettingsModel — task 4) and
// keeps widgets pure-render + draft-buffer state machines.
//
// Two cadences (D10):
//   - immediate-commit: ToggleRow, EnumSelector, primary-radio, unset gestures
//     emit IntentCommit / IntentUnset on each user action.
//   - draft-buffered: TextInput, NumericInput, ListEditor, OpenKeysetKVEditor
//     keep an in-widget draft; emit IntentCommit on Enter (after validating
//     ALL configured constraints), IntentReject on Enter with an invalid
//     draft (draft + focus survive), and IntentDiscard on Esc / Tab /
//     focus-out (the visible state reverts to the original committed value).
//     Containers emit IntentNavigate when Esc only backs out of a nesting
//     level and no leaf draft was reverted.
//
// Per D3 + the lipgloss O(n)-per-frame gotcha, every lipgloss.Style is cached
// as a struct field at construction; View() never allocates styles.
package settings

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

// ----------------------------------------------------------------------------
// FieldIntent — boundary contract between widgets and the host SettingsModel.
// ----------------------------------------------------------------------------

// IntentStatus enumerates the outcomes a FieldWidget can report. The host
// SettingsModel routes each status to the appropriate persistence call (or
// status-bar flash) — widgets never call SettingsPatch/SettingsDelete.
type IntentStatus int

const (
	// IntentCommit means the typed candidate is well-formed and the host
	// should write it via SettingsPatch.
	IntentCommit IntentStatus = iota
	// IntentDiscard means the user cancelled (Esc) or focus moved away
	// (Tab / focus-out). The host writes nothing; the widget has already
	// reverted its draft to the original committed value.
	IntentDiscard
	// IntentNavigate means a container consumed a navigation gesture such as
	// Esc backing out of one nesting level. The host writes nothing, and no
	// leaf value was reverted or cleared.
	IntentNavigate
	// IntentReject means the typed candidate failed at least one schema
	// constraint at commit time. The host writes nothing and surfaces
	// Errors via the status bar. The widget keeps the draft + focus.
	IntentReject
	// IntentUnset means the user pressed the unset gesture (`u` or
	// Backspace) on an explicit overlay; the host should call
	// SettingsDelete to remove the dot-path key, restoring inheritance.
	IntentUnset
)

// FieldIntent is the typed message a FieldWidget emits to its host. DotPath
// uses the same canonical form SettingsPatch/SettingsDelete consume (e.g.
// "harnesses.claude-code.args"). Value is the typed candidate (string, bool,
// float64, int, []string, map[string]any) — the host marshals it via the
// existing SettingsPatch surface; widgets do not encode JSON themselves.
//
// Errors is populated only when Status == IntentReject; one entry per failed
// constraint, in declaration order, for stable test assertions.
type FieldIntent struct {
	DotPath string
	Value   any
	Status  IntentStatus
	Errors  []string
}

// ----------------------------------------------------------------------------
// FieldWidget interface.
// ----------------------------------------------------------------------------

// FieldWidget is the Bubble Tea sub-model contract every settings-configurator
// widget implements. The Update return triple is the boundary contract:
//   - the (possibly-mutated) widget value (Bubble Tea value-semantics dance)
//   - an optional tea.Cmd for async work (rare; today only the OpenKeysetKVEditor
//     might need it)
//   - an optional *FieldIntent — non-nil iff the widget wants the host to act
//     this Update tick. Multiple Updates can fire without an intent (e.g., a
//     keystroke into a draft buffer).
type FieldWidget interface {
	Init() tea.Cmd
	Update(msg tea.Msg) (FieldWidget, tea.Cmd, *FieldIntent)
	View() string
	Focus() tea.Cmd
	Blur() *FieldIntent // returns IntentDiscard for draft-buffered widgets that had a pending draft; nil for immediate-commit widgets
	Focused() bool
	DotPath() string
}

// ----------------------------------------------------------------------------
// Cached styles.
//
// One struct, allocated once at package init, shared by every widget. Per the
// lipgloss O(n)-per-frame gotcha, View() must NEVER allocate lipgloss.Style.
// ----------------------------------------------------------------------------

type widgetStyles struct {
	dim      lipgloss.Style
	label    lipgloss.Style
	value    lipgloss.Style
	cursor   lipgloss.Style // active-row inverse highlight
	error    lipgloss.Style // inline validation error
	pending  lipgloss.Style // draft-buffer indicator
	checkOn  lipgloss.Style
	checkOff lipgloss.Style
	desc     lipgloss.Style // dimmed inline description
	// subLabel renders the bold header for inner panels (e.g.,
	// capture > core). It's parallel to
	// themeStyles.subsectionTitle but lives here so widgets can render their
	// own subsection labels without reaching into the themeStyles bag —
	// preserves the cached-style discipline (no per-frame allocation).
	subLabel lipgloss.Style
}

func defaultStyles() widgetStyles {
	return widgetStyles{
		dim:      lipgloss.NewStyle().Foreground(lipgloss.Color("8")),
		label:    lipgloss.NewStyle().Foreground(lipgloss.Color("7")),
		value:    lipgloss.NewStyle().Foreground(lipgloss.Color("4")),
		cursor:   lipgloss.NewStyle().Foreground(lipgloss.Color("0")).Background(lipgloss.Color("4")).Bold(true),
		error:    lipgloss.NewStyle().Foreground(lipgloss.Color("1")),
		pending:  lipgloss.NewStyle().Foreground(lipgloss.Color("3")),
		checkOn:  lipgloss.NewStyle().Foreground(lipgloss.Color("2")).Bold(true),
		checkOff: lipgloss.NewStyle().Foreground(lipgloss.Color("8")),
		desc:     lipgloss.NewStyle().Foreground(lipgloss.Color("8")).Italic(true),
		subLabel: lipgloss.NewStyle().Foreground(lipgloss.Color("7")).Bold(true),
	}
}

// ----------------------------------------------------------------------------
// Display hints — opt-in setter the model uses to label and describe widgets.
// ----------------------------------------------------------------------------

// DisplayHinter is implemented by FieldWidget values that accept a human-
// readable label + description for richer rendering. It is OPT-IN: the model
// (model.go) uses a type-assertion at buildWidget time so widgets that don't
// implement it (or constructors that don't yet wire one up) keep their pre-
// existing single-line render. New widgets SHOULD implement it so the user
// always sees what a field is and what it does.
type DisplayHinter interface {
	SetDisplayHints(label, description string)
}

// defaultDescWrap is the column width used to soft-wrap descriptions when no
// explicit width has been pushed in. Sized to the configurator's narrow-mode
// body (~56 cols) minus the per-row indent (4) and a small margin — wider
// modal sizes stay readable, narrower ones still fit because word-wrap is
// applied. The host can push a real width via WidthSetter when the modal is
// sized.
const defaultDescWrap = 72

// WidthSetter is implemented by widgets that re-flow their description text to
// a host-supplied wrap width. Like DisplayHinter, it is OPT-IN; the model
// pushes a width on every SetSize. Widgets that don't implement it use
// defaultDescWrap.
type WidthSetter interface {
	SetWrapWidth(w int)
}

// wrapWords soft-wraps `s` to width `w` on whitespace boundaries. Returns the
// input unchanged when w <= 0 or the input is empty. Long single words are
// allowed to overflow rather than being broken — the alternative is truncation
// or hyphenation, both of which obscure the value text.
func wrapWords(s string, w int) string {
	if w <= 0 || s == "" {
		return s
	}
	var b strings.Builder
	col := 0
	for i, word := range strings.Fields(s) {
		wn := runeLen(word)
		if i == 0 {
			b.WriteString(word)
			col = wn
			continue
		}
		if col+1+wn > w {
			b.WriteByte('\n')
			b.WriteString(word)
			col = wn
		} else {
			b.WriteByte(' ')
			b.WriteString(word)
			col += 1 + wn
		}
	}
	return b.String()
}

// runeLen returns the rune count of s. Cheaper than utf8.RuneCountInString for
// the short label-and-description strings we wrap; equivalent results.
func runeLen(s string) int {
	n := 0
	for range s {
		n++
	}
	return n
}

// BodyViewer is implemented by container widgets that can render their content
// without their own outer label header. The model's section-frame helper calls
// ViewBody() instead of View() when wrapping a top-level container in a frame
// whose own header already shows the section name — avoiding the duplicate
// "label appears twice" effect (once in the frame header, once in the widget's
// internal header). Sub-panels nested inside a parent panel keep using View()
// so their bold subsection label still renders.
type BodyViewer interface {
	ViewBody() string
}

// AdvancedSection is a collapsed-by-default disclosure wrapper for settings
// that are valid but rarely touched. It keeps the wrapped widget's own dot
// paths and intents intact; only the top-level presentation changes.
type AdvancedSection struct {
	dotPath  string
	label    string
	child    FieldWidget
	focused  bool
	expanded bool
	entered  bool
	styles   widgetStyles

	wrapWidth int
}

func NewAdvancedSection(dotPath, label string, child FieldWidget) *AdvancedSection {
	return &AdvancedSection{
		dotPath: dotPath,
		label:   label,
		child:   child,
		styles:  defaultStyles(),
	}
}

func (a *AdvancedSection) Init() tea.Cmd   { return nil }
func (a *AdvancedSection) DotPath() string { return a.dotPath }
func (a *AdvancedSection) Focused() bool   { return a.focused }
func (a *AdvancedSection) Focus() tea.Cmd {
	a.focused = true
	return nil
}

func (a *AdvancedSection) Blur() *FieldIntent {
	a.focused = false
	a.entered = false
	if a.child != nil && a.child.Focused() {
		return a.child.Blur()
	}
	return nil
}

func (a *AdvancedSection) SetWrapWidth(w int) {
	a.wrapWidth = w
	if ws, ok := a.child.(WidthSetter); ok {
		ws.SetWrapWidth(w)
	}
}

func (a *AdvancedSection) Entered() bool { return a.entered }

func (a *AdvancedSection) ConsumesNavRunes() bool {
	if !a.expanded || !a.entered || a.child == nil {
		return false
	}
	if c, ok := a.child.(NavRuneConsumer); ok {
		return c.ConsumesNavRunes()
	}
	switch a.child.(type) {
	case *TextInput, *NumericInput:
		return false
	}
	return false
}

func (a *AdvancedSection) InnerFocusYRange() (int, int) {
	if !a.focused {
		return -1, -1
	}
	if !a.expanded || !a.entered || a.child == nil {
		return 0, 0
	}
	if r, ok := a.child.(InnerFocusRanger); ok {
		if top, bottom := r.InnerFocusYRange(); top >= 0 {
			return top + 1, bottom + 1
		}
	}
	return 1, lineCountLocal(a.childViewBody())
}

func (a *AdvancedSection) NavStep(delta int) (bool, *FieldIntent) {
	if !a.focused || !a.expanded || !a.entered || a.child == nil {
		return false, nil
	}
	if stepper, ok := a.child.(NavStepper); ok {
		return stepper.NavStep(delta)
	}
	return false, nil
}

func (a *AdvancedSection) Update(msg tea.Msg) (FieldWidget, tea.Cmd, *FieldIntent) {
	if !a.focused {
		return a, nil, nil
	}
	if key, ok := msg.(tea.KeyPressMsg); ok {
		switch key.String() {
		case "enter", "space":
			if !a.expanded {
				a.expanded = true
				a.entered = true
				if a.child == nil {
					return a, nil, nil
				}
				cmd := a.child.Focus()
				child, childCmd, intent := a.child.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
				a.child = child
				return a, teaBatchLocal(cmd, childCmd), intent
			}
		case "esc":
			if !a.expanded {
				return a, nil, nil
			}
			if a.entered && a.child != nil {
				child, cmd, intent := a.child.Update(msg)
				a.child = child
				if intent != nil {
					return a, cmd, intent
				}
				if nested, ok := child.(NestedNavigator); ok && nested.Entered() {
					return a, cmd, nil
				}
				if blurIntent := a.child.Blur(); blurIntent != nil {
					a.entered = false
					return a, cmd, blurIntent
				}
				a.entered = false
				return a, cmd, &FieldIntent{DotPath: a.dotPath, Status: IntentNavigate}
			}
			a.expanded = false
			return a, nil, &FieldIntent{DotPath: a.dotPath, Status: IntentNavigate}
		}
	}
	if !a.expanded || !a.entered || a.child == nil {
		return a, nil, nil
	}
	child, cmd, intent := a.child.Update(msg)
	a.child = child
	return a, cmd, intent
}

func (a *AdvancedSection) View() string { return a.ViewBody() }

func (a *AdvancedSection) ViewBody() string {
	state := "[+]"
	if a.expanded {
		state = "[-]"
	}
	summary := fmt.Sprintf("%s %s", state, a.label)
	if a.focused && !a.entered {
		summary = a.styles.cursor.Render(summary)
	} else {
		summary = a.styles.label.Render(summary)
	}
	if !a.expanded || a.child == nil {
		return summary
	}
	body := a.childViewBody()
	if body == "" {
		return summary
	}
	return summary + "\n" + body
}

func (a *AdvancedSection) childViewBody() string {
	if a.child == nil {
		return ""
	}
	if bv, ok := a.child.(BodyViewer); ok {
		return bv.ViewBody()
	}
	return a.child.View()
}

func teaBatchLocal(a, b tea.Cmd) tea.Cmd {
	if a == nil {
		return b
	}
	if b == nil {
		return a
	}
	return tea.Batch(a, b)
}

func lineCountLocal(s string) int {
	if s == "" {
		return 0
	}
	return strings.Count(s, "\n") + 1
}

// indentEachLine prepends `prefix` to every line of `s`. Used by container
// widgets (ClosedObjectSubPanel) to indent rendered children, and by per-row
// widgets to indent descriptions under a field label.
func indentEachLine(s, prefix string) string {
	if s == "" {
		return s
	}
	parts := strings.Split(s, "\n")
	for i, p := range parts {
		parts[i] = prefix + p
	}
	return strings.Join(parts, "\n")
}

// renderDescription returns the description block (zero or more lines, indented
// by `indent` spaces, soft-wrapped to `wrap` cols, dim-styled). Empty when
// description is empty — callers can append unconditionally.
func renderDescription(styles widgetStyles, description string, indent, wrap int) string {
	if description == "" {
		return ""
	}
	if wrap <= 0 {
		wrap = defaultDescWrap
	}
	innerWrap := wrap - indent
	if innerWrap < 16 {
		innerWrap = 16 // narrow-modal floor; words overflow rather than truncate
	}
	wrapped := wrapWords(description, innerWrap)
	pad := strings.Repeat(" ", indent)
	return indentEachLine(styles.desc.Render(wrapped), pad)
}

// ----------------------------------------------------------------------------
// EnumSelector — closed-set picker. Immediate-commit (D10).
// ----------------------------------------------------------------------------

// EnumSelector renders a horizontal list of enum candidates with h/l or arrow
// navigation and Enter/space to commit. Any unlisted candidate is rejected at
// the boundary (D6) — typing a free-form value is impossible by construction.
//
// Display hints (set via SetDisplayHints) drive the multi-line render path:
// when fieldLabel is non-empty, View() renders three blocks — a header row
// with the label + state marker, an options row with the candidate dots, and
// (optional) a soft-wrapped description below. With no label set the legacy
// single-line render is preserved (used by PrimaryRadio and the structural
// closed-set tests).
type EnumSelector struct {
	dotPath    string
	values     []string // closed set; first index is the default
	labels     []string // display labels parallel to values; falls back to values[i]
	current    int      // index of the currently committed value, or -1 when absent
	cursor     int      // index of the highlighted candidate (selection cursor)
	focused    bool
	styles     widgetStyles
	allowUnset bool // when true, pressing 'u'/Backspace emits IntentUnset

	// Display hints (D-display): set by the model via SetDisplayHints.
	// fieldLabel is the per-row name (e.g., "subagents"); description is
	// the soft-wrapped help text rendered below the option dots.
	fieldLabel  string
	description string
	wrapWidth   int
}

// NewEnumSelector returns a fresh EnumSelector. Pass labels==nil to use values
// as their own display strings. allowUnset=true exposes the unset gesture per
// D9 — used for overlay enums like harnesses.<name>.roles.<role> where unset
// restores inheritance.
func NewEnumSelector(dotPath string, values, labels []string, current string, allowUnset bool) *EnumSelector {
	if labels == nil {
		labels = values
	}
	cur := -1
	for i, v := range values {
		if v == current {
			cur = i
			break
		}
	}
	cursor := cur
	if cursor < 0 {
		cursor = 0
	}
	return &EnumSelector{
		dotPath:    dotPath,
		values:     append([]string(nil), values...),
		labels:     append([]string(nil), labels...),
		current:    cur,
		cursor:     cursor,
		styles:     defaultStyles(),
		allowUnset: allowUnset,
	}
}

func (e *EnumSelector) Init() tea.Cmd   { return nil }
func (e *EnumSelector) DotPath() string { return e.dotPath }
func (e *EnumSelector) Focused() bool   { return e.focused }
func (e *EnumSelector) Focus() tea.Cmd  { e.focused = true; return nil }

// SetDisplayHints attaches the per-row label and description for the multi-
// line render path. Called by the model after construction (per the
// DisplayHinter opt-in protocol). Empty strings preserve the legacy single-
// line render — that's how PrimaryRadio's option-list rendering stays
// untouched.
func (e *EnumSelector) SetDisplayHints(label, description string) {
	e.fieldLabel = label
	e.description = description
}

// SetWrapWidth re-flows the description text to the host-supplied width.
// Called by the model on SetSize so descriptions track terminal resizes.
func (e *EnumSelector) SetWrapWidth(w int) { e.wrapWidth = w }

// Blur on EnumSelector is a no-op for state — selection is committed on Enter,
// not on focus-out. Returning nil signals "no intent to emit."
func (e *EnumSelector) Blur() *FieldIntent { e.focused = false; return nil }

func (e *EnumSelector) Update(msg tea.Msg) (FieldWidget, tea.Cmd, *FieldIntent) {
	if !e.focused {
		return e, nil, nil
	}
	key, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return e, nil, nil
	}
	switch key.String() {
	case "left", "h":
		if e.cursor > 0 {
			e.cursor--
		}
	case "right", "l":
		if e.cursor < len(e.values)-1 {
			e.cursor++
		}
	case "enter", "space":
		// Commit selection. Closed-set rejection is structurally impossible
		// here (cursor is bounded by len(e.values)) — but we still emit the
		// validated typed value, not a free-form string, per D6.
		if e.cursor < 0 || e.cursor >= len(e.values) {
			return e, nil, nil
		}
		e.current = e.cursor
		return e, nil, &FieldIntent{
			DotPath: e.dotPath,
			Value:   e.values[e.cursor],
			Status:  IntentCommit,
		}
	case "u", "backspace":
		if !e.allowUnset {
			return e, nil, nil
		}
		e.current = -1
		return e, nil, &FieldIntent{
			DotPath: e.dotPath,
			Status:  IntentUnset,
		}
	}
	return e, nil, nil
}

func (e *EnumSelector) View() string {
	options := e.renderOptions()
	if e.fieldLabel == "" {
		// Legacy single-line render — used by PrimaryRadio's structural tests
		// and by callers that intentionally don't set a label.
		return options
	}
	// Multi-line render: header row (label + state marker) → options row →
	// optional description block. Indentation matches what
	// ClosedObjectSubPanel applies to its children, so per-row content lines
	// up vertically across the panel.
	var b strings.Builder
	b.WriteString(e.renderHeaderRow())
	b.WriteByte('\n')
	b.WriteString(indentEachLine(options, "  "))
	if e.description != "" {
		b.WriteByte('\n')
		b.WriteString(renderDescription(e.styles, e.description, 2, e.wrapWidth))
	}
	return b.String()
}

// renderHeaderRow renders the label + current-state marker for the multi-line
// path. The marker mirrors HarnessBlockPanel's vocabulary: "(inherited)" when
// no value is committed, "[override: <value>]" when a committed value exists.
// Required-and-set fields render the value plainly without the override
// brackets — they're not overlays.
func (e *EnumSelector) renderHeaderRow() string {
	label := e.styles.label.Render(e.fieldLabel)
	if e.focused {
		label = e.styles.cursor.Render(e.fieldLabel)
	}
	state := ""
	switch {
	case e.current < 0 && e.allowUnset:
		state = e.styles.dim.Render("(inherited)")
	case e.current >= 0 && e.allowUnset:
		state = e.styles.value.Render(fmt.Sprintf("[override: %s]", e.values[e.current]))
	case e.current >= 0:
		state = e.styles.value.Render(e.values[e.current])
	}
	if state == "" {
		return label
	}
	return fmt.Sprintf("%s  %s", label, state)
}

// renderOptions renders the horizontal candidate-dot row. Pulled out of View()
// so both the legacy single-line path and the new multi-line path share the
// dispatch — the only difference between them is the surrounding chrome.
func (e *EnumSelector) renderOptions() string {
	var b strings.Builder
	for i, label := range e.labels {
		marker := "○"
		if i == e.current {
			marker = "●"
		}
		token := fmt.Sprintf("%s %s", marker, label)
		if i == e.cursor && e.focused {
			b.WriteString(e.styles.cursor.Render(token))
		} else if i == e.current {
			b.WriteString(e.styles.value.Render(token))
		} else {
			b.WriteString(e.styles.dim.Render(token))
		}
		if i < len(e.labels)-1 {
			b.WriteString("  ")
		}
	}
	return b.String()
}

// ----------------------------------------------------------------------------
// ToggleRow — boolean toggle. Immediate-commit (D10).
// ----------------------------------------------------------------------------

// ToggleRow renders a `[ ]`/`[x]` checkbox-style boolean. Space/Enter toggles
// and emits IntentCommit. Per D9 it can also expose an unset gesture for
// optional booleans whose absent state is meaningfully distinct from `false`.
type ToggleRow struct {
	dotPath    string
	label      string
	current    bool
	present    bool // false = key absent in settings.json (overlay distinction per D9)
	focused    bool
	allowUnset bool
	styles     widgetStyles

	description string
	wrapWidth   int
}

func NewToggleRow(dotPath, label string, current bool, present, allowUnset bool) *ToggleRow {
	return &ToggleRow{
		dotPath:    dotPath,
		label:      label,
		current:    current,
		present:    present,
		allowUnset: allowUnset,
		styles:     defaultStyles(),
	}
}

func (t *ToggleRow) Init() tea.Cmd      { return nil }
func (t *ToggleRow) DotPath() string    { return t.dotPath }
func (t *ToggleRow) Focused() bool      { return t.focused }
func (t *ToggleRow) Focus() tea.Cmd     { t.focused = true; return nil }
func (t *ToggleRow) Blur() *FieldIntent { t.focused = false; return nil }

// SetDisplayHints attaches the description for this toggle row. The label
// argument is ignored — ToggleRow's label is set at construction (it's the
// schema property name, used as the visible row label). Description is
// rendered as a soft-wrapped dim line below the toggle.
func (t *ToggleRow) SetDisplayHints(_, description string) {
	t.description = description
}

// SetWrapWidth re-flows the description text to the host-supplied width.
func (t *ToggleRow) SetWrapWidth(w int) { t.wrapWidth = w }

func (t *ToggleRow) Update(msg tea.Msg) (FieldWidget, tea.Cmd, *FieldIntent) {
	if !t.focused {
		return t, nil, nil
	}
	key, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return t, nil, nil
	}
	switch key.String() {
	case "space", "enter", "x":
		t.current = !t.current
		t.present = true
		return t, nil, &FieldIntent{
			DotPath: t.dotPath,
			Value:   t.current,
			Status:  IntentCommit,
		}
	case "u", "backspace":
		if !t.allowUnset || !t.present {
			return t, nil, nil
		}
		t.present = false
		return t, nil, &FieldIntent{
			DotPath: t.dotPath,
			Status:  IntentUnset,
		}
	}
	return t, nil, nil
}

func (t *ToggleRow) View() string {
	check := "[ ]"
	if t.current {
		check = "[x]"
	}
	var rendered string
	if t.current {
		rendered = t.styles.checkOn.Render(check)
	} else {
		rendered = t.styles.checkOff.Render(check)
	}
	line := rendered + " " + t.styles.label.Render(t.label)
	if !t.present && t.allowUnset {
		line += " " + t.styles.dim.Render("(inherited)")
	}
	if t.focused {
		line = t.styles.cursor.Render(line)
	}
	if t.description != "" {
		line += "\n" + renderDescription(t.styles, t.description, 4, t.wrapWidth)
	}
	return line
}

// ----------------------------------------------------------------------------
// TextInput — string field with pattern + minLength. Draft-buffered (D10).
// ----------------------------------------------------------------------------

// TextInput keeps an in-widget draft buffer. Focus means the row is selected
// for navigation; Enter/i/e enters edit mode. In edit mode, Enter validates
// against pattern/minLength and commits, while Esc/focus-out discards. This
// split keeps j/k navigation from getting trapped on string fields.
type TextInput struct {
	dotPath    string
	label      string
	committed  string // last accepted value; the source of truth on discard
	draft      string // mutable buffer
	pattern    *regexp.Regexp
	minLength  int
	focused    bool
	editing    bool
	allowUnset bool
	present    bool
	errors     []string // last validation errors, rendered inline below the field
	styles     widgetStyles

	description string
	wrapWidth   int
}

func NewTextInput(dotPath, label, current string, pattern *regexp.Regexp, minLength int, present, allowUnset bool) *TextInput {
	return &TextInput{
		dotPath:    dotPath,
		label:      label,
		committed:  current,
		draft:      current,
		pattern:    pattern,
		minLength:  minLength,
		present:    present,
		allowUnset: allowUnset,
		styles:     defaultStyles(),
	}
}

func (t *TextInput) Init() tea.Cmd   { return nil }
func (t *TextInput) DotPath() string { return t.dotPath }
func (t *TextInput) Focused() bool   { return t.focused }
func (t *TextInput) Focus() tea.Cmd  { t.focused = true; return nil }

func (t *TextInput) ConsumesNavRunes() bool { return t.editing }

// SetDisplayHints attaches the description for this text row. The label
// argument is ignored (set at construction).
func (t *TextInput) SetDisplayHints(_, description string) {
	t.description = description
}

// SetWrapWidth re-flows the description text to the host-supplied width.
func (t *TextInput) SetWrapWidth(w int) { t.wrapWidth = w }

// Blur emits IntentDiscard when the draft diverged from committed (per D10:
// tab/focus = discard, never commit). The widget reverts visible state to
// committed before returning so re-focusing later shows committed, not stale
// draft.
func (t *TextInput) Blur() *FieldIntent {
	t.focused = false
	t.editing = false
	if t.draft == t.committed {
		return nil
	}
	t.draft = t.committed
	t.errors = nil
	return &FieldIntent{
		DotPath: t.dotPath,
		Value:   t.committed,
		Status:  IntentDiscard,
	}
}

// validateText runs all configured string constraints and returns one error
// per failure in declaration order. Used at commit time only (D10: validate
// at commit, not per-keystroke).
func (t *TextInput) validate(s string) []string {
	var errs []string
	if t.minLength > 0 && len(s) < t.minLength {
		errs = append(errs, fmt.Sprintf("must be at least %d characters", t.minLength))
	}
	if t.pattern != nil && !t.pattern.MatchString(s) {
		errs = append(errs, fmt.Sprintf("must match pattern %s", t.pattern.String()))
	}
	return errs
}

func (t *TextInput) Update(msg tea.Msg) (FieldWidget, tea.Cmd, *FieldIntent) {
	if !t.focused {
		return t, nil, nil
	}
	key, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return t, nil, nil
	}
	if !t.editing {
		switch key.String() {
		case "enter", "i", "e":
			t.editing = true
			t.errors = nil
		case "u", "backspace":
			if t.allowUnset && t.present {
				t.present = false
				return t, nil, &FieldIntent{
					DotPath: t.dotPath,
					Status:  IntentUnset,
				}
			}
		}
		return t, nil, nil
	}
	switch key.String() {
	case "enter":
		errs := t.validate(t.draft)
		if len(errs) > 0 {
			t.errors = errs
			return t, nil, &FieldIntent{
				DotPath: t.dotPath,
				Value:   t.draft,
				Status:  IntentReject,
				Errors:  errs,
			}
		}
		t.errors = nil
		t.committed = t.draft
		t.present = true
		t.editing = false
		return t, nil, &FieldIntent{
			DotPath: t.dotPath,
			Value:   t.draft,
			Status:  IntentCommit,
		}
	case "esc":
		if t.draft == t.committed && t.errors == nil {
			t.editing = false
			return t, nil, &FieldIntent{
				DotPath: t.dotPath,
				Value:   t.committed,
				Status:  IntentDiscard,
			}
		}
		t.draft = t.committed
		t.errors = nil
		t.editing = false
		return t, nil, &FieldIntent{
			DotPath: t.dotPath,
			Value:   t.committed,
			Status:  IntentDiscard,
		}
	case "u":
		// Unset gesture is only available when the widget is empty (so 'u'
		// can be typed normally during editing). Per D9 it removes the
		// overlay key, restoring inheritance.
		if !t.allowUnset || !t.present || t.draft != "" {
			t.draft += "u"
			return t, nil, nil
		}
		t.present = false
		return t, nil, &FieldIntent{
			DotPath: t.dotPath,
			Status:  IntentUnset,
		}
	case "backspace":
		if t.draft == "" && t.allowUnset && t.present {
			t.present = false
			return t, nil, &FieldIntent{
				DotPath: t.dotPath,
				Status:  IntentUnset,
			}
		}
		if len(t.draft) > 0 {
			t.draft = t.draft[:len(t.draft)-1]
		}
	default:
		// Treat any single-rune keypress as input. Multi-char keys (arrows,
		// home, end, etc.) are ignored by this minimal text input.
		s := key.String()
		if len([]rune(s)) == 1 {
			t.draft += s
		}
	}
	return t, nil, nil
}

func (t *TextInput) View() string {
	indicator := " "
	if t.draft != t.committed {
		indicator = t.styles.pending.Render("*")
	}
	display := t.draft
	if display == "" && !t.focused {
		display = t.styles.dim.Render("<empty>")
	}
	cursor := ""
	if t.focused && t.editing {
		cursor = "_"
	}
	line := fmt.Sprintf("%s %s: %s%s%s",
		indicator,
		t.styles.label.Render(t.label),
		t.styles.value.Render(display),
		cursor,
		"")
	if !t.present && t.allowUnset {
		line += " " + t.styles.dim.Render("(inherited)")
	}
	if t.focused && !t.editing {
		line = t.styles.cursor.Render(line) + " " + t.styles.dim.Render("[enter edit]")
	}
	if len(t.errors) > 0 {
		line += "\n  " + t.styles.error.Render(strings.Join(t.errors, "; "))
	}
	if t.description != "" {
		line += "\n" + renderDescription(t.styles, t.description, 4, t.wrapWidth)
	}
	return line
}

// ----------------------------------------------------------------------------
// NumericInput — int/float field with min/max. Draft-buffered (D10).
// ----------------------------------------------------------------------------

// NumericInput accepts a numeric draft and validates against minimum/maximum
// at commit time (D10). IsInteger=true rejects non-integral commits via Atoi
// (typed candidate is int); false uses ParseFloat (typed candidate is float64).
type NumericInput struct {
	dotPath    string
	label      string
	committed  string // canonical string form of the committed value
	draft      string
	isInteger  bool
	minimum    *float64
	maximum    *float64
	focused    bool
	editing    bool
	allowUnset bool
	present    bool
	errors     []string
	styles     widgetStyles

	description string
	wrapWidth   int
}

func NewNumericInput(dotPath, label, current string, isInteger bool, minimum, maximum *float64, present, allowUnset bool) *NumericInput {
	return &NumericInput{
		dotPath:    dotPath,
		label:      label,
		committed:  current,
		draft:      current,
		isInteger:  isInteger,
		minimum:    minimum,
		maximum:    maximum,
		present:    present,
		allowUnset: allowUnset,
		styles:     defaultStyles(),
	}
}

func (n *NumericInput) Init() tea.Cmd   { return nil }
func (n *NumericInput) DotPath() string { return n.dotPath }
func (n *NumericInput) Focused() bool   { return n.focused }
func (n *NumericInput) Focus() tea.Cmd  { n.focused = true; return nil }

// ConsumesNavRunes (NavRuneConsumer) reports whether this scalar row is in
// edit mode. Focus alone is navigation selection, so j/k remain settings
// navigation keys until the user enters edit mode with Enter/i/e.
func (n *NumericInput) ConsumesNavRunes() bool { return n.editing }

// SetDisplayHints attaches the description for this numeric row. The label
// argument is ignored (set at construction).
func (n *NumericInput) SetDisplayHints(_, description string) {
	n.description = description
}

// SetWrapWidth re-flows the description text to the host-supplied width.
func (n *NumericInput) SetWrapWidth(w int) { n.wrapWidth = w }

func (n *NumericInput) Blur() *FieldIntent {
	n.focused = false
	n.editing = false
	if n.draft == n.committed {
		return nil
	}
	n.draft = n.committed
	n.errors = nil
	return &FieldIntent{
		DotPath: n.dotPath,
		Value:   n.committed,
		Status:  IntentDiscard,
	}
}

// validate parses the draft and runs min/max. Returns (typed, errors). On
// parse failure, typed is nil and errors carries the parse error so the host
// can flash it.
func (n *NumericInput) validate(s string) (any, []string) {
	if s == "" {
		return nil, []string{"value required"}
	}
	var errs []string
	var typed any
	if n.isInteger {
		i, err := strconv.Atoi(s)
		if err != nil {
			return nil, []string{fmt.Sprintf("must be an integer (%v)", err)}
		}
		typed = i
		f := float64(i)
		if n.minimum != nil && f < *n.minimum {
			errs = append(errs, fmt.Sprintf("must be at least %v", *n.minimum))
		}
		if n.maximum != nil && f > *n.maximum {
			errs = append(errs, fmt.Sprintf("must be at most %v", *n.maximum))
		}
	} else {
		f, err := strconv.ParseFloat(s, 64)
		if err != nil {
			return nil, []string{fmt.Sprintf("must be a number (%v)", err)}
		}
		typed = f
		if n.minimum != nil && f < *n.minimum {
			errs = append(errs, fmt.Sprintf("must be at least %v", *n.minimum))
		}
		if n.maximum != nil && f > *n.maximum {
			errs = append(errs, fmt.Sprintf("must be at most %v", *n.maximum))
		}
	}
	return typed, errs
}

func (n *NumericInput) Update(msg tea.Msg) (FieldWidget, tea.Cmd, *FieldIntent) {
	if !n.focused {
		return n, nil, nil
	}
	key, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return n, nil, nil
	}
	if !n.editing {
		switch key.String() {
		case "enter", "i", "e":
			n.editing = true
			n.errors = nil
		case "u", "backspace":
			if n.allowUnset && n.present {
				n.present = false
				return n, nil, &FieldIntent{
					DotPath: n.dotPath,
					Status:  IntentUnset,
				}
			}
		}
		return n, nil, nil
	}
	switch key.String() {
	case "enter":
		typed, errs := n.validate(n.draft)
		if len(errs) > 0 {
			n.errors = errs
			return n, nil, &FieldIntent{
				DotPath: n.dotPath,
				Value:   n.draft,
				Status:  IntentReject,
				Errors:  errs,
			}
		}
		n.errors = nil
		n.committed = n.draft
		n.present = true
		n.editing = false
		return n, nil, &FieldIntent{
			DotPath: n.dotPath,
			Value:   typed,
			Status:  IntentCommit,
		}
	case "esc":
		if n.draft == n.committed && n.errors == nil {
			n.editing = false
			return n, nil, &FieldIntent{
				DotPath: n.dotPath,
				Value:   n.committed,
				Status:  IntentDiscard,
			}
		}
		n.draft = n.committed
		n.errors = nil
		n.editing = false
		return n, nil, &FieldIntent{
			DotPath: n.dotPath,
			Value:   n.committed,
			Status:  IntentDiscard,
		}
	case "u":
		if !n.allowUnset || !n.present || n.draft != "" {
			return n, nil, nil
		}
		n.present = false
		return n, nil, &FieldIntent{
			DotPath: n.dotPath,
			Status:  IntentUnset,
		}
	case "backspace":
		if n.draft == "" && n.allowUnset && n.present {
			n.present = false
			return n, nil, &FieldIntent{
				DotPath: n.dotPath,
				Status:  IntentUnset,
			}
		}
		if len(n.draft) > 0 {
			n.draft = n.draft[:len(n.draft)-1]
		}
	default:
		s := key.String()
		// Numeric input accepts digits, sign, decimal point, and the letter 'e'
		// for scientific notation when not an integer.
		if len(s) == 1 {
			r := s[0]
			ok := (r >= '0' && r <= '9') || r == '-' || r == '+'
			if !n.isInteger {
				ok = ok || r == '.' || r == 'e' || r == 'E'
			}
			if ok {
				n.draft += s
			}
		}
	}
	return n, nil, nil
}

func (n *NumericInput) View() string {
	indicator := " "
	if n.draft != n.committed {
		indicator = n.styles.pending.Render("*")
	}
	display := n.draft
	if display == "" && !n.focused {
		display = n.styles.dim.Render("<empty>")
	}
	cursor := ""
	if n.focused && n.editing {
		cursor = "_"
	}
	line := fmt.Sprintf("%s %s: %s%s",
		indicator,
		n.styles.label.Render(n.label),
		n.styles.value.Render(display),
		cursor)
	if !n.present && n.allowUnset {
		line += " " + n.styles.dim.Render("(inherited)")
	}
	if n.focused && !n.editing {
		line = n.styles.cursor.Render(line) + " " + n.styles.dim.Render("[enter edit]")
	}
	if len(n.errors) > 0 {
		line += "\n  " + n.styles.error.Render(strings.Join(n.errors, "; "))
	}
	if n.description != "" {
		line += "\n" + renderDescription(n.styles, n.description, 4, n.wrapWidth)
	}
	return line
}

// ----------------------------------------------------------------------------
// ListEditor — array-of-strings field with minItems + uniqueItems.
// Draft-buffered (D10).
// ----------------------------------------------------------------------------

// ListEditor manages a draft `[]string` and validates against minItems and
// uniqueItems at commit time. Item-level constraints (e.g. an item-pattern for
// advisor_ids) are checked as well: per-item pattern violations surface as
// individual errors so the user can see which item is wrong.
//
// Editing surface:
//   - j/k to move the row cursor
//   - 'a' opens an inline append buffer; Enter appends to draft; Esc cancels
//   - 'd' deletes the row at cursor
//   - Enter (when no append buffer is active) commits the entire draft
//   - Esc discards the draft and restores committed
type ListEditor struct {
	dotPath     string
	label       string
	committed   []string
	draft       []string
	allowed     []string
	itemPattern *regexp.Regexp
	minItems    int
	uniqueItems bool
	focused     bool
	allowUnset  bool
	present     bool
	cursor      int
	editing     bool
	appending   bool
	selector    bool
	appendBuf   string
	errors      []string
	styles      widgetStyles

	description string
	wrapWidth   int
}

func NewListEditor(dotPath, label string, current []string, itemPattern *regexp.Regexp, minItems int, uniqueItems, present, allowUnset bool) *ListEditor {
	return &ListEditor{
		dotPath:     dotPath,
		label:       label,
		committed:   append([]string(nil), current...),
		draft:       append([]string(nil), current...),
		itemPattern: itemPattern,
		minItems:    minItems,
		uniqueItems: uniqueItems,
		present:     present,
		allowUnset:  allowUnset,
		styles:      defaultStyles(),
	}
}

func NewEnumListEditor(dotPath, label string, current, allowed []string, minItems int, uniqueItems, present, allowUnset bool) *ListEditor {
	w := NewListEditor(dotPath, label, current, nil, minItems, uniqueItems, present, allowUnset)
	w.allowed = append([]string(nil), allowed...)
	w.selector = true
	return w
}

func (l *ListEditor) Init() tea.Cmd   { return nil }
func (l *ListEditor) DotPath() string { return l.dotPath }
func (l *ListEditor) Focused() bool   { return l.focused }
func (l *ListEditor) Focus() tea.Cmd  { l.focused = true; return nil }

// ConsumesNavRunes (NavRuneConsumer) — claim j/k only after Enter has put the
// list into edit/navigation mode. When the list row is merely selected, j/k
// stay available for section/field navigation.
func (l *ListEditor) ConsumesNavRunes() bool { return l.editing || l.appending }

// SetDisplayHints attaches the description for this list row. The label
// argument is ignored (set at construction).
func (l *ListEditor) SetDisplayHints(_, description string) {
	l.description = description
}

// SetWrapWidth re-flows the description text to the host-supplied width.
func (l *ListEditor) SetWrapWidth(w int) { l.wrapWidth = w }

func (l *ListEditor) Blur() *FieldIntent {
	l.focused = false
	l.editing = false
	if stringSliceEqual(l.draft, l.committed) && !l.appending {
		return nil
	}
	l.draft = append([]string(nil), l.committed...)
	l.appending = false
	l.appendBuf = ""
	l.errors = nil
	return &FieldIntent{
		DotPath: l.dotPath,
		Value:   append([]string(nil), l.committed...),
		Status:  IntentDiscard,
	}
}

func (l *ListEditor) validate(items []string) []string {
	var errs []string
	if l.minItems > 0 && len(items) < l.minItems {
		errs = append(errs, fmt.Sprintf("must have at least %d item(s)", l.minItems))
	}
	if l.uniqueItems {
		seen := make(map[string]struct{}, len(items))
		for _, it := range items {
			if _, dup := seen[it]; dup {
				errs = append(errs, fmt.Sprintf("duplicate item: %q", it))
				break
			}
			seen[it] = struct{}{}
		}
	}
	if l.itemPattern != nil {
		for i, it := range items {
			if !l.itemPattern.MatchString(it) {
				errs = append(errs, fmt.Sprintf("item %d (%q) must match pattern %s", i, it, l.itemPattern.String()))
			}
		}
	}
	if l.selector {
		allowed := make(map[string]struct{}, len(l.allowed))
		for _, it := range l.allowed {
			allowed[it] = struct{}{}
		}
		for _, it := range items {
			if _, ok := allowed[it]; !ok {
				errs = append(errs, fmt.Sprintf("unsupported item: %q", it))
			}
		}
	}
	return errs
}

func (l *ListEditor) toggleSelectedOption(value string) {
	selected := !stringSliceContains(l.draft, value)
	current := make(map[string]bool, len(l.draft)+1)
	for _, it := range l.draft {
		current[it] = true
	}
	if selected {
		current[value] = true
	} else {
		delete(current, value)
	}
	next := make([]string, 0, len(l.allowed))
	for _, it := range l.allowed {
		if current[it] {
			next = append(next, it)
		}
	}
	l.draft = next
}

func (l *ListEditor) Update(msg tea.Msg) (FieldWidget, tea.Cmd, *FieldIntent) {
	if !l.focused {
		return l, nil, nil
	}
	key, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return l, nil, nil
	}

	if l.appending {
		switch key.String() {
		case "enter":
			if l.appendBuf == "" {
				l.appending = false
				return l, nil, nil
			}
			l.draft = append(l.draft, l.appendBuf)
			l.appendBuf = ""
			l.appending = false
		case "esc":
			// Esc cancels the in-progress append. Return IntentDiscard so the
			// model recognizes esc was consumed and keeps the modal open.
			// (Returning nil would tell the model "no edit to revert" and
			// trigger the close-on-bare-esc path.)
			l.appendBuf = ""
			l.appending = false
			return l, nil, &FieldIntent{
				DotPath: l.dotPath,
				Status:  IntentDiscard,
			}
		case "backspace":
			if len(l.appendBuf) > 0 {
				l.appendBuf = l.appendBuf[:len(l.appendBuf)-1]
			}
		default:
			s := key.String()
			if len([]rune(s)) == 1 {
				l.appendBuf += s
			}
		}
		return l, nil, nil
	}

	if !l.editing {
		switch key.String() {
		case "enter", "i", "e":
			l.editing = true
			l.errors = nil
		case "u", "backspace":
			if !l.allowUnset || !l.present {
				return l, nil, nil
			}
			l.present = false
			return l, nil, &FieldIntent{
				DotPath: l.dotPath,
				Status:  IntentUnset,
			}
		}
		return l, nil, nil
	}

	switch key.String() {
	case "j", "down":
		maxCursor := len(l.draft) - 1
		if l.selector {
			maxCursor = len(l.allowed) - 1
		}
		if l.cursor < maxCursor {
			l.cursor++
		}
	case "k", "up":
		if l.cursor > 0 {
			l.cursor--
		}
	case "a":
		if l.selector {
			return l, nil, nil
		}
		l.appending = true
		l.appendBuf = ""
	case "d":
		if l.selector {
			return l, nil, nil
		}
		if l.cursor >= 0 && l.cursor < len(l.draft) {
			l.draft = append(l.draft[:l.cursor], l.draft[l.cursor+1:]...)
			if l.cursor >= len(l.draft) && l.cursor > 0 {
				l.cursor--
			}
		}
	case "space", "x":
		if l.selector && l.cursor >= 0 && l.cursor < len(l.allowed) {
			l.toggleSelectedOption(l.allowed[l.cursor])
		}
	case "enter":
		errs := l.validate(l.draft)
		if len(errs) > 0 {
			l.errors = errs
			return l, nil, &FieldIntent{
				DotPath: l.dotPath,
				Value:   append([]string(nil), l.draft...),
				Status:  IntentReject,
				Errors:  errs,
			}
		}
		l.errors = nil
		l.committed = append([]string(nil), l.draft...)
		l.present = true
		l.editing = false
		return l, nil, &FieldIntent{
			DotPath: l.dotPath,
			Value:   append([]string(nil), l.draft...),
			Status:  IntentCommit,
		}
	case "esc":
		l.editing = false
		l.draft = append([]string(nil), l.committed...)
		l.errors = nil
		return l, nil, &FieldIntent{
			DotPath: l.dotPath,
			Value:   append([]string(nil), l.committed...),
			Status:  IntentDiscard,
		}
	case "u":
		if !l.allowUnset || !l.present {
			return l, nil, nil
		}
		l.present = false
		return l, nil, &FieldIntent{
			DotPath: l.dotPath,
			Status:  IntentUnset,
		}
	}
	return l, nil, nil
}

func (l *ListEditor) View() string {
	var b strings.Builder
	indicator := " "
	if !stringSliceEqual(l.draft, l.committed) {
		indicator = l.styles.pending.Render("*")
	}
	countLabel := "items"
	if l.selector {
		countLabel = "selected"
	}
	header := fmt.Sprintf("%s %s: (%d %s)", indicator, l.styles.label.Render(l.label), len(l.draft), countLabel)
	if !l.present && l.allowUnset {
		header += " " + l.styles.dim.Render("(inherited)")
	}
	if l.focused && !l.editing {
		action := "[enter edit]"
		if l.selector {
			action = "[enter select]"
		}
		header = l.styles.cursor.Render(header) + " " + l.styles.dim.Render(action)
	}
	b.WriteString(header)
	b.WriteByte('\n')
	if l.description != "" {
		b.WriteString(renderDescription(l.styles, l.description, 4, l.wrapWidth))
		b.WriteByte('\n')
	}

	if l.selector {
		for i, item := range l.allowed {
			marker := "[ ]"
			if stringSliceContains(l.draft, item) {
				marker = "[x]"
			}
			row := fmt.Sprintf("    %s %s", marker, item)
			if l.focused && l.editing && i == l.cursor {
				b.WriteString(l.styles.cursor.Render(row))
			} else {
				b.WriteString(l.styles.value.Render(row))
			}
			b.WriteByte('\n')
		}
	} else {
		for i, item := range l.draft {
			row := fmt.Sprintf("    %s", item)
			if l.focused && l.editing && i == l.cursor && !l.appending {
				b.WriteString(l.styles.cursor.Render(row))
			} else {
				b.WriteString(l.styles.value.Render(row))
			}
			b.WriteByte('\n')
		}
	}
	if l.appending {
		cursor := "_"
		b.WriteString(fmt.Sprintf("    %s%s\n", l.styles.pending.Render("+ "), l.appendBuf+cursor))
	} else if l.focused && l.editing && l.selector {
		b.WriteString(l.styles.dim.Render("    [Space toggle  Enter commit  Esc discard]"))
		b.WriteByte('\n')
	} else if l.focused && l.editing {
		b.WriteString(l.styles.dim.Render("    [a add  d delete  Enter commit  Esc discard]"))
		b.WriteByte('\n')
	}
	if len(l.errors) > 0 {
		b.WriteString("  ")
		b.WriteString(l.styles.error.Render(strings.Join(l.errors, "; ")))
		b.WriteByte('\n')
	}
	return strings.TrimRight(b.String(), "\n")
}

// ----------------------------------------------------------------------------
// ActiveHoursRangesEditor — settlement active-hours range editor.
// ----------------------------------------------------------------------------

type ActiveHoursRange struct {
	Days  []string
	Start string
	End   string
}

type ActiveHoursRangesEditor struct {
	dotPath   string
	label     string
	committed []ActiveHoursRange
	draft     []ActiveHoursRange
	focused   bool
	editing   bool
	present   bool
	cursor    int
	field     int // 0=days, 1=start, 2=end
	errors    []string
	styles    widgetStyles

	description string
	wrapWidth   int
}

var activeHourDayIDs = []string{"mon", "tue", "wed", "thu", "fri", "sat", "sun"}

func NewActiveHoursRangesEditor(dotPath, label string, current []ActiveHoursRange, present bool) *ActiveHoursRangesEditor {
	return &ActiveHoursRangesEditor{
		dotPath:   dotPath,
		label:     label,
		committed: cloneActiveHoursRanges(current),
		draft:     cloneActiveHoursRanges(current),
		present:   present,
		styles:    defaultStyles(),
	}
}

func defaultActiveHoursRange() ActiveHoursRange {
	return ActiveHoursRange{Days: []string{"mon", "tue", "wed", "thu", "fri"}, Start: "09:00", End: "17:00"}
}

func (a *ActiveHoursRangesEditor) Init() tea.Cmd   { return nil }
func (a *ActiveHoursRangesEditor) DotPath() string { return a.dotPath }
func (a *ActiveHoursRangesEditor) Focused() bool   { return a.focused }
func (a *ActiveHoursRangesEditor) Focus() tea.Cmd  { a.focused = true; return nil }
func (a *ActiveHoursRangesEditor) ConsumesNavRunes() bool {
	return a.editing
}

func (a *ActiveHoursRangesEditor) SetDisplayHints(_, description string) {
	a.description = description
}

func (a *ActiveHoursRangesEditor) SetWrapWidth(w int) { a.wrapWidth = w }

func (a *ActiveHoursRangesEditor) Blur() *FieldIntent {
	a.focused = false
	a.editing = false
	if activeHoursRangesEqual(a.draft, a.committed) {
		return nil
	}
	a.draft = cloneActiveHoursRanges(a.committed)
	a.errors = nil
	return &FieldIntent{DotPath: a.dotPath, Value: activeHoursRangesValue(a.committed), Status: IntentDiscard}
}

func (a *ActiveHoursRangesEditor) Update(msg tea.Msg) (FieldWidget, tea.Cmd, *FieldIntent) {
	if !a.focused {
		return a, nil, nil
	}
	key, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return a, nil, nil
	}
	if !a.editing {
		switch key.String() {
		case "enter", "i", "e":
			if len(a.draft) == 0 {
				a.draft = []ActiveHoursRange{defaultActiveHoursRange()}
				a.cursor = 0
				a.field = 0
			}
			a.editing = true
			a.errors = nil
		}
		return a, nil, nil
	}

	switch key.String() {
	case "j", "down":
		a.stepEditField(+1)
	case "k", "up":
		a.stepEditField(-1)
	case "h", "left":
		if a.field > 0 {
			a.field--
		}
	case "l", "right":
		if a.field < 2 {
			a.field++
		}
	case "a":
		a.draft = append(a.draft, defaultActiveHoursRange())
		a.cursor = len(a.draft) - 1
		a.field = 0
	case "d":
		if len(a.draft) > 0 && a.cursor >= 0 && a.cursor < len(a.draft) {
			a.draft = append(a.draft[:a.cursor], a.draft[a.cursor+1:]...)
			if a.cursor >= len(a.draft) {
				a.cursor = len(a.draft) - 1
			}
			if a.cursor < 0 {
				a.cursor = 0
			}
			if len(a.draft) == 0 {
				a.field = 0
			}
		}
	case "+", "=":
		a.adjustTime(+30)
	case "-":
		a.adjustTime(-30)
	case "enter":
		errs := a.validate()
		if len(errs) > 0 {
			a.errors = errs
			return a, nil, &FieldIntent{DotPath: a.dotPath, Value: activeHoursRangesValue(a.draft), Status: IntentReject, Errors: errs}
		}
		a.errors = nil
		a.committed = cloneActiveHoursRanges(a.draft)
		a.present = true
		a.editing = false
		return a, nil, &FieldIntent{DotPath: a.dotPath, Value: activeHoursRangesValue(a.draft), Status: IntentCommit}
	case "esc":
		a.editing = false
		a.draft = cloneActiveHoursRanges(a.committed)
		a.errors = nil
		return a, nil, &FieldIntent{DotPath: a.dotPath, Value: activeHoursRangesValue(a.committed), Status: IntentDiscard}
	default:
		if len(key.String()) == 1 && key.String()[0] >= '1' && key.String()[0] <= '7' {
			a.toggleDay(int(key.String()[0] - '1'))
		}
	}
	return a, nil, nil
}

func (a *ActiveHoursRangesEditor) stepEditField(delta int) {
	if len(a.draft) == 0 {
		return
	}
	next := a.cursor*3 + a.field + delta
	max := len(a.draft)*3 - 1
	if next < 0 {
		next = 0
	}
	if next > max {
		next = max
	}
	a.cursor = next / 3
	a.field = next % 3
}

func (a *ActiveHoursRangesEditor) adjustTime(delta int) {
	if a.cursor < 0 || a.cursor >= len(a.draft) || a.field == 0 {
		return
	}
	r := &a.draft[a.cursor]
	if a.field == 1 {
		r.Start = formatMinutes(parseHHMM(r.Start) + delta)
	} else {
		r.End = formatMinutes(parseHHMM(r.End) + delta)
	}
}

func (a *ActiveHoursRangesEditor) toggleDay(dayIdx int) {
	if a.cursor < 0 || a.cursor >= len(a.draft) || dayIdx < 0 || dayIdx >= len(activeHourDayIDs) {
		return
	}
	day := activeHourDayIDs[dayIdx]
	r := &a.draft[a.cursor]
	if stringSliceContains(r.Days, day) {
		if len(r.Days) == 1 {
			return
		}
		next := r.Days[:0]
		for _, d := range r.Days {
			if d != day {
				next = append(next, d)
			}
		}
		r.Days = append([]string(nil), next...)
		return
	}
	for _, d := range activeHourDayIDs {
		if d == day || stringSliceContains(r.Days, d) {
			if !stringSliceContains(r.Days, d) {
				r.Days = append(r.Days, d)
			}
		}
	}
	r.Days = normalizeDays(r.Days)
}

func (a *ActiveHoursRangesEditor) validate() []string {
	var errs []string
	for i, r := range a.draft {
		if len(normalizeDays(r.Days)) == 0 {
			errs = append(errs, fmt.Sprintf("range %d must include at least one day", i+1))
		}
		if !validHHMM(r.Start) || !validHHMM(r.End) {
			errs = append(errs, fmt.Sprintf("range %d times must be HH:MM", i+1))
		}
	}
	return errs
}

func (a *ActiveHoursRangesEditor) View() string {
	var b strings.Builder
	indicator := " "
	if !activeHoursRangesEqual(a.draft, a.committed) {
		indicator = a.styles.pending.Render("*")
	}
	header := fmt.Sprintf("%s %s: (%d ranges)", indicator, a.styles.label.Render(a.label), len(a.draft))
	if !a.present {
		header += " " + a.styles.dim.Render("(default)")
	}
	if a.focused && !a.editing {
		header = a.styles.cursor.Render(header) + " " + a.styles.dim.Render("[enter edit]")
	}
	b.WriteString(header)
	b.WriteByte('\n')
	if a.description != "" {
		b.WriteString(renderDescription(a.styles, a.description, 4, a.wrapWidth))
		b.WriteByte('\n')
	}
	for i, r := range a.draft {
		row := fmt.Sprintf("    %s  %s-%s", daysLabel(r.Days), r.Start, r.End)
		if a.focused && a.editing && i == a.cursor {
			row += " " + a.styles.dim.Render(activeHoursFieldLabel(a.field))
			b.WriteString(a.styles.cursor.Render(row))
			b.WriteByte('\n')
			b.WriteString(a.styles.dim.Render("      days: " + activeHoursDaySelector(r.Days)))
		} else {
			b.WriteString(a.styles.value.Render(row))
		}
		b.WriteByte('\n')
	}
	if a.focused && a.editing {
		b.WriteString(a.styles.dim.Render("    [j/k field  h/l field  +/- time  1-7 days  a add  d delete  Enter commit  Esc discard]"))
		b.WriteByte('\n')
	}
	if len(a.errors) > 0 {
		b.WriteString("  ")
		b.WriteString(a.styles.error.Render(strings.Join(a.errors, "; ")))
		b.WriteByte('\n')
	}
	return strings.TrimRight(b.String(), "\n")
}

func activeHoursFieldLabel(field int) string {
	switch field {
	case 0:
		return "[days]"
	case 1:
		return "[start]"
	case 2:
		return "[end]"
	default:
		return ""
	}
}

func activeHoursDaySelector(days []string) string {
	parts := make([]string, 0, len(activeHourDayIDs))
	for i, d := range activeHourDayIDs {
		marker := "[ ]"
		if stringSliceContains(days, d) {
			marker = "[x]"
		}
		parts = append(parts, fmt.Sprintf("%d%s %s", i+1, marker, d))
	}
	return strings.Join(parts, " ")
}

func daysLabel(days []string) string {
	days = normalizeDays(days)
	if stringSliceEqual(days, []string{"mon", "tue", "wed", "thu", "fri"}) {
		return "mon-fri"
	}
	if stringSliceEqual(days, activeHourDayIDs) {
		return "daily"
	}
	return strings.Join(days, ",")
}

func activeHoursRangesValue(ranges []ActiveHoursRange) []any {
	out := make([]any, 0, len(ranges))
	for _, r := range ranges {
		out = append(out, map[string]any{
			"days":  append([]string(nil), normalizeDays(r.Days)...),
			"start": r.Start,
			"end":   r.End,
		})
	}
	return out
}

func cloneActiveHoursRanges(in []ActiveHoursRange) []ActiveHoursRange {
	out := make([]ActiveHoursRange, len(in))
	for i, r := range in {
		out[i] = ActiveHoursRange{Days: append([]string(nil), normalizeDays(r.Days)...), Start: r.Start, End: r.End}
	}
	return out
}

func activeHoursRangesEqual(a, b []ActiveHoursRange) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].Start != b[i].Start || a[i].End != b[i].End || !stringSliceEqual(normalizeDays(a[i].Days), normalizeDays(b[i].Days)) {
			return false
		}
	}
	return true
}

func normalizeDays(days []string) []string {
	out := []string{}
	for _, d := range activeHourDayIDs {
		if stringSliceContains(days, d) {
			out = append(out, d)
		}
	}
	return out
}

func validHHMM(s string) bool {
	if len(s) != 5 || s[2] != ':' {
		return false
	}
	return parseHHMM(s) >= 0
}

func parseHHMM(s string) int {
	if len(s) != 5 || s[2] != ':' {
		return -1
	}
	hh, err1 := strconv.Atoi(s[:2])
	mm, err2 := strconv.Atoi(s[3:])
	if err1 != nil || err2 != nil || hh < 0 || hh > 23 || mm < 0 || mm > 59 {
		return -1
	}
	return hh*60 + mm
}

func formatMinutes(mins int) string {
	const day = 24 * 60
	mins = ((mins % day) + day) % day
	return fmt.Sprintf("%02d:%02d", mins/60, mins%60)
}

// ----------------------------------------------------------------------------
// ClosedObjectSubPanel — closed-keyset object container.
// ----------------------------------------------------------------------------

// ClosedObjectSubPanel renders a header + a list of named child widgets. It
// owns navigation between children (Tab/Shift-Tab) but otherwise forwards
// Update to the focused child. Per D10, Tab is a discard gesture for the
// currently-focused child's draft buffer; the panel surfaces the resulting
// IntentDiscard up to the host.
type ClosedObjectSubPanel struct {
	dotPath  string
	label    string
	children []FieldWidget
	cursor   int
	focused  bool
	entered  bool
	styles   widgetStyles

	description string
	wrapWidth   int
}

func NewClosedObjectSubPanel(dotPath, label string, children []FieldWidget) *ClosedObjectSubPanel {
	return &ClosedObjectSubPanel{
		dotPath:  dotPath,
		label:    label,
		children: children,
		styles:   defaultStyles(),
	}
}

func (p *ClosedObjectSubPanel) Init() tea.Cmd { return nil }
func (p *ClosedObjectSubPanel) DotPath() string {
	return p.dotPath
}

// SetDisplayHints attaches the section description for this panel. The label
// argument is ignored (set at construction). The description is rendered as a
// soft-wrapped dim block immediately under the section header.
func (p *ClosedObjectSubPanel) SetDisplayHints(_, description string) {
	p.description = description
}

// SetWrapWidth re-flows the description text and forwards the width to every
// child widget that implements WidthSetter, so a single SetSize tick reaches
// all rendered descriptions in one pass. Children receive width-2 to account
// for the 2-char indent the panel applies to each child's rendered View, so a
// description deep in the tree wraps at the actual visible column the line
// occupies — not the panel's outer width.
func (p *ClosedObjectSubPanel) SetWrapWidth(w int) {
	p.wrapWidth = w
	childWidth := w - 2
	if childWidth < 16 {
		childWidth = 16
	}
	for _, c := range p.children {
		if ws, ok := c.(WidthSetter); ok {
			ws.SetWrapWidth(childWidth)
		}
	}
}
func (p *ClosedObjectSubPanel) Focused() bool { return p.focused }
func (p *ClosedObjectSubPanel) Focus() tea.Cmd {
	p.focused = true
	p.entered = false
	if p.cursor < 0 {
		p.cursor = 0
	}
	return nil
}

func (p *ClosedObjectSubPanel) Entered() bool { return p.entered }

// Blur on the panel blurs the focused child and propagates any IntentDiscard
// the child wants to emit (per D10's tab/focus = discard).
func (p *ClosedObjectSubPanel) Blur() *FieldIntent {
	p.focused = false
	p.entered = false
	if p.cursor >= 0 && p.cursor < len(p.children) && p.children[p.cursor].Focused() {
		return p.children[p.cursor].Blur()
	}
	return nil
}

// ConsumesNavRunes (NavRuneConsumer) — delegate to the currently-focused
// child so j/k typed into a scalar/list/kv editor's active edit mode reaches
// the child as literal input. When the child is only selected for navigation
// (or is a non-typing widget like ToggleRow), we report `false` so the model
// can advance the panel's internal cursor via NavStep instead.
func (p *ClosedObjectSubPanel) ConsumesNavRunes() bool {
	if !p.entered {
		return false
	}
	if p.cursor < 0 || p.cursor >= len(p.children) {
		return false
	}
	c := p.children[p.cursor]
	if cc, ok := c.(NavRuneConsumer); ok {
		return cc.ConsumesNavRunes()
	}
	switch c.(type) {
	case *TextInput, *NumericInput:
		return false
	}
	return false
}

// InnerFocusYRange returns the inclusive [top, bottom] line offsets of the
// currently-focused child *within this panel's rendered ViewBody()*. Returns
// (-1, -1) when the panel has no children, isn't focused, or the cursor
// points past the children list.
//
// The model's computeFocusedYRange uses this when the focused top-level
// slot is a BodyViewer-implementing ClosedObjectSubPanel: without the inner
// range, a panel taller than the viewport (capability_overrides has 15+
// child rows) would scroll the panel's *bottom* into view while the user's
// actual cursor sits at the top, leaving the focused row off-screen with no
// way to find it short of escaping the panel entirely. With this range,
// entered-container navigation keeps the cursor row anchored as the inner
// cursor moves through the panel's children.
//
// Implementation mirrors HarnessBlockPanel.InnerFocusYRange: re-emit the
// ViewBody structure while tracking newline offsets at each child boundary.
// We use `strings.Count(..., "\n")` directly (NOT lineCount which adds 1
// for trailing-newline strings) — for prefix-line-counting we want "the
// line index of the next character to write," which equals the count of
// newlines so far. Recurses into a child that itself implements
// InnerFocusRanger so a focused nested panel keeps its own inner cursor
// anchored, not just the top of the nested block.
func (p *ClosedObjectSubPanel) InnerFocusYRange() (int, int) {
	if !p.focused || !p.entered || len(p.children) == 0 {
		return -1, -1
	}
	if p.cursor < 0 || p.cursor >= len(p.children) {
		return -1, -1
	}

	var b strings.Builder
	// Mirror ViewBody's emit order EXACTLY: optional description, then
	// children separated by blank lines. Drift between this and ViewBody
	// would silently shift the y-range, so any future ViewBody change
	// must update both call sites.
	if p.description != "" {
		b.WriteString(renderDescription(p.styles, p.description, 0, p.wrapWidth))
		b.WriteByte('\n')
	}
	nextLine := func() int { return strings.Count(b.String(), "\n") }
	for i, c := range p.children {
		if i > 0 {
			b.WriteByte('\n')
		}
		top := nextLine()
		view := c.View()
		b.WriteString(view)
		// Lines added by the child's own view (relative to its first line).
		additional := strings.Count(view, "\n")
		if strings.HasSuffix(view, "\n") {
			additional--
		}
		if additional < 0 {
			additional = 0
		}
		bottom := top + additional
		if i == p.cursor {
			// Refine via the child's own InnerFocusYRange when the child
			// is itself a multi-row container — without this, the viewport
			// would scroll to show the whole nested panel when the user is
			// actually editing a single row deep inside it.
			if r, ok := c.(InnerFocusRanger); ok {
				if ctop, cbottom := r.InnerFocusYRange(); ctop >= 0 {
					return top + ctop, top + cbottom
				}
			}
			return top, bottom
		}
		b.WriteByte('\n')
	}
	return -1, -1
}

// NavStep advances the closed-object panel's internal cursor by `delta`,
// blurring the previously-focused child and focusing the new one. Returns
// (false, nil) at the boundary so the model can hop to the next top-level
// slot via focusOffset. Mirrors HarnessBlockPanel.NavStep — both containers
// participate in the same explicit-enter navigation contract so the user can
// move through one visible nesting level at a time.
//
// Recursive descent: when the currently-focused child is itself a NavStepper
// (e.g. a nested ClosedObjectSubPanel), we delegate the step to the child
// first. Only when the child reports it cannot move (boundary of its inner
// cursor) do we advance our own cursor. Without this, panels nested inside
// panels — `capture` containing `core`/`structural_signals`, etc. — would
// be unreachable past their first child after the nested panel was opened.
func (p *ClosedObjectSubPanel) NavStep(delta int) (bool, *FieldIntent) {
	if !p.focused || !p.entered || len(p.children) == 0 {
		return false, nil
	}
	if p.cursor >= 0 && p.cursor < len(p.children) {
		if cs, ok := p.children[p.cursor].(NavStepper); ok {
			if nn, ok := p.children[p.cursor].(NestedNavigator); ok && nn.Entered() {
				if moved, intent := cs.NavStep(delta); moved {
					return true, intent
				}
			}
		}
	}
	next := p.cursor + delta
	if next < 0 || next >= len(p.children) {
		return false, nil
	}
	intent := p.children[p.cursor].Blur()
	p.cursor = next
	_ = p.children[p.cursor].Focus()
	return true, intent
}

func (p *ClosedObjectSubPanel) Update(msg tea.Msg) (FieldWidget, tea.Cmd, *FieldIntent) {
	if !p.focused || len(p.children) == 0 {
		return p, nil, nil
	}
	if key, ok := msg.(tea.KeyPressMsg); ok {
		switch key.String() {
		case "enter":
			if !p.entered {
				p.entered = true
				if p.cursor < 0 {
					p.cursor = 0
				}
				if p.cursor < len(p.children) {
					return p, p.children[p.cursor].Focus(), nil
				}
				return p, nil, nil
			}
		case "tab":
			if !p.entered {
				return p, nil, nil
			}
			// Tab = discard the focused child's draft, advance cursor.
			intent := p.children[p.cursor].Blur()
			if p.cursor < len(p.children)-1 {
				p.cursor++
				_ = p.children[p.cursor].Focus()
			}
			return p, nil, intent
		case "shift+tab":
			if !p.entered {
				return p, nil, nil
			}
			intent := p.children[p.cursor].Blur()
			if p.cursor > 0 {
				p.cursor--
				_ = p.children[p.cursor].Focus()
			}
			return p, nil, intent
		case "esc":
			if !p.entered {
				return p, nil, nil
			}
			child, cmd, intent := p.children[p.cursor].Update(msg)
			p.children[p.cursor] = child
			if intent != nil {
				return p, cmd, intent
			}
			if nested, ok := child.(NestedNavigator); ok && nested.Entered() {
				return p, cmd, nil
			}
			if blurIntent := p.children[p.cursor].Blur(); blurIntent != nil {
				p.entered = false
				return p, cmd, blurIntent
			}
			p.entered = false
			return p, cmd, &FieldIntent{DotPath: p.dotPath, Status: IntentNavigate}
		}
	}
	if !p.entered {
		return p, nil, nil
	}
	child, cmd, intent := p.children[p.cursor].Update(msg)
	p.children[p.cursor] = child
	return p, cmd, intent
}

func (p *ClosedObjectSubPanel) View() string {
	var b strings.Builder
	if p.label != "" {
		label := p.styles.subLabel.Render(p.label)
		if p.focused {
			state := "[enter]"
			if p.entered {
				state = "[active]"
			}
			label = p.styles.cursor.Render(p.label) + " " + p.styles.dim.Render(state)
		}
		b.WriteString(label)
		b.WriteByte('\n')
	}
	if p.description != "" {
		b.WriteString(renderDescription(p.styles, p.description, 2, p.wrapWidth))
		b.WriteByte('\n')
	}
	// Indent each child under the section header so per-row content (label,
	// options, description) lines up vertically and visually nests inside the
	// panel rather than sitting flush-left next to the header.
	for i, c := range p.children {
		if i > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(indentEachLine(c.View(), "  "))
		b.WriteByte('\n')
	}
	return strings.TrimRight(b.String(), "\n")
}

// ViewBody renders this panel's description + children WITHOUT the outer
// label header and WITHOUT the panel's own 2-col indent. The model's
// renderSection helper wraps this body in an open section frame whose header
// already carries the label and whose left rail provides the visual indent
// cue — emitting either inside the body would double up. Inner
// (non-top-level) panels still go through View() (which keeps the bold
// subsection header + child indent) so nested hierarchy stays legible
// without the visual noise of nested frames.
func (p *ClosedObjectSubPanel) ViewBody() string {
	var b strings.Builder
	if p.description != "" {
		b.WriteString(renderDescription(p.styles, p.description, 0, p.wrapWidth))
		b.WriteByte('\n')
	}
	for i, c := range p.children {
		if i > 0 {
			b.WriteByte('\n')
		}
		// No indent here — the section frame's rail provides the left
		// gutter. Inner ClosedObjectSubPanels still self-indent their own
		// children inside their View() so nested hierarchy reads.
		b.WriteString(c.View())
		b.WriteByte('\n')
	}
	return strings.TrimRight(b.String(), "\n")
}

// ----------------------------------------------------------------------------
// OpenKeysetKVEditor — open-keyset map editor (e.g. ceremonies_map).
// Draft-buffered (D10).
// ----------------------------------------------------------------------------

// OpenKeysetKVEditor manages a draft open-keyset map for fields whose keyset
// is open at the schema layer. Add commits the full map (Enter); Esc discards.
// Per-value parsing delegates to a caller-supplied OpenMapValueParser so the
// generic editor can still emit schema-shaped values (number maps commit
// numbers, ceremony maps commit []string, nested object maps commit objects).
type OpenMapValueParser func(key, value string) (any, []string)

type OpenKeysetKVEditor struct {
	dotPath     string
	label       string
	committed   map[string]string // string-form values (e.g. comma-joined arrays)
	draft       map[string]string
	keyOrder    []string
	keyPattern  *regexp.Regexp
	valueParser OpenMapValueParser
	focused     bool
	allowUnset  bool
	present     bool
	editing     bool
	mode        kvEditorMode
	keyBuf      string
	valBuf      string
	editingKey  string // when editing existing entry, the key being edited
	cursor      int
	errors      []string
	styles      widgetStyles

	description string
	wrapWidth   int
}

type kvEditorMode int

const (
	kvNavigating kvEditorMode = iota
	kvAddingKey
	kvAddingValue
	kvEditingValue
)

func NewOpenKeysetKVEditor(dotPath, label string, current map[string]string, keyPattern *regexp.Regexp, valueValidator func(key, value string) []string, present, allowUnset bool) *OpenKeysetKVEditor {
	var parser OpenMapValueParser
	if valueValidator != nil {
		parser = func(key, value string) (any, []string) {
			return value, valueValidator(key, value)
		}
	}
	return NewTypedOpenKeysetKVEditor(dotPath, label, current, keyPattern, parser, present, allowUnset)
}

func NewTypedOpenKeysetKVEditor(dotPath, label string, current map[string]string, keyPattern *regexp.Regexp, valueParser OpenMapValueParser, present, allowUnset bool) *OpenKeysetKVEditor {
	if valueParser == nil {
		valueParser = func(_ string, value string) (any, []string) { return value, nil }
	}
	cp := make(map[string]string, len(current))
	keys := make([]string, 0, len(current))
	for k, v := range current {
		cp[k] = v
		keys = append(keys, k)
	}
	committed := make(map[string]string, len(current))
	for k, v := range current {
		committed[k] = v
	}
	keys = sortedKeys(cp)
	return &OpenKeysetKVEditor{
		dotPath:     dotPath,
		label:       label,
		committed:   committed,
		draft:       cp,
		keyOrder:    keys,
		keyPattern:  keyPattern,
		valueParser: valueParser,
		present:     present,
		allowUnset:  allowUnset,
		styles:      defaultStyles(),
	}
}

// NewStringArrayOpenKeysetKVEditor constructs the common open-map shape used
// by ceremonies maps: dynamic key -> []string. Values are displayed as comma-
// separated strings for fast editing and commit as []string, not as the raw
// display text.
func NewStringArrayOpenKeysetKVEditor(dotPath, label string, current map[string]string, present, allowUnset bool) *OpenKeysetKVEditor {
	itemMin := 1
	itemPattern := regexp.MustCompile(`^[a-z][a-z0-9-]*$`)
	valueSchema := &SchemaNode{
		Kind:        KindArray,
		UniqueItems: true,
		Items: &SchemaNode{
			Kind:            KindString,
			Pattern:         itemPattern.String(),
			PatternCompiled: itemPattern,
			minLength:       &itemMin,
		},
	}
	return NewTypedOpenKeysetKVEditor(dotPath, label, current, nil, openMapValueParser(valueSchema), present, allowUnset)
}

func (kv *OpenKeysetKVEditor) Init() tea.Cmd   { return nil }
func (kv *OpenKeysetKVEditor) DotPath() string { return kv.dotPath }
func (kv *OpenKeysetKVEditor) Focused() bool   { return kv.focused }
func (kv *OpenKeysetKVEditor) Focus() tea.Cmd  { kv.focused = true; return nil }

// ConsumesNavRunes (NavRuneConsumer) — claim j/k after Enter has opened the
// kv editor, including its key/value typing modes. While the row is merely
// selected, j/k remain available for settings navigation.
func (kv *OpenKeysetKVEditor) ConsumesNavRunes() bool {
	return kv.editing || kv.mode != kvNavigating
}

// SetDisplayHints attaches the description for this KV section. The label
// argument is ignored (set at construction).
func (kv *OpenKeysetKVEditor) SetDisplayHints(_, description string) {
	kv.description = description
}

// SetWrapWidth re-flows the description text to the host-supplied width.
func (kv *OpenKeysetKVEditor) SetWrapWidth(w int) { kv.wrapWidth = w }

func (kv *OpenKeysetKVEditor) Blur() *FieldIntent {
	kv.focused = false
	kv.editing = false
	if kv.mode == kvNavigating && stringMapEqual(kv.draft, kv.committed) {
		return nil
	}
	kv.draft = copyStringMap(kv.committed)
	kv.keyOrder = sortedKeys(kv.committed)
	kv.mode = kvNavigating
	kv.keyBuf = ""
	kv.valBuf = ""
	kv.errors = nil
	return &FieldIntent{
		DotPath: kv.dotPath,
		Value:   copyStringMap(kv.committed),
		Status:  IntentDiscard,
	}
}

func (kv *OpenKeysetKVEditor) typedDraft() (map[string]any, []string) {
	var errs []string
	typed := make(map[string]any, len(kv.draft))
	if kv.keyPattern != nil {
		for k := range kv.draft {
			if !kv.keyPattern.MatchString(k) {
				errs = append(errs, fmt.Sprintf("key %q must match pattern %s", k, kv.keyPattern.String()))
			}
		}
	}
	for k, v := range kv.draft {
		parsed, vErrs := kv.valueParser(k, v)
		if len(vErrs) > 0 {
			for _, e := range vErrs {
				errs = append(errs, fmt.Sprintf("%s: %s", k, e))
			}
			continue
		}
		typed[k] = parsed
	}
	return typed, errs
}

func (kv *OpenKeysetKVEditor) Update(msg tea.Msg) (FieldWidget, tea.Cmd, *FieldIntent) {
	if !kv.focused {
		return kv, nil, nil
	}
	key, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return kv, nil, nil
	}
	switch kv.mode {
	case kvAddingKey:
		switch key.String() {
		case "enter":
			if kv.keyBuf == "" {
				kv.mode = kvNavigating
				return kv, nil, nil
			}
			kv.editingKey = kv.keyBuf
			kv.valBuf = ""
			kv.mode = kvAddingValue
		case "esc":
			// Esc cancels the in-progress key entry. Return IntentDiscard so
			// the model treats esc as consumed (preventing the close-on-
			// bare-esc fallback) and the modal stays open in kvNavigating.
			kv.keyBuf = ""
			kv.mode = kvNavigating
			return kv, nil, &FieldIntent{
				DotPath: kv.dotPath,
				Status:  IntentDiscard,
			}
		case "backspace":
			if len(kv.keyBuf) > 0 {
				kv.keyBuf = kv.keyBuf[:len(kv.keyBuf)-1]
			}
		default:
			if s := key.String(); len([]rune(s)) == 1 {
				kv.keyBuf += s
			}
		}
		return kv, nil, nil
	case kvAddingValue, kvEditingValue:
		switch key.String() {
		case "enter":
			if _, exists := kv.draft[kv.editingKey]; !exists {
				kv.keyOrder = append(kv.keyOrder, kv.editingKey)
			}
			kv.draft[kv.editingKey] = kv.valBuf
			kv.editingKey = ""
			kv.keyBuf = ""
			kv.valBuf = ""
			kv.mode = kvNavigating
		case "esc":
			// Esc cancels the in-progress value entry (whether adding a new
			// pair or editing an existing one). Same IntentDiscard return as
			// kvAddingKey above — without it, bare-esc closes the modal.
			kv.editingKey = ""
			kv.keyBuf = ""
			kv.valBuf = ""
			kv.mode = kvNavigating
			return kv, nil, &FieldIntent{
				DotPath: kv.dotPath,
				Status:  IntentDiscard,
			}
		case "backspace":
			if len(kv.valBuf) > 0 {
				kv.valBuf = kv.valBuf[:len(kv.valBuf)-1]
			}
		default:
			if s := key.String(); len([]rune(s)) == 1 {
				kv.valBuf += s
			}
		}
		return kv, nil, nil
	}

	if !kv.editing {
		switch key.String() {
		case "enter", "i", "e":
			kv.editing = true
			kv.errors = nil
		case "u", "backspace":
			if !kv.allowUnset || !kv.present {
				return kv, nil, nil
			}
			kv.present = false
			return kv, nil, &FieldIntent{
				DotPath: kv.dotPath,
				Status:  IntentUnset,
			}
		}
		return kv, nil, nil
	}

	// kvNavigating mode
	switch key.String() {
	case "j", "down":
		if kv.cursor < len(kv.keyOrder)-1 {
			kv.cursor++
		}
	case "k", "up":
		if kv.cursor > 0 {
			kv.cursor--
		}
	case "a":
		kv.mode = kvAddingKey
		kv.keyBuf = ""
	case "e":
		if kv.cursor >= 0 && kv.cursor < len(kv.keyOrder) {
			kv.editingKey = kv.keyOrder[kv.cursor]
			kv.valBuf = kv.draft[kv.editingKey]
			kv.mode = kvEditingValue
		}
	case "d":
		if kv.cursor >= 0 && kv.cursor < len(kv.keyOrder) {
			k := kv.keyOrder[kv.cursor]
			delete(kv.draft, k)
			kv.keyOrder = append(kv.keyOrder[:kv.cursor], kv.keyOrder[kv.cursor+1:]...)
			if kv.cursor >= len(kv.keyOrder) && kv.cursor > 0 {
				kv.cursor--
			}
		}
	case "enter":
		typed, errs := kv.typedDraft()
		if len(errs) > 0 {
			kv.errors = errs
			return kv, nil, &FieldIntent{
				DotPath: kv.dotPath,
				Value:   copyStringMap(kv.draft),
				Status:  IntentReject,
				Errors:  errs,
			}
		}
		kv.errors = nil
		kv.committed = copyStringMap(kv.draft)
		kv.present = true
		kv.editing = false
		return kv, nil, &FieldIntent{
			DotPath: kv.dotPath,
			Value:   typed,
			Status:  IntentCommit,
		}
	case "esc":
		kv.editing = false
		kv.draft = copyStringMap(kv.committed)
		kv.keyOrder = sortedKeys(kv.committed)
		kv.errors = nil
		return kv, nil, &FieldIntent{
			DotPath: kv.dotPath,
			Value:   copyStringMap(kv.committed),
			Status:  IntentDiscard,
		}
	case "u":
		if !kv.allowUnset || !kv.present {
			return kv, nil, nil
		}
		kv.present = false
		return kv, nil, &FieldIntent{
			DotPath: kv.dotPath,
			Status:  IntentUnset,
		}
	}
	return kv, nil, nil
}

func (kv *OpenKeysetKVEditor) View() string {
	var b strings.Builder
	indicator := " "
	if !stringMapEqual(kv.draft, kv.committed) {
		indicator = kv.styles.pending.Render("*")
	}
	header := fmt.Sprintf("%s %s: (%d entries)", indicator, kv.styles.label.Render(kv.label), len(kv.draft))
	if !kv.present && kv.allowUnset {
		header += " " + kv.styles.dim.Render("(inherited)")
	}
	if kv.focused && !kv.editing {
		header = kv.styles.cursor.Render(header) + " " + kv.styles.dim.Render("[enter edit]")
	}
	b.WriteString(header)
	body := kv.viewBodyRows()
	if body != "" {
		b.WriteByte('\n')
		b.WriteString(body)
	}
	return strings.TrimRight(b.String(), "\n")
}

// ViewBody renders this KV editor's content without the outer label header,
// for use inside a section frame whose own header already carries the label.
// The "(N entries)" + draft-pending indicator are kept inside the body since
// they describe state, not identity. Per the BodyViewer interface contract.
func (kv *OpenKeysetKVEditor) ViewBody() string {
	indicator := " "
	if !stringMapEqual(kv.draft, kv.committed) {
		indicator = kv.styles.pending.Render("*")
	}
	header := fmt.Sprintf("%s (%d entries)", indicator, len(kv.draft))
	if !kv.present && kv.allowUnset {
		header += " " + kv.styles.dim.Render("(inherited)")
	}
	if kv.focused && !kv.editing {
		header = kv.styles.cursor.Render(header) + " " + kv.styles.dim.Render("[enter edit]")
	}
	body := kv.viewBodyRows()
	if body == "" {
		return header
	}
	return header + "\n" + body
}

// viewBodyRows renders the row list + active-mode editor line + errors.
// Pulled out so View() and ViewBody() share the same row-rendering surface.
func (kv *OpenKeysetKVEditor) viewBodyRows() string {
	var b strings.Builder
	if kv.description != "" {
		b.WriteString(renderDescription(kv.styles, kv.description, 4, kv.wrapWidth))
		b.WriteByte('\n')
	}

	for i, k := range kv.keyOrder {
		v := kv.draft[k]
		row := fmt.Sprintf("    %s = %s", k, v)
		if kv.focused && kv.editing && i == kv.cursor && kv.mode == kvNavigating {
			b.WriteString(kv.styles.cursor.Render(row))
		} else {
			b.WriteString(kv.styles.value.Render(row))
		}
		b.WriteByte('\n')
	}

	switch kv.mode {
	case kvAddingKey:
		b.WriteString(fmt.Sprintf("    %s%s_\n", kv.styles.pending.Render("+ key: "), kv.keyBuf))
	case kvAddingValue:
		b.WriteString(fmt.Sprintf("    %s%s = %s_\n", kv.styles.pending.Render("+ "), kv.editingKey, kv.valBuf))
	case kvEditingValue:
		b.WriteString(fmt.Sprintf("    %s%s = %s_\n", kv.styles.pending.Render("~ "), kv.editingKey, kv.valBuf))
	default:
		if kv.focused && kv.editing {
			b.WriteString(kv.styles.dim.Render("    [a add  e edit  d delete  Enter commit  Esc discard]"))
			b.WriteByte('\n')
		}
	}

	if len(kv.errors) > 0 {
		b.WriteString("  ")
		b.WriteString(kv.styles.error.Render(strings.Join(kv.errors, "; ")))
		b.WriteByte('\n')
	}
	return strings.TrimRight(b.String(), "\n")
}

// ----------------------------------------------------------------------------
// internal helpers.
// ----------------------------------------------------------------------------

func stringSliceEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func stringSliceContains(items []string, needle string) bool {
	for _, item := range items {
		if item == needle {
			return true
		}
	}
	return false
}

func stringMapEqual(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, va := range a {
		if vb, ok := b[k]; !ok || va != vb {
			return false
		}
	}
	return true
}

func copyStringMap(m map[string]string) map[string]string {
	out := make(map[string]string, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

func sortedKeys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	// Stable order without importing sort: insertion sort is fine for small
	// keysets (worst-case dozens of entries).
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j-1] > out[j]; j-- {
			out[j-1], out[j] = out[j], out[j-1]
		}
	}
	return out
}
