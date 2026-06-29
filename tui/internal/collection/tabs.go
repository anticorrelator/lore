package collection

import (
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/style"
)

// Tab describes one tab in a TabHost. Render returns the tab's body
// content; Update forwards a message to the tab's sub-model and returns
// any command. Either callback may be nil. Callbacks close over consumer
// state — consumers that replace sub-models by value must refresh the
// descriptors via SetTabs.
type Tab struct {
	// ID is the tab's stable identity, used to preserve the active tab
	// across SetTabs calls (e.g. detail reloads).
	ID     string
	Label  string
	Render func() string
	Update func(tea.Msg) tea.Cmd
}

// TabHost owns the tab-bar state shared by detail views: the active tab,
// tab/shift+tab cycling, preserve-across-reload, and label-width mouse
// hit-testing. It renders body content only; the host wraps chrome.
type TabHost struct {
	tabs      []Tab
	active    int
	savedID   string
	defaultID string

	// contentStartY/X are the absolute terminal coordinates of the first
	// row of the host's rendered output; barOffsetY is the bar line's
	// offset from there. Used for mouse hit-testing.
	contentStartY int
	contentStartX int
	barOffsetY    int
}

// NewTabHost creates an empty tab host. The bar is assumed to render one
// line below the content start (after View's leading blank line); override
// with SetBarOffsetY when composing a different layout.
func NewTabHost() TabHost {
	return TabHost{barOffsetY: 1}
}

// SetTabs replaces the tab set and resolves the active tab by ID: a
// Preserve()d ID wins, then the currently active ID, then the default ID,
// then the first tab.
func (h *TabHost) SetTabs(tabs []Tab) {
	currentID := h.ActiveID()
	h.tabs = tabs
	if h.savedID != "" {
		saved := h.savedID
		h.savedID = ""
		if h.SetActiveID(saved) {
			return
		}
	}
	if currentID != "" && h.SetActiveID(currentID) {
		return
	}
	if h.defaultID != "" && h.SetActiveID(h.defaultID) {
		return
	}
	h.active = 0
}

// SetDefaultID sets the tab activated when neither a preserved nor the
// previously active ID survives a SetTabs.
func (h *TabHost) SetDefaultID(id string) { h.defaultID = id }

// Preserve snapshots the active tab ID for restoration by the next
// SetTabs (e.g. across a detail reload).
func (h *TabHost) Preserve() { h.savedID = h.ActiveID() }

// Tabs returns the current tab descriptors.
func (h TabHost) Tabs() []Tab { return h.tabs }

// ActiveIndex returns the active tab's index (0 when empty).
func (h TabHost) ActiveIndex() int { return h.active }

// ActiveID returns the active tab's ID, or "" when the host is empty.
func (h TabHost) ActiveID() string {
	if h.active >= 0 && h.active < len(h.tabs) {
		return h.tabs[h.active].ID
	}
	return ""
}

// SetActiveID activates the tab with the given ID, reporting whether it
// was found. The active tab is unchanged on a miss.
func (h *TabHost) SetActiveID(id string) bool {
	for i, t := range h.tabs {
		if t.ID == id {
			h.active = i
			return true
		}
	}
	return false
}

// CycleNext advances the active tab, wrapping.
func (h *TabHost) CycleNext() {
	if len(h.tabs) > 0 {
		h.active = (h.active + 1) % len(h.tabs)
	}
}

// CyclePrev retreats the active tab, wrapping.
func (h *TabHost) CyclePrev() {
	if len(h.tabs) > 0 {
		h.active = (h.active - 1 + len(h.tabs)) % len(h.tabs)
	}
}

// SetContentStart stores the absolute terminal coordinates of the first
// row of the host's rendered output. Called by the parent when layout
// changes; mouse hit-testing depends on it.
func (h *TabHost) SetContentStart(y, x int) {
	h.contentStartY = y
	h.contentStartX = x
}

// SetBarOffsetY sets the bar line's offset from the content start.
func (h *TabHost) SetBarOffsetY(dy int) { h.barOffsetY = dy }

// Update handles tab/shift+tab cycling and tab-bar mouse clicks, and
// forwards anything else to the active tab's Update callback. Consumers
// that must suppress cycling (e.g. while an inline editor is active)
// simply do not delegate those keys here.
func (h TabHost) Update(msg tea.Msg) (TabHost, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyPressMsg:
		switch msg.String() {
		case "tab":
			h.CycleNext()
			return h, nil
		case "shift+tab":
			h.CyclePrev()
			return h, nil
		}

	case tea.MouseClickMsg:
		if msg.Button == tea.MouseLeft {
			if i, ok := h.hitTest(msg.X, msg.Y); ok {
				h.active = i
				return h, nil
			}
		}
	}
	if h.active >= 0 && h.active < len(h.tabs) {
		if update := h.tabs[h.active].Update; update != nil {
			return h, update(msg)
		}
	}
	return h, nil
}

// hitTest maps absolute click coordinates to a tab index. The bar format
// is "  " + [" label "] + " " + [" label "] + …, each label rendered with
// horizontal padding PadTabH.
func (h TabHost) hitTest(x, y int) (int, bool) {
	if y != h.contentStartY+h.barOffsetY || len(h.tabs) == 0 {
		return 0, false
	}
	cellX := h.contentStartX + rowLead // "  " indent
	for i, tab := range h.tabs {
		tabW := lipgloss.Width(tab.Label) + 2*style.PadTabH
		if x >= cellX && x < cellX+tabW {
			return i, true
		}
		cellX += tabW + 1 // " " separator between tabs
	}
	return 0, false
}

// ViewBar renders the tab bar line.
func (h TabHost) ViewBar() string {
	parts := make([]string, len(h.tabs))
	for i, tab := range h.tabs {
		if i == h.active {
			parts[i] = style.ActiveTab.Render(tab.Label)
		} else {
			parts[i] = style.InactiveTab.Render(tab.Label)
		}
	}
	return strings.Repeat(" ", rowLead) + strings.Join(parts, " ")
}

// ViewContent renders the active tab's body, or "" when the host is empty
// or the tab has no Render callback.
func (h TabHost) ViewContent() string {
	if h.active >= 0 && h.active < len(h.tabs) {
		if render := h.tabs[h.active].Render; render != nil {
			return render()
		}
	}
	return ""
}

// View renders the host body: a leading blank line, the tab bar, a blank
// line, then the active tab's content — matching the detail-view layout
// the bar-offset default assumes. Body only — no chrome.
func (h TabHost) View() string {
	return "\n" + h.ViewBar() + "\n\n" + h.ViewContent()
}
