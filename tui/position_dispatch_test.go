package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

func TestPositionDescriptorRetainsContext(t *testing.T) {
	raw := json.RawMessage(`{"position_preparation":{"bindings":{"execution_root":null}}}`)
	req := session.Request{Type: "worker", ExtraContext: raw}
	d := descriptorFromRequest(req)
	if string(d.PositionContext) != string(raw) || d.ExtraContext != "" {
		t.Fatalf("lost preparation: %+v", d)
	}
}

func positionTestTree(t *testing.T, descriptor work.SessionDescriptor) work.SessionDescriptor {
	t.Helper()
	source := t.TempDir()
	for _, args := range [][]string{{"init"}, {"-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "fixture"}} {
		cmd := exec.Command("git", args...)
		cmd.Dir = source
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git: %v: %s", err, out)
		}
	}
	msg := allocateSessionWorktreeCmd(descriptor, source, filepath.Join(t.TempDir(), "execution"), "position-launch-fixture",
		func(ready work.SessionDescriptor) tea.Msg { return ready })()
	ready, ok := msg.(work.SessionDescriptor)
	if !ok || ready.Worktree == nil {
		t.Fatalf("ordinary allocation: %+v", msg)
	}
	if string(ready.PositionContext) != string(descriptor.PositionContext) {
		t.Fatal("allocation lost position inputs")
	}
	return ready
}

func TestPositionProductionLaunch(t *testing.T) {
	fixtureRoot := os.Getenv("POSITION_SESSION_FIXTURES")
	if fixtureRoot == "" {
		t.Skip("run tests/test_position_session_launch.sh for canonical packet fixtures")
	}
	data, err := os.ReadFile(filepath.Join(fixtureRoot, "launch", "examples.json"))
	if err != nil {
		t.Fatal(err)
	}
	var examples []struct {
		Position, Framework, Mode, Kdir, Model string
		QueuePath                              string `json:"queue_path"`
	}
	if err := json.Unmarshal(data, &examples); err != nil {
		t.Fatal(err)
	}
	for _, example := range examples {
		t.Run(example.Framework+"/"+example.Position+"/"+example.Mode, func(t *testing.T) {
			t.Setenv("LORE_DATA_DIR", example.Kdir)
			t.Setenv("LORE_KNOWLEDGE_DIR", example.Kdir)
			t.Setenv("HOME", filepath.Dir(example.Kdir))
			t.Setenv("LORE_HARNESS_ARGS", "[]")
			t.Setenv("LORE_FRAMEWORK", "")
			bin := t.TempDir()
			stub := "#!/usr/bin/env python3\nimport json,os,sys\nwith open(os.environ['POSITION_CAPTURE'],'w') as f: json.dump({'args':sys.argv[1:],'cwd':os.getcwd(),'config':os.environ.get('OPENCODE_CONFIG_CONTENT'),'manifest':os.environ.get('LORE_POSITION_DISPATCH_MANIFEST'),'sha256':os.environ.get('LORE_POSITION_DISPATCH_SHA256'),'model':os.environ.get('LORE_SESSION_MODEL')},f)\n"
			for _, name := range []string{"claude", "codex", "opencode"} {
				if err := os.WriteFile(filepath.Join(bin, name), []byte(stub), 0755); err != nil {
					t.Fatal(err)
				}
			}
			t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
			raw, err := os.ReadFile(example.QueuePath)
			if err != nil {
				t.Fatal(err)
			}
			var req session.Request
			if err := json.Unmarshal(raw, &req); err != nil {
				t.Fatal(err)
			}
			d := descriptorFromRequest(req)
			d = positionTestTree(t, d)
			identity := *d.Worktree
			capture := filepath.Join(fixtureRoot, "launch", example.Framework+"-"+example.Position+"-"+example.Mode+"-captured.json")
			t.Setenv("POSITION_CAPTURE", capture)
			// A failed binding must never reach the capturing process.
			bad := d
			bad.Framework = "unknown"
			if _, ok := work.StartTerminalCmd(bad, 80, 24, example.Kdir, work.SessionEnv{}, false)().(work.StreamErrorMsg); !ok {
				t.Fatal("invalid activation spawned")
			}
			if _, err := os.Stat(capture); !os.IsNotExist(err) {
				t.Fatal("capture exists after refusal")
			}
			msg := work.StartTerminalCmd(d, 80, 24, example.Kdir, work.SessionEnv{}, false)()
			started, ok := msg.(work.SessionProcessStartedMsg)
			if !ok {
				t.Fatalf("spawn: %T %+v", msg, msg)
			}
			defer started.Ptmx.Close()
			if err := started.Cmd.Wait(); err != nil {
				t.Fatal(err)
			}
			captured, err := os.ReadFile(capture)
			if err != nil {
				t.Fatal(err)
			}
			var actual struct {
				Args                                 []string
				Cwd, Config, Manifest, Sha256, Model string
			}
			if err := json.Unmarshal(captured, &actual); err != nil {
				t.Fatal(err)
			}
			if actual.Cwd != identity.CanonicalPath {
				t.Fatalf("cwd %s != %s", actual.Cwd, identity.CanonicalPath)
			}
			manifestBytes, err := os.ReadFile(actual.Manifest)
			if err != nil {
				t.Fatal(err)
			}
			if actual.Sha256 != fmt.Sprintf("%x", sha256.Sum256(manifestBytes)) {
				t.Fatal("launch lost or changed manifest digest")
			}
			if actual.Model != d.Model {
				t.Fatalf("resolved model missing: %q", actual.Model)
			}
			var manifest struct {
				Bindings map[string]any
				Producer map[string]string
				Payload  struct{ Path string }
			}
			if err := json.Unmarshal(manifestBytes, &manifest); err != nil {
				t.Fatal(err)
			}
			if manifest.Bindings["execution_root"] != actual.Cwd || manifest.Producer["position"] != example.Position {
				t.Fatalf("wrong producer/root: %s", manifestBytes)
			}
			payload, err := os.ReadFile(manifest.Payload.Path)
			if err != nil {
				t.Fatal(err)
			}
			if actual.Args[len(actual.Args)-1] != string(payload) {
				t.Fatal("payload bytes changed")
			}
			value := func(flag string) string {
				for i, arg := range actual.Args {
					if arg == flag && i+1 < len(actual.Args) {
						return actual.Args[i+1]
					}
				}
				return ""
			}
			expectedModel := example.Model
			if expectedModel == "" {
				expectedModel = "provider/opaque-model"
			}
			if value("--model") != expectedModel {
				t.Fatal("model pin changed")
			}
			native, err := os.ReadFile(filepath.Join(filepath.Dir(actual.Manifest), "native.md"))
			if err != nil {
				t.Fatal(err)
			}
			if example.Framework == "codex" {
				if value("--agent") != "" || strings.HasPrefix(string(native), "---") {
					t.Fatal("wrong Codex surface")
				}
			} else {
				var definitions map[string]map[string]any
				if example.Framework == "claude-code" {
					if actual.Args[len(actual.Args)-2] != "--" {
						t.Fatal("variadic tools consume positional prompt")
					}
					if err := json.Unmarshal([]byte(value("--agents")), &definitions); err != nil {
						t.Fatal(err)
					}
					if strings.Contains(value("--tools"), "Edit") != (example.Position == "worker") {
						t.Fatal("tool scope changed")
					}
				} else {
					var cfg struct{ Agent map[string]map[string]any }
					if err := json.Unmarshal([]byte(actual.Config), &cfg); err != nil {
						t.Fatal(err)
					}
					definitions = cfg.Agent
					if value("--prompt") != string(payload) {
						t.Fatal("OpenCode prompt was positional")
					}
				}
				selected, ok := definitions[value("--agent")]
				if !ok {
					t.Fatal("selected definition absent")
				}
				parts := strings.SplitN(string(native), "---\n", 3)
				if len(parts) != 3 || selected["prompt"] != parts[2] {
					t.Fatal("native prompt bytes changed")
				}
				if example.Framework == "opencode" {
					permission := selected["permission"].(map[string]any)
					if (permission["edit"] == "allow") != (example.Position == "worker") || selected["mode"] != "primary" {
						t.Fatal("native permissions/mode changed")
					}
				}
			}
			// Corrupted required identities and dependencies fail in the real host.
			if example.Framework == "codex" && example.Position == "worker" {
				var context map[string]any
				if err := json.Unmarshal(d.PositionContext, &context); err != nil {
					t.Fatal(err)
				}
				pending := context["position_preparation"].(map[string]any)
				bindings := pending["bindings"].(map[string]any)
				checkRefusal := func(candidate work.SessionDescriptor) {
					t.Helper()
					if err := os.Remove(capture); err != nil && !os.IsNotExist(err) {
						t.Fatal(err)
					}
					if _, ok := work.StartTerminalCmd(candidate, 80, 24, example.Kdir, work.SessionEnv{}, false)().(work.StreamErrorMsg); !ok {
						t.Fatal("invalid binding spawned")
					}
					if _, err := os.Stat(capture); !os.IsNotExist(err) {
						t.Fatal("capturing process ran after refusal")
					}
				}
				for _, field := range []string{"task_id", "packet_id", "revision_id", "assignment", "report_id", "mode"} {
					original := bindings[field]
					bindings[field] = "changed"
					bad = d
					bad.PositionContext, _ = json.Marshal(context)
					checkRefusal(bad)
					bindings[field] = original
				}
				descriptor := pending["descriptor"].(map[string]any)
				dependency := descriptor["body_path"].(string)
				original, err := os.ReadFile(dependency)
				if err != nil {
					t.Fatal(err)
				}
				if err := os.Remove(dependency); err != nil {
					t.Fatal(err)
				}
				checkRefusal(d)
				if err := os.WriteFile(dependency, original, 0644); err != nil {
					t.Fatal(err)
				}
				launchFile := filepath.Join(filepath.Dir(actual.Manifest), "launch.json")
				original, err = os.ReadFile(launchFile)
				if err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(launchFile, []byte(`{}`), 0644); err != nil {
					t.Fatal(err)
				}
				checkRefusal(d)
				if err := os.WriteFile(launchFile, original, 0644); err != nil {
					t.Fatal(err)
				}
				// Retain the successful process capture as evidence after refusal probes.
				if err := os.WriteFile(capture, captured, 0644); err != nil {
					t.Fatal(err)
				}
			}
			// Replay revalidates the final root and every reference before spawn.
			published := map[string]any{"dispatch_guidance": string(payload), "position_dispatch": map[string]any{
				"manifest_path": actual.Manifest, "manifest_sha256": actual.Sha256,
				"payload_path": manifest.Payload.Path, "payload_sha256": fmt.Sprintf("%x", sha256.Sum256(payload)), "native_path": filepath.Join(filepath.Dir(actual.Manifest), "native.md"), "native_sha256": fmt.Sprintf("%x", sha256.Sum256(native))}}
			bad = d
			bad.PositionContext, _ = json.Marshal(published)
			replay := work.StartTerminalCmd(bad, 80, 24, example.Kdir, work.SessionEnv{}, false)()
			again, ok := replay.(work.SessionProcessStartedMsg)
			if !ok {
				t.Fatalf("fixed replay refused: %+v", replay)
			}
			if err := again.Cmd.Wait(); err != nil {
				t.Fatal(err)
			}
			again.Ptmx.Close()
			wrongRoot := positionTestTree(t, bad)
			bad.Worktree = wrongRoot.Worktree
			if _, ok := work.StartTerminalCmd(bad, 80, 24, example.Kdir, work.SessionEnv{}, false)().(work.StreamErrorMsg); !ok {
				t.Fatal("wrong root spawned")
			}
			bad.Worktree = &identity
			published["position_dispatch"].(map[string]any)["native_sha256"] = "wrong"
			bad.PositionContext, _ = json.Marshal(published)
			if _, ok := work.StartTerminalCmd(bad, 80, 24, example.Kdir, work.SessionEnv{}, false)().(work.StreamErrorMsg); !ok {
				t.Fatal("mixed reference spawned")
			}
		})
	}
}
