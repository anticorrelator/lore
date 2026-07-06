package work

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

// TUI launch smoke tests (T26): assert StartTerminalCmd spawns the
// framework-resolved binary, prepends the harness-args, and routes the two
// TUI-injected concerns (append_system_prompt, inline_settings_override)
// through the adapter contract — including the explicit-skip degradation when
// a harness reports the kind as `unsupported` in adapters/capabilities.json.
//
// The tests stage a fake LORE_DATA_DIR (mirroring the framework_test.go
// pattern) plus a fake $PATH containing executable stubs for `claude`,
// `opencode`, `codex`, and `lore`. We invoke StartTerminalCmd's tea.Cmd, then
// inspect the SessionProcessStartedMsg.Cmd.Path / Cmd.Args before the subprocess
// exits — verifying what was *spawned* without depending on the real harness
// being installed.

// stageFakeBinaries writes shell-script stubs for claude, opencode, codex, and
// lore into a tempdir, prepends that dir to PATH for the test, and returns the
// directory. The stubs all sleep briefly so the parent has time to inspect the
// PTY-spawned process before it exits.
//
// The `lore` stub special-cases `followup view --json <id>`: it emits a
// minimal valid JSON envelope so loadFollowupContext returns a non-empty
// system prompt and the followup-mode args path runs.
func stageFakeBinaries(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()

	// Generic harness stub: print args and sleep so the parent can read the
	// SessionProcessStartedMsg before the subprocess exits.
	harnessStub := "#!/bin/sh\nprintf '%s\\n' \"$@\"\nsleep 1\n"
	for _, name := range []string{"claude", "opencode", "codex"} {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(harnessStub), 0755); err != nil {
			t.Fatalf("write %s stub: %v", name, err)
		}
	}

	// `lore followup view --json <id>` stub. Emits the minimum JSON shape that
	// loadFollowupContext's followupData unmarshals so the system-prompt path
	// produces a non-empty string.
	loreStub := `#!/bin/sh
if [ "$1" = "followup" ] && [ "$2" = "view" ]; then
  printf '%s' '{"title":"smoke","source":"test","status":"open","suggested_actions":[]}'
  exit 0
fi
exit 0
`
	if err := os.WriteFile(filepath.Join(dir, "lore"), []byte(loreStub), 0755); err != nil {
		t.Fatalf("write lore stub: %v", err)
	}

	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return dir
}

// stageFakeLoreData mirrors config/framework_test.go::setupFakeLoreData:
// stages a LORE_DATA_DIR with a symlink to scripts/ (so loreRepoDir resolves
// adapters/capabilities.json) and writes unified settings.json selecting the
// named framework. Optional per-framework harness args are written into
// settings.json when extra args are provided.
func stageFakeLoreData(t *testing.T, framework string, extraArgs []string) string {
	t.Helper()

	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	repoRoot := filepath.Clean(filepath.Join(wd, "..", "..", ".."))
	if _, err := os.Stat(filepath.Join(repoRoot, "adapters", "capabilities.json")); err != nil {
		t.Fatalf("expected repo root at %s but capabilities.json missing: %v", repoRoot, err)
	}

	dataDir := t.TempDir()
	if err := os.Symlink(filepath.Join(repoRoot, "scripts"), filepath.Join(dataDir, "scripts")); err != nil {
		t.Fatal(err)
	}
	configDir := filepath.Join(dataDir, "config")
	if err := os.MkdirAll(configDir, 0755); err != nil {
		t.Fatal(err)
	}
	harnesses := map[string]any{
		"claude-code": map[string]any{"args": []string{}},
		"opencode":    map[string]any{"args": []string{}},
		"codex":       map[string]any{"args": []string{}},
	}
	if extraArgs != nil {
		harnesses[framework].(map[string]any)["args"] = extraArgs
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
	t.Setenv("LORE_FRAMEWORK", "")
	// Suppress the claude-code built-in `--dangerously-skip-permissions`
	// default by setting an explicit empty harness-args env override when no
	// extra args were requested. Keeps assertions deterministic across
	// frameworks.
	if extraArgs == nil {
		t.Setenv("LORE_HARNESS_ARGS", "[]")
	} else {
		t.Setenv("LORE_HARNESS_ARGS", "")
	}
	return dataDir
}

// runStartTerminal invokes StartTerminalCmd's tea.Cmd and returns either the
// SessionProcessStartedMsg or the StreamErrorMsg. Closes the PTY immediately so
// the subprocess teardown path runs cleanly.
func runStartTerminal(t *testing.T, slug, projectDir string, followupMode bool) tea.Msg {
	t.Helper()
	// width=80, height=24 are typical PTY defaults; the values aren't
	// load-bearing for the args we assert.
	d := SessionDescriptor{Type: SessionSpec, Slug: slug, Title: "smoke title", SkipConfirm: true, FollowupMode: followupMode, FindingIndex: -1}
	cmd := StartTerminalCmd(d, projectDir, 80, 24, projectDir, SessionEnv{}, false)
	msg := cmd()
	if started, ok := msg.(SessionProcessStartedMsg); ok {
		// Close the PTY so the stub subprocess receives EOF and exits without
		// leaving zombies. The reader goroutine drains via the channel close.
		if started.Ptmx != nil {
			_ = started.Ptmx.Close()
		}
	}
	return msg
}

func TestStartTerminalCmd_SpawnsClaudeBinaryWithDefaultFlags(t *testing.T) {
	stageFakeBinaries(t)
	dir := stageFakeLoreData(t, "claude-code", nil)

	msg := runStartTerminal(t, "smoke-slug", dir, false)
	started, ok := msg.(SessionProcessStartedMsg)
	if !ok {
		t.Fatalf("expected SessionProcessStartedMsg, got %T (%+v)", msg, msg)
	}

	if !strings.HasSuffix(started.Cmd.Path, "/claude") {
		t.Errorf("Cmd.Path = %q, want suffix /claude", started.Cmd.Path)
	}
	if !envContains(started.Cmd.Env, "LORE_FRAMEWORK=claude-code") {
		t.Errorf("Cmd.Env missing LORE_FRAMEWORK=claude-code: %v", started.Cmd.Env)
	}
	// claude-code routes inline_settings_override through the adapter →
	// `--settings {}` should be in args. append_system_prompt is gated on
	// followupMode (off here), so it should NOT appear.
	if !argsContainPair(started.Cmd.Args, "--settings", "{}") {
		t.Errorf("Cmd.Args missing `--settings {}` for claude-code: %v", started.Cmd.Args)
	}
	if argsContains(started.Cmd.Args, "--append-system-prompt") {
		t.Errorf("Cmd.Args should NOT contain --append-system-prompt outside followup mode: %v", started.Cmd.Args)
	}
}

// TestStartTerminalCmd_ExportsSessionIdentity asserts the D3 session identity
// joins LORE_FRAMEWORK in the harness child's environment, and that an empty
// SessionEnv field is omitted rather than exported blank.
func TestStartTerminalCmd_ExportsSessionIdentity(t *testing.T) {
	stageFakeBinaries(t)
	dir := stageFakeLoreData(t, "claude-code", nil)

	d := SessionDescriptor{Type: SessionSpec, Slug: "smoke-slug", Title: "smoke title", SkipConfirm: true, FindingIndex: -1}
	cmd := StartTerminalCmd(d, dir, 80, 24, dir,
		SessionEnv{Instance: "amber-otter", Slug: "smoke-slug", Type: "spec"}, false)
	msg := cmd()
	started, ok := msg.(SessionProcessStartedMsg)
	if !ok {
		t.Fatalf("expected SessionProcessStartedMsg, got %T (%+v)", msg, msg)
	}
	if started.Ptmx != nil {
		_ = started.Ptmx.Close()
	}
	for _, want := range []string{
		"LORE_SESSION_INSTANCE=amber-otter",
		"LORE_SESSION_SLUG=smoke-slug",
		"LORE_SESSION_TYPE=spec",
	} {
		if !envContains(started.Cmd.Env, want) {
			t.Errorf("Cmd.Env missing %q: %v", want, started.Cmd.Env)
		}
	}
}

// TestSessionEnvVarsOmitsEmptyFields: a partially-populated identity exports
// only its non-empty vars — a downstream `[ -n "$LORE_SESSION_INSTANCE" ]`
// gate must never see a blank export.
func TestSessionEnvVarsOmitsEmptyFields(t *testing.T) {
	got := SessionEnv{Instance: "solo", Type: "chat"}.vars()
	want := []string{"LORE_SESSION_INSTANCE=solo", "LORE_SESSION_TYPE=chat"}
	if len(got) != len(want) {
		t.Fatalf("vars() = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("vars()[%d] = %q, want %q", i, got[i], want[i])
		}
	}
	if len(SessionEnv{}.vars()) != 0 {
		t.Errorf("zero SessionEnv should export nothing, got %v", SessionEnv{}.vars())
	}
}

// TestSessionEnvVars_RoutingOverrides asserts each routing override becomes a
// LORE_MODEL_<ROLE> var whose name is byte-identical to scripts/lib.sh
// resolve_model_for_role's env_var construction (uppercase + hyphens→underscores).
// The hyphenated role is the load-bearing case: worker-mechanical must map to
// LORE_MODEL_WORKER_MECHANICAL — the exact var the resolver's env layer reads —
// not LORE_MODEL_WORKER-MECHANICAL (an invalid shell identifier). Roles are
// sorted for a deterministic order and follow the LORE_SESSION_* vars.
func TestSessionEnvVars_RoutingOverrides(t *testing.T) {
	got := SessionEnv{
		Instance: "amber-otter",
		RoutingOverrides: map[string]string{
			"worker":            "opus",
			"worker-mechanical": "haiku",
		},
	}.vars()
	want := []string{
		"LORE_SESSION_INSTANCE=amber-otter",
		"LORE_MODEL_WORKER=opus",
		"LORE_MODEL_WORKER_MECHANICAL=haiku",
	}
	if len(got) != len(want) {
		t.Fatalf("vars() = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("vars()[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

// TestSessionEnvVars_RoutingOverridesSkipsBlank: a blank role or model never
// exports a var — the resolver's env layer reads "" as unset, so a blank export
// would be both meaningless and (for a blank role) an invalid identifier.
func TestSessionEnvVars_RoutingOverridesSkipsBlank(t *testing.T) {
	got := SessionEnv{
		RoutingOverrides: map[string]string{"worker": "", "": "opus"},
	}.vars()
	if len(got) != 0 {
		t.Errorf("blank role/model should export nothing, got %v", got)
	}
}

func TestStartTerminalCmd_PrependsHarnessArgs(t *testing.T) {
	stageFakeBinaries(t)
	dir := stageFakeLoreData(t, "claude-code", []string{"--my-prepended-flag"})

	msg := runStartTerminal(t, "smoke-slug", dir, false)
	started, ok := msg.(SessionProcessStartedMsg)
	if !ok {
		t.Fatalf("expected SessionProcessStartedMsg, got %T (%+v)", msg, msg)
	}

	// Cmd.Args[0] is argv[0] (the binary basename), so harness args start at [1].
	if len(started.Cmd.Args) < 2 || started.Cmd.Args[1] != "--my-prepended-flag" {
		t.Errorf("Cmd.Args[1] = %v (full: %v), want first prepended arg `--my-prepended-flag`",
			func() string {
				if len(started.Cmd.Args) >= 2 {
					return started.Cmd.Args[1]
				}
				return "<missing>"
			}(),
			started.Cmd.Args)
	}
}

func TestStartTerminalCmd_FollowupModeInjectsAppendSystemPromptOnClaudeCode(t *testing.T) {
	stageFakeBinaries(t)
	dir := stageFakeLoreData(t, "claude-code", nil)

	msg := runStartTerminal(t, "smoke-slug", dir, true)
	started, ok := msg.(SessionProcessStartedMsg)
	if !ok {
		t.Fatalf("expected SessionProcessStartedMsg, got %T (%+v)", msg, msg)
	}

	// Followup mode + a non-empty followup context should produce
	// `--append-system-prompt <text>` somewhere in the args.
	if !argsContains(started.Cmd.Args, "--append-system-prompt") {
		t.Errorf("Cmd.Args missing --append-system-prompt in followup mode on claude-code: %v",
			started.Cmd.Args)
	}
}

func TestStartTerminalCmd_OpenCodeSkipsUnsupportedConcerns(t *testing.T) {
	stageFakeBinaries(t)
	dir := stageFakeLoreData(t, "opencode", nil)

	// followupMode=true → exercises the append_system_prompt path; opencode
	// reports `unsupported` for both TUI launch flags and so should skip both.
	msg := runStartTerminal(t, "smoke-slug", dir, true)
	started, ok := msg.(SessionProcessStartedMsg)
	if !ok {
		t.Fatalf("expected SessionProcessStartedMsg, got %T (%+v)", msg, msg)
	}

	if !strings.HasSuffix(started.Cmd.Path, "/opencode") {
		t.Errorf("Cmd.Path = %q, want suffix /opencode", started.Cmd.Path)
	}
	if !envContains(started.Cmd.Env, "LORE_FRAMEWORK=opencode") {
		t.Errorf("Cmd.Env missing LORE_FRAMEWORK=opencode: %v", started.Cmd.Env)
	}
	// Both TUI-injected concerns should be skipped — substituting any
	// claude-specific flag would crash opencode on an unknown CLI argument.
	if argsContains(started.Cmd.Args, "--append-system-prompt") {
		t.Errorf("Cmd.Args contains --append-system-prompt on opencode (should be skipped per `unsupported`): %v",
			started.Cmd.Args)
	}
	if argsContains(started.Cmd.Args, "--settings") {
		t.Errorf("Cmd.Args contains --settings on opencode (should be skipped per `unsupported`): %v",
			started.Cmd.Args)
	}
}

func TestStartTerminalCmd_CodexSkipsUnsupportedConcerns(t *testing.T) {
	stageFakeBinaries(t)
	dir := stageFakeLoreData(t, "codex", nil)

	msg := runStartTerminal(t, "smoke-slug", dir, true)
	started, ok := msg.(SessionProcessStartedMsg)
	if !ok {
		t.Fatalf("expected SessionProcessStartedMsg, got %T (%+v)", msg, msg)
	}

	if !strings.HasSuffix(started.Cmd.Path, "/codex") {
		t.Errorf("Cmd.Path = %q, want suffix /codex", started.Cmd.Path)
	}
	if !envContains(started.Cmd.Env, "LORE_FRAMEWORK=codex") {
		t.Errorf("Cmd.Env missing LORE_FRAMEWORK=codex: %v", started.Cmd.Env)
	}
	if argsContains(started.Cmd.Args, "--append-system-prompt") {
		t.Errorf("Cmd.Args contains --append-system-prompt on codex (should be skipped per `unsupported`): %v",
			started.Cmd.Args)
	}
	if argsContains(started.Cmd.Args, "--settings") {
		t.Errorf("Cmd.Args contains --settings on codex (should be skipped per `unsupported`): %v",
			started.Cmd.Args)
	}
}

// TestStartTerminalCmd_InjectsSessionIDOnClaudeCode asserts the D3 deterministic
// transcript binding: claude-code declares spend_telemetry binding
// `session-id-flag`, so the spawn generates a UUID, passes it as --session-id,
// and hands it back on the message for teardown's spend probe. The flag value and
// the message field must be the same id.
func TestStartTerminalCmd_InjectsSessionIDOnClaudeCode(t *testing.T) {
	stageFakeBinaries(t)
	dir := stageFakeLoreData(t, "claude-code", nil)

	msg := runStartTerminal(t, "smoke-slug", dir, false)
	started, ok := msg.(SessionProcessStartedMsg)
	if !ok {
		t.Fatalf("expected SessionProcessStartedMsg, got %T (%+v)", msg, msg)
	}

	flagVal := argValueAfter(started.Cmd.Args, "--session-id")
	if flagVal == "" {
		t.Fatalf("Cmd.Args missing `--session-id <uuid>` for claude-code: %v", started.Cmd.Args)
	}
	if len(flagVal) != 36 {
		t.Errorf("--session-id value %q is not a 36-char UUID", flagVal)
	}
	if started.SessionID != flagVal {
		t.Errorf("SessionProcessStartedMsg.SessionID = %q, want the injected flag value %q", started.SessionID, flagVal)
	}
	if started.Harness != "claude-code" {
		t.Errorf("SessionProcessStartedMsg.Harness = %q, want claude-code", started.Harness)
	}
}

// TestStartTerminalCmd_NoSessionIDWithoutBinding asserts codex and opencode —
// which declare spend_telemetry binding `none` — get no --session-id flag and an
// empty SessionID on the message, so they close duration-only. The harness field
// is still carried for the teardown probe's --harness argument.
func TestStartTerminalCmd_NoSessionIDWithoutBinding(t *testing.T) {
	for _, framework := range []string{"codex", "opencode"} {
		t.Run(framework, func(t *testing.T) {
			stageFakeBinaries(t)
			dir := stageFakeLoreData(t, framework, nil)

			msg := runStartTerminal(t, "smoke-slug", dir, false)
			started, ok := msg.(SessionProcessStartedMsg)
			if !ok {
				t.Fatalf("expected SessionProcessStartedMsg, got %T (%+v)", msg, msg)
			}
			if argsContains(started.Cmd.Args, "--session-id") {
				t.Errorf("Cmd.Args contains --session-id on %s (binding=none, should be skipped): %v", framework, started.Cmd.Args)
			}
			if started.SessionID != "" {
				t.Errorf("SessionProcessStartedMsg.SessionID = %q on %s, want empty (no binding)", started.SessionID, framework)
			}
			if started.Harness != framework {
				t.Errorf("SessionProcessStartedMsg.Harness = %q, want %q", started.Harness, framework)
			}
		})
	}
}

func TestStartTerminalCmd_UnknownFrameworkReturnsStreamError(t *testing.T) {
	stageFakeBinaries(t)
	t.Setenv("LORE_DATA_DIR", stageFakeLoreDataWithLaunchFramework(t, "definitely-not-a-real-harness"))

	msg := runStartTerminal(t, "smoke-slug", t.TempDir(), false)
	streamErr, ok := msg.(StreamErrorMsg)
	if !ok {
		t.Fatalf("expected StreamErrorMsg for unknown framework, got %T (%+v)", msg, msg)
	}
	if streamErr.Err == nil || !strings.Contains(streamErr.Err.Error(), "unknown TUI launch framework") {
		t.Errorf("StreamErrorMsg.Err = %v, want substring %q", streamErr.Err, "unknown TUI launch framework")
	}
	if streamErr.Slug != "smoke-slug" {
		t.Errorf("StreamErrorMsg.Slug = %q, want %q", streamErr.Slug, "smoke-slug")
	}
}

func stageFakeLoreDataWithLaunchFramework(t *testing.T, framework string) string {
	t.Helper()
	dataDir := stageFakeLoreData(t, "claude-code", nil)
	path := filepath.Join(dataDir, "config", "settings.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var cfg map[string]any
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatal(err)
	}
	cfg["tui_launch_framework"] = framework
	data, _ := json.MarshalIndent(cfg, "", "  ")
	if err := os.WriteFile(path, data, 0644); err != nil {
		t.Fatal(err)
	}
	return dataDir
}

// argsContains reports whether `needle` appears anywhere in args.
func argsContains(args []string, needle string) bool {
	for _, a := range args {
		if a == needle {
			return true
		}
	}
	return false
}

func envContains(env []string, needle string) bool {
	for _, value := range env {
		if value == needle {
			return true
		}
	}
	return false
}

// argsContainPair reports whether `flag` appears in args immediately followed
// by `value` — used to assert flag-and-value injection (e.g., `--settings {}`).
func argsContainPair(args []string, flag, value string) bool {
	for i := 0; i < len(args)-1; i++ {
		if args[i] == flag && args[i+1] == value {
			return true
		}
	}
	return false
}

// argValueAfter returns the argument immediately following `flag`, or "" when the
// flag is absent or trails the slice — used to read an injected flag's value
// (e.g. the generated --session-id).
func argValueAfter(args []string, flag string) string {
	for i := 0; i < len(args)-1; i++ {
		if args[i] == flag {
			return args[i+1]
		}
	}
	return ""
}
