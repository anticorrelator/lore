package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
	"github.com/anticorrelator/lore/tui/internal/worktree"
)

// sessionSpendProbeTimeout caps the boundary-time token-spend probe
// (session-spend.sh) at teardown. Teardown must never block on spend, so a
// probe that exceeds this is killed and the row closes duration-only.
const sessionSpendProbeTimeout = 5 * time.Second

// liveSession is the metadata the TUI tracks for one local session: enough to
// write its registry row and to journal its lifecycle. requestID is set only for
// queue-claimed (agent) sessions.
type liveSession struct {
	typ       string // spec|implement|chat
	initiator string // agent|human
	requestID string
	started   time.Time
	// autoClose is the per-request auto-close override the close ladder consults:
	// nil defers to initiator (agent auto-closes, human holds open), a set value
	// forces the outcome. Carried from the request row at spawn.
	autoClose *bool
	// sessionID and harness bind teardown's token-spend probe: sessionID is the
	// spawn-generated harness session id (empty when the harness has no
	// deterministic binding), harness the framework it was spawned under. Both are
	// stamped from SessionProcessStartedMsg when the process comes up.
	sessionID string
	harness   string
	// closeRequests is the ordered, distinct set of close-request ids consumed
	// during this lifecycle. It survives close_failed outcomes and adoption, then
	// travels as a compact JSON-array string in closed.links.close_requests.
	closeRequests []string
	// worktree is the durable execution workspace identity. A nil value marks a
	// legacy session that cannot be safely recovered into a host checkout.
	worktree     *worktree.Identity
	worktreeID   string
	executionDir string
	pid          int
	// worktreeDispositionPending suppresses duplicate publish attempts when the
	// PTY completion and close ladder observe the same process death concurrently.
	// Durable recovery still relies on the persisted lifecycle state, not this bit.
	worktreeDispositionPending bool
	// tmuxName is the hosting tmux session name (empty for direct-PTY): persisted
	// on the registry row as the recovery manifest and the quit-path detach marker.
	tmuxName string
	// adopted marks a session brought up by the startup adoption scan rather than a
	// fresh spawn; adoptedFrom names the dead instance whose row it was recovered
	// from. Both drive the `recovered` journal row (in place of `spawned`) and are
	// transient — not persisted onto the registry row.
	adopted     bool
	adoptedFrom string
}

// --- messages ---

// sessionSnapshotMsg carries a full registry snapshot for external-session
// badging. It replaces badging state wholesale, never merges.
type sessionSnapshotMsg struct {
	instances   []session.Instance
	diagnostics []session.Diagnostic
}

// queueTickResultMsg carries the durable transitions one queue pass performed.
type queueTickResultMsg struct {
	result session.QueueTickResult
	err    error
}

// instanceSyncedMsg reports the outcome of a registry write/heartbeat.
type instanceSyncedMsg struct {
	err error
}

// journalResultMsg reports the outcome of a journal append.
type journalResultMsg struct {
	err error
}

type worktreeDispositionMsg struct {
	slug           string
	closeRequestID string
	ls             liveSession
	outcome        worktree.PublishOutcome
	err            error
}

type managedWorktreeQuiescedMsg struct {
	slug           string
	closeRequestID string
	err            error
}

// --- Cmds ---

// readInstancesCmd reads the instance registry (a full snapshot).
func readInstancesCmd(sessionsDir string) tea.Cmd {
	return func() tea.Msg {
		instances, diagnostics := session.ListInstancesWithDiagnostics(sessionsDir)
		return sessionSnapshotMsg{instances: instances, diagnostics: diagnostics}
	}
}

// syncInstanceCmd heartbeats this instance's registry file, recreating it if a
// stale-reaper or first tick left it absent.
func (m model) syncInstanceCmd() tea.Cmd {
	dir := m.sessionsDir
	inst := m.instanceRow()
	kdir := m.config.KnowledgeDir
	return func() tea.Msg {
		if err := session.Heartbeat(dir, inst); err != nil {
			return instanceSyncedMsg{err: err}
		}
		for _, hosted := range inst.Sessions {
			if hosted.WorktreeID == "" {
				continue
			}
			placement, err := worktree.ValidateManagedPlacement(context.Background(), kdir, hosted.WorktreeID, hosted.ExecutionDir, hosted.Worktree)
			if err != nil {
				return instanceSyncedMsg{err: fmt.Errorf("renew managed worktree %s: %w", hosted.WorktreeID, err)}
			}
			if err := worktree.RenewManagedPlacement(context.Background(), kdir, hosted.WorktreeID, placement.Owner.ID); err != nil {
				return instanceSyncedMsg{err: err}
			}
		}
		return instanceSyncedMsg{err: worktree.SweepManagedPlacements(context.Background(), kdir)}
	}
}

// writeInstanceCmd rewrites this instance's registry file after its session set
// changed.
func (m model) writeInstanceCmd() tea.Cmd {
	dir := m.sessionsDir
	inst := m.instanceRow()
	return func() tea.Msg {
		return instanceSyncedMsg{err: session.WriteInstance(dir, inst)}
	}
}

func (m model) disposeWorktreeCmd(slug string, ls liveSession, closeRequestID string) tea.Cmd {
	destination := m.normalizedProjectDir
	if destination == "" {
		destination = m.config.ProjectDir
	}
	return func() tea.Msg {
		if ls.worktree == nil {
			return worktreeDispositionMsg{slug: slug, closeRequestID: closeRequestID, ls: ls,
				err: fmt.Errorf("missing versioned worktree identity")}
		}
		outcome, err := publishWorktree(context.Background(), *ls.worktree, destination)
		return worktreeDispositionMsg{slug: slug, closeRequestID: closeRequestID, ls: ls, outcome: outcome, err: err}
	}
}

func (m model) quiesceManagedWorktreeCmd(slug string, ls liveSession, closeRequestID string) tea.Cmd {
	kdir := m.config.KnowledgeDir
	return func() tea.Msg {
		if ls.worktree == nil || ls.worktreeID == "" || ls.executionDir == "" {
			return managedWorktreeQuiescedMsg{slug: slug, closeRequestID: closeRequestID,
				err: fmt.Errorf("incomplete managed worktree placement")}
		}
		placement, err := worktree.ValidateManagedPlacement(context.Background(), kdir, ls.worktreeID, ls.executionDir, ls.worktree)
		if err != nil {
			return managedWorktreeQuiescedMsg{slug: slug, closeRequestID: closeRequestID, err: err}
		}
		if placement.State != "active" && placement.State != "recovered" {
			return managedWorktreeQuiescedMsg{slug: slug, closeRequestID: closeRequestID,
				err: fmt.Errorf("managed worktree state %q cannot quiesce", placement.State)}
		}
		err = worktree.TransitionManagedPlacement(context.Background(), kdir, ls.worktreeID, "quiescent")
		return managedWorktreeQuiescedMsg{slug: slug, closeRequestID: closeRequestID, err: err}
	}
}

func (m model) handleManagedWorktreeQuiesced(msg managedWorktreeQuiescedMsg) (model, tea.Cmd) {
	ls, tracked := m.localSessions[msg.slug]
	if !tracked {
		return m, nil
	}
	ls.worktreeDispositionPending = false
	m.localSessions[msg.slug] = ls
	if msg.err != nil {
		m.flashErr = compactErr("managed worktree quiesce", msg.err)
		return m, m.writeInstanceCmd()
	}
	var cmds []tea.Cmd
	m, cmds = m.finalizeLocalSessionClosed(msg.slug, msg.closeRequestID)
	return m, tea.Sequence(cmds...)
}

func publishWorktree(ctx context.Context, identity worktree.Identity, destination string) (worktree.PublishOutcome, error) {
	publishable, artifact, err := worktree.MakePublishable(ctx, identity)
	if err != nil {
		return worktree.PublishOutcome{
			Kind: worktree.OutcomeRestoreRefused, Identity: identity,
			Expected: identity.Captured, Reason: err.Error(),
		}, err
	}
	return worktree.Publish(ctx, publishable, artifact, destination)
}

func worktreeOutcomeEvent(instanceName, slug string, ls liveSession, outcome worktree.PublishOutcome) session.Event {
	event := session.EventRestoreRefused
	if outcome.Kind == worktree.OutcomeWorktreeQuarantined {
		event = session.EventWorktreeQuarantined
	}
	links := map[string]string{
		"worktree_epoch": outcome.Identity.Epoch,
		"worktree_path":  outcome.Identity.CanonicalPath,
		"target_ref":     outcome.Identity.TargetRef,
		"target_oid":     outcome.Identity.TargetOID,
	}
	if expected, err := json.Marshal(outcome.Expected); err == nil {
		links["expected_generation"] = string(expected)
	}
	if outcome.Observed != nil {
		if observed, err := json.Marshal(outcome.Observed); err == nil {
			links["observed_generation"] = string(observed)
		}
	}
	if outcome.Artifact.Ref != "" {
		links["result_ref"] = outcome.Artifact.Ref
	}
	if outcome.Artifact.OID != "" {
		links["result_oid"] = outcome.Artifact.OID
	}
	if outcome.Artifact.PatchPath != "" {
		links["patch_path"] = outcome.Artifact.PatchPath
	}
	return session.Event{
		Event: event, ActorInstance: session.StrPtr(instanceName), Slug: slug,
		SessionType: ls.typ, Initiator: ls.initiator, Reason: outcome.Reason, Links: links,
	}
}

func (m model) handleWorktreeDisposition(msg worktreeDispositionMsg) (model, tea.Cmd) {
	ls, tracked := m.localSessions[msg.slug]
	if !tracked {
		return m, nil
	}
	ls.worktreeDispositionPending = false
	if msg.outcome.Identity.Version != 0 {
		ls.worktree = cloneWorktreeIdentity(&msg.outcome.Identity)
	}
	m.localSessions[msg.slug] = ls
	if msg.err != nil || msg.outcome.Kind == worktree.OutcomeRestoreRefused {
		m.flashErr = compactErr("worktree disposition", msg.err)
		outcome := msg.outcome
		if outcome.Reason == "" && msg.err != nil {
			outcome.Reason = msg.err.Error()
		}
		return m, tea.Sequence(
			m.writeInstanceCmd(),
			journalCmd(m.eventScript, m.config.KnowledgeDir, worktreeOutcomeEvent(m.instanceName, msg.slug, ls, outcome)),
		)
	}

	var outcomeCmd tea.Cmd
	if msg.outcome.Kind == worktree.OutcomeWorktreeQuarantined {
		outcomeCmd = journalCmd(m.eventScript, m.config.KnowledgeDir, worktreeOutcomeEvent(m.instanceName, msg.slug, ls, msg.outcome))
	}
	var terminalCmds []tea.Cmd
	m, terminalCmds = m.finalizeLocalSessionClosed(msg.slug, msg.closeRequestID)
	cmds := make([]tea.Cmd, 0, len(terminalCmds)+1)
	if outcomeCmd != nil {
		cmds = append(cmds, outcomeCmd)
	}
	cmds = append(cmds, terminalCmds...)
	return m, tea.Sequence(cmds...)
}

// queueTickCmd runs one reclaim+claim pass. The live-instance set is read inside
// the Cmd; the plan-doc gate is snapshotted from the loaded work items now.
func (m model) queueTickCmd() tea.Cmd {
	dir := m.sessionsDir
	name := m.instanceName
	vintage := m.buildTime
	projectDir := m.normalizedProjectDir
	planDocs := make(map[string]bool)
	for _, it := range m.list.Items() {
		planDocs[it.Slug] = it.HasPlanDoc
	}
	// Eviction guard: slugs with a live or in-flight session on this instance.
	// localSessions is the promoted-live set; pendingSpawns is claimed-but-not-yet-
	// started. A pending request for either is left unclaimed so its spawn can never
	// replace the running session. Snapshotted at Cmd-build time, like planDocs.
	liveSlugs := make(map[string]bool, len(m.localSessions)+len(m.pendingSpawns))
	for slug := range m.localSessions {
		liveSlugs[slug] = true
	}
	for slug := range m.pendingSpawns {
		liveSlugs[slug] = true
	}
	return func() tea.Msg {
		live := make(map[string]bool)
		instances, instanceDiagnostics := session.ListInstancesWithDiagnostics(dir)
		for _, inst := range instances {
			live[inst.Name] = true
		}
		res, err := session.QueueTick(dir, name, vintage, projectDir, live,
			func(slug string) bool { return planDocs[slug] },
			func(slug string) bool { return liveSlugs[slug] },
			time.Now(), session.ReclaimAfter)
		res.Diagnostics = append(instanceDiagnostics, res.Diagnostics...)
		return queueTickResultMsg{result: res, err: err}
	}
}

// journalCmd appends one event row via the sole-writer script.
func journalCmd(script, kdir string, ev session.Event) tea.Cmd {
	return func() tea.Msg {
		return journalResultMsg{err: session.AppendEvent(script, kdir, ev)}
	}
}

type modalObservation struct {
	known         bool
	blocked       bool
	framework     string
	numberedModal *config.NumberedModalSignature
}

var matchModalAnswer = config.MatchModalAnswer

// observeModalPanel reads one screen and reuses the readiness classifier's
// interactive predicate. Resolution or snapshot failures are unobservable, not
// clears: callers preserve the prior latch until a successful classification.
func observeModalPanel(panel work.SessionPanelModel) modalObservation {
	framework, err := config.ResolveTUILaunchFramework()
	if err != nil {
		return modalObservation{}
	}
	snap, err := panel.ScreenState()
	if err != nil {
		return modalObservation{}
	}
	state, ok := classifyScreen(framework, snap)
	return modalObservation{known: ok, blocked: ok && state.interactive, framework: framework, numberedModal: state.numberedModal}
}

func (m model) observeModal(panel work.SessionPanelModel) modalObservation {
	if m.observeModalFn != nil {
		return m.observeModalFn(panel)
	}
	return observeModalPanel(panel)
}

// registeredModalAnswerCmd preserves modal_blocked as the first durable fact,
// then delegates enqueueing to the existing session-answer verb. A failed
// journal append prevents authorization from reaching the answer queue.
func registeredModalAnswerCmd(script, kdir, slug string, blocked session.Event, registration config.ModalAnswerRegistration) tea.Cmd {
	return func() tea.Msg {
		if err := session.AppendEvent(script, kdir, blocked); err != nil {
			return journalResultMsg{err: err}
		}
		answerScript := filepath.Join(filepath.Dir(script), "session-answer.sh")
		cmd := exec.Command("bash", answerScript, slug,
			"--option", strconv.Itoa(registration.Answer.Option),
			"--expect", registration.Answer.Expect,
			"--registration-id", registration.ID,
			"--kdir", kdir)
		if out, err := cmd.CombinedOutput(); err != nil {
			return journalResultMsg{err: fmt.Errorf("enqueue registered modal answer: %w: %s", err, strings.TrimSpace(string(out)))}
		}
		return journalResultMsg{}
	}
}

// advanceModalObservations emits exactly one modal_blocked row per successfully
// observed nonmodal→modal entry. Persistent modal frames are suppressed, a
// classified clear silently re-arms, and read/classification failures preserve
// the latch so transient observation gaps cannot manufacture duplicate entries.
func (m model) advanceModalObservations() (model, []tea.Cmd) {
	var cmds []tea.Cmd
	for slug, ls := range m.localSessions {
		panel, ok := m.sessionPanels[slug]
		if !ok {
			continue
		}
		obs := m.observeModal(panel)
		if !obs.known {
			continue
		}
		if !obs.blocked {
			delete(m.sessionModalBlocked, slug)
			continue
		}
		if m.sessionModalBlocked[slug] {
			continue
		}
		if m.sessionModalBlocked == nil {
			m.sessionModalBlocked = make(map[string]bool)
		}
		m.sessionModalBlocked[slug] = true
		blocked := m.modalBlockedEventFor(slug, ls)
		if obs.numberedModal != nil {
			if registration, matched := matchModalAnswer(obs.framework, *obs.numberedModal); matched {
				cmds = append(cmds, registeredModalAnswerCmd(m.eventScript, m.config.KnowledgeDir, slug, blocked, registration))
				continue
			}
		}
		cmds = append(cmds, journalCmd(m.eventScript, m.config.KnowledgeDir, blocked))
	}
	return m, cmds
}

// emitSpawnedCmd deletes the claimed row then journals `spawned` — the delete is
// the durable terminal state, so it must land before the history row.
func emitSpawnedCmd(dir, script, kdir string, ev session.Event) tea.Cmd {
	return func() tea.Msg {
		if err := session.DeleteClaimed(dir, ev.RequestID); err != nil {
			return journalResultMsg{err: err}
		}
		return journalResultMsg{err: session.AppendEvent(script, kdir, ev)}
	}
}

// emitRecoveredCmd writes this instance's registry row (now carrying the adopted
// session) then journals `recovered` — the durable registry write is the recovery
// manifest and must land before the history row, matching the substrate's
// durable-before-journal ordering. Both run in one Cmd goroutine so the order is
// guaranteed (a batched writeInstanceCmd would race the journal append).
func emitRecoveredCmd(dir, script, kdir string, inst session.Instance, ev session.Event) tea.Cmd {
	return func() tea.Msg {
		if err := session.WriteInstance(dir, inst); err != nil {
			return journalResultMsg{err: err}
		}
		return journalResultMsg{err: session.AppendEvent(script, kdir, ev)}
	}
}

// adoptedSession is one still-running tmux-hosted session recovered from a dead
// instance's registry row during startup adoption.
type adoptedSession struct {
	deadInstance  string
	slug          string
	typ           string
	initiator     string
	requestID     string
	started       time.Time
	tmuxName      string
	sessionID     string
	harness       string
	autoClose     *bool
	closeRequests []string
	worktree      *worktree.Identity
	worktreeID    string
	executionDir  string
	pid           int
	refusalReason string
}

// adoptionScanMsg carries survivors plus non-fatal recovery notices. Sessions
// with no surviving tmux are journaled `orphaned` inside the scan Cmd; only live
// ones need re-attach and a `recovered` row here.
type adoptionScanMsg struct {
	alive       []adoptedSession
	retained    []adoptedSession
	notices     []runtimeNotice
	diagnostics []session.Diagnostic
}

func adoptedFromRegistry(deadInstance string, s session.Session) adoptedSession {
	return adoptedSession{
		deadInstance: deadInstance,
		slug:         s.Slug, typ: s.Type, initiator: s.Initiator, requestID: s.RequestID,
		started: parseStartedISO(s.Started), tmuxName: s.Tmux, sessionID: s.SessionID,
		harness: s.Harness, autoClose: s.AutoClose,
		closeRequests: append([]string(nil), s.CloseRequests...),
		worktree:      cloneWorktreeIdentity(s.Worktree),
		worktreeID:    s.WorktreeID,
		executionDir:  s.ExecutionDir,
		pid:           s.PID,
	}
}

func validateAdoptionIdentity(kdir string, s session.Session) error {
	if err := validatePersistedWorktree(s.Worktree); err != nil {
		return err
	}
	if s.Worktree.State != worktree.StateActive && s.Worktree.State != worktree.StateTeardownPending {
		return fmt.Errorf("worktree lifecycle %q cannot host a surviving process", s.Worktree.State)
	}
	managed := s.WorktreeID != "" || s.ExecutionDir != ""
	if managed {
		if s.WorktreeID == "" || s.ExecutionDir == "" {
			return fmt.Errorf("incomplete managed worktree placement")
		}
		placement, err := worktree.ValidateManagedPlacement(context.Background(), kdir, s.WorktreeID, s.ExecutionDir, s.Worktree)
		if err != nil {
			return err
		}
		if placement.State != "active" && placement.State != "recovered" {
			return fmt.Errorf("managed worktree lifecycle %q cannot host a surviving process", placement.State)
		}
		if placement.Owner.Kind != "session" || placement.Owner.PID != s.PID ||
			placement.Owner.TmuxName != s.Tmux || placement.Owner.TmuxServer != "lore-tui" {
			return fmt.Errorf("managed worktree owner does not match persisted session pid/tmux identity")
		}
	}
	if managed {
		panePID, err := work.TmuxPanePID(s.Tmux)
		if err != nil {
			return fmt.Errorf("read tmux pane pid: %w", err)
		}
		if s.PID <= 0 || panePID != s.PID {
			return fmt.Errorf("tmux pane pid mismatch: observed %d, expected %d", panePID, s.PID)
		}
	}
	paneCWD, err := work.TmuxPaneCWD(s.Tmux)
	if err != nil {
		return fmt.Errorf("read tmux pane cwd: %w", err)
	}
	canonicalPaneCWD, err := filepath.EvalSymlinks(paneCWD)
	if err != nil {
		return fmt.Errorf("resolve tmux pane cwd: %w", err)
	}
	canonicalPaneCWD, err = filepath.Abs(canonicalPaneCWD)
	if err != nil {
		return fmt.Errorf("canonicalize tmux pane cwd: %w", err)
	}
	expectedDir := s.Worktree.CanonicalPath
	if managed {
		expectedDir = s.ExecutionDir
	}
	if canonicalPaneCWD != expectedDir {
		return fmt.Errorf("tmux pane cwd mismatch: observed %q, expected %q", canonicalPaneCWD, expectedDir)
	}
	return nil
}

func validatePersistedWorktree(identity *worktree.Identity) error {
	if identity == nil {
		return fmt.Errorf("missing versioned worktree identity")
	}
	if !identity.OwnsWorktree() {
		return fmt.Errorf("worktree lifecycle %q does not retain ownership", identity.State)
	}
	if err := worktree.ValidateIdentity(context.Background(), *identity); err != nil {
		return err
	}
	return nil
}

func adoptionRefusedEvent(self string, a adoptedSession) session.Event {
	return session.Event{
		EventID: recoveryEventID("restore-refused", a.deadInstance, a.slug, a.requestID),
		Event:   session.EventRestoreRefused, ActorInstance: session.StrPtr(self),
		TargetInstance: session.StrPtr(a.deadInstance), Slug: a.slug,
		SessionType: a.typ, Initiator: a.initiator, Reason: a.refusalReason,
	}
}

func recoveryEventID(kind string, parts ...string) string {
	sum := sha256.Sum256([]byte(strings.Join(parts, "\x00")))
	return fmt.Sprintf("%s-%x", kind, sum[:16])
}

func appendOrphanDue(script, kdir string, ev session.Event) error {
	if ev.SessionType != "spec" && ev.SessionType != "implement" {
		return nil
	}
	outcomeID := "retro-due-" + ev.EventID
	cmd := exec.Command("bash", filepath.Join(filepath.Dir(script), "retro-deferred-append.sh"),
		"--cycle-id", ev.Slug,
		"--event-type", "session-orphaned",
		"--outcome", "due",
		"--outcome-id", outcomeID,
		"--disposition", "unhandled",
		"--reason", "always-stratum",
		"--rate", "1",
		"--stratum", "instance_death",
		"--kdir", kdir)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("append orphan retro DUE: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func retireDeadTargetCloseRequests(sessionsDir, script, kdir, actor, deadInstance string) ([]runtimeNotice, []session.Diagnostic) {
	rows, diagnostics := session.ScanCloseRequestsWithDiagnostics(sessionsDir)
	var notices []runtimeNotice
	for _, cr := range rows {
		if cr.RequestID == "" || cr.TargetInstance != deadInstance {
			continue
		}
		ev := session.Event{
			EventID:        recoveryEventID("close-failed-dead-target", deadInstance, cr.RequestID),
			Event:          session.EventCloseFailed,
			ActorInstance:  session.StrPtr(actor),
			TargetInstance: session.StrPtr(deadInstance),
			Slug:           cr.Slug,
			RequestID:      cr.RequestID,
			Reason:         closeFailedTargetInstanceDead,
		}
		if err := session.AppendEvent(script, kdir, ev); err != nil {
			notices = append(notices, runtimeNotice{Class: operationalFailure, Code: "dead-target-retirement-append", Message: compactErr("dead-target close retirement", err)})
			continue
		}
		if err := session.DeleteCloseRequest(sessionsDir, cr.RequestID); err != nil {
			notices = append(notices, runtimeNotice{Class: operationalFailure, Code: "dead-target-retirement-delete", Message: compactErr("dead-target close retirement", err)})
		}
	}
	return notices, diagnostics
}

// adoptionScanCmd is the D5 startup recovery pass. It scans the instance registry
// for dead instances' rows (owner mtime-stale AND pid-dead), atomically claims each
// by rename, and for every nested session decides re-attach vs. close by tmux
// liveness. Filter inputs (repo, self name, script paths) are snapshotted at
// Cmd-build time; the instances directory is read live inside the Cmd — the same
// build-time-snapshot/run-time-read split the close/queue scanners use. Runs once
// at startup, never on the poll heartbeat.
func (m model) adoptionScanCmd() tea.Cmd {
	dir := m.sessionsDir
	repo := m.config.RepoIdentifier
	self := m.instanceName
	script, kdir := m.eventScript, m.config.KnowledgeDir
	destination := m.normalizedProjectDir
	if destination == "" {
		destination = m.config.ProjectDir
	}
	return func() tea.Msg {
		var alive []adoptedSession
		var retained []adoptedSession
		var notices []runtimeNotice
		var diagnostics []session.Diagnostic
		transferred := m.instanceRow()
		for _, inst := range session.ScanAdoptable(dir, repo, self, time.Now()) {
			claim, claimPath, err := session.ClaimInstance(dir, inst.Name)
			if err != nil {
				continue // lost the claim race, or the row vanished
			}
			var claimAlive []adoptedSession
			var claimRetained []adoptedSession
			var claimEvents []session.Event
			for _, s := range claim.Sessions {
				if s.Tmux != "" && work.TmuxHasSession(s.Tmux) {
					a := adoptedFromRegistry(claim.Name, s)
					if err := validateAdoptionIdentity(kdir, s); err != nil {
						a.refusalReason = err.Error()
						claimRetained = append(claimRetained, a)
						claimEvents = append(claimEvents, adoptionRefusedEvent(self, a))
						continue
					}
					claimAlive = append(claimAlive, a)
					continue
				}
				// No survivor remains. Record the observation as its own terminal;
				// ordinary closed is reserved for an observed teardown.
				a := adoptedFromRegistry(claim.Name, s)
				ls := a.liveSession()
				if s.WorktreeID != "" || s.ExecutionDir != "" {
					// A coordinated tree is never published or restored by session
					// recovery. The orphan event lands below; the manager's sweep then
					// captures its recovery bundle before any removal.
					if s.WorktreeID == "" || s.ExecutionDir == "" {
						a.refusalReason = "incomplete managed worktree placement"
						claimEvents = append(claimEvents, adoptionRefusedEvent(self, a))
						claimRetained = append(claimRetained, a)
					} else if _, placementErr := worktree.ValidateManagedPlacement(context.Background(), kdir, s.WorktreeID, s.ExecutionDir, s.Worktree); placementErr != nil {
						a.refusalReason = placementErr.Error()
						claimEvents = append(claimEvents, adoptionRefusedEvent(self, a))
						claimRetained = append(claimRetained, a)
					}
				} else if err := validatePersistedWorktree(s.Worktree); err != nil {
					a.refusalReason = err.Error()
					claimEvents = append(claimEvents, adoptionRefusedEvent(self, a))
					claimRetained = append(claimRetained, a)
				} else {
					pending := *s.Worktree
					if pending.State != worktree.StateTeardownPending {
						pending, err = worktree.Transition(pending, worktree.StateTeardownPending)
					}
					if err != nil {
						a.refusalReason = err.Error()
						claimEvents = append(claimEvents, adoptionRefusedEvent(self, a))
						claimRetained = append(claimRetained, a)
					} else {
						a.worktree = cloneWorktreeIdentity(&pending)
						outcome, dispositionErr := publishWorktree(context.Background(), pending, destination)
						if dispositionErr != nil || outcome.Kind == worktree.OutcomeRestoreRefused {
							a.refusalReason = outcome.Reason
							if a.refusalReason == "" && dispositionErr != nil {
								a.refusalReason = dispositionErr.Error()
							}
							claimEvents = append(claimEvents, adoptionRefusedEvent(self, a))
							claimRetained = append(claimRetained, a)
						} else if outcome.Kind == worktree.OutcomeWorktreeQuarantined {
							claimEvents = append(claimEvents, worktreeOutcomeEvent(self, s.Slug, ls, outcome))
						}
					}
				}
				ev := m.orphanedEventFor(s.Slug, ls, claim.Name)
				claimEvents = append(claimEvents, ev)
			}
			transferStart := len(transferred.Sessions)
			for _, a := range append(append([]adoptedSession(nil), claimAlive...), claimRetained...) {
				transferred.Sessions = append(transferred.Sessions, a.registrySession())
			}
			if err := session.WriteInstance(dir, transferred); err != nil {
				transferred.Sessions = transferred.Sessions[:transferStart]
				notices = append(notices, runtimeNotice{Class: operationalFailure, Code: "adoption-ownership-transfer", Message: compactErr("adoption ownership transfer", err)})
				continue
			}
			alive = append(alive, claimAlive...)
			retained = append(retained, claimRetained...)
			for _, ev := range claimEvents {
				if err := session.AppendEvent(script, kdir, ev); err != nil {
					notices = append(notices, runtimeNotice{Class: operationalFailure, Code: "recovery-outcome-append", Message: compactErr("recovery outcome", err)})
					continue
				}
				if ev.Event == session.EventOrphaned {
					if err := appendOrphanDue(script, kdir, ev); err != nil {
						notices = append(notices, runtimeNotice{Class: operationalFailure, Code: "orphaned-due", Message: compactErr("orphaned session", err)})
					}
				}
			}
			retirementNotices, retirementDiagnostics := retireDeadTargetCloseRequests(dir, script, kdir, self, claim.Name)
			notices = append(notices, retirementNotices...)
			diagnostics = append(diagnostics, retirementDiagnostics...)
			if err := session.DeleteClaim(claimPath); err != nil {
				notices = append(notices, runtimeNotice{Class: operationalFailure, Code: "adoption-claim-delete", Message: compactErr("adoption claim delete", err)})
			}
		}
		// Crash evidence and adoption ownership transfers above must be durable
		// before the manager may sweep an abandoned coordinated checkout.
		if err := worktree.SweepManagedPlacements(context.Background(), kdir); err != nil {
			notices = append(notices, runtimeNotice{Class: operationalFailure, Code: "worktree-sweep", Message: compactErr("managed worktree sweep", err)})
		}
		return adoptionScanMsg{alive: alive, retained: retained, notices: notices, diagnostics: diagnostics}
	}
}

// handleAdoptionScan re-attaches each recovered survivor through the normal panel
// path: it pre-creates the panel, records the adopted metadata as a pending spawn
// (marked adopted so the started handler journals `recovered` rather than
// `spawned`), and dispatches the attach Cmd. Panels created here are re-sized by
// resizeSessionPanels on the first WindowSizeMsg, so a size not yet known at
// startup self-corrects.
func (m model) handleAdoptionScan(msg adoptionScanMsg) (model, tea.Cmd) {
	m = m.routeRuntimeNotices(msg.notices)
	diagnosticCmd := appendDiagnosticsCmd(m.sessionsDir, msg.diagnostics)
	if m.localSessions == nil {
		m.localSessions = make(map[string]liveSession)
	}
	for _, a := range msg.retained {
		m.localSessions[a.slug] = a.liveSession()
	}
	if len(msg.alive) == 0 {
		return m, diagnosticCmd
	}
	specH := m.detailPanelHeight()
	specW := m.rightPanelWidth() - 2
	if m.pendingSpawns == nil {
		m.pendingSpawns = make(map[string]liveSession)
	}
	var cmds []tea.Cmd
	for _, a := range msg.alive {
		m.localSessions[a.slug] = a.liveSession()
		m.list, _ = m.list.Update(work.SessionStatusMsg{Slug: a.slug, Type: a.typ})
		panel := work.NewSessionPanelModel(a.slug)
		panel, _ = panel.Update(tea.WindowSizeMsg{Width: specW, Height: specH})
		m.setSessionPanel(a.slug, panel)
		m.pendingSpawns[a.slug] = liveSession{
			typ:           a.typ,
			initiator:     a.initiator,
			requestID:     a.requestID,
			started:       a.started,
			autoClose:     a.autoClose,
			sessionID:     a.sessionID,
			harness:       a.harness,
			tmuxName:      a.tmuxName,
			adopted:       true,
			adoptedFrom:   a.deadInstance,
			closeRequests: append([]string(nil), a.closeRequests...),
			worktree:      cloneWorktreeIdentity(a.worktree),
			worktreeID:    a.worktreeID,
			executionDir:  a.executionDir,
			pid:           a.pid,
		}
		cmds = append(cmds, work.AttachTerminalCmd(a.slug, a.tmuxName, a.sessionID, a.harness,
			m.config.KnowledgeDir, a.worktreeID, a.executionDir, *a.worktree, specW, specH))
	}
	if diagnosticCmd != nil {
		cmds = append(cmds, diagnosticCmd)
	}
	return m, tea.Batch(cmds...)
}

func (a adoptedSession) liveSession() liveSession {
	return liveSession{
		typ: a.typ, initiator: a.initiator, requestID: a.requestID, started: a.started,
		autoClose: a.autoClose, sessionID: a.sessionID, harness: a.harness,
		tmuxName: a.tmuxName, adopted: true, adoptedFrom: a.deadInstance,
		closeRequests: append([]string(nil), a.closeRequests...),
		worktree:      cloneWorktreeIdentity(a.worktree),
		worktreeID:    a.worktreeID,
		executionDir:  a.executionDir,
		pid:           a.pid,
	}
}

func (a adoptedSession) registrySession() session.Session {
	return session.Session{
		Slug: a.slug, Type: a.typ, Initiator: a.initiator,
		Started: a.started.UTC().Format("2006-01-02T15:04:05Z"), Tmux: a.tmuxName,
		RequestID: a.requestID, SessionID: a.sessionID, Harness: a.harness,
		AutoClose: a.autoClose, CloseRequests: append([]string(nil), a.closeRequests...),
		Worktree:   cloneWorktreeIdentity(a.worktree),
		WorktreeID: a.worktreeID, ExecutionDir: a.executionDir, PID: a.pid,
	}
}

// parseStartedISO parses a registry row's `started` timestamp, falling back to now
// (duration 0) on a malformed value so a `closed` row for an adopted-dead session
// never emits a nonsense duration from a zero-value time.
func parseStartedISO(iso string) time.Time {
	t, err := time.Parse("2006-01-02T15:04:05Z", iso)
	if err != nil {
		return time.Now()
	}
	return t
}

// emitSpawnFailedCmd returns the request to pending with an incremented attempt
// count and a recorded reason, then journals `spawn_failed`. The return-to-
// pending is the durable transition and lands first.
func emitSpawnFailedCmd(dir, script, kdir, requestID, reason, actor string) tea.Cmd {
	return func() tea.Msg {
		req, err := session.ReadClaimed(dir, requestID)
		if err != nil {
			return journalResultMsg{err: err}
		}
		req.Attempts++
		at := time.Now().UTC().Format("2006-01-02T15:04:05Z")
		req.LastAttemptAt = &at
		req.LastError = &reason
		req.ClaimedBy = nil
		req.ClaimedAt = nil
		if err := session.ReturnToPending(dir, req); err != nil {
			return journalResultMsg{err: err}
		}
		ev := session.Event{
			Event:         session.EventSpawnFailed,
			ActorInstance: session.StrPtr(actor),
			Slug:          req.SlugValue(),
			SessionType:   req.Type,
			Initiator:     req.Initiator,
			RequestID:     requestID,
			Reason:        reason,
		}
		return journalResultMsg{err: session.AppendEvent(script, kdir, ev)}
	}
}

// --- handlers ---

// handleSessionSnapshot turns a registry snapshot into external-session badging
// for the list and detail views. Sessions on this instance are local and never
// badged as external.
func (m model) handleSessionSnapshot(msg sessionSnapshotMsg) (model, tea.Cmd) {
	external := make(map[string]work.ExternalSession)
	for _, inst := range msg.instances {
		if inst.Name == m.instanceName {
			continue
		}
		for _, s := range inst.Sessions {
			external[s.Slug] = work.ExternalSession{
				Instance:  inst.Name,
				Type:      s.Type,
				Initiator: s.Initiator,
			}
		}
	}
	m.list, _ = m.list.Update(work.ExternalSessionMsg{Sessions: external})
	currentSlug := m.list.CurrentSlug()
	if es, ok := external[currentSlug]; ok {
		m.detail, _ = m.detail.Update(work.DetailExternalSessionMsg{
			Active: true, Instance: es.Instance, Type: es.Type, Initiator: es.Initiator,
		})
	} else {
		m.detail, _ = m.detail.Update(work.DetailExternalSessionMsg{Active: false})
	}
	return m, appendDiagnosticsCmd(m.sessionsDir, msg.diagnostics)
}

// handleQueueTickResult journals every durable queue transition and spawns the
// claimed request (if any). Reclaim/abandon durable changes already completed in
// the tick, so their journal rows follow safely.
func (m model) handleQueueTickResult(msg queueTickResultMsg) (model, tea.Cmd) {
	if msg.err != nil {
		m.flashErr = compactErr("session queue", msg.err)
	}
	script, kdir := m.eventScript, m.config.KnowledgeDir
	var cmds []tea.Cmd
	if cmd := appendDiagnosticsCmd(m.sessionsDir, msg.result.Diagnostics); cmd != nil {
		cmds = append(cmds, cmd)
	}
	for _, ev := range msg.result.Reclaimed {
		cmds = append(cmds, journalCmd(script, kdir, session.Event{
			Event:         session.EventReclaimed,
			ActorInstance: session.StrPtr(m.instanceName),
			RequestID:     ev.RequestID,
			Reason:        ev.Reason,
		}))
	}
	for _, ev := range msg.result.Abandoned {
		cmds = append(cmds, journalCmd(script, kdir, session.Event{
			Event:         session.EventAbandoned,
			ActorInstance: session.StrPtr(m.instanceName),
			RequestID:     ev.RequestID,
			Reason:        ev.Reason,
		}))
	}
	if req := msg.result.Claimed; req != nil {
		cmds = append(cmds, journalCmd(script, kdir, session.Event{
			Event:          session.EventClaimed,
			ActorInstance:  session.StrPtr(m.instanceName),
			TargetInstance: req.TargetInstance,
			Slug:           req.SlugValue(),
			SessionType:    req.Type,
			Initiator:      req.Initiator,
			RequestID:      req.RequestID,
		}))
		var spawnCmd tea.Cmd
		m, spawnCmd = m.spawnFromRequest(*req)
		if spawnCmd != nil {
			cmds = append(cmds, spawnCmd)
		}
	}
	if len(cmds) == 0 {
		return m, nil
	}
	return m, tea.Batch(cmds...)
}

// spawnFromRequest maps a claimed request onto a session descriptor and drives
// the shared spawn path. Agent-initiated, so it never steals focus.
func (m model) spawnFromRequest(req session.Request) (model, tea.Cmd) {
	return m.spawnSession(descriptorFromRequest(req), req.RequestID)
}

// descriptorFromRequest maps a claimed queue request onto the session descriptor
// the shared spawn path consumes. It is the sole place the additive request
// fields (track, model, framework, skip_confirm) become descriptor state, so the
// mapping — including the skip_confirm absent-default — is unit-testable without
// a spawn.
func descriptorFromRequest(req session.Request) work.SessionDescriptor {
	// skip_confirm defaults to true when absent — the historical queue-spawn
	// autonomy (a claimed request runs without confirmation gates). A set field
	// forces the outcome, letting a coordinator request a gated run (false).
	skipConfirm := true
	if req.SkipConfirm != nil {
		skipConfirm = *req.SkipConfirm
	}
	return work.SessionDescriptor{
		Type:             req.Type,
		Slug:             req.SlugValue(),
		Title:            req.SlugValue(),
		ExtraContext:     req.ExtraContextText(),
		Initiator:        req.Initiator,
		AutoClose:        req.AutoClose,
		RoutingOverrides: req.RoutingOverrides,
		Model:            req.ModelValue(),
		Framework:        req.FrameworkValue(),
		Worktree:         req.WorktreeIdentity,
		WorktreeID:       req.WorktreeIDValue(),
		ExecutionDir:     req.ExecutionDirValue(),
		ShortMode:        req.TrackValue() == work.SpecTrackShort,
		SkipConfirm:      skipConfirm,
		FindingIndex:     -1,
	}
}

func allocateSessionWorktreeCmd(d work.SessionDescriptor, sourceDir, worktreePath, epoch string, next func(work.SessionDescriptor) tea.Msg) tea.Cmd {
	return func() tea.Msg {
		identity, err := worktree.Create(context.Background(), sourceDir, worktreePath, epoch)
		if err != nil {
			return work.StreamErrorMsg{Slug: d.Slug, Err: fmt.Errorf("create session worktree: %w", err)}
		}
		d.Worktree = &identity
		return next(d)
	}
}

// spawnSession is the single spawn path for both the human confirm modal and the
// agent request queue. It pre-creates and sizes the panel, records the pending
// spawn's metadata for the SpecProcessStarted handler, and returns the spawn
// Cmd. Agent-initiated spawns are marked so the started handler never steals
// focus; human spawns keep the existing modal-return-focus behavior.
func (m model) spawnSession(d work.SessionDescriptor, requestID string) (model, tea.Cmd) {
	slug := d.Slug
	m.list, _ = m.list.Update(work.SessionStatusMsg{Slug: slug, Type: sessionType(d.Type)})
	specH := m.detailPanelHeight()
	specW := m.rightPanelWidth() - 2 // 1-char buffer on each side
	panel := work.NewSessionPanelModel(slug)
	panel, _ = panel.Update(tea.WindowSizeMsg{Width: specW, Height: specH})
	m.setSessionPanel(slug, panel)
	m.detail, _ = m.detail.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth(), Height: m.detailPanelHeight()})

	if m.pendingSpawns == nil {
		m.pendingSpawns = make(map[string]liveSession)
	}
	m.pendingSpawns[slug] = liveSession{
		typ:          sessionType(d.Type),
		initiator:    d.Initiator,
		requestID:    requestID,
		started:      time.Now(),
		autoClose:    d.AutoClose,
		worktreeID:   d.WorktreeID,
		executionDir: d.ExecutionDir,
	}
	if d.Initiator != "agent" {
		m.sessionLaunchedFromModal = m.state == stateWork
	}
	env := work.SessionEnv{Instance: m.instanceName, Slug: slug, Type: sessionType(d.Type),
		WorktreeID: d.WorktreeID, ExecutionDir: d.ExecutionDir, RoutingOverrides: d.RoutingOverrides}
	if d.Worktree == nil {
		sourceDir := m.normalizedProjectDir
		if sourceDir == "" {
			sourceDir = m.config.ProjectDir
		}
		epoch := session.NewRequestID()
		worktreePath := filepath.Join(m.config.KnowledgeDir, "_sessions", "worktrees", epoch)
		return m, allocateSessionWorktreeCmd(d, sourceDir, worktreePath, epoch, func(allocated work.SessionDescriptor) tea.Msg {
			return work.StartTerminalCmd(allocated, specW, specH, m.config.KnowledgeDir, env, m.tmuxEnabled)()
		})
	}
	return m, work.StartTerminalCmd(d, specW, specH, m.config.KnowledgeDir, env, m.tmuxEnabled)
}

// instanceRow builds this instance's registry row from its live session set.
func (m model) instanceRow() session.Instance {
	sessions := make([]session.Session, 0, len(m.localSessions))
	for slug, ls := range m.localSessions {
		sessions = append(sessions, session.Session{
			Slug:          slug,
			Type:          ls.typ,
			Initiator:     ls.initiator,
			Started:       ls.started.UTC().Format("2006-01-02T15:04:05Z"),
			Tmux:          ls.tmuxName,
			PID:           ls.pid,
			RequestID:     ls.requestID,
			SessionID:     ls.sessionID,
			Harness:       ls.harness,
			AutoClose:     ls.autoClose,
			CloseRequests: append([]string(nil), ls.closeRequests...),
			Worktree:      cloneWorktreeIdentity(ls.worktree),
			WorktreeID:    ls.worktreeID,
			ExecutionDir:  ls.executionDir,
		})
	}
	// Framework is resolved live at row-build so a settings change is reflected
	// on the next full write; a resolution error omits the field rather than
	// surfacing a wrong value.
	framework, err := config.ResolveTUILaunchFramework()
	if err != nil {
		framework = ""
	}
	return session.Instance{
		Name:             m.instanceName,
		PID:              os.Getpid(),
		Repo:             m.config.RepoIdentifier,
		Started:          m.instanceStartedISO,
		InitiatorDefault: "human",
		Sessions:         sessions,
		BuildSHA:         m.buildSHA,
		BuildTime:        m.buildTime,
		ProjectDir:       m.normalizedProjectDir,
		Framework:        framework,
	}
}

func cloneWorktreeIdentity(identity *worktree.Identity) *worktree.Identity {
	if identity == nil {
		return nil
	}
	cloned := *identity
	return &cloned
}

// closedEventMeta builds the `closed` journal row's identity fields for a
// torn-down local session, leaving Spend for the caller to fill.
func (m model) closedEventMeta(slug string, ls liveSession) session.Event {
	ev := session.Event{
		Event:         session.EventClosed,
		ActorInstance: session.StrPtr(m.instanceName),
		Slug:          slug,
		SessionType:   ls.typ,
		Initiator:     ls.initiator,
		RequestID:     ls.requestID,
	}
	if len(ls.closeRequests) > 0 {
		encoded, _ := json.Marshal(ls.closeRequests) // []string cannot fail to marshal
		ev.Links = map[string]string{"close_requests": string(encoded)}
	}
	return ev
}

// closedEventFor builds the `closed` row with the duration-only spend shape —
// the synchronous quit-path row (cleanupAllSubprocesses), where the program is
// exiting and no boundary-time spend probe can run. The interactive teardown
// paths enrich instead via closedSpendJournalCmd.
func (m model) closedEventFor(slug string, ls liveSession) session.Event {
	ev := m.closedEventMeta(slug, ls)
	ev.Spend = durationOnlySpend(sessionDurationSeconds(ls.started))
	return ev
}

func (m model) orphanedEventFor(slug string, ls liveSession, deadInstance string) session.Event {
	ev := session.Event{
		EventID:        recoveryEventID("orphaned", deadInstance, slug, ls.requestID, ls.started.UTC().Format(time.RFC3339)),
		Event:          session.EventOrphaned,
		ActorInstance:  session.StrPtr(m.instanceName),
		TargetInstance: session.StrPtr(deadInstance),
		Slug:           slug,
		SessionType:    ls.typ,
		Initiator:      ls.initiator,
		RequestID:      ls.requestID,
		Reason:         "instance-death",
	}
	ev.Spend = closedSpend(m.spendScript, ls.harness, ls.sessionID, m.config.ProjectDir, sessionDurationSeconds(ls.started))
	return ev
}

// closedSpendJournalCmd runs the boundary-time token-spend probe and appends the
// enriched `closed` row, both inside one Cmd goroutine so the probe never blocks
// the UI thread and the append still flows through the sole writer
// (session-event-append.sh). A session with no deterministic transcript binding,
// or any probe gap, closes with the duration-only spend; duration_seconds is
// always merged TUI-side — the helper never sees it. A non-empty closeRequestID
// overrides the row's request_id with the consumed close-request's id (the match
// key a ladder-driven teardown carries); empty leaves the spawn request_id.
func (m model) closedSpendJournalCmd(slug string, ls liveSession, closeRequestID string) tea.Cmd {
	script, kdir := m.eventScript, m.config.KnowledgeDir
	spendScript, cwd := m.spendScript, m.config.ProjectDir
	ev := m.closedEventMeta(slug, ls)
	if closeRequestID != "" {
		ev.RequestID = closeRequestID
	}
	dur := sessionDurationSeconds(ls.started)
	harness, sessionID := ls.harness, ls.sessionID
	return func() tea.Msg {
		ev.Spend = closedSpend(spendScript, harness, sessionID, cwd, dur)
		return journalResultMsg{err: session.AppendEvent(script, kdir, ev)}
	}
}

// sessionDurationSeconds is the teardown wall-clock in whole seconds, floored at
// zero so a clock skew never emits a negative duration.
func sessionDurationSeconds(started time.Time) int {
	dur := int(time.Since(started).Seconds())
	if dur < 0 {
		dur = 0
	}
	return dur
}

// durationOnlySpend is the degraded closed-spend object: the always-present
// duration plus the explicit degradation marker.
func durationOnlySpend(durationSeconds int) json.RawMessage {
	return json.RawMessage(fmt.Sprintf(`{"duration_seconds":%d,"basis":"duration-only"}`, durationSeconds))
}

// closedSpend returns the `closed` row's spend object. With a deterministic
// transcript binding (sessionID set at spawn) it probes session-spend.sh under a
// short timeout and overlays the returned D1 token fields onto the duration-only
// base; duration_seconds is always present and TUI-owned. Any gap — no binding,
// timeout, non-JSON output, or a helper that itself degraded — leaves the
// duration-only shape (`basis:"duration-only"`).
func closedSpend(spendScript, harness, sessionID, cwd string, durationSeconds int) json.RawMessage {
	if spendScript == "" || harness == "" || sessionID == "" {
		return durationOnlySpend(durationSeconds)
	}
	probed := probeSessionSpend(spendScript, harness, sessionID, cwd)
	if probed == nil {
		return durationOnlySpend(durationSeconds)
	}
	// The helper never emits duration_seconds; it is the teardown's own field, so
	// stamp it last and let it win over anything the overlay carried.
	probed["duration_seconds"] = json.RawMessage(strconv.Itoa(durationSeconds))
	if _, ok := probed["basis"]; !ok {
		probed["basis"] = json.RawMessage(`"duration-only"`)
	}
	out, err := json.Marshal(probed)
	if err != nil {
		return durationOnlySpend(durationSeconds)
	}
	return out
}

// probeSessionSpend shells out to session-spend.sh with the session's binding and
// returns the parsed spend object, or nil on timeout, launch failure, or
// unparseable output. The helper always exits 0 and prints one JSON object; a
// non-zero exit here therefore means the probe was killed (timeout) or never ran.
// The child runs in its own process group so a timeout kills the python
// grandchild too, not just the bash wrapper.
func probeSessionSpend(spendScript, harness, sessionID, cwd string) map[string]json.RawMessage {
	ctx, cancel := context.WithTimeout(context.Background(), sessionSpendProbeTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "bash", spendScript,
		"--harness", harness, "--session-id", sessionID, "--cwd", cwd)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	var out bytes.Buffer
	cmd.Stdout = &out
	// stderr is dropped: the helper logs its degradations there, and teardown must
	// never surface or block on them.
	if err := cmd.Run(); err != nil {
		return nil
	}
	var parsed map[string]json.RawMessage
	if err := json.Unmarshal(bytes.TrimSpace(out.Bytes()), &parsed); err != nil {
		return nil
	}
	return parsed
}

// idleEventFor builds one of the running-session transition rows
// (needs_input/quiescent/resumed) for a local session. These carry the running
// instance and the session's identity but — unlike queue-lifecycle events — no
// request_id.
func (m model) idleEventFor(slug, event string, ls liveSession) session.Event {
	return session.Event{
		Event:         event,
		ActorInstance: session.StrPtr(m.instanceName),
		Slug:          slug,
		SessionType:   ls.typ,
		Initiator:     ls.initiator,
	}
}

// modalBlockedEventFor builds the entry-only modal classification row. Like the
// idle transitions it describes a running session rather than a queue request,
// so it carries no request_id; reason=modal is mandatory at the sole writer.
func (m model) modalBlockedEventFor(slug string, ls liveSession) session.Event {
	return session.Event{
		Event:         session.EventModalBlocked,
		ActorInstance: session.StrPtr(m.instanceName),
		Slug:          slug,
		SessionType:   ls.typ,
		Initiator:     ls.initiator,
		Reason:        sendReasonModal,
	}
}

// sessionType normalizes a descriptor Type onto the substrate's session_type
// enum, defaulting an unknown value to "spec".
func sessionType(t string) string {
	switch t {
	case work.SessionSpec, work.SessionImplement, work.SessionChat, work.SessionWorker:
		return t
	default:
		return work.SessionSpec
	}
}
