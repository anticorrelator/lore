package collection

import (
	"fmt"
	"slices"
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

	// width is the bar's cell budget; tabs that would overflow it collapse
	// into a trailing "+N more" pill. Zero (unset) renders all tabs.
	width int

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

// SetWidth sets the bar's width budget in cells. Zero disables overflow
// collapsing.
func (h *TabHost) SetWidth(w int) { h.width = w }

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

// overflowPillLabel is the trailing pill collapsing n hidden tabs.
func overflowPillLabel(n int) string { return fmt.Sprintf("+%d more", n) }

// tabCellWidth is a rendered tab's cell width: label plus PadTabH each side.
func tabCellWidth(label string) int {
	return lipgloss.Width(label) + 2*style.PadTabH
}

// barWidth measures the bar line holding the given tab indices plus a
// trailing "+hiddenN more" pill (omitted when hiddenN is 0).
func (h TabHost) barWidth(visible []int, hiddenN int) int {
	w := rowLead
	for i, idx := range visible {
		if i > 0 {
			w++
		}
		w += tabCellWidth(h.tabs[idx].Label)
	}
	if hiddenN > 0 {
		w += 1 + tabCellWidth(overflowPillLabel(hiddenN))
	}
	return w
}

// visibleTabs is the single source of truth for which tabs the bar shows,
// shared by ViewBar and hitTest so clicks always land on the tab they
// visually hit. It returns the rendered tab indices in bar order and the
// indices collapsed into the trailing "+N more" pill. All tabs are visible
// when the width budget is unset or everything fits. On overflow the bar
// keeps the longest prefix that fits beside the pill; the active tab is
// always visible, taking the last visible slot when it falls in the tail.
func (h TabHost) visibleTabs() (visible, hidden []int) {
	n := len(h.tabs)
	if n == 0 {
		return nil, nil
	}
	visible = make([]int, n)
	for i := range visible {
		visible[i] = i
	}
	if h.width <= 0 || h.barWidth(visible, 0) <= h.width {
		return visible, nil
	}
	// k == 1 is the floor: the active tab and the pill render even when
	// the budget cannot hold them.
	for k := n - 1; k >= 1; k-- {
		cand := make([]int, k)
		for i := range cand {
			cand[i] = i
		}
		if h.active >= k {
			cand[k-1] = h.active
		}
		if k == 1 || h.barWidth(cand, n-k) <= h.width {
			hidden = make([]int, 0, n-k)
			for i := 0; i < n; i++ {
				if !slices.Contains(cand, i) {
					hidden = append(hidden, i)
				}
			}
			return cand, hidden
		}
	}
	return nil, nil // unreachable: the k == 1 floor always returns
}

// hitTest maps absolute click coordinates to a tab index. The bar format
// is "  " + [" label "] + " " + [" label "] + …, each label rendered with
// horizontal padding PadTabH. A click on the "+N more" pill activates the
// first hidden tab.
func (h TabHost) hitTest(x, y int) (int, bool) {
	if y != h.contentStartY+h.barOffsetY || len(h.tabs) == 0 {
		return 0, false
	}
	visible, hidden := h.visibleTabs()
	cellX := h.contentStartX + rowLead // "  " indent
	for _, idx := range visible {
		tabW := tabCellWidth(h.tabs[idx].Label)
		if x >= cellX && x < cellX+tabW {
			return idx, true
		}
		cellX += tabW + 1 // " " separator between tabs
	}
	if len(hidden) > 0 {
		pillW := tabCellWidth(overflowPillLabel(len(hidden)))
		if x >= cellX && x < cellX+pillW {
			return hidden[0], true
		}
	}
	return 0, false
}

// ViewBar renders the tab bar line.
func (h TabHost) ViewBar() string {
	visible, hidden := h.visibleTabs()
	parts := make([]string, 0, len(visible)+1)
	for _, idx := range visible {
		if idx == h.active {
			parts = append(parts, style.ActiveTab.Render(h.tabs[idx].Label))
		} else {
			parts = append(parts, style.InactiveTab.Render(h.tabs[idx].Label))
		}
	}
	if len(hidden) > 0 {
		parts = append(parts, style.InactiveTab.Render(overflowPillLabel(len(hidden))))
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
