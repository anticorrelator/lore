package main

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/anticorrelator/lore/tui/internal/worktree"
	"os"
	"path/filepath"
	"syscall"
	"testing"

	tea "charm.land/bubbletea/v2"
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
	ready := filepath.Join(sessionsDir, "hosts", "key", "ready.json")
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
	proof := filepath.Join(m.sessionsDir, "hosts", m.hostKey, "cleanup", "demo.json")
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
	if err := m.recoverHostAllocations(); err != nil {
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
