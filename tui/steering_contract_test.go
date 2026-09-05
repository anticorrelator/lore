package main

import (
	tea "charm.land/bubbletea/v2"
	"encoding/json"
	"fmt"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
	"github.com/anticorrelator/lore/tui/internal/worktree"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSteeringProviderErrorOutranksInterrupt(t *testing.T) {
	for _, framework := range []string{"claude-code", "codex", "opencode"} {
		rows := []string{"Reconnecting... 2/5", "Working (120s · esc to interrupt)"}
		activity, evidence := classifyActivity(framework, work.ScreenSnapshot{Rows: rows})
		if activity != "blocked" || evidence.Matcher != "provider-error-v1" {
			t.Fatalf("%s %s %+v", framework, activity, evidence)
		}
	}
	if got, _ := classifyActivity("codex", work.ScreenSnapshot{Rows: []string{"The docs mention reconnecting", "Working (120s · esc to interrupt)"}}); got != "working" {
		t.Fatal(got)
	}
}

func TestSteeringProgressIsNotCaptureFreshness(t *testing.T) {
	m := runtimeModel(t)
	m.localSessions["demo"] = liveSession{harness: "claude-code", sessionID: "native"}
	m.observationProgress = map[string]observationProgress{}
	now := time.Now()
	snap := work.ScreenSnapshot{Rows: append([]string{"Bash sleep 600", "Working (1s · esc to interrupt)"}, ccComposerRows...)}
	first := session.Observation{Generation: "g"}
	m.observeProgress("demo", &first, snap, now)
	snap.Rows[1] = "Working (150s · esc to interrupt)"
	second := session.Observation{Generation: "g", ObservedAt: now.Add(150 * time.Second).Format(time.RFC3339Nano), Fresh: true}
	m.observeProgress("demo", &second, snap, now.Add(150*time.Second))
	if second.ProgressAgeSeconds != 150 || !second.SuspectedStall || second.ProgressObservedAt != first.ProgressObservedAt || !second.Fresh {
		t.Fatalf("%+v", second)
	}
	if got, _ := classifyActivity("claude-code", snap); got != "working" {
		t.Fatal("silence changed active long tool", got)
	}
	partial := session.Observation{Generation: "g"}
	m.observeProgress("demo", &partial, work.ScreenSnapshot{Rows: []string{"partial repaint"}}, now.Add(150*time.Second))
	if partial.ProgressObservedAt != first.ProgressObservedAt {
		t.Fatal("unknown paint refreshed progress")
	}
	snap.Rows[0] = "Bash returned output"
	m.observeProgress("demo", &second, snap, now.Add(151*time.Second))
	if second.ProgressAgeSeconds != 0 || second.SuspectedStall {
		t.Fatalf("new output %+v", second)
	}
	next := session.Observation{Generation: "next"}
	m.observeProgress("demo", &next, work.ScreenSnapshot{}, now.Add(200*time.Second))
	if next.ProgressObservedAt != "" {
		t.Fatal("new generation inherited progress")
	}
}

func TestSteeringObservationRepaintTrace(t *testing.T) {
	m := runtimeModel(t)
	m.localSessions["demo"] = liveSession{typ: "implement"}
	for _, tc := range []struct {
		activity, generation string
		event                bool
	}{
		{"working", "g", true}, {"unknown", "g", false}, {"working", "g", false},
		{"blocked", "g", true}, {"unknown", "g", false}, {"working", "g", true}, {"working", "g", false},
		{"unknown", "next", false}, {"working", "next", true},
	} {
		var cmd tea.Cmd
		m, cmd = m.applySessionObservation("demo", session.Observation{Activity: tc.activity, Generation: tc.generation}, time.Now())
		if (cmd != nil) != tc.event {
			t.Fatalf("%+v event=%v", tc, cmd != nil)
		}
		if m.sessionObservations["demo"].Activity != tc.activity {
			t.Fatal("sample hidden")
		}
	}
}

// Synthetic libghostty terminal fixtures exercise actual snapshot width, rows,
// ANSI and cursor fields. They are not a replay of the missing incident screen.
func TestSteeringComposerGeometry(t *testing.T) {
	for _, width := range []int{40, 79, 80, 120} {
		for _, split := range []bool{false, true} {
			t.Run(fmt.Sprintf("%d/split=%v", width, split), func(t *testing.T) {
				for _, control := range []string{"idle", "active", "held", "absent", "modal", "mismatch"} {
					prompt := "❯ "
					if control == "held" {
						prompt = "❯ do not replace"
					}
					if control == "absent" {
						prompt = "  "
					}
					border := strings.Repeat("─", width)
					rows := []string{"✻ Worked for 4s", border, prompt, border, "/diff to hide diff"}
					if control == "active" {
						rows[0] = "Working (10s · esc to interrupt)"
					}
					if control == "modal" {
						rows = []string{border, "Do you want to proceed?", "❯ 1. Yes", "  2. No", "Esc to cancel", border}
					}
					if control == "mismatch" {
						rows[3] = strings.Repeat("─", width-2)
					}
					columns := width + 2
					if split {
						columns = width + 42
						for i, row := range rows {
							rows[i] = row + strings.Repeat(" ", max(0, width-len([]rune(row)))) + "│ diff panel"
						}
					}
					panel := work.NewSessionPanelModel("geometry")
					panel, _ = panel.Update(tea.WindowSizeMsg{Width: columns, Height: len(rows) + 2})
					panel, _ = panel.Update(work.TerminalOutputMsg{Slug: "geometry", Data: []byte("\x1b[2J\x1b[H" + strings.Join(rows, "\r\n"))})
					snap, err := panel.ScreenState()
					if err != nil {
						t.Fatal(err)
					}
					if snap.Columns == 0 || snap.ANSI == "" || len(snap.Rows) == 0 {
						t.Fatalf("missing actual snapshot %+v", snap)
					}
					ready, reason := sendReadiness("claude-code", true, true, true, snap)
					want := control == "idle" || control == "active"
					if ready != want {
						t.Fatalf("%s ready=%v reason=%s rows=%q", control, ready, reason, snap.Rows)
					}
				}
			})
		}
	}
}

func steeringRequest(now time.Time) (interruptRequest, liveSession) {
	ls := liveSession{requestID: "launch", sessionID: "native", pid: os.Getpid(), harness: "claude-code", worktree: &worktree.Identity{Epoch: "epoch"}}
	r := interruptRequest{RequestID: "interrupt-test", Slug: "demo", TargetInstance: "host", OwnerPID: os.Getpid(), OwnerStarted: "owner-start", SessionPID: os.Getpid(), LaunchRequestID: "launch", SessionID: "native", Epoch: "epoch", RequestedAt: now.Format(time.RFC3339Nano), ExpiresAt: now.Add(15 * time.Second).Format(time.RFC3339Nano)}
	return r, ls
}
func TestSteeringInterruptIdentityAndModalGate(t *testing.T) {
	now := time.Now()
	r, ls := steeringRequest(now)
	snap := work.ScreenSnapshot{Rows: []string{"Working (10s · esc to interrupt)"}}
	if got := interruptGate(r, ls, "host", "owner-start", os.Getpid(), "claude-code", snap, now); got != "" {
		t.Fatal(got)
	}
	for _, field := range []string{"expired", "launch", "native", "epoch", "owner", "owner-start", "missing", "process", "unsupported", "modal", "idle", "password"} {
		t.Run(field, func(t *testing.T) {
			r, ls := steeringRequest(now)
			s := snap
			h := "claude-code"
			switch field {
			case "expired":
				r.ExpiresAt = now.Format(time.RFC3339Nano)
			case "launch":
				r.LaunchRequestID = "other"
			case "native":
				r.SessionID = "other"
			case "epoch":
				r.Epoch = "other"
			case "owner":
				r.OwnerPID++
			case "owner-start":
				r.OwnerStarted = "other"
			case "missing":
				r.SessionID = ""
			case "process":
				r.SessionPID++
			case "unsupported":
				h = "unsupported"
			case "modal":
				s.Rows = append([]string{"Working (10s · esc to interrupt)"}, ccModalRows...)
			case "idle":
				s.Rows = append([]string{"✻ Worked for 4s"}, ccComposerRows...)
			case "password":
				s.PasswordInput = true
			}
			if got := interruptGate(r, ls, "host", "owner-start", os.Getpid(), h, s, now); got == "" {
				t.Fatal("unsafe interrupt admitted")
			}
		})
	}
}

func TestSteeringInterruptDeliveryNeverReplays(t *testing.T) {
	for _, host := range []string{"", "managed-host"} {
		t.Run("host="+host, func(t *testing.T) {
			m := runtimeModel(t)
			m.hostKey = host
			m.instanceName = "host"
			m.instanceStartedISO = "owner-start"
			r, ls := steeringRequest(time.Now())
			m.localSessions["demo"] = ls
			panel, reader := runtimePanel(t, "demo", []string{"Working (10s · esc to interrupt)"})
			m.sessionPanels["demo"] = panel
			queue := filepath.Join(m.sessionsDir, "interrupt-requests", r.RequestID+".json")
			if err := hostAtomicJSON(queue, r); err != nil {
				t.Fatal(err)
			}
			m, _ = m.handleInterruptScan(interruptScanMsg{r})
			if m.flashErr != "" {
				t.Fatal(m.flashErr)
			}
			readRuntimeBytes(t, reader, "\x1b")
			if _, err := os.Stat(queue); !os.IsNotExist(err) {
				t.Fatal("queue not consumed", err)
			}
			delivery := m
			if host == "" {
				delivery.hostKey = "interrupt-host"
			}
			b, err := os.ReadFile(delivery.hostDeliveryPath(r.RequestID))
			if err != nil {
				t.Fatal(err)
			}
			var saved hostDelivery
			json.Unmarshal(b, &saved)
			if saved.Event.Event != "interrupt_uncertain" || saved.Event.Links["escape_written"] != "true" {
				t.Fatalf("untruthful outcome %+v", saved)
			}
			// A scan captured before consumption and a recreated request cannot write twice.
			hostAtomicJSON(queue, r)
			m, _ = m.handleInterruptScan(interruptScanMsg{r})
			reader.SetReadDeadline(time.Now().Add(20 * time.Millisecond))
			buffer := make([]byte, 1)
			if n, _ := reader.Read(buffer); n != 0 {
				t.Fatal("replayed ESC")
			}
		})
	}
}

func TestSteeringInterruptRefusalDoesNotWrite(t *testing.T) {
	m := runtimeModel(t)
	m.instanceName = "host"
	m.instanceStartedISO = "owner-start"
	r, ls := steeringRequest(time.Now())
	m.localSessions["demo"] = ls
	panel, reader := runtimePanel(t, "demo", append([]string{"Working (10s · esc to interrupt)"}, ccModalRows...))
	m.sessionPanels["demo"] = panel
	m, _ = m.handleInterruptScan(interruptScanMsg{r})
	if m.flashErr != "" {
		t.Fatal(m.flashErr)
	}
	reader.SetReadDeadline(time.Now().Add(20 * time.Millisecond))
	buffer := make([]byte, 1)
	if n, _ := reader.Read(buffer); n != 0 {
		t.Fatal("modal received ESC")
	}
	delivery := m
	delivery.hostKey = "interrupt-host"
	b, err := os.ReadFile(delivery.hostDeliveryPath(r.RequestID))
	if err != nil {
		t.Fatal(err)
	}
	var saved hostDelivery
	json.Unmarshal(b, &saved)
	if saved.Event.Event != "interrupt_refused" || saved.Event.Reason != "modal-owned-input" {
		t.Fatalf("%+v", saved)
	}
}
