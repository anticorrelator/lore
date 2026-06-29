package settings

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

// ----------------------------------------------------------------------------
// Test fakes for the SettingsStore and CommandRunner injection seams.
// ----------------------------------------------------------------------------

// fakeStore is a SettingsStore backed by an in-memory map. Mirrors the on-disk
// settings.json document but skips the flock+atomic-rename ceremony — tests
// don't need it and including it would couple them to the real config dir.
type fakeStore struct {
	doc map[string]any
	// patches and deletes record the routed write calls in order so
	// assertions can verify what SettingsModel emitted (e.g., that
	// harnesses.<fw>.enabled commits never reach Patch).
	patches []recordedPatch
	deletes []string
	// patchErr / deleteErr, when non-nil, is returned from the next Patch /
	// Delete call. Reset to nil after firing.
	patchErr  error
	deleteErr error
}

type recordedPatch struct {
	dotPath string
	value   any
}

func newFakeStore(doc map[string]any) *fakeStore {
	if doc == nil {
		doc = map[string]any{}
	}
	return &fakeStore{doc: doc}
}

func (f *fakeStore) LoadAll() (map[string]any, error) {
	return cloneAnyMap(f.doc), nil
}

func (f *fakeStore) Patch(dotPath string, value any) error {
	f.patches = append(f.patches, recordedPatch{dotPath: dotPath, value: value})
	if f.patchErr != nil {
		err := f.patchErr
		f.patchErr = nil
		return err
	}
	// Mirror SettingsPatch's roundtrip: marshal+unmarshal so the stored
	// value matches what a real Patch would produce.
	b, err := json.Marshal(value)
	if err != nil {
		return err
	}
	var rt any
	if err := json.Unmarshal(b, &rt); err != nil {
		return err
	}
	return setDotPath(f.doc, dotPath, rt)
}

func (f *fakeStore) Delete(dotPath string) error {
	f.deletes = append(f.deletes, dotPath)
	if f.deleteErr != nil {
		err := f.deleteErr
		f.deleteErr = nil
		return err
	}
	return deleteDotPath(f.doc, dotPath)
}

// cloneAnyMap is a shallow JSON-roundtrip clone of a settings doc; sufficient
// for fakeStore because LoadAll callers don't mutate the returned map.
func cloneAnyMap(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	b, err := json.Marshal(m)
	if err != nil {
		return map[string]any{}
	}
	var out map[string]any
	if err := json.Unmarshal(b, &out); err != nil {
		return map[string]any{}
	}
	return out
}

func setDotPath(doc map[string]any, dotPath string, value any) error {
	segments := strings.Split(dotPath, ".")
	node := doc
	for _, seg := range segments[:len(segments)-1] {
		next, exists := node[seg]
		if !exists {
			child := map[string]any{}
			node[seg] = child
			node = child
			continue
		}
		child, ok := next.(map[string]any)
		if !ok {
			return errors.New("non-object intermediate")
		}
		node = child
	}
	node[segments[len(segments)-1]] = value
	return nil
}

func deleteDotPath(doc map[string]any, dotPath string) error {
	segments := strings.Split(dotPath, ".")
	node := doc
	for _, seg := range segments[:len(segments)-1] {
		next, ok := node[seg].(map[string]any)
		if !ok {
			return nil
		}
		node = next
	}
	delete(node, segments[len(segments)-1])
	return nil
}

// fakeRunner records CommandRunner.Run calls. Returns the configured
// stdout/stderr/err values for assertion-driven testing of the
// harness-toggle shell-out path.
type fakeRunner struct {
	calls  []recordedRun
	stdout string
	stderr string
	err    error
}

type recordedRun struct {
	script string
	args   []string
}

func (f *fakeRunner) Run(script string, args ...string) (string, string, error) {
	f.calls = append(f.calls, recordedRun{script: script, args: append([]string(nil), args...)})
	return f.stdout, f.stderr, f.err
}

// ----------------------------------------------------------------------------
// Common fixture: a small schema covering every NodeKind so the empty-registry
// default-by-type assertion can sweep the taxonomy in one pass.
// ----------------------------------------------------------------------------

const everyKindSchema = `{
	"$schema": "https://json-schema.org/draft/2020-12/schema",
	"type": "object",
	"additionalProperties": false,
	"required": ["version", "tui_launch_framework", "harnesses"],
	"properties": {
		"version": {"type": "integer", "minimum": 1},
		"tui_launch_framework": {"type": "string", "enum": ["claude-code", "opencode", "codex"]},
		"harnesses": {
			"type": "object",
			"additionalProperties": false,
			"properties": {
				"claude-code": {
					"type": "object",
					"additionalProperties": false,
					"properties": {
						"args":    {"type": "array", "items": {"type": "string"}},
						"enabled": {"type": "boolean"}
					}
				},
				"codex": {
					"type": "object",
					"additionalProperties": false,
					"properties": {
						"args":    {"type": "array", "items": {"type": "string"}},
						"enabled": {"type": "boolean"}
					}
				}
			}
		},
		"flag": {"type": "boolean"},
		"name": {"type": "string", "pattern": "^[a-z]+$", "minLength": 1},
		"layout": {"type": "string", "enum": ["left", "right"]},
		"count": {"type": "integer", "minimum": 0},
		"ratio": {"type": "number", "minimum": 0, "maximum": 1},
		"tags": {"type": "array", "items": {"type": "string"}, "minItems": 1, "uniqueItems": true},
		"closed_obj": {
			"type": "object",
			"additionalProperties": false,
			"properties": {"label": {"type": "string"}}
		},
		"open_obj": {
			"type": "object",
			"additionalProperties": {"type": "string"}
		}
	}
}`

func writeEveryKindSchema(t *testing.T) string {
	t.Helper()
	return writeFixture(t, everyKindSchema)
}

func writeMinimalCapabilities(t *testing.T, frameworks []string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "capabilities.json")
	fwMap := map[string]any{}
	for _, id := range frameworks {
		fwMap[id] = map[string]any{"id": id, "display_name": id}
	}
	body, err := json.Marshal(map[string]any{
		"version":    1,
		"frameworks": fwMap,
	})
	if err != nil {
		t.Fatalf("marshal capabilities: %v", err)
	}
	if err := os.WriteFile(p, body, 0o600); err != nil {
		t.Fatalf("write capabilities: %v", err)
	}
	return p
}

// newTestModel constructs a SettingsModel against an in-memory store and a
// fixture schema/capabilities. Callers can override the seed document and
// runner. Returns the model and the seeded fakes for assertions.
func newTestModel(t *testing.T, seed map[string]any) (*SettingsModel, *fakeStore, *fakeRunner) {
	t.Helper()
	schemaPath := writeEveryKindSchema(t)
	capsPath := writeMinimalCapabilities(t, []string{"claude-code", "opencode", "codex"})
	store := newFakeStore(seed)
	runner := &fakeRunner{}
	m, err := NewSettingsModel(SettingsModelOptions{
		SchemaPath:       schemaPath,
		CapabilitiesPath: capsPath,
		Store:            store,
		Runner:           runner,
		EnableScript:     "/fake/enable.sh",
		DisableScript:    "/fake/disable.sh",
		Registry:         NewWidgetRegistry(),
	})
	if err != nil {
		t.Fatalf("NewSettingsModel: %v", err)
	}
	return m, store, runner
}

// ----------------------------------------------------------------------------
// Tests.
// ----------------------------------------------------------------------------

// TestEmptyRegistry_DefaultByTypeForEveryVisibleKind verifies that with an
// empty WidgetRegistry, the schema walker chooses a default-by-type widget for
// every visible NodeKind in the verified-current taxonomy. The walker excludes
// tui_launch_framework and the harnesses subtree (D8 boundary), plus metadata /
// retired-compat fields that are schema-valid but not user-editable.
func TestEmptyRegistry_DefaultByTypeForEveryVisibleKind(t *testing.T) {
	m, _, _ := newTestModel(t, nil)

	wantWidgetType := map[string]string{
		"flag":       "*settings.ToggleRow",
		"name":       "*settings.TextInput",
		"layout":     "*settings.EnumSelector",
		"count":      "*settings.NumericInput",
		"ratio":      "*settings.NumericInput",
		"tags":       "*settings.ListEditor",
		"closed_obj": "*settings.ClosedObjectSubPanel",
		"open_obj":   "*settings.OpenKeysetKVEditor",
	}

	got := map[string]string{}
	for _, w := range m.widgets {
		// Use the dot-path's last segment as the property name for top-level fields.
		dot := w.DotPath()
		if !strings.Contains(dot, ".") {
			got[dot] = widgetTypeName(w)
		}
	}

	for path, want := range wantWidgetType {
		if got[path] != want {
			t.Errorf("widget at %q: want %s, got %s", path, want, got[path])
		}
	}

	// tui_launch_framework and the entire harnesses subtree must NOT be in the
	// schema-driven walker's output (D8 boundary). Dedicated top-sections
	// (PrimaryRadio, HarnessBlockPanel — the latter embedding its own
	// per-harness enabled toggle) own those paths.
	//
	// version is valid settings.json metadata, but it is owned by migration
	// code rather than users, so it is hidden from the editor.
	for _, w := range m.widgets {
		if w.DotPath() == "tui_launch_framework" {
			t.Errorf("tui_launch_framework leaked into schema-driven walker (D8 boundary)")
		}
		if strings.HasPrefix(w.DotPath(), "harnesses") {
			t.Errorf("harnesses subtree leaked into schema-driven walker: %s (D8 boundary)", w.DotPath())
		}
		if w.DotPath() == "version" {
			t.Errorf("version leaked into settings editor; it is file metadata, not a user setting")
		}
	}
}

func TestHiddenSettingsPaths_NotRendered(t *testing.T) {
	schemaPath := writeFixture(t, `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"type": "object",
		"additionalProperties": false,
		"required": ["version", "tui_launch_framework", "harnesses"],
		"properties": {
			"version": {"type": "integer", "minimum": 1},
			"tui_launch_framework": {"type": "string", "enum": ["claude-code"]},
			"harnesses": {
				"type": "object",
				"additionalProperties": false,
				"properties": {"claude-code": {"type": "object", "additionalProperties": false, "properties": {"args": {"type": "array", "items": {"type": "string"}}}}}
			}
		}
	}`)
	capsPath := writeMinimalCapabilities(t, []string{"claude-code"})
	store := newFakeStore(map[string]any{
		"version":              float64(1),
		"tui_launch_framework": "claude-code",
		"harnesses":            map[string]any{"claude-code": map[string]any{"args": []any{}}},
	})
	m, err := NewSettingsModel(SettingsModelOptions{
		SchemaPath:       schemaPath,
		CapabilitiesPath: capsPath,
		Store:            store,
		Runner:           &fakeRunner{},
		Registry:         NewWidgetRegistry(),
	})
	if err != nil {
		t.Fatalf("NewSettingsModel: %v", err)
	}

	for _, w := range m.widgets {
		if w.DotPath() == "version" {
			t.Fatalf("hidden path rendered as top-level widget: %s", w.DotPath())
		}
	}
	view := stripANSI(m.View())
	if strings.Contains(view, "lead") || strings.Contains(view, "spec-design") {
		t.Fatalf("unknown top-level settings leaked into generic render:\n%s", view)
	}
}

// widgetTypeName returns "*settings.<Type>" for a widget value.
func widgetTypeName(w FieldWidget) string {
	switch w.(type) {
	case *NumericInput:
		return "*settings.NumericInput"
	case *ToggleRow:
		return "*settings.ToggleRow"
	case *TextInput:
		return "*settings.TextInput"
	case *EnumSelector:
		return "*settings.EnumSelector"
	case *ListEditor:
		return "*settings.ListEditor"
	case *ClosedObjectSubPanel:
		return "*settings.ClosedObjectSubPanel"
	case *OpenKeysetKVEditor:
		return "*settings.OpenKeysetKVEditor"
	case *PrimaryRadio:
		return "*settings.PrimaryRadio"
	case *HarnessBlockPanel:
		return "*settings.HarnessBlockPanel"
	default:
		return "unknown"
	}
}

// TestEnumReject_ValueNotInSet feeds an IntentCommit with an out-of-set
// value to routeIntent and verifies the model rejects it (D6) — no Patch,
// status line shows error.
func TestEnumReject_ValueNotInSet(t *testing.T) {
	m, store, _ := newTestModel(t, nil)

	intent := &FieldIntent{
		DotPath: "layout",
		Status:  IntentCommit,
		Value:   "diagonal", // not in [left, right]
	}
	m.nav.routeIntent(intent)

	if len(store.patches) != 0 {
		t.Errorf("expected no patches for out-of-set enum, got %v", store.patches)
	}
	if !m.statusIsError {
		t.Errorf("expected status error for out-of-set enum")
	}
	if !strings.Contains(m.statusMsg, "layout") {
		t.Errorf("expected status to mention field name, got %q", m.statusMsg)
	}
}

// TestActiveFrameworkReject_NotInCapabilities verifies the tui_launch_framework
// closed-set check against capabilities.json frameworks (D8). A value
// outside the registered set must be rejected without a Patch call.
func TestActiveFrameworkReject_NotInCapabilities(t *testing.T) {
	m, store, _ := newTestModel(t, nil)

	intent := &FieldIntent{
		DotPath: "tui_launch_framework",
		Status:  IntentCommit,
		Value:   "rogue-framework",
	}
	m.nav.routeIntent(intent)

	if len(store.patches) != 0 {
		t.Errorf("expected no patches for unknown framework, got %v", store.patches)
	}
	if !m.statusIsError {
		t.Errorf("expected status error for unknown framework")
	}
	if !strings.Contains(m.statusMsg, "rogue-framework") {
		t.Errorf("expected status to mention rejected value, got %q", m.statusMsg)
	}
}

// TestActiveFrameworkAccept_InCapabilities verifies the success path: a
// value present in capabilities.json frameworks routes through Patch.
func TestActiveFrameworkAccept_InCapabilities(t *testing.T) {
	m, store, _ := newTestModel(t, nil)

	intent := &FieldIntent{
		DotPath: "tui_launch_framework",
		Status:  IntentCommit,
		Value:   "opencode",
	}
	m.nav.routeIntent(intent)

	if len(store.patches) != 1 {
		t.Fatalf("expected 1 patch, got %d: %v", len(store.patches), store.patches)
	}
	if store.patches[0].dotPath != "tui_launch_framework" || store.patches[0].value != "opencode" {
		t.Errorf("unexpected patch: %+v", store.patches[0])
	}
	if m.statusIsError {
		t.Errorf("expected no error on accepted framework, got %q", m.statusMsg)
	}
}

// TestHarnessEnabledShellOut_RoutesViaCommandRunner verifies the dual-write
// contract: a per-harness toggle goes through CommandRunner.Run on the
// configured enable/disable script with the framework as a positional arg —
// NOT through Patch.
func TestHarnessEnabledShellOut_RoutesViaCommandRunner(t *testing.T) {
	m, store, runner := newTestModel(t, nil)

	cmd := m.ToggleHarness("claude-code", true)
	if cmd == nil {
		t.Fatalf("ToggleHarness returned nil cmd")
	}
	msg := cmd()
	result, ok := msg.(harnessToggleResultMsg)
	if !ok {
		t.Fatalf("expected harnessToggleResultMsg, got %T", msg)
	}
	if result.err != nil {
		t.Fatalf("unexpected runner error: %v", result.err)
	}
	if result.framework != "claude-code" {
		t.Errorf("expected framework claude-code, got %q", result.framework)
	}

	if len(runner.calls) != 1 {
		t.Fatalf("expected 1 runner call, got %d", len(runner.calls))
	}
	if runner.calls[0].script != "/fake/enable.sh" {
		t.Errorf("expected enable.sh, got %q", runner.calls[0].script)
	}
	if len(runner.calls[0].args) != 1 || runner.calls[0].args[0] != "claude-code" {
		t.Errorf("expected runner call args [claude-code], got %v", runner.calls[0].args)
	}
	if len(store.patches) != 0 {
		t.Errorf("harness toggle must not direct-Patch harnesses.<fw>.enabled; got patches %v", store.patches)
	}
}

// TestHarnessEnabledDirectCommit_TreatedAsProgrammingError verifies that an
// IntentCommit on harnesses.<fw>.enabled (which would only happen if a
// default-by-type ToggleRow widget is misregistered) is REJECTED with a
// status error rather than silently routed to Patch (which would bypass
// the dual-write fan-out the harness-toggle script performs alongside the
// flag flip).
func TestHarnessEnabledDirectCommit_TreatedAsProgrammingError(t *testing.T) {
	m, store, _ := newTestModel(t, nil)

	intent := &FieldIntent{
		DotPath: "harnesses.claude-code.enabled",
		Status:  IntentCommit,
		Value:   true,
	}
	m.nav.routeIntent(intent)

	if len(store.patches) != 0 {
		t.Errorf("harnesses.<fw>.enabled direct-commit must not Patch, got %v", store.patches)
	}
	if !m.statusIsError {
		t.Errorf("expected status error for harnesses.<fw>.enabled direct-commit")
	}
}

// TestPerHarnessLockIndependence verifies that a toggle in flight on one
// framework does not block a toggle on a different framework — the lock is
// keyed per-framework, not global.
func TestPerHarnessLockIndependence(t *testing.T) {
	m, _, _ := newTestModel(t, nil)

	cmd1 := m.ToggleHarness("claude-code", true)
	if cmd1 == nil {
		t.Fatalf("first ToggleHarness returned nil cmd")
	}
	// Don't resolve cmd1 — keep claude-code locked.

	// codex toggle should still be allowed.
	cmd2 := m.ToggleHarness("codex", false)
	if cmd2 == nil {
		t.Fatalf("ToggleHarness on codex must not be blocked by claude-code lock")
	}

	// Second claude-code toggle with the lock still held must be suppressed.
	cmd3 := m.ToggleHarness("claude-code", false)
	if cmd3 != nil {
		t.Errorf("second ToggleHarness on claude-code must be suppressed while lock held")
	}
}

// TestUnsetRoundTrip_PatchThenUnset_ByteIdentical verifies the round-trip
// invariant: writing a value and then unsetting it produces a settings
// document byte-identical to the original (modulo the reload between).
//
// Note: Patch + Delete on the fake store leaves an empty intermediate
// object behind (no parent pruning, per D9). This test asserts the leaf
// is gone, which is the contract — full byte-identity is exercised by
// the SettingsDelete tests in config_test.go.
func TestUnsetRoundTrip_PatchThenUnset(t *testing.T) {
	seed := map[string]any{}
	m, store, _ := newTestModel(t, seed)

	// Patch: set name = "foo"
	m.nav.routeIntent(&FieldIntent{DotPath: "name", Status: IntentCommit, Value: "foo"})
	if v, ok := store.doc["name"]; !ok || v != "foo" {
		t.Fatalf("after patch, expected name=foo in store, got %v (present=%v)", v, ok)
	}

	// Unset: remove name
	m.nav.routeIntent(&FieldIntent{DotPath: "name", Status: IntentUnset})
	if _, ok := store.doc["name"]; ok {
		t.Errorf("after unset, expected name absent in store, got %v", store.doc["name"])
	}
	if len(store.deletes) != 1 || store.deletes[0] != "name" {
		t.Errorf("expected single delete on 'name', got %v", store.deletes)
	}
}

// TestAbsentOverlayTabThroughDoesNotPatch verifies that simulating Tab
// gestures across schema-driven widgets when there is NO commit emitted
// does not produce any Patch calls. This is the model-layer integration
// of D9's "tab-through is not a write" invariant — the widgets enforce
// IntentDiscard on Blur, and the model must not turn that into a Patch.
func TestAbsentOverlayTabThroughDoesNotPatch(t *testing.T) {
	m, store, _ := newTestModel(t, nil)

	// Drive the model through several Tab presses. Each Tab blurs the
	// current widget and focuses the next. With no draft activity, no
	// IntentCommit should ever fire.
	for i := 0; i < 8; i++ {
		_, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyTab})
	}

	if len(store.patches) > 0 {
		t.Errorf("tab-through with no edits emitted patches: %v", store.patches)
	}
}

func TestEscBacksOutOfParentWithoutClearingCommittedLeaf(t *testing.T) {
	m, store, _ := newTestModel(t, map[string]any{
		"closed_obj": map[string]any{"label": ""},
	})
	m.nav.focusByDotPath("closed_obj")

	_, _ = m.Update(keyMsg("enter")) // enter closed_obj
	_, _ = m.Update(keyMsg("enter")) // edit label
	_, _ = m.Update(keyMsg("f"))
	_, _ = m.Update(keyMsg("o"))
	_, _ = m.Update(keyMsg("o"))
	_, _ = m.Update(keyMsg("enter")) // commit label

	if len(store.patches) != 1 || store.patches[0].dotPath != "closed_obj.label" {
		t.Fatalf("expected one committed leaf patch, got %+v", store.patches)
	}
	if got := store.doc["closed_obj"].(map[string]any)["label"]; got != "foo" {
		t.Fatalf("expected committed label before Esc, got %v", got)
	}

	_, _ = m.Update(keyMsg("esc")) // back out of closed_obj
	if got := store.doc["closed_obj"].(map[string]any)["label"]; got != "foo" {
		t.Fatalf("Esc backing out of parent cleared committed label; got %v", got)
	}
	if len(store.patches) != 1 {
		t.Fatalf("Esc backing out of parent should not write another patch, got %+v", store.patches)
	}
	if len(store.deletes) != 0 {
		t.Fatalf("Esc backing out of parent should not unset leaves, got deletes=%v", store.deletes)
	}
}

// TestEscClosesModalWhenNoFocus verifies the host's contract: Esc at top
// level (no draft active) sets Closed() so the host can unwrap the modal.
func TestEscClosesModalWhenNoFocus(t *testing.T) {
	m, _, _ := newTestModel(t, nil)
	if m.Closed() {
		t.Fatalf("model started in closed state")
	}
	_, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	if !m.Closed() {
		t.Errorf("expected Closed() after Esc with no focus")
	}
}

// TestSchemaErrorRendersBanner verifies the D1 verification gate: an
// UnsupportedConstructError at LoadSchema time is stashed and View()
// renders an error banner rather than a partial widget tree.
func TestSchemaErrorRendersBanner(t *testing.T) {
	body := `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"type": "object",
		"additionalProperties": false,
		"properties": {
			"x": {"oneOf": [{"type": "string"}, {"type": "integer"}]}
		}
	}`
	schemaPath := writeFixture(t, body)
	capsPath := writeMinimalCapabilities(t, []string{"claude-code"})
	store := newFakeStore(nil)

	m, err := NewSettingsModel(SettingsModelOptions{
		SchemaPath:       schemaPath,
		CapabilitiesPath: capsPath,
		Store:            store,
		Runner:           &fakeRunner{},
		Registry:         NewWidgetRegistry(),
	})
	if err == nil {
		t.Fatalf("expected error from unsupported construct, got nil")
	}
	if m == nil {
		t.Fatalf("expected model returned alongside error so View can render banner")
	}
	if !strings.Contains(m.View(), "settings schema error") {
		t.Errorf("expected View to render error banner, got: %q", m.View())
	}
}

// TestRegistryOverrideTakesPrecedence verifies the registry hook: an
// override constructor for a (parentPath, fieldName) is preferred over the
// default-by-type widget.
func TestRegistryOverrideTakesPrecedence(t *testing.T) {
	schemaPath := writeEveryKindSchema(t)
	capsPath := writeMinimalCapabilities(t, []string{"claude-code"})
	store := newFakeStore(nil)
	registry := NewWidgetRegistry()

	// Override the top-level "name" string field with a custom widget that
	// returns a recognizable EnumSelector — proving the override path runs.
	sentinel := NewEnumSelector("name", []string{"sentinel-a", "sentinel-b"}, nil, "", false)
	registry.Register("", "name", func(fieldPath string, schema *SchemaNode) FieldWidget {
		return sentinel
	})

	m, err := NewSettingsModel(SettingsModelOptions{
		SchemaPath:       schemaPath,
		CapabilitiesPath: capsPath,
		Store:            store,
		Runner:           &fakeRunner{},
		Registry:         registry,
	})
	if err != nil {
		t.Fatalf("NewSettingsModel: %v", err)
	}

	for _, w := range m.widgets {
		if w.DotPath() == "name" {
			if w != FieldWidget(sentinel) {
				t.Errorf("override not applied: name widget is %T, expected sentinel EnumSelector", w)
			}
			return
		}
	}
	t.Errorf("name widget not found in model")
}

// TestRegisterTopSection_RendersBeforeWidgets verifies the seam task 5 uses
// to plug PrimaryRadio / HarnessBlockPanel / agent toggle into the modal:
// RegisterTopSection-attached widgets render before the schema-driven walker.
func TestRegisterTopSection_RendersBeforeWidgets(t *testing.T) {
	m, _, _ := newTestModel(t, nil)

	radio := NewPrimaryRadio("tui_launch_framework", []string{"claude-code", "opencode"}, nil, "claude-code")
	m.RegisterTopSection("primary harness", radio)

	view := m.View()
	radioIdx := strings.Index(view, "claude-code")
	flagIdx := strings.Index(view, "flag")
	if radioIdx == -1 {
		t.Fatalf("expected primary radio rendered, got: %s", view)
	}
	if flagIdx == -1 {
		t.Fatalf("expected schema-driven flag rendered, got: %s", view)
	}
	if radioIdx > flagIdx {
		t.Errorf("top section must render before schema-driven widgets; primary at %d, flag at %d", radioIdx, flagIdx)
	}
}

func TestLimitToDotPath_RendersOnlyOneSubtreeAndDoesNotCloseOnEsc(t *testing.T) {
	m, _, _ := newTestModel(t, map[string]any{
		"closed_obj": map[string]any{"label": "alpha"},
		"name":       "beta",
	})
	m.LimitToDotPath("closed_obj")

	out := stripANSI(m.View())
	if !strings.Contains(out, "closed_obj") || !strings.Contains(out, "label") {
		t.Fatalf("limited view should render closed_obj subtree, got:\n%s", out)
	}
	if strings.Contains(out, "name:") || strings.Contains(out, "flag:") {
		t.Fatalf("limited view should not render sibling settings, got:\n%s", out)
	}

	_, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if m.Closed() {
		t.Fatal("embedded limited settings should not close on top-level Esc")
	}
	out = stripANSI(m.View())
	if strings.Contains(out, "name:") || strings.Contains(out, "flag:") {
		t.Fatalf("limited view should remain constrained after navigation, got:\n%s", out)
	}
}

func TestLimitToDotPath_CompactEmbedOmitsOuterFrame(t *testing.T) {
	m, _, _ := newTestModel(t, map[string]any{
		"closed_obj": map[string]any{"label": "alpha"},
	})
	m.LimitToDotPath("closed_obj")
	m.SetCompactEmbed(true)

	out := stripANSI(m.View())
	if strings.Contains(out, "╭") || strings.Contains(out, "│") {
		t.Fatalf("compact embedded view should omit the top-level section frame, got:\n%s", out)
	}
	if strings.Contains(out, "closed_obj") {
		t.Fatalf("compact embedded view should rely on host title, got:\n%s", out)
	}
	if !strings.Contains(out, "label") {
		t.Fatalf("compact embedded view should still render subtree fields, got:\n%s", out)
	}
}

func TestLimitToDotPath_CompactEmbedNavigationStartsInsideSubtree(t *testing.T) {
	m, _, _ := newTestModel(t, map[string]any{
		"closed_obj": map[string]any{"label": "alpha"},
	})
	m.LimitToDotPath("closed_obj")
	m.SetCompactEmbed(true)

	panel, ok := m.limitedWidget().(*ClosedObjectSubPanel)
	if !ok {
		t.Fatalf("limited widget is %T, want ClosedObjectSubPanel", m.limitedWidget())
	}
	if !panel.entered || len(panel.children) == 0 || !panel.children[0].Focused() {
		t.Fatalf("compact limited panel should start inside first child; entered=%v children=%d", panel.entered, len(panel.children))
	}

	_, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if panel.cursor == 0 && len(panel.children) > 1 {
		t.Fatalf("j should navigate the embedded subtree, cursor=%d", panel.cursor)
	}
}

func TestLimitToDotPath_CompactEmbedGridsSimpleLeavesAndSuppressesDescriptions(t *testing.T) {
	schemaPath := writeFixture(t, `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"type": "object",
		"additionalProperties": false,
		"required": ["tui_launch_framework", "harnesses"],
		"properties": {
			"tui_launch_framework": {"type": "string", "enum": ["claude-code"]},
			"harnesses": {"type": "object", "additionalProperties": false, "properties": {"claude-code": {"type": "object", "additionalProperties": false, "properties": {"args": {"type": "array", "items": {"type": "string"}}}}}},
			"settlement": {
				"type": "object",
				"additionalProperties": false,
				"description": "Long operational explanation should not appear inline.",
					"properties": {
						"enabled": {"type": "boolean", "description": "Enable explanation should not appear inline."},
						"max_concurrency": {"type": "integer", "minimum": 1, "description": "Concurrency explanation should not appear inline."}
					}
			}
		}
	}`)
	capsPath := writeMinimalCapabilities(t, []string{"claude-code"})
	store := newFakeStore(map[string]any{
		"tui_launch_framework": "claude-code",
		"harnesses":            map[string]any{"claude-code": map[string]any{"args": []any{}}},
		"settlement": map[string]any{
			"enabled":         true,
			"max_concurrency": float64(20),
		},
	})
	m, err := NewSettingsModel(SettingsModelOptions{
		SchemaPath:       schemaPath,
		CapabilitiesPath: capsPath,
		Store:            store,
		Runner:           &fakeRunner{},
		EnableScript:     "/fake/enable.sh",
		DisableScript:    "/fake/disable.sh",
		Registry:         NewWidgetRegistry(),
	})
	if err != nil {
		t.Fatalf("NewSettingsModel: %v", err)
	}
	m.LimitToDotPath("settlement")
	m.SetCompactEmbed(true)
	m.SetSize(90, 20)

	out := stripANSI(m.View())
	if strings.Contains(out, "explanation") || strings.Contains(out, "settlement") {
		t.Fatalf("compact embedded view should suppress section/field descriptions and host-owned title, got:\n%s", out)
	}
	var lines []string
	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) != "" {
			lines = append(lines, line)
		}
	}
	if len(lines) != 1 {
		t.Fatalf("expected compact embed to keep three simple leaves on one row at width 90, got %d:\n%s", len(lines), out)
	}
	if !strings.Contains(lines[0], "enabled") || !strings.Contains(lines[0], "concurrency") {
		t.Fatalf("expected simple leaves to share one compact row, got:\n%s", out)
	}
}

func TestLimitToDotPath_CompactEmbedGroupsBatchControlsOnOwnLine(t *testing.T) {
	schemaPath := writeFixture(t, `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"type": "object",
		"additionalProperties": false,
		"required": ["tui_launch_framework", "harnesses"],
		"properties": {
			"tui_launch_framework": {"type": "string", "enum": ["claude-code"]},
			"harnesses": {"type": "object", "additionalProperties": false, "properties": {"claude-code": {"type": "object", "additionalProperties": false, "properties": {"args": {"type": "array", "items": {"type": "string"}}}}}},
			"settlement": {
				"type": "object",
				"additionalProperties": false,
				"properties": {
					"enabled": {"type": "boolean"},
					"max_concurrency": {"type": "integer", "minimum": 1},
					"batch_size": {"type": "integer", "minimum": 1},
					"batch_recompute_min_interval_seconds": {"type": "integer", "minimum": 0},
					"lease_ttl_seconds": {"type": "integer", "minimum": 1}
				}
			}
		}
	}`)
	capsPath := writeMinimalCapabilities(t, []string{"claude-code"})
	store := newFakeStore(map[string]any{
		"tui_launch_framework": "claude-code",
		"harnesses":            map[string]any{"claude-code": map[string]any{"args": []any{}}},
		"settlement": map[string]any{
			"enabled":                              true,
			"max_concurrency":                      float64(2),
			"batch_size":                           float64(12),
			"batch_recompute_min_interval_seconds": float64(60),
			"lease_ttl_seconds":                    float64(900),
		},
	})
	m, err := NewSettingsModel(SettingsModelOptions{
		SchemaPath:       schemaPath,
		CapabilitiesPath: capsPath,
		Store:            store,
		Runner:           &fakeRunner{},
		EnableScript:     "/fake/enable.sh",
		DisableScript:    "/fake/disable.sh",
		Registry:         NewWidgetRegistry(),
	})
	if err != nil {
		t.Fatalf("NewSettingsModel: %v", err)
	}
	m.LimitToDotPath("settlement")
	m.SetCompactEmbed(true)
	m.SetSize(120, 20)

	out := stripANSI(m.View())
	var generalLine, batchLine string
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(line, "general:"):
			generalLine = line
		case strings.HasPrefix(line, "batch:"):
			batchLine = line
		}
	}
	if batchLine == "" {
		t.Fatalf("batch controls should render on their own line, got:\n%s", out)
	}
	if !strings.Contains(batchLine, "batch size: 12") || !strings.Contains(batchLine, "batch interval: 60") {
		t.Fatalf("batch line should include size and interval, got:\n%s", out)
	}
	if strings.Contains(generalLine, "batch size") || strings.Contains(generalLine, "batch interval") {
		t.Fatalf("batch controls should not be folded into the general line, got:\n%s", out)
	}
	if !strings.Contains(generalLine, "enabled") || !strings.Contains(generalLine, "concurrency") || !strings.Contains(generalLine, "lease ttl") {
		t.Fatalf("non-batch simple controls should stay on the general line, got:\n%s", out)
	}
}

func TestLimitToDotPath_CompactEmbedFlattensNestedSettlementGroups(t *testing.T) {
	schemaPath := writeFixture(t, `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"type": "object",
		"additionalProperties": false,
		"required": ["tui_launch_framework", "harnesses"],
		"properties": {
			"tui_launch_framework": {"type": "string", "enum": ["claude-code", "codex"]},
			"harnesses": {"type": "object", "additionalProperties": false, "properties": {"claude-code": {"type": "object", "additionalProperties": false, "properties": {"args": {"type": "array", "items": {"type": "string"}}}}}},
			"settlement": {
				"type": "object",
				"additionalProperties": false,
				"properties": {
					"enabled": {"type": "boolean"},
					"max_concurrency": {"type": "integer", "minimum": 1},
					"active_hours": {
						"type": "object",
						"additionalProperties": false,
						"properties": {
							"enabled": {"type": "boolean"},
							"timezone": {"type": "string"},
							"ranges": {
								"type": "array",
								"items": {
									"type": "object",
									"additionalProperties": false,
									"properties": {
										"days": {"type": "array", "items": {"type": "string", "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]}},
										"start": {"type": "string"},
										"end": {"type": "string"}
									}
								}
							}
						}
					},
					"harness_selection": {
						"type": "object",
						"additionalProperties": false,
						"properties": {
							"mode": {"type": "string", "enum": ["random", "round_robin"]},
							"eligible_frameworks": {"type": "array", "items": {"type": "string", "enum": ["claude-code", "codex"]}, "uniqueItems": true},
							"random_seed": {"type": "string"}
						}
					}
				}
			}
		}
	}`)
	capsPath := writeMinimalCapabilities(t, []string{"claude-code", "codex"})
	store := newFakeStore(map[string]any{
		"tui_launch_framework": "claude-code",
		"harnesses":            map[string]any{"claude-code": map[string]any{"args": []any{}}},
		"settlement": map[string]any{
			"enabled":         true,
			"max_concurrency": float64(1),
			"active_hours": map[string]any{
				"enabled":  true,
				"timezone": "local",
				"ranges": []any{
					map[string]any{"days": []any{"mon", "tue", "wed", "thu", "fri"}, "start": "09:00", "end": "17:00"},
					map[string]any{"days": []any{"sat"}, "start": "10:00", "end": "14:00"},
				},
			},
			"harness_selection": map[string]any{
				"mode":                "random",
				"eligible_frameworks": []any{"claude-code", "codex"},
			},
		},
	})
	m, err := NewSettingsModel(SettingsModelOptions{
		SchemaPath:       schemaPath,
		CapabilitiesPath: capsPath,
		Store:            store,
		Runner:           &fakeRunner{},
		EnableScript:     "/fake/enable.sh",
		DisableScript:    "/fake/disable.sh",
		Registry:         NewWidgetRegistry(),
	})
	if err != nil {
		t.Fatalf("NewSettingsModel: %v", err)
	}
	m.LimitToDotPath("settlement")
	m.SetCompactEmbed(true)
	m.SetSize(140, 20)

	out := stripANSI(m.View())
	var lines []string
	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) != "" {
			lines = append(lines, line)
		}
	}
	if len(lines) > 10 {
		t.Fatalf("settlement compact embed should keep settings organized and bounded, got %d rows:\n%s", len(lines), out)
	}
	for _, want := range []string{"enabled", "active hours", "windows", "harness", "eligible"} {
		if !strings.Contains(out, want) {
			t.Fatalf("compact settlement settings missing %q:\n%s", want, out)
		}
	}
	if !strings.Contains(lines[len(lines)-2], "active hours:") || !strings.Contains(lines[len(lines)-2], "windows:") || !strings.Contains(lines[len(lines)-1], "sat 10:00-14:00") {
		t.Fatalf("active-hour windows should render last and support multiple lines, got:\n%s", out)
	}
	if strings.Contains(lines[len(lines)-3], "windows") {
		t.Fatalf("windows should be separated from the active-hours summary row, got:\n%s", out)
	}
	var activeHoursLine string
	for _, line := range lines {
		if strings.Contains(line, "active hours:") {
			activeHoursLine = line
		}
	}
	if !strings.Contains(activeHoursLine, "[x] enabled") || !strings.Contains(activeHoursLine, "timezone: local") || !strings.Contains(activeHoursLine, "windows:") {
		t.Fatalf("active-hours controls should render as one grouped row, got:\n%s", activeHoursLine)
	}
	if strings.Index(activeHoursLine, "[x] enabled") > strings.Index(activeHoursLine, "windows:") {
		t.Fatalf("active-hours enabled should precede window values on the active-hours row, got:\n%s", activeHoursLine)
	}
	eligibleIdx := -1
	harnessIdx := -1
	activeHoursIdx := -1
	for i, line := range lines {
		if strings.Contains(line, "harness:") {
			harnessIdx = i
		}
		if strings.Contains(line, "eligible:") {
			eligibleIdx = i
		}
		if strings.Contains(line, "active hours:") {
			activeHoursIdx = i
		}
	}
	if eligibleIdx <= harnessIdx {
		t.Fatalf("eligible frameworks should render as a selector block beneath harness, got:\n%s", out)
	}
	if activeHoursIdx <= eligibleIdx {
		t.Fatalf("active-hours settings should stay grouped with final windows block, got:\n%s", out)
	}
	if !strings.Contains(out, "[x] claude-code") || !strings.Contains(out, "[x] codex") {
		t.Fatalf("eligible frameworks should use checkbox selector rows, got:\n%s", out)
	}

	panel, ok := m.limitedWidget().(*ClosedObjectSubPanel)
	if !ok {
		t.Fatalf("limited widget = %T, want settlement panel", m.limitedWidget())
	}
	var gotPaths []string
	for _, control := range m.nav.compactEmbedControls(panel) {
		gotPaths = append(gotPaths, control.DotPath())
	}
	wantPaths := []string{
		"settlement.enabled",
		"settlement.max_concurrency",
		"settlement.harness_selection.mode",
		"settlement.harness_selection.random_seed",
		"settlement.harness_selection.eligible_frameworks",
		"settlement.active_hours.enabled",
		"settlement.active_hours.timezone",
		"settlement.active_hours.ranges",
	}
	if strings.Join(gotPaths, "\n") != strings.Join(wantPaths, "\n") {
		t.Fatalf("compact settlement navigation should be flat leaf controls only\ngot:\n%s\nwant:\n%s", strings.Join(gotPaths, "\n"), strings.Join(wantPaths, "\n"))
	}

	for steps := 0; steps < len(wantPaths); steps++ {
		focused := m.nav.focusedCompactControl()
		if focused != nil && focused.DotPath() == "settlement.active_hours.ranges" {
			break
		}
		_, _ = m.Update(keyMsg("j"))
	}
	if focused := m.nav.focusedCompactControl(); focused == nil || focused.DotPath() != "settlement.active_hours.ranges" {
		t.Fatalf("expected focus to reach active-hour ranges, got %v", focused)
	}
	_, _ = m.Update(keyMsg("enter"))
	for i := 0; i < 4; i++ {
		_, _ = m.Update(keyMsg("a"))
	}
	out = stripANSI(m.View())
	lines = lines[:0]
	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) != "" {
			lines = append(lines, line)
		}
	}
	if len(lines) > 10 {
		t.Fatalf("editing active-hour windows should stay bounded in compact settings, got %d rows:\n%s", len(lines), out)
	}
	if !strings.Contains(out, "[editing]") || !strings.Contains(out, "...") {
		t.Fatalf("active-hour window editor should show a bounded editing viewport with overflow, got:\n%s", out)
	}
	if strings.Contains(out, "[x] claude-code") || strings.Contains(out, "[x] codex") {
		t.Fatalf("unrelated harness selector should collapse while active-hour windows are editing, got:\n%s", out)
	}
}

func TestLimitToDotPath_CompactEmbedUnsetWindowsRenderAllTime(t *testing.T) {
	schemaPath := writeFixture(t, `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"type": "object",
		"additionalProperties": false,
		"required": ["tui_launch_framework", "harnesses"],
		"properties": {
			"tui_launch_framework": {"type": "string", "enum": ["claude-code"]},
			"harnesses": {"type": "object", "additionalProperties": false, "properties": {"claude-code": {"type": "object", "additionalProperties": false, "properties": {"args": {"type": "array", "items": {"type": "string"}}}}}},
			"settlement": {
				"type": "object",
				"additionalProperties": false,
				"properties": {
					"active_hours": {
						"type": "object",
						"additionalProperties": false,
						"properties": {
							"enabled": {"type": "boolean"},
							"timezone": {"type": "string"},
							"ranges": {
								"type": "array",
								"items": {
									"type": "object",
									"additionalProperties": false,
									"properties": {
										"days": {"type": "array", "items": {"type": "string", "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]}},
										"start": {"type": "string"},
										"end": {"type": "string"}
									}
								}
							}
						}
					}
				}
			}
		}
	}`)
	capsPath := writeMinimalCapabilities(t, []string{"claude-code"})
	store := newFakeStore(map[string]any{
		"tui_launch_framework": "claude-code",
		"harnesses":            map[string]any{"claude-code": map[string]any{"args": []any{}}},
		"settlement": map[string]any{
			"active_hours": map[string]any{
				"enabled":  true,
				"timezone": "local",
			},
		},
	})
	m, err := NewSettingsModel(SettingsModelOptions{
		SchemaPath:       schemaPath,
		CapabilitiesPath: capsPath,
		Store:            store,
		Runner:           &fakeRunner{},
		EnableScript:     "/fake/enable.sh",
		DisableScript:    "/fake/disable.sh",
		Registry:         NewWidgetRegistry(),
	})
	if err != nil {
		t.Fatalf("NewSettingsModel: %v", err)
	}
	m.LimitToDotPath("settlement")
	m.SetCompactEmbed(true)

	out := stripANSI(m.View())
	if !strings.Contains(out, "windows:") || !strings.Contains(out, "(all time)") {
		t.Fatalf("unset active-hour windows should render as all time, got:\n%s", out)
	}
	if strings.Contains(out, "09:00-17:00") {
		t.Fatalf("unset active-hour windows should not invent a weekday window, got:\n%s", out)
	}
}

// TestLimitToDotPath_CompactEmbedDescriptionSuppressionIsProfileGated pins
// that description/frame suppression belongs to the compact-embed layout
// profile, not to LimitToDotPath: the same limited model renders the section
// frame and field descriptions in full mode, and drops them in compact mode.
func TestLimitToDotPath_CompactEmbedDescriptionSuppressionIsProfileGated(t *testing.T) {
	schemaPath := writeFixture(t, `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"type": "object",
		"additionalProperties": false,
		"required": ["tui_launch_framework", "harnesses"],
		"properties": {
			"tui_launch_framework": {"type": "string", "enum": ["claude-code"]},
			"harnesses": {"type": "object", "additionalProperties": false, "properties": {"claude-code": {"type": "object", "additionalProperties": false, "properties": {"args": {"type": "array", "items": {"type": "string"}}}}}},
			"settlement": {
				"type": "object",
				"additionalProperties": false,
				"properties": {
					"enabled": {"type": "boolean", "description": "Enable explanation should not appear inline."},
					"max_concurrency": {"type": "integer", "minimum": 1, "description": "Concurrency explanation should not appear inline."}
				}
			}
		}
	}`)
	capsPath := writeMinimalCapabilities(t, []string{"claude-code"})
	store := newFakeStore(map[string]any{
		"tui_launch_framework": "claude-code",
		"harnesses":            map[string]any{"claude-code": map[string]any{"args": []any{}}},
		"settlement": map[string]any{
			"enabled":         true,
			"max_concurrency": float64(20),
		},
	})
	m, err := NewSettingsModel(SettingsModelOptions{
		SchemaPath:       schemaPath,
		CapabilitiesPath: capsPath,
		Store:            store,
		Runner:           &fakeRunner{},
		EnableScript:     "/fake/enable.sh",
		DisableScript:    "/fake/disable.sh",
		Registry:         NewWidgetRegistry(),
	})
	if err != nil {
		t.Fatalf("NewSettingsModel: %v", err)
	}
	m.LimitToDotPath("settlement")
	m.SetSize(90, 20)

	full := stripANSI(m.View())
	if !strings.Contains(full, "settlement") {
		t.Fatalf("full limited view should keep the section title, got:\n%s", full)
	}
	if !strings.Contains(full, "explanation") {
		t.Fatalf("full limited view should render field descriptions, got:\n%s", full)
	}

	m.SetCompactEmbed(true)
	compact := stripANSI(m.View())
	if strings.Contains(compact, "explanation") || strings.Contains(compact, "settlement") {
		t.Fatalf("compact embed should suppress descriptions and host-owned title, got:\n%s", compact)
	}
	if strings.Contains(compact, "╭") || strings.Contains(compact, "│") {
		t.Fatalf("compact embed should omit the section frame, got:\n%s", compact)
	}
}

// TestLimitToDotPath_CompactEmbedEditingManyWindowsCentersCursorWithOverflowCounts
// pins the bounded window-editing viewport: with more windows than fit the
// compact allowance, edit mode shows a cursor-centered slice with explicit
// "... N earlier" / "... N later" overflow counts, and the embed never closes
// on Esc.
func TestLimitToDotPath_CompactEmbedEditingManyWindowsCentersCursorWithOverflowCounts(t *testing.T) {
	schemaPath := writeFixture(t, `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"type": "object",
		"additionalProperties": false,
		"required": ["tui_launch_framework", "harnesses"],
		"properties": {
			"tui_launch_framework": {"type": "string", "enum": ["claude-code"]},
			"harnesses": {"type": "object", "additionalProperties": false, "properties": {"claude-code": {"type": "object", "additionalProperties": false, "properties": {"args": {"type": "array", "items": {"type": "string"}}}}}},
			"settlement": {
				"type": "object",
				"additionalProperties": false,
				"properties": {
					"active_hours": {
						"type": "object",
						"additionalProperties": false,
						"properties": {
							"enabled": {"type": "boolean"},
							"timezone": {"type": "string"},
							"ranges": {
								"type": "array",
								"items": {
									"type": "object",
									"additionalProperties": false,
									"properties": {
										"days": {"type": "array", "items": {"type": "string", "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]}},
										"start": {"type": "string"},
										"end": {"type": "string"}
									}
								}
							}
						}
					}
				}
			}
		}
	}`)
	capsPath := writeMinimalCapabilities(t, []string{"claude-code"})
	days := []string{"mon", "tue", "wed", "thu", "fri", "sat", "sun"}
	ranges := make([]any, 0, len(days))
	for i, d := range days {
		ranges = append(ranges, map[string]any{
			"days":  []any{d},
			"start": fmt.Sprintf("%02d:00", i+1),
			"end":   fmt.Sprintf("%02d:00", i+2),
		})
	}
	store := newFakeStore(map[string]any{
		"tui_launch_framework": "claude-code",
		"harnesses":            map[string]any{"claude-code": map[string]any{"args": []any{}}},
		"settlement": map[string]any{
			"active_hours": map[string]any{
				"enabled":  true,
				"timezone": "local",
				"ranges":   ranges,
			},
		},
	})
	m, err := NewSettingsModel(SettingsModelOptions{
		SchemaPath:       schemaPath,
		CapabilitiesPath: capsPath,
		Store:            store,
		Runner:           &fakeRunner{},
		EnableScript:     "/fake/enable.sh",
		DisableScript:    "/fake/disable.sh",
		Registry:         NewWidgetRegistry(),
	})
	if err != nil {
		t.Fatalf("NewSettingsModel: %v", err)
	}
	m.LimitToDotPath("settlement")
	m.SetCompactEmbed(true)
	m.SetSize(140, 20)

	// Auto-enter focuses the first deferred control (active_hours.enabled);
	// two steps land on the windows editor.
	_, _ = m.Update(keyMsg("j"))
	_, _ = m.Update(keyMsg("j"))
	out := stripANSI(m.View())
	if !strings.Contains(out, "[edit]") {
		t.Fatalf("focused windows control should advertise the [edit] entry cue, got:\n%s", out)
	}

	_, _ = m.Update(keyMsg("enter"))
	if !m.FocusConsumesRunes() {
		t.Fatal("window editing should consume nav runes")
	}
	out = stripANSI(m.View())
	if !strings.Contains(out, "[editing]") || !strings.Contains(out, "(7 windows)") {
		t.Fatalf("edit mode should show the editing cue and total window count, got:\n%s", out)
	}
	if !strings.Contains(out, "later") || strings.Contains(out, "earlier") {
		t.Fatalf("with the cursor on the first window only a later-overflow marker should render, got:\n%s", out)
	}

	// Three editable fields per window: nine j presses move the cursor from
	// window 0 to window 3 (the 04:00 window).
	for i := 0; i < 9; i++ {
		_, _ = m.Update(keyMsg("j"))
	}
	out = stripANSI(m.View())
	if !strings.Contains(out, "... 2 earlier") || !strings.Contains(out, "... 2 later") {
		t.Fatalf("mid-list cursor should produce both overflow markers, got:\n%s", out)
	}
	cursorLine := ""
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, ">") {
			cursorLine = line
			break
		}
	}
	if !strings.Contains(cursorLine, "04:00") {
		t.Fatalf("cursor should sit on the fourth window (04:00), got cursor line %q in:\n%s", cursorLine, out)
	}

	_, _ = m.Update(keyMsg("esc"))
	if m.FocusConsumesRunes() {
		t.Fatal("Esc should exit window editing")
	}
	if m.Closed() {
		t.Fatal("Esc must not close the embedded panel while discarding an edit")
	}
	_, _ = m.Update(keyMsg("esc"))
	if m.Closed() {
		t.Fatal("top-level Esc must never close the compact embed")
	}
}

// TestLimitToDotPath_CompactEmbedNavigationStaysWiredAfterImmediateCommit pins
// that an immediate-commit leaf (ToggleRow) keeps the auto-entered container
// navigable: after space commits the toggle, j still moves focus to the next
// control instead of being swallowed by an unfocused container.
func TestLimitToDotPath_CompactEmbedNavigationStaysWiredAfterImmediateCommit(t *testing.T) {
	schemaPath := writeFixture(t, `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"type": "object",
		"additionalProperties": false,
		"required": ["tui_launch_framework", "harnesses"],
		"properties": {
			"tui_launch_framework": {"type": "string", "enum": ["claude-code"]},
			"harnesses": {"type": "object", "additionalProperties": false, "properties": {"claude-code": {"type": "object", "additionalProperties": false, "properties": {"args": {"type": "array", "items": {"type": "string"}}}}}},
			"settlement": {
				"type": "object",
				"additionalProperties": false,
				"properties": {
					"enabled": {"type": "boolean"},
					"max_concurrency": {"type": "integer", "minimum": 1}
				}
			}
		}
	}`)
	capsPath := writeMinimalCapabilities(t, []string{"claude-code"})
	store := newFakeStore(map[string]any{
		"tui_launch_framework": "claude-code",
		"harnesses":            map[string]any{"claude-code": map[string]any{"args": []any{}}},
		"settlement": map[string]any{
			"enabled":         true,
			"max_concurrency": float64(20),
		},
	})
	m, err := NewSettingsModel(SettingsModelOptions{
		SchemaPath:       schemaPath,
		CapabilitiesPath: capsPath,
		Store:            store,
		Runner:           &fakeRunner{},
		EnableScript:     "/fake/enable.sh",
		DisableScript:    "/fake/disable.sh",
		Registry:         NewWidgetRegistry(),
	})
	if err != nil {
		t.Fatalf("NewSettingsModel: %v", err)
	}
	m.LimitToDotPath("settlement")
	m.SetCompactEmbed(true)
	m.SetSize(120, 20)

	_, _ = m.Update(keyMsg("space"))
	if len(store.patches) != 1 || store.patches[0].dotPath != "settlement.enabled" || store.patches[0].value != false {
		t.Fatalf("space should immediately commit the toggle, got patches %+v", store.patches)
	}

	_, _ = m.Update(keyMsg("j"))
	out := stripANSI(m.View())
	if !strings.Contains(out, "concurrency: 20 [edit]") {
		t.Fatalf("j after a commit should focus the next control, got:\n%s", out)
	}
}

// TestLimitToDotPath_CompactEmbedDeferredOnlyPanelEmitsNoSummaryRow pins that
// a nested panel whose content is entirely deferred (active-hours windows
// with no sibling leaf controls) contributes no bare header row — the embed
// renders only the merged windows block, with no empty padding lines.
func TestLimitToDotPath_CompactEmbedDeferredOnlyPanelEmitsNoSummaryRow(t *testing.T) {
	schemaPath := writeFixture(t, `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"type": "object",
		"additionalProperties": false,
		"required": ["tui_launch_framework", "harnesses"],
		"properties": {
			"tui_launch_framework": {"type": "string", "enum": ["claude-code"]},
			"harnesses": {"type": "object", "additionalProperties": false, "properties": {"claude-code": {"type": "object", "additionalProperties": false, "properties": {"args": {"type": "array", "items": {"type": "string"}}}}}},
			"settlement": {
				"type": "object",
				"additionalProperties": false,
				"properties": {
					"active_hours": {
						"type": "object",
						"additionalProperties": false,
						"properties": {
							"ranges": {
								"type": "array",
								"items": {
									"type": "object",
									"additionalProperties": false,
									"properties": {
										"days": {"type": "array", "items": {"type": "string", "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]}},
										"start": {"type": "string"},
										"end": {"type": "string"}
									}
								}
							}
						}
					}
				}
			}
		}
	}`)
	capsPath := writeMinimalCapabilities(t, []string{"claude-code"})
	store := newFakeStore(map[string]any{
		"tui_launch_framework": "claude-code",
		"harnesses":            map[string]any{"claude-code": map[string]any{"args": []any{}}},
		"settlement": map[string]any{
			"active_hours": map[string]any{
				"ranges": []any{
					map[string]any{"days": []any{"mon"}, "start": "09:00", "end": "17:00"},
					map[string]any{"days": []any{"sat"}, "start": "10:00", "end": "14:00"},
				},
			},
		},
	})
	m, err := NewSettingsModel(SettingsModelOptions{
		SchemaPath:       schemaPath,
		CapabilitiesPath: capsPath,
		Store:            store,
		Runner:           &fakeRunner{},
		EnableScript:     "/fake/enable.sh",
		DisableScript:    "/fake/disable.sh",
		Registry:         NewWidgetRegistry(),
	})
	if err != nil {
		t.Fatalf("NewSettingsModel: %v", err)
	}
	m.LimitToDotPath("settlement")
	m.SetCompactEmbed(true)
	m.SetSize(120, 20)

	out := stripANSI(m.View())
	var lines []string
	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) != "" {
			lines = append(lines, line)
		}
	}
	if len(lines) != 2 {
		t.Fatalf("deferred-only panel should render exactly the two window lines, got %d:\n%s", len(lines), out)
	}
	if !strings.Contains(lines[0], "active hours:") || !strings.Contains(lines[0], "windows:") || !strings.Contains(lines[0], "mon 09:00-17:00") {
		t.Fatalf("first line should be the merged active-hours windows row, got:\n%s", out)
	}
	if !strings.Contains(lines[1], "sat 10:00-14:00") {
		t.Fatalf("second window should render as an indented continuation, got:\n%s", out)
	}
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "active hours:" || strings.HasPrefix(trimmed, "general:") {
			t.Fatalf("deferred-only panel must not emit a bare summary or general row, got:\n%s", out)
		}
	}
}

// TestAgentToggleAsyncResult_ReloadsEffective verifies the post-shell-out
// reconciliation: when the agent-toggle command resolves, the model
// re-reads settings.json so the cached effective document reflects what
// the script wrote.
func TestHarnessToggleAsyncResult_ReloadsEffective(t *testing.T) {
	m, store, _ := newTestModel(t, map[string]any{
		"harnesses": map[string]any{
			"claude-code": map[string]any{
				"args":    []any{},
				"enabled": false,
			},
		},
	})

	// Simulate enable.sh writing harnesses.claude-code.enabled=true to the store.
	if err := setDotPath(store.doc, "harnesses.claude-code.enabled", true); err != nil {
		t.Fatalf("seed store: %v", err)
	}

	// Drive the harness-toggle result message into the model.
	_, _ = m.Update(harnessToggleResultMsg{
		framework: "claude-code",
		enabled:   true,
		stderr:    "",
	})

	// The model should have re-loaded and rebuilt widgets. We check that
	// the cached effective at harnesses.claude-code.enabled now reads true.
	v, present := m.lookupEffective("harnesses.claude-code.enabled")
	if !present {
		t.Errorf("expected harnesses.claude-code.enabled present after reload")
	}
	if b, _ := v.(bool); !b {
		t.Errorf("expected harnesses.claude-code.enabled=true after reload, got %v", v)
	}
}

func TestHarnessToggleAsyncResult_ReconcilesRegisteredPanel(t *testing.T) {
	m, store, _ := newTestModel(t, map[string]any{
		"harnesses": map[string]any{
			"claude-code": map[string]any{
				"args":    []any{},
				"enabled": true,
			},
		},
	})
	args := NewListEditor("harnesses.claude-code.args", "args", []string{}, nil, 0, false, true, false)
	panel := NewHarnessBlockPanel("claude-code", true, nil, args, nil, nil, HarnessEffective{})
	m.RegisterTopSection("harness claude-code", panel)

	if err := setDotPath(store.doc, "harnesses.claude-code.enabled", false); err != nil {
		t.Fatalf("seed store: %v", err)
	}
	_, _ = m.Update(harnessToggleResultMsg{
		framework: "claude-code",
		enabled:   false,
	})

	if panel.Enabled() {
		t.Fatalf("registered harness panel did not reconcile to disk enabled=false")
	}
}

func TestHarnessToggleAsyncResult_RollsBackRegisteredPanelOnError(t *testing.T) {
	m, _, _ := newTestModel(t, map[string]any{
		"harnesses": map[string]any{
			"claude-code": map[string]any{
				"args":    []any{},
				"enabled": true,
			},
		},
	})
	args := NewListEditor("harnesses.claude-code.args", "args", []string{}, nil, 0, false, true, false)
	// Simulate the optimistic checkbox already flipped off before the
	// shell-out failure returns.
	panel := NewHarnessBlockPanel("claude-code", false, nil, args, nil, nil, HarnessEffective{})
	m.RegisterTopSection("harness claude-code", panel)

	_, _ = m.Update(harnessToggleResultMsg{
		framework: "claude-code",
		enabled:   false,
		err:       errors.New("boom"),
	})

	if !panel.Enabled() {
		t.Fatalf("failed toggle should reconcile/roll back panel to disk enabled=true")
	}
}

// TestDescriptionsByDotPath_AppliedToWidgets verifies the host-supplied
// description override (DescriptionsByDotPath) reaches the rendered widget,
// taking precedence over the schema's own description string. This is the
// load-bearing seam for surfacing capabilities.json / roles.json text in the
// configurator — without it, all 15 capability_overrides rows would share the
// same generic "support_level" description from the schema $def.
func TestDescriptionsByDotPath_AppliedToWidgets(t *testing.T) {
	schemaPath := writeFixture(t, `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"type": "object",
		"additionalProperties": false,
		"required": ["version", "tui_launch_framework", "harnesses"],
		"properties": {
			"version": {"type": "integer", "minimum": 1},
			"tui_launch_framework": {"type": "string", "enum": ["claude-code"]},
			"harnesses": {
				"type": "object",
				"additionalProperties": false,
				"properties": {"claude-code": {"type": "object", "additionalProperties": false, "properties": {"args": {"type": "array", "items": {"type": "string"}}}}}
			},
			"flag": {"type": "boolean", "description": "schema-default flag description"}
		}
	}`)
	capsPath := writeMinimalCapabilities(t, []string{"claude-code"})
	store := newFakeStore(nil)
	runner := &fakeRunner{}
	m, err := NewSettingsModel(SettingsModelOptions{
		SchemaPath:       schemaPath,
		CapabilitiesPath: capsPath,
		Store:            store,
		Runner:           runner,
		EnableScript:     "/fake/enable.sh",
		DisableScript:    "/fake/disable.sh",
		Registry:         NewWidgetRegistry(),
		DescriptionsByDotPath: map[string]string{
			"flag": "host-supplied flag description (e.g. from capabilities.json)",
		},
	})
	if err != nil {
		t.Fatalf("NewSettingsModel: %v", err)
	}

	// Find the `flag` widget and assert its rendered description matches the
	// host-supplied override, not the schema-default text.
	var got *ToggleRow
	for _, w := range m.widgets {
		if w.DotPath() == "flag" {
			got, _ = w.(*ToggleRow)
			break
		}
	}
	if got == nil {
		t.Fatalf("flag widget not in walker output")
	}
	got.SetWrapWidth(80)
	out := got.View()
	if !strings.Contains(out, "host-supplied flag description") {
		t.Errorf("expected host description in render, got:\n%s", out)
	}
	if strings.Contains(out, "schema-default flag description") {
		t.Errorf("schema description leaked through despite host override:\n%s", out)
	}
}

// TestSetSize_PropagatesWrapWidthToWidgets confirms that SetSize forwards a
// non-zero wrap width to every widget that implements WidthSetter, including
// children of ClosedObjectSubPanel. Without this, descriptions would render
// at the default wrap (72) regardless of how wide the host modal is.
func TestSetSize_PropagatesWrapWidthToWidgets(t *testing.T) {
	m, _, _ := newTestModel(t, nil)

	m.SetSize(96, 30)

	// Find a top-level widget with a WidthSetter and verify its width was set.
	// Each widget under the schema-driven walker is a concrete *settings.X
	// type; the assertions peek into the relevant fields directly rather than
	// going through the WidthSetter interface (which has no getter).
	var checked int
	for _, w := range m.widgets {
		switch v := w.(type) {
		case *ToggleRow:
			if v.wrapWidth != 96 {
				t.Errorf("ToggleRow wrapWidth = %d, want 96", v.wrapWidth)
			}
			checked++
		case *ClosedObjectSubPanel:
			if v.wrapWidth != 96 {
				t.Errorf("ClosedObjectSubPanel wrapWidth = %d, want 96", v.wrapWidth)
			}
			// Children should receive 96 - 2 (panel indent allowance).
			for _, c := range v.children {
				if tr, ok := c.(*TextInput); ok && tr.wrapWidth != 94 {
					t.Errorf("nested TextInput wrapWidth = %d, want 94 (96-2)", tr.wrapWidth)
				}
			}
			checked++
		}
	}
	if checked == 0 {
		t.Fatalf("no widgets exercised the wrap-width propagation path")
	}
}

func TestHierarchicalNavigation_JKMovesTopLevelUntilEnter(t *testing.T) {
	m, _, _ := newTestModel(t, nil)

	args := NewListEditor("harnesses.claude-code.args", "args", []string{"--alpha"}, nil, 0, false, true, false)
	panel1 := NewHarnessBlockPanel("claude-code", true, nil, args, nil, nil, HarnessEffective{})
	args2 := makeArgsWidget("harnesses.codex.args", []string{})
	panel2 := NewHarnessBlockPanel("codex", true, nil, args2, nil, nil, HarnessEffective{})
	m.RegisterTopSection("harness claude-code", panel1)
	m.RegisterTopSection("harness codex", panel2)

	_, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if m.nav.focusIdx != 0 {
		t.Fatalf("first j should focus the first top-level section, got %d", m.nav.focusIdx)
	}
	_, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if m.nav.focusIdx != 1 {
		t.Fatalf("second j should move to the next top-level section before enter, got %d", m.nav.focusIdx)
	}
	if panel1.entered || panel1.cursor != 0 {
		t.Fatalf("unentered panel should not move its inner cursor; entered=%v cursor=%d", panel1.entered, panel1.cursor)
	}
	_, _ = m.Update(tea.KeyPressMsg{Code: 'k', Text: "k"})
	if m.nav.focusIdx != 0 {
		t.Fatalf("k should move back to the previous top-level section, got %d", m.nav.focusIdx)
	}
}

func TestHierarchicalNavigation_EnterDescendsOneLevel(t *testing.T) {
	m, _, _ := newTestModel(t, nil)

	args := NewListEditor("harnesses.claude-code.args", "args", []string{"--alpha"}, nil, 0, false, true, false)
	roles := NewOpenKeysetKVEditor("harnesses.claude-code.roles", "roles", map[string]string{"lead": "opus"}, nil, nil, true, true)
	panel := NewHarnessBlockPanel("claude-code", true, nil, args, roles, nil, HarnessEffective{})
	m.RegisterTopSection("harness claude-code", panel)

	_, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	_, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if !panel.entered {
		t.Fatalf("enter should open the focused harness panel")
	}
	if c, _ := panel.childAt(0); c == nil || !c.Focused() {
		t.Fatalf("enter should focus the first child, got %T focused=%v", c, c != nil && c.Focused())
	}

	_, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if panel.cursor != 1 {
		t.Fatalf("j inside an entered panel should move to args, got cursor=%d", panel.cursor)
	}
	if !args.Focused() || args.editing {
		t.Fatalf("args should be selected but not editing; focused=%v editing=%v", args.Focused(), args.editing)
	}
	_, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if panel.cursor != 2 {
		t.Fatalf("j from a selected list should move to roles, not inside the list; cursor=%d", panel.cursor)
	}
}

func TestHierarchicalNavigation_NestedClosedObjectRequiresRepeatedEnter(t *testing.T) {
	const nestedSchema = `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"type": "object",
		"additionalProperties": false,
		"required": ["version", "tui_launch_framework", "harnesses"],
		"properties": {
			"version": {"type": "integer", "minimum": 1},
			"tui_launch_framework": {"type": "string", "enum": ["claude-code"]},
			"harnesses": {
				"type": "object",
				"additionalProperties": false,
				"properties": {
					"claude-code": {
						"type": "object",
						"additionalProperties": false,
						"properties": {"args": {"type": "array", "items": {"type": "string"}}}
					}
				}
			},
			"tuning": {
				"type": "object",
				"additionalProperties": false,
				"properties": {
					"core": {
						"type": "object",
						"additionalProperties": false,
						"properties": {
							"alpha": {"type": "integer", "minimum": 0},
							"beta":  {"type": "integer", "minimum": 0}
						}
					},
					"adaptive": {"type": "boolean"}
				}
		}
	}
}`
	seed := func() map[string]any {
		return map[string]any{
			"tuning": map[string]any{
				"core":     map[string]any{"alpha": 1.0, "beta": 2.0},
				"adaptive": false,
			},
		}
	}

	build := func(t *testing.T) (*SettingsModel, *ClosedObjectSubPanel, *ClosedObjectSubPanel, int) {
		t.Helper()
		schemaPath := writeFixture(t, nestedSchema)
		capsPath := writeMinimalCapabilities(t, []string{"claude-code"})
		m, err := NewSettingsModel(SettingsModelOptions{
			SchemaPath:       schemaPath,
			CapabilitiesPath: capsPath,
			Store:            newFakeStore(seed()),
			Runner:           &fakeRunner{},
			EnableScript:     "/fake/enable.sh",
			DisableScript:    "/fake/disable.sh",
			Registry:         NewWidgetRegistry(),
		})
		if err != nil {
			t.Fatalf("NewSettingsModel: %v", err)
		}
		slots := m.allWidgetSlots()
		tuningIdx := -1
		for i, w := range slots {
			if w.DotPath() == "tuning" {
				tuningIdx = i
				break
			}
		}
		if tuningIdx < 0 {
			t.Fatalf("tuning not registered as a top-level slot; slots: %+v", slotPaths(slots))
		}
		tuning, ok := slots[tuningIdx].(*ClosedObjectSubPanel)
		if !ok {
			t.Fatalf("tuning is not a ClosedObjectSubPanel: %T", slots[tuningIdx])
		}
		core, ok := tuning.children[0].(*ClosedObjectSubPanel)
		if !ok {
			t.Fatalf("tuning.children[0] is not a ClosedObjectSubPanel (core): %T", tuning.children[0])
		}
		return m, tuning, core, tuningIdx
	}

	walkTo := func(m *SettingsModel, tuningIdx int, key tea.KeyPressMsg) {
		guard := 0
		for m.nav.focusIdx != tuningIdx {
			_, _ = m.Update(key)
			guard++
			if guard > 50 {
				return // safety: caller asserts the post-condition
			}
		}
	}

	m, tuning, core, tuningIdx := build(t)
	jKey := tea.KeyPressMsg{Code: 'j', Text: "j"}
	walkTo(m, tuningIdx, jKey)
	if tuning.entered || core.focused {
		t.Fatalf("focused tuning should not auto-enter children; tuning.entered=%v core.focused=%v", tuning.entered, core.focused)
	}

	_, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if !tuning.entered || !core.focused || core.entered {
		t.Fatalf("first enter should open tuning and select core only; tuning.entered=%v core.focused=%v core.entered=%v", tuning.entered, core.focused, core.entered)
	}
	_, _ = m.Update(jKey)
	if tuning.cursor != 1 || core.cursor != 0 {
		t.Fatalf("j after first enter should move tuning core→adaptive, not core alpha→beta; tuning.cursor=%d core.cursor=%d", tuning.cursor, core.cursor)
	}
	_, _ = m.Update(tea.KeyPressMsg{Code: 'k', Text: "k"})
	_, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if !core.entered {
		t.Fatalf("second enter should open nested core")
	}
	_, _ = m.Update(jKey)
	if tuning.cursor != 0 || core.cursor != 1 {
		t.Fatalf("j inside entered core should move alpha→beta; tuning.cursor=%d core.cursor=%d", tuning.cursor, core.cursor)
	}

	beta, ok := core.children[1].(*NumericInput)
	if !ok {
		t.Fatalf("core.children[1] is not a NumericInput (beta): %T", core.children[1])
	}
	_, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	_, _ = m.Update(tea.KeyPressMsg{Code: '9', Text: "9"})
	if beta.draft != "29" {
		t.Fatalf("typing after the leaf enter should reach beta; draft=%q", beta.draft)
	}
}

func TestHierarchicalNavigation_EscBacksOutOneLevel(t *testing.T) {
	m, _, _ := newTestModel(t, nil)

	args := NewListEditor("harnesses.claude-code.args", "args", []string{"--alpha"}, nil, 0, false, true, false)
	panel := NewHarnessBlockPanel("claude-code", true, nil, args, nil, nil, HarnessEffective{})
	m.RegisterTopSection("harness claude-code", panel)

	_, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	_, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	_, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	_, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if !panel.entered || !args.editing {
		t.Fatalf("setup expected entered panel and editing args; panel.entered=%v args.editing=%v", panel.entered, args.editing)
	}

	_, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	if m.Closed() || !panel.entered || args.editing {
		t.Fatalf("first esc should leave list edit mode only; closed=%v panel.entered=%v args.editing=%v", m.Closed(), panel.entered, args.editing)
	}
	_, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	if m.Closed() || panel.entered {
		t.Fatalf("second esc should back out of the panel only; closed=%v panel.entered=%v", m.Closed(), panel.entered)
	}
	_, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	if !m.Closed() {
		t.Fatalf("third esc at the outer boundary should close the settings modal")
	}
}

func TestHierarchicalNavigation_FocusConsumesRunesOnlyInLeafEditMode(t *testing.T) {
	m, _, _ := newTestModel(t, nil)

	args := NewListEditor("harnesses.claude-code.args", "args", []string{"--alpha"}, nil, 0, false, true, false)
	panel := NewHarnessBlockPanel("claude-code", true, nil, args, nil, nil, HarnessEffective{})
	m.RegisterTopSection("harness claude-code", panel)

	_, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if m.FocusConsumesRunes() {
		t.Fatalf("selected but unopened panel should let q/j/k remain global/settings navigation")
	}
	_, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	_, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if m.FocusConsumesRunes() {
		t.Fatalf("selected list row should not consume q/j/k before edit mode")
	}
	_, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if !m.FocusConsumesRunes() {
		t.Fatalf("list edit mode should consume q/j/k so q can be typed instead of quitting")
	}
	_, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	if m.FocusConsumesRunes() {
		t.Fatalf("after leaving edit mode, q should be available to quit again")
	}
}

func TestHierarchicalNavigation_StringFieldsUseNavModeUntilEditing(t *testing.T) {
	schemaPath := writeFixture(t, `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"type": "object",
		"additionalProperties": false,
		"required": ["version", "tui_launch_framework", "harnesses"],
		"properties": {
			"version": {"type": "integer", "minimum": 1},
			"tui_launch_framework": {"type": "string", "enum": ["claude-code"]},
			"harnesses": {
				"type": "object",
				"additionalProperties": false,
				"properties": {"claude-code": {"type": "object", "additionalProperties": false, "properties": {"args": {"type": "array", "items": {"type": "string"}}}}}
			},
			"models": {
				"type": "object",
				"additionalProperties": false,
				"properties": {
					"lead": {"type": "string"},
					"worker": {"type": "string"}
				}
			}
		}
	}`)
	capsPath := writeMinimalCapabilities(t, []string{"claude-code"})
	m, err := NewSettingsModel(SettingsModelOptions{
		SchemaPath:       schemaPath,
		CapabilitiesPath: capsPath,
		Store: newFakeStore(map[string]any{
			"version":              float64(1),
			"tui_launch_framework": "claude-code",
			"harnesses":            map[string]any{"claude-code": map[string]any{"args": []any{}}},
			"models":               map[string]any{"lead": "opus", "worker": "sonnet"},
		}),
		Runner:        &fakeRunner{},
		EnableScript:  "/fake/enable.sh",
		DisableScript: "/fake/disable.sh",
		Registry:      NewWidgetRegistry(),
	})
	if err != nil {
		t.Fatalf("NewSettingsModel: %v", err)
	}
	slots := m.allWidgetSlots()
	if len(slots) != 1 {
		t.Fatalf("expected one visible models slot, got %v", slotPaths(slots))
	}
	models, ok := slots[0].(*ClosedObjectSubPanel)
	if !ok {
		t.Fatalf("models slot is %T, want ClosedObjectSubPanel", slots[0])
	}

	_, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if models.entered {
		t.Fatalf("j should select the models section without entering it")
	}
	_, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if models.cursor != 0 {
		t.Fatalf("enter should focus models.lead without stepping past it; cursor=%d", models.cursor)
	}
	lead := models.children[0].(*TextInput)
	if !lead.focused || lead.editing {
		t.Fatalf("lead should be selected but not editing; focused=%v editing=%v", lead.focused, lead.editing)
	}

	_, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if models.cursor != 1 {
		t.Fatalf("second j should move from lead to worker, not type into lead; cursor=%d lead.draft=%q", models.cursor, lead.draft)
	}
	worker := models.children[1].(*TextInput)
	if !worker.focused || worker.editing {
		t.Fatalf("worker should be selected but not editing; focused=%v editing=%v", worker.focused, worker.editing)
	}

	_, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if !worker.editing {
		t.Fatalf("Enter should put selected worker field into edit mode")
	}
	_, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if worker.draft != "sonnetj" {
		t.Fatalf("j should be literal input while editing worker; draft=%q", worker.draft)
	}
}

// slotPaths is a small debug helper for the nested-navigation test — returns
// the dot-paths of each top-level slot so a failure message points at why
// a panel was missing.
func slotPaths(slots []FieldWidget) []string {
	out := make([]string, 0, len(slots))
	for _, w := range slots {
		out = append(out, w.DotPath())
	}
	return out
}

// TestComputeFocusedYRange_AlignsWithRenderedBody verifies that the y-range
// reported for a focused slot matches the actual line number of the slot in
// the rendered body. Regression coverage for an off-by-one bug where the
// joiner between slots ("\n\n") was counted as 2 lines instead of 1, drifting
// the focused range one line further down per preceding slot. With several
// slots, the drift pushed the focused row off-screen and ensureFocusedVisible
// pinned the viewport on the wrong line — manifesting as "the cursor
// disappears and pressing k doesn't bring it back" because each k retreats
// only one over-shoot at a time.
func TestComputeFocusedYRange_AlignsWithRenderedBody(t *testing.T) {
	m, _, _ := newTestModel(t, nil)

	// Register a handful of top sections so the body has multiple slots
	// joined by "\n\n". Three is enough to exercise the drift math.
	for _, fw := range []string{"alpha", "beta", "gamma"} {
		args := makeArgsWidget("harnesses."+fw+".args", []string{})
		panel := NewHarnessBlockPanel(fw, true, nil, args, nil, nil, HarnessEffective{})
		m.RegisterTopSection("harness "+fw, panel)
	}

	body := m.renderBodyContent()
	bodyLines := strings.Split(body, "\n")

	// For each top-level slot, focus it and verify computeFocusedYRange's
	// returned [top, bottom] points at lines that actually contain the
	// expected harness header. Without the joiner-fix, the second slot's
	// reported `top` would land on a blank line; the third slot's would
	// land beyond the slot entirely.
	for slotIdx, want := range []string{"alpha", "beta", "gamma"} {
		m.nav.focusIdx = slotIdx
		// The HarnessBlockPanel reports an inner cursor range; for this
		// alignment check we want the slot-wide range, so blur the panel
		// (clears its `focused` flag and InnerFocusYRange returns -1,-1).
		if p, ok := m.allWidgetSlots()[slotIdx].(*HarnessBlockPanel); ok {
			_ = p.Blur()
		}
		top, bottom := m.computeFocusedYRange()
		if top < 0 || bottom < 0 {
			t.Fatalf("slot %d (%s): expected valid range, got (%d,%d)", slotIdx, want, top, bottom)
		}
		if top >= len(bodyLines) || bottom >= len(bodyLines) {
			t.Fatalf("slot %d (%s): range (%d,%d) exceeds body line count %d", slotIdx, want, top, bottom, len(bodyLines))
		}
		// The header line ("╭─ harness <name> ...") must be inside [top,bot].
		found := false
		for i := top; i <= bottom; i++ {
			if strings.Contains(bodyLines[i], "harness "+want) {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("slot %d (%s): no 'harness %s' header in body lines [%d..%d]; lines:\n%s",
				slotIdx, want, want, top, bottom, strings.Join(bodyLines[top:bottom+1], "\n"))
		}
	}
}

// TestHarnessToggleStderrSurfaces_NoticesCount verifies the stderr surfacing
// rule (sharp-edges Q2 → option C with twist): the status line includes a
// notice count when stderr is non-empty, and is silent on clean success.
func TestHarnessToggleStderrSurfaces_NoticesCount(t *testing.T) {
	m, _, _ := newTestModel(t, nil)

	// Clean run.
	_, _ = m.Update(harnessToggleResultMsg{framework: "claude-code", enabled: true, stderr: ""})
	if strings.Contains(m.statusMsg, "notices") {
		t.Errorf("clean stderr should not show notice count, got %q", m.statusMsg)
	}

	// Run with two stderr notices.
	_, _ = m.Update(harnessToggleResultMsg{
		framework: "claude-code",
		enabled:   true,
		stderr:    "harness-enable: skill-X conflict (left as-is)\nharness-enable: skill-Y conflict (left as-is)\n",
	})
	if !strings.Contains(m.statusMsg, "2 notices") {
		t.Errorf("expected '2 notices' in status, got %q", m.statusMsg)
	}
}

// Status-bar contract "PgUp/PgDn scroll": the configurator routes page keys
// to its viewport even while a widget has focus.
func TestPgDnPgUpScrollViewport(t *testing.T) {
	m, _, _ := newTestModel(t, nil)
	// Small viewport so the widget tree overflows and scrolling has room.
	m.SetSize(80, 6)
	_ = m.View() // View populates the viewport content
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyHome})
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyPgDown})
	if m.viewport.YOffset() == 0 {
		t.Fatal("PgDn should scroll the settings viewport down")
	}
	down := m.viewport.YOffset()
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyPgUp})
	if m.viewport.YOffset() >= down {
		t.Error("PgUp should scroll the settings viewport back up")
	}
}
