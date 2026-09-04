package main

import (
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

func runtimePanel(t *testing.T, slug string, rows []string) (work.SessionPanelModel, *os.File) {
	t.Helper()
	p := work.NewSessionPanelModel(slug)
	p, _ = p.Update(tea.WindowSizeMsg{Width: 140, Height: len(rows) + 2})
	p, _ = p.Update(work.TerminalOutputMsg{Slug: slug, Data: []byte("\x1b[2J\x1b[H" + strings.Join(rows, "\r\n"))})
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { reader.Close(); writer.Close() })
	return p.SetPtmx(writer, nil, nil), reader
}

func runtimeModel(t *testing.T) model {
	t.Helper()
	setupFakeLoreData(t, `{"version":1,"tui_launch_framework":"claude-code"}`)
	m, _ := baseSessionModel(t)
	m.eventScript = repoScriptPath(t, "session-event-append.sh")
	m.localSessions = map[string]liveSession{}
	m.sessionPanels = map[string]work.SessionPanelModel{}
	return m
}

func setRuntimeLaunchDefault(t *testing.T, h string) {
	t.Helper()
	b, err := json.Marshal(map[string]any{"version": 1, "tui_launch_framework": h})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(config.SettingsPath(), b, 0600); err != nil {
		t.Fatal(err)
	}
	if got, err := config.ResolveTUILaunchFramework(); err != nil || got != h {
		t.Fatalf("launch preference = %s, %v", got, err)
	}
}

func readRuntimeBytes(t *testing.T, f *os.File, want string) {
	t.Helper()
	f.SetReadDeadline(time.Now().Add(time.Second))
	b := make([]byte, len(want))
	_, err := io.ReadFull(f, b)
	if err != nil || string(b) != want {
		t.Fatalf("input = %q, %v; want %q", b, err, want)
	}
}

func TestRuntimeHarnessMixedSendPeekAndVerification(t *testing.T) {
	m := runtimeModel(t)
	readers := map[string]*os.File{}
	for h, rows := range map[string][]string{"codex": cxComposerRows, "claude-code": ccComposerRows} {
		p, r := runtimePanel(t, h, rows)
		m.sessionPanels[h] = p
		readers[h] = r
		m.localSessions[h] = liveSession{harness: h}
	}
	var sends []session.SendRequest
	var peeks []session.PeekRequest
	for _, h := range []string{"codex", "claude-code"} {
		sends = append(sends, session.SendRequest{RequestID: h, Slug: h, Body: "continue"})
		peeks = append(peeks, session.PeekRequest{RequestID: h, Slug: h})
	}
	m, cmd := m.handlePeekRequestScan(peekRequestScanMsg{matched: peeks})
	runJournalCmds(t, cmd)
	for _, h := range []string{"codex", "claude-code"} {
		b, err := os.ReadFile(filepath.Join(session.PeekResponsesDir(m.sessionsDir), h+".json"))
		if err != nil {
			t.Fatal(err)
		}
		var p session.PeekResponse
		if err = json.Unmarshal(b, &p); err != nil {
			t.Fatal(err)
		}
		if !p.Ready {
			t.Fatalf("%s peek refused: %s", h, p.BlockedReason)
		}
	}
	m, _ = m.handleSendRequestScan(sendRequestScanMsg{matched: sends})
	for _, h := range []string{"codex", "claude-code"} {
		if _, ok := m.pendingSendVerify[h]; !ok {
			t.Fatalf("%s send did not pass production gate", h)
		}
		seq, ok, err := config.HarnessSubmitSequence(h)
		if !ok || err != nil {
			t.Fatalf("submit contract: %v", err)
		}
		readRuntimeBytes(t, readers[h], "continue"+seq)
	}
	// A later launch preference must not change the runtime's post-send matcher.
	setRuntimeLaunchDefault(t, "codex")
	p, _ := runtimePanel(t, "claude-code", ccPasteChipComposerRows)
	m.sessionPanels["claude-code"] = p
	if got := m.observeSendState(p); got != obsPending {
		t.Fatalf("pending Claude draft = %v", got)
	}
	m, _ = m.advanceSendVerifications()
	if _, ok := m.pendingSendVerify["codex"]; ok {
		t.Fatal("Codex submission not confirmed")
	}
	if _, ok := m.pendingSendVerify["claude-code"]; !ok {
		t.Fatal("Claude held draft incorrectly confirmed")
	}
}

func TestRuntimeHarnessMixedAnswersAndModalObservation(t *testing.T) {
	m := runtimeModel(t)
	var requests []session.AnswerRequest
	readers := map[string]*os.File{}
	for h, rows := range map[string][]string{"codex": cxOptionSelectRows, "claude-code": ccOptionSelectRows} {
		p, r := runtimePanel(t, h, rows)
		m.sessionPanels[h] = p
		readers[h] = r
		m.localSessions[h] = liveSession{harness: h}
		requests = append(requests, session.AnswerRequest{RequestID: h, Slug: h, Option: 1, Expect: "Choose the next step"})
		obs := m.observeModal(p)
		if !obs.blocked || obs.framework != h || obs.numberedModal == nil {
			t.Fatalf("%s modal = %+v", h, obs)
		}
		if !m.observeClose(p).interactive() {
			t.Fatalf("%s close missed modal", h)
		}
	}
	m, _ = m.handleAnswerRequestScan(answerRequestScanMsg{matched: requests})
	if len(m.pendingAnswerVerify) != 2 {
		t.Fatalf("mixed answer writes = %d", len(m.pendingAnswerVerify))
	}
	readRuntimeBytes(t, readers["codex"], "\x1b[A\r")
	readRuntimeBytes(t, readers["claude-code"], "\r")
	setRuntimeLaunchDefault(t, "codex")
	if obs := m.observeModal(m.sessionPanels["claude-code"]); !obs.blocked || obs.framework != "claude-code" {
		t.Fatalf("default changed runtime modal: %+v", obs)
	}
}

func TestRuntimeHarnessUnknownAndLegacyRefuseInput(t *testing.T) {
	for _, h := range []string{"", "unrecognized"} {
		t.Run("harness="+h, func(t *testing.T) {
			m := runtimeModel(t)
			p, r := runtimePanel(t, "demo", ccComposerRows)
			m.localSessions["demo"] = liveSession{harness: h}
			m.sessionPanels["demo"] = p
			m, cmd := m.handleSendRequestScan(sendRequestScanMsg{matched: []session.SendRequest{{RequestID: "send", Slug: "demo", Body: "no"}}})
			runJournalCmds(t, cmd)
			if len(m.pendingSendVerify) != 0 {
				t.Fatal("unknown runtime accepted send")
			}
			assertNoPTYBytes(t, r)
			p, r = runtimePanel(t, "demo", ccOptionSelectRows)
			m.sessionPanels["demo"] = p
			m, cmd = m.handleAnswerRequestScan(answerRequestScanMsg{matched: []session.AnswerRequest{{RequestID: "answer", Slug: "demo", Option: 1, Expect: "Choose the next step"}}})
			runJournalCmds(t, cmd)
			if len(m.pendingAnswerVerify) != 0 {
				t.Fatal("unknown runtime accepted answer")
			}
			assertNoPTYBytes(t, r)
			if obs := m.observeModal(p); obs.known {
				t.Fatalf("unknown runtime classified: %+v", obs)
			}
			if obs := m.observeClose(p); obs.screenKnown {
				t.Fatal("unknown close used default matcher")
			}
			p, _ = p.Update(work.StreamCompleteMsg{Slug: "demo"})
			if !m.observeClose(p).done {
				t.Fatal("unknown harness lost process completion")
			}
		})
	}
}

func TestRuntimeHarnessCloseUsesRuntimeAfterDefaultChanges(t *testing.T) {
	for _, h := range []string{"codex", "claude-code", "", "unknown"} {
		t.Run("harness="+h, func(t *testing.T) {
			m := runtimeModel(t)
			p, r := runtimePanel(t, "demo", ccComposerRows)
			proc := exec.Command("sleep", "30")
			if err := proc.Start(); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { proc.Process.Kill(); proc.Wait() })
			p = p.SetPtmx(p.Ptmx(), proc, nil)
			m.localSessions["demo"] = liveSession{harness: h}
			m.closeGrace = time.Millisecond
			m.closePoll = time.Millisecond
			cmd := m.closeLadderCmd("demo", p, "close")
			setRuntimeLaunchDefault(t, "opencode")
			cmd()
			seq, supported, _ := config.HarnessGracefulExitSequence(h)
			if supported {
				readRuntimeBytes(t, r, seq)
			} else {
				assertNoPTYBytes(t, r)
			}
		})
	}
}

// Captured Codex 0.153.3 footer/composer from the refused live peek. The same
// captured screen is recognized as Codex, so no broader signature is necessary.
func TestRuntimeHarnessCodex153CapturedScreen(t *testing.T) {
	rows := []string{
		"• Waiting for background terminal (37s • esc to interrupt) · 1 background terminal running · /ps to view · /stop to close",
		"  └ lore prefetch topic --scale-set architecture,subsystem", "", "",
		"› Ask Codex to do anything", "",
		"  gpt-6-astra high · ~/.lore/repos/github.com/anticorrelator/lore/_sessions/worktrees/20260904T234124Z-f30af344",
	}
	snap := work.ScreenSnapshot{Rows: rows}
	if ready, why := sendReadiness("codex", false, true, true, snap); !ready {
		t.Fatalf("captured Codex refused: %s", why)
	}
	if ready, why := sendReadiness("claude-code", false, true, true, snap); ready || why != sendReasonNoSignature {
		t.Fatalf("wrong harness = %v, %s", ready, why)
	}
}

func TestRuntimeHarnessAdoptedPeekRedaction(t *testing.T) {
	m := runtimeModel(t)
	// Use the same adoption metadata conversion as recovery, with a different
	// launch preference and a faint Claude composer placeholder.
	m.localSessions["recovered"] = (adoptedSession{harness: "claude-code", slug: "recovered"}).liveSession()
	setRuntimeLaunchDefault(t, "codex")
	p, _ := runtimePanel(t, "recovered", ccGhostRows)
	p, _ = p.Update(work.TerminalOutputMsg{Slug: "recovered", Data: []byte("\x1b[2J\x1b[H" + strings.ReplaceAll(ccGhostANSI, "\n", "\r\n"))})
	m.sessionPanels["recovered"] = p
	_, cmd := m.handlePeekRequestScan(peekRequestScanMsg{matched: []session.PeekRequest{{Slug: "recovered", RequestID: "redact"}}})
	runJournalCmds(t, cmd)
	b, err := os.ReadFile(filepath.Join(session.PeekResponsesDir(m.sessionsDir), "redact.json"))
	if err != nil {
		t.Fatal(err)
	}
	var resp session.PeekResponse
	if err = json.Unmarshal(b, &resp); err != nil {
		t.Fatal(err)
	}
	if !resp.Ready || strings.Contains(strings.Join(resp.Rows, "\n"), "commit this") {
		t.Fatalf("recovered peek = %+v", resp)
	}
}

func TestRuntimeHarnessModalRegistrationUsesObservedRuntime(t *testing.T) {
	m := runtimeModel(t)
	p, _ := runtimePanel(t, "demo", cxAdditionalSafetyRows)
	m.localSessions["demo"] = liveSession{harness: "codex"}
	m.sessionPanels["demo"] = p
	previous := matchModalAnswer
	t.Cleanup(func() { matchModalAnswer = previous })
	seen := ""
	matchModalAnswer = func(framework string, signature config.NumberedModalSignature) (config.ModalAnswerRegistration, bool) {
		seen = framework
		if signature.Title != "Additional safety checks" {
			t.Fatalf("wrong signature: %+v", signature)
		}
		return config.ModalAnswerRegistration{}, false
	}
	m, _ = m.advanceModalObservations()
	if seen != "codex" || !m.sessionModalBlocked["demo"] {
		t.Fatalf("registration framework=%q latch=%v", seen, m.sessionModalBlocked)
	}
}
