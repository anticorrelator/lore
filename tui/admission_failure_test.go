package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

func TestFullSpawnDiagnosticAndDeterministicDisposition(t *testing.T) {
	for _, deterministic := range []bool{false, true} {
		t.Run(fmt.Sprint(deterministic), func(t *testing.T) {
			m, dir := baseSessionModel(t)
			m.eventScript = repoScriptPath(t, "session-event-append.sh")
			req := session.Request{RequestID: "failure-test", Type: "worker", Slug: session.StrPtr("demo"), Initiator: "agent"}
			if err := os.MkdirAll(session.PendingDir(dir), 0755); err != nil {
				t.Fatal(err)
			}
			data, _ := json.Marshal(req)
			if err := os.WriteFile(filepath.Join(session.PendingDir(dir), req.RequestID+".json"), data, 0644); err != nil {
				t.Fatal(err)
			}
			if won, err := session.ClaimRequest(dir, req.RequestID); err != nil || !won {
				t.Fatalf("claim %v %v", won, err)
			}
			m.pendingSpawns = map[string]liveSession{"demo": {requestID: req.RequestID}}
			cause := strings.Repeat("nested diagnostic ", 40) + "\n/usr/local/python3: ModuleNotFoundError yaml; /custom/state denied"
			var failure error = fmt.Errorf("%s", cause)
			if deterministic {
				failure = &work.LaunchAdmissionError{Err: failure}
			}
			_, cmd := m.handleStreamError(work.StreamErrorMsg{Slug: "demo", Err: failure})
			var execute func(tea.Cmd)
			execute = func(cmd tea.Cmd) {
				if cmd == nil {
					return
				}
				if batch, ok := cmd().(tea.BatchMsg); ok {
					for _, sub := range batch {
						execute(sub)
					}
				}
			}
			beforeFailure := time.Now().UTC()
			execute(cmd)
			afterFailure := time.Now().UTC()
			rows := readEventRows(t, m.config.KnowledgeDir)
			if len(rows) == 0 || rows[0].Reason != "spawn: "+cause {
				t.Fatalf("full cause lost: %+v", rows)
			}
			if deterministic {
				if len(session.ScanPending(dir)) != 0 {
					t.Fatal("deterministic refusal retried")
				}
				archived, err := os.ReadFile(filepath.Join(dir, "requests", "abandoned", req.RequestID+".json"))
				if err != nil || !strings.Contains(string(archived), "/custom/state denied") {
					t.Fatalf("archive missing %v %s", err, archived)
				}
				if rows[len(rows)-1].Event != session.EventAbandoned {
					t.Fatalf("no terminal explanation: %+v", rows)
				}
			} else {
				pending := session.ScanPending(dir)
				if len(pending) != 1 || pending[0].Attempts != 1 || pending[0].LastError == nil || *pending[0].LastError != "spawn: "+cause {
					t.Fatalf("transient retry lost cause: %+v", pending)
				}
				if pending[0].LastAttemptAt == nil {
					t.Fatal("missing retry timestamp")
				}
				at, err := time.Parse(time.RFC3339Nano, *pending[0].LastAttemptAt)
				if err != nil || at.Before(beforeFailure) || at.After(afterFailure) {
					t.Fatalf("retry timestamp outside actual failure interval: %v %v", at, err)
				}
			}
		})
	}
}

func TestQueueAdmissionPassDoesNotOverlap(t *testing.T) {
	m, dir := baseSessionModel(t)
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	lock, err := hostLock(filepath.Join(dir, ".queue-admission-"+m.instanceName+".lock"), true)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	result := m.queueTickCmd()().(queueTickResultMsg)
	if result.err != nil || result.result.Claimed != nil {
		t.Fatalf("overlapping pass: %+v", result)
	}
}
