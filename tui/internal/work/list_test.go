package work

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

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
