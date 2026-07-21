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
// and an isolated settings.json so tests don't touch the user's config.
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
	harnesses := map[string]any{
		"claude-code": map[string]any{"args": DefaultClaudeArgs()},
		"opencode":    map[string]any{"args": []string{}},
		"codex":       map[string]any{"args": []string{}},
	}
	if roles != nil {
		harnesses[framework].(map[string]any)["roles"] = roles
	}
	cfg := map[string]any{
		"version":              1,
		"tui_launch_framework": framework,
		"capability_overrides": map[string]string{},
		"harnesses":            harnesses,
	}
	data, _ := json.MarshalIndent(cfg, "", "  ")
	if err := os.WriteFile(filepath.Join(configDir, "settings.json"), data, 0644); err != nil {
		t.Fatal(err)
	}

	t.Setenv("LORE_DATA_DIR", dataDir)
	// Ensure no env-side framework override leaks in.
	t.Setenv("LORE_FRAMEWORK", "")
	return dataDir
}

func TestResolveActiveFramework(t *testing.T) {
	setupFakeLoreData(t, "opencode", nil)

	got, err := ResolveActiveFramework()
	if err != nil {
		t.Fatalf("ResolveActiveFramework: %v", err)
	}
	if got != "claude-code" {
		t.Errorf("got %q, want claude-code default despite TUI preference", got)
	}
}

func TestResolveTUILaunchFramework(t *testing.T) {
	setupFakeLoreData(t, "opencode", nil)

	got, err := ResolveTUILaunchFramework()
	if err != nil {
		t.Fatalf("ResolveTUILaunchFramework: %v", err)
	}
	if got != "opencode" {
		t.Errorf("got %q, want opencode", got)
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
	t.Setenv("LORE_FRAMEWORK", "opencode")

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

func TestResolveHarnessInstallPath_OpenCode(t *testing.T) {
	setupFakeLoreData(t, "opencode", nil)
	t.Setenv("LORE_FRAMEWORK", "opencode")
	home, _ := os.UserHomeDir()

	cases := []struct {
		kind string
		want string
	}{
		{"instructions", filepath.Join(home, ".config", "opencode", "AGENTS.md")},
		{"skills", filepath.Join(home, ".agents", "skills")},
		{"agents", filepath.Join(home, ".claude", "agents")},
		{"settings", filepath.Join(home, ".config", "opencode", "config.json")},
		{"mcp_servers", filepath.Join(home, ".config", "opencode", "opencode.json")},
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

func TestResolveHarnessInstallPath_Codex(t *testing.T) {
	setupFakeLoreData(t, "codex", nil)
	t.Setenv("LORE_FRAMEWORK", "codex")
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

func TestHarnessBinary(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	cases := []struct {
		framework string
		want      string
	}{
		{"claude-code", "claude"},
		{"opencode", "opencode"},
		{"codex", "codex"},
	}
	for _, c := range cases {
		got, err := HarnessBinary(c.framework)
		if err != nil {
			t.Errorf("HarnessBinary(%q): %v", c.framework, err)
			continue
		}
		if got != c.want {
			t.Errorf("HarnessBinary(%q) = %q, want %q", c.framework, got, c.want)
		}
	}
}

func TestHarnessBinary_ResolvesActiveWhenEmpty(t *testing.T) {
	setupFakeLoreData(t, "opencode", nil)
	t.Setenv("LORE_FRAMEWORK", "opencode")
	got, err := HarnessBinary("")
	if err != nil {
		t.Fatalf("HarnessBinary(\"\"): %v", err)
	}
	if got != "opencode" {
		t.Errorf("HarnessBinary(\"\") on opencode = %q, want %q", got, "opencode")
	}
}

func TestHarnessBinary_RejectsUnknown(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	_, err := HarnessBinary("bogus")
	if err == nil {
		t.Fatal("expected error for unknown framework, got nil")
	}
	if !strings.Contains(err.Error(), "unknown framework") {
		t.Errorf("error = %v, want substring %q", err, "unknown framework")
	}
}

func TestHarnessSystemPromptFlag(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	cases := []struct {
		framework     string
		wantFlag      string
		wantSupported bool
	}{
		{"claude-code", "--append-system-prompt", true},
		{"opencode", "", false},
		{"codex", "", false},
	}
	for _, c := range cases {
		gotFlag, gotSupported, err := HarnessSystemPromptFlag(c.framework)
		if err != nil {
			t.Errorf("HarnessSystemPromptFlag(%q): %v", c.framework, err)
			continue
		}
		if gotFlag != c.wantFlag || gotSupported != c.wantSupported {
			t.Errorf("HarnessSystemPromptFlag(%q) = (%q, %v), want (%q, %v)", c.framework, gotFlag, gotSupported, c.wantFlag, c.wantSupported)
		}
	}
}

func TestHarnessSystemPromptFlag_ResolvesActiveWhenEmpty(t *testing.T) {
	setupFakeLoreData(t, "opencode", nil)
	t.Setenv("LORE_FRAMEWORK", "opencode")
	gotFlag, gotSupported, err := HarnessSystemPromptFlag("")
	if err != nil {
		t.Fatalf("HarnessSystemPromptFlag(\"\"): %v", err)
	}
	if gotFlag != "" || gotSupported {
		t.Errorf("HarnessSystemPromptFlag(\"\") on opencode = (%q, %v), want (\"\", false)", gotFlag, gotSupported)
	}
}

func TestHarnessSystemPromptFlag_RejectsUnknown(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	_, _, err := HarnessSystemPromptFlag("bogus")
	if err == nil {
		t.Fatal("expected error for unknown framework, got nil")
	}
	if !strings.Contains(err.Error(), "unknown framework") {
		t.Errorf("error = %v, want substring %q", err, "unknown framework")
	}
}

func TestHarnessSettingsOverrideFlag(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	cases := []struct {
		framework     string
		wantFlag      string
		wantSupported bool
	}{
		{"claude-code", "--settings", true},
		{"opencode", "", false},
		{"codex", "", false},
	}
	for _, c := range cases {
		gotFlag, gotSupported, err := HarnessSettingsOverrideFlag(c.framework)
		if err != nil {
			t.Errorf("HarnessSettingsOverrideFlag(%q): %v", c.framework, err)
			continue
		}
		if gotFlag != c.wantFlag || gotSupported != c.wantSupported {
			t.Errorf("HarnessSettingsOverrideFlag(%q) = (%q, %v), want (%q, %v)", c.framework, gotFlag, gotSupported, c.wantFlag, c.wantSupported)
		}
	}
}

func TestHarnessSettingsOverrideFlag_RejectsUnknown(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	_, _, err := HarnessSettingsOverrideFlag("bogus")
	if err == nil {
		t.Fatal("expected error for unknown framework, got nil")
	}
}

func TestHarnessGracefulExitSequence(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	cases := []struct {
		framework     string
		wantSeq       string
		wantSupported bool
	}{
		{"claude-code", "\x03\x03", true}, // Ctrl-C twice
		{"opencode", "\x03", true},        // single Ctrl-C from idle
		{"codex", "\x03", true},           // single Ctrl-C on empty composer
	}
	for _, c := range cases {
		gotSeq, gotSupported, err := HarnessGracefulExitSequence(c.framework)
		if err != nil {
			t.Errorf("HarnessGracefulExitSequence(%q): %v", c.framework, err)
			continue
		}
		if gotSeq != c.wantSeq || gotSupported != c.wantSupported {
			t.Errorf("HarnessGracefulExitSequence(%q) = (%q, %v), want (%q, %v)", c.framework, gotSeq, gotSupported, c.wantSeq, c.wantSupported)
		}
	}
}

// An unknown framework degrades to not-supported rather than erroring: a harness
// without a probed interaction row is a state the close path must skip-with-notice
// on, not crash — so the reader returns not-supported rather than an error.
func TestHarnessGracefulExitSequence_UnknownDegrades(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	seq, supported, err := HarnessGracefulExitSequence("bogus")
	if err != nil {
		t.Fatalf("HarnessGracefulExitSequence(bogus): unexpected error %v", err)
	}
	if seq != "" || supported {
		t.Errorf("HarnessGracefulExitSequence(bogus) = (%q, %v), want (\"\", false)", seq, supported)
	}
}

func TestHarnessSpendTelemetry(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	cases := []struct {
		framework   string
		wantSupport string
		wantArtact  string
		wantBinding string
	}{
		{"claude-code", "full", "transcript", "session-id-flag"},
		{"opencode", "partial", "store", "none"},
		{"codex", "partial", "rollout", "none"},
	}
	for _, c := range cases {
		support, artifact, binding, ok, err := HarnessSpendTelemetry(c.framework)
		if err != nil {
			t.Errorf("HarnessSpendTelemetry(%q): %v", c.framework, err)
			continue
		}
		if !ok {
			t.Errorf("HarnessSpendTelemetry(%q): expected a usable spend block", c.framework)
			continue
		}
		if support != c.wantSupport || artifact != c.wantArtact || binding != c.wantBinding {
			t.Errorf("HarnessSpendTelemetry(%q) = (%q, %q, %q), want (%q, %q, %q)",
				c.framework, support, artifact, binding, c.wantSupport, c.wantArtact, c.wantBinding)
		}
	}
}

// An unknown framework degrades to not-supported rather than erroring, mirroring
// the interaction readers: the close path falls back to duration-only rather than
// crashing on a harness with no probed spend block.
func TestHarnessSpendTelemetry_UnknownDegrades(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	support, artifact, binding, ok, err := HarnessSpendTelemetry("bogus")
	if err != nil {
		t.Fatalf("HarnessSpendTelemetry(bogus): unexpected error %v", err)
	}
	if ok || support != "" || artifact != "" || binding != "" {
		t.Errorf("HarnessSpendTelemetry(bogus) = (%q, %q, %q, %v), want empty + false", support, artifact, binding, ok)
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

// writeHarnessArgs helper writes harness args into settings.json under the
// staged LORE_DATA_DIR. Used by tests that verify LoadHarnessArgs precedence.
func writeHarnessArgs(t *testing.T, perFramework map[string][]string) {
	t.Helper()
	dataDir := os.Getenv("LORE_DATA_DIR")
	if dataDir == "" {
		t.Fatal("LORE_DATA_DIR not set; call setupFakeLoreData first")
	}
	path := filepath.Join(dataDir, "config", "settings.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	harnesses, _ := out["harnesses"].(map[string]any)
	if harnesses == nil {
		harnesses = map[string]any{}
		out["harnesses"] = harnesses
	}
	for fw, args := range perFramework {
		block, _ := harnesses[fw].(map[string]any)
		if block == nil {
			block = map[string]any{}
			harnesses[fw] = block
		}
		block["args"] = args
	}
	data, _ := json.MarshalIndent(out, "", "  ")
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
	t.Setenv("LORE_FRAMEWORK", "opencode")
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

// writeHarnessAutonomousArgs writes the autonomous-session arg profile into
// settings.json under harnesses.<fw>.autonomous_args, alongside whatever `args`
// writeHarnessArgs already staged. Used by the initiator-aware selection tests.
func writeHarnessAutonomousArgs(t *testing.T, perFramework map[string][]string) {
	t.Helper()
	dataDir := os.Getenv("LORE_DATA_DIR")
	if dataDir == "" {
		t.Fatal("LORE_DATA_DIR not set; call setupFakeLoreData first")
	}
	path := filepath.Join(dataDir, "config", "settings.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	harnesses, _ := out["harnesses"].(map[string]any)
	if harnesses == nil {
		harnesses = map[string]any{}
		out["harnesses"] = harnesses
	}
	for fw, args := range perFramework {
		block, _ := harnesses[fw].(map[string]any)
		if block == nil {
			block = map[string]any{}
			harnesses[fw] = block
		}
		block["autonomous_args"] = args
	}
	data, _ := json.MarshalIndent(out, "", "  ")
	if err := os.WriteFile(path, data, 0644); err != nil {
		t.Fatal(err)
	}
}

// Agent-initiated spawn with an autonomous profile present uses it.
func TestLoadHarnessArgsForInitiator_AgentUsesAutonomous(t *testing.T) {
	setupFakeLoreData(t, "codex", nil)
	writeHarnessArgs(t, map[string][]string{
		"codex": {"--ask-for-approval", "on-request"},
	})
	writeHarnessAutonomousArgs(t, map[string][]string{
		"codex": {"--ask-for-approval", "never"},
	})
	got := LoadHarnessArgsForInitiator("codex", "agent")
	want := []string{"--ask-for-approval", "never"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Errorf("agent+autonomous_args: got %v, want %v", got, want)
	}
}

// Agent-initiated spawn with no autonomous profile falls through to args.
func TestLoadHarnessArgsForInitiator_AgentNoKeyUsesArgs(t *testing.T) {
	setupFakeLoreData(t, "codex", nil)
	writeHarnessArgs(t, map[string][]string{
		"codex": {"--ask-for-approval", "on-request"},
	})
	got := LoadHarnessArgsForInitiator("codex", "agent")
	want := []string{"--ask-for-approval", "on-request"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Errorf("agent+no-key: got %v, want %v (must equal args)", got, want)
	}
}

// Human-initiated spawn ignores the autonomous profile even when present.
func TestLoadHarnessArgsForInitiator_HumanUsesArgs(t *testing.T) {
	setupFakeLoreData(t, "codex", nil)
	writeHarnessArgs(t, map[string][]string{
		"codex": {"--ask-for-approval", "on-request"},
	})
	writeHarnessAutonomousArgs(t, map[string][]string{
		"codex": {"--ask-for-approval", "never"},
	})
	got := LoadHarnessArgsForInitiator("codex", "human")
	want := []string{"--ask-for-approval", "on-request"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Errorf("human+autonomous_args present: got %v, want %v (must equal args)", got, want)
	}
}

// The LORE_HARNESS_ARGS env override outranks the autonomous profile.
func TestLoadHarnessArgsForInitiator_EnvOverridesAutonomous(t *testing.T) {
	setupFakeLoreData(t, "codex", nil)
	writeHarnessAutonomousArgs(t, map[string][]string{
		"codex": {"--ask-for-approval", "never"},
	})
	t.Setenv("LORE_HARNESS_ARGS", `["--from-env"]`)
	got := LoadHarnessArgsForInitiator("codex", "agent")
	if len(got) != 1 || got[0] != "--from-env" {
		t.Errorf("env override: got %v, want [--from-env]", got)
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
	if err := MigrateClaudeArgsToHarnessArgs(); err != nil {
		t.Fatalf("MigrateClaudeArgsToHarnessArgs: %v", err)
	}
	if _, err := os.Stat(newPath); !os.IsNotExist(err) {
		t.Fatalf("migration compatibility shim should not create harness-args.json, stat err=%v", err)
	}
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

// writeCeremonyRoles stages a `ceremony_roles` block on the given framework in
// the isolated settings.json. Call after setupFakeLoreData; existing `roles`
// bindings are preserved. Mirrors the bash ceremony-layer fixtures in
// tests/frameworks/roles.bats.
func writeCeremonyRoles(t *testing.T, framework string, ceremonyRoles map[string]map[string]string) {
	t.Helper()
	dataDir := os.Getenv("LORE_DATA_DIR")
	if dataDir == "" {
		t.Fatal("LORE_DATA_DIR not set; call setupFakeLoreData first")
	}
	path := filepath.Join(dataDir, "config", "settings.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	harnesses, _ := out["harnesses"].(map[string]any)
	if harnesses == nil {
		harnesses = map[string]any{}
		out["harnesses"] = harnesses
	}
	block, _ := harnesses[framework].(map[string]any)
	if block == nil {
		block = map[string]any{}
		harnesses[framework] = block
	}
	block["ceremony_roles"] = ceremonyRoles
	data, _ := json.MarshalIndent(out, "", "  ")
	if err := os.WriteFile(path, data, 0644); err != nil {
		t.Fatal(err)
	}
}

func TestResolveModelForRoleInCeremony_CeremonyBindingBeatsRoleOverlay(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{"researcher": "opus"})
	writeCeremonyRoles(t, "claude-code", map[string]map[string]string{
		"spec": {"researcher": "haiku"},
	})
	got, err := ResolveModelForRoleInCeremony("researcher", "spec")
	if err != nil {
		t.Fatalf("ResolveModelForRoleInCeremony: %v", err)
	}
	if got != "haiku" {
		t.Errorf("got %q, want haiku (ceremony binding should beat role overlay)", got)
	}
}

func TestResolveModelForRoleInCeremony_FallsThroughWhenCeremonyKeyAbsent(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{"researcher": "opus"})
	// A present-but-non-matching ceremony (implement) must fall through to the
	// role overlay for a spec query.
	writeCeremonyRoles(t, "claude-code", map[string]map[string]string{
		"implement": {"researcher": "haiku"},
	})
	got, err := ResolveModelForRoleInCeremony("researcher", "spec")
	if err != nil {
		t.Fatalf("ResolveModelForRoleInCeremony: %v", err)
	}
	if got != "opus" {
		t.Errorf("got %q, want opus (should fall through to role overlay)", got)
	}
}

func TestResolveModelForRoleInCeremony_FallsThroughWhenRoleAbsentInCeremonyMap(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{"researcher": "opus", "lead": "sonnet"})
	writeCeremonyRoles(t, "claude-code", map[string]map[string]string{
		"spec": {"lead": "fable"},
	})
	got, err := ResolveModelForRoleInCeremony("researcher", "spec")
	if err != nil {
		t.Fatalf("ResolveModelForRoleInCeremony: %v", err)
	}
	if got != "opus" {
		t.Errorf("got %q, want opus (role absent in ceremony map should fall through)", got)
	}
}

func TestResolveModelForRole_RoleOnlyIgnoresCeremonyRoles(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{"researcher": "opus"})
	writeCeremonyRoles(t, "claude-code", map[string]map[string]string{
		"spec": {"researcher": "haiku"},
	})
	// Role-only resolution must be byte-identical to pre-ceremony behavior.
	got, err := ResolveModelForRole("researcher")
	if err != nil {
		t.Fatalf("ResolveModelForRole: %v", err)
	}
	if got != "opus" {
		t.Errorf("got %q, want opus (role-only must ignore ceremony_roles)", got)
	}
}

func TestResolveModelForRoleInCeremony_EnvBeatsCeremony(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{"researcher": "opus"})
	writeCeremonyRoles(t, "claude-code", map[string]map[string]string{
		"spec": {"researcher": "haiku"},
	})
	t.Setenv("LORE_MODEL_RESEARCHER", "sonnet")
	got, err := ResolveModelForRoleInCeremony("researcher", "spec")
	if err != nil {
		t.Fatalf("ResolveModelForRoleInCeremony: %v", err)
	}
	if got != "sonnet" {
		t.Errorf("got %q, want sonnet (env override should beat ceremony binding)", got)
	}
}

func TestResolveModelForRoleInCeremony_RejectsUnknownCeremonyInQuery(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{"researcher": "opus"})
	_, err := ResolveModelForRoleInCeremony("researcher", "bogus_ceremony")
	if err == nil {
		t.Fatal("expected error for unknown ceremony in query, got nil")
	}
	if !strings.Contains(err.Error(), "unknown ceremony") {
		t.Errorf("error = %v, want substring %q", err, "unknown ceremony")
	}
}

func TestResolveModelForRoleInCeremony_RejectsUnknownCeremonyKeyStored(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{"researcher": "opus"})
	writeCeremonyRoles(t, "claude-code", map[string]map[string]string{
		"deploy": {"researcher": "haiku"},
	})
	_, err := ResolveModelForRoleInCeremony("researcher", "spec")
	if err == nil {
		t.Fatal("expected error for unknown ceremony key stored under ceremony_roles, got nil")
	}
	if !strings.Contains(err.Error(), "unknown ceremony") || !strings.Contains(err.Error(), "deploy") {
		t.Errorf("error = %v, want substrings %q and %q", err, "unknown ceremony", "deploy")
	}
}

func TestResolveModelForRoleInCeremony_RejectsUnknownRoleKeyInCeremonyMap(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{"researcher": "opus"})
	writeCeremonyRoles(t, "claude-code", map[string]map[string]string{
		"spec": {"spectator": "haiku"},
	})
	_, err := ResolveModelForRoleInCeremony("researcher", "spec")
	if err == nil {
		t.Fatal("expected error for unknown role key inside a ceremony map, got nil")
	}
	if !strings.Contains(err.Error(), "unknown role") || !strings.Contains(err.Error(), "spectator") {
		t.Errorf("error = %v, want substrings %q and %q", err, "unknown role", "spectator")
	}
	if !strings.Contains(err.Error(), "roles.json") {
		t.Errorf("error = %v, want substring %q", err, "roles.json")
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
	t.Setenv("LORE_FRAMEWORK", "opencode")
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

// --- Class-qualified worker role fallback (D2) --------------------------------
// These mirror the bash coverage in tests/frameworks/roles.bats; the two
// resolvers must agree byte-for-byte on the fallback semantics.

func TestResolveModelForRole_ClassRoleFallsBackToWorkerOverlay(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{"worker": "sonnet"})
	got, err := ResolveModelForRoleInCeremony("worker-mechanical", "implement")
	if err != nil {
		t.Fatalf("ResolveModelForRoleInCeremony: %v", err)
	}
	want, _ := ResolveModelForRoleInCeremony("worker", "implement")
	if got != "sonnet" || got != want {
		t.Errorf("worker-mechanical=%q worker=%q, want both sonnet", got, want)
	}
}

func TestResolveModelForRole_ClassRoleFallsThroughToDefault(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{"default": "opus"})
	got, err := ResolveModelForRoleInCeremony("worker-judgment-dense", "implement")
	if err != nil {
		t.Fatalf("ResolveModelForRoleInCeremony: %v", err)
	}
	want, _ := ResolveModelForRoleInCeremony("worker", "implement")
	if got != "opus" || got != want {
		t.Errorf("worker-judgment-dense=%q worker=%q, want both opus", got, want)
	}
}

func TestResolveModelForRole_ClassRoleCeremonyBindingWins(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{"worker": "sonnet"})
	writeCeremonyRoles(t, "claude-code", map[string]map[string]string{
		"implement": {"worker-mechanical": "haiku"},
	})
	got, err := ResolveModelForRoleInCeremony("worker-mechanical", "implement")
	if err != nil {
		t.Fatalf("ResolveModelForRoleInCeremony: %v", err)
	}
	if got != "haiku" {
		t.Errorf("got %q, want haiku (ceremony binding beats the fallback)", got)
	}
}

func TestResolveModelForRole_ClassRoleOverlayBindingWins(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{
		"worker":            "sonnet",
		"worker-mechanical": "haiku",
	})
	got, err := ResolveModelForRoleInCeremony("worker-mechanical", "implement")
	if err != nil {
		t.Fatalf("ResolveModelForRoleInCeremony: %v", err)
	}
	if got != "haiku" {
		t.Errorf("got %q, want haiku (own role overlay beats the fallback)", got)
	}
}

func TestResolveModelForRole_ClassRoleEnvOverrideUnderscoreName(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{"worker": "sonnet"})
	t.Setenv("LORE_MODEL_WORKER_MECHANICAL", "mech-model")
	got, err := ResolveModelForRoleInCeremony("worker-mechanical", "implement")
	if err != nil {
		t.Fatalf("ResolveModelForRoleInCeremony: %v", err)
	}
	if got != "mech-model" {
		t.Errorf("got %q, want mech-model (env override uses underscore name)", got)
	}
}

func TestResolveModelForRole_ClassRoleErrorsNamingWorkerWhenUnbound(t *testing.T) {
	setupFakeLoreData(t, "claude-code", nil)
	_, err := ResolveModelForRoleInCeremony("worker-mechanical", "implement")
	if err == nil {
		t.Fatal("expected error when neither class role nor worker is bound")
	}
	if !strings.Contains(err.Error(), `role "worker"`) {
		t.Errorf("error = %v, want it to name the fallback role \"worker\"", err)
	}
}

func TestResolveRouteForRole_UnqualifiedOpenCodeProviderBinding(t *testing.T) {
	setupFakeLoreData(t, "opencode", map[string]string{"worker": "openai/gpt-5.5"})
	t.Setenv("LORE_FRAMEWORK", "opencode")
	route, err := ResolveRouteForRoleInCeremony("worker", "implement")
	if err != nil {
		t.Fatalf("ResolveRouteForRoleInCeremony: %v", err)
	}
	want := ModelRoute{"openai/gpt-5.5", "opencode", "opencode", "openai/gpt-5.5", false}
	if route != want {
		t.Errorf("route = %#v, want %#v", route, want)
	}
}

func TestResolveRouteForRole_QualifiedCodexTarget(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{"worker-mechanical": "codex/gpt-5.5-medium"})
	t.Setenv("LORE_FRAMEWORK", "claude-code")
	route, err := ResolveRouteForRoleInCeremony("worker-mechanical", "implement")
	if err != nil {
		t.Fatalf("ResolveRouteForRoleInCeremony: %v", err)
	}
	want := ModelRoute{"codex/gpt-5.5-medium", "claude-code", "codex", "gpt-5.5-medium", true}
	if route != want {
		t.Errorf("route = %#v, want %#v", route, want)
	}
}

func TestResolveRouteForRole_ClassFallbackMatchesWorkerRoute(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{"worker": "codex/gpt-5.5-high"})
	t.Setenv("LORE_FRAMEWORK", "claude-code")
	classRoute, err := ResolveRouteForRoleInCeremony("worker-judgment-dense", "implement")
	if err != nil {
		t.Fatalf("class route: %v", err)
	}
	workerRoute, err := ResolveRouteForRoleInCeremony("worker", "implement")
	if err != nil {
		t.Fatalf("worker route: %v", err)
	}
	if classRoute != workerRoute {
		t.Errorf("class route = %#v, worker route = %#v", classRoute, workerRoute)
	}
}

func TestResolveRouteForRole_RejectsMalformedQualifier(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{"worker": "codex/"})
	t.Setenv("LORE_FRAMEWORK", "claude-code")
	_, err := ResolveRouteForRole("worker")
	if err == nil || !strings.Contains(err.Error(), "empty native binding") {
		t.Fatalf("error = %v, want malformed qualifier rejection", err)
	}
}

func TestResolveRouteForRole_ValidatesSelectedTargetShape(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{"worker": "codex/openai/gpt-5.5"})
	t.Setenv("LORE_FRAMEWORK", "claude-code")
	_, err := ResolveRouteForRole("worker")
	if err == nil || !strings.Contains(err.Error(), "target framework \"codex\"") {
		t.Fatalf("error = %v, want target-native shape rejection", err)
	}
}

func TestResolveRouteForRole_RejectsUnsupportedForeignBridge(t *testing.T) {
	setupFakeLoreData(t, "claude-code", map[string]string{"worker": "opencode/openai/gpt-5.5"})
	t.Setenv("LORE_FRAMEWORK", "claude-code")
	_, err := ResolveRouteForRole("worker")
	if err == nil || !strings.Contains(err.Error(), "claude-code->opencode") {
		t.Fatalf("error = %v, want named unsupported bridge", err)
	}
}
