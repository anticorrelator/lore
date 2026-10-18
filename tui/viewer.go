package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/sessionview"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// A lore-tui window runs no session of its own. Every session runs in its
// store's background host. The window shows one by attaching a tmux client to
// the host's pane (a viewer panel) and ends one through `lore session close`.
// Under _sessions/ it only reads; everything it changes there goes through the
// CLI verbs it runs.

const (
	// hostRevivalInterval bounds how often a window runs `lore session ensure
	// --if-work` for sessions only dead registry rows list.
	hostRevivalInterval = time.Minute
	// windowRequester is what a window passes as --requested-by.
	windowRequester = "lore-tui"
)

// sessionViewer is an open viewer panel and the session it shows.
type sessionViewer struct {
	panel     work.SessionPanelModel
	slug      string
	sessionID string
	title     string
}

// hostRevivalDueMsg asks Update to run the host revival check once.
type hostRevivalDueMsg struct{}

// hostRevivalMsg reports one revival check. ran is set when `lore session
// ensure --if-work` was run, at the time the check started.
type hostRevivalMsg struct {
	ran    bool
	at     time.Time
	output string
	err    error
}

// viewStore points a window at its store's sessions. A window hosts none, so
// it has no instance identity: it reads the substrate and changes it only
// through the lore verbs it runs. Its terminals are tmux clients, so without
// tmux it lists sessions but cannot show them, and says so once.
func (m model) viewStore(kdir string, tmuxAvailable func() (bool, string)) model {
	if kdir == "" {
		return m
	}
	m.sessionsDir = filepath.Join(kdir, "_sessions")
	if ok, detail := tmuxAvailable(); !ok {
		m.noTmuxReason = detail
		m.statusNotice = fmt.Sprintf("tmux is unavailable here (%s): sessions are listed, but their terminals cannot be shown", detail)
	}
	return m
}

func (m model) now() time.Time {
	if m.clock != nil {
		return m.clock()
	}
	return time.Now()
}

// viewerKey is the panel key of a session: its slug, or its harness session id
// for a session that has none. Sessions rows carry it as PanelKey.
func viewerKey(slug, sessionID string) string {
	if slug != "" {
		return slug
	}
	if sessionID != "" {
		return "session:" + sessionID
	}
	return ""
}

// panelFor returns the panel shown for key: an owned session's panel (a store
// host has those) or a viewer.
func (m model) panelFor(key string) (work.SessionPanelModel, bool) {
	if key == "" {
		return work.SessionPanelModel{}, false
	}
	if panel, ok := m.sessionPanels[key]; ok {
		return panel, true
	}
	if v, ok := m.viewers[key]; ok {
		return v.panel, true
	}
	return work.SessionPanelModel{}, false
}

// updatePanel routes msg to the panel shown for key and stores the result.
func (m *model) updatePanel(key string, msg tea.Msg) (tea.Cmd, bool) {
	if key == "" {
		return nil, false
	}
	if panel, ok := m.sessionPanels[key]; ok {
		next, cmd := panel.Update(msg)
		m.sessionPanels[key] = next
		return cmd, true
	}
	if v, ok := m.viewers[key]; ok {
		var cmd tea.Cmd
		v.panel, cmd = v.panel.Update(msg)
		m.viewers[key] = v
		return cmd, true
	}
	return nil, false
}

// liveSessionRow is the sessions-list row for a session the registry lists
// under slug, if there is one.
func (m model) liveSessionRow(slug string) (sessionview.SessionRow, bool) {
	if slug == "" {
		return sessionview.SessionRow{}, false
	}
	for _, row := range m.sessionRows {
		if !row.InFlight && row.Slug == slug {
			return row, true
		}
	}
	return sessionview.SessionRow{}, false
}

// openViewer opens a viewer on the session a row shows, replacing a finished
// viewer of the same key. It leaves focus and terminal mode to the caller. A
// session that cannot be viewed gets a status notice instead.
func (m model) openViewer(row sessionview.SessionRow) (model, tea.Cmd) {
	key := row.PanelKey
	if key == "" {
		key = viewerKey(row.Slug, row.SessionID)
	}
	if key == "" || row.InFlight {
		return m, nil
	}
	if row.Tmux == "" {
		m.statusNotice = fmt.Sprintf("%s runs without tmux in the background host, so its terminal cannot be shown here", row.Display)
		return m, nil
	}
	if m.noTmuxReason != "" {
		m.statusNotice = fmt.Sprintf("tmux is unavailable here (%s), so session terminals cannot be shown", m.noTmuxReason)
		return m, nil
	}
	if existing, ok := m.viewers[key]; ok {
		if existing.panel.TmuxName() == row.Tmux && !existing.panel.IsDone() {
			return m, nil
		}
		existing.panel.Cleanup()
	}
	panel := work.NewViewerSessionPanelModel(key, row.Tmux)
	if pair, ok := work.NewTerminalColorPair(m.terminalForeground, m.terminalBackground); ok {
		panel = panel.WithTerminalColorPair(pair)
	}
	panel, _ = panel.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth() - 2, Height: m.detailPanelHeight()})
	if m.viewers == nil {
		m.viewers = make(map[string]sessionViewer)
	}
	m.viewers[key] = sessionViewer{panel: panel, slug: row.Slug, sessionID: row.SessionID, title: row.Display}
	return m, panel.Init()
}

// showPanel puts the right panel on key's terminal.
func (m model) showPanel(key string, focus panelFocus) model {
	m.terminalMode = true
	m.setPreferDetail(key, false)
	m.focusedPanel = focus
	return m
}

// viewItemSession opens or shows the viewer of a live session for slug. It
// reports false when the registry lists no live session for it.
func (m model) viewItemSession(slug string) (model, tea.Cmd, bool) {
	if panel, ok := m.panelFor(slug); ok && !(panel.IsViewer() && panel.IsDone()) {
		return m.showPanel(slug, panelRight), nil, true
	}
	row, ok := m.liveSessionRow(slug)
	if !ok {
		return m, nil, false
	}
	m, cmd := m.openViewer(row)
	if _, ok := m.viewers[row.PanelKey]; ok {
		m = m.showPanel(row.PanelKey, panelRight)
	}
	return m, cmd, true
}

// closeViewer detaches one viewer. The session keeps running.
func (m model) closeViewer(key string) model {
	v, ok := m.viewers[key]
	if !ok {
		return m
	}
	v.panel.Cleanup()
	delete(m.viewers, key)
	m.terminalMode = false
	m.detail, _ = m.detail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})
	return m
}

// closeViewersForQuit stops any background AI command and every viewer's tmux
// client. Every session keeps running in the background host.
func (m *model) closeViewersForQuit() {
	if m.aiCancel != nil {
		m.aiCancel()
		m.aiCancel = nil
	}
	for key, v := range m.viewers {
		v.panel = v.panel.Cleanup()
		m.viewers[key] = v
	}
}

// handleViewerMsg routes viewer traffic to the viewer of its key. The panel
// checks the generation; a client no viewer takes is closed.
func (m model) handleViewerMsg(key string, msg tea.Msg) (model, tea.Cmd) {
	if _, ok := m.viewers[key]; !ok {
		if attached, ok := msg.(work.ViewerAttachedMsg); ok {
			return m, func() tea.Msg { attached.Close(); return nil }
		}
		return m, nil
	}
	cmd, _ := m.updatePanel(key, msg)
	return m, cmd
}

// handleViewerTerminate is a viewer's Ctrl+\: the viewer closes and its
// session keeps running.
func (m model) handleViewerTerminate(msg work.ViewerTerminateMsg) (model, tea.Cmd) {
	v, ok := m.viewers[msg.Slug]
	if !ok || v.panel.ViewerGeneration() != msg.Generation {
		return m, nil
	}
	m = m.closeViewer(msg.Slug)
	m.focusedPanel = panelLeft
	return m, nil
}

// resizeViewers sizes every viewer to the panel slot and returns the commands
// that resize their clients' PTYs.
func (m *model) resizeViewers() tea.Cmd {
	var cmds []tea.Cmd
	for key, v := range m.viewers {
		var cmd tea.Cmd
		v.panel, cmd = v.panel.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth() - 2, Height: m.detailPanelHeight()})
		m.viewers[key] = v
		if cmd != nil {
			cmds = append(cmds, cmd)
		}
	}
	return tea.Batch(cmds...)
}

// currentTerminalKey is the panel key the focused terminal shows in state.
func (m model) currentTerminalKey() string {
	switch m.state {
	case stateFollowUps:
		return m.followupDetail.CurrentID()
	case stateSessions:
		if row, ok := m.sessionsList.CurrentSession(); ok {
			return row.PanelKey
		}
		return ""
	default:
		return m.list.CurrentSlug()
	}
}

// terminalCtrlC is Ctrl+c with a terminal focused: a live session gets the
// same close confirmation as x, a finished panel is discarded.
func (m model) terminalCtrlC() (model, tea.Cmd) {
	key := m.currentTerminalKey()
	panel, ok := m.panelFor(key)
	if !ok {
		return m, nil
	}
	if panel.IsDone() {
		if _, viewer := m.viewers[key]; viewer {
			m = m.closeViewer(key)
			m.focusedPanel = panelLeft
			return m, nil
		}
		return m, func() tea.Msg { return work.TerminalTerminateMsg{Slug: key} }
	}
	slug, sessionID, title := key, "", key
	if v, viewer := m.viewers[key]; viewer {
		slug, sessionID, title = v.slug, v.sessionID, v.title
	}
	if slug == "" && sessionID == "" {
		m.flashErr = "cannot close: session has no slug or id to address"
		return m, nil
	}
	m.confirmAction = "close_session"
	m.confirmSlug = slug
	m.confirmSessionID = sessionID
	m.confirmTitle = title
	return m, nil
}

// --- host revival ---

// startHostRevival runs the revival check when one is due: at most one
// `lore session ensure --if-work` a minute, and never two checks at once.
func (m model) startHostRevival() (model, tea.Cmd) {
	if m.sessionsDir == "" || m.hostRevivalBusy {
		return m, nil
	}
	now := m.now()
	if !m.lastHostRevival.IsZero() && now.Sub(m.lastHostRevival) < hostRevivalInterval {
		return m, nil
	}
	m.hostRevivalBusy = true
	dir, kdir := m.sessionsDir, m.config.KnowledgeDir
	return m, func() tea.Msg {
		runtime, err := config.SessionRuntime()
		if err != nil || !orphanedSessionsListed(dir, runtime) {
			return hostRevivalMsg{}
		}
		args := []string{"session", "ensure", "--if-work", "--json"}
		if kdir != "" {
			args = append(args, "--kdir", kdir)
		}
		cmd := exec.Command("lore", args...)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		out, err := cmd.CombinedOutput()
		return hostRevivalMsg{ran: true, at: now, output: strings.TrimSpace(string(out)), err: err}
	}
}

// orphanedSessionsListed reports whether a registry row of this runtime whose
// process is dead lists sessions while no live store host row exists. Those
// sessions are listed nowhere a viewer reads until a store host adopts them.
func orphanedSessionsListed(sessionsDir, runtime string) bool {
	dir := session.InstancesDir(sessionsDir)
	rows, _ := filepath.Glob(filepath.Join(dir, "*.json"))
	claims, _ := filepath.Glob(filepath.Join(dir, "*.json.adopting.*"))
	orphaned := false
	for _, path := range append(rows, claims...) {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var row session.Instance
		if json.Unmarshal(data, &row) != nil {
			continue
		}
		if row.Runtime == runtime && len(row.Sessions) > 0 && !session.ProcessAlive(row.PID) {
			orphaned = true
			break
		}
	}
	if !orphaned {
		return false
	}
	for _, inst := range session.ListInstances(sessionsDir) {
		if inst.Scope == session.ScopeStore && inst.Runtime == runtime && session.ProcessAlive(inst.PID) {
			return false
		}
	}
	return true
}

func (m model) handleHostRevival(msg hostRevivalMsg) (model, tea.Cmd) {
	m.hostRevivalBusy = false
	if !msg.ran {
		return m, nil
	}
	m.lastHostRevival = msg.at
	if msg.err == nil {
		m.hostRevivalErr = ""
		return m, m.sessionsRefreshCmd()
	}
	text := msg.output
	var failure struct {
		Error string `json:"error"`
	}
	if json.Unmarshal([]byte(text), &failure) == nil && failure.Error != "" {
		text = failure.Error
	}
	if text == "" {
		text = msg.err.Error()
	}
	if first, _, _ := strings.Cut(text, "\n"); first != m.hostRevivalErr {
		m.hostRevivalErr = first
		m.statusNotice = "background host did not start: " + first
	}
	return m, nil
}
