package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

type interruptRequest struct {
	RequestID       string `json:"request_id"`
	Slug            string `json:"slug"`
	TargetInstance  string `json:"target_instance"`
	LaunchRequestID string `json:"launch_request_id"`
	SessionID       string `json:"session_id"`
	Epoch           string `json:"epoch"`
	OwnerPID        int    `json:"owner_pid"`
	OwnerStarted    string `json:"owner_started"`
	SessionPID      int    `json:"session_pid"`
	RequestedAt     string `json:"requested_at"`
	ExpiresAt       string `json:"expires_at"`
}
type interruptScanMsg []interruptRequest

var interruptID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

func scanInterruptRequestsCmd(dir, instance string) tea.Cmd {
	return func() tea.Msg {
		var rows interruptScanMsg
		paths, _ := filepath.Glob(filepath.Join(dir, "interrupt-requests", "*.json"))
		for _, path := range paths {
			b, err := os.ReadFile(path)
			if err != nil {
				continue
			}
			var r interruptRequest
			if json.Unmarshal(b, &r) == nil && interruptID.MatchString(r.RequestID) && filepath.Base(path) == r.RequestID+".json" && r.TargetInstance == instance {
				rows = append(rows, r)
			}
		}
		return rows
	}
}

func interruptGate(r interruptRequest, ls liveSession, instance, ownerStarted string, ownerPID int, framework string, snap work.ScreenSnapshot, now time.Time) string {
	requested, e1 := time.Parse(time.RFC3339Nano, r.RequestedAt)
	expires, e2 := time.Parse(time.RFC3339Nano, r.ExpiresAt)
	if e1 != nil || e2 != nil || requested.After(now.Add(time.Second)) || !expires.After(now) || expires.Sub(requested) <= 0 || expires.Sub(requested) > 15*time.Second {
		return "expired-or-invalid-request"
	}
	if r.TargetInstance != instance || r.OwnerPID <= 0 || r.OwnerPID != ownerPID || r.OwnerStarted == "" || r.OwnerStarted != ownerStarted {
		return "owner-mismatch"
	}
	if r.LaunchRequestID == "" || r.SessionID == "" || r.Epoch == "" || r.SessionPID <= 0 || ls.worktree == nil {
		return "identity-unavailable"
	}
	if ls.requestID != r.LaunchRequestID || ls.sessionID != r.SessionID || ls.worktree.Epoch != r.Epoch || ls.pid != r.SessionPID {
		return "generation-mismatch"
	}
	if _, ok := screenMatchers[framework]; !ok {
		return "unsupported-harness"
	}
	state, _ := classifyScreen(framework, snap)
	if state.interactive || snap.PasswordInput {
		return "modal-owned-input"
	}
	if activeScreenMatcher(framework, snap.Rows) == "" {
		return "no-current-turn"
	}
	return ""
}

type interruptPreparedMsg struct {
	request     interruptRequest
	deliveryKey string
	event       session.Event
}
type interruptConsumedMsg struct {
	requestID string
	err       error
}

// interruptScreenGate reads only the current event-loop-owned session and
// terminal. Persistence must not run between this check and the ESC write.
func (m model) interruptScreenGate(r interruptRequest) (work.SessionPanelModel, string) {
	ls, exists := m.localSessions[r.Slug]
	panel, attached := m.sessionPanels[r.Slug]
	if !exists || !attached || panel.IsDone() || panel.MirrorError() != "" {
		return panel, "session-unavailable"
	}
	snap, err := panel.ScreenState()
	if err != nil {
		return panel, "screen-unavailable"
	}
	return panel, interruptGate(r, ls, m.instanceName, m.instanceStartedISO, os.Getpid(), m.sessionHarness(r.Slug), snap, time.Now())
}

func (m model) handleInterruptScan(rows interruptScanMsg) (model, tea.Cmd) {
	if m.pendingInterrupt == nil {
		m.pendingInterrupt = make(map[string]bool)
	}
	var cmds []tea.Cmd
	for _, r := range rows {
		if _, pending := m.pendingInterrupt[r.RequestID]; pending {
			continue
		}
		m.pendingInterrupt[r.RequestID] = true
		_, reason := m.interruptScreenGate(r)
		delivery := m
		if delivery.hostKey == "" {
			delivery.hostKey = "interrupt-" + m.instanceName
		}
		ev := session.Event{Event: session.EventInterruptRefused, RequestID: r.RequestID, Slug: r.Slug, ActorInstance: session.StrPtr(m.instanceName), Reason: reason, Links: map[string]string{"session_id": r.SessionID, "launch_request_id": r.LaunchRequestID, "epoch": r.Epoch}}
		cmds = append(cmds, delivery.prepareInterruptCmd(r, ev))
	}
	return m, tea.Batch(cmds...)
}

// The command owns all blocking reads, fsync and journal work. While it runs,
// Update remains free to process terminal paints and lifecycle transitions.
func (m model) prepareInterruptCmd(r interruptRequest, ev session.Event) tea.Cmd {
	return func() tea.Msg {
		path := m.hostDeliveryPath(r.RequestID)
		if b, err := os.ReadFile(path); err == nil {
			var d hostDelivery
			if err = json.Unmarshal(b, &d); err == nil {
				err = m.finishHostDelivery(d)
			}
			return interruptConsumedMsg{r.RequestID, err}
		} else if !os.IsNotExist(err) {
			return interruptConsumedMsg{r.RequestID, err}
		}
		if ev.Reason != "" {
			return m.finishInterruptCmd(ev)()
		}
		ev.Event = session.EventInterruptUncertain
		ev.Reason = "delivery-uncertain"
		// The durable record prohibits a second ESC even if this process exits
		// before the prepared message is handled or its outcome can be published.
		if err := m.hostDeliveryAttempt("interrupt", ev); err != nil {
			return interruptConsumedMsg{r.RequestID, err}
		}
		attempt := ev
		attempt.Event = session.EventInterruptAttempted
		attempt.EventID = "interrupt-attempt-" + r.RequestID
		if err := session.AppendEvent(m.eventScript, m.config.KnowledgeDir, attempt); err != nil {
			return interruptConsumedMsg{r.RequestID, err}
		}
		return interruptPreparedMsg{request: r, deliveryKey: m.hostKey, event: ev}
	}
}

func (m model) handleInterruptPrepared(msg interruptPreparedMsg) (model, tea.Cmd) {
	if !m.pendingInterrupt[msg.request.RequestID] {
		return m, nil
	}
	m.pendingInterrupt[msg.request.RequestID] = false
	panel, reason := m.interruptScreenGate(msg.request)
	ev := msg.event
	if reason != "" {
		ev.Event = session.EventInterruptRefused
		ev.Reason = reason
	} else {
		err := panel.Interrupt()
		ev.Links["transport_attempted"] = "true"
		if err != nil {
			ev.Links["transport_error"] = fmt.Sprint(err)
		} else {
			ev.Links["escape_written"] = "true"
		}
	}
	delivery := m
	delivery.hostKey = msg.deliveryKey
	return m, delivery.finishInterruptCmd(ev)
}

func (m model) finishInterruptCmd(ev session.Event) tea.Cmd {
	return func() tea.Msg {
		ev.EventID = "host-delivery-" + m.hostKey + "-" + ev.RequestID
		d := hostDelivery{Kind: "interrupt", Event: ev, Terminal: true}
		err := hostAtomicJSON(m.hostDeliveryPath(ev.RequestID), d)
		if err == nil {
			err = m.finishHostDelivery(d)
		}
		return interruptConsumedMsg{ev.RequestID, err}
	}
}

func (m model) handleInterruptConsumed(msg interruptConsumedMsg) (model, tea.Cmd) {
	delete(m.pendingInterrupt, msg.requestID)
	if msg.err != nil {
		m.flashErr = compactErr("interrupt receipt", msg.err)
	}
	return m, nil
}
