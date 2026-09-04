package coordination

import (
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/coordination/board"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/sessionview"
	"github.com/anticorrelator/lore/tui/internal/style"
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

func attentionFixture() board.Attention {
	return board.Attention{
		board.ActNow: {
			{Bucket: board.ActNow, Arc: "arc-a", StreamID: "s1", Label: "Ship A", Gate: "hold", Status: "pending", Verdict: "unknown"},
			{Bucket: board.ActNow, Arc: "arc-b", StreamID: "s2", Label: "Ship B", Gate: "flag", Status: "mystery", Verdict: "full"},
		},
		board.NeedsJudgment: {},
		board.Waiting:       {},
		board.Reconcile:     {},
	}
}

func setFreshAttentionActivity(m *ListModel) {
	m.SetAttentionActivity(map[string]string{
		"arc-a": iso(time.Now().Add(-2 * time.Hour)),
		"arc-b": iso(time.Now().Add(-3 * time.Hour)),
	})
}

func TestListModelAttentionSwapsAtFullHeightAndRendersDenoisedRows(t *testing.T) {
	m := NewListModel()
	m.SetArcs([]Arc{{Slug: "arc-a", Status: StatusActive}, {Slug: "arc-b", Status: StatusActive}}, 0)
	m.SetAttention(attentionFixture(), nil)
	setFreshAttentionActivity(&m)
	m, _ = m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	if out := stripANSI(m.View()); strings.Contains(out, "ATTENTION") || strings.Contains(out, "Ship A") {
		t.Fatalf("collapsed attention must consume zero listing rows:\n%s", out)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'a', Text: "a"})
	out := stripANSI(m.View())
	for _, want := range []string{
		"Act now (2)", "Needs judgment · none", "Waiting · none", "Reconcile · none",
		"Ship A · arc-a · 2h ago", "Ship B · arc-b · 3h ago", "hold", "flag", "mystery",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("attention projection missing %q:\n%s", want, out)
		}
	}
	for _, noise := range []string{"status:", "gate:", "verdict:", "[arc-a]", "▸ Attention", "▸ Arcs"} {
		if strings.Contains(out, noise) {
			t.Errorf("attention projection retained noisy %q:\n%s", noise, out)
		}
	}
	if lines := strings.Count(out, "\n"); lines < 7 {
		t.Fatalf("attention should own the full listing viewport, got %d lines:\n%s", lines, out)
	}
}

func TestListModelAttentionHidesVerdictColumnWhenVisibleRowsAreEmpty(t *testing.T) {
	m := NewListModel()
	attention := attentionFixture()
	for i := range attention[board.ActNow] {
		attention[board.ActNow][i].Verdict = "—"
	}
	m.SetAttention(attention, nil)
	setFreshAttentionActivity(&m)
	m, _ = m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	m, _ = m.Update(tea.KeyPressMsg{Code: 'a', Text: "a"})
	if out := stripANSI(m.View()); strings.Contains(out, "VERDICT") {
		t.Fatalf("all-dash verdict column must be hidden:\n%s", out)
	}

	attention[board.ActNow][1].Verdict = "future-verdict"
	m.SetAttention(attention, nil)
	out := stripANSI(m.View())
	if !strings.Contains(out, "VERDICT") || !strings.Contains(out, "future-verdict") || !strings.Contains(out, "—") {
		t.Fatalf("a populated verdict must reveal the column and keep dash peers explicit:\n%s", out)
	}
}

func TestListModelTitleRollupOmitsEmptyBuckets(t *testing.T) {
	m := NewListModel()
	m.SetAttention(board.Attention{
		board.ActNow:        {{Bucket: board.ActNow, Arc: "a", StreamID: "s1"}, {Bucket: board.ActNow, Arc: "b", StreamID: "s2"}},
		board.NeedsJudgment: {},
		board.Waiting:       {{Bucket: board.Waiting, Arc: "c", StreamID: "s3"}},
		board.Reconcile:     {},
	}, nil)
	if got, want := m.Title(), "Coordination — ⚠ 2 act now · 1 waiting"; got != want {
		t.Fatalf("title = %q, want %q", got, want)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'a', Text: "a"})
	if got := m.Title(); got != "Attention" {
		t.Fatalf("swapped title = %q, want Attention", got)
	}
}

func TestListModelAttentionAndArcCursorsAreIndependent(t *testing.T) {
	m := NewListModel()
	m.SetArcs([]Arc{{Slug: "arc-a", Status: StatusActive}, {Slug: "arc-b", Status: StatusActive}}, 0)
	m.SetAttention(attentionFixture(), nil)
	setFreshAttentionActivity(&m)
	m, _ = m.Update(tea.KeyPressMsg{Code: 'a', Text: "a"})
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if _, arc, stream, ok := m.CurrentAttention(); !ok || arc != "arc-b" || stream != "s2" {
		t.Fatalf("attention cursor = %s/%s ok=%v, want arc-b/s2", arc, stream, ok)
	}
	if m.CurrentSlug() != "arc-a" {
		t.Fatalf("attention navigation changed the arc cursor to %q", m.CurrentSlug())
	}

	refreshed := attentionFixture()
	refreshed[board.ActNow] = []board.AttentionRow{refreshed[board.ActNow][1], refreshed[board.ActNow][0]}
	m.SetAttention(refreshed, nil)
	if _, arc, stream, ok := m.CurrentAttention(); !ok || arc != "arc-b" || stream != "s2" {
		t.Fatalf("refresh did not preserve attention identity: %s/%s ok=%v", arc, stream, ok)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'a', Text: "a"})
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if m.CurrentSlug() != "arc-b" {
		t.Fatalf("arc navigation did not resume independently, got %q", m.CurrentSlug())
	}
}

func TestListModelDisappearedAttentionTargetStaysStale(t *testing.T) {
	m := NewListModel()
	m, _ = m.Update(tea.WindowSizeMsg{Width: 140, Height: 30})
	m.SetAttention(attentionFixture(), nil)
	setFreshAttentionActivity(&m)
	m, _ = m.Update(tea.KeyPressMsg{Code: 'a', Text: "a"})
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	m.SetAttention(board.Attention{
		board.ActNow:        {attentionFixture()[board.ActNow][0]},
		board.NeedsJudgment: {}, board.Waiting: {}, board.Reconcile: {},
	}, nil)
	if _, arc, stream, ok := m.CurrentAttention(); !ok || arc != "arc-b" || stream != "s2" {
		t.Fatalf("disappeared cursor fell onto a neighbor: %s/%s ok=%v", arc, stream, ok)
	}
	if out := stripANSI(m.View()); !strings.Contains(out, "Ship B · arc-b · 3h ago · stale/unknown target") {
		t.Errorf("disappeared identity must render explicitly stale:\n%s", out)
	}
}

func TestListModelStaleAttentionFoldsPerBucketAndExpands(t *testing.T) {
	now := time.Now()
	m := NewListModel()
	m.SetAttention(attentionFixture(), nil)
	m.attentionActivityLoaded = true
	m.attentionActivity = map[string]string{
		"arc-a": iso(now.Add(-2 * time.Hour)),
		"arc-b": iso(now.Add(-8 * 24 * time.Hour)),
	}
	m.refreshAttentionRowsAt(now)
	m, _ = m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	m, _ = m.Update(tea.KeyPressMsg{Code: 'a', Text: "a"})
	out := stripANSI(m.View())
	if !strings.Contains(out, "Ship A · arc-a") || !strings.Contains(out, "▸ stale (1)") || strings.Contains(out, "Ship B · arc-b") {
		t.Fatalf("stale entry was not collapsed beneath its bucket:\n%s", out)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if _, ok := parseStaleFoldID(m.attention.CurrentID()); !ok {
		t.Fatalf("cursor did not land on stale disclosure, id=%q", m.attention.CurrentID())
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	out = stripANSI(m.View())
	if !strings.Contains(out, "▾ stale (1)") || !strings.Contains(out, "Ship B · arc-b · 8d ago · stale") {
		t.Fatalf("Enter did not expand the stale fold:\n%s", out)
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

// Every bucket shows everything in it. A live arc renders however old it is,
// and a closed arc stays listed until it archives — nothing is folded, so no
// header advertises a key to bring rows back.
func TestListModelNoBucketHidesItsMembers(t *testing.T) {
	m := NewListModel()
	m, _ = m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	m.SetArcs([]Arc{
		{Slug: "still-open", Status: StatusActive, Opened: daysAgo(21)},
		{Slug: "long-done", Status: StatusClosed, Opened: daysAgo(21), ClosedAt: daysAgo(20)},
		{Slug: "also-done", Status: StatusClosed, Opened: daysAgo(30), ClosedAt: daysAgo(25)},
		// Never eligible for the sweep, so the list is where it stays.
		{Slug: "dateless-done", Status: StatusClosed},
	}, 0)

	out := stripANSI(m.View())
	for _, want := range []string{"still-open", "long-done", "also-done", "dateless-done"} {
		if !strings.Contains(out, want) {
			t.Errorf("%q must render — no bucket hides its members:\n%s", want, out)
		}
	}
	if !strings.Contains(out, "Older (4)") {
		t.Errorf("the Older header must count every arc beneath it:\n%s", out)
	}
	if strings.Contains(out, "closed hidden") || strings.Contains(out, "ctrl+a") {
		t.Errorf("with nothing folded, no header may advertise a reveal key:\n%s", out)
	}
	if m.Count() != 4 {
		t.Errorf("the tab count should hold every listed arc, got %d", m.Count())
	}
}

// The first row is always a header. Stepping up onto it must leave the cursor
// on the first arc rather than stranding it on a divider.
func TestListModelUpOntoLeadingHeaderHoldsTheCursor(t *testing.T) {
	m := NewListModel()
	m, _ = m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	m.SetArcs([]Arc{
		{Slug: "fresh", Status: StatusActive, Opened: hoursAgo(1)},
		{Slug: "still-open", Status: StatusActive, Opened: daysAgo(21)},
	}, 0)
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if m.CurrentSlug() != "still-open" {
		t.Fatalf("j should step over the Older header onto the old live arc, got %q", m.CurrentSlug())
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'k', Text: "k"})
	if m.CurrentSlug() != "fresh" {
		t.Fatalf("k should step back over the header onto the first arc, got %q", m.CurrentSlug())
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'k', Text: "k"})
	if m.CurrentSlug() != "fresh" {
		t.Errorf("k onto the leading header must hold the cursor, got %q", m.CurrentSlug())
	}
}

// A section header reads as a boundary and not as another arc row: its label
// carries the accent-bold weight the work list gives its project headers, and a
// rule runs from the label out to the panel edge.
func TestListModelSectionHeadersRuleToThePanelEdge(t *testing.T) {
	const width = 80
	if sectionHeaderStyle.GetForeground() != style.ColorAccent || !sectionHeaderStyle.GetBold() {
		t.Error("section header labels must carry the accent-bold weight the work list uses")
	}

	m := NewListModel()
	m, _ = m.Update(tea.WindowSizeMsg{Width: width, Height: 30})
	m.SetArcs([]Arc{
		{Slug: "fresh", Status: StatusActive, Opened: hoursAgo(1)},
		{Slug: "older-one", Status: StatusActive, Opened: daysAgo(21)},
	}, 0)

	var header, row string
	for _, line := range strings.Split(m.View(), "\n") {
		plain := stripANSI(line)
		switch {
		case strings.Contains(plain, "Today (1)"):
			header = line
		case strings.Contains(plain, "fresh"):
			row = line
		}
	}
	if header == "" || row == "" {
		t.Fatalf("expected both a Today header and an arc row:\n%s", stripANSI(m.View()))
	}

	plain := stripANSI(header)
	if lipgloss.Width(plain) != width {
		t.Errorf("the header must span the panel, got %d of %d columns: %q", lipgloss.Width(plain), width, plain)
	}
	if !strings.HasPrefix(plain, headerRuleLead) || !strings.HasSuffix(plain, "─") {
		t.Errorf("the rule must open the line and reach the panel edge: %q", plain)
	}
	if !strings.Contains(header, sectionHeaderStyle.Render("Today (1)")) {
		t.Errorf("the header label must render in the section-header style: %q", header)
	}
	if strings.Contains(row, sectionHeaderStyle.Render("fresh")) {
		t.Errorf("an arc row must not carry the section-header style: %q", row)
	}
}

// The sweep predicate is stricter than the bucket, because its callers write to
// the record: an arc whose instant cannot be read has not been shown to be old,
// even though it still sorts and buckets under Older.
func TestArcAgedOutAtRequiresAReadableInstant(t *testing.T) {
	now := time.Date(2026, 7, 29, 9, 0, 0, 0, time.Local)
	cases := []struct {
		name string
		arc  Arc
		want bool
	}{
		{"closed three weeks back", Arc{ClosedAt: iso(now.AddDate(0, 0, -21))}, true},
		{"closed a moment past the boundary", Arc{ClosedAt: iso(time.Date(2026, 7, 22, 23, 59, 0, 0, time.Local))}, true},
		{"closed six days back", Arc{ClosedAt: iso(time.Date(2026, 7, 23, 0, 0, 0, 0, time.Local))}, false},
		{"closed this morning", Arc{ClosedAt: iso(now.Add(-2 * time.Hour))}, false},
		{"no declared instant", Arc{}, false},
		{"unparseable instant", Arc{ClosedAt: "whenever"}, false},
	}
	for _, c := range cases {
		if got := c.arc.AgedOutAt(now); got != c.want {
			t.Errorf("%s: AgedOutAt=%v want %v", c.name, got, c.want)
		}
	}
	if got := (Arc{ClosedAt: "whenever"}).BucketAt(now); got != BucketOlder {
		t.Errorf("an unreadable instant must still bucket as older, got %v", got)
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

func strptr(value string) *string { return &value }

func sizedDetail() DetailModel {
	m := NewDetailModel()
	m, _ = m.Update(tea.WindowSizeMsg{Width: 100, Height: 40})
	return m
}

func integratedDetail() DetailModel {
	m := sizedDetail()
	m.SetArc("arc-a")
	m.SetMembers([]Member{
		{Slug: "item-a", Resolved: true},
		{Slug: "item-b", Resolved: true},
	}, nil)
	m.SetLedger("## Brief\n\nCompact brief\n", "Compact brief", true)
	m.SetDigest("A decision the owner can scan.\n", true)
	m.SetBoard([]board.Row{
		{Arc: "arc-a", StreamID: "b", Label: "Second", DependsOn: []string{"a"}, Gate: "flag", Status: "pending", Verdict: "", WorkItem: strptr("item-b")},
		{Arc: "arc-a", StreamID: "a", Label: "First", Gate: "hold", Status: "done", Verdict: "full", WorkItem: strptr("item-a"), ReviewPacket: strptr("packets/a.md")},
	}, true, nil)
	m.SetEvents([]session.Event{
		{TS: "2026-08-29T12:00:00Z", Event: "needs_input", Slug: "item-a"},
		{Links: map[string]string{"work_item": "item-b"}},
	})
	return m
}

func TestDetailIntegratedBodyOrderAndUnknowns(t *testing.T) {
	m := integratedDetail()
	out := stripANSI(m.View())
	digest := strings.Index(out, "Since you left")
	brief := strings.Index(out, "Brief")
	streams := strings.Index(out, "Streams")
	ticker := strings.Index(out, "Recent activity")
	if !(digest >= 0 && digest < streams && streams < brief && brief < ticker) {
		t.Fatalf("live body must render Since you left → Streams → Brief → Recent activity:\n%s", out)
	}
	for _, want := range []string{"flagged for your review", "A decision the owner can scan.", "unknown · unknown · item-b"} {
		if !strings.Contains(out, want) {
			t.Errorf("integrated body missing explicit %q:\n%s", want, out)
		}
	}
	if holdStyle.GetForeground() == flagStyle.GetForeground() {
		t.Error("hold and flag must use distinct treatments")
	}
}

func TestDetailBoardProjectionStatesStayDistinct(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")

	m.SetBoard(nil, true, nil)
	if out := stripANSI(m.View()); !strings.Contains(out, "empty plan — no declared stream rows") {
		t.Fatalf("present empty arc did not render as an empty plan:\n%s", out)
	}

	m.SetBoard(nil, false, nil)
	if out := stripANSI(m.View()); !strings.Contains(out, "arc is absent from the coordination projection") {
		t.Fatalf("absent arc did not render as unknown:\n%s", out)
	}

	m.SetBoard(nil, false, errors.New("status unavailable"))
	if out := stripANSI(m.View()); !strings.Contains(out, "streams unknown — status unavailable") {
		t.Fatalf("load error did not remain distinct from absence:\n%s", out)
	}
}

func TestDetailDigestStatesAndClosedOrder(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	m.SetBoard([]board.Row{rowForDetail("a", "One")}, true, nil)

	m.SetDigest("", false)
	if out := stripANSI(m.View()); !strings.Contains(out, "no decisions recorded yet") {
		t.Fatalf("absent digest state missing:\n%s", out)
	}
	m.SetDigest("", true)
	if out := stripANSI(m.View()); !strings.Contains(out, "digest.md unknown — document could not be read") {
		t.Fatalf("unreadable digest state missing:\n%s", out)
	}
	m.SetDigest("**Decision:** keep the rail continuous.", true)
	m.SetClosed(true)
	out := stripANSI(m.View())
	digest := strings.Index(out, "Since you left")
	streams := strings.Index(out, "Final streams")
	if !(digest >= 0 && digest < streams) || !strings.Contains(out, "Decision:") {
		t.Fatalf("closed digest must precede final streams:\n%s", out)
	}
}

func rowForDetail(id, label string) board.Row {
	return board.Row{Arc: "arc-a", StreamID: id, Label: label, Tree: "writer", Gate: "notify", Status: "done", Verdict: "full"}
}

func TestDetailMarqueeTicksOnlyForOverflowAndResetsOnArcChange(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	m.SetBoard([]board.Row{rowForDetail("fit", "short")}, true, nil)
	if cmd := m.StartMarquee(); cmd != nil {
		t.Fatal("a fitting board must not arm a marquee tick")
	}

	m.SetBoard([]board.Row{rowForDetail("long", strings.Repeat("long label ", 20))}, true, nil)
	start := m.rendered[0].Lines[0].Text
	if cmd := m.StartMarquee(); cmd == nil || !m.marqueeTicking {
		t.Fatal("an overflowing board must arm one marquee tick")
	}
	for i := 0; i <= 15; i++ {
		generation := m.marqueeGeneration
		m, _ = m.Update(MarqueeTickMsg{arc: "arc-a", generation: generation})
	}
	if got := m.rendered[0].Lines[0].Text; got == start {
		t.Fatalf("row did not move after the start dwell:\n%s\n%s", start, got)
	}
	m.openMode(ModeLedger)
	if m.marqueeTicking || m.StartMarquee() != nil {
		t.Fatal("a document drill-in must stop and suppress marquee ticks")
	}
	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if cmd == nil || !m.marqueeTicking {
		t.Fatal("returning to the visible overflowing board must re-arm the marquee")
	}
	m.SetArc("arc-b")
	if m.marqueePhase != 0 || m.marqueeTicking {
		t.Fatalf("arc change did not reset marquee state: phase=%d ticking=%v", m.marqueePhase, m.marqueeTicking)
	}
}

func normalizeDetailGolden(value string) string {
	var lines []string
	for _, line := range strings.Split(stripANSI(value), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "─ ") {
			line = "[" + strings.Trim(strings.TrimSpace(line), "─ ") + "]"
		} else {
			line = strings.Join(strings.Fields(line), " ")
		}
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n") + "\n"
}

func TestDetailIntegratedBodyGolden(t *testing.T) {
	want, err := os.ReadFile(filepath.Join("testdata", "integrated_detail.golden"))
	if err != nil {
		t.Fatal(err)
	}
	if got := normalizeDetailGolden(integratedDetail().View()); got != string(want) {
		t.Fatalf("integrated detail golden mismatch:\n--- got ---\n%s--- want ---\n%s", got, want)
	}
}

func TestDetailSelectionPreservesStreamIdentityAcrossRefresh(t *testing.T) {
	m := integratedDetail()
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if got := m.SelectedStream(); got != "b" {
		t.Fatalf("j should select the second topological stream, got %q", got)
	}
	m.SetBoard([]board.Row{
		{Arc: "arc-a", StreamID: "a", Label: "First", Gate: "hold", Status: "done", Verdict: "full"},
		{Arc: "arc-a", StreamID: "b", Label: "Second", DependsOn: []string{"a"}, Gate: "flag", Status: "pending", Verdict: "unknown"},
	}, true, nil)
	if got := m.SelectedStream(); got != "b" {
		t.Errorf("board refresh must preserve the cursor by stream identity, got %q", got)
	}
}

func TestDetailGatePacketAndLocalBack(t *testing.T) {
	m := integratedDetail()
	m.SetReviewPackets(map[string]string{"packets/a.md": "# Owner decision\n\nChoose one.\n"})
	updated, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd != nil || updated.Mode() != ModePacket {
		t.Fatalf("readable declared packet should open locally, mode=%q cmd=%v", updated.Mode(), cmd)
	}
	if out := stripANSI(updated.View()); !strings.Contains(out, "Owner decision") {
		t.Errorf("packet drill-in must render its body:\n%s", out)
	}
	updated, _ = updated.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if updated.Mode() != ModePrimary || !strings.Contains(stripANSI(updated.View()), "Compact brief") {
		t.Error("Esc must return from the packet to the primary arc body")
	}
}

func TestDetailRowRoutingUsesSessionThenWorkWithoutGuessing(t *testing.T) {
	row := board.Row{Arc: "arc-a", StreamID: "s1", Label: "Run", Gate: "notify", Status: "pending", Verdict: "unknown", WorkItem: strptr("item-a")}
	m := sizedDetail()
	m.SetArc("arc-a")
	m.SetMembers([]Member{{Slug: "item-a", Resolved: true}}, nil)
	m.SetBoard([]board.Row{row}, true, nil)
	m.SetSessions([]sessionview.SessionRow{{RowID: "one", Slug: "item-a", Display: "one"}})
	_, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if msg, ok := cmd().(SessionSelectedMsg); !ok || msg.RowID != "one" {
		t.Fatalf("one live session should win, got %T %v", cmd(), cmd())
	}

	m.SetSessions([]sessionview.SessionRow{
		{RowID: "one", Slug: "item-a", Display: "one"},
		{RowID: "two", BaseItem: "item-a", Display: "two"},
	})
	_, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if msg, ok := cmd().(MemberSelectedMsg); !ok || msg.Slug != "item-a" {
		t.Fatalf("ambiguous sessions must fall back to declared work, got %T %v", cmd(), cmd())
	}
}

func TestDetailSessionTargetsRenderExplicitLiveScreenState(t *testing.T) {
	row := board.Row{Arc: "arc-a", StreamID: "s1", Label: "Run", Gate: "notify", Status: "pending", Verdict: "unknown", WorkItem: strptr("item-a")}
	cases := []struct {
		name string
		row  sessionview.SessionRow
		want string
	}{
		{"local", sessionview.SessionRow{RowID: "local", Slug: "item-a", Display: "local", Local: true}, "live terminal available in sessions"},
		{"remote tmux", sessionview.SessionRow{RowID: "tmux", Slug: "item-a", Display: "tmux", Tmux: "lore-b-item-a"}, "live drill-in available in sessions"},
		{"remote unknown", sessionview.SessionRow{RowID: "bare", Slug: "item-a", Display: "bare"}, "live screen unavailable — tmux identity unknown"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := sizedDetail()
			m.SetArc("arc-a")
			m.SetMembers([]Member{{Slug: "item-a", Resolved: true}}, nil)
			m.SetBoard([]board.Row{row}, true, nil)
			m.SetSessions([]sessionview.SessionRow{tc.row})
			if got := m.targetSummary(row); !strings.Contains(got, tc.want) {
				t.Fatalf("session target summary %q missing %q", got, tc.want)
			}
			out := stripANSI(m.View())
			wantLive := tc.row.Tmux != ""
			if strings.Contains(out, " · live") != wantLive {
				t.Fatalf("pinned live status mismatch (want %v):\n%s", wantLive, out)
			}
			if strings.Contains(out, "target session") {
				t.Fatalf("per-row target summary must not render:\n%s", out)
			}
		})
	}
}

func TestDetailUndeclaredWorkTargetStaysUnknown(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	m.SetBoard([]board.Row{{
		Arc: "arc-a", StreamID: "s1", Label: "Foreign", Gate: "notify",
		Status: "pending", Verdict: "unknown", WorkItem: strptr("not-a-member"),
	}}, true, nil)
	m.SetSessions([]sessionview.SessionRow{{RowID: "wrong", Slug: "not-a-member", Display: "wrong"}})
	updated, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd != nil {
		t.Fatalf("undeclared target must not navigate, got %T", cmd())
	}
	if got := updated.targetSummary(updated.rows[0]); !strings.Contains(got, "not an arc member") || !strings.Contains(got, "target unknown") {
		t.Errorf("undeclared resolution must stay explicit off-screen: %s", got)
	}
	if out := stripANSI(updated.View()); strings.Contains(out, "target unknown") {
		t.Errorf("per-row target summary must be absent from the board:\n%s", out)
	}
}

func TestDetailClosedAndLiveReportModesStayDistinct(t *testing.T) {
	m := integratedDetail()
	m.SetReport("# Report\n\nEarlier report\n", true)
	if strings.Contains(stripANSI(m.View()), "Earlier report") {
		t.Error("a live arc's present report must not replace its Brief")
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'r', Text: "r"})
	if m.Mode() != ModeReport || !strings.Contains(stripANSI(m.View()), "Earlier report") {
		t.Error("a live report must remain reachable as a local drill-in")
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	m.SetClosed(true)
	out := stripANSI(m.View())
	if strings.Contains(out, "Earlier report") || strings.Contains(out, "Compact brief") {
		t.Errorf("a closed arc's primary body must omit inline report and Brief:\n%s", out)
	}
	digest := strings.Index(out, "Since you left")
	streams := strings.Index(out, "Final streams")
	graph := strings.Index(out, "First")
	if !(digest >= 0 && digest < streams && streams < graph) {
		t.Errorf("a closed arc must render its digest then final DAG:\n%s", out)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'r', Text: "r"})
	if m.Mode() != ModeReport || !strings.Contains(stripANSI(m.View()), "Earlier report") {
		t.Error("a closed report must remain reachable as a local drill-in")
	}
}

func TestFilterEventsMatchesBothIdentityKeysAndBoundsTail(t *testing.T) {
	events := []session.Event{
		{EventID: "drop", Slug: "other"},
		{EventID: "direct", Slug: "item-a"},
		{EventID: "worker", Slug: "item-a--w1", Links: map[string]string{"work_item": "item-a"}},
		{EventID: "latest", Links: map[string]string{"work_item": "item-a"}},
	}
	got := FilterEvents(events, []string{"item-a"}, 2)
	if len(got) != 2 || got[0].EventID != "worker" || got[1].EventID != "latest" {
		t.Fatalf("filter must use both keys and retain the last bounded rows, got %+v", got)
	}
}

func TestLatestEventTimesUsesExistingJournalGenerationForEveryArc(t *testing.T) {
	events := []session.Event{
		{TS: "2026-08-20T10:00:00Z", Slug: "item-a"},
		{TS: "2026-08-21T10:00:00Z", Slug: "item-a--w1", Links: map[string]string{"work_item": "item-a"}},
		{TS: "not-an-instant", Slug: "item-b"},
		{TS: "2026-08-22T10:00:00Z", Slug: "unrelated"},
	}
	got := LatestEventTimes(events, []Arc{
		{Slug: "arc-a", Members: []string{"item-a"}},
		{Slug: "arc-b", Members: []string{"item-b"}},
	})
	if got["arc-a"] != "2026-08-21T10:00:00Z" {
		t.Fatalf("arc-a latest = %q, want worker-linked latest event", got["arc-a"])
	}
	if _, ok := got["arc-b"]; ok {
		t.Fatalf("unparseable timestamps must remain absent, got %#v", got)
	}
}

func TestReadReviewPacketRequiresContainedMarkdown(t *testing.T) {
	workDir := t.TempDir()
	arcDir := ArcDir(workDir, "arc-a")
	if err := os.MkdirAll(filepath.Join(arcDir, "packets"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(arcDir, "packets", "read.md"), []byte("safe"), 0o644); err != nil {
		t.Fatal(err)
	}
	if body, ok := ReadReviewPacket(workDir, "arc-a", "packets/read.md"); !ok || body != "safe" {
		t.Fatalf("safe declared packet = %q,%v", body, ok)
	}
	for _, ref := range []string{"../outside.md", "/tmp/outside.md", "packets/read.txt", "packets/missing.md"} {
		if _, ok := ReadReviewPacket(workDir, "arc-a", ref); ok {
			t.Errorf("unsafe or unreadable packet %q must not open", ref)
		}
	}
}
