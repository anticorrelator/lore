package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/anticorrelator/lore/tui/internal/worktree"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

func TestHostRuntimeLockAndIdleIntentBarrier(t *testing.T) {
	dir := t.TempDir()
	lock, err := hostLock(filepath.Join(dir, "runtime.lock"), true)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	other, err := hostLock(filepath.Join(dir, "runtime.lock"), true)
	if other != nil {
		other.Close()
	}
	if !errors.Is(err, syscall.EWOULDBLOCK) {
		t.Fatalf("duplicate lock=%v", err)
	}
	m, sessionsDir := baseSessionModel(t)
	m.hostKey = "key"
	ready := filepath.Join(m.hostDir(), "ready.json")
	if err := hostAtomicJSON(ready, map[string]bool{"ready": true}); err != nil {
		t.Fatal(err)
	}
	h := sessionHostModel{runtime: m, options: hostOptions{Key: "key", ReadyFile: ready}}
	if err := hostAtomicJSON(filepath.Join(sessionsDir, "managed", "item--w1.json"), map[string]string{"host_key": "key", "state": "enqueueing"}); err != nil {
		t.Fatal(err)
	}
	if stop, err := h.withdrawIfIdle(); err != nil || stop {
		t.Fatalf("idle crossed enqueue barrier: %v %v", stop, err)
	}
	if _, err := os.Stat(ready); err != nil {
		t.Fatal("ready withdrawn during enqueue", err)
	}
}

func TestHostDeliveryCrashRecoveryNeverReplays(t *testing.T) {
	for _, kind := range []string{"send", "answer"} {
		t.Run(kind, func(t *testing.T) {
			m, _ := baseSessionModel(t)
			m.hostKey = "key"
			m.eventScript = repoScriptPath(t, "session-event-append.sh")
			ev := session.Event{Event: session.EventSendRefused, Slug: "demo", RequestID: "req-1", Reason: "delivery-uncertain", ActorInstance: session.StrPtr("dead")}
			if kind == "answer" {
				ev.Event = session.EventAnswerRefused
				ev.Option = 2
			}
			if err := m.hostDeliveryAttempt(kind, ev); err != nil {
				t.Fatal(err)
			}
			if err := m.hostDeliveryAttempt(kind, ev); err == nil {
				t.Fatal("duplicate input attempt allowed")
			}
			// The restarted model has none of the original in-memory verification state.
			m.instanceName = "new-owner"
			if err := m.recoverHostDeliveries(); err != nil {
				t.Fatal(err)
			}
			if err := m.recoverHostDeliveries(); err != nil {
				t.Fatal("retry not idempotent", err)
			}
			got := readEventTypes(t, m.config.KnowledgeDir)
			if len(got) != 1 || got[0] != ev.Event {
				t.Fatalf("recovered outcomes=%v", got)
			}
			b, err := os.ReadFile(m.hostDeliveryPath(ev.RequestID))
			if err != nil {
				t.Fatal(err)
			}
			var row hostDelivery
			if err = json.Unmarshal(b, &row); err != nil {
				t.Fatal(err)
			}
			if !row.Terminal || row.Event.Reason != "delivery-uncertain" {
				t.Fatalf("uncertainty lost: %+v", row)
			}
		})
	}
}

func TestHostAdoptionFailurePreservesOwnership(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.hostKey = "key"
	m.localSessions = map[string]liveSession{"demo": {adopted: true, requestID: "spawn"}}
	m.pendingSpawns = map[string]liveSession{"demo": {adopted: true, requestID: "spawn"}}
	h := &sessionHostModel{runtime: m}
	_, cmd := h.Update(work.StreamErrorMsg{Slug: "demo", Err: errors.New("attach refused")})
	if h.err == nil || cmd == nil {
		t.Fatal("attach failure did not fail recovery")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Fatal("host did not request controlled restart")
	}
	if len(h.runtime.localSessions) != 1 || len(h.runtime.pendingSpawns) != 1 {
		t.Fatal("attach failure discarded ownership")
	}
}

func TestHostOutcomeBeforeCloseSurvivesCrashBeforeCommands(t *testing.T) {
	_, source, identity := closedSessionWorktree(t, "host-close-crash")
	m, _ := baseSessionModel(t)
	m.hostKey = "key"
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	m.localSessions = map[string]liveSession{"demo": {typ: "worker", initiator: "agent", requestID: "spawn", sourceDir: source, worktree: &identity}}
	// Execute the real production handler, then lose every returned command.
	// This is the window after terminal-ledger fsync but before outcome append.
	_, _ = m.handleWorktreeDisposition(worktreeDispositionMsg{slug: "demo", closeRequestID: "close", outcome: worktree.PublishOutcome{Kind: worktree.OutcomePublished, Identity: identity}})
	if got := readEventTypes(t, m.config.KnowledgeDir); len(got) != 0 {
		t.Fatalf("handler unexpectedly executed commands: %v", got)
	}
	if err := m.recoverHostDeliveries(); err != nil {
		t.Fatal(err)
	}
	got := readEventTypes(t, m.config.KnowledgeDir)
	if len(got) != 2 || got[0] != session.EventWorktreePublished || got[1] != session.EventClosed {
		t.Fatalf("recovery event order=%v", got)
	}
	if _, err := os.Stat(identity.CanonicalPath); !os.IsNotExist(err) {
		t.Fatalf("recovery left checkout: %v", err)
	}
	proof := filepath.Join(m.hostDir(), "cleanup", "demo.json")
	if _, err := os.Stat(proof); err != nil {
		t.Fatal("cleanup receipt missing", err)
	}
	// Also cover death after physical removal but before its receipt is durable.
	if err := os.Remove(proof); err != nil {
		t.Fatal(err)
	}
	if err := m.recoverHostDeliveries(); err != nil {
		t.Fatal("repeat cleanup recovery", err)
	}
	if got := readEventTypes(t, m.config.KnowledgeDir); len(got) != 2 {
		t.Fatalf("duplicate outcomes=%v", got)
	}
}

func TestHostAllocationIntentPrecedesCreateAndRecoversNoLaunch(t *testing.T) {
	_, source, _ := closedSessionWorktree(t, "source-fixture")
	m, _ := baseSessionModel(t)
	m.hostKey = "key"
	m.normalizedProjectDir = source
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	path := filepath.Join(m.sessionsDir, "worktrees", "allocation-crash")
	checkpoint := m.hostAllocationCheckpoint("spawn", work.SessionDescriptor{Slug: "demo", Type: "worker"})
	_, err := worktree.CreateOnRef(context.Background(), source, path, "allocation-crash", "", func(intent worktree.AllocationIntent) error {
		if _, err := os.Lstat(path); !os.IsNotExist(err) {
			t.Fatalf("checkpoint followed filesystem mutation: %v", err)
		}
		return checkpoint(intent)
	})
	if err != nil {
		t.Fatal(err)
	}
	// No Prepared or started handler ran: the allocation record alone owns this.
	if err := m.recoverHostAllocations(map[string]bool{m.hostKey: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("unfinished allocation leaked: %v", err)
	}
	if _, err := os.Stat(m.hostAllocationPath("spawn")); !os.IsNotExist(err) {
		t.Fatalf("allocation claim not retired: %v", err)
	}
	if got := readEventTypes(t, m.config.KnowledgeDir); len(got) != 1 || got[0] != session.EventWorktreeQuarantined {
		t.Fatalf("allocation outcome=%v", got)
	}
}

func TestHostLostObservationIsUncertain(t *testing.T) {
	for _, kind := range []string{"send", "answer"} {
		t.Run(kind, func(t *testing.T) {
			m, _ := baseSessionModel(t)
			m.hostKey = "key"
			m.eventScript = repoScriptPath(t, "session-event-append.sh")
			var cmds []tea.Cmd
			if kind == "send" {
				m.pendingSendVerify = map[string]pendingSendState{"request": {slug: "gone", requestID: "request"}}
				m, cmds = m.advanceSendVerifications()
			} else {
				m.pendingAnswerVerify = map[string]pendingAnswerState{"request": {slug: "gone", requestID: "request", option: 1}}
				m, cmds = m.advanceAnswerVerifications()
			}
			if len(cmds) != 1 {
				t.Fatalf("terminal commands=%d", len(cmds))
			}
			cmds[0]()
			b, err := os.ReadFile(m.hostDeliveryPath("request"))
			if err != nil {
				t.Fatal(err)
			}
			var d hostDelivery
			if err = json.Unmarshal(b, &d); err != nil {
				t.Fatal(err)
			}
			if d.Event.Reason != "delivery-uncertain" {
				t.Fatalf("lost observation became definite refusal: %+v", d)
			}
		})
	}
}

func TestHostOutcomeRecordAloneCarriesCloseContinuation(t *testing.T) {
	_, source, identity := closedSessionWorktree(t, "outcome-only-crash")
	m, _ := baseSessionModel(t)
	m.hostKey = "key"
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	ls := liveSession{typ: "worker", initiator: "agent", requestID: "spawn", sourceDir: source, worktree: &identity}
	ev := worktreeOutcomeEvent(m.instanceName, "demo", ls, worktree.PublishOutcome{Kind: worktree.OutcomePublished, Identity: identity})
	if _, err := m.hostWorktreeOutcome(ev, identity.Epoch, m.hostCloseDelivery("demo", ls, "close")); err != nil {
		t.Fatal(err)
	}
	// Crash before finalizeLocalSessionClosed even creates the close record.
	if _, err := os.Stat(m.hostDeliveryPath("close")); !os.IsNotExist(err) {
		t.Fatalf("fixture already has close record: %v", err)
	}
	if err := m.recoverHostDeliveries(); err != nil {
		t.Fatal(err)
	}
	if got := readEventTypes(t, m.config.KnowledgeDir); len(got) != 2 || got[0] != session.EventWorktreePublished || got[1] != session.EventClosed {
		t.Fatalf("continuation lost: %v", got)
	}
	if _, err := os.Stat(identity.CanonicalPath); !os.IsNotExist(err) {
		t.Fatalf("continuation cleanup absent: %v", err)
	}
}

func TestHostWriteErrorsRemainUncertain(t *testing.T) {
	for _, kind := range []string{"send", "answer"} {
		t.Run(kind, func(t *testing.T) {
			m := runtimeModel(t)
			m.hostKey = "key"
			m.localSessions["demo"] = liveSession{harness: "claude-code", typ: "worker", initiator: "agent"}
			rows := ccComposerRows
			if kind == "answer" {
				rows = ccOptionSelectRows
			}
			p, _ := runtimePanel(t, "demo", rows)
			if err := p.Ptmx().Close(); err != nil {
				t.Fatal(err)
			}
			m.sessionPanels["demo"] = p
			var cmd tea.Cmd
			if kind == "send" {
				m, cmd = m.handleSendRequestScan(sendRequestScanMsg{matched: []session.SendRequest{{Slug: "demo", RequestID: "write", Body: "continue"}}})
			} else {
				m, cmd = m.handleAnswerRequestScan(answerRequestScanMsg{matched: []session.AnswerRequest{{Slug: "demo", RequestID: "write", Option: 2, Expect: "Choose the next step"}}})
			}
			runJournalCmds(t, cmd)
			b, err := os.ReadFile(m.hostDeliveryPath("write"))
			if err != nil {
				t.Fatal(err)
			}
			var d hostDelivery
			if err = json.Unmarshal(b, &d); err != nil {
				t.Fatal(err)
			}
			if d.Event.Reason != "delivery-uncertain" {
				t.Fatalf("write error certainty=%+v", d.Event)
			}
		})
	}
}

func TestHostCloseKeepsTranscriptSpend(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.hostKey = "key"
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	m.spendScript = writeSpendStub(t, `{"input_tokens":100,"output_tokens":50,"total_tokens":150,"harness":"claude-code","basis":"transcript"}`)
	m.localSessions = map[string]liveSession{"demo": {typ: "worker", initiator: "agent", requestID: "spawn", harness: "claude-code", sessionID: "native"}}
	_, cmds := m.finalizeLocalSessionClosed("demo", "close")
	if len(cmds) != 1 {
		t.Fatalf("close cmds=%d", len(cmds))
	}
	runJournalCmds(t, cmds[0])
	b, err := os.ReadFile(m.hostDeliveryPath("close"))
	if err != nil {
		t.Fatal(err)
	}
	var d hostDelivery
	if err = json.Unmarshal(b, &d); err != nil {
		t.Fatal(err)
	}
	var spend map[string]any
	if err = json.Unmarshal(d.Event.Spend, &spend); err != nil {
		t.Fatal(err)
	}
	if spend["basis"] != "transcript" || spend["total_tokens"] != float64(150) {
		t.Fatalf("cost attribution lost: %s", d.Event.Spend)
	}
}

// The 2026-09-24 crash-loop: one stale checkout holding content no ref
// describes made the startup sweep fail, the host exit, and the supervisor
// restart it into the same refusal until its restart budget ran out, so no
// session could start for that source. The checkout is now logged as retained
// and the host comes up, with the checkout's bytes untouched.
func TestHostStartupSweepRetainsUnprovenCheckoutAndComesUp(t *testing.T) {
	root, _, identity := closedSessionWorktree(t, "20260721T205159Z-46d1320f")
	lateWork := filepath.Join(identity.CanonicalPath, "late-work.txt")
	if err := os.WriteFile(lateWork, []byte("not in any ref\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	m := model{config: config.Config{KnowledgeDir: root, ProjectDir: root}, sessionsDir: filepath.Join(root, "_sessions"), hostKey: "key"}
	h := &sessionHostModel{runtime: m, options: hostOptions{Key: "key"}}

	for pass := 1; pass <= 2; pass++ {
		result := h.runtime.sweepSessionWorktreesCmd()().(sessionWorktreeSweptMsg)
		if len(result.failures) != 0 || len(result.retained) != 1 {
			t.Fatalf("pass %d: failures %v, retained %v; want the stale checkout retained", pass, result.failures, result.retained)
		}
		h.Update(hostSweepDoneMsg{result})
		if h.err != nil {
			t.Fatalf("pass %d: host failed on a retained checkout: %v", pass, h.err)
		}
		if !h.swept {
			t.Fatalf("pass %d: startup sweep never completed", pass)
		}
	}
	if len(h.retainedReported) != 1 {
		t.Fatalf("retained reports = %v, want the checkout logged once", h.retainedReported)
	}
	if b, err := os.ReadFile(lateWork); err != nil || string(b) != "not in any ref\n" {
		t.Fatalf("retained checkout content changed: %q %v", b, err)
	}

	// A removal that started and failed still stops the host.
	h = &sessionHostModel{runtime: m, options: hostOptions{Key: "key"}}
	h.Update(hostSweepDoneMsg{sessionWorktreeSweptMsg{failures: []error{errors.New("remove session worktree: permission denied")}}})
	if h.err == nil {
		t.Fatal("a failed removal no longer stops the host")
	}
}

// The host's own close path meets the same refusal when a session's checkout
// drifted after its result was preserved. It records a settled receipt naming
// why the checkout stayed, instead of failing and retrying the refusal on every
// restart.
func TestHostCloseRetainsUnprovenCheckoutWithSettledReceipt(t *testing.T) {
	m, _ := baseSessionModel(t)
	m.hostKey = "key"
	h := &sessionHostModel{runtime: m, options: hostOptions{Key: "key"}}
	refusal := fmt.Errorf("%w: content at /tmp/demo is not reachable from any preserved ref", worktree.ErrContentUnproven)
	h.Update(sessionWorktreeCleanedMsg{slug: "demo--w1", epoch: "e1", err: refusal})
	if h.err != nil {
		t.Fatalf("host failed on a retained close: %v", h.err)
	}
	b, err := os.ReadFile(filepath.Join(m.hostDir(), "cleanup", "demo--w1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var receipt struct {
		Epoch    string `json:"epoch"`
		Cleaned  bool   `json:"cleaned"`
		Retained string `json:"retained"`
	}
	if err = json.Unmarshal(b, &receipt); err != nil {
		t.Fatal(err)
	}
	if receipt.Epoch != "e1" || receipt.Cleaned || receipt.Retained != refusal.Error() {
		t.Fatalf("receipt = %+v, want a retained receipt naming the refusal", receipt)
	}

	h.Update(sessionWorktreeCleanedMsg{slug: "demo--w2", epoch: "e2", err: errors.New("remove session worktree: permission denied")})
	if h.err == nil {
		t.Fatal("a failed removal on close no longer stops the host")
	}
}

const storeHostKey = "storekey0123456789abcdef"

// Package tests never query the production tmux server, even read-only: a
// store host's orphan check otherwise asks every runtime's server.
func init() {
	probe := tmuxAliveOnServer
	tmuxAliveOnServer = func(server, name string) bool {
		return server != "lore-tui" && probe(server, name)
	}
}

// storeHostFixture is a store under a staged LORE_DATA_DIR, two checkouts that
// resolve to it, and one that resolves to another store. LORE_KNOWLEDGE_DIR is
// unset, so resolution runs as it does for an unpinned store.
type storeHostFixture struct {
	store, one, two, foreign string
}

func newStoreHostFixture(t *testing.T) storeHostFixture {
	t.Helper()
	stageMainRouteScripts(t)
	t.Setenv("LORE_KNOWLEDGE_DIR", "")
	os.Unsetenv("LORE_KNOWLEDGE_DIR")
	store := filepath.Join(os.Getenv("LORE_DATA_DIR"), "repos", "example.com", "acme", "proj")
	if err := os.MkdirAll(store, 0o755); err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	return storeHostFixture{
		store:   store,
		one:     storeHostCheckout(t, filepath.Join(root, "one", "proj"), "https://example.com/acme/proj.git"),
		two:     storeHostCheckout(t, filepath.Join(root, "two", "proj-clone"), "git@example.com:acme/proj.git"),
		foreign: storeHostCheckout(t, filepath.Join(root, "other", "thing"), "https://example.com/acme/thing.git"),
	}
}

func storeHostCheckout(t *testing.T, dir, remote string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"init", "-q", "-b", "main"}, {"remote", "add", "origin", remote}} {
		if out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	return dir
}

// storeHostModel is the runtime model sessionHostMain builds for a store: no
// checkout of its own, cwd-independent configuration from the store path.
func storeHostModel(t *testing.T, store string) model {
	t.Helper()
	m := newModel(config.Config{KnowledgeDir: store, WorkDir: filepath.Join(store, "_work")}, config.Prefs{}, stateWork)
	m.width, m.height = 140, 48
	m.hostKey = storeHostKey
	m.instanceName = "brisk-heron-0a1b2c"
	m.sessionsDir = filepath.Join(store, "_sessions")
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	return m
}

func writeStoreRequest(t *testing.T, sessionsDir string, req session.Request) {
	t.Helper()
	req.Framework, req.Model = strPtr("claude-code"), strPtr("fixture-model")
	if req.RequestedAt == "" {
		req.RequestedAt = time.Now().UTC().Format("2006-01-02T15:04:05Z")
	}
	if err := session.WritePending(sessionsDir, req); err != nil {
		t.Fatal(err)
	}
}

func readJSONFields(t *testing.T, path string) map[string]json.RawMessage {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(b, &fields); err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	return fields
}

func jsonString(t *testing.T, raw json.RawMessage) string {
	t.Helper()
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		t.Fatalf("not a JSON string: %s", raw)
	}
	return s
}

func TestStoreHostArgumentContract(t *testing.T) {
	t.Setenv("LORE_KNOWLEDGE_DIR", "")
	os.Unsetenv("LORE_KNOWLEDGE_DIR")
	kdir := t.TempDir()
	runtime := os.Getenv(config.SessionRuntimeEnv)
	storeHostKey := session.StoreHostKey(config.NormalizeProjectDir(kdir), runtime)
	ready := filepath.Join(t.TempDir(), "hosts", storeHostKey, "ready.json")
	store := func(extra ...string) []string {
		return append([]string{"--scope", "store", "--host-key", storeHostKey, "--kdir", kdir, "--ready-file", ready, "--idle-timeout", "1", "--runtime", runtime}, extra...)
	}
	retired := []string{"--host-key", storeHostKey, "--kdir", kdir, "--source-dir", kdir, "--ready-file", ready, "--runtime", runtime}
	for name, args := range map[string][]string{
		"retired source-dir form":       retired,
		"source-dir beside store scope": store("--source-dir", kdir),
		"no scope":                      {"--host-key", storeHostKey, "--kdir", kdir, "--ready-file", ready, "--runtime", runtime},
		"unknown scope":                 {"--scope", "checkout", "--host-key", storeHostKey, "--kdir", kdir, "--ready-file", ready, "--runtime", runtime},
		"missing host key":              {"--scope", "store", "--kdir", kdir, "--ready-file", ready, "--runtime", runtime},
		"host key with a separator":     {"--scope", "store", "--host-key", "a/b", "--kdir", kdir, "--ready-file", ready, "--runtime", runtime},
		"missing store":                 {"--scope", "store", "--host-key", storeHostKey, "--ready-file", ready, "--runtime", runtime},
		"relative ready file":           {"--scope", "store", "--host-key", storeHostKey, "--kdir", kdir, "--ready-file", "ready.json", "--runtime", runtime},
		"negative idle timeout":         store("--idle-timeout", "-1"),
		"stray argument":                store("extra"),
		"unknown flag":                  store("--bogus"),
		"runtime mismatch":              {"--scope", "store", "--host-key", storeHostKey, "--kdir", kdir, "--ready-file", ready, "--runtime", runtime + "-other"},
	} {
		if code := sessionHostMain(args); code != 2 {
			t.Errorf("%s: exit %d, want 2", name, code)
		}
	}
	if _, err := os.Stat(filepath.Dir(ready)); !os.IsNotExist(err) {
		t.Fatalf("a refused host created its state directory: %v", err)
	}

	// A LORE_KNOWLEDGE_DIR naming another store would reach every hosted
	// session, so the host refuses to start under it.
	t.Setenv("LORE_KNOWLEDGE_DIR", t.TempDir())
	if code := sessionHostMain(store()); code != 1 {
		t.Fatalf("foreign LORE_KNOWLEDGE_DIR: exit %d, want 1", code)
	}
	if _, err := os.Stat(filepath.Dir(ready)); !os.IsNotExist(err) {
		t.Fatalf("a host under a foreign LORE_KNOWLEDGE_DIR created its state directory: %v", err)
	}
	os.Unsetenv("LORE_KNOWLEDGE_DIR")

	// The refusal names the retirement and the replacement, for whoever reads
	// the supervisor's host log.
	cmd := exec.Command(os.Args[0], append([]string{"--session-host"}, retired...)...)
	cmd.Env = append(os.Environ(), mainRuntimeProbeEnv+"="+runtime)
	out, err := cmd.CombinedOutput()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 2 {
		t.Fatalf("binary accepted the retired form: %v\n%s", err, out)
	}
	if !strings.Contains(string(out), "retired") || !strings.Contains(string(out), "--scope store") {
		t.Fatalf("refusal does not name the retirement:\n%s", out)
	}

	// A second host for the store exits 3 before touching anything.
	if err := os.MkdirAll(filepath.Dir(ready), 0o700); err != nil {
		t.Fatal(err)
	}
	lock, err := hostLock(filepath.Join(filepath.Dir(ready), "runtime.lock"), true)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if code := sessionHostMain(store()); code != 3 {
		t.Fatalf("held runtime.lock: exit %d, want 3", code)
	}
	if _, err := os.Stat(ready); !os.IsNotExist(err) {
		t.Fatalf("a host that lost the lock wrote ready.json: %v", err)
	}
}

// The real binary, started the way the supervisor starts it, publishes the
// store-scope ready file and registry row, holds runtime.lock while it serves,
// and exits 0 once it has withdrawn idle.
func TestStoreHostPublishesStoreReadyAndRegistryRowThenWithdrawsIdle(t *testing.T) {
	f := newStoreHostFixture(t)
	runtime := os.Getenv(config.SessionRuntimeEnv)
	storeHostKey := session.StoreHostKey(config.NormalizeProjectDir(f.store), runtime)
	ready := filepath.Join(config.SessionHostsDir(filepath.Join(f.store, "_sessions")), storeHostKey, "ready.json")
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "--session-host", "--scope", "store", "--host-key", storeHostKey,
		"--kdir", f.store, "--ready-file", ready, "--idle-timeout", "3", "--runtime", runtime)
	cmd.Env = append(os.Environ(), mainRuntimeProbeEnv+"="+runtime)
	var output bytes.Buffer
	cmd.Stdout, cmd.Stderr = &output, &output
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()

	var fields map[string]json.RawMessage
	for fields == nil {
		select {
		case err := <-exited:
			t.Fatalf("host exited before publishing ready: %v\n%s", err, output.String())
		case <-time.After(20 * time.Millisecond):
		}
		if b, err := os.ReadFile(ready); err == nil && json.Unmarshal(b, &fields) != nil {
			fields = nil
		}
	}
	want := []string{"build_sha", "build_time", "host_key", "instance_name", "knowledge_dir", "pid", "ready", "runtime_capabilities", "schema_version", "scope"}
	var got []string
	for k := range fields {
		got = append(got, k)
	}
	slices.Sort(got)
	if !slices.Equal(got, want) {
		t.Fatalf("ready.json fields = %v, want %v", got, want)
	}
	if string(fields["schema_version"]) != "2" || jsonString(t, fields["scope"]) != "store" || jsonString(t, fields["host_key"]) != storeHostKey ||
		string(fields["ready"]) != "true" || string(fields["pid"]) != strconv.Itoa(cmd.Process.Pid) ||
		jsonString(t, fields["knowledge_dir"]) != config.NormalizeProjectDir(f.store) {
		t.Fatalf("ready.json = %v", fields)
	}
	var capabilities []string
	if err := json.Unmarshal(fields["runtime_capabilities"], &capabilities); err != nil || len(capabilities) == 0 {
		t.Fatalf("runtime_capabilities = %s", fields["runtime_capabilities"])
	}
	name := jsonString(t, fields["instance_name"])
	row := readJSONFields(t, filepath.Join(session.InstancesDir(filepath.Join(f.store, "_sessions")), name+".json"))
	if jsonString(t, row["role"]) != "session-host" || jsonString(t, row["host_key"]) != storeHostKey ||
		jsonString(t, row["scope"]) != "store" || jsonString(t, row["runtime"]) != runtime || jsonString(t, row["repo"]) != "example.com/acme/proj" {
		t.Fatalf("registry row = %v", row)
	}
	if _, ok := row["project_dir"]; ok {
		t.Fatalf("store host registry row names a checkout: %s", row["project_dir"])
	}
	if other, err := hostLock(filepath.Join(filepath.Dir(ready), "runtime.lock"), true); err == nil {
		other.Close()
		t.Fatal("a serving host does not hold runtime.lock")
	}

	select {
	case err := <-exited:
		if err != nil {
			t.Fatalf("idle withdrawal exit: %v\n%s", err, output.String())
		}
	case <-ctx.Done():
		t.Fatalf("host never withdrew idle\n%s", output.String())
	}
	if _, err := os.Stat(ready); !os.IsNotExist(err) {
		t.Fatalf("withdrawn host left ready.json: %v", err)
	}
}

func TestStoreHostSeedsEachSessionFromItsRowsCheckout(t *testing.T) {
	f := newStoreHostFixture(t)
	m := storeHostModel(t, f.store)
	writeStoreRequest(t, m.sessionsDir, session.Request{RequestID: "r-alpha", HostKey: storeHostKey, Type: "spec", Slug: strPtr("alpha"), Initiator: "agent",
		RequiredProjectDir: strPtr(f.one), PlacementStance: strPtr(session.StanceRequiredDir)})
	writeStoreRequest(t, m.sessionsDir, session.Request{RequestID: "r-beta", HostKey: storeHostKey, Type: "spec", Slug: strPtr("beta"), Initiator: "agent",
		PreferProjectDir: strPtr(f.two), PlacementStance: strPtr(session.StancePreferredDir)})
	for tick := 0; tick < 2; tick++ {
		msg := m.queueTickCmd()().(queueTickResultMsg)
		if msg.err != nil || msg.result.Claimed == nil {
			t.Fatalf("tick %d: claimed %+v, err %v, abandoned %+v", tick, msg.result.Claimed, msg.err, msg.result.Abandoned)
		}
		m, _ = m.handleQueueTickResult(msg)
	}
	want := map[string]string{"alpha": config.NormalizeProjectDir(f.one), "beta": config.NormalizeProjectDir(f.two)}
	runtime := os.Getenv(config.SessionRuntimeEnv)
	for slug, checkout := range want {
		pending := m.pendingSpawns[slug]
		if pending.sourceDir != checkout {
			t.Fatalf("%s seeded from %q, want %q", slug, pending.sourceDir, checkout)
		}
		d := work.SessionDescriptor{Slug: slug, Type: work.SessionSpec, Initiator: "agent"}
		if err := m.hostSpawnCheckpoint(pending.requestID, pending.checkpointID)(d, "fake", "sid-"+slug, "lore-pane-"+slug, 0); err != nil {
			t.Fatal(err)
		}
		row := readJSONFields(t, filepath.Join(session.InstancesDir(m.sessionsDir), m.hostSpawnName(pending.checkpointID)+".json"))
		if jsonString(t, row["role"]) != "session-host-spawn" || jsonString(t, row["scope"]) != "store" || jsonString(t, row["runtime"]) != runtime {
			t.Fatalf("%s spawn checkpoint row = %v", slug, row)
		}
		if _, ok := row["project_dir"]; ok {
			t.Fatalf("%s spawn checkpoint names the host's checkout: %s", slug, row["project_dir"])
		}
		var sessions []session.Session
		if err := json.Unmarshal(row["sessions"], &sessions); err != nil || len(sessions) != 1 || sessions[0].SourceDir != checkout {
			t.Fatalf("%s spawn checkpoint sessions = %s", slug, row["sessions"])
		}
	}
	for slug := range want {
		m, _ = m.handleSessionProcessStarted(work.SessionProcessStartedMsg{Slug: slug, Harness: "fake", SessionID: "sid-" + slug})
	}
	row := m.instanceRow()
	if row.Scope != session.ScopeStore || row.ProjectDir != "" || row.Role != "session-host" || len(row.Sessions) != 2 {
		t.Fatalf("host row = %+v", row)
	}
	for _, s := range row.Sessions {
		if s.SourceDir != want[s.Slug] {
			t.Fatalf("session %s row names checkout %q, want %q", s.Slug, s.SourceDir, want[s.Slug])
		}
		if got := m.spendDir(m.localSessions[s.Slug]); got != want[s.Slug] {
			t.Fatalf("session %s spend probe reads %q, want its checkout", s.Slug, got)
		}
	}
}

func TestStoreHostRefusesForeignOrMissingCheckoutsWithKnowledgeDirUnset(t *testing.T) {
	f := newStoreHostFixture(t)
	m := storeHostModel(t, f.store)
	if m.storeScope().Pinned {
		t.Fatal("store reads as pinned with LORE_KNOWLEDGE_DIR unset")
	}
	writeStoreRequest(t, m.sessionsDir, session.Request{RequestID: "foreign", HostKey: storeHostKey, Type: "spec", Slug: strPtr("foreign"), Initiator: "agent",
		RequiredProjectDir: strPtr(f.foreign), PlacementStance: strPtr(session.StanceRequiredDir)})
	writeStoreRequest(t, m.sessionsDir, session.Request{RequestID: "missing", HostKey: storeHostKey, Type: "spec", Slug: strPtr("missing"), Initiator: "agent",
		RequiredProjectDir: strPtr(filepath.Join(t.TempDir(), "deleted-clone")), PlacementStance: strPtr(session.StanceRequiredDir)})
	writeStoreRequest(t, m.sessionsDir, session.Request{RequestID: "none", HostKey: storeHostKey, Type: "chat", Slug: strPtr("chat-none"), Initiator: "agent",
		PlacementStance: strPtr(session.StanceAny)})
	writeStoreRequest(t, m.sessionsDir, session.Request{RequestID: "unkeyed", Type: "spec", Slug: strPtr("unkeyed"), Initiator: "agent",
		RequiredProjectDir: strPtr(f.one), PlacementStance: strPtr(session.StanceRequiredDir)})

	msg := m.queueTickCmd()().(queueTickResultMsg)
	if msg.err != nil || msg.result.Claimed != nil {
		t.Fatalf("claimed %+v, err %v", msg.result.Claimed, msg.err)
	}
	reasons := map[string]string{}
	for _, ev := range msg.result.Abandoned {
		reasons[ev.RequestID] = ev.Reason
	}
	for id, reason := range map[string]string{"foreign": "belongs to knowledge store", "missing": "does not exist", "none": "names no checkout"} {
		if !strings.Contains(reasons[id], reason) {
			t.Fatalf("%s refusal = %q, want it to name %q (all: %v)", id, reasons[id], reason, reasons)
		}
		if _, err := os.Stat(filepath.Join(m.sessionsDir, "requests", "abandoned", id+".json")); err != nil {
			t.Fatalf("%s not archived: %v", id, err)
		}
	}
	m, cmd := m.handleQueueTickResult(msg)
	runJournalCmds(t, cmd)
	if got := readEventTypes(t, f.store); len(got) != 3 || got[0] != session.EventAbandoned || got[2] != session.EventAbandoned {
		t.Fatalf("journal = %v, want three request_abandoned rows", got)
	}
	if pending := session.ScanPending(m.sessionsDir); len(pending) != 1 || pending[0].RequestID != "unkeyed" {
		t.Fatalf("store host touched an unkeyed row: pending %+v", pending)
	}

	// A store pinned by LORE_KNOWLEDGE_DIR, here through a symlinked path, skips
	// resolution, which would only echo the pin; the other clauses still hold.
	link := filepath.Join(t.TempDir(), "store-link")
	if err := os.Symlink(f.store, link); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LORE_KNOWLEDGE_DIR", link)
	if !m.storeScope().Pinned {
		t.Fatal("LORE_KNOWLEDGE_DIR naming the store does not pin it")
	}
	inStore := storeHostCheckout(t, filepath.Join(f.store, "_sessions", "worktrees", "stray"), "https://example.com/acme/proj.git")
	writeStoreRequest(t, m.sessionsDir, session.Request{RequestID: "pinned-a-in-store", HostKey: storeHostKey, Type: "spec", Slug: strPtr("stray"), Initiator: "agent",
		RequiredProjectDir: strPtr(inStore), PlacementStance: strPtr(session.StanceRequiredDir)})
	writeStoreRequest(t, m.sessionsDir, session.Request{RequestID: "pinned-b-foreign", HostKey: storeHostKey, Type: "spec", Slug: strPtr("pinned"), Initiator: "agent",
		RequiredProjectDir: strPtr(f.foreign), PlacementStance: strPtr(session.StanceRequiredDir)})
	msg = m.queueTickCmd()().(queueTickResultMsg)
	if msg.err != nil || msg.result.Claimed == nil || msg.result.Claimed.RequestID != "pinned-b-foreign" {
		t.Fatalf("pinned store: claimed %+v, err %v", msg.result.Claimed, msg.err)
	}
	if len(msg.result.Abandoned) != 1 || msg.result.Abandoned[0].RequestID != "pinned-a-in-store" || !strings.Contains(msg.result.Abandoned[0].Reason, "inside knowledge store") {
		t.Fatalf("pinned store abandoned %+v", msg.result.Abandoned)
	}
}

func TestStoreHostInstanceNameAvoidsAnotherStoresTmuxSession(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not installed; skipping the shared-server name check")
	}
	sessions := filepath.Join(t.TempDir(), "_sessions")
	otherSessions := filepath.Join(t.TempDir(), "_sessions")
	sequence := func(names ...string) func() (string, error) {
		return func() (string, error) {
			if len(names) == 0 {
				return "", errors.New("draws exhausted")
			}
			name := names[0]
			names = names[1:]
			return name, nil
		}
	}
	// Two stores' hosts that draw the same word pair still get distinct
	// instance names, so their sessions for one slug get distinct tmux names.
	mine, err := storeHostInstanceName(sessions, storeHostKey, sequence("amber-otter"), tmuxSessionNames)
	if err != nil {
		t.Fatal(err)
	}
	theirs, err := storeHostInstanceName(otherSessions, "otherstorekey00000000000", sequence("amber-otter"), tmuxSessionNames)
	if err != nil {
		t.Fatal(err)
	}
	if work.TmuxSessionName(mine, "demo--w1") == work.TmuxSessionName(theirs, "demo--w1") {
		t.Fatalf("two stores' hosts share tmux name %q", work.TmuxSessionName(mine, "demo--w1"))
	}

	// A session already living on the shared server under a candidate's prefix
	// sends the host to another draw.
	occupied := work.TmuxSessionName(mine, "demo--w1")
	if out, err := exec.Command("tmux", "-L", config.TmuxServer(), "-f", "/dev/null", "new-session", "-d", "-s", occupied, "--", "sleep", "300").CombinedOutput(); err != nil {
		t.Fatalf("create the other session: %v (%s)", err, out)
	}
	t.Cleanup(func() { _ = exec.Command("tmux", "-L", config.TmuxServer(), "kill-session", "-t", "="+occupied).Run() })
	next, err := storeHostInstanceName(sessions, storeHostKey, sequence("amber-otter", "brisk-heron"), tmuxSessionNames)
	if err != nil || next == mine || !strings.HasPrefix(next, "brisk-heron-") {
		t.Fatalf("name beside a live tmux session = %q, %v", next, err)
	}

	// A dead registry row still holding a name is a recovery manifest that a
	// fresh row would overwrite, so that name is skipped too.
	if err := os.MkdirAll(session.InstancesDir(sessions), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(session.InstancesDir(sessions), next+".json"), []byte(`{"name":"dead"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	after, err := storeHostInstanceName(sessions, storeHostKey, sequence("brisk-heron", "calm-cedar"), tmuxSessionNames)
	if err != nil || !strings.HasPrefix(after, "calm-cedar-") {
		t.Fatalf("name beside a dead row = %q, %v", after, err)
	}
	if _, err := storeHostInstanceName(sessions, storeHostKey, sequence("amber-otter"), tmuxSessionNames); err == nil {
		t.Fatal("an exhausted draw produced a name")
	}
}

// driveHost runs cmd and feeds every message it yields back through h, the
// way the event loop would, following batches and sequences in order. It
// reports whether the host asked to quit. A command that blocks (a terminal
// poll, a tick) must not reach it.
func driveHost(t *testing.T, h *sessionHostModel, cmd tea.Cmd) bool {
	t.Helper()
	steps := 0
	var drive func(tea.Cmd) bool
	drive = func(cmd tea.Cmd) bool {
		if cmd == nil {
			return false
		}
		if steps++; steps > 500 {
			t.Fatal("host did not settle")
		}
		msg := cmd()
		if msg == nil {
			return false
		}
		if v := reflect.ValueOf(msg); v.Kind() == reflect.Slice && v.Type().Elem() == reflect.TypeOf(tea.Cmd(nil)) {
			quit := false
			for i := 0; i < v.Len(); i++ {
				quit = drive(v.Index(i).Interface().(tea.Cmd)) || quit
			}
			return quit
		}
		if _, ok := msg.(tea.QuitMsg); ok {
			return true
		}
		_, next := h.Update(msg)
		return drive(next)
	}
	return drive(cmd)
}

// servingStoreHost is a store host past startup recovery, as a test drives it.
func servingStoreHost(m model) *sessionHostModel {
	return &sessionHostModel{runtime: m, options: hostOptions{Key: m.hostKey, ReadyFile: filepath.Join(m.hostDir(), "ready.json"), Idle: time.Hour},
		recovered: true, swept: true, ready: true, recoveredKeys: map[string]bool{m.hostKey: true}}
}

// plantHostRow writes a dead host's registry row listing one session.
func plantHostRow(t *testing.T, sessionsDir, name, key, slug string) {
	t.Helper()
	row := session.Instance{Name: name, PID: deadPID(t), HostKey: key, Role: "session-host", Repo: "example.com/acme/proj", Started: "2026-10-01T00:00:00Z",
		Sessions: []session.Session{{Slug: slug, Type: "worker", Initiator: "agent", Started: "2026-10-01T00:00:00Z", RequestID: "r-" + slug}}}
	if err := session.WriteInstance(sessionsDir, row); err != nil {
		t.Fatal(err)
	}
}

func writeMigrationRecord(t *testing.T, sessionsDir, from, to string) {
	t.Helper()
	path := filepath.Join(sessionsDir, "hosts", from, "migrated.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(map[string]any{"schema_version": 1, "from": from, "to": to, "at": "2026-10-18T00:00:00Z"})
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatal(err)
	}
}

func instanceExists(sessionsDir, name string) bool {
	_, err := os.Stat(filepath.Join(session.InstancesDir(sessionsDir), name+".json"))
	return err == nil
}

// In the default runtime a store host adopts the dead rows of every key that
// migrated into its own: those migrated before it started, during startup
// recovery, and one that migrates while it serves, on its next pass, without a
// restart. A key that migrated elsewhere is left alone, and so is an
// allocation record of a launch this process is still running.
func TestStoreHostRecoveryAdoptsMigratedKeysAtStartupAndOnALaterPass(t *testing.T) {
	t.Setenv(config.SessionRuntimeEnv, "")
	m, sessionsDir := baseSessionModel(t)
	m.hostKey = storeHostKey
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	plantHostRow(t, sessionsDir, "old-host-one", "oldkey000000000000000001", "first--w1")
	plantHostRow(t, sessionsDir, "old-host-two", "oldkey000000000000000002", "second--w1")
	plantHostRow(t, sessionsDir, "elsewhere", "oldkey000000000000000003", "third--w1")
	writeMigrationRecord(t, sessionsDir, "oldkey000000000000000001", storeHostKey)
	writeMigrationRecord(t, sessionsDir, "oldkey000000000000000003", "anotherstorekey000000000")

	h := servingStoreHost(m)
	h.recovered, h.swept, h.recoveredKeys = false, false, nil
	if quit := driveHost(t, h, h.Init()); quit || h.err != nil {
		t.Fatalf("startup recovery stopped the host: %v", h.err)
	}
	if _, ok := h.runtime.localSessions["first--w1"]; !ok || instanceExists(sessionsDir, "old-host-one") {
		t.Fatalf("migrated key not adopted at startup: %+v", h.runtime.localSessions)
	}
	if _, ok := h.runtime.localSessions["second--w1"]; ok || !instanceExists(sessionsDir, "old-host-two") {
		t.Fatal("a key that had not migrated was adopted")
	}
	if !h.recoveredKeys["oldkey000000000000000001"] || h.recoveredKeys["oldkey000000000000000002"] {
		t.Fatalf("recovered keys = %v", h.recoveredKeys)
	}

	// The second key migrates while the host serves. A launch the host is
	// still running has an allocation record and a row claimed by this host.
	writeMigrationRecord(t, sessionsDir, "oldkey000000000000000002", storeHostKey)
	writeStoreRequest(t, sessionsDir, session.Request{RequestID: "r-inflight", HostKey: storeHostKey, Type: "worker", Slug: strPtr("inflight--w1"), Initiator: "agent"})
	if won, err := session.ClaimRequest(sessionsDir, "r-inflight"); !won || err != nil {
		t.Fatalf("claim fixture: %v %v", won, err)
	}
	if _, err := session.WriteClaimMetadata(sessionsDir, "r-inflight", h.runtime.instanceName); err != nil {
		t.Fatal(err)
	}
	inflight := h.runtime.hostAllocationPath("r-inflight")
	if err := hostAtomicJSON(inflight, hostAllocation{RequestID: "r-inflight", Slug: "inflight--w1", Type: "worker", Intent: worktree.AllocationIntent{Path: filepath.Join(sessionsDir, "worktrees", "pending")}}); err != nil {
		t.Fatal(err)
	}
	// The migration copied the old host's ledger, including an uncertain send
	// it never settled. This host's own unsettled record is an operation still
	// running and is not the pass's to settle.
	oldKey := "oldkey000000000000000002"
	copied := session.Event{EventID: "host-delivery-" + oldKey + "-send-old", Event: session.EventSendRefused, Slug: "second--w1", RequestID: "send-old", Reason: "delivery-uncertain", ActorInstance: session.StrPtr("old-host-two")}
	if err := hostAtomicJSON(h.runtime.hostDeliveryPath("send-old"), hostDelivery{Kind: "send", Event: copied}); err != nil {
		t.Fatal(err)
	}
	own := session.Event{Event: session.EventSendRefused, Slug: "first--w1", RequestID: "send-own", Reason: "delivery-uncertain", ActorInstance: session.StrPtr(h.runtime.instanceName)}
	if err := h.runtime.hostDeliveryAttempt("send", own); err != nil {
		t.Fatal(err)
	}
	h.reconciling = true
	if quit := driveHost(t, h, h.reconcileCmd()); quit || h.err != nil || h.reconciling {
		t.Fatalf("reconciliation pass: quit=%v err=%v reconciling=%v", quit, h.err, h.reconciling)
	}
	if _, ok := h.runtime.localSessions["second--w1"]; !ok || instanceExists(sessionsDir, "old-host-two") {
		t.Fatalf("key migrated while serving not adopted: %+v", h.runtime.localSessions)
	}
	if !h.recoveredKeys["oldkey000000000000000002"] {
		t.Fatalf("recovered keys = %v", h.recoveredKeys)
	}
	if !instanceExists(sessionsDir, "elsewhere") {
		t.Fatal("a key migrated to another store was adopted")
	}
	if _, err := os.Stat(inflight); err != nil {
		t.Fatalf("the pass settled a launch still in flight: %v", err)
	}
	ledger := func(id string) hostDelivery {
		b, err := os.ReadFile(h.runtime.hostDeliveryPath(id))
		if err != nil {
			t.Fatal(err)
		}
		var d hostDelivery
		if err := json.Unmarshal(b, &d); err != nil {
			t.Fatal(err)
		}
		return d
	}
	if d := ledger("send-old"); !d.Terminal || !d.Committed {
		t.Fatalf("copied record not replayed: %+v", d)
	}
	if d := ledger("send-own"); d.Terminal || d.Committed {
		t.Fatalf("the pass settled this host's own running delivery: %+v", d)
	}
	replayed := 0
	for _, ev := range readEventRows(t, m.config.KnowledgeDir) {
		if ev.EventID == copied.EventID {
			replayed++
		}
	}
	if replayed != 1 {
		t.Fatalf("copied outcome journaled %d times", replayed)
	}
	row := h.runtime.instanceRow()
	if len(row.Sessions) != 2 {
		t.Fatalf("host row sessions = %+v", row.Sessions)
	}
}

// A named runtime's recovery key set is its own store key alone: legacy keys
// carry no runtime, so their rows may be production's.
func TestStoreHostRecoveryNamedRuntimeAdoptsOnlyItsOwnKey(t *testing.T) {
	m, sessionsDir := baseSessionModel(t)
	m.hostKey = storeHostKey
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	plantHostRow(t, sessionsDir, "own-predecessor", storeHostKey, "own--w1")
	plantHostRow(t, sessionsDir, "legacy", "oldkey000000000000000001", "legacy--w1")
	writeMigrationRecord(t, sessionsDir, "oldkey000000000000000001", storeHostKey)
	h := servingStoreHost(m)
	h.recovered, h.swept = false, false
	if quit := driveHost(t, h, h.Init()); quit || h.err != nil {
		t.Fatalf("startup recovery stopped the host: %v", h.err)
	}
	if _, ok := h.runtime.localSessions["own--w1"]; !ok {
		t.Fatal("own predecessor not adopted")
	}
	if _, ok := h.runtime.localSessions["legacy--w1"]; ok || !instanceExists(sessionsDir, "legacy") || len(h.recoveredKeys) != 1 {
		t.Fatalf("named runtime adopted a legacy key: keys %v", h.recoveredKeys)
	}
}

// A migration copies the old host's allocation records. One whose request a
// migrated-key row lists was launched, so it is cleared and its checkout left
// to the session; one nobody launched is quarantined as before.
func TestStoreHostRecoveryClearsTheCopiedAllocationOfALaunchedMigratedSession(t *testing.T) {
	t.Setenv(config.SessionRuntimeEnv, "")
	_, source, _ := closedSessionWorktree(t, "copied-source")
	m, sessionsDir := baseSessionModel(t)
	m.hostKey = storeHostKey
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	allocate := func(requestID, epoch string) string {
		path := filepath.Join(sessionsDir, "worktrees", epoch)
		if _, err := worktree.CreateOnRef(context.Background(), source, path, epoch, "", m.hostAllocationCheckpoint(requestID, work.SessionDescriptor{Slug: requestID, Type: "worker"})); err != nil {
			t.Fatal(err)
		}
		return path
	}
	launched := allocate("r-launched", "20261018T010101Z-0000aaaa")
	orphan := allocate("r-orphan", "20261018T010102Z-0000bbbb")
	row := session.Instance{Name: "old-host", PID: deadPID(t), HostKey: "oldkey000000000000000001", Role: "session-host", Started: "2026-10-01T00:00:00Z",
		Sessions: []session.Session{{Slug: "launched--w1", Type: "worker", Initiator: "agent", RequestID: "r-launched"}}}
	if err := session.WriteInstance(sessionsDir, row); err != nil {
		t.Fatal(err)
	}
	writeMigrationRecord(t, sessionsDir, "oldkey000000000000000001", storeHostKey)
	keys, err := session.HostRecoveryKeys(sessionsDir, storeHostKey)
	if err != nil {
		t.Fatal(err)
	}
	if err := m.recoverHostAllocations(keys); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(launched); err != nil {
		t.Fatalf("a launched session's checkout was quarantined: %v", err)
	}
	if _, err := os.Stat(orphan); !os.IsNotExist(err) {
		t.Fatalf("an unlaunched allocation survived: %v", err)
	}
	if got := readEventTypes(t, m.config.KnowledgeDir); len(got) != 1 || got[0] != session.EventWorktreeQuarantined {
		t.Fatalf("recovery events = %v", got)
	}
	if left, _ := filepath.Glob(filepath.Join(m.hostDir(), "allocations", "*.json")); len(left) != 0 {
		t.Fatalf("allocation records left: %v", left)
	}
}

func writeRawRegistryRow(t *testing.T, sessionsDir, name string, row map[string]any) {
	t.Helper()
	row["name"] = name
	b, _ := json.Marshal(row)
	if err := os.MkdirAll(session.InstancesDir(sessionsDir), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(session.InstancesDir(sessionsDir), name+".json"), b, 0o644); err != nil {
		t.Fatal(err)
	}
}

// A store host recovers a dead TUI's sessions so that closing a window strands
// nothing: it adopts the dead TUI's row, takes the TUI's checkout for a session
// that names none, and retires close requests addressed to the dead TUI. A live
// TUI is never robbed, and rows of another runtime, or without a runtime in a
// named one, are left to their own runtime.
func TestStoreHostRecoveryAdoptsADeadTUIAndRetiresItsCloseRequests(t *testing.T) {
	m, sessionsDir := baseSessionModel(t)
	m.hostKey = storeHostKey
	m.config.RepoIdentifier = "example.com/acme/proj"
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	tuiSession := func(slug string) []session.Session {
		return []session.Session{{Slug: slug, Type: "worker", Initiator: "agent", Started: "2026-10-01T00:00:00Z", RequestID: "r-" + slug}}
	}
	if err := session.WriteInstance(sessionsDir, session.Instance{Name: "dead-tui", PID: deadPID(t), Repo: m.config.RepoIdentifier, ProjectDir: "/checkouts/proj", Started: "2026-10-01T00:00:00Z", Sessions: tuiSession("tui--w1")}); err != nil {
		t.Fatal(err)
	}
	if err := session.WriteInstance(sessionsDir, session.Instance{Name: "live-tui", PID: os.Getpid(), Repo: m.config.RepoIdentifier, ProjectDir: "/checkouts/proj", Started: "2026-10-01T00:00:00Z", Sessions: tuiSession("live--w1")}); err != nil {
		t.Fatal(err)
	}
	sessions := []map[string]any{{"slug": "foreign--w1", "type": "worker", "initiator": "agent", "started": "2026-10-01T00:00:00Z"}}
	writeRawRegistryRow(t, sessionsDir, "other-runtime-tui", map[string]any{"pid": deadPID(t), "repo": m.config.RepoIdentifier, "runtime": "elsewhere", "sessions": sessions})
	writeRawRegistryRow(t, sessionsDir, "unstamped-tui", map[string]any{"pid": deadPID(t), "repo": m.config.RepoIdentifier, "sessions": sessions})
	closePath := writeCloseRequestFixture(t, sessionsDir, session.CloseRequest{RequestID: "close-dead", Slug: "tui--w1", TargetInstance: "dead-tui", Reason: "coordinator"})

	h := servingStoreHost(m)
	h.recovered, h.swept = false, false
	if quit := driveHost(t, h, h.Init()); quit || h.err != nil {
		t.Fatalf("startup recovery stopped the host: %v", h.err)
	}
	adopted, ok := h.runtime.localSessions["tui--w1"]
	if !ok || adopted.sourceDir != "/checkouts/proj" || adopted.adoptedFrom != "dead-tui" {
		t.Fatalf("dead TUI session = %+v (present %v)", adopted, ok)
	}
	if _, err := os.Stat(closePath); !os.IsNotExist(err) {
		t.Fatalf("close request to the dead TUI not retired: %v", err)
	}
	retired := false
	for _, ev := range readEventRows(t, m.config.KnowledgeDir) {
		retired = retired || (ev.Event == session.EventCloseFailed && ev.Reason == closeFailedTargetInstanceDead && ev.TargetInstance != nil && *ev.TargetInstance == "dead-tui")
	}
	if !retired {
		t.Fatal("no close_failed target-instance-dead row")
	}
	for _, name := range []string{"live-tui", "other-runtime-tui", "unstamped-tui"} {
		if !instanceExists(sessionsDir, name) {
			t.Fatalf("%s was taken", name)
		}
	}
	for _, s := range h.runtime.instanceRow().Sessions {
		if s.Slug == "tui--w1" && s.SourceDir != "/checkouts/proj" {
			t.Fatalf("host row names checkout %q for the adopted session", s.SourceDir)
		}
	}
}

// A dead row's session that is gone from this runtime's tmux server but alive
// on another runtime's server belongs to that runtime. The host neither adopts
// it nor journals it orphaned. A session alive nowhere is journaled orphaned.
func TestStoreHostRecoveryNeverOrphansASessionAliveOnAnotherRuntimeServer(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not installed")
	}
	m, sessionsDir := baseSessionModel(t)
	m.hostKey = storeHostKey
	m.config.RepoIdentifier = "example.com/acme/proj"
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	other := os.Getenv(config.SessionRuntimeEnv) + "-b"
	if err := os.MkdirAll(filepath.Join(sessionsDir, "runtimes", other, "hosts"), 0o700); err != nil {
		t.Fatal(err)
	}
	survivor := "lore-elsewhere-" + strconv.Itoa(os.Getpid())
	server := "lore-tui-" + other
	if out, err := exec.Command("tmux", "-L", server, "-f", "/dev/null", "new-session", "-d", "-s", survivor, "--", "sleep", "300").CombinedOutput(); err != nil {
		t.Fatalf("tmux: %v: %s", err, out)
	}
	t.Cleanup(func() { _ = exec.Command("tmux", "-L", server, "kill-server").Run() })
	tmuxSession := func(slug, tmux string) []session.Session {
		return []session.Session{{Slug: slug, Type: "worker", Initiator: "agent", Started: "2026-10-01T00:00:00Z", RequestID: "r-" + slug, Tmux: tmux}}
	}
	if err := session.WriteInstance(sessionsDir, session.Instance{Name: "dead-a", PID: deadPID(t), Repo: m.config.RepoIdentifier, Started: "2026-10-01T00:00:00Z", Sessions: tmuxSession("alive--w1", survivor)}); err != nil {
		t.Fatal(err)
	}
	if err := session.WriteInstance(sessionsDir, session.Instance{Name: "dead-b", PID: deadPID(t), Repo: m.config.RepoIdentifier, Started: "2026-10-01T00:00:00Z", Sessions: tmuxSession("gone--w1", "lore-gone-"+strconv.Itoa(os.Getpid()))}); err != nil {
		t.Fatal(err)
	}
	msg := m.adoptionScanCmd()().(adoptionScanMsg)
	if len(msg.notices) != 0 {
		t.Fatalf("scan notices: %+v", msg.notices)
	}
	if !instanceExists(sessionsDir, "dead-a") {
		t.Fatal("the row of a session alive on another runtime's server was claimed")
	}
	for _, ev := range readEventRows(t, m.config.KnowledgeDir) {
		if ev.Event == session.EventOrphaned && ev.Slug == "alive--w1" {
			t.Fatal("a session alive on another runtime's server was journaled orphaned")
		}
	}
	orphaned := false
	for _, ev := range readEventRows(t, m.config.KnowledgeDir) {
		orphaned = orphaned || (ev.Event == session.EventOrphaned && ev.Slug == "gone--w1")
	}
	if !orphaned {
		t.Fatal("a session alive nowhere was not journaled orphaned")
	}
	if got := otherRuntimeTmuxServers(m.config.KnowledgeDir); !slices.Contains(got, "lore-tui") || !slices.Contains(got, server) || slices.Contains(got, config.TmuxServer()) {
		t.Fatalf("servers checked = %v", got)
	}
}

// --host-key must be the store's key: sha256 over the symlink-resolved store
// path, plus the runtime name in a named runtime. Anything else exits 2 before
// the host creates state or touches tmux.
func TestStoreHostRefusesAHostKeyThatIsNotItsStores(t *testing.T) {
	t.Setenv("LORE_KNOWLEDGE_DIR", "")
	os.Unsetenv("LORE_KNOWLEDGE_DIR")
	runtime := os.Getenv(config.SessionRuntimeEnv)
	kdir := t.TempDir()
	link := filepath.Join(t.TempDir(), "store-link")
	if err := os.Symlink(kdir, link); err != nil {
		t.Fatal(err)
	}
	resolved := config.NormalizeProjectDir(kdir)
	// The host-key check comes first. Should it ever not, this setting stops the
	// host with exit 1 before it could serve.
	t.Setenv("LORE_KNOWLEDGE_DIR", t.TempDir())
	for name, key := range map[string]string{
		"another store's key":   session.StoreHostKey(config.NormalizeProjectDir(t.TempDir()), runtime),
		"the default runtime's": session.StoreHostKey(resolved, ""),
		"the unresolved path's": session.StoreHostKey(link, runtime),
		"a legacy key":          "storekey0123456789abcdef",
	} {
		ready := filepath.Join(t.TempDir(), "hosts", key, "ready.json")
		if code := sessionHostMain([]string{"--scope", "store", "--host-key", key, "--kdir", link, "--ready-file", ready, "--runtime", runtime}); code != 2 {
			t.Errorf("%s: exit %d, want 2", name, code)
		}
		if _, err := os.Stat(filepath.Dir(ready)); !os.IsNotExist(err) {
			t.Errorf("%s: refused host created its state directory", name)
		}
	}
	// The store's own key passes the check; with runtime.lock held the host
	// then stops at 3, before serving.
	os.Unsetenv("LORE_KNOWLEDGE_DIR")
	key := session.StoreHostKey(resolved, runtime)
	ready := filepath.Join(t.TempDir(), "hosts", key, "ready.json")
	if err := os.MkdirAll(filepath.Dir(ready), 0o700); err != nil {
		t.Fatal(err)
	}
	lock, err := hostLock(filepath.Join(filepath.Dir(ready), "runtime.lock"), true)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if code := sessionHostMain([]string{"--scope", "store", "--host-key", key, "--kdir", link, "--ready-file", ready, "--runtime", runtime}); code != 3 {
		t.Fatalf("store key through a symlinked --kdir: exit %d, want 3", code)
	}
}
