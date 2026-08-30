package coordination

import (
	"fmt"
	"sort"
	"strings"

	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/coordination/board"
	"github.com/anticorrelator/lore/tui/internal/render"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/sessionview"
	"github.com/anticorrelator/lore/tui/internal/style"
	"github.com/anticorrelator/lore/tui/internal/work"
)

const unknown = "unknown"

type DetailMode string

const (
	ModePrimary DetailMode = "primary"
	ModeLedger  DetailMode = "ledger"
	ModeReport  DetailMode = "report"
	ModePacket  DetailMode = "packet"
)

var (
	holdStyle = lipgloss.NewStyle().Foreground(style.ColorAttention).Bold(true)
	flagStyle = lipgloss.NewStyle().Foreground(style.ColorDanger).Bold(true)
)

// MemberSelectedMsg asks the host to open a declared work item in the existing
// work workspace.
type MemberSelectedMsg struct{ Slug string }

// SessionSelectedMsg asks the host to open one unambiguous live session in the
// sessions workspace, which remains the only attach-capable surface.
type SessionSelectedMsg struct{ RowID string }

// Member is one declared arc member joined against the work index. Unresolved
// declarations remain present so an absent work item cannot disappear silently.
type Member struct {
	Slug     string
	Item     work.WorkItem
	Resolved bool
}

// DetailModel renders one arc. All content is host-pushed, keeping the model
// deterministic and headless-testable.
type DetailModel struct {
	arc    string
	width  int
	height int
	mode   DetailMode

	members  []Member
	sessions []sessionview.SessionRow

	rows        []board.Row
	rendered    []board.RenderedRow
	rowCursor   int
	boardLoaded bool
	boardFound  bool
	boardErr    string

	events []session.Event

	ledgerLoaded bool
	ledger       string
	brief        string
	briefFound   bool

	report      string
	reportFound bool
	closed      bool

	packets    map[string]string
	packetRef  string
	packetBody string
	viewport   viewport.Model
}

func NewDetailModel() DetailModel {
	m := DetailModel{mode: ModePrimary}
	m.refresh()
	return m
}

func (m DetailModel) Arc() string { return m.arc }

func (m DetailModel) Title() string {
	if m.arc == "" {
		return "Coordination"
	}
	return m.arc
}

func (m DetailModel) Mode() DetailMode { return m.mode }

func (m DetailModel) InDrillIn() bool { return m.mode != ModePrimary }

// SetArc preserves every same-arc identity. A changed arc resets all derived
// state so stale async responses cannot paint under a new selection.
func (m *DetailModel) SetArc(arc string) {
	if arc == m.arc {
		return
	}
	m.arc = arc
	m.mode = ModePrimary
	m.members = nil
	m.sessions = nil
	m.rows = nil
	m.rendered = nil
	m.rowCursor = 0
	m.boardLoaded = false
	m.boardFound = false
	m.boardErr = ""
	m.events = nil
	m.ledgerLoaded = false
	m.ledger = ""
	m.brief = ""
	m.briefFound = false
	m.report = ""
	m.reportFound = false
	m.closed = false
	m.packets = nil
	m.packetRef = ""
	m.packetBody = ""
	m.refresh()
}

func (m *DetailModel) SetMembers(members []Member, _ map[string]bool) {
	m.members = append([]Member(nil), members...)
	m.refresh()
}

// SetSessions preserves no separate cursor: sessions are navigation targets
// for the selected DAG row, not a second collection inside coordination.
func (m *DetailModel) SetSessions(rows []sessionview.SessionRow) {
	rows = append([]sessionview.SessionRow(nil), rows...)
	sort.Slice(rows, func(i, j int) bool { return rows[i].RowID < rows[j].RowID })
	m.sessions = rows
	m.refresh()
}

func (m *DetailModel) SetLedger(content, brief string, briefFound bool) {
	m.ledgerLoaded = true
	m.ledger = content
	m.brief = brief
	m.briefFound = briefFound
	m.refresh()
}

func (m *DetailModel) SetReport(report string, found bool) {
	m.report = report
	m.reportFound = found
	if !found && m.mode == ModeReport {
		m.mode = ModePrimary
	}
	m.refresh()
}

func (m *DetailModel) SetClosed(closed bool) {
	m.closed = closed
	if closed && m.mode == ModeReport {
		m.mode = ModePrimary
	}
	m.refresh()
}

// SetBoard replaces the fresh status projection while preserving selection by
// stream identity. Empty fields remain explicit at render time.
func (m *DetailModel) SetBoard(rows []board.Row, found bool, err error) {
	selected := m.SelectedStream()
	m.boardLoaded = true
	m.boardFound = found
	m.boardErr = ""
	if err != nil {
		m.boardErr = err.Error()
		m.rows = nil
		m.rendered = nil
		m.rowCursor = 0
		m.refresh()
		return
	}
	m.rows = append([]board.Row(nil), rows...)
	m.rebuildRendered()
	m.rowCursor = 0
	if selected != "" {
		m.SelectStream(selected)
	}
	m.refresh()
}

func (m *DetailModel) SetEvents(events []session.Event) {
	m.events = append([]session.Event(nil), events...)
	m.refresh()
}

func (m *DetailModel) SetReviewPackets(packets map[string]string) {
	m.packets = make(map[string]string, len(packets))
	for ref, body := range packets {
		m.packets[ref] = body
	}
	if m.mode == ModePacket {
		body, ok := m.packets[m.packetRef]
		if !ok {
			m.mode = ModePrimary
			m.packetRef, m.packetBody = "", ""
		} else {
			m.packetBody = body
		}
	}
	m.refresh()
}

// SetContentStart is retained for the shared pane callback. The integrated
// body has no tab bar to hit-test.
func (m *DetailModel) SetContentStart(int, int) {}

func (m DetailModel) SelectedStream() string {
	if m.rowCursor < 0 || m.rowCursor >= len(m.rendered) {
		return ""
	}
	return m.rendered[m.rowCursor].StreamID
}

func (m *DetailModel) SelectStream(streamID string) bool {
	for i, row := range m.rendered {
		if row.StreamID == streamID {
			m.rowCursor = i
			m.refresh()
			return true
		}
	}
	return false
}

func (m DetailModel) currentRow() (board.Row, bool) {
	if m.rowCursor < 0 || m.rowCursor >= len(m.rendered) {
		return board.Row{}, false
	}
	return m.rowByID(m.rendered[m.rowCursor].StreamID)
}

func explicit(value string) string {
	if strings.TrimSpace(value) == "" {
		return unknown
	}
	return value
}

func pointerValue(value *string) string {
	if value == nil || strings.TrimSpace(*value) == "" {
		return unknown
	}
	return *value
}

func (m *DetailModel) rebuildRendered() {
	rows := append([]board.Row(nil), m.rows...)
	for i := range rows {
		rows[i].Label = explicit(rows[i].Label)
		rows[i].Tree = explicit(rows[i].Tree)
		rows[i].Gate = explicit(rows[i].Gate)
		rows[i].Status = explicit(rows[i].Status)
		rows[i].Verdict = explicit(rows[i].Verdict)
	}
	m.rendered = board.RenderRows(rows, m.contentWidth())
}

func (m DetailModel) contentWidth() int {
	w := m.width - 4
	if w < 20 {
		return 20
	}
	return w
}

func (m DetailModel) contentHeight() int {
	h := m.height - 2
	if h < 5 {
		return 5
	}
	return h
}

func (m *DetailModel) refresh() {
	offset := m.viewport.YOffset()
	m.rebuildRendered()
	vp := viewport.New(viewport.WithWidth(m.contentWidth()), viewport.WithHeight(m.contentHeight()))
	vp.SetContent(m.render())
	vp.SetYOffset(offset)
	m.viewport = vp
}

func sectionRule(label string, width int) string {
	title := " " + label + " "
	fill := width - lipgloss.Width(title) - 1
	if fill < 1 {
		fill = 1
	}
	return style.SectionRule.Render("─") + style.SubsectionTitle.Render(title) +
		style.SectionRule.Render(strings.Repeat("─", fill))
}

func (m DetailModel) render() string {
	if m.arc == "" {
		return style.Dim.Render("No arc selected.")
	}
	switch m.mode {
	case ModeLedger:
		return m.renderDocument("Ledger", m.ledger, m.ledgerLoaded, "coordination.md")
	case ModeReport:
		return m.renderDocument("Report", m.report, m.reportFound, "report.md")
	case ModePacket:
		return m.renderDocument("Review packet · "+explicit(m.packetRef), m.packetBody, true, explicit(m.packetRef))
	default:
		if m.closed {
			return m.renderClosed()
		}
		return m.renderLive()
	}
}

func (m DetailModel) renderClosed() string {
	var b strings.Builder
	b.WriteString(m.renderDocument("Report", m.report, m.reportFound, "report.md"))
	b.WriteString("\n\n")
	b.WriteString(sectionRule("Final streams", m.contentWidth()))
	b.WriteString("\n")
	b.WriteString(m.renderBoard())
	return b.String()
}

func (m DetailModel) renderDocument(label, body string, found bool, filename string) string {
	var b strings.Builder
	b.WriteString(sectionRule(label, m.contentWidth()))
	b.WriteString("\n")
	switch {
	case !found:
		b.WriteString(style.Dim.Render(filename + " unknown — document is absent"))
	case strings.TrimSpace(body) == "":
		b.WriteString(style.Dim.Render(filename + " unknown — document could not be read"))
	default:
		b.WriteString(render.Markdown(body, m.contentWidth()))
	}
	return b.String()
}

func (m DetailModel) renderLive() string {
	var b strings.Builder
	b.WriteString(sectionRule("Brief", m.contentWidth()))
	b.WriteString("\n")
	switch {
	case !m.ledgerLoaded:
		b.WriteString(style.Dim.Render("Brief unknown — coordination.md is still loading"))
	case m.briefFound:
		b.WriteString(render.Markdown(m.brief, m.contentWidth()))
	default:
		b.WriteString(style.Dim.Render("Brief unknown — coordination.md has no ## Brief section"))
	}
	b.WriteString("\n\n")
	b.WriteString(sectionRule("Streams", m.contentWidth()))
	b.WriteString("\n")
	b.WriteString(m.renderBoard())
	b.WriteString("\n\n")
	b.WriteString(sectionRule("Recent activity", m.contentWidth()))
	b.WriteString("\n")
	b.WriteString(m.renderEvents())
	return b.String()
}

func (m DetailModel) renderBoard() string {
	switch {
	case !m.boardLoaded:
		return style.Dim.Render("streams unknown — reading coordination status")
	case m.boardErr != "":
		return style.Dim.Render("streams unknown — " + m.boardErr)
	case !m.boardFound:
		return style.Dim.Render("streams unknown — arc is absent from the coordination projection")
	case len(m.rendered) == 0:
		return style.Dim.Render("empty plan — no declared stream rows")
	}
	var b strings.Builder
	for i, rendered := range m.rendered {
		prefix := "  "
		if !m.closed && i == m.rowCursor {
			prefix = "▸ "
		}
		line := rendered.Line
		row, _ := m.rowByID(rendered.StreamID)
		if !m.closed {
			switch row.Gate {
			case "hold":
				line = holdStyle.Render(line)
			case "flag":
				line = flagStyle.Render(line)
			}
		}
		b.WriteString(prefix + line + "\n")
		if !m.closed {
			b.WriteString("    " + style.Dim.Render(m.targetSummary(row)) + "\n")
		}
	}
	return strings.TrimSuffix(b.String(), "\n")
}

func (m DetailModel) rowByID(id string) (board.Row, bool) {
	for _, row := range m.rows {
		if row.StreamID == id {
			return row, true
		}
	}
	return board.Row{}, false
}

func (m DetailModel) liveSessions(workItem string) []sessionview.SessionRow {
	declared, _ := m.memberState(workItem)
	if workItem == "" || workItem == unknown || !declared {
		return nil
	}
	var rows []sessionview.SessionRow
	for _, row := range m.sessions {
		if row.InFlight {
			continue
		}
		if row.Slug == workItem || row.BaseItem == workItem {
			rows = append(rows, row)
		}
	}
	return rows
}

func (m DetailModel) memberState(slug string) (declared, resolved bool) {
	for _, member := range m.members {
		if member.Slug == slug {
			return true, member.Resolved
		}
	}
	return false, false
}

func gateRow(gate string) bool { return gate == "hold" || gate == "flag" }

func (m DetailModel) targetSummary(row board.Row) string {
	workItem := pointerValue(row.WorkItem)
	packet := pointerValue(row.ReviewPacket)
	declared, resolved := m.memberState(workItem)
	workLabel := workItem
	if workItem != unknown && !declared {
		workLabel += " (not an arc member)"
	} else if workItem != unknown && !resolved {
		workLabel += " (unresolved)"
	}
	if gateRow(row.Gate) {
		if _, ok := m.packets[packet]; ok {
			return fmt.Sprintf("work item %s · packet %s · target packet", workLabel, packet)
		}
		if resolved {
			return fmt.Sprintf("work item %s · packet %s · target work item", workLabel, packet)
		}
		return fmt.Sprintf("work item %s · packet %s · target unknown", workLabel, packet)
	}
	sessions := m.liveSessions(workItem)
	switch {
	case len(sessions) == 1:
		return fmt.Sprintf("%s · work item %s · packet %s", sessionTargetSummary(sessions[0]), workLabel, packet)
	case resolved && len(sessions) > 1:
		return fmt.Sprintf("work item %s · packet %s · session ambiguous (%d live) · target work item", workLabel, packet, len(sessions))
	case resolved:
		return fmt.Sprintf("work item %s · packet %s · session unknown · target work item", workLabel, packet)
	default:
		return fmt.Sprintf("work item %s · packet %s · target unknown", workLabel, packet)
	}
}

func sessionTargetSummary(row sessionview.SessionRow) string {
	target := "target session " + explicit(row.Display)
	switch {
	case row.Local:
		return "live terminal available in sessions · " + target
	case row.Tmux != "":
		return "live drill-in available in sessions · " + target
	default:
		return "live screen unavailable — tmux identity unknown · " + target
	}
}

func (m DetailModel) renderEvents() string {
	if len(m.events) == 0 {
		return style.Dim.Render("activity unknown — no matching journal events")
	}
	var b strings.Builder
	for _, event := range m.events {
		identity := explicit(event.Slug)
		if identity == unknown && event.Links != nil {
			identity = explicit(event.Links["work_item"])
		}
		fmt.Fprintf(&b, "• %s · %s · %s\n", explicit(event.TS), explicit(event.Event), identity)
	}
	return strings.TrimSuffix(b.String(), "\n")
}

func (m *DetailModel) openCurrent() tea.Cmd {
	row, ok := m.currentRow()
	if !ok {
		return nil
	}
	workItem := pointerValue(row.WorkItem)
	packet := pointerValue(row.ReviewPacket)
	if gateRow(row.Gate) {
		if body, readable := m.packets[packet]; readable {
			m.mode = ModePacket
			m.packetRef = packet
			m.packetBody = body
			m.viewport.SetYOffset(0)
			m.refresh()
			return nil
		}
		_, resolved := m.memberState(workItem)
		if resolved {
			return func() tea.Msg { return MemberSelectedMsg{Slug: workItem} }
		}
		return nil
	}
	if sessions := m.liveSessions(workItem); len(sessions) == 1 {
		rowID := sessions[0].RowID
		return func() tea.Msg { return SessionSelectedMsg{RowID: rowID} }
	}
	_, resolved := m.memberState(workItem)
	if resolved {
		return func() tea.Msg { return MemberSelectedMsg{Slug: workItem} }
	}
	return nil
}

func (m *DetailModel) openMode(mode DetailMode) {
	switch mode {
	case ModeLedger:
		m.mode = mode
	case ModeReport:
		if !m.closed && m.reportFound {
			m.mode = mode
		}
	}
	m.viewport.SetYOffset(0)
	m.refresh()
}

func (m DetailModel) Init() tea.Cmd { return nil }

func (m DetailModel) Update(msg tea.Msg) (DetailModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.refresh()
		return m, nil
	case tea.KeyPressMsg:
		if m.InDrillIn() {
			switch msg.String() {
			case "h", "esc":
				m.mode = ModePrimary
				m.packetRef, m.packetBody = "", ""
				m.viewport.SetYOffset(0)
				m.refresh()
				return m, nil
			}
		} else if !m.closed {
			switch msg.String() {
			case "j", "down":
				if m.rowCursor < len(m.rendered)-1 {
					m.rowCursor++
					m.refresh()
				}
				return m, nil
			case "k", "up":
				if m.rowCursor > 0 {
					m.rowCursor--
					m.refresh()
				}
				return m, nil
			case "enter", "l":
				return m, m.openCurrent()
			}
		}
		switch msg.String() {
		case "e":
			m.openMode(ModeLedger)
			return m, nil
		case "r":
			m.openMode(ModeReport)
			return m, nil
		}
	}
	var cmd tea.Cmd
	m.viewport, cmd = m.viewport.Update(msg)
	return m, cmd
}

func (m DetailModel) View() string {
	if m.arc == "" {
		return "\n  " + style.Dim.Render("No arc selected.") + "\n\n  " +
			style.Dim.Render("`lore arc open` starts an arc; it appears here as its own row.") + "\n"
	}
	return "\n" + m.viewport.View()
}
