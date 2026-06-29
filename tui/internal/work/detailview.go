package work

import (
	"fmt"
	"strings"

	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/collection"
	"github.com/anticorrelator/lore/tui/internal/style"
)

// Tab identifies a detail view tab.
type Tab int

const (
	TabMeta Tab = iota
	TabPlan
	TabNotes
	TabTasks
	TabExecLog
	TabFile // extra document tabs; identified by a "file:<name>" host ID
)

// extraFileIDPrefix namespaces extra-file tab IDs in the collection.TabHost;
// the suffix is the file's name stem, which is unique within the work item.
const extraFileIDPrefix = "file:"

// hostID is the Tab's stable string identity inside the collection.TabHost.
// TabFile tabs are identified per file via extraFileIDPrefix instead.
func (t Tab) hostID() string {
	switch t {
	case TabMeta:
		return "meta"
	case TabPlan:
		return "plan"
	case TabNotes:
		return "notes"
	case TabTasks:
		return "tasks"
	case TabExecLog:
		return "execlog"
	}
	return ""
}

// tabFromHostID maps a TabHost ID back to the Tab constant (TabMeta when
// the host is empty or the ID is unknown).
func tabFromHostID(id string) Tab {
	if strings.HasPrefix(id, extraFileIDPrefix) {
		return TabFile
	}
	switch id {
	case "plan":
		return TabPlan
	case "notes":
		return TabNotes
	case "tasks":
		return TabTasks
	case "execlog":
		return TabExecLog
	}
	return TabMeta
}

// DetailLoadedMsg is sent when work item detail finishes loading.
type DetailLoadedMsg struct {
	Slug   string
	Detail *WorkItemDetail
	Err    error
}

// BackToListMsg is sent when the user exits the detail view.
type BackToListMsg struct{}

// DetailExternalSessionMsg tells the detail view whether an external session is active.
type DetailExternalSessionMsg struct {
	Active bool
}

// DetailPlanRefreshedMsg carries freshly-read plan.md content for an in-place
// update that preserves the active tab and scroll position.
type DetailPlanRefreshedMsg struct {
	Slug    string
	Content string
}

// DetailModel is the Bubble Tea model for the tabbed detail view. The tab
// host owns tab state, cycling, preserve-across-reload, and mouse
// hit-testing; content rendering and key routing stay here because the tab
// sub-models are value types descriptor callbacks cannot track across model
// copies, so descriptors carry identity and label only.
type DetailModel struct {
	slug    string
	workDir string
	detail  *WorkItemDetail
	loading bool
	err     error
	tabHost collection.TabHost
	width   int
	height  int

	// contentStartY/X track the absolute terminal position of the first row
	// of this detail view's output, set by the parent via SetContentStart().
	// Used for mouse hit-testing (tab bar clicks).
	contentStartY int
	contentStartX int

	externalSession bool // true when another TUI instance has an active session on this slug

	planTab       PlanTabModel
	notesTab      NotesTabModel
	tasksModel    TasksModel
	execLogModel  ExecLogModel
	extraViewports []viewport.Model
}

// NewDetailModel creates a detail model for the given slug and starts loading.
func NewDetailModel(workDir, slug string) DetailModel {
	return DetailModel{
		slug:    slug,
		workDir: workDir,
		loading: true,
		tabHost: collection.NewTabHost(),
	}
}

// LoadDetail returns a command that fetches work item detail directly from disk.
func LoadDetail(workDir, slug string) tea.Cmd {
	return func() tea.Msg {
		detail, err := LoadWorkItemDetail(workDir, slug)
		return DetailLoadedMsg{Slug: slug, Detail: detail, Err: err}
	}
}

func (m DetailModel) Init() tea.Cmd {
	return LoadDetail(m.workDir, m.slug)
}

func (m DetailModel) Update(msg tea.Msg) (DetailModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		// Forward resize to all tab models so they stay in sync on terminal resize
		inner := tea.WindowSizeMsg{Width: m.contentWidth(), Height: m.contentHeight()}
		m.planTab, _ = m.planTab.Update(inner)
		m.notesTab, _ = m.notesTab.Update(inner)
		m.tasksModel, _ = m.tasksModel.Update(inner)
		m.execLogModel, _ = m.execLogModel.Update(inner)
		for i := range m.extraViewports {
			m.extraViewports[i].SetWidth(m.contentWidth())
			m.extraViewports[i].SetHeight(m.contentHeight())
		}
		return m, nil

	case DetailExternalSessionMsg:
		m.externalSession = msg.Active
		// The banner line shifts the tab bar down one row; keep the host's
		// mouse hit-test anchored on the bar.
		if msg.Active {
			m.tabHost.SetBarOffsetY(2)
		} else {
			m.tabHost.SetBarOffsetY(1)
		}
		return m, nil

	case DetailLoadedMsg:
		if msg.Slug != m.slug {
			return m, nil // stale response from a previous item
		}
		m.loading = false
		if msg.Err != nil {
			m.err = msg.Err
			return m, nil
		}
		m.detail = msg.Detail
		m.tabHost.SetTabs(m.buildTabs())
		m.notesTab = NewNotesTabModel(m.detail.NotesContent, m.contentWidth(), m.contentHeight())
		if m.detail.PlanContent != nil {
			rendered := renderMarkdown(*m.detail.PlanContent, m.contentWidth())
			vp := viewport.New(viewport.WithWidth(m.contentWidth()), viewport.WithHeight(m.contentHeight()))
			vp.SetContent(rendered)
			m.planTab = PlanTabModel{viewport: vp, ready: true}
		} else {
			m.planTab = PlanTabModel{empty: true}
		}
		if m.detail.HasTasks {
			if msg.Detail.TasksContent != nil {
				m.tasksModel = newTasksModelFromFile(*msg.Detail.TasksContent)
			} else {
				m.tasksModel = NewTasksModel(m.workDir, m.slug)
			}
			m.tasksModel.width = m.contentWidth()
			m.tasksModel.height = m.contentHeight()
		}
		if m.detail.HasExecutionLog {
			if msg.Detail.ExecLogContent != nil {
				entries := parseExecLog(*msg.Detail.ExecLogContent)
				m.execLogModel = NewExecLogModelFromEntries(entries)
			} else {
				m.execLogModel = NewExecLogModel(m.workDir, m.slug)
			}
			m.execLogModel.width = m.contentWidth()
			m.execLogModel.height = m.contentHeight()
		}
		m.extraViewports = nil
		for _, ef := range m.detail.ExtraFiles {
			rendered := renderMarkdown(ef.Content, m.contentWidth())
			vp := viewport.New(viewport.WithWidth(m.contentWidth()), viewport.WithHeight(m.contentHeight()))
			vp.SetContent(rendered)
			m.extraViewports = append(m.extraViewports, vp)
		}
		return m, nil

	case DetailPlanRefreshedMsg:
		if msg.Slug != m.slug {
			return m, nil
		}
		rendered := renderMarkdown(msg.Content, m.contentWidth())
		prevOffset := m.planTab.viewport.YOffset()
		vp := viewport.New(viewport.WithWidth(m.contentWidth()), viewport.WithHeight(m.contentHeight()))
		vp.SetContent(rendered)
		vp.SetYOffset(prevOffset)
		m.planTab = PlanTabModel{viewport: vp, ready: true}
		// Expose the plan tab if it wasn't present before (e.g. plan.md just created).
		if m.detail != nil && m.detail.PlanContent == nil {
			s := msg.Content
			m.detail.PlanContent = &s
			m.tabHost.SetTabs(m.buildTabs())
		}
		return m, nil

	case tea.MouseMsg:
		// Tab bar click hit-test: only switch tabs on left-click press. The
		// host owns the per-label arithmetic; bar-line clicks never reach the
		// active tab's content.
		if click, ok := msg.(tea.MouseClickMsg); ok && click.Button == tea.MouseLeft {
			if click.Y == m.tabBarY() && len(m.tabHost.Tabs()) > 0 {
				m.tabHost, _ = m.tabHost.Update(click)
				return m, nil
			}
		}
		// Forward all other mouse events to the active tab for scroll handling.

	case tea.KeyPressMsg:
		switch msg.String() {
		case "esc", "b":
			return m, func() tea.Msg { return BackToListMsg{} }
		case "tab", "shift+tab":
			m.tabHost, _ = m.tabHost.Update(msg)
			return m, nil
		}
	}

	// Forward to active tab
	var cmd tea.Cmd
	switch m.ActiveTab() {
	case TabPlan:
		m.planTab, cmd = m.planTab.Update(msg)
	case TabNotes:
		m.notesTab, cmd = m.notesTab.Update(msg)
	case TabTasks:
		m.tasksModel, cmd = m.tasksModel.Update(msg)
	case TabExecLog:
		m.execLogModel, cmd = m.execLogModel.Update(msg)
	case TabFile:
		if idx := m.activeExtraIndex(); idx >= 0 && idx < len(m.extraViewports) {
			m.extraViewports[idx], cmd = m.extraViewports[idx].Update(msg)
		}
	}

	return m, cmd
}

// tabBarY returns the absolute terminal row of the tab bar line: one below
// the content start, two when the external-session banner is showing.
func (m DetailModel) tabBarY() int {
	if m.externalSession {
		return m.contentStartY + 2
	}
	return m.contentStartY + 1
}

// activeExtraIndex resolves the active "file:" tab to its index in
// extraViewports (and detail.ExtraFiles), or -1 when the active tab is not
// an extra-file tab.
func (m DetailModel) activeExtraIndex() int {
	id := m.tabHost.ActiveID()
	if m.detail == nil || !strings.HasPrefix(id, extraFileIDPrefix) {
		return -1
	}
	name := strings.TrimPrefix(id, extraFileIDPrefix)
	for i, ef := range m.detail.ExtraFiles {
		if ef.Name == name {
			return i
		}
	}
	return -1
}

// buildTabs creates the visible tab list based on what content is available.
// Extra files contribute one tab each, identified by their name stem, so the
// descriptor set is unbounded. Descriptors carry identity and label only —
// content dispatch stays in Update/renderTabContent.
func (m DetailModel) buildTabs() []collection.Tab {
	tabs := []collection.Tab{
		{ID: TabMeta.hostID(), Label: "Meta"},
	}

	if m.detail.PlanContent != nil {
		tabs = append(tabs, collection.Tab{ID: TabPlan.hostID(), Label: "Plan"})
	}

	tabs = append(tabs, collection.Tab{ID: TabNotes.hostID(), Label: "Notes"})

	if m.detail.HasTasks {
		tabs = append(tabs, collection.Tab{ID: TabTasks.hostID(), Label: "Tasks"})
	}

	if m.detail.HasExecutionLog {
		tabs = append(tabs, collection.Tab{ID: TabExecLog.hostID(), Label: "Exec Log"})
	}

	for _, ef := range m.detail.ExtraFiles {
		tabs = append(tabs, collection.Tab{ID: extraFileIDPrefix + ef.Name, Label: extraFileLabel(ef.Name)})
	}

	return tabs
}

// extraFileLabel converts a filename stem (without .md) into a display label
// by replacing hyphens and underscores with spaces and title-casing each word.
func extraFileLabel(name string) string {
	name = strings.ReplaceAll(name, "-", " ")
	name = strings.ReplaceAll(name, "_", " ")
	words := strings.Fields(name)
	for i, w := range words {
		if len(w) > 0 {
			words[i] = strings.ToUpper(w[:1]) + w[1:]
		}
	}
	return strings.Join(words, " ")
}

// ActiveTab returns the currently active tab ID.
func (m DetailModel) ActiveTab() Tab {
	return tabFromHostID(m.tabHost.ActiveID())
}

// JumpTo navigates the detail view to the position described by loc.
// It switches to the target tab and sets the cursor or scroll offset.
func (m *DetailModel) JumpTo(loc SearchLocation) {
	m.tabHost.SetActiveID(loc.TabID.hostID())
	// Set cursor/offset within the target tab's sub-model.
	switch loc.TabID {
	case TabNotes:
		if loc.EntryIdx >= 0 && loc.EntryIdx < len(m.notesTab.entries) {
			m.notesTab.cursor = loc.EntryIdx
			m.notesTab.scroll = 0
		}
		// fallback mode: no entries — tab switch above is sufficient, no cursor to set
	case TabExecLog:
		if loc.EntryIdx >= 0 && loc.EntryIdx < len(m.execLogModel.entries) {
			m.execLogModel.cursor = loc.EntryIdx
			m.execLogModel.scroll = 0
		}
	case TabTasks:
		if loc.EntryIdx >= 0 && loc.EntryIdx < len(m.tasksModel.rows) {
			m.tasksModel.cursor = loc.EntryIdx
		}
	case TabPlan:
		if m.planTab.ready {
			m.planTab.viewport.SetYOffset(loc.ScrollOffset)
		}
	}
}

// SetContentStart stores the absolute terminal coordinates of the first row
// of the detail view's output. Called by main.go when layout changes.
func (m *DetailModel) SetContentStart(y, x int) {
	m.contentStartY = y
	m.contentStartX = x
	m.tabHost.SetContentStart(y, x)
}

// PreserveTab snapshots the current active tab so it can be restored after a
// poll-triggered reload.
func (m *DetailModel) PreserveTab() {
	m.tabHost.Preserve()
}

// Detail returns the loaded detail, or nil if still loading.
func (m DetailModel) Detail() *WorkItemDetail {
	return m.detail
}

func (m DetailModel) contentWidth() int {
	w := m.width - 4
	if w < 20 {
		w = 20
	}
	return w
}

func (m DetailModel) contentHeight() int {
	// height is already inner (terminal - 3 for borders/status bar)
	// overhead: blank(1) + tabbar(1) + blank(1) = 3
	h := m.height - 3
	if h < 5 {
		h = 5
	}
	return h
}

func (m DetailModel) View() string {
	if m.slug == "" {
		return "\n  Select a work item to view details.\n"
	}

	if m.loading {
		return fmt.Sprintf("\n  Loading %s...\n", m.slug)
	}

	if m.err != nil {
		return fmt.Sprintf("\n  Error loading %s: %v\n\n  Press Esc to go back.\n", m.slug, m.err)
	}

	var b strings.Builder

	if m.externalSession {
		banner := style.Dim.Render("  ◆ active session in another window")
		b.WriteString(banner)
		b.WriteString("\n")
	}

	// Tab bar (title is in the box border — no need to repeat it here)
	b.WriteString("\n")
	b.WriteString(m.renderTabBar())
	b.WriteString("\n\n")

	// Tab content area
	content := m.renderTabContent(m.contentWidth(), m.contentHeight())
	b.WriteString(content)

	return b.String()
}

func (m DetailModel) renderTabBar() string {
	return m.tabHost.ViewBar()
}

func (m DetailModel) renderTabContent(width, height int) string {
	if m.detail == nil {
		return ""
	}

	tab := m.ActiveTab()
	switch tab {
	case TabMeta:
		return m.renderMetaTab(width)
	case TabPlan:
		return m.planTab.View()
	case TabNotes:
		return m.notesTab.View()
	case TabTasks:
		return m.tasksModel.View()
	case TabExecLog:
		return m.execLogModel.View()
	case TabFile:
		if idx := m.activeExtraIndex(); idx >= 0 && idx < len(m.extraViewports) {
			return m.extraViewports[idx].View()
		}
	}
	return ""
}

// renderMetaTab shows work item metadata with styled badges and relative times.
func (m DetailModel) renderMetaTab(width int) string {
	d := m.detail
	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(style.ColorMetaKey)
	dimStyle := style.Dim
	activeStyle := lipgloss.NewStyle().Bold(true).Foreground(style.ColorSuccess)
	archivedStyle := style.Dim
	linkStyle := lipgloss.NewStyle().Foreground(style.ColorAccent).Underline(true)

	var b strings.Builder

	field := func(label, value string) {
		b.WriteString("  ")
		b.WriteString(labelStyle.Render(label + ":"))
		b.WriteString(" ")
		if value == "" {
			b.WriteString(dimStyle.Render("--"))
		} else {
			b.WriteString(value)
		}
		b.WriteString("\n")
	}

	field("Slug", d.Slug)

	// Status with color badge
	statusDisplay := d.Status
	switch d.Status {
	case "active":
		statusDisplay = activeStyle.Render(d.Status)
	case "archived":
		statusDisplay = archivedStyle.Render(d.Status)
	}
	b.WriteString("  ")
	b.WriteString(labelStyle.Render("Status:"))
	b.WriteString(" ")
	b.WriteString(statusDisplay)
	b.WriteString("\n")

	// Created timestamp
	field("Created", d.Created)

	// Updated with relative time
	updatedDisplay := d.Updated
	if d.Updated != "" {
		rel := FormatRelativeTime(d.Updated)
		updatedDisplay = d.Updated + " " + dimStyle.Render("("+rel+")")
	}
	b.WriteString("  ")
	b.WriteString(labelStyle.Render("Updated:"))
	b.WriteString(" ")
	b.WriteString(updatedDisplay)
	b.WriteString("\n")

	// Issue URL (styled as link)
	if d.Issue != "" {
		b.WriteString("  ")
		b.WriteString(labelStyle.Render("Issue:"))
		b.WriteString(" ")
		b.WriteString(linkStyle.Render(d.Issue))
		b.WriteString("\n")
	} else {
		field("Issue", "")
	}

	// PR URL (styled as link)
	if d.PR != "" {
		b.WriteString("  ")
		b.WriteString(labelStyle.Render("PR:"))
		b.WriteString(" ")
		b.WriteString(linkStyle.Render(d.PR))
		b.WriteString("\n")
	} else {
		field("PR", "")
	}

	if len(d.Branches) > 0 {
		field("Branches", strings.Join(d.Branches, ", "))
	} else {
		field("Branches", "")
	}

	if len(d.Tags) > 0 {
		field("Tags", strings.Join(d.Tags, ", "))
	} else {
		field("Tags", "")
	}

	if len(d.RelatedWork) > 0 {
		field("Related", strings.Join(d.RelatedWork, ", "))
	}

	return b.String()
}

// BuildSearchIndex returns searchable locations across all tabs in the detail view.
func (m DetailModel) BuildSearchIndex() []SearchLocation {
	if m.detail == nil {
		return nil
	}

	var locs []SearchLocation

	// Notes tab: one entry per note, or a single fallback entry for raw content.
	if m.notesTab.fallback {
		locs = append(locs, SearchLocation{
			TabID:    TabNotes,
			TabLabel: "Notes",
			Label:    "Notes (raw)",
			Subtitle: "Notes",
			EntryIdx: -1,
		})
	} else if !m.notesTab.empty {
		for i, entry := range m.notesTab.entries {
			locs = append(locs, SearchLocation{
				TabID:    TabNotes,
				TabLabel: "Notes",
				Label:    entry.Timestamp,
				Subtitle: "Notes",
				EntryIdx: i,
			})
		}
	}

	// ExecLog tab: one entry per log entry.
	if !m.execLogModel.empty {
		for i, entry := range m.execLogModel.entries {
			label := entry.Timestamp
			if entry.Source != "" {
				label += " | " + entry.Source
			}
			locs = append(locs, SearchLocation{
				TabID:    TabExecLog,
				TabLabel: "Exec Log",
				Label:    label,
				Subtitle: "Exec Log",
				EntryIdx: i,
			})
		}
	}

	// Tasks tab: one entry per visible task row (skip phase headers).
	if !m.tasksModel.empty {
		for i, row := range m.tasksModel.rows {
			if row.isPhase {
				continue
			}
			if row.task != nil {
				locs = append(locs, SearchLocation{
					TabID:    TabTasks,
					TabLabel: "Tasks",
					Label:    row.task.Subject,
					Subtitle: "Tasks",
					EntryIdx: i,
				})
			}
		}
	}

	// Plan tab: one entry per heading line in the raw plan content.
	if m.detail.PlanContent != nil && !m.planTab.empty {
		lines := strings.Split(*m.detail.PlanContent, "\n")
		for i, line := range lines {
			if strings.HasPrefix(line, "#") {
				heading := strings.TrimSpace(strings.TrimLeft(line, "#"))
				if heading != "" {
					locs = append(locs, SearchLocation{
						TabID:        TabPlan,
						TabLabel:     "Plan",
						Label:        heading,
						Subtitle:     "Plan",
						ScrollOffset: i,
					})
				}
			}
		}
	}

	return locs
}
