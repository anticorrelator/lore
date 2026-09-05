package main

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/anticorrelator/lore/tui/internal/worktree"
	"os"
	"path/filepath"
	"sort"

	tea "charm.land/bubbletea/v2"
	"github.com/anticorrelator/lore/tui/internal/session"
)

// Kept after completion: this is durable proof that replay is forbidden, even
// when a producer died before publishing its queue row.
type hostDelivery struct {
	Completion *hostDelivery      `json:"completion,omitempty"`
	ID         string             `json:"id,omitempty"`
	Cleanup    *worktree.Identity `json:"cleanup,omitempty"`
	Kind       string             `json:"kind"`
	Event      session.Event      `json:"event"`
	Terminal   bool               `json:"terminal"`
	Committed  bool               `json:"committed,omitempty"`
}

func (m model) hostDeliveryPath(id string) string {
	return filepath.Join(m.sessionsDir, "hosts", m.hostKey, "deliveries", id+".json")
}
func (m model) hostDeliveryAttempt(kind string, ev session.Event) error {
	if m.hostKey == "" {
		return nil
	}
	if _, err := os.Stat(m.hostDeliveryPath(ev.RequestID)); err == nil {
		return fmt.Errorf("delivery already attempted: %s", ev.RequestID)
	} else if !os.IsNotExist(err) {
		return err
	}
	ev.EventID = "host-delivery-" + m.hostKey + "-" + ev.RequestID
	return hostAtomicJSON(m.hostDeliveryPath(ev.RequestID), hostDelivery{Kind: kind, Event: ev})
}
func (m model) hostDeliveryTerminalCmd(kind string, ev session.Event) tea.Cmd {
	ev.EventID = "host-delivery-" + m.hostKey + "-" + ev.RequestID
	return func() tea.Msg {
		err := hostAtomicJSON(m.hostDeliveryPath(ev.RequestID), hostDelivery{Kind: kind, Event: ev, Terminal: true})
		if err == nil {
			err = m.finishHostDelivery(hostDelivery{Kind: kind, Event: ev, Terminal: true})
		}
		if kind == "send" {
			return sendConsumedMsg{requestID: ev.RequestID, err: err}
		}
		return answerConsumedMsg{requestID: ev.RequestID, err: err}
	}
}
func (m model) finishHostDelivery(d hostDelivery) error {
	// The writer deduplicates event_id. Journal before deletion so every crash
	// boundary has either a pending request or a recoverable terminal record.
	if !d.Committed {
		if err := session.AppendEvent(m.eventScript, m.config.KnowledgeDir, d.Event); err != nil {
			return err
		}
	}
	var err error
	if d.Kind == "send" {
		err = session.DeleteSendRequest(m.sessionsDir, d.Event.RequestID)
	} else if d.Kind == "answer" {
		err = session.DeleteAnswerRequest(m.sessionsDir, d.Event.RequestID)
	} else if d.Kind == "close" {
		var ids []string
		if raw := d.Event.Links["close_requests"]; raw != "" {
			if err = json.Unmarshal([]byte(raw), &ids); err != nil {
				return err
			}
		}
		if d.Event.RequestID != "" {
			ids = append(ids, d.Event.RequestID)
		}
		for _, id := range ids {
			if err = session.DeleteCloseRequest(m.sessionsDir, id); err != nil {
				return err
			}
		}
	} else if d.Kind != "worktree" {
		return fmt.Errorf("unknown host delivery kind %q", d.Kind)
	}
	if err != nil {
		return err
	}
	d.Terminal = true
	d.Committed = true
	id := d.ID
	if id == "" {
		id = d.Event.RequestID
	}
	return hostAtomicJSON(m.hostDeliveryPath(id), d)
}
func (m model) recoverHostDeliveries() error {
	paths, err := filepath.Glob(filepath.Join(m.sessionsDir, "hosts", m.hostKey, "deliveries", "*.json"))
	if err != nil {
		return err
	}
	var rows []hostDelivery
	for _, path := range paths {
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		var d hostDelivery
		if err = json.Unmarshal(b, &d); err != nil {
			return err
		}
		rows = append(rows, d)
	}
	// The outcome and its close continuation are one durable transaction.
	// A crash before the separate close record exists must still finish close.
	for _, d := range rows {
		if d.Kind == "worktree" && d.Completion != nil {
			next := *d.Completion
			id := next.ID
			if id == "" {
				id = next.Event.RequestID
			}
			if _, err := os.Stat(m.hostDeliveryPath(id)); os.IsNotExist(err) {
				if err = hostAtomicJSON(m.hostDeliveryPath(id), next); err != nil {
					return err
				}
				rows = append(rows, next)
			} else if err != nil {
				return err
			}
		}
	}
	// Publication/quarantine is visible before any terminal referring to it.
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].Kind == "worktree" && rows[j].Kind != "worktree" })
	for _, d := range rows {
		if err = m.finishHostDelivery(d); err != nil {
			return err
		}
	}
	for _, d := range rows {
		if d.Kind == "close" && d.Cleanup != nil {
			receiptPath := filepath.Join(m.sessionsDir, "hosts", m.hostKey, "cleanup", d.Event.Slug+".json")
			if b, err := os.ReadFile(receiptPath); err == nil {
				var receipt struct {
					Epoch   string                `json:"epoch"`
					Cleaned bool                  `json:"cleaned"`
					Proof   worktree.CleanupProof `json:"proof"`
				}
				if err = json.Unmarshal(b, &receipt); err != nil {
					return err
				}
				if receipt.Epoch == d.Cleanup.Epoch && receipt.Cleaned && receipt.Proof.Verified {
					continue
				}
			} else if !os.IsNotExist(err) {
				return err
			}
			proof, err := worktree.CleanupSessionCheckout(context.Background(), *d.Cleanup)
			if err != nil {
				return err
			}
			if err = hostAtomicJSON(filepath.Join(m.sessionsDir, "hosts", m.hostKey, "cleanup", d.Event.Slug+".json"), map[string]any{"schema_version": 1, "slug": d.Event.Slug, "epoch": d.Cleanup.Epoch, "proof": proof, "cleaned": true}); err != nil {
				return err
			}
		}
	}
	return nil
}

func (m model) hostWorktreeOutcome(outcome session.Event, epoch string, completion ...hostDelivery) (tea.Cmd, error) {
	id := "outcome-" + epoch
	outcome.EventID = "host-outcome-" + m.hostKey + "-" + epoch
	d := hostDelivery{ID: id, Kind: "worktree", Event: outcome, Terminal: true}
	if len(completion) > 0 {
		d.Completion = &completion[0]
	}
	if err := hostAtomicJSON(m.hostDeliveryPath(id), d); err != nil {
		return nil, err
	}
	return func() tea.Msg { return journalResultMsg{err: m.finishHostDelivery(d)} }, nil
}

func (m model) hostClosedSlugs() (map[string]bool, error) {
	out := map[string]bool{}
	paths, err := filepath.Glob(filepath.Join(m.sessionsDir, "hosts", m.hostKey, "deliveries", "*.json"))
	if err != nil {
		return nil, err
	}
	for _, path := range paths {
		b, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		var d hostDelivery
		if err = json.Unmarshal(b, &d); err != nil {
			return nil, err
		}
		if d.Kind == "close" && d.Terminal {
			out[d.Event.Slug] = true
		}
	}
	return out, nil
}

// A producer may republish the same row after losing its own acknowledgement.
// Existing evidence wins; never replace it with a new refusal or reinject.
func (m model) existingHostDelivery(id string) (tea.Cmd, bool) {
	if m.hostKey == "" {
		return nil, false
	}
	b, err := os.ReadFile(m.hostDeliveryPath(id))
	if os.IsNotExist(err) {
		return nil, false
	}
	return func() tea.Msg {
		var d hostDelivery
		if err == nil {
			err = json.Unmarshal(b, &d)
		}
		if err == nil {
			err = m.finishHostDelivery(d)
		}
		return journalResultMsg{err: err}
	}, true
}

func (m model) hostCloseDelivery(slug string, ls liveSession, closeRequestID string) hostDelivery {
	ev := m.closedEventFor(slug, ls)
	if closeRequestID != "" {
		ev.RequestID = closeRequestID
	}
	id := ev.RequestID
	ev.EventID = "host-close-" + m.hostKey + "-" + id
	d := hostDelivery{ID: id, Kind: "close", Event: ev, Terminal: true}
	if ls.worktreeID == "" && ls.worktree != nil && ls.worktree.CleanupEligible() {
		d.Cleanup = cloneWorktreeIdentity(ls.worktree)
	}
	return d
}
