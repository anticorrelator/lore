package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	tea "charm.land/bubbletea/v2"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
	"github.com/charmbracelet/x/ansi"
)

const historyTTL = 2 * time.Minute
const historySnapshotBytes = 2 * 1024 * 1024
const historyCacheBytes = 8 * 1024 * 1024
const historySnapshotRows = 5000

type peekHistorySnapshot struct {
	id, slug, generation string
	captured             time.Time
	capture              work.HistoryCapture
	bytes                int
}
type peekHistoryCache struct {
	snapshots map[string]*peekHistorySnapshot
	key       [32]byte
}
type peekHistoryCapturedMsg struct {
	request    session.PeekRequest
	generation string
	captured   time.Time
	capture    work.HistoryCapture
	err        error
}

func randomHistoryID() string {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(id[:])
}
func newPeekHistoryCache() *peekHistoryCache {
	c := &peekHistoryCache{snapshots: map[string]*peekHistorySnapshot{}}
	if _, err := rand.Read(c.key[:]); err != nil {
		panic(err)
	}
	return c
}
func (c *peekHistoryCache) expire(now time.Time) {
	for id, s := range c.snapshots {
		if !now.Before(s.captured.Add(historyTTL)) {
			delete(c.snapshots, id)
		}
	}
}
func (c *peekHistoryCache) add(slug, generation string, capture work.HistoryCapture, now time.Time) *peekHistorySnapshot {
	c.expire(now)
	rows := []string{}
	size := 0
	for i := len(capture.Rows) - 1; i >= 0 && len(rows) < historySnapshotRows; i-- {
		if size+len(capture.Rows[i])+1 > historySnapshotBytes {
			break
		}
		rows = append(rows, strings.Clone(capture.Rows[i]))
		size += len(capture.Rows[i]) + 1
	}
	if len(rows) < len(capture.Rows) {
		capture.Truncated = true
	}
	for i, j := 0, len(rows)-1; i < j; i, j = i+1, j-1 {
		rows[i], rows[j] = rows[j], rows[i]
	}
	capture.Rows = rows
	snapshot := &peekHistorySnapshot{id: randomHistoryID(), slug: slug, generation: generation, captured: now, capture: capture}
	for _, row := range capture.Rows {
		snapshot.bytes += len(row) + 1
	}
	for {
		total := snapshot.bytes
		var oldest *peekHistorySnapshot
		for _, s := range c.snapshots {
			total += s.bytes
			if oldest == nil || s.captured.Before(oldest.captured) {
				oldest = s
			}
		}
		if len(c.snapshots) < 8 && total <= historyCacheBytes {
			break
		}
		if oldest == nil {
			break
		}
		delete(c.snapshots, oldest.id)
	}
	c.snapshots[snapshot.id] = snapshot
	return snapshot
}
func (c *peekHistoryCache) cursor(id string, end int) string {
	payload := id + ":" + strconv.Itoa(end)
	mac := hmac.New(sha256.New, c.key[:])
	mac.Write([]byte(payload))
	return base64.RawURLEncoding.EncodeToString([]byte(payload + ":" + hex.EncodeToString(mac.Sum(nil))))
}
func (c *peekHistoryCache) resolve(cursor, slug, generation string, now time.Time) (*peekHistorySnapshot, int, string) {
	c.expire(now)
	raw, err := base64.RawURLEncoding.DecodeString(cursor)
	if err != nil {
		return nil, 0, "history-invalid-cursor"
	}
	parts := strings.Split(string(raw), ":")
	if len(parts) != 3 {
		return nil, 0, "history-invalid-cursor"
	}
	end, err := strconv.Atoi(parts[1])
	if err != nil {
		return nil, 0, "history-invalid-cursor"
	}
	if !hmac.Equal([]byte(cursor), []byte(c.cursor(parts[0], end))) {
		return nil, 0, "history-cursor-expired-or-unavailable"
	}
	s := c.snapshots[parts[0]]
	if s == nil {
		return nil, 0, "history-cursor-expired-or-unavailable"
	}
	if s.slug != slug || s.generation != generation {
		return nil, 0, "history-cursor-session-mismatch"
	}
	if end < 0 || end > len(s.capture.Rows) {
		return nil, 0, "history-invalid-cursor"
	}
	return s, end, ""
}
func historyRequestLimits(pr session.PeekRequest) (int, int, string) {
	if pr.Summary && (pr.Raw || pr.Lines != 0 || pr.Before != "" || pr.MaxBytes != 0) {
		return 0, 0, "summary-incompatible-options"
	}
	lines := pr.Lines
	if lines == 0 {
		lines = 100
	}
	budget := pr.MaxBytes
	if budget == 0 {
		budget = 4096
	}
	if lines < 1 || lines > 500 || budget < 1 || budget > 16384 {
		return 0, 0, "history-invalid-limit"
	}
	return lines, budget, ""
}
func prefixUTF8(text string, limit int) string {
	if limit >= len(text) {
		return text
	}
	if limit < 0 {
		limit = 0
	}
	for limit > 0 && !utf8.RuneStart(text[limit]) {
		limit--
	}
	return text[:limit]
}
func (c *peekHistoryCache) page(s *peekHistorySnapshot, end, lines, budget int, raw bool) *session.PeekHistory {
	page := &session.PeekHistory{Source: s.capture.Source, ScreenBuffer: s.capture.ScreenBuffer, SnapshotID: s.id, CapturedAt: s.captured.UTC().Format(time.RFC3339Nano), ExpiresAt: s.captured.Add(historyTTL).UTC().Format(time.RFC3339Nano), Generation: s.generation, RetainedRows: s.capture.RetainedRows, SnapshotRows: len(s.capture.Rows), Start: end, End: end, ByteLimit: budget, Available: true, RetentionTruncated: s.capture.Truncated, Limitation: "Retained display rows, not a complete transcript; overwritten and alternate-screen history may be unavailable.", Rows: []string{}}
	if s.capture.ScreenBuffer == "alternate" {
		page.Limitation = "Alternate screen: retained active display only; primary-screen history is not included."
	}
	styled := []string{}
	for i := end - 1; i >= 0 && len(page.Rows) < lines; i-- {
		plain := ansi.Strip(s.capture.Rows[i])
		style := s.capture.Rows[i]
		cost := len(plain) + 1
		if raw {
			cost += len(style) + 1
		}
		if cost > budget-page.Bytes {
			if len(page.Rows) > 0 {
				break
			}
			limit := budget - 1
			if raw {
				limit = (budget - 2) / 2
			}
			if limit < 0 {
				limit = 0
			}
			plain = prefixUTF8(plain, limit)
			style = plain
			cost = len(plain) + 1
			if raw {
				cost += len(style) + 1
			}
			if cost > budget {
				cost = 0
				plain = ""
				style = ""
			}
			page.RowTruncated = true
		}
		page.Rows = append([]string{plain}, page.Rows...)
		styled = append([]string{style}, styled...)
		page.Start = i
		page.Bytes += cost
		if page.RowTruncated {
			break
		}
	}
	if raw {
		page.ANSI = strings.Join(styled, "\n")
	}
	page.More = page.Start > 0
	page.Truncated = page.More || page.RowTruncated || page.RetentionTruncated
	if page.More {
		page.NextCursor = c.cursor(s.id, page.Start)
	}
	if page.RowTruncated {
		page.Limitation += " An oversized row was clipped; its omitted suffix is not available through the older-page cursor."
	}
	return page
}
func (m model) handleExtendedPeek(pr session.PeekRequest) (model, tea.Cmd) {
	lines, budget, invalid := historyRequestLimits(pr)
	resp := m.peekSnapshot(pr.Slug, pr.RequestID, false)
	if invalid != "" {
		resp.Error = invalid
		return m, respondPeekCmd(m.sessionsDir, pr.RequestID, resp)
	}
	if pr.Summary {
		resp.Summary = true
		return m, respondPeekCmd(m.sessionsDir, pr.RequestID, resp)
	}
	if m.peekHistory == nil {
		m.peekHistory = newPeekHistoryCache()
	}
	now := time.Now()
	m.peekHistory.expire(now)
	generation := resp.Observation.Generation
	if pr.Before != "" {
		snapshot, end, err := m.peekHistory.resolve(pr.Before, pr.Slug, generation, now)
		if err != "" {
			resp.Error = err
		} else {
			resp.History = m.peekHistory.page(snapshot, end, lines, budget, pr.Raw)
		}
		return m, respondPeekCmd(m.sessionsDir, pr.RequestID, resp)
	}
	if m.peekHistoryPending >= 2 {
		resp.Error = "history-busy"
		return m, respondPeekCmd(m.sessionsDir, pr.RequestID, resp)
	}
	if tmuxName := m.localSessions[pr.Slug].tmuxName; tmuxName != "" {
		m.peekHistoryPending++
		return m, func() tea.Msg {
			capture, err := work.CaptureTmuxHistory(tmuxName, historySnapshotRows, historySnapshotBytes)
			return peekHistoryCapturedMsg{request: pr, generation: generation, captured: time.Now(), capture: capture, err: err}
		}
	}
	capture, err := m.sessionPanels[pr.Slug].HistorySnapshot(historySnapshotRows, historySnapshotBytes)
	return m.finishPeekHistory(pr, generation, now, capture, err)
}
func (m model) handlePeekHistoryCaptured(msg peekHistoryCapturedMsg) (model, tea.Cmd) {
	if m.peekHistoryPending > 0 {
		m.peekHistoryPending--
	}
	return m.finishPeekHistory(msg.request, msg.generation, msg.captured, msg.capture, msg.err)
}
func (m model) finishPeekHistory(pr session.PeekRequest, generation string, captured time.Time, capture work.HistoryCapture, err error) (model, tea.Cmd) {
	resp := m.peekSnapshot(pr.Slug, pr.RequestID, false)
	if err != nil {
		resp.Error = "history-unavailable"
		resp.History = &session.PeekHistory{Source: capture.Source, Available: false, Limitation: fmt.Sprint(err)}
	} else if _, ok := m.localSessions[pr.Slug]; !ok || resp.Observation.Generation != generation {
		resp.Error = "history-session-changed"
	} else {
		if m.peekHistory == nil {
			m.peekHistory = newPeekHistoryCache()
		}
		snapshot := m.peekHistory.add(pr.Slug, generation, capture, captured)
		lines, budget, _ := historyRequestLimits(pr)
		resp.History = m.peekHistory.page(snapshot, len(snapshot.capture.Rows), lines, budget, pr.Raw)
	}
	return m, respondPeekCmd(m.sessionsDir, pr.RequestID, resp)
}
