package search

import (
	"testing"

	tea "charm.land/bubbletea/v2"
)

func testPopup() PopupModel {
	m := New([]PopupItem{
		{ID: "a", Label: "alpha item"},
		{ID: "b", Label: "beta item"},
		{ID: "c", Label: "gamma thing"},
	}, "Test Popup")
	m.SetSize(100, 40)
	return m
}

// --- Footer keybind contract ("Enter select  |  Esc cancel  |  j/k navigate") ---

func TestPopupEnterEmitsSelected(t *testing.T) {
	m := testPopup()
	_, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("Enter should emit a selection command")
	}
	msg, ok := cmd().(PopupSelectedMsg)
	if !ok {
		t.Fatalf("Enter produced %T, want PopupSelectedMsg", cmd())
	}
	if msg.Item.ID != "a" {
		t.Errorf("selected item = %q, want a", msg.Item.ID)
	}
}

func TestPopupEscEmitsDismissed(t *testing.T) {
	m := testPopup()
	_, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if cmd == nil {
		t.Fatal("Esc should emit a dismissal command")
	}
	if _, ok := cmd().(PopupDismissedMsg); !ok {
		t.Fatalf("Esc produced %T, want PopupDismissedMsg", cmd())
	}
}

func TestPopupJKNavigate(t *testing.T) {
	m := testPopup()
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if m.cursor != 1 {
		t.Fatalf("j should move the cursor down, got %d", m.cursor)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'k', Text: "k"})
	if m.cursor != 0 {
		t.Fatalf("k should move the cursor up, got %d", m.cursor)
	}
}

func TestPopupTypedCharactersFilter(t *testing.T) {
	m := testPopup()
	for _, c := range "beta" {
		m, _ = m.Update(tea.KeyPressMsg{Code: c, Text: string(c)})
	}
	if m.InputValue() != "beta" {
		t.Fatalf("typed characters should reach the filter input, got %q", m.InputValue())
	}
	if len(m.filtered) != 1 || m.filtered[0].ID != "b" {
		t.Errorf("filter should narrow to the beta item, got %v", m.filtered)
	}
}

// TestPopupPasteReachesInput locks the inputmsg contract (see
// internal/inputmsg): bracketed paste is text entry for the popup's
// textinput and must drive the same filtering as typed characters.
func TestPopupPasteReachesInput(t *testing.T) {
	m := New([]PopupItem{
		{ID: "a", Label: "alpha item"},
		{ID: "b", Label: "beta item"},
	}, "Search")

	m, _ = m.Update(tea.PasteMsg{Content: "beta"})
	if got := m.InputValue(); got != "beta" {
		t.Errorf("InputValue = %q, want pasted text", got)
	}
	if len(m.filtered) != 1 || m.filtered[0].ID != "b" {
		t.Errorf("paste should re-filter items, filtered = %+v", m.filtered)
	}
}
