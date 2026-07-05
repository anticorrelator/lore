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
//   - IntentDiscard / IntentNavigate → no-op; the widget already cancelled an
//     active buffer, or a container consumed navigation without changing values.
//
//   - Style caching per D3 + the lipgloss O(n)-per-frame gotcha: every
//     shared style is a package-init value in tui/internal/style. View()
//     never allocates a lipgloss.Style.
package settings

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/style"
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
	// preserving the same schema-backed write routing.
	limitDotPath string

	// nav is the editing/navigation coordinator (coordinator.go). It owns
	// the focus cursor, navigation gestures, and intent-routing dispatch.
	nav coordinator

	closed bool // set by Esc at top-level when no draft is active

	// statusMsg is rendered at the bottom of the body. Written on
	// IntentReject, write errors, and external-command stderr surfacing.
	statusMsg     string
	statusIsError bool
	lastWrite     struct {
		dotPath     string
		prevValue   any
		prevPresent bool
		armed       bool
	}

	// harnessToggleLocked: set to a non-empty framework id while a
	// harness-toggle shell-out is in flight, to suppress double-press races
	// on that specific harness (per the optimistic-UI plan in the
	// sharp-edges consult). Other harnesses' toggles remain interactive
	// while one is mid-flight.
	harnessToggleLocked map[string]bool

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
		m.viewport = viewport.New(viewport.WithWidth(width), viewport.WithHeight(height))
		m.viewportInit = true
	} else {
		m.viewport.SetWidth(width)
		m.viewport.SetHeight(height)
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
		harnessToggleLocked: map[string]bool{},
	}
	m.nav = coordinator{m: m, focusIdx: -1}

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
// touch settings.json (e.g., the agent toggle). Re-walking drops any
// non-focused transient edit buffers; the focused widget's index is preserved
// when its dot-path still exists post-walk.
func (m *SettingsModel) rebuildWidgets() {
	if m.schema == nil || m.schema.Root == nil {
		m.widgets = nil
		return
	}
	if m.schema.Root.Kind != KindObjectClosed {
		m.widgets = nil
		return
	}

	priorFocusPath := m.nav.focusedDotPath()
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
		m.nav.focusByDotPath(priorFocusPath)
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
func (m *SettingsModel) FocusConsumesRunes() bool { return m.nav.consumesNavRunes() }

// StatusHints returns the mode-aware hint set the host renders in the modal
// status bar. Leaf widgets provide their active-mode verbs; the model adds
// only global suffixes whose handlers are currently reachable.
func (m *SettingsModel) StatusHints() []StatusHint {
	if m.schemaErr != nil {
		return []StatusHint{{Key: "esc", Label: "close"}}
	}

	focused := m.nav.focusedWidget()
	if focused == nil {
		return m.genericStatusHints(nil)
	}

	provider, ok := focused.(HintProvider)
	if !ok {
		return m.genericStatusHints(focused)
	}
	hints := append([]StatusHint(nil), provider.StatusHints()...)
	// Row navigation is the baseline gesture of the whole panel: prepend
	// it whenever the focused widget is not consuming j/k as input (i.e.
	// the user is at row-selection level, not inside an editor mode).
	// Widget hints keep the front seats for their mode verbs otherwise.
	if !widgetConsumesNavRunes(focused) && !hasStatusHintKey(hints, "j/k") {
		hints = append([]StatusHint{{Key: "j/k", Label: "move"}}, hints...)
	}
	return m.appendStatusSuffixes(hints, focused)
}

func (m *SettingsModel) genericStatusHints(focused FieldWidget) []StatusHint {
	hints := []StatusHint{
		{Key: "j/k", Label: "move"},
		{Key: "enter", Label: "open"},
	}
	return m.appendStatusSuffixes(hints, focused)
}

func (m *SettingsModel) appendStatusSuffixes(hints []StatusHint, focused FieldWidget) []StatusHint {
	if m.lastWrite.armed && !m.nav.consumesNavRunes() {
		hints = appendStatusHintIfMissing(hints, StatusHint{Key: "U", Label: "undo"})
	}
	if m.statusEscCloses(focused, hints) {
		hints = appendStatusHintIfMissing(hints, StatusHint{Key: "esc", Label: "close"})
	}
	return hints
}

func (m *SettingsModel) statusEscCloses(focused FieldWidget, hints []StatusHint) bool {
	if hasStatusHintKey(hints, "esc") || m.limitDotPath != "" {
		return false
	}
	return focused == nil || !widgetConsumesNavRunes(focused)
}

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
		if key, ok := msg.(tea.KeyPressMsg); ok && key.String() == "esc" {
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

	if key, ok := msg.(tea.KeyPressMsg); ok {
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
			focused := m.nav.focusedWidget()
			if focused == nil {
				m.closed = true
				return m, nil
			}
			updated, cmd, intent := focused.Update(msg)
			m.nav.replaceFocused(updated)
			if intent != nil {
				if extra := m.nav.routeIntent(intent); extra != nil {
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
			m.nav.stepRowNavigation(+1)
			return m, nil
		case "shift+tab":
			m.nav.stepRowNavigation(-1)
			return m, nil
		// Scroll keys: route to the viewport so users can navigate long
		// widget trees with PgUp/PgDn even mid-edit.
		case "pgup", "pgdown", "home", "end", "ctrl+u", "ctrl+d":
			if m.viewportInit {
				vp, cmd := m.viewport.Update(msg)
				m.viewport = vp
				return m, cmd
			}
		case "U":
			if !m.nav.consumesNavRunes() {
				m.undoLastWrite()
				return m, nil
			}
		// j/k hierarchical navigation. At the outer boundary these move
		// between top-level sections. Once Enter has opened a container,
		// the focused container's NavStep moves within that level. When a
		// leaf editor is in edit mode, j/k are forwarded as literal/editor
		// input instead.
		case "j", "k", "up", "down":
			if !m.nav.consumesNavRunes() {
				delta := +1
				if key.String() == "k" || key.String() == "up" {
					delta = -1
				}
				m.nav.stepRowNavigation(delta)
				return m, nil
			}
		}
	}

	// Initial focus: first navigation keystroke installs focus on first item.
	m.nav.ensureInitialFocus()

	// Forward to the focused widget.
	w := m.nav.focusedWidget()
	if w == nil {
		return m, nil
	}
	commitMoveDelta := 0
	if key, ok := msg.(tea.KeyPressMsg); ok && m.nav.consumesNavRunes() {
		switch key.String() {
		case "up":
			commitMoveDelta = -1
		case "down":
			commitMoveDelta = +1
		}
	}
	updated, cmd, intent := w.Update(msg)
	m.nav.replaceFocused(updated)
	if intent != nil {
		if extra := m.nav.routeIntent(intent); extra != nil {
			cmd = teaBatch(cmd, extra)
		}
	}
	if commitMoveDelta != 0 && !m.nav.consumesNavRunes() {
		m.nav.stepRowNavigation(commitMoveDelta)
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

// FocusDotPath moves the initial modal focus to a rendered settings path.
// Hosts use this for context-sensitive entry points such as opening Settings
// from the settlement panel directly at the settlement section.
func (m *SettingsModel) FocusDotPath(dotPath string) {
	m.nav.focusByDotPath(dotPath)
}

// LimitToDotPath renders and updates only the matching top-level widget while
// keeping SettingsModel's normal validation and persistence path. Esc cancels
// active edits or backs out nested containers, but it does not close the host
// view in this embedded mode.
func (m *SettingsModel) LimitToDotPath(dotPath string) {
	m.limitDotPath = dotPath
	m.closed = false
	m.nav.focusByDotPath(dotPath)
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
		prevValue, prevPresent := m.lookupEffective(intent.DotPath)
		if err := m.store.Patch("tui_launch_framework", chosen); err != nil {
			m.statusMsg = fmt.Sprintf("write tui_launch_framework: %v", err)
			m.statusIsError = true
			return nil
		}
		m.armUndoIfChanged(intent.DotPath, prevValue, prevPresent, chosen)
		m.setEffective(intent.DotPath, chosen)
		m.statusMsg = fmt.Sprintf("saved %s · U undo", intent.DotPath)
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
	prevValue, prevPresent := m.lookupEffective(intent.DotPath)
	if err := m.store.Patch(intent.DotPath, intent.Value); err != nil {
		m.statusMsg = fmt.Sprintf("write %s: %v", intent.DotPath, err)
		m.statusIsError = true
		return nil
	}
	m.armUndoIfChanged(intent.DotPath, prevValue, prevPresent, intent.Value)
	m.setEffective(intent.DotPath, intent.Value)
	m.statusMsg = fmt.Sprintf("saved %s · U undo", intent.DotPath)
	m.statusIsError = false
	return nil
}

// routeUnset handles the IntentUnset branch of the coordinator's intent
// routing: delete the overlay key so inheritance resumes, refreshing the
// cached effective document so subsequent renders see absence.
func (m *SettingsModel) routeUnset(intent *FieldIntent) {
	prevValue, prevPresent := m.lookupEffective(intent.DotPath)
	if err := m.store.Delete(intent.DotPath); err != nil {
		m.statusMsg = fmt.Sprintf("unset %s: %v", intent.DotPath, err)
		m.statusIsError = true
		return
	}
	// Arm only when the delete removed something: unsetting an already
	// absent key is a no-op and must not clobber the real undo target.
	if prevPresent {
		m.armUndo(intent.DotPath, prevValue, prevPresent)
	}
	m.invalidateEffective(intent.DotPath)
	m.statusMsg = fmt.Sprintf("unset %s · U undo", intent.DotPath)
	m.statusIsError = false
}

// armUndoIfChanged arms the single-slot undo only when the written value
// actually differs from the previous effective value. Defense in depth
// behind the widgets' changed-only commit guards: a no-op re-commit (same
// value written again) must never clobber the user's real undo target.
func (m *SettingsModel) armUndoIfChanged(dotPath string, prevValue any, prevPresent bool, newValue any) {
	if prevPresent && effectiveValuesEqual(prevValue, newValue) {
		return
	}
	m.armUndo(dotPath, prevValue, prevPresent)
}

// effectiveValuesEqual compares two settings values structurally via a JSON
// round-trip, tolerating the mixed concrete types that reach routeCommit
// (e.g. int from NumericInput vs float64 from the effective document).
func effectiveValuesEqual(a, b any) bool {
	ra, errA := json.Marshal(a)
	rb, errB := json.Marshal(b)
	if errA != nil || errB != nil {
		return false
	}
	return string(ra) == string(rb)
}

func (m *SettingsModel) armUndo(dotPath string, prevValue any, prevPresent bool) {
	m.lastWrite.dotPath = dotPath
	m.lastWrite.prevValue = cloneEffectiveValue(prevValue)
	m.lastWrite.prevPresent = prevPresent
	m.lastWrite.armed = true
}

func (m *SettingsModel) undoLastWrite() {
	if !m.lastWrite.armed {
		return
	}
	dotPath := m.lastWrite.dotPath
	if m.lastWrite.prevPresent {
		if err := m.store.Patch(dotPath, m.lastWrite.prevValue); err != nil {
			m.statusMsg = fmt.Sprintf("undo %s: %v", dotPath, err)
			m.statusIsError = true
			return
		}
	} else {
		if err := m.store.Delete(dotPath); err != nil {
			m.statusMsg = fmt.Sprintf("undo %s: %v", dotPath, err)
			m.statusIsError = true
			return
		}
	}
	if eff, err := m.store.LoadAll(); err == nil {
		m.effective = eff
		m.rebuildWidgets()
		m.reconcileHarnessPanels()
	} else {
		m.statusMsg = fmt.Sprintf("undo %s reload: %v", dotPath, err)
		m.statusIsError = true
		return
	}
	m.lastWrite.armed = false
	m.statusMsg = fmt.Sprintf("undid %s", dotPath)
	m.statusIsError = false
}

func cloneEffectiveValue(v any) any {
	if v == nil {
		return nil
	}
	raw, err := json.Marshal(v)
	if err != nil {
		return v
	}
	var out any
	if err := json.Unmarshal(raw, &out); err != nil {
		return v
	}
	return out
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
		b.WriteString(style.SevBlocking.Render("settings schema error"))
		b.WriteByte('\n')
		b.WriteString(style.Dim.Render(m.schemaErr.Error()))
		b.WriteByte('\n')
		return b.String()
	}

	content := m.renderBodyContent()

	if !m.viewportInit || m.viewport.Height() <= 0 {
		return content
	}
	m.viewport.SetContent(content)
	return m.viewport.View()
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
