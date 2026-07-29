package coordination

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/sessionview"
	"github.com/anticorrelator/lore/tui/internal/work"
)

var ansiRe = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func stripANSI(s string) string { return ansiRe.ReplaceAllString(s, "") }

// --- ReadPin (sidecar schema v1) ---

func TestReadPinMissingSidecarIsPinless(t *testing.T) {
	pin, err := ReadPin(t.TempDir())
	if err != nil || pin != nil {
		t.Fatalf("missing sidecar must read as pin-less, got pin=%v err=%v", pin, err)
	}
}

func TestReadPinClearedSidecarIsPinless(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "_coordination.json"), []byte(`{"schema_version":1}`), 0o644); err != nil {
		t.Fatal(err)
	}
	pin, err := ReadPin(dir)
	if err != nil || pin != nil {
		t.Fatalf("cleared sidecar (no pin key) must read as pin-less, got pin=%v err=%v", pin, err)
	}
}

func TestReadPinSetSidecar(t *testing.T) {
	dir := t.TempDir()
	raw := `{"schema_version":1,"pin":{"instance":"calm-cedar","pinned_at":"2026-07-22T09:00:00Z","pinned_by":"dustin"}}`
	if err := os.WriteFile(filepath.Join(dir, "_coordination.json"), []byte(raw), 0o644); err != nil {
		t.Fatal(err)
	}
	pin, err := ReadPin(dir)
	if err != nil || pin == nil {
		t.Fatalf("set sidecar must read the pin, got pin=%v err=%v", pin, err)
	}
	if pin.Instance != "calm-cedar" || pin.PinnedAt != "2026-07-22T09:00:00Z" || pin.PinnedBy != "dustin" {
		t.Errorf("pin fields mismatch: %+v", pin)
	}
}

func TestReadPinCorruptSidecarSurfacesError(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "_coordination.json"), []byte(`{"schema_version":"one"`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadPin(dir); err == nil {
		t.Error("corrupt sidecar must surface an error, not read as unpinned")
	}
}

// --- ListModel ---

func TestListModelCursorRestsOnArcsNotSectionHeaders(t *testing.T) {
	m := NewListModel()
	m.SetArcs([]Arc{
		{Slug: "arc-b", Status: StatusActive, Items: 2},
		{Slug: "arc-a", Status: StatusActive, Items: 1},
	}, 0)
	if m.CurrentSlug() != "arc-b" {
		t.Fatalf("cursor should rest on the first arc, got %q", m.CurrentSlug())
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if m.CurrentSlug() != "arc-a" {
		t.Fatalf("j should move to the next arc, got %q", m.CurrentSlug())
	}
	// Cursor preserved by slug across a reload.
	m.SetArcs([]Arc{
		{Slug: "arc-c", Status: StatusActive},
		{Slug: "arc-a", Status: StatusActive},
		{Slug: "arc-b", Status: StatusActive},
	}, 0)
	if m.CurrentSlug() != "arc-a" {
		t.Errorf("reload should preserve the cursor by slug, got %q", m.CurrentSlug())
	}
}

// A closed arc lands under its own section header, and walking from the first
// active arc to the last closed one never parks the cursor on a header.
func TestListModelSectionsSplitActiveFromComplete(t *testing.T) {
	m := NewListModel()
	m.SetArcs([]Arc{
		{Slug: "live", Status: StatusActive},
		{Slug: "done", Status: StatusClosed},
	}, 0)
	out := stripANSI(m.View())
	if !strings.Contains(out, "Active (1)") || !strings.Contains(out, "Complete (1)") {
		t.Errorf("both sections should carry a counted header:\n%s", out)
	}
	if m.CurrentSlug() != "live" {
		t.Fatalf("cursor should open on the first active arc, got %q", m.CurrentSlug())
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if m.CurrentSlug() != "done" {
		t.Errorf("j should step over the Complete header onto the closed arc, got %q", m.CurrentSlug())
	}
}

func TestListModelArchivedHiddenUntilToggled(t *testing.T) {
	m := NewListModel()
	m.SetArcs([]Arc{
		{Slug: "live", Status: StatusActive},
		{Slug: "old", Status: StatusArchived},
	}, 0)
	if out := stripANSI(m.View()); strings.Contains(out, "old") {
		t.Errorf("archived arcs must be hidden by default:\n%s", out)
	}
	if m.Count() != 1 {
		t.Errorf("the tab count should exclude hidden archived arcs, got %d", m.Count())
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'a', Mod: tea.ModCtrl})
	out := stripANSI(m.View())
	if !strings.Contains(out, "Archived (1)") || !strings.Contains(out, "old") {
		t.Errorf("ctrl+a should reveal the Archived section:\n%s", out)
	}
	if m.Count() != 2 {
		t.Errorf("revealed archived arcs should count, got %d", m.Count())
	}
}

// The list renders the project as a column, and an arc with no project label
// shows the no-label cell rather than borrowing its slug.
func TestListModelProjectIsAColumn(t *testing.T) {
	m := NewListModel()
	m, _ = m.Update(tea.WindowSizeMsg{Width: 80, Height: 20})
	m.SetArcs([]Arc{
		{Slug: "labeled", Status: StatusActive, Project: "proj-x"},
		{Slug: "bare", Status: StatusActive},
	}, 0)
	out := stripANSI(m.View())
	if !strings.Contains(out, "PROJECT") || !strings.Contains(out, "proj-x") {
		t.Errorf("project should render as its own column:\n%s", out)
	}
	if !strings.Contains(out, noProjectCell) {
		t.Errorf("a project-less arc should render %q:\n%s", noProjectCell, out)
	}
}

func TestListModelSkippedRecordsSurfaceInEmptyState(t *testing.T) {
	m := NewListModel()
	m.SetArcs(nil, 3)
	out := stripANSI(m.View())
	if !strings.Contains(out, "lore arc open") {
		t.Errorf("the empty state should name the verb that starts an arc:\n%s", out)
	}
	if !strings.Contains(out, "3 unreadable") {
		t.Errorf("skipped records should surface in the UI, not on stderr:\n%s", out)
	}
}

func TestListModelClosedArcsExcludesArchived(t *testing.T) {
	m := NewListModel()
	m.SetArcs([]Arc{
		{Slug: "live", Status: StatusActive},
		{Slug: "done", Status: StatusClosed},
		{Slug: "old", Status: StatusArchived},
	}, 0)
	closed := m.ClosedArcs()
	if len(closed) != 1 || closed[0].Slug != "done" {
		t.Errorf("only closed arcs are archivable, got %v", closed)
	}
}

func TestListModelEnterEmitsArcSelected(t *testing.T) {
	m := NewListModel()
	m.SetArcs([]Arc{{Slug: "arc-a", Status: StatusActive, Items: 1}}, 0)
	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("Enter should emit a selection command")
	}
	msg, ok := cmd().(ArcSelectedMsg)
	if !ok || msg.Slug != "arc-a" {
		t.Fatalf("Enter produced %v, want ArcSelectedMsg{arc-a}", msg)
	}
	_ = m
}

// --- DetailModel first-class states ---

// An arc with no project label has no pin home, which is a different fact from
// having one and finding no pin in it.
func TestDetailPinNoProjectIsItsOwnState(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	m.SetLedger("x", "", false)
	m.SetPin(PinNoProject, nil)
	out := stripANSI(m.View())
	if !strings.Contains(out, "no project label") {
		t.Errorf("a project-less arc must say so on the pin line:\n%s", out)
	}
	if strings.Contains(out, "no standing target") {
		t.Errorf("no pin home must not read as an empty pin home:\n%s", out)
	}
}

// A declared member the index cannot resolve keeps its row: the arc still
// declares it, and dropping it would hide a membership list that has drifted.
func TestDetailUnresolvedMemberRendersDimAndIsNotOpenable(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	m.SetMembers([]Member{
		{Slug: "gone"},
		{Slug: "here", Resolved: true, Item: work.WorkItem{Slug: "here", Status: "active"}},
	}, nil)
	m.tabHost.SetActiveID(TabItems)
	out := stripANSI(m.View())
	if !strings.Contains(out, "gone") || !strings.Contains(out, "unresolved") {
		t.Errorf("an unresolved member must still render, marked:\n%s", out)
	}
	if _, ok := m.CurrentItem(); ok {
		t.Error("an unresolved member has no work detail to open")
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	it, ok := m.CurrentItem()
	if !ok || it.Slug != "here" {
		t.Errorf("the resolved member below it should open, got %+v ok=%v", it, ok)
	}
}

func sizedDetail() DetailModel {
	m := NewDetailModel()
	m, _ = m.Update(tea.WindowSizeMsg{Width: 80, Height: 30})
	return m
}

func TestDetailNoArcRendersExplicitEmptyState(t *testing.T) {
	m := sizedDetail()
	if out := stripANSI(m.View()); !strings.Contains(out, "No arc selected") {
		t.Errorf("empty detail must render the no-arc state:\n%s", out)
	}
}

func TestDetailStatusBriefStates(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	if out := stripANSI(m.View()); !strings.Contains(out, "reading coordination.md") {
		t.Errorf("pre-read status must render the loading state:\n%s", out)
	}
	m.SetLedger("## Rows\n\nrow\n", "", false)
	if out := stripANSI(m.View()); !strings.Contains(out, "no Brief yet") {
		t.Errorf("ledger without ## Brief must render the first-class no-Brief state:\n%s", out)
	}
	m.SetLedger("## Brief\n\nlanded: the mirror\n", "landed: the mirror", true)
	if out := stripANSI(m.View()); !strings.Contains(out, "landed: the mirror") {
		t.Errorf("extracted Brief must render:\n%s", out)
	}
}

func TestDetailPinThreeStates(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	m.SetLedger("x", "", false)

	m.SetPin(PinAbsent, nil)
	if out := stripANSI(m.View()); !strings.Contains(out, "none — dispatch has no standing target") {
		t.Errorf("absent pin must render first-class:\n%s", out)
	}

	m.SetPin(PinLive, &Pin{Instance: "calm-cedar"})
	if out := stripANSI(m.View()); !strings.Contains(out, "calm-cedar") || !strings.Contains(out, "● live") {
		t.Errorf("live pin must name the instance and its liveness:\n%s", out)
	}

	m.SetPin(PinDead, &Pin{Instance: "swift-heron"})
	out := stripANSI(m.View())
	if !strings.Contains(out, "✗ dead") {
		t.Errorf("dead pin must render distinctly from absent and live:\n%s", out)
	}
	if !strings.Contains(out, "pin dead: swift-heron") {
		t.Errorf("dead pin must appear as an attention item:\n%s", out)
	}
}

func TestDetailStatusCountsAndAttention(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	m.SetLedger("x", "", false)
	m.SetPin(PinAbsent, nil)
	m.SetMembers([]Member{
		{Slug: "m1", Resolved: true, Item: work.WorkItem{Slug: "m1", Status: "active", BlockedBy: []string{"m2"}}},
		{Slug: "m2", Resolved: true, Item: work.WorkItem{Slug: "m2", Status: "active"}},
	}, map[string]bool{"m1": true, "m2": true})
	m.SetSessions([]sessionview.SessionRow{
		{RowID: "r1", Display: "m1", Type: "implement", Local: true},
		{RowID: "r2", Display: "m2", Type: "spec", NeedsInput: true, Local: true},
		{RowID: "r3", Display: "m3", Type: "worker", InFlight: true},
	})
	out := stripANSI(m.View())
	if !strings.Contains(out, "2 live") {
		t.Errorf("in-flight spawns must not count as live sessions:\n%s", out)
	}
	if !strings.Contains(out, "blocked: m1") {
		t.Errorf("a member with an active blocker is an attention item:\n%s", out)
	}
	if !strings.Contains(out, "needs input: m2") {
		t.Errorf("a needs-input session is an attention item:\n%s", out)
	}
}

func TestDetailSessionsTabJoinAndMirrorScoping(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	m.SetSessions([]sessionview.SessionRow{
		{RowID: "remote", Display: "impl-a", Type: "implement", Instance: "inst-b", Tmux: "lore-x"},
		{RowID: "local", Display: "impl-b", Type: "implement", Instance: "inst-a", Local: true},
	})

	// Mirror capture is scoped to a displayed Sessions tab.
	if _, _, ok := m.RemoteMirror(); ok {
		t.Fatal("RemoteMirror must report nothing while the Sessions tab is hidden")
	}
	m.tabHost.SetActiveID(TabSessions)
	m.syncSessionCard()
	rowID, tmuxName, ok := m.RemoteMirror()
	if !ok || rowID != "remote" || tmuxName != "lore-x" {
		t.Fatalf("remote tmux row under the cursor must be mirrorable, got %q %q %v", rowID, tmuxName, ok)
	}
	m.SetMirror("remote", []string{"pane line one"})
	if out := stripANSI(m.View()); !strings.Contains(out, "pane line one") {
		t.Errorf("captured pane rows must render in the mirror card:\n%s", out)
	}

	// j moves to the local row: no mirror, card renders it as attach-less local.
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if _, _, ok := m.RemoteMirror(); ok {
		t.Error("a local row must not be mirrorable")
	}
}

func TestDetailTabCycle(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	order := []string{TabStatus, TabSessions, TabItems, TabLedger}
	for i, want := range order {
		if got := m.ActiveTabID(); got != want {
			t.Fatalf("tab %d: got %q want %q", i, got, want)
		}
		m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyTab})
	}
	if m.ActiveTabID() != TabStatus {
		t.Error("Tab should wrap back to Status")
	}
}

func TestDetailLedgerRendersMarkdown(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	m.SetLedger("# Arc Ledger\n\n- row one\n", "", false)
	m.tabHost.SetActiveID(TabLedger)
	out := stripANSI(m.View())
	if !strings.Contains(out, "Arc Ledger") || !strings.Contains(out, "• row one") {
		t.Errorf("ledger tab must render the full document through the markdown pipeline:\n%s", out)
	}
}

// TestDetailNoReportIsFourTabs pins that an arc with no report.md
// renders exactly as today: four tabs, Brief-first Status, no Report tab.
func TestDetailNoReportIsFourTabs(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	m.SetLedger("## Brief\n\nlive brief\n", "live brief", true)
	m.SetReport("", false)
	if got := len(m.tabHost.Tabs()); got != 4 {
		t.Fatalf("an arc without report.md must render four tabs, got %d", got)
	}
	if m.ActiveTabID() != TabStatus {
		t.Errorf("detail should rest on Status, got %q", m.ActiveTabID())
	}
	if out := stripANSI(m.View()); !strings.Contains(out, "live brief") {
		t.Errorf("Status first section must be the Brief when no report is present:\n%s", out)
	}
}

// TestDetailReportTabPresenceAndClosedStatus covers the report projection: the
// fifth tab appears whenever report.md is present, the Status first section
// switches from Brief (live) to the whole report (closed), and the Report tab
// renders the report whole through the markdown pipeline.
func TestDetailReportTabPresenceAndClosedStatus(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	m.SetLedger("## Brief\n\nlive brief\n", "live brief", true)

	// Live successor arc: report present but not closed — five tabs, Status
	// still shows the Brief, and the report is reachable through its tab.
	m.SetReport("# Report\n\nthe whole report body\n", true)
	if got := len(m.tabHost.Tabs()); got != 5 {
		t.Fatalf("a present report must add a fifth tab, got %d tabs", got)
	}
	if out := stripANSI(m.View()); !strings.Contains(out, "live brief") {
		t.Errorf("live arc Status first section must stay the Brief:\n%s", out)
	}
	m.tabHost.SetActiveID(TabReport)
	if out := stripANSI(m.View()); !strings.Contains(out, "the whole report body") || !strings.Contains(out, "Report") {
		t.Errorf("Report tab must render the whole report through markdown:\n%s", out)
	}

	// Closed arc: the Status first section becomes the report, not the Brief.
	m.tabHost.SetActiveID(TabStatus)
	m.SetClosed(true)
	m.SetReport("# Report\n\nclosed report body\n", true)
	out := stripANSI(m.View())
	if !strings.Contains(out, "closed report body") {
		t.Errorf("closed arc Status first section must render the report whole:\n%s", out)
	}
	if strings.Contains(out, "live brief") {
		t.Errorf("closed arc Status must not show the Brief in its first section:\n%s", out)
	}
}

// TestDetailReportTabIdentitySurvivesRebuild pins tab-identity preservation
// across a SetReport rebuild and the Status fallback when the Report tab
// vanishes.
func TestDetailReportTabIdentitySurvivesRebuild(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	m.SetLedger("## Brief\n\nb\n", "b", true)
	m.SetClosed(true)
	m.SetReport("# R\n\nbody\n", true)

	// A rebuild while parked on Ledger keeps the user on Ledger.
	m.tabHost.SetActiveID(TabLedger)
	m.SetReport("# R\n\nbody v2\n", true)
	if m.ActiveTabID() != TabLedger {
		t.Errorf("a SetReport rebuild must preserve the active tab by ID, got %q", m.ActiveTabID())
	}

	// Parked on Report, a vanished report falls back to Status and drops the tab.
	m.tabHost.SetActiveID(TabReport)
	m.SetReport("", false)
	if got := len(m.tabHost.Tabs()); got != 4 {
		t.Fatalf("a vanished report must drop the Report tab, got %d tabs", got)
	}
	if m.ActiveTabID() != TabStatus {
		t.Errorf("a vanished Report tab must fall back to Status, got %q", m.ActiveTabID())
	}
}

// TestDetailClosedReportUnreadableIsExplicit pins that a closed arc whose
// report reads empty renders an explicit dim state, never a silent blank.
func TestDetailClosedReportUnreadableIsExplicit(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	m.SetLedger("## Brief\n\nb\n", "b", true)
	m.SetClosed(true)
	m.SetReport("", true)
	if out := stripANSI(m.View()); !strings.Contains(out, "report.md could not be read") {
		t.Errorf("a closed arc with an unreadable report must render an explicit state:\n%s", out)
	}
}
