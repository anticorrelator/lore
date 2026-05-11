package main

import (
	"regexp"
	"strings"
	"testing"
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

	roles := buildHarnessRolesWidget(doc, "codex")
	if roles == nil {
		t.Fatalf("roles widget should always be materialized")
	}
	if roles.DotPath() != "harnesses.codex.roles" {
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
				"roles": map[string]any{
					"lead": "gpt-5.2",
				},
				"ceremonies": map[string]any{
					"spec-design": []any{"codex-plan-review"},
				},
			},
		},
	}

	rolesView := stripANSI(buildHarnessRolesWidget(doc, "codex").View())
	if !strings.Contains(rolesView, "lead = gpt-5.2") || strings.Contains(rolesView, "lead = opus") {
		t.Fatalf("roles widget should prefer harness-local values:\n%s", rolesView)
	}

	ceremoniesView := stripANSI(buildHarnessCeremoniesWidget(doc, "codex").View())
	if !strings.Contains(ceremoniesView, "spec-design = codex-plan-review") || strings.Contains(ceremoniesView, "codex-design-review") {
		t.Fatalf("ceremonies widget should read only harness-local values:\n%s", ceremoniesView)
	}
}
