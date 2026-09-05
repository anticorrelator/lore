package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

func TestPeekHistoryStablePagesAndCursorRefusals(t *testing.T) {
	cache := newPeekHistoryCache()
	now := time.Now()
	capture := work.HistoryCapture{Source: "fixture", Rows: []string{"zero", "one", "two", "three", "four"}, RetainedRows: 5}
	snapshot := cache.add("worker", "launch", capture, now)
	first := cache.page(snapshot, 5, 2, 4096, false)
	if strings.Join(first.Rows, ",") != "three,four" || !first.More || first.Start != 3 {
		t.Fatalf("first=%+v", first)
	}
	cache.add("worker", "launch", work.HistoryCapture{Rows: []string{"new output"}}, now.Add(time.Second))
	saved, end, err := cache.resolve(first.NextCursor, "worker", "launch", now.Add(time.Second))
	if err != "" {
		t.Fatal(err)
	}
	second := cache.page(saved, end, 2, 4096, false)
	if strings.Join(second.Rows, ",") != "one,two" || second.SnapshotID != first.SnapshotID {
		t.Fatalf("shifted page=%+v", second)
	}
	for _, tc := range []struct {
		cursor, slug, generation string
		at                       time.Time
		want                     string
	}{
		{"invalid", "worker", "launch", now, "history-invalid-cursor"},
		{first.NextCursor, "other", "launch", now, "history-cursor-session-mismatch"},
		{first.NextCursor, "worker", "relaunch", now, "history-cursor-session-mismatch"},
		{first.NextCursor, "worker", "launch", now.Add(historyTTL), "history-cursor-expired-or-unavailable"},
	} {
		if _, _, got := cache.resolve(tc.cursor, tc.slug, tc.generation, tc.at); got != tc.want {
			t.Errorf("got=%s want=%s", got, tc.want)
		}
	}
	if _, _, got := newPeekHistoryCache().resolve(first.NextCursor, "worker", "launch", now); got != "history-cursor-expired-or-unavailable" {
		t.Fatal(got)
	}
}

func TestPeekHistoryPageBoundsUnicodeAndANSI(t *testing.T) {
	for _, raw := range []bool{false, true} {
		for _, budget := range []int{1, 2, 3, 10, 4096, 16384} {
			cache := newPeekHistoryCache()
			row := "\x1b[31m" + strings.Repeat("界", 20000) + "\x1b[0m"
			snapshot := cache.add("w", "g", work.HistoryCapture{Rows: []string{"older", row}, RetainedRows: 2}, time.Now())
			page := cache.page(snapshot, 2, 500, budget, raw)
			actual := len(strings.Join(page.Rows, "\n")) + len(page.ANSI)
			if actual > budget || page.Bytes > budget || !page.RowTruncated || !page.More || !utf8.ValidString(strings.Join(page.Rows, "")) || !utf8.ValidString(page.ANSI) {
				t.Fatalf("budget=%d raw=%v actual=%d page=%+v", budget, raw, actual, page)
			}
			_, end, err := cache.resolve(page.NextCursor, "w", "g", time.Now())
			if err != "" || end != 1 {
				t.Fatalf("clipped row cursor repeats: %d %s", end, err)
			}
		}
	}
	cache := newPeekHistoryCache()
	snapshot := cache.add("w", "g", work.HistoryCapture{Rows: []string{"\x1b[31mred\x1b[0m"}}, time.Now())
	page := cache.page(snapshot, 1, 10, 100, true)
	if !strings.Contains(page.ANSI, "\x1b[31m") || page.Rows[0] != "red" {
		t.Fatalf("styling lost: %+v", page)
	}
}

func TestPeekHistoryCacheBounds(t *testing.T) {
	cache := newPeekHistoryCache()
	now := time.Now()
	for i := 0; i < 20; i++ {
		cache.add("w", "g", work.HistoryCapture{Rows: []string{strings.Repeat("x", historySnapshotBytes-1)}}, now.Add(time.Duration(i)*time.Second))
	}
	total := 0
	for _, s := range cache.snapshots {
		total += s.bytes
	}
	if len(cache.snapshots) > 8 || total > historyCacheBytes {
		t.Fatalf("unbounded cache %d %d", len(cache.snapshots), total)
	}
	cache.expire(now.Add(3 * time.Minute))
	if len(cache.snapshots) != 0 {
		t.Fatal("expired snapshots retained")
	}
}

func readHistoryResponse(t *testing.T, m model, id string) session.PeekResponse {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(m.sessionsDir, "peek-responses", id+".json"))
	if err != nil {
		t.Fatal(err)
	}
	var response session.PeekResponse
	if err = json.Unmarshal(data, &response); err != nil {
		t.Fatal(err)
	}
	return response
}

func TestPeekHistoryUsesActualNativeRetentionAndCurrentObservation(t *testing.T) {
	m := runtimeModel(t)
	m.sessionsDir = filepath.Join(t.TempDir(), "sessions")
	panel, _ := runtimePanel(t, "worker", ccComposerRows)
	var history []string
	for i := 0; i < 100; i++ {
		history = append(history, fmt.Sprintf("historical-%03d", i))
	}
	panel, _ = panel.Update(work.TerminalOutputMsg{Slug: "worker", Data: []byte(strings.Join(history, "\r\n") + "\r\n" + strings.Join(append([]string{"✶ Musing… (12s · esc to interrupt)"}, ccComposerRows...), "\r\n"))})
	m.sessionPanels["worker"] = panel
	m.localSessions["worker"] = liveSession{harness: "claude-code", sessionID: "launch"}
	before, _ := panel.ScreenState()
	m, cmd := m.handleExtendedPeek(session.PeekRequest{Slug: "worker", RequestID: "first", Lines: 20})
	runJournalCmds(t, cmd)
	response := readHistoryResponse(t, m, "first")
	if response.Error != "" || response.History == nil || response.History.SnapshotRows < 90 || response.Observation.Activity != "working" {
		t.Fatalf("response=%+v", response)
	}
	after, _ := m.sessionPanels["worker"].ScreenState()
	if strings.Join(before.Rows, "\n") != strings.Join(after.Rows, "\n") {
		t.Fatal("history moved live screen")
	}
	initialID := response.History.SnapshotID
	cursor := response.History.NextCursor
	panel, _ = panel.Update(work.TerminalOutputMsg{Slug: "worker", Data: []byte("\r\nNEW-OUTPUT\r\n" + strings.Join(ccModalRows, "\r\n"))})
	m.sessionPanels["worker"] = panel
	m, cmd = m.handleExtendedPeek(session.PeekRequest{Slug: "worker", RequestID: "second", Lines: 20, Before: cursor})
	runJournalCmds(t, cmd)
	response = readHistoryResponse(t, m, "second")
	if response.History.SnapshotID != initialID || response.Observation.Activity != "blocked" || strings.Contains(strings.Join(response.History.Rows, "\n"), "NEW-OUTPUT") {
		t.Fatalf("history/activity mixed: %+v", response)
	}
}

func TestPeekSummaryOmitsBulkAndKeepsModal(t *testing.T) {
	m := runtimeModel(t)
	m.sessionsDir = filepath.Join(t.TempDir(), "sessions")
	panel, _ := runtimePanel(t, "worker", ccModalRows)
	m.sessionPanels["worker"] = panel
	m.localSessions["worker"] = liveSession{harness: "claude-code", sessionID: "launch"}
	m, cmd := m.handleExtendedPeek(session.PeekRequest{Slug: "worker", RequestID: "summary", Summary: true})
	runJournalCmds(t, cmd)
	data, err := os.ReadFile(filepath.Join(m.sessionsDir, "peek-responses", "summary.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err = json.Unmarshal(data, &fields); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"rows", "ansi", "history", "screen"} {
		if _, ok := fields[key]; ok {
			t.Fatalf("summary contains %s", key)
		}
	}
	if fields["modal"] == nil || fields["observation"] == nil {
		t.Fatal("summary lost decision evidence")
	}
}
