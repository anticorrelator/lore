package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/coordination"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/sessionview"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// coordinationContractModel builds a stateCoordination model with two arcs and
// a loaded arc detail for the keybind contract tests.
func coordinationContractModel(t *testing.T) model {
	t.Helper()
	m := minimalModel(stateCoordination, []work.WorkItem{
		{Slug: "item-a", Title: "Item A", Project: "arc-a", Status: "active"},
		{Slug: "item-b", Title: "Item B", Project: "arc-b", Status: "active"},
	}, nil)
	m.width, m.height = 120, 40
	m.coordinationList.SetArcs([]coordination.Arc{{Slug: "arc-a", Members: 1}, {Slug: "arc-b", Members: 1}})
	m.coordinationDetail.SetArc("arc-a")
	m.coordinationDetail.SetLedger("## Brief\n\nlanded: mirror\n", "landed: mirror", true)
	m.coordinationDetail.SetPin(coordination.PinAbsent, nil)
	m.coordinationPanelCallbacks().resize()
	return m
}

// TestCoordinationEntryKeybindContract pins the `o` entry key advertised in
// the tab indicator and the work/sessions/settlement status bars, and that
// chat keeps `c` in its two contexts (work-detail focus, follow-ups).
func TestCoordinationEntryKeybindContract(t *testing.T) {
	t.Run("o (coordination)", func(t *testing.T) {
		nm, cmd := updateModel(t, workContractModel(), press('o'))
		if nm.state != stateCoordination {
			t.Fatalf("o from the work list should enter coordination, got state %d", nm.state)
		}
		if cmd == nil {
			t.Error("entering coordination should dispatch the arc scan")
		}
		if nm.focusedPanel != panelLeft {
			t.Error("coordination should open list-focused")
		}

		sm := sessionsContractModel(t)
		nsm, _ := updateModel(t, sm, press('o'))
		if nsm.state != stateCoordination {
			t.Error("o from the sessions list should enter coordination")
		}

		stm := minimalModel(stateSettlement, nil, nil)
		stm.width, stm.height = 120, 40
		nstm, _ := updateModel(t, stm, press('o'))
		if nstm.state != stateCoordination {
			t.Error("o from settlement should enter coordination")
		}
	})
	t.Run("c stays chat in the work detail focus", func(t *testing.T) {
		m := workContractModel()
		m.focusedPanel = panelRight
		_, cmd := updateModel(t, m, press('c'))
		if cmd == nil {
			t.Fatal("c on the work detail should emit a chat request")
		}
		if _, ok := cmd().(work.ChatRequestMsg); !ok {
			t.Fatalf("c produced %T, want work.ChatRequestMsg", cmd())
		}
	})
	t.Run("o with zero arcs opens the explicit empty state", func(t *testing.T) {
		m := workContractModel()
		nm, _ := updateModel(t, m, press('o'))
		if nm.state != stateCoordination {
			t.Fatal("o should enter coordination even with zero arcs")
		}
		if out := stripANSI(nm.viewContent()); !strings.Contains(out, "No coordination arcs") {
			t.Errorf("zero-arc coordination view must render its empty state:\n%s", out)
		}
	})
}

// TestCoordinationListStatusBarKeybindContract verifies the coordination list
// hint set: "j/k navigate · l/Enter detail · w work list · f follow-ups ·
// v sessions · t settlement · h/Esc back · q quit · ? help".
func TestCoordinationListStatusBarKeybindContract(t *testing.T) {
	t.Run("j/k (navigate)", func(t *testing.T) {
		m := coordinationContractModel(t)
		nm, _ := updateModel(t, m, press('j'))
		if nm.coordinationList.CurrentSlug() != "arc-b" {
			t.Fatalf("j should move the cursor, got %q", nm.coordinationList.CurrentSlug())
		}
		nm, _ = updateModel(t, nm, press('k'))
		if nm.coordinationList.CurrentSlug() != "arc-a" {
			t.Errorf("k should return the cursor, got %q", nm.coordinationList.CurrentSlug())
		}
	})
	t.Run("l (detail)", func(t *testing.T) {
		nm, _ := updateModel(t, coordinationContractModel(t), press('l'))
		if nm.focusedPanel != panelRight {
			t.Error("l should focus the detail panel")
		}
	})
	t.Run("Enter (detail)", func(t *testing.T) {
		m := coordinationContractModel(t)
		_, cmd := updateModel(t, m, press(tea.KeyEnter))
		if cmd == nil {
			t.Fatal("Enter should emit a selection command")
		}
		msg := cmd()
		sel, ok := msg.(coordination.ArcSelectedMsg)
		if !ok {
			t.Fatalf("Enter produced %T, want coordination.ArcSelectedMsg", msg)
		}
		nm, _ := updateModel(t, m, msg)
		if nm.focusedPanel != panelRight {
			t.Error("selecting an arc should focus the detail panel")
		}
		if nm.coordinationDetail.Arc() != sel.Slug {
			t.Errorf("selection should load the arc detail, got %q", nm.coordinationDetail.Arc())
		}
	})
	t.Run("w (work list)", func(t *testing.T) {
		nm, _ := updateModel(t, coordinationContractModel(t), press('w'))
		if nm.state != stateWork {
			t.Error("w should return to the work view")
		}
	})
	t.Run("f (follow-ups)", func(t *testing.T) {
		nm, _ := updateModel(t, coordinationContractModel(t), press('f'))
		if nm.state != stateFollowUps {
			t.Error("f should enter follow-ups")
		}
	})
	t.Run("v (sessions)", func(t *testing.T) {
		nm, _ := updateModel(t, coordinationContractModel(t), press('v'))
		if nm.state != stateSessions {
			t.Error("v should enter the sessions view")
		}
	})
	t.Run("t (settlement)", func(t *testing.T) {
		nm, _ := updateModel(t, coordinationContractModel(t), press('t'))
		if nm.state != stateSettlement {
			t.Error("t should enter settlement")
		}
	})
	t.Run("h (back)", func(t *testing.T) {
		nm, _ := updateModel(t, coordinationContractModel(t), press('h'))
		if nm.state != stateWork {
			t.Error("h on the arc list should return to the work view")
		}
	})
	t.Run("Esc (back)", func(t *testing.T) {
		nm, _ := updateModel(t, coordinationContractModel(t), press(tea.KeyEscape))
		if nm.state != stateWork {
			t.Error("Esc on the arc list should return to the work view")
		}
	})
	t.Run("q (quit)", func(t *testing.T) {
		_, cmd := updateModel(t, coordinationContractModel(t), press('q'))
		if cmd == nil {
			t.Fatal("q should quit")
		}
		if _, ok := cmd().(tea.QuitMsg); !ok {
			t.Error("q should dispatch tea.Quit")
		}
	})
}

// TestCoordinationDetailKeybindContract verifies the arc detail's advertised
// keys through the real Update path: tab cycling, sessions-tab j/k, the close
// verb, and back-to-list.
func TestCoordinationDetailKeybindContract(t *testing.T) {
	detailFocused := func(t *testing.T) model {
		m := coordinationContractModel(t)
		m.focusedPanel = panelRight
		return m
	}
	t.Run("Tab (cycle tabs)", func(t *testing.T) {
		m := detailFocused(t)
		if m.coordinationDetail.ActiveTabID() != coordination.TabStatus {
			t.Fatalf("detail should open on Status, got %q", m.coordinationDetail.ActiveTabID())
		}
		nm, _ := updateModel(t, m, press(tea.KeyTab))
		if nm.coordinationDetail.ActiveTabID() != coordination.TabSessions {
			t.Errorf("Tab should cycle Status→Sessions, got %q", nm.coordinationDetail.ActiveTabID())
		}
	})
	t.Run("j/k (sessions)", func(t *testing.T) {
		m := detailFocused(t)
		m.coordinationDetail.SetSessions([]sessionview.SessionRow{
			{RowID: "r1", Display: "a-sess", Local: true},
			{RowID: "r2", Display: "b-sess", Local: true},
		})
		m, _ = updateModel(t, m, press(tea.KeyTab)) // Status → Sessions
		nm, _ := updateModel(t, m, press('j'))
		if row, ok := nm.coordinationDetail.CurrentSession(); !ok || row.RowID != "r2" {
			t.Errorf("j on the Sessions tab should move the session cursor, got %+v", row)
		}
	})
	t.Run("x (close)", func(t *testing.T) {
		m := detailFocused(t)
		m.coordinationDetail.SetSessions([]sessionview.SessionRow{
			{RowID: "r1", Slug: "impl-a", Display: "impl-a", SessionID: "sid1", Local: true},
		})
		m, _ = updateModel(t, m, press(tea.KeyTab)) // Status → Sessions
		nm, _ := updateModel(t, m, press('x'))
		if nm.confirmAction != "close_session" || nm.confirmSlug != "impl-a" {
			t.Errorf("x on the Sessions tab should open the close confirm for the selected session, got %q/%q", nm.confirmAction, nm.confirmSlug)
		}
	})
	t.Run("h (back to list)", func(t *testing.T) {
		nm, _ := updateModel(t, detailFocused(t), press('h'))
		if nm.focusedPanel != panelLeft {
			t.Error("h should refocus the arc list")
		}
	})
	// itemsTab returns a detail-focused model with two members and the Items
	// tab active, ready for the Items-tab drill-in subtests.
	itemsTab := func(t *testing.T) model {
		t.Helper()
		m := detailFocused(t)
		m.coordinationDetail.SetMembers([]work.WorkItem{
			{Slug: "item-a", Title: "Item A", Status: "active"},
			{Slug: "item-b", Title: "Item B", Status: "active"},
		}, nil)
		m, _ = updateModel(t, m, press(tea.KeyTab)) // Status → Sessions
		m, _ = updateModel(t, m, press(tea.KeyTab)) // Sessions → Items
		if got := stripANSI(strings.Join(m.statusBarHints(m.keymapContext()), " · ")); !strings.Contains(got, "open item") {
			t.Fatalf("Items tab should advertise l/Enter open item, got %q", got)
		}
		return m
	}
	t.Run("j/k (items)", func(t *testing.T) {
		m := itemsTab(t)
		nm, _ := updateModel(t, m, press('j'))
		if it, ok := nm.coordinationDetail.CurrentItem(); !ok || it.Slug != "item-b" {
			t.Errorf("j on the Items tab should move the item cursor, got %+v", it)
		}
		nm, _ = updateModel(t, nm, press('k'))
		if it, ok := nm.coordinationDetail.CurrentItem(); !ok || it.Slug != "item-a" {
			t.Errorf("k on the Items tab should return the item cursor, got %+v", it)
		}
	})
	assertOpenItem := func(t *testing.T, key tea.KeyPressMsg) {
		t.Helper()
		m := itemsTab(t)
		_, cmd := updateModel(t, m, key)
		if cmd == nil {
			t.Fatal("open item should emit a member selection command")
		}
		msg := cmd()
		sel, ok := msg.(coordination.MemberSelectedMsg)
		if !ok || sel.Slug != "item-a" {
			t.Fatalf("open item produced %T (%v), want coordination.MemberSelectedMsg{item-a}", msg, msg)
		}
		nm, _ := updateModel(t, m, msg)
		if nm.state != stateWork {
			t.Errorf("member selection should enter the work view, got state %d", nm.state)
		}
		if !nm.returnToCoordination {
			t.Error("member drill-in should arm the coordination return")
		}
		if nm.list.CurrentSlug() != "item-a" {
			t.Errorf("member drill-in should carry the work list cursor to item-a, got %q", nm.list.CurrentSlug())
		}
	}
	t.Run("l (open item)", func(t *testing.T) { assertOpenItem(t, press('l')) })
	t.Run("Enter (open item)", func(t *testing.T) { assertOpenItem(t, press(tea.KeyEnter)) })

	// sessionsTab returns a detail-focused model on the Sessions tab with one
	// row present in both the coordination detail and the sessions workspace
	// list (the attach hand-off resolves the row there).
	sessionsTab := func(t *testing.T) model {
		t.Helper()
		m := detailFocused(t)
		m.coordinationDetail.SetSessions([]sessionview.SessionRow{
			{RowID: "r1", Display: "impl-a", Local: true},
		})
		m.sessionsList.SetSessions([]sessionview.SessionRow{
			{RowID: "r1", PanelKey: "impl-a", Display: "impl-a", Local: true},
		})
		m, _ = updateModel(t, m, press(tea.KeyTab)) // Status → Sessions
		if got := stripANSI(strings.Join(m.statusBarHints(m.keymapContext()), " · ")); !strings.Contains(got, "open session") {
			t.Fatalf("Sessions tab should advertise l/Enter open session, got %q", got)
		}
		return m
	}
	assertOpenSession := func(t *testing.T, key tea.KeyPressMsg) {
		t.Helper()
		m := sessionsTab(t)
		_, cmd := updateModel(t, m, key)
		if cmd == nil {
			t.Fatal("open session should emit a session selection command")
		}
		msg := cmd()
		sel, ok := msg.(coordination.SessionSelectedMsg)
		if !ok || sel.RowID != "r1" {
			t.Fatalf("open session produced %T (%v), want coordination.SessionSelectedMsg{r1}", msg, msg)
		}
		nm, _ := updateModel(t, m, msg)
		if nm.state != stateSessions {
			t.Errorf("session selection should enter the sessions workspace, got state %d", nm.state)
		}
		if !nm.returnToCoordination {
			t.Error("session drill-in should arm the coordination return")
		}
		if nm.focusedPanel != panelRight {
			t.Error("session drill-in should focus the landing surface")
		}
	}
	t.Run("l (open session)", func(t *testing.T) { assertOpenSession(t, press('l')) })
	t.Run("Enter (open session)", func(t *testing.T) { assertOpenSession(t, press(tea.KeyEnter)) })
}

// TestCoordinationDrillInReturnKeybindContract pins the one-shot return: after a
// coordination drill-in the landing surface's back hint reads "coordination" and
// its back seam re-enters the coordination view, clearing the return target.
func TestCoordinationDrillInReturnKeybindContract(t *testing.T) {
	t.Run("work detail back hint reads coordination and Esc returns", func(t *testing.T) {
		m := coordinationContractModel(t)
		m.focusedPanel = panelRight
		m.coordinationDetail.SetMembers([]work.WorkItem{{Slug: "item-a", Status: "active"}}, nil)
		m, _ = updateModel(t, m, press(tea.KeyTab)) // Status → Sessions
		m, _ = updateModel(t, m, press(tea.KeyTab)) // Sessions → Items
		_, cmd := updateModel(t, m, press(tea.KeyEnter))
		m, _ = updateModel(t, m, cmd()) // land in the work detail
		if m.state != stateWork || !m.returnToCoordination {
			t.Fatalf("drill-in should land in work with the return armed, got state %d flag %v", m.state, m.returnToCoordination)
		}
		if got := stripANSI(strings.Join(m.statusBarHints(m.keymapContext()), " · ")); !strings.Contains(got, "coordination") {
			t.Errorf("armed work-detail back hint should read coordination, got %q", got)
		}
		nm, _ := updateModel(t, m, press(tea.KeyEscape))
		if nm.state != stateCoordination {
			t.Fatalf("one Esc should return to coordination, got state %d", nm.state)
		}
		if nm.returnToCoordination {
			t.Error("returning should clear the one-shot return target")
		}
		if nm.focusedPanel != panelRight {
			t.Error("return should re-enter coordination with the detail focused")
		}
	})
	t.Run("sessions list back hint reads coordination and Esc returns", func(t *testing.T) {
		m := coordinationContractModel(t)
		m.focusedPanel = panelRight
		m.coordinationDetail.SetSessions([]sessionview.SessionRow{{RowID: "r1", Display: "impl-a", Local: true}})
		m.sessionsList.SetSessions([]sessionview.SessionRow{{RowID: "r1", PanelKey: "impl-a", Display: "impl-a", Local: true}})
		m, _ = updateModel(t, m, press(tea.KeyTab)) // Status → Sessions
		_, cmd := updateModel(t, m, press(tea.KeyEnter))
		m, _ = updateModel(t, m, cmd()) // land in the sessions workspace
		if m.state != stateSessions || !m.returnToCoordination {
			t.Fatalf("drill-in should land in sessions with the return armed, got state %d flag %v", m.state, m.returnToCoordination)
		}
		// The workspace-exit hint (and its coordination redirect) live on the list.
		m.focusedPanel = panelLeft
		if got := stripANSI(strings.Join(m.statusBarHints(m.keymapContext()), " · ")); !strings.Contains(got, "coordination") {
			t.Errorf("armed sessions back hint should read coordination, got %q", got)
		}
		nm, _ := updateModel(t, m, press(tea.KeyEscape))
		if nm.state != stateCoordination {
			t.Fatalf("Esc from the sessions list should return to coordination, got state %d", nm.state)
		}
		if nm.returnToCoordination {
			t.Error("returning should clear the one-shot return target")
		}
	})
	t.Run("explicit state switch clears the pending return", func(t *testing.T) {
		m := coordinationContractModel(t)
		m.focusedPanel = panelRight
		m.coordinationDetail.SetMembers([]work.WorkItem{{Slug: "item-a", Status: "active"}}, nil)
		m, _ = updateModel(t, m, press(tea.KeyTab))
		m, _ = updateModel(t, m, press(tea.KeyTab))
		_, cmd := updateModel(t, m, press(tea.KeyEnter))
		m, _ = updateModel(t, m, cmd()) // land in the work detail, return armed
		nm, _ := updateModel(t, m, press('v'))
		if nm.state != stateSessions {
			t.Fatalf("v should switch to the sessions view, got state %d", nm.state)
		}
		if nm.returnToCoordination {
			t.Error("an explicit state switch should clear the pending coordination return")
		}
	})
}

// TestCoordinationArcScanSyncsDetail pins the cursor-identity-driven detail
// sync: an arc scan landing while the view is open points the detail at the
// arc under the cursor, and a scan for an unchanged selection is a no-op.
func TestCoordinationArcScanSyncsDetail(t *testing.T) {
	m := minimalModel(stateCoordination, nil, nil)
	m.width, m.height = 120, 40
	nm, cmd := updateModel(t, m, coordinationArcsScannedMsg{arcs: []coordination.Arc{{Slug: "arc-a", Members: 1}}})
	if nm.coordinationDetail.Arc() != "arc-a" {
		t.Fatalf("scan should sync the detail to the cursor arc, got %q", nm.coordinationDetail.Arc())
	}
	if cmd == nil {
		t.Error("first sync should dispatch the ledger and pin reads")
	}
	nm2, cmd2 := updateModel(t, nm, coordinationArcsScannedMsg{arcs: []coordination.Arc{{Slug: "arc-a", Members: 1}}})
	if cmd2 != nil {
		t.Error("a scan with an unchanged selection should not re-dispatch reads")
	}
	_ = nm2
}

// arcHomeFixture writes a project home for arc under workDir, seeding
// coordination.md and (when report is non-nil) report.md, each stamped with the
// given mtime so the recency derivation is deterministic. A nil ledger skips
// coordination.md entirely, standing in for a missing/unreadable ledger.
func arcHomeFixture(t *testing.T, workDir, arc string, ledger, report *string, ledgerMod, reportMod time.Time) {
	t.Helper()
	home := work.ProjectHome(workDir, arc)
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	if ledger != nil {
		p := filepath.Join(home, "coordination.md")
		if err := os.WriteFile(p, []byte(*ledger), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(p, ledgerMod, ledgerMod); err != nil {
			t.Fatal(err)
		}
	}
	if report != nil {
		p := filepath.Join(home, "report.md")
		if err := os.WriteFile(p, []byte(*report), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(p, reportMod, reportMod); err != nil {
			t.Fatal(err)
		}
	}
}

// TestReadArcLedgerDerivesClosed pins the live-vs-closed derivation in the
// host's single ledger-read command across every classification boundary.
func TestReadArcLedgerDerivesClosed(t *testing.T) {
	ledger := "## Brief\n\nthe brief\n"
	report := "# Report\n\nthe report\n"
	early := time.Date(2026, 7, 20, 9, 0, 0, 0, time.UTC)
	late := time.Date(2026, 7, 20, 10, 0, 0, 0, time.UTC)

	run := func(t *testing.T, setup func(t *testing.T, workDir string)) coordinationLedgerReadMsg {
		t.Helper()
		workDir := t.TempDir()
		setup(t, workDir)
		msg, ok := readArcLedgerCmd(workDir, "arc-a")().(coordinationLedgerReadMsg)
		if !ok {
			t.Fatal("readArcLedgerCmd must return a coordinationLedgerReadMsg")
		}
		return msg
	}

	t.Run("report strictly newer is closed", func(t *testing.T) {
		msg := run(t, func(t *testing.T, wd string) {
			arcHomeFixture(t, wd, "arc-a", &ledger, &report, early, late)
		})
		if !msg.closed || !msg.reportFound {
			t.Fatalf("newer report must classify closed with the report present: %+v", msg)
		}
		if msg.report != report || msg.brief != "the brief" {
			t.Errorf("both files must be delivered in one message: %+v", msg)
		}
	})

	t.Run("ledger newer is live", func(t *testing.T) {
		msg := run(t, func(t *testing.T, wd string) {
			arcHomeFixture(t, wd, "arc-a", &ledger, &report, late, early)
		})
		if msg.closed {
			t.Errorf("a ledger newer than the report must stay live: %+v", msg)
		}
		if !msg.reportFound {
			t.Errorf("the report must still be reachable while live: %+v", msg)
		}
	})

	t.Run("equal mtimes is live", func(t *testing.T) {
		msg := run(t, func(t *testing.T, wd string) {
			arcHomeFixture(t, wd, "arc-a", &ledger, &report, early, early)
		})
		if msg.closed {
			t.Errorf("equal mtimes must resolve to live: %+v", msg)
		}
	})

	t.Run("missing report is live", func(t *testing.T) {
		msg := run(t, func(t *testing.T, wd string) {
			arcHomeFixture(t, wd, "arc-a", &ledger, nil, early, time.Time{})
		})
		if msg.closed || msg.reportFound {
			t.Errorf("a home without report.md must be live with no report: %+v", msg)
		}
	})

	t.Run("report beside a missing ledger is closed", func(t *testing.T) {
		msg := run(t, func(t *testing.T, wd string) {
			arcHomeFixture(t, wd, "arc-a", nil, &report, time.Time{}, late)
		})
		if !msg.closed || !msg.reportFound {
			t.Fatalf("a report beside an unreadable ledger must classify closed: %+v", msg)
		}
		if msg.err == nil {
			t.Errorf("an unreadable ledger must still surface its read error: %+v", msg)
		}
	})
}

// TestBuildSessionRowsProjectJoin pins the in-memory session→project join: a
// session's own slug resolves through the index, a derived worker slug falls
// back to its base item, and an unresolvable slug joins no project.
func TestBuildSessionRowsProjectJoin(t *testing.T) {
	m := minimalModel(stateWork, []work.WorkItem{
		{Slug: "impl-a", Project: "arc-a"},
	}, nil)
	m.instanceName = "inst-a"
	rows := m.buildSessionRows([]session.Instance{{
		Name: "inst-b",
		Sessions: []session.Session{
			{Slug: "impl-a", Type: "implement", SessionID: "s1"},
			{Slug: "impl-a--w2", Type: "worker", SessionID: "s2"},
			{Slug: "stray", Type: "chat", SessionID: "s3"},
		},
	}}, nil, nil)
	got := map[string]string{}
	for _, r := range rows {
		got[r.Slug] = r.Project
	}
	if got["impl-a"] != "arc-a" {
		t.Errorf("slug join failed: %q", got["impl-a"])
	}
	if got["impl-a--w2"] != "arc-a" {
		t.Errorf("derived-worker base join failed: %q", got["impl-a--w2"])
	}
	if got["stray"] != "" {
		t.Errorf("unresolvable slug must join no project: %q", got["stray"])
	}
}

// TestCoordinationSessionsJoinFiltersByArc pins the per-refresh arc filter:
// only rows whose Project matches the selected arc reach the detail.
func TestCoordinationSessionsJoinFiltersByArc(t *testing.T) {
	m := coordinationContractModel(t)
	m.sessionRows = []sessionview.SessionRow{
		{RowID: "r1", Display: "impl-a", Project: "arc-a"},
		{RowID: "r2", Display: "impl-b", Project: "arc-b"},
		{RowID: "r3", Display: "stray", Project: ""},
	}
	m.syncCoordinationSessions()
	m.focusedPanel = panelRight
	m, _ = updateModel(t, m, press(tea.KeyTab)) // Status → Sessions
	out := stripANSI(m.viewContent())
	if !strings.Contains(out, "impl-a") {
		t.Errorf("the arc's session must render:\n%s", out)
	}
	if strings.Contains(out, "impl-b") || strings.Contains(out, "stray") {
		t.Errorf("other arcs' and unjoined sessions must not render:\n%s", out)
	}
}

// TestCoordinationViewComposesBothLayouts smoke-tests the compositor arm: the
// coordination view renders through the shared split-pane in both layout
// modes with its list title, tab row section, and detail tabs.
func TestCoordinationViewComposesBothLayouts(t *testing.T) {
	for _, layout := range []config.LayoutMode{config.LayoutLeftRight, config.LayoutTopBottom} {
		m := coordinationContractModel(t)
		m.layoutMode = layout
		m.coordinationPanelCallbacks().resize()
		out := stripANSI(m.viewContent())
		for _, want := range []string{"Arcs", "arc-a", "coordination (2)", "Status", "Sessions", "Items", "Ledger"} {
			if !strings.Contains(out, want) {
				t.Errorf("layout %v: coordination view missing %q:\n%s", layout, want, out)
			}
		}
	}
}
