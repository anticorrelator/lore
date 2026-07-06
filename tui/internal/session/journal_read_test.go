package session

import (
	"os"
	"path/filepath"
	"testing"
)

func writeJournal(t *testing.T, sessionsDir, content string) {
	t.Helper()
	if err := os.MkdirAll(sessionsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(EventsFile(sessionsDir), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestReadEventsFrom_AdvancesCursorToRowBoundary verifies a full read returns
// every complete row and a cursor at the byte after the last newline, and that
// resuming from that cursor reads only the appended rows.
func TestReadEventsFrom_AdvancesCursorToRowBoundary(t *testing.T) {
	dir := t.TempDir()
	writeJournal(t, dir, `{"event":"spawned","slug":"a"}`+"\n"+`{"event":"closed","slug":"a"}`+"\n")

	events, cursor := ReadEventsFrom(dir, 0)
	if len(events) != 2 {
		t.Fatalf("want 2 events, got %d", len(events))
	}
	if events[0].Event != "spawned" || events[1].Event != "closed" {
		t.Errorf("unexpected events: %+v", events)
	}

	// Append one row and resume from the cursor.
	f, _ := os.OpenFile(EventsFile(dir), os.O_APPEND|os.O_WRONLY, 0o644)
	_, _ = f.WriteString(`{"event":"needs_input","slug":"b"}` + "\n")
	_ = f.Close()

	more, next := ReadEventsFrom(dir, cursor)
	if len(more) != 1 || more[0].Event != "needs_input" {
		t.Fatalf("resume should read only the appended row, got %+v", more)
	}
	if next <= cursor {
		t.Error("cursor should advance past the appended row")
	}
}

// TestReadEventsFrom_LeavesPartialTrailingRow verifies a row still being written
// (no trailing newline) is not consumed and the cursor does not advance past it.
func TestReadEventsFrom_LeavesPartialTrailingRow(t *testing.T) {
	dir := t.TempDir()
	writeJournal(t, dir, `{"event":"spawned","slug":"a"}`+"\n"+`{"event":"clo`)

	events, cursor := ReadEventsFrom(dir, 0)
	if len(events) != 1 || events[0].Event != "spawned" {
		t.Fatalf("only the complete row should be read, got %+v", events)
	}
	// Cursor sits at the start of the partial row.
	want := int64(len(`{"event":"spawned","slug":"a"}` + "\n"))
	if cursor != want {
		t.Errorf("cursor = %d, want %d (start of the partial row)", cursor, want)
	}
}

// TestReadEventsFrom_MissingFile is a no-op, not an error (the journal is created
// lazily on first append).
func TestReadEventsFrom_MissingFile(t *testing.T) {
	events, cursor := ReadEventsFrom(filepath.Join(t.TempDir(), "nope"), 0)
	if events != nil || cursor != 0 {
		t.Errorf("missing journal should yield (nil, 0), got (%v, %d)", events, cursor)
	}
}

// TestReadEventsFrom_SkipsTornRow excludes a corrupt row rather than aborting.
func TestReadEventsFrom_SkipsTornRow(t *testing.T) {
	dir := t.TempDir()
	writeJournal(t, dir, `{"event":"spawned","slug":"a"}`+"\n"+`{not json}`+"\n"+`{"event":"closed","slug":"a"}`+"\n")
	events, _ := ReadEventsFrom(dir, 0)
	if len(events) != 2 {
		t.Fatalf("torn row should be excluded, got %d events", len(events))
	}
}
