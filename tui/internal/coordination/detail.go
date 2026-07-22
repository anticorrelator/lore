package coordination

import (
	"fmt"
	"sort"
	"strings"

	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/collection"
	"github.com/anticorrelator/lore/tui/internal/render"
	"github.com/anticorrelator/lore/tui/internal/sessionview"
	"github.com/anticorrelator/lore/tui/internal/style"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// Tab IDs for the coordination detail's tab host.
const (
	TabStatus   = "status"
	TabSessions = "sessions"
	TabItems    = "items"
	TabLedger   = "ledger"
)

var (
	attentionStyle = lipgloss.NewStyle().Foreground(style.ColorAttention)
	pinLiveStyle   = lipgloss.NewStyle().Foreground(style.ColorSuccess)
	pinDeadStyle   = lipgloss.NewStyle().Foreground(style.ColorDanger).Bold(true)
)

// MemberSelectedMsg is emitted when Enter/l lands on an Items-tab member row.
// The host carries the selection into the work detail and records the
// coordination view as the return target.
type MemberSelectedMsg struct {
	Slug string
}

// SessionSelectedMsg is emitted when Enter/l lands on a Sessions-tab row. The
// host carries the row into the sessions workspace with its existing attach
// semantics and records the coordination view as the return target.
type SessionSelectedMsg struct {
	RowID string
}

// DetailModel is the coordination arc detail: a tab host over Status
// (Brief + pin + machine state), Sessions (the arc's sessions across
// instances), Items (arc members with status badges), and Ledger (the full
// coordination.md). All content is pushed by the host; the model performs no
// disk I/O, so it stays headless-testable.
type DetailModel struct {
	arc     string
	width   int
	height  int
	tabHost collection.TabHost

	contentStartY int
	contentStartX int

	members    []work.WorkItem
	itemCursor int
	// blocked lists member slugs with at least one still-active blocker,
	// derived from the index projection the host pushes.
	blocked []string

	sessions      []sessionview.SessionRow
	sessionCursor int
	// sessionCard is the read-only session card reused from the sessions
	// workspace; for a cross-instance tmux-hosted row it renders the live
	// screen mirror the host captures on the poll tick.
	sessionCard sessionview.DetailModel

	pinLoaded bool
	pinStatus PinStatus
	pin       *Pin
	pinErr    string

	ledgerLoaded bool
	ledger       string
	brief        string
	briefFound   bool

	statusViewport viewport.Model
	itemsViewport  viewport.Model
	ledgerViewport viewport.Model
}

// NewDetailModel builds an empty coordination detail. A zero-value DetailModel
// blank-renders (nil tab host); always construct through here.
func NewDetailModel() DetailModel {
	m := DetailModel{
		tabHost:     collection.NewTabHost(),
		sessionCard: sessionview.NewDetailModel(),
	}
	m.tabHost.SetDefaultID(TabStatus)
	m.tabHost.SetTabs(m.buildTabs())
	return m
}

// buildTabs returns the fixed four-tab set. Descriptors carry identity and
// label only — content dispatch stays in Update/renderTabContent.
func (m DetailModel) buildTabs() []collection.Tab {
	return []collection.Tab{
		{ID: TabStatus, Label: "Status"},
		{ID: TabSessions, Label: "Sessions"},
		{ID: TabItems, Label: "Items"},
		{ID: TabLedger, Label: "Ledger"},
	}
}

// Arc returns the arc slug this detail renders, "" when none is selected.
func (m DetailModel) Arc() string { return m.arc }

// ActiveTabID returns the active tab's ID.
func (m DetailModel) ActiveTabID() string { return m.tabHost.ActiveID() }

// Title is the detail panel's border title.
func (m DetailModel) Title() string {
	if m.arc == "" {
		return "Coordination"
	}
	return m.arc
}

// SetArc points the detail at a new arc, resetting all per-arc state to
// explicit loading states until the host's reads land. Setting the same arc
// again is a no-op so poll-driven re-selection does not flicker.
func (m *DetailModel) SetArc(arc string) {
	if arc == m.arc {
		return
	}
	m.arc = arc
	m.members = nil
	m.itemCursor = 0
	m.blocked = nil
	m.sessions = nil
	m.sessionCursor = 0
	m.sessionCard = sessionview.NewDetailModel()
	m.pinLoaded = false
	m.pin = nil
	m.pinStatus = PinAbsent
	m.pinErr = ""
	m.ledgerLoaded = false
	m.ledger = ""
	m.brief = ""
	m.briefFound = false
	m.refreshAll()
}

// SetMembers replaces the arc's member items. active is the ActiveSlugs set
// over the whole index, used to derive which members are still blocked.
func (m *DetailModel) SetMembers(members []work.WorkItem, active map[string]bool) {
	prevSlug := ""
	if it, ok := m.CurrentItem(); ok {
		prevSlug = it.Slug
	}
	m.members = members
	m.itemCursor = 0
	for i, it := range members {
		if it.Slug == prevSlug {
			m.itemCursor = i
			break
		}
	}
	m.blocked = nil
	for _, it := range members {
		for _, b := range it.BlockedBy {
			if active[b] {
				m.blocked = append(m.blocked, it.Slug)
				break
			}
		}
	}
	m.refreshStatus()
	m.refreshItems()
}

// SetSessions replaces the arc's session rows (the host's read-side join),
// preserving the cursor by RowID and re-syncing the session card.
func (m *DetailModel) SetSessions(rows []sessionview.SessionRow) {
	prevID := ""
	if r, ok := m.CurrentSession(); ok {
		prevID = r.RowID
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Display < rows[j].Display })
	m.sessions = rows
	m.sessionCursor = 0
	for i, r := range rows {
		if r.RowID == prevID {
			m.sessionCursor = i
			break
		}
	}
	m.syncSessionCard()
	m.refreshStatus()
}

// SetPin records the derived pin state (absent / live / dead) for the arc.
func (m *DetailModel) SetPin(status PinStatus, pin *Pin) {
	m.pinLoaded = true
	m.pinStatus = status
	m.pin = pin
	m.pinErr = ""
	m.refreshStatus()
}

// SetPinError surfaces an unreadable pin sidecar as its own explicit state —
// never silently rendered as unpinned.
func (m *DetailModel) SetPinError(err string) {
	m.pinLoaded = true
	m.pinErr = err
	m.refreshStatus()
}

// SetLedger stores the ledger content and its extracted Brief. An empty
// content marks the ledger unreadable; briefFound=false renders the
// first-class "no Brief yet" state.
func (m *DetailModel) SetLedger(content, brief string, briefFound bool) {
	m.ledgerLoaded = true
	m.ledger = content
	m.brief = brief
	m.briefFound = briefFound
	m.refreshStatus()
	m.refreshLedger()
}

// CurrentItem returns the member item under the Items tab cursor.
func (m DetailModel) CurrentItem() (work.WorkItem, bool) {
	if m.itemCursor < 0 || m.itemCursor >= len(m.members) {
		return work.WorkItem{}, false
	}
	return m.members[m.itemCursor], true
}

// CurrentSession returns the session row under the Sessions tab cursor.
func (m DetailModel) CurrentSession() (sessionview.SessionRow, bool) {
	if m.sessionCursor < 0 || m.sessionCursor >= len(m.sessions) {
		return sessionview.SessionRow{}, false
	}
	return m.sessions[m.sessionCursor], true
}

// RemoteMirror reports the row the host should capture-pane on the poll tick:
// the Sessions tab's current row when it is a cross-instance tmux-hosted
// session and the tab is actually displayed. Visibility scoping keeps the
// subprocess cost proportional to what the user is looking at.
func (m DetailModel) RemoteMirror() (rowID, tmuxName string, ok bool) {
	if m.tabHost.ActiveID() != TabSessions {
		return "", "", false
	}
	return m.sessionCard.RemoteMirror()
}

// SetMirror forwards a captured remote screen to the session card, which
// drops it unless it still matches the displayed row.
func (m *DetailModel) SetMirror(rowID string, lines []string) {
	m.sessionCard.SetMirror(rowID, lines)
}

// SetContentStart stores the absolute terminal coordinates of the first row
// of the detail's output so the tab bar can mouse hit-test.
func (m *DetailModel) SetContentStart(y, x int) {
	m.contentStartY = y
	m.contentStartX = x
	m.tabHost.SetContentStart(y, x)
}

// PreserveTab snapshots the active tab across a host-driven rebuild.
func (m *DetailModel) PreserveTab() { m.tabHost.Preserve() }

func (m DetailModel) contentWidth() int {
	w := m.width - 4
	if w < 20 {
		w = 20
	}
	return w
}

func (m DetailModel) contentHeight() int {
	// overhead: blank(1) + tabbar(1) + blank(1) = 3
	h := m.height - 3
	if h < 5 {
		h = 5
	}
	return h
}

func (m *DetailModel) syncSessionCard() {
	if r, ok := m.CurrentSession(); ok {
		m.sessionCard.SetSession(r, true)
	} else {
		m.sessionCard.SetSession(sessionview.SessionRow{}, false)
	}
}

// refreshAll re-renders every tab's content at the current dimensions.
func (m *DetailModel) refreshAll() {
	m.refreshStatus()
	m.refreshItems()
	m.refreshLedger()
}

func (m *DetailModel) refreshStatus() {
	offset := m.statusViewport.YOffset()
	vp := viewport.New(viewport.WithWidth(m.contentWidth()), viewport.WithHeight(m.contentHeight()))
	vp.SetContent(m.renderStatus(m.contentWidth()))
	vp.SetYOffset(offset)
	m.statusViewport = vp
}

func (m *DetailModel) refreshItems() {
	offset := m.itemsViewport.YOffset()
	vp := viewport.New(viewport.WithWidth(m.contentWidth()), viewport.WithHeight(m.contentHeight()))
	vp.SetContent(m.renderItems())
	vp.SetYOffset(offset)
	m.itemsViewport = vp
}

func (m *DetailModel) refreshLedger() {
	offset := m.ledgerViewport.YOffset()
	vp := viewport.New(viewport.WithWidth(m.contentWidth()), viewport.WithHeight(m.contentHeight()))
	vp.SetContent(m.renderLedger())
	vp.SetYOffset(offset)
	m.ledgerViewport = vp
}

// sectionRule renders "─ Label ────…" in the shared section-framing tokens.
func sectionRule(label string, width int) string {
	title := " " + label + " "
	fill := width - lipgloss.Width(title) - 1
	if fill < 1 {
		fill = 1
	}
	return style.SectionRule.Render("─") +
		style.SubsectionTitle.Render(title) +
		style.SectionRule.Render(strings.Repeat("─", fill))
}

// liveSessionCount counts the arc's live sessions (in-flight spawns are not
// yet live).
func (m DetailModel) liveSessionCount() int {
	n := 0
	for _, r := range m.sessions {
		if !r.InFlight {
			n++
		}
	}
	return n
}

// renderPinLine renders the pin's three first-class states plus the two
// transitional ones (still reading, sidecar unreadable).
func (m DetailModel) renderPinLine() string {
	label := style.Dim.Render("pin  ")
	switch {
	case m.pinErr != "":
		return label + pinDeadStyle.Render("sidecar unreadable") + style.Dim.Render(" — "+m.pinErr)
	case !m.pinLoaded:
		return label + style.Dim.Render("reading…")
	case m.pinStatus == PinLive:
		return label + m.pin.Instance + "  " + pinLiveStyle.Render("● live")
	case m.pinStatus == PinDead:
		return label + m.pin.Instance + "  " + pinDeadStyle.Render("✗ dead") + style.Dim.Render(" — registry row stale; repin before dispatch")
	default:
		return label + style.Dim.Render("none — dispatch has no standing target")
	}
}

func (m DetailModel) renderStatus(width int) string {
	if m.arc == "" {
		return style.Dim.Render("Select an arc.")
	}
	var b strings.Builder

	b.WriteString(sectionRule("Brief", width))
	b.WriteString("\n")
	switch {
	case !m.ledgerLoaded:
		b.WriteString(style.Dim.Render("reading coordination.md…"))
		b.WriteString("\n")
	case m.briefFound:
		b.WriteString(render.Markdown(m.brief, width))
	default:
		b.WriteString(style.Dim.Render("no Brief yet — the ledger has no ## Brief section"))
		b.WriteString("\n")
	}
	b.WriteString("\n")

	b.WriteString(sectionRule("Machine", width))
	b.WriteString("\n")
	b.WriteString(m.renderPinLine())
	b.WriteString("\n")
	b.WriteString(style.Dim.Render("sessions  "))
	b.WriteString(fmt.Sprintf("%d live", m.liveSessionCount()))
	b.WriteString("\n\n")

	b.WriteString(sectionRule("Attention", width))
	b.WriteString("\n")
	var attention []string
	if m.pinLoaded && m.pinStatus == PinDead {
		attention = append(attention, attentionStyle.Render("✗ pin dead: "+m.pin.Instance)+style.Dim.Render(" — dispatch would refuse"))
	}
	for _, slug := range m.blocked {
		attention = append(attention, attentionStyle.Render("⧗ blocked: ")+slug)
	}
	for _, r := range m.sessions {
		if r.NeedsInput {
			attention = append(attention, attentionStyle.Render("● needs input: ")+r.Display)
		}
	}
	if len(attention) == 0 {
		b.WriteString(style.Dim.Render("nothing needs attention"))
		b.WriteString("\n")
	} else {
		for _, a := range attention {
			b.WriteString(a)
			b.WriteString("\n")
		}
	}
	return b.String()
}

// statusBadge renders "● status" through the shared status ramp.
func statusBadge(status string) string {
	s := style.StatusDone
	if status == "active" {
		s = style.StatusActive
	}
	return s.Render("● " + status)
}

func (m DetailModel) renderItems() string {
	if m.arc == "" {
		return style.Dim.Render("Select an arc.")
	}
	if len(m.members) == 0 {
		return style.Dim.Render("no items assigned to this arc yet")
	}
	blocked := make(map[string]bool, len(m.blocked))
	for _, s := range m.blocked {
		blocked[s] = true
	}
	var b strings.Builder
	for i, it := range m.members {
		cursor := "  "
		if i == m.itemCursor {
			cursor = "▸ "
		}
		b.WriteString(cursor)
		b.WriteString(statusBadge(it.Status))
		b.WriteString("  ")
		b.WriteString(it.Slug)
		if blocked[it.Slug] {
			b.WriteString("  ")
			b.WriteString(attentionStyle.Render("⧗ blocked"))
		}
		if it.Title != "" && it.Title != it.Slug {
			b.WriteString("\n     ")
			b.WriteString(style.Dim.Render(it.Title))
		}
		b.WriteString("\n")
	}
	return b.String()
}

func (m DetailModel) renderLedger() string {
	switch {
	case m.arc == "":
		return style.Dim.Render("Select an arc.")
	case !m.ledgerLoaded:
		return style.Dim.Render("reading coordination.md…")
	case m.ledger == "":
		return style.Dim.Render("coordination.md could not be read")
	}
	return render.Markdown(m.ledger, m.contentWidth())
}

// renderSessions renders the Sessions tab: the arc's rows with a cursor, then
// the read-only card (or live mirror) for the selected row.
func (m DetailModel) renderSessions() string {
	if m.arc == "" {
		return style.Dim.Render("Select an arc.")
	}
	if len(m.sessions) == 0 {
		return style.Dim.Render("no sessions for this arc")
	}
	var b strings.Builder
	for i, r := range m.sessions {
		cursor := "  "
		if i == m.sessionCursor {
			cursor = "▸ "
		}
		badge, badgeStyle := sessionBadge(r)
		lineText := r.Display + "  " + r.Type
		if i == m.sessionCursor {
			b.WriteString(cursor + lineText + "  " + badgeStyle.Render(badge))
		} else {
			b.WriteString(cursor + style.Dim.Render(lineText) + "  " + badgeStyle.Render(badge))
		}
		if !r.Local {
			b.WriteString("  " + style.Dim.Render("@"+r.Instance))
		}
		b.WriteString("\n")
	}
	b.WriteString("\n")
	b.WriteString(m.sessionCard.View())
	return b.String()
}

// sessionBadge mirrors the sessions list's next-action vocabulary.
func sessionBadge(r sessionview.SessionRow) (string, lipgloss.Style) {
	switch {
	case r.InFlight:
		return "spawning", style.StatusWarn
	case r.NeedsInput:
		return "needs input", attentionStyle
	case r.ClosePending:
		return "close pending", attentionStyle
	case !r.Local:
		return "◆ active", style.Dim
	case r.Quiescent:
		return "idle", style.Dim
	default:
		return "running", style.StatusActive
	}
}

func (m DetailModel) Init() tea.Cmd { return nil }

func (m DetailModel) Update(msg tea.Msg) (DetailModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.tabHost.SetWidth(m.contentWidth())
		// The session card consumes forwarded inner dimensions verbatim.
		m.sessionCard, _ = m.sessionCard.Update(tea.WindowSizeMsg{Width: m.contentWidth(), Height: m.contentHeight()})
		m.refreshAll()
		return m, nil

	case tea.MouseMsg:
		// Tab bar click hit-test; other mouse events scroll the active tab.
		if click, ok := msg.(tea.MouseClickMsg); ok && click.Button == tea.MouseLeft {
			if click.Y == m.contentStartY+1 && len(m.tabHost.Tabs()) > 0 {
				m.tabHost, _ = m.tabHost.Update(click)
				return m, nil
			}
		}

	case tea.KeyPressMsg:
		switch msg.String() {
		case "tab", "shift+tab":
			m.tabHost, _ = m.tabHost.Update(msg)
			return m, nil
		}
		switch m.tabHost.ActiveID() {
		case TabItems:
			// Items tab: j/k walks the arc's members; Enter/l drills into the
			// selected member's work detail.
			if len(m.members) > 0 {
				switch msg.String() {
				case "j", "down":
					if m.itemCursor < len(m.members)-1 {
						m.itemCursor++
						m.refreshItems()
					}
					return m, nil
				case "k", "up":
					if m.itemCursor > 0 {
						m.itemCursor--
						m.refreshItems()
					}
					return m, nil
				case "enter", "l":
					if it, ok := m.CurrentItem(); ok {
						slug := it.Slug
						return m, func() tea.Msg { return MemberSelectedMsg{Slug: slug} }
					}
					return m, nil
				}
			}
		case TabSessions:
			// Sessions tab: j/k walks the arc's session rows; Enter/l drills into
			// the selected session's surface in the sessions workspace.
			if len(m.sessions) > 0 {
				switch msg.String() {
				case "j", "down":
					if m.sessionCursor < len(m.sessions)-1 {
						m.sessionCursor++
						m.syncSessionCard()
					}
					return m, nil
				case "k", "up":
					if m.sessionCursor > 0 {
						m.sessionCursor--
						m.syncSessionCard()
					}
					return m, nil
				case "enter", "l":
					if r, ok := m.CurrentSession(); ok {
						id := r.RowID
						return m, func() tea.Msg { return SessionSelectedMsg{RowID: id} }
					}
					return m, nil
				}
			}
		}
	}

	// Forward to the active tab's viewport for scrolling.
	var cmd tea.Cmd
	switch m.tabHost.ActiveID() {
	case TabStatus:
		m.statusViewport, cmd = m.statusViewport.Update(msg)
	case TabItems:
		m.itemsViewport, cmd = m.itemsViewport.Update(msg)
	case TabLedger:
		m.ledgerViewport, cmd = m.ledgerViewport.Update(msg)
	}
	return m, cmd
}

func (m DetailModel) View() string {
	if m.arc == "" {
		return "\n  " + style.Dim.Render("No arc selected.") + "\n\n  " +
			style.Dim.Render("A project becomes an arc when its home gains a coordination.md ledger.") + "\n"
	}
	var b strings.Builder
	b.WriteString("\n")
	b.WriteString(m.tabHost.ViewBar())
	b.WriteString("\n\n")
	switch m.tabHost.ActiveID() {
	case TabSessions:
		b.WriteString(m.renderSessions())
	case TabItems:
		b.WriteString(m.itemsViewport.View())
	case TabLedger:
		b.WriteString(m.ledgerViewport.View())
	default:
		b.WriteString(m.statusViewport.View())
	}
	return b.String()
}
