package work

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
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
// inspect the SpecProcessStartedMsg.Cmd.Path / Cmd.Args before the subprocess
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
	// SpecProcessStartedMsg before the subprocess exits.
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
// SpecProcessStartedMsg or the StreamErrorMsg. Closes the PTY immediately so
// the subprocess teardown path runs cleanly.
func runStartTerminal(t *testing.T, slug, projectDir string, followupMode bool) tea.Msg {
	t.Helper()
	// width=80, height=24 are typical PTY defaults; the values aren't
	// load-bearing for the args we assert.
	cmd := StartTerminalCmd(slug, "smoke title", projectDir, 80, 24, "", false, false, true, followupMode, projectDir, -1)
	msg := cmd()
	if started, ok := msg.(SpecProcessStartedMsg); ok {
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
	started, ok := msg.(SpecProcessStartedMsg)
	if !ok {
		t.Fatalf("expected SpecProcessStartedMsg, got %T (%+v)", msg, msg)
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

func TestStartTerminalCmd_PrependsHarnessArgs(t *testing.T) {
	stageFakeBinaries(t)
	dir := stageFakeLoreData(t, "claude-code", []string{"--my-prepended-flag"})

	msg := runStartTerminal(t, "smoke-slug", dir, false)
	started, ok := msg.(SpecProcessStartedMsg)
	if !ok {
		t.Fatalf("expected SpecProcessStartedMsg, got %T (%+v)", msg, msg)
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
	started, ok := msg.(SpecProcessStartedMsg)
	if !ok {
		t.Fatalf("expected SpecProcessStartedMsg, got %T (%+v)", msg, msg)
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
	started, ok := msg.(SpecProcessStartedMsg)
	if !ok {
		t.Fatalf("expected SpecProcessStartedMsg, got %T (%+v)", msg, msg)
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
	started, ok := msg.(SpecProcessStartedMsg)
	if !ok {
		t.Fatalf("expected SpecProcessStartedMsg, got %T (%+v)", msg, msg)
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
