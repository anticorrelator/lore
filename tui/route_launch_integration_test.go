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
	kdir := t.TempDir()
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
	stub := "#!/bin/sh\nprintf '%s\\n' \"$@\"\nsleep 1\n"
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
	instances := filepath.Join(kdir, "_sessions", "instances")
	if err := os.MkdirAll(instances, 0755); err != nil {
		t.Fatal(err)
	}
	instance, _ := json.Marshal(map[string]any{"name": "integration-host", "pid": os.Getpid(), "repo": "fixture", "started": "2026-09-09T00:00:00Z", "initiator_default": "human", "project_dir": source, "sessions": []any{}})
	if err := os.WriteFile(filepath.Join(instances, "integration-host.json"), instance, 0644); err != nil {
		t.Fatal(err)
	}

	for _, tc := range []struct {
		typ, slug, initiator, wantArg, model string
		fast                                 bool
	}{
		{"worker", "demo--w1", "agent", "--autonomous-route-arg", "gpt-5.6-sol", true},
		{"spec", "demo", "human", "--human-route-arg", "gpt-6-astra", false},
	} {
		t.Run(tc.typ, func(t *testing.T) {
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

			rows := session.ScanPending(filepath.Join(kdir, "_sessions"))
			if len(rows) != 1 || rows[0].Route == nil {
				t.Fatalf("pending=%#v", rows)
			}
			req := rows[0]
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

			old, err := session.QueueTick(filepath.Join(kdir, "_sessions"), "host", "2026-09-09T01:27:41Z", source, map[string]bool{"host": true}, func(string) bool { return true }, nil, time.Now(), session.ReclaimAfter)
			if err != nil || old.Claimed != nil {
				t.Fatalf("old host claim=%#v err=%v", old.Claimed, err)
			}
			claimed, err := session.QueueTick(filepath.Join(kdir, "_sessions"), "host", routeAwareVintage, source, map[string]bool{"host": true}, func(string) bool { return true }, nil, time.Now(), session.ReclaimAfter)
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
			if got := strings.Contains(joined, `service_tier="fast"`); got != tc.fast {
				t.Fatalf("argv=%#v fast=%v, want %v", started.Cmd.Args, got, tc.fast)
			}
		})
	}
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
