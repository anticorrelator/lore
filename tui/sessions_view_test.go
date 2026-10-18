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

// sessionsContractModel builds a stateSessions model with two sessions of the
// store: one with an open viewer, and one with no tmux name, which cannot be
// viewed, for the sessions-view keybind contract tests.
func sessionsContractModel(t *testing.T) model {
	t.Helper()
	m := minimalModel(stateSessions, nil, nil)
	m.width = 120
	m.height = 40
	rows := []sessionview.SessionRow{
		{RowID: "store-host|impl-foo|sid1", PanelKey: "impl-foo", Slug: "impl-foo", Display: "impl-foo",
			Type: "implement", Initiator: "human", Instance: "store-host", Local: true, SessionID: "sid1", Tmux: "lore-store-host-impl-foo"},
		{RowID: "store-host|other|sid2", PanelKey: "other", Slug: "other", Display: "other (not viewable)",
			Type: "spec", Initiator: "agent", Instance: "store-host", Local: true, SessionID: "sid2"},
	}
	m.sessionRows = rows
	m.sessionsList.SetSessions(rows)
	m.sessionsPanelCallbacks().resize()
	m, _ = m.openViewer(rows[0])
	return m
}

func viewerContractModel(t *testing.T) model {
	t.Helper()
	m := minimalModel(stateSessions, nil, nil)
	m.width, m.height = 120, 40
	rows := []sessionview.SessionRow{
		{RowID: "store-host|one|sid1", PanelKey: "one", Slug: "one", Display: "one", Instance: "store-host", Local: true, SessionID: "sid1", Tmux: "tmux-one"},
		{RowID: "store-host|two|sid2", PanelKey: "two", Slug: "two", Display: "two", Instance: "store-host", Local: true, SessionID: "sid2", Tmux: "tmux-two"},
	}
	m.sessionRows = rows
	m.sessionsList.SetSessions(rows)
	m.sessionsPanelCallbacks().resize()
	return m
}

// TestSessionsViewerOwnershipContract: Enter opens a viewer on the selected
// session, outside the owned-session panel map; re-entering reuses it, cursor
// movement opens nothing, and a second session gets a viewer of its own while
// the first stays open.
func TestSessionsViewerOwnershipContract(t *testing.T) {
	m := viewerContractModel(t)
	nm, cmd := updateModel(t, m, sessionview.SessionSelectedMsg{RowID: "store-host|one|sid1"})
	if cmd == nil {
		t.Fatal("selecting a session should start its viewer's attach")
	}
	first, ok := nm.viewers["one"]
	if !ok || !first.panel.IsViewer() || first.panel.TmuxName() != "tmux-one" {
		t.Fatalf("viewer = %#v ok=%v", first.panel.TmuxName(), ok)
	}
	panel, ok := nm.currentSessionsPanel()
	if !ok || !panel.IsViewer() || !nm.terminalMode || nm.focusedPanel != panelRight {
		t.Fatalf("current sessions panel = viewer:%v ok:%v terminal:%v", panel.IsViewer(), ok, nm.terminalMode)
	}
	if _, stored := nm.sessionPanels["one"]; stored {
		t.Fatal("a viewer must stay outside the owned-session panel map")
	}

	nm, cmd = updateModel(t, nm, sessionview.SessionSelectedMsg{RowID: "store-host|one|sid1"})
	if cmd != nil || nm.viewers["one"].panel.ViewerGeneration() != first.panel.ViewerGeneration() {
		t.Fatal("re-entering a session should reuse its viewer")
	}

	nm.focusedPanel = panelLeft
	nm, _ = updateModel(t, nm, press('j'))
	if _, opened := nm.viewers["two"]; opened {
		t.Fatal("passive cursor movement opened a viewer")
	}
	nm, cmd = updateModel(t, nm, sessionview.SessionSelectedMsg{RowID: "store-host|two|sid2"})
	if cmd == nil || nm.viewers["two"].panel.TmuxName() != "tmux-two" {
		t.Fatal("selecting the second session should open its viewer")
	}
	if _, kept := nm.viewers["one"]; !kept {
		t.Fatal("opening a second viewer closed the first")
	}
}

func TestSessionsViewerRoutingAndCloseContract(t *testing.T) {
	// Each subtest gets its own model: copies of one share the viewers map.
	opened := func(t *testing.T) model {
		t.Helper()
		m, _ := updateModel(t, viewerContractModel(t), sessionview.SessionSelectedMsg{RowID: "store-host|one|sid1"})
		return m
	}

	t.Run("viewer messages route to the viewer by key", func(t *testing.T) {
		m := opened(t)
		v := m.viewers["one"]
		nm, _ := updateModel(t, m, work.ViewerEndedMsg{Slug: "one", TmuxName: "tmux-one", Generation: v.panel.ViewerGeneration(), Reason: work.ViewerAttachFailed, Err: fmt.Errorf("no tmux session")})
		if !nm.viewers["one"].panel.IsDone() || nm.viewers["one"].panel.ViewerEndReason() != work.ViewerAttachFailed {
			t.Fatal("viewer did not take its end message")
		}
		if len(nm.sessionPanels) != 0 {
			t.Fatal("viewer message mutated the owned-session panel map")
		}
	})

	t.Run("detail toggling preserves the viewer", func(t *testing.T) {
		nm, _ := updateModel(t, opened(t), press('t', tea.ModCtrl))
		if _, ok := nm.viewers["one"]; nm.terminalMode || !ok {
			t.Fatalf("first ctrl+t should show detail without closing the viewer: terminal=%v", nm.terminalMode)
		}
		nm, _ = updateModel(t, nm, press('t', tea.ModCtrl))
		if !nm.terminalMode {
			t.Fatal("second ctrl+t should restore the viewer")
		}
	})

	t.Run("closing the viewer leaves the session", func(t *testing.T) {
		m := opened(t)
		v := m.viewers["one"]
		nm, cmd := updateModel(t, m, work.ViewerTerminateMsg{Slug: "one", Generation: v.panel.ViewerGeneration()})
		if _, ok := nm.viewers["one"]; cmd != nil || ok || nm.terminalMode || nm.focusedPanel != panelLeft {
			t.Fatalf("viewer close = cmd:%v viewer:%v terminal:%v focus:%v", cmd != nil, ok, nm.terminalMode, nm.focusedPanel)
		}
		if _, ok := nm.sessionsList.SessionByID("store-host|one|sid1"); !ok {
			t.Fatal("closing the viewer removed the session row")
		}
		if nm.confirmAction == "close_session" {
			t.Fatal("closing a viewer entered the session close flow")
		}
	})

	t.Run("leaving sessions keeps the viewer", func(t *testing.T) {
		nm, _ := updateModel(t, opened(t), press('t', tea.ModCtrl))
		nm.focusedPanel = panelLeft
		nm, _ = updateModel(t, nm, press('w'))
		if _, ok := nm.viewers["one"]; nm.state != stateWork || !ok {
			t.Fatalf("leaving sessions = state:%v viewer:%v", nm.state, ok)
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
// "j/k navigate · l/Enter attach · x close · h/Esc back · q quit · ? help".
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
		if hints := stripANSI(strings.Join(m.statusBarHints(kmSessionsList), " · ")); !strings.Contains(hints, "l/Enter attach") {
			t.Fatalf("sessions list hints = %s", hints)
		}
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
			t.Error("selecting a session with an open viewer should enter terminal mode")
		}
	})
	t.Run("l (attach)", func(t *testing.T) {
		m := sessionsContractModel(t)
		delete(m.viewers, "impl-foo")
		nm, cmd := updateModel(t, m, press('l'))
		if _, ok := nm.viewers["impl-foo"]; !ok || cmd == nil || !nm.terminalMode || nm.focusedPanel != panelRight {
			t.Fatalf("l should open the session's viewer: viewer=%v attach=%v terminal=%v", ok, cmd != nil, nm.terminalMode)
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

// sessionsDetailModel focuses the read-only card on the row that cannot be viewed.
func sessionsDetailModel(t *testing.T) model {
	t.Helper()
	m := sessionsContractModel(t)
	m, _ = updateModel(t, m, press('j')) // cursor → the unviewable row (no panel)
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

	// Enter attaches the selected session's viewer and focuses its terminal.
	_, cmd := updateModel(t, m, press(tea.KeyEnter))
	if cmd == nil {
		t.Fatal("Enter should emit a session selection")
	}
	m, _ = updateModel(t, m, cmd())
	if !m.terminalMode || m.focusedPanel != panelRight {
		t.Fatalf("session should be attached before scrollback: terminal=%v focus=%v", m.terminalMode, m.focusedPanel)
	}
	// A viewer's history is the pane's, captured from the host's tmux server.
	history := func(t *testing.T, nm model) model {
		t.Helper()
		v := nm.viewers["impl-foo"]
		lines := make([]string, 100)
		for i := range lines {
			lines[i] = fmt.Sprintf("session output line %02d", i)
		}
		nm, _ = updateModel(t, nm, work.ViewerScrollbackMsg{Slug: "impl-foo", TmuxName: v.panel.TmuxName(), Generation: v.panel.ViewerGeneration(), Lines: lines})
		return nm
	}

	t.Run("Shift+PgUp", func(t *testing.T) {
		nm, capture := updateModel(t, m, press(tea.KeyPgUp, tea.ModShift))
		if capture == nil {
			t.Fatal("Shift+PgUp did not ask for the pane's history")
		}
		nm = history(t, nm)
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
		nm = history(t, nm)
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
			{Slug: "impl-foo--w1", Type: "worker", Initiator: "agent", SessionID: "sidw1", Tmux: "lore-inst-a-impl-foo--w1"},
		}},
		{Name: "inst-b", Sessions: []session.Session{
			{Slug: "", Type: "chat", Initiator: "human", SessionID: "deadbeefcafef00d", Tmux: "lore-inst-b-chat"},
			{Slug: "no-tmux", Type: "chat", Initiator: "human", SessionID: "sid-nt"},
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
	if r, ok := byDisplay["chat:deadbeef"]; !ok || !r.Local || r.PanelKey != "session:deadbeefcafef00d" {
		t.Errorf("slugless session should compose chat:<8hex> and key its viewer by session id, got rows %v", displays(rows))
	}
	if r, ok := byDisplay["no-tmux (not viewable)"]; !ok || r.Tmux != "" {
		t.Errorf("a session without tmux should say it cannot be viewed, got rows %v", displays(rows))
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
