package work

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/session"
)

func TestTmuxLaunchCapabilityContractHarnessMatrix(t *testing.T) {
	t.Setenv("TERM", "operator-term")
	t.Setenv("COLORTERM", "operator-value")
	t.Setenv("TMUX", "stale")
	t.Setenv("TMUX_PANE", "%99")
	t.Setenv("TERM_PROGRAM", "operator-terminal")
	t.Setenv("SHELL", "/operator/shell")
	t.Setenv("PANE_CONTRACT_CARRIED", "carried")

	fixtures := []struct {
		framework string
		binary    string
	}{
		{"claude-code", "claude"},
		{"codex", "codex"},
		{"opencode", "opencode"},
	}
	for _, fixture := range fixtures {
		t.Run(fixture.framework, func(t *testing.T) {
			spec := newPaneLaunchSpec([]string{"LORE_FRAMEWORK=" + fixture.framework, "COLORTERM=wrong", "PANE_CONTRACT_CARRIED=override"},
				fixture.binary, []string{"--fixture"})
			for _, stale := range []string{"TERM=operator-term", "COLORTERM=operator-value", "COLORTERM=wrong", "TMUX=stale",
				"TMUX_PANE=%99", "TERM_PROGRAM=operator-terminal", "SHELL=/operator/shell", "PANE_CONTRACT_CARRIED=carried"} {
				if slices.Contains(spec.Env, stale) {
					t.Errorf("launch spec leaked %q", stale)
				}
			}
			for _, want := range []string{"LORE_FRAMEWORK=" + fixture.framework, "PANE_CONTRACT_CARRIED=override", "COLORTERM=truecolor"} {
				if !slices.Contains(spec.Env, want) {
					t.Errorf("launch spec lost %q", want)
				}
			}
			keys := map[string]bool{}
			for _, kv := range spec.Env {
				key, _, _ := strings.Cut(kv, "=")
				if keys[key] {
					t.Errorf("launch spec lists %s twice; the harness would read the first", key)
				}
				keys[key] = true
			}
			if !slices.Equal(spec.Argv, []string{fixture.binary, "--fixture"}) {
				t.Errorf("launch spec argv = %v, want the harness command", spec.Argv)
			}

			pane := []string{"/opt/lore/lore-tui", PaneExecFlag, "/tmp/hosts/key/launch/pane-1.json"}
			args := tmuxSessionArgs("lore-test-session", "/tmp/session-worktree", 80, 24, pane)
			joined := strings.Join(args, "\x00")
			if !strings.Contains(joined, "new-session\x00-d\x00-s\x00lore-test-session\x00-x\x0080\x00-y\x0024\x00-c\x00/tmp/session-worktree") {
				t.Errorf("tmux args did not pin the pane cwd")
			}
			// The pane's environment is set by its command, not by -e assignments
			// layered over whatever the tmux server started with.
			if n := strings.Count(joined, "\x00-e\x00"); n > 0 {
				t.Errorf("tmux args still layer %d -e assignments over the server environment", n)
			}
			separator := slices.Index(args, "--")
			if separator < 0 || !slices.Equal(args[separator+1:], pane) {
				t.Fatalf("pane command = %q, want exactly %q", args[max(separator, 0):], pane)
			}
		})
	}

	// The same matrix launched through StartTerminalCmd onto a real pane, once
	// with every framework's session_lifecycle_hooks cell at none and once with
	// each raised to partial. At none the argv is today's. Only Claude Code
	// installs through the inline settings argument, so only its argv may
	// change, and only in the --settings value; every pane carries the
	// generation the host will derive for the session.
	for _, name := range []string{"TMUX", "TMUX_PANE"} {
		t.Setenv(name, "")
		os.Unsetenv(name)
	}
	privatePaneServer(t, "matrix")
	t.Setenv("TMPDIR", t.TempDir())
	stageLaunchRecorders(t)
	started := time.Date(2026, 10, 18, 7, 4, 5, 987654321, time.UTC)
	for _, fixture := range fixtures {
		t.Run(fixture.framework+" launch", func(t *testing.T) {
			dataDir := stageFakeLoreData(t, fixture.framework, nil)
			// The first launch carries no request id, so a harness that takes no
			// session id is named by its tmux session.
			stageLifecycleRepo(t, dataDir, map[string]string{"claude-code": "none", "codex": "none", "opencode": "none"})
			noneEnv := SessionEnv{Instance: "matrix", Slug: "none-" + fixture.framework, Type: SessionSpec, Started: started}
			noneMsg, none := launchRecorded(t, fixture.framework, dataDir, noneEnv, "")
			repo := stageLifecycleRepo(t, dataDir, map[string]string{"claude-code": "partial", "codex": "partial", "opencode": "partial"})
			raisedEnv := SessionEnv{Instance: "matrix", Slug: "raised-" + fixture.framework, Type: SessionSpec, RequestID: "req-" + fixture.framework, Started: started}
			raisedMsg, raised := launchRecorded(t, fixture.framework, dataDir, raisedEnv, "")

			for _, run := range []struct {
				label string
				env   SessionEnv
				msg   SessionProcessStartedMsg
				rec   launchRecord
			}{{"none", noneEnv, noneMsg, none}, {"raised", raisedEnv, raisedMsg, raised}} {
				want := session.Generation(run.msg.SessionID, run.env.RequestID, run.msg.Tmux, started)
				if got := run.rec.Env["LORE_SESSION_GENERATION"]; got == "" || got != want {
					t.Errorf("%s pane LORE_SESSION_GENERATION = %q, want %q", run.label, got, want)
				}
				if run.msg.Tmux != TmuxSessionName("matrix", run.rec.Env["LORE_SESSION_SLUG"]) {
					t.Errorf("%s launch hosted in %q", run.label, run.msg.Tmux)
				}
			}

			model := "smoke-model"
			if fixture.framework == "opencode" {
				model = "anthropic/opus"
			}
			prompt := "/spec none-" + fixture.framework + " --yes"
			var today []string
			switch fixture.framework {
			case "claude-code":
				today = []string{"--model", model, "--settings", "{}", "--session-id", noneMsg.SessionID, prompt}
			case "codex":
				today = []string{"-m", model, prompt}
			case "opencode":
				today = []string{"--standalone", "--prompt", prompt}
			}
			if !slices.Equal(none.Argv, today) {
				t.Fatalf("argv with the cells at none = %q, want today's %q", none.Argv, today)
			}
			if fixture.framework == "opencode" {
				if got := none.Env["OPENCODE_CONFIG_CONTENT"]; got != `{"model":"anthropic/opus"}` {
					t.Fatalf("pane OPENCODE_CONFIG_CONTENT = %q, want the routed model", got)
				}
			}

			expected := slices.Clone(today)
			expected[len(expected)-1] = "/spec raised-" + fixture.framework + " --yes"
			if fixture.framework == "claude-code" {
				expected[slices.Index(expected, "--session-id")+1] = raisedMsg.SessionID
				loreRepo, err := config.LoreRepoDir()
				if err != nil {
					t.Fatal(err)
				}
				if resolved, _ := filepath.EvalSymlinks(repo); loreRepo != resolved {
					t.Fatalf("the launch resolves the lore repo to %s, not the staged copy %s", loreRepo, resolved)
				}
				payload, err := lifecycleHooksPayload(declaredClaudeHooks(t), filepath.Join(loreRepo, "scripts", "session-lifecycle-hook.sh"), "claude-code")
				if err != nil {
					t.Fatal(err)
				}
				expected[slices.Index(expected, "--settings")+1] = payload
				var shape struct {
					Hooks map[string][]map[string]any `json:"hooks"`
				}
				if err := json.Unmarshal([]byte(payload), &shape); err != nil || len(shape.Hooks) != 7 {
					t.Fatalf("raised payload %s: %v", payload, err)
				}
			}
			if !slices.Equal(raised.Argv, expected) {
				t.Fatalf("argv with the cells raised = %q, want %q", raised.Argv, expected)
			}
		})
	}
}

// launchRecord is what a recording harness saw at start.
type launchRecord struct {
	Argv []string          `json:"argv"`
	Env  map[string]string `json:"env"`
}

// stageLaunchRecorders puts a claude, codex and opencode on PATH that write
// their argv and environment to $LORE_LAUNCH_PROBE, then wait.
func stageLaunchRecorders(t *testing.T) {
	t.Helper()
	bin := t.TempDir()
	script := `#!/usr/bin/env python3
import json, os, sys, time
out = os.environ["LORE_LAUNCH_PROBE"]
with open(out + ".tmp", "w") as f:
    json.dump({"argv": sys.argv[1:], "env": dict(os.environ)}, f)
os.rename(out + ".tmp", out)
time.sleep(120)
`
	for _, name := range []string{"claude", "codex", "opencode"} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
}

// launchRecorded launches a spec session for framework onto a tmux pane
// through StartTerminalCmd and returns what its recording harness saw.
func launchRecorded(t *testing.T, framework, knowledgeDir string, env SessionEnv, extraContext string) (SessionProcessStartedMsg, launchRecord) {
	t.Helper()
	identity := mustSessionWorktree(t)
	model := "smoke-model"
	if framework == "opencode" {
		model = "anthropic/opus"
	}
	d := SessionDescriptor{Type: SessionSpec, Slug: env.Slug, Framework: framework, Model: model, SkipConfirm: true, FindingIndex: -1,
		Worktree: &identity, ExtraContext: extraContext}
	probe := filepath.Join(t.TempDir(), "launch.json")
	t.Setenv("LORE_LAUNCH_PROBE", probe)
	msg := StartTerminalCmd(d, 80, 24, knowledgeDir, env, true)()
	started, ok := msg.(SessionProcessStartedMsg)
	if !ok {
		t.Fatalf("launch of %s = %T (%+v)", framework, msg, msg)
	}
	t.Cleanup(func() {
		killTmuxSession(started.Tmux)
		_ = started.Ptmx.Close()
	})
	var record launchRecord
	if err := json.Unmarshal(waitForFile(t, probe), &record); err != nil {
		t.Fatal(err)
	}
	return started, record
}

// stageLifecycleRepo points dataDir's lore repo at a copy of this checkout
// whose capabilities.json sets each named framework's session_lifecycle_hooks
// support; every other adapters and scripts entry is the real one. It returns
// the copy's root, where the launch path now finds scripts/.
func stageLifecycleRepo(t *testing.T, dataDir string, support map[string]string) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	checkout := filepath.Clean(filepath.Join(wd, "..", "..", ".."))
	repo := t.TempDir()
	for _, dir := range []string{"adapters", "scripts"} {
		entries, err := os.ReadDir(filepath.Join(checkout, dir))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Mkdir(filepath.Join(repo, dir), 0o755); err != nil {
			t.Fatal(err)
		}
		for _, entry := range entries {
			if dir == "adapters" && entry.Name() == "capabilities.json" {
				continue
			}
			if err := os.Symlink(filepath.Join(checkout, dir, entry.Name()), filepath.Join(repo, dir, entry.Name())); err != nil {
				t.Fatal(err)
			}
		}
	}
	data, err := os.ReadFile(filepath.Join(checkout, "adapters", "capabilities.json"))
	if err != nil {
		t.Fatal(err)
	}
	var caps map[string]any
	if err := json.Unmarshal(data, &caps); err != nil {
		t.Fatal(err)
	}
	for framework, level := range support {
		cell := caps["frameworks"].(map[string]any)[framework].(map[string]any)["session_lifecycle_hooks"].(map[string]any)
		cell["support"] = level
	}
	if data, err = json.Marshal(caps); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "adapters", "capabilities.json"), data, 0o644); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dataDir, "scripts")
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(repo, "scripts"), link); err != nil {
		t.Fatal(err)
	}
	return repo
}

// declaredClaudeHooks is the claude-code session_lifecycle_hooks events as
// the capabilities file declares them, whatever its support level.
func declaredClaudeHooks(t *testing.T) []config.LifecycleHook {
	t.Helper()
	_, hooks, _, err := config.HarnessLifecycleHooks("claude-code")
	if err != nil {
		t.Fatal(err)
	}
	if len(hooks) == 0 {
		t.Fatal("claude-code declares no session lifecycle hooks")
	}
	return hooks
}

// A store host and a visible TUI share their runtime's tmux server, and tmux
// gives every new pane the environment of whichever client started that server.
// The pane must still get exactly the environment its launcher intends.
func TestTmuxPaneEnvironmentIgnoresTheServersStartupEnvironment(t *testing.T) {
	if _, err := exec.LookPath(tmuxBinary); err != nil {
		t.Skip("tmux is not installed")
	}
	// Short and private: a macOS socket path must fit 104 bytes.
	root, err := os.MkdirTemp("/tmp", "lore-pane-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	if root, err = filepath.EvalSymlinks(root); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMUX_TMPDIR", root)
	t.Setenv(config.SessionRuntimeEnv, fmt.Sprintf("panetest-%d", os.Getpid()))
	socket := filepath.Join(root, fmt.Sprintf("tmux-%d", os.Getuid()), config.TmuxServer())
	t.Cleanup(func() { _ = exec.Command(tmuxBinary, "-S", socket, "kill-server").Run() })
	for _, name := range []string{"LORE_KNOWLEDGE_DIR", "CLAUDE_CODE_CHILD_SESSION", "SERVER_STARTUP_ONLY"} {
		t.Setenv(name, "")
		os.Unsetenv(name)
	}
	t.Setenv("PANE_FIXTURE_CARRIED", "carried")

	first := exec.Command(tmuxBinary, "-L", config.TmuxServer(), "-f", "/dev/null", "new-session", "-d", "-s", "first-client", "sleep", "120")
	first.Env = append(os.Environ(), "LORE_KNOWLEDGE_DIR=/other/store", "CLAUDE_CODE_CHILD_SESSION=1", "SERVER_STARTUP_ONLY=leaked")
	if out, err := first.CombinedOutput(); err != nil {
		t.Fatalf("start the server from another client: %v: %s", err, out)
	}

	work := filepath.Join(root, "worktree")
	if err := os.Mkdir(work, 0o755); err != nil {
		t.Fatal(err)
	}
	envFile, pidFile := filepath.Join(root, "pane.env"), filepath.Join(root, "pane.pid")
	script := "echo $$ > " + pidFile + "; env > " + envFile + ".tmp; mv " + envFile + ".tmp " + envFile + "; exec sleep 120"
	launch := filepath.Join(root, "launch")
	pid, err := createTmuxSession("lore-pane-env-probe", work, 80, 24,
		[]string{"LORE_FRAMEWORK=claude-code", "LORE_SESSION_SLUG=pane-probe"}, "/bin/sh", []string{"-c", script}, launch)
	if err != nil {
		t.Fatal(err)
	}
	if specs, _ := filepath.Glob(filepath.Join(launch, "*")); len(specs) != 0 {
		t.Errorf("launch specs left after the pane started: %v", specs)
	}
	var data []byte
	deadline := time.Now().Add(10 * time.Second)
	for {
		if data, err = os.ReadFile(envFile); err == nil || time.Now().After(deadline) {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("the pane never wrote its environment: %v", err)
	}
	env := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if key, value, ok := strings.Cut(line, "="); ok {
			env[key] = value
		}
	}
	for _, name := range []string{"LORE_KNOWLEDGE_DIR", "CLAUDE_CODE_CHILD_SESSION", "SERVER_STARTUP_ONLY"} {
		if value, ok := env[name]; ok {
			t.Errorf("pane inherited %s=%s from the client that started the server", name, value)
		}
	}
	for name, want := range map[string]string{"PANE_FIXTURE_CARRIED": "carried", "LORE_FRAMEWORK": "claude-code",
		"LORE_SESSION_SLUG": "pane-probe", "TERM": "tmux-256color", "COLORTERM": "truecolor", "PWD": work} {
		if env[name] != want {
			t.Errorf("pane %s = %q, want %q", name, env[name], want)
		}
	}
	if !strings.HasPrefix(env["TMUX"], socket+",") || !strings.HasPrefix(env["TMUX_PANE"], "%") {
		t.Errorf("pane lost tmux's own markers: TMUX=%q TMUX_PANE=%q", env["TMUX"], env["TMUX_PANE"])
	}
	written, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(written)) != strconv.Itoa(pid) {
		t.Errorf("harness pid %s is not the pane pid %d that close and adoption signal", strings.TrimSpace(string(written)), pid)
	}
}

func TestTmuxCapabilityPinsPreserveExistingOptions(t *testing.T) {
	wantPins := [][2]string{
		{"default-terminal", "tmux-256color"},
		{"escape-time", "0"},
		{"exit-empty", "on"},
		{"history-limit", fmt.Sprint(tmuxHistoryLimit)},
		{"prefix", "none"},
		{"prefix2", "none"},
		{"status", "off"},
		{"remain-on-exit", "off"},
		{"window-size", "latest"},
	}
	got := tmuxOptionPins()
	if len(got) != len(wantPins)*5 {
		t.Fatalf("option pin args = %v", got)
	}
	for i, pin := range wantPins {
		if !slices.Equal(got[i*5:i*5+5], []string{"set", "-g", pin[0], pin[1], ";"}) {
			t.Errorf("pin %d = %v, want %v", i, got[i*5:i*5+5], pin)
		}
	}
	if got := tmuxRGBFeaturePin(); !slices.Equal(got, []string{"set", "-as", "terminal-features", ",*:RGB", ";"}) {
		t.Errorf("RGB feature pin = %v", got)
	}
}

func TestTmuxCommandsFollowSessionRuntime(t *testing.T) {
	t.Setenv(config.SessionRuntimeEnv, "dev")
	want := []string{"-L", "lore-tui-dev"}
	for name, args := range map[string][]string{
		"session": tmuxSessionArgs("s", "/tmp/w", 80, 24, []string{"/bin/true"}),
		"attach":  tmuxAttachCommand("s").Args[1:],
		"pin":     tmuxWindowPinArgs("s", 80, 24),
		"viewer":  viewerAttachArgs("s", true),
	} {
		if !slices.Equal(args[:2], want) {
			t.Errorf("%s args = %v, want server %v", name, args, want)
		}
	}

	dir := t.TempDir()
	logPath := filepath.Join(dir, "tmux.log")
	if err := os.WriteFile(filepath.Join(dir, "tmux"), []byte("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$TMUX_LOG\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("TMUX_LOG", logPath)
	t.Setenv("LORE_DATA_DIR", t.TempDir())
	TmuxHasSession("s")
	_, _ = TmuxPanePID("s")
	_, _ = TmuxPaneCWD("s")
	_, _ = captureTmuxPaneHistory("s")
	_, _ = CaptureTmuxHistory("s", 10, 100)
	killTmuxSession("s")
	_ = pinTmuxWindowSize("s", 80, 24)
	ViewerSessionAlive("s")
	_, _ = captureTmuxPaneHistoryOn(viewerTmuxEnv(), "=s:")
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 9 {
		t.Fatalf("tmux calls = %q, want 9", lines)
	}
	for _, line := range lines {
		if !strings.HasPrefix(line, "-L lore-tui-dev ") {
			t.Errorf("tmux call left the runtime's server: %q", line)
		}
	}
}

// The payload a raised Claude Code launch passes validates against the hooks
// settings shape transcribed from Claude's hooks documentation, and each hook
// command exits 0 with no output even when the script it names cannot run.
func TestClaudeSettingsPayloadMatchesHooksSchema(t *testing.T) {
	stageFakeBinaries(t)
	dataDir := stageFakeLoreData(t, "claude-code", nil)
	stageLifecycleRepo(t, dataDir, map[string]string{"claude-code": "partial"})
	identity := mustSessionWorktree(t)
	d := SessionDescriptor{Type: SessionSpec, Slug: "schema", Framework: "claude-code", Model: "smoke-model", SkipConfirm: true, FindingIndex: -1, Worktree: &identity}
	msg := StartTerminalCmd(d, 80, 24, dataDir, SessionEnv{Instance: "schema", Slug: "schema", Type: SessionSpec}, false)()
	started, ok := msg.(SessionProcessStartedMsg)
	if !ok {
		t.Fatalf("launch = %T (%+v)", msg, msg)
	}
	_ = started.Ptmx.Close()
	at := slices.Index(started.Cmd.Args, "--settings")
	if at < 0 || at+1 >= len(started.Cmd.Args) {
		t.Fatalf("launch passed no --settings: %q", started.Cmd.Args)
	}
	payload := started.Cmd.Args[at+1]

	schema := loadHooksSchema(t)
	var value any
	if err := json.Unmarshal([]byte(payload), &value); err != nil {
		t.Fatalf("payload is not JSON: %v\n%s", err, payload)
	}
	if problems := schemaErrors(schema, schema, value, "$"); len(problems) != 0 {
		t.Fatalf("payload does not match tests/fixtures/claude-code-hooks-settings.schema.json: %v\n%s", problems, payload)
	}

	repo, err := config.LoreRepoDir()
	if err != nil {
		t.Fatal(err)
	}
	command := lifecycleHookCommand(filepath.Join(repo, "scripts", "session-lifecycle-hook.sh"), "claude-code")
	var shape struct {
		Hooks map[string][]struct {
			Matcher *string          `json:"matcher"`
			Hooks   []map[string]any `json:"hooks"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal([]byte(payload), &shape); err != nil {
		t.Fatal(err)
	}
	groups := 0
	for event, list := range shape.Hooks {
		for _, group := range list {
			groups++
			if len(group.Hooks) != 1 {
				t.Errorf("%s group has %d handlers, want one", event, len(group.Hooks))
				continue
			}
			handler := group.Hooks[0]
			if len(handler) != 3 || handler["type"] != "command" || handler["command"] != command || handler["async"] != true {
				t.Errorf("%s handler = %v, want only type command, async true and %q", event, handler, command)
			}
		}
	}
	for _, hook := range declaredClaudeHooks(t) {
		found := 0
		for _, group := range shape.Hooks[hook.HookEvent] {
			matcher := ""
			if group.Matcher != nil {
				matcher = *group.Matcher
			}
			if matcher == hook.Matcher {
				found++
			}
		}
		if found != 1 {
			t.Errorf("declared %s (matcher %q) appears in %d groups, want one", hook.HookEvent, hook.Matcher, found)
		}
	}
	if groups != len(declaredClaudeHooks(t)) {
		t.Errorf("payload has %d groups for %d declared hooks", groups, len(declaredClaudeHooks(t)))
	}
	// A hook declared twice, or with no event name, adds no group: Claude would
	// run a repeated handler twice and journal the edge twice.
	repeated := append(slices.Clone(declaredClaudeHooks(t)), declaredClaudeHooks(t)...)
	repeated = append(repeated, config.LifecycleHook{Matcher: "Bash", Event: "needs_input", Activity: "blocked"})
	if again, err := lifecycleHooksPayload(repeated, filepath.Join(repo, "scripts", "session-lifecycle-hook.sh"), "claude-code"); err != nil || again != payload {
		t.Errorf("repeated declarations built %s (%v), want the launch's payload", again, err)
	}

	for name, change := range map[string]func(map[string]any){
		"a key beside hooks at the root":             func(p map[string]any) { p["env"] = map[string]any{"X": "1"} },
		"an undocumented event name":                 func(p map[string]any) { p["hooks"].(map[string]any)["TurnEnded"] = p["hooks"].(map[string]any)["Stop"] },
		"a matcher on the handler":                   func(p map[string]any) { firstHandler(p, "PreToolUse")["matcher"] = "Bash" },
		"a handler type other than command":          func(p map[string]any) { firstHandler(p, "Stop")["type"] = "http" },
		"a handler field outside type/command/async": func(p map[string]any) { firstHandler(p, "Stop")["asyncRewake"] = true },
		"a non-boolean async":                        func(p map[string]any) { firstHandler(p, "Stop")["async"] = "true" },
		"an empty command":                           func(p map[string]any) { firstHandler(p, "Stop")["command"] = "" },
		"an empty handler list": func(p map[string]any) {
			p["hooks"].(map[string]any)["Stop"].([]any)[0].(map[string]any)["hooks"] = []any{}
		},
		"an event mapped to a bare handler": func(p map[string]any) {
			p["hooks"].(map[string]any)["Stop"] = map[string]any{"type": "command", "command": "true"}
		},
	} {
		var mutated map[string]any
		if err := json.Unmarshal([]byte(payload), &mutated); err != nil {
			t.Fatal(err)
		}
		change(mutated)
		if len(schemaErrors(schema, schema, mutated, "$")) == 0 {
			t.Errorf("the validator accepted %s", name)
		}
	}

	dir := filepath.Join(t.TempDir(), "it's a dir")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	unrunnable := filepath.Join(dir, "not-executable.sh")
	if err := os.WriteFile(unrunnable, []byte("#!/bin/sh\necho ran\nexit 3\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	failing := filepath.Join(dir, "failing.sh")
	if err := os.WriteFile(failing, []byte("#!/bin/sh\necho to-stderr >&2\nexit 9\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	for label, script := range map[string]string{
		"a missing script":          filepath.Join(dir, "missing.sh"),
		"a non-executable script":   unrunnable,
		"a directory":               dir,
		"a script that fails":       failing,
		"the repo's script, no env": filepath.Join(repo, "scripts", "session-lifecycle-hook.sh"),
	} {
		cmd := exec.Command("/bin/sh", "-c", lifecycleHookCommand(script, "claude-code"))
		cmd.Env = []string{"PATH=/usr/bin:/bin"}
		cmd.Stdin = strings.NewReader(`{"hook_event_name":"Stop","session_id":"x"}`)
		var stdout, stderr strings.Builder
		cmd.Stdout, cmd.Stderr = &stdout, &stderr
		if err := cmd.Run(); err != nil || stdout.Len() != 0 || stderr.Len() != 0 {
			t.Errorf("%s: err %v, stdout %q, stderr %q; want exit 0 and no output", label, err, stdout.String(), stderr.String())
		}
	}
}

func firstHandler(payload map[string]any, event string) map[string]any {
	return payload["hooks"].(map[string]any)[event].([]any)[0].(map[string]any)["hooks"].([]any)[0].(map[string]any)
}

// schemaKeywords is the JSON Schema subset schemaErrors implements; the fixture
// may use no other keyword, so none is silently ignored.
var schemaKeywords = []string{"$schema", "$id", "title", "description", "$comment", "type", "const", "enum", "required",
	"properties", "additionalProperties", "propertyNames", "items", "minItems", "minLength", "minProperties", "$ref", "$defs"}

func loadHooksSchema(t *testing.T) map[string]any {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "tests", "fixtures", "claude-code-hooks-settings.schema.json"))
	if err != nil {
		t.Fatal(err)
	}
	var schema map[string]any
	if err := json.Unmarshal(data, &schema); err != nil {
		t.Fatal(err)
	}
	var walk func(node any, where string, named bool)
	walk = func(node any, where string, named bool) {
		switch node := node.(type) {
		case map[string]any:
			for key, value := range node {
				if !named && !slices.Contains(schemaKeywords, key) {
					t.Fatalf("%s: keyword %q is outside the subset this validator reads", where, key)
				}
				walk(value, where+"."+key, !named && (key == "properties" || key == "$defs"))
			}
		case []any:
			for i, value := range node {
				walk(value, fmt.Sprintf("%s[%d]", where, i), false)
			}
		}
	}
	walk(schema, "$", false)
	return schema
}

func schemaErrors(root, node map[string]any, value any, where string) []string {
	for {
		ref, ok := node["$ref"].(string)
		if !ok {
			break
		}
		node = root["$defs"].(map[string]any)[strings.TrimPrefix(ref, "#/$defs/")].(map[string]any)
	}
	var found []string
	if expected, ok := node["type"].(string); ok {
		matches := false
		switch expected {
		case "object":
			_, matches = value.(map[string]any)
		case "array":
			_, matches = value.([]any)
		case "string":
			_, matches = value.(string)
		case "boolean":
			_, matches = value.(bool)
		}
		if !matches {
			return []string{where + ": expected " + expected}
		}
	}
	if want, ok := node["const"]; ok && value != want {
		found = append(found, fmt.Sprintf("%s: expected %v", where, want))
	}
	if enum, ok := node["enum"].([]any); ok && !slices.Contains(enum, value) {
		found = append(found, fmt.Sprintf("%s: %v is not a documented value", where, value))
	}
	if text, ok := value.(string); ok {
		if min, ok := node["minLength"].(float64); ok && float64(len(text)) < min {
			found = append(found, where+": too short")
		}
	}
	if object, ok := value.(map[string]any); ok {
		if required, ok := node["required"].([]any); ok {
			for _, key := range required {
				if _, present := object[key.(string)]; !present {
					found = append(found, fmt.Sprintf("%s: missing %v", where, key))
				}
			}
		}
		if min, ok := node["minProperties"].(float64); ok && float64(len(object)) < min {
			found = append(found, where+": too few keys")
		}
		properties, _ := node["properties"].(map[string]any)
		for key, item := range object {
			if names, ok := node["propertyNames"].(map[string]any); ok {
				found = append(found, schemaErrors(root, names, key, where+"<"+key+">")...)
			}
			if property, ok := properties[key].(map[string]any); ok {
				found = append(found, schemaErrors(root, property, item, where+"."+key)...)
				continue
			}
			switch extra := node["additionalProperties"].(type) {
			case bool:
				if !extra {
					found = append(found, where+": unexpected key "+key)
				}
			case map[string]any:
				found = append(found, schemaErrors(root, extra, item, where+"."+key)...)
			}
		}
	}
	if list, ok := value.([]any); ok {
		if min, ok := node["minItems"].(float64); ok && float64(len(list)) < min {
			found = append(found, where+": too few items")
		}
		if items, ok := node["items"].(map[string]any); ok {
			for i, item := range list {
				found = append(found, schemaErrors(root, items, item, fmt.Sprintf("%s[%d]", where, i))...)
			}
		}
	}
	return found
}

// tmux refuses a command of more than about 16 KB. A launch with a large
// initial prompt and the hooks payload sends tmux only the short pane command;
// the harness still receives both whole, through the pane's launch spec.
func TestTmuxPaneCommandFitsWithLargePrompt(t *testing.T) {
	realTmux, err := exec.LookPath(tmuxBinary)
	if err != nil {
		t.Skip("tmux is not installed")
	}
	for _, name := range []string{"TMUX", "TMUX_PANE"} {
		t.Setenv(name, "")
		os.Unsetenv(name)
	}
	privatePaneServer(t, "panefit")
	t.Setenv("TMPDIR", t.TempDir())
	dataDir := stageFakeLoreData(t, "claude-code", nil)
	stageLifecycleRepo(t, dataDir, map[string]string{"claude-code": "partial"})
	stageLaunchRecorders(t)
	bin := t.TempDir()
	log := filepath.Join(bin, "tmux.log")
	wrapper := "#!/bin/sh\nn=0\nfor a in \"$@\"; do n=$((n + ${#a} + 1)); done\nprintf '%s %s\\n' \"$n\" \"$*\" >> " + log + "\nexec " + realTmux + " \"$@\"\n"
	if err := os.WriteFile(filepath.Join(bin, "tmux"), []byte(wrapper), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("LC_ALL", "C")

	brief := strings.Repeat("Implement the brief; quote 'single' and \"double\" = signs ; ", 1200)
	env := SessionEnv{Instance: "fit", Slug: "fit", Type: SessionSpec, RequestID: "req-fit", Started: time.Now()}
	msg, record := launchRecorded(t, "claude-code", dataDir, env, brief)

	repo, err := config.LoreRepoDir()
	if err != nil {
		t.Fatal(err)
	}
	payload, err := lifecycleHooksPayload(declaredClaudeHooks(t), filepath.Join(repo, "scripts", "session-lifecycle-hook.sh"), "claude-code")
	if err != nil {
		t.Fatal(err)
	}
	prompt := "/spec fit --yes -- " + brief
	if len(prompt)+len(payload) <= 16*1024 {
		t.Fatalf("fixture is only %d bytes; it must exceed what tmux accepts in one command", len(prompt)+len(payload))
	}
	if n := len(record.Argv); n == 0 || record.Argv[n-1] != prompt {
		t.Errorf("the harness did not receive the %d-byte prompt whole", len(prompt))
	}
	if at := slices.Index(record.Argv, "--settings"); at < 0 || at+1 >= len(record.Argv) || record.Argv[at+1] != payload {
		t.Errorf("the harness did not receive the hooks payload: %q", record.Argv)
	}
	if got, want := record.Env["LORE_SESSION_GENERATION"], session.Generation(msg.SessionID, "req-fit", msg.Tmux, env.Started); got != want {
		t.Errorf("pane LORE_SESSION_GENERATION = %q, want %q", got, want)
	}
	data, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	created := false
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		size, rest, _ := strings.Cut(line, " ")
		n, err := strconv.Atoi(size)
		if err != nil {
			t.Fatalf("tmux log line %q", line)
		}
		if strings.Contains(rest, "new-session") {
			created = true
		}
		if n >= 16*1024 {
			t.Errorf("a %d-byte tmux command would be refused: %s", n, line)
		}
	}
	if !created {
		t.Fatalf("no new-session went through tmux: %s", data)
	}
}

// A cell above none whose channel is not the inline settings argument installs
// nothing through it; that framework's own channel carries its hooks.
func TestLifecycleHookSettingsInstallOnlyThroughTheSettingsChannel(t *testing.T) {
	dataDir := stageFakeLoreData(t, "claude-code", nil)
	repo := stageLifecycleRepo(t, dataDir, map[string]string{"claude-code": "partial"})
	path := filepath.Join(repo, "adapters", "capabilities.json")
	for channel, installs := range map[string]bool{"settings-json": true, "config-override": false, "plugin-env": false, "": false} {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var caps map[string]any
		if err := json.Unmarshal(data, &caps); err != nil {
			t.Fatal(err)
		}
		caps["frameworks"].(map[string]any)["claude-code"].(map[string]any)["session_lifecycle_hooks"].(map[string]any)["channel"] = channel
		if data, err = json.Marshal(caps); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, data, 0o644); err != nil {
			t.Fatal(err)
		}
		settings, err := lifecycleHookSettings("claude-code")
		if err != nil {
			t.Fatal(err)
		}
		if installed := settings != "{}"; installed != installs {
			t.Errorf("channel %q: --settings %s, want hooks installed %v", channel, settings, installs)
		}
	}
}
