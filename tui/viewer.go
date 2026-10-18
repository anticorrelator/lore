package main

import (
	"bytes"
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
	"github.com/anticorrelator/lore/tui/internal/render"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/sessionview"
	"github.com/anticorrelator/lore/tui/internal/style"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// A lore-tui window runs no session of its own. Every session runs in its
// store's background host. The window shows one by attaching a tmux client to
// the host's pane (a viewer panel), starts one through `lore session request`,
// and ends one through `lore session close`. Under _sessions/ it only reads;
// everything it changes there goes through those CLI verbs.

const (
	// launchRefreshInterval is how often the registry and journal are re-read
	// while a launch from this window is waiting to spawn.
	launchRefreshInterval = 500 * time.Millisecond
	// hostRevivalInterval bounds how often a window runs `lore session ensure
	// --if-work` for sessions only dead registry rows list.
	hostRevivalInterval = time.Minute
	// requestEventMemory is how many recent request-outcome journal rows a
	// window keeps, so a launch whose request id arrives after its outcome was
	// read still finds it.
	requestEventMemory = 256
	// windowRequester is what a window passes as --requested-by.
	windowRequester = "lore-tui"
	// noDeclarationLead starts the writer's refusal for a work item that
	// declares no checkout.
	noDeclarationLead = "no checkout declared:"
)

// sessionViewer is an open viewer panel and the session it shows.
type sessionViewer struct {
	panel     work.SessionPanelModel
	slug      string
	sessionID string
	title     string
}

// pendingLaunch is a launch from this window that has neither spawned nor been
// refused. requestID is empty until `lore session request` returns.
type pendingLaunch struct {
	descriptor work.SessionDescriptor
	requestID  string
	attempts   int
	lastReason string
	counted    map[string]bool
	// focusList keeps the work list focused when the viewer opens, as a launch
	// from the work view's confirm modal always has.
	focusList bool
}

// refusalNotice is a modal that shows, in full, why a launch or a close did not
// happen. offer is set for a work item that declares no checkout: Enter then
// declares checkout, the window's own, and launches descriptor again.
type refusalNotice struct {
	title      string
	text       string
	descriptor work.SessionDescriptor
	checkout   string
	offer      bool
	declaring  bool
}

// launchRequestedMsg is the outcome of one `lore session request` run.
type launchRequestedMsg struct {
	descriptor work.SessionDescriptor
	// checkout is the git top level of the window's working directory, or ""
	// when the window is not inside a git checkout.
	checkout  string
	requestID string
	refusal   string
}

// checkoutDeclaredMsg is the outcome of `lore work source-checkout`.
type checkoutDeclaredMsg struct {
	descriptor work.SessionDescriptor
	checkout   string
	output     string
	err        error
}

type launchRefreshTickMsg struct{}

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

// --- launches ---

// launchSession sends a launch to the store's background host. The window
// follows the request in the journal and opens a viewer once it spawns.
func (m model) launchSession(d work.SessionDescriptor) (model, tea.Cmd) {
	key := d.Slug
	if _, pending := m.launches[key]; pending {
		m.flashErr = fmt.Sprintf("%s is already starting in the background host", key)
		return m, nil
	}
	if m.launches == nil {
		m.launches = make(map[string]pendingLaunch)
	}
	m.launches[key] = pendingLaunch{descriptor: d, counted: map[string]bool{}, focusList: m.state == stateWork}
	var tick tea.Cmd
	m, tick = m.armLaunchRefresh()
	return m, tea.Batch(requestLaunchCmd(d, m.config.ProjectDir, m.config.KnowledgeDir), tick)
}

// windowCheckout is the git top level of dir, physically resolved, or "" when
// dir is not inside a git checkout.
func windowCheckout(dir string) string {
	if dir == "" {
		return ""
	}
	out, err := exec.Command("git", "-C", dir, "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return ""
	}
	top := strings.TrimSpace(string(out))
	if top == "" {
		return ""
	}
	return config.NormalizeProjectDir(top)
}

// launchRoute is the role route a window launch freezes into its request.
func launchRoute(t string) (string, error) {
	role, ceremony := "default", ""
	switch t {
	case work.SessionSpec:
		role, ceremony = "lead", "spec"
	case work.SessionImplement:
		role, ceremony = "lead", "implement"
	}
	route, err := config.ResolveCanonicalRoute(role, ceremony, nil)
	if err != nil {
		return "", err
	}
	raw, err := json.Marshal(route)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

// launchArgs is the `lore session request` argv for d. The window names its
// own checkout with --prefer-dir; a work item's declared checkout, when it has
// one, outranks it in the writer.
func launchArgs(d work.SessionDescriptor, route, preferDir, kdir string) []string {
	args := []string{"session", "request", "--type", string(d.Type), "--initiator", "human",
		"--prefer-dir", preferDir, "--session-route", route, "--json"}
	if kdir != "" {
		args = append(args, "--kdir", kdir)
	}
	if d.Slug != "" {
		args = append(args, "--slug", d.Slug)
	}
	if d.ExtraContext != "" {
		args = append(args, "--context", d.ExtraContext)
	}
	if d.Type == work.SessionSpec && d.ShortMode {
		args = append(args, "--track", "short")
	}
	if d.SkipConfirm {
		args = append(args, "--yes")
	} else {
		args = append(args, "--confirm")
	}
	return args
}

// requestLaunchCmd runs `lore session request` off the UI thread.
func requestLaunchCmd(d work.SessionDescriptor, projectDir, kdir string) tea.Cmd {
	return func() tea.Msg {
		checkout := windowCheckout(projectDir)
		preferDir := checkout
		if preferDir == "" {
			preferDir = config.NormalizeProjectDir(projectDir)
		}
		route, err := launchRoute(string(d.Type))
		if err != nil {
			return launchRequestedMsg{descriptor: d, checkout: checkout, refusal: "could not resolve the route for this launch: " + err.Error()}
		}
		cmd := exec.Command("lore", launchArgs(d, route, preferDir, kdir)...)
		cmd.Dir = preferDir
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		var stdout, stderr bytes.Buffer
		cmd.Stdout, cmd.Stderr = &stdout, &stderr
		runErr := cmd.Run()
		requestID, refusal := parseLaunchOutput(stdout.Bytes(), stderr.Bytes(), runErr)
		return launchRequestedMsg{descriptor: d, checkout: checkout, requestID: requestID, refusal: refusal}
	}
}

// parseLaunchOutput reads `lore session request --json`: a request id on
// success, or the whole refusal text, which under --json is the error field of
// the one object it prints.
func parseLaunchOutput(stdout, stderr []byte, runErr error) (string, string) {
	var result struct {
		RequestID string `json:"request_id"`
		Error     string `json:"error"`
	}
	found := false
	lines := strings.Split(strings.TrimSpace(string(stdout)), "\n")
	for i := len(lines) - 1; i >= 0 && !found; i-- {
		line := strings.TrimSpace(lines[i])
		if !strings.HasPrefix(line, "{") {
			continue
		}
		result.RequestID, result.Error = "", ""
		found = json.Unmarshal([]byte(line), &result) == nil && (result.RequestID != "" || result.Error != "")
	}
	if !found {
		result.RequestID, result.Error = "", ""
		if json.Unmarshal(bytes.TrimSpace(stdout), &result) == nil && (result.RequestID != "" || result.Error != "") {
			found = true
		}
	}
	if runErr == nil && found && result.RequestID != "" {
		return result.RequestID, ""
	}
	if found && result.Error != "" {
		return "", result.Error
	}
	text := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(string(stderr)), "Error: "))
	if text == "" {
		text = strings.TrimSpace(string(stdout))
	}
	if runErr == nil {
		return "", "lore session request printed no request id:\n" + text
	}
	if text == "" {
		text = runErr.Error()
	}
	return "", text
}

// handleLaunchRequested records the request id of a sent launch, or shows its
// refusal in full.
func (m model) handleLaunchRequested(msg launchRequestedMsg) (model, tea.Cmd) {
	key := msg.descriptor.Slug
	pending, ok := m.launches[key]
	if msg.refusal != "" {
		if ok {
			delete(m.launches, key)
		}
		d := msg.descriptor
		notice := refusalNotice{title: "Launch refused", text: msg.refusal, descriptor: d, checkout: msg.checkout}
		notice.offer = strings.HasPrefix(strings.TrimSpace(msg.refusal), noDeclarationLead) &&
			d.Slug != "" && !d.FollowupMode && msg.checkout != ""
		m.refusals = append(m.refusals, notice)
		return m, nil
	}
	if !ok {
		return m, nil
	}
	pending.requestID = msg.requestID
	m.launches[key] = pending
	return m, m.sessionsRefreshCmd()
}

// armLaunchRefresh starts the fast refresh while a launch is pending.
func (m model) armLaunchRefresh() (model, tea.Cmd) {
	if m.launchTickArmed || len(m.launches) == 0 {
		return m, nil
	}
	m.launchTickArmed = true
	return m, tea.Tick(launchRefreshInterval, func(time.Time) tea.Msg { return launchRefreshTickMsg{} })
}

func (m model) handleLaunchRefreshTick() (model, tea.Cmd) {
	m.launchTickArmed = false
	if len(m.launches) == 0 {
		return m, nil
	}
	var tick tea.Cmd
	m, tick = m.armLaunchRefresh()
	return m, tea.Batch(m.sessionsRefreshCmd(), tick)
}

// requestOutcome reports whether ev is a journal row that settles or advances
// a launch.
func requestOutcome(ev session.Event) bool {
	if ev.RequestID == "" {
		return false
	}
	switch ev.Event {
	case session.EventSpawned, session.EventSpawnFailed, session.EventAbandoned, session.EventRestoreRefused,
		session.EventExpired, session.EventCancelled, session.EventClosed:
		return true
	}
	return false
}

func eventIdentity(ev session.Event) string {
	if ev.EventID != "" {
		return ev.EventID
	}
	return ev.Event + "|" + ev.TS + "|" + ev.RequestID + "|" + ev.Reason
}

// rememberRequestEvents keeps the most recent request outcomes.
func (m model) rememberRequestEvents(events []session.Event) model {
	for _, ev := range events {
		if requestOutcome(ev) {
			m.requestEvents = append(m.requestEvents, ev)
		}
	}
	if over := len(m.requestEvents) - requestEventMemory; over > 0 {
		m.requestEvents = append([]session.Event(nil), m.requestEvents[over:]...)
	}
	return m
}

// launchedSession finds the session a request spawned in the store host's
// registry rows. A launch checkpoint row is not one: its session may not be
// running yet.
func launchedSession(instances []session.Instance, requestID string) (session.Session, bool) {
	for _, inst := range instances {
		if inst.Role == "session-host-spawn" || inst.Role == "session-spawn" {
			continue
		}
		for _, s := range inst.Sessions {
			if s.RequestID == requestID {
				return s, true
			}
		}
	}
	return session.Session{}, false
}

func refusalTitle(event string) string {
	switch event {
	case session.EventAbandoned:
		return "Launch abandoned"
	case session.EventExpired:
		return "Launch expired"
	case session.EventCancelled:
		return "Launch cancelled"
	default:
		return "Launch refused"
	}
}

func journaledRefusalText(d work.SessionDescriptor, ev session.Event) string {
	what := fmt.Sprintf("%s for %s", d.Type, d.Slug)
	var head, fallback string
	switch ev.Event {
	case session.EventAbandoned:
		head = "The background host gave up on " + what + "."
		fallback = "It stopped retrying after repeated failed attempts."
	case session.EventExpired:
		head = "The request for " + what + " expired before it started."
		fallback = "It waited past its time limit without the background host claiming it."
	case session.EventCancelled:
		head = "The request for " + what + " was cancelled before it started."
	default:
		head = "The background host refused " + what + "."
	}
	reason := strings.TrimSpace(ev.Reason)
	if reason == "" {
		reason = fallback
	}
	if reason == "" {
		return head
	}
	return head + "\n\n" + reason
}

// followLaunches settles each pending launch from the journal and registry:
// spawned opens its viewer, spawn_failed records the attempt the host retries,
// and a terminal refusal shows its reason in full.
func (m model) followLaunches(instances []session.Instance) (model, tea.Cmd) {
	var cmds []tea.Cmd
	for key, l := range m.launches {
		if l.requestID == "" {
			continue
		}
		if l.counted == nil {
			l.counted = map[string]bool{}
		}
		settled := false
		for _, ev := range m.requestEvents {
			if ev.RequestID != l.requestID || l.counted[eventIdentity(ev)] {
				continue
			}
			l.counted[eventIdentity(ev)] = true
			switch ev.Event {
			case session.EventSpawnFailed:
				l.attempts++
				l.lastReason = strings.TrimSpace(ev.Reason)
			case session.EventAbandoned, session.EventRestoreRefused, session.EventExpired, session.EventCancelled:
				m.refusals = append(m.refusals, refusalNotice{title: refusalTitle(ev.Event), text: journaledRefusalText(l.descriptor, ev), descriptor: l.descriptor})
				settled = true
			case session.EventClosed:
				m.statusNotice = fmt.Sprintf("%s ended before its terminal could be shown", key)
				settled = true
			}
			if settled {
				break
			}
		}
		if !settled {
			if s, ok := launchedSession(instances, l.requestID); ok {
				var cmd tea.Cmd
				m, cmd = m.openLaunchedViewer(l, s)
				cmds = append(cmds, cmd)
				settled = true
			}
		}
		if settled {
			delete(m.launches, key)
			continue
		}
		m.launches[key] = l
	}
	return m, tea.Batch(cmds...)
}

// openLaunchedViewer opens the viewer of a session this window launched and
// focuses it as a launch from the confirm modal always has.
func (m model) openLaunchedViewer(l pendingLaunch, s session.Session) (model, tea.Cmd) {
	key := viewerKey(s.Slug, s.SessionID)
	title := sessionview.SessionDisplay(s.Slug, s.Type, s.SessionID)
	m, cmd := m.openViewer(sessionview.SessionRow{PanelKey: key, Slug: s.Slug, SessionID: s.SessionID, Display: title, Tmux: s.Tmux})
	if _, ok := m.viewers[key]; !ok {
		return m, cmd
	}
	switch {
	case m.state == stateWork && m.list.CurrentSlug() == key:
		focus := panelRight
		if l.focusList {
			focus = panelLeft
		}
		m = m.showPanel(key, focus)
	case m.state == stateFollowUps && m.followupDetail.CurrentID() == key:
		m = m.showPanel(key, panelRight)
	}
	return m, cmd
}

// launchStatus is what an item's panel says while its launch is pending.
func (m model) launchStatus(key string) (string, bool) {
	l, ok := m.launches[key]
	if !ok {
		return "", false
	}
	line := fmt.Sprintf("Starting %s for %s in the background host…", l.descriptor.Type, key)
	if l.attempts > 0 {
		reason := l.lastReason
		if reason == "" {
			reason = "no reason given"
		}
		line += fmt.Sprintf("\nAttempt %d failed: %s\nThe background host is retrying.", l.attempts, reason)
	}
	return line, true
}

// withLaunchStatus puts a pending launch's status above an item's detail.
func (m model) withLaunchStatus(key, detail string) string {
	status, ok := m.launchStatus(key)
	if !ok {
		return detail
	}
	var b strings.Builder
	b.WriteString("\n")
	for _, line := range wrapParagraphs(status, m.rightPanelWidth()-6) {
		b.WriteString(style.StatusWarn.Render(line))
		b.WriteString("\n")
	}
	b.WriteString("\n")
	return b.String() + detail
}

// wrapParagraphs word-wraps each line of text to width, keeping blank lines
// and each line's leading indentation.
func wrapParagraphs(text string, width int) []string {
	var out []string
	for _, line := range strings.Split(text, "\n") {
		trimmed := strings.TrimLeft(line, " ")
		if trimmed == "" {
			out = append(out, "")
			continue
		}
		indent := line[:len(line)-len(trimmed)]
		w := width - len(indent)
		if w < 10 {
			w = 10
		}
		for _, wrapped := range render.WordWrapRaw(trimmed, w) {
			out = append(out, indent+wrapped)
		}
	}
	return out
}

// --- refusals ---

func (m model) refusalActive() bool { return len(m.refusals) > 0 }

// handleRefusalKey is the refusal modal's key handling: Esc dismisses, and
// Enter declares the window's checkout when the modal offers it.
func (m model) handleRefusalKey(km tea.KeyPressMsg) (model, tea.Cmd) {
	notice := m.refusals[0]
	switch km.String() {
	case "esc":
		m.refusals = append([]refusalNotice(nil), m.refusals[1:]...)
		return m, nil
	case "enter":
		if !notice.offer || notice.declaring {
			return m, nil
		}
		notice.declaring = true
		refusals := append([]refusalNotice(nil), m.refusals...)
		refusals[0] = notice
		m.refusals = refusals
		return m, declareCheckoutCmd(notice.descriptor, notice.checkout)
	}
	return m, nil
}

// declareCheckoutCmd runs `lore work source-checkout <slug>` in the window's
// checkout, outside any session's identity, so the verb declares that checkout.
func declareCheckoutCmd(d work.SessionDescriptor, checkout string) tea.Cmd {
	return func() tea.Msg {
		cmd := exec.Command("lore", "work", "source-checkout", d.Slug)
		cmd.Dir = checkout
		cmd.Env = withoutSessionIdentity(os.Environ())
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		out, err := cmd.CombinedOutput()
		return checkoutDeclaredMsg{descriptor: d, checkout: checkout, output: strings.TrimSpace(string(out)), err: err}
	}
}

// withoutSessionIdentity drops the variables that make a lore verb act for a
// running session.
func withoutSessionIdentity(env []string) []string {
	out := make([]string, 0, len(env))
	for _, kv := range env {
		name, _, _ := strings.Cut(kv, "=")
		switch name {
		case "LORE_SESSION_INSTANCE", "LORE_SESSION_SLUG", "LORE_SESSION_TYPE":
			continue
		}
		out = append(out, kv)
	}
	return out
}

// handleCheckoutDeclared launches again once the declaration landed, unless
// the person dismissed the modal while it ran.
func (m model) handleCheckoutDeclared(msg checkoutDeclaredMsg) (model, tea.Cmd) {
	showing := len(m.refusals) > 0 && m.refusals[0].declaring && m.refusals[0].descriptor.Slug == msg.descriptor.Slug
	if showing {
		m.refusals = append([]refusalNotice(nil), m.refusals[1:]...)
	}
	if msg.err != nil {
		text := msg.output
		if text == "" {
			text = msg.err.Error()
		}
		m.refusals = append([]refusalNotice{{
			title: "Checkout not declared",
			text:  fmt.Sprintf("lore work source-checkout %s, run in %s, failed:\n\n%s", msg.descriptor.Slug, msg.checkout, text),
		}}, m.refusals...)
		return m, nil
	}
	if !showing {
		m.statusNotice = fmt.Sprintf("declared %s as the checkout of %s", msg.checkout, msg.descriptor.Slug)
		return m, nil
	}
	return m.launchSession(msg.descriptor)
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
