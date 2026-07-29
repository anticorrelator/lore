package main

import (
	"fmt"
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
	m.coordinationList.SetArcs([]coordination.Arc{
		{Slug: "arc-a", Status: coordination.StatusActive, Items: 1, Members: []string{"item-a"}},
		{Slug: "arc-b", Status: coordination.StatusActive, Items: 1, Members: []string{"item-b"}},
	}, 0)
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
		m.coordinationDetail.SetMembers([]coordination.Member{
			{Slug: "item-a", Resolved: true, Item: work.WorkItem{Slug: "item-a", Title: "Item A", Status: "active"}},
			{Slug: "item-b", Resolved: true, Item: work.WorkItem{Slug: "item-b", Title: "Item B", Status: "active"}},
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
		m.coordinationDetail.SetMembers([]coordination.Member{{Slug: "item-a", Resolved: true, Item: work.WorkItem{Slug: "item-a", Status: "active"}}}, nil)
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
		m.coordinationDetail.SetMembers([]coordination.Member{{Slug: "item-a", Resolved: true, Item: work.WorkItem{Slug: "item-a", Status: "active"}}}, nil)
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
	nm, cmd := updateModel(t, m, coordinationArcsScannedMsg{arcs: []coordination.Arc{{Slug: "arc-a", Status: coordination.StatusActive, Items: 1}}})
	if nm.coordinationDetail.Arc() != "arc-a" {
		t.Fatalf("scan should sync the detail to the cursor arc, got %q", nm.coordinationDetail.Arc())
	}
	if cmd == nil {
		t.Error("first sync should dispatch the ledger and pin reads")
	}
	nm2, cmd2 := updateModel(t, nm, coordinationArcsScannedMsg{arcs: []coordination.Arc{{Slug: "arc-a", Status: coordination.StatusActive, Items: 1}}})
	if cmd2 != nil {
		t.Error("a scan with an unchanged selection should not re-dispatch reads")
	}
	_ = nm2
}

// arcStoreFixture writes an arc record under workDir/_arcs/, plus its ledger
// and (when report is non-nil) its report. The mtimes are stamped so tests can
// order the two files against each other; nothing in the read path consults
// them. A nil ledger skips coordination.md, standing in for an unreadable one.
func arcStoreFixture(t *testing.T, workDir, arc, status string, ledger, report *string, ledgerMod, reportMod time.Time) {
	t.Helper()
	dir := coordination.ArcDir(workDir, arc)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	rec := fmt.Sprintf(`{"schema_version":1,"slug":%q,"title":"Arc %s","status":%q,"members":[],"opened":"2026-07-20T09:00:00Z"}`, arc, arc, status)
	if err := os.WriteFile(filepath.Join(dir, "_meta.json"), []byte(rec), 0o644); err != nil {
		t.Fatal(err)
	}
	write := func(name string, body *string, mod time.Time) {
		if body == nil {
			return
		}
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(*body), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(p, mod, mod); err != nil {
			t.Fatal(err)
		}
	}
	write("coordination.md", ledger, ledgerMod)
	write("report.md", report, reportMod)
}

// TestReadArcLedgerReadsTheStoreAndNeverDerivesClosure pins that the ledger
// read targets the arc's own directory and carries no closure signal at all —
// the file timestamps it once compared are gone from the path.
func TestReadArcLedgerReadsTheStoreAndNeverDerivesClosure(t *testing.T) {
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

	t.Run("both documents arrive in one message", func(t *testing.T) {
		msg := run(t, func(t *testing.T, wd string) {
			arcStoreFixture(t, wd, "arc-a", "closed", &ledger, &report, early, late)
		})
		if msg.report != report || msg.brief != "the brief" || !msg.briefFound {
			t.Errorf("both documents must be delivered in one message: %+v", msg)
		}
		if !msg.reportFound {
			t.Errorf("a present report must be reported found: %+v", msg)
		}
	})

	t.Run("mtime order does not change the read", func(t *testing.T) {
		reportNewer := run(t, func(t *testing.T, wd string) {
			arcStoreFixture(t, wd, "arc-a", "closed", &ledger, &report, early, late)
		})
		ledgerNewer := run(t, func(t *testing.T, wd string) {
			arcStoreFixture(t, wd, "arc-a", "closed", &ledger, &report, late, early)
		})
		if reportNewer != ledgerNewer {
			t.Errorf("file order must not change the ledger read:\n%+v\n%+v", reportNewer, ledgerNewer)
		}
	})

	t.Run("missing report leaves the tab off", func(t *testing.T) {
		msg := run(t, func(t *testing.T, wd string) {
			arcStoreFixture(t, wd, "arc-a", "active", &ledger, nil, early, time.Time{})
		})
		if msg.reportFound {
			t.Errorf("an arc without report.md must report no report: %+v", msg)
		}
	})

	t.Run("unreadable ledger surfaces its error", func(t *testing.T) {
		msg := run(t, func(t *testing.T, wd string) {
			arcStoreFixture(t, wd, "arc-a", "closed", nil, &report, time.Time{}, late)
		})
		if msg.err == nil {
			t.Errorf("an unreadable ledger must surface its read error: %+v", msg)
		}
		if !msg.reportFound {
			t.Errorf("the report must still be reachable: %+v", msg)
		}
	})
}

// TestLateLedgerAppendNeverFlipsClosure is the regression the declared-status
// cutover exists for: appending to a closed arc's ledger after its report was
// written once flipped the Status tab back to the Brief. Closure now comes from
// the record, so the append changes nothing.
func TestLateLedgerAppendNeverFlipsClosure(t *testing.T) {
	workDir := t.TempDir()
	ledger := "## Brief\n\nthe brief\n"
	report := "# Report\n\nthe closing report\n"
	arcStoreFixture(t, workDir, "arc-a", "closed", &ledger, &report,
		time.Date(2026, 7, 20, 9, 0, 0, 0, time.UTC),
		time.Date(2026, 7, 20, 10, 0, 0, 0, time.UTC))

	m := minimalModel(stateCoordination, nil, nil)
	m.width, m.height = 120, 40
	m.config.WorkDir = workDir

	scan, ok := m.scanArcStoreCmd()().(coordinationArcsScannedMsg)
	if !ok {
		t.Fatal("scanArcStoreCmd must return a coordinationArcsScannedMsg")
	}
	m, _ = updateModel(t, m, scan)
	m, _ = updateModel(t, m, readArcLedgerCmd(workDir, "arc-a")())
	if out := stripANSI(m.coordinationDetail.View()); !strings.Contains(out, "the closing report") {
		t.Fatalf("a closed arc must lead its Status tab with the report:\n%s", out)
	}

	// The sanctioned late append: the ledger is now the newest file on disk.
	p := filepath.Join(coordination.ArcDir(workDir, "arc-a"), "coordination.md")
	if err := os.WriteFile(p, []byte(ledger+"\n- a row added after the close\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(p, time.Now(), time.Now()); err != nil {
		t.Fatal(err)
	}

	scan2, _ := m.scanArcStoreCmd()().(coordinationArcsScannedMsg)
	m, _ = updateModel(t, m, scan2)
	m, _ = updateModel(t, m, readArcLedgerCmd(workDir, "arc-a")())
	out := stripANSI(m.coordinationDetail.View())
	if !strings.Contains(out, "the closing report") {
		t.Errorf("a late ledger append must not flip a closed arc back to its Brief:\n%s", out)
	}
}

// TestQuitOffersArcArchiveForClosedArcs pins the close-time affordance: `q`
// with a closed arc present holds the quit and offers the archive, an
// untouched offer quits without writing, and ctrl+c never sees it.
func TestQuitOffersArcArchiveForClosedArcs(t *testing.T) {
	arcs := []coordination.Arc{
		{Slug: "live", Status: coordination.StatusActive},
		{Slug: "done", Status: coordination.StatusClosed},
	}

	t.Run("q opens the offer instead of quitting", func(t *testing.T) {
		m := minimalModel(stateCoordination, nil, nil)
		m.width, m.height = 120, 40
		m.coordinationList.SetArcs(arcs, 0)
		nm, cmd := updateModel(t, m, press('q'))
		if !nm.arcArchiveActive {
			t.Fatal("q with a closed arc present should open the archive offer")
		}
		if cmd != nil {
			t.Error("the offer must hold the quit, not race it")
		}
		if len(nm.selectedArchiveSlugs()) != 0 {
			t.Error("the offer must open with nothing selected")
		}
		if out := stripANSI(nm.viewContent()); !strings.Contains(out, "Archive closed arcs?") || !strings.Contains(out, "done") {
			t.Errorf("the offer should list the closed arcs:\n%s", out)
		}
		if strings.Contains(stripANSI(nm.viewContent()), "live") {
			t.Error("an active arc is not archivable and must not be offered")
		}
	})

	t.Run("Enter with nothing selected quits without archiving", func(t *testing.T) {
		m := minimalModel(stateCoordination, nil, nil)
		m.width, m.height = 120, 40
		m.coordinationList.SetArcs(arcs, 0)
		m, _ = updateModel(t, m, press('q'))
		nm, cmd := updateModel(t, m, press(tea.KeyEnter))
		if nm.arcArchiveActive {
			t.Error("Enter should close the offer")
		}
		if cmd == nil {
			t.Fatal("Enter should quit")
		}
		if _, isQuit := cmd().(tea.QuitMsg); !isQuit {
			t.Error("an empty selection must quit directly, running no archive")
		}
	})

	t.Run("Esc declines and quits", func(t *testing.T) {
		m := minimalModel(stateCoordination, nil, nil)
		m.width, m.height = 120, 40
		m.coordinationList.SetArcs(arcs, 0)
		m, _ = updateModel(t, m, press('q'))
		nm, cmd := updateModel(t, m, press(tea.KeyEscape))
		if nm.arcArchiveActive || cmd == nil {
			t.Error("Esc should decline the offer and quit")
		}
	})

	t.Run("space selects the arc under the cursor", func(t *testing.T) {
		m := minimalModel(stateCoordination, nil, nil)
		m.width, m.height = 120, 40
		m.coordinationList.SetArcs(arcs, 0)
		m, _ = updateModel(t, m, press('q'))
		m, _ = updateModel(t, m, press(' '))
		if got := m.selectedArchiveSlugs(); len(got) != 1 || got[0] != "done" {
			t.Errorf("space should toggle the cursor arc, got %v", got)
		}
	})

	t.Run("no closed arcs means no offer", func(t *testing.T) {
		m := minimalModel(stateCoordination, nil, nil)
		m.width, m.height = 120, 40
		m.coordinationList.SetArcs([]coordination.Arc{{Slug: "live", Status: coordination.StatusActive}}, 0)
		nm, cmd := updateModel(t, m, press('q'))
		if nm.arcArchiveActive {
			t.Error("with nothing closed, q should quit straight away")
		}
		if cmd == nil {
			t.Fatal("q should quit")
		}
	})

	t.Run("ctrl+c bypasses the offer", func(t *testing.T) {
		m := minimalModel(stateCoordination, nil, nil)
		m.width, m.height = 120, 40
		m.coordinationList.SetArcs(arcs, 0)
		nm, cmd := updateModel(t, m, tea.KeyPressMsg{Code: 'c', Mod: tea.ModCtrl})
		if nm.arcArchiveActive {
			t.Error("ctrl+c must never see the archive offer")
		}
		if cmd == nil {
			t.Fatal("ctrl+c should quit")
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

// TestCoordinationSessionsJoinFiltersByArc pins the per-refresh membership
// join: a session reaches the detail when the arc declares its slug, or the
// base item of its derived worker slug. The project label never joins — it is
// the label that let unrelated work look like membership.
func TestCoordinationSessionsJoinFiltersByArc(t *testing.T) {
	m := coordinationContractModel(t)
	m.sessionRows = []sessionview.SessionRow{
		{RowID: "r1", Display: "impl-a", Slug: "item-a"},
		{RowID: "r4", Display: "worker-a", Slug: "item-a-w1", BaseItem: "item-a"},
		{RowID: "r2", Display: "impl-b", Slug: "item-b"},
		{RowID: "r3", Display: "stray", Project: "arc-a"},
	}
	m.syncCoordinationSessions()
	m.focusedPanel = panelRight
	m, _ = updateModel(t, m, press(tea.KeyTab)) // Status → Sessions
	out := stripANSI(m.viewContent())
	if !strings.Contains(out, "impl-a") {
		t.Errorf("a declared member's session must render:\n%s", out)
	}
	if !strings.Contains(out, "worker-a") {
		t.Errorf("a derived worker must join through its base item:\n%s", out)
	}
	if strings.Contains(out, "impl-b") {
		t.Errorf("another arc's member must not render:\n%s", out)
	}
	if strings.Contains(out, "stray") {
		t.Errorf("a session carrying only the project label is not a member:\n%s", out)
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
