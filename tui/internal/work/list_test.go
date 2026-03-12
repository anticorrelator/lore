package work

import (
	"strings"
	"testing"
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
