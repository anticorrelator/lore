package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textarea"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/creack/pty"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/gh"
	"github.com/anticorrelator/lore/tui/internal/knowledge"
	"github.com/anticorrelator/lore/tui/internal/search"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// appState tracks which view is active.
type appState int

const (
	stateWork appState = iota
	stateSearch
	stateKnowledge
)

// panelFocus tracks which panel has keyboard focus in split-pane mode.
type panelFocus int

const (
	panelLeft panelFocus = iota
	panelRight
)

// popupContext distinguishes which handler processes PopupSelectedMsg.
type popupContext int

const (
	contextList   popupContext = iota // list-context: jump to work item
	contextDetail                     // detail-context: jump within detail view
)

const leftPanelWidth = 40

// innerHeight returns the usable inner content height: terminal minus top/bottom borders, status bar, and top padding.
func (m model) innerHeight() int {
	h := m.height - 4
	if h < 1 {
		h = 1
	}
	return h
}

// topPanelHeight returns the height of the top panel in top/bottom layout (25% of innerHeight, min 5).
func (m model) topPanelHeight() int {
	h := m.innerHeight() * 25 / 100
	if h < 5 {
		h = 5
	}
	return h
}

// topPanelWidth returns the inner content width for panels in top/bottom layout.
func (m model) topPanelWidth() int {
	return m.width - 2
}

// detailPanelHeight returns the inner content height available for the detail panel,
// accounting for layout mode. In left/right mode the detail gets the full innerHeight;
// in top/bottom mode it gets the remaining space below the top panel and separator.
func (m model) detailPanelHeight() int {
	if m.layoutMode == config.LayoutTopBottom {
		return m.innerHeight() - m.topPanelHeight() - 1
	}
	return m.innerHeight()
}

// prefsSavedMsg is a no-op message returned after asynchronously persisting layout preferences.
type prefsSavedMsg struct{}

// workAIFinishedMsg is sent after lore work ai returns.
type workAIFinishedMsg struct{}

// aiTickMsg drives the loading-dots animation while aiLoading is true.
type aiTickMsg struct{}

func aiTick() tea.Cmd {
	return tea.Tick(400*time.Millisecond, func(time.Time) tea.Msg { return aiTickMsg{} })
}

func enableKittyKeyboard() tea.Cmd {
	return func() tea.Msg {
		os.Stdout.WriteString("\x1b[>1u")
		return nil
	}
}

func disableKittyKeyboard() tea.Cmd {
	return func() tea.Msg {
		os.Stdout.WriteString("\x1b[<u")
		return nil
	}
}

// popupSearchResultMsg carries results from a debounced popup search subprocess.
type popupSearchResultMsg struct {
	items []search.PopupItem
	query string
}

// indexPollTickMsg fires every 5 seconds to trigger an mtime check on _index.json.
type indexPollTickMsg struct{}

func indexPollTick() tea.Cmd {
	return tea.Tick(5*time.Second, func(time.Time) tea.Msg { return indexPollTickMsg{} })
}

// indexMtimeCheckedMsg carries the result of stat-ing the index file.
type indexMtimeCheckedMsg struct {
	mtime time.Time
	err   error
}

// checkIndexMtime returns a Cmd that stats the index file and sends the mtime back.
func checkIndexMtime(path string) tea.Cmd {
	return func() tea.Msg {
		info, err := os.Stat(path)
		if err != nil {
			return indexMtimeCheckedMsg{err: err}
		}
		return indexMtimeCheckedMsg{mtime: info.ModTime()}
	}
}

// planMtimeCheckedMsg carries the result of stat-ing a work item's plan.md.
type planMtimeCheckedMsg struct {
	slug  string
	mtime time.Time
	err   error
}

// detailMtimeCheckedMsg carries the result of stat-ing a work item's detail files.
type detailMtimeCheckedMsg struct {
	slug  string
	mtime time.Time
	err   error
}

// planContentReadMsg carries freshly-read plan.md content for an in-place refresh.
type planContentReadMsg struct {
	slug    string
	content string
}

// checkPlanMtime stats plan.md for the given slug and sends planMtimeCheckedMsg.
func checkPlanMtime(workDir, slug string) tea.Cmd {
	return func() tea.Msg {
		p := filepath.Join(workDir, slug, "plan.md")
		info, err := os.Stat(p)
		if err != nil {
			return planMtimeCheckedMsg{slug: slug, err: err}
		}
		return planMtimeCheckedMsg{slug: slug, mtime: info.ModTime()}
	}
}

// checkDetailMtime stats _meta.json, notes.md, execution-log.md, and tasks.json
// for the given slug and sends detailMtimeCheckedMsg with the most recent mtime.
func checkDetailMtime(workDir, slug string) tea.Cmd {
	return func() tea.Msg {
		dir := filepath.Join(workDir, slug)
		files := []string{"_meta.json", "notes.md", "execution-log.md", "tasks.json"}
		var maxMtime time.Time
		for _, f := range files {
			info, err := os.Stat(filepath.Join(dir, f))
			if err != nil {
				continue // file may not exist yet
			}
			if mt := info.ModTime(); mt.After(maxMtime) {
				maxMtime = mt
			}
		}
		if maxMtime.IsZero() {
			return detailMtimeCheckedMsg{slug: slug, err: errors.New("no detail files found")}
		}
		return detailMtimeCheckedMsg{slug: slug, mtime: maxMtime}
	}
}

// readPlanContent reads plan.md for the given slug and sends planContentReadMsg.
func readPlanContent(workDir, slug string) tea.Cmd {
	return func() tea.Msg {
		data, err := os.ReadFile(filepath.Join(workDir, slug, "plan.md"))
		if err != nil {
			return planContentReadMsg{slug: slug}
		}
		return planContentReadMsg{slug: slug, content: string(data)}
	}
}

// runWorkAI runs lore work ai headlessly and returns workAIFinishedMsg when done.
func runWorkAI(prompt string) tea.Cmd {
	return func() tea.Msg {
		exec.Command("lore", "work", "ai", prompt).Run()
		return workAIFinishedMsg{}
	}
}

// runArchive runs lore work archive (or unarchive) and returns ArchiveFinishedMsg when done.
func runArchive(slug string, unarchive bool) tea.Cmd {
	return func() tea.Msg {
		subcmd := "archive"
		if unarchive {
			subcmd = "unarchive"
		}
		err := exec.Command("lore", "work", subcmd, slug).Run()
		return work.ArchiveFinishedMsg{Err: err}
	}
}

type model struct {
	state        appState
	focusedPanel panelFocus
	layoutMode   config.LayoutMode
	list         work.ListModel
	detail       work.DetailModel
	searchPanel  search.PanelModel
	browser      knowledge.BrowserModel
	config       config.Config
	width        int
	height       int
	err          error
	detailCache  map[string]*work.WorkItemDetail

	aiInputActive bool
	aiLoading     bool
	aiDots        int
	aiInput       textarea.Model

	// specPanels holds one SpecPanelModel per work item slug that is currently
	// speccing (or has just completed). The spec panel for the currently
	// selected list item is shown in the right panel when present.
	specPanels   map[string]work.SpecPanelModel
	terminalMode bool

	specConfirmActive        bool
	specConfirmSlug          string
	specConfirmTitle         string
	specConfirmInput         textarea.Model
	specConfirmShortMode     bool
	specConfirmSkipConfirm   bool
	specConfirmChatMode      bool
	specLaunchedFromModal    bool

	showHelp bool

	popup          search.PopupModel
	popupActive    bool
	popupCtx       popupContext
	popupLastQuery string
	popupDebounce  int

	// indexPath is the absolute path to _index.json, used for mtime polling.
	indexPath      string
	lastIndexMtime time.Time
	lastPlanMtime    time.Time
	lastDetailMtime  time.Time
}

// currentSpecPanel returns the spec panel for the currently selected work item, if any.
func (m model) currentSpecPanel() (work.SpecPanelModel, bool) {
	if m.specPanels == nil {
		return work.SpecPanelModel{}, false
	}
	slug := m.list.CurrentSlug()
	if slug == "" {
		return work.SpecPanelModel{}, false
	}
	panel, ok := m.specPanels[slug]
	return panel, ok
}

// hasSpecPanel reports whether a spec panel exists for the given slug.
func (m model) hasSpecPanel(slug string) bool {
	_, ok := m.specPanels[slug]
	return ok
}

// setSpecPanel stores or replaces the spec panel for the given slug.
func (m *model) setSpecPanel(slug string, panel work.SpecPanelModel) {
	if m.specPanels == nil {
		m.specPanels = make(map[string]work.SpecPanelModel)
	}
	m.specPanels[slug] = panel
}

type workItemsLoadedMsg struct {
	items []work.WorkItem
	err   error
}

type prStatusLoadedMsg struct {
	statuses map[string]gh.PRStatus
	err      error
}

func loadWorkItems(workDir string) tea.Cmd {
	return func() tea.Msg {
		items, err := work.LoadIndex(workDir)
		return workItemsLoadedMsg{items: items, err: err}
	}
}

func loadPRStatus() tea.Cmd {
	return func() tea.Msg {
		statuses, err := gh.LoadPRStatus(context.Background())
		return prStatusLoadedMsg{statuses: statuses, err: err}
	}
}

// buildWorkItemPopupItems converts work items into popup items for the search overlay.
func buildWorkItemPopupItems(items []work.WorkItem) []search.PopupItem {
	result := make([]search.PopupItem, len(items))
	for i, item := range items {
		result[i] = search.PopupItem{
			ID:       item.Slug,
			Label:    item.Title,
			Subtitle: item.Slug,
		}
	}
	return result
}

// runPopupSearch executes `lore work search <query> --json` and converts results to PopupItems.
func runPopupSearch(query string) tea.Msg {
	cmd := exec.Command("lore", "work", "search", query, "--json")
	out, err := cmd.Output()
	if err != nil {
		return popupSearchResultMsg{query: query}
	}
	var results []search.SearchResult
	if err := json.Unmarshal(out, &results); err != nil {
		return popupSearchResultMsg{query: query}
	}
	items := make([]search.PopupItem, len(results))
	for i, r := range results {
		slug := r.Slug
		if slug == "" {
			// Extract from path as fallback.
			parts := strings.Split(r.Path, "/")
			for j, p := range parts {
				if p == "_work" && j+1 < len(parts) {
					slug = parts[j+1]
					break
				}
			}
		}
		label := r.Heading
		if label == "" {
			label = slug
		}
		items[i] = search.PopupItem{
			ID:       slug,
			Label:    label,
			Subtitle: r.Category,
		}
	}
	return popupSearchResultMsg{items: items, query: query}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(
		loadWorkItems(m.config.WorkDir),
		loadPRStatus(),
		indexPollTick(),
	)
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	// Help modal: intercept all keys; Esc or ? closes it.
	if m.showHelp {
		if km, ok := msg.(tea.KeyMsg); ok {
			if km.String() == "esc" || km.String() == "?" {
				m.showHelp = false
			}
			return m, nil
		}
		// Non-key messages (e.g. window resize) fall through.
	}

	// Spec confirm modal: intercept all keys before launching subprocess.
	if m.specConfirmActive {
		if km, ok := msg.(tea.KeyMsg); ok {
			switch km.String() {
			case "enter":
				extraContext := strings.TrimSpace(m.specConfirmInput.Value())
				m.specConfirmActive = false
				slug := m.specConfirmSlug
				// Mark item as speccing in the list.
				m.list, _ = m.list.Update(work.SpecStatusMsg{Slug: slug})
				// Create spec panel sized to the panel slot it occupies (detailPanelHeight).
				specH := m.detailPanelHeight()
				specW := m.rightPanelWidth() - 2 // 1-char buffer on each side
				panel := work.NewSpecPanelModel(slug)
				panel, _ = panel.Update(tea.WindowSizeMsg{Width: specW, Height: specH})
				m.setSpecPanel(slug, panel)
				m.detail, _ = m.detail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
				m.specLaunchedFromModal = true
				return m, work.StartTerminalCmd(slug, m.specConfirmTitle, m.config.ProjectDir, specW, specH, extraContext, m.specConfirmShortMode, m.specConfirmChatMode, m.specConfirmSkipConfirm)
			case "esc", "ctrl+c":
				m.specConfirmActive = false
				return m, nil
			case "alt+1":
				if !m.specConfirmChatMode {
					m.specConfirmShortMode = !m.specConfirmShortMode
				}
				return m, nil
			case "alt+2":
				if !m.specConfirmChatMode {
					m.specConfirmSkipConfirm = !m.specConfirmSkipConfirm
				}
				return m, nil
			default:
				var taCmd tea.Cmd
				m.specConfirmInput, taCmd = m.specConfirmInput.Update(msg)
				return m, taCmd
			}
		}
		// Non-key messages fall through.
	}

	// AI modal: intercept all keys when the input is active.
	if m.aiInputActive {
		if km, ok := msg.(tea.KeyMsg); ok {
			switch km.String() {
			case "enter":
				prompt := strings.TrimSpace(m.aiInput.Value())
				m.aiInputActive = false
				if prompt == "" {
					return m, nil
				}
				m.aiLoading = true
				m.aiDots = 0
				return m, tea.Batch(runWorkAI(prompt), aiTick())
			case "esc", "ctrl+c":
				m.aiInputActive = false
				return m, nil
			default:
				var taCmd tea.Cmd
				m.aiInput, taCmd = m.aiInput.Update(msg)
				return m, taCmd
			}
		}
		// Non-key messages (window resize etc.) fall through to normal handling.
	}

	// Popup overlay: route all key messages to popup when active.
	if m.popupActive {
		if _, ok := msg.(tea.KeyMsg); ok {
			var cmd tea.Cmd
			m.popup, cmd = m.popup.Update(msg)

			// Debounced subprocess search when input changes.
			newQuery := m.popup.InputValue()
			if newQuery != m.popupLastQuery {
				m.popupLastQuery = newQuery
				m.popupDebounce++
				if len(newQuery) < 2 {
					// Short query: revert to full work item list.
					m.popup.SetItems(buildWorkItemPopupItems(m.list.Items()))
				} else {
					id := m.popupDebounce
					q := newQuery
					searchCmd := tea.Tick(200*time.Millisecond, func(time.Time) tea.Msg {
						_ = id
						return runPopupSearch(q)
					})
					return m, tea.Batch(cmd, searchCmd)
				}
			}

			return m, cmd
		}
		// Non-key messages (PopupDismissedMsg, PopupSelectedMsg, resize) fall through.
	}

	switch msg := msg.(type) {
	case workAIFinishedMsg:
		m.aiLoading = false
		// Reload the work item list to pick up newly created items.
		return m, loadWorkItems(m.config.WorkDir)

	case work.ArchiveRequestMsg:
		return m, runArchive(msg.Slug, msg.Unarchive)

	case work.ArchiveFinishedMsg:
		if msg.Err != nil {
			m.err = fmt.Errorf("archive operation failed: %w", msg.Err)
		}
		return m, loadWorkItems(m.config.WorkDir)

	case aiTickMsg:
		if m.aiLoading {
			m.aiDots = (m.aiDots + 1) % 4
			return m, aiTick()
		}

	case indexPollTickMsg:
		cmds := []tea.Cmd{checkIndexMtime(m.indexPath), indexPollTick()}
		// Poll plan.md and detail files for the current item on every tick.
		if slug := m.list.CurrentSlug(); slug != "" {
			cmds = append(cmds, checkPlanMtime(m.config.WorkDir, slug))
			cmds = append(cmds, checkDetailMtime(m.config.WorkDir, slug))
		}
		return m, tea.Batch(cmds...)

	case indexMtimeCheckedMsg:
		if msg.err != nil {
			return m, nil // skip on error, retry next tick
		}
		if m.lastIndexMtime.IsZero() {
			m.lastIndexMtime = msg.mtime // baseline initialization
			return m, nil
		}
		if !msg.mtime.Equal(m.lastIndexMtime) {
			m.lastIndexMtime = msg.mtime
			return m, loadWorkItems(m.config.WorkDir)
		}
		return m, nil

	case planMtimeCheckedMsg:
		if msg.err != nil || msg.slug != m.list.CurrentSlug() {
			return m, nil
		}
		prev := m.lastPlanMtime
		m.lastPlanMtime = msg.mtime
		if prev.IsZero() || !msg.mtime.Equal(prev) {
			// First appearance OR mtime changed — read and push to detail view.
			return m, readPlanContent(m.config.WorkDir, msg.slug)
		}
		return m, nil

	case planContentReadMsg:
		if msg.slug != m.list.CurrentSlug() || msg.content == "" {
			return m, nil
		}
		// Invalidate cache so next full reload picks up the new content too.
		if m.detailCache != nil {
			delete(m.detailCache, msg.slug)
		}
		dm, cmd := m.detail.Update(work.DetailPlanRefreshedMsg{Slug: msg.slug, Content: msg.content})
		m.detail = dm
		return m, cmd

	case detailMtimeCheckedMsg:
		if msg.err != nil || msg.slug != m.list.CurrentSlug() {
			return m, nil
		}
		if m.lastDetailMtime.IsZero() {
			m.lastDetailMtime = msg.mtime // baseline initialization
			return m, nil
		}
		if !msg.mtime.Equal(m.lastDetailMtime) {
			m.lastDetailMtime = msg.mtime
			// Preserve active tab across the reload.
			m.detail.PreserveTab()
			// Invalidate cache so the reload fetches fresh data.
			if m.detailCache != nil {
				delete(m.detailCache, msg.slug)
			}
			return m, work.LoadDetail(m.config.WorkDir, msg.slug)
		}
		return m, nil

	case tea.MouseMsg:
		// Centralized click routing: main.go owns all panel geometry,
		// so mouse events are routed here before reaching sub-models.
		isClick := msg.Action == tea.MouseActionPress && msg.Button == tea.MouseButtonLeft && !msg.Shift
		switch m.state {
		case stateWork:
			if m.layoutMode == config.LayoutLeftRight {
				// LayoutLeftRight X routing:
				// Layout: ┌(1) + leftContent(leftPanelWidth) + ┐(1) | ┌(1) + rightContent + ┐(1)
				// Left panel occupies X in [0, leftPanelWidth+1]; right starts at leftPanelWidth+2.
				if isClick {
					xBoundary := leftPanelWidth + 2
					if msg.X < xBoundary {
						m.focusedPanel = panelLeft
					} else {
						m.focusedPanel = panelRight
					}
				}
			} else {
				// Top/bottom layout Y thresholds (from viewSplitPaneTopBottom rendering):
				// Row 0: blank, Row 1: top border, Rows 2..(1+topH): top content,
				// Row (2+topH): top bottom-border, Row (3+topH): bottom top-border,
				// Rows (4+topH+i) for i in 0..bottomH-1: bottom content rows.
				// Spec zone starts at row 4+topH+detailH+1 = 5+topH+detailH.
				if isClick {
					topH := m.topPanelHeight()
					if msg.Y <= 1+topH {
						m.focusedPanel = panelLeft
					} else {
						m.focusedPanel = panelRight
					}
				}
			}
			// Forward MouseMsg to the now-focused sub-model so click/wheel
			// events reach per-pane handlers (viewport scroll, tab clicks, etc.).
			switch m.focusedPanel {
			case panelLeft:
				prevSlug := m.list.CurrentSlug()
				lm, cmd := m.list.Update(msg)
				m.list = lm
				newSlug := m.list.CurrentSlug()
				if newSlug != "" && newSlug != prevSlug {
					var detailCmd tea.Cmd
					m, detailCmd = m.loadDetail(newSlug)
					return m, tea.Batch(cmd, detailCmd)
				}
				return m, cmd
			default: // panelRight
				// When terminal mode is active, route mouse events to the spec panel.
				if m.terminalMode {
					slug := m.list.CurrentSlug()
					if m.specPanels != nil {
						if panel, ok := m.specPanels[slug]; ok {
							sm, cmd := panel.Update(msg)
							m.specPanels[slug] = sm
							return m, cmd
						}
					}
				}
				// Set absolute position so detail can hit-test tab bar clicks.
				if m.layoutMode == config.LayoutLeftRight {
					m.detail.SetContentStart(2, leftPanelWidth+5)
				} else {
					m.detail.SetContentStart(m.topPanelHeight()+4, 3)
				}
				var cmd tea.Cmd
				m.detail, cmd = m.detail.Update(msg)
				return m, cmd
			}
		case stateKnowledge:
			// Browser uses the same leftPanelWidth split as stateWork LayoutLeftRight.
			if isClick {
				xBoundary := leftPanelWidth + 2
				if msg.X < xBoundary {
					m.browser.FocusLeft()
				} else {
					m.browser.FocusRight()
				}
			}
			bm, cmd := m.browser.Update(msg)
			m.browser = bm
			return m, cmd
		}

	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c":
			// In terminal mode, ctrl+c terminates the terminal panel only.
			if m.state == stateWork && m.terminalMode {
				slug := m.list.CurrentSlug()
				return m, func() tea.Msg { return work.TerminalTerminateMsg{Slug: slug} }
			}
			for slug := range m.specPanels {
				work.ClearSession(m.config.WorkDir, slug) //nolint:errcheck
			}
			return m, tea.Quit
		case "ctrl+d":
			if !(m.state == stateWork && m.terminalMode) {
				for slug := range m.specPanels {
					work.ClearSession(m.config.WorkDir, slug) //nolint:errcheck
				}
				return m, tea.Quit
			}
		case "?":
			if !m.terminalMode {
				m.showHelp = true
				return m, nil
			}
		case "q":
			if m.state == stateWork && !m.terminalMode {
				for slug := range m.specPanels {
					work.ClearSession(m.config.WorkDir, slug) //nolint:errcheck
				}
				return m, tea.Quit
			}
		case "N":
			// N opens the AI work item prompt (left panel only).
			if m.state == stateWork && m.focusedPanel == panelLeft {
				ta := textarea.New()
				ta.Placeholder = ""
				ta.Prompt = " "
				ta.ShowLineNumbers = false
				ta.CharLimit = 0
				ta.SetWidth(54) // must come after Prompt/ShowLineNumbers
				ta.SetHeight(4)
				focusCmd := ta.Focus()
				m.aiInput = ta
				m.aiInputActive = true
				return m, focusCmd
			}
		case "L":
			// L toggles layout between left/right and top/bottom (left panel only).
			if m.state == stateWork && m.focusedPanel == panelLeft {
				if m.layoutMode == config.LayoutLeftRight {
					m.layoutMode = config.LayoutTopBottom
				} else {
					m.layoutMode = config.LayoutLeftRight
				}
				m.list.SetCompactMode(m.layoutMode == config.LayoutLeftRight)

				// Re-apply dimensions to list
				listW := leftPanelWidth
				listH := m.innerHeight()
				if m.layoutMode == config.LayoutTopBottom {
					listW = m.topPanelWidth()
					listH = m.topPanelHeight()
				}
				m.list, _ = m.list.Update(tea.WindowSizeMsg{Width: listW, Height: listH})

				// Re-apply dimensions to detail and all open spec panels.
				m.detail, _ = m.detail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
				specH := m.detailPanelHeight()
				specW := m.rightPanelWidth() - 2
				for slug, panel := range m.specPanels {
					sm, _ := panel.Update(tea.WindowSizeMsg{Width: specW, Height: specH})
					if ptmx := sm.Ptmx(); ptmx != nil {
						_ = pty.Setsize(ptmx, &pty.Winsize{
							Rows: uint16(specH),
							Cols: uint16(specW),
						})
					}
					m.specPanels[slug] = sm
				}

				// Persist preference asynchronously
				prefs := config.Prefs{Layout: m.layoutMode}
				return m, func() tea.Msg {
					_ = config.SavePrefs(prefs)
					return prefsSavedMsg{}
				}
			}
		case "/":
			if m.state == stateWork && m.focusedPanel == panelLeft {
				items := buildWorkItemPopupItems(m.list.Items())
				m.popup = search.New(items, "Search Work Items")
				m.popup.SetSize(m.width, m.height)
				m.popupActive = true
				m.popupCtx = contextList
				return m, m.popup.Init()
			}
			if m.state == stateWork && m.focusedPanel == panelRight && !m.terminalMode && m.detail.Detail() != nil {
				locs := m.detail.BuildSearchIndex()
				items := make([]search.PopupItem, len(locs))
				for i, loc := range locs {
					items[i] = search.PopupItem{
						ID:       fmt.Sprintf("%d", i),
						Label:    loc.Label,
						Subtitle: loc.TabLabel,
						Data:     loc,
					}
				}
				m.popup = search.New(items, "Search Detail")
				m.popup.SetSize(m.width, m.height)
				m.popupActive = true
				m.popupCtx = contextDetail
				return m, m.popup.Init()
			}
			// stateKnowledge / no match: no-op.
		case "K":
			if m.state == stateWork && !m.terminalMode {
				m.state = stateKnowledge
				m.browser = knowledge.NewBrowserModel(m.config.KnowledgeDir)
				m.browser, _ = m.browser.Update(tea.WindowSizeMsg{Width: m.width, Height: m.height})
				return m, knowledge.LoadManifestCmd(m.config.KnowledgeDir)
			}
		case "h":
			// h shifts focus back to left (list) panel from the right detail panel.
			if m.state == stateWork && m.focusedPanel == panelRight && !m.terminalMode {
				m.focusedPanel = panelLeft
				return m, nil
			}
		case "esc":
			// Esc from right panel (detail mode only): back to list.
			// In terminal mode, esc falls through to spec panel which sends TerminalDetachMsg.
			if m.state == stateWork && m.focusedPanel == panelRight && !m.terminalMode {
				m.focusedPanel = panelLeft
				return m, nil
			}
		case "ctrl+t":
			// ctrl+t toggles the right panel between detail and terminal, like a tab.
			// Handled here (before route-to-active-view) so it is never forwarded to the PTY.
			if m.state == stateWork && m.focusedPanel == panelRight {
				if m.terminalMode {
					m.terminalMode = false
					return m, disableKittyKeyboard()
				}
				if panel, ok := m.currentSpecPanel(); ok && panel.Ptmx() != nil {
					m.terminalMode = true
					return m, tea.Batch(tea.EnableMouseCellMotion, enableKittyKeyboard())
				}
			}
		case "tab":
			// Tab moves focus left→right only. When on the right panel, Tab
			// falls through to the detail view so it can cycle through tabs.
			if m.state == stateWork && m.focusedPanel == panelLeft {
				m.focusedPanel = panelRight
				return m, nil
			}
		case "s":
			if m.state == stateWork && m.focusedPanel == panelRight && !m.terminalMode {
				if slug := m.list.CurrentSlug(); slug != "" {
					return m, func() tea.Msg { return work.SpecRequestMsg{Slug: slug} }
				}
			}
		case "c":
			if m.state == stateWork && m.focusedPanel == panelRight && !m.terminalMode {
				if slug := m.list.CurrentSlug(); slug != "" {
					title := slug
					for _, item := range m.list.Items() {
						if item.Slug == slug {
							title = item.Title
							break
						}
					}
					return m, func() tea.Msg { return work.ChatRequestMsg{Slug: slug, Title: title} }
				}
			}
		}

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

		// Send constrained sizes to sub-models (inner height excludes borders + status bar).
		// In top/bottom layout, list gets full width and topPanelHeight.
		listW := leftPanelWidth
		listH := m.innerHeight()
		if m.layoutMode == config.LayoutTopBottom {
			listW = m.topPanelWidth()
			listH = m.topPanelHeight()
		}
		lm, lcmd := m.list.Update(tea.WindowSizeMsg{Width: listW, Height: listH})
		m.list = lm

		// Size detail — reduced when current item has a spec panel open.
		var dcmd tea.Cmd
		m.detail, dcmd = m.detail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
		specH := m.detailPanelHeight()
		specW := m.rightPanelWidth() - 2
		for slug, panel := range m.specPanels {
			sm, _ := panel.Update(tea.WindowSizeMsg{Width: specW, Height: specH})
			if ptmx := sm.Ptmx(); ptmx != nil {
				_ = pty.Setsize(ptmx, &pty.Winsize{
					Rows: uint16(specH),
					Cols: uint16(specW),
				})
			}
			m.specPanels[slug] = sm
		}

		sp, scmd := m.searchPanel.Update(msg)
		m.searchPanel = sp
		bm, bcmd := m.browser.Update(msg)
		m.browser = bm
		m.popup.SetSize(msg.Width, msg.Height)

		return m, tea.Batch(lcmd, dcmd, scmd, bcmd)

	case workItemsLoadedMsg:
		if msg.err != nil {
			// Discard transient JSON parse errors (mid-write race on _index.json)
			// and keep the existing list intact.
			var syntaxErr *json.SyntaxError
			var typeErr *json.UnmarshalTypeError
			if errors.As(msg.err, &syntaxErr) || errors.As(msg.err, &typeErr) {
				return m, nil
			}
			m.err = fmt.Errorf("failed to load work items: %w", msg.err)
			return m, nil
		}
		prevSlug := m.list.CurrentSlug()
		m.list = work.NewListModel(msg.items)
		m.list.SetCompactMode(m.layoutMode == config.LayoutLeftRight)
		// Re-apply current window dimensions — the new model starts with height=0
		// and any previously received WindowSizeMsg was dispatched to the old model.
		listW := leftPanelWidth
		listH := m.innerHeight()
		if m.layoutMode == config.LayoutTopBottom {
			listW = m.topPanelWidth()
			listH = m.topPanelHeight()
		}
		m.list, _ = m.list.Update(tea.WindowSizeMsg{Width: listW, Height: listH})
		// Restore cursor to the previously selected item after rebuild.
		m.list.SetCursorBySlug(prevSlug)

		// Re-apply any active spec status indicators to the new list model.
		for slug := range m.specPanels {
			m.list, _ = m.list.Update(work.SpecStatusMsg{Slug: slug})
		}

		var cmds []tea.Cmd
		currentSlug := m.list.CurrentSlug()

		if m.lastIndexMtime.IsZero() {
			// Initial load: full cache clear, preload all items.
			m.detailCache = make(map[string]*work.WorkItemDetail)
			if currentSlug != "" {
				m.detail = work.NewDetailModel(m.config.WorkDir, currentSlug)
				cmds = append(cmds, m.detail.Init())
			}
			for _, item := range msg.items {
				cmds = append(cmds, work.LoadDetail(m.config.WorkDir, item.Slug))
			}
		} else {
			// Auto-refresh: only re-fetch changed items and the currently-viewed item.
			// Remove stale cache entries for items no longer in the index.
			newSlugs := make(map[string]bool, len(msg.items))
			for _, item := range msg.items {
				newSlugs[item.Slug] = true
			}
			for slug := range m.detailCache {
				if !newSlugs[slug] {
					delete(m.detailCache, slug)
				}
			}
			for _, item := range msg.items {
				cached := m.detailCache[item.Slug]
				if item.Slug == currentSlug || cached == nil || cached.Updated != item.Updated {
					cmds = append(cmds, work.LoadDetail(m.config.WorkDir, item.Slug))
				}
			}
		}
		return m, tea.Batch(cmds...)

	case prStatusLoadedMsg:
		lm, cmd := m.list.Update(work.PRStatusMsg{
			Statuses: msg.statuses,
			Err:      msg.err,
		})
		m.list = lm
		return m, cmd

	case work.SpecRequestMsg:
		// 's' on list item: if spec already running, jump to terminal focus.
		// Otherwise show confirmation modal before launching subprocess.
		if m.hasSpecPanel(msg.Slug) {
			m.terminalMode = true
			m.focusedPanel = panelRight
			return m, tea.Batch(tea.EnableMouseCellMotion, enableKittyKeyboard())
		}
		ta := textarea.New()
		ta.Placeholder = ""
		ta.Prompt = " "
		ta.ShowLineNumbers = false
		ta.CharLimit = 0
		ta.SetWidth(54)
		ta.SetHeight(4)
		focusCmd := ta.Focus()
		m.specConfirmSlug = msg.Slug
		m.specConfirmTitle = msg.Slug
		m.specConfirmInput = ta
		m.specConfirmShortMode = true
		m.specConfirmSkipConfirm = true
		m.specConfirmChatMode = false
		m.specConfirmActive = true
		return m, focusCmd

	case work.ChatRequestMsg:
		// 'c' on list item: open a chat session about the work item.
		if m.hasSpecPanel(msg.Slug) {
			m.focusedPanel = panelRight
			return m, nil
		}
		ta := textarea.New()
		ta.Placeholder = ""
		ta.Prompt = " "
		ta.ShowLineNumbers = false
		ta.CharLimit = 0
		ta.SetWidth(54)
		ta.SetHeight(4)
		focusCmd := ta.Focus()
		m.specConfirmSlug = msg.Slug
		m.specConfirmTitle = msg.Title
		m.specConfirmInput = ta
		m.specConfirmChatMode = true
		m.specConfirmActive = true
		return m, focusCmd

	case work.SpecProcessStartedMsg:
		// PTY subprocess launched — attach PTY to the pre-created spec panel and start polling.
		slug := msg.Slug
		var panel work.SpecPanelModel
		if existing, ok := m.specPanels[slug]; ok {
			panel = existing
		} else {
			panel = work.NewSpecPanelModel(slug)
		}
		sm, cmd := panel.Update(msg) // SpecProcessStartedMsg sets ptmx + starts PollTerminalCmd
		m.setSpecPanel(slug, sm)
		work.WriteSession(m.config.WorkDir, slug, "spec") //nolint:errcheck
		// Auto-enter terminal focus when session starts for the currently viewed item,
		// unless the spec was launched from the confirmation modal — in that case,
		// return focus to the listing view so the user stays oriented.
		if slug == m.list.CurrentSlug() {
			if m.specLaunchedFromModal {
				m.specLaunchedFromModal = false
				m.terminalMode = true
				m.focusedPanel = panelLeft
				return m, tea.Batch(cmd, tea.EnableMouseCellMotion)
			}
			m.terminalMode = true
			m.focusedPanel = panelRight
			return m, tea.Batch(cmd, tea.EnableMouseCellMotion, enableKittyKeyboard())
		}
		return m, cmd

	case work.TerminalOutputMsg:
		// Route output to the correct spec panel, then continue polling.
		slug := msg.Slug
		if m.specPanels != nil {
			if panel, ok := m.specPanels[slug]; ok {
				sm, _ := panel.Update(msg)
				m.specPanels[slug] = sm
				return m, work.PollTerminalCmd(slug, sm.OutputChan())
			}
		}
		return m, nil

	case work.StreamCompleteMsg:
		// PTY channel closed (subprocess exited normally). Auto-dismiss the spec
		// panel so the detail view expands and shows the freshly written plan.md.
		slug := msg.Slug
		wasSpec := false
		if m.specPanels != nil {
			if panel, ok := m.specPanels[slug]; ok {
				panel.Cleanup()
				delete(m.specPanels, slug)
				if m.terminalMode && m.list.CurrentSlug() == slug {
					m.focusedPanel = panelRight
					wasSpec = true
				}
			}
		}
		if m.list.CurrentSlug() == slug {
			m.terminalMode = false
		}
		m.list, _ = m.list.Update(work.SpecStatusMsg{Slug: slug, Done: true})
		// Restore detail to full height now that the spec panel is gone.
		if m.list.CurrentSlug() == slug {
			m.detail, _ = m.detail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
			// Invalidate cache so reload picks up plan.md written by spec.
			if m.detailCache != nil {
				delete(m.detailCache, slug)
			}
		}
		var cmds []tea.Cmd
		if wasSpec {
			cmds = append(cmds, tea.EnableMouseCellMotion, disableKittyKeyboard())
		}
		cmds = append(cmds, loadWorkItems(m.config.WorkDir))
		if m.list.CurrentSlug() == slug {
			cmds = append(cmds, m.detail.Init()) // reload detail to show updated plan.md
		}
		work.ClearSession(m.config.WorkDir, slug) //nolint:errcheck
		return m, tea.Batch(cmds...)

	case work.StreamErrorMsg:
		// PTY error — mark done with error, cleanup PTY. Still reload list in
		// case spec wrote partial files before failing.
		slug := msg.Slug
		wasSpec := false
		if m.specPanels != nil {
			if panel, ok := m.specPanels[slug]; ok {
				sm, _ := panel.Update(msg) // marks hasError+done
				sm = sm.Cleanup()
				m.specPanels[slug] = sm
				if m.terminalMode && m.list.CurrentSlug() == slug {
					m.focusedPanel = panelRight
					wasSpec = true
				}
			}
		}
		if m.list.CurrentSlug() == slug {
			m.terminalMode = false
		}
		m.list, _ = m.list.Update(work.SpecStatusMsg{Slug: slug, Done: true})
		work.ClearSession(m.config.WorkDir, slug) //nolint:errcheck
		if wasSpec {
			return m, tea.Batch(tea.EnableMouseCellMotion, disableKittyKeyboard(), loadWorkItems(m.config.WorkDir))
		}
		return m, loadWorkItems(m.config.WorkDir)

	case work.TerminalDetachMsg:
		// User pressed Esc from terminal focus — return to list view.
		m.focusedPanel = panelLeft
		m.terminalMode = false
		return m, tea.Batch(tea.EnableMouseCellMotion, disableKittyKeyboard())

	case work.TerminalTerminateMsg:
		// User killed the subprocess (Ctrl+\\) — cleanup and remove the panel.
		// Reload list in case spec wrote files before being killed.
		slug := msg.Slug
		if m.specPanels != nil {
			if panel, ok := m.specPanels[slug]; ok {
				panel.Cleanup()
				delete(m.specPanels, slug)
			}
		}
		wasSpec := m.terminalMode
		m.terminalMode = false

		m.list, _ = m.list.Update(work.SpecStatusMsg{Slug: slug, Done: true})
		m.detail, _ = m.detail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
		work.ClearSession(m.config.WorkDir, slug) //nolint:errcheck
		if wasSpec {
			return m, tea.Batch(tea.EnableMouseCellMotion, disableKittyKeyboard(), loadWorkItems(m.config.WorkDir))
		}
		return m, loadWorkItems(m.config.WorkDir)

	case work.ItemSelectedMsg:
		// Enter on list item: load detail and shift focus to right panel
		m.focusedPanel = panelRight
		return m.loadDetail(msg.Item.Slug)

	case work.DetailLoadedMsg:
		// Cache the raw detail for instant revisit (renderMarkdown is synchronous and fast)
		if msg.Err == nil && msg.Detail != nil && m.detailCache != nil {
			m.detailCache[msg.Slug] = msg.Detail
		}
		dm, cmd := m.detail.Update(msg)
		m.detail = dm
		return m, cmd

	case work.BackToListMsg:
		// In split-pane, just shift focus back to left
		m.focusedPanel = panelLeft
		return m, nil

	case search.PopupDismissedMsg:
		m.popupActive = false
		return m, nil

	case search.PopupSelectedMsg:
		m.popupActive = false
		switch m.popupCtx {
		case contextList:
			slug := msg.Item.ID
			m.list.SetCursorBySlug(slug)
			return m.loadDetail(slug)
		case contextDetail:
			if loc, ok := msg.Item.Data.(work.SearchLocation); ok {
				m.detail.JumpTo(loc)
			}
			return m, nil
		}

	case popupSearchResultMsg:
		// Only accept results for the current query to ignore stale debounced searches.
		if m.popupActive && msg.query == m.popupLastQuery {
			m.popup.SetItems(msg.items)
		}
		return m, nil

	case search.SearchDismissedMsg:
		m.state = stateWork
		return m, nil

	case search.SearchResultSelectedMsg:
		m.state = stateWork
		m.list.SetCursorBySlug(msg.Slug)
		return m.loadDetail(msg.Slug)

	case knowledge.BrowserDismissedMsg:
		m.state = stateWork
		return m, nil

	case knowledge.ManifestLoadedMsg:
		bm, cmd := m.browser.Update(msg)
		m.browser = bm
		return m, cmd

	case knowledge.EntryLoadedMsg:
		bm, cmd := m.browser.Update(msg)
		m.browser = bm
		return m, cmd
	}

	// Route to active view
	switch m.state {
	case stateWork:
		if m.focusedPanel == panelRight && m.terminalMode {
			// Route to the spec panel (terminal mode) for the currently selected work item.
			slug := m.list.CurrentSlug()
			if m.specPanels != nil {
				if panel, ok := m.specPanels[slug]; ok {
					sm, cmd := panel.Update(msg)
					m.specPanels[slug] = sm
					return m, cmd
				}
			}
			// No panel for current item — fall back to detail.
			m.terminalMode = false
			dm, cmd := m.detail.Update(msg)
			m.detail = dm
			return m, tea.Batch(cmd, disableKittyKeyboard())
		}
		if m.focusedPanel == panelLeft {
			prevSlug := m.list.CurrentSlug()
			lm, cmd := m.list.Update(msg)
			m.list = lm
			newSlug := m.list.CurrentSlug()
			if newSlug != "" && newSlug != prevSlug {
				var detailCmd tea.Cmd
				m, detailCmd = m.loadDetail(newSlug)
				return m, tea.Batch(cmd, detailCmd)
			}
			return m, cmd
		}
		dm, cmd := m.detail.Update(msg)
		m.detail = dm
		return m, cmd
	case stateSearch:
		sp, cmd := m.searchPanel.Update(msg)
		m.searchPanel = sp
		return m, cmd
	case stateKnowledge:
		bm, cmd := m.browser.Update(msg)
		m.browser = bm
		return m, cmd
	}

	return m, nil
}

// loadDetail creates a fresh DetailModel for slug, applies current dimensions,
// and serves content from the detail cache if available.
// renderMarkdown is synchronous and fast (<1ms), so cache hits are instant.
func (m model) loadDetail(slug string) (model, tea.Cmd) {
	m.lastPlanMtime = time.Time{}   // reset so new item's plan.md gets a fresh baseline
	m.lastDetailMtime = time.Time{} // reset so new item's detail files get a fresh baseline
	m.detail = work.NewDetailModel(m.config.WorkDir, slug)
	m.detail, _ = m.detail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
	m.terminalMode = m.hasSpecPanel(slug)

	var initCmd tea.Cmd
	if m.detailCache != nil {
		if cached, ok := m.detailCache[slug]; ok {
			dm, _ := m.detail.Update(work.DetailLoadedMsg{Slug: slug, Detail: cached})
			m.detail = dm
		} else {
			initCmd = m.detail.Init()
		}
	} else {
		initCmd = m.detail.Init()
	}

	if m.terminalMode && m.focusedPanel == panelRight {
		return m, tea.Batch(initCmd, tea.EnableMouseCellMotion)
	}
	return m, initCmd
}

// rightPanelWidth returns the inner content width for the right (or bottom) panel.
// In left/right mode: 1(┌) + leftPanelWidth + 1(┐) + 1(┌) + rightPanelWidth + 1(┐) = m.width
// In top/bottom mode: returns topPanelWidth() since both panels span full width.
func (m model) rightPanelWidth() int {
	if m.layoutMode == config.LayoutTopBottom {
		return m.topPanelWidth()
	}
	w := m.width - leftPanelWidth - 4
	if w < 20 {
		w = 20
	}
	return w
}

func (m model) View() string {
	if m.err != nil {
		return fmt.Sprintf("Error: %v\n\nPress q to quit.\n", m.err)
	}

	var base string
	switch m.state {
	case stateWork:
		if m.layoutMode == config.LayoutTopBottom {
			base = m.viewSplitPaneTopBottom()
		} else {
			base = m.viewSplitPane()
		}
	case stateSearch:
		return m.searchPanel.View()
	case stateKnowledge:
		return m.browser.View()
	default:
		return ""
	}

	if m.popupActive {
		return lipgloss.Place(m.width, m.height-1, lipgloss.Center, lipgloss.Center, m.popup.View())
	}
	if m.specConfirmActive {
		return m.renderSpecConfirmModal()
	}
	if m.aiInputActive {
		return m.renderAIModal(base)
	}
	if m.showHelp {
		return m.renderHelpModal(base)
	}
	return base
}

// viewSplitPane renders the split-pane work view with lazygit-style box borders.
func (m model) viewSplitPane() string {
	contentH := m.innerHeight()
	leftInner := leftPanelWidth
	rightInner := m.rightPanelWidth()

	// Check whether the current item has an active spec panel.
	currentSpec, hasCurrentSpec := m.currentSpecPanel()

	// Focus-aware border colors
	activeBorderColor := lipgloss.Color("4")     // blue
	inactiveBorderColor := lipgloss.Color("238") // dim

	leftBorderColor := inactiveBorderColor
	rightBorderColor := inactiveBorderColor
	if m.focusedPanel == panelLeft {
		leftBorderColor = activeBorderColor
	}
	if m.focusedPanel == panelRight {
		rightBorderColor = activeBorderColor
	}

	leftBS := lipgloss.NewStyle().Foreground(leftBorderColor)
	rightBS := lipgloss.NewStyle().Foreground(rightBorderColor)

	// Title styles: blue+bold when focused, default-color (full-visibility) when not
	leftTitleFg := lipgloss.Color("7") // default bright — always visible
	if m.focusedPanel == panelLeft {
		leftTitleFg = activeBorderColor
	}
	rightTitleFg := lipgloss.Color("7")
	if m.focusedPanel == panelRight {
		rightTitleFg = activeBorderColor
	}
	leftTitleS := lipgloss.NewStyle().Foreground(leftTitleFg).Bold(m.focusedPanel == panelLeft)
	rightTitleS := lipgloss.NewStyle().Foreground(rightTitleFg).Bold(m.focusedPanel == panelRight)

	// Build panel titles (label reflects active/archived filter mode)
	modeLabel := "Active"
	if m.list.GetFilterMode() == work.FilterArchived {
		modeLabel = "Archived"
	}
	leftTitle := modeLabel
	if items := m.list.Items(); len(items) > 0 {
		leftTitle = fmt.Sprintf("%s (%d)", modeLabel, len(items))
	}
	rightTitle := "Detail"
	if d := m.detail.Detail(); d != nil {
		t := d.Title
		maxW := rightInner - 6
		if lipgloss.Width(t) > maxW && maxW > 3 {
			runes := []rune(t)
			t = string(runes[:maxW-1]) + "…"
		}
		rightTitle = t
	} else if slug := m.list.CurrentSlug(); slug != "" {
		rightTitle = slug
	}

	// Tab indicator for list panel: active · archived, highlight current mode.
	listTabActiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("252"))
	listTabInactiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("238"))
	listTabSepS := lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
	var listActiveTabS, listArchivedTabS lipgloss.Style
	if m.list.GetFilterMode() == work.FilterArchived {
		listActiveTabS, listArchivedTabS = listTabInactiveS, listTabActiveS
	} else {
		listActiveTabS, listArchivedTabS = listTabActiveS, listTabInactiveS
	}
	leftAnnot := listTabSepS.Render("ctrl+a  ") + listActiveTabS.Render("active") + listTabSepS.Render(" · ") + listArchivedTabS.Render("archived")
	leftAnnotW := 8 + 6 + 3 + 8 // "ctrl+a  " + "active" + " · " + "archived"

	// Right panel annotation: show "ctrl+t  detail · terminal" mode indicator when a spec session exists.
	var rightBorderTitle string
	if hasCurrentSpec {
		activeS := lipgloss.NewStyle().Foreground(lipgloss.Color("252"))
		inactiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("238"))
		sepS := lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
		var detailS, terminalS lipgloss.Style
		if m.terminalMode {
			detailS, terminalS = inactiveS, activeS
		} else {
			detailS, terminalS = activeS, inactiveS
		}
		modeAnnot := sepS.Render("ctrl+t  ") + detailS.Render("detail") + sepS.Render(" · ") + terminalS.Render("terminal")
		modeAnnotW := 8 + 6 + 3 + 8 // "ctrl+t  " + "detail" + " · " + "terminal"
		rightBorderTitle = renderBorderTitleWithAnnot(rightTitle, rightInner, rightTitleS, rightBS, modeAnnot, modeAnnotW)
	} else {
		rightBorderTitle = renderBorderTitle(rightTitle, rightInner, rightTitleS, rightBS)
	}

	// Top border: ┌─ Title ──── active · archived ─┐┌─ Title ──── ctrl+t  detail · terminal ─┐
	topRow := leftBS.Render("┌") +
		renderBorderTitleWithAnnot(leftTitle, leftInner, leftTitleS, leftBS, leftAnnot, leftAnnotW) +
		leftBS.Render("┐") +
		rightBS.Render("┌") +
		rightBorderTitle +
		rightBS.Render("┐")

	// Bottom border: └──────────────────────┘└──────────────────────────────────────┘
	bottomRow := leftBS.Render("└") +
		leftBS.Render(strings.Repeat("─", leftInner)) +
		leftBS.Render("┘") +
		rightBS.Render("└") +
		rightBS.Render(strings.Repeat("─", rightInner)) +
		rightBS.Render("┘")

	leftView := m.list.View()
	leftLines := strings.Split(leftView, "\n")

	// Right panel content: terminal mode shows spec panel, otherwise detail view.
	var rightLines []string
	if m.terminalMode && hasCurrentSpec {
		specView := currentSpec.View()
		rightLines = strings.Split(specView, "\n")
	} else {
		rightView := m.detail.View()
		rightLines = strings.Split(rightView, "\n")
	}

	leftBorderChar := leftBS.Render("│")
	rightBorderChar := rightBS.Render("│")

	var b strings.Builder
	b.WriteString("\n")
	b.WriteString(topRow)
	b.WriteString("\n")
	for i := 0; i < contentH; i++ {
		left := ""
		if i < len(leftLines) {
			left = leftLines[i]
		}

		var right string
		if i < len(rightLines) {
			if m.terminalMode && hasCurrentSpec {
				right = " " + rightLines[i] // 1-char left buffer; right buffer from padding
			} else {
				right = "  " + rightLines[i]
			}
		} else {
			right = "  "
		}

		lW := lipgloss.Width(left)
		if lW > leftInner {
			left = truncateLine(left, leftInner)
		} else if lW < leftInner {
			left += strings.Repeat(" ", leftInner-lW)
		}
		rW := lipgloss.Width(right)
		if rW > rightInner {
			right = truncateLine(right, rightInner)
		} else if rW < rightInner {
			right += strings.Repeat(" ", rightInner-rW)
		}

		b.WriteString(leftBorderChar)
		b.WriteString(left)
		b.WriteString(leftBorderChar)
		b.WriteString(rightBorderChar)
		b.WriteString(right)
		b.WriteString(rightBorderChar)
		b.WriteString("\n")
	}
	b.WriteString(bottomRow)
	b.WriteString("\n")
	b.WriteString(m.renderStatusBar(m.width))

	return b.String()
}

// viewSplitPaneTopBottom renders the stacked top/bottom layout: list on top, detail on bottom.
func (m model) viewSplitPaneTopBottom() string {
	if m.width <= 0 || m.height <= 0 {
		return ""
	}
	topH := m.topPanelHeight()
	bottomH := m.detailPanelHeight()
	panelW := m.topPanelWidth()

	// Check whether the current item has an active spec panel.
	currentSpecTB, hasCurrentSpecTB := m.currentSpecPanel()

	// Focus-aware border colors
	activeBorderColor := lipgloss.Color("4")     // blue
	inactiveBorderColor := lipgloss.Color("238") // dim

	topBorderColor := inactiveBorderColor
	bottomBorderColor := inactiveBorderColor
	if m.focusedPanel == panelLeft {
		topBorderColor = activeBorderColor
	}
	if m.focusedPanel == panelRight {
		bottomBorderColor = activeBorderColor
	}

	topBS := lipgloss.NewStyle().Foreground(topBorderColor)
	bottomBS := lipgloss.NewStyle().Foreground(bottomBorderColor)

	// Title styles: blue+bold when focused, default-color (full-visibility) when not
	topTitleFg := lipgloss.Color("7")
	if m.focusedPanel == panelLeft {
		topTitleFg = activeBorderColor
	}
	bottomTitleFg := lipgloss.Color("7")
	if m.focusedPanel == panelRight {
		bottomTitleFg = activeBorderColor
	}
	topTitleS := lipgloss.NewStyle().Foreground(topTitleFg).Bold(m.focusedPanel == panelLeft)
	bottomTitleS := lipgloss.NewStyle().Foreground(bottomTitleFg).Bold(m.focusedPanel == panelRight)

	// Build panel titles
	modeLabel := "Active"
	if m.list.GetFilterMode() == work.FilterArchived {
		modeLabel = "Archived"
	}
	topTitle := modeLabel
	if items := m.list.Items(); len(items) > 0 {
		topTitle = fmt.Sprintf("%s (%d)", modeLabel, len(items))
	}
	bottomTitle := "Detail"
	if d := m.detail.Detail(); d != nil {
		t := d.Title
		maxW := panelW - 6
		if lipgloss.Width(t) > maxW && maxW > 3 {
			runes := []rune(t)
			t = string(runes[:maxW-1]) + "…"
		}
		bottomTitle = t
	} else if slug := m.list.CurrentSlug(); slug != "" {
		bottomTitle = slug
	}

	topBorderChar := topBS.Render("│")
	bottomBorderChar := bottomBS.Render("│")

	topView := m.list.View()
	topLines := strings.Split(topView, "\n")

	// Bottom panel content: terminal mode shows spec panel, otherwise detail view.
	var bottomLines []string
	if m.terminalMode && hasCurrentSpecTB {
		specView := currentSpecTB.View()
		bottomLines = strings.Split(specView, "\n")
	} else {
		bottomView := m.detail.View()
		bottomLines = strings.Split(bottomView, "\n")
	}

	// padLine pads or truncates a content line to exactly panelW visual width.
	padLine := func(line string) string {
		w := lipgloss.Width(line)
		if w > panelW {
			return truncateLine(line, panelW)
		}
		if w < panelW {
			return line + strings.Repeat(" ", panelW-w)
		}
		return line
	}

	var b strings.Builder
	b.WriteString("\n")

	// Tab indicator for top (list) panel: active · archived, highlight current mode.
	tbActiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("252"))
	tbInactiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("238"))
	tbSepS := lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
	var tbActiveTabS, tbArchivedTabS lipgloss.Style
	if m.list.GetFilterMode() == work.FilterArchived {
		tbActiveTabS, tbArchivedTabS = tbInactiveS, tbActiveS
	} else {
		tbActiveTabS, tbArchivedTabS = tbActiveS, tbInactiveS
	}
	topAnnot := tbSepS.Render("ctrl+a  ") + tbActiveTabS.Render("active") + tbSepS.Render(" · ") + tbArchivedTabS.Render("archived")
	topAnnotW := 8 + 6 + 3 + 8 // "ctrl+a  " + "active" + " · " + "archived"

	// === Top panel (list) ===
	b.WriteString(topBS.Render("┌"))
	b.WriteString(renderBorderTitleWithAnnot(topTitle, panelW, topTitleS, topBS, topAnnot, topAnnotW))
	b.WriteString(topBS.Render("┐"))
	b.WriteString("\n")
	for i := 0; i < topH; i++ {
		line := ""
		if i < len(topLines) {
			line = topLines[i]
		}
		b.WriteString(topBorderChar)
		b.WriteString(padLine(line))
		b.WriteString(topBorderChar)
		b.WriteString("\n")
	}
	b.WriteString(topBS.Render("└"))
	b.WriteString(topBS.Render(strings.Repeat("─", panelW)))
	b.WriteString(topBS.Render("┘"))
	b.WriteString("\n")

	// === Bottom panel (detail or terminal) ===
	// Bottom panel annotation: show "detail · terminal" mode indicator when a spec session exists.
	var bottomBorderTitle string
	if hasCurrentSpecTB {
		btActiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("252"))
		btInactiveS := lipgloss.NewStyle().Foreground(lipgloss.Color("238"))
		btSepS := lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
		var btDetailS, btTerminalS lipgloss.Style
		if m.terminalMode {
			btDetailS, btTerminalS = btInactiveS, btActiveS
		} else {
			btDetailS, btTerminalS = btActiveS, btInactiveS
		}
		btModeAnnot := btSepS.Render("ctrl+t  ") + btDetailS.Render("detail") + btSepS.Render(" · ") + btTerminalS.Render("terminal")
		btModeAnnotW := 8 + 6 + 3 + 8 // "ctrl+t  " + "detail" + " · " + "terminal"
		bottomBorderTitle = renderBorderTitleWithAnnot(bottomTitle, panelW, bottomTitleS, bottomBS, btModeAnnot, btModeAnnotW)
	} else {
		bottomBorderTitle = renderBorderTitle(bottomTitle, panelW, bottomTitleS, bottomBS)
	}
	b.WriteString(bottomBS.Render("┌"))
	b.WriteString(bottomBorderTitle)
	b.WriteString(bottomBS.Render("┐"))
	b.WriteString("\n")
	for i := 0; i < bottomH; i++ {
		var content string
		if i < len(bottomLines) {
			if m.terminalMode && hasCurrentSpecTB {
				content = " " + bottomLines[i] // 1-char left buffer; right buffer from padding
			} else {
				content = "  " + bottomLines[i]
			}
		} else {
			content = "  "
		}
		b.WriteString(bottomBorderChar)
		b.WriteString(padLine(content))
		b.WriteString(bottomBorderChar)
		b.WriteString("\n")
	}
	b.WriteString(bottomBS.Render("└"))
	b.WriteString(bottomBS.Render(strings.Repeat("─", panelW)))
	b.WriteString(bottomBS.Render("┘"))
	b.WriteString("\n")

	b.WriteString(m.renderStatusBar(m.width))
	return b.String()
}

// truncateLine clips s to at most maxW visual columns, appending "…" if needed.
func truncateLine(s string, maxW int) string {
	if lipgloss.Width(s) <= maxW {
		return s
	}
	runes := []rune(s)
	for i := len(runes) - 1; i >= 0; i-- {
		candidate := string(runes[:i]) + "…"
		if lipgloss.Width(candidate) <= maxW {
			return candidate
		}
	}
	return "…"
}

// renderBorderTitle renders "─ Title ──────────" filling exactly width chars.
func renderBorderTitle(title string, width int, titleS, borderS lipgloss.Style) string {
	prefix := borderS.Render("─ ")
	rendered := titleS.Render(title)
	usedW := 2 + lipgloss.Width(rendered) // "─ " + title
	remaining := width - usedW
	if remaining < 0 {
		remaining = 0
	}
	return prefix + rendered + borderS.Render(strings.Repeat("─", remaining))
}

// renderBorderTitleWithAnnot renders "─ Title ─── annot ─" filling exactly width chars.
// annot is a pre-rendered string (may contain ANSI codes); annotW is its visual width.
func renderBorderTitleWithAnnot(title string, width int, titleS, borderS lipgloss.Style, annot string, annotW int) string {
	prefix := borderS.Render("─ ")
	rendered := titleS.Render(title)
	usedLeft := 2 + lipgloss.Width(rendered) // "─ " + title
	// Right side: " " + annot + " ─" = annotW + 3 visual chars
	rightSlot := annotW + 3
	middle := width - usedLeft - rightSlot
	if middle < 1 {
		middle = 1
	}
	return prefix + rendered + borderS.Render(strings.Repeat("─", middle)) + borderS.Render(" ") + annot + borderS.Render(" ─")
}

// modalInnerW is the visible content width inside all modals.
const modalInnerW = 58

// modalStyles returns the shared style set used by all modals.
type modalStyleSet struct {
	border lipgloss.Style
	title  lipgloss.Style
	dim    lipgloss.Style
	key    lipgloss.Style
	sep    lipgloss.Style
}

func newModalStyles() modalStyleSet {
	return modalStyleSet{
		border: lipgloss.NewStyle().Foreground(lipgloss.Color("4")),
		title:  lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("4")),
		dim:    lipgloss.NewStyle().Foreground(lipgloss.Color("8")),
		key:    lipgloss.NewStyle().Foreground(lipgloss.Color("7")).Bold(true),
		sep:    lipgloss.NewStyle().Foreground(lipgloss.Color("238")),
	}
}

// buildModalBox wraps title+body in a rounded blue border box at modalInnerW width.
func buildModalBox(s modalStyleSet, title, body string) string {
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(s.border.GetForeground()).
		Width(modalInnerW).
		Render(s.title.Render(title) + "\n" + body)
}

// placeModal centers box over the full screen with a status bar at the bottom.
func (m model) placeModal(box string) string {
	return lipgloss.Place(m.width, m.height-1,
		lipgloss.Center, lipgloss.Center,
		box,
		lipgloss.WithWhitespaceChars(" "),
	) + "\n" + m.renderStatusBar(m.width)
}

// renderSpecConfirmModal shows a centered confirmation modal before launching the spec subprocess.
// Displays the slug, an optional context input, and enter/esc hints.
func (m model) renderSpecConfirmModal() string {
	s := newModalStyles()

	inputBox := lipgloss.NewStyle().
		Border(lipgloss.NormalBorder()).
		BorderForeground(lipgloss.Color("238")).
		Width(modalInnerW - 2).
		Render(m.specConfirmInput.View())
	hints := s.key.Render("Enter") + " " + s.dim.Render("start") +
		s.sep.Render("  ·  ") +
		s.key.Render("Shift+Enter") + " " + s.dim.Render("newline") +
		s.sep.Render("  ·  ") +
		s.key.Render("Esc") + " " + s.dim.Render("cancel")

	var title, body string
	if m.specConfirmChatMode {
		title = "Chat about " + m.specConfirmSlug + "?"
		body = "\n" + s.dim.Render(" opening message (optional):") +
			"\n" + inputBox + "\n\n " + hints + "\n"
	} else {
		title = "Run /spec for " + m.specConfirmSlug + "?"
		shortCheck := "[ ]"
		if m.specConfirmShortMode {
			shortCheck = "[x]"
		}
		skipCheck := "[ ]"
		if m.specConfirmSkipConfirm {
			skipCheck = "[x]"
		}
		checkboxes := " " + s.key.Render(shortCheck) + " " + s.dim.Render("Short mode") +
			"  " + s.sep.Render("(") + s.key.Render("Alt+1") + s.sep.Render(")") +
			"\n " + s.key.Render(skipCheck) + " " + s.dim.Render("Skip confirmations") +
			"  " + s.sep.Render("(") + s.key.Render("Alt+2") + s.sep.Render(")")
		body = "\n" + checkboxes + "\n\n" +
			s.dim.Render(" additional context for claude (optional):") +
			"\n" + inputBox + "\n\n " + hints + "\n"
	}
	return m.placeModal(buildModalBox(s, title, body))
}

// renderAIModal shows a centered modal for the AI work-item creation prompt.
func (m model) renderAIModal(_ string) string {
	s := newModalStyles()
	inputBox := lipgloss.NewStyle().
		Border(lipgloss.NormalBorder()).
		BorderForeground(lipgloss.Color("238")).
		Width(modalInnerW - 2).
		Render(m.aiInput.View())
	hints := s.key.Render("Enter") + " " + s.dim.Render("run") +
		s.sep.Render("  ·  ") +
		s.key.Render("Shift+Enter") + " " + s.dim.Render("newline") +
		s.sep.Render("  ·  ") +
		s.key.Render("Esc") + " " + s.dim.Render("cancel")
	body := "\n" + s.dim.Render(" describe what work items to create:") +
		"\n" + inputBox + "\n\n " + hints + "\n"
	return m.placeModal(buildModalBox(s, "Add Work Items via AI", body))
}

// renderHelpModal overlays a centered modal listing all keybindings.
func (m model) renderHelpModal(_ string) string {
	s := newModalStyles()
	sectionS := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("7"))

	row := func(key, desc string) string {
		k := s.key.Render(fmt.Sprintf("  %-18s", key))
		return k + s.dim.Render(desc)
	}

	content := sectionS.Render("Work List") + "\n" +
		row("j / k", "navigate") + "\n" +
		row("Enter", "open detail") + "\n" +
		row("s", "run spec") + "\n" +
		row("c", "chat about spec") + "\n" +
		row("N", "create work items with AI") + "\n" +
		row("L", "toggle layout") + "\n" +
		row("ctrl+a", "toggle archived") + "\n" +
		row("K", "knowledge browser") + "\n" +
		"\n" +
		sectionS.Render("Work Detail") + "\n" +
		row("Tab / Shift-Tab", "cycle tabs") + "\n" +
		row("j / k", "scroll") + "\n" +
		row("h / Esc", "back to list") + "\n" +
		"\n" +
		sectionS.Render("Spec Panel (terminal mode)") + "\n" +
		row("scroll wheel", "scroll output") + "\n" +
		row("ctrl+t", "switch to detail view") + "\n" +
		row("Esc", "back to list") + "\n" +
		row("Ctrl+c", "terminate subprocess") + "\n" +
		row("Ctrl+\\", "terminate subprocess") + "\n" +
		row("(all other keys)", "forwarded to subprocess") + "\n" +
		"\n" +
		sectionS.Render("Global") + "\n" +
		row("?", "this help") + "\n" +
		row("q / Ctrl+C / Ctrl+D", "quit")

	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(s.border.GetForeground()).
		Padding(0, 1).
		Render(s.title.Render("Keyboard Shortcuts") + "\n\n" + content + "\n\n" +
			s.dim.Render("  Press ? or Esc to close"))

	return m.placeModal(box)
}

// renderStatusBar renders a single-line context-sensitive keybinding hint bar.
func (m model) renderStatusBar(width int) string {
	dimS := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	keyS := lipgloss.NewStyle().Foreground(lipgloss.Color("7")).Bold(true)
	sepS := lipgloss.NewStyle().Foreground(lipgloss.Color("238"))

	sep := sepS.Render("  ·  ")
	hint := func(key, desc string) string {
		return keyS.Render(key) + " " + dimS.Render(desc)
	}

	var hints []string
	switch m.state {
	case stateWork:
		if m.focusedPanel == panelLeft {
			hints = []string{
				hint("j/k", "navigate"),
				hint("Enter", "open"),
				hint("s", "spec"),
				hint("c", "chat"),
				hint("N", "AI add"),
				hint("L", "layout"),
				hint("K", "knowledge"),
				hint("q", "quit"),
				hint("?", "help"),
			}
		} else if m.terminalMode {
			// terminal mode: keys go to PTY
			hints = []string{
				hint("ctrl+t", "detail"),
				hint("Esc", "back to list"),
				hint("Ctrl+c", "terminate"),
			}
		} else {
			// panelRight — detail view (content tabs)
			hints = []string{
				hint("s", "spec"),
				hint("c", "chat"),
				hint("Tab/Shift-Tab", "cycle tabs"),
				hint("j/k", "scroll"),
				hint("h/Esc", "back to list"),
				hint("?", "help"),
			}
		}
	case stateSearch:
		hints = []string{
			hint("type", "search"),
			hint("Enter", "select"),
			hint("Esc", "cancel"),
			hint("?", "help"),
		}
	case stateKnowledge:
		hints = []string{
			hint("j/k", "navigate"),
			hint("l/Enter", "detail"),
			hint("h/Esc", "tree"),
			hint("/", "search"),
			hint("Esc", "exit"),
			hint("?", "help"),
		}
	}

	if m.aiLoading {
		aiS := lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
		bar := "  " + aiS.Render("Creating work items...")
		barW := lipgloss.Width(bar)
		if barW < width {
			bar += strings.Repeat(" ", width-barW)
		}
		return bar
	}

	bar := "  " + strings.Join(hints, sep)
	barW := lipgloss.Width(bar)
	if barW < width {
		bar += strings.Repeat(" ", width-barW)
	}
	return dimS.Render(bar)
}

func main() {
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	prefs := config.LoadPrefs()
	m := model{
		config:     cfg,
		layoutMode: prefs.Layout,
		indexPath:  filepath.Join(cfg.WorkDir, "_index.json"),
	}
	p := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
