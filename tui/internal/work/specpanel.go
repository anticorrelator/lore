package work

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime/debug"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/vt"
	"github.com/creack/pty"
)

// NeedsInputChangedMsg is sent when a spec panel's needsInput state changes.
type NeedsInputChangedMsg struct {
	Slug       string
	NeedsInput bool
}

// QuiescenceTickMsg is the periodic tick used to check for output quiescence.
type QuiescenceTickMsg struct {
	Slug string
}

// quiescenceThreshold is how long after the last PTY output before we consider
// the session idle and potentially waiting for user input.
const quiescenceThreshold = 5 * time.Second

// QuiescenceTickCmd returns a tea.Cmd that fires a QuiescenceTickMsg after 1 second.
func QuiescenceTickCmd(slug string) tea.Cmd {
	return tea.Tick(time.Second, func(t time.Time) tea.Msg {
		return QuiescenceTickMsg{Slug: slug}
	})
}

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

// writeCrashLog writes a panic stack trace to a temp file for post-mortem debugging.
func writeCrashLog(label string, r interface{}) {
	crashLog := filepath.Join(os.TempDir(), "lore-tui-crash.log")
	stack := fmt.Sprintf("panic in %s: %v\n\n%s", label, r, debug.Stack())
	_ = os.WriteFile(crashLog, []byte(stack), 0644)
}

// readScreenLines reads the current emulator screen as plain text lines,
// one string per row, with trailing spaces trimmed.
func readScreenLines(emu *vt.Emulator) []string {
	h := emu.Height()
	w := emu.Width()
	lines := make([]string, h)
	for y := 0; y < h; y++ {
		var b strings.Builder
		for x := 0; x < w; x++ {
			cell := emu.CellAt(x, y)
			if cell == nil || cell.Width == 0 {
				// Zero-width cells are placeholders for wide chars — skip.
				continue
			}
			b.WriteString(cell.Content)
		}
		lines[y] = strings.TrimRight(b.String(), " ")
	}
	return lines
}

// safeReadScreenLines wraps readScreenLines with panic recovery to guard
// against vt emulator bugs (e.g. CellAt on corrupt state).
func safeReadScreenLines(emu *vt.Emulator) (lines []string) {
	defer func() {
		if r := recover(); r != nil {
			lines = nil
		}
	}()
	return readScreenLines(emu)
}

// safeRender wraps emulator.Render() with panic recovery.
func safeRender(emu *vt.Emulator) (result string) {
	defer func() {
		if r := recover(); r != nil {
			result = ""
		}
	}()
	return strings.ReplaceAll(emu.Render(), "\r\n", "\n")
}

// detectScrollUp compares the previous and current screen snapshots to find
// how many lines scrolled off the top. Returns the smallest k >= 1 where a
// sufficient number of contiguous lines from the top of cur match the
// corresponding lines from prev shifted by k, meaning prev[0:k] scrolled off.
//
// Uses contiguous-from-top matching rather than requiring all h-k lines to
// match. This is critical for Ink-based apps (like Claude Code) which
// re-render the bottom portion of the screen (spinner, streaming token) on
// every update — only the top portion (committed static content) is stable
// across writes.
func detectScrollUp(prev, cur []string) int {
	h := len(prev)
	if h == 0 || h != len(cur) {
		return 0
	}

	// Minimum contiguous matching lines from the top to accept a scroll.
	minMatch := 3
	if h <= 4 {
		minMatch = 1
	} else if h <= 8 {
		minMatch = 2
	}

	// Allow detecting scrolls up to h - minMatch lines (need at least
	// minMatch lines remaining to compare).
	limit := h - minMatch
	if limit < 1 {
		limit = 1
	}

	for k := 1; k <= limit; k++ {
		// Count contiguous matching lines from the top.
		matchCount := 0
		for i := 0; i < h-k; i++ {
			if cur[i] == prev[i+k] {
				matchCount++
			} else {
				break
			}
		}
		if matchCount >= minMatch {
			return k
		}
	}
	return 0
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

	// cachedRender holds the last emulator.Render() output, updated in Update()
	// handlers so that View() can return it in O(1) without re-rendering.
	cachedRender string

	// scrollBuf accumulates lines that scrolled off the top of the emulator
	// screen, detected by diffing screen snapshots between writes.
	// scrollOffset is lines from the bottom of the virtual document (0 = live view).
	scrollBuf    []string
	scrollOffset int

	// prevScreen holds the screen content (one string per row) after the
	// last emulator write. Used to detect scrolling via screen-diff.
	prevScreen []string

	// lastOutputTime records when the last TerminalOutputMsg was received.
	// Used for quiescence detection — if no output arrives for a threshold
	// period, the session is considered idle and may need user input.
	lastOutputTime time.Time

	// needsInput is true when the terminal session has been quiescent
	// (no PTY output) for longer than the quiescence threshold, indicating
	// the subprocess is likely waiting for user input.
	needsInput bool

	// stopDrain signals the emulator response drain goroutine to exit.
	stopDrain chan struct{}
	// ptmxCh sends the PTY master to the drain goroutine for response forwarding.
	ptmxCh chan *os.File
}

// NewSpecPanelModel creates a spec panel model for the given work item slug.
// A background goroutine drains the emulator's response pipe so that DA1,
// XTVERSION, and similar query responses don't block emulator.Write().
// Responses are forwarded to the PTY once attached via SetPtmx.
func NewSpecPanelModel(slug string) SpecPanelModel {
	emu := vt.NewEmulator(80, 24)
	stopDrain := make(chan struct{})
	ptmxCh := make(chan *os.File, 1)
	go drainEmulatorResponses(emu, ptmxCh, stopDrain)
	return SpecPanelModel{
		slug:      slug,
		open:      true,
		emulator:  emu,
		stopDrain: stopDrain,
		ptmxCh:    ptmxCh,
	}
}

// drainEmulatorResponses reads from the emulator's response pipe and optionally
// forwards data to the PTY master. Runs until the emulator is closed (Read
// returns an error). The ptmxCh delivers the PTY master once available.
func drainEmulatorResponses(emu *vt.Emulator, ptmxCh <-chan *os.File, stop <-chan struct{}) {
	var ptmx *os.File
	buf := make([]byte, 4096)
	// emu.Read blocks on io.Pipe, so run it in a sub-goroutine and
	// multiplex with the stop channel.
	type readResult struct {
		n   int
		err error
	}
	readCh := make(chan readResult, 1)
	go func() {
		for {
			n, err := emu.Read(buf)
			readCh <- readResult{n, err}
			if err != nil {
				return
			}
		}
	}()
	for {
		select {
		case <-stop:
			emu.Close() // unblocks the Read goroutine
			return
		case f := <-ptmxCh:
			ptmx = f
		case r := <-readCh:
			if r.n > 0 && ptmx != nil {
				data := make([]byte, r.n)
				copy(data, buf[:r.n])
				ptmx.Write(data) //nolint:errcheck
			}
			if r.err != nil {
				return
			}
		}
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

// NeedsInput returns true if the terminal session has been quiescent long
// enough to suggest the subprocess is waiting for user input.
func (m SpecPanelModel) NeedsInput() bool {
	return m.needsInput
}

// LastOutputTime returns when the last PTY output was received.
func (m SpecPanelModel) LastOutputTime() time.Time {
	return m.lastOutputTime
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
// Also notifies the drain goroutine so emulator responses are forwarded to the PTY.
// Returns the updated model (value semantics).
func (m SpecPanelModel) SetPtmx(ptmx *os.File, cmd *exec.Cmd, output <-chan []byte) SpecPanelModel {
	m.ptmx = ptmx
	m.cmd = cmd
	m.outputChan = output
	if m.ptmxCh != nil && ptmx != nil {
		select {
		case m.ptmxCh <- ptmx:
		default:
		}
	}
	return m
}

// Cleanup closes the PTY master, kills the subprocess, stops the emulator
// response drain goroutine, and closes the emulator. Reaps the subprocess in
// a background goroutine so the caller is never blocked.
// Safe to call multiple times (nil checks throughout).
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
	if m.stopDrain != nil {
		close(m.stopDrain)
		m.stopDrain = nil
	}
	if m.emulator != nil {
		m.emulator.Close()
	}
	return m
}

func (m SpecPanelModel) Init() tea.Cmd {
	return nil
}

// totalLines returns the total number of lines in the virtual document
// (scrollback history + current screen).
func (m SpecPanelModel) totalLines() int {
	return len(m.scrollBuf) + len(m.prevScreen)
}

func (m SpecPanelModel) Update(msg tea.Msg) (_ SpecPanelModel, _ tea.Cmd) {
	defer func() {
		if r := recover(); r != nil {
			writeCrashLog(fmt.Sprintf("SpecPanelModel.Update(%T)", msg), r)
		}
	}()
	switch msg := msg.(type) {
	case SpecProcessStartedMsg:
		m.ptmx = msg.Ptmx
		m.cmd = msg.Cmd
		m.outputChan = msg.Output
		// Notify drain goroutine so it can forward emulator responses to the PTY.
		if m.ptmxCh != nil && msg.Ptmx != nil {
			select {
			case m.ptmxCh <- msg.Ptmx:
			default:
			}
		}
		return m, tea.Batch(
			PollTerminalCmd(m.slug, m.outputChan),
			QuiescenceTickCmd(m.slug),
		)

	case TerminalOutputMsg:
		func() {
			defer func() { recover() }() // guard against vt emulator panics
			m.emulator.Write(msg.Data)
		}()

		// Track output timing for quiescence detection.
		m.lastOutputTime = time.Now()
		var cmds []tea.Cmd
		if m.needsInput {
			m.needsInput = false
			slug := m.slug
			cmds = append(cmds, func() tea.Msg {
				return NeedsInputChangedMsg{Slug: slug, NeedsInput: false}
			})
		}

		// Snapshot current screen and detect scrolled-off lines.
		curScreen := safeReadScreenLines(m.emulator)
		if m.prevScreen != nil {
			k := detectScrollUp(m.prevScreen, curScreen)
			if k > 0 {
				for i := 0; i < k; i++ {
					m.scrollBuf = append(m.scrollBuf, m.prevScreen[i])
				}
				if m.scrollOffset > 0 {
					m.scrollOffset += k
				}
			}
		}
		m.prevScreen = curScreen

		// Trim scrollback buffer to cap.
		if len(m.scrollBuf) > maxScrollBufLines {
			trimCount := len(m.scrollBuf) - maxScrollBufLines
			m.scrollBuf = m.scrollBuf[trimCount:]
			m.scrollOffset -= trimCount
			if m.scrollOffset < 0 {
				m.scrollOffset = 0
			}
		}

		// Clamp scroll offset.
		if m.scrollOffset > 0 {
			visH := m.height
			if visH < 1 {
				visH = 1
			}
			maxOff := m.totalLines() - visH
			if maxOff < 0 {
				maxOff = 0
			}
			if m.scrollOffset > maxOff {
				m.scrollOffset = maxOff
			}
		}

		m.cachedRender = safeRender(m.emulator)
		if len(cmds) > 0 {
			return m, tea.Batch(cmds...)
		}
		return m, nil

	case QuiescenceTickMsg:
		// Ignore ticks for other panels or if panel is done.
		if msg.Slug != m.slug || m.done {
			return m, nil
		}
		// Check if output has been quiescent long enough.
		if !m.lastOutputTime.IsZero() && time.Since(m.lastOutputTime) > quiescenceThreshold && !m.needsInput {
			m.needsInput = true
			slug := m.slug
			return m, tea.Batch(
				func() tea.Msg { return NeedsInputChangedMsg{Slug: slug, NeedsInput: true} },
				QuiescenceTickCmd(m.slug),
			)
		}
		// Re-arm the tick.
		return m, QuiescenceTickCmd(m.slug)

	case tea.MouseMsg:
		visH := m.height
		if visH < 1 {
			visH = 1
		}
		switch msg.Type {
		case tea.MouseWheelUp:
			m.scrollOffset += 3
			maxOff := m.totalLines() - visH
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
		vpWidth := msg.Width
		if vpWidth < 1 {
			vpWidth = 1
		}
		vpHeight := msg.Height
		if vpHeight < 1 {
			vpHeight = 1
		}
		m.emulator.Resize(vpWidth, vpHeight)
		// Invalidate prevScreen — height changed, screen content is reflowed.
		m.prevScreen = nil
		m.cachedRender = safeRender(m.emulator)
		return m, nil

	case StreamCompleteMsg:
		m.done = true
		// Capture final screen state so it's available for scrollback viewing.
		m.prevScreen = safeReadScreenLines(m.emulator)
		return m, nil

	case StreamErrorMsg:
		m.hasError = true
		m.done = true
		func() {
			defer func() { recover() }()
			m.emulator.Write([]byte(fmt.Sprintf("\n[error] %v\n", msg.Err)))
		}()
		m.prevScreen = safeReadScreenLines(m.emulator)
		m.cachedRender = safeRender(m.emulator)
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

		case tea.KeyPgUp: // PgUp — scroll up by half a page
			visH := m.height
			if visH < 1 {
				visH = 1
			}
			m.scrollOffset += visH / 2
			maxOff := m.totalLines() - visH
			if maxOff < 0 {
				maxOff = 0
			}
			if m.scrollOffset > maxOff {
				m.scrollOffset = maxOff
			}
			return m, nil

		case tea.KeyPgDown: // PgDown — scroll down by half a page
			visH := m.height
			if visH < 1 {
				visH = 1
			}
			m.scrollOffset -= visH / 2
			if m.scrollOffset < 0 {
				m.scrollOffset = 0
			}
			return m, nil

		case tea.KeyEnd: // End — snap to live view (bottom)
			m.scrollOffset = 0
			return m, nil

		case tea.KeyHome: // Home — scroll to top of buffer
			visH := m.height
			if visH < 1 {
				visH = 1
			}
			maxOff := m.totalLines() - visH
			if maxOff < 0 {
				maxOff = 0
			}
			m.scrollOffset = maxOff
			return m, nil

		default:
			if m.ptmx != nil {
				if b := keyToBytes(msg); b != nil {
					m.ptmx.Write(b)
				}
			}
			return m, nil
		}
	}

	// Forward raw bytes for unrecognized messages — e.g. bubbletea's unexported
	// unknownCSISequenceMsg carries kitty-protocol sequences (like Shift+Enter = \x1b[13;2u)
	// as a []byte slice. The reflect check is the only way to access them without forking bubbletea.
	if m.ptmx != nil {
		v := reflect.ValueOf(msg)
		if v.Kind() == reflect.Slice && v.Type().Elem().Kind() == reflect.Uint8 {
			b := v.Bytes()
			// Intercept kitty-encoded Escape (\x1b[27u) — same semantic as tea.KeyEscape
			if bytes.Equal(b, []byte{0x1b, '[', '2', '7', 'u'}) {
				slug := m.slug
				return m, func() tea.Msg { return TerminalDetachMsg{Slug: slug} }
			}
			// Intercept kitty-encoded Ctrl+\ (\x1b[92;5u) — same semantic as tea.KeyCtrlBackslash
			if bytes.Equal(b, []byte{0x1b, '[', '9', '2', ';', '5', 'u'}) {
				slug := m.slug
				return m, func() tea.Msg { return TerminalTerminateMsg{Slug: slug} }
			}
			m.ptmx.Write(b) //nolint:errcheck
		}
	}

	return m, nil
}

func (m SpecPanelModel) View() (result string) {
	defer func() {
		if r := recover(); r != nil {
			writeCrashLog("SpecPanelModel.View", r)
			result = fmt.Sprintf("[view panic: %v]", r)
		}
	}()
	// Scrollback view: render from the virtual document (scrollBuf + current screen).
	if m.scrollOffset > 0 && m.totalLines() > 0 {
		visH := m.height
		if visH < 1 {
			visH = 1
		}
		// Reserve last line for scroll position indicator.
		contentH := visH - 1
		if contentH < 1 {
			contentH = 1
		}

		total := m.totalLines()
		endIdx := total - m.scrollOffset
		if endIdx < 0 {
			endIdx = 0
		}
		startIdx := endIdx - contentH
		if startIdx < 0 {
			startIdx = 0
		}

		var lines []string
		sbLen := len(m.scrollBuf)
		for i := startIdx; i < endIdx; i++ {
			if i < sbLen {
				lines = append(lines, "  "+m.scrollBuf[i])
			} else {
				screenIdx := i - sbLen
				if m.prevScreen != nil && screenIdx < len(m.prevScreen) {
					lines = append(lines, "  "+m.prevScreen[screenIdx])
				}
			}
		}
		// Pad content area then append indicator.
		for len(lines) < contentH {
			lines = append(lines, "")
		}
		dimS := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
		indicator := fmt.Sprintf("-- scrollback (%d lines above) --", m.scrollOffset)
		lines = append(lines, "  "+dimS.Render(indicator))
		return strings.Join(lines, "\n")
	}

	// Live view: return the cached render (updated in Update() handlers).
	if m.cachedRender == "" && !m.done {
		dimS := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
		return dimS.Render("  Waiting for output...")
	}

	return m.cachedRender
}

// PollTerminalCmd returns a Cmd that blocks until PTY data arrives, then drains
// up to 9 chunks total before returning a single TerminalOutputMsg. Returns
// StreamCompleteMsg when the channel is closed.
func PollTerminalCmd(slug string, ch <-chan []byte) tea.Cmd {
	return func() (result tea.Msg) {
		defer func() {
			if r := recover(); r != nil {
				writeCrashLog("PollTerminalCmd", r)
				result = StreamErrorMsg{Slug: slug, Err: fmt.Errorf("poll panic: %v", r)}
			}
		}()
		chunk, ok := <-ch
		if !ok {
			return StreamCompleteMsg{Slug: slug}
		}
		data := make([]byte, len(chunk))
		copy(data, chunk)
		for i := 0; i < 8; i++ {
			select {
			case more, ok := <-ch:
				if !ok {
					return TerminalOutputMsg{Slug: slug, Data: data}
				}
				data = append(data, more...)
			default:
				return TerminalOutputMsg{Slug: slug, Data: data}
			}
		}
		return TerminalOutputMsg{Slug: slug, Data: data}
	}
}

// followupData holds the JSON fields returned by `lore followup load --json`.
type followupData struct {
	Title            string `json:"title"`
	Source           string `json:"source"`
	Status           string `json:"status"`
	SuggestedActions []struct {
		Type string `json:"type"`
	} `json:"suggested_actions"`
	FindingContent *string `json:"finding_content"`
}

// loadFollowupContext runs `lore followup view --json <id>` and returns a
// structured system prompt string. Returns "" on any error (graceful degradation).
func loadFollowupContext(id, knowledgeDir string) string {
	out, err := exec.Command("lore", "followup", "view", "--json", id).Output()
	if err != nil {
		writeCrashLog("loadFollowupContext", fmt.Sprintf("lore followup view failed for %q: %v", id, err))
		return ""
	}

	var data followupData
	if err := json.Unmarshal(out, &data); err != nil {
		writeCrashLog("loadFollowupContext", fmt.Sprintf("JSON parse failed for %q: %v", id, err))
		return ""
	}

	var b strings.Builder
	b.WriteString("# Followup Context\n\n")
	b.WriteString("**Title:** " + data.Title + "\n")
	b.WriteString("**Source:** " + data.Source + "\n")
	b.WriteString("**Status:** " + data.Status + "\n")

	if len(data.SuggestedActions) > 0 {
		actions := make([]string, len(data.SuggestedActions))
		for i, a := range data.SuggestedActions {
			actions[i] = a.Type
		}
		b.WriteString("**Suggested Actions:** " + strings.Join(actions, ", ") + "\n")
	}

	if data.FindingContent != nil && *data.FindingContent != "" {
		b.WriteString("\n## Finding Content\n")
		b.WriteString(*data.FindingContent + "\n")
	}

	return b.String()
}

// StartTerminalCmd spawns the claude subprocess for /spec inside a PTY and
// returns SpecProcessStartedMsg with the PTY master, exec.Cmd, and a channel
// of raw byte chunks read from the PTY. The PTY master is the read/write
// interface — write user keystrokes, read subprocess output.
// projectDir must be the project root (not the knowledge _work/ dir) so that
// the /spec skill can explore the correct codebase.
func StartTerminalCmd(slug, title, projectDir string, width, height int, extraContext string, shortMode, chatMode, skipConfirm, followupMode bool, knowledgeDir string) tea.Cmd {
	return func() (result tea.Msg) {
		defer func() {
			if r := recover(); r != nil {
				writeCrashLog("StartTerminalCmd", r)
				result = StreamErrorMsg{Slug: slug, Err: fmt.Errorf("start panic: %v", r)}
			}
		}()
		// Build the initial prompt to auto-submit. Passing it as a positional
		// argument to claude starts an interactive session and submits it
		// immediately — no PTY-write timing hack needed.
		var initialPrompt string
		if chatMode {
			if followupMode {
				initialPrompt = "Let's discuss this followup: " + slug
			} else {
				initialPrompt = "Let's talk about " + title
			}
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

		// Build args: optionally inject --append-system-prompt before the
		// positional initialPrompt when followupMode is active.
		args := []string{"--dangerously-skip-permissions"}
		if followupMode && slug != "" {
			if sysPrompt := loadFollowupContext(slug, knowledgeDir); sysPrompt != "" {
				args = append(args, "--append-system-prompt", sysPrompt)
			}
		}
		args = append(args, initialPrompt)

		cmd := exec.Command("claude", args...)
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
			defer func() {
				if r := recover(); r != nil {
					writeCrashLog("PTY reader goroutine", r)
				}
			}()
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
