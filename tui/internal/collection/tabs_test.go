package collection

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

func staticTab(id, label, content string) Tab {
	return Tab{ID: id, Label: label, Render: func() string { return content }}
}

func newTestHost() TabHost {
	h := NewTabHost()
	h.SetTabs([]Tab{
		staticTab("meta", "Meta", "meta body"),
		staticTab("finding", "Finding", "finding body"),
		staticTab("triage", "Triage", "triage body"),
	})
	return h
}

func TestTabHostCycleWraps(t *testing.T) {
	h := newTestHost()

	h, _ = h.Update(tea.KeyPressMsg{Code: tea.KeyTab})
	if h.ActiveID() != "finding" {
		t.Fatalf("after tab: active = %q, want finding", h.ActiveID())
	}

	h, _ = h.Update(tea.KeyPressMsg{Code: tea.KeyTab, Mod: tea.ModShift})
	if h.ActiveID() != "meta" {
		t.Fatalf("after shift+tab: active = %q, want meta", h.ActiveID())
	}

	h, _ = h.Update(tea.KeyPressMsg{Code: tea.KeyTab, Mod: tea.ModShift})
	if h.ActiveID() != "triage" {
		t.Fatalf("shift+tab should wrap backwards: active = %q, want triage", h.ActiveID())
	}
}

func TestTabHostPreserveAcrossSetTabs(t *testing.T) {
	h := newTestHost()
	h.SetActiveID("finding")
	h.Preserve()

	// Reload reorders and drops a tab: the preserved ID is restored.
	h.SetTabs([]Tab{
		staticTab("triage", "Triage", ""),
		staticTab("finding", "Finding", ""),
	})
	if h.ActiveID() != "finding" {
		t.Fatalf("preserved tab not restored: active = %q, want finding", h.ActiveID())
	}

	// Preserved ID gone → falls back to the default ID.
	h.SetDefaultID("triage")
	h.Preserve()
	h.SetTabs([]Tab{
		staticTab("meta", "Meta", ""),
		staticTab("triage", "Triage", ""),
	})
	if h.ActiveID() != "triage" {
		t.Fatalf("default tab not applied: active = %q, want triage", h.ActiveID())
	}

	// Neither preserved, current, nor default present → first tab.
	h.Preserve()
	h.SetTabs([]Tab{staticTab("comments", "Comments", "")})
	if h.ActiveID() != "comments" {
		t.Fatalf("fallback to first tab failed: active = %q", h.ActiveID())
	}
}

func TestTabHostKeepsCurrentIDWithoutPreserve(t *testing.T) {
	h := newTestHost()
	h.SetActiveID("triage")

	h.SetTabs([]Tab{
		staticTab("triage", "Triage", ""),
		staticTab("meta", "Meta", ""),
	})
	if h.ActiveID() != "triage" {
		t.Fatalf("current ID not retained across SetTabs: active = %q, want triage", h.ActiveID())
	}
}

func TestTabHostMouseHitTest(t *testing.T) {
	h := newTestHost()
	h.SetContentStart(5, 10)
	// Bar line is contentStartY+1 = 6. Labels with Padding(0,1):
	// x=12: "Meta" spans [12,18), separator 18, "Finding" spans [19,28),
	// separator 28, "Triage" spans [29,37).

	h, _ = h.Update(tea.MouseClickMsg{Button: tea.MouseLeft, X: 20, Y: 6})
	if h.ActiveID() != "finding" {
		t.Fatalf("click at x=20 → active = %q, want finding", h.ActiveID())
	}

	h, _ = h.Update(tea.MouseClickMsg{Button: tea.MouseLeft, X: 29, Y: 6})
	if h.ActiveID() != "triage" {
		t.Fatalf("click at x=29 → active = %q, want triage", h.ActiveID())
	}

	// Wrong row: not a bar click; active tab unchanged.
	h, _ = h.Update(tea.MouseClickMsg{Button: tea.MouseLeft, X: 13, Y: 7})
	if h.ActiveID() != "triage" {
		t.Fatalf("off-bar click changed tab: active = %q, want triage", h.ActiveID())
	}

	// Past the last label: no tab.
	h, _ = h.Update(tea.MouseClickMsg{Button: tea.MouseLeft, X: 80, Y: 6})
	if h.ActiveID() != "triage" {
		t.Fatalf("click past labels changed tab: active = %q, want triage", h.ActiveID())
	}
}

func TestTabHostForwardsToActiveTab(t *testing.T) {
	var got []tea.Msg
	h := NewTabHost()
	h.SetTabs([]Tab{
		{ID: "a", Label: "A", Update: func(msg tea.Msg) tea.Cmd {
			got = append(got, msg)
			return func() tea.Msg { return "handled" }
		}},
		{ID: "b", Label: "B"},
	})

	key := tea.KeyPressMsg{Code: 'j', Text: "j"}
	h, cmd := h.Update(key)
	if len(got) != 1 || got[0] != tea.Msg(key) {
		t.Fatalf("active tab did not receive the message: got %v", got)
	}
	if cmd == nil || cmd() != "handled" {
		t.Fatal("active tab's Cmd was not returned")
	}

	// Cycling keys are consumed by the host, not forwarded.
	h, _ = h.Update(tea.KeyPressMsg{Code: tea.KeyTab})
	if len(got) != 1 {
		t.Fatalf("tab key leaked to the active tab: got %v", got)
	}
	if h.ActiveID() != "b" {
		t.Fatalf("active = %q, want b", h.ActiveID())
	}
}

func TestTabHostView(t *testing.T) {
	h := newTestHost()
	bar := stripANSI(h.ViewBar())
	for _, label := range []string{"Meta", "Finding", "Triage"} {
		if !strings.Contains(bar, label) {
			t.Errorf("bar missing label %q: %q", label, bar)
		}
	}
	if h.ViewContent() != "meta body" {
		t.Errorf("ViewContent = %q, want meta body", h.ViewContent())
	}
	view := stripANSI(h.View())
	if !strings.HasPrefix(view, "\n") || !strings.Contains(view, "meta body") {
		t.Errorf("View layout unexpected: %q", view)
	}
}

func TestTabHostEmpty(t *testing.T) {
	h := NewTabHost()
	if h.ActiveID() != "" {
		t.Errorf("empty host ActiveID = %q, want empty", h.ActiveID())
	}
	h, cmd := h.Update(tea.KeyPressMsg{Code: tea.KeyTab})
	if cmd != nil {
		t.Error("empty host returned a Cmd")
	}
	if h.ViewContent() != "" || stripANSI(h.ViewBar()) != "  " {
		t.Errorf("empty host rendered content: bar=%q content=%q", h.ViewBar(), h.ViewContent())
	}
}
