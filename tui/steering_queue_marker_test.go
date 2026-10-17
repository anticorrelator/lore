package main

import (
	"encoding/json"
	"github.com/anticorrelator/lore/tui/internal/session"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/anticorrelator/lore/tui/internal/work"
)

func queuedComposerFixture(styled bool) []string {
	hint := "❯ Press up to edit queued messages"
	if styled {
		hint = "❯ \x1b[2mPress up to edit queued messages\x1b[22m"
	}
	return []string{"✻ Crunching… 5m 0s", rule, hint, rule,
		"  queued request: review the changes", "  ↑ inspect the earlier diff", "  keep the current task running"}
}
func TestSteeringQueuedComposerIsNotAnOptionModal(t *testing.T) {
	for _, styled := range []bool{true, false} {
		panel, _ := runtimePanel(t, "queue", queuedComposerFixture(styled))
		snap, err := panel.ScreenState()
		if err != nil {
			t.Fatal(err)
		}
		state, _ := classifyScreen("claude-code", snap)
		ready, reason := sendReadiness("claude-code", false, true, true, snap)
		if ready != styled || state.queued != styled || state.interactive {
			t.Fatalf("styled=%v ready=%v reason=%s state=%+v", styled, ready, reason, state)
		}
		if styled {
			if got := observeSend("claude-code", false, snap); got != obsSubmitted {
				t.Fatalf("queued message misreported unsubmitted: %v", got)
			}
			if activity, _ := classifyActivity("claude-code", snap); activity != "working" {
				t.Fatal("queued active turn not working", activity)
			}
		} else if !state.heldInput {
			t.Fatal("typed queue hint was treated as empty")
		}
	}
	for _, modal := range [][]string{ccModalRows, ccOptionSelectRows, {rule, "Choose an action", "❯ Continue", "  Stop", "  Explain", "Use arrow keys", rule}} {
		rows := append(queuedComposerFixture(true), modal...)
		panel, _ := runtimePanel(t, "modal", rows)
		snap, _ := panel.ScreenState()
		if ready, reason := sendReadiness("claude-code", true, true, true, snap); ready || reason != sendReasonModal {
			t.Fatalf("real modal bypassed: %v %s", ready, reason)
		}
	}
	rows := queuedComposerFixture(true)
	rows[2] = "❯ real draft"
	panel, _ := runtimePanel(t, "draft", rows)
	snap, _ := panel.ScreenState()
	if ready, _ := sendReadiness("claude-code", true, true, true, snap); ready {
		t.Fatal("held draft admitted")
	}
}

func TestSteeringRecordedQueuedComposerReplay(t *testing.T) {
	// Existing recorded probe, not a newly run harness or the later incident.
	path := filepath.Join("..", "tests", "probes", "session_injection", "observations", "raw", "claude-code", "p5_midgen.log")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	// probe_claude_code.py records these annotations in the log, not the PTY.
	data = regexp.MustCompile(`\n===PROBE-MARKER [^\n]*===\n`).ReplaceAll(data, nil)
	hint := []byte("Press up to edit queued messages")
	at := strings.Index(string(data), string(hint))
	if at < 0 {
		t.Fatal("recorded hint missing")
	}
	end := at + len(hint)
	tail := strings.Index(string(data[end:]), "\x1b[?2026l")
	if tail < 0 {
		t.Fatal("recorded paint boundary missing")
	}
	end += tail + len("\x1b[?2026l")
	panel := work.NewSessionPanelModel("recorded")
	panel, _ = panel.Update(tea.WindowSizeMsg{Width: 120, Height: 40})
	panel, _ = panel.Update(work.TerminalOutputMsg{Slug: "recorded", Data: data[:end]})
	snap, err := panel.ScreenState()
	if err != nil {
		t.Fatal(err)
	}
	state, _ := classifyScreen("claude-code", snap)
	if !state.queued || state.interactive || state.heldInput {
		t.Fatalf("recorded queue state %+v rows=%q", state, snap.Rows)
	}
	if ready, reason := sendReadiness("claude-code", false, true, true, snap); !ready {
		t.Fatalf("recorded queue cannot accept another send: %s", reason)
	}
}

func TestSteeringRotatingCompletedMarkers(t *testing.T) {
	for _, marker := range []string{"✻ Worked for 4s", "✻ Baked for 1m", "✻ Sautéed for 35m 56s · done 1:23 PM", "✻ Sautéed for 2s", "✻ Crunched for 1h 2m 3s · done 12:01 AM"} {
		panel, _ := runtimePanel(t, "done", append([]string{marker}, ccComposerRows...))
		snap, _ := panel.ScreenState()
		if got, _ := classifyActivity("claude-code", snap); got != "idle" {
			t.Fatalf("%q classified %s", marker, got)
		}
		if ready, reason := sendReadiness("claude-code", true, true, true, snap); !ready {
			t.Fatalf("%q refused %s", marker, reason)
		}
	}
	for _, marker := range []string{"✻ Sautéing… 35m 56s", "✻ Sautéed for 35m 56s · done 25:99 PM", "Sautéed for 35m 56s", "✻ Sautéed for 35m 56s extra", "✻ Sautéed for later"} {
		if ccSettled.MatchString(marker) {
			t.Fatalf("non-completion accepted %q", marker)
		}
	}
	marker := "✻ Sautéed for 35m 56s · done 1:23 PM"
	for control, rows := range [][]string{
		append([]string{marker, "❯ next request", "✻ Crunching… 5m 0s"}, ccComposerRows...),
		append([]string{marker}, ccModalRows...),
		append([]string{marker}, ccHeldRows...),
	} {
		panel, _ := runtimePanel(t, "control", rows)
		snap, _ := panel.ScreenState()
		if got, _ := classifyActivity("claude-code", snap); got == "idle" {
			t.Fatalf("active/modal/held control classified idle: %q", rows)
		}
		if ready, _ := sendReadiness("claude-code", true, true, true, snap); ready != (control == 0) {
			t.Fatalf("active/modal/held send control %d ready=%v", control, ready)
		}
	}
	// The independent probe corpus already records a rotated Unicode marker.
	b, err := os.ReadFile(filepath.Join("..", "tests", "probes", "session_injection", "observations", "claude-code.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Mid struct {
			Rows []string `json:"final_rows"`
		} `json:"mid_generation_inject"`
	}
	if err = json.Unmarshal(b, &fixture); err != nil {
		t.Fatal(err)
	}
	panel, _ := runtimePanel(t, "recorded-done", fixture.Mid.Rows)
	snap, _ := panel.ScreenState()
	if got, _ := classifyActivity("claude-code", snap); got != "idle" {
		t.Fatalf("recorded rotated completion %s", got)
	}
}

func TestSteeringSendAgainWhileMessageQueued(t *testing.T) {
	m := runtimeModel(t)
	m.localSessions["demo"] = liveSession{harness: "claude-code", typ: "implement"}
	panel, reader := runtimePanel(t, "demo", queuedComposerFixture(true))
	m.sessionPanels["demo"] = panel
	snap, _ := panel.ScreenState()
	if ready, reason := sendReadiness("claude-code", false, true, false, snap); ready || reason != sendReasonGenerating {
		t.Fatal("queue bypassed unsupported mid-generation contract", ready, reason)
	}
	m, cmd := m.handleSendRequestScan(sendRequestScanMsg{matched: []session.SendRequest{{RequestID: "second", Slug: "demo", Body: "another queued message"}}})
	runJournalCmds(t, cmd)
	if _, ok := m.pendingSendVerify["second"]; !ok {
		t.Fatalf("second message was not admitted: %s", m.flashErr)
	}
	readRuntimeBytes(t, reader, "another queued message\r")
	m, cmds := m.advanceSendVerifications()
	for _, cmd := range cmds {
		runJournalCmds(t, cmd)
	}
	if _, ok := m.pendingSendVerify["second"]; ok {
		t.Fatal("queue hint left second submission pending")
	}
}
