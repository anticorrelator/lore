package main

import (
	"os/exec"
	"regexp"
	"syscall"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/sessionview"
)

// derivedWorkerRe matches a derived-slug worker session <base>--w<n>. slugify
// collapses any "--" run to one "-", so a real work-item slug can never contain
// "--" — making this parse unambiguous and authoritative for grouping workers
// under their base item without consulting the journal's links.work_item stamp.
var derivedWorkerRe = regexp.MustCompile(`^(.+)--w\d+$`)

// deriveBase returns the base work item for a derived-slug worker, or "" for any
// other slug (a standalone session groups nowhere).
func deriveBase(slug string) string {
	if m := derivedWorkerRe.FindStringSubmatch(slug); m != nil {
		return m[1]
	}
	return ""
}

// sessionsRefreshedMsg carries one substrate-union read: the registry snapshot
// (existence/identity), the request queue (in-flight spawns), and the journal
// delta since the last cursor (activity overlay).
type sessionsRefreshedMsg struct {
	instances     []session.Instance
	pending       []session.Request
	claimed       []session.ClaimedRow
	events        []session.Event
	journalCursor int64
}

// sessionCloseRequestedMsg reports the outcome of enqueuing a close request via
// the existing producer (lore session close).
type sessionCloseRequestedMsg struct {
	err error
}

// sessionsRefreshCmd reads the three sessions substrates off the UI thread and
// returns them as one message. It is the only I/O the sessions view performs;
// the union assembly and the journal fold happen in the pure handler. The
// journal is read from the stored byte cursor forward, so a growing events.jsonl
// costs one incremental read per tick, not a full re-scan.
func (m model) sessionsRefreshCmd() tea.Cmd {
	dir := m.sessionsDir
	cursor := m.sessionsJournalCursor
	return func() tea.Msg {
		events, next := session.ReadEventsFrom(dir, cursor)
		return sessionsRefreshedMsg{
			instances:     session.ListInstances(dir),
			pending:       session.ScanPending(dir),
			claimed:       session.ScanClaimed(dir),
			events:        events,
			journalCursor: next,
		}
	}
}

// handleSessionsRefreshed folds the journal delta into the activity overlay,
// assembles the substrate union into list rows, and updates the tab-indicator
// count. It re-syncs the detail card only while the sessions view is active.
func (m model) handleSessionsRefreshed(msg sessionsRefreshedMsg) (model, tea.Cmd) {
	m.sessionActivity = sessionview.FoldEvents(m.sessionActivity, msg.events)
	m.sessionsJournalCursor = msg.journalCursor

	m.sessionsList.SetSessions(m.buildSessionRows(msg.instances, msg.pending, msg.claimed))
	m.sessionsCount = m.sessionsList.Count()
	m.sessionsNeedsInput = m.sessionsList.NeedsInputCount()

	if m.state == stateSessions {
		m.loadSessionsDetail(m.sessionsList.CurrentKey())
	}
	return m, nil
}

// buildSessionRows assembles the three-substrate union into list rows: the
// registry snapshot supplies every existing session (local + cross-instance),
// the request queue supplies in-flight spawns, and the folded journal overlay
// supplies the needs-input / close-pending activity the registry cannot carry.
// A queued row whose slug is already live in the registry is dropped (the
// claim→spawn→registry-write window can briefly show a slug in both surfaces).
func (m model) buildSessionRows(instances []session.Instance, pending []session.Request, claimed []session.ClaimedRow) []sessionview.SessionRow {
	var rows []sessionview.SessionRow
	liveSlugs := map[string]bool{}

	for _, inst := range instances {
		local := inst.Name == m.instanceName
		for _, s := range inst.Sessions {
			if s.Slug != "" {
				liveSlugs[s.Slug] = true
			}
			act := m.sessionActivity[sessionview.ActivityKey{Instance: inst.Name, Slug: s.Slug}]
			display := s.Slug
			if display == "" {
				display = sessionview.ChatDisplayID(s.SessionID)
			}
			rows = append(rows, sessionview.SessionRow{
				RowID:        inst.Name + "|" + s.Slug + "|" + s.SessionID,
				PanelKey:     s.Slug,
				Slug:         s.Slug,
				Display:      display,
				Type:         s.Type,
				Initiator:    s.Initiator,
				Instance:     inst.Name,
				Local:        local,
				SessionID:    s.SessionID,
				BaseItem:     deriveBase(s.Slug),
				NeedsInput:   act.NeedsInput,
				Quiescent:    act.Quiescent,
				ClosePending: act.ClosePending,
				Started:      s.Started,
			})
		}
	}

	inflight := func(req session.Request, owner string) {
		slug := req.SlugValue()
		if slug != "" && liveSlugs[slug] {
			return // already live in the registry; not still spawning
		}
		display := slug
		if display == "" {
			display = "chat:? (spawning)"
		}
		rows = append(rows, sessionview.SessionRow{
			RowID:     "inflight|" + req.RequestID,
			Slug:      slug,
			Display:   display,
			Type:      req.Type,
			Initiator: req.Initiator,
			Instance:  owner,
			InFlight:  true,
			BaseItem:  deriveBase(slug),
		})
	}
	for _, req := range pending {
		inflight(req, req.TargetValue())
	}
	for _, row := range claimed {
		owner := row.Request.TargetValue()
		if row.Request.ClaimedBy != nil && *row.Request.ClaimedBy != "" {
			owner = *row.Request.ClaimedBy
		}
		inflight(row.Request, owner)
	}
	return rows
}

// handleSessionSelected attaches the selected session: a locally-hosted row
// enters terminal focus on its live panel; an external or in-flight row focuses
// the read-only card.
func (m model) handleSessionSelected(msg sessionview.SessionSelectedMsg) (model, tea.Cmd) {
	row, ok := m.sessionsList.SessionByID(msg.RowID)
	if !ok {
		return m, nil
	}
	m.focusedPanel = panelRight
	m.sessionsDetail.SetSession(row, true)
	if row.Local && m.hasSessionPanel(row.PanelKey) {
		m.setPreferDetail(row.PanelKey, false)
		m.terminalMode = true
	} else {
		m.terminalMode = false
	}
	return m, nil
}

// openSessionCloseConfirm opens the confirmation modal for closing the session
// under the cursor. Addressing mirrors the CLI producer: a slugged session
// closes by slug, a slugless one by its session_id short form; a row with
// neither cannot be addressed and is refused rather than closed blindly. An
// in-flight spawn has no live session to close (cancel is a separate verb).
func (m model) openSessionCloseConfirm() (model, tea.Cmd) {
	row, ok := m.sessionsList.CurrentSession()
	if !ok {
		return m, nil
	}
	if row.InFlight {
		m.flashErr = "cannot close a spawning session — wait for it to start"
		return m, nil
	}
	if row.Slug == "" && row.SessionID == "" {
		m.flashErr = "cannot close: session has no slug or id to address"
		return m, nil
	}
	m.confirmAction = "close_session"
	m.confirmSlug = row.Slug
	m.confirmSessionID = row.SessionID
	m.confirmTitle = row.Display
	return m, nil
}

// runSessionClose enqueues a close request through the existing producer (lore
// session close), which resolves the owning instance, writes the close-request
// row, and journals close_requested — the same path the CLI uses, so this pass
// adds no new writer. A slugged session is addressed by slug; a slugless one by
// --session <id>. The owning instance's poll consumes the row and tears down.
func runSessionClose(slug, sessionID, requestedBy string) tea.Cmd {
	return func() tea.Msg {
		args := []string{"session", "close"}
		if slug != "" {
			args = append(args, slug)
		} else {
			args = append(args, "--session", sessionID)
		}
		args = append(args, "--reason", "human")
		if requestedBy != "" {
			args = append(args, "--requested-by", requestedBy)
		}
		cmd := exec.Command("lore", args...)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		err := cmd.Run()
		return sessionCloseRequestedMsg{err: err}
	}
}

// handleSessionCloseRequested surfaces a failed enqueue and refreshes the view so
// the close-pending badge appears once the journal records close_requested.
func (m model) handleSessionCloseRequested(msg sessionCloseRequestedMsg) (model, tea.Cmd) {
	if msg.err != nil {
		m.flashErr = compactErr("session close", msg.err)
		return m, nil
	}
	return m, m.sessionsRefreshCmd()
}
