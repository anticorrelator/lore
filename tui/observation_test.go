package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

func harnessPanel(t *testing.T, slug string, rows []string) work.SessionPanelModel {
	p, _ := runtimePanel(t, slug, rows)
	return p
}

func TestActivityIndependentOfInputAndSilence(t *testing.T) {
	for framework, composer := range map[string][]string{"claude-code": ccComposerRows, "codex": cxComposerRows, "opencode": ocComposerRows} {
		t.Run(framework, func(t *testing.T) {
			rows := append([]string{"Working (10s · esc to interrupt)"}, composer...)
			snap := work.ScreenSnapshot{Rows: rows}
			ready, _ := sendReadiness(framework, true, true, true, snap)
			activity, _ := classifyActivity(framework, snap)
			if !ready || activity != "working" {
				t.Fatalf("ready=%v activity=%s", ready, activity)
			}
			activity, _ = classifyActivity(framework, work.ScreenSnapshot{Rows: composer})
			if activity != "unknown" {
				t.Fatalf("silent tool and composer alone inferred %s", activity)
			}
		})
	}
}

func TestSettledActivityAndStaleHistory(t *testing.T) {
	rows := append([]string{"✻ Worked for 4s"}, ccComposerRows...)
	rows = append(rows, "Background task 1: 5s")
	activity, evidence := classifyActivity("claude-code", work.ScreenSnapshot{Rows: rows})
	if activity != "idle" || evidence.Matcher != "claude-code-worked-for-v1" {
		t.Fatalf("%s %+v", activity, evidence)
	}
	rows = append([]string{"✻ Worked for 4s", "> Run next tool", "Bash sleep 100"}, ccComposerRows...)
	if got, _ := classifyActivity("claude-code", work.ScreenSnapshot{Rows: rows}); got != "unknown" {
		t.Fatalf("historical footer inferred %s", got)
	}
}

func TestObservationStartupRecoveryAndPeek(t *testing.T) {
	m := sessionModelWithRealScript(t)
	m.sessionsDir = filepath.Join(t.TempDir(), "sessions")
	m.instanceName = "host-a"
	m.localSessions["demo"] = liveSession{harness: "claude-code", sessionID: "launch-1", typ: "implement"}
	m.sessionPanels = map[string]work.SessionPanelModel{"demo": harnessPanel(t, "demo", append([]string{"✻ Worked for 4s"}, ccComposerRows...))}
	now := time.Now()
	first, _, _ := m.snapshotObservation("demo", now)
	if first.Activity != "starting" {
		t.Fatalf("initial: %+v", first)
	}
	m, _ = m.applySessionObservation("demo", first, now)
	obs, _, _ := m.snapshotObservation("demo", now.Add(3*time.Second))
	if obs.Activity != "idle" || obs.Generation != "launch-1" {
		t.Fatalf("settled: %+v", obs)
	}
	m.instanceName = "host-b"
	recovered, _, _ := m.snapshotObservation("demo", now.Add(4*time.Second))
	if recovered.Generation != obs.Generation || recovered.Instance == obs.Instance {
		t.Fatalf("recovered identity: %+v", recovered)
	}
	m.sessionObservations = nil
	recovered, _, _ = m.snapshotObservation("demo", now.Add(4*time.Second))
	if recovered.Activity != "starting" {
		t.Fatalf("recovered inherited park: %+v", recovered)
	}
	m.sessionPanels["demo"] = harnessPanel(t, "demo", ccModalRows)
	m, cmd := m.handlePeekRequestScan(peekRequestScanMsg{matched: []session.PeekRequest{{Slug: "demo", RequestID: "rich", Raw: true}}})
	runJournalCmds(t, cmd)
	data, err := os.ReadFile(filepath.Join(m.sessionsDir, "peek-responses", "rich.json"))
	if err != nil {
		t.Fatal(err)
	}
	var response session.PeekResponse
	if err = json.Unmarshal(data, &response); err != nil {
		t.Fatal(err)
	}
	if response.Observation.Activity != "blocked" || response.Modal == nil || !response.Modal.Answerable || response.Modal.Signature.Title == "" || len(response.Rows) == 0 || response.ANSI == "" || response.Screen.Width == 0 {
		t.Fatalf("peek lacks evidence: %+v", response)
	}
	m.sessionPanels["demo"] = harnessPanel(t, "demo", ccComposerRows)
	cleared, _, state := m.snapshotObservation("demo", now.Add(5*time.Second))
	if cleared.Activity == "blocked" || state.interactive {
		t.Fatalf("modal persisted: %+v", cleared)
	}
	m.sessionPanels["demo"] = work.SessionPanelModel{}
	unavailable, _, _ := m.snapshotObservation("demo", now)
	if unavailable.Fresh || unavailable.Activity != "unknown" || unavailable.Authority != "none" {
		t.Fatalf("unavailable: %+v", unavailable)
	}
}

func TestTerminalAnimationDoesNotConfirmSend(t *testing.T) {
	for _, framework := range []string{"claude-code", "codex", "opencode"} {
		snap := work.ScreenSnapshot{Rows: []string{"background task elapsed 1s", "partial repaint"}, ANSI: strings.Repeat(" ", 5)}
		if observeSend(framework, false, snap) != obsUnobservable {
			t.Fatalf("%s animation confirmed send", framework)
		}
	}
}

func TestSettledAllHarnessesRejectLaterInput(t *testing.T) {
	for _, tc := range []struct {
		framework, footer string
		composer          []string
	}{
		{"claude-code", "✻ Worked for 4s", ccComposerRows},
		{"codex", "─ Worked for 1m 23s ─────────────────", cxComposerRows},
		{"opencode", "▣ Build · GPT-4o mini · 2.3s", ocComposerRows},
	} {
		rows := append([]string{tc.footer}, tc.composer...)
		if got, _ := classifyActivity(tc.framework, work.ScreenSnapshot{Rows: rows}); got != "idle" {
			t.Errorf("%s settled=%s", tc.framework, got)
		}
		prefix := "> Run next task"
		if tc.framework == "codex" {
			prefix = "› Run next task"
		}
		rows = append([]string{tc.footer, prefix, "Bash sleep 100"}, tc.composer...)
		if got, _ := classifyActivity(tc.framework, work.ScreenSnapshot{Rows: rows}); got != "unknown" {
			t.Errorf("%s historical=%s", tc.framework, got)
		}
	}
}

func TestObservationGenerationBindsLaunchAcrossRecovery(t *testing.T) {
	launched := liveSession{sessionID: "same-session", requestID: "request-1", started: time.Unix(100, 999)}
	recovered := launched
	recovered.started = time.Unix(100, 0)
	if observationGeneration(launched) != observationGeneration(recovered) {
		t.Fatal("registry timestamp precision changed generation")
	}
	relaunched := launched
	relaunched.started = time.Unix(101, 0)
	if observationGeneration(launched) == observationGeneration(relaunched) {
		t.Fatal("resuming same session inherited launch generation")
	}
}

func TestActivityChromeIgnoresCompletedHistoryAndQuotedHints(t *testing.T) {
	rows := append([]string{"The command says esc to interrupt.", "✶ Musing… (12s · esc to interrupt)", "✻ Worked for 4s"}, ccComposerRows...)
	if activity, _ := classifyActivity("claude-code", work.ScreenSnapshot{Rows: rows}); activity != "idle" {
		t.Fatalf("historical activity overrides settled turn: %s", activity)
	}
	rows = append([]string{"The command says esc to interrupt."}, cxComposerRows...)
	if activity, _ := classifyActivity("codex", work.ScreenSnapshot{Rows: rows}); activity != "unknown" {
		t.Fatalf("quoted hint claims work: %s", activity)
	}
}

func TestObservationIdentityWithoutNativeSessionID(t *testing.T) {
	m := runtimeModel(t)
	m.localSessions["worker-codex"] = liveSession{harness: "codex", requestID: "request-1", started: time.Unix(100, 0)}
	m.sessionPanels["worker-codex"] = harnessPanel(t, "worker-codex", cxComposerRows)
	obs, _, _ := m.snapshotObservation("worker-codex", time.Now())
	if obs.SessionID != "worker-codex" || obs.SessionHandle != "worker-codex" || obs.NativeSessionID != "" || obs.Generation == "" {
		t.Fatalf("missing universal identity: %+v", obs)
	}
}

func TestClaudeRotatingSettledAndDiffFooter(t *testing.T) {
	for _, marker := range []string{"✻ Sautéed for 35m 56s · done 1:23 PM", "✻ Cogitated for 4s", "✻ Baked for 1h 2m 3s"} {
		rows := append([]string{marker, "/diff to hide diff"}, ccComposerRows...)
		got, _ := classifyActivity("claude-code", work.ScreenSnapshot{Rows: rows})
		if got != "idle" {
			t.Fatalf("%q: %s", marker, got)
		}
	}
}

func TestClaudeQueuedComposerIsNotModal(t *testing.T) {
	rows := append([]string{"✶ Crunching… (5m 0s · esc to interrupt)"}, ccComposerRows...)
	for i, row := range rows {
		if strings.TrimSpace(row) == "❯" {
			rows[i] = "❯ Press up to edit queued messages"
		}
	}
	rows = append(rows, "queued first message", "queued second message", "↑ edit queue")
	snap := work.ScreenSnapshot{Rows: rows, ANSI: strings.Join(rows, "\n")}
	if ccInteractivePrompt(rows) {
		t.Fatal("queue classified as modal")
	}
	ready, reason := sendReadiness("claude-code", false, true, true, snap)
	if !ready {
		t.Fatalf("queued turn unreachable: %s", reason)
	}
}

func TestReconnectFailureIsStalledWithoutInferringIdle(t *testing.T) {
	rows := append([]string{"Reconnecting… idle timeout waiting for websocket", "Working (10s · esc to interrupt)"}, cxComposerRows...)
	got, evidence := classifyActivity("codex", work.ScreenSnapshot{Rows: rows})
	if got != "stalled" || !strings.Contains(evidence.Reason, "websocket") {
		t.Fatalf("%s %+v", got, evidence)
	}
}
