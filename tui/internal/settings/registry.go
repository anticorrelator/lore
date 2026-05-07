// Package settings: registry.go is the widget-override hook (D4).
//
// The default-by-type dispatch in SettingsModel covers every field in the
// verified-current schema correctly. WidgetRegistry is a struct-level escape
// hatch: callers register a custom WidgetConstructor for a specific
// (parentPath, fieldName) pair when the default widget is wrong (e.g., a
// `string` field whose semantics demand a path picker, not a plain TextInput).
//
// The registry ships EMPTY at Phase 1 — no overrides are registered. The hook
// exists so a future schema edit needing a special widget can land without
// case-by-case branching in the dispatch core, and so task 5's harness widgets
// (HarnessBlockPanel, PrimaryRadio) can plug in via Register without coupling
// SettingsModel to those types.
//
// Struct-level (not global) preserves testability: each test constructs its
// own SettingsModel with its own registry, and overrides cannot leak across
// test cases.
package settings

// WidgetConstructor produces a FieldWidget for a specific dot-path. The
// schema is the resolved SchemaNode for that path — overrides may inspect
// it (e.g., to lift an enum's value set) or ignore it (e.g., a path picker
// that knows its own candidate set).
//
// fieldPath is the canonical dot-separated path the resulting widget will
// route writes through (e.g., "harnesses.claude-code.args"). Callers MUST
// pass the same fieldPath the SettingsModel uses for the field; deviating
// produces a widget whose FieldIntent.DotPath does not match the schema
// node, breaking commit routing.
type WidgetConstructor func(fieldPath string, schema *SchemaNode) FieldWidget

// overrideKey is the registry's index. Keying on (ParentPath, FieldName) —
// not the full dot-path — mirrors the data-driven sub-model registration
// pattern in tui/internal/followup/detail.go (followup-detail-view-tabs-are-
// data-driven-by-sidecar). The split also makes overrides match every
// instance of a field within a parent; e.g., registering an override for
// (parentPath="harnesses.<framework>", fieldName="args") covers every
// framework's args block, not just one.
type overrideKey struct {
	ParentPath string
	FieldName  string
}

// WidgetRegistry maps (parentPath, fieldName) pairs to WidgetConstructors.
// Constructed once per SettingsModel via NewWidgetRegistry; populated via
// Register; queried via Resolve during the schema walk.
type WidgetRegistry struct {
	overrides map[overrideKey]WidgetConstructor
}

// NewWidgetRegistry returns an empty registry. The returned pointer is
// retained by SettingsModel for the lifetime of the modal — Register calls
// must complete BEFORE the modal opens (i.e., before the first View() tick).
// In-flight registration during a render cycle is not supported.
func NewWidgetRegistry() *WidgetRegistry {
	return &WidgetRegistry{
		overrides: map[overrideKey]WidgetConstructor{},
	}
}

// Register installs a WidgetConstructor for (parentPath, fieldName). A second
// Register call with the same key overwrites the first — last-write-wins is
// deliberate: it lets a host package layer overrides on top of a default
// registry without a "merge" ceremony.
func (r *WidgetRegistry) Register(parentPath, fieldName string, fn WidgetConstructor) {
	r.overrides[overrideKey{ParentPath: parentPath, FieldName: fieldName}] = fn
}

// Lookup returns the registered constructor for (parentPath, fieldName) and
// whether one is present. Returns (nil, false) when no override is registered.
//
// SettingsModel callers use this to decide between override-vs-default
// dispatch; the actual widget construction (default-by-type fallback) lives
// in SettingsModel because the fallback needs access to the model's cached
// effective values and the per-widget unset-allowed predicate, which the
// registry has no business knowing about.
func (r *WidgetRegistry) Lookup(parentPath, fieldName string) (WidgetConstructor, bool) {
	fn, ok := r.overrides[overrideKey{ParentPath: parentPath, FieldName: fieldName}]
	return fn, ok
}
