package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

type hostOptions struct {
	Key, KnowledgeDir, SourceDir, ReadyFile string
	Idle                                    time.Duration
}

func sessionHostRole(key string) string {
	if key != "" {
		return "session-host"
	}
	return ""
}
func hostRetarget(v []bool) bool { return len(v) > 0 && v[0] }

func hostLock(path string, nonblock bool) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	flags := syscall.LOCK_EX
	if nonblock {
		flags |= syscall.LOCK_NB
	}
	if err = syscall.Flock(int(f.Fd()), flags); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}
func hostAtomicJSON(path string, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".host-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(append(b, '\n'))
	}
	if err == nil {
		err = f.Sync()
	}
	ce := f.Close()
	if err == nil {
		err = ce
	}
	if err != nil {
		return err
	}
	if err = os.Rename(f.Name(), path); err != nil {
		return err
	}
	d, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
func canonicalHostDir(path string) (string, error) {
	p, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	p, err = filepath.EvalSymlinks(p)
	if err != nil {
		return "", err
	}
	st, err := os.Stat(p)
	if err != nil {
		return "", err
	}
	if !st.IsDir() {
		return "", fmt.Errorf("not a directory: %s", p)
	}
	return p, nil
}
func sessionHostMain(args []string) int {
	fs := flag.NewFlagSet("session-host", flag.ContinueOnError)
	var o hostOptions
	var idle float64
	fs.StringVar(&o.Key, "host-key", "", "stable host key")
	fs.StringVar(&o.KnowledgeDir, "kdir", "", "knowledge store")
	fs.StringVar(&o.SourceDir, "source-dir", "", "canonical source checkout")
	fs.StringVar(&o.ReadyFile, "ready-file", "", "ready metadata")
	fs.Float64Var(&idle, "idle-timeout", 60, "idle timeout in seconds")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 0 || o.Key == "" || strings.ContainsAny(o.Key, "/\\") || o.SourceDir == "" || o.KnowledgeDir == "" || !filepath.IsAbs(o.ReadyFile) || idle < 0 {
		fmt.Fprintln(os.Stderr, "invalid session host arguments")
		return 2
	}
	var err error
	o.SourceDir, err = canonicalHostDir(o.SourceDir)
	if err == nil {
		o.KnowledgeDir, err = canonicalHostDir(o.KnowledgeDir)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	o.Idle = time.Duration(idle * float64(time.Second))
	if err = os.MkdirAll(filepath.Dir(o.ReadyFile), 0700); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	lock, err := hostLock(filepath.Join(filepath.Dir(o.ReadyFile), "runtime.lock"), true)
	if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
		return 3
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer lock.Close()
	if err = os.Remove(o.ReadyFile); err != nil && !os.IsNotExist(err) {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer os.Remove(o.ReadyFile)
	// The runtime owns a virtual terminal even when its supervisor has none.
	if err = os.Setenv("TERM", "xterm-256color"); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if err = os.Chdir(o.SourceDir); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if config.NormalizeProjectDir(cfg.KnowledgeDir) != o.KnowledgeDir {
		fmt.Fprintln(os.Stderr, "source checkout resolves to another knowledge store")
		return 1
	}
	cfg.ProjectDir = o.SourceDir
	cfg.KnowledgeDir = o.KnowledgeDir
	cfg.WorkDir = filepath.Join(o.KnowledgeDir, "_work")
	m := newModel(cfg, config.LoadPrefs(), stateWork)
	m.hostKey = o.Key
	m.width = 140
	m.height = 48
	m.sessionsDir = filepath.Join(o.KnowledgeDir, "_sessions")
	m.normalizedProjectDir = o.SourceDir
	m.instanceName, err = session.GenerateName(m.sessionsDir, "")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	repo, err := config.LoreRepoDir()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	m.eventScript = filepath.Join(repo, "scripts/session-event-append.sh")
	m.expiryScript = filepath.Join(repo, "scripts/session-request-expire.sh")
	m.spendScript = filepath.Join(repo, "scripts/session-spend.sh")
	m.instanceStartedISO = time.Now().UTC().Format(time.RFC3339)
	m.buildSHA, m.buildTime = resolveBuildIdentity()
	m.tmuxEnabled, _ = work.TmuxAvailable()
	if !m.tmuxEnabled {
		fmt.Fprintln(os.Stderr, "session host: tmux unavailable; owned direct-PTY processes cannot survive host death")
	}
	if err = session.WriteInstance(m.sessionsDir, m.instanceRow()); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	host := &sessionHostModel{runtime: m, options: o}
	p := tea.NewProgram(host, tea.WithInput(nil), tea.WithOutput(io.Discard), tea.WithoutRenderer(), tea.WithWindowSize(140, 48))
	_, err = p.Run()
	// This is a runtime shutdown, never a request to close surviving tmux agents.
	host.runtime.cleanupAllSubprocesses()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if host.err != nil {
		fmt.Fprintln(os.Stderr, host.err)
		return 1
	}
	return 0
}

type hostRuntimeErrorMsg struct{ err error }
type hostPromotionDoneMsg struct{ err error }
type hostTickMsg struct{}
type hostCommandDoneMsg struct{}
type hostRecoveryDoneMsg struct{ result adoptionScanMsg }
type hostSweepDoneMsg struct{ result sessionWorktreeSweptMsg }
type sessionHostModel struct {
	promoting int

	runtime                 model
	options                 hostOptions
	inflight                int
	recovered, swept, ready bool
	idleSince               time.Time
	lastSweep               time.Time
	err                     error
}

func (h *sessionHostModel) View() tea.View { return tea.NewView("") }
func (h *sessionHostModel) wrap(cmd tea.Cmd) tea.Cmd {
	if cmd == nil {
		return nil
	}
	h.inflight++
	return tea.Sequence(cmd, func() tea.Msg { return hostCommandDoneMsg{} })
}
func (h *sessionHostModel) Init() tea.Cmd {
	return h.wrap(func() tea.Msg {
		if err := h.runtime.recoverHostAllocations(); err != nil {
			return hostRecoveryDoneMsg{adoptionScanMsg{notices: []runtimeNotice{{Class: operationalFailure, Message: err.Error()}}}}
		}
		if err := h.runtime.recoverHostDeliveries(); err != nil {
			return hostRecoveryDoneMsg{adoptionScanMsg{notices: []runtimeNotice{{Class: operationalFailure, Message: err.Error()}}}}
		}
		return hostRecoveryDoneMsg{h.runtime.adoptionScanCmd()().(adoptionScanMsg)}
	})
}
func hostTick() tea.Cmd {
	return tea.Tick(time.Second, func(time.Time) tea.Msg { return hostTickMsg{} })
}
func (h *sessionHostModel) fail(err error) (tea.Model, tea.Cmd) { h.err = err; return h, tea.Quit }
func (h *sessionHostModel) publishReady() error {
	if err := session.WriteInstance(h.runtime.sessionsDir, h.runtime.instanceRow()); err != nil {
		return err
	}
	if err := h.runtime.recoverHostDeliveries(); err != nil {
		return err
	}
	return hostAtomicJSON(h.options.ReadyFile, map[string]any{"schema_version": 1, "host_key": h.options.Key, "instance_name": h.runtime.instanceName, "pid": os.Getpid(), "source_dir": h.options.SourceDir, "knowledge_dir": h.options.KnowledgeDir, "ready": true})
}
func (h *sessionHostModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd
	switch v := msg.(type) {
	case hostRecoveryDoneMsg:
		for _, n := range v.result.notices {
			if n.Class == operationalFailure {
				return h.fail(fmt.Errorf("recovery: %s", n.Message))
			}
		}
		var cmd tea.Cmd
		h.runtime, cmd = h.runtime.handleAdoptionScan(v.result)
		cmds = append(cmds, h.wrap(cmd))
		h.recovered = true
		cmds = append(cmds, h.wrap(func() tea.Msg {
			return hostSweepDoneMsg{h.runtime.sweepSessionWorktreesCmd()().(sessionWorktreeSweptMsg)}
		}))
	case hostSweepDoneMsg:
		if v.result.deferred != nil {
			fmt.Fprintln(os.Stderr, "shared orphan cleanup deferred:", v.result.deferred)
		}
		if len(v.result.failures) > 0 {
			return h.fail(v.result.failures[0])
		}
		h.swept = true
		h.lastSweep = time.Now()
	case work.SessionProcessStartedMsg:
		h.promoting++
		next, cmd := h.runtime.Update(msg)
		h.runtime = next.(model)
		cmds = append(cmds, h.wrap(cmd))
	case hostRuntimeErrorMsg:
		return h.fail(v.err)
	case hostPromotionDoneMsg:
		h.promoting--
		if v.err != nil {
			return h.fail(v.err)
		}
	case hostCommandDoneMsg:
		h.inflight--
	case hostTickMsg:
		if h.ready {
			if h.idleCandidate() {
				if h.idleSince.IsZero() {
					h.idleSince = time.Now()
				}
				if time.Since(h.idleSince) >= h.options.Idle {
					stopped, err := h.withdrawIfIdle()
					if err != nil {
						return h.fail(err)
					}
					if stopped {
						return h, tea.Quit
					}
				}
			} else {
				h.idleSince = time.Time{}
			}
			cmds = append(cmds, h.sessionTick())
		}
		cmds = append(cmds, hostTick())
	case work.StreamCompleteMsg:
		if ls, ok := h.runtime.localSessions[v.Slug]; ok && ls.tmuxName != "" && work.TmuxHasSession(ls.tmuxName) {
			return h.fail(fmt.Errorf("tmux attachment ended while session %s survives", v.Slug))
		}
		next, cmd := h.runtime.Update(msg)
		h.runtime = next.(model)
		cmds = append(cmds, h.wrap(cmd))
	case sessionWorktreeCleanedMsg:
		if v.err != nil {
			return h.fail(v.err)
		}
		if err := hostAtomicJSON(filepath.Join(h.runtime.sessionsDir, "hosts", h.options.Key, "cleanup", v.slug+".json"), map[string]any{"schema_version": 1, "slug": v.slug, "epoch": v.epoch, "proof": v.proof, "cleaned": true}); err != nil {
			return h.fail(err)
		}
	case instanceSyncedMsg:
		if v.err != nil {
			return h.fail(v.err)
		}
	case closeRequestDeletedMsg:
		if v.err != nil {
			return h.fail(v.err)
		}
	case work.StreamErrorMsg:
		if pending, ok := h.runtime.pendingSpawns[v.Slug]; ok && (pending.adopted || h.runtime.hostKey != "") {
			// Preserve ownership and retry through scoped startup recovery; never turn
			// a failed attach into a new launch request.
			return h.fail(fmt.Errorf("session %s: %w", v.Slug, v.Err))
		}
		next, cmd := h.runtime.Update(msg)
		h.runtime = next.(model)
		cmds = append(cmds, h.wrap(cmd))
	case journalResultMsg:
		if v.err != nil {
			return h.fail(v.err)
		}
	case sendConsumedMsg:
		if v.err != nil {
			return h.fail(v.err)
		}
		h.runtime, _ = h.runtime.handleSendConsumed(v)
	case answerConsumedMsg:
		if v.err != nil {
			return h.fail(v.err)
		}
		h.runtime, _ = h.runtime.handleAnswerConsumed(v)
	case tea.WindowSizeMsg:
		// Host geometry is fixed; a human's attach client may independently resize
		// tmux. No frontend event can repeatedly steal its dimensions.
	default:
		if loaded, ok := msg.(workItemsLoadedMsg); ok {
			if loaded.err == nil {
				h.runtime.list = work.NewListModel(loaded.items)
			}
		} else {
			next, cmd := h.runtime.Update(msg)
			h.runtime = next.(model)
			cmds = append(cmds, h.wrap(cmd))
		}
	}
	if !h.ready && h.recovered && h.swept && h.promoting == 0 && len(h.runtime.pendingSpawns) == 0 {
		if err := h.publishReady(); err != nil {
			return h.fail(err)
		}
		h.ready = true
		cmds = append(cmds, hostTick())
	}
	if h.runtime.flashErr != "" {
		fmt.Fprintln(os.Stderr, h.runtime.flashErr)
		h.runtime.flashErr = ""
	}
	return h, tea.Batch(cmds...)
}
func (h *sessionHostModel) sessionTick() tea.Cmd {
	m := &h.runtime
	items, err := work.LoadIndex(m.config.WorkDir)
	if err == nil {
		m.list = work.NewListModel(items)
	}
	hosted := map[string]bool{}
	for slug := range m.localSessions {
		hosted[slug] = true
	}
	cmds := []tea.Cmd{m.syncInstanceCmd(), m.queueTickCmd(), scanSendRequestsCmd(m.sessionsDir, m.instanceName, hosted, true), scanPeekRequestsCmd(m.sessionsDir, m.instanceName, hosted, true), scanAnswerRequestsCmd(m.sessionsDir, m.instanceName, hosted, true), scanCloseRequestsCmd(m.sessionsDir, m.instanceName, hosted, sessionIDIndex(m.localSessions), true)}
	var more []tea.Cmd
	*m, more = m.advanceCloseLadders()
	cmds = append(cmds, more...)
	*m, more = m.advanceSendVerifications()
	cmds = append(cmds, more...)
	*m, more = m.advanceAnswerVerifications()
	cmds = append(cmds, more...)
	*m, more = m.advanceModalObservations()
	cmds = append(cmds, more...)
	if time.Since(h.lastSweep) > 30*time.Second {
		h.lastSweep = time.Now()
		for slug, ls := range m.localSessions {
			if panel, ok := m.sessionPanels[slug]; ok && !panel.IsDone() {
				continue
			}
			if _, pending := m.pendingSpawns[slug]; pending || ls.worktreeDispositionPending {
				continue
			}
			if ls.tmuxName != "" && work.TmuxHasSession(ls.tmuxName) {
				for _, row := range m.instanceRow().Sessions {
					if row.Slug == slug && validateAdoptionIdentity(m.config.KnowledgeDir, row) == nil {
						var cmd tea.Cmd
						*m, cmd = m.handleAdoptionScan(adoptionScanMsg{alive: []adoptedSession{adoptedFromRegistry(ls.adoptedFrom, row)}})
						cmds = append(cmds, cmd)
					}
				}
			} else {
				var terminal []tea.Cmd
				*m, terminal = m.endLocalSession(slug)
				cmds = append(cmds, terminal...)
			}
		}
		if len(m.localSessions) == 0 && len(m.pendingSpawns) == 0 {
			cmds = append(cmds, m.sweepSessionWorktreesCmd())
		}
	}

	return h.wrap(tea.Batch(cmds...))
}
func (h *sessionHostModel) idleCandidate() bool {
	m := &h.runtime
	return h.inflight == 0 && len(m.localSessions) == 0 && len(m.pendingSpawns) == 0 && len(m.pendingClose) == 0 && len(m.pendingSendVerify) == 0 && len(m.pendingAnswerVerify) == 0
}
func (h *sessionHostModel) withdrawIfIdle() (bool, error) {
	lock, err := hostLock(filepath.Join(filepath.Dir(h.options.ReadyFile), "ensure.lock"), true)
	if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer lock.Close()
	if !h.idleCandidate() {
		return false, nil
	}
	rows, diagnostics := session.ScanPendingWithDiagnostics(h.runtime.sessionsDir)
	if len(diagnostics) > 0 {
		return false, nil
	}
	for _, r := range rows {
		if r.HostKey == h.options.Key {
			return false, nil
		}
	}
	claimed, _ := session.ScanClaimedWithDiagnostics(h.runtime.sessionsDir)
	for _, r := range claimed {
		if r.Request.HostKey == h.options.Key {
			return false, nil
		}
	}
	paths, _ := filepath.Glob(filepath.Join(h.runtime.sessionsDir, "managed", "*.json"))
	for _, path := range paths {
		b, err := os.ReadFile(path)
		if err != nil {
			return false, err
		}
		var v struct {
			HostKey string `json:"host_key"`
			State   string `json:"state"`
		}
		if err = json.Unmarshal(b, &v); err != nil {
			return false, err
		}
		if v.HostKey == h.options.Key && (v.State == "intent" || v.State == "enqueueing") {
			return false, nil
		}
	}
	result := h.runtime.sweepSessionWorktreesCmd()().(sessionWorktreeSweptMsg)
	if len(result.failures) > 0 {
		return false, result.failures[0]
	}
	if err = os.Remove(h.options.ReadyFile); err != nil && !os.IsNotExist(err) {
		return false, err
	}
	h.ready = false
	return true, nil
}
