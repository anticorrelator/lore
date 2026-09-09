package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/anticorrelator/lore/tui/internal/settings"
)

var settingsPanelANSIPattern = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func stripANSI(s string) string {
	return settingsPanelANSIPattern.ReplaceAllString(s, "")
}

func TestBuildHarnessDefaultsWidgets_IgnoreTopLevelCeremonies(t *testing.T) {
	doc := map[string]any{
		"roles": map[string]any{
			"lead":    "opus",
			"default": "sonnet",
		},
		"ceremonies": map[string]any{
			"spec-design": []any{"codex-design-review"},
		},
		"harnesses": map[string]any{
			"codex": map[string]any{
				"args": []any{},
			},
		},
	}

	roles := buildHarnessNativeModelsWidget(doc, "codex", []string{"default", "lead"})
	if roles == nil {
		t.Fatalf("roles widget should always be materialized")
	}
	if roles.DotPath() != "harnesses.codex.native_models" {
		t.Fatalf("roles widget dot path = %q", roles.DotPath())
	}
	rolesView := stripANSI(roles.View())
	if strings.Contains(rolesView, "lead = opus") || strings.Contains(rolesView, "default = sonnet") {
		t.Fatalf("roles widget should ignore top-level roles:\n%s", rolesView)
	}

	ceremonies := buildHarnessCeremoniesWidget(doc, "codex")
	if ceremonies == nil {
		t.Fatalf("ceremonies widget should always be materialized")
	}
	if ceremonies.DotPath() != "harnesses.codex.ceremonies" {
		t.Fatalf("ceremonies widget dot path = %q", ceremonies.DotPath())
	}
	ceremoniesView := stripANSI(ceremonies.View())
	if strings.Contains(ceremoniesView, "spec-design") || strings.Contains(ceremoniesView, "codex-design-review") {
		t.Fatalf("ceremonies widget should ignore top-level ceremonies:\n%s", ceremoniesView)
	}
}

func TestBuildHarnessDefaultsWidgets_PreferHarnessLocalValues(t *testing.T) {
	doc := map[string]any{
		"roles": map[string]any{
			"lead": "opus",
		},
		"ceremonies": map[string]any{
			"spec-design": []any{"codex-design-review"},
		},
		"harnesses": map[string]any{
			"codex": map[string]any{
				"args": []any{},
				"native_models": map[string]any{
					"lead":    "gpt-5.2",
					"default": "gpt-5.5-high",
				},
				"ceremonies": map[string]any{
					"spec-design": []any{"codex-plan-review"},
				},
			},
		},
	}

	rolesView := stripANSI(buildHarnessNativeModelsWidget(doc, "codex", []string{"default", "lead"}).View())
	if !strings.Contains(rolesView, "lead = gpt-5.2") || strings.Contains(rolesView, "lead = opus") {
		t.Fatalf("roles widget should prefer harness-local values:\n%s", rolesView)
	}

	ceremoniesView := stripANSI(buildHarnessCeremoniesWidget(doc, "codex").View())
	if !strings.Contains(ceremoniesView, "spec-design = codex-plan-review") || strings.Contains(ceremoniesView, "codex-design-review") {
		t.Fatalf("ceremonies widget should read only harness-local values:\n%s", ceremoniesView)
	}
}

func TestProjectSettingsEditorSchemaRemovesRouteUnionOnly(t *testing.T) {
	projected, cleanup, err := projectSettingsEditorSchema(filepath.Join("..", "adapters", "settings.schema.json"))
	if err != nil {
		t.Fatal(err)
	}
	defer cleanup()
	raw, err := os.ReadFile(projected)
	if err != nil {
		t.Fatal(err)
	}
	text := string(raw)
	if strings.Contains(text, `"route_value"`) || strings.Contains(text, `"routes_config"`) {
		t.Fatal("route-only definitions survived editor projection")
	}
	if !strings.Contains(text, `"native_models"`) || !strings.Contains(text, `"coordination"`) {
		t.Fatal("projection dropped unrelated editable fields")
	}
	if _, err := settings.LoadSchema(projected); err != nil {
		t.Fatalf("projected schema must load: %v", err)
	}
}

func TestHostSettingsStoreValidatesCandidateBeforeWriting(t *testing.T) {
	const fixture = `{"version":2,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[],"native_models":{"default":"opus"}},"codex":{"args":[],"native_models":{"default":"gpt-5.5-high"}},"opencode":{"args":[],"native_models":{"default":"anthropic/opus"}}},"routes":{"default":"claude-code/opus"}}`
	dataDir := setupFakeLoreData(t, fixture)
	path := filepath.Join(dataDir, "config", "settings.json")
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	store := hostSettingsStore{}
	if err := store.Patch("harnesses.codex.native_models", map[string]any{"default": "gpt-5.5-high", "unknown": "bad"}); err == nil {
		t.Fatal("unknown role edit should be refused")
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Fatal("failed edit changed settings bytes")
	}
	if err := store.Delete("harnesses.codex.native_models.default"); err == nil {
		t.Fatal("required default deletion should be refused")
	}
	after, _ = os.ReadFile(path)
	if !bytes.Equal(before, after) {
		t.Fatal("failed default deletion changed settings bytes")
	}
	if err := store.Patch("harnesses.codex.native_models", map[string]any{"default": "gpt-5.5-high", "worker": "gpt-5.6-sol-high"}); err != nil {
		t.Fatalf("valid native edit: %v", err)
	}
	after, _ = os.ReadFile(path)
	var doc map[string]any
	if err := json.Unmarshal(after, &doc); err != nil {
		t.Fatal(err)
	}
	harness := doc["harnesses"].(map[string]any)["codex"].(map[string]any)
	if _, present := harness["roles"]; present {
		t.Fatal("edit recreated retired roles")
	}
	if _, present := harness["ceremony_roles"]; present {
		t.Fatal("edit recreated retired ceremony_roles")
	}
	if err := store.Delete("harnesses.codex.native_models.worker"); err != nil {
		t.Fatalf("delete optional native binding: %v", err)
	}
	after, _ = os.ReadFile(path)
	if bytes.Contains(after, []byte(`"worker"`)) {
		t.Fatal("optional native binding was not deleted")
	}
}
