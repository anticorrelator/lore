package work

import (
	"regexp"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/gh"
	"github.com/anticorrelator/lore/tui/internal/style"
)

// lipgloss v2 always emits ANSI from Style.Render (profile degradation
// happens in the program writer): text assertions strip SGR first, and
// color-routing assertions pin a substring to a token's opening sequence.
var listANSIPattern = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func stripListANSI(s string) string {
	return listANSIPattern.ReplaceAllString(s, "")
}

// sgrOpen returns the opening SGR sequence a style emits before its text.
func sgrOpen(st lipgloss.Style) string {
	r := st.Render("|")
	return r[:strings.Index(r, "|")]
}

func newTestListModel(items []WorkItem) ListModel {
	m := NewListModel(items)
	m.width = 120
	m.height = 20
	return m
}

func TestCompactNeedsInputShowsBullet(t *testing.T) {
	items := []WorkItem{
		{Slug: "my-item", Title: "My Item", Status: "active", Updated: "2026-01-01"},
	}
	m := newTestListModel(items)
	m.compactMode = true
	m.specActiveSlugs = map[string]bool{"my-item": true}
	m.specNeedsInputSlugs = map[string]bool{"my-item": true}

	view := m.View()
	if !strings.Contains(view, "●") {
		t.Fatalf("expected ● glyph in compact view, got:\n%s", view)
	}
	// Should NOT contain the old diamond glyph for this item's attention indicator.
	// (External sessions use ◆, but this item is not external.)
}

func TestCompactActiveNoNeedsInputNoBullet(t *testing.T) {
	items := []WorkItem{
		{Slug: "my-item", Title: "My Item", Status: "active", Updated: "2026-01-01"},
	}
	m := newTestListModel(items)
	m.compactMode = true
	m.specActiveSlugs = map[string]bool{"my-item": true}
	m.specNeedsInputSlugs = map[string]bool{"my-item": false}

	view := m.View()
	if strings.Contains(view, "●") {
		t.Fatalf("should not show ● when needsInput is false, got:\n%s", view)
	}
}

func TestCompactExternalSessionShowsDiamond(t *testing.T) {
	items := []WorkItem{
		{Slug: "ext-item", Title: "External", Status: "active", Updated: "2026-01-01"},
	}
	m := newTestListModel(items)
	m.compactMode = true
	m.externalActiveSlugs = map[string]bool{"ext-item": true}

	view := m.View()
	if !strings.Contains(view, "◆") {
		t.Fatalf("expected dim ◆ glyph for external session, got:\n%s", view)
	}
}

func TestFullNeedsInputShowsDotColumn(t *testing.T) {
	items := []WorkItem{
		{Slug: "my-item", Title: "My Item", Status: "active", Updated: "2026-01-01"},
	}
	m := newTestListModel(items)
	m.compactMode = false
	m.specActiveSlugs = map[string]bool{"my-item": true}
	m.specNeedsInputSlugs = map[string]bool{"my-item": true}

	view := m.View()
	// ● moves to the dot column (before slug), readiness shows "speccing"
	if !strings.Contains(view, "●") {
		t.Fatalf("expected ● glyph in dot column of full view, got:\n%s", view)
	}
	if strings.Contains(view, "attention") {
		t.Fatalf("should not show 'attention' in readiness column, got:\n%s", view)
	}
	if !strings.Contains(view, "speccing") {
		t.Fatalf("expected 'speccing' in readiness column when specActive && needsInput, got:\n%s", view)
	}
}

func TestFullActiveNoNeedsInputShowsSpeccing(t *testing.T) {
	items := []WorkItem{
		{Slug: "my-item", Title: "My Item", Status: "active", Updated: "2026-01-01"},
	}
	m := newTestListModel(items)
	m.compactMode = false
	m.specActiveSlugs = map[string]bool{"my-item": true}
	m.specNeedsInputSlugs = map[string]bool{"my-item": false}

	view := m.View()
	if !strings.Contains(view, "speccing") {
		t.Fatalf("expected 'speccing' in full view when not needs input, got:\n%s", view)
	}
	if strings.Contains(view, "attention") {
		t.Fatalf("should not show 'attention' when needsInput is false, got:\n%s", view)
	}
}

func TestFullExternalSessionShowsDiamondActive(t *testing.T) {
	items := []WorkItem{
		{Slug: "ext-item", Title: "External", Status: "active", Updated: "2026-01-01"},
	}
	m := newTestListModel(items)
	m.compactMode = false
	m.externalActiveSlugs = map[string]bool{"ext-item": true}

	view := m.View()
	if !strings.Contains(view, "◆ active") {
		t.Fatalf("expected '◆ active' for external session in full view, got:\n%s", view)
	}
}

// TestFullNeedsInputReadinessPreserved verifies that when an item is in the
// attention state (specActive && needsInput), the readiness column still shows
// readiness/activity info ("speccing") and the ● dot appears separately in the
// dot column — they coexist, not replace each other.
func TestFullNeedsInputReadinessPreserved(t *testing.T) {
	items := []WorkItem{
		{Slug: "my-item", Title: "My Item", Status: "active", HasTasks: true, Updated: "2026-01-01"},
	}
	m := newTestListModel(items)
	m.compactMode = false
	m.specActiveSlugs = map[string]bool{"my-item": true}
	m.specNeedsInputSlugs = map[string]bool{"my-item": true}

	view := m.View()
	// ● must appear in dot column
	if !strings.Contains(view, "●") {
		t.Fatalf("expected ● glyph in dot column, got:\n%s", view)
	}
	// Readiness/activity info must also be present (speccing, not replaced by attention)
	if !strings.Contains(view, "speccing") {
		t.Fatalf("expected readiness column to show 'speccing', got:\n%s", view)
	}
	// "attention" text must NOT appear in readiness column
	if strings.Contains(view, "attention") {
		t.Fatalf("'attention' text should not appear in readiness column, got:\n%s", view)
	}
}

// --- Status ramp routing (style.Status* tokens) ---

func TestReadinessLabelRoutesThroughStatusRamp(t *testing.T) {
	cases := []struct {
		name      string
		item      WorkItem
		wantLabel string
		wantStyle lipgloss.Style
	}{
		{"archived", WorkItem{Status: "archived"}, "archived", style.StatusDone},
		{"ready", WorkItem{Status: "active", HasTasks: true}, "ready", style.StatusReady},
		{"needs tasks", WorkItem{Status: "active", HasPlanDoc: true}, "needs tasks", style.StatusWarn},
		{"needs spec", WorkItem{Status: "active"}, "needs spec", style.StatusDisabled},
	}
	for _, c := range cases {
		label, st := readinessLabel(c.item)
		if label != c.wantLabel {
			t.Errorf("%s: label = %q, want %q", c.name, label, c.wantLabel)
		}
		if got, want := st.GetForeground(), c.wantStyle.GetForeground(); got != want {
			t.Errorf("%s: foreground = %v, want %v", c.name, got, want)
		}
		if got, want := st.GetItalic(), c.wantStyle.GetItalic(); got != want {
			t.Errorf("%s: italic = %v, want %v", c.name, got, want)
		}
	}
}

func TestFullViewReadinessUsesStatusRampColor(t *testing.T) {
	items := []WorkItem{
		{Slug: "ready-item", Title: "Ready", Status: "active", HasTasks: true, Updated: "2026-01-01"},
	}
	m := newTestListModel(items)

	view := m.View()
	if !strings.Contains(view, sgrOpen(style.StatusReady)+"ready") {
		t.Fatalf("readiness label should open with the StatusReady sequence, got:\n%s", view)
	}
}

func TestFullViewSpeccingUsesStatusActive(t *testing.T) {
	items := []WorkItem{
		{Slug: "my-item", Title: "My Item", Status: "active", Updated: "2026-01-01"},
	}
	m := newTestListModel(items)
	m.specActiveSlugs = map[string]bool{"my-item": true}

	view := m.View()
	if !strings.Contains(view, sgrOpen(style.StatusActive)+"speccing") {
		t.Fatalf("speccing label should open with the StatusActive sequence, got:\n%s", view)
	}
}

func TestNeedsInputDotUsesAttentionColor(t *testing.T) {
	items := []WorkItem{
		{Slug: "my-item", Title: "My Item", Status: "active", Updated: "2026-01-01"},
	}
	m := newTestListModel(items)
	m.specActiveSlugs = map[string]bool{"my-item": true}
	m.specNeedsInputSlugs = map[string]bool{"my-item": true}

	want := lipgloss.NewStyle().Foreground(style.ColorAttention).Render("●")
	if view := m.View(); !strings.Contains(view, want) {
		t.Fatalf("needs-input dot should render in ColorAttention, got:\n%s", view)
	}
}

func TestPRBadgeStateColors(t *testing.T) {
	m := newTestListModel(nil)
	m.prLoaded = true
	m.prStatus = map[string]gh.PRStatus{
		"pr-open":   {Number: 7, State: "OPEN"},
		"pr-merged": {Number: 8, State: "MERGED"},
		"pr-closed": {Number: 9, State: "CLOSED"},
	}

	if got := m.prBadge("pr-open", 10); !strings.HasPrefix(got, sgrOpen(style.StatusReady)) {
		t.Errorf("open PR badge should use StatusReady, got %q", got)
	}
	if got := m.prBadge("pr-closed", 10); !strings.HasPrefix(got, sgrOpen(style.StatusError)) {
		t.Errorf("closed PR badge should use StatusError, got %q", got)
	}
	// Merged keeps its purple — distinct from the dim "--" no-PR placeholder.
	if got := m.prBadge("pr-merged", 10); !strings.HasPrefix(got, sgrOpen(prMergedStyle)) {
		t.Errorf("merged PR badge should keep the merged purple, got %q", got)
	}
}

// --- Three-tier indicator priority (speccing > external session > readiness) ---

// Local speccing outranks an external session for the same slug, in both
// render modes — the two indicators never show together.
func TestStatusIndicatorPriorityLocalOverExternal(t *testing.T) {
	items := []WorkItem{
		{Slug: "both", Title: "Both", Status: "active", Updated: "2026-01-01"},
	}
	for _, compact := range []bool{true, false} {
		m := newTestListModel(items)
		m.compactMode = compact
		m.specActiveSlugs = map[string]bool{"both": true}
		m.specNeedsInputSlugs = map[string]bool{"both": false}
		m.externalActiveSlugs = map[string]bool{"both": true}

		view := stripListANSI(m.View())
		if !strings.Contains(view, "speccing") {
			t.Errorf("compact=%v: local speccing should win over external, got:\n%s", compact, view)
		}
		if strings.Contains(view, "◆") {
			t.Errorf("compact=%v: external diamond must not show while speccing locally, got:\n%s", compact, view)
		}
	}
}

// An external session outranks the readiness label.
func TestStatusIndicatorPriorityExternalOverReadiness(t *testing.T) {
	items := []WorkItem{
		{Slug: "ext", Title: "External", Status: "active", HasTasks: true, Updated: "2026-01-01"},
	}
	m := newTestListModel(items)
	m.externalActiveSlugs = map[string]bool{"ext": true}

	view := stripListANSI(m.View())
	if !strings.Contains(view, "◆ active") {
		t.Fatalf("external session should show '◆ active', got:\n%s", view)
	}
	// Skip the header line — "READINESS" would false-match "ready" checks.
	for _, line := range strings.Split(view, "\n")[1:] {
		if strings.Contains(line, "ready") {
			t.Fatalf("readiness label should be replaced by the external indicator, got:\n%s", view)
		}
	}
}

// --- Status-bar keybind contract (panelLeft hints) ---

func contractItems() []WorkItem {
	return []WorkItem{
		{Slug: "one", Title: "One", Status: "active"},
		{Slug: "two", Title: "Two", Status: "active"},
		{Slug: "old", Title: "Old", Status: "archived"},
	}
}

// "j/k navigate"
func TestListModelJKMoveCursor(t *testing.T) {
	m := newTestListModel(contractItems())
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if m.Cursor() != 1 {
		t.Fatalf("j should move the cursor down, got %d", m.Cursor())
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'k', Text: "k"})
	if m.Cursor() != 0 {
		t.Fatalf("k should move the cursor up, got %d", m.Cursor())
	}
}

// "Enter open detail"
func TestListModelEnterEmitsItemSelected(t *testing.T) {
	m := newTestListModel(contractItems())
	_, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("Enter should emit a selection command")
	}
	msg, ok := cmd().(ItemSelectedMsg)
	if !ok {
		t.Fatalf("Enter produced %T, want ItemSelectedMsg", cmd())
	}
	if msg.Item.Slug != "one" {
		t.Errorf("selected slug = %q, want one", msg.Item.Slug)
	}
}

// "s run spec"
func TestListModelSEmitsSpecRequest(t *testing.T) {
	m := newTestListModel(contractItems())
	_, cmd := m.Update(tea.KeyPressMsg{Code: 's', Text: "s"})
	if cmd == nil {
		t.Fatal("s should emit a spec request")
	}
	msg, ok := cmd().(SpecRequestMsg)
	if !ok {
		t.Fatalf("s produced %T, want SpecRequestMsg", cmd())
	}
	if msg.Slug != "one" {
		t.Errorf("spec slug = %q, want one", msg.Slug)
	}
}

// "c chat about spec"
func TestListModelCEmitsChatRequest(t *testing.T) {
	m := newTestListModel(contractItems())
	_, cmd := m.Update(tea.KeyPressMsg{Code: 'c', Text: "c"})
	if cmd == nil {
		t.Fatal("c should emit a chat request")
	}
	if _, ok := cmd().(ChatRequestMsg); !ok {
		t.Fatalf("c produced %T, want ChatRequestMsg", cmd())
	}
}

// --- Project grouping (group headers, collapse, flat-tail regression) ---

// groupedItems is recency-sorted (as LoadIndex guarantees) with two labeled
// projects, an ungrouped tail, and archived members in both projects.
func groupedItems() []WorkItem {
	return []WorkItem{
		{Slug: "beta-1", Title: "Beta One", Status: "active", Project: "beta", Updated: "2026-06-10T12:00:00Z"},
		{Slug: "alpha-1", Title: "Alpha One", Status: "active", Project: "alpha", Updated: "2026-06-09T12:00:00Z"},
		{Slug: "beta-2", Title: "Beta Two", Status: "active", Project: "beta", Updated: "2026-06-08T12:00:00Z"},
		{Slug: "loose-1", Title: "Loose One", Status: "active", Updated: "2026-06-07T12:00:00Z"},
		{Slug: "alpha-old", Title: "Alpha Old", Status: "archived", Project: "alpha", Updated: "2026-06-06T12:00:00Z"},
		{Slug: "loose-2", Title: "Loose Two", Status: "active", Updated: "2026-06-05T12:00:00Z"},
		{Slug: "beta-old", Title: "Beta Old", Status: "archived", Project: "beta", Updated: "2026-06-04T12:00:00Z"},
	}
}

func TestGroupByProjectSectionsByRecencyUngroupedTailLast(t *testing.T) {
	groups := GroupByProject(groupedItems())
	if len(groups) != 3 {
		t.Fatalf("expected 3 sections (beta, alpha, ungrouped), got %d: %+v", len(groups), groups)
	}
	if groups[0].Project != "beta" || groups[1].Project != "alpha" {
		t.Errorf("sections should follow most-recent-member order, got %q, %q", groups[0].Project, groups[1].Project)
	}
	if groups[2].Project != "" {
		t.Errorf("ungrouped tail must be last, got %q", groups[2].Project)
	}
	tail := groups[2].Items
	if len(tail) != 2 || tail[0].Slug != "loose-1" || tail[1].Slug != "loose-2" {
		t.Errorf("ungrouped tail should preserve input (recency) order, got %+v", tail)
	}
	if got := len(groups[0].Items); got != 3 {
		t.Errorf("beta section should hold all 3 members pre-filter, got %d", got)
	}
}

// The cursor starts on the first item row, not the leading group header, so
// the detail panel has a selection from the first frame.
func TestListModelInitialCursorOnFirstItem(t *testing.T) {
	m := newTestListModel(groupedItems())
	if got := m.CurrentSlug(); got != "beta-1" {
		t.Fatalf("initial selection = %q, want beta-1", got)
	}
}

func TestListModelGroupsDefaultExpanded(t *testing.T) {
	m := newTestListModel(groupedItems())
	view := stripListANSI(m.View())
	for _, slug := range []string{"beta-1", "beta-2", "alpha-1", "loose-1", "loose-2"} {
		if !strings.Contains(view, slug) {
			t.Errorf("expanded-by-default view should show %q, got:\n%s", slug, view)
		}
	}
	if strings.Contains(view, "▶") {
		t.Errorf("no group should start collapsed, got:\n%s", view)
	}
}

// Header rows render "<project> (n)" with the visible (filtered) member count.
func TestListModelHeaderShowsVisibleMemberCount(t *testing.T) {
	m := newTestListModel(groupedItems())
	view := stripListANSI(m.View())
	if !strings.Contains(view, "beta (2)") || !strings.Contains(view, "alpha (1)") {
		t.Fatalf("active filter should show 'beta (2)' and 'alpha (1)', got:\n%s", view)
	}
}

// Border annotation "ctrl+a  active · archived" — toggling the filter
// recomputes groups and counts for the selected set.
func TestListModelCtrlARecomputesGroupsAndCounts(t *testing.T) {
	m := newTestListModel(groupedItems())
	m, _ = m.Update(tea.KeyPressMsg{Code: 'a', Mod: tea.ModCtrl})
	view := stripListANSI(m.View())
	if !strings.Contains(view, "alpha (1)") || !strings.Contains(view, "beta (1)") {
		t.Fatalf("archived filter should show 'alpha (1)' and 'beta (1)', got:\n%s", view)
	}
	if strings.Contains(view, "beta (2)") {
		t.Fatalf("active-filter count must not survive the toggle, got:\n%s", view)
	}
	if got := m.CurrentSlug(); got != "alpha-old" {
		t.Errorf("cursor should reset to the first archived item, got %q", got)
	}
}

// "Enter open detail" — contextual on a group header: Enter toggles collapse
// in-model (no command), and j/k then skip the hidden members.
func TestListModelEnterOnHeaderTogglesCollapse(t *testing.T) {
	m := newTestListModel(groupedItems())
	// k from the first item lands on the beta header.
	m, _ = m.Update(tea.KeyPressMsg{Code: 'k', Text: "k"})
	if _, ok := m.CurrentItem(); ok {
		t.Fatal("precondition: cursor should be on the beta group header")
	}

	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd != nil {
		t.Fatal("Enter on a header must toggle collapse, not emit a command")
	}
	view := stripListANSI(m.View())
	if !strings.Contains(view, "▶ beta (2)") {
		t.Fatalf("collapsed header should show ▶ with unchanged count, got:\n%s", view)
	}
	if strings.Contains(view, "beta-1") || strings.Contains(view, "beta-2") {
		t.Fatalf("collapsed members must not render, got:\n%s", view)
	}

	// j from the collapsed header skips its members: next stop is the alpha
	// header, then alpha's first item.
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if _, ok := m.CurrentItem(); ok {
		t.Fatalf("j should land on the alpha header, got item %q", m.CurrentSlug())
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if got := m.CurrentSlug(); got != "alpha-1" {
		t.Fatalf("j should skip collapsed beta members to alpha-1, got %q", got)
	}

	// Enter on the header again re-expands.
	m, _ = m.Update(tea.KeyPressMsg{Code: 'k', Text: "k"})
	m, _ = m.Update(tea.KeyPressMsg{Code: 'k', Text: "k"})
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	view = stripListANSI(m.View())
	if !strings.Contains(view, "▼ beta (2)") || !strings.Contains(view, "beta-1") {
		t.Fatalf("re-expanded group should show ▼ and its members, got:\n%s", view)
	}
}

// "Enter open detail" — on an item row inside a group, Enter still selects.
func TestListModelEnterOnGroupedItemStillSelects(t *testing.T) {
	m := newTestListModel(groupedItems())
	_, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("Enter on an item should emit a selection command")
	}
	msg, ok := cmd().(ItemSelectedMsg)
	if !ok {
		t.Fatalf("Enter produced %T, want ItemSelectedMsg", cmd())
	}
	if msg.Item.Slug != "beta-1" {
		t.Errorf("selected slug = %q, want beta-1", msg.Item.Slug)
	}
}

// "s run spec" / "c chat about spec" — no-ops on a group header.
func TestListModelSCNoopOnHeader(t *testing.T) {
	m := newTestListModel(groupedItems())
	m, _ = m.Update(tea.KeyPressMsg{Code: 'k', Text: "k"}) // beta header
	if _, cmd := m.Update(tea.KeyPressMsg{Code: 's', Text: "s"}); cmd != nil {
		t.Error("s on a header should not emit a spec request")
	}
	if _, cmd := m.Update(tea.KeyPressMsg{Code: 'c', Text: "c"}); cmd != nil {
		t.Error("c on a header should not emit a chat request")
	}
}

// Regression: a list with no projects renders the same flat list as before
// grouping existed — no header rows, input order, one cursor stop per item.
func TestListModelUngroupedOnlyRendersFlat(t *testing.T) {
	for _, compact := range []bool{true, false} {
		m := newTestListModel(contractItems())
		m.compactMode = compact

		view := stripListANSI(m.View())
		if strings.Contains(view, "▼") || strings.Contains(view, "▶") {
			t.Fatalf("compact=%v: ungrouped-only list must not render group headers, got:\n%s", compact, view)
		}
		if one, two := strings.Index(view, "One"), strings.Index(view, "Two"); compact && (one < 0 || two < 0 || one > two) {
			t.Errorf("items should keep input order, got:\n%s", view)
		}

		// Cursor stops are exactly the items, in order.
		if got := m.CurrentSlug(); got != "one" {
			t.Errorf("compact=%v: initial selection = %q, want one", compact, got)
		}
		m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
		if got := m.CurrentSlug(); got != "two" {
			t.Errorf("compact=%v: j selection = %q, want two", compact, got)
		}
	}
}

// Border annotation "ctrl+a  active · archived"
func TestListModelCtrlAToggleActiveArchivedFilter(t *testing.T) {
	m := newTestListModel(contractItems())
	if m.GetFilterMode() != FilterActive {
		t.Fatal("precondition: list starts on the active filter")
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'a', Mod: tea.ModCtrl})
	if m.GetFilterMode() != FilterArchived {
		t.Error("ctrl+a should switch to the archived filter")
	}
	if len(m.Items()) != 1 || m.Items()[0].Slug != "old" {
		t.Errorf("archived filter should show only the archived item, got %v", m.Items())
	}
}
