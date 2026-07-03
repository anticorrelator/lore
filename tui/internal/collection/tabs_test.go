package collection

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
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

func overflowTestHost(width int) TabHost {
	h := NewTabHost()
	h.SetTabs([]Tab{
		staticTab("alpha", "Alpha", ""),
		staticTab("beta", "Beta", ""),
		staticTab("gamma", "Gamma", ""),
		staticTab("delta", "Delta", ""),
		staticTab("epsilon", "Epsilon", ""),
		staticTab("zeta", "Zeta", ""),
	})
	h.SetContentStart(0, 0)
	h.SetWidth(width)
	return h
}

func TestTabHostUnsetWidthRendersAllTabs(t *testing.T) {
	h := overflowTestHost(0)
	bar := stripANSI(h.ViewBar())
	for _, label := range []string{"Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta"} {
		if !strings.Contains(bar, label) {
			t.Errorf("unset width hid %q: %q", label, bar)
		}
	}
	if strings.Contains(bar, "more") {
		t.Errorf("unset width rendered an overflow pill: %q", bar)
	}
}

func TestTabHostOverflowCollapsesTail(t *testing.T) {
	h := overflowTestHost(30)
	bar := stripANSI(h.ViewBar())
	// Budget 30 fits Alpha and Beta beside the pill; the tail collapses.
	if !strings.Contains(bar, "Alpha") || !strings.Contains(bar, "Beta") {
		t.Fatalf("leading tabs missing: %q", bar)
	}
	for _, hidden := range []string{"Gamma", "Delta", "Epsilon", "Zeta"} {
		if strings.Contains(bar, hidden) {
			t.Errorf("tail tab %q still rendered: %q", hidden, bar)
		}
	}
	if !strings.Contains(bar, "+4 more") {
		t.Errorf("overflow pill missing: %q", bar)
	}
	if w := lipgloss.Width(bar); w > 30 {
		t.Errorf("bar width %d exceeds budget 30: %q", w, bar)
	}
}

func TestTabHostOverflowActiveTabAlwaysVisible(t *testing.T) {
	h := overflowTestHost(30)
	h.SetActiveID("epsilon")
	bar := stripANSI(h.ViewBar())
	if !strings.Contains(bar, "Epsilon") {
		t.Fatalf("active tab hidden by overflow: %q", bar)
	}
	if !strings.Contains(bar, "+4 more") {
		t.Errorf("pill missing with active in tail: %q", bar)
	}
}

func TestTabHostOverflowPillActivatesFirstHidden(t *testing.T) {
	h := overflowTestHost(30)
	bar := stripANSI(h.ViewBar())
	pillX := strings.Index(bar, "+4 more")
	if pillX < 0 {
		t.Fatalf("no pill in bar: %q", bar)
	}
	// Bar line is contentStartY+1 = 1 with content start at (0,0).
	h, _ = h.Update(tea.MouseClickMsg{Button: tea.MouseLeft, X: pillX, Y: 1})
	if h.ActiveID() != "gamma" {
		t.Fatalf("pill click activated %q, want gamma (first hidden)", h.ActiveID())
	}
	// The newly active tab is now visible; the pill re-collapses around it.
	bar = stripANSI(h.ViewBar())
	if !strings.Contains(bar, "Gamma") {
		t.Errorf("activated tab not visible after pill click: %q", bar)
	}
}

func TestTabHostOverflowCyclingReachesHiddenTabs(t *testing.T) {
	h := overflowTestHost(30)
	seen := map[string]bool{}
	for i := 0; i < len(h.Tabs()); i++ {
		seen[h.ActiveID()] = true
		if bar := stripANSI(h.ViewBar()); !strings.Contains(bar, h.Tabs()[h.ActiveIndex()].Label) {
			t.Errorf("active %q not visible in bar: %q", h.ActiveID(), bar)
		}
		h, _ = h.Update(tea.KeyPressMsg{Code: tea.KeyTab})
	}
	if len(seen) != len(h.Tabs()) {
		t.Fatalf("cycling reached %d of %d tabs: %v", len(seen), len(h.Tabs()), seen)
	}
}

// TestTabHostOverflowClicksMatchBar sweeps widths and active tabs, asserting
// the hit-test agrees with the rendered bar: every visible label click lands
// on that tab, and a pill click lands on the first hidden tab.
func TestTabHostOverflowClicksMatchBar(t *testing.T) {
	labels := []string{"Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta"}
	ids := []string{"alpha", "beta", "gamma", "delta", "epsilon", "zeta"}
	for width := 10; width <= 52; width += 3 {
		for active := range ids {
			h := overflowTestHost(width)
			h.SetActiveID(ids[active])
			bar := stripANSI(h.ViewBar())

			if !strings.Contains(bar, labels[active]) {
				t.Fatalf("width %d: active %q not in bar %q", width, labels[active], bar)
			}

			hiddenFirst := ""
			for i, label := range labels {
				pos := strings.Index(bar, label)
				if pos < 0 {
					if hiddenFirst == "" {
						hiddenFirst = ids[i]
					}
					continue
				}
				got, ok := h.hitTest(pos, 1)
				if !ok || got != i {
					t.Errorf("width %d active %d: click on %q at x=%d hit tab %d (ok=%v)",
						width, active, label, pos, got, ok)
				}
			}

			if pillX := strings.Index(bar, "+"); pillX >= 0 {
				got, ok := h.hitTest(pillX, 1)
				if !ok || h.Tabs()[got].ID != hiddenFirst {
					t.Errorf("width %d active %d: pill click hit %d, want first hidden %q (bar %q)",
						width, active, got, hiddenFirst, bar)
				}
			}
		}
	}
}
