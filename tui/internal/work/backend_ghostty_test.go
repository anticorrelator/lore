package work

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	libghostty "go.mitchellh.com/libghostty"
)

type terminalVisualFixture struct {
	Encoding       string        `json:"encoding"`
	Cols           int           `json:"cols"`
	Rows           int           `json:"rows"`
	ComposerRow    int           `json:"composer_row"`
	BackgroundSpan [2]int        `json:"background_span"`
	BackgroundRGB  [3]uint8      `json:"background_rgb"`
	FaintSpan      [2]int        `json:"faint_span"`
	InverseCells   []int         `json:"inverse_cells"`
	Cursor         fixtureCursor `json:"cursor"`
	PlainRows      []string      `json:"plain_rows"`
}

type fixtureCursor struct {
	X        int      `json:"x"`
	Y        int      `json:"y"`
	Shape    string   `json:"shape"`
	Blink    bool     `json:"blink"`
	ColorRGB [3]uint8 `json:"color_rgb"`
}

func loadTerminalVisualFixture(t *testing.T) (terminalVisualFixture, []byte) {
	t.Helper()
	var fixture terminalVisualFixture
	metadata, err := os.ReadFile(filepath.Join("testdata", "terminal-visual-fidelity.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(metadata, &fixture); err != nil {
		t.Fatal(err)
	}
	encoded, err := os.ReadFile(filepath.Join("testdata", "terminal-visual-fidelity.ansi"))
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := strconv.Unquote(`"` + strings.TrimSpace(string(encoded)) + `"`)
	if err != nil {
		t.Fatalf("decode ANSI fixture: %v", err)
	}
	return fixture, []byte(decoded)
}

type fixtureCellState struct {
	HasBackground bool
	Background    [3]uint8
	Faint         bool
	Inverse       bool
}

func ghosttyFixtureRow(t *testing.T, b *terminalBackend, target int) []fixtureCellState {
	t.Helper()
	if err := b.rs.Update(b.term); err != nil {
		t.Fatal(err)
	}
	if err := b.rs.RowIterator(b.ri); err != nil {
		t.Fatal(err)
	}
	row := 0
	for b.ri.Next() {
		if err := b.ri.Cells(b.rc); err != nil {
			t.Fatal(err)
		}
		if row != target {
			row++
			continue
		}
		var cells []fixtureCellState
		for b.rc.Next() {
			var style libghostty.RenderCellStyle
			if err := b.rc.StyleInto(&style); err != nil {
				t.Fatal(err)
			}
			cells = append(cells, fixtureCellState{
				HasBackground: style.HasBackground,
				Background:    [3]uint8{style.Background.R, style.Background.G, style.Background.B},
				Faint:         style.Faint,
				Inverse:       style.Inverse,
			})
		}
		return cells
	}
	t.Fatalf("fixture row %d not found", target)
	return nil
}

func renderedFixtureRows(render string) [][]fixtureCellState {
	rows := [][]fixtureCellState{{}}
	state := fixtureCellState{}
	for i := 0; i < len(render); {
		if render[i] == '\x1b' && i+1 < len(render) && render[i+1] == '[' {
			end := i + 2
			for end < len(render) && render[end] != 'm' {
				end++
			}
			if end < len(render) {
				applyFixtureSGR(&state, render[i+2:end])
				i = end + 1
				continue
			}
		}
		if render[i] == '\n' {
			rows = append(rows, []fixtureCellState{})
			i++
			continue
		}
		rows[len(rows)-1] = append(rows[len(rows)-1], state)
		i++
	}
	return rows
}

func applyFixtureSGR(state *fixtureCellState, sequence string) {
	if sequence == "" {
		sequence = "0"
	}
	parts := strings.Split(sequence, ";")
	for i := 0; i < len(parts); i++ {
		code, _ := strconv.Atoi(parts[i])
		switch code {
		case 0:
			*state = fixtureCellState{}
		case 2:
			state.Faint = true
		case 22:
			state.Faint = false
		case 7:
			state.Inverse = true
		case 27:
			state.Inverse = false
		case 48:
			if i+4 < len(parts) && parts[i+1] == "2" {
				r, _ := strconv.Atoi(parts[i+2])
				g, _ := strconv.Atoi(parts[i+3])
				b, _ := strconv.Atoi(parts[i+4])
				state.HasBackground = true
				state.Background = [3]uint8{uint8(r), uint8(g), uint8(b)}
				i += 4
			}
		case 49:
			state.HasBackground = false
			state.Background = [3]uint8{}
		}
	}
}

func assertFixtureAttributes(t *testing.T, fixture terminalVisualFixture, cells []fixtureCellState) {
	t.Helper()
	for x := fixture.BackgroundSpan[0]; x <= fixture.BackgroundSpan[1]; x++ {
		if x >= len(cells) {
			t.Fatalf("background span ends at %d but row has %d cells", fixture.BackgroundSpan[1], len(cells))
		}
		if !cells[x].HasBackground || cells[x].Background != fixture.BackgroundRGB {
			t.Errorf("cell %d background = present:%v rgb:%v, want %v", x, cells[x].HasBackground, cells[x].Background, fixture.BackgroundRGB)
		}
	}
	for x := fixture.FaintSpan[0]; x <= fixture.FaintSpan[1]; x++ {
		if !cells[x].Faint {
			t.Errorf("cell %d is not faint", x)
		}
	}
	for _, x := range fixture.InverseCells {
		if x >= len(cells) || !cells[x].Inverse {
			t.Errorf("cell %d is not inverse", x)
		}
	}
}

func TestTerminalVisualFidelityFixture(t *testing.T) {
	fixture, stream := loadTerminalVisualFixture(t)
	m := newSizedPanel(t, fixture.Cols, fixture.Rows)
	m, _ = m.Update(TerminalOutputMsg{Slug: "test", Data: stream})

	t.Run("ghostty-cell-state", func(t *testing.T) {
		assertFixtureAttributes(t, fixture, ghosttyFixtureRow(t, m.backend, fixture.ComposerRow))
	})

	t.Run("adapter-emission", func(t *testing.T) {
		rows := renderedFixtureRows(m.cachedRender)
		if fixture.ComposerRow >= len(rows) {
			t.Fatalf("rendered row %d missing from %d rows", fixture.ComposerRow, len(rows))
		}
		assertFixtureAttributes(t, fixture, rows[fixture.ComposerRow])
	})

	t.Run("plain-observer-and-cursor", func(t *testing.T) {
		snapshot, err := m.ScreenState()
		if err != nil {
			t.Fatal(err)
		}
		if fmt.Sprint(snapshot.Rows) != fmt.Sprint(fixture.PlainRows) {
			t.Fatalf("plain rows = %#v, want %#v", snapshot.Rows, fixture.PlainRows)
		}
		visual := m.TerminalVisual()
		if visual.Cursor == nil {
			t.Fatal("visible viewport cursor missing")
		}
		if visual.Cursor.X != fixture.Cursor.X || visual.Cursor.Y != fixture.Cursor.Y || visual.Cursor.Shape != TerminalCursorBar || visual.Cursor.Blink != fixture.Cursor.Blink {
			t.Errorf("cursor = %+v, want x=%d y=%d shape=bar blink=%v", visual.Cursor, fixture.Cursor.X, fixture.Cursor.Y, fixture.Cursor.Blink)
		}
		if visual.Cursor.Color == nil || [3]uint8{visual.Cursor.Color.R, visual.Cursor.Color.G, visual.Cursor.Color.B} != fixture.Cursor.ColorRGB {
			t.Errorf("cursor color = %v, want %v", visual.Cursor.Color, fixture.Cursor.ColorRGB)
		}
	})

	t.Run("cursor-suppression", func(t *testing.T) {
		hidden, _ := m.Update(TerminalOutputMsg{Slug: "test", Data: []byte("\x1b[?25l")})
		if cursor := hidden.TerminalVisual().Cursor; cursor != nil {
			t.Errorf("hidden cursor remained visible: %+v", cursor)
		}

		scrolled := m
		scrolled.scrollOffset = 1
		if cursor := scrolled.TerminalVisual().Cursor; cursor != nil {
			t.Errorf("scrollback published cursor: %+v", cursor)
		}

		done, _ := m.Update(StreamCompleteMsg{Slug: "test"})
		if cursor := done.TerminalVisual().Cursor; cursor != nil {
			t.Errorf("completed panel published cursor: %+v", cursor)
		}
	})
}

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
	// Scrollback reserves one of the 24 rows for its position indicator.
	maxOff := maxScrollOffset(m.totalLines(), 24)
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
