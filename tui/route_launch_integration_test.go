package main

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
	"github.com/anticorrelator/lore/tui/internal/worktree"
)

const routeAwareVintage = "2026-09-09T01:27:42Z"

func TestRouteRequestQueueDescriptorLaunchIntegration(t *testing.T) {
	repo, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}
	source := initRouteLaunchRepo(t)
	kdir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	data := t.TempDir()
	bin := t.TempDir()
	t.Setenv("LORE_DATA_DIR", data)
	t.Setenv("LORE_FRAMEWORK", "codex")
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	if err := os.Symlink(filepath.Join(repo, "scripts"), filepath.Join(data, "scripts")); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(data, "config"), 0755); err != nil {
		t.Fatal(err)
	}
	settings := `{"version":2,"tui_launch_framework":"codex","capability_overrides":{},"routes":{"default":{"framework":"codex","model":"gpt-6-astra","effort":"high"},"lead":{"framework":"codex","model":"gpt-6-astra","effort":"high"},"worker":{"framework":"codex","model":"gpt-5.6-sol","effort":"high","service_tier":"fast"}},"harnesses":{"codex":{"args":["--human-route-arg"],"autonomous_args":["--autonomous-route-arg"],"native_models":{"default":"gpt-5.5-high"}}}}`
	if err := os.WriteFile(filepath.Join(data, "config", "settings.json"), []byte(settings), 0644); err != nil {
		t.Fatal(err)
	}
	stub := "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$ROUTE_ARGV_RECORD\"\nsleep 1\n"
	if err := os.WriteFile(filepath.Join(bin, "codex"), []byte(stub), 0755); err != nil {
		t.Fatal(err)
	}

	item := filepath.Join(kdir, "_work", "demo")
	if err := os.MkdirAll(item, 0755); err != nil {
		t.Fatal(err)
	}
	meta, _ := json.Marshal(map[string]any{"slug": "demo", "title": "Demo", "status": "active", "source_checkout": source})
	if err := os.WriteFile(filepath.Join(item, "_meta.json"), meta, 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(item, "plan.md"), []byte("# Plan\n"), 0644); err != nil {
		t.Fatal(err)
	}
	// Route options carry a build-vintage floor, and a floor is published only
	// when the store's live session host meets it; that host is the claimer.
	hostKey := serveStoreForWriter(t, kdir, routeAwareVintage)
	sessionsDir := filepath.Join(kdir, "_sessions")
	scope := session.StoreScope{KnowledgeDir: kdir, Pinned: true}
	live := map[string]bool{"store-host": true}

	for _, tc := range []struct {
		typ, slug, initiator, wantArg, model string
		fast                                 bool
	}{
		{"worker", "demo--w1", "agent", "--autonomous-route-arg", "gpt-5.6-sol", true},
		{"spec", "demo", "human", "--human-route-arg", "gpt-6-astra", false},
	} {
		t.Run(tc.typ, func(t *testing.T) {
			record := filepath.Join(t.TempDir(), "argv")
			t.Setenv("ROUTE_ARGV_RECORD", record)
			epoch := "20260909T020000Z-abcdef12"
			if tc.typ == "spec" {
				epoch = "20260909T020001Z-abcdef13"
			}
			identity, err := worktree.Create(context.Background(), source, filepath.Join(t.TempDir(), "session"), epoch)
			if err != nil {
				t.Fatal(err)
			}
			identityPath := filepath.Join(t.TempDir(), "identity.json")
			raw, _ := json.Marshal(identity)
			if err := os.WriteFile(identityPath, raw, 0644); err != nil {
				t.Fatal(err)
			}
			confirmFlag := "--yes"
			if tc.initiator == "human" {
				confirmFlag = "--confirm"
			}
			args := []string{filepath.Join(repo, "scripts", "session-request.sh"), "--type", tc.typ, "--slug", tc.slug, "--initiator", tc.initiator, "--worktree-identity", identityPath, "--anywhere", "--kdir", kdir, confirmFlag, "--json"}
			if tc.typ == "worker" {
				args = append(args, "--context", "compiled integration brief")
			} else {
				args = append(args, "--confirm")
			}
			cmd := exec.Command("bash", args...)
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("request: %v: %s", err, out)
			}

			rows := session.ScanPending(sessionsDir)
			if len(rows) != 1 || rows[0].Route == nil {
				t.Fatalf("pending=%#v", rows)
			}
			req := rows[0]
			if req.HostKey != hostKey {
				t.Fatalf("host_key=%q, want the store host's %q", req.HostKey, hostKey)
			}
			if req.MinVintageValue() != routeAwareVintage {
				t.Fatalf("floor=%q", req.MinVintageValue())
			}
			events, err := os.ReadFile(filepath.Join(kdir, "_sessions", "events.jsonl"))
			if err != nil {
				t.Fatal(err)
			}
			last := strings.TrimSpace(strings.Split(strings.TrimSpace(string(events)), "\n")[len(strings.Split(strings.TrimSpace(string(events)), "\n"))-1])
			var event struct {
				Route json.RawMessage `json:"route"`
			}
			if err := json.Unmarshal([]byte(last), &event); err != nil {
				t.Fatal(err)
			}
			routeJSON, _ := json.Marshal(req.Route)
			if string(event.Route) != string(routeJSON) {
				t.Fatalf("event route=%s row route=%s", event.Route, routeJSON)
			}

			old, err := session.QueueTickForStoreHost(sessionsDir, "store-host", "2026-09-09T01:27:41Z", hostKey, scope, live, func(string) bool { return true }, nil, time.Now(), session.ReclaimAfter, nil)
			if err != nil || old.Claimed != nil {
				t.Fatalf("old host claim=%#v err=%v", old.Claimed, err)
			}
			claimed, err := session.QueueTickForStoreHost(sessionsDir, "store-host", routeAwareVintage, hostKey, scope, live, func(string) bool { return true }, nil, time.Now(), session.ReclaimAfter, nil)
			if err != nil || claimed.Claimed == nil {
				t.Fatalf("new host claim=%#v err=%v", claimed.Claimed, err)
			}
			d := descriptorFromRequest(*claimed.Claimed)
			if (tc.initiator == "human") == d.SkipConfirm {
				t.Fatalf("skip_confirm=%v for initiator=%s", d.SkipConfirm, tc.initiator)
			}
			msg := work.StartTerminalCmd(d, 80, 24, data, work.SessionEnv{}, false)()
			started, ok := msg.(work.SessionProcessStartedMsg)
			if !ok {
				t.Fatalf("launch=%T %+v", msg, msg)
			}
			defer started.Ptmx.Close()
			joined := strings.Join(started.Cmd.Args, "\x00")
			want := []string{tc.wantArg, "-m", tc.model, "-c", `model_reasoning_effort="high"`}
			if tc.fast {
				want = append(want, "-c", `service_tier="fast"`)
			}
			if !strings.Contains(joined, strings.Join(want, "\x00")) {
				t.Fatalf("argv=%#v missing ordered %#v", started.Cmd.Args, want)
			}
			waitForRouteArgv(t, record, want)
			if got := strings.Contains(joined, `service_tier="fast"`); got != tc.fast {
				t.Fatalf("argv=%#v fast=%v, want %v", started.Cmd.Args, got, tc.fast)
			}
		})
	}

	t.Run("managed-retry-preserves-frozen-route", func(t *testing.T) {
		record := filepath.Join(t.TempDir(), "argv")
		t.Setenv("ROUTE_ARGV_RECORD", record)
		// The current worker selection deliberately differs from the retry manifest.
		changed := `{"version":2,"tui_launch_framework":"codex","capability_overrides":{},"routes":{"default":"codex/gpt-6-astra-high","worker":"codex/gpt-6-astra-high"},"harnesses":{"codex":{"args":["--human-route-arg"],"autonomous_args":["--autonomous-route-arg"],"native_models":{"default":"gpt-5.5-high"}}}}`
		if err := os.WriteFile(filepath.Join(data, "config", "settings.json"), []byte(changed), 0644); err != nil {
			t.Fatal(err)
		}
		managedDir := filepath.Join(kdir, "_sessions", "managed")
		if err := os.MkdirAll(managedDir, 0755); err != nil {
			t.Fatal(err)
		}
		manifestPath := filepath.Join(managedDir, "demo--w3.json")
		frozen := map[string]any{
			"framework": "codex", "model": "gpt-5.6-sol", "options": map[string]any{"effort": "high", "service_tier": "fast"},
			"routing_source": map[string]any{"layer": "routes", "role": "worker"},
		}
		manifest := map[string]any{
			"handle": "demo--w3", "request_id": "managed-0123456789abcdef0123456789abcdef",
			"host_key": hostKey, "work_item": "demo", "source_dir": source,
			"route": frozen, "framework": "codex", "model": "gpt-5.6-sol",
			"routing_source": frozen["routing_source"], "context": "retry integration", "state": "intent",
		}
		raw, _ := json.Marshal(manifest)
		if err := os.WriteFile(manifestPath, raw, 0644); err != nil {
			t.Fatal(err)
		}
		py := `import importlib.util,sys
from unittest.mock import patch
spec=importlib.util.spec_from_file_location("session_managed",sys.argv[1])
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
k=m.Path(sys.argv[2]); manifest=m.read(m.Path(sys.argv[3]))
status={"instance_name":"store-host","runtime_capabilities":["position-preparation-v1"]}
with patch.object(m,"ensure",return_value=status), patch.object(m,"ready",return_value=status):
    m.enqueue_start(k,manifest)`
		cmd := exec.Command("python3", "-c", py, filepath.Join(repo, "scripts", "session-managed.py"), kdir, manifestPath)
		cmd.Dir = source
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("managed enqueue: %v: %s", err, out)
		}
		persisted, err := os.ReadFile(manifestPath)
		var persistedManifest struct {
			State string `json:"state"`
		}
		decodeErr := json.Unmarshal(persisted, &persistedManifest)
		if err != nil || decodeErr != nil || persistedManifest.State != "enqueued" {
			t.Fatalf("manifest=%s err=%v", persisted, err)
		}
		claimed, err := session.QueueTickForStoreHost(sessionsDir, "store-host", routeAwareVintage, hostKey, scope, live, func(string) bool { return true }, nil, time.Now(), session.ReclaimAfter, nil)
		if err != nil || claimed.Claimed == nil {
			t.Fatalf("managed claim=%#v err=%v", claimed.Claimed, err)
		}
		gotRoute, _ := json.Marshal(claimed.Claimed.Route)
		wantRoute, _ := json.Marshal(frozen)
		if string(gotRoute) != string(wantRoute) {
			t.Fatalf("managed route=%s want=%s", gotRoute, wantRoute)
		}
		identity, err := worktree.Create(context.Background(), source, filepath.Join(t.TempDir(), "session"), "20260909T040000Z-abcdef15")
		if err != nil {
			t.Fatal(err)
		}
		d := descriptorFromRequest(*claimed.Claimed)
		d.Worktree = &identity
		msg := work.StartTerminalCmd(d, 80, 24, data, work.SessionEnv{}, false)()
		started, ok := msg.(work.SessionProcessStartedMsg)
		if !ok {
			t.Fatalf("managed launch=%T %+v", msg, msg)
		}
		defer started.Ptmx.Close()
		waitForRouteArgv(t, record, []string{"--autonomous-route-arg", "-m", "gpt-5.6-sol", "-c", `model_reasoning_effort="high"`, "-c", `service_tier="fast"`})
	})
}

// TestWindowLaunchClaimsAndLaunchesFrozenRoute runs a window's launch through
// the real request writer (the stub lore hands `session request` to it), claims
// the row as the store host does, and launches it with the route the window froze.
func TestWindowLaunchClaimsAndLaunchesFrozenRoute(t *testing.T) {
	f := newWindowFixture(t)
	repo, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("STUB_LORE_WRITER", filepath.Join(repo, "scripts", "session-request.sh"))
	data := os.Getenv("LORE_DATA_DIR")
	settings := `{"version":2,"tui_launch_framework":"codex","capability_overrides":{},"routes":{"default":"codex/gpt-6-astra-high","lead":{"framework":"codex","model":"gpt-6-astra","effort":"high"}},"harnesses":{"claude-code":{"args":[],"native_models":{"default":"opus"}},"codex":{"args":["--human-direct"],"native_models":{"default":"gpt-5.5-high"}},"opencode":{"args":[],"native_models":{"default":"anthropic/opus"}}}}`
	if err := os.WriteFile(filepath.Join(data, "config", "settings.json"), []byte(settings), 0644); err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	record := filepath.Join(t.TempDir(), "argv")
	t.Setenv("ROUTE_ARGV_RECORD", record)
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	if err := os.WriteFile(filepath.Join(bin, "codex"), []byte("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$ROUTE_ARGV_RECORD\"\nsleep 1\n"), 0755); err != nil {
		t.Fatal(err)
	}
	hostKey := serveStoreForWriter(t, f.kdir, routeAwareVintage)

	m := f.window(t)
	m, cmd := m.launchSession(work.SessionDescriptor{Type: work.SessionSpec, Slug: "direct", Initiator: "human", SkipConfirm: false})
	m = settle(t, m, cmd)
	if m.refusalActive() {
		t.Fatalf("the writer refused the window's launch: %s", m.refusals[0].text)
	}
	rows := session.ScanPending(f.sessions)
	if len(rows) != 1 || rows[0].Route == nil {
		t.Fatalf("pending=%#v", rows)
	}
	if rows[0].HostKey != hostKey || rows[0].TargetInstance != nil || rows[0].PreferProjectDir == nil || *rows[0].PreferProjectDir != f.checkout {
		t.Fatalf("row host_key=%q target=%v prefer=%v, want the store key, no target and the window's checkout %s", rows[0].HostKey, rows[0].TargetInstance, rows[0].PreferProjectDir, f.checkout)
	}
	if l := m.launches["direct"]; l.requestID != rows[0].RequestID {
		t.Fatalf("the window follows request %q, the writer enqueued %q", l.requestID, rows[0].RequestID)
	}
	claimed, err := session.QueueTickForStoreHost(f.sessions, "store-host", routeAwareVintage, hostKey, session.StoreScope{KnowledgeDir: f.kdir, Pinned: true}, map[string]bool{"store-host": true}, func(string) bool { return true }, nil, time.Now().Add(20*time.Second), session.ReclaimAfter, nil)
	if err != nil || claimed.Claimed == nil {
		t.Fatalf("claim=%#v err=%v", claimed.Claimed, err)
	}
	identity, err := worktree.Create(context.Background(), f.checkout, filepath.Join(t.TempDir(), "session"), "20260909T030000Z-abcdef14")
	if err != nil {
		t.Fatal(err)
	}
	d := descriptorFromRequest(*claimed.Claimed)
	d.Worktree = &identity
	launch := work.StartTerminalCmd(d, 80, 24, data, work.SessionEnv{}, false)()
	started, ok := launch.(work.SessionProcessStartedMsg)
	if !ok {
		t.Fatalf("launch=%T %+v", launch, launch)
	}
	defer started.Ptmx.Close()
	want := []string{"--human-direct", "-m", "gpt-6-astra", "-c", `model_reasoning_effort="high"`}
	waitForRouteArgv(t, record, want)
}

func waitForRouteArgv(t *testing.T, path string, want []string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		raw, err := os.ReadFile(path)
		if err == nil {
			got := strings.Split(strings.TrimSpace(string(raw)), "\n")
			if strings.Contains(strings.Join(got, "\x00"), strings.Join(want, "\x00")) {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("fake harness did not record ordered argv %#v", want)
}

func initRouteLaunchRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for _, args := range [][]string{{"init"}, {"config", "user.email", "route@example.invalid"}, {"config", "user.name", "Route Test"}} {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "marker"), []byte("route\n"), 0644); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"add", "marker"}, {"commit", "-m", "base"}} {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	physical, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	return physical
}
