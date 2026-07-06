package sessionview

import (
	"fmt"
	"sort"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/collection"
	"github.com/anticorrelator/lore/tui/internal/style"
)

// SessionSelectedMsg is emitted when Enter lands on a session row. The host
// resolves the row by ID and either attaches its local panel or focuses the
// read-only detail card.
type SessionSelectedMsg struct {
	RowID string
}

// SessionRow is one session the host hands the list to render. The host owns
// the substrate union (registry + queue + journal overlay); the list owns
// grouping, columns, and cursor. RowID is the stable, globally-unique identity
// used for cursor preservation and detail routing; PanelKey is the sessionPanels
// map key for a locally-hosted session (attachable), empty otherwise.
type SessionRow struct {
	RowID     string
	PanelKey  string
	Slug      string
	Display   string // slug, or chat:<8hex> for a slugless session
	Type      string // spec|implement|chat|worker
	Initiator string // agent|human
	Instance  string // owning instance
	Local     bool   // hosted by this instance (has an attachable panel)
	InFlight  bool   // a queued spawn not yet live
	SessionID string // harness session id (close --session addressing)
	BaseItem  string // base work item for a derived-slug worker; "" = ungrouped

	NeedsInput   bool
	Quiescent    bool
	ClosePending bool

	Started string
}

// headerIDPrefix namespaces base-item group header rows so they never collide
// with a session RowID.
const headerIDPrefix = "base:"

var listColumns = []collection.Column{
	{Key: "dot", Title: " ", Width: 1, Priority: 1},
	{Key: "id", Title: "SESSION", Width: 20, Priority: 0, Flex: true},
	{Key: "type", Title: "TYPE", Width: 9, Priority: 3},
	{Key: "activity", Title: "ACTIVITY", Width: 13, Priority: 2},
	{Key: "instance", Title: "INSTANCE", Width: 12, Priority: 4},
}

// ListModel is the sessions list panel: a collection.List consumer backed by a
// host-supplied session set.
type ListModel struct {
	rows []SessionRow
	list collection.List
}

// NewListModel builds an empty sessions list.
func NewListModel() ListModel {
	m := ListModel{list: collection.NewList(listColumns)}
	m.list.SetEmptyText("  No live sessions.")
	m.list.SetOnSelect(func(r collection.Row) tea.Cmd {
		if r.Header || r.ID == "" {
			return nil
		}
		id := r.ID
		return func() tea.Msg { return SessionSelectedMsg{RowID: id} }
	})
	// No onCursorChange hook: the host's routePanelMsg diffs the current key on
	// every move (key-driven and programmatic) and loads the card itself, so a
	// hover-prefetch message would only double-load.
	return m
}

// SetSessions replaces the session set and rebuilds the rows, preserving the
// cursor by RowID.
func (m *ListModel) SetSessions(rows []SessionRow) {
	m.rows = rows
	m.refreshRows()
}

// refreshRows groups derived-slug workers under their base work item and renders
// standalone sessions flat below the grouped section. Deterministic ordering
// (sorted bases, sorted members, sorted ungrouped) keeps the list stable across
// the 5s substrate refresh so the cursor does not jump.
func (m *ListModel) refreshRows() {
	grouped := map[string][]SessionRow{}
	var bases []string
	var ungrouped []SessionRow
	for _, r := range m.rows {
		if r.BaseItem != "" {
			if _, seen := grouped[r.BaseItem]; !seen {
				bases = append(bases, r.BaseItem)
			}
			grouped[r.BaseItem] = append(grouped[r.BaseItem], r)
			continue
		}
		ungrouped = append(ungrouped, r)
	}
	sort.Strings(bases)
	sort.Slice(ungrouped, func(i, j int) bool { return ungrouped[i].Display < ungrouped[j].Display })

	var out []collection.Row
	for _, base := range bases {
		members := grouped[base]
		sort.Slice(members, func(i, j int) bool { return members[i].Display < members[j].Display })
		out = append(out, collection.Row{
			ID:     headerIDPrefix + base,
			Header: true,
			Title:  collection.Cell{Text: fmt.Sprintf("%s (%d)", base, len(members)), Style: groupHeaderStyle},
		})
		for _, r := range members {
			out = append(out, sessionRowCells(r))
		}
	}
	for _, r := range ungrouped {
		out = append(out, sessionRowCells(r))
	}
	m.list.SetRows(out)
}

// sessionRowCells maps a SessionRow to its collection row: columnar cells and
// the stacked two-line form.
func sessionRowCells(r SessionRow) collection.Row {
	dot := " "
	if r.NeedsInput {
		dot = "●"
	}
	badge, badgeStyle := activityBadge(r)
	instance := r.Instance
	if r.Local {
		instance = ""
	}
	return collection.Row{
		ID: r.RowID,
		Cells: []collection.Cell{
			{Text: dot, Style: needsInputStyle},
			{Text: r.Display},
			{Text: r.Type, Style: style.Dim},
			{Text: badge, Style: badgeStyle},
			{Text: instance, Style: style.Dim},
		},
		Title: collection.Cell{Text: r.Display},
		Meta: []collection.Cell{
			{Text: r.Type, Style: style.Dim},
			{Text: badge, Style: badgeStyle},
		},
	}
}

// activityBadge names the session's next required action (or its running state),
// with the style token matching the urgency. Labels name the action, not the
// internal event: "needs input", "close pending", "spawning".
func activityBadge(r SessionRow) (string, lipgloss.Style) {
	switch {
	case r.InFlight:
		return "spawning", style.StatusWarn
	case r.NeedsInput:
		return "needs input", needsInputStyle
	case r.ClosePending:
		return "close pending", reviewHeldStyle
	case !r.Local:
		return "◆ active", style.Dim
	case r.Quiescent:
		return "idle", style.Dim
	default:
		return "running", style.StatusActive
	}
}

func (m ListModel) Init() tea.Cmd { return nil }

func (m ListModel) Update(msg tea.Msg) (ListModel, tea.Cmd) {
	l, cmd := m.list.Update(msg)
	m.list = l
	return m, cmd
}

func (m ListModel) View() string { return m.list.View() }

// CurrentKey returns the RowID under the cursor, or "" on a header/empty list.
func (m ListModel) CurrentKey() string { return m.list.CurrentID() }

// CurrentSession returns the session under the cursor, or false on a header row.
func (m ListModel) CurrentSession() (SessionRow, bool) {
	return m.SessionByID(m.list.CurrentID())
}

// SessionByID returns the session with the given RowID, or false when absent.
func (m ListModel) SessionByID(id string) (SessionRow, bool) {
	if id == "" {
		return SessionRow{}, false
	}
	for _, r := range m.rows {
		if r.RowID == id {
			return r, true
		}
	}
	return SessionRow{}, false
}

// Count is the number of live/in-flight sessions (excludes group headers).
func (m ListModel) Count() int { return len(m.rows) }

// NeedsInputCount is the number of sessions awaiting input — the tab-indicator
// needs-input marker.
func (m ListModel) NeedsInputCount() int {
	n := 0
	for _, r := range m.rows {
		if r.NeedsInput {
			n++
		}
	}
	return n
}

// ChatDisplayID composes the slugless identity chat:<8hex-of-session_id> the way
// session-list.sh renders it (chat:? when no session_id), so a list row composes
// with `lore session close --session`. The registry --json envelope carries the
// raw session_id; this composition is the list's own.
func ChatDisplayID(sessionID string) string {
	if sessionID == "" {
		return "chat:?"
	}
	hex := strings.ReplaceAll(sessionID, "-", "")
	if len(hex) > 8 {
		hex = hex[:8]
	}
	return "chat:" + hex
}

var (
	needsInputStyle  = lipgloss.NewStyle().Foreground(style.ColorAttention)
	reviewHeldStyle  = lipgloss.NewStyle().Foreground(style.ColorAttention)
	groupHeaderStyle = lipgloss.NewStyle().Foreground(style.ColorAccent).Bold(true)
)
