package main

import (
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/sessionview"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// sessionsContractModel builds a stateSessions model with one local session
// (with a live panel to attach) and one cross-instance session, for the
// sessions-view keybind contract tests.
func sessionsContractModel(t *testing.T) model {
	t.Helper()
	m := minimalModel(stateSessions, nil, nil)
	m.width = 120
	m.height = 40
	m.instanceName = "inst-a"
	m.setSessionPanel("impl-foo", work.NewSessionPanelModel("impl-foo"))
	m.sessionsList.SetSessions([]sessionview.SessionRow{
		{RowID: "inst-a|impl-foo|sid1", PanelKey: "impl-foo", Slug: "impl-foo", Display: "impl-foo",
			Type: "implement", Initiator: "human", Instance: "inst-a", Local: true, SessionID: "sid1"},
		{RowID: "inst-b|other|sid2", Slug: "other", Display: "other",
			Type: "spec", Initiator: "agent", Instance: "inst-b", Local: false, SessionID: "sid2", Tmux: "other-tmux"},
	})
	m.sessionsPanelCallbacks().resize()
	return m
}

func remoteMirrorContractModel(t *testing.T) model {
	t.Helper()
	m := minimalModel(stateSessions, nil, nil)
	m.width, m.height = 120, 40
	m.sessionsList.SetSessions([]sessionview.SessionRow{
		{RowID: "inst-b|one|sid1", Slug: "one", Display: "one", Instance: "inst-b", SessionID: "sid1", Tmux: "tmux-one"},
		{RowID: "inst-c|two|sid2", Slug: "two", Display: "two", Instance: "inst-c", SessionID: "sid2", Tmux: "tmux-two"},
	})
	m.sessionsPanelCallbacks().resize()
	return m
}

func TestSessionsRemoteMirrorOwnershipContract(t *testing.T) {
	m := remoteMirrorContractModel(t)
	nm, cmd := updateModel(t, m, sessionview.SessionSelectedMsg{RowID: "inst-b|one|sid1"})
	if cmd == nil {
		t.Fatal("explicit remote drill-in should open a mirror generation")
	}
	if !nm.sessionMirrorActive || nm.sessionMirrorRowID != "inst-b|one|sid1" || nm.sessionMirrorGeneration != 1 {
		t.Fatalf("remote mirror ownership = active:%v row:%q generation:%d", nm.sessionMirrorActive, nm.sessionMirrorRowID, nm.sessionMirrorGeneration)
	}
	panel, ok := nm.currentSessionsPanel()
	if !ok || !panel.IsMirror() || panel.TmuxName() != "tmux-one" {
		t.Fatalf("current sessions panel = mirror:%v tmux:%q ok:%v", panel.IsMirror(), panel.TmuxName(), ok)
	}
	if _, stored := nm.sessionPanels["one"]; stored {
		t.Fatal("remote mirror must stay outside the owned-session panel map")
	}

	// Re-entering the same target reuses the generation and does not reopen it.
	nm, cmd = updateModel(t, nm, sessionview.SessionSelectedMsg{RowID: "inst-b|one|sid1"})
	if cmd != nil || nm.sessionMirrorGeneration != 1 {
		t.Fatalf("same-target drill should reuse generation 1, got generation=%d cmd=%v", nm.sessionMirrorGeneration, cmd != nil)
	}

	// Cursor movement is passive: it can hide the panel but cannot acquire or
	// replace a pipe. Only the second explicit selection switches targets.
	nm, _ = updateModel(t, nm, press('j'))
	if !nm.sessionMirrorActive || nm.sessionMirrorRowID != "inst-b|one|sid1" || nm.sessionMirrorGeneration != 1 {
		t.Fatal("passive cursor movement changed the active mirror")
	}
	nm.sessionsList.SetCursorByID("inst-c|two|sid2")
	nm, cmd = updateModel(t, nm, sessionview.SessionSelectedMsg{RowID: "inst-c|two|sid2"})
	if cmd == nil || !nm.sessionMirrorActive || nm.sessionMirrorRowID != "inst-c|two|sid2" || nm.sessionMirrorGeneration != 2 {
		t.Fatalf("target switch = active:%v row:%q generation:%d cmd:%v", nm.sessionMirrorActive, nm.sessionMirrorRowID, nm.sessionMirrorGeneration, cmd != nil)
	}
	if nm.sessionMirrorPanel.TmuxName() != "tmux-two" {
		t.Fatalf("target switch opened %q, want tmux-two", nm.sessionMirrorPanel.TmuxName())
	}
}

func TestSessionsRemoteMirrorRoutingAndCloseContract(t *testing.T) {
	m := remoteMirrorContractModel(t)
	m, _ = updateModel(t, m, sessionview.SessionSelectedMsg{RowID: "inst-b|one|sid1"})

	t.Run("generation messages route to root panel", func(t *testing.T) {
		nm, _ := updateModel(t, m, work.SessionMirrorOpenedMsg{
			Slug:       "inst-b|one|sid1",
			TmuxName:   "tmux-one",
			Generation: 1,
			Err:        fmt.Errorf("open failed"),
		})
		if got := nm.sessionMirrorPanel.MirrorError(); got != "open failed" {
			t.Fatalf("root mirror error = %q", got)
		}
		if len(nm.sessionPanels) != 0 {
			t.Fatal("mirror message mutated the owned-session panel map")
		}
	})

	t.Run("detail toggling preserves mirror", func(t *testing.T) {
		nm, _ := updateModel(t, m, press('t', tea.ModCtrl))
		if nm.terminalMode || !nm.sessionMirrorActive {
			t.Fatalf("first ctrl+t should show detail without closing mirror: terminal=%v active=%v", nm.terminalMode, nm.sessionMirrorActive)
		}
		nm, _ = updateModel(t, nm, press('t', tea.ModCtrl))
		if !nm.terminalMode || !nm.sessionMirrorActive {
			t.Fatalf("second ctrl+t should restore mirror: terminal=%v active=%v", nm.terminalMode, nm.sessionMirrorActive)
		}
	})

	t.Run("mirror-only close leaves remote row", func(t *testing.T) {
		nm, cmd := updateModel(t, m, work.TerminalTerminateMsg{Slug: "inst-b|one|sid1"})
		if cmd != nil || nm.sessionMirrorActive || nm.terminalMode || nm.focusedPanel != panelLeft {
			t.Fatalf("mirror close = cmd:%v active:%v terminal:%v focus:%v", cmd != nil, nm.sessionMirrorActive, nm.terminalMode, nm.focusedPanel)
		}
		if _, ok := nm.sessionsList.SessionByID("inst-b|one|sid1"); !ok {
			t.Fatal("closing the mirror removed the remote session row")
		}
		if nm.confirmAction == "close_session" {
			t.Fatal("mirror-only close entered the remote-session close flow")
		}
	})

	t.Run("leaving sessions closes mirror", func(t *testing.T) {
		nm, _ := updateModel(t, m, press('t', tea.ModCtrl))
		nm.focusedPanel = panelLeft
		nm, _ = updateModel(t, nm, press('w'))
		if nm.state != stateWork || nm.sessionMirrorActive {
			t.Fatalf("leaving sessions = state:%v mirror-active:%v", nm.state, nm.sessionMirrorActive)
		}
	})
}

// TestSessionsEntryKeybindContract pins the `v` global entry key advertised in
// the tab indicator and the work/follow-ups status bars.
func TestSessionsEntryKeybindContract(t *testing.T) {
	t.Run("v (sessions)", func(t *testing.T) {
		nm, cmd := updateModel(t, workContractModel(), press('v'))
		if nm.state != stateSessions {
			t.Fatalf("v should enter the sessions view from work, got state %d", nm.state)
		}
		if cmd == nil {
			t.Error("v should dispatch the sessions refresh")
		}
		fm := minimalModel(stateFollowUps, nil, nil)
		fm.width, fm.height = 120, 40
		nfm, _ := updateModel(t, fm, press('v'))
		if nfm.state != stateSessions {
			t.Error("v should enter the sessions view from follow-ups")
		}
	})
}

// TestSessionsListStatusBarKeybindContract verifies the sessions list hint set:
// "j/k navigate · Enter attach · x close · h/Esc back · q quit · ? help".
func TestSessionsListStatusBarKeybindContract(t *testing.T) {
	t.Run("j/k (navigate)", func(t *testing.T) {
		m := sessionsContractModel(t)
		before := m.sessionsList.CurrentKey()
		nm, _ := updateModel(t, m, press('j'))
		if nm.sessionsList.CurrentKey() == before {
			t.Fatalf("j should move the cursor off %q", before)
		}
		nm, _ = updateModel(t, nm, press('k'))
		if nm.sessionsList.CurrentKey() != before {
			t.Errorf("k should return the cursor to %q, got %q", before, nm.sessionsList.CurrentKey())
		}
	})
	t.Run("Enter (attach)", func(t *testing.T) {
		m := sessionsContractModel(t)
		_, cmd := updateModel(t, m, press(tea.KeyEnter))
		if cmd == nil {
			t.Fatal("Enter should emit a selection command")
		}
		msg := cmd()
		if _, ok := msg.(sessionview.SessionSelectedMsg); !ok {
			t.Fatalf("Enter produced %T, want sessionview.SessionSelectedMsg", msg)
		}
		nm, _ := updateModel(t, m, msg)
		if nm.focusedPanel != panelRight {
			t.Error("selecting a session should focus the right panel")
		}
		if !nm.terminalMode {
			t.Error("selecting a local session with a live panel should enter terminal mode")
		}
	})
	t.Run("x (close)", func(t *testing.T) {
		m := sessionsContractModel(t)
		nm, _ := updateModel(t, m, press('x'))
		if nm.confirmAction != "close_session" {
			t.Fatalf("x should open the close-session confirm, got action %q", nm.confirmAction)
		}
		if nm.confirmSlug != "impl-foo" {
			t.Errorf("close confirm should target the current slug, got %q", nm.confirmSlug)
		}
	})
	t.Run("h (back)", func(t *testing.T) {
		nm, _ := updateModel(t, sessionsContractModel(t), press('h'))
		if nm.state != stateWork {
			t.Error("h on the sessions list should return to the work view")
		}
	})
	t.Run("Esc (back)", func(t *testing.T) {
		nm, _ := updateModel(t, sessionsContractModel(t), press(tea.KeyEscape))
		if nm.state != stateWork {
			t.Error("Esc on the sessions list should return to the work view")
		}
	})
	t.Run("q (quit)", func(t *testing.T) {
		_, cmd := updateModel(t, sessionsContractModel(t), press('q'))
		if cmd == nil {
			t.Fatal("q should quit")
		}
		if _, ok := cmd().(tea.QuitMsg); !ok {
			t.Error("q should dispatch tea.Quit")
		}
	})
}

// sessionsDetailModel focuses the read-only card on the cross-instance row.
func sessionsDetailModel(t *testing.T) model {
	t.Helper()
	m := sessionsContractModel(t)
	m, _ = updateModel(t, m, press('j')) // cursor → cross-instance row (no panel)
	m, _ = updateModel(t, m, press('l')) // focus the card
	return m
}

// TestSessionsDetailStatusBarKeybindContract verifies the read-only card hints:
// "x close · h/Esc back to list".
func TestSessionsDetailStatusBarKeybindContract(t *testing.T) {
	t.Run("x (close)", func(t *testing.T) {
		m := sessionsDetailModel(t)
		if m.focusedPanel != panelRight || m.terminalMode {
			t.Fatalf("card context requires right focus and non-terminal, got focus=%d terminal=%v", m.focusedPanel, m.terminalMode)
		}
		nm, _ := updateModel(t, m, press('x'))
		if nm.confirmAction != "close_session" {
			t.Fatalf("x should open the close-session confirm from the card, got %q", nm.confirmAction)
		}
		if nm.confirmSlug != "other" {
			t.Errorf("close confirm should target the card's slug, got %q", nm.confirmSlug)
		}
	})
	t.Run("h (back to list)", func(t *testing.T) {
		nm, _ := updateModel(t, sessionsDetailModel(t), press('h'))
		if nm.focusedPanel != panelLeft {
			t.Error("h on the card should focus back to the list")
		}
	})
}

// TestSessionsTerminalScrollbackContract pins the terminal-history contract
// through the first-class sessions workspace. The work view already exercises
// the same SessionPanelModel, but the sessions view has its own list identity,
// attachment transition, and panel callbacks — a routing regression here can
// leave the shared backend healthy while scrollback appears dead to the user.
func TestSessionsTerminalScrollbackContract(t *testing.T) {
	m := sessionsContractModel(t)
	m, _ = updateModel(t, m, tea.WindowSizeMsg{Width: 120, Height: 40})

	var out strings.Builder
	for i := 0; i < 100; i++ {
		fmt.Fprintf(&out, "session output line %02d\r\n", i)
	}
	m, _ = updateModel(t, m, work.TerminalOutputMsg{Slug: "impl-foo", Data: []byte(out.String())})

	// Enter attaches the selected local session and focuses its terminal.
	_, cmd := updateModel(t, m, press(tea.KeyEnter))
	if cmd == nil {
		t.Fatal("Enter should emit a session selection")
	}
	m, _ = updateModel(t, m, cmd())
	if !m.terminalMode || m.focusedPanel != panelRight {
		t.Fatalf("session should be attached before scrollback: terminal=%v focus=%v", m.terminalMode, m.focusedPanel)
	}

	t.Run("Shift+PgUp", func(t *testing.T) {
		nm, _ := updateModel(t, m, press(tea.KeyPgUp, tea.ModShift))
		panel, ok := nm.currentSessionsPanel()
		if !ok {
			t.Fatal("attached session panel disappeared")
		}
		if !strings.Contains(stripANSI(panel.View()), "-- scrollback (") {
			t.Fatal("Shift+PgUp did not enter session scrollback")
		}
	})

	t.Run("mouse wheel", func(t *testing.T) {
		nm, _ := updateModel(t, m, tea.MouseWheelMsg{Button: tea.MouseWheelUp, X: 90, Y: 20})
		panel, ok := nm.currentSessionsPanel()
		if !ok {
			t.Fatal("attached session panel disappeared")
		}
		if !strings.Contains(stripANSI(panel.View()), "-- scrollback (") {
			t.Fatal("wheel up over sessions terminal did not enter scrollback")
		}
	})
}

// TestSessionsCloseAddressesSluglessBySessionID verifies D7 addressing: a slugged
// session closes by slug, a slugless one by --session <id>, and a row with
// neither is refused rather than closed blindly.
func TestSessionsCloseAddressesSluglessBySessionID(t *testing.T) {
	base := minimalModel(stateSessions, nil, nil)
	base.width, base.height = 120, 40
	base.instanceName = "inst-a"

	t.Run("slugless addresses by session id", func(t *testing.T) {
		m := base
		m.sessionsList.SetSessions([]sessionview.SessionRow{
			{RowID: "inst-a||sid9", Slug: "", Display: "chat:sid9", Type: "chat",
				Instance: "inst-a", Local: true, SessionID: "sid9abcd"},
		})
		m.sessionsPanelCallbacks().resize()
		nm, _ := updateModel(t, m, press('x'))
		if nm.confirmAction != "close_session" {
			t.Fatalf("x should open the close confirm, got %q", nm.confirmAction)
		}
		if nm.confirmSlug != "" {
			t.Errorf("slugless close must not carry a slug, got %q", nm.confirmSlug)
		}
		if nm.confirmSessionID != "sid9abcd" {
			t.Errorf("slugless close should carry the session id, got %q", nm.confirmSessionID)
		}
	})

	t.Run("unaddressable row is refused", func(t *testing.T) {
		m := base
		m.sessionsList.SetSessions([]sessionview.SessionRow{
			{RowID: "inst-a||", Slug: "", Display: "chat:?", Type: "chat", Instance: "inst-a", Local: true},
		})
		m.sessionsPanelCallbacks().resize()
		nm, _ := updateModel(t, m, press('x'))
		if nm.confirmAction == "close_session" {
			t.Error("a row with no slug and no session id must not open a close confirm")
		}
		if nm.flashErr == "" {
			t.Error("an unaddressable close should surface a flash error")
		}
	})

	t.Run("in-flight spawn cannot be closed", func(t *testing.T) {
		m := base
		m.sessionsList.SetSessions([]sessionview.SessionRow{
			{RowID: "inflight|r1", Slug: "impl-bar", Display: "impl-bar", Type: "implement", InFlight: true},
		})
		m.sessionsPanelCallbacks().resize()
		nm, _ := updateModel(t, m, press('x'))
		if nm.confirmAction == "close_session" {
			t.Error("an in-flight spawn has no live session to close")
		}
	})
}

// TestBuildSessionRowsUnionsSubstrates verifies the three-substrate union: a
// registry session, an in-flight queue request, and a journal-derived activity
// overlay all surface, with a queued slug already live in the registry dropped.
func TestBuildSessionRowsUnionsSubstrates(t *testing.T) {
	m := minimalModel(stateSessions, nil, nil)
	m.instanceName = "inst-a"
	m.sessionActivity = map[sessionview.ActivityKey]sessionview.Activity{
		{Instance: "inst-a", Slug: "impl-foo--w1"}: {NeedsInput: true},
	}
	instances := []session.Instance{
		{Name: "inst-a", Sessions: []session.Session{
			{Slug: "impl-foo--w1", Type: "worker", Initiator: "agent", SessionID: "sidw1"},
		}},
		{Name: "inst-b", Sessions: []session.Session{
			{Slug: "", Type: "chat", Initiator: "human", SessionID: "deadbeefcafef00d"},
		}},
	}
	pending := []session.Request{
		{RequestID: "r-new", Type: "implement", Slug: strptr("impl-bar")},
		{RequestID: "r-dup", Type: "worker", Slug: strptr("impl-foo--w1")}, // already live → dropped
	}
	rows := m.buildSessionRows(instances, pending, nil)

	byDisplay := map[string]sessionview.SessionRow{}
	for _, r := range rows {
		byDisplay[r.Display] = r
	}
	worker, ok := byDisplay["impl-foo--w1"]
	if !ok {
		t.Fatal("registry worker session missing from union")
	}
	if !worker.Local || worker.BaseItem != "impl-foo" || !worker.NeedsInput {
		t.Errorf("worker row wrong: local=%v base=%q needsInput=%v", worker.Local, worker.BaseItem, worker.NeedsInput)
	}
	if _, ok := byDisplay["chat:deadbeef"]; !ok {
		t.Errorf("slugless cross-instance session should compose chat:<8hex>, got rows %v", displays(rows))
	}
	if r, ok := byDisplay["impl-bar"]; !ok || !r.InFlight {
		t.Errorf("in-flight queue request should surface as a spawning row")
	}
	dupCount := 0
	for _, r := range rows {
		if r.Display == "impl-foo--w1" {
			dupCount++
		}
	}
	if dupCount != 1 {
		t.Errorf("a queued slug already live in the registry must be dropped, got %d rows for impl-foo--w1", dupCount)
	}
}

func displays(rows []sessionview.SessionRow) []string {
	out := make([]string, 0, len(rows))
	for _, r := range rows {
		out = append(out, r.Display)
	}
	return out
}

func strptr(s string) *string { return &s }
