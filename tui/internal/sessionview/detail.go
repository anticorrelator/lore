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

	// mirrorRowID/mirrorLines hold the last client-less capture-pane snapshot of a
	// remote tmux-hosted session's visible screen. mirrorRowID pins the snapshot to
	// the row it was captured for so a frame is never shown under a different session.
	mirrorRowID string
	mirrorLines []string
}

func NewDetailModel() DetailModel { return DetailModel{} }

// SetSession loads the row the card renders (has=false clears it to the empty
// state). All reads are pushed by the host, so the card does no I/O. Moving to a
// different row drops the prior mirror frame so the previous session's screen is
// never shown under the new one before its first capture lands.
func (m *DetailModel) SetSession(r SessionRow, has bool) {
	if r.RowID != m.row.RowID {
		m.mirrorRowID = ""
		m.mirrorLines = nil
	}
	m.row = r
	m.has = has
}

// SetMirror stores a fresh remote-screen snapshot for the read-only mirror. A
// snapshot whose rowID no longer matches the displayed row is dropped: a capture
// dispatched before the cursor moved must not paint under the wrong session.
func (m *DetailModel) SetMirror(rowID string, lines []string) {
	if rowID != m.row.RowID {
		return
	}
	m.mirrorRowID = rowID
	m.mirrorLines = lines
}

// RemoteMirror reports whether the current card is a cross-instance tmux-hosted
// session whose visible screen the host should capture on the poll tick, and
// returns its row id and tmux name. A local row (own live panel), an in-flight
// spawn, or a direct-PTY row (no tmux name) is not mirrorable.
func (m DetailModel) RemoteMirror() (rowID, tmuxName string, ok bool) {
	if !m.has || m.row.Local || m.row.InFlight || m.row.Tmux == "" {
		return "", "", false
	}
	return m.row.RowID, m.row.Tmux, true
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

	// A cross-instance tmux-hosted session upgrades to a read-only screen mirror:
	// its captured pane rows verbatim. No readiness classification is performed —
	// that consumes emulator-local fields only the owning instance holds; the
	// mirror renders rows and nothing more.
	if _, _, ok := m.RemoteMirror(); ok {
		return m.mirrorView()
	}

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
		// A cross-instance session with no tmux name is direct-PTY (or a legacy
		// writer): it cannot be mirrored from here and is viewable live only on its
		// host. First-class local-only state, not an error or a blank mirror.
		b.WriteString(style.Dim.Render("read-only — runs on another instance"))
		b.WriteString("\n")
		b.WriteString(style.Dim.Render("live screen available only on its host"))
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

// mirrorView renders a remote tmux-hosted session as a read-only screen mirror:
// a compact identity header, then the captured pane rows verbatim (ANSI intact).
// There is no input path and no readiness/activity classification — the label
// states plainly that this is a mirror, not a live attach.
func (m DetailModel) mirrorView() string {
	r := m.row
	var b strings.Builder
	b.WriteString(style.Dim.Render("read-only mirror — runs on " + r.Instance))
	b.WriteString("\n")
	b.WriteString(style.Dim.Render(r.Display + "  ·  " + r.Type))
	b.WriteString("\n\n")
	if len(m.mirrorLines) == 0 {
		b.WriteString(style.Dim.Render("capturing live screen…"))
	} else {
		b.WriteString(strings.Join(m.mirrorLines, "\n"))
	}
	b.WriteString("\n\n")
	b.WriteString(style.Dim.Render("x  request close"))
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
