package main

import (
	tea "charm.land/bubbletea/v2"
	"encoding/json"
	"fmt"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
	"os"
	"path/filepath"
	"regexp"
	"time"
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

// The durable delivery record fences every ESC attempt across scans and host
// recovery. Successful transport remains uncertain: it cannot prove a turn ended.
func (m model) handleInterruptScan(rows interruptScanMsg) (model, tea.Cmd) {
	for _, r := range rows {
		delivery := m
		if delivery.hostKey == "" {
			delivery.hostKey = "interrupt-" + m.instanceName
		}
		path := delivery.hostDeliveryPath(r.RequestID)
		if b, err := os.ReadFile(path); err == nil {
			var d hostDelivery
			if json.Unmarshal(b, &d) == nil {
				if err = delivery.finishHostDelivery(d); err != nil {
					m.flashErr = compactErr("interrupt receipt", err)
				}
			}
			continue
		} else if !os.IsNotExist(err) {
			m.flashErr = compactErr("interrupt receipt", err)
			continue
		}
		ev := session.Event{Event: session.EventInterruptRefused, RequestID: r.RequestID, Slug: r.Slug, ActorInstance: session.StrPtr(m.instanceName), Links: map[string]string{"session_id": r.SessionID, "launch_request_id": r.LaunchRequestID, "epoch": r.Epoch}}
		reason := "session-unavailable"
		ls, exists := m.localSessions[r.Slug]
		panel, attached := m.sessionPanels[r.Slug]
		if exists && attached && !panel.IsDone() && panel.MirrorError() == "" {
			if snap, err := panel.ScreenState(); err == nil {
				reason = interruptGate(r, ls, m.instanceName, m.instanceStartedISO, os.Getpid(), m.sessionHarness(r.Slug), snap, time.Now())
			}
		}
		ev.Reason = reason
		if reason == "" {
			ev.Event = session.EventInterruptUncertain
			ev.Reason = "delivery-uncertain"
			if err := delivery.hostDeliveryAttempt("interrupt", ev); err != nil {
				m.flashErr = compactErr("persist interrupt attempt", err)
				continue
			}
			// Persist attempted before touching the terminal. Recheck immediately after
			// persistence because the filesystem/journal can block while the turn moves.
			attempt := ev
			attempt.Event = session.EventInterruptAttempted
			attempt.EventID = "interrupt-attempt-" + r.RequestID
			if err := session.AppendEvent(m.eventScript, m.config.KnowledgeDir, attempt); err != nil {
				m.flashErr = compactErr("interrupt attempt", err)
				continue
			}
			snap, err := panel.ScreenState()
			if err != nil {
				ev.Event = session.EventInterruptRefused
				ev.Reason = "screen-unavailable"
			} else if reason = interruptGate(r, ls, m.instanceName, m.instanceStartedISO, os.Getpid(), m.sessionHarness(r.Slug), snap, time.Now()); reason != "" {
				ev.Event = session.EventInterruptRefused
				ev.Reason = reason
			} else {
				err = panel.Interrupt()
				ev.Links["transport_attempted"] = "true"
				if err != nil {
					ev.Links["transport_error"] = fmt.Sprint(err)
				} else {
					ev.Links["escape_written"] = "true"
				}
			}
		}
		ev.EventID = "host-delivery-" + delivery.hostKey + "-" + r.RequestID
		d := hostDelivery{Kind: "interrupt", Event: ev, Terminal: true}
		if err := hostAtomicJSON(path, d); err != nil {
			m.flashErr = compactErr("interrupt outcome", err)
			continue
		}
		if err := delivery.finishHostDelivery(d); err != nil {
			m.flashErr = compactErr("interrupt outcome", err)
		}
	}
	return m, nil
}
