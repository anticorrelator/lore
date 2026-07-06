package session

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
)

// EventsFile is the append-only journal under a _sessions/ root. The sole
// writer is session-event-append.sh; this package only ever reads it.
func EventsFile(sessionsDir string) string {
	return filepath.Join(sessionsDir, "events.jsonl")
}

// ReadEventsFrom reads journal rows appended at or after byteOffset and returns
// them with the offset a subsequent call should resume from. It honors the
// substrate's opaque-cursor contract (docs/session-substrate.md): the returned
// cursor only ever advances to a whole-row boundary (the byte after the last
// newline), so a partial trailing row — a write in flight — is left unconsumed
// and re-read on the next call rather than parsed half-formed.
//
// A missing file yields no rows and offset 0 (the journal is created lazily on
// first append). An offset past the current size — reachable only via external
// truncation/tampering — resets to a full re-read from 0 rather than returning a
// bogus advancing cursor.
func ReadEventsFrom(sessionsDir string, byteOffset int64) ([]Event, int64) {
	path := EventsFile(sessionsDir)
	f, err := os.Open(path)
	if err != nil {
		return nil, 0
	}
	defer f.Close()

	fi, err := f.Stat()
	if err != nil {
		return nil, byteOffset
	}
	if byteOffset > fi.Size() {
		byteOffset = 0
	}
	if _, err := f.Seek(byteOffset, 0); err != nil {
		return nil, byteOffset
	}

	data, err := io.ReadAll(f)
	if err != nil {
		return nil, byteOffset
	}
	// Only consume up to the last complete row (through its trailing newline);
	// anything after is a partial write, left for the next read.
	lastNL := bytes.LastIndexByte(data, '\n')
	if lastNL < 0 {
		return nil, byteOffset
	}
	consumed := data[:lastNL+1]

	var out []Event
	for _, line := range bytes.Split(consumed, []byte{'\n'}) {
		trimmed := bytes.TrimSpace(line)
		if len(trimmed) == 0 {
			continue
		}
		var ev Event
		if err := json.Unmarshal(trimmed, &ev); err != nil {
			continue // torn row: excluded, never repaired
		}
		out = append(out, ev)
	}
	return out, byteOffset + int64(len(consumed))
}
