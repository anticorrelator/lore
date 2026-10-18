package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/sessionview"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// The window under test runs every lore verb against a stub on PATH: the real
// `lore session request` and `lore session ensure` would start a login
// supervisor that outlives the test. The stub logs each call (working
// directory, argv and session identity) and answers from files the test
// writes. HOME, LORE_DATA_DIR, TMUX_TMPDIR and the session runtime are the
// test's own, so nothing reaches a real store, host or tmux server.
const stubLore = `#!/bin/bash
dir="$STUB_LORE_DIR"
{
  printf '%s' "$PWD"
  for a in "$@"; do printf '\t%s' "$a"; done
  printf '\t|identity=%s,%s,%s\n' "${LORE_SESSION_INSTANCE-unset}" "${LORE_SESSION_SLUG-unset}" "${LORE_SESSION_TYPE-unset}"
} >> "$dir/calls.log"
case "$1 $2" in
  "session request")
    if [ -n "$STUB_LORE_WRITER" ]; then shift 2; exec bash "$STUB_LORE_WRITER" "$@"; fi
    tab=$(printf '\t')
    n=$(grep -c "${tab}session${tab}request${tab}" "$dir/calls.log")
    out="$dir/request.$n.out"; [ -f "$out" ] || out="$dir/request.out"
    err="$dir/request.$n.err"; [ -f "$err" ] || err="$dir/request.err"
    code="$dir/request.$n.code"; [ -f "$code" ] || code="$dir/request.code"
    [ -f "$out" ] && cat "$out"
    [ -f "$err" ] && cat "$err" >&2
    exit "$(cat "$code" 2>/dev/null || echo 0)" ;;
  "session ensure")
    [ -f "$dir/ensure.out" ] && cat "$dir/ensure.out" || echo '{"ensured": true, "instance_name": "store-host", "scope": "store"}'
    exit "$(cat "$dir/ensure.code" 2>/dev/null || echo 0)" ;;
  "session close")
    [ -f "$dir/close.out" ] && cat "$dir/close.out" >&2
    exit "$(cat "$dir/close.code" 2>/dev/null || echo 0)" ;;
  "work source-checkout")
    [ -f "$dir/declare.out" ] && cat "$dir/declare.out"
    exit "$(cat "$dir/declare.code" 2>/dev/null || echo 0)" ;;
esac
exit 1
`

const windowRuntime = "tuiview"

type windowFixture struct {
	kdir, sessions, checkout, stub string
}

type stubCall struct {
	dir      string
	args     []string
	identity string
}

func newWindowFixture(t *testing.T) *windowFixture {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "adapters", "settings.template.json"))
	if err != nil {
		t.Fatal(err)
	}
	setupFakeLoreData(t, string(raw))
	t.Setenv("HOME", t.TempDir())
	t.Setenv("TMUX", "")
	tmuxDir, err := os.MkdirTemp("/tmp", "lvw")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(tmuxDir) })
	t.Setenv("TMUX_TMPDIR", tmuxDir)
	t.Setenv(config.SessionRuntimeEnv, windowRuntime)
	t.Setenv("LORE_KNOWLEDGE_DIR", "")

	kdir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	index := `{"plans":[{"slug":"demo","title":"Demo","status":"active","has_plan_doc":true},{"slug":"item-two","title":"Item Two","status":"active"}]}`
	for _, dir := range []string{filepath.Join(kdir, "_work", "demo"), filepath.Join(kdir, "_work", "item-two"), session.InstancesDir(filepath.Join(kdir, "_sessions"))} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(kdir, "_work", "_index.json"), []byte(index), 0o644); err != nil {
		t.Fatal(err)
	}
	checkout := initRouteLaunchRepo(t)
	if err := os.MkdirAll(filepath.Join(checkout, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}

	bin, stub := t.TempDir(), t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "lore"), []byte(stubLore), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bin, "gh"), []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("STUB_LORE_DIR", stub)
	t.Setenv("STUB_LORE_WRITER", "")
	// The first run of a freshly written executable can be slow; pay it here,
	// outside what a test times.
	for _, name := range []string{"lore", "gh"} {
		_ = exec.Command(filepath.Join(bin, name), "--warm").Run()
	}
	return &windowFixture{kdir: kdir, sessions: filepath.Join(kdir, "_sessions"), checkout: checkout, stub: stub}
}

// window builds a lore-tui window the way main does, opened in a
// subdirectory of the checkout, with the work index loaded.
func (f *windowFixture) window(t *testing.T) model {
	t.Helper()
	cfg := config.Config{KnowledgeDir: f.kdir, WorkDir: filepath.Join(f.kdir, "_work"), ProjectDir: filepath.Join(f.checkout, "sub"), RepoIdentifier: "github.com/fixture/repo"}
	m := newModel(cfg, config.Prefs{Layout: config.LayoutTopBottom}, stateWork)
	m = m.viewStore(cfg.KnowledgeDir, func() (bool, string) { return true, "tmux 3.8" })
	m, _ = updateModel(t, m, tea.WindowSizeMsg{Width: 140, Height: 44})
	m, _ = updateModel(t, m, loadWorkItems(cfg.WorkDir)())
	return m
}

// respond sets what the stub's n-th `lore session request` prints and exits
// with; n of 0 answers every call that has no answer of its own.
func (f *windowFixture) respond(t *testing.T, n, code int, stdout, stderr string) {
	t.Helper()
	name := "request"
	if n > 0 {
		name = fmt.Sprintf("request.%d", n)
	}
	for suffix, body := range map[string]string{".out": stdout, ".err": stderr, ".code": strconv.Itoa(code)} {
		if err := os.WriteFile(filepath.Join(f.stub, name+suffix), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func (f *windowFixture) stubFile(t *testing.T, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(f.stub, name), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func (f *windowFixture) calls(t *testing.T, prefix ...string) []stubCall {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(f.stub, "calls.log"))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	var out []stubCall
	for _, line := range strings.Split(strings.TrimRight(string(raw), "\n"), "\n") {
		fields := strings.Split(line, "\t")
		if len(fields) < 2 {
			continue
		}
		call := stubCall{dir: fields[0], args: fields[1 : len(fields)-1], identity: strings.TrimPrefix(fields[len(fields)-1], "|identity=")}
		if hasPrefix(call.args, prefix) {
			out = append(out, call)
		}
	}
	return out
}

func hasPrefix(args, prefix []string) bool {
	if len(args) < len(prefix) {
		return false
	}
	for i, p := range prefix {
		if args[i] != p {
			return false
		}
	}
	return true
}

func (f *windowFixture) hostKey() string {
	return session.StoreHostKey(f.kdir, windowRuntime)
}

// writeRow writes a registry row whose file is age old.
func (f *windowFixture) writeRow(t *testing.T, name string, row map[string]any, age time.Duration) {
	t.Helper()
	row["name"] = name
	raw, err := json.Marshal(row)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(session.InstancesDir(f.sessions), name+".json")
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	if age > 0 {
		when := time.Now().Add(-age)
		if err := os.Chtimes(path, when, when); err != nil {
			t.Fatal(err)
		}
	}
}

// storeHost is a live store-host row listing sessions.
func (f *windowFixture) storeHost(t *testing.T, sessions ...map[string]any) {
	t.Helper()
	if sessions == nil {
		sessions = []map[string]any{}
	}
	f.writeRow(t, "store-host", map[string]any{"pid": os.Getpid(), "role": "session-host", "scope": "store", "host_key": f.hostKey(),
		"runtime": windowRuntime, "repo": "github.com/fixture/repo", "started": "2026-10-18T00:00:00Z", "initiator_default": "human", "sessions": sessions}, 0)
}

func (f *windowFixture) appendEvent(t *testing.T, ev map[string]any) {
	t.Helper()
	if _, ok := ev["ts"]; !ok {
		ev["ts"] = time.Now().UTC().Format(time.RFC3339)
	}
	raw, err := json.Marshal(ev)
	if err != nil {
		t.Fatal(err)
	}
	file, err := os.OpenFile(session.EventsFile(f.sessions), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if _, err := file.Write(append(raw, '\n')); err != nil {
		t.Fatal(err)
	}
}

// refresh runs one read of the store's sessions through Update. The commands
// it returns, such as a new viewer's attach, are handed back unrun.
func refresh(t *testing.T, m model) (model, tea.Cmd) {
	t.Helper()
	return updateModel(t, m, m.sessionsRefreshCmd()())
}

// serveStoreForWriter stands in for the store's session host as the request
// writer sees it: the store pinned in the login's served.json, as a host
// started with LORE_KNOWLEDGE_DIR naming a scratch store is, and a live
// store-scope registry row holding the store's key. It returns that key.
func serveStoreForWriter(t *testing.T, kdir, buildTime string) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(kdir)
	if err != nil {
		t.Fatal(err)
	}
	runtime, err := config.SessionRuntime()
	if err != nil {
		t.Fatal(err)
	}
	writeJSON(t, filepath.Join(config.LoginDir(), "served.json"), map[string]any{"schema_version": 1,
		"stores": map[string]any{resolved: map[string]any{"wanted_at": "2026-10-18T00:00:00Z", "pin_knowledge_dir": true}}})
	key := session.StoreHostKey(resolved, runtime)
	writeJSON(t, filepath.Join(session.InstancesDir(filepath.Join(resolved, "_sessions")), "store-host.json"), map[string]any{
		"name": "store-host", "pid": os.Getpid(), "role": "session-host", "scope": "store", "host_key": key, "runtime": runtime,
		"repo": "fixture", "started": "2026-10-18T00:00:00Z", "initiator_default": "human", "sessions": []any{},
		"runtime_capabilities": []string{"position-preparation-v1"}, "build_time": buildTime})
	return key
}

// settle runs cmds and every command their results return, feeding each
// message through Update, until only timers are left. Poll and launch ticks
// are timers here: a test drives polls itself. A revival check or launch
// request still in flight is waited for, however slow.
func settle(t *testing.T, m model, cmds ...tea.Cmd) model {
	t.Helper()
	results := make(chan tea.Msg, 4096)
	pending := 0
	start := func(cmd tea.Cmd) {
		if cmd == nil {
			return
		}
		pending++
		go func() { results <- cmd() }()
	}
	for _, cmd := range cmds {
		start(cmd)
	}
	for steps := 0; pending > 0; steps++ {
		if steps > 5000 {
			t.Fatal("window did not settle")
		}
		select {
		case msg := <-results:
			pending--
			if msg == nil {
				continue
			}
			if batch, ok := msg.(tea.BatchMsg); ok {
				for _, cmd := range batch {
					start(cmd)
				}
				continue
			}
			if v := reflect.ValueOf(msg); v.Kind() == reflect.Slice && v.Type().Elem() == reflect.TypeOf(tea.Cmd(nil)) {
				for i := 0; i < v.Len(); i++ {
					start(v.Index(i).Interface().(tea.Cmd))
				}
				continue
			}
			switch msg.(type) {
			case indexPollTickMsg, launchRefreshTickMsg, tea.QuitMsg:
				continue
			}
			next, cmd := updateModel(t, m, msg)
			m = next
			start(cmd)
		case <-time.After(700 * time.Millisecond):
			if !windowBusy(m) {
				return m
			}
			if steps > 4000 {
				t.Fatal("a revival check or launch request never finished")
			}
			steps += 100
		}
	}
	return m
}

// windowBusy reports whether a command a test asserts on is still running.
func windowBusy(m model) bool {
	if m.hostRevivalBusy {
		return true
	}
	for _, l := range m.launches {
		if l.requestID == "" {
			return true
		}
	}
	for _, r := range m.refusals {
		if r.declaring {
			return true
		}
	}
	return false
}

// snapshotTree records every path under root with its content hash, mode and
// modification time.
func snapshotTree(t *testing.T, root string) map[string]string {
	t.Helper()
	out := map[string]string{}
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		if d.IsDir() {
			out[rel+"/"] = info.Mode().String()
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		out[rel] = fmt.Sprintf("%x %s %d", sha256.Sum256(data), info.Mode(), info.ModTime().UnixNano())
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func assertTreeUnchanged(t *testing.T, before, after map[string]string) {
	t.Helper()
	for path, was := range before {
		if now, ok := after[path]; !ok {
			t.Errorf("%s was removed", path)
		} else if now != was {
			t.Errorf("%s changed: %s -> %s", path, was, now)
		}
	}
	for path := range after {
		if _, ok := before[path]; !ok {
			t.Errorf("%s was created", path)
		}
	}
}

// hostingFixture is a store with a pending keyed row, a dead window's row that
// lists a session, a close request and a send request addressed to that
// window, and no live store host.
func hostingFixture(t *testing.T) *windowFixture {
	t.Helper()
	f := newWindowFixture(t)
	pending := map[string]any{"request_id": "req-pending", "type": "spec", "slug": "demo", "target_instance": nil, "initiator": "agent",
		"requested_by": "agent", "requested_at": "2026-10-18T00:00:00Z", "attempts": 0, "host_key": f.hostKey(), "prefer_project_dir": f.checkout,
		"route": map[string]any{"framework": "claude-code", "model": "opus"}, "framework": "claude-code", "model": "opus"}
	writeJSON(t, filepath.Join(session.PendingDir(f.sessions), "req-pending.json"), pending)
	f.writeRow(t, "old-window", map[string]any{"pid": deadPID(t), "repo": "github.com/fixture/repo", "runtime": windowRuntime, "project_dir": f.checkout,
		"started": "2026-10-17T00:00:00Z", "initiator_default": "human",
		"sessions": []map[string]any{{"slug": "item-two", "type": "chat", "initiator": "human", "started": "2026-10-17T00:00:00Z", "tmux": "lore-old-window-item-two"}}}, time.Hour)
	writeJSON(t, filepath.Join(session.CloseRequestsDir(f.sessions), "close-1.json"), map[string]any{"request_id": "close-1", "slug": "item-two", "target_instance": "old-window", "reason": "human", "requested_at": "2026-10-18T00:00:00Z"})
	writeJSON(t, filepath.Join(session.SendRequestsDir(f.sessions), "send-1.json"), map[string]any{"request_id": "send-1", "slug": "item-two", "target_instance": "old-window", "text": "hello", "requested_at": "2026-10-18T00:00:00Z"})
	return f
}

func writeJSON(t *testing.T, path string, v any) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestTUIHostsNothingUnderItsStore(t *testing.T) {
	f := hostingFixture(t)
	m := f.window(t)
	if m.instanceName != "" {
		t.Fatalf("a window has instance name %q", m.instanceName)
	}
	now := time.Date(2026, 10, 18, 12, 0, 0, 0, time.UTC)
	m.clock = func() time.Time { return now }
	before := snapshotTree(t, f.sessions)

	m = settle(t, m, m.Init())
	for i := 0; i < 12; i++ {
		var cmd tea.Cmd
		m, cmd = m.handleIndexPollTick()
		m = settle(t, m, cmd)
		now = now.Add(5 * time.Second)
	}
	assertTreeUnchanged(t, before, snapshotTree(t, f.sessions))
	if m.instanceName != "" || len(m.localSessions) != 0 || len(m.pendingSpawns) != 0 || len(m.sessionPanels) != 0 {
		t.Fatalf("window took on hosting state: name=%q local=%d spawns=%d panels=%d", m.instanceName, len(m.localSessions), len(m.pendingSpawns), len(m.sessionPanels))
	}
	if rows := session.ScanPending(f.sessions); len(rows) != 1 || rows[0].RequestID != "req-pending" {
		t.Fatalf("the pending keyed row moved: %#v", rows)
	}
	for _, call := range f.calls(t, "session") {
		if len(call.args) < 2 || call.args[1] != "ensure" {
			t.Errorf("window ran %v", call.args)
		}
	}
	ensures := f.calls(t, "session", "ensure", "--if-work")
	if len(ensures) != 1 {
		t.Fatalf("sixty seconds of polls over a dead row listing sessions ran ensure %d times, want 1 (busy=%v last=%v calls=%v)", len(ensures), m.hostRevivalBusy, m.lastHostRevival, f.calls(t))
	}
	if got := strings.Join(ensures[0].args, " "); !strings.Contains(got, "--kdir "+f.kdir) {
		t.Errorf("ensure does not name the window's store: %s", got)
	}
	if ids := m.sessionsList.Count(); ids != 1 {
		t.Errorf("sessions view lists %d rows, want the pending request only", ids)
	}
}

func TestTUIHostsNothingRegistersNoInstanceOnLaunchOrClose(t *testing.T) {
	f := newWindowFixture(t)
	f.storeHost(t, map[string]any{"slug": "item-two", "type": "spec", "initiator": "agent", "started": "2026-10-18T00:00:00Z", "tmux": "lore-store-host-item-two", "session_id": "sid-two"})
	f.respond(t, 0, 0, `{"request_id":"req-launch","enqueued":true}`, "")
	m := f.window(t)
	m = settle(t, m, m.sessionsRefreshCmd())
	before := snapshotTree(t, f.sessions)

	m, _ = updateModel(t, m, work.SpecRequestMsg{Slug: "demo"})
	m, cmd := updateModel(t, m, press(tea.KeyEnter))
	m = settle(t, m, cmd)
	m.sessionsList.SetCursorByID("store-host|item-two|sid-two")
	m.state = stateSessions
	m, _ = updateModel(t, m, press('x'))
	_, cmd = updateModel(t, m, press('y'))
	settle(t, m, cmd)

	assertTreeUnchanged(t, before, snapshotTree(t, f.sessions))
	if n := len(f.calls(t, "session", "request")); n != 1 {
		t.Errorf("launch ran lore session request %d times", n)
	}
	if n := len(f.calls(t, "session", "close")); n != 1 {
		t.Errorf("close ran lore session close %d times", n)
	}
}

func TestViewerTUIRevivesTheStoreHostAtMostOnceAMinute(t *testing.T) {
	poll := func(t *testing.T, m model) model {
		t.Helper()
		m, cmd := m.handleIndexPollTick()
		return settle(t, m, cmd)
	}
	t.Run("dead row listing sessions, no live store host", func(t *testing.T) {
		f := hostingFixture(t)
		m := f.window(t)
		now := time.Date(2026, 10, 18, 12, 0, 0, 0, time.UTC)
		m.clock = func() time.Time { return now }
		for i := 0; i < 5; i++ {
			m = poll(t, m)
			now = now.Add(10 * time.Second)
		}
		if n := len(f.calls(t, "session", "ensure", "--if-work")); n != 1 {
			t.Fatalf("ensure ran %d times in 50s, want 1", n)
		}
		now = now.Add(15 * time.Second)
		m = poll(t, m)
		if n := len(f.calls(t, "session", "ensure", "--if-work")); n != 2 {
			t.Fatalf("ensure ran %d times after a minute, want 2", n)
		}
	})
	t.Run("a live store host leaves it alone", func(t *testing.T) {
		f := hostingFixture(t)
		f.storeHost(t)
		m := f.window(t)
		poll(t, m)
		if n := len(f.calls(t, "session", "ensure")); n != 0 {
			t.Fatalf("ensure ran %d times with a live store host", n)
		}
	})
	t.Run("a dead row from another runtime is not this window's", func(t *testing.T) {
		f := newWindowFixture(t)
		f.writeRow(t, "other-runtime", map[string]any{"pid": deadPID(t), "repo": "github.com/fixture/repo", "runtime": "elsewhere",
			"sessions": []map[string]any{{"slug": "item-two", "type": "chat", "tmux": "lore-x"}}}, time.Hour)
		m := f.window(t)
		poll(t, m)
		if n := len(f.calls(t, "session", "ensure")); n != 0 {
			t.Fatalf("ensure ran %d times for another runtime's row", n)
		}
	})
	t.Run("a failed ensure is shown once", func(t *testing.T) {
		f := hostingFixture(t)
		f.stubFile(t, "ensure.out", `{"error": "store host did not start: supervisor refused"}`)
		f.stubFile(t, "ensure.code", "1")
		m := f.window(t)
		m = poll(t, m)
		if !strings.Contains(m.statusNotice, "supervisor refused") {
			t.Fatalf("failed ensure notice = %q", m.statusNotice)
		}
	})
}

// launchFixture opens the spec confirm for demo and presses Enter.
func launchFromModal(t *testing.T, m model, slug string) (model, tea.Cmd) {
	t.Helper()
	m, _ = updateModel(t, m, work.SpecRequestMsg{Slug: slug})
	if !m.sessionConfirmActive {
		t.Fatal("s did not open the confirm modal")
	}
	return updateModel(t, m, press(tea.KeyEnter))
}

func TestViewerTUILaunchRunsSessionRequestAndOpensTheViewerOnSpawned(t *testing.T) {
	f := newWindowFixture(t)
	f.storeHost(t)
	f.respond(t, 0, 0, `{"request_id":"req-1","type":"spec","slug":"demo","enqueued":true,"host_key":"k"}`, "")
	m := f.window(t)

	m, cmd := launchFromModal(t, m, "demo")
	if _, pending := m.launches["demo"]; !pending {
		t.Fatal("Enter did not record a pending launch")
	}
	m = settle(t, m, cmd)

	calls := f.calls(t, "session", "request")
	if len(calls) != 1 {
		t.Fatalf("lore session request ran %d times", len(calls))
	}
	args := calls[0].args
	if calls[0].dir != f.checkout {
		t.Errorf("request ran in %s, want the checkout's top level %s", calls[0].dir, f.checkout)
	}
	flag := func(name string) string {
		for i := 0; i+1 < len(args); i++ {
			if args[i] == name {
				return args[i+1]
			}
		}
		return ""
	}
	if flag("--type") != "spec" || flag("--initiator") != "human" || flag("--prefer-dir") != f.checkout || flag("--slug") != "demo" || flag("--kdir") != f.kdir {
		t.Fatalf("request argv = %q", args)
	}
	var route map[string]any
	if err := json.Unmarshal([]byte(flag("--session-route")), &route); err != nil || route["framework"] == nil {
		t.Fatalf("--session-route %q is not a frozen route: %v", flag("--session-route"), err)
	}
	if !slicesContain(args, "--json") || !slicesContain(args, "--yes") || flag("--track") != "short" {
		t.Fatalf("request argv = %q", args)
	}
	if l := m.launches["demo"]; l.requestID != "req-1" {
		t.Fatalf("pending launch = %#v", l)
	}
	if m.flashErr != "" || m.refusalActive() {
		t.Fatalf("a sent launch flashed %q or refused", m.flashErr)
	}
	if out := stripANSI(m.viewContent()); !strings.Contains(out, "Starting spec for demo in the background host") {
		t.Fatalf("the item's panel does not say it is starting:\n%s", out)
	}
	if m.hasSessionPanel("demo") {
		t.Fatal("a viewer opened before the session spawned")
	}

	f.storeHost(t, map[string]any{"slug": "demo", "type": "spec", "initiator": "human", "started": "2026-10-18T00:00:00Z", "request_id": "req-1", "session_id": "sid-1", "tmux": "lore-store-host-demo"})
	f.appendEvent(t, map[string]any{"event_id": "ev-spawned", "event": "spawned", "slug": "demo", "request_id": "req-1", "actor_instance": "store-host"})
	m, attach := refresh(t, m)
	v, ok := m.viewers["demo"]
	if !ok || !v.panel.IsViewer() || v.panel.TmuxName() != "lore-store-host-demo" {
		t.Fatalf("spawned did not open a viewer on the host's pane: %#v ok=%v", v.panel.TmuxName(), ok)
	}
	if attach == nil {
		t.Fatal("opening the viewer returned no attach command")
	}
	if _, owned := m.sessionPanels["demo"]; owned {
		t.Fatal("the viewer landed in the owned-session panel map")
	}
	if !m.terminalMode || m.focusedPanel != panelLeft {
		t.Fatalf("a launch from the work list shows its terminal with the list focused: terminal=%v focus=%v", m.terminalMode, m.focusedPanel)
	}
	if _, pending := m.launches["demo"]; pending {
		t.Fatal("the launch is still pending after it spawned")
	}
}

func slicesContain(values []string, want string) bool {
	for _, v := range values {
		if v == want {
			return true
		}
	}
	return false
}

func TestViewerTUISpawnFailedShowsTheRetry(t *testing.T) {
	f := newWindowFixture(t)
	f.storeHost(t)
	f.respond(t, 0, 0, `{"request_id":"req-retry","enqueued":true}`, "")
	m := f.window(t)
	m, cmd := launchFromModal(t, m, "demo")
	m = settle(t, m, cmd)

	f.appendEvent(t, map[string]any{"event_id": "ev-f1", "event": "spawn_failed", "slug": "demo", "request_id": "req-retry", "reason": "spawn: create session worktree: disk full"})
	m, _ = refresh(t, m)
	m, _ = refresh(t, m)
	if l := m.launches["demo"]; l.attempts != 1 || l.lastReason != "spawn: create session worktree: disk full" {
		t.Fatalf("pending launch after one failure = %#v", l)
	}
	out := stripANSI(m.viewContent())
	if !strings.Contains(out, "Attempt 1 failed: spawn: create session worktree: disk full") || !strings.Contains(out, "retrying") {
		t.Fatalf("panel does not show the retry:\n%s", out)
	}
	if m.refusalActive() {
		t.Fatal("a retried failure opened a refusal")
	}
}

// viewerWindow is a window showing a live viewer on demo with its terminal focused.
func viewerWindow(t *testing.T, f *windowFixture) model {
	t.Helper()
	f.storeHost(t, map[string]any{"slug": "demo", "type": "spec", "initiator": "agent", "started": "2026-10-18T00:00:00Z", "session_id": "sid-demo", "tmux": "lore-store-host-demo"})
	m := f.window(t)
	m, _ = refresh(t, m)
	m, _ = updateModel(t, m, press('l'))
	if _, ok := m.viewers["demo"]; !ok || !m.terminalMode || m.focusedPanel != panelRight {
		t.Fatalf("fixture viewer not shown: terminal=%v focus=%v", m.terminalMode, m.focusedPanel)
	}
	return m
}

func endViewer(t *testing.T, m model, key string) model {
	t.Helper()
	v := m.viewers[key]
	m, _ = updateModel(t, m, work.ViewerEndedMsg{Slug: key, TmuxName: v.panel.TmuxName(), Generation: v.panel.ViewerGeneration(), Reason: work.ViewerSessionEnded})
	if !m.viewers[key].panel.IsDone() {
		t.Fatal("the viewer did not end")
	}
	return m
}

func TestViewerTUICtrlCAndXCloseThroughTheHost(t *testing.T) {
	t.Run("Ctrl+c (close)", func(t *testing.T) {
		f := newWindowFixture(t)
		m := viewerWindow(t, f)
		if hints := stripANSI(strings.Join(m.statusBarHints(kmTerminal), " · ")); !strings.Contains(hints, "Ctrl+c close") {
			t.Fatalf("terminal hints = %s", hints)
		}
		m, cmd := updateModel(t, m, press('c', tea.ModCtrl))
		if cmd != nil || m.confirmAction != "close_session" || m.confirmSlug != "demo" || m.confirmSessionID != "sid-demo" {
			t.Fatalf("ctrl+c = cmd:%v action:%q slug:%q session:%q", cmd != nil, m.confirmAction, m.confirmSlug, m.confirmSessionID)
		}
		if out := stripANSI(m.viewContent()); !strings.Contains(out, "background host running it ends the session") {
			t.Fatalf("close confirmation:\n%s", out)
		}
		m, cmd = updateModel(t, m, press('y'))
		settle(t, m, cmd)
		calls := f.calls(t, "session", "close")
		if len(calls) != 1 || strings.Join(calls[0].args, " ") != "session close demo --reason human --requested-by lore-tui" {
			t.Fatalf("close calls = %#v", calls)
		}
		if _, ok := m.viewers["demo"]; !ok {
			t.Fatal("confirming the close dropped the viewer before the session ended")
		}
	})
	t.Run("Ctrl+c (discard)", func(t *testing.T) {
		f := newWindowFixture(t)
		m := endViewer(t, viewerWindow(t, f), "demo")
		if hints := stripANSI(strings.Join(m.statusBarHints(kmTerminal), " · ")); !strings.Contains(hints, "Ctrl+c discard") {
			t.Fatalf("terminal hints on an ended session = %s", hints)
		}
		m, _ = updateModel(t, m, press('c', tea.ModCtrl))
		if _, ok := m.viewers["demo"]; ok || m.confirmAction != "" || m.terminalMode {
			t.Fatalf("ctrl+c on an ended session should discard its viewer: viewer=%v action=%q", ok, m.confirmAction)
		}
		if n := len(f.calls(t, "session", "close")); n != 0 {
			t.Fatalf("discarding an ended viewer ran close %d times", n)
		}
	})
	t.Run("x (close)", func(t *testing.T) {
		f := newWindowFixture(t)
		f.storeHost(t, map[string]any{"slug": "", "type": "chat", "initiator": "human", "started": "2026-10-18T00:00:00Z", "session_id": "abcdef0123456789", "tmux": "lore-store-host-chat"})
		m := f.window(t)
		m, _ = refresh(t, m)
		m, _ = updateModel(t, m, press('v'))
		m, _ = updateModel(t, m, press('x'))
		if m.confirmAction != "close_session" || m.confirmSlug != "" || m.confirmSessionID != "abcdef0123456789" {
			t.Fatalf("x = action:%q slug:%q session:%q", m.confirmAction, m.confirmSlug, m.confirmSessionID)
		}
		m, cmd := updateModel(t, m, press(tea.KeyEnter))
		settle(t, m, cmd)
		calls := f.calls(t, "session", "close")
		if len(calls) != 1 || strings.Join(calls[0].args, " ") != "session close --session abcdef0123456789 --reason human --requested-by lore-tui" {
			t.Fatalf("close calls = %#v", calls)
		}
	})
	t.Run("a refused close is shown in full", func(t *testing.T) {
		f := newWindowFixture(t)
		reason := "Error: no live host lists session demo; it may have ended already. Run lore session list to see where it runs, then retry the close."
		f.stubFile(t, "close.out", reason)
		f.stubFile(t, "close.code", "1")
		m := viewerWindow(t, f)
		m, _ = updateModel(t, m, press('c', tea.ModCtrl))
		m, cmd := updateModel(t, m, press('y'))
		m = settle(t, m, cmd)
		if !m.refusalActive() || m.refusals[0].title != "Close failed" {
			t.Fatalf("a refused close showed no modal: flash=%q", m.flashErr)
		}
		assertShowsInFull(t, m.viewContent(), strings.TrimPrefix(reason, "Error: "))
	})
}

func TestViewerTUICtrlBackslashClosesOnlyTheViewer(t *testing.T) {
	f := newWindowFixture(t)
	m := viewerWindow(t, f)
	_, cmd := updateModel(t, m, press('\\', tea.ModCtrl))
	if cmd == nil {
		t.Fatal("ctrl+\\ produced no command")
	}
	msg := cmd()
	if _, ok := msg.(work.ViewerTerminateMsg); !ok {
		t.Fatalf("ctrl+\\ produced %T", msg)
	}
	m, _ = updateModel(t, m, msg)
	if _, ok := m.viewers["demo"]; ok || m.terminalMode || m.focusedPanel != panelLeft {
		t.Fatalf("ctrl+\\ left viewer=%v terminal=%v focus=%v", ok, m.terminalMode, m.focusedPanel)
	}
	if n := len(f.calls(t, "session")); n != 0 {
		t.Fatalf("closing the viewer ran %d session verbs", n)
	}
}

func TestViewerTUIQuitClosesViewersOnly(t *testing.T) {
	for _, key := range []tea.KeyPressMsg{press('q'), press('c', tea.ModCtrl), press('d', tea.ModCtrl)} {
		t.Run(key.String(), func(t *testing.T) {
			f := newWindowFixture(t)
			f.storeHost(t,
				map[string]any{"slug": "demo", "type": "spec", "initiator": "agent", "started": "2026-10-18T00:00:00Z", "session_id": "sid-demo", "tmux": "lore-store-host-demo"},
				map[string]any{"slug": "item-two", "type": "chat", "initiator": "human", "started": "2026-10-18T00:00:00Z", "session_id": "sid-two", "tmux": "lore-store-host-item-two"})
			m := f.window(t)
			m, _ = refresh(t, m)
			m, _ = updateModel(t, m, press('l'))
			m.focusedPanel = panelLeft
			m, _ = updateModel(t, m, press('j'))
			m, _ = updateModel(t, m, press('l'))
			m.focusedPanel = panelLeft
			if len(m.viewers) != 2 {
				t.Fatalf("fixture has %d viewers", len(m.viewers))
			}
			for k, v := range m.viewers {
				if v.panel.ViewerAttachCmd() == nil {
					t.Fatalf("viewer %s is not waiting to attach", k)
				}
			}
			before := snapshotTree(t, f.sessions)
			nm, cmd := updateModel(t, m, key)
			if !isQuitCmd(cmd) {
				t.Fatalf("%s did not quit", key)
			}
			for k, v := range nm.viewers {
				if v.panel.ViewerAttachCmd() != nil {
					t.Errorf("viewer %s was left open at quit", k)
				}
			}
			assertTreeUnchanged(t, before, snapshotTree(t, f.sessions))
			if n := len(f.calls(t, "session")); n != 0 {
				t.Fatalf("quitting ran %d session verbs", n)
			}
		})
	}
}

func TestViewerTUIOpensOtherSessionsOnExplicitKeys(t *testing.T) {
	agentSession := map[string]any{"slug": "demo", "type": "spec", "initiator": "agent", "started": "2026-10-18T00:00:00Z", "session_id": "sid-demo", "tmux": "lore-store-host-demo"}
	setup := func(t *testing.T) model {
		t.Helper()
		f := newWindowFixture(t)
		f.storeHost(t, agentSession)
		m := f.window(t)
		m, _ = refresh(t, m)
		if m.list.CurrentSlug() != "demo" {
			t.Fatalf("cursor on %q", m.list.CurrentSlug())
		}
		return m
	}
	t.Run("cursor movement opens nothing", func(t *testing.T) {
		m := setup(t)
		m, _ = updateModel(t, m, press('j'))
		m, _ = updateModel(t, m, press('k'))
		m, _ = refresh(t, m)
		if len(m.viewers) != 0 || m.terminalMode {
			t.Fatalf("passive navigation opened %d viewers", len(m.viewers))
		}
		if hints := stripANSI(strings.Join(m.statusBarHints(kmWorkList), " · ")); !strings.Contains(hints, "l/Enter attach session") {
			t.Fatalf("work list hints over a live session = %s", hints)
		}
	})
	t.Run("l (attach session)", func(t *testing.T) {
		m, cmd := updateModel(t, setup(t), press('l'))
		if _, ok := m.viewers["demo"]; !ok || cmd == nil || !m.terminalMode || m.focusedPanel != panelRight {
			t.Fatalf("l: viewer=%v attach=%v terminal=%v focus=%v", ok, cmd != nil, m.terminalMode, m.focusedPanel)
		}
	})
	t.Run("Enter (attach session)", func(t *testing.T) {
		m := setup(t)
		_, cmd := updateModel(t, m, press(tea.KeyEnter))
		if cmd == nil {
			t.Fatal("Enter produced no command")
		}
		m, _ = updateModel(t, m, cmd())
		if _, ok := m.viewers["demo"]; !ok || !m.terminalMode || m.focusedPanel != panelRight {
			t.Fatalf("Enter: viewer=%v terminal=%v focus=%v", ok, m.terminalMode, m.focusedPanel)
		}
	})
	for _, msg := range []tea.Msg{work.SpecRequestMsg{Slug: "demo"}, work.ImplementRequestMsg{Slug: "demo"}, work.ChatRequestMsg{Slug: "demo", Title: "Demo"}} {
		t.Run(fmt.Sprintf("%T views the live session", msg), func(t *testing.T) {
			m, _ := updateModel(t, setup(t), msg)
			if m.sessionConfirmActive {
				t.Fatal("a live session's item opened a launch confirm")
			}
			if _, ok := m.viewers["demo"]; !ok || !m.terminalMode {
				t.Fatalf("viewer=%v terminal=%v", ok, m.terminalMode)
			}
		})
	}
	t.Run("sessions view Enter and l", func(t *testing.T) {
		for _, key := range []tea.KeyPressMsg{press(tea.KeyEnter), press('l')} {
			m := setup(t)
			m, _ = updateModel(t, m, press('v'))
			nm, cmd := updateModel(t, m, key)
			if key.Code == tea.KeyEnter {
				if cmd == nil {
					t.Fatal("Enter produced no selection")
				}
				msg, ok := cmd().(sessionview.SessionSelectedMsg)
				if !ok {
					t.Fatal("Enter produced no SessionSelectedMsg")
				}
				nm, _ = updateModel(t, nm, msg)
			}
			if _, ok := nm.viewers["demo"]; !ok || !nm.terminalMode || nm.focusedPanel != panelRight {
				t.Fatalf("%s: viewer=%v terminal=%v focus=%v", key, ok, nm.terminalMode, nm.focusedPanel)
			}
			if panel, ok := nm.currentSessionsPanel(); !ok || !panel.IsViewer() {
				t.Fatalf("%s: sessions view shows no viewer", key)
			}
		}
	})
	t.Run("a viewer stays on navigation", func(t *testing.T) {
		m, _ := updateModel(t, setup(t), press('l'))
		m.focusedPanel = panelLeft
		m, _ = updateModel(t, m, press('j'))
		if m.terminalMode {
			t.Fatal("item-two has no panel")
		}
		m, _ = updateModel(t, m, press('k'))
		if !m.terminalMode {
			t.Fatal("returning to demo did not show its viewer")
		}
	})
}

func TestViewerTUISessionWithoutTmuxIsNotViewable(t *testing.T) {
	f := newWindowFixture(t)
	f.storeHost(t, map[string]any{"slug": "demo", "type": "spec", "initiator": "agent", "started": "2026-10-18T00:00:00Z", "session_id": "sid-demo"})
	m := f.window(t)
	m, _ = refresh(t, m)
	row, ok := m.liveSessionRow("demo")
	if !ok || !strings.Contains(row.Display, "not viewable") {
		t.Fatalf("row = %#v", row)
	}
	m, _ = updateModel(t, m, work.SpecRequestMsg{Slug: "demo"})
	if m.sessionConfirmActive || len(m.viewers) != 0 {
		t.Fatalf("a live, unviewable session: confirm=%v viewers=%d", m.sessionConfirmActive, len(m.viewers))
	}
	if !strings.Contains(m.statusNotice, "cannot be shown") {
		t.Fatalf("notice = %q", m.statusNotice)
	}
	if n := len(f.calls(t, "session")); n != 0 {
		t.Fatalf("ran %d session verbs", n)
	}
}

func TestViewerTUIWithoutTmuxListsSessionsAndSaysSo(t *testing.T) {
	f := newWindowFixture(t)
	f.storeHost(t, map[string]any{"slug": "demo", "type": "spec", "initiator": "agent", "started": "2026-10-18T00:00:00Z", "session_id": "sid-demo", "tmux": "lore-store-host-demo"})
	m := f.window(t)
	m.noTmuxReason, m.statusNotice = "", ""
	m = m.viewStore(f.kdir, func() (bool, string) { return false, "tmux not found on PATH" })
	if !strings.Contains(m.statusNotice, "terminals cannot be shown") {
		t.Fatalf("startup notice = %q", m.statusNotice)
	}
	m, _ = refresh(t, m)
	if m.sessionsList.Count() != 1 {
		t.Fatalf("sessions listed = %d", m.sessionsList.Count())
	}
	m, _ = updateModel(t, m, press('l'))
	if len(m.viewers) != 0 {
		t.Fatal("a viewer opened without tmux")
	}
}

func TestViewerTUIBadgesDescribeSessionsNotHosts(t *testing.T) {
	f := newWindowFixture(t)
	f.storeHost(t, map[string]any{"slug": "demo", "type": "implement", "initiator": "agent", "started": "2026-10-18T00:00:00Z", "session_id": "sid-demo", "tmux": "lore-store-host-demo"})
	m := f.window(t)
	m, _ = refresh(t, m)
	if out := stripANSI(m.list.View()); !strings.Contains(out, "implementing") || strings.Contains(out, "◆") {
		t.Fatalf("work list badge:\n%s", out)
	}
	m, _ = updateModel(t, m, loadWorkItems(m.config.WorkDir)())
	if out := stripANSI(m.list.View()); !strings.Contains(out, "implementing") {
		t.Fatalf("badge lost on reload:\n%s", out)
	}
	m, _ = updateModel(t, m, press('v'))
	out := stripANSI(m.viewContent())
	if list := stripANSI(m.sessionsList.View()); strings.Contains(list, "store-host") || !strings.Contains(list, "running") {
		t.Fatalf("sessions list should badge the session by what it does, not who hosts it:\n%s", list)
	}
	if strings.Contains(out, "another instance") || strings.Contains(out, "read-only") {
		t.Fatalf("sessions card draws the session as another host's:\n%s", out)
	}
	if !strings.Contains(out, "github.com/fixture/repo") {
		t.Fatalf("tab row does not name the store the window views:\n%s", out)
	}
	f.storeHost(t)
	m, _ = refresh(t, m)
	m, _ = updateModel(t, m, press('w'))
	if out := stripANSI(m.list.View()); strings.Contains(out, "implementing") {
		t.Fatalf("badge outlived its session:\n%s", out)
	}
}

func TestViewerTUIRoutesViewerTrafficByKeyAndGeneration(t *testing.T) {
	f := newWindowFixture(t)
	f.storeHost(t,
		map[string]any{"slug": "demo", "type": "spec", "initiator": "agent", "started": "2026-10-18T00:00:00Z", "session_id": "sid-demo", "tmux": "lore-store-host-demo"},
		map[string]any{"slug": "item-two", "type": "chat", "initiator": "human", "started": "2026-10-18T00:00:00Z", "session_id": "sid-two", "tmux": "lore-store-host-item-two"})
	m := f.window(t)
	m, _ = refresh(t, m)
	m, _ = m.openViewer(m.sessionRows[0])
	m, _ = m.openViewer(m.sessionRows[1])
	a, b := m.sessionRows[0].PanelKey, m.sessionRows[1].PanelKey
	stale := work.ViewerEndedMsg{Slug: a, TmuxName: m.viewers[a].panel.TmuxName(), Generation: m.viewers[b].panel.ViewerGeneration(), Reason: work.ViewerSessionEnded}
	m, _ = updateModel(t, m, stale)
	if m.viewers[a].panel.IsDone() {
		t.Fatal("another viewer's generation ended this one")
	}
	m = endViewer(t, m, a)
	if m.viewers[b].panel.IsDone() {
		t.Fatal("ending one viewer ended the other")
	}
	if len(m.sessionPanels) != 0 {
		t.Fatal("viewer traffic reached the owned-session panels")
	}
	_, cmd := updateModel(t, m, work.ViewerAttachedMsg{Slug: "nobody", TmuxName: "lore-x", Generation: 1})
	if cmd == nil {
		t.Fatal("a client no viewer takes is not closed")
	}
	cmd()
	m, _ = updateModel(t, m, work.ViewerOutputMsg{Slug: "nobody", Generation: 1, Data: []byte("x")})
	if _, ok := m.viewers["nobody"]; ok {
		t.Fatal("stray viewer traffic created a viewer")
	}
}

func TestViewerTUISessionsScrollbackRoutesToTheViewer(t *testing.T) {
	f := newWindowFixture(t)
	f.storeHost(t, map[string]any{"slug": "demo", "type": "spec", "initiator": "agent", "started": "2026-10-18T00:00:00Z", "session_id": "sid-demo", "tmux": "lore-store-host-demo"})
	m := f.window(t)
	m, _ = refresh(t, m)
	m, _ = updateModel(t, m, press('v'))
	m, _ = updateModel(t, m, press('l'))
	m, cmd := updateModel(t, m, press(tea.KeyPgUp, tea.ModShift))
	if cmd == nil {
		t.Fatal("Shift+PgUp did not ask for the pane's history")
	}
	v := m.viewers["demo"]
	lines := make([]string, 100)
	for i := range lines {
		lines[i] = fmt.Sprintf("history line %02d", i)
	}
	m, _ = updateModel(t, m, work.ViewerScrollbackMsg{Slug: "demo", TmuxName: v.panel.TmuxName(), Generation: v.panel.ViewerGeneration(), Lines: lines})
	panel, ok := m.currentSessionsPanel()
	if !ok || !strings.Contains(stripANSI(panel.View()), "-- scrollback (") {
		t.Fatal("the viewer's scrollback did not reach the sessions view")
	}
}

// assertShowsInFull checks that every word of text appears, in order, in the
// rendered view.
func assertShowsInFull(t *testing.T, view, text string) {
	t.Helper()
	clean := stripANSI(view)
	for _, r := range []string{"│", "╭", "╮", "╰", "╯", "─"} {
		clean = strings.ReplaceAll(clean, r, " ")
	}
	got := strings.Join(strings.Fields(clean), " ")
	want := strings.Join(strings.Fields(text), " ")
	if !strings.Contains(got, want) {
		t.Fatalf("view does not show the whole text\nwant: %s\nview:\n%s", want, clean)
	}
}

const noCheckoutRefusal = `no checkout declared: run lore work source-checkout demo
Work item 'demo' declares no source checkout, so this request cannot say which
clone it runs in. From inside the checkout this work belongs in, run:
  lore work source-checkout demo
then send the request again. Nothing was enqueued.`

func TestLaunchRefusalFromTheWriterRendersInFull(t *testing.T) {
	f := newWindowFixture(t)
	refusal := "--prefer-dir is not a checkout of this store; name one\n'/work/other-clone' cannot be served by this store's session host: /work/other-clone belongs to knowledge store /stores/other, not /stores/this. Name the top level of a git checkout of this store. Nothing was enqueued."
	raw, _ := json.Marshal(map[string]string{"error": refusal})
	f.respond(t, 0, 1, string(raw), "")
	m := f.window(t)
	m, cmd := launchFromModal(t, m, "demo")
	m = settle(t, m, cmd)
	if !m.refusalActive() || m.refusals[0].offer {
		t.Fatalf("refusal modal: active=%v", m.refusalActive())
	}
	if m.flashErr != "" {
		t.Fatalf("the refusal went to the flash: %q", m.flashErr)
	}
	if _, pending := m.launches["demo"]; pending || m.hasSessionPanel("demo") {
		t.Fatal("a refused launch left a pending launch or a panel")
	}
	assertShowsInFull(t, m.viewContent(), refusal)
	t.Run("Esc (dismiss)", func(t *testing.T) {
		nm, cmd := updateModel(t, m, press(tea.KeyEscape))
		if nm.refusalActive() || cmd != nil {
			t.Fatal("Esc did not dismiss the refusal")
		}
	})
	t.Run("other keys are swallowed", func(t *testing.T) {
		nm, cmd := updateModel(t, m, press('q'))
		if !nm.refusalActive() || isQuitCmd(cmd) {
			t.Fatal("a key other than Esc acted behind the refusal")
		}
	})
}

func TestLaunchRefusalWithoutJSONShowsWhatTheCommandPrinted(t *testing.T) {
	f := newWindowFixture(t)
	f.respond(t, 0, 2, "", "Error: lore: unknown session verb 'request'; run lore rebuild, then retry this launch from the window.\n")
	m := f.window(t)
	m, cmd := launchFromModal(t, m, "demo")
	m = settle(t, m, cmd)
	if !m.refusalActive() {
		t.Fatal("no refusal")
	}
	assertShowsInFull(t, m.viewContent(), "lore: unknown session verb 'request'; run lore rebuild, then retry this launch from the window.")
}

func TestLaunchRefusalJournaledAfterClaimRendersInFull(t *testing.T) {
	cases := []struct {
		event, title, reason, want string
	}{
		{"restore_refused", "Launch refused", "worktree refused: the source checkout " + "is on branch feature/x, and this request requires main; switch the checkout to main or re-declare it, then launch again", ""},
		{"request_abandoned", "Launch abandoned", "attempts exhausted (3): spawn: harness exited before its first screen: codex: unknown model gpt-6-astra", ""},
		{"request_expired", "Launch expired", "", "It waited past its time limit without the background host claiming it."},
		{"request_cancelled", "Launch cancelled", "cancelled by lore session cancel from a coordinator, who said: superseded by the reviewed plan revision", ""},
	}
	for _, tc := range cases {
		t.Run(tc.event, func(t *testing.T) {
			f := newWindowFixture(t)
			f.storeHost(t)
			f.respond(t, 0, 0, `{"request_id":"req-j","enqueued":true}`, "")
			m := f.window(t)
			m, cmd := launchFromModal(t, m, "demo")
			m = settle(t, m, cmd)
			f.appendEvent(t, map[string]any{"event_id": "ev-" + tc.event, "event": tc.event, "slug": "demo", "request_id": "req-j", "reason": tc.reason})
			m, _ = refresh(t, m)
			if !m.refusalActive() || m.refusals[0].title != tc.title {
				t.Fatalf("refusal = %#v", m.refusals)
			}
			if _, pending := m.launches["demo"]; pending {
				t.Fatal("a refused launch is still pending")
			}
			want := tc.reason
			if want == "" {
				want = tc.want
			}
			assertShowsInFull(t, m.viewContent(), want)
			m, _ = refresh(t, m)
			if len(m.refusals) != 1 {
				t.Fatalf("the refusal showed %d times", len(m.refusals))
			}
		})
	}
	t.Run("an outcome read before the request id arrived", func(t *testing.T) {
		f := newWindowFixture(t)
		f.storeHost(t)
		m := f.window(t)
		m, _ = updateModel(t, m, work.SpecRequestMsg{Slug: "demo"})
		m, _ = updateModel(t, m, press(tea.KeyEnter))
		f.appendEvent(t, map[string]any{"event_id": "ev-early", "event": "restore_refused", "slug": "demo", "request_id": "req-early", "reason": "checkout is not in this store"})
		m, _ = refresh(t, m)
		m, _ = updateModel(t, m, launchRequestedMsg{descriptor: m.launches["demo"].descriptor, checkout: f.checkout, requestID: "req-early"})
		m, _ = refresh(t, m)
		if !m.refusalActive() {
			t.Fatal("an outcome journaled before the request id arrived was lost")
		}
	})
}

func TestLaunchRefusalNoCheckoutOffersToDeclareTheWindowsCheckout(t *testing.T) {
	f := newWindowFixture(t)
	raw, _ := json.Marshal(map[string]string{"error": noCheckoutRefusal})
	f.respond(t, 1, 1, string(raw), "")
	f.respond(t, 2, 0, `{"request_id":"req-after-declare","enqueued":true}`, "")
	t.Setenv("LORE_SESSION_INSTANCE", "some-session")
	t.Setenv("LORE_SESSION_SLUG", "other-item")
	t.Setenv("LORE_SESSION_TYPE", "chat")
	m := f.window(t)
	m, cmd := launchFromModal(t, m, "demo")
	m = settle(t, m, cmd)
	if !m.refusalActive() || !m.refusals[0].offer || m.refusals[0].checkout != f.checkout {
		t.Fatalf("no offer: %#v", m.refusals)
	}
	out := m.viewContent()
	assertShowsInFull(t, out, noCheckoutRefusal)
	assertShowsInFull(t, out, "Enter declares this window's checkout,")
	assertShowsInFull(t, out, "as the checkout of demo (lore work source-checkout demo), then launches again.")

	t.Run("Esc (dismiss)", func(t *testing.T) {
		nm, cmd := updateModel(t, m, press(tea.KeyEscape))
		if nm.refusalActive() || cmd != nil {
			t.Fatal("Esc did not dismiss the offer")
		}
	})
	t.Run("Enter (declare and launch)", func(t *testing.T) {
		nm, cmd := updateModel(t, m, press(tea.KeyEnter))
		if cmd == nil || !nm.refusals[0].declaring {
			t.Fatal("Enter did not start the declaration")
		}
		nm = settle(t, nm, cmd)
		declares := f.calls(t, "work", "source-checkout")
		if len(declares) != 1 || strings.Join(declares[0].args, " ") != "work source-checkout demo" {
			t.Fatalf("declare calls = %#v", declares)
		}
		if declares[0].dir != f.checkout {
			t.Errorf("declared in %s, want the window's checkout %s", declares[0].dir, f.checkout)
		}
		if declares[0].identity != "unset,unset,unset" {
			t.Errorf("declaration ran with session identity %s", declares[0].identity)
		}
		if nm.refusalActive() {
			t.Fatalf("the modal stayed after a successful declaration: %#v", nm.refusals)
		}
		if n := len(f.calls(t, "session", "request")); n != 2 {
			t.Fatalf("the launch did not run again: %d requests", n)
		}
		if l, ok := nm.launches["demo"]; !ok || l.requestID != "req-after-declare" {
			t.Fatalf("relaunch = %#v", nm.launches)
		}
	})
	t.Run("a failed declaration is shown in full", func(t *testing.T) {
		f.stubFile(t, "declare.out", "Error: /elsewhere is not a checkout of this store: it belongs to knowledge store /other. Run this from a checkout of this store.")
		f.stubFile(t, "declare.code", "1")
		nm, cmd := updateModel(t, m, press(tea.KeyEnter))
		nm = settle(t, nm, cmd)
		if !nm.refusalActive() || nm.refusals[0].title != "Checkout not declared" || nm.refusals[0].offer {
			t.Fatalf("declaration failure = %#v", nm.refusals)
		}
		assertShowsInFull(t, nm.viewContent(), "it belongs to knowledge store /other. Run this from a checkout of this store.")
	})
}
