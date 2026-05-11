package settings

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestLoadSchema_LiveAdaptersSchema verifies the live adapters/settings.schema.json
// loads cleanly. This is a smoke test of the D1 commitment: every construct
// in the verified-current schema must be in the supported taxonomy. The
// schema file is read-only — this test never mutates it.
func TestLoadSchema_LiveAdaptersSchema(t *testing.T) {
	_, here, _, ok := runtime.Caller(0)
	if !ok {
		t.Skip("cannot resolve caller path")
	}
	// internal/settings/schema_live_test.go -> repo-root/adapters/settings.schema.json
	schemaPath := filepath.Join(filepath.Dir(here), "..", "..", "..", "adapters", "settings.schema.json")

	s, err := LoadSchema(schemaPath)
	if err != nil {
		t.Fatalf("live schema failed to load (D1 violation or schema regression): %v", err)
	}
	if s.Root.Kind != KindObjectClosed {
		t.Fatalf("live schema root kind = %v, want closed object", s.Root.Kind)
	}
	// Spot-check: active_framework must resolve to KindEnum via $defs/framework_id.
	af, ok := s.Root.Properties["active_framework"]
	if !ok {
		t.Fatal("active_framework missing from live schema")
	}
	if af.Kind != KindEnum {
		t.Fatalf("active_framework kind = %v, want enum", af.Kind)
	}
	if len(af.Enum) == 0 {
		t.Fatal("active_framework enum is empty")
	}
	if af.SourceRef != "#/$defs/framework_id" {
		t.Fatalf("active_framework SourceRef = %q, want #/$defs/framework_id", af.SourceRef)
	}
	// Spot-check: harnesses is closed-keyset with at least one entry.
	h, ok := s.Root.Properties["harnesses"]
	if !ok {
		t.Fatal("harnesses missing from live schema")
	}
	if h.Kind != KindObjectClosed {
		t.Fatalf("harnesses kind = %v", h.Kind)
	}
	if len(h.PropertyOrder) == 0 {
		t.Fatal("harnesses property order empty")
	}
}

// TestLiveRender_CapabilityOverridesMatrixHasLabelsAndDescriptions exercises
// the rendering pipeline end-to-end against the live schema + adapters: it
// builds a SettingsModel with the real adapters/capabilities.json descriptions
// and asserts the capability_overrides section emerges as labeled rows with
// per-capability help text — i.e., the matrix-of-anonymous-rows readability
// gap is closed for every capability id, not just the first one.
//
// This test is the quickest tripwire if a future change unwires
// DescriptionsByDotPath, regresses ClosedObjectSubPanel's child-indent, or
// reverts EnumSelector.View() to the legacy single-line form.
func TestLiveRender_CapabilityOverridesMatrixHasLabelsAndDescriptions(t *testing.T) {
	_, here, _, ok := runtime.Caller(0)
	if !ok {
		t.Skip("cannot resolve caller path")
	}
	repoRoot := filepath.Join(filepath.Dir(here), "..", "..", "..")
	schemaPath := filepath.Join(repoRoot, "adapters", "settings.schema.json")
	capsPath := filepath.Join(repoRoot, "adapters", "capabilities.json")

	descByPath, capabilityIDs := loadCapabilityDescriptions(t, capsPath)
	if len(capabilityIDs) == 0 {
		t.Fatal("expected capability ids in adapters/capabilities.json")
	}

	store := newFakeStore(map[string]any{
		"version":              float64(1),
		"active_framework":     "claude-code",
		"harnesses":            map[string]any{"claude-code": map[string]any{"args": []any{}}},
		"capability_overrides": map[string]any{},
	})
	m, err := NewSettingsModel(SettingsModelOptions{
		SchemaPath:            schemaPath,
		CapabilitiesPath:      capsPath,
		Store:                 store,
		Runner:                &fakeRunner{},
		EnableScript:          "/dev/null",
		DisableScript:         "/dev/null",
		Registry:              NewWidgetRegistry(),
		DescriptionsByDotPath: descByPath,
	})
	if err != nil {
		t.Fatalf("NewSettingsModel: %v", err)
	}
	m.SetSize(96, 40)

	// Find the advanced wrapper. It should stay folded by default so the
	// capability matrix no longer dominates the settings landing surface.
	var advanced *AdvancedSection
	for _, w := range m.widgets {
		if p, ok := w.(*AdvancedSection); ok && p.DotPath() == "advanced" {
			advanced = p
			break
		}
	}
	if advanced == nil {
		t.Fatalf("advanced capability_overrides wrapper not found in walker output")
	}
	collapsed := stripANSI(advanced.View())
	if !strings.Contains(collapsed, "[+] capability_overrides") {
		t.Fatalf("advanced section should render collapsed summary, got:\n%s", collapsed)
	}
	if strings.Contains(collapsed, "team_messaging") {
		t.Fatalf("collapsed advanced section should hide capability rows, got:\n%s", collapsed)
	}

	advanced.Focus()
	updated, _, intent := advanced.Update(keyMsg("enter"))
	if intent != nil {
		t.Fatalf("expanding advanced section should not emit intent: %#v", intent)
	}
	advanced = updated.(*AdvancedSection)
	rendered := stripANSI(advanced.View())

	// Each capability id from capabilities.json must appear as a labeled row
	// AND the same id's description must appear (or a recognizable prefix of
	// it — descriptions are wrapped, so we match the leading 24 characters).
	missingLabels := []string{}
	missingDescs := []string{}
	for _, id := range capabilityIDs {
		if !strings.Contains(rendered, id) {
			missingLabels = append(missingLabels, id)
		}
		desc := descByPath["capability_overrides."+id]
		if desc == "" {
			continue
		}
		head := desc
		if len(head) > 24 {
			head = head[:24]
		}
		// Word-wrap may insert a newline; allow a single space-or-newline
		// between any two adjacent characters of the head.
		if !containsLoose(rendered, head) {
			missingDescs = append(missingDescs, id)
		}
	}
	if len(missingLabels) > 0 {
		t.Errorf("capability rows missing label text in render: %v\n--- rendered ---\n%s", missingLabels, rendered)
	}
	if len(missingDescs) > 0 {
		t.Errorf("capability rows missing description prefix in render: %v\n--- rendered ---\n%s", missingDescs, rendered)
	}

	// Sanity: the rendered panel must have multiple lines (not the legacy
	// single-line matrix). The expected shape is roughly 4 lines per row
	// (header + options + 1-2 description lines + blank).
	if strings.Count(rendered, "\n") < len(capabilityIDs)*2 {
		t.Errorf("rendered panel is suspiciously short — expected multi-line per row, got:\n%s", rendered)
	}

	// Surface the rendered panel under -v so visual inspection of the layout
	// is easy when iterating on the configurator design.
	t.Logf("\n--- live advanced capability_overrides render (96-col body) ---\n%s\n--- end ---", rendered)
}

func TestLiveRender_SettlementEligibleFrameworksSelectableFromSchemaEnum(t *testing.T) {
	_, here, _, ok := runtime.Caller(0)
	if !ok {
		t.Skip("cannot resolve caller path")
	}
	repoRoot := filepath.Join(filepath.Dir(here), "..", "..", "..")
	schemaPath := filepath.Join(repoRoot, "adapters", "settings.schema.json")
	capsPath := filepath.Join(repoRoot, "adapters", "capabilities.json")

	store := newFakeStore(map[string]any{
		"version":          float64(1),
		"active_framework": "claude-code",
		"harnesses":        map[string]any{"claude-code": map[string]any{"args": []any{}}},
		"settlement": map[string]any{
			"active_hours": map[string]any{
				"ranges": []any{
					map[string]any{"start": "07:30", "end": "11:00", "days": []any{"tue", "thu"}},
				},
			},
			"harness_selection": map[string]any{
				"eligible_frameworks": []any{},
			},
		},
	})
	m, err := NewSettingsModel(SettingsModelOptions{
		SchemaPath:       schemaPath,
		CapabilitiesPath: capsPath,
		Store:            store,
		Runner:           &fakeRunner{},
		EnableScript:     "/dev/null",
		DisableScript:    "/dev/null",
		Registry:         NewWidgetRegistry(),
	})
	if err != nil {
		t.Fatalf("NewSettingsModel: %v", err)
	}

	var settlement *ClosedObjectSubPanel
	for _, w := range m.widgets {
		if p, ok := w.(*ClosedObjectSubPanel); ok && p.DotPath() == "settlement" {
			settlement = p
			break
		}
	}
	if settlement == nil {
		t.Fatalf("settlement settings panel not found")
	}
	rendered := stripANSI(settlement.View())
	for _, want := range []string{
		"eligible_frameworks",
		"[x] claude-code",
		"[x] opencode",
		"[x] codex",
		"ranges",
		"tue,thu  07:30-11:00",
	} {
		if !strings.Contains(rendered, want) {
			t.Fatalf("settlement eligible frameworks should render schema enum choices; missing %q in:\n%s", want, rendered)
		}
	}
}

// TestLiveRender_TopLevelRolesIgnored confirms that unknown top-level roles in
// an existing settings document do not render as a generic editable panel.
// Harness-local role editors are built by the host settings panel instead.
func TestLiveRender_TopLevelRolesIgnored(t *testing.T) {
	_, here, _, ok := runtime.Caller(0)
	if !ok {
		t.Skip("cannot resolve caller path")
	}
	repoRoot := filepath.Join(filepath.Dir(here), "..", "..", "..")
	schemaPath := filepath.Join(repoRoot, "adapters", "settings.schema.json")
	capsPath := filepath.Join(repoRoot, "adapters", "capabilities.json")

	store := newFakeStore(map[string]any{
		"version":          float64(1),
		"active_framework": "claude-code",
		"harnesses":        map[string]any{"claude-code": map[string]any{"args": []any{}}},
		"roles":            map[string]any{"default": "sonnet", "lead": "opus"},
	})
	m, err := NewSettingsModel(SettingsModelOptions{
		SchemaPath:            schemaPath,
		CapabilitiesPath:      capsPath,
		Store:                 store,
		Runner:                &fakeRunner{},
		EnableScript:          "/dev/null",
		DisableScript:         "/dev/null",
		Registry:              NewWidgetRegistry(),
		DescriptionsByDotPath: map[string]string{"roles.lead": "legacy role description"},
	})
	if err != nil {
		t.Fatalf("NewSettingsModel: %v", err)
	}
	m.SetSize(96, 40)

	for _, w := range m.widgets {
		if w.DotPath() == "roles" {
			t.Fatalf("top-level roles panel should not render from generic walker")
		}
	}
	rendered := stripANSI(m.View())
	if strings.Contains(rendered, "legacy role description") {
		t.Fatalf("top-level roles description leaked into render:\n%s", rendered)
	}
}

func loadCapabilityDescriptions(t *testing.T, capsPath string) (map[string]string, []string) {
	t.Helper()
	data, err := os.ReadFile(capsPath)
	if err != nil {
		t.Fatalf("read %s: %v", capsPath, err)
	}
	var doc struct {
		Capabilities map[string]string `json:"capabilities"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("parse %s: %v", capsPath, err)
	}
	out := map[string]string{}
	ids := []string{}
	for id, desc := range doc.Capabilities {
		out["capability_overrides."+id] = desc
		ids = append(ids, id)
	}
	return out, ids
}

// stripANSI removes simple CSI sequences (ESC [ ... m) so containment checks
// are not foiled by lipgloss's color escape codes.
func stripANSI(s string) string {
	var b strings.Builder
	inEsc := false
	for _, r := range s {
		if r == 0x1b {
			inEsc = true
			continue
		}
		if inEsc {
			if r == 'm' {
				inEsc = false
			}
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

// containsLoose reports whether `s` contains `needle`, treating any single
// whitespace boundary in `s` as a wildcard (so a wrapped description still
// matches its un-wrapped expected prefix).
func containsLoose(s, needle string) bool {
	// Fast path.
	if strings.Contains(s, needle) {
		return true
	}
	// Slow path: collapse whitespace runs in both strings and compare.
	collapse := func(in string) string {
		var b strings.Builder
		prevWS := false
		for _, r := range in {
			if r == ' ' || r == '\n' || r == '\t' {
				if !prevWS {
					b.WriteByte(' ')
					prevWS = true
				}
				continue
			}
			b.WriteRune(r)
			prevWS = false
		}
		return b.String()
	}
	return strings.Contains(collapse(s), collapse(needle))
}
