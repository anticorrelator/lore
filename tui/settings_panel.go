package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"

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
	return config.SettingsPatch(dotPath, value)
}

func (hostSettingsStore) Delete(dotPath string) error {
	return config.SettingsDelete(dotPath)
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

	m, err := settings.NewSettingsModel(settings.SettingsModelOptions{
		SchemaPath:            schemaPath,
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
	toggleFn := func(framework string, enabled bool) tea.Cmd {
		return m.ToggleHarness(framework, enabled)
	}
	for _, fw := range frameworks {
		eff := computeHarnessEffective(doc, fw)
		argsWidget := buildHarnessArgsWidget(doc, fw)
		enabled := readHarnessEnabled(doc, fw)
		// Roles and ceremonies are harness-local defaults. Always materialize
		// the widgets so the TUI edits the only supported settings location.
		rolesWidget := buildHarnessRolesWidget(doc, fw)
		ceremoniesWidget := buildHarnessCeremoniesWidget(doc, fw)
		panel := settings.NewHarnessBlockPanel(fw, enabled, toggleFn, argsWidget, rolesWidget, ceremoniesWidget, eff)
		m.RegisterTopSection("harness "+fw, panel)
	}

	return m, err
}

func initSettlementSettingsPanel() (*settings.SettingsModel, error) {
	panel, err := initSettingsPanel()
	if panel != nil {
		panel.LimitToDotPath("settlement")
		panel.SetCompactEmbed(true)
	}
	return panel, err
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

// buildHarnessRolesWidget constructs an OpenKeysetKVEditor for
// harnesses.<fw>.roles. Roles are harness-local defaults, so the editor is
// always materialized and commits back to the harness path.
func buildHarnessRolesWidget(doc map[string]any, fw string) settings.FieldWidget {
	roles := lookupStringMap(doc, "harnesses", fw, "roles")
	dotPath := "harnesses." + fw + ".roles"
	w := settings.NewOpenKeysetKVEditor(dotPath, "roles", roles, nil, nil, true, false)
	w.SetDisplayHints("roles", "Model defaults for this harness.")
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

// computeHarnessEffective resolves the roles/ceremonies shown for a harness.
// Settings keep these maps under harnesses.<fw>; there is no top-level
// fallback.
func computeHarnessEffective(doc map[string]any, fw string) settings.HarnessEffective {
	roles := lookupStringMap(doc, "harnesses", fw, "roles")
	ceremonies := lookupCeremoniesMap(doc, "harnesses", fw, "ceremonies")
	return settings.HarnessEffective{Roles: roles, Ceremonies: ceremonies}
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
