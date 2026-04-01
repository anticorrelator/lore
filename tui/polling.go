package main

import (
	"errors"
	"os"
	"path/filepath"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/anticorrelator/lore/tui/internal/followup"
	"github.com/anticorrelator/lore/tui/internal/work"
)

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

// followupIndexMtimeCheckedMsg carries the result of stat-ing _followup_index.json.
type followupIndexMtimeCheckedMsg struct {
	mtime time.Time
	err   error
}

// checkFollowupIndexMtime stats _followup_index.json and sends followupIndexMtimeCheckedMsg.
func checkFollowupIndexMtime(knowledgeDir string) tea.Cmd {
	return func() tea.Msg {
		p := filepath.Join(knowledgeDir, "_followup_index.json")
		info, err := os.Stat(p)
		if err != nil {
			return followupIndexMtimeCheckedMsg{err: err}
		}
		return followupIndexMtimeCheckedMsg{mtime: info.ModTime()}
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

// handleIndexPollTick handles the periodic poll tick: schedules mtime checks, touches
// session files for active spec panels, and kicks off a new tick.
func (m model) handleIndexPollTick() (model, tea.Cmd) {
	cmds := []tea.Cmd{checkIndexMtime(m.indexPath), indexPollTick()}
	// Poll plan.md and detail files for the current item on every tick.
	if slug := m.list.CurrentSlug(); slug != "" {
		cmds = append(cmds, checkPlanMtime(m.config.WorkDir, slug))
		cmds = append(cmds, checkDetailMtime(m.config.WorkDir, slug))
	}
	// Poll follow-up index when in stateFollowUps to detect CLI mutations.
	if m.state == stateFollowUps {
		cmds = append(cmds, checkFollowupIndexMtime(m.config.KnowledgeDir))
	}
	// Touch session files for locally active slugs and discover external sessions.
	for slug := range m.specPanels {
		work.TouchSession(m.config.WorkDir, slug) //nolint:errcheck
	}
	cmds = append(cmds, listActiveSessions(m.config.WorkDir))
	return m, tea.Batch(cmds...)
}

// handleIndexMtimeChecked compares the new index mtime against the last known value
// and triggers a work-item reload when the file has changed.
func (m model) handleIndexMtimeChecked(msg indexMtimeCheckedMsg) (model, tea.Cmd) {
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
}

// handleFollowupIndexMtimeChecked compares the follow-up index mtime and reloads
// the follow-up index when the file has changed.
func (m model) handleFollowupIndexMtimeChecked(msg followupIndexMtimeCheckedMsg) (model, tea.Cmd) {
	if msg.err != nil {
		return m, nil // index may not exist yet; skip
	}
	if m.lastFollowupIndexMtime.IsZero() {
		m.lastFollowupIndexMtime = msg.mtime // baseline
		return m, nil
	}
	if !msg.mtime.Equal(m.lastFollowupIndexMtime) {
		m.lastFollowupIndexMtime = msg.mtime
		return m, followup.LoadIndexCmd(m.config.KnowledgeDir)
	}
	return m, nil
}

// handleActiveSessionsChecked filters out locally owned sessions and updates
// the list and detail views with external session state.
func (m model) handleActiveSessionsChecked(msg activeSessionsCheckedMsg) (model, tea.Cmd) {
	// Filter out locally owned sessions — only external ones matter for the indicator.
	external := make(map[string]bool)
	myPID := os.Getpid()
	for slug, info := range msg.sessions {
		if info.PID != myPID {
			external[slug] = true
		}
	}
	m.list, _ = m.list.Update(work.ExternalSessionMsg{Slugs: external})
	// Tell the detail view whether the currently displayed slug has an external session.
	currentSlug := m.list.CurrentSlug()
	m.detail, _ = m.detail.Update(work.DetailExternalSessionMsg{Active: external[currentSlug]})
	return m, nil
}

// handlePlanMtimeChecked compares plan.md mtime and triggers a content read when changed.
func (m model) handlePlanMtimeChecked(msg planMtimeCheckedMsg) (model, tea.Cmd) {
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
}

// handlePlanContentRead pushes freshly-read plan.md content into the detail view.
func (m model) handlePlanContentRead(msg planContentReadMsg) (model, tea.Cmd) {
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
}

// handleDetailMtimeChecked compares the detail file mtime and triggers a full detail
// reload when any of the tracked files have changed.
func (m model) handleDetailMtimeChecked(msg detailMtimeCheckedMsg) (model, tea.Cmd) {
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
}
