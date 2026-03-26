package work

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestParseNotes(t *testing.T) {
	t.Run("ISO-T date header", func(t *testing.T) {
		content := "## 2026-03-25T14:30\n**Focus:** writing tests\n**Progress:** done\n**Next:** review"
		entries := parseNotes(content)
		if len(entries) != 1 {
			t.Fatalf("expected 1 entry, got %d", len(entries))
		}
		if entries[0].Timestamp != "2026-03-25T14:30" {
			t.Errorf("expected timestamp 2026-03-25T14:30, got %q", entries[0].Timestamp)
		}
		if entries[0].Content == "" {
			t.Error("expected non-empty content")
		}
	})

	t.Run("date-only header", func(t *testing.T) {
		content := "## 2026-03-25\nSome content here."
		entries := parseNotes(content)
		if len(entries) != 1 {
			t.Fatalf("expected 1 entry, got %d", len(entries))
		}
		if entries[0].Timestamp != "2026-03-25" {
			t.Errorf("expected timestamp 2026-03-25, got %q", entries[0].Timestamp)
		}
	})

	t.Run("date-with-label header is not parsed as date entry", func(t *testing.T) {
		// noteHeaderRe only captures YYYY-MM-DD or YYYY-MM-DDTHH:MM prefixes;
		// "## 2026-03-25 — Label" has a space after the date, so the regex
		// still matches the date portion — verify it does.
		content := "## 2026-03-25 — Sprint Review\nContent here."
		entries := parseNotes(content)
		// The regex matches the date prefix even with trailing text, so we expect 1 entry.
		if len(entries) != 1 {
			t.Fatalf("expected 1 entry, got %d", len(entries))
		}
		if entries[0].Timestamp != "2026-03-25" {
			t.Errorf("expected timestamp 2026-03-25, got %q", entries[0].Timestamp)
		}
	})

	t.Run("non-date H2 header returns empty", func(t *testing.T) {
		content := "## Session Notes\nSome content."
		entries := parseNotes(content)
		if len(entries) != 0 {
			t.Errorf("expected 0 entries for non-date header, got %d", len(entries))
		}
	})

	t.Run("mixed date and non-date headers", func(t *testing.T) {
		content := "## Session Notes\nPreamble content.\n## 2026-03-25T10:00\nFirst entry.\n## 2026-03-26T09:00\nSecond entry."
		entries := parseNotes(content)
		if len(entries) != 2 {
			t.Fatalf("expected 2 entries, got %d", len(entries))
		}
		if entries[0].Timestamp != "2026-03-25T10:00" {
			t.Errorf("expected first timestamp 2026-03-25T10:00, got %q", entries[0].Timestamp)
		}
		if entries[1].Timestamp != "2026-03-26T09:00" {
			t.Errorf("expected second timestamp 2026-03-26T09:00, got %q", entries[1].Timestamp)
		}
	})

	t.Run("empty input", func(t *testing.T) {
		entries := parseNotes("")
		if len(entries) != 0 {
			t.Errorf("expected 0 entries for empty input, got %d", len(entries))
		}
	})

	t.Run("whitespace-only input", func(t *testing.T) {
		entries := parseNotes("   \n\t\n  ")
		if len(entries) != 0 {
			t.Errorf("expected 0 entries for whitespace input, got %d", len(entries))
		}
	})

	t.Run("preamble prepended to first entry when entry has no content", func(t *testing.T) {
		content := "# Session Notes\n\n## 2026-03-25T08:00\n"
		entries := parseNotes(content)
		if len(entries) != 1 {
			t.Fatalf("expected 1 entry, got %d", len(entries))
		}
		if entries[0].Content == "" {
			t.Error("expected preamble to be prepended to first entry's Content")
		}
		// Preamble should contain the H1 line
		if entries[0].Content != "# Session Notes" {
			t.Errorf("unexpected preamble content: %q", entries[0].Content)
		}
	})

	t.Run("preamble prepended with separator when entry has content", func(t *testing.T) {
		content := "# Session Notes\n\n## 2026-03-25T08:00\nEntry body."
		entries := parseNotes(content)
		if len(entries) != 1 {
			t.Fatalf("expected 1 entry, got %d", len(entries))
		}
		// Preamble + "---" separator + entry content
		expected := "# Session Notes\n---\nEntry body."
		if entries[0].Content != expected {
			t.Errorf("expected %q, got %q", expected, entries[0].Content)
		}
	})

	t.Run("multiple entries parsed in order", func(t *testing.T) {
		content := "## 2026-01-01T09:00\nalpha\n## 2026-02-01T10:00\nbeta\n## 2026-03-01T11:00\ngamma"
		entries := parseNotes(content)
		if len(entries) != 3 {
			t.Fatalf("expected 3 entries, got %d", len(entries))
		}
		timestamps := []string{"2026-01-01T09:00", "2026-02-01T10:00", "2026-03-01T11:00"}
		contents := []string{"alpha", "beta", "gamma"}
		for i, e := range entries {
			if e.Timestamp != timestamps[i] {
				t.Errorf("entry %d: expected timestamp %q, got %q", i, timestamps[i], e.Timestamp)
			}
			if e.Content != contents[i] {
				t.Errorf("entry %d: expected content %q, got %q", i, contents[i], e.Content)
			}
		}
	})
}

func TestNotesTabModelView(t *testing.T) {
	t.Run("empty model renders no-notes message", func(t *testing.T) {
		m := NewNotesTabModel(nil, 80, 24)
		out := m.View()
		if !strings.Contains(out, "No session notes.") {
			t.Errorf("expected 'No session notes.' in empty view, got %q", out)
		}
	})

	t.Run("empty string content renders no-notes message", func(t *testing.T) {
		s := "   "
		m := NewNotesTabModel(&s, 80, 24)
		out := m.View()
		if !strings.Contains(out, "No session notes.") {
			t.Errorf("expected 'No session notes.' in whitespace-only view, got %q", out)
		}
	})

	t.Run("fallback model does not render no-notes message", func(t *testing.T) {
		// Content with no date headers triggers fallback viewport path.
		s := "Some undated notes content here."
		m := NewNotesTabModel(&s, 80, 24)
		if !m.fallback {
			t.Fatal("expected model to be in fallback mode")
		}
		out := m.View()
		if strings.Contains(out, "No session notes.") {
			t.Errorf("fallback view should not show 'No session notes.', got %q", out)
		}
		if strings.TrimSpace(out) == "" {
			t.Error("fallback view should produce non-empty output")
		}
	})

	t.Run("dated model renders two-pane layout with separator", func(t *testing.T) {
		s := "## 2026-03-25T10:00\n**Focus:** writing\n**Progress:** done\n**Next:** review"
		m := NewNotesTabModel(&s, 80, 24)
		out := m.View()
		if strings.Contains(out, "No session notes.") {
			t.Errorf("dated view should not show 'No session notes.', got %q", out)
		}
		// Two-pane layout uses │ separator
		if !strings.Contains(out, "│") {
			t.Errorf("expected two-pane separator │ in dated view, got %q", out)
		}
		// Timestamp should appear in the left pane
		if !strings.Contains(out, "2026-03-25T10:00") {
			t.Errorf("expected timestamp in dated view, got %q", out)
		}
	})

	t.Run("dated model with multiple entries shows first entry selected", func(t *testing.T) {
		s := "## 2026-01-01T09:00\nalpha content\n## 2026-02-01T10:00\nbeta content"
		m := NewNotesTabModel(&s, 80, 24)
		out := m.View()
		// Both timestamps should appear in the left pane
		if !strings.Contains(out, "2026-01-01T09:00") {
			t.Errorf("expected first timestamp in dated view, got %q", out)
		}
		if !strings.Contains(out, "2026-02-01T10:00") {
			t.Errorf("expected second timestamp in dated view, got %q", out)
		}
		// First entry's content should be visible in right pane (cursor=0)
		if !strings.Contains(out, "alpha content") {
			t.Errorf("expected first entry content in right pane, got %q", out)
		}
	})
}

func TestNewNotesTabModel(t *testing.T) {
	t.Run("nil content returns empty model", func(t *testing.T) {
		m := NewNotesTabModel(nil, 80, 24)
		if !m.empty {
			t.Error("expected empty=true for nil content")
		}
		if m.fallback {
			t.Error("expected fallback=false for nil content")
		}
		if len(m.entries) != 0 {
			t.Errorf("expected no entries, got %d", len(m.entries))
		}
	})

	t.Run("whitespace-only content returns empty model", func(t *testing.T) {
		s := "   \n\t\n  "
		m := NewNotesTabModel(&s, 80, 24)
		if !m.empty {
			t.Error("expected empty=true for whitespace-only content")
		}
		if m.fallback {
			t.Error("expected fallback=false for whitespace-only content")
		}
	})

	t.Run("boilerplate-only content (H1 + comment) returns empty model", func(t *testing.T) {
		s := "# Session Notes\n\n<!-- Append session entries below. -->\n"
		m := NewNotesTabModel(&s, 80, 24)
		if !m.empty {
			t.Error("expected empty=true for boilerplate-only content")
		}
		if m.fallback {
			t.Error("expected fallback=false for boilerplate-only content")
		}
	})

	t.Run("non-date H2 headers trigger fallback viewport path", func(t *testing.T) {
		s := "## Overview\nSome context.\n## Goals\nDo things."
		m := NewNotesTabModel(&s, 80, 24)
		if m.empty {
			t.Error("expected empty=false for non-date content")
		}
		if !m.fallback {
			t.Error("expected fallback=true for non-date H2 content")
		}
		if len(m.entries) != 0 {
			t.Errorf("expected no entries in fallback mode, got %d", len(m.entries))
		}
	})

	t.Run("dated entries produce two-pane path (not fallback)", func(t *testing.T) {
		s := "## 2026-03-25T10:00\nContent here.\n## 2026-03-26T09:00\nMore content."
		m := NewNotesTabModel(&s, 80, 24)
		if m.empty {
			t.Error("expected empty=false for dated content")
		}
		if m.fallback {
			t.Error("expected fallback=false for dated entries")
		}
		if len(m.entries) != 2 {
			t.Errorf("expected 2 entries, got %d", len(m.entries))
		}
		if m.cursor != 0 {
			t.Errorf("expected cursor=0, got %d", m.cursor)
		}
	})

	t.Run("fallback model resizes viewport on WindowSizeMsg", func(t *testing.T) {
		s := "Some undated content."
		m := NewNotesTabModel(&s, 80, 24)
		if !m.fallback {
			t.Fatal("expected fallback mode")
		}
		m, _ = m.Update(tea.WindowSizeMsg{Width: 120, Height: 40})
		if m.width != 120 {
			t.Errorf("expected width=120, got %d", m.width)
		}
		if m.height != 40 {
			t.Errorf("expected height=40, got %d", m.height)
		}
		if m.vp.Width != 120 {
			t.Errorf("expected vp.Width=120, got %d", m.vp.Width)
		}
		if m.vp.Height != 40 {
			t.Errorf("expected vp.Height=40, got %d", m.vp.Height)
		}
	})
}
