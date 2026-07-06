package sessionview

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

func TestChatDisplayID(t *testing.T) {
	cases := map[string]string{
		"":                                     "chat:?",
		"8a3f2c1d-dead-beef-0000-111122223333": "chat:8a3f2c1d",
		"short":                                "chat:short",
	}
	for in, want := range cases {
		if got := ChatDisplayID(in); got != want {
			t.Errorf("ChatDisplayID(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestListGroupsWorkersUnderBase verifies derived-slug workers render under a
// base-item header while standalone sessions render flat, and that the cursor
// lands on a selectable session row (never a header) from the first frame.
func TestListGroupsWorkersUnderBase(t *testing.T) {
	m := NewListModel()
	m.SetSessions([]SessionRow{
		{RowID: "a|impl-foo--w1|s1", Slug: "impl-foo--w1", Display: "impl-foo--w1", BaseItem: "impl-foo", Local: true},
		{RowID: "a|impl-foo--w2|s2", Slug: "impl-foo--w2", Display: "impl-foo--w2", BaseItem: "impl-foo", Local: true},
		{RowID: "b|chat|s3", Slug: "", Display: "chat:abcd1234", Local: false},
	})
	sz(&m, 60, 20)

	view := m.View()
	if !strings.Contains(view, "impl-foo (2)") {
		t.Errorf("expected a base-item header 'impl-foo (2)', got:\n%s", view)
	}
	if m.Count() != 3 {
		t.Errorf("Count should exclude the header, got %d", m.Count())
	}
	if _, ok := m.CurrentSession(); !ok {
		t.Error("cursor should start on a selectable session row, not a header")
	}
}

func TestListNeedsInputCount(t *testing.T) {
	m := NewListModel()
	m.SetSessions([]SessionRow{
		{RowID: "1", Display: "a", NeedsInput: true},
		{RowID: "2", Display: "b"},
		{RowID: "3", Display: "c", NeedsInput: true},
	})
	if got := m.NeedsInputCount(); got != 2 {
		t.Errorf("NeedsInputCount = %d, want 2", got)
	}
}

// TestListSessionByID resolves the routing key back to its row.
func TestListSessionByID(t *testing.T) {
	m := NewListModel()
	m.SetSessions([]SessionRow{
		{RowID: "a|foo|s1", PanelKey: "foo", Slug: "foo", Display: "foo", Local: true},
	})
	r, ok := m.SessionByID("a|foo|s1")
	if !ok || r.PanelKey != "foo" {
		t.Errorf("SessionByID should resolve the row, got %+v ok=%v", r, ok)
	}
	if _, ok := m.SessionByID("missing"); ok {
		t.Error("SessionByID should miss on an unknown id")
	}
}

// sz drives a WindowSizeMsg into the list so its render window is bounded.
func sz(m *ListModel, w, h int) {
	lm, _ := m.Update(tea.WindowSizeMsg{Width: w, Height: h})
	*m = lm
}
