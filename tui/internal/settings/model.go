// Package settings: model.go hosts the schema-driven Bubble Tea sub-model
// SettingsModel — the configurator modal body (D2).
//
// Boundaries (do not relax without revisiting the work item plan):
//
//   - View() returns BODY content only. The host (package main) wraps it
//     with the existing modal chrome (buildModalBox + placeModal). This file
//     does NOT import package main symbols (modalStyleSet, newModalStyles,
//     buildModalBox) — they are unexported in package main and the body-vs-
//     chrome split makes that import boundary impossible by construction (D2).
//
//   - SettingsModel does NOT touch the real ~/.lore/config or
//     adapters/settings.schema.json directly. Production callers pass real
//     paths via SettingsModelOptions; tests pass temp fixtures and a fake
//     CommandRunner. The injection seam is structural, not optional.
//
//   - The schema-driven walker EXCLUDES `tui_launch_framework` and the entire
//     `harnesses` subtree (D8 boundary). Those dot-paths are owned by
//     dedicated top-sections registered via RegisterTopSection —
//     PrimaryRadio (tui_launch_framework) and HarnessBlockPanel (harnesses.*).
//     Each HarnessBlockPanel embeds a per-harness enabled toggle as its
//     first child; that widget routes through ToggleHarness (which shells
//     out to scripts/harness-toggle/{enable,disable}.sh) instead of a
//     plain Patch. It also hides schema-valid but non-user-facing metadata
//     paths (`version`) so the generic renderer stays a settings editor
//     rather than a raw JSON inspector.
//
//   - Write routing per D5/D8/D9:
//
//   - IntentCommit on a generic field → SettingsStore.Patch(path, value),
//     after closed-set re-validation (D6) when the target is enum-typed.
//
//   - IntentCommit on `tui_launch_framework` → Patch after closed-set check
//     against the loaded capabilities frameworks list (D8).
//
//   - IntentCommit on `harnesses.<fw>.enabled` is FORBIDDEN as a plain
//     Patch — that path is owned by the per-harness toggle which routes
//     through CommandRunner.Run on scripts/harness-toggle/{enable,
//     disable}.sh. A stray IntentCommit on a harness-enabled path is
//     treated as a programming error and surfaced as a status-bar
//     error — the model deliberately does NOT silently fall back to
//     Patch (the script installs/removes symlinks and rewrites the
//     instruction file; a plain Patch would drift those out of sync).
//
//   - IntentUnset → SettingsStore.Delete(path).
//
//   - IntentReject → status-bar flash; no write issued.
//
//   - IntentDiscard / IntentNavigate → no-op; the widget already reverted
//     a draft, or a container consumed navigation without changing values.
//
//   - Style caching per D3 + the lipgloss O(n)-per-frame gotcha: themeStyles
//     is constructed once at NewSettingsModel time and stashed on the model
//     struct. View() never allocates a lipgloss.Style.
package settings

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ----------------------------------------------------------------------------
// Injection seams.
// ----------------------------------------------------------------------------

// SettingsStore abstracts the read/write surface SettingsModel uses for
// shape values. Production constructs a *defaultSettingsStore from
// tui/internal/config; tests pass a fake. Note that `Get` is unused in the
// initial walk (effective values are loaded en-bloc via LoadAll) but is
// retained on the interface so a future targeted refresh path can call it
// without widening the interface mid-task.
type SettingsStore interface {
	// LoadAll returns the entire settings.json document as a map. Missing
	// file → empty map (mirrors loader semantics, not an error).
	LoadAll() (map[string]any, error)
	// Patch writes value at the dot-separated path. Mirrors
	// tui/internal/config.SettingsPatch.
	Patch(dotPath string, value any) error
	// Delete removes the leaf at the dot-separated path. Mirrors
	// tui/internal/config.SettingsDelete (idempotent on absence).
	Delete(dotPath string) error
}

// CommandRunner abstracts the shell-out surface SettingsModel uses for
// scripts/harness-toggle/{enable,disable}.sh and any future external
// commands. The Run signature accepts the script path + args and returns
// (stdout, stderr, err). Tests pass a fake recording the calls; production
// passes a thin os/exec wrapper.
type CommandRunner interface {
	Run(scriptPath string, args ...string) (stdout, stderr string, err error)
}

// SettingsModelOptions bundles the constructor inputs. All fields are
// required; missing fields cause NewSettingsModel to return an error rather
// than silently defaulting to real disk paths (the testability contract is
// load-bearing — a default would let a misconfigured test mutate
// ~/.lore/config).
type SettingsModelOptions struct {
	SchemaPath       string
	CapabilitiesPath string
	Store            SettingsStore
	Runner           CommandRunner
	// EnableScript / DisableScript are absolute paths to the harness-toggle
	// shell scripts. Injectable so tests can point them at a fake runner.
	// ToggleHarness invokes them with the framework as a positional arg.
	EnableScript  string
	DisableScript string
	// Registry is the widget-override hook. Pass NewWidgetRegistry() when
	// no overrides are needed.
	Registry *WidgetRegistry
	// DescriptionsByDotPath supplies per-field description text the model
	// applies to widgets at construction (via DisplayHinter). Optional —
	// when a dot-path is absent here, the schema's `description` is used.
	// The host populates this with per-capability descriptions from
	// adapters/capabilities.json (capability_overrides.<key>) and per-role
	// descriptions from adapters/roles.json (roles.<role>) so the
	// configurator surfaces the same explanatory text the loaders consult,
	// not just the generic shared $defs description.
	DescriptionsByDotPath map[string]string
}

// ----------------------------------------------------------------------------
// SettingsModel.
// ----------------------------------------------------------------------------

// topSection is a dedicated widget registered above the schema-driven walker
// for D8-excluded paths (tui_launch_framework, harnesses subtree).
// Task 5's HarnessBlockPanel / PrimaryRadio plug in via RegisterTopSection.
type topSection struct {
	name   string
	widget FieldWidget
}

// SettingsModel is the configurator modal body. It owns the schema-driven
// widget tree, dispatches keystrokes to the focused widget, translates the
// resulting FieldIntent into write-routing calls, and surfaces write errors
// in the status line.
//
// The model is consumed by the host (package main) per D2: host wraps
// SettingsModel.View() with buildModalBox + placeModal chrome.
type SettingsModel struct {
	schema        *Schema
	frameworks    []string // capabilities.json frameworks (closed set for tui_launch_framework)
	registry      *WidgetRegistry
	store         SettingsStore
	runner        CommandRunner
	enableScript  string
	disableScript string
	// descByPath is the host-supplied per-dot-path description override map.
	// Consulted in buildWidget before the schema's own Description so the
	// host can inject capabilities.json / roles.json text without modifying
	// the schema document itself.
	descByPath map[string]string
	// wrapWidth is the latest body-content width pushed in via SetSize. It
	// is forwarded to each widget that implements WidthSetter so descriptions
	// re-flow on terminal resize. Zero means "use the widget's default
	// (defaultDescWrap)".
	wrapWidth int

	// effective is the snapshot of settings.json loaded at construction (and
	// after every external shell-out). Used by the schema walker to seed
	// each widget's `current` and `present` flags.
	effective map[string]any

	// topSections render before the schema-driven widgets. Order is
	// preserved by registration order. Task 5 attaches HarnessBlockPanel /
	// PrimaryRadio / global agent toggle here.
	topSections []topSection

	// widgets is the schema-driven walker output, in declared property
	// order, with dedicated-top-section paths and hidden metadata paths
	// excluded (D8/settings-editor boundary).
	widgets []FieldWidget

	// limitDotPath restricts the model to a single top-level widget while
	// preserving the same schema-backed write routing. Hosts use this for
	// inline editors such as the settlement panel, where the whole settings
	// modal would be too much surface area.
	limitDotPath string
	compactEmbed bool

	focusIdx int  // -1 when nothing focused; otherwise index into the combined topSections+widgets list
	closed   bool // set by Esc at top-level when no draft is active

	// statusMsg is rendered at the bottom of the body. Written on
	// IntentReject, write errors, and external-command stderr surfacing.
	statusMsg     string
	statusIsError bool

	// harnessToggleLocked: set to a non-empty framework id while a
	// harness-toggle shell-out is in flight, to suppress double-press races
	// on that specific harness (per the optimistic-UI plan in the
	// sharp-edges consult). Other harnesses' toggles remain interactive
	// while one is mid-flight.
	harnessToggleLocked map[string]bool

	styles themeStyles

	// schemaErr captures *UnsupportedConstructError (or any LoadSchema error)
	// so View() can render the modal as a static error banner per the D1
	// verification gate.
	schemaErr error

	// viewport scrolls the rendered body when content exceeds the host-given
	// height. Width/Height are sized via SetSize from the host at modal open
	// (or on WindowSizeMsg). When height is zero (host hasn't sized yet),
	// View falls back to the full content string so behavior is identical to
	// pre-viewport rendering.
	viewport     viewport.Model
	viewportInit bool
}

// SetSize informs the modal of the host-allocated body width/height. The host
// computes these from the terminal dimensions minus modal chrome (border,
// title row, hint row). View() uses the values to size the internal viewport
// so long widget trees scroll instead of clipping.
//
// SetSize also forwards the body width to every widget that implements
// WidthSetter so soft-wrapped descriptions track the terminal width.
// ClosedObjectSubPanel chains the same call to its children, so a single
// SetSize tick reaches every nested rendered description in one pass.
func (m *SettingsModel) SetSize(width, height int) {
	if !m.viewportInit {
		m.viewport = viewport.New(width, height)
		m.viewportInit = true
	} else {
		m.viewport.Width = width
		m.viewport.Height = height
	}
	m.wrapWidth = width
	m.propagateWrapWidth()
}

// propagateWrapWidth pushes m.wrapWidth into every widget that accepts a
// description wrap width. Called on SetSize and after rebuildWidgets so
// freshly-walked widgets pick up the latest size.
func (m *SettingsModel) propagateWrapWidth() {
	if m.wrapWidth <= 0 {
		return
	}
	for _, ts := range m.topSections {
		if ws, ok := ts.widget.(WidthSetter); ok {
			ws.SetWrapWidth(m.wrapWidth)
		}
	}
	for _, w := range m.widgets {
		if ws, ok := w.(WidthSetter); ok {
			ws.SetWrapWidth(m.wrapWidth)
		}
	}
}

// NewSettingsModel constructs a SettingsModel from injectable options.
//
// Errors from LoadSchema split into two categories:
//
//   - *UnsupportedConstructError or schema-malformed: returned non-nil so
//     the caller can decide whether to refuse to open the modal or render
//     it with a static error body. The host's normal path is to render the
//     modal with the error visible (per the D1 verification gate); to make
//     that easy, NewSettingsModel returns BOTH a usable SettingsModel
//     (whose View renders the error) AND the error itself, so the caller
//     can route the error to logs while still rendering the modal.
//
//   - capabilities.json read/parse failure: returned as a hard error and
//     the model is nil. tui_launch_framework's closed-set is load-bearing
//     for D8; rendering the modal without it is a downgrade we refuse.
func NewSettingsModel(opts SettingsModelOptions) (*SettingsModel, error) {
	if opts.Store == nil {
		return nil, fmt.Errorf("settings.NewSettingsModel: Store is required")
	}
	if opts.Runner == nil {
		return nil, fmt.Errorf("settings.NewSettingsModel: Runner is required")
	}
	if opts.SchemaPath == "" {
		return nil, fmt.Errorf("settings.NewSettingsModel: SchemaPath is required")
	}
	if opts.CapabilitiesPath == "" {
		return nil, fmt.Errorf("settings.NewSettingsModel: CapabilitiesPath is required")
	}
	if opts.Registry == nil {
		opts.Registry = NewWidgetRegistry()
	}

	frameworks, err := enumerateCapabilityFrameworks(opts.CapabilitiesPath)
	if err != nil {
		return nil, err
	}

	m := &SettingsModel{
		registry:            opts.Registry,
		store:               opts.Store,
		runner:              opts.Runner,
		enableScript:        opts.EnableScript,
		disableScript:       opts.DisableScript,
		frameworks:          frameworks,
		descByPath:          opts.DescriptionsByDotPath,
		styles:              newThemeStyles(),
		focusIdx:            -1,
		harnessToggleLocked: map[string]bool{},
	}

	schema, schemaErr := LoadSchema(opts.SchemaPath)
	if schemaErr != nil {
		// Per D1: stash the error and render a static-banner View. Do NOT
		// abort construction — the host's normal path is to open the modal
		// with the error visible.
		m.schemaErr = schemaErr
		return m, schemaErr
	}
	m.schema = schema

	effective, err := opts.Store.LoadAll()
	if err != nil {
		return nil, fmt.Errorf("settings: load effective values: %w", err)
	}
	m.effective = effective

	m.rebuildWidgets()
	return m, nil
}

// enumerateCapabilityFrameworks reads adapters/capabilities.json and returns
// the sorted list of framework ids. The path is injectable so tests use a
// fixture; production reads the live adapters/capabilities.json.
func enumerateCapabilityFrameworks(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("settings: read capabilities %s: %w", path, err)
	}
	var doc struct {
		Frameworks map[string]json.RawMessage `json:"frameworks"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("settings: parse capabilities %s: %w", path, err)
	}
	out := make([]string, 0, len(doc.Frameworks))
	for k := range doc.Frameworks {
		out = append(out, k)
	}
	sort.Strings(out)
	return out, nil
}

// RegisterTopSection attaches a dedicated widget above the schema-driven
// walker for one of the D8-excluded dot-paths. Task 5's HarnessBlockPanel /
// PrimaryRadio / global agent toggle plug in here.
//
// Order of registration determines render order. SettingsModel does NOT
// validate that the registered widget's dot-path actually corresponds to
// an excluded path — the caller is responsible for that contract. (A
// validating wrapper would couple the seam to the excluded-path list, which
// would force task 5 to know about the walker's internals; the seam stays
// loose so task 5 can choose its own widget surface.)
func (m *SettingsModel) RegisterTopSection(name string, widget FieldWidget) {
	m.topSections = append(m.topSections, topSection{name: name, widget: widget})
}

// rebuildWidgets walks the schema and constructs the schema-driven widget
// list, excluding paths that are either owned by a dedicated top-section or
// intentionally hidden because they are metadata/retired-compat fields, not
// user settings. Called at construction and after external shell-outs that
// touch settings.json (e.g., the agent toggle). Re-walking discards every
// non-focused widget's draft (which is correct per D10's tab/focus = discard
// rule); the focused widget's index is preserved when its dot-path still
// exists post-walk.
func (m *SettingsModel) rebuildWidgets() {
	if m.schema == nil || m.schema.Root == nil {
		m.widgets = nil
		return
	}
	if m.schema.Root.Kind != KindObjectClosed {
		m.widgets = nil
		return
	}

	priorFocusPath := m.focusedDotPath()
	m.widgets = m.widgets[:0]

	for _, name := range m.schema.Root.PropertyOrder {
		if isExcludedTopLevel(name) {
			continue
		}
		if isHiddenSettingsPath(name) {
			continue
		}
		child := m.schema.Root.Properties[name]
		w := m.buildWidget("", name, child)
		if w != nil {
			if name == "capability_overrides" {
				w = NewAdvancedSection("advanced", "capability_overrides", w)
			}
			m.widgets = append(m.widgets, w)
		}
	}

	// After every walk, re-broadcast the cached wrap width so the freshly-
	// constructed widget tree picks up the host-allocated body width
	// without waiting for the next SetSize tick.
	m.propagateWrapWidth()

	// Restore focus by dot-path (not by index) — schema property order is
	// stable but the widgets slice indices can shift if the property set
	// changes between sessions.
	if priorFocusPath != "" {
		m.focusByDotPath(priorFocusPath)
	}
}

// isExcludedTopLevel reports whether a top-level schema property is owned
// by a dedicated top-section (D8 boundary). Owned paths:
//   - tui_launch_framework: PrimaryRadio (closed-set radio, immediate-commit Patch)
//   - harnesses.*:      HarnessBlockPanel (per-harness panel; the embedded
//     enabled toggle routes through ToggleHarness, not Patch)
//
// The retired top-level `agent` block is no longer in the schema. If a stale
// document still carries an `agent` key (e.g., a user upgrading mid-cycle),
// install.sh strips it during migration; in the unlikely event the modal
// opens against a pre-migration document, the schema walker would simply
// reject the unknown property.
func isExcludedTopLevel(name string) bool {
	switch name {
	case "tui_launch_framework", "harnesses":
		return true
	}
	return false
}

// isHiddenSettingsPath reports schema-valid paths that are deliberately not
// rendered in the TUI settings editor. These fields remain valid and are still
// read/written by migration/runtime code where appropriate; the TUI simply
// does not expose them as user-editable controls.
func isHiddenSettingsPath(dotPath string) bool {
	switch dotPath {
	case "version":
		// Envelope/migration metadata. install.sh owns bumps and cleanup
		// decisions; hand-editing it from the TUI is not useful.
		return true
	default:
		return false
	}
}

// buildWidget consults the registry for an override; falls back to default-
// by-type dispatch. parentPath is "" for root-level properties; otherwise
// the dot-path of the parent object. The returned widget is non-nil for
// every supported NodeKind; an unrecognized kind returns nil and is omitted
// from the rendered tree (the schema loader rejects unsupported kinds at
// load time, so this branch should be unreachable in practice).
func (m *SettingsModel) buildWidget(parentPath, fieldName string, schema *SchemaNode) FieldWidget {
	dotPath := joinDotPath(parentPath, fieldName)
	if isHiddenSettingsPath(dotPath) {
		return nil
	}

	if fn, ok := m.registry.Lookup(parentPath, fieldName); ok {
		w := fn(dotPath, schema)
		m.applyDisplayHints(w, fieldName, dotPath, schema)
		return w
	}

	current, present := m.lookupEffective(dotPath)
	allowUnset := !isRequired(parentPath, fieldName, m.schema) // top-level optional fields and overlay fields permit unset

	var widget FieldWidget
	switch schema.Kind {
	case KindBoolean:
		b, _ := current.(bool)
		widget = NewToggleRow(dotPath, fieldName, b, present, allowUnset)
	case KindEnum:
		s, _ := current.(string)
		widget = NewEnumSelector(dotPath, schema.Enum, schema.Enum, s, allowUnset)
	case KindString:
		s, _ := current.(string)
		if !present {
			switch dotPath {
			case "settlement.active_hours.timezone":
				s = "local"
				present = true
			}
		}
		minLen, _ := schema.MinLengthConstraint()
		widget = NewTextInput(dotPath, fieldName, s, schema.PatternCompiled, minLen, present, allowUnset)
	case KindInteger:
		display := numericString(current)
		min := minimumPtr(schema)
		max := maximumPtr(schema)
		widget = NewNumericInput(dotPath, fieldName, display, true, min, max, present, allowUnset)
	case KindNumber:
		display := numericString(current)
		min := minimumPtr(schema)
		max := maximumPtr(schema)
		widget = NewNumericInput(dotPath, fieldName, display, false, min, max, present, allowUnset)
	case KindArray:
		// Only string-arrays are in the verified-current taxonomy (D1).
		items := stringSliceFromAny(current)
		minItems, _ := schema.MinItemsConstraint()
		if dotPath == "settlement.active_hours.ranges" {
			ranges := activeHoursRangesFromAny(current)
			widget = NewActiveHoursRangesEditor(dotPath, fieldName, ranges, present)
			break
		}
		if schema.Items != nil && schema.Items.Kind == KindEnum && len(schema.Items.Enum) > 0 {
			allowed := append([]string(nil), schema.Items.Enum...)
			if dotPath == "settlement.harness_selection.eligible_frameworks" && len(items) == 0 {
				items = append([]string(nil), allowed...)
				present = true
			}
			widget = NewEnumListEditor(dotPath, fieldName, items, allowed, minItems, schema.UniqueItems, present, allowUnset)
		} else {
			var itemPattern *regexp.Regexp
			if schema.Items != nil {
				itemPattern = schema.Items.PatternCompiled
			}
			widget = NewListEditor(dotPath, fieldName, items, itemPattern, minItems, schema.UniqueItems, present, allowUnset)
		}
	case KindObjectClosed:
		var children []FieldWidget
		for _, childName := range schema.PropertyOrder {
			childSchema := schema.Properties[childName]
			child := m.buildWidget(dotPath, childName, childSchema)
			if child != nil {
				children = append(children, child)
			}
		}
		widget = NewClosedObjectSubPanel(dotPath, fieldName, children)
	case KindObjectOpen:
		// Open-keyset KV editor. Values are displayed as editable strings,
		// but parsed back through the value schema before commit so the
		// generic editor preserves shape as the schema grows: number maps
		// commit numbers, array maps commit []string, and object maps commit
		// validated JSON objects rather than map[string]string.
		valueSchema := schema.OpenValueSchema()
		kv := openMapDisplayFromAny(current, valueSchema)
		var keyPattern *regexp.Regexp // current taxonomy has no key-pattern; reserved for future
		widget = NewTypedOpenKeysetKVEditor(dotPath, fieldName, kv, keyPattern, openMapValueParser(valueSchema), present, allowUnset)
	}
	if widget == nil {
		return nil
	}
	m.applyDisplayHints(widget, fieldName, dotPath, schema)
	return widget
}

// applyDisplayHints attaches the per-field label and description to a freshly-
// constructed widget when the widget implements DisplayHinter. The description
// resolves in this order:
//
//  1. Host-supplied DescriptionsByDotPath (e.g., adapters/capabilities.json
//     descriptions for capability_overrides.<key>, adapters/roles.json
//     descriptions for roles.<role>) — the most specific source.
//  2. The schema node's own Description field (resolved from the schema
//     document, possibly inherited via $ref).
//
// Empty descriptions are passed through unchanged so widgets that don't render
// description text aren't penalized. The label is the field name as declared
// in the schema (used by EnumSelector for its multi-line render — other
// widgets ignore the label argument because their constructor already took
// one).
func (m *SettingsModel) applyDisplayHints(w FieldWidget, fieldName, dotPath string, schema *SchemaNode) {
	hinter, ok := w.(DisplayHinter)
	if !ok {
		return
	}
	desc := ""
	if v, present := m.descByPath[dotPath]; present {
		desc = v
	} else if schema != nil {
		desc = schema.Description
	}
	hinter.SetDisplayHints(fieldName, desc)
}

// joinDotPath combines a parent path and field name into a dot-separated
// path. parent="" → just fieldName.
func joinDotPath(parent, field string) string {
	if parent == "" {
		return field
	}
	return parent + "." + field
}

// isRequired reports whether the named field is in its parent's required[].
// For the root, "required" is the schema root's required list. Default-of-
// optional permits the unset gesture per D9; required fields suppress it
// because removing them produces an invalid document.
func isRequired(parentPath, fieldName string, schema *Schema) bool {
	if schema == nil || schema.Root == nil {
		return false
	}
	parent := schema.Root
	if parentPath != "" {
		// Walk down to the parent node by dot-path.
		segments := strings.Split(parentPath, ".")
		for _, seg := range segments {
			if parent == nil || parent.Kind != KindObjectClosed {
				return false
			}
			parent = parent.Properties[seg]
		}
	}
	if parent == nil {
		return false
	}
	for _, r := range parent.Required {
		if r == fieldName {
			return true
		}
	}
	return false
}

// lookupEffective resolves a dot-path against the cached effective document
// and returns (value, present). Mirrors resolveSettingsDotPath in
// tui/internal/config/settings.go but operates on the cached snapshot rather
// than re-reading from disk.
func (m *SettingsModel) lookupEffective(dotPath string) (any, bool) {
	if dotPath == "" || m.effective == nil {
		return nil, false
	}
	segments := strings.Split(dotPath, ".")
	var node any = m.effective
	for _, seg := range segments {
		mp, ok := node.(map[string]any)
		if !ok {
			return nil, false
		}
		v, present := mp[seg]
		if !present {
			return nil, false
		}
		node = v
	}
	return node, true
}

// numericString stringifies a JSON-decoded numeric value into the
// canonical-string form NumericInput expects. Empty when current is nil
// (absent overlay).
func numericString(current any) string {
	switch x := current.(type) {
	case nil:
		return ""
	case float64:
		// Trim trailing zeros for a tidy display ("0.5" not "0.500000").
		s := strings.TrimRight(strings.TrimRight(fmt.Sprintf("%f", x), "0"), ".")
		if s == "" {
			s = "0"
		}
		// If the original value is an integer (e.g. 5.0), drop the dot.
		if x == float64(int64(x)) {
			return fmt.Sprintf("%d", int64(x))
		}
		return s
	case int:
		return fmt.Sprintf("%d", x)
	case int64:
		return fmt.Sprintf("%d", x)
	case string:
		return x
	default:
		return fmt.Sprintf("%v", x)
	}
}

// minimumPtr / maximumPtr return *float64 for the schema's min/max constraint
// or nil when absent. NumericInput's constructor takes *float64 to encode
// "no bound declared".
func minimumPtr(schema *SchemaNode) *float64 {
	v, ok := schema.MinimumConstraint()
	if !ok {
		return nil
	}
	return &v
}

func maximumPtr(schema *SchemaNode) *float64 {
	v, ok := schema.MaximumConstraint()
	if !ok {
		return nil
	}
	return &v
}

// stringSliceFromAny coerces a JSON-decoded array of strings to []string.
// Non-array or non-string-element shapes return nil — the schema loader
// rejects mixed-type arrays at load time, so this is defensive only.
func stringSliceFromAny(v any) []string {
	arr, ok := v.([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(arr))
	for _, x := range arr {
		s, ok := x.(string)
		if !ok {
			return nil
		}
		out = append(out, s)
	}
	return out
}

func activeHoursRangesFromAny(v any) []ActiveHoursRange {
	var arr []any
	switch typed := v.(type) {
	case []any:
		arr = typed
	case []map[string]any:
		arr = make([]any, 0, len(typed))
		for _, row := range typed {
			arr = append(arr, row)
		}
	default:
		return nil
	}
	out := make([]ActiveHoursRange, 0, len(arr))
	for _, row := range arr {
		obj, ok := row.(map[string]any)
		if !ok {
			continue
		}
		start, _ := obj["start"].(string)
		end, _ := obj["end"].(string)
		days := stringSliceFromAny(obj["days"])
		if start == "" || end == "" || len(days) == 0 {
			continue
		}
		out = append(out, ActiveHoursRange{Days: days, Start: start, End: end})
	}
	return out
}

// openMapDisplayFromAny coerces a JSON-decoded open-keyset object into the
// string-form rows the KV editor displays. The reverse parse is supplied by
// openMapValueParser for the same value schema, so display strings are a UI
// convenience rather than the persisted shape.
func openMapDisplayFromAny(v any, valueSchema *SchemaNode) map[string]string {
	obj, ok := v.(map[string]any)
	if !ok {
		return map[string]string{}
	}
	out := make(map[string]string, len(obj))
	for k, val := range obj {
		out[k] = formatOpenMapValue(val, valueSchema)
	}
	return out
}

func formatOpenMapValue(v any, schema *SchemaNode) string {
	if schema == nil {
		return fmt.Sprintf("%v", v)
	}
	switch schema.Kind {
	case KindString, KindEnum:
		if s, ok := v.(string); ok {
			return s
		}
	case KindBoolean:
		if b, ok := v.(bool); ok {
			return strconv.FormatBool(b)
		}
	case KindInteger, KindNumber:
		return numericString(v)
	case KindArray:
		if xs := stringSliceFromAny(v); xs != nil {
			return strings.Join(xs, ",")
		}
	}
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprintf("%v", v)
	}
	return string(b)
}

func openMapValueParser(schema *SchemaNode) OpenMapValueParser {
	return func(_ string, raw string) (any, []string) {
		return parseOpenMapValue(raw, schema)
	}
}

func parseOpenMapValue(raw string, schema *SchemaNode) (any, []string) {
	if schema == nil {
		return raw, nil
	}
	switch schema.Kind {
	case KindString:
		if errs := validateStringValue(raw, schema); len(errs) > 0 {
			return nil, errs
		}
		return raw, nil
	case KindEnum:
		if !contains(schema.Enum, raw) {
			return nil, []string{fmt.Sprintf("%q is not in the allowed set", raw)}
		}
		return raw, nil
	case KindBoolean:
		switch strings.ToLower(strings.TrimSpace(raw)) {
		case "true", "t", "yes", "y", "on", "1":
			return true, nil
		case "false", "f", "no", "n", "off", "0":
			return false, nil
		default:
			return nil, []string{"must be a boolean (true/false)"}
		}
	case KindInteger:
		i, err := strconv.Atoi(strings.TrimSpace(raw))
		if err != nil {
			return nil, []string{fmt.Sprintf("must be an integer (%v)", err)}
		}
		if errs := validateNumberBounds(float64(i), schema); len(errs) > 0 {
			return nil, errs
		}
		return i, nil
	case KindNumber:
		f, err := strconv.ParseFloat(strings.TrimSpace(raw), 64)
		if err != nil {
			return nil, []string{fmt.Sprintf("must be a number (%v)", err)}
		}
		if errs := validateNumberBounds(f, schema); len(errs) > 0 {
			return nil, errs
		}
		return f, nil
	case KindArray:
		items, errs := parseStringArrayValue(raw, schema)
		if len(errs) > 0 {
			return nil, errs
		}
		return items, nil
	case KindObjectClosed:
		var obj map[string]any
		if err := json.Unmarshal([]byte(raw), &obj); err != nil {
			return nil, []string{fmt.Sprintf("must be a JSON object (%v)", err)}
		}
		if errs := validateObjectValue(obj, schema); len(errs) > 0 {
			return nil, errs
		}
		return obj, nil
	default:
		return nil, []string{fmt.Sprintf("open-map value shape %s is not supported by configurator", schema.Kind)}
	}
}

func validateStringValue(s string, schema *SchemaNode) []string {
	var errs []string
	if minLen, ok := schema.MinLengthConstraint(); ok && len(s) < minLen {
		errs = append(errs, fmt.Sprintf("must be at least %d characters", minLen))
	}
	if schema.PatternCompiled != nil && !schema.PatternCompiled.MatchString(s) {
		errs = append(errs, fmt.Sprintf("must match pattern %s", schema.PatternCompiled.String()))
	}
	return errs
}

func validateNumberBounds(f float64, schema *SchemaNode) []string {
	var errs []string
	if min, ok := schema.MinimumConstraint(); ok && f < min {
		errs = append(errs, fmt.Sprintf("must be at least %v", min))
	}
	if max, ok := schema.MaximumConstraint(); ok && f > max {
		errs = append(errs, fmt.Sprintf("must be at most %v", max))
	}
	return errs
}

func parseStringArrayValue(raw string, schema *SchemaNode) ([]string, []string) {
	var items []string
	trimmed := strings.TrimSpace(raw)
	if strings.HasPrefix(trimmed, "[") {
		if err := json.Unmarshal([]byte(trimmed), &items); err != nil {
			return nil, []string{fmt.Sprintf("must be a JSON string array or comma-separated list (%v)", err)}
		}
	} else if trimmed == "" {
		items = []string{}
	} else {
		parts := strings.Split(raw, ",")
		items = make([]string, 0, len(parts))
		for _, part := range parts {
			part = strings.TrimSpace(part)
			if part != "" {
				items = append(items, part)
			}
		}
	}
	var errs []string
	if minItems, ok := schema.MinItemsConstraint(); ok && len(items) < minItems {
		errs = append(errs, fmt.Sprintf("must have at least %d item(s)", minItems))
	}
	if schema.UniqueItems {
		seen := map[string]struct{}{}
		for _, item := range items {
			if _, dup := seen[item]; dup {
				errs = append(errs, fmt.Sprintf("duplicate item: %q", item))
				break
			}
			seen[item] = struct{}{}
		}
	}
	if schema.Items != nil {
		for i, item := range items {
			if itemErrs := validateOpenMapTypedValue(item, schema.Items); len(itemErrs) > 0 {
				for _, err := range itemErrs {
					errs = append(errs, fmt.Sprintf("item %d: %s", i, err))
				}
			}
		}
	}
	return items, errs
}

func validateObjectValue(obj map[string]any, schema *SchemaNode) []string {
	var errs []string
	for _, req := range schema.Required {
		if _, ok := obj[req]; !ok {
			errs = append(errs, fmt.Sprintf("missing required property %q", req))
		}
	}
	for k, v := range obj {
		child := schema.Properties[k]
		if child == nil {
			errs = append(errs, fmt.Sprintf("unknown property %q", k))
			continue
		}
		if childErrs := validateOpenMapTypedValue(v, child); len(childErrs) > 0 {
			for _, err := range childErrs {
				errs = append(errs, fmt.Sprintf("%s: %s", k, err))
			}
		}
	}
	return errs
}

func validateOpenMapTypedValue(v any, schema *SchemaNode) []string {
	if schema == nil {
		return nil
	}
	switch schema.Kind {
	case KindString:
		s, ok := v.(string)
		if !ok {
			return []string{fmt.Sprintf("expected string, got %T", v)}
		}
		return validateStringValue(s, schema)
	case KindEnum:
		s, ok := v.(string)
		if !ok || !contains(schema.Enum, s) {
			return []string{fmt.Sprintf("%v is not in the allowed set", v)}
		}
	case KindBoolean:
		if _, ok := v.(bool); !ok {
			return []string{fmt.Sprintf("expected boolean, got %T", v)}
		}
	case KindInteger:
		f, ok := numberAsFloat(v)
		if !ok || f != float64(int64(f)) {
			return []string{fmt.Sprintf("expected integer, got %T", v)}
		}
		return validateNumberBounds(f, schema)
	case KindNumber:
		f, ok := numberAsFloat(v)
		if !ok {
			return []string{fmt.Sprintf("expected number, got %T", v)}
		}
		return validateNumberBounds(f, schema)
	case KindArray:
		itemsAny, ok := v.([]any)
		if !ok {
			items, ok := v.([]string)
			if !ok {
				return []string{fmt.Sprintf("expected array, got %T", v)}
			}
			itemsAny = make([]any, len(items))
			for i, item := range items {
				itemsAny[i] = item
			}
		}
		var errs []string
		if minItems, ok := schema.MinItemsConstraint(); ok && len(itemsAny) < minItems {
			errs = append(errs, fmt.Sprintf("must have at least %d item(s)", minItems))
		}
		seen := map[string]struct{}{}
		for i, item := range itemsAny {
			if schema.Items != nil {
				for _, err := range validateOpenMapTypedValue(item, schema.Items) {
					errs = append(errs, fmt.Sprintf("item %d: %s", i, err))
				}
			}
			if schema.UniqueItems {
				key := fmt.Sprintf("%v", item)
				if _, dup := seen[key]; dup {
					errs = append(errs, fmt.Sprintf("duplicate item: %q", key))
					break
				}
				seen[key] = struct{}{}
			}
		}
		return errs
	case KindObjectClosed:
		obj, ok := v.(map[string]any)
		if !ok {
			return []string{fmt.Sprintf("expected object, got %T", v)}
		}
		return validateObjectValue(obj, schema)
	}
	return nil
}

func numberAsFloat(v any) (float64, bool) {
	switch x := v.(type) {
	case float64:
		return x, true
	case float32:
		return float64(x), true
	case int:
		return float64(x), true
	case int64:
		return float64(x), true
	case json.Number:
		f, err := x.Float64()
		return f, err == nil
	default:
		return 0, false
	}
}

// ----------------------------------------------------------------------------
// Bubble Tea Init/Update/View.
// ----------------------------------------------------------------------------

// Init returns nil — SettingsModel has no async startup work.
func (m *SettingsModel) Init() tea.Cmd { return nil }

// Closed reports whether the user has dismissed the modal (top-level Esc
// with no active draft). The host checks Closed() each tick and unwraps the
// modal when true.
func (m *SettingsModel) Closed() bool { return m.closed }

// FocusConsumesRunes reports whether the currently-focused widget interprets
// literal letter keystrokes ('q', 'j', 'k', etc.) as widget-internal input.
// Hosts use this to decide whether global shortcuts like 'q' (quit) should
// be intercepted before reaching the panel: when a text-entry widget is
// focused the host must defer so the user can type the letter literally.
func (m *SettingsModel) FocusConsumesRunes() bool { return m.focusConsumesNavRunes() }

// Update routes keystrokes to the focused widget and translates the
// resulting FieldIntent into write-routing calls.
//
// harnessToggleResultMsg is the tea.Msg type the harness-toggle command
// emits when the shell-out resolves; see ToggleHarness. The framework
// field identifies which harness was toggled so the result handler can
// release the right per-harness lock and refresh the right widget slot.
type harnessToggleResultMsg struct {
	framework string
	enabled   bool
	stdout    string
	stderr    string
	err       error
}

func (m *SettingsModel) Update(msg tea.Msg) (*SettingsModel, tea.Cmd) {
	if m.schemaErr != nil {
		// In schema-error mode, only Esc is honored.
		if key, ok := msg.(tea.KeyMsg); ok && key.String() == "esc" {
			m.closed = true
		}
		return m, nil
	}

	// Harness-toggle async result.
	if r, ok := msg.(harnessToggleResultMsg); ok {
		if m.harnessToggleLocked != nil {
			delete(m.harnessToggleLocked, r.framework)
		}
		if r.err != nil {
			m.statusMsg = fmt.Sprintf("harness %s toggle failed: %v", r.framework, r.err)
			m.statusIsError = true
		} else {
			noticeCount := countNotices(r.stderr)
			if noticeCount > 0 {
				m.statusMsg = fmt.Sprintf("harness %s %s (%d notices)", r.framework, boolToOnOff(r.enabled), noticeCount)
			} else {
				m.statusMsg = fmt.Sprintf("harness %s %s", r.framework, boolToOnOff(r.enabled))
			}
			m.statusIsError = false
		}
		// Full reload after external shell-out (sharp-edges Q3 → option A):
		// other paths may have been touched and we cannot safely scope.
		if eff, err := m.store.LoadAll(); err == nil {
			m.effective = eff
			m.rebuildWidgets()
			m.reconcileHarnessPanels()
		} else if r.err == nil {
			m.setHarnessPanelEnabled(r.framework, r.enabled)
		} else {
			m.setHarnessPanelEnabled(r.framework, !r.enabled)
		}
		return m, nil
	}

	// Mouse wheel: route to viewport for scrolling. The host program enables
	// mouse cell motion at startup so MouseWheelUp/Down arrive as MouseMsg.
	if _, ok := msg.(tea.MouseMsg); ok {
		if m.viewportInit {
			vp, cmd := m.viewport.Update(msg)
			m.viewport = vp
			return m, cmd
		}
		return m, nil
	}

	if key, ok := msg.(tea.KeyMsg); ok {
		switch key.String() {
		case "esc":
			// Esc semantics: forward to the focused widget first; if the
			// widget consumes the keystroke by emitting an intent (e.g.,
			// IntentDiscard reverting an in-progress draft), keep the
			// modal open. If the widget returns silently (no draft to
			// revert, no edit-mode to cancel), CLOSE the modal — that's
			// the user expectation matching every other modal in the TUI.
			//
			// The previous behavior fell through to the generic widget
			// dispatch, which silently swallowed Esc whenever the focused
			// widget didn't have an `esc` case (EnumSelector, ToggleRow,
			// etc.) and never closed.
			focused := m.focusedWidget()
			if compactFocused := m.compactFocusedControl(); compactFocused != nil {
				focused = compactFocused
			}
			if focused == nil {
				m.closed = true
				return m, nil
			}
			updated, cmd, intent := focused.Update(msg)
			m.replaceFocusedControl(updated)
			if intent != nil {
				if extra := m.routeIntent(intent); extra != nil {
					cmd = teaBatch(cmd, extra)
				}
				return m, cmd
			}
			if m.limitDotPath != "" {
				m.closed = false
				return m, cmd
			}
			m.closed = true
			return m, cmd
		case "tab":
			m.stepRowNavigation(+1)
			return m, nil
		case "shift+tab":
			m.stepRowNavigation(-1)
			return m, nil
		// Scroll keys: route to the viewport so users can navigate long
		// widget trees with PgUp/PgDn even mid-edit.
		case "pgup", "pgdown", "home", "end", "ctrl+u", "ctrl+d":
			if m.viewportInit {
				vp, cmd := m.viewport.Update(msg)
				m.viewport = vp
				return m, cmd
			}
		// j/k hierarchical navigation. At the outer boundary these move
		// between top-level sections. Once Enter has opened a container,
		// the focused container's NavStep moves within that level. When a
		// leaf editor is in edit mode, j/k are forwarded as literal/editor
		// input instead.
		case "j", "k":
			if !m.focusConsumesNavRunes() {
				delta := +1
				if key.String() == "k" {
					delta = -1
				}
				m.stepRowNavigation(delta)
				return m, nil
			}
		}
	}

	// Initial focus: first navigation keystroke installs focus on first item.
	if m.focusIdx < 0 && len(m.allWidgetSlots()) > 0 {
		m.focusIdx = 0
		_ = m.allWidgetSlots()[0].Focus()
		m.enterLimitedCompactContainer()
		m.ensureFocusedVisible()
	}

	// Forward to the focused widget.
	w := m.focusedWidget()
	if compactFocused := m.compactFocusedControl(); compactFocused != nil {
		w = compactFocused
	}
	if w == nil {
		return m, nil
	}
	updated, cmd, intent := w.Update(msg)
	m.replaceFocusedControl(updated)
	if intent != nil {
		if extra := m.routeIntent(intent); extra != nil {
			cmd = teaBatch(cmd, extra)
		}
	}
	return m, cmd
}

// teaBatch combines two tea.Cmds without nil-checks at the call site.
func teaBatch(a, b tea.Cmd) tea.Cmd {
	if a == nil {
		return b
	}
	if b == nil {
		return a
	}
	return tea.Batch(a, b)
}

// allWidgetSlots returns the combined topSections + schema-driven widgets
// list in render order. Used by focus dispatch.
func (m *SettingsModel) allWidgetSlots() []FieldWidget {
	if m.limitDotPath != "" {
		if w := m.limitedWidget(); w != nil {
			return []FieldWidget{w}
		}
		return nil
	}
	out := make([]FieldWidget, 0, len(m.topSections)+len(m.widgets))
	for _, ts := range m.topSections {
		out = append(out, ts.widget)
	}
	out = append(out, m.widgets...)
	return out
}

func (m *SettingsModel) limitedWidget() FieldWidget {
	for _, ts := range m.topSections {
		if ts.widget.DotPath() == m.limitDotPath {
			return ts.widget
		}
	}
	for _, w := range m.widgets {
		if w.DotPath() == m.limitDotPath {
			return w
		}
	}
	return nil
}

func (m *SettingsModel) focusedWidget() FieldWidget {
	all := m.allWidgetSlots()
	if m.focusIdx < 0 || m.focusIdx >= len(all) {
		return nil
	}
	return all[m.focusIdx]
}

// focusedDotPath returns the dot-path of the currently-focused widget, or ""
// when nothing is focused.
func (m *SettingsModel) focusedDotPath() string {
	w := m.focusedWidget()
	if w == nil {
		return ""
	}
	return w.DotPath()
}

// focusByDotPath moves focus to the widget with the matching dot-path. No-op
// when no widget matches (e.g., the path was excluded by a schema edit).
func (m *SettingsModel) focusByDotPath(dotPath string) {
	if m.limitDotPath != "" {
		if dotPath == m.limitDotPath && m.limitedWidget() != nil {
			m.focusIdx = 0
			_ = m.limitedWidget().Focus()
			m.enterLimitedCompactContainer()
		} else {
			m.focusIdx = -1
		}
		return
	}
	all := m.allWidgetSlots()
	for i, w := range all {
		if w.DotPath() == dotPath {
			m.focusIdx = i
			_ = w.Focus()
			return
		}
	}
	m.focusIdx = -1
}

// FocusDotPath moves the initial modal focus to a rendered settings path.
// Hosts use this for context-sensitive entry points such as opening Settings
// from the settlement panel directly at the settlement section.
func (m *SettingsModel) FocusDotPath(dotPath string) {
	m.focusByDotPath(dotPath)
}

// LimitToDotPath renders and updates only the matching top-level widget while
// keeping SettingsModel's normal validation and persistence path. Esc cancels
// active edits or backs out nested containers, but it does not close the host
// view in this embedded mode.
func (m *SettingsModel) LimitToDotPath(dotPath string) {
	m.limitDotPath = dotPath
	m.closed = false
	m.focusByDotPath(dotPath)
	m.enterLimitedCompactContainer()
}

// SetCompactEmbed trims section chrome for an embedded limited settings
// editor. It is intended for surfaces that already provide their own panel
// title and split chrome, such as the settlement panel.
func (m *SettingsModel) SetCompactEmbed(compact bool) {
	m.compactEmbed = compact
	m.enterLimitedCompactContainer()
}

func (m *SettingsModel) enterLimitedCompactContainer() {
	if !m.compactEmbed || m.limitDotPath == "" {
		return
	}
	panel, ok := m.limitedWidget().(*ClosedObjectSubPanel)
	if !ok || len(panel.children) == 0 {
		return
	}
	panel.focused = true
	panel.entered = true
	controls := m.compactNavigationControls(panel)
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
func (m *SettingsModel) replaceFocused(w FieldWidget) {
	if m.limitDotPath != "" {
		for i, ts := range m.topSections {
			if ts.widget.DotPath() == m.limitDotPath {
				m.topSections[i].widget = w
				return
			}
		}
		for i, widget := range m.widgets {
			if widget.DotPath() == m.limitDotPath {
				m.widgets[i] = w
				return
			}
		}
		return
	}
	if m.focusIdx < 0 {
		return
	}
	if m.focusIdx < len(m.topSections) {
		m.topSections[m.focusIdx].widget = w
		return
	}
	idx := m.focusIdx - len(m.topSections)
	if idx < len(m.widgets) {
		m.widgets[idx] = w
	}
}

func (m *SettingsModel) replaceFocusedControl(w FieldWidget) {
	if m.compactEmbed && m.limitDotPath != "" {
		if m.replaceCompactControl(w) {
			return
		}
	}
	m.replaceFocused(w)
}

func (m *SettingsModel) compactFocusedControl() FieldWidget {
	if !m.compactEmbed || m.limitDotPath == "" {
		return nil
	}
	panel, ok := m.limitedWidget().(*ClosedObjectSubPanel)
	if !ok {
		return nil
	}
	for _, control := range m.compactNavigationControls(panel) {
		if control.Focused() {
			return control
		}
	}
	return nil
}

func (m *SettingsModel) replaceCompactControl(updated FieldWidget) bool {
	panel, ok := m.limitedWidget().(*ClosedObjectSubPanel)
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
func (m *SettingsModel) stepRowNavigation(delta int) {
	if m.stepLimitedCompactNavigation(delta) {
		m.ensureFocusedVisible()
		return
	}
	if stepper, ok := m.focusedWidget().(NavStepper); ok {
		if moved, intent := stepper.NavStep(delta); moved {
			if intent != nil {
				m.routeIntent(intent)
			}
			m.ensureFocusedVisible()
			return
		}
	}
	if m.limitDotPath != "" {
		m.ensureFocusedVisible()
		return
	}
	if intent := m.focusOffset(delta); intent != nil {
		m.routeIntent(intent)
	}
	m.ensureFocusedVisible()
}

func (m *SettingsModel) stepLimitedCompactNavigation(delta int) bool {
	if !m.compactEmbed || m.limitDotPath == "" {
		return false
	}
	panel, ok := m.limitedWidget().(*ClosedObjectSubPanel)
	if !ok {
		return false
	}
	controls := m.compactNavigationControls(panel)
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
		m.routeIntent(intent)
	}
	_ = controls[next].Focus()
	panel.focused = true
	panel.entered = true
	return true
}

func (m *SettingsModel) compactNavigationControls(panel *ClosedObjectSubPanel) []FieldWidget {
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
func (m *SettingsModel) focusOffset(delta int) *FieldIntent {
	if m.limitDotPath != "" {
		return nil
	}
	all := m.allWidgetSlots()
	if len(all) == 0 {
		return nil
	}
	var intent *FieldIntent
	if m.focusIdx >= 0 && m.focusIdx < len(all) {
		intent = all[m.focusIdx].Blur()
	}
	next := m.focusIdx + delta
	if next < 0 {
		next = len(all) - 1
	}
	if next >= len(all) {
		next = 0
	}
	m.focusIdx = next
	_ = all[next].Focus()
	return intent
}

// routeIntent translates a FieldIntent into write-routing calls per D5/D8/D9.
// Returns a tea.Cmd when the routing requires async work (only the agent
// toggle today).
func (m *SettingsModel) routeIntent(intent *FieldIntent) tea.Cmd {
	if intent == nil {
		return nil
	}
	switch intent.Status {
	case IntentCommit:
		return m.routeCommit(intent)
	case IntentReject:
		m.statusMsg = strings.Join(intent.Errors, "; ")
		m.statusIsError = true
		return nil
	case IntentUnset:
		if err := m.store.Delete(intent.DotPath); err != nil {
			m.statusMsg = fmt.Sprintf("unset %s: %v", intent.DotPath, err)
			m.statusIsError = true
			return nil
		}
		// Refresh effective for the affected path so subsequent renders
		// see absence.
		m.invalidateEffective(intent.DotPath)
		m.statusMsg = ""
		m.statusIsError = false
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

// routeCommit handles the IntentCommit branch of routeIntent. Split out for
// readability — the tui_launch_framework / per-harness-enabled special cases
// are dense.
func (m *SettingsModel) routeCommit(intent *FieldIntent) tea.Cmd {
	// harnesses.<fw>.enabled — must route through the harness-toggle script,
	// not a plain Patch. The script also installs/removes symlinks and
	// rewrites the instruction file; a plain Patch would drift those out
	// of sync. The per-harness toggle widget calls ToggleHarness directly
	// and emits no FieldIntent, so a stray IntentCommit on this path is a
	// programming error.
	if fw, ok := harnessEnabledFramework(intent.DotPath); ok {
		m.statusMsg = fmt.Sprintf("internal error: harnesses.%s.enabled must route through the harness-toggle script", fw)
		m.statusIsError = true
		return nil
	}

	switch intent.DotPath {
	case "tui_launch_framework":
		chosen, ok := intent.Value.(string)
		if !ok {
			m.statusMsg = fmt.Sprintf("tui_launch_framework: expected string, got %T", intent.Value)
			m.statusIsError = true
			return nil
		}
		if !contains(m.frameworks, chosen) {
			m.statusMsg = fmt.Sprintf("tui_launch_framework: %q is not a registered framework", chosen)
			m.statusIsError = true
			return nil
		}
		if err := m.store.Patch("tui_launch_framework", chosen); err != nil {
			m.statusMsg = fmt.Sprintf("write tui_launch_framework: %v", err)
			m.statusIsError = true
			return nil
		}
		m.setEffective(intent.DotPath, chosen)
		m.statusMsg = ""
		m.statusIsError = false
		return nil
	}

	// Generic shape field. Closed-set re-validation per D6 when the field
	// resolves to an enum schema node.
	if node := m.schemaNodeAt(intent.DotPath); node != nil && node.Kind == KindEnum {
		s, ok := intent.Value.(string)
		if !ok || !contains(node.Enum, s) {
			m.statusMsg = fmt.Sprintf("%s: %v is not in the allowed set", intent.DotPath, intent.Value)
			m.statusIsError = true
			return nil
		}
	}
	if err := m.store.Patch(intent.DotPath, intent.Value); err != nil {
		m.statusMsg = fmt.Sprintf("write %s: %v", intent.DotPath, err)
		m.statusIsError = true
		return nil
	}
	m.setEffective(intent.DotPath, intent.Value)
	m.statusMsg = ""
	m.statusIsError = false
	return nil
}

// ToggleHarness runs the harness-toggle enable/disable shell-out for the
// named framework and returns a tea.Cmd that resolves with the result.
// Called by the per-harness toggle widget embedded inside HarnessBlockPanel.
//
// Optimistic-UI plan: callers should flip the visible state immediately
// (the toggle widget's local bool), then surface this command to Bubble Tea.
// The harnessToggleResultMsg handler reconciles the cached effective
// document and re-walks the widget tree.
//
// Lock contention is per-framework: a toggle in flight for claude-code does
// not block a parallel toggle on codex. This matches the script semantics
// (each enable/disable is scoped to one framework via the positional arg).
func (m *SettingsModel) ToggleHarness(framework string, enabled bool) tea.Cmd {
	if framework == "" {
		return func() tea.Msg {
			return harnessToggleResultMsg{
				enabled: enabled,
				err:     fmt.Errorf("ToggleHarness: framework arg is required"),
			}
		}
	}
	if m.harnessToggleLocked == nil {
		m.harnessToggleLocked = map[string]bool{}
	}
	if m.harnessToggleLocked[framework] {
		// Suppress double-press while a toggle is in flight for this
		// specific framework.
		return nil
	}
	script := m.disableScript
	if enabled {
		script = m.enableScript
	}
	if script == "" {
		return func() tea.Msg {
			return harnessToggleResultMsg{
				framework: framework,
				enabled:   enabled,
				err:       fmt.Errorf("harness-toggle script path not configured"),
			}
		}
	}
	m.harnessToggleLocked[framework] = true
	runner := m.runner
	return func() tea.Msg {
		stdout, stderr, err := runner.Run(script, framework)
		return harnessToggleResultMsg{
			framework: framework,
			enabled:   enabled,
			stdout:    stdout,
			stderr:    stderr,
			err:       err,
		}
	}
}

// harnessEnabledFramework reports whether dotPath is of the form
// `harnesses.<fw>.enabled` and returns the extracted framework id when so.
// Used by routeCommit to reject plain Patches on the per-harness enabled
// path — those must go through ToggleHarness.
func harnessEnabledFramework(dotPath string) (string, bool) {
	const prefix = "harnesses."
	const suffix = ".enabled"
	if !strings.HasPrefix(dotPath, prefix) || !strings.HasSuffix(dotPath, suffix) {
		return "", false
	}
	mid := dotPath[len(prefix) : len(dotPath)-len(suffix)]
	// Reject nested paths like `harnesses.x.y.enabled` — only the direct
	// child counts.
	if mid == "" || strings.Contains(mid, ".") {
		return "", false
	}
	return mid, true
}

// schemaNodeAt resolves a dot-path against the parsed schema and returns
// the matching SchemaNode, or nil when the path doesn't correspond to a
// declared property. Used for inline closed-set re-validation per D6.
func (m *SettingsModel) schemaNodeAt(dotPath string) *SchemaNode {
	if m.schema == nil || m.schema.Root == nil || dotPath == "" {
		return nil
	}
	node := m.schema.Root
	for _, seg := range strings.Split(dotPath, ".") {
		if node == nil {
			return nil
		}
		switch node.Kind {
		case KindObjectClosed:
			node = node.Properties[seg]
		case KindObjectOpen:
			node = node.AdditionalProperties
		default:
			return nil
		}
	}
	return node
}

// setEffective updates the cached effective value at dot-path. Mirrors the
// in-place insert-or-update semantics of setSettingsDotPath.
func (m *SettingsModel) setEffective(dotPath string, value any) {
	if m.effective == nil {
		m.effective = map[string]any{}
	}
	segments := strings.Split(dotPath, ".")
	node := m.effective
	for i, seg := range segments[:len(segments)-1] {
		next, exists := node[seg]
		if !exists {
			child := map[string]any{}
			node[seg] = child
			node = child
			continue
		}
		child, ok := next.(map[string]any)
		if !ok {
			// Shouldn't happen — Patch would have errored. Defensive: replace.
			child = map[string]any{}
			node[seg] = child
		}
		node = child
		_ = i
	}
	node[segments[len(segments)-1]] = value
}

// invalidateEffective removes the cached effective value at dot-path. Mirrors
// SettingsDelete's semantics (no parent pruning).
func (m *SettingsModel) invalidateEffective(dotPath string) {
	if m.effective == nil {
		return
	}
	segments := strings.Split(dotPath, ".")
	node := m.effective
	for _, seg := range segments[:len(segments)-1] {
		next, ok := node[seg].(map[string]any)
		if !ok {
			return
		}
		node = next
	}
	delete(node, segments[len(segments)-1])
}

// reconcileHarnessPanels refreshes already-registered HarnessBlockPanel
// top sections from the reloaded effective document. The schema-driven
// widgets are rebuilt after a harness-toggle shell-out, but top sections
// are registered by the host and intentionally live outside that walker;
// this pass keeps the visible per-harness checkboxes from drifting after
// success, failure, or rapid keypress suppression.
func (m *SettingsModel) reconcileHarnessPanels() {
	for _, ts := range m.topSections {
		panel, ok := ts.widget.(*HarnessBlockPanel)
		if !ok {
			continue
		}
		panel.SetEnabled(m.harnessEnabledFromEffective(panel.Framework()))
	}
}

func (m *SettingsModel) setHarnessPanelEnabled(framework string, enabled bool) {
	for _, ts := range m.topSections {
		panel, ok := ts.widget.(*HarnessBlockPanel)
		if !ok || panel.Framework() != framework {
			continue
		}
		panel.SetEnabled(enabled)
		return
	}
}

func (m *SettingsModel) harnessEnabledFromEffective(framework string) bool {
	v, present := m.lookupEffective("harnesses." + framework + ".enabled")
	if !present {
		return true
	}
	b, ok := v.(bool)
	if !ok {
		return true
	}
	return b
}

// NavRuneConsumer is implemented by container widgets that need to delegate
// the j/k-vs-focus-step decision to a currently-active inner widget rather
// than answering for themselves. Container widgets (HarnessBlockPanel,
// ClosedObjectSubPanel) implement this so j/k typed into a child that is
// actively editing reaches the child rather than jumping focus to the next
// slot.
//
// Leaf widgets that toggle between an editing mode and a navigating mode
// (ListEditor, OpenKeysetKVEditor) also implement this — they consume runes
// only while a draft is being typed; in nav mode they let j/k pass through
// for settings-level navigation.
type NavRuneConsumer interface {
	ConsumesNavRunes() bool
}

// NavStepper is implemented by container widgets that own multiple
// navigable rows. NavStep advances the container's internal cursor by
// `delta` (+1 forward, -1 backward) and returns:
//
//   - moved=true when the cursor moved one row internally, with `intent`
//     carrying any IntentDiscard the just-blurred child wants to surface
//     (per D10's tab/focus = discard rule). The model routes the intent
//     and stops — focusIdx (the top-level slot) does NOT change, so the
//     containing section frame keeps its bright rail.
//   - moved=false when the cursor is at the boundary (first row on -1,
//     last row on +1). The model then advances focus to the next/prev
//     top-level slot via focusOffset.
//
// HarnessBlockPanel and ClosedObjectSubPanel both implement NavStepper so
// opened containers can traverse their current child level while unopened
// containers remain a single top-level stop.
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
// (NOT within the rendered slot — the model adds the section-frame offset).
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

// focusConsumesNavRunes reports whether the focused widget is currently
// interpreting j/k as widget-internal input (typing or editor navigation).
// When true, j/k must NOT be intercepted for settings navigation — the
// keystrokes belong to the
// widget. The taxonomy:
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
func (m *SettingsModel) focusConsumesNavRunes() bool {
	w := m.focusedWidget()
	if compactFocused := m.compactFocusedControl(); compactFocused != nil {
		w = compactFocused
	}
	if w == nil {
		return false
	}
	if c, ok := w.(NavRuneConsumer); ok {
		return c.ConsumesNavRunes()
	}
	switch w.(type) {
	case *TextInput, *NumericInput:
		return false
	}
	return false
}

// ensureFocusedVisible nudges the viewport so the currently-focused widget
// is within the visible window. No-op when the viewport hasn't been sized,
// when nothing is focused, or when focus is already in view.
func (m *SettingsModel) ensureFocusedVisible() {
	if !m.viewportInit || m.viewport.Height <= 0 {
		return
	}
	top, bottom := m.computeFocusedYRange()
	if top < 0 {
		return
	}
	yo := m.viewport.YOffset
	h := m.viewport.Height
	if top < yo {
		m.viewport.SetYOffset(top)
	} else if bottom >= yo+h {
		m.viewport.SetYOffset(bottom - h + 1)
	}
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
	if m.focusIdx < 0 {
		return -1, -1
	}
	slots := m.renderedSlots()
	if m.focusIdx >= len(slots) {
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
		if i == m.focusIdx {
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
			if focused := m.focusedWidget(); focused != nil && !m.compactEmbed {
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
// the implicit trailing line. Used by computeFocusedYRange and renderedSlots.
func lineCount(s string) int {
	if s == "" {
		return 0
	}
	return strings.Count(s, "\n") + 1
}

// View renders the body of the configurator modal — chrome (border, title,
// status bar) is supplied by the host (D2). Per D3, all styles are cached
// fields on m.styles; View() never allocates a lipgloss.Style.
//
// When SetSize has installed a viewport, the body is rendered through it so
// long widget trees scroll instead of clipping. When the host hasn't sized
// the model yet (viewportInit=false), View falls back to the raw content
// string — this preserves test behavior (most tests inspect the body string
// directly) and host shells that don't issue SetSize still see something.
func (m *SettingsModel) View() string {
	if m.schemaErr != nil {
		// D1 verification gate: render the error inline rather than silently
		// rendering a partial widget.
		var b strings.Builder
		b.WriteString(m.styles.sevBlocking.Render("settings schema error"))
		b.WriteByte('\n')
		b.WriteString(m.styles.dim.Render(m.schemaErr.Error()))
		b.WriteByte('\n')
		return b.String()
	}

	content := m.renderBodyContent()

	if m.limitDotPath != "" && m.compactEmbed {
		return content
	}
	if !m.viewportInit || m.viewport.Height <= 0 {
		return content
	}
	m.viewport.SetContent(content)
	return m.viewport.View()
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
			b.WriteString(m.styles.sevBlocking.Render(m.statusMsg))
		} else {
			b.WriteString(m.styles.dim.Render(m.statusMsg))
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
// which render bare. Framing a one-liner adds chrome without hierarchy
// benefit.
func (m *SettingsModel) renderedSlots() []string {
	if m.limitDotPath != "" {
		w := m.limitedWidget()
		if w == nil {
			return nil
		}
		if m.compactEmbed {
			return []string{m.compactWidgetView(w)}
		}
		for _, ts := range m.topSections {
			if ts.widget.DotPath() == m.limitDotPath {
				return []string{m.renderSection(ts.name, ts.widget.View(), m.focusIdx == 0)}
			}
		}
		title, body, framed := schemaSectionParts(w)
		if framed {
			return []string{m.renderSection(title, body, m.focusIdx == 0)}
		}
		return []string{body}
	}

	out := make([]string, 0, len(m.topSections)+len(m.widgets))
	cursor := 0

	for _, ts := range m.topSections {
		focused := m.focusIdx == cursor
		body := ts.widget.View()
		out = append(out, m.renderSection(ts.name, body, focused))
		cursor++
	}

	for _, w := range m.widgets {
		focused := m.focusIdx == cursor
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

func (m *SettingsModel) focusedWidgetBodyOffset() int {
	if m.limitDotPath != "" && m.compactEmbed {
		return 0
	}
	return 1
}

func (m *SettingsModel) compactWidgetView(w FieldWidget) string {
	switch typed := w.(type) {
	case *ClosedObjectSubPanel:
		return m.compactClosedObjectView(typed, typed.dotPath == m.limitDotPath)
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

func (m *SettingsModel) compactClosedObjectView(p *ClosedObjectSubPanel, topLevel bool) string {
	if topLevel {
		return m.compactTopLevelObjectView(p)
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
		childView := m.compactWidgetView(child)
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

func (m *SettingsModel) compactTopLevelObjectView(p *ClosedObjectSubPanel) string {
	var lines []string
	var deferred []string
	var cells []string
	flushCells := func() {
		if len(cells) == 0 {
			return
		}
		lines = append(lines, "general: "+strings.Join(compactTrimCells(cells), "  |  "))
		cells = nil
	}

	for _, child := range p.children {
		if cell, ok := m.compactLeafCell(child); ok {
			cells = append(cells, cell)
			continue
		}
		flushCells()
		if panel, ok := child.(*ClosedObjectSubPanel); ok {
			panelLine, panelDeferred := m.compactPanelSummaryWithDeferredWindows(panel)
			if panelLine != "" {
				lines = append(lines, strings.Split(panelLine, "\n")...)
			}
			deferred = append(deferred, panelDeferred...)
			continue
		}
		childView := m.compactWidgetView(child)
		if childView != "" {
			lines = append(lines, strings.Split(childView, "\n")...)
		}
	}
	flushCells()
	lines = append(lines, deferred...)

	return strings.TrimRight(strings.Join(lines, "\n"), "\n")
}

func (m *SettingsModel) compactPanelSummary(p *ClosedObjectSubPanel) string {
	line, deferred := m.compactPanelSummaryWithDeferredWindows(p)
	if len(deferred) > 0 {
		if line != "" {
			return strings.TrimRight(line+"\n"+strings.Join(deferred, "\n"), "\n")
		}
		return strings.TrimRight(strings.Join(deferred, "\n"), "\n")
	}
	return line
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
		childView := m.compactWidgetView(child)
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
		maxRows := compactActiveHoursEditWindowRows(m.viewport.Height)
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
// Per D3, every style is pulled from the cached themeStyles bag — no
// lipgloss.Style is allocated here. Per the codex consult, this idiom replaces
// the old activeTab pill on top-section labels (which read like tab navigation
// rather than a section header).
func (m *SettingsModel) renderSection(title, body string, focused bool) string {
	rail := m.styles.sectionRail
	if focused {
		rail = m.styles.sectionRailActive
	}

	width := m.wrapWidth
	if width <= 0 {
		width = 60
	}

	// Header: ╭─ title ────...
	var header strings.Builder
	header.WriteString(rail.Render("╭─ "))
	header.WriteString(m.styles.sectionTitle.Render(title))
	header.WriteByte(' ')
	// Fill the remainder with ─ characters. "╭─ " (3) + title runes + " " (1)
	// already consumed; clamp to ≥1 to avoid negative repeat counts on very
	// narrow widths.
	used := 3 + runeCount(title) + 1
	fillN := width - used
	if fillN < 1 {
		fillN = 1
	}
	header.WriteString(m.styles.sectionRule.Render(strings.Repeat("─", fillN)))

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
// into widgets.go's runeLen) so model.go stays decoupled from widget-internal
// helpers — the cost is one ~5-line duplicate, the benefit is that section
// framing has no cross-file dependency on widget rendering primitives.
func runeCount(s string) int {
	n := 0
	for range s {
		n++
	}
	return n
}

// ----------------------------------------------------------------------------
// Helpers.
// ----------------------------------------------------------------------------

func contains(set []string, v string) bool {
	for _, s := range set {
		if s == v {
			return true
		}
	}
	return false
}

// countNotices counts non-empty stderr lines from the harness-toggle
// script. The script emits one notice line per degraded framework
// (assemble-instructions-sh-exits-0-not-non-zero-when convention).
func countNotices(stderr string) int {
	if stderr == "" {
		return 0
	}
	n := 0
	for _, line := range strings.Split(strings.TrimRight(stderr, "\n"), "\n") {
		if strings.TrimSpace(line) != "" {
			n++
		}
	}
	return n
}

func boolToOnOff(b bool) string {
	if b {
		return "enabled"
	}
	return "disabled"
}
