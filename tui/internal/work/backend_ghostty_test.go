package work

import (
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

// newSizedPanel creates a panel sized via the real WindowSizeMsg path so the
// model height and backend dimensions stay in sync, as in the live TUI.
func newSizedPanel(t *testing.T, width, height int) SessionPanelModel {
	t.Helper()
	m := NewSessionPanelModel("test")
	m, _ = m.Update(tea.WindowSizeMsg{Width: width, Height: height})
	return m
}

// feedNumberedLines writes rows "line00".."lineNN" through the real
// TerminalOutputMsg path, without a trailing newline after the last row, so
// document row i carries the label "line%02d" i.
func feedNumberedLines(t *testing.T, m SessionPanelModel, n int) SessionPanelModel {
	t.Helper()
	var sb strings.Builder
	for i := 0; i < n; i++ {
		if i > 0 {
			sb.WriteString("\r\n")
		}
		fmt.Fprintf(&sb, "line%02d", i)
	}
	m, _ = m.Update(TerminalOutputMsg{Slug: "test", Data: []byte(sb.String())})
	return m
}

func TestViewBlendsScrollbackAndScreen(t *testing.T) {
	m := newSizedPanel(t, 20, 6) // 5 content lines + 1 indicator
	m = feedNumberedLines(t, m, 10)

	total := m.totalLines()
	if total < 8 {
		t.Fatalf("expected scrollback to accumulate, totalLines=%d", total)
	}

	// scrollOffset = 2 shows document rows [total-7, total-2): the window
	// straddles native scrollback and the live screen.
	m.scrollOffset = 2
	view := m.View()
	wantTop := fmt.Sprintf("line%02d", total-7)
	wantBottom := fmt.Sprintf("line%02d", total-3)
	notAbove := fmt.Sprintf("line%02d", total-8)
	notBelow := fmt.Sprintf("line%02d", total-2)
	if !strings.Contains(view, wantTop) {
		t.Errorf("expected %s in view:\n%s", wantTop, view)
	}
	if !strings.Contains(view, wantBottom) {
		t.Errorf("expected %s in view:\n%s", wantBottom, view)
	}
	if strings.Contains(view, notAbove) {
		t.Errorf("%s should be above the window:\n%s", notAbove, view)
	}
	if strings.Contains(view, notBelow) {
		t.Errorf("%s should be below the window:\n%s", notBelow, view)
	}

	// The scrollback read is observational: a follow-up live render still
	// shows the document bottom, not the scrolled-to window.
	live := m.backend.renderScreen()
	if !strings.Contains(live, "line09") {
		t.Errorf("live render after scrollback read should show the bottom:\n%s", live)
	}
}

func TestScrollIndicatorInView(t *testing.T) {
	m := newSizedPanel(t, 20, 10)
	m = feedNumberedLines(t, m, 30)

	// When scrollOffset == 0, no indicator.
	m.scrollOffset = 0
	view0 := m.View()
	if strings.Contains(view0, "scrollback") {
		t.Fatal("indicator should not appear when scrollOffset == 0")
	}

	// When scrollOffset > 0, indicator should appear.
	m.scrollOffset = 5
	view5 := m.View()
	if !strings.Contains(view5, "scrollback") || !strings.Contains(view5, "lines above") {
		t.Fatal("indicator should appear when scrollOffset > 0")
	}
}

func TestScrollOffsetClampedToDocument(t *testing.T) {
	m := newSizedPanel(t, 40, 24)

	// Write deep history in one chunk; native scrollback retains it.
	var sb strings.Builder
	for i := 0; i < 6000; i++ {
		fmt.Fprintf(&sb, "l%d\r\n", i)
	}
	m, _ = m.Update(TerminalOutputMsg{Slug: "test", Data: []byte(sb.String())})

	if total := m.totalLines(); total < 5000 {
		t.Fatalf("expected deep native scrollback, totalLines=%d", total)
	}

	// An absurd offset must clamp to the document size on the next output.
	m.scrollOffset = 10_000_000
	m, _ = m.Update(TerminalOutputMsg{Slug: "test", Data: []byte("x")})
	maxOff := m.totalLines() - 24
	if m.scrollOffset != maxOff {
		t.Fatalf("expected scrollOffset clamped to %d, got %d", maxOff, m.scrollOffset)
	}
}

func TestScrollbackViewWhenDone(t *testing.T) {
	m := newSizedPanel(t, 20, 10)
	m = feedNumberedLines(t, m, 20)

	m, _ = m.Update(StreamCompleteMsg{Slug: "test"})
	if !m.IsDone() {
		t.Fatal("expected panel to be done after StreamCompleteMsg")
	}

	// Scrollback should still work from the retained backend state.
	m.scrollOffset = 5
	view := m.View()
	if !strings.Contains(view, "line") {
		t.Fatal("scrollback View() should render content when panel is done")
	}
	if !strings.Contains(view, "scrollback") {
		t.Fatal("scroll indicator should appear in done panel when scrolled")
	}
}

func TestRenderScreenPreservesColor(t *testing.T) {
	m := newSizedPanel(t, 40, 5)
	m, _ = m.Update(TerminalOutputMsg{Slug: "test", Data: []byte("\x1b[31mRED\x1b[0m plain")})

	if !strings.Contains(m.cachedRender, "RED") {
		t.Fatalf("expected RED in render:\n%q", m.cachedRender)
	}
	if !strings.Contains(m.cachedRender, ";38;2;") {
		t.Fatalf("expected a foreground SGR sequence in render:\n%q", m.cachedRender)
	}
	if strings.Contains(m.cachedRender, "\r") {
		t.Fatalf("render must not contain stray \\r:\n%q", m.cachedRender)
	}
}

func TestScrollbackPreservesColor(t *testing.T) {
	m := newSizedPanel(t, 20, 4)
	var sb strings.Builder
	for i := 0; i < 12; i++ {
		fmt.Fprintf(&sb, "\x1b[32mgreen%02d\x1b[0m\r\n", i)
	}
	m, _ = m.Update(TerminalOutputMsg{Slug: "test", Data: []byte(sb.String())})

	if m.totalLines() <= 4 {
		t.Fatalf("expected lines in scrollback, totalLines=%d", m.totalLines())
	}
	// Scroll as far up as the UI allows (the indicator line reserves one row,
	// so the topmost reachable document row is row 1).
	m.scrollOffset = m.totalLines() - 4
	view := m.View()
	if !strings.Contains(view, "green01") {
		t.Fatalf("expected oldest reachable line in scrollback view:\n%q", view)
	}
	if !strings.Contains(view, ";38;2;") {
		t.Fatalf("scrollback must preserve color SGR sequences:\n%q", view)
	}
}

func TestWritePtyForwardsDeviceQueryResponses(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	defer w.Close()

	m := newSizedPanel(t, 40, 10)
	m = m.SetPtmx(w, nil, nil)

	// DA1 then DSR cursor-position queries: the WritePty effect fires
	// synchronously inside the write, forwarding responses to the PTY.
	m, _ = m.Update(TerminalOutputMsg{Slug: "test", Data: []byte("\x1b[c\x1b[6n")})

	if err := r.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 256)
	n, err := r.Read(buf)
	if err != nil || n == 0 {
		t.Fatalf("expected device-query responses on the PTY; n=%d err=%v", n, err)
	}
	got := string(buf[:n])
	if !strings.HasPrefix(got, "\x1b[?") {
		t.Errorf("expected DA1 response prefix \\x1b[?, got %q", got)
	}
	if !strings.Contains(got, "R") {
		t.Errorf("expected DSR cursor-position response (CSI ... R), got %q", got)
	}
}

func TestResizeReflowsToRequestedRows(t *testing.T) {
	m := newSizedPanel(t, 40, 24)
	m = feedNumberedLines(t, m, 30)

	m, _ = m.Update(tea.WindowSizeMsg{Width: 30, Height: 10})
	if got := strings.Count(m.cachedRender, "\n"); got != 9 {
		t.Fatalf("expected 10 rendered rows after resize, got %d newlines:\n%q", got, m.cachedRender)
	}
}

func TestWideCharColumnAccounting(t *testing.T) {
	m := newSizedPanel(t, 20, 3)
	m, _ = m.Update(TerminalOutputMsg{Slug: "test", Data: []byte("好x")})

	first := strings.SplitN(m.cachedRender, "\n", 2)[0]
	if got := lipgloss.Width(first); got != 3 {
		t.Fatalf("expected width 3 for wide char + x, got %d (%q)", got, first)
	}
}
