package work

import (
	"fmt"
	"os"
	"strings"
	"sync"

	libghostty "go.mitchellh.com/libghostty"
)

// maxScrollbackBytes caps the native scrollback history, set at terminal
// creation (libghostty does not resize it dynamically). Despite the C header
// documenting max_scrollback as "lines", it is a page-memory byte budget:
// measured retention is width-dependent and page-granular (~6000 rows at
// 200 cols for 16MB, more at narrower widths), which comfortably covers the
// 5000-line history the panel previously kept.
const maxScrollbackBytes = 16 << 20

// terminalBackend wraps a libghostty-vt terminal behind the build-tag-selected
// backend seam. Scrollback is native and color-preserving; device-query
// responses (DA1, XTVERSION, DSR) are forwarded to the PTY through the
// WritePty effect callback, which libghostty fires synchronously inside
// write().
//
// All methods must be called from a single goroutine (the Bubble Tea event
// loop) — the underlying terminal is stateful and not safe for concurrent
// use. Functional SpecPanelModel copies share one backend pointer.
type terminalBackend struct {
	term *libghostty.Terminal
	rs   *libghostty.RenderState
	ri   *libghostty.RenderStateRowIterator
	rc   *libghostty.RenderStateRowCells

	// ptmx is resolved at callback-invocation time (not captured at
	// construction) so setPtyWriter can attach the PTY after the terminal
	// already exists. nil drops responses.
	ptmx *os.File

	closed    bool
	closeOnce sync.Once

	// per-row render scratch, reused across rows and renders
	cells []renderCell
	text  []byte
}

// renderCell is one screen cell staged for SGR run-collapsed emission.
// textStart == textEnd means the cell has no text and renders as a blank.
type renderCell struct {
	style              libghostty.RenderCellStyle
	textStart, textEnd int // byte range into the row text scratch buffer
}

func newTerminalBackend(cols, rows int) *terminalBackend {
	if cols < 1 {
		cols = 1
	}
	if rows < 1 {
		rows = 1
	}
	b := &terminalBackend{}
	term, err := libghostty.NewTerminal(
		libghostty.WithSize(uint16(cols), uint16(rows)),
		libghostty.WithMaxScrollback(maxScrollbackBytes),
		// WritePty fires synchronously inside VTWrite with device-query
		// responses. It must not re-enter VTWrite on the same terminal;
		// writing to the PTY master is its only side effect. The data
		// slice is only valid for the call duration, so it is written
		// (not retained) here.
		libghostty.WithWritePty(func(_ *libghostty.Terminal, data []byte) {
			if b.ptmx == nil {
				writeCrashLog("ghostty WritePty", fmt.Sprintf("dropped %d response bytes: no PTY attached", len(data)))
				return
			}
			b.ptmx.Write(data) //nolint:errcheck
		}),
	)
	if err != nil {
		writeCrashLog("newTerminalBackend", err)
		b.closed = true
		return b
	}
	rs, err := libghostty.NewRenderState()
	if err == nil {
		b.ri, err = libghostty.NewRenderStateRowIterator()
	}
	if err == nil {
		b.rc, err = libghostty.NewRenderStateRowCells()
	}
	if err != nil {
		writeCrashLog("newTerminalBackend", err)
		if b.ri != nil {
			b.ri.Close()
		}
		if rs != nil {
			rs.Close()
		}
		term.Close()
		b.term, b.rs, b.ri, b.rc = nil, nil, nil, nil
		b.closed = true
		return b
	}
	b.term = term
	b.rs = rs
	return b
}

// setPtyWriter attaches the PTY master so device-query responses emitted by
// the WritePty callback reach the subprocess.
func (b *terminalBackend) setPtyWriter(ptmx *os.File) {
	if b == nil || b.closed {
		return
	}
	b.ptmx = ptmx
}

// write feeds raw PTY bytes through the terminal parser. Query responses may
// be forwarded to the PTY synchronously before this returns.
func (b *terminalBackend) write(data []byte) {
	if b == nil || b.closed {
		return
	}
	b.term.VTWrite(data)
}

// resize changes the terminal dimensions, reflowing content and scrollback.
func (b *terminalBackend) resize(cols, rows int) {
	if b == nil || b.closed {
		return
	}
	if cols < 1 {
		cols = 1
	}
	if rows < 1 {
		rows = 1
	}
	// Zero pixel dims: only needed for image protocols and size reports.
	if err := b.term.Resize(uint16(cols), uint16(rows), 0, 0); err != nil {
		writeCrashLog("ghostty resize", err)
	}
}

// renderScreen returns the live screen as ANSI text with \n row terminators
// and no stray \r. Always renders from the document bottom regardless of any
// prior scrollback read.
func (b *terminalBackend) renderScreen() string {
	if b == nil || b.closed {
		return ""
	}
	b.term.ScrollViewportBottom()
	rows, err := b.term.Rows()
	if err != nil {
		return ""
	}
	lines, err := b.renderViewportRows(int(rows))
	if err != nil {
		writeCrashLog("ghostty renderScreen", err)
		return ""
	}
	return strings.Join(lines, "\n")
}

// screenState captures the observable terminal state the readiness gate and
// peek both consume: cursor position/visibility, bracketed-paste mode,
// password-input masking, the plain-text screen rows (for signature matching),
// and the ANSI render (for peek --raw). One snapshot serves both so a gate
// decision and the rows a peek reports are captured from the same instant. Like
// every other backend method it must run on the Bubble Tea goroutine — the
// terminal is stateful and not safe for concurrent use.
func (b *terminalBackend) screenState() (ScreenSnapshot, error) {
	if b == nil || b.closed {
		return ScreenSnapshot{}, fmt.Errorf("terminal backend closed")
	}
	b.term.ScrollViewportBottom()
	var snap ScreenSnapshot
	snap.CursorX, _ = b.term.CursorX()
	snap.CursorY, _ = b.term.CursorY()
	snap.CursorVisible, _ = b.term.CursorVisible()
	snap.BracketedPaste, _ = b.term.ModeGet(libghostty.ModeBracketedPaste)
	rows, err := b.term.Rows()
	if err != nil {
		return snap, err
	}
	plain, err := b.plainViewportRows(int(rows))
	if err != nil {
		return snap, err
	}
	snap.Rows = plain
	// Password masking lives on the render state, which plainViewportRows just
	// refreshed from the terminal (rs.Update); read it before any further write.
	snap.PasswordInput, _ = b.rs.CursorPasswordInput()
	snap.ANSI = b.renderScreen()
	return snap, nil
}

// plainViewportRows renders the first n viewport rows as plain text (no SGR),
// one string per row — the form the screen-state signature matchers key on.
func (b *terminalBackend) plainViewportRows(n int) ([]string, error) {
	if err := b.rs.Update(b.term); err != nil {
		return nil, err
	}
	if err := b.rs.RowIterator(b.ri); err != nil {
		return nil, err
	}
	lines := make([]string, 0, n)
	for len(lines) < n && b.ri.Next() {
		if err := b.ri.Cells(b.rc); err != nil {
			return nil, err
		}
		line, err := b.plainRowCells()
		if err != nil {
			return nil, err
		}
		lines = append(lines, line)
	}
	return lines, nil
}

// plainRowCells renders the current row's cells as plain text, dropping wide-char
// spacer cells and trimming trailing blanks. No SGR bytes, no \r or \n.
func (b *terminalBackend) plainRowCells() (string, error) {
	var sb strings.Builder
	var scratch []byte
	for b.rc.Next() {
		scratch = scratch[:0]
		var err error
		scratch, err = b.rc.AppendGraphemes(scratch)
		if err != nil {
			return "", err
		}
		if len(scratch) == 0 {
			raw, err := b.rc.Raw()
			if err != nil {
				return "", err
			}
			wide, err := raw.Wide()
			if err != nil {
				return "", err
			}
			if wide == libghostty.CellWideSpacerTail || wide == libghostty.CellWideSpacerHead {
				continue
			}
			sb.WriteByte(' ')
			continue
		}
		sb.Write(scratch)
	}
	return strings.TrimRight(sb.String(), " "), nil
}

// totalLines returns the document height: native scrollback plus the screen.
func (b *terminalBackend) totalLines() int {
	if b == nil || b.closed {
		return 0
	}
	n, err := b.term.TotalRows()
	if err != nil {
		return 0
	}
	return int(n)
}

// readScrollback returns rows [start,end) of the document (scrollback +
// screen) rendered through the same cell→SGR adapter as the live view. The
// read is observational: the viewport is repositioned for the read and always
// restored to the document bottom, so a subsequent renderScreen sees the live
// screen.
func (b *terminalBackend) readScrollback(start, end int) []string {
	if b == nil || b.closed || end <= start || start < 0 {
		return nil
	}
	b.term.ScrollViewportTop()
	if start > 0 {
		b.term.ScrollViewportDelta(start)
	}
	lines, err := b.renderViewportRows(end - start)
	b.term.ScrollViewportBottom()
	if err != nil {
		writeCrashLog("ghostty readScrollback", err)
		return nil
	}
	return lines
}

// close releases the terminal and render-state handles exactly once. Copied
// model values share one backend, so double-Cleanup must not double-free.
func (b *terminalBackend) close() {
	b.closeOnce.Do(func() {
		b.closed = true
		b.ptmx = nil
		if b.rc != nil {
			b.rc.Close()
		}
		if b.ri != nil {
			b.ri.Close()
		}
		if b.rs != nil {
			b.rs.Close()
		}
		if b.term != nil {
			b.term.Close()
		}
	})
}

// renderViewportRows snapshots the terminal into the render state and renders
// the first n viewport rows, one string per row.
func (b *terminalBackend) renderViewportRows(n int) ([]string, error) {
	if err := b.rs.Update(b.term); err != nil {
		return nil, err
	}
	if err := b.rs.RowIterator(b.ri); err != nil {
		return nil, err
	}
	lines := make([]string, 0, n)
	for len(lines) < n && b.ri.Next() {
		if err := b.ri.Cells(b.rc); err != nil {
			return nil, err
		}
		line, err := b.renderRowCells()
		if err != nil {
			return nil, err
		}
		lines = append(lines, line)
	}
	return lines, nil
}

// renderRowCells renders the current row's cells as ANSI text: an SGR
// sequence opens only when the cell style changes from the previous run,
// a reset closes the line if any style is open, and trailing unstyled blanks
// are trimmed. The output contains no \r or \n and stays
// lipgloss.Width-measurable.
func (b *terminalBackend) renderRowCells() (string, error) {
	cells := b.cells[:0]
	buf := b.text[:0]
	for b.rc.Next() {
		var c renderCell
		if err := b.rc.StyleInto(&c.style); err != nil {
			return "", err
		}
		c.textStart = len(buf)
		var err error
		buf, err = b.rc.AppendGraphemes(buf)
		if err != nil {
			return "", err
		}
		c.textEnd = len(buf)
		if c.textEnd == c.textStart {
			// Textless cell: wide-char spacers occupy a column already
			// accounted for by the wide grapheme (tail) or by line wrap
			// (head) and must not emit output; anything else is a blank.
			raw, err := b.rc.Raw()
			if err != nil {
				return "", err
			}
			wide, err := raw.Wide()
			if err != nil {
				return "", err
			}
			if wide == libghostty.CellWideSpacerTail || wide == libghostty.CellWideSpacerHead {
				continue
			}
		}
		cells = append(cells, c)
	}
	b.cells, b.text = cells, buf

	// Trim trailing unstyled blank cells.
	defaultStyle := libghostty.RenderCellStyle{}
	last := len(cells)
	for last > 0 {
		c := cells[last-1]
		if c.style != defaultStyle {
			break
		}
		txt := buf[c.textStart:c.textEnd]
		if len(txt) > 0 && !(len(txt) == 1 && txt[0] == ' ') {
			break
		}
		last--
	}

	var sb strings.Builder
	cur := defaultStyle
	for _, c := range cells[:last] {
		if c.style != cur {
			appendSGR(&sb, c.style)
			cur = c.style
		}
		if c.textEnd > c.textStart {
			sb.Write(buf[c.textStart:c.textEnd])
		} else {
			sb.WriteByte(' ')
		}
	}
	if cur != defaultStyle {
		sb.WriteString("\x1b[0m")
	}
	return sb.String(), nil
}

// appendSGR writes a single SGR sequence that resets and then applies the
// given style; for the zero style this is a plain reset.
func appendSGR(sb *strings.Builder, s libghostty.RenderCellStyle) {
	sb.WriteString("\x1b[0")
	if s.Bold {
		sb.WriteString(";1")
	}
	if s.Faint {
		sb.WriteString(";2")
	}
	if s.Italic {
		sb.WriteString(";3")
	}
	if s.Underline {
		sb.WriteString(";4")
	}
	if s.Inverse {
		sb.WriteString(";7")
	}
	if s.Strikethrough {
		sb.WriteString(";9")
	}
	if s.HasForeground {
		fmt.Fprintf(sb, ";38;2;%d;%d;%d", s.Foreground.R, s.Foreground.G, s.Foreground.B)
	}
	if s.HasBackground {
		fmt.Fprintf(sb, ";48;2;%d;%d;%d", s.Background.R, s.Background.G, s.Background.B)
	}
	sb.WriteByte('m')
}
