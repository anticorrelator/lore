package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

var paneGenerationSeq atomic.Int64

// paneGenerationHost is a store host that has claimed one queued request and
// launched its session onto a real tmux pane, through the path the host runs:
// queue tick, worktree allocation, launch checkpoint, StartTerminalCmd. pane is
// the environment the session's harness started with.
type paneGenerationHost struct {
	m         model
	requestID string
	started   work.SessionProcessStartedMsg
	pane      map[string]string
}

func launchPaneGenerationSession(t *testing.T, slug string) paneGenerationHost {
	t.Helper()
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux is not installed")
	}
	root, err := os.MkdirTemp("/tmp", "lore-pgen-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	if root, err = filepath.EvalSymlinks(root); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMUX_TMPDIR", root)
	t.Setenv(config.SessionRuntimeEnv, fmt.Sprintf("pgen-%d-%d", os.Getpid(), paneGenerationSeq.Add(1)))
	t.Cleanup(func() { _ = exec.Command("tmux", "-L", config.TmuxServer(), "kill-server").Run() })
	t.Setenv("TMPDIR", t.TempDir())
	t.Setenv("TERM", "xterm-256color")
	for _, name := range []string{"TMUX", "TMUX_PANE"} {
		t.Setenv(name, "")
		os.Unsetenv(name)
	}

	f := newStoreHostFixture(t)
	writeRouteSettings(t)
	commitCheckout(t, f.one)
	bin := t.TempDir()
	recorder := "#!/usr/bin/env python3\nimport json, os, time\nout = os.environ['LORE_PANE_PROBE']\n" +
		"with open(out + '.tmp', 'w') as f:\n    json.dump(dict(os.environ), f)\nos.rename(out + '.tmp', out)\ntime.sleep(300)\n"
	if err := os.WriteFile(filepath.Join(bin, "claude"), []byte(recorder), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	probe := filepath.Join(t.TempDir(), "pane-env.json")
	t.Setenv("LORE_PANE_PROBE", probe)

	m := storeHostModel(t, f.store)
	m.tmuxEnabled = true
	// The host has been up for a while when the request arrives.
	m.instanceStartedISO = time.Now().Add(-time.Hour).UTC().Format("2006-01-02T15:04:05Z")
	requestID := "req-" + slug
	writeStoreRequest(t, m.sessionsDir, session.Request{RequestID: requestID, HostKey: storeHostKey, Type: "spec", Slug: strPtr(slug), Initiator: "agent",
		RequiredProjectDir: strPtr(f.one), PlacementStance: strPtr(session.StanceRequiredDir)})
	tick, ok := m.queueTickCmd()().(queueTickResultMsg)
	if !ok || tick.err != nil || tick.result.Claimed == nil || tick.result.Claimed.RequestID != requestID {
		t.Fatalf("queue tick did not claim %s: %+v", requestID, tick)
	}
	m, cmd := m.handleQueueTickResult(tick)
	batch, ok := cmd().(tea.BatchMsg)
	if !ok {
		t.Fatalf("claim returned %T, want a journal and spawn batch", cmd())
	}
	var started work.SessionProcessStartedMsg
	launched := false
	for _, child := range batch {
		switch msg := child().(type) {
		case journalResultMsg:
			if msg.err != nil {
				t.Fatalf("journal: %v", msg.err)
			}
		case work.SessionProcessStartedMsg:
			started, launched = msg, true
		case work.StreamErrorMsg:
			t.Fatalf("launch failed: %v", msg.Err)
		}
	}
	if !launched {
		t.Fatal("the claimed request was never launched")
	}
	t.Cleanup(func() {
		_ = exec.Command("tmux", "-L", config.TmuxServer(), "kill-session", "-t", "="+started.Tmux).Run()
		_ = started.Ptmx.Close()
	})
	if started.Tmux == "" || started.SessionID == "" {
		t.Fatalf("launch was not tmux-hosted with a session id: %+v", started)
	}

	deadline := time.Now().Add(15 * time.Second)
	var data []byte
	for {
		if data, err = os.ReadFile(probe); err == nil || time.Now().After(deadline) {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("the pane's harness never recorded its environment: %v", err)
	}
	var pane map[string]string
	if err := json.Unmarshal(data, &pane); err != nil {
		t.Fatal(err)
	}
	if pane["LORE_SESSION_GENERATION"] == "" {
		t.Fatalf("the pane carries no LORE_SESSION_GENERATION: %v", pane)
	}
	return paneGenerationHost{m: m, requestID: requestID, started: started, pane: pane}
}

// promote runs the host's promotion of a started session: its registry row,
// the spawned row and the launch checkpoint's removal.
func (h *paneGenerationHost) promote(t *testing.T) {
	t.Helper()
	var cmd tea.Cmd
	h.m, cmd = h.m.handleSessionProcessStarted(h.started)
	batch, ok := cmd().(tea.BatchMsg)
	if !ok {
		t.Fatalf("process start returned %T, want a batch", cmd())
	}
	done := make(chan hostPromotionDoneMsg, 1)
	for _, child := range batch {
		go func(c tea.Cmd) {
			if msg, ok := c().(hostPromotionDoneMsg); ok {
				done <- msg
			}
		}(child)
	}
	select {
	case msg := <-done:
		if msg.err != nil {
			t.Fatalf("promotion: %v", msg.err)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("the host never promoted the session")
	}
}

// adoptAfterDeath marks the registry row named row as left by a dead process and
// returns the session as a new host for the same store adopts it.
func (h *paneGenerationHost) adoptAfterDeath(t *testing.T, row, slug string) liveSession {
	t.Helper()
	path := filepath.Join(session.InstancesDir(h.m.sessionsDir), row+".json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var inst session.Instance
	if err := json.Unmarshal(data, &inst); err != nil {
		t.Fatal(err)
	}
	inst.PID = deadPID(t)
	if data, err = json.Marshal(inst); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	next := storeHostModel(t, h.m.config.KnowledgeDir)
	next.instanceName = "calm-otter-1d2e3f"
	next.tmuxEnabled = true
	scan := next.adoptionScanner()(nil)
	if len(scan.alive) != 1 || scan.alive[0].slug != slug || scan.alive[0].deadInstance != row {
		t.Fatalf("adoption of %s from %s found %+v (notices %+v)", slug, row, scan.alive, scan.notices)
	}
	next, _ = next.handleAdoptionScan(scan)
	ls, ok := next.localSessions[slug]
	if !ok || !ls.adopted {
		t.Fatalf("the new host did not adopt %s: %+v", slug, next.localSessions)
	}
	return ls
}

func TestPaneGenerationEqualsObservationGenerationSpawned(t *testing.T) {
	h := launchPaneGenerationSession(t, "gen-spawned")
	h.promote(t)
	ls, ok := h.m.localSessions["gen-spawned"]
	if !ok {
		t.Fatal("the launched session is not live on its host")
	}
	pane := h.pane["LORE_SESSION_GENERATION"]
	if got := observationGeneration(ls); got != pane {
		t.Fatalf("host generation %q, pane LORE_SESSION_GENERATION %q", got, pane)
	}
	if obs, _, _ := h.m.snapshotObservation("gen-spawned", time.Now()); obs.Generation != pane {
		t.Fatalf("the host observes generation %q, pane carries %q", obs.Generation, pane)
	}
	if !strings.HasPrefix(pane, h.started.SessionID+"/"+h.requestID+"/") {
		t.Fatalf("pane generation %q does not name session %s and request %s", pane, h.started.SessionID, h.requestID)
	}
}

func TestPaneGenerationEqualsObservationGenerationAdopted(t *testing.T) {
	h := launchPaneGenerationSession(t, "gen-adopted")
	h.promote(t)
	if _, err := os.Stat(filepath.Join(session.InstancesDir(h.m.sessionsDir), h.m.hostSpawnName(h.requestID)+".json")); !os.IsNotExist(err) {
		t.Fatalf("the launch checkpoint survived promotion: %v", err)
	}
	ls := h.adoptAfterDeath(t, h.m.instanceName, "gen-adopted")
	if got, pane := observationGeneration(ls), h.pane["LORE_SESSION_GENERATION"]; got != pane {
		t.Fatalf("adopted from the registry row: host generation %q, pane %q", got, pane)
	}
}

func TestPaneGenerationEqualsObservationGenerationCheckpointAdopted(t *testing.T) {
	h := launchPaneGenerationSession(t, "gen-checkpoint")
	// The host dies after the harness started and before it promoted the
	// session, so only the launch checkpoint lists it.
	checkpoint := h.m.hostSpawnName(h.requestID)
	ls := h.adoptAfterDeath(t, checkpoint, "gen-checkpoint")
	if got, pane := observationGeneration(ls), h.pane["LORE_SESSION_GENERATION"]; got != pane {
		t.Fatalf("adopted from the launch checkpoint: host generation %q, pane %q", got, pane)
	}
}
