package sessionview

import (
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/style"
)

// DetailModel is the read-only card shown for a session with no local panel to
// attach: a cross-instance session or an in-flight spawn. It renders registry
// fields plus the journal activity overlay — a local session shows its live
// SessionPanelModel instead, routed by the host. The View is body-only; the host
// wraps panel chrome.
type DetailModel struct {
	row    SessionRow
	has    bool
	width  int
	height int
}

func NewDetailModel() DetailModel { return DetailModel{} }

// SetSession loads the row the card renders (has=false clears it to the empty
// state). All reads are pushed by the host, so the card does no I/O.
func (m *DetailModel) SetSession(r SessionRow, has bool) {
	m.row = r
	m.has = has
}

// Title is the card's border title.
func (m DetailModel) Title() string {
	if !m.has {
		return "Session"
	}
	return m.row.Display
}

func (m DetailModel) Init() tea.Cmd { return nil }

// Update handles sizing; the card is fixed-height and consumes wheel events
// without scrolling (it always fits), satisfying the every-scrollable-view wheel
// contract by owning the message rather than leaking it.
func (m DetailModel) Update(msg tea.Msg) (DetailModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
	}
	return m, nil
}

func (m DetailModel) View() string {
	if !m.has {
		return style.Dim.Render("Select a session.")
	}
	r := m.row

	var b strings.Builder
	line := func(label, value string) {
		if value == "" {
			return
		}
		b.WriteString(style.Dim.Render(label))
		b.WriteString("  ")
		b.WriteString(value)
		b.WriteString("\n")
	}

	// Lead with the standing condition: what this card is and why it is read-only.
	switch {
	case r.InFlight:
		b.WriteString(style.StatusWarn.Render("spawning — queued, not yet live"))
	case !r.Local:
		b.WriteString(style.Dim.Render("read-only — runs on another instance"))
	}
	b.WriteString("\n\n")

	line("id       ", r.Display)
	line("type     ", r.Type)
	line("initiator", r.Initiator)
	line("instance ", r.Instance)
	if action := activityAction(r); action != "" {
		b.WriteString(style.Dim.Render("activity "))
		b.WriteString("  ")
		b.WriteString(activityActionStyle(r).Render(action))
		b.WriteString("\n")
	}
	line("started  ", r.Started)
	if r.SessionID != "" {
		line("session  ", ChatDisplayID(r.SessionID))
	}
	if !r.InFlight {
		b.WriteString("\n")
		b.WriteString(style.Dim.Render("x  request close"))
	}
	return b.String()
}

// activityAction resolves the card's activity line to the same next-action label
// the list badge uses, falling back to the coarse running/idle state.
func activityAction(r SessionRow) string {
	if r.InFlight {
		return "spawning"
	}
	a := Activity{NeedsInput: r.NeedsInput, Quiescent: r.Quiescent, ClosePending: r.ClosePending}
	if s := a.NextAction(); s != "" {
		return s
	}
	if r.Quiescent {
		return "idle"
	}
	return "running"
}

func activityActionStyle(r SessionRow) lipgloss.Style {
	switch {
	case r.NeedsInput:
		return needsInputStyle
	case r.ClosePending:
		return reviewHeldStyle
	case r.InFlight:
		return style.StatusWarn
	default:
		return style.Dim
	}
}
