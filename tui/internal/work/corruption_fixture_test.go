package work

import (
	"flag"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
)

// updateGolden regenerates testdata/*.golden from the adapter's current
// output: go test -run TestClaudeCorruptionFixture ./internal/work -update
var updateGolden = flag.Bool("update", false, "rewrite golden files from current adapter output")

const (
	fixtureCols = 80
	fixtureRows = 24
	// Prime chunk stride so escape sequences and multi-byte UTF-8 runes are
	// split across chunk boundaries at varying offsets.
	fixtureChunkSize = 257
)

var sgrSequence = regexp.MustCompile(`\x1b\[[0-9;]*m`)

// readAvailable drains everything currently buffered in the pipe, returning
// once a short read deadline expires.
func readAvailable(t *testing.T, r *os.File) []byte {
	t.Helper()
	var out []byte
	buf := make([]byte, 4096)
	for {
		if err := r.SetReadDeadline(time.Now().Add(200 * time.Millisecond)); err != nil {
			t.Fatal(err)
		}
		n, err := r.Read(buf)
		out = append(out, buf[:n]...)
		if err != nil {
			return out
		}
	}
}

// readExact reads exactly n bytes from the pipe or fails the test.
func readExact(t *testing.T, r *os.File, n int) []byte {
	t.Helper()
	if err := r.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		t.Fatalf("expected %d bytes on the PTY, got error: %v", n, err)
	}
	return buf
}

// TestClaudeCorruptionFixture replays a synthetic corrupted Claude Code PTY
// session (see testdata/claude-corruption-01.meta.json for provenance and
// byte layout) in chunks through the real TerminalOutputMsg path and asserts
// the acceptance criteria for the libghostty backend: color-preserving
// scrollback, device-query responses on the PTY, a clean golden-pinned final
// screen, panic-free resize reflow, and byte-exact key forwarding.
func TestClaudeCorruptionFixture(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "claude-corruption-01.bytes"))
	if err != nil {
		t.Fatal(err)
	}

	ptyRead, ptyWrite, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer ptyRead.Close()
	defer ptyWrite.Close()

	m := newSizedPanel(t, fixtureCols, fixtureRows)
	m = m.SetPtmx(ptyWrite, nil, nil)

	for off := 0; off < len(raw); off += fixtureChunkSize {
		end := off + fixtureChunkSize
		if end > len(raw) {
			end = len(raw)
		}
		m, _ = m.Update(TerminalOutputMsg{Slug: "test", Data: raw[off:end]})
	}

	// Device queries embedded in the fixture (DA1, DSR 6n, XTVERSION) must
	// produce responses on the PTY through the WRITE_PTY callback.
	resp := readAvailable(t, ptyRead)
	if !strings.Contains(string(resp), "\x1b[?") {
		t.Errorf("expected a DA1 response (CSI ? ... c) on the PTY, got %q", resp)
	}
	if !regexp.MustCompile(`\x1b\[\d+;\d+R`).Match(resp) {
		t.Errorf("expected a DSR cursor-position response (CSI row;col R) on the PTY, got %q", resp)
	}

	// Final screen: golden-pinned and free of orphaned escapes.
	goldenPath := filepath.Join("testdata", "claude-corruption-01.golden")
	if *updateGolden {
		if err := os.WriteFile(goldenPath, []byte(m.cachedRender), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	golden, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatal(err)
	}
	if m.cachedRender != string(golden) {
		t.Errorf("final screen does not match golden (rerun with -update to regenerate)\ngot:\n%q\nwant:\n%q", m.cachedRender, golden)
	}
	if stripped := sgrSequence.ReplaceAllString(m.cachedRender, ""); strings.ContainsRune(stripped, 0x1b) {
		t.Errorf("final screen contains an orphaned ESC outside a complete SGR sequence:\n%q", stripped)
	}

	// Scrolled-off lines must retain their SGR color (the regression that
	// motivated the backend swap: x/vt scrollback was plain text).
	if m.totalLines() <= fixtureRows {
		t.Fatalf("expected fixture to overflow the screen into scrollback, totalLines=%d", m.totalLines())
	}
	m.scrollOffset = m.totalLines() - fixtureRows
	scrollView := m.View()
	if !strings.Contains(scrollView, "tool-output 01") {
		t.Errorf("expected an early fixture line in the scrollback view:\n%q", scrollView)
	}
	if !strings.Contains(scrollView, ";38;2;") {
		t.Errorf("scrollback view must preserve SGR color sequences:\n%q", scrollView)
	}
	m.scrollOffset = 0

	// Resize after replay must reflow without panic and fill the new height.
	m, _ = m.Update(tea.WindowSizeMsg{Width: 60, Height: 18})
	if got := strings.Count(m.cachedRender, "\n"); got != 17 {
		t.Errorf("expected 18 rendered rows after resize, got %d newlines:\n%q", got, m.cachedRender)
	}

	// Representative keys must reach the PTY byte-for-byte. The Escape case
	// also covers the kitty CSI-u path: Bubble Tea v2 decodes \x1b[27u to the
	// same KeyPressMsg{Code: tea.KeyEscape} as a legacy 0x1b.
	keyCases := []struct {
		name string
		msg  tea.KeyPressMsg
		want []byte
	}{
		{"rune", tea.KeyPressMsg{Code: 'a', Text: "a"}, []byte("a")},
		{"enter", tea.KeyPressMsg{Code: tea.KeyEnter}, []byte{'\r'}},
		{"up", tea.KeyPressMsg{Code: tea.KeyUp}, []byte{0x1b, '[', 'A'}},
		{"down", tea.KeyPressMsg{Code: tea.KeyDown}, []byte{0x1b, '[', 'B'}},
		{"right", tea.KeyPressMsg{Code: tea.KeyRight}, []byte{0x1b, '[', 'C'}},
		{"left", tea.KeyPressMsg{Code: tea.KeyLeft}, []byte{0x1b, '[', 'D'}},
		{"ctrl+c", tea.KeyPressMsg{Code: 'c', Mod: tea.ModCtrl}, []byte{0x03}},
		{"escape", tea.KeyPressMsg{Code: tea.KeyEscape}, []byte{0x1b}},
	}
	for _, kc := range keyCases {
		m, _ = m.Update(kc.msg)
		if got := readExact(t, ptyRead, len(kc.want)); string(got) != string(kc.want) {
			t.Errorf("key %s: expected %q on the PTY, got %q", kc.name, kc.want, got)
		}
	}

	// The trailing single Escape above armed the detach gesture: a second Esc
	// within the window must emit TerminalDetachMsg without forwarding bytes.
	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	detach, ok := firstCmdMsg(cmd).(TerminalDetachMsg)
	if !ok {
		t.Fatalf("expected TerminalDetachMsg from double Esc, got %T", firstCmdMsg(cmd))
	}
	if detach.Slug != "test" {
		t.Errorf("detach slug: expected %q, got %q", "test", detach.Slug)
	}
	if leftover := readAvailable(t, ptyRead); len(leftover) != 0 {
		t.Errorf("detach Esc must not forward bytes to the PTY, got %q", leftover)
	}
}
