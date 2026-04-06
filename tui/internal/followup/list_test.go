package followup

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// sampleItems returns a slice of FollowUpItems covering all statuses for test use.
func sampleItems() []FollowUpItem {
	return []FollowUpItem{
		{ID: "open-1", Title: "Open One", Status: "open", Source: "pr", Updated: "2026-03-01T00:00:00Z"},
		{ID: "pending-1", Title: "Pending One", Status: "pending", Source: "ci", Updated: "2026-03-02T00:00:00Z"},
		{ID: "reviewed-1", Title: "Reviewed One", Status: "reviewed", Source: "review", Updated: "2026-03-03T00:00:00Z"},
		{ID: "promoted-1", Title: "Promoted One", Status: "promoted", Source: "manual", Updated: "2026-03-04T00:00:00Z"},
		{ID: "dismissed-1", Title: "Dismissed One", Status: "dismissed", Source: "bot", Updated: "2026-03-05T00:00:00Z"},
	}
}

// --- visibleItems / filtering ---

func TestListModelFilterActiveShowsOpenAndPending(t *testing.T) {
	m := NewListModel(sampleItems())
	visible := m.visibleItems()
	for _, item := range visible {
		if item.Status != "open" && item.Status != "pending" {
			t.Errorf("FilterActive: got unexpected status %q for item %q", item.Status, item.ID)
		}
	}
	if len(visible) != 2 {
		t.Errorf("FilterActive: got %d items, want 2 (open + pending)", len(visible))
	}
}

func TestListModelFollowUpCountMatchesVisible(t *testing.T) {
	m := NewListModel(sampleItems())
	if m.FollowUpCount() != 2 {
		t.Errorf("FollowUpCount (active) = %d, want 2", m.FollowUpCount())
	}
}

func TestListModelItemsMatchesVisibleItems(t *testing.T) {
	m := NewListModel(sampleItems())
	if len(m.Items()) != len(m.visibleItems()) {
		t.Errorf("Items() len %d != visibleItems() len %d", len(m.Items()), len(m.visibleItems()))
	}
}

// --- CurrentID / CurrentItem ---

func TestListModelCurrentIDAtStart(t *testing.T) {
	m := NewListModel(sampleItems())
	id := m.CurrentID()
	visible := m.visibleItems()
	if len(visible) == 0 {
		t.Skip("no visible items")
	}
	if id != visible[0].ID {
		t.Errorf("CurrentID = %q, want %q", id, visible[0].ID)
	}
}

func TestListModelCurrentIDEmptyList(t *testing.T) {
	m := NewListModel([]FollowUpItem{})
	if m.CurrentID() != "" {
		t.Errorf("CurrentID should be empty for empty list, got %q", m.CurrentID())
	}
}

func TestListModelCurrentItemEmptyList(t *testing.T) {
	m := NewListModel([]FollowUpItem{})
	_, ok := m.CurrentItem()
	if ok {
		t.Error("CurrentItem should return ok=false for empty list")
	}
}

// --- keyboard navigation ---

func TestListModelKeyDownMovesCursor(t *testing.T) {
	m := NewListModel(sampleItems())
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("j")})
	if m.Cursor() != 1 {
		t.Errorf("cursor after j = %d, want 1", m.Cursor())
	}
}

func TestListModelKeyUpBoundedAtZero(t *testing.T) {
	m := NewListModel(sampleItems())
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("k")})
	if m.Cursor() != 0 {
		t.Errorf("cursor after k at 0 = %d, want 0 (bounded)", m.Cursor())
	}
}

func TestListModelKeyGGoesToStart(t *testing.T) {
	m := NewListModel(sampleItems())
	// Move to end, then g.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("G")})
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("g")})
	if m.Cursor() != 0 {
		t.Errorf("cursor after G then g = %d, want 0", m.Cursor())
	}
}

func TestListModelKeyCapGGoesToEnd(t *testing.T) {
	m := NewListModel(sampleItems())
	visible := m.visibleItems()
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("G")})
	if m.Cursor() != len(visible)-1 {
		t.Errorf("cursor after G = %d, want %d", m.Cursor(), len(visible)-1)
	}
}

func TestListModelKeyDownEmitsPrefetch(t *testing.T) {
	m := NewListModel(sampleItems())
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("j")})
	if cmd == nil {
		t.Fatal("moving cursor down should emit a Cmd (hover-prefetch)")
	}
	msg := cmd()
	ldm, ok := msg.(LoadDetailMsg)
	if !ok {
		t.Fatalf("cmd() returned %T, want LoadDetailMsg", msg)
	}
	visible := m.visibleItems()
	if ldm.ID != visible[1].ID {
		t.Errorf("LoadDetailMsg.ID = %q, want %q", ldm.ID, visible[1].ID)
	}
}

func TestListModelEnterEmitsSelectedMsg(t *testing.T) {
	m := NewListModel(sampleItems())
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("Enter should emit a Cmd")
	}
	msg := cmd()
	sel, ok := msg.(FollowUpSelectedMsg)
	if !ok {
		t.Fatalf("cmd() returned %T, want FollowUpSelectedMsg", msg)
	}
	visible := m.visibleItems()
	if sel.Item.ID != visible[0].ID {
		t.Errorf("FollowUpSelectedMsg.Item.ID = %q, want %q", sel.Item.ID, visible[0].ID)
	}
}

func TestListModelEscEmitsDismissedMsg(t *testing.T) {
	m := NewListModel(sampleItems())
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd == nil {
		t.Fatal("Esc should emit a Cmd")
	}
	msg := cmd()
	if _, ok := msg.(ListDismissedMsg); !ok {
		t.Fatalf("cmd() returned %T, want ListDismissedMsg", msg)
	}
}

// --- SetItems ---

func TestListModelSetItemsUpdatesVisible(t *testing.T) {
	m := NewListModel(sampleItems())
	m.SetItems([]FollowUpItem{
		{ID: "new-1", Title: "New One", Status: "open", Source: "test"},
	})
	if m.FollowUpCount() != 1 {
		t.Errorf("after SetItems, FollowUpCount = %d, want 1", m.FollowUpCount())
	}
	if m.CurrentID() != "new-1" {
		t.Errorf("CurrentID = %q, want %q", m.CurrentID(), "new-1")
	}
}

func TestListModelSetItemsClampsCursor(t *testing.T) {
	m := NewListModel(sampleItems())
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("j")})
	// Replace with a single-item list — cursor should clamp to 0.
	m.SetItems([]FollowUpItem{
		{ID: "only", Title: "Only", Status: "open", Source: "test"},
	})
	if m.Cursor() != 0 {
		t.Errorf("cursor after SetItems shrink = %d, want 0", m.Cursor())
	}
}

// --- SetCursorByID ---

func TestListModelSetCursorByID(t *testing.T) {
	m := NewListModel(sampleItems())
	visible := m.visibleItems()
	if len(visible) < 2 {
		t.Skip("need at least 2 visible items")
	}
	m.SetCursorByID(visible[1].ID)
	if m.Cursor() != 1 {
		t.Errorf("cursor after SetCursorByID = %d, want 1", m.Cursor())
	}
}

func TestListModelSetCursorByIDMissingIsNoOp(t *testing.T) {
	m := NewListModel(sampleItems())
	m.SetCursorByID("does-not-exist")
	if m.Cursor() != 0 {
		t.Errorf("cursor after SetCursorByID(missing) = %d, want 0 (unchanged)", m.Cursor())
	}
}

// --- compact / full mode rendering ---

func TestListModelSetCompactMode(t *testing.T) {
	m := NewListModel(sampleItems())
	m.SetCompactMode(true)
	if !m.compactMode {
		t.Error("compactMode should be true after SetCompactMode(true)")
	}
	m.SetCompactMode(false)
	if m.compactMode {
		t.Error("compactMode should be false after SetCompactMode(false)")
	}
}

func TestListModelViewCompactContainsSlugs(t *testing.T) {
	m := NewListModel(sampleItems())
	m.SetCompactMode(true)
	m.width = 80
	m.height = 20
	view := m.View()
	for _, item := range m.visibleItems() {
		if !strings.Contains(view, item.ID) {
			t.Errorf("compact view missing slug %q", item.ID)
		}
	}
}

func TestListModelViewFullContainsSlugs(t *testing.T) {
	m := NewListModel(sampleItems())
	m.SetCompactMode(false)
	m.width = 120
	m.height = 20
	view := m.View()
	for _, item := range m.visibleItems() {
		if !strings.Contains(view, item.ID) {
			t.Errorf("full view missing slug %q", item.ID)
		}
	}
}

func TestListModelViewCompactEmptyList(t *testing.T) {
	m := NewListModel([]FollowUpItem{})
	m.SetCompactMode(true)
	m.width = 80
	m.height = 20
	view := m.View()
	if !strings.Contains(view, "No") {
		t.Errorf("compact view for empty list should contain 'No', got: %q", view)
	}
}
