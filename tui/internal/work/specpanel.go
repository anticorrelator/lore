package work

import (
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/vt"
	"github.com/creack/pty"
)

// StreamCompleteMsg is sent when the subprocess stream channel is closed (process exited).
type StreamCompleteMsg struct {
	Slug string
}

// StreamErrorMsg is sent when the subprocess exits with a non-zero exit code.
type StreamErrorMsg struct {
	Slug string
	Err  error
}

// TerminalOutputMsg carries a chunk of raw bytes read from the PTY master.
type TerminalOutputMsg struct {
	Slug string
	Data []byte
}

// SpecProcessStartedMsg is sent after the subprocess is launched via PTY.
type SpecProcessStartedMsg struct {
	Slug   string
	Ptmx   *os.File     // PTY master — read/write interface to subprocess
	Cmd    *exec.Cmd    // for cmd.Wait() in cleanup
	Output <-chan []byte // byte chunks from the PTY reader goroutine
}

// TerminalDetachMsg is sent when user presses Ctrl+] to detach from terminal
// focus without killing the subprocess (panel stays open, subprocess keeps running).
type TerminalDetachMsg struct {
	Slug string
}

// TerminalTerminateMsg is sent when user presses Ctrl+\ to kill the subprocess
// and close the spec panel entirely.
type TerminalTerminateMsg struct {
	Slug string
}

const maxScrollBufLines = 5000

// ansiStripRE matches ANSI/VT escape sequences for removal from scrollback text.
var ansiStripRE = regexp.MustCompile(`\x1b(?:\[[0-9;?]*[A-Za-z]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[^[\]])`)

func stripAnsi(s string) string {
	s = ansiStripRE.ReplaceAllString(s, "")
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.ReplaceAll(s, "\r", "\n")
	return s
}

// SpecPanelModel is the Bubble Tea model for the interactive spec panel.
type SpecPanelModel struct {
	slug       string
	width      int
	height     int
	open       bool
	emulator   *vt.Emulator
	done       bool
	hasError   bool
	ptmx       *os.File
	cmd        *exec.Cmd
	outputChan <-chan []byte

	// scrollBuf accumulates ANSI-stripped lines for scrollback viewing.
	// scrollOffset is lines from the bottom (0 = live view).
	scrollBuf    []string
	scrollOffset int
}

// NewSpecPanelModel creates a spec panel model for the given work item slug.
func NewSpecPanelModel(slug string) SpecPanelModel {
	return SpecPanelModel{
		slug:     slug,
		open:     true,
		emulator: vt.NewEmulator(80, 24),
	}
}

// Slug returns the work item slug this panel is running for.
func (m SpecPanelModel) Slug() string {
	return m.slug
}

// HasError returns true if the subprocess exited with an error.
func (m SpecPanelModel) HasError() bool {
	return m.hasError
}

// IsDone returns true if the subprocess has exited (successfully or with error).
func (m SpecPanelModel) IsDone() bool {
	return m.done
}

// Ptmx returns the PTY master file descriptor, or nil if no PTY is active.
func (m SpecPanelModel) Ptmx() *os.File {
	return m.ptmx
}

// OutputChan returns the output channel for PTY polling.
func (m SpecPanelModel) OutputChan() <-chan []byte {
	return m.outputChan
}

// SetPtmx stores the PTY master, command, and output channel after process launch.
// Returns the updated model (value semantics).
func (m SpecPanelModel) SetPtmx(ptmx *os.File, cmd *exec.Cmd, output <-chan []byte) SpecPanelModel {
	m.ptmx = ptmx
	m.cmd = cmd
	m.outputChan = output
	return m
}

// Cleanup closes the PTY master and kills the subprocess immediately, then
// reaps it in a background goroutine so the caller is never blocked.
// Safe to call multiple times (nil ptmx check).
func (m SpecPanelModel) Cleanup() SpecPanelModel {
	if m.ptmx != nil {
		m.ptmx.Close()
		m.ptmx = nil
	}
	if m.cmd != nil {
		cmd := m.cmd
		m.cmd = nil
		if cmd.Process != nil {
			cmd.Process.Kill()
		}
		go cmd.Wait() // reap without blocking the event loop
	}
	return m
}

func (m SpecPanelModel) Init() tea.Cmd {
	return nil
}

func (m SpecPanelModel) Update(msg tea.Msg) (SpecPanelModel, tea.Cmd) {
	switch msg := msg.(type) {
	case SpecProcessStartedMsg:
		m.ptmx = msg.Ptmx
		m.cmd = msg.Cmd
		m.outputChan = msg.Output
		return m, PollTerminalCmd(m.slug, m.outputChan)

	case TerminalOutputMsg:
		if len(msg.Data) > 0 {
			_, _ = m.emulator.Write(msg.Data)
			stripped := stripAnsi(string(msg.Data))
			for _, line := range strings.Split(stripped, "\n") {
				if line != "" {
					m.scrollBuf = append(m.scrollBuf, line)
				}
			}
			if len(m.scrollBuf) > maxScrollBufLines {
				m.scrollBuf = m.scrollBuf[len(m.scrollBuf)-maxScrollBufLines:]
			}
		}
		return m, nil

	case tea.MouseMsg:
		visH := m.height - 2
		if visH < 1 {
			visH = 1
		}
		switch msg.Type {
		case tea.MouseWheelUp:
			m.scrollOffset += 3
			maxOff := len(m.scrollBuf) - visH
			if maxOff < 0 {
				maxOff = 0
			}
			if m.scrollOffset > maxOff {
				m.scrollOffset = maxOff
			}
		case tea.MouseWheelDown:
			m.scrollOffset -= 3
			if m.scrollOffset < 0 {
				m.scrollOffset = 0
			}
		}
		return m, nil

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		// Reserve 1 line for title
		vpHeight := msg.Height - 1
		if vpHeight < 1 {
			vpHeight = 1
		}
		m.emulator.Resize(msg.Width, vpHeight)
		return m, nil

	case StreamCompleteMsg:
		m.done = true
		return m, nil

	case StreamErrorMsg:
		m.hasError = true
		m.done = true
		m.emulator.Write([]byte(fmt.Sprintf("\n[error] %v\n", msg.Err)))
		return m, nil

	case tea.KeyMsg:
		// This handler is only reached when focusedPanel == panelSpec, meaning
		// the terminal has keyboard focus. Intercept escape chords and scroll keys;
		// forward all other keys to the PTY subprocess.
		switch msg.Type {
		case tea.KeyEscape: // Esc — detach, return focus to detail panel
			slug := m.slug
			return m, func() tea.Msg { return TerminalDetachMsg{Slug: slug} }
		case tea.KeyCtrlBackslash: // Ctrl+\ — terminate subprocess
			slug := m.slug
			return m, func() tea.Msg { return TerminalTerminateMsg{Slug: slug} }

		default:
			if m.ptmx != nil {
				if b := keyToBytes(msg); b != nil {
					m.ptmx.Write(b)
				}
			}
			return m, nil
		}
	}

	return m, nil
}


func (m SpecPanelModel) View() string {
	titleStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("4")).Bold(true)
	if m.hasError {
		titleStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("1")).Bold(true)
	}

	var title string
	if m.done {
		if m.hasError {
			title = "Spec · error"
		} else {
			title = "Spec · done"
		}
	} else if m.scrollOffset > 0 {
		title = fmt.Sprintf("Spec · %s [↑ scroll · wheel to navigate]", m.slug)
	} else {
		title = fmt.Sprintf("Spec · %s [live]", m.slug)
	}

	// Scrollback view: render from accumulated text buffer when scrolled up.
	if m.scrollOffset > 0 && len(m.scrollBuf) > 0 {
		visH := m.height - 2
		if visH < 1 {
			visH = 1
		}
		endIdx := len(m.scrollBuf) - m.scrollOffset
		if endIdx < 0 {
			endIdx = 0
		}
		startIdx := endIdx - visH
		if startIdx < 0 {
			startIdx = 0
		}
		var lines []string
		for i := startIdx; i < endIdx && i < len(m.scrollBuf); i++ {
			lines = append(lines, "  "+m.scrollBuf[i])
		}
		for len(lines) < visH {
			lines = append(lines, "")
		}
		return "  " + titleStyle.Render(title) + "\n" + strings.Join(lines, "\n")
	}

	// Live view via VT emulator
	rendered := m.emulator.Render()
	if rendered == "" && !m.done {
		dimS := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
		return "  " + titleStyle.Render(title) + "\n" + dimS.Render("  Waiting for output...")
	}

	return "  " + titleStyle.Render(title) + "\n" + rendered
}

// PollTerminalCmd returns a Cmd that waits 50ms then drains one chunk from the
// PTY output channel. Returns TerminalOutputMsg with the byte data (tagged with
// slug), or StreamCompleteMsg when the channel is closed.
func PollTerminalCmd(slug string, ch <-chan []byte) tea.Cmd {
	return tea.Tick(50*time.Millisecond, func(t time.Time) tea.Msg {
		select {
		case data, ok := <-ch:
			if !ok {
				return StreamCompleteMsg{Slug: slug}
			}
			return TerminalOutputMsg{Slug: slug, Data: data}
		default:
			return TerminalOutputMsg{Slug: slug, Data: nil}
		}
	})
}

// StartTerminalCmd spawns the claude subprocess for /spec inside a PTY and
// returns SpecProcessStartedMsg with the PTY master, exec.Cmd, and a channel
// of raw byte chunks read from the PTY. The PTY master is the read/write
// interface — write user keystrokes, read subprocess output.
// projectDir must be the project root (not the knowledge _work/ dir) so that
// the /spec skill can explore the correct codebase.
func StartTerminalCmd(slug, title, projectDir string, width, height int, extraContext string, shortMode, chatMode, skipConfirm bool) tea.Cmd {
	return func() tea.Msg {
		// Build the initial prompt to auto-submit. Passing it as a positional
		// argument to claude starts an interactive session and submits it
		// immediately — no PTY-write timing hack needed.
		var initialPrompt string
		if chatMode {
			initialPrompt = "Let's talk about the " + title + " work item"
			if extraContext != "" {
				initialPrompt += ": " + extraContext
			}
		} else {
			initialPrompt = "/spec "
			if shortMode {
				initialPrompt += "short "
			}
			initialPrompt += slug
			if skipConfirm {
				initialPrompt += " --yes"
			}
			if extraContext != "" {
				initialPrompt += " -- " + extraContext
			}
		}

		cmd := exec.Command("claude", "--dangerously-skip-permissions", initialPrompt)
		cmd.Dir = projectDir
		// Do NOT set cmd.Stderr = io.Discard here: with a PTY the subprocess's
		// stdin/stdout/stderr are all wired to the PTY slave, so claude's full
		// TUI output (including stderr) is captured by the emulator. Discarding
		// stderr would black out parts of claude's interface.

		ws := &pty.Winsize{
			Rows: uint16(height),
			Cols: uint16(width),
		}
		ptmx, err := pty.StartWithSize(cmd, ws)
		if err != nil {
			return StreamErrorMsg{Slug: slug, Err: fmt.Errorf("pty start: %w", err)}
		}

		outputCh := make(chan []byte, 64)
		go func() {
			defer close(outputCh)
			buf := make([]byte, 32*1024)
			for {
				n, err := ptmx.Read(buf)
				if n > 0 {
					chunk := make([]byte, n)
					copy(chunk, buf[:n])
					outputCh <- chunk
				}
				if err != nil {
					break // EIO on Linux, EOF on macOS after subprocess exits
				}
			}
		}()

		return SpecProcessStartedMsg{
			Slug:   slug,
			Ptmx:   ptmx,
			Cmd:    cmd,
			Output: outputCh,
		}
	}
}

// keyToBytes converts a BubbleTea KeyMsg into the raw byte sequence that
// should be written to a PTY to reproduce that keypress. Returns nil for
// unknown key types.
func keyToBytes(km tea.KeyMsg) []byte {
	var b []byte

	switch km.Type {
	case tea.KeyRunes:
		b = []byte(string(km.Runes))
	case tea.KeySpace:
		b = []byte{' '}
	case tea.KeyEnter:
		b = []byte{'\r'}
	case tea.KeyBackspace:
		b = []byte{0x7f}
	case tea.KeyTab:
		b = []byte{'\t'}
	case tea.KeyEscape:
		b = []byte{0x1b}
	case tea.KeyUp:
		b = []byte{0x1b, '[', 'A'}
	case tea.KeyDown:
		b = []byte{0x1b, '[', 'B'}
	case tea.KeyRight:
		b = []byte{0x1b, '[', 'C'}
	case tea.KeyLeft:
		b = []byte{0x1b, '[', 'D'}
	case tea.KeyHome:
		b = []byte{0x1b, '[', 'H'}
	case tea.KeyEnd:
		b = []byte{0x1b, '[', 'F'}
	case tea.KeyPgUp:
		b = []byte{0x1b, '[', '5', '~'}
	case tea.KeyPgDown:
		b = []byte{0x1b, '[', '6', '~'}
	case tea.KeyDelete:
		b = []byte{0x1b, '[', '3', '~'}
	case tea.KeyInsert:
		b = []byte{0x1b, '[', '2', '~'}
	case tea.KeyCtrlA:
		b = []byte{0x01}
	case tea.KeyCtrlB:
		b = []byte{0x02}
	case tea.KeyCtrlC:
		b = []byte{0x03}
	case tea.KeyCtrlD:
		b = []byte{0x04}
	case tea.KeyCtrlE:
		b = []byte{0x05}
	case tea.KeyCtrlF:
		b = []byte{0x06}
	case tea.KeyCtrlG:
		b = []byte{0x07}
	case tea.KeyCtrlH:
		b = []byte{0x08}
	case tea.KeyCtrlJ:
		b = []byte{0x0a}
	case tea.KeyCtrlK:
		b = []byte{0x0b}
	case tea.KeyCtrlL:
		b = []byte{0x0c}
	case tea.KeyCtrlN:
		b = []byte{0x0e}
	case tea.KeyCtrlO:
		b = []byte{0x0f}
	case tea.KeyCtrlP:
		b = []byte{0x10}
	case tea.KeyCtrlQ:
		b = []byte{0x11}
	case tea.KeyCtrlR:
		b = []byte{0x12}
	case tea.KeyCtrlS:
		b = []byte{0x13}
	case tea.KeyCtrlT:
		b = []byte{0x14}
	case tea.KeyCtrlU:
		b = []byte{0x15}
	case tea.KeyCtrlV:
		b = []byte{0x16}
	case tea.KeyCtrlW:
		b = []byte{0x17}
	case tea.KeyCtrlX:
		b = []byte{0x18}
	case tea.KeyCtrlY:
		b = []byte{0x19}
	case tea.KeyCtrlZ:
		b = []byte{0x1a}
	case tea.KeyCtrlBackslash:
		b = []byte{0x1c}
	case tea.KeyCtrlCloseBracket:
		b = []byte{0x1d}
	default:
		return nil
	}

	// Alt modifier prepends ESC
	if km.Alt && km.Type != tea.KeyEscape {
		return append([]byte{0x1b}, b...)
	}
	return b
}
