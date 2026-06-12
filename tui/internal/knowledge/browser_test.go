package knowledge

import (
	"testing"

	tea "charm.land/bubbletea/v2"
)

// testBrowser builds a loaded browser: one category with two direct entries.
// Node layout after buildTree: [0] category (expanded), [1] entry a, [2] entry b.
func testBrowser(t *testing.T) BrowserModel {
	t.Helper()
	m := NewBrowserModel("")
	m, _ = m.Update(tea.WindowSizeMsg{Width: 120, Height: 40})
	manifest := &Manifest{
		Categories: []CategoryInfo{{Name: "conventions", EntryCount: 2}},
		Entries: []KnowledgeEntry{
			{Path: "conventions/alpha.md", Category: "conventions", Title: "Alpha"},
			{Path: "conventions/beta.md", Category: "conventions", Title: "Beta"},
		},
	}
	m, _ = m.Update(ManifestLoadedMsg{Manifest: manifest})
	if len(m.nodes) != 3 {
		t.Fatalf("expected 3 tree nodes, got %d", len(m.nodes))
	}
	return m
}

// loadedBrowser returns a testBrowser whose detail pane has a loaded entry,
// so focus-to-right transitions pass the readiness gate.
func loadedBrowser(t *testing.T) BrowserModel {
	t.Helper()
	m := testBrowser(t)
	m, _ = m.Update(EntryLoadedMsg{Content: "entry body"})
	if !m.entryDetail.Ready() {
		t.Fatal("precondition: entry detail should be ready after EntryLoadedMsg")
	}
	return m
}

// --- Status-bar keybind contract for stateKnowledge ---
// ("j/k navigate · l/Enter detail · h/Esc tree · / search · Esc exit")

func TestBrowserJKNavigateTree(t *testing.T) {
	m := testBrowser(t)
	start := m.cursor
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if m.cursor == start {
		t.Fatal("j should move the tree cursor down")
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'k', Text: "k"})
	if m.cursor != start {
		t.Fatal("k should move the tree cursor back up")
	}
}

func TestBrowserLFocusesDetail(t *testing.T) {
	m := loadedBrowser(t)
	m, _ = m.Update(tea.KeyPressMsg{Code: 'l', Text: "l"})
	if m.focusedPanel != panelRight {
		t.Error("l should focus the detail panel once an entry is loaded")
	}
}

// --- Readiness gate: focus may not enter an empty detail pane ---

func TestBrowserFocusRightKeysGatedWhenNoEntry(t *testing.T) {
	keys := []tea.KeyPressMsg{
		{Code: 'l', Text: "l"},
		{Code: tea.KeyTab},
		{Code: tea.KeyRight},
	}
	for _, k := range keys {
		m := testBrowser(t)
		m, _ = m.Update(k)
		if m.focusedPanel != panelLeft {
			t.Errorf("%v at the no-entry state should leave focus on the tree", k)
		}
	}
}

func TestBrowserRightClickGatedWhenNoEntry(t *testing.T) {
	m := testBrowser(t)
	m, _ = m.Update(tea.MouseClickMsg{
		Button: tea.MouseLeft,
		X:      leftPanelWidth + 10, // inside the right (detail) pane
		Y:      2,
	})
	if m.focusedPanel != panelLeft {
		t.Error("right-pane click at the no-entry state should leave focus on the tree")
	}
}

func TestBrowserJKNavigateAfterGatedFocusAttempt(t *testing.T) {
	m := testBrowser(t)
	m, _ = m.Update(tea.KeyPressMsg{Code: 'l', Text: "l"}) // gated no-op
	start := m.cursor
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if m.cursor == start {
		t.Fatal("j should still move the tree cursor after a gated focus-right attempt")
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'k', Text: "k"})
	if m.cursor != start {
		t.Fatal("k should still move the tree cursor after a gated focus-right attempt")
	}
}

func TestBrowserFocusRightAllowedWhenEntryLoaded(t *testing.T) {
	m := loadedBrowser(t)
	m, _ = m.Update(tea.MouseClickMsg{
		Button: tea.MouseLeft,
		X:      leftPanelWidth + 10,
		Y:      2,
	})
	if m.focusedPanel != panelRight {
		t.Error("right-pane click should focus the detail panel once an entry is loaded")
	}
}

func TestBrowserEnterOnEntryLoadsDetail(t *testing.T) {
	m := testBrowser(t)
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"}) // move to first entry
	if m.nodes[m.cursor].isCategory {
		t.Fatal("precondition: cursor should be on an entry node")
	}
	_, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd == nil {
		t.Error("Enter on an entry should dispatch the entry load")
	}
}

func TestBrowserEnterOnCategoryTogglesFold(t *testing.T) {
	m := testBrowser(t)
	if m.nodes[0].folded {
		t.Fatal("precondition: top-level category starts expanded")
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if !m.nodes[0].folded {
		t.Error("Enter on a category should fold it")
	}
}

func TestBrowserHEscRefocusTree(t *testing.T) {
	for _, k := range []tea.KeyPressMsg{
		{Code: 'h', Text: "h"},
		{Code: tea.KeyEscape},
	} {
		m := testBrowser(t)
		m.focusedPanel = panelRight
		m, _ = m.Update(k)
		if m.focusedPanel != panelLeft {
			t.Errorf("%v should refocus the tree panel", k)
		}
	}
}

func TestBrowserSlashOpensSearch(t *testing.T) {
	m := testBrowser(t)
	m, _ = m.Update(tea.KeyPressMsg{Code: '/', Text: "/"})
	if !m.SearchActive() {
		t.Error("/ should activate the search panel")
	}
}

func TestBrowserEscFromTreeDismisses(t *testing.T) {
	m := testBrowser(t)
	_, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if cmd == nil {
		t.Fatal("Esc from the tree should emit the dismissal command")
	}
	if _, ok := cmd().(BrowserDismissedMsg); !ok {
		t.Fatalf("Esc produced %T, want BrowserDismissedMsg", cmd())
	}
}
