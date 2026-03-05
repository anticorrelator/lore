package work

import (
	"fmt"
	"testing"
)

func TestStripAnsiX10Mouse(t *testing.T) {
	// X10 mouse sequence: ESC [ M <button> <col> <y>
	// col=35 => 35+32=67 => ASCII 'C', y=1 => 1+32=33 => ASCII '!'
	input := "\x1b[M\x20C!"
	got := stripAnsi(input)
	if got != "" {
		t.Errorf("X10 mouse sequence should be fully stripped, got %q", got)
	}
}

func TestStripAnsiX10MouseMidString(t *testing.T) {
	// X10 mouse sequence embedded in normal text
	input := "hello\x1b[M\x20C!world"
	got := stripAnsi(input)
	if got != "helloworld" {
		t.Errorf("expected %q, got %q", "helloworld", got)
	}
}

func TestStripAnsiColorCode(t *testing.T) {
	// Standard SGR color: ESC [ 31 m (red foreground)
	input := "\x1b[31mhello\x1b[0m"
	got := stripAnsi(input)
	if got != "hello" {
		t.Errorf("expected %q, got %q", "hello", got)
	}
}

func TestStripAnsiMixed(t *testing.T) {
	// Color code + X10 mouse + normal text
	input := "\x1b[32mgreen\x1b[M\x20C!\x1b[0m end"
	got := stripAnsi(input)
	if got != "green end" {
		t.Errorf("expected %q, got %q", "green end", got)
	}
}

func TestStripAnsiTildeTerminated(t *testing.T) {
	// Bracketed paste markers end in '~' (0x7e), not a letter — must be stripped
	start := "\x1b[200~"
	end := "\x1b[201~"
	if got := stripAnsi(start + "pasted text" + end); got != "pasted text" {
		t.Errorf("bracketed paste markers should be stripped, got %q", got)
	}
	// PgUp / PgDn function keys
	if got := stripAnsi("\x1b[5~scroll\x1b[6~"); got != "scroll" {
		t.Errorf("PgUp/PgDn sequences should be stripped, got %q", got)
	}
}

func TestStripAnsiCarriageReturn(t *testing.T) {
	// Spinner overwrites: only the last frame after \r should survive.
	if got := stripAnsi("frame1\rframe2\rframe3"); got != "frame3" {
		t.Errorf("expected last overwrite frame, got %q", got)
	}
	// \r at end of line means the line is blank (overwritten with nothing).
	if got := stripAnsi("text\r"); got != "" {
		t.Errorf("trailing \\r should produce empty line, got %q", got)
	}
	// \r\n is a normal line ending, not an overwrite.
	if got := stripAnsi("line1\r\nline2"); got != "line1\nline2" {
		t.Errorf("\\r\\n should be a line ending, got %q", got)
	}
}

func TestCountCursorUp(t *testing.T) {
	if n := countCursorUp("\x1b[3A"); n != 3 {
		t.Errorf("expected 3, got %d", n)
	}
	if n := countCursorUp("\x1b[A"); n != 1 { // no digit defaults to 1
		t.Errorf("expected 1, got %d", n)
	}
	if n := countCursorUp("\x1b[2A\x1b[3A"); n != 5 {
		t.Errorf("expected 5, got %d", n)
	}
	if n := countCursorUp("no escapes here"); n != 0 {
		t.Errorf("expected 0, got %d", n)
	}
}

func TestTrimIncompleteEscapeTildeCSI(t *testing.T) {
	// ESC[200~ (bracketed paste start) is complete — must not be held as tail.
	safe, tail := trimIncompleteEscape("text\x1b[200~")
	if safe != "text\x1b[200~" || tail != "" {
		t.Errorf("ESC[200~ should be complete, got safe=%q tail=%q", safe, tail)
	}
	// ESC[200 with no ~ yet is incomplete.
	safe, tail = trimIncompleteEscape("text\x1b[200")
	if safe != "text" || tail != "\x1b[200" {
		t.Errorf("ESC[200 should be incomplete, got safe=%q tail=%q", safe, tail)
	}
}

func TestTrimIncompleteEscapeNoEscape(t *testing.T) {
	safe, tail := trimIncompleteEscape("hello world")
	if safe != "hello world" || tail != "" {
		t.Errorf("expected (\"hello world\", \"\"), got (%q, %q)", safe, tail)
	}
}

func TestTrimIncompleteEscapeEmpty(t *testing.T) {
	safe, tail := trimIncompleteEscape("")
	if safe != "" || tail != "" {
		t.Errorf("expected (\"\", \"\"), got (%q, %q)", safe, tail)
	}
}

func TestTrimIncompleteEscapeBareESC(t *testing.T) {
	// Bare ESC at end — incomplete
	safe, tail := trimIncompleteEscape("hello\x1b")
	if safe != "hello" || tail != "\x1b" {
		t.Errorf("expected (\"hello\", \"\\x1b\"), got (%q, %q)", safe, tail)
	}
}

func TestTrimIncompleteEscapePartialCSI(t *testing.T) {
	// ESC [ with no terminal letter — incomplete CSI
	safe, tail := trimIncompleteEscape("hello\x1b[")
	if safe != "hello" || tail != "\x1b[" {
		t.Errorf("expected (\"hello\", \"\\x1b[\"), got (%q, %q)", safe, tail)
	}
}

func TestTrimIncompleteEscapePartialCSIParams(t *testing.T) {
	// ESC [ 3 1 — params but no terminal letter
	safe, tail := trimIncompleteEscape("hello\x1b[31")
	if safe != "hello" || tail != "\x1b[31" {
		t.Errorf("expected (\"hello\", \"\\x1b[31\"), got (%q, %q)", safe, tail)
	}
}

func TestTrimIncompleteEscapeCompleteCSI(t *testing.T) {
	// ESC [ 31 m — complete sequence, no trimming needed
	safe, tail := trimIncompleteEscape("hello\x1b[31m")
	if safe != "hello\x1b[31m" || tail != "" {
		t.Errorf("expected complete string with empty tail, got (%q, %q)", safe, tail)
	}
}

func TestTrimIncompleteEscapeCompleteThenPartial(t *testing.T) {
	// Complete sequence followed by incomplete one
	safe, tail := trimIncompleteEscape("hello\x1b[31mworld\x1b[")
	if safe != "hello\x1b[31mworld" || tail != "\x1b[" {
		t.Errorf("expected safe up to incomplete, got (%q, %q)", safe, tail)
	}
}

func TestScrollBufPrevChunkLinesCap(t *testing.T) {
	m := NewSpecPanelModel("test")

	// First chunk: 3 non-empty lines, no cursor-up.
	data1 := []byte("line1\nline2\nline3\n")
	m, _ = m.Update(TerminalOutputMsg{Slug: "test", Data: data1})
	if len(m.scrollBuf) != 3 {
		t.Fatalf("after chunk 1: expected 3 scrollBuf lines, got %d", len(m.scrollBuf))
	}
	if m.prevChunkLines != 3 {
		t.Fatalf("after chunk 1: expected prevChunkLines=3, got %d", m.prevChunkLines)
	}

	// Second chunk: cursor-up 24 + 24 new lines.
	// With the fix, pop is capped at prevChunkLines (3), not upCount (24).
	// So scrollBuf should be: 3 - 3 + 24 = 24 lines.
	var data2 []byte
	data2 = append(data2, "\x1b[24A"...)
	for i := 0; i < 24; i++ {
		data2 = append(data2, []byte(fmt.Sprintf("new%d\n", i))...)
	}
	m, _ = m.Update(TerminalOutputMsg{Slug: "test", Data: data2})

	// Without the fix, pop would be 24 (> scrollBuf len 3, capped to 3),
	// which coincidentally gives the same result. The key difference is the
	// *mechanism*: the fix caps at prevChunkLines, not at scrollBuf length.
	// To distinguish, we verify prevChunkLines updated correctly.
	if m.prevChunkLines != 24 {
		t.Fatalf("after chunk 2: expected prevChunkLines=24, got %d", m.prevChunkLines)
	}
	expectedLen := 24 // 3 original - 3 popped + 24 new
	if len(m.scrollBuf) != expectedLen {
		t.Fatalf("after chunk 2: expected %d scrollBuf lines, got %d", expectedLen, len(m.scrollBuf))
	}
}

func TestScrollBufSpinnerDedup(t *testing.T) {
	m := NewSpecPanelModel("test")

	// First spinner frame: 1 non-empty line.
	data1 := []byte("spinner frame 1\n")
	m, _ = m.Update(TerminalOutputMsg{Slug: "test", Data: data1})
	if len(m.scrollBuf) != 1 {
		t.Fatalf("after frame 1: expected 1 scrollBuf line, got %d", len(m.scrollBuf))
	}

	// Second spinner frame: cursor-up 1 + 1 new line (replaces frame 1).
	data2 := []byte("\x1b[1Aspinner frame 2\n")
	m, _ = m.Update(TerminalOutputMsg{Slug: "test", Data: data2})
	if len(m.scrollBuf) != 1 {
		t.Fatalf("after frame 2: expected 1 scrollBuf line (dedup), got %d", len(m.scrollBuf))
	}
	if m.scrollBuf[0] != "spinner frame 2" {
		t.Fatalf("expected second frame content, got %q", m.scrollBuf[0])
	}
}

func TestScrollOffsetStabilityDuringPop(t *testing.T) {
	m := NewSpecPanelModel("test")
	m.height = 24

	// Pre-populate scrollBuf with 40 lines and set prevChunkLines to 3
	// (simulating a previous chunk that added 3 lines).
	// 40 lines ensures maxOff (40-24=16) > scrollOffset (5), avoiding clamp.
	for i := 0; i < 40; i++ {
		m.scrollBuf = append(m.scrollBuf, fmt.Sprintf("line%d", i))
	}
	m.prevChunkLines = 3
	m.scrollOffset = 5

	endIdxBefore := len(m.scrollBuf) - m.scrollOffset // 40 - 5 = 35

	// Send a TerminalOutputMsg with upCount=3 (matches prevChunkLines) and 3 new lines.
	// Pop removes 3, scrollOffset decreases by 3 (5→2), then 3 lines added,
	// scrollOffset increases by 3 (2→5). Net: scrollBuf same size, scrollOffset same.
	data := []byte("\x1b[3AnewA\nnewB\nnewC\n")
	m, _ = m.Update(TerminalOutputMsg{Slug: "test", Data: data})

	endIdxAfter := len(m.scrollBuf) - m.scrollOffset

	if endIdxAfter != endIdxBefore {
		t.Fatalf("endIdx shifted: before=%d, after=%d (scrollBuf=%d, scrollOffset=%d)",
			endIdxBefore, endIdxAfter, len(m.scrollBuf), m.scrollOffset)
	}
	if m.scrollOffset != 5 {
		t.Fatalf("expected scrollOffset=5 (unchanged), got %d", m.scrollOffset)
	}
}

func TestTrimIncompleteEscapeTwoByteSafe(t *testing.T) {
	// ESC c (RIS - reset) — complete 2-byte sequence
	safe, tail := trimIncompleteEscape("hello\x1bc")
	if safe != "hello\x1bc" || tail != "" {
		t.Errorf("expected complete string, got (%q, %q)", safe, tail)
	}
}
