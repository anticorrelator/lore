package work

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime/debug"
	"strings"
	"time"
	"unicode"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/creack/pty"
	libghostty "go.mitchellh.com/libghostty"

	"github.com/anticorrelator/lore/tui/internal/config"
)

// resolveFollowupDir mirrors followup.ResolveDir / scripts/lib.sh::resolve_followup_dir,
// preferring the active tier and falling back to _followups/_archive/. Inlined here to
// avoid an import cycle between work and followup.
func resolveFollowupDir(knowledgeDir, id string) (string, bool) {
	active := filepath.Join(knowledgeDir, "_followups", id)
	if info, err := os.Stat(active); err == nil && info.IsDir() {
		return active, true
	}
	archived := filepath.Join(knowledgeDir, "_followups", "_archive", id)
	if info, err := os.Stat(archived); err == nil && info.IsDir() {
		return archived, true
	}
	return "", false
}

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
	Ptmx   *os.File      // PTY master — read/write interface to subprocess
	Cmd    *exec.Cmd     // for cmd.Wait() in cleanup
	Output <-chan []byte // byte chunks from the PTY reader goroutine
}

// TerminalDetachMsg is sent when the user double-presses Esc within
// escDetachWindow to detach from terminal focus without killing the subprocess
// (panel stays open, subprocess keeps running). A single Esc is forwarded to
// the PTY so harnesses like Claude Code can use it to interrupt running work.
type TerminalDetachMsg struct {
	Slug string
}

// escDetachWindow is the maximum interval between two Esc presses for the
// gesture to be interpreted as "detach" rather than two independent Esc
// forwards to the PTY. Tuned to comfortably exceed a deliberate double-tap
// (~150–300 ms) while staying below the gap between two reflective single
// presses.
const escDetachWindow = 500 * time.Millisecond

// TerminalTerminateMsg is sent when user presses Ctrl+\ to kill the subprocess
// and close the spec panel entirely.
type TerminalTerminateMsg struct {
	Slug string
}

// ClosedPanelInputMsg is sent when a keystroke or paste reaches a torn-down
// session (done, no live PTY). The host surfaces a status-line notice so the
// input is visibly refused rather than silently written into a dead fd. Slug
// identifies the panel; Key is the refused keystroke's string form (for tests
// and any future affordance).
type ClosedPanelInputMsg struct {
	Slug string
	Key  string
}

// writeCrashLog writes a panic stack trace to a temp file for post-mortem debugging.
func writeCrashLog(label string, r interface{}) {
	crashLog := filepath.Join(os.TempDir(), "lore-tui-crash.log")
	stack := fmt.Sprintf("panic in %s: %v\n\n%s", label, r, debug.Stack())
	_ = os.WriteFile(crashLog, []byte(stack), 0644)
}

// SpecPanelModel is the Bubble Tea model for the interactive spec panel.
type SpecPanelModel struct {
	slug       string
	width      int
	height     int
	open       bool
	done       bool
	hasError   bool
	ptmx       *os.File
	cmd        *exec.Cmd
	outputChan <-chan []byte

	// backend is the build-tag-selected terminal emulator (x/vt or
	// libghostty). It is shared mutable state outside the Elm model:
	// functional model copies all point at the same backend instance.
	backend *terminalBackend

	// cachedRender holds the last rendered screen, updated in Update()
	// handlers so that View() can return it in O(1) without re-rendering.
	cachedRender string

	// scrollOffset is lines from the bottom of the terminal document
	// (scrollback + screen); 0 = live view.
	scrollOffset int

	// lastOutputTime records when the last TerminalOutputMsg was received.
	// Used for quiescence detection — if no output arrives for a threshold
	// period, the session is considered idle and may need user input.
	lastOutputTime time.Time

	// needsInput is true when the terminal session has been quiescent
	// (no PTY output) for longer than the quiescence threshold, indicating
	// the subprocess is likely waiting for user input.
	needsInput bool

	// closeRequested marks a session whose close-request was consumed but held
	// open (a human-initiated session, or one with auto_close=false): the panel
	// shows a "done" badge and stays readable while its harness keeps running.
	// It is distinct from done (process exited) — a close-requested session
	// still has a live PTY and accepts follow-up input.
	closeRequested bool

	// lastEscTime records when an Esc was last forwarded to the PTY. A second
	// Esc arriving within escDetachWindow with no intervening non-Esc KeyMsg
	// is interpreted as the detach gesture instead of being forwarded.
	lastEscTime time.Time
}

// NewSpecPanelModel creates a spec panel model for the given work item slug.
// The backend forwards emulator-originated device-query responses (DA1,
// XTVERSION, DSR) to the PTY once one is attached via SetPtmx.
func NewSpecPanelModel(slug string) SpecPanelModel {
	return SpecPanelModel{
		slug:    slug,
		open:    true,
		backend: newTerminalBackend(80, 24),
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

// CloseRequested reports whether this panel is holding open after a consumed
// close-request (the "done" badge state) rather than being torn down.
func (m SpecPanelModel) CloseRequested() bool {
	return m.closeRequested
}

// MarkCloseRequested flips the held-open badge on. The close ladder calls it
// when it consumes a close-request for a session the initiator gate keeps open
// instead of tearing down (value semantics — returns the updated model).
func (m SpecPanelModel) MarkCloseRequested() SpecPanelModel {
	m.closeRequested = true
	return m
}

// QuiescentForClose is the single predicate the close ladder waits on before
// tearing a session down: true once teardown is safe. It stays the only
// predicate the ladder consults so the screen classification can evolve without
// touching the ladder.
//
// A finished process is always safe. Otherwise output quiescence (needsInput)
// grounds it — but that signal alone CANNOT distinguish "turn complete" from
// "awaiting user input": a close-request that lands while the session is paused
// on a post-terminus interactive prompt (e.g. a ceremony/permission question
// after finalize) reads as quiescent and would tear the session down mid-prompt.
// atInteractivePrompt is the readiness gate's screen classification (a
// permission/approval modal is showing), computed by the caller from a
// ScreenSnapshot; when it holds, an idle session is NOT considered safe to close.
func (m SpecPanelModel) QuiescentForClose(atInteractivePrompt bool) bool {
	if m.done {
		return true
	}
	return m.needsInput && !atInteractivePrompt
}

// ScreenSnapshot is the observable terminal state the send/peek readiness gate
// and peek response consume. Rows is the plain-text screen (the form signature
// matchers key on); ANSI is the styled render for peek --raw. BracketedPaste is
// the live DECSET 2004 state, which decides how an injected message is encoded.
type ScreenSnapshot struct {
	CursorX        uint16
	CursorY        uint16
	CursorVisible  bool
	BracketedPaste bool
	PasswordInput  bool
	Rows           []string
	ANSI           string
}

// ErrUnsafePayload is returned by InjectMessage when the message body must be
// refused before any PTY write. Two cases (see unsafePayloadReason): the body
// contains the bracketed-paste terminator ESC[201~, or it contains a line break
// while bracketed-paste mode is off. The send path maps it to an unsafe-payload
// refusal — the body is neither sanitized silently nor written.
var ErrUnsafePayload = errors.New("unsafe message payload")

// pasteTerminator is the bracketed-paste end sequence (ESC [ 2 0 1 ~). Built as
// explicit bytes so the source carries the literal ESC (0x1b), not a decoded
// control character.
var pasteTerminator = []byte{0x1b, '[', '2', '0', '1', '~'}

// unsafePayloadReason returns a non-empty reason when body must be refused, or ""
// when it is safe to inject at the given bracketed-paste mode.
//
// libghostty.PasteEncode strips ESC to a space in both modes, so an embedded
// ESC[201~ is technically neutralized ("hi\x1b[201~x" -> "hi [201~x") and cannot
// escape the bracket — but we refuse it loudly rather than silently mangle a
// coordinator's literal bytes, so the caller decides. Newlines ride verbatim
// inside a bracketed paste (one composer entry, no submit), so multiline send is
// in-scope when bracketed; unbracketed, PasteEncode turns each newline into CR
// (= submit), so an unbracketed line break is N partial submits — the documented
// trap, and the only mode where a newline is unsafe.
func unsafePayloadReason(body []byte, bracketed bool) string {
	if bytes.Contains(body, pasteTerminator) {
		return "embedded bracketed-paste terminator (ESC[201~)"
	}
	if !bracketed && bytes.ContainsAny(body, "\n\r") {
		return "line break with bracketed-paste mode off (each break would submit)"
	}
	return ""
}

// ScreenState returns a snapshot of the panel's terminal for the readiness gate
// and peek. It reads the shared backend, so callers must invoke it from the
// Bubble Tea goroutine (never a Cmd goroutine).
func (m SpecPanelModel) ScreenState() (ScreenSnapshot, error) {
	if m.backend == nil {
		return ScreenSnapshot{}, errors.New("no terminal backend")
	}
	return m.backend.screenState()
}

// InjectMessage writes body into the session's composer as a bracketed paste
// (per the live terminal's paste mode) followed by submitSeq to commit it. It
// refuses an unsafe body (ErrUnsafePayload) before any PTY write, and never
// writes body raw — PasteEncode neutralizes the harnesses' divergent CR/LF
// submit semantics. bracketed is the caller-captured DECSET 2004 state (from the
// same snapshot the gate used) so encoding matches what the gate observed.
func (m SpecPanelModel) InjectMessage(body, submitSeq string, bracketed bool) error {
	if m.ptmx == nil {
		return errors.New("no PTY attached")
	}
	raw := []byte(body)
	if reason := unsafePayloadReason(raw, bracketed); reason != "" {
		return fmt.Errorf("%w: %s", ErrUnsafePayload, reason)
	}
	encoded, err := libghostty.PasteEncode(raw, bracketed)
	if err != nil {
		return err
	}
	if _, err := m.ptmx.Write(encoded); err != nil {
		return err
	}
	if submitSeq != "" {
		if _, err := m.ptmx.Write([]byte(submitSeq)); err != nil {
			return err
		}
	}
	return nil
}

// Process returns the harness subprocess handle, or nil when no process is
// attached (never started, or already reaped). The close ladder drives it
// through SIGTERM→Kill escalation.
func (m SpecPanelModel) Process() *os.Process {
	if m.cmd == nil {
		return nil
	}
	return m.cmd.Process
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
// Also attaches the PTY to the backend so emulator-originated query responses
// are forwarded to it. Returns the updated model (value semantics).
func (m SpecPanelModel) SetPtmx(ptmx *os.File, cmd *exec.Cmd, output <-chan []byte) SpecPanelModel {
	m.ptmx = ptmx
	m.cmd = cmd
	m.outputChan = output
	if m.backend != nil && ptmx != nil {
		m.backend.setPtyWriter(ptmx)
	}
	return m
}

// Cleanup closes the PTY master, kills the subprocess, and closes the terminal
// backend. Reaps the subprocess in a background goroutine so the caller is
// never blocked. Safe to call multiple times (the backend close is idempotent).
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
	if m.backend != nil {
		m.backend.close()
	}
	return m
}

func (m SpecPanelModel) Init() tea.Cmd {
	return nil
}

// totalLines returns the total number of lines in the terminal document
// (scrollback history + current screen).
func (m SpecPanelModel) totalLines() int {
	if m.backend == nil {
		return 0
	}
	return m.backend.totalLines()
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
		// Attach the PTY to the backend so emulator-originated query
		// responses are forwarded to the subprocess.
		if m.backend != nil && msg.Ptmx != nil {
			m.backend.setPtyWriter(msg.Ptmx)
		}
		return m, tea.Batch(
			PollTerminalCmd(m.slug, m.outputChan),
			QuiescenceTickCmd(m.slug),
		)

	case TerminalOutputMsg:
		prevTotal := m.totalLines()
		m.backend.write(msg.Data)

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

		// While scrolled into history, keep the same content visible as the
		// document grows, then clamp to the document size.
		if m.scrollOffset > 0 {
			if grown := m.totalLines() - prevTotal; grown > 0 {
				m.scrollOffset += grown
			}
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

		m.cachedRender = m.backend.renderScreen()
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

	case tea.MouseWheelMsg:
		visH := m.height
		if visH < 1 {
			visH = 1
		}
		switch msg.Button {
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
		m.backend.resize(vpWidth, vpHeight)
		m.cachedRender = m.backend.renderScreen()
		return m, nil

	case StreamCompleteMsg:
		m.done = true
		return m, nil

	case StreamErrorMsg:
		m.hasError = true
		m.done = true
		m.backend.write([]byte(fmt.Sprintf("\r\n[error] %v\r\n", msg.Err)))
		m.cachedRender = m.backend.renderScreen()
		return m, nil

	case tea.PasteMsg:
		// Bracketed paste: forward the pasted text to the PTY. Pasted input
		// clears the pending double-Esc gesture like any non-Esc key.
		m.lastEscTime = time.Time{}
		if m.done {
			return m.refuseClosedInput("paste")
		}
		if m.ptmx != nil && msg.Content != "" {
			if _, err := m.ptmx.Write([]byte(msg.Content)); err != nil {
				return m.refuseClosedInput("paste")
			}
		}
		return m, nil

	case tea.KeyPressMsg:
		// This handler is only reached when the terminal has keyboard focus
		// (focusedPanel == panelRight in terminal mode). Intercept escape
		// chords and shift-modified scroll keys; forward all other keys —
		// including plain PgUp/PgDn/Home/End, which the subprocess may bind —
		// to the PTY.
		//
		// Any non-Esc key arriving here clears the pending double-Esc gesture
		// so that an accidentally-paired Esc-letter-Esc sequence does not detach.
		if msg.Code != tea.KeyEscape {
			m.lastEscTime = time.Time{}
		}

		// Lore scrollback lives on the shifted keys, following the common
		// terminal-emulator convention (shift+PgUp scrolls the host, plain
		// PgUp goes to the program). Matched by code+modifier because the
		// string form of modified keys varies across input protocols.
		if msg.Mod.Contains(tea.ModShift) {
			visH := m.height
			if visH < 1 {
				visH = 1
			}
			maxOff := m.totalLines() - visH
			if maxOff < 0 {
				maxOff = 0
			}
			switch msg.Code {
			case tea.KeyPgUp: // Shift+PgUp — scroll up by half a page
				m.scrollOffset += visH / 2
				if m.scrollOffset > maxOff {
					m.scrollOffset = maxOff
				}
				return m, nil
			case tea.KeyPgDown: // Shift+PgDn — scroll down by half a page
				m.scrollOffset -= visH / 2
				if m.scrollOffset < 0 {
					m.scrollOffset = 0
				}
				return m, nil
			case tea.KeyHome: // Shift+Home — scroll to top of buffer
				m.scrollOffset = maxOff
				return m, nil
			case tea.KeyEnd: // Shift+End — snap to live view (bottom)
				m.scrollOffset = 0
				return m, nil
			}
		}

		switch msg.String() {
		case "esc": // single Esc forwards; double Esc within window detaches
			if m.done {
				return m.refuseClosedInput("esc")
			}
			return m.handleEscKey()
		case "ctrl+\\": // Ctrl+\ — terminate subprocess (dismisses a closed panel)
			slug := m.slug
			return m, func() tea.Msg { return TerminalTerminateMsg{Slug: slug} }

		default:
			if m.done {
				return m.refuseClosedInput(msg.String())
			}
			if m.ptmx != nil {
				if b := KeyToBytes(msg); b != nil {
					if _, err := m.ptmx.Write(b); err != nil {
						return m.refuseClosedInput(msg.String())
					}
				}
			}
			return m, nil
		}
	}

	return m, nil
}

// refuseClosedInput is the response to a keystroke or paste that reached a
// torn-down session (done, no live PTY, or a PTY write that just failed): it
// writes nothing and emits a ClosedPanelInputMsg so the host surfaces a
// status-line notice instead of dropping the input silently. Scrollback keys
// are handled before this point, so navigating retained history still works.
func (m SpecPanelModel) refuseClosedInput(key string) (SpecPanelModel, tea.Cmd) {
	slug := m.slug
	return m, func() tea.Msg { return ClosedPanelInputMsg{Slug: slug, Key: key} }
}

// handleEscKey implements the single-Esc-forwards / double-Esc-detaches gesture.
//
// First Esc: forward \x1b to the PTY (so harnesses like Claude Code can use
// Esc to interrupt) and arm the double-Esc timer. Second Esc within
// escDetachWindow: detach focus back to the detail panel without forwarding,
// without killing the subprocess. The arm is cleared by any non-Esc key
// reaching the panel; PTY output does not clear it (so a streaming subprocess
// does not block the detach gesture).
func (m SpecPanelModel) handleEscKey() (SpecPanelModel, tea.Cmd) {
	now := time.Now()
	if !m.lastEscTime.IsZero() && now.Sub(m.lastEscTime) < escDetachWindow {
		m.lastEscTime = time.Time{}
		slug := m.slug
		return m, func() tea.Msg { return TerminalDetachMsg{Slug: slug} }
	}
	m.lastEscTime = now
	if m.ptmx != nil {
		if _, err := m.ptmx.Write([]byte{0x1b}); err != nil {
			return m.refuseClosedInput("esc")
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
	// Scrollback view: render the requested window of the terminal document
	// (native scrollback + current screen) through the backend.
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
		for _, ln := range m.backend.readScrollback(startIdx, endIdx) {
			lines = append(lines, "  "+ln)
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

// lensFindingJSON is a minimal local struct for deserializing lens-findings.json
// entries. Mirrors followup.LensFinding without creating a cross-package dependency.
type lensFindingJSON struct {
	Severity    string `json:"severity"`
	Title       string `json:"title"`
	File        string `json:"file"`
	Line        int    `json:"line"`
	Body        string `json:"body"`
	Lens        string `json:"lens"`
	Disposition string `json:"disposition"`
	Rationale   string `json:"rationale"`
}

// lensReviewJSON is a minimal local struct for deserializing lens-findings.json.
type lensReviewJSON struct {
	Findings []lensFindingJSON `json:"findings"`
}

// loadFollowupContext runs `lore followup view --json <id>` and returns a
// structured system prompt string. Returns "" on any error (graceful degradation).
// When findingIndex >= 0, loads lens-findings.json and builds a finding-scoped
// prompt; falls back to full-followup context if the index is out of range.
func loadFollowupContext(id, knowledgeDir string, findingIndex int) string {
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

	// Finding-scoped context: load lens-findings.json and append the specific finding.
	if findingIndex >= 0 {
		if itemDir, ok := resolveFollowupDir(knowledgeDir, id); ok {
			sidecarPath := filepath.Join(itemDir, "lens-findings.json")
			sidecarBytes, err := os.ReadFile(sidecarPath)
			if err == nil {
				if scoped := appendFindingContext(b.String(), sidecarBytes, findingIndex); scoped != "" {
					return scoped
				}
				// findingIndex out of range or JSON error — fall through to full-followup context.
			}
		}
	}

	// Full-followup context (no finding scope or fallback).
	if data.FindingContent != nil && *data.FindingContent != "" {
		b.WriteString("\n## Finding Content\n")
		b.WriteString(*data.FindingContent + "\n")
	}

	return b.String()
}

// appendFindingContext appends finding details to the base prompt string using
// the provided lens-findings.json bytes and finding index. Returns "" if the
// index is out of range or the JSON is malformed (caller falls back to full context).
func appendFindingContext(base string, sidecarBytes []byte, findingIndex int) string {
	var review lensReviewJSON
	if err := json.Unmarshal(sidecarBytes, &review); err != nil || findingIndex < 0 || findingIndex >= len(review.Findings) {
		return ""
	}
	f := review.Findings[findingIndex]
	var b strings.Builder
	b.WriteString(base)
	b.WriteString(fmt.Sprintf("**Finding Index:** %d of %d\n", findingIndex, len(review.Findings)))
	b.WriteString("\n## Finding\n")
	b.WriteString("**Title:** " + f.Title + "\n")
	b.WriteString("**Severity:** " + f.Severity + "\n")
	b.WriteString("**Disposition:** " + f.Disposition + "\n")
	if f.Rationale != "" {
		b.WriteString("**Rationale:** " + f.Rationale + "\n")
	}
	if f.File != "" {
		if f.Line > 0 {
			b.WriteString(fmt.Sprintf("**File:** %s:%d\n", f.File, f.Line))
		} else {
			b.WriteString("**File:** " + f.File + "\n")
		}
	}
	if f.Lens != "" {
		b.WriteString("**Lens:** " + f.Lens + "\n")
	}
	if f.Body != "" {
		b.WriteString("\n" + f.Body + "\n")
	}
	return b.String()
}

// StartTerminalCmd spawns the claude subprocess for /spec inside a PTY and
// buildInitialPrompt constructs the prompt string passed to claude at startup.
// It encodes four modes: followup chat, regular chat, short spec, and full spec.
// findingIndex, when >= 0 and followupMode is true, inserts "--finding <N>" after the followup ID.
//
// Chat prompts always start with a slash command at position 0 so the Claude
// Code harness auto-invokes the matching skill. The skill name declares the
// entity type; the slug identifies the specific item. This gives the agent an
// unambiguous loading pattern (via the skill's documented CLI path) rather
// than forcing it to infer identity from prose and fall back to file search.
func buildInitialPrompt(slug, title, extraContext string, shortMode, chatMode, skipConfirm, followupMode bool, findingIndex int) string {
	_ = title
	var p string
	if chatMode {
		if followupMode {
			p = "/followup-discuss " + slug
			if findingIndex >= 0 {
				p += fmt.Sprintf(" --finding %d", findingIndex)
			}
		} else {
			p = "/work " + slug
		}
		if extraContext != "" {
			p += ": " + extraContext
		}
	} else {
		p = "/spec "
		if shortMode {
			p += "short "
		}
		p += slug
		if skipConfirm {
			p += " --yes"
		}
		if extraContext != "" {
			p += " -- " + extraContext
		}
	}
	return p
}

// returns SpecProcessStartedMsg with the PTY master, exec.Cmd, and a channel
// of raw byte chunks read from the PTY. The PTY master is the read/write
// interface — write user keystrokes, read subprocess output.
// projectDir must be the project root (not the knowledge _work/ dir) so that
// the /spec skill can explore the correct codebase.
func StartTerminalCmd(slug, title, projectDir string, width, height int, extraContext string, shortMode, chatMode, skipConfirm, followupMode bool, knowledgeDir string, findingIndex int, sessionEnv SessionEnv) tea.Cmd {
	return func() (result tea.Msg) {
		defer func() {
			if r := recover(); r != nil {
				writeCrashLog("StartTerminalCmd", r)
				result = StreamErrorMsg{Slug: slug, Err: fmt.Errorf("start panic: %v", r)}
			}
		}()
		// Build the initial prompt to auto-submit. Passing it as a positional
		// argument to the harness binary starts an interactive session and
		// submits it immediately — no PTY-write timing hack needed.
		initialPrompt := buildInitialPrompt(slug, title, extraContext, shortMode, chatMode, skipConfirm, followupMode, findingIndex)

		// Resolve the TUI launch framework once and use it for the binary,
		// harness-specific prepended args, and child-process environment. This
		// preference is intentionally TUI-scoped; shell helpers inside the
		// spawned session see it via LORE_FRAMEWORK rather than by reading
		// settings.json as global process truth.
		activeFramework, err := config.ResolveTUILaunchFramework()
		if err != nil {
			return StreamErrorMsg{Slug: slug, Err: fmt.Errorf("resolve TUI launch framework: %w", err)}
		}
		harnessBinary, err := config.HarnessBinary(activeFramework)
		if err != nil {
			return StreamErrorMsg{Slug: slug, Err: fmt.Errorf("resolve harness binary: %w", err)}
		}

		// Build args: start with user-configured harness flags
		// (~/.lore/config/harness-args.json `[<framework>].args`), then
		// adapter-mediated flag injection for the two TUI-injected concerns
		// (append_system_prompt, inline_settings_override). Each concern's
		// flag spelling is resolved against the active harness; on
		// `unsupported` the TUI skips the injection entirely rather than
		// substituting a different flag (opencode/codex would error on an
		// unknown flag). See adapters/agents/README.md §"TUI Launch Concerns".
		args := append([]string(nil), config.LoadHarnessConfig(activeFramework).Args...)
		if followupMode && slug != "" {
			if sysPrompt := loadFollowupContext(slug, knowledgeDir, findingIndex); sysPrompt != "" {
				flag, supported, err := config.HarnessSystemPromptFlag(activeFramework)
				if err != nil {
					return StreamErrorMsg{Slug: slug, Err: fmt.Errorf("resolve append_system_prompt flag: %w", err)}
				}
				if supported {
					args = append(args, flag, sysPrompt)
				} else {
					fmt.Fprintf(os.Stderr, "[lore] degraded: append_system_prompt skipped (capability=none on framework=%s); followup-discuss context not pre-loaded\n", activeFramework)
				}
			}
		}
		settingsFlag, settingsSupported, err := config.HarnessSettingsOverrideFlag(activeFramework)
		if err != nil {
			return StreamErrorMsg{Slug: slug, Err: fmt.Errorf("resolve inline_settings_override flag: %w", err)}
		}
		if settingsSupported {
			args = append(args, settingsFlag, `{}`)
		} else {
			fmt.Fprintf(os.Stderr, "[lore] degraded: inline_settings_override skipped (capability=none on framework=%s); session-scoped settings overrides unavailable\n", activeFramework)
		}
		args = append(args, initialPrompt)

		cmd := exec.Command(harnessBinary, args...)
		cmd.Dir = projectDir
		cmd.Env = append(os.Environ(), "LORE_FRAMEWORK="+activeFramework)
		cmd.Env = append(cmd.Env, sessionEnv.vars()...)
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

// KeyToBytes converts a Bubble Tea key press into the raw byte sequence that
// should be written to a PTY to reproduce that keypress. Returns nil for
// unknown keys.
func KeyToBytes(km tea.KeyPressMsg) []byte {
	key := km.Key()
	b := keyBaseBytes(key)
	if b == nil {
		return nil
	}
	// Alt modifier prepends ESC
	if key.Mod.Contains(tea.ModAlt) && key.Code != tea.KeyEscape {
		return append([]byte{0x1b}, b...)
	}
	return b
}

// keyBaseBytes maps a v2 Key to the legacy byte encoding a terminal without
// the kitty protocol would send — what the child PTY expects on stdin.
func keyBaseBytes(key tea.Key) []byte {
	if key.Mod.Contains(tea.ModCtrl) {
		switch {
		case key.Code >= 'a' && key.Code <= 'z':
			return []byte{byte(key.Code-'a') + 1}
		case key.Code == '\\':
			return []byte{0x1c}
		case key.Code == ']':
			return []byte{0x1d}
		}
		// No dedicated C0 byte (e.g. ctrl+enter): fall through to the
		// unmodified mapping, matching what a legacy terminal would send.
	}

	switch key.Code {
	case tea.KeySpace:
		return []byte{' '}
	case tea.KeyEnter:
		return []byte{'\r'}
	case tea.KeyBackspace:
		return []byte{0x7f}
	case tea.KeyTab:
		return []byte{'\t'}
	case tea.KeyEscape:
		return []byte{0x1b}
	case tea.KeyUp:
		return []byte{0x1b, '[', 'A'}
	case tea.KeyDown:
		return []byte{0x1b, '[', 'B'}
	case tea.KeyRight:
		return []byte{0x1b, '[', 'C'}
	case tea.KeyLeft:
		return []byte{0x1b, '[', 'D'}
	case tea.KeyHome:
		return []byte{0x1b, '[', 'H'}
	case tea.KeyEnd:
		return []byte{0x1b, '[', 'F'}
	case tea.KeyPgUp:
		return []byte{0x1b, '[', '5', '~'}
	case tea.KeyPgDown:
		return []byte{0x1b, '[', '6', '~'}
	case tea.KeyDelete:
		return []byte{0x1b, '[', '3', '~'}
	case tea.KeyInsert:
		return []byte{0x1b, '[', '2', '~'}
	}

	// Printable input: prefer the produced text (covers shifted characters),
	// falling back to the key code for modified printables (e.g. alt+f, where
	// Text is empty but Code is the letter).
	if key.Text != "" {
		return []byte(key.Text)
	}
	if unicode.IsPrint(key.Code) {
		return []byte(string(key.Code))
	}
	return nil
}
