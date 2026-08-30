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
	"github.com/anticorrelator/lore/tui/internal/coordination/board"
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
	m.coordinationList.SetAttention(board.Attention{
		board.ActNow: {
			{Bucket: board.ActNow, Arc: "arc-a", StreamID: "s1", Label: "Run item A", Gate: "hold", Status: "pending", Verdict: "unknown"},
			{Bucket: board.ActNow, Arc: "arc-b", StreamID: "s2", Label: "Run item B", Gate: "flag", Status: "pending", Verdict: "unknown"},
		},
		board.NeedsJudgment: {}, board.Waiting: {}, board.Reconcile: {},
	}, nil)
	m.coordinationDetail.SetArc("arc-a")
	m.syncCoordinationMembers()
	m.coordinationDetail.SetLedger("## Brief\n\nlanded: mirror\n", "landed: mirror", true)
	m.coordinationDetail.SetBoard([]board.Row{{
		Arc: "arc-a", StreamID: "s1", Label: "Run item A", Gate: "notify",
		Status: "pending", Verdict: "unknown", WorkItem: strptrMain("item-a"),
	}}, true, nil)
	m.coordinationPanelCallbacks().resize()
	return m
}

// TestCoordinationEntryKeybindContract pins the `o` entry key advertised in
// the tab indicator and the work/sessions status bars, and that chat keeps `c`
// in its two contexts (work-detail focus, follow-ups).
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
// v sessions · h/Esc back · q quit · ? help".
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
	t.Run("a (attention focus)", func(t *testing.T) {
		m := coordinationContractModel(t)
		nm, _ := updateModel(t, m, press('a'))
		if !nm.coordinationList.AttentionFocused() {
			t.Fatal("a should move top-pane focus to attention")
		}
		if got := stripANSI(strings.Join(nm.statusBarHints(nm.keymapContext()), " · ")); !strings.Contains(got, "a arc list") || !strings.Contains(got, "Enter jump") {
			t.Errorf("focused attention hints should advertise return and exact jump, got %q", got)
		}
		if got := stripANSI(nm.buildPaneConfig().listTitle); got != "Attention" {
			t.Errorf("swapped pane title = %q, want Attention", got)
		}
	})
	t.Run("h/Esc close attention before leaving coordination", func(t *testing.T) {
		for _, key := range []tea.KeyPressMsg{press('h'), press(tea.KeyEscape)} {
			m := coordinationContractModel(t)
			m, _ = updateModel(t, m, press('a'))
			nm, _ := updateModel(t, m, key)
			if nm.state != stateCoordination || nm.coordinationList.AttentionFocused() {
				t.Errorf("%s should restore the arc listing in place: state=%v attention=%v", key.String(), nm.state, nm.coordinationList.AttentionFocused())
			}
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
	t.Run("t (no longer a state switch)", func(t *testing.T) {
		nm, _ := updateModel(t, coordinationContractModel(t), press('t'))
		if nm.state != stateCoordination {
			t.Errorf("t should no longer switch views, got state %d", nm.state)
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

func TestCoordinationAttentionSelectionJumpsByExactIdentity(t *testing.T) {
	m := coordinationContractModel(t)
	m, _ = updateModel(t, m, press('a'))
	m, _ = updateModel(t, m, press('j'))
	_, cmd := updateModel(t, m, press(tea.KeyEnter))
	if cmd == nil {
		t.Fatal("Enter on attention should emit an exact jump")
	}
	selected, ok := cmd().(coordination.AttentionSelectedMsg)
	if !ok || selected.Arc != "arc-b" || selected.StreamID != "s2" {
		t.Fatalf("attention selection = %#v (%T), want arc-b/s2", cmd(), cmd())
	}
	m, load := updateModel(t, m, selected)
	if m.focusedPanel != panelRight || m.coordinationList.AttentionFocused() || m.coordinationList.CurrentSlug() != "arc-b" || m.coordinationDetail.Arc() != "arc-b" || load == nil {
		t.Fatalf("jump did not set exact arc and detail focus: focus=%v cursor=%q detail=%q cmd=%v", m.focusedPanel, m.coordinationList.CurrentSlug(), m.coordinationDetail.Arc(), load)
	}
	m, _ = updateModel(t, m, coordinationBodyReadMsg{arc: "arc-b", boardFound: true, rows: []board.Row{
		{Arc: "arc-b", StreamID: "neighbor", Label: "Neighbor", Gate: "notify", Status: "pending", Verdict: "unknown"},
		{Arc: "arc-b", StreamID: "s2", Label: "Exact", Gate: "flag", Status: "pending", Verdict: "unknown"},
	}})
	if got := m.coordinationDetail.SelectedStream(); got != "s2" {
		t.Fatalf("body generation selected %q, want exact stream s2", got)
	}
	if m.coordinationJump == nil || m.coordinationTargetIssue != "" {
		t.Fatalf("successful exact jump did not retain its refresh guard: jump=%v issue=%q", m.coordinationJump, m.coordinationTargetIssue)
	}
}

func TestCoordinationAttentionStaleTargetsNeverSelectNeighbors(t *testing.T) {
	t.Run("stream disappeared", func(t *testing.T) {
		m := coordinationContractModel(t)
		selected := coordination.AttentionSelectedMsg{Bucket: board.ActNow, Arc: "arc-a", StreamID: "gone"}
		m, _ = updateModel(t, m, selected)
		m, _ = updateModel(t, m, coordinationBodyReadMsg{arc: "arc-a", boardFound: true, rows: []board.Row{{
			Arc: "arc-a", StreamID: "neighbor", Label: "Neighbor", Gate: "notify", Status: "pending", Verdict: "unknown",
		}}})
		if got := m.coordinationDetail.SelectedStream(); got != "" {
			t.Fatalf("stale stream selected neighbor %q", got)
		}
		if !strings.Contains(m.coordinationTargetIssue, "stream gone is absent from arc arc-a") {
			t.Fatalf("stale stream issue was not explicit: %q", m.coordinationTargetIssue)
		}
	})

	t.Run("arc disappeared", func(t *testing.T) {
		m := coordinationContractModel(t)
		m, _ = updateModel(t, m, coordination.AttentionSelectedMsg{Bucket: board.Waiting, Arc: "gone-arc", StreamID: "s9"})
		if m.coordinationList.CurrentSlug() != "arc-a" {
			t.Fatalf("stale arc moved the cursor onto %q", m.coordinationList.CurrentSlug())
		}
		if m.coordinationDetail.Arc() != "gone-arc" || !strings.Contains(m.coordinationTargetIssue, "not in the visible arc list") {
			t.Fatalf("stale arc was not retained explicitly: detail=%q issue=%q", m.coordinationDetail.Arc(), m.coordinationTargetIssue)
		}
	})
}

// TestCoordinationDetailKeybindContract verifies integrated-body selection,
// declared-target routing, and local document drill-ins through the real host.

func strptrMain(value string) *string { return &value }

func TestCoordinationDetailKeybindContract(t *testing.T) {
	detailFocused := func(t *testing.T) model {
		m := coordinationContractModel(t)
		m.focusedPanel = panelRight
		return m
	}

	t.Run("j/k (streams)", func(t *testing.T) {
		m := detailFocused(t)
		m.coordinationDetail.SetBoard([]board.Row{
			{Arc: "arc-a", StreamID: "s1", Label: "First", Gate: "notify", Status: "done", Verdict: "full"},
			{Arc: "arc-a", StreamID: "s2", Label: "Second", DependsOn: []string{"s1"}, Gate: "notify", Status: "pending", Verdict: "unknown"},
		}, true, nil)
		nm, _ := updateModel(t, m, press('j'))
		if got := nm.coordinationDetail.SelectedStream(); got != "s2" {
			t.Fatalf("j should select s2, got %q", got)
		}
		nm, _ = updateModel(t, nm, press('k'))
		if got := nm.coordinationDetail.SelectedStream(); got != "s1" {
			t.Errorf("k should return to s1, got %q", got)
		}
	})

	t.Run("l / Enter (open target)", func(t *testing.T) {
		for _, key := range []tea.KeyPressMsg{press('l'), press(tea.KeyEnter)} {
			m := detailFocused(t)
			m.coordinationDetail.SetSessions([]sessionview.SessionRow{{RowID: "r1", Slug: "item-a", Display: "item-a", Local: true}})
			m.sessionsList.SetSessions([]sessionview.SessionRow{{RowID: "r1", Slug: "item-a", PanelKey: "item-a", Display: "item-a", Local: true}})
			_, cmd := updateModel(t, m, key)
			if cmd == nil {
				t.Fatal("open target should emit a session selection")
			}
			msg, ok := cmd().(coordination.SessionSelectedMsg)
			if !ok || msg.RowID != "r1" {
				t.Fatalf("open target produced %T %v", cmd(), cmd())
			}
			nm, _ := updateModel(t, m, msg)
			if nm.state != stateSessions || !nm.returnToCoordination {
				t.Errorf("session target should use the sessions workspace and arm return, state=%v return=%v", nm.state, nm.returnToCoordination)
			}
		}
	})

	t.Run("e (ledger drill-in)", func(t *testing.T) {
		m := detailFocused(t)
		nm, _ := updateModel(t, m, press('e'))
		if nm.coordinationDetail.Mode() != coordination.ModeLedger {
			t.Fatalf("e should open the ledger locally, got %q", nm.coordinationDetail.Mode())
		}
		if got := stripANSI(strings.Join(nm.statusBarHints(nm.keymapContext()), " · ")); !strings.Contains(got, "back to arc") {
			t.Errorf("drill-in hint should advertise local return, got %q", got)
		}
		nm, _ = updateModel(t, nm, press('h'))
		if nm.focusedPanel != panelRight || nm.coordinationDetail.Mode() != coordination.ModePrimary {
			t.Errorf("first h should return locally before leaving detail, focus=%v mode=%q", nm.focusedPanel, nm.coordinationDetail.Mode())
		}
		nm, _ = updateModel(t, nm, press('h'))
		if nm.focusedPanel != panelLeft {
			t.Error("second h should return to the arc list")
		}
	})

	t.Run("r (report drill-in)", func(t *testing.T) {
		m := detailFocused(t)
		m.coordinationDetail.SetReport("# Report\n\nEarlier\n", true)
		nm, _ := updateModel(t, m, press('r'))
		if nm.coordinationDetail.Mode() != coordination.ModeReport {
			t.Errorf("r should open a live report locally, got %q", nm.coordinationDetail.Mode())
		}
	})
}

func TestCoordinationSessionDrillUsesSessionsTerminalHost(t *testing.T) {
	m := coordinationContractModel(t)
	m.focusedPanel = panelRight
	remote := sessionview.SessionRow{
		RowID: "remote", Slug: "item-a", Display: "item-a", Instance: "other",
		Tmux: "lore-other-item-a",
	}
	m.coordinationDetail.SetSessions([]sessionview.SessionRow{remote})
	m.sessionsList.SetSessions([]sessionview.SessionRow{remote})

	_, cmd := updateModel(t, m, press(tea.KeyEnter))
	if cmd == nil {
		t.Fatal("explicit coordination drill should select the remote session")
	}
	nm, _ := updateModel(t, m, cmd())
	if nm.state != stateSessions || !nm.returnToCoordination || !nm.sessionMirrorActive {
		t.Fatalf("remote drill must use the sessions mirror owner: state=%v return=%v mirror=%v", nm.state, nm.returnToCoordination, nm.sessionMirrorActive)
	}
	cb := nm.coordinationPanelCallbacks()
	if cb.currentSlug() != "" {
		t.Fatalf("coordination terminal seam exposed slug %q", cb.currentSlug())
	}
	if _, ok := cb.sessionPanelFn(); ok {
		t.Fatal("coordination must not expose a terminal panel")
	}
}

func TestCoordinationDrillInReturnKeybindContract(t *testing.T) {
	m := coordinationContractModel(t)
	m.focusedPanel = panelRight
	_, cmd := updateModel(t, m, press(tea.KeyEnter))
	if cmd == nil {
		t.Fatal("row work fallback should emit a selection")
	}
	m, _ = updateModel(t, m, cmd())
	if m.state != stateWork || !m.returnToCoordination {
		t.Fatalf("work fallback should arm coordination return, state=%v return=%v", m.state, m.returnToCoordination)
	}
	nm, _ := updateModel(t, m, press(tea.KeyEscape))
	if nm.state != stateCoordination || nm.returnToCoordination || nm.focusedPanel != panelRight {
		t.Errorf("Esc should return to the preserved coordination detail, state=%v return=%v focus=%v", nm.state, nm.returnToCoordination, nm.focusedPanel)
	}
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
	if cmd2 == nil {
		t.Error("an unchanged scan should still refresh cross-arc attention")
	}
	_ = nm2
}

func TestCoordinationBodyReadDropsStaleArcGeneration(t *testing.T) {
	m := coordinationContractModel(t)
	stale := coordinationBodyReadMsg{
		arc: "arc-b", boardFound: true,
		rows: []board.Row{{Arc: "arc-b", StreamID: "wrong", Label: "Wrong arc", Gate: "notify", Status: "done", Verdict: "full"}},
	}
	nm, _ := updateModel(t, m, stale)
	if got := nm.coordinationDetail.SelectedStream(); got != "s1" {
		t.Fatalf("stale body response changed the selected arc generation to %q", got)
	}

	fresh := coordinationBodyReadMsg{
		arc: "arc-a", boardFound: true,
		rows: []board.Row{{Arc: "arc-a", StreamID: "fresh", Label: "Fresh", Gate: "notify", Status: "done", Verdict: "full"}},
	}
	nm, _ = updateModel(t, nm, fresh)
	if got := nm.coordinationDetail.SelectedStream(); got != "fresh" {
		t.Errorf("matching body response should land, got %q", got)
	}
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
	// The record opens now so the arc sits in the list's newest bucket: these
	// fixtures exercise the ledger and report projections, not the fold.
	opened := time.Now().Format(time.RFC3339)
	rec := fmt.Sprintf(`{"schema_version":1,"slug":%q,"title":"Arc %s","status":%q,"members":[],"opened":%q}`, arc, arc, status, opened)
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
// written once flipped the primary body back to the Brief. Closure now comes from
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
	if out := stripANSI(m.coordinationDetail.View()); !strings.Contains(out, "Final streams") || !strings.Contains(out, "Report") || strings.Contains(out, "the brief") {
		t.Fatalf("a closed arc must render its final DAG before the report without returning to the Brief:\n%s", out)
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
	if !strings.Contains(out, "Final streams") || !strings.Contains(out, "Report") || strings.Contains(out, "the brief") {
		t.Errorf("a late ledger append must not flip a closed arc back to its Brief:\n%s", out)
	}
}

// The sweep archives exactly the closed arcs whose record shows them more than
// a week past their latest declared instant. A live arc of the same age is never
// eligible, and neither is a closed arc whose instant cannot be read — archiving
// writes to the record, and an unreadable date is not evidence of age.
func TestArcSweepSelectsAgedClosedArcsOnly(t *testing.T) {
	now := time.Date(2026, 7, 29, 9, 0, 0, 0, time.Local)
	ago := func(days int) string { return now.AddDate(0, 0, -days).Format(time.RFC3339) }
	arcs := []coordination.Arc{
		{Slug: "stale-done", Status: coordination.StatusClosed, Opened: ago(30), ClosedAt: ago(9)},
		{Slug: "stale-live", Status: coordination.StatusActive, Opened: ago(9)},
		{Slug: "fresh-done", Status: coordination.StatusClosed, Opened: ago(9), ClosedAt: ago(1)},
		{Slug: "dateless-done", Status: coordination.StatusClosed},
		{Slug: "unreadable-done", Status: coordination.StatusClosed, ClosedAt: "whenever"},
		{Slug: "already-archived", Status: coordination.StatusArchived, ClosedAt: ago(30)},
	}

	m := minimalModel(stateCoordination, nil, nil)
	got := m.arcSweepSet(arcs, now)
	if len(got) != 1 || got[0] != "stale-done" {
		t.Errorf("only a closed arc with a readable instant past the week is swept, got %v", got)
	}
}

// The sweep rides the arc-store scan, which runs on the poll heartbeat from
// every application state — so an aged closed arc archives whether or not the
// coordination tab is the one in front of the coordinator.
func TestArcSweepRidesTheScanFromAnyState(t *testing.T) {
	ago := func(days int) string { return time.Now().AddDate(0, 0, -days).Format(time.RFC3339) }
	scan := coordinationArcsScannedMsg{arcs: []coordination.Arc{
		{Slug: "stale-done", Status: coordination.StatusClosed, Opened: ago(30), ClosedAt: ago(9)},
		{Slug: "stale-live", Status: coordination.StatusActive, Opened: ago(9)},
	}}

	for _, state := range []appState{stateWork, stateCoordination} {
		m := minimalModel(state, nil, nil)
		m.width, m.height = 120, 40
		nm, cmd := updateModel(t, m, scan)
		if !nm.arcSweepInFlight {
			t.Errorf("state %v: the scan should have dispatched the sweep", state)
		}
		if !nm.arcSwept["stale-done"] {
			t.Errorf("state %v: the aged closed arc should have been submitted", state)
		}
		if nm.arcSwept["stale-live"] {
			t.Errorf("state %v: a live arc is never submitted, whatever its age", state)
		}
		if cmd == nil {
			t.Errorf("state %v: the sweep should ride out with the scan's commands", state)
		}
	}
}

// One sweep runs at a time and each slug is submitted once. The heartbeat
// rescans while an arc stays closed until its archive lands, so without both
// guards a single aged arc would respawn the subprocess on every tick.
func TestArcSweepSubmitsEachSlugOnce(t *testing.T) {
	now := time.Date(2026, 7, 29, 9, 0, 0, 0, time.Local)
	arcs := []coordination.Arc{{
		Slug:     "stale-done",
		Status:   coordination.StatusClosed,
		Opened:   now.AddDate(0, 0, -30).Format(time.RFC3339),
		ClosedAt: now.AddDate(0, 0, -9).Format(time.RFC3339),
	}}

	m := minimalModel(stateCoordination, nil, nil)
	if cmd := m.startArcSweep(arcs); cmd == nil {
		t.Fatal("the first scan holding an aged closed arc should dispatch a sweep")
	}
	if !m.arcSweepInFlight || !m.arcSwept["stale-done"] {
		t.Fatal("dispatching a sweep must mark it in flight and record the submitted slug")
	}
	if cmd := m.startArcSweep(arcs); cmd != nil {
		t.Error("a second scan while a sweep is in flight must not dispatch another")
	}

	m.arcSweepInFlight = false
	if cmd := m.startArcSweep(arcs); cmd != nil {
		t.Error("a slug already submitted this session must not be submitted again")
	}
	if got := m.arcSweepSet(arcs, now); len(got) != 0 {
		t.Errorf("a submitted slug leaves the eligible set, got %v", got)
	}
}

// The sweep was never asked for, so it reports through channels that clear on
// the next key press and never holds the coordinator up. A failure names the
// arcs; a clean run counts them. Either outcome releases the in-flight guard so
// the next scan can pick up what this one did not cover.
func TestArcSweepReportsThroughTransientChannels(t *testing.T) {
	t.Run("a clean sweep counts the arcs it archived", func(t *testing.T) {
		m := minimalModel(stateCoordination, nil, nil)
		m.arcSweepInFlight = true
		nm, cmd := updateModel(t, m, arcArchiveFinishedMsg{Archived: []string{"one", "two"}})
		if cmd != nil {
			t.Error("the sweep must not quit or block on its own result")
		}
		if nm.arcSweepInFlight {
			t.Error("a finished sweep must release the guard")
		}
		if !strings.Contains(nm.statusNotice, "2 arcs") {
			t.Errorf("a clean sweep should count what it archived, got %q", nm.statusNotice)
		}
		if nm.flashErr != "" {
			t.Errorf("a clean sweep raises no error, got %q", nm.flashErr)
		}
	})

	t.Run("one archived arc reads as one arc", func(t *testing.T) {
		m := minimalModel(stateCoordination, nil, nil)
		nm, _ := updateModel(t, m, arcArchiveFinishedMsg{Archived: []string{"one"}})
		if !strings.Contains(nm.statusNotice, "1 arc ") {
			t.Errorf("a single arc should not read as a plural, got %q", nm.statusNotice)
		}
	})

	t.Run("a failure names the arcs that did not archive", func(t *testing.T) {
		m := minimalModel(stateCoordination, nil, nil)
		m.arcSweepInFlight = true
		nm, cmd := updateModel(t, m, arcArchiveFinishedMsg{
			Failed: []string{"stubborn"},
			Err:    fmt.Errorf("still open"),
		})
		if cmd != nil {
			t.Error("a failed sweep must not quit")
		}
		if nm.arcSweepInFlight {
			t.Error("a failed sweep must still release the guard")
		}
		if !strings.Contains(nm.flashErr, "stubborn") {
			t.Errorf("the failure should name the arc, got %q", nm.flashErr)
		}
	})
}

// Quitting is immediate. Closed arcs no longer hold the quit open on an offer:
// they archive on their own, so `q` writes nothing and leaves.
func TestQuitFromCoordinationIsImmediate(t *testing.T) {
	m := minimalModel(stateCoordination, nil, nil)
	m.width, m.height = 120, 40
	m.coordinationList.SetArcs([]coordination.Arc{
		{Slug: "live", Status: coordination.StatusActive, Opened: time.Now().Format(time.RFC3339)},
		{Slug: "stale-done", Status: coordination.StatusClosed,
			ClosedAt: time.Now().AddDate(0, 0, -20).Format(time.RFC3339)},
	}, 0)

	nm, cmd := updateModel(t, m, press('q'))
	if cmd == nil {
		t.Fatal("q should quit")
	}
	if _, isQuit := cmd().(tea.QuitMsg); !isQuit {
		t.Error("a closed arc must not hold the quit open")
	}
	if out := stripANSI(nm.viewContent()); strings.Contains(out, "Archive closed arcs") {
		t.Errorf("no archive modal may render on the way out:\n%s", out)
	}
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
	assertSession := func(t *testing.T, row sessionview.SessionRow) {
		t.Helper()
		m := coordinationContractModel(t)
		m.sessionRows = []sessionview.SessionRow{
			row,
			{RowID: "other", Display: "impl-b", Slug: "item-b"},
			{RowID: "stray", Display: "stray", Project: "arc-a"},
		}
		m.syncCoordinationSessions()
		m.focusedPanel = panelRight
		_, cmd := updateModel(t, m, press(tea.KeyEnter))
		if cmd == nil {
			t.Fatal("declared member session should be a navigation target")
		}
		msg, ok := cmd().(coordination.SessionSelectedMsg)
		if !ok || msg.RowID != row.RowID {
			t.Fatalf("session join produced %T %v, want %q", cmd(), cmd(), row.RowID)
		}
	}
	t.Run("direct slug", func(t *testing.T) {
		assertSession(t, sessionview.SessionRow{RowID: "direct", Display: "impl-a", Slug: "item-a"})
	})
	t.Run("worker base item", func(t *testing.T) {
		assertSession(t, sessionview.SessionRow{RowID: "worker", Display: "worker-a", Slug: "item-a--w1", BaseItem: "item-a"})
	})
}

func TestArcScanCollapsesOnlyActiveDeclaredSessions(t *testing.T) {
	m := minimalModel(stateSessions, nil, nil)
	m.sessionRows = []sessionview.SessionRow{
		{RowID: "active", Slug: "item-a", Display: "item-a"},
		{RowID: "closed", Slug: "item-b", Display: "item-b"},
	}
	m.sessionsList.SetSessions(m.sessionRows)

	nm, _ := m.handleCoordinationArcsScanned(coordinationArcsScannedMsg{arcs: []coordination.Arc{
		{Slug: "live", Status: coordination.StatusActive, Members: []string{"item-a"}},
		{Slug: "done", Status: coordination.StatusClosed, Members: []string{"item-b"}},
	}})
	view := nm.sessionsList.View()
	if !strings.Contains(view, "▶ arc-owned (1)") {
		t.Fatalf("active declared session should collapse:\n%s", view)
	}
	if !strings.Contains(view, "item-b") {
		t.Fatalf("closed-arc membership must not hide a session:\n%s", view)
	}
	if strings.Contains(view, "item-a ") {
		t.Fatalf("active-arc member should stay behind the disclosure:\n%s", view)
	}
}

// TestCoordinationViewComposesBothLayouts smoke-tests the compositor arm: the
// coordination view renders through the shared split-pane in both layout
// modes with its list title and integrated detail sections.
func TestCoordinationViewComposesBothLayouts(t *testing.T) {
	for _, layout := range []config.LayoutMode{config.LayoutLeftRight, config.LayoutTopBottom} {
		m := coordinationContractModel(t)
		m.layoutMode = layout
		m.coordinationPanelCallbacks().resize()
		out := stripANSI(m.viewContent())
		for _, want := range []string{"arc-a", "coordination (2)", "Brief", "Streams", "Recent activity"} {
			if !strings.Contains(out, want) {
				t.Errorf("layout %v: coordination view missing %q:\n%s", layout, want, out)
			}
		}
	}
}

func TestCoordinationPaneTitleRollupOmitsEmptyBuckets(t *testing.T) {
	m := coordinationContractModel(t)
	if got, want := stripANSI(m.buildPaneConfig().listTitle), "Coordination — ⚠ 2 act now"; got != want {
		t.Fatalf("coordination pane title = %q, want %q", got, want)
	}
	m.layoutMode = config.LayoutTopBottom
	m.coordinationPanelCallbacks().resize()
	if got := stripANSI(m.viewContent()); !strings.Contains(got, "Coordination — ⚠ 2 act now") {
		t.Fatalf("top-bottom frame did not render the attention rollup title:\n%s", got)
	}
}
