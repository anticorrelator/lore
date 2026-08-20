package work

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/worktree"
)

func mustSessionWorktree(t *testing.T) worktree.Identity {
	t.Helper()
	source := t.TempDir()
	for _, args := range [][]string{
		{"init"},
		{"config", "user.email", "launch-test@example.invalid"},
		{"config", "user.name", "Launch Test"},
	} {
		cmd := exec.Command("git", args...)
		cmd.Dir = source
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	if err := os.WriteFile(filepath.Join(source, "marker"), []byte("source\n"), 0644); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("git", "add", "marker")
	cmd.Dir = source
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git add: %v: %s", err, out)
	}
	cmd = exec.Command("git", "commit", "-m", "fixture")
	cmd.Dir = source
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git commit: %v: %s", err, out)
	}
	identity, err := worktree.Create(context.Background(), source, filepath.Join(t.TempDir(), "session-worktree"), "launch-test-epoch")
	if err != nil {
		t.Fatalf("create session worktree: %v", err)
	}
	return identity
}

func captureParentStderr(t *testing.T, fn func()) string {
	t.Helper()
	original := os.Stderr
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stderr = w
	defer func() { os.Stderr = original }()
	fn()
	_ = w.Close()
	var buf bytes.Buffer
	_, _ = io.Copy(&buf, r)
	_ = r.Close()
	return buf.String()
}

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
	identity := mustSessionWorktree(t)
	d := SessionDescriptor{Type: SessionSpec, Slug: slug, Title: "smoke title", SkipConfirm: true, FollowupMode: followupMode, FindingIndex: -1, Worktree: &identity}
	cmd := StartTerminalCmd(d, 80, 24, projectDir, SessionEnv{}, false)
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
	if started.Harness != "claude-code" {
		t.Errorf("SessionProcessStartedMsg.Harness = %q, want claude-code", started.Harness)
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

func TestStartTerminalCmdPinsDirectPTYToValidatedWorktree(t *testing.T) {
	stageFakeBinaries(t)
	knowledgeDir := stageFakeLoreData(t, "claude-code", nil)
	identity := mustSessionWorktree(t)
	d := SessionDescriptor{Type: SessionSpec, Slug: "cwd-smoke", Title: "cwd smoke", SkipConfirm: true, FindingIndex: -1, Worktree: &identity}

	msg := StartTerminalCmd(d, 80, 24, knowledgeDir, SessionEnv{}, false)()
	started, ok := msg.(SessionProcessStartedMsg)
	if !ok {
		t.Fatalf("expected SessionProcessStartedMsg, got %T (%+v)", msg, msg)
	}
	defer started.Ptmx.Close()
	if started.Cmd.Dir != identity.CanonicalPath {
		t.Fatalf("direct PTY cwd = %q, want %q", started.Cmd.Dir, identity.CanonicalPath)
	}
	if started.Worktree.State != worktree.StateActive || started.Worktree.CanonicalPath != identity.CanonicalPath {
		t.Fatalf("started worktree = %+v, want active identity at %q", started.Worktree, identity.CanonicalPath)
	}
}

func TestStartTerminalCmdPinsManagedDirectPTYToExecutionDir(t *testing.T) {
	stageFakeBinaries(t)
	knowledgeDir := stageFakeLoreData(t, "claude-code", nil)
	identity := mustSessionWorktree(t)
	registry := filepath.Join(knowledgeDir, "_coordination", "worktrees", "registry")
	if err := os.MkdirAll(registry, 0o755); err != nil {
		t.Fatal(err)
	}
	row := worktree.ManagedPlacement{
		SchemaVersion: 1, WorktreeID: "tree-1", ExecutionDir: identity.CanonicalPath, State: "reserved",
		Owner: worktree.ManagedOwner{Kind: "session", ID: "worker-1"}, GuardIdentity: identity,
	}
	data, err := json.Marshal(row)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(registry, "tree-1.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	d := SessionDescriptor{Type: SessionWorker, Slug: "worker-1", SkipConfirm: true, FindingIndex: -1,
		Worktree: &identity, WorktreeID: "tree-1", ExecutionDir: identity.CanonicalPath}
	env := SessionEnv{Instance: "owner", Slug: d.Slug, Type: d.Type, WorktreeID: d.WorktreeID, ExecutionDir: d.ExecutionDir}
	msg := StartTerminalCmd(d, 80, 24, knowledgeDir, env, false)()
	started, ok := msg.(SessionProcessStartedMsg)
	if !ok {
		t.Fatalf("expected SessionProcessStartedMsg, got %T (%+v)", msg, msg)
	}
	defer started.Ptmx.Close()
	if started.Cmd.Dir != identity.CanonicalPath || started.ExecutionDir != identity.CanonicalPath || started.WorktreeID != "tree-1" {
		t.Fatalf("managed spawn placement = cmd:%q id:%q dir:%q", started.Cmd.Dir, started.WorktreeID, started.ExecutionDir)
	}
	if started.PID <= 0 {
		t.Fatalf("managed direct PTY did not preserve process ownership: %+v", started)
	}
	for _, want := range []string{"LORE_WORKTREE_ID=tree-1", "LORE_EXECUTION_DIR=" + identity.CanonicalPath} {
		if !envContains(started.Cmd.Env, want) {
			t.Fatalf("managed child env missing %q: %v", want, started.Cmd.Env)
		}
	}
}

func TestStartTerminalCmdRefusesPartialManagedPlacementBeforeSpawn(t *testing.T) {
	identity := mustSessionWorktree(t)
	d := SessionDescriptor{Type: SessionWorker, Slug: "partial", Worktree: &identity, WorktreeID: "tree-1"}
	msg := StartTerminalCmd(d, 80, 24, t.TempDir(), SessionEnv{}, false)()
	failed, ok := msg.(StreamErrorMsg)
	if !ok || !strings.Contains(failed.Err.Error(), "incomplete managed worktree placement") {
		t.Fatalf("partial managed placement was not refused: %T %+v", msg, msg)
	}
}

func TestStartTerminalCmdRefusesMissingWorktreeBeforeSpawn(t *testing.T) {
	d := SessionDescriptor{Type: SessionSpec, Slug: "missing-worktree", Title: "missing", SkipConfirm: true, FindingIndex: -1}
	msg := StartTerminalCmd(d, 80, 24, t.TempDir(), SessionEnv{}, false)()
	failed, ok := msg.(StreamErrorMsg)
	if !ok {
		t.Fatalf("expected StreamErrorMsg, got %T (%+v)", msg, msg)
	}
	if !strings.Contains(failed.Err.Error(), "missing worktree identity") {
		t.Fatalf("error = %q, want missing identity refusal", failed.Err)
	}
}

func TestStartTerminalCmdRefusesInvalidWorktreeBeforeSpawn(t *testing.T) {
	identity := mustSessionWorktree(t)
	identity.Epoch = "different-epoch"
	d := SessionDescriptor{Type: SessionSpec, Slug: "invalid-worktree", Title: "invalid", SkipConfirm: true, FindingIndex: -1, Worktree: &identity}
	msg := StartTerminalCmd(d, 80, 24, t.TempDir(), SessionEnv{}, false)()
	failed, ok := msg.(StreamErrorMsg)
	if !ok {
		t.Fatalf("expected StreamErrorMsg, got %T (%+v)", msg, msg)
	}
	if !strings.Contains(failed.Err.Error(), "worktree epoch mismatch") {
		t.Fatalf("error = %q, want epoch refusal", failed.Err)
	}
}

// TestStartTerminalCmd_ExportsSessionIdentity asserts the D3 session identity
// joins LORE_FRAMEWORK in the harness child's environment, and that an empty
// SessionEnv field is omitted rather than exported blank.
func TestStartTerminalCmd_ExportsSessionIdentity(t *testing.T) {
	stageFakeBinaries(t)
	dir := stageFakeLoreData(t, "claude-code", nil)

	identity := mustSessionWorktree(t)
	d := SessionDescriptor{Type: SessionSpec, Slug: "smoke-slug", Title: "smoke title", SkipConfirm: true, FindingIndex: -1, Worktree: &identity}
	cmd := StartTerminalCmd(d, 80, 24, dir,
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

func TestSessionEnvVarsCarriesManagedPlacement(t *testing.T) {
	got := SessionEnv{Instance: "owner", Slug: "worker-1", Type: "worker",
		WorktreeID: "tree-1", ExecutionDir: "/work/tree-1"}.vars()
	want := []string{
		"LORE_SESSION_INSTANCE=owner", "LORE_SESSION_SLUG=worker-1", "LORE_SESSION_TYPE=worker",
		"LORE_WORKTREE_ID=tree-1", "LORE_EXECUTION_DIR=/work/tree-1",
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
	var msg tea.Msg
	stderr := captureParentStderr(t, func() {
		msg = runStartTerminal(t, "smoke-slug", dir, true)
	})
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
	if stderr != "" {
		t.Fatalf("StartTerminalCmd wrote parent stderr: %q", stderr)
	}
	// Assert by code, not by position: the spawn also emits a lead-model notice
	// on every launch, and the two concern degradations are what this test owns.
	for _, code := range []string{"append-system-prompt-unsupported", "inline-settings-unsupported"} {
		if !noticesContainCode(started.Notices, code) {
			t.Errorf("Notices missing %q: %#v", code, started.Notices)
		}
	}
}

// noticesContainCode reports whether any operator notice carries the code.
func noticesContainCode(notices []OperatorNotice, code string) bool {
	for _, n := range notices {
		if n.Code == code {
			return true
		}
	}
	return false
}

// noticeByCode returns the first notice carrying the code, and whether one was
// found.
func noticeByCode(notices []OperatorNotice, code string) (OperatorNotice, bool) {
	for _, n := range notices {
		if n.Code == code {
			return n, true
		}
	}
	return OperatorNotice{}, false
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

func TestStartTerminalCmd_FrameworkOverrideSelectsSpawnIdentity(t *testing.T) {
	stageFakeBinaries(t)
	dir := stageFakeLoreData(t, "claude-code", nil)

	d := SessionDescriptor{
		Type:         SessionSpec,
		Slug:         "smoke-slug",
		Title:        "smoke title",
		Framework:    "codex",
		SkipConfirm:  true,
		FindingIndex: -1,
	}
	identity := mustSessionWorktree(t)
	d.Worktree = &identity
	cmd := StartTerminalCmd(d, 80, 24, dir, SessionEnv{}, false)
	msg := cmd()
	started, ok := msg.(SessionProcessStartedMsg)
	if !ok {
		t.Fatalf("expected SessionProcessStartedMsg, got %T (%+v)", msg, msg)
	}
	if started.Ptmx != nil {
		_ = started.Ptmx.Close()
	}

	if !strings.HasSuffix(started.Cmd.Path, "/codex") {
		t.Errorf("Cmd.Path = %q, want suffix /codex", started.Cmd.Path)
	}
	if !envContains(started.Cmd.Env, "LORE_FRAMEWORK=codex") {
		t.Errorf("Cmd.Env missing LORE_FRAMEWORK=codex: %v", started.Cmd.Env)
	}
	if started.Harness != "codex" {
		t.Errorf("SessionProcessStartedMsg.Harness = %q, want codex", started.Harness)
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

// TestStartTerminalCmd_ComposesModelFlag asserts the lead-model override rides
// the harness's universal `--model` flag: a descriptor carrying Model spawns with
// `--model <id>` before the positional prompt. The second half spawns with no
// Model against settings that bind no role, which is the unbound case —
// nothing is composed. (The role-resolved path has its own test below.)
func TestStartTerminalCmd_ComposesModelFlag(t *testing.T) {
	stageFakeBinaries(t)
	dir := stageFakeLoreData(t, "claude-code", nil)

	identity := mustSessionWorktree(t)
	withModel := SessionDescriptor{Type: SessionSpec, Slug: "smoke-slug", Title: "smoke", Model: "opus", SkipConfirm: true, FindingIndex: -1, Worktree: &identity}
	cmd := StartTerminalCmd(withModel, 80, 24, dir, SessionEnv{}, false)
	msg := cmd()
	started, ok := msg.(SessionProcessStartedMsg)
	if !ok {
		t.Fatalf("expected SessionProcessStartedMsg, got %T (%+v)", msg, msg)
	}
	if started.Ptmx != nil {
		_ = started.Ptmx.Close()
	}
	if !argsContainPair(started.Cmd.Args, "--model", "opus") {
		t.Errorf("Cmd.Args missing `--model opus`: %v", started.Cmd.Args)
	}

	// Empty Model injects no flag.
	msg2 := runStartTerminal(t, "smoke-slug", dir, false)
	started2 := msg2.(SessionProcessStartedMsg)
	if argsContains(started2.Cmd.Args, "--model") {
		t.Errorf("Cmd.Args should not contain --model when Model is empty: %v", started2.Cmd.Args)
	}
}

// stageLeadModelSettings stages a LORE_DATA_DIR whose settings.json binds the
// given `harnesses.claude-code.roles` and `.ceremony_roles` blocks, and clears
// every LORE_MODEL_* var the resolver's top-precedence env layer would read.
// The env clearing matters: without it a developer shell that exports
// LORE_MODEL_LEAD would beat the overlay under test and the assertion would
// pass for the wrong reason.
func stageLeadModelSettings(t *testing.T, roles map[string]string, ceremonyRoles map[string]map[string]string) string {
	t.Helper()
	for _, role := range []string{"LEAD", "WORKER", "DEFAULT", "RESEARCHER"} {
		t.Setenv("LORE_MODEL_"+role, "")
	}
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
	harness := cfg["harnesses"].(map[string]any)["claude-code"].(map[string]any)
	if roles != nil {
		harness["roles"] = roles
	}
	if ceremonyRoles != nil {
		harness["ceremony_roles"] = ceremonyRoles
	}
	data, _ := json.MarshalIndent(cfg, "", "  ")
	if err := os.WriteFile(path, data, 0644); err != nil {
		t.Fatal(err)
	}
	return dataDir
}

// spawnForLeadModel runs StartTerminalCmd for a descriptor of the given session
// type and per-dispatch model, returning the started message.
func spawnForLeadModel(t *testing.T, sessionType, model, knowledgeDir string) SessionProcessStartedMsg {
	t.Helper()
	identity := mustSessionWorktree(t)
	d := SessionDescriptor{Type: sessionType, Slug: "lead-model-slug", Title: "lead model",
		Model: model, SkipConfirm: true, FindingIndex: -1, Worktree: &identity}
	msg := StartTerminalCmd(d, 80, 24, knowledgeDir, SessionEnv{}, false)()
	started, ok := msg.(SessionProcessStartedMsg)
	if !ok {
		t.Fatalf("expected SessionProcessStartedMsg, got %T (%+v)", msg, msg)
	}
	if started.Ptmx != nil {
		_ = started.Ptmx.Close()
	}
	return started
}

// TestStartTerminalCmd_LeadModelOverrideBeatsRoleBinding asserts the
// per-dispatch override stays top precedence: a descriptor Model composes
// unchanged even when the session type's role seat is bound to something else.
func TestStartTerminalCmd_LeadModelOverrideBeatsRoleBinding(t *testing.T) {
	stageFakeBinaries(t)
	dir := stageLeadModelSettings(t,
		map[string]string{"lead": "overlay-model"},
		map[string]map[string]string{"spec": {"lead": "ceremony-model"}},
	)

	started := spawnForLeadModel(t, SessionSpec, "dispatch-model", dir)
	if !argsContainPair(started.Cmd.Args, "--model", "dispatch-model") {
		t.Errorf("Cmd.Args missing `--model dispatch-model`: %v", started.Cmd.Args)
	}
	if argsContains(started.Cmd.Args, "ceremony-model") || argsContains(started.Cmd.Args, "overlay-model") {
		t.Errorf("role binding leaked past the per-dispatch override: %v", started.Cmd.Args)
	}
	notice, ok := noticeByCode(started.Notices, "lead-model-override")
	if !ok || !strings.Contains(notice.Message, "dispatch-model") {
		t.Errorf("Notices = %#v, want a lead-model-override notice naming dispatch-model", started.Notices)
	}
}

// TestStartTerminalCmd_LeadModelResolvesPerSessionType asserts each session type
// resolves the seat its top-level agent actually occupies: spec and implement
// take the ceremony-scoped lead seat (so the two ceremonies can bind different
// tiers), a worker session takes plain `worker`, and chat takes `default`. Each
// case binds a distinct model so a mis-mapped seat fails loudly rather than
// coincidentally matching.
func TestStartTerminalCmd_LeadModelResolvesPerSessionType(t *testing.T) {
	cases := []struct {
		sessionType string
		wantModel   string
		wantSeat    string
	}{
		{SessionSpec, "spec-lead-model", "spec.lead"},
		{SessionImplement, "implement-lead-model", "implement.lead"},
		{SessionWorker, "worker-model", "worker"},
		{SessionChat, "default-model", "default"},
	}
	for _, tc := range cases {
		t.Run(tc.sessionType, func(t *testing.T) {
			stageFakeBinaries(t)
			dir := stageLeadModelSettings(t,
				map[string]string{
					"lead":    "role-overlay-lead-model",
					"worker":  "worker-model",
					"default": "default-model",
				},
				map[string]map[string]string{
					"spec":      {"lead": "spec-lead-model"},
					"implement": {"lead": "implement-lead-model"},
				},
			)

			started := spawnForLeadModel(t, tc.sessionType, "", dir)
			if !argsContainPair(started.Cmd.Args, "--model", tc.wantModel) {
				t.Errorf("%s: Cmd.Args missing `--model %s`: %v", tc.sessionType, tc.wantModel, started.Cmd.Args)
			}
			notice, ok := noticeByCode(started.Notices, "lead-model-role-resolved")
			if !ok {
				t.Fatalf("%s: Notices = %#v, want a lead-model-role-resolved notice", tc.sessionType, started.Notices)
			}
			if !strings.Contains(notice.Message, tc.wantModel) || !strings.Contains(notice.Message, tc.wantSeat) {
				t.Errorf("%s: notice %q does not name model %q and seat %q", tc.sessionType, notice.Message, tc.wantModel, tc.wantSeat)
			}
		})
	}
}

// TestStartTerminalCmd_LeadModelUnboundComposesNoFlag asserts an unbound seat
// composes no flag rather than an invented tier: with no roles block at all the
// spawn falls through to the harness's own default and says so.
func TestStartTerminalCmd_LeadModelUnboundComposesNoFlag(t *testing.T) {
	stageFakeBinaries(t)
	dir := stageLeadModelSettings(t, nil, nil)

	started := spawnForLeadModel(t, SessionSpec, "", dir)
	if argsContains(started.Cmd.Args, "--model") {
		t.Errorf("unbound lead seat composed a --model flag: %v", started.Cmd.Args)
	}
	if _, ok := noticeByCode(started.Notices, "lead-model-unbound"); !ok {
		t.Errorf("Notices = %#v, want a lead-model-unbound notice", started.Notices)
	}
}

// TestStartTerminalCmd_LeadModelResolverErrorComposesNoFlag asserts a
// misconfigured overlay degrades to flag-less with a distinct notice rather than
// refusing the spawn. The trigger is an unknown role key stored under
// `harnesses.claude-code.roles`, which the resolver rejects by closed set — a
// different failure class than "nothing bound", and one the operator must fix.
func TestStartTerminalCmd_LeadModelResolverErrorComposesNoFlag(t *testing.T) {
	stageFakeBinaries(t)
	dir := stageLeadModelSettings(t,
		map[string]string{"lead": "overlay-model", "not-a-real-role": "whatever"},
		nil,
	)

	started := spawnForLeadModel(t, SessionSpec, "", dir)
	if argsContains(started.Cmd.Args, "--model") {
		t.Errorf("resolver error composed a --model flag: %v", started.Cmd.Args)
	}
	notice, ok := noticeByCode(started.Notices, "lead-model-resolve-failed")
	if !ok {
		t.Fatalf("Notices = %#v, want a lead-model-resolve-failed notice", started.Notices)
	}
	if !strings.Contains(notice.Message, "not-a-real-role") {
		t.Errorf("notice %q does not name the offending key", notice.Message)
	}
	if _, ok := noticeByCode(started.Notices, "lead-model-unbound"); ok {
		t.Errorf("a misconfiguration was reported as an unbound seat: %#v", started.Notices)
	}
}

// TestStartTerminalCmd_LeadModelResolvesAgainstRequestFramework asserts the
// resolution reads the overlay of the framework claiming *this* session, not the
// TUI process's own active framework. Binding differs between the two so a
// resolver that consulted the process framework would compose the wrong value.
func TestStartTerminalCmd_LeadModelResolvesAgainstRequestFramework(t *testing.T) {
	stageFakeBinaries(t)
	dir := stageLeadModelSettings(t, map[string]string{"lead": "claude-lead-model"}, nil)

	// Add an opencode overlay binding a different model, then claim the session
	// for opencode via the descriptor while the process framework stays
	// claude-code.
	path := filepath.Join(dir, "config", "settings.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var cfg map[string]any
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatal(err)
	}
	cfg["harnesses"].(map[string]any)["opencode"].(map[string]any)["roles"] = map[string]string{"lead": "opencode-lead-model"}
	data, _ := json.MarshalIndent(cfg, "", "  ")
	if err := os.WriteFile(path, data, 0644); err != nil {
		t.Fatal(err)
	}

	identity := mustSessionWorktree(t)
	d := SessionDescriptor{Type: SessionSpec, Slug: "cross-framework", Title: "cross framework",
		Framework: "opencode", SkipConfirm: true, FindingIndex: -1, Worktree: &identity}
	msg := StartTerminalCmd(d, 80, 24, dir, SessionEnv{}, false)()
	started, ok := msg.(SessionProcessStartedMsg)
	if !ok {
		t.Fatalf("expected SessionProcessStartedMsg, got %T (%+v)", msg, msg)
	}
	if started.Ptmx != nil {
		_ = started.Ptmx.Close()
	}
	if !argsContainPair(started.Cmd.Args, "--model", "opencode-lead-model") {
		t.Errorf("Cmd.Args missing `--model opencode-lead-model`: %v", started.Cmd.Args)
	}
	if argsContains(started.Cmd.Args, "claude-lead-model") {
		t.Errorf("resolved against the process framework, not the session's: %v", started.Cmd.Args)
	}
}

// TestTmuxSessionNameSlugless asserts the generated slugless host name mirrors the
// `lore-<instance>-<slug>` scheme with a `chat-<short-id>` suffix, stays within
// tmux's safe [a-z0-9-] name charset, and is unique across calls so two concurrent
// slugless sessions never collide on their tmux host name.
func TestTmuxSessionNameSlugless(t *testing.T) {
	const instance = "amber-otter"
	a := TmuxSessionNameSlugless(instance)
	b := TmuxSessionNameSlugless(instance)
	prefix := "lore-" + instance + "-chat-"
	if !strings.HasPrefix(a, prefix) {
		t.Errorf("name %q missing prefix %q", a, prefix)
	}
	if a == b {
		t.Errorf("two slugless names collided: %q", a)
	}
	for _, name := range []string{a, b} {
		for _, r := range name {
			if !(r == '-' || (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')) {
				t.Errorf("name %q contains tmux-unsafe rune %q", name, r)
			}
		}
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

// TestStartTerminalCmd_DeclaresContainmentBoundary: the spawn path declares the
// session's own checkout and the knowledge store, so the write fence in the child
// learns its boundary from the launcher rather than from a working directory the
// session may already have left.
func TestStartTerminalCmd_DeclaresContainmentBoundary(t *testing.T) {
	stageFakeBinaries(t)
	dir := stageFakeLoreData(t, "claude-code", nil)

	identity := mustSessionWorktree(t)
	d := SessionDescriptor{Type: SessionSpec, Slug: "fence-slug", Title: "fence title", SkipConfirm: true, FindingIndex: -1, Worktree: &identity}
	cmd := StartTerminalCmd(d, 80, 24, dir,
		SessionEnv{Instance: "amber-otter", Slug: "fence-slug", Type: "spec"}, false)
	msg := cmd()
	started, ok := msg.(SessionProcessStartedMsg)
	if !ok {
		t.Fatalf("expected SessionProcessStartedMsg, got %T (%+v)", msg, msg)
	}
	if started.Ptmx != nil {
		_ = started.Ptmx.Close()
	}
	for _, want := range []string{
		"LORE_SESSION_WORKTREE=" + identity.CanonicalPath,
		"LORE_SESSION_STORE_ROOT=" + dir,
	} {
		if !envContains(started.Cmd.Env, want) {
			t.Errorf("Cmd.Env missing %q: %v", want, started.Cmd.Env)
		}
	}
	// LORE_KNOWLEDGE_DIR short-circuits store resolution, so the store root must
	// never travel under that name.
	for _, v := range started.Cmd.Env {
		if strings.HasPrefix(v, "LORE_KNOWLEDGE_DIR=") {
			t.Errorf("spawn exported %q; store resolution would be redirected for every lore verb", v)
		}
	}
}

func TestSessionEnvVarsCarriesContainmentBoundary(t *testing.T) {
	got := SessionEnv{Instance: "owner", Type: "chat",
		WorktreeRoot: "/store/_sessions/worktrees/A", StoreRoot: "/store"}.vars()
	want := []string{
		"LORE_SESSION_INSTANCE=owner", "LORE_SESSION_TYPE=chat",
		"LORE_SESSION_WORKTREE=/store/_sessions/worktrees/A", "LORE_SESSION_STORE_ROOT=/store",
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
