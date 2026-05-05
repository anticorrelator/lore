package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// setupFakeLoreData stages a fake LORE_DATA_DIR with a symlink to the real
// repo's scripts/ dir (so loreRepoDir() can find adapters/capabilities.json)
// and an isolated framework.json so tests don't touch the user's config.
func setupFakeLoreData(t *testing.T, framework string, roles map[string]string) string {
	t.Helper()

	// Find the repo root by walking up from this source file via runtime?
	// We use go test's working dir: tests run in the package dir, so
	// ../../.. from this file is <repo>/tui/internal/config -> <repo>.
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	repoRoot := filepath.Clean(filepath.Join(wd, "..", "..", ".."))

	// Sanity check: adapters/capabilities.json must exist at the resolved root.
	if _, err := os.Stat(filepath.Join(repoRoot, "adapters", "capabilities.json")); err != nil {
		t.Fatalf("expected repo root at %s but capabilities.json missing: %v", repoRoot, err)
	}

	dataDir := t.TempDir()
	scriptsLink := filepath.Join(dataDir, "scripts")
	if err := os.Symlink(filepath.Join(repoRoot, "scripts"), scriptsLink); err != nil {
		t.Fatal(err)
	}

	configDir := filepath.Join(dataDir, "config")
	if err := os.MkdirAll(configDir, 0755); err != nil {
		t.Fatal(err)
	}
	cfg := userFrameworkConfig{
		Version:             1,
		Framework:           framework,
		CapabilityOverrides: map[string]string{},
		Roles:               roles,
	}
	data, _ := json.MarshalIndent(cfg, "", "  ")
	if err := os.WriteFile(filepath.Join(configDir, "framework.json"), data, 0644); err != nil {
		t.Fatal(err)
	}

	t.Setenv("LORE_DATA_DIR", dataDir)
	// Ensure no env-side framework override leaks in.
	t.Setenv("LORE_FRAMEWORK", "")
	return dataDir
}

func TestResolveActiveFramework(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)

	got, err := ResolveActiveFramework()
	if err != nil {
		t.Fatalf("ResolveActiveFramework: %v", err)
	}
	if got != "claude-code" {
		t.Errorf("got %q, want claude-code", got)
	}
}

func TestResolveActiveFramework_EnvOverride(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	t.Setenv("LORE_FRAMEWORK", "opencode")

	got, err := ResolveActiveFramework()
	if err != nil {
		t.Fatalf("ResolveActiveFramework: %v", err)
	}
	if got != "opencode" {
		t.Errorf("got %q, want opencode", got)
	}
}

func TestResolveActiveFramework_RejectsUnknown(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	t.Setenv("LORE_FRAMEWORK", "bogus")

	_, err := ResolveActiveFramework()
	if err == nil {
		t.Fatal("expected error for unknown framework, got nil")
	}
	if !strings.Contains(err.Error(), "unknown framework") {
		t.Errorf("error = %v, want substring %q", err, "unknown framework")
	}
}

func TestResolveHarnessInstallPath_ClaudeCode(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	home, _ := os.UserHomeDir()

	cases := []struct {
		kind string
		want string
	}{
		{"instructions", filepath.Join(home, ".claude", "CLAUDE.md")},
		{"skills", filepath.Join(home, ".claude", "skills")},
		{"agents", filepath.Join(home, ".claude", "agents")},
		{"settings", filepath.Join(home, ".claude", "settings.json")},
		{"teams", filepath.Join(home, ".claude", "teams")},
		{"ephemeral_plans", filepath.Join(home, ".claude", "plans")},
	}
	for _, c := range cases {
		path, supported, err := ResolveHarnessInstallPath(c.kind)
		if err != nil {
			t.Errorf("kind=%s: unexpected error: %v", c.kind, err)
			continue
		}
		if !supported {
			t.Errorf("kind=%s: supported=false, want true", c.kind)
		}
		if path != c.want {
			t.Errorf("kind=%s: path=%q, want %q", c.kind, path, c.want)
		}
	}
}

func TestResolveHarnessInstallPath_Unsupported(t *testing.T) {
	setupFakeLoreData(t, "opencode", nil)

	for _, kind := range []string{"teams", "ephemeral_plans"} {
		path, supported, err := ResolveHarnessInstallPath(kind)
		if err != nil {
			t.Errorf("kind=%s on opencode: unexpected error: %v", kind, err)
			continue
		}
		if supported {
			t.Errorf("kind=%s on opencode: supported=true, want false", kind)
		}
		if path != "" {
			t.Errorf("kind=%s on opencode: path=%q, want empty", kind, path)
		}
	}
}

func TestResolveHarnessInstallPath_Codex(t *testing.T) {
	setupFakeLoreData(t, "codex", nil)
	home, _ := os.UserHomeDir()

	path, supported, err := ResolveHarnessInstallPath("instructions")
	if err != nil {
		t.Fatalf("ResolveHarnessInstallPath: %v", err)
	}
	if !supported {
		t.Error("supported=false, want true")
	}
	want := filepath.Join(home, ".codex", "AGENTS.md")
	if path != want {
		t.Errorf("path=%q, want %q", path, want)
	}
}

func TestResolveHarnessInstallPath_RejectsUnknownKind(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	_, _, err := ResolveHarnessInstallPath("bogus_kind")
	if err == nil {
		t.Fatal("expected error for unknown kind, got nil")
	}
}

func TestResolveAgentTemplate(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)

	path, err := ResolveAgentTemplate("worker")
	if err != nil {
		t.Fatalf("ResolveAgentTemplate: %v", err)
	}
	if !strings.HasSuffix(path, "/agents/worker.md") {
		t.Errorf("path=%q, want suffix /agents/worker.md", path)
	}
	if _, statErr := os.Stat(path); statErr != nil {
		t.Errorf("returned path does not exist: %v", statErr)
	}
}

func TestResolveAgentTemplate_RejectsMissing(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	_, err := ResolveAgentTemplate("definitely_not_a_real_template_xyz")
	if err == nil {
		t.Fatal("expected error for missing template, got nil")
	}
}

func TestResolveAgentTemplate_RejectsEmpty(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	_, err := ResolveAgentTemplate("")
	if err == nil {
		t.Fatal("expected error for empty name, got nil")
	}
}

// writeHarnessArgs helper writes a harness-args.json file under the staged
// LORE_DATA_DIR. Used by tests that verify LoadHarnessArgs precedence.
func writeHarnessArgs(t *testing.T, perFramework map[string][]string) {
	t.Helper()
	dataDir := os.Getenv("LORE_DATA_DIR")
	if dataDir == "" {
		t.Fatal("LORE_DATA_DIR not set; call setupFakeLoreData first")
	}
	out := map[string]any{"version": 1}
	for fw, args := range perFramework {
		out[fw] = HarnessArgsConfig{Args: args}
	}
	data, _ := json.MarshalIndent(out, "", "  ")
	path := filepath.Join(dataDir, "config", "harness-args.json")
	if err := os.WriteFile(path, data, 0644); err != nil {
		t.Fatal(err)
	}
}

func TestLoadHarnessArgs_ClaudeCodeDefault(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	got := LoadHarnessArgs("claude-code")
	want := []string{"--dangerously-skip-permissions"}
	if len(got) != 1 || got[0] != want[0] {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestLoadHarnessArgs_PerFrameworkArgs(t *testing.T) {
	setupFakeLoreData(t, "opencode", nil)
	writeHarnessArgs(t, map[string][]string{
		"claude-code": {"--flag-a", "--flag-b"},
		"opencode":    {"--opencode-flag"},
	})
	got := LoadHarnessArgs("opencode")
	if len(got) != 1 || got[0] != "--opencode-flag" {
		t.Errorf("got %v, want [--opencode-flag]", got)
	}
}

func TestLoadHarnessArgs_ResolvesActiveWhenEmpty(t *testing.T) {
	setupFakeLoreData(t, "opencode", nil)
	writeHarnessArgs(t, map[string][]string{
		"opencode": {"--from-active"},
	})
	got := LoadHarnessArgs("")
	if len(got) != 1 || got[0] != "--from-active" {
		t.Errorf("got %v, want [--from-active]", got)
	}
}

func TestLoadHarnessArgs_EnvOverride(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	writeHarnessArgs(t, map[string][]string{
		"claude-code": {"--from-file"},
	})
	t.Setenv("LORE_HARNESS_ARGS", `["--from-env"]`)
	got := LoadHarnessArgs("claude-code")
	if len(got) != 1 || got[0] != "--from-env" {
		t.Errorf("got %v, want [--from-env]", got)
	}
}

func TestLoadHarnessArgs_NonClaudeCodeDefaultsEmpty(t *testing.T) {
	setupFakeLoreData(t, "opencode", nil)
	got := LoadHarnessArgs("opencode")
	if len(got) != 0 {
		t.Errorf("got %v, want empty (opencode has no built-in default)", got)
	}
}

func TestLoadClaudeConfig_DeprecatedAlias(t *testing.T) {
	setupFakeLoreData(t, "opencode", nil)
	writeHarnessArgs(t, map[string][]string{
		"claude-code": {"--from-claude-slot"},
	})
	got := LoadClaudeConfig()
	if len(got.Args) != 1 || got.Args[0] != "--from-claude-slot" {
		t.Errorf("got %v, want [--from-claude-slot] (alias must always read claude-code slot)", got.Args)
	}
}

func TestMigrateClaudeArgsToHarnessArgs(t *testing.T) {
	dataDir := setupFakeLoreData(t, "claude-code", nil)
	// Stage a legacy claude.json with custom args.
	legacyPath := filepath.Join(dataDir, "config", "claude.json")
	legacy := ClaudeConfig{Args: []string{"--legacy-a", "--legacy-b"}}
	data, _ := json.Marshal(legacy)
	if err := os.WriteFile(legacyPath, data, 0644); err != nil {
		t.Fatal(err)
	}
	// Confirm harness-args.json doesn't exist yet.
	newPath := filepath.Join(dataDir, "config", "harness-args.json")
	if _, err := os.Stat(newPath); err == nil {
		t.Fatal("harness-args.json should not exist before migration")
	}
	// Run migration.
	if err := MigrateClaudeArgsToHarnessArgs(); err != nil {
		t.Fatalf("MigrateClaudeArgsToHarnessArgs: %v", err)
	}
	// Confirm new file written and legacy untouched.
	got, err := os.ReadFile(newPath)
	if err != nil {
		t.Fatalf("reading %s: %v", newPath, err)
	}
	var parsed map[string]any
	if err := json.Unmarshal(got, &parsed); err != nil {
		t.Fatalf("parse harness-args.json: %v", err)
	}
	if parsed["_deprecated_legacy_source"] == nil {
		t.Error("missing _deprecated_legacy_source after migration")
	}
	cc, ok := parsed["claude-code"].(map[string]any)
	if !ok {
		t.Fatalf("claude-code key missing/wrong shape: %v", parsed["claude-code"])
	}
	args, ok := cc["args"].([]any)
	if !ok || len(args) != 2 {
		t.Fatalf("args wrong shape/len: %v", cc["args"])
	}
	// Confirm idempotence: second call is no-op.
	if err := MigrateClaudeArgsToHarnessArgs(); err != nil {
		t.Fatalf("idempotent migration failed: %v", err)
	}
}

func TestResolveModelForRole_FromUserConfig(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{
		"default":    "sonnet",
		"lead":       "opus",
		"worker":     "sonnet",
		"researcher": "sonnet",
		"reviewer":   "sonnet",
		"judge":      "haiku",
		"summarizer": "sonnet",
	})
	cases := []struct {
		role string
		want string
	}{
		{"lead", "opus"},
		{"judge", "haiku"},
		{"worker", "sonnet"},
		{"default", "sonnet"},
	}
	for _, c := range cases {
		got, err := ResolveModelForRole(c.role)
		if err != nil {
			t.Errorf("role=%s: unexpected error: %v", c.role, err)
			continue
		}
		if got != c.want {
			t.Errorf("role=%s: got=%q want=%q", c.role, got, c.want)
		}
	}
}

func TestResolveModelForRole_EnvOverride(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{
		"default": "sonnet",
		"lead":    "opus",
	})
	t.Setenv("LORE_MODEL_LEAD", "haiku")
	got, err := ResolveModelForRole("lead")
	if err != nil {
		t.Fatalf("ResolveModelForRole: %v", err)
	}
	if got != "haiku" {
		t.Errorf("got %q, want haiku (env should beat user config)", got)
	}
}

func TestResolveModelForRole_DefaultFallback(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{
		"default": "sonnet",
		// no per-role bindings
	})
	got, err := ResolveModelForRole("worker")
	if err != nil {
		t.Fatalf("ResolveModelForRole: %v", err)
	}
	if got != "sonnet" {
		t.Errorf("got %q, want sonnet (should fall through to roles.default)", got)
	}
}

func TestResolveModelForRole_RejectsUnknown(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{"default": "sonnet"})
	_, err := ResolveModelForRole("bogus_role_xyz")
	if err == nil {
		t.Fatal("expected error for unknown role, got nil")
	}
	if !strings.Contains(err.Error(), "unknown role") {
		t.Errorf("error = %v, want substring %q", err, "unknown role")
	}
}

func TestResolveModelForRole_PerRepoConfigBeatsUserConfig(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{
		"default": "sonnet",
		"lead":    "opus",
	})
	// Stage a temp dir with .lore.config and chdir into it.
	repo := t.TempDir()
	if err := os.WriteFile(
		filepath.Join(repo, ".lore.config"),
		[]byte("repo=acme/x\nmodel_for_lead=foo-model\n"),
		0644,
	); err != nil {
		t.Fatal(err)
	}
	orig, _ := os.Getwd()
	if err := os.Chdir(repo); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(orig) })

	got, err := ResolveModelForRole("lead")
	if err != nil {
		t.Fatalf("ResolveModelForRole: %v", err)
	}
	if got != "foo-model" {
		t.Errorf("got %q, want foo-model (per-repo should beat user config)", got)
	}
}

func TestResolveModelForRole_RejectsEmpty(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	_, err := ResolveModelForRole("")
	if err == nil {
		t.Fatal("expected error for empty role, got nil")
	}
}

func TestHarnessDisplayName(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)

	cases := []struct {
		id   string
		want string
	}{
		{"claude-code", "Claude Code"},
		{"opencode", "OpenCode"},
		{"codex", "Codex"},
	}
	for _, tc := range cases {
		got := HarnessDisplayName(tc.id)
		if got != tc.want {
			t.Errorf("HarnessDisplayName(%q) = %q, want %q", tc.id, got, tc.want)
		}
	}
}

func TestHarnessDisplayName_EmptyResolvesActive(t *testing.T) {
	setupFakeLoreData(t, "opencode", nil)
	got := HarnessDisplayName("")
	if got != "OpenCode" {
		t.Errorf("HarnessDisplayName(\"\") under opencode = %q, want OpenCode", got)
	}
}

func TestHarnessDisplayName_UnknownFallsBackToId(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	got := HarnessDisplayName("not-a-real-harness")
	if got != "not-a-real-harness" {
		t.Errorf("HarnessDisplayName for unknown id = %q, want passthrough id", got)
	}
}
