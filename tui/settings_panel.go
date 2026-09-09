package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/settings"
)

// hostSettingsStore adapts tui/internal/config Settings{Get,Patch,Delete} to
// the settings.SettingsStore interface. The settings package owns the
// interface; defining the production impl in package main keeps the
// internal/settings package free of any tui/internal/config dependency
// (mirrors the body-vs-chrome split per D2).
type hostSettingsStore struct{}

func (hostSettingsStore) LoadAll() (map[string]any, error) {
	return config.LoadSettingsDocument()
}

func (hostSettingsStore) Patch(dotPath string, value any) error {
	doc, err := config.LoadSettingsDocument()
	if err != nil {
		return err
	}
	candidate, err := cloneSettingsDocument(doc)
	if err != nil {
		return err
	}
	setDocumentPath(candidate, dotPath, value)
	if err := config.ValidateRoutingSettings(candidate); err != nil {
		return fmt.Errorf("settings validation refused edit: %w", err)
	}
	return config.SettingsPatch(dotPath, value)
}

func (hostSettingsStore) Delete(dotPath string) error {
	doc, err := config.LoadSettingsDocument()
	if err != nil {
		return err
	}
	candidate, err := cloneSettingsDocument(doc)
	if err != nil {
		return err
	}
	deleteDocumentPath(candidate, dotPath)
	if err := config.ValidateRoutingSettings(candidate); err != nil {
		return fmt.Errorf("settings validation refused edit: %w", err)
	}
	return config.SettingsDelete(dotPath)
}

func cloneSettingsDocument(doc map[string]any) (map[string]any, error) {
	raw, err := json.Marshal(doc)
	if err != nil {
		return nil, err
	}
	var clone map[string]any
	if err := json.Unmarshal(raw, &clone); err != nil {
		return nil, err
	}
	return clone, nil
}

func setDocumentPath(doc map[string]any, dotPath string, value any) {
	parts := strings.Split(dotPath, ".")
	node := doc
	for _, part := range parts[:len(parts)-1] {
		next, ok := node[part].(map[string]any)
		if !ok {
			next = map[string]any{}
			node[part] = next
		}
		node = next
	}
	node[parts[len(parts)-1]] = value
}

func deleteDocumentPath(doc map[string]any, dotPath string) {
	parts := strings.Split(dotPath, ".")
	node := doc
	for _, part := range parts[:len(parts)-1] {
		next, ok := node[part].(map[string]any)
		if !ok {
			return
		}
		node = next
	}
	delete(node, parts[len(parts)-1])
}

// hostCommandRunner runs the harness-toggle scripts via os/exec. Stdout/stderr
// are captured separately so the SettingsModel can count degraded-framework
// notice lines on stderr (per the assemble-instructions-sh-exits-0 contract).
type hostCommandRunner struct{}

func (hostCommandRunner) Run(scriptPath string, args ...string) (string, string, error) {
	cmd := exec.Command("bash", append([]string{scriptPath}, args...)...) //nolint:gosec
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	return stdout.String(), stderr.String(), err
}

// (The retired global agentToggleWidget lived here. It's been replaced by
// the per-harness enabled toggle embedded inside settings.HarnessBlockPanel
// — see initSettingsPanel below for wiring.)

// initSettingsPanel constructs the SettingsModel against live disk paths and
// registers the harness-aware top sections (PrimaryRadio plus one
// HarnessBlockPanel per registered framework — each panel embeds its own
// per-harness enabled toggle). Returns nil with a logged error when
// prerequisites (lore repo root, schema, capabilities) cannot be located —
// the modal is then disabled rather than crashing the TUI.
func initSettingsPanel() (*settings.SettingsModel, error) {
	repoDir, err := config.LoreRepoDir()
	if err != nil {
		return nil, fmt.Errorf("settings: resolve lore repo: %w", err)
	}
	schemaPath := filepath.Join(repoDir, "adapters", "settings.schema.json")
	capsPath := filepath.Join(repoDir, "adapters", "capabilities.json")
	enableScript := filepath.Join(repoDir, "scripts", "harness-toggle", "enable.sh")
	disableScript := filepath.Join(repoDir, "scripts", "harness-toggle", "disable.sh")

	store := hostSettingsStore{}
	runner := hostCommandRunner{}

	// Build the per-dot-path description map by sourcing rich text from the
	// adapter registries. Keep this to capability_overrides; harness-local
	// roles/ceremonies use short section help in their dedicated panels so
	// three harness blocks don't become a wall of prose.
	descriptions := loadFieldDescriptions(repoDir)

	editorSchemaPath, cleanup, err := projectSettingsEditorSchema(schemaPath)
	if err != nil {
		return nil, fmt.Errorf("settings: project editor schema: %w", err)
	}
	defer cleanup()
	m, err := settings.NewSettingsModel(settings.SettingsModelOptions{
		SchemaPath:            editorSchemaPath,
		CapabilitiesPath:      capsPath,
		Store:                 store,
		Runner:                runner,
		EnableScript:          enableScript,
		DisableScript:         disableScript,
		Registry:              settings.NewWidgetRegistry(),
		DescriptionsByDotPath: descriptions,
	})
	// Per D1: NewSettingsModel returns BOTH a usable model AND the schema
	// error so the modal can render a static error banner. Only abort when
	// the model is nil (capabilities load failure is a hard refusal).
	if m == nil {
		return nil, err
	}

	// Top section: PrimaryRadio for the TUI-only launch framework.
	frameworks := readFrameworksList(capsPath)
	currentFramework := readTUILaunchFrameworkOr("")
	radio := settings.NewPrimaryRadio("tui_launch_framework", frameworks, nil, currentFramework)
	m.RegisterTopSection("TUI launch harness", radio)

	// Top sections: one HarnessBlockPanel per registered framework. The
	// panel's enabled toggle (first child in tab order) routes through
	// SettingsModel.ToggleHarness, which shells out to the harness-toggle
	// scripts with the framework as a positional arg.
	doc, _ := store.LoadAll()
	roleIDs, err := loadRoleIDs(filepath.Join(repoDir, "adapters", "roles.json"))
	if err != nil {
		return nil, fmt.Errorf("settings: load role registry: %w", err)
	}
	toggleFn := func(framework string, enabled bool) tea.Cmd {
		return m.ToggleHarness(framework, enabled)
	}
	for _, fw := range frameworks {
		eff, err := computeHarnessEffective(doc, fw, roleIDs)
		if err != nil {
			return nil, fmt.Errorf("settings: resolve routes for %s: %w", fw, err)
		}
		argsWidget := buildHarnessArgsWidget(doc, fw)
		enabled := readHarnessEnabled(doc, fw)
		// Native models and ceremony advisor registrations are harness-local.
		modelsWidget := buildHarnessNativeModelsWidget(doc, fw, roleIDs)
		ceremoniesWidget := buildHarnessCeremoniesWidget(doc, fw)
		panel := settings.NewHarnessRoutesPanel(fw, enabled, toggleFn, argsWidget, modelsWidget, ceremoniesWidget, eff)
		m.RegisterTopSection("harness "+fw, panel)
	}

	return m, err
}

// projectSettingsEditorSchema removes the read-only route union from the
// schema consumed by the deliberately limited generic widget renderer. The
// persisted document is still validated against the full canonical schema by
// hostSettingsStore before every write.
func projectSettingsEditorSchema(schemaPath string) (string, func(), error) {
	raw, err := os.ReadFile(schemaPath)
	if err != nil {
		return "", func() {}, err
	}
	var schema map[string]any
	if err := json.Unmarshal(raw, &schema); err != nil {
		return "", func() {}, err
	}
	props, _ := schema["properties"].(map[string]any)
	delete(props, "routes")
	delete(props, "version") // hidden migration metadata; uses unsupported const
	if required, ok := schema["required"].([]any); ok {
		kept := required[:0]
		for _, v := range required {
			if v != "routes" && v != "version" {
				kept = append(kept, v)
			}
		}
		schema["required"] = kept
	}
	defs, _ := schema["$defs"].(map[string]any)
	for _, key := range []string{"route_value", "route_roles_overlay", "ceremony_route_overlays", "routes_config"} {
		delete(defs, key)
	}
	out, err := json.Marshal(schema)
	if err != nil {
		return "", func() {}, err
	}
	f, err := os.CreateTemp("", "lore-settings-editor-*.schema.json")
	if err != nil {
		return "", func() {}, err
	}
	name := f.Name()
	cleanup := func() { _ = os.Remove(name) }
	if _, err = f.Write(out); err == nil {
		err = f.Close()
	} else {
		_ = f.Close()
	}
	if err != nil {
		cleanup()
		return "", func() {}, err
	}
	return name, cleanup, nil
}

// loadFieldDescriptions assembles the per-dot-path description map the
// settings configurator threads into widget render. The map sources from the
// capability registry:
//
//   - adapters/capabilities.json `.capabilities` → `capability_overrides.<id>`:
//     each capability gets its registered one-line description (e.g.
//     "Spawns fresh subagent contexts for fanout..." for `subagents`). Without
//     this the configurator would render 15 identical-looking enum rows
//     because the schema only carries a shared `support_level` description.
//
// On any I/O error the function returns whatever it has so far (possibly nil),
// not an error: the configurator degrades to schema-only descriptions, which
// is still better than the pre-change behavior. The repo dir is the standard
// `LoreRepoDir()` output; tests use a fixture root.
func loadFieldDescriptions(repoDir string) map[string]string {
	out := map[string]string{}
	mergeCapabilityDescriptions(out, filepath.Join(repoDir, "adapters", "capabilities.json"))
	return out
}

// mergeCapabilityDescriptions reads the `capabilities` map from
// adapters/capabilities.json and writes one `capability_overrides.<id>` entry
// per capability id into dst. Silently no-ops on file/parse errors so a
// partially-broken adapter file degrades to schema descriptions.
func mergeCapabilityDescriptions(dst map[string]string, capsPath string) {
	data, err := os.ReadFile(capsPath)
	if err != nil {
		return
	}
	var doc struct {
		Capabilities map[string]string `json:"capabilities"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return
	}
	for id, desc := range doc.Capabilities {
		dst["capability_overrides."+id] = desc
	}
}

// readFrameworksList reads the frameworks keyset from capabilities.json. On
// error, returns nil — the radio degrades to no options rather than crashing.
func readFrameworksList(capsPath string) []string {
	caps, err := config.LoadCapabilitiesFrameworks(capsPath)
	if err != nil {
		return nil
	}
	return caps
}

// readTUILaunchFrameworkOr reads the TUI launch framework preference from
// settings.json, falling back to the supplied default. Used to seed
// PrimaryRadio at modal open.
func readTUILaunchFrameworkOr(fallback string) string {
	raw, present, err := config.SettingsGet("tui_launch_framework")
	if err != nil || !present {
		return fallback
	}
	// SettingsGet returns the raw JSON token, e.g. "\"claude-code\"" — strip
	// the surrounding quotes for the radio's option-equality test.
	if len(raw) >= 2 && raw[0] == '"' && raw[len(raw)-1] == '"' {
		return raw[1 : len(raw)-1]
	}
	return raw
}

// readHarnessEnabled reads `harnesses.<fw>.enabled` from a pre-loaded
// settings document. Absence is default-on (matches the schema's default
// semantic and the bash `lore_harness_enabled` resolver). The doc is the
// snapshot loaded once by initSettingsPanel — we read from it instead of
// re-querying settings.json so all per-harness toggles see a consistent
// view.
func readHarnessEnabled(doc map[string]any, fw string) bool {
	v := lookup(doc, "harnesses", fw, "enabled")
	if v == nil {
		// Absent → default on.
		return true
	}
	b, ok := v.(bool)
	if !ok {
		return true
	}
	return b
}

// buildHarnessArgsWidget constructs a ListEditor for harnesses.<fw>.args
// seeded from the on-disk document. Empty / absent → empty list.
func buildHarnessArgsWidget(doc map[string]any, fw string) settings.FieldWidget {
	dotPath := "harnesses." + fw + ".args"
	current := lookupStringSlice(doc, "harnesses", fw, "args")
	// uniqueItems / minItems / itemPattern not enforced here — the schema
	// constraint surface for harness args is intentionally permissive
	// (positional CLI flags).
	return settings.NewListEditor(dotPath, "args", current, nil, 0, false, current != nil, false)
}

// buildHarnessNativeModelsWidget constructs the v2 native binding editor.
func buildHarnessNativeModelsWidget(doc map[string]any, fw string, roleIDs []string) settings.FieldWidget {
	models := lookupStringMap(doc, "harnesses", fw, "native_models")
	allowed := map[string]bool{}
	for _, id := range roleIDs {
		allowed[id] = true
	}
	validate := func(key, value string) []string {
		var errs []string
		if !allowed[key] {
			errs = append(errs, fmt.Sprintf("unknown role %q", key))
		}
		if strings.TrimSpace(value) == "" {
			errs = append(errs, "model must not be empty")
		}
		return errs
	}
	w := settings.NewRequiredOpenKeysetKVEditor("harnesses."+fw+".native_models", "native_models", models, "default", validate)
	if hints, ok := w.(interface{ SetDisplayHints(string, string) }); ok {
		hints.SetDisplayHints("native_models", "Models for in-process subagents on this harness. The default binding is required.")
	}
	return w
}

// buildHarnessCeremoniesWidget constructs an OpenKeysetKVEditor for
// harnesses.<fw>.ceremonies. Ceremony advisors are harness-local defaults now,
// so the editor is always materialized and reads only the harness-local map.
//
// Ceremony values are arrays of advisor ids in the schema. The editor displays
// each array as a comma-joined string for compact editing, then parses it back
// to []string on commit so the persisted value remains schema-shaped.
func buildHarnessCeremoniesWidget(doc map[string]any, fw string) settings.FieldWidget {
	ceremonies := lookupCeremoniesMap(doc, "harnesses", fw, "ceremonies")
	// Flatten array-of-strings values to comma-joined strings for display.
	// The reverse direction (commit) is the gap noted above.
	flat := make(map[string]string, len(ceremonies))
	for k, advisors := range ceremonies {
		flat[k] = strings.Join(advisors, ",")
	}
	dotPath := "harnesses." + fw + ".ceremonies"
	w := settings.NewStringArrayOpenKeysetKVEditor(dotPath, "ceremonies", flat, true, false)
	w.SetDisplayHints("ceremonies", "Advisor skills for this harness's ceremonies.")
	return w
}

// computeHarnessEffective resolves global and harness-native routes for display.
func computeHarnessEffective(doc map[string]any, fw string, roleIDs []string) (settings.HarnessEffective, error) {
	routes := map[string]string{}
	native := map[string]string{}
	for _, role := range roleIDs {
		route, err := config.ResolveCanonicalRoute(role, "", nil)
		if err != nil {
			return settings.HarnessEffective{}, fmt.Errorf("global role %s: %w", role, err)
		}
		routes[role] = formatRoute(route)
		nativeRoute, err := config.ResolveNativeCanonicalRoute(role, "", fw)
		if err != nil {
			return settings.HarnessEffective{}, fmt.Errorf("native role %s: %w", role, err)
		}
		native[role] = formatRoute(nativeRoute)
	}
	return settings.HarnessEffective{Roles: routes, NativeModels: native, Ceremonies: lookupCeremoniesMap(doc, "harnesses", fw, "ceremonies")}, nil
}

func formatRoute(route config.Route) string {
	out := route.Framework + "/" + route.Model
	if len(route.Options) > 0 {
		raw, _ := json.Marshal(route.Options)
		out += " " + string(raw)
	}
	return out
}

func loadRoleIDs(path string) ([]string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var doc struct {
		Roles []struct {
			ID string `json:"id"`
		} `json:"roles"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("parse role registry: %w", err)
	}
	if len(doc.Roles) == 0 {
		return nil, fmt.Errorf("role registry is empty")
	}
	out := make([]string, 0, len(doc.Roles))
	for _, row := range doc.Roles {
		if row.ID == "" {
			return nil, fmt.Errorf("role registry contains empty id")
		}
		out = append(out, row.ID)
	}
	return out, nil
}

func lookupStringSlice(doc map[string]any, path ...string) []string {
	node := lookup(doc, path...)
	arr, ok := node.([]any)
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

func lookupStringMap(doc map[string]any, path ...string) map[string]string {
	node := lookup(doc, path...)
	obj, ok := node.(map[string]any)
	if !ok {
		return nil
	}
	out := make(map[string]string, len(obj))
	for k, v := range obj {
		if s, ok := v.(string); ok {
			out[k] = s
		}
	}
	return out
}

func lookupCeremoniesMap(doc map[string]any, path ...string) map[string][]string {
	node := lookup(doc, path...)
	obj, ok := node.(map[string]any)
	if !ok {
		return nil
	}
	out := make(map[string][]string, len(obj))
	for k, v := range obj {
		arr, ok := v.([]any)
		if !ok {
			continue
		}
		advisors := make([]string, 0, len(arr))
		for _, x := range arr {
			if s, ok := x.(string); ok {
				advisors = append(advisors, s)
			}
		}
		out[k] = advisors
	}
	return out
}

func lookup(doc map[string]any, path ...string) any {
	var node any = doc
	for _, seg := range path {
		mp, ok := node.(map[string]any)
		if !ok {
			return nil
		}
		node = mp[seg]
	}
	return node
}

// settingsModalWidth returns the outer modal box width for the settings
// configurator. The settings modal is wider than the standard modalInnerW
// (58) because harness blocks render multi-column effective-vs-override
// rows that wrap awkwardly at 58. We span the smaller of (terminal width
// minus a small margin) and a generous cap so the box never feels cramped
// on narrow terminals nor absurdly wide on a tiled session.
func settingsModalWidth(termWidth int) int {
	const cap, margin, floor = 120, 4, 60
	w := termWidth - margin
	if w > cap {
		w = cap
	}
	if w < floor {
		w = floor
	}
	return w
}

// settingsModalBodyHeight returns the inner viewport height for the settings
// body — terminal height minus chrome (border 2 + title 1 + status bar 1 +
// small breathing room). Hints render in the status bar (below the modal box),
// not inside the body, so no row is reserved for them here.
func settingsModalBodyHeight(termHeight int) int {
	const chrome = 6 // border 2 + title 1 + blank 1 + status 1 + margin 1
	h := termHeight - chrome
	if h < 8 {
		h = 8
	}
	return h
}

// sizeSettingsPanel pushes the host-derived width/height into the settings
// model so its viewport scrolls long content. Called at modal open and on
// every WindowSizeMsg while the modal is active.
func (m *model) sizeSettingsPanel() {
	if m.settingsPanel == nil {
		return
	}
	outerW := settingsModalWidth(m.width)
	// Inner content width: outer minus border (2) and a small horizontal pad.
	bodyW := outerW - 4
	if bodyW < 1 {
		bodyW = 1
	}
	bodyH := settingsModalBodyHeight(m.height)
	m.settingsPanel.SetSize(bodyW, bodyH)
}

// renderSettingsModal wraps the SettingsModel body with the host's modal
// chrome (D2). Hotkey hints are rendered by renderStatusBar below the modal
// box (via placeModal), matching the work/follow-up views — so the body here
// is only the schema-driven panel content.
func (m model) renderSettingsModal() string {
	if m.settingsPanel == nil {
		return ""
	}
	s := newModalStyles()
	body := "\n" + m.settingsPanel.View() + "\n"
	return m.placeModal(buildModalBoxWidth(s, "Settings", body, settingsModalWidth(m.width)))
}
