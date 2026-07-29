package coordination

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/sessionview"
	"github.com/anticorrelator/lore/tui/internal/style"
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

// iso renders an instant the way an arc record declares one.
func iso(t time.Time) string { return t.Format(time.RFC3339) }

// hoursAgo and daysAgo build declared instants relative to the running clock,
// which is the clock the list buckets against.
func hoursAgo(n int) string { return iso(time.Now().Add(-time.Duration(n) * time.Hour)) }
func daysAgo(n int) string  { return iso(time.Now().AddDate(0, 0, -n)) }

// The bucket boundary is the local calendar day, not a rolling window: an arc
// closed late yesterday reads as this week all through today.
func TestBucketOfSplitsOnLocalCalendarDays(t *testing.T) {
	now := time.Date(2026, 7, 29, 9, 0, 0, 0, time.Local)
	cases := []struct {
		name    string
		recency string
		want    Bucket
	}{
		{"this morning", iso(now.Add(-2 * time.Hour)), BucketToday},
		{"local midnight today", iso(time.Date(2026, 7, 29, 0, 0, 0, 0, time.Local)), BucketToday},
		{"late yesterday", iso(time.Date(2026, 7, 28, 23, 30, 0, 0, time.Local)), BucketThisWeek},
		{"six days back at midnight", iso(time.Date(2026, 7, 23, 0, 0, 0, 0, time.Local)), BucketThisWeek},
		{"a moment before that", iso(time.Date(2026, 7, 22, 23, 59, 0, 0, time.Local)), BucketOlder},
		{"three weeks ago", iso(now.AddDate(0, 0, -21)), BucketOlder},
		{"no declared instant", "", BucketOlder},
		{"unparseable", "whenever", BucketOlder},
	}
	for _, c := range cases {
		if got := bucketOf(c.recency, now); got != c.want {
			t.Errorf("%s: bucketOf(%q)=%v want %v", c.name, c.recency, got, c.want)
		}
	}
}

// Rows sit under recency headers, newest first, and the retired Active and
// Complete sections appear nowhere.
func TestListModelGroupsArcsByRecency(t *testing.T) {
	m := NewListModel()
	m, _ = m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	// midweek carries the backfill shape most closed records have: an open
	// written at migration time, later than the close it preserved. It buckets
	// on the close.
	m.SetArcs([]Arc{
		{Slug: "fresh", Status: StatusActive, Opened: hoursAgo(2)},
		{Slug: "midweek", Status: StatusClosed, Opened: hoursAgo(1), ClosedAt: daysAgo(3)},
		{Slug: "ancient", Status: StatusActive, Opened: daysAgo(21)},
	}, 0)
	out := stripANSI(m.View())
	for _, want := range []string{"Today (1)", "This week (1)", "Older (1)"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q header:\n%s", want, out)
		}
	}
	if strings.Contains(out, "Active (") || strings.Contains(out, "Complete (") {
		t.Errorf("the retired sections must not render:\n%s", out)
	}
	order := []string{"Today", "fresh", "This week", "midweek", "Older", "ancient"}
	at := 0
	for _, want := range order {
		i := strings.Index(out[at:], want)
		if i < 0 {
			t.Fatalf("expected %q after position %d, newest bucket first:\n%s", want, at, out)
		}
		at += i + len(want)
	}
}

// A live arc renders in its bucket however old it is, and its badge warns.
// A closed arc of the same age folds away until the toggle reveals it, and the
// Older header names what is hidden and the key that brings it back.
func TestListModelLiveArcsNeverFoldAndTheFoldAnnouncesItself(t *testing.T) {
	m := NewListModel()
	m, _ = m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	m.SetArcs([]Arc{
		{Slug: "still-open", Status: StatusActive, Opened: daysAgo(21)},
		{Slug: "long-done", Status: StatusClosed, Opened: daysAgo(21), ClosedAt: daysAgo(20)},
		{Slug: "also-done", Status: StatusClosed, Opened: daysAgo(30), ClosedAt: daysAgo(25)},
	}, 0)

	out := stripANSI(m.View())
	if !strings.Contains(out, "still-open") {
		t.Errorf("a live arc must render however old it is:\n%s", out)
	}
	if strings.Contains(out, "long-done") {
		t.Errorf("a closed arc past the week must fold away:\n%s", out)
	}
	if !strings.Contains(out, "Older (1) · 2 closed hidden — ctrl+a") {
		t.Errorf("the Older header must name the hidden count and the key:\n%s", out)
	}
	if m.Count() != 1 {
		t.Errorf("the tab count should exclude folded arcs, got %d", m.Count())
	}

	m, _ = m.Update(tea.KeyPressMsg{Code: 'a', Mod: tea.ModCtrl})
	out = stripANSI(m.View())
	if !strings.Contains(out, "long-done") || !strings.Contains(out, "Older (3)") {
		t.Errorf("ctrl+a must reveal the folded closed arcs:\n%s", out)
	}
	if !strings.Contains(out, "still-open") {
		t.Errorf("the live arc renders in its bucket with the toggle on too:\n%s", out)
	}
	if strings.Contains(out, "closed hidden") {
		t.Errorf("nothing is hidden once the toggle is on:\n%s", out)
	}
	if m.Count() != 3 {
		t.Errorf("revealed arcs should count, got %d", m.Count())
	}
}

// With everything closed and folded, the Older header is the only row. It still
// renders — the notice is what tells the user where the arcs went — and it
// carries no count, because nothing is visible to count.
func TestListModelFoldNoticeRendersWithoutVisibleMembers(t *testing.T) {
	m := NewListModel()
	m, _ = m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	m.SetArcs([]Arc{
		{Slug: "long-done", Status: StatusClosed, Opened: daysAgo(21), ClosedAt: daysAgo(20)},
	}, 0)
	out := stripANSI(m.View())
	if !strings.Contains(out, "Older · 1 closed hidden — ctrl+a") {
		t.Errorf("a members-less Older header must still announce the fold:\n%s", out)
	}
	if strings.Contains(out, "Older (") {
		t.Errorf("a members-less header must carry no count:\n%s", out)
	}
}

// A fold-notice header can be the list's last row. Stepping down onto it must
// leave the cursor where it was, not throw it to the top of the list.
func TestListModelDownOntoTrailingHeaderHoldsTheCursor(t *testing.T) {
	m := NewListModel()
	m, _ = m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	m.SetArcs([]Arc{
		{Slug: "fresh", Status: StatusActive, Opened: hoursAgo(1)},
		{Slug: "still-open", Status: StatusActive, Opened: daysAgo(21)},
		{Slug: "long-done", Status: StatusClosed, Opened: daysAgo(21), ClosedAt: daysAgo(20)},
	}, 0)
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if m.CurrentSlug() != "still-open" {
		t.Fatalf("j should step over the Older header onto the old live arc, got %q", m.CurrentSlug())
	}

	// The Older header now sits below the cursor carrying only the notice.
	m.SetArcs([]Arc{
		{Slug: "fresh", Status: StatusActive, Opened: hoursAgo(1)},
		{Slug: "long-done", Status: StatusClosed, Opened: daysAgo(21), ClosedAt: daysAgo(20)},
	}, 0)
	if m.CurrentSlug() != "fresh" {
		t.Fatalf("cursor should fall to the remaining arc, got %q", m.CurrentSlug())
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if m.CurrentSlug() != "fresh" {
		t.Errorf("j onto a trailing header must hold the cursor, not jump to the top, got %q", m.CurrentSlug())
	}
}

// The badge says what an arc is without the reader tracing back to its header.
// A live arc past the week is drawn in the warn color; the row never claims the
// arc has stalled.
func TestListModelStateBadges(t *testing.T) {
	m := NewListModel()
	m, _ = m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	m.SetArcs([]Arc{
		{Slug: "fresh", Status: StatusActive, Opened: hoursAgo(1)},
		{Slug: "still-open", Status: StatusActive, Opened: daysAgo(21)},
		{Slug: "recent-close", Status: StatusClosed, Opened: daysAgo(9), ClosedAt: hoursAgo(3)},
		{Slug: "filed", Status: StatusArchived, Opened: daysAgo(30), ClosedAt: daysAgo(29)},
	}, 0)
	m, _ = m.Update(tea.KeyPressMsg{Code: 'a', Mod: tea.ModCtrl})

	out := stripANSI(m.View())
	if !strings.Contains(out, "STATE") || !strings.Contains(out, "AGE") {
		t.Errorf("the row should carry state and age columns:\n%s", out)
	}
	for _, want := range []string{"live", "closed", "archived"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q badge:\n%s", want, out)
		}
	}
	if strings.Contains(strings.ToLower(out), "stall") {
		t.Errorf("the row must not assert inactivity the record cannot support:\n%s", out)
	}

	if got := stateStyle(StatusActive, BucketOlder); got.GetForeground() != style.StatusWarn.GetForeground() {
		t.Errorf("a live arc past the week should warn, got %v", got.GetForeground())
	}
	if got := stateStyle(StatusActive, BucketToday); got.GetForeground() != style.StatusActive.GetForeground() {
		t.Errorf("a recent live arc should read as active, got %v", got.GetForeground())
	}
	if got := stateStyle(StatusArchived, BucketOlder); got.GetForeground() != style.StatusDone.GetForeground() {
		t.Errorf("an archived arc should read as done, got %v", got.GetForeground())
	}
}

// The closed ramp fades a row as its close recedes, and it is keyed on the same
// bucket that decides the row's header and its fold.
func TestClosedRampFadesWithTheBucket(t *testing.T) {
	if closedRamp(BucketToday).GetForeground() != style.StatusDone.GetForeground() {
		t.Error("a close from today should read as an ordinary settled row")
	}
	if closedRamp(BucketThisWeek).GetForeground() != style.ColorChrome {
		t.Error("a close from this week should recede to chrome")
	}
	older := closedRamp(BucketOlder)
	if older.GetForeground() != style.ColorChrome || !older.GetFaint() {
		t.Errorf("the oldest step should be fainter still, got %v faint=%v", older.GetForeground(), older.GetFaint())
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
