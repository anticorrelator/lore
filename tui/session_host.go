package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
	"github.com/anticorrelator/lore/tui/internal/worktree"
)

type hostOptions struct {
	Key, KnowledgeDir, ReadyFile, Runtime string
	Idle                                  time.Duration
}

// sessionHostRole is the role the store host's registry row carries.
const sessionHostRole = "session-host"

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
func (m model) hostDir() string {
	return filepath.Join(config.SessionHostsDir(m.sessionsDir), m.hostKey)
}

// sessionHostMain runs a host that serves every checkout of one knowledge
// store. Exit codes: 0 after an idle withdrawal, 1 on an error, 2 on invalid
// arguments (including the retired --source-dir form and a host key that is not
// the store's), 3 when another host already holds the store's runtime lock, and
// 75 after a drain its supervisor requested through restart.json.
func sessionHostMain(args []string) int {
	fs := flag.NewFlagSet("session-host", flag.ContinueOnError)
	var o hostOptions
	var idle float64
	var scope, retiredSource string
	fs.StringVar(&scope, "scope", "", `host scope; "store" serves every checkout of the knowledge store`)
	fs.StringVar(&o.Key, "host-key", "", "stable host key")
	fs.StringVar(&o.KnowledgeDir, "kdir", "", "knowledge store")
	fs.StringVar(&retiredSource, "source-dir", "", "retired: checkout-scoped hosting is replaced by --scope store")
	fs.StringVar(&o.ReadyFile, "ready-file", "", "ready metadata")
	fs.Float64Var(&idle, "idle-timeout", 60, "idle timeout in seconds")
	fs.StringVar(&o.Runtime, "runtime", "", "session runtime namespace; must match "+config.SessionRuntimeEnv)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	sourceGiven := false
	fs.Visit(func(f *flag.Flag) { sourceGiven = sourceGiven || f.Name == "source-dir" })
	if sourceGiven || scope != "store" {
		fmt.Fprintln(os.Stderr, "session host: checkout-scoped hosting (--source-dir) is retired; a host serves every checkout of its store and starts with --scope store")
		return 2
	}
	if fs.NArg() != 0 || o.Key == "" || strings.ContainsAny(o.Key, "/\\") || o.KnowledgeDir == "" || !filepath.IsAbs(o.ReadyFile) || idle < 0 {
		fmt.Fprintln(os.Stderr, "invalid session host arguments")
		return 2
	}
	if namespace, _ := config.SessionRuntime(); o.Runtime != namespace {
		fmt.Fprintf(os.Stderr, "session host --runtime %q does not match %s=%q\n", o.Runtime, config.SessionRuntimeEnv, namespace)
		return 2
	}
	givenKnowledgeDir, err := filepath.Abs(o.KnowledgeDir)
	if err == nil {
		o.KnowledgeDir, err = canonicalHostDir(o.KnowledgeDir)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if namespace, _ := config.SessionRuntime(); o.Key != session.StoreHostKey(o.KnowledgeDir, namespace) {
		fmt.Fprintf(os.Stderr, "session host: --host-key %s is not this store's host key in this runtime (%s, from the resolved store path %s and runtime %q)\n", o.Key, session.StoreHostKey(o.KnowledgeDir, namespace), o.KnowledgeDir, namespace)
		return 2
	}
	// Every hosted session inherits this environment, and resolve-repo.sh answers
	// LORE_KNOWLEDGE_DIR for any directory, so a value naming another store would
	// point this store's agents at that one.
	if pin := os.Getenv("LORE_KNOWLEDGE_DIR"); pin != "" && config.NormalizeProjectDir(pin) != o.KnowledgeDir {
		fmt.Fprintf(os.Stderr, "session host: LORE_KNOWLEDGE_DIR=%s names another knowledge store than --kdir %s; start the host with it unset or naming this store\n", pin, o.KnowledgeDir)
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
	// A launch spec holds a session's whole environment. One a dead predecessor
	// wrote and its pane never read would otherwise stay on disk; under the
	// runtime lock, no other host of this key is launching.
	if err = work.SweepStalePaneLaunchSpecs(o.Key, time.Now()); err != nil {
		fmt.Fprintln(os.Stderr, "session host: stale launch specs:", err)
	}
	// The runtime owns a virtual terminal even when its supervisor has none.
	if err = os.Setenv("TERM", "xterm-256color"); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	// Nothing reads a checkout from the working directory: each session's
	// checkout comes from its request row.
	if err = os.Chdir(o.KnowledgeDir); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	cfg := config.Config{
		KnowledgeDir:   o.KnowledgeDir,
		WorkDir:        filepath.Join(o.KnowledgeDir, "_work"),
		RepoIdentifier: storeRepoIdentifier(givenKnowledgeDir, o.KnowledgeDir),
	}
	m := newModel(cfg, config.LoadPrefs(), stateWork)
	m.hostKey = o.Key
	m.width = 140
	m.height = 48
	m.sessionsDir = filepath.Join(o.KnowledgeDir, "_sessions")
	m.instanceName, err = storeHostInstanceName(m.sessionsDir, o.Key, func() (string, error) {
		return session.GenerateName(m.sessionsDir, "")
	}, tmuxSessionNames)
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
	return host.exitCode
}

// storeRepoIdentifier names the store the way config.Load names a visible
// TUI's repo: its path below <data dir>/repos, else its base name. A TUI
// derives that from unresolved `lore resolve` output, so the store path as
// given and as resolved are both tried against the data dir as set and as
// resolved.
func storeRepoIdentifier(given, resolved string) string {
	data := os.Getenv("LORE_DATA_DIR")
	if data == "" {
		home, _ := os.UserHomeDir()
		data = filepath.Join(home, ".lore")
	}
	roots := []string{data}
	if r, err := filepath.EvalSymlinks(data); err == nil && r != data {
		roots = append(roots, r)
	}
	for _, root := range roots {
		prefix := filepath.Join(root, "repos") + string(filepath.Separator)
		for _, dir := range []string{given, resolved} {
			if strings.HasPrefix(dir, prefix) {
				return strings.TrimPrefix(dir, prefix)
			}
		}
	}
	return filepath.Base(resolved)
}

// storeHostInstanceName picks this host's instance name. A tmux session is
// named lore-<instance>-<slug> on a server that every store of this runtime
// shares, while GenerateName checks a name only against this store's live
// registry rows, so two stores' hosts could draw the same name and then the
// same tmux name for equal slugs. The name therefore ends in a tag derived
// from the store host key, which no other store's host shares, and a draw is
// refused while any tmux session already starts with lore-<name>- or any
// registry row of this store, live or dead, still holds the name: a dead
// row is a recovery manifest that a fresh write would overwrite.
func storeHostInstanceName(sessionsDir, key string, draw func() (string, error), tmuxNames func() []string) (string, error) {
	sum := sha256.Sum256([]byte(key))
	tag := hex.EncodeToString(sum[:3])
	names := tmuxNames()
	for attempt := 0; attempt < 32; attempt++ {
		base, err := draw()
		if err != nil {
			return "", err
		}
		name := base + "-" + tag
		taken := false
		for _, tmux := range names {
			taken = taken || strings.HasPrefix(tmux, work.TmuxSessionName(name, ""))
		}
		rows, _ := filepath.Glob(filepath.Join(session.InstancesDir(sessionsDir), name+".json*"))
		if !taken && len(rows) == 0 {
			return name, nil
		}
	}
	return "", fmt.Errorf("session host: no free instance name for host key %s", key)
}

// tmuxSessionNames lists every session on this runtime's tmux server, or none
// when the server is not running.
func tmuxSessionNames() []string {
	out, err := exec.Command("tmux", "-L", config.TmuxServer(), "list-sessions", "-F", "#{session_name}").Output()
	if err != nil {
		return nil
	}
	return strings.Fields(string(out))
}

type hostRuntimeErrorMsg struct{ err error }
type hostPromotionDoneMsg struct{ err error }
type hostTickMsg struct{}
type hostCommandDoneMsg struct{}
type hostRecoveryDoneMsg struct {
	result adoptionScanMsg
	keys   map[string]bool
}
type hostSweepDoneMsg struct{ result sessionWorktreeSweptMsg }

// hostReconcileDoneMsg carries one reconciliation pass: the recovery key set
// it read and the adoption scan it ran over that set and over dead TUIs.
type hostReconcileDoneMsg struct {
	result adoptionScanMsg
	keys   map[string]bool
	err    error
}

// hostLaunchRefusedMsg carries a spawn failure whose launch left nothing
// running, after its allocated checkout was settled.
type hostLaunchRefusedMsg struct{ failure work.StreamErrorMsg }

// hostExitRestart is the exit code of a host that drained for the restart its
// supervisor requested.
const hostExitRestart = 75

type sessionHostModel struct {
	promoting int

	runtime                 model
	options                 hostOptions
	inflight                int
	recovered, swept, ready bool
	idleSince               time.Time
	lastSweep               time.Time
	err                     error
	exitCode                int

	// recoveredKeys are the host keys whose allocation and delivery records
	// this process has recovered; a key that joins the recovery set later is
	// recovered on the next reconciliation pass.
	recoveredKeys map[string]bool
	// reconciling and queueTicks count work in flight that a drain waits out:
	// a reconciliation pass and queue passes that may still claim a row.
	reconciling bool
	queueTicks  int
	// draining is set while restart.json names this process; the host then
	// starts no new operation and exits at its first quiescent tick.
	draining bool
	// retainedReported holds the retained-checkout reports already written to
	// the host log, so a checkout the sweep keeps finding is logged once per
	// host process rather than on every pass.
	retainedReported map[string]bool
}

func (h *sessionHostModel) View() tea.View { return tea.NewView("") }
func (h *sessionHostModel) wrap(cmd tea.Cmd) tea.Cmd {
	if cmd == nil {
		return nil
	}
	h.inflight++
	return tea.Sequence(cmd, func() tea.Msg { return hostCommandDoneMsg{} })
}

// Init recovers, in order, the allocation records, the delivery ledger and the
// dead registry rows of every key in the recovery set, then dead TUI rows of
// this store's repo, before the host publishes readiness.
func (h *sessionHostModel) Init() tea.Cmd {
	m := h.runtime
	scan := m.adoptionScanner()
	return h.wrap(func() tea.Msg {
		failed := func(err error) tea.Msg {
			return hostRecoveryDoneMsg{result: adoptionScanMsg{notices: []runtimeNotice{{Class: operationalFailure, Message: err.Error()}}}}
		}
		keys, err := session.HostRecoveryKeys(m.sessionsDir, m.hostKey)
		if err != nil {
			return failed(err)
		}
		if err := m.recoverHostAllocations(keys); err != nil {
			return failed(err)
		}
		if err := m.recoverHostDeliveries(); err != nil {
			return failed(err)
		}
		return hostRecoveryDoneMsg{result: scan(keys), keys: keys}
	})
}

// reconcileCmd is the periodic recovery pass. A key that joined the recovery
// set since the last pass has its copied allocation and delivery records
// recovered first, then the adoption scan runs over the whole set and over
// dead TUI rows. The pass never touches a record this process wrote for a
// launch or delivery it is still running.
func (h *sessionHostModel) reconcileCmd() tea.Cmd {
	m := h.runtime
	recovered := map[string]bool{}
	for key := range h.recoveredKeys {
		recovered[key] = true
	}
	scan := m.adoptionScanner()
	dir, self := m.sessionsDir, m.instanceName
	claimedBySelf := func(requestID string) bool {
		req, err := session.ReadClaimed(dir, requestID)
		return err == nil && req.ClaimedBy != nil && *req.ClaimedBy == self
	}
	return func() tea.Msg {
		keys, err := session.HostRecoveryKeys(m.sessionsDir, m.hostKey)
		if err != nil {
			return hostReconcileDoneMsg{err: err}
		}
		joined := map[string]bool{}
		for key := range keys {
			if !recovered[key] {
				joined[key] = true
			}
		}
		if len(joined) > 0 {
			if err := m.recoverHostAllocationsExcept(keys, claimedBySelf); err != nil {
				return hostReconcileDoneMsg{err: err}
			}
			if err := m.recoverHostDeliveriesWhere(func(d hostDelivery) bool { return deliveryMintedBy(d, joined) }); err != nil {
				return hostReconcileDoneMsg{err: err}
			}
		}
		return hostReconcileDoneMsg{result: scan(keys), keys: keys}
	}
}

// deliveryMintedBy reports whether a ledger record was written by a host whose
// key is in keys. Each record's event id embeds the key of the host that made
// the attempt, and a migration copies records unchanged.
func deliveryMintedBy(d hostDelivery, keys map[string]bool) bool {
	for _, prefix := range []string{"host-delivery-", "host-close-", "host-outcome-"} {
		if rest, ok := strings.CutPrefix(d.Event.EventID, prefix); ok {
			key, _, found := strings.Cut(rest, "-")
			return found && keys[key]
		}
	}
	return false
}

// settleRefusedLaunchCmd handles a fresh launch that failed before its session
// came up. Its launch checkpoint is the evidence of what it started: with none,
// or with one whose tmux session and process are both gone, nothing survives,
// so the allocated checkout is settled as startup recovery would settle it and
// the request goes back through the ordinary spawn-failure path. Anything else
// may still be running, and starting the request again could launch a second
// agent, so the host stops and leaves it to recovery.
func (m model) settleRefusedLaunchCmd(failure work.StreamErrorMsg, pending liveSession) tea.Cmd {
	checkpointID := pending.checkpointID
	if checkpointID == "" {
		checkpointID = pending.requestID
	}
	path := filepath.Join(session.InstancesDir(m.sessionsDir), m.hostSpawnName(checkpointID)+".json")
	stop := hostRuntimeErrorMsg{err: fmt.Errorf("session %s: %w", failure.Slug, failure.Err)}
	return func() tea.Msg {
		b, err := os.ReadFile(path)
		if err == nil {
			var row session.Instance
			if json.Unmarshal(b, &row) != nil {
				return stop
			}
			for _, s := range row.Sessions {
				if s.Tmux == "" || tmuxAliveOnServer(config.TmuxServer(), s.Tmux) || session.ProcessAlive(s.PID) {
					return stop
				}
			}
		} else if !os.IsNotExist(err) {
			return stop
		}
		if err := m.settleRefusedLaunchAllocation(pending.requestID); err != nil {
			return hostRuntimeErrorMsg{err: fmt.Errorf("session %s: settle refused launch: %w", failure.Slug, err)}
		}
		if err := m.clearHostSpawn(checkpointID); err != nil {
			return hostRuntimeErrorMsg{err: fmt.Errorf("session %s: settle refused launch: %w", failure.Slug, err)}
		}
		return hostLaunchRefusedMsg{failure: failure}
	}
}

// restartRequested reports whether restart.json beside ready.json names this
// process, by pid and by the start time its registry row records.
func (h *sessionHostModel) restartRequested() bool {
	b, err := os.ReadFile(filepath.Join(filepath.Dir(h.options.ReadyFile), "restart.json"))
	if err != nil {
		return false
	}
	var request struct {
		TargetPID     int    `json:"target_pid"`
		TargetStarted string `json:"target_started"`
	}
	return json.Unmarshal(b, &request) == nil && request.TargetPID == os.Getpid() && request.TargetStarted == h.runtime.instanceStartedISO
}

// quiescent reports whether no operation a restart could cut short is under
// way: no spawn or promotion, close, send or answer verification, input or
// interrupt in flight, no worktree outcome being published, no delivery-ledger
// record without its committed terminal, and no queue or reconciliation pass
// that may still claim or adopt. It never reads inflight, which every live
// session's blocking terminal poll holds above zero.
func (h *sessionHostModel) quiescent() bool {
	m := &h.runtime
	if h.promoting > 0 || h.reconciling || h.queueTicks > 0 || len(m.pendingSpawns) > 0 || len(m.pendingClose) > 0 ||
		len(m.pendingSendVerify) > 0 || len(m.pendingAnswerVerify) > 0 || len(m.pendingSend) > 0 || len(m.pendingAnswer) > 0 || len(m.pendingInterrupt) > 0 {
		return false
	}
	for _, ls := range m.localSessions {
		// A session outside tmux would end with this process.
		if ls.worktreeDispositionPending || ls.tmuxName == "" {
			return false
		}
	}
	return !h.runtime.hostLedgerOpen()
}

// hostLedgerOpen reports whether any delivery-ledger record still lacks its
// committed terminal, or cannot be read.
func (m model) hostLedgerOpen() bool {
	paths, err := filepath.Glob(filepath.Join(m.hostDir(), "deliveries", "*.json"))
	if err != nil {
		return true
	}
	for _, path := range paths {
		b, err := os.ReadFile(path)
		if err != nil {
			return true
		}
		var d hostDelivery
		if json.Unmarshal(b, &d) != nil || !d.Terminal || !d.Committed {
			return true
		}
	}
	return false
}

// withdrawForRestart removes ready.json under ensure.lock, as an idle
// withdrawal does, so no caller can publish to this process while it exits.
// Surviving tmux sessions stay as they are for the next host to adopt.
func (h *sessionHostModel) withdrawForRestart() (bool, error) {
	lock, err := hostLock(filepath.Join(filepath.Dir(h.options.ReadyFile), "ensure.lock"), true)
	if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer lock.Close()
	if !h.quiescent() {
		return false, nil
	}
	if err = os.Remove(h.options.ReadyFile); err != nil && !os.IsNotExist(err) {
		return false, err
	}
	h.ready = false
	return true, nil
}

// logNotices writes adoption notices to the host log one by one; the
// runtime's flash would keep only the last.
func logNotices(notices ...[]runtimeNotice) {
	for _, list := range notices {
		for _, n := range list {
			if n.Message != "" {
				fmt.Fprintln(os.Stderr, "session recovery:", n.Message)
			}
		}
	}
}
func hostTick() tea.Cmd {
	return tea.Tick(time.Second, func(time.Time) tea.Msg { return hostTickMsg{} })
}
func (h *sessionHostModel) fail(err error) (tea.Model, tea.Cmd) { h.err = err; return h, tea.Quit }

// reportRetained logs checkouts a sweep or close left in place because their
// content is not proven preserved. They are never fatal: one such checkout
// must not keep the host from serving new sessions, and restarting cannot
// change the answer.
func (h *sessionHostModel) reportRetained(retained []error) {
	for _, err := range retained {
		line := err.Error()
		if h.retainedReported[line] {
			continue
		}
		if h.retainedReported == nil {
			h.retainedReported = map[string]bool{}
		}
		h.retainedReported[line] = true
		fmt.Fprintln(os.Stderr, "session worktree retained:", line)
	}
}
func (h *sessionHostModel) publishReady() error {
	if err := session.WriteInstance(h.runtime.sessionsDir, h.runtime.instanceRow()); err != nil {
		return err
	}
	if err := h.runtime.recoverHostDeliveries(); err != nil {
		return err
	}
	return hostAtomicJSON(h.options.ReadyFile, map[string]any{
		"schema_version": 2, "scope": session.ScopeStore, "host_key": h.options.Key,
		"instance_name": h.runtime.instanceName, "pid": os.Getpid(), "knowledge_dir": h.options.KnowledgeDir,
		"ready": true, "runtime_capabilities": session.RuntimeCapabilities(),
		"build_sha": h.runtime.buildSHA, "build_time": h.runtime.buildTime,
	})
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
		h.recoveredKeys = v.keys
		logNotices(v.result.notices, v.result.tuiNotices)
		v.result.notices, v.result.tuiNotices = nil, nil
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
		h.reportRetained(v.result.retained)
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
	case hostReconcileDoneMsg:
		h.reconciling = false
		if v.err != nil {
			fmt.Fprintln(os.Stderr, "session recovery:", v.err)
			break
		}
		if h.recoveredKeys == nil {
			h.recoveredKeys = map[string]bool{}
		}
		for key := range v.keys {
			h.recoveredKeys[key] = true
		}
		logNotices(v.result.notices, v.result.tuiNotices)
		v.result.notices, v.result.tuiNotices = nil, nil
		var cmd tea.Cmd
		h.runtime, cmd = h.runtime.handleAdoptionScan(v.result)
		cmds = append(cmds, h.wrap(cmd))
	case hostLaunchRefusedMsg:
		fmt.Fprintf(os.Stderr, "session %s: launch failed before it started: %v\n", v.failure.Slug, v.failure.Err)
		next, cmd := h.runtime.Update(v.failure)
		h.runtime = next.(model)
		cmds = append(cmds, h.wrap(cmd))
	case queueTickResultMsg:
		if h.queueTicks > 0 {
			h.queueTicks--
		}
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
			h.draining = h.restartRequested()
			if h.draining {
				h.idleSince = time.Time{}
				if h.quiescent() {
					stopped, err := h.withdrawForRestart()
					if err != nil {
						return h.fail(err)
					}
					if stopped {
						h.exitCode = hostExitRestart
						return h, tea.Quit
					}
				}
			} else if h.idleCandidate() {
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
		var retained error
		if errors.Is(v.err, worktree.ErrContentUnproven) {
			retained = v.err
			h.reportRetained([]error{fmt.Errorf("%s: %w", v.epoch, v.err)})
		} else if v.err != nil {
			return h.fail(v.err)
		}
		if err := h.runtime.writeHostCleanupReceipt(v.slug, v.epoch, v.proof, retained); err != nil {
			return h.fail(err)
		}
	case sessionWorktreeSweptMsg:
		// The periodic sweep. Failures still reach the log through the runtime's
		// flash; retained checkouts are logged here, once each.
		h.reportRetained(v.retained)
		next, cmd := h.runtime.Update(msg)
		h.runtime = next.(model)
		cmds = append(cmds, h.wrap(cmd))
	case instanceSyncedMsg:
		if v.err != nil {
			return h.fail(v.err)
		}
	case closeRequestDeletedMsg:
		if v.err != nil {
			return h.fail(v.err)
		}
	case work.StreamErrorMsg:
		if pending, ok := h.runtime.pendingSpawns[v.Slug]; ok {
			if !pending.adopted && pending.requestID != "" {
				cmds = append(cmds, h.wrap(h.runtime.settleRefusedLaunchCmd(v, pending)))
				break
			}
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
	cmds := []tea.Cmd{m.syncInstanceCmd(), scanPeekRequestsCmd(m.sessionsDir, hosted)}
	if !h.draining {
		// A draining host finishes what it started and takes on nothing new;
		// what waits in the queue is the next host's.
		h.queueTicks++
		cmds = append(cmds, scanInterruptRequestsCmd(m.sessionsDir, m.instanceName), m.queueTickCmd(), scanSendRequestsCmd(m.sessionsDir, hosted), scanAnswerRequestsCmd(m.sessionsDir, hosted), scanCloseRequestsCmd(m.sessionsDir, hosted, sessionIDIndex(m.localSessions)))
	}
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
		if !h.draining && !h.reconciling {
			h.reconciling = true
			cmds = append(cmds, h.reconcileCmd())
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
	h.reportRetained(result.retained)
	if len(result.failures) > 0 {
		return false, result.failures[0]
	}
	if err = os.Remove(h.options.ReadyFile); err != nil && !os.IsNotExist(err) {
		return false, err
	}
	h.ready = false
	return true, nil
}
