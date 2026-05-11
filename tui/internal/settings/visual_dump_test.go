package settings

import (
	"path/filepath"
	"runtime"
	"testing"
)

// TestVisualDumpForManualInspection renders a fully-wired model against the
// real adapters/settings.schema.json and prints View() output. Skipped during
// normal `go test`; un-skip locally to inspect the section framing.
func TestVisualDumpForManualInspection(t *testing.T) {
	// Manual probe only — un-skip locally to inspect section framing.
	t.Skip("visual probe — un-skip locally to inspect render")
	_, thisFile, _, _ := runtime.Caller(0)
	repoDir := filepath.Join(filepath.Dir(thisFile), "..", "..", "..")
	schemaPath := filepath.Join(repoDir, "adapters", "settings.schema.json")
	capsPath := filepath.Join(repoDir, "adapters", "capabilities.json")

	store := newFakeStore(map[string]any{
		"version":              1,
		"tui_launch_framework": "claude-code",
		"harnesses": map[string]any{
			"claude-code": map[string]any{"args": []any{"--dangerously-skip-permissions"}},
			"opencode":    map[string]any{"args": []any{}},
			"codex":       map[string]any{"args": []any{}},
		},
		"capability_overrides": map[string]any{"instructions": "full", "skills": "partial"},
		"roles":                map[string]any{"default": "sonnet", "lead": "opus"},
	})
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
	if m == nil {
		t.Fatal("nil model")
	}

	// Register a primary harness radio + one harness block so we can also
	// inspect the top-section render path (these go through the same
	// renderSection helper as schema-driven sections).
	radio := NewPrimaryRadio("tui_launch_framework", []string{"claude-code", "opencode", "codex"}, nil, "claude-code")
	m.RegisterTopSection("primary harness", radio)
	args := NewListEditor("harnesses.claude-code.args", "args", []string{"--dangerously-skip-permissions"}, nil, 0, false, true, false)
	hp := NewHarnessBlockPanel("claude-code", true, nil, args, nil, nil, HarnessEffective{Roles: map[string]string{"lead": "opus", "default": "sonnet"}})
	m.RegisterTopSection("harness claude-code", hp)

	m.SetSize(80, 40)
	t.Logf("\n%s", m.View())
}
