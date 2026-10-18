package work

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/creack/pty"

	"github.com/anticorrelator/lore/tui/internal/config"
)

// tmuxFixture is one test's private tmux server: a short TMUX_TMPDIR under /tmp
// (a macOS socket path must fit 104 bytes) and a runtime name of its own, both
// set before the first tmux call, plus a data directory with no supervisor
// record. Its server is killed in cleanup.
type tmuxFixture struct {
	root   string
	socket string
	tmux   string
	python string
	child  string
}

var tmuxFixtureSeq atomic.Int64

// paneChild stands in for a harness: it prints history rows and READY, logs its
// terminal size at start and on every SIGWINCH, and logs and echoes each input
// line it reads.
const paneChild = `import os, select, signal, sys, tty
log = open(sys.argv[1], "a", buffering=1)
def report(*_):
    size = os.get_terminal_size(0)
    log.write(f"size {size.columns} {size.lines}\n")
signal.signal(signal.SIGWINCH, report)
for i in range(80):
    sys.stdout.write(f"HIST-{i:03d}\r\n")
sys.stdout.write("READY\r\n")
sys.stdout.flush()
report()
tty.setraw(0)
pending = b""
while True:
    if not select.select([0], [], [], 0.2)[0]:
        continue
    data = os.read(0, 1024)
    if not data:
        break
    pending += data
    while b"\r" in pending:
        line, pending = pending.split(b"\r", 1)
        text = line.decode(errors="replace")
        log.write(f"input {text}\n")
        sys.stdout.write(f"ECHO {text}\r\n")
        sys.stdout.flush()
`

func newTmuxFixture(t *testing.T) tmuxFixture {
	t.Helper()
	tmuxPath, err := exec.LookPath(tmuxBinary)
	if err != nil {
		t.Skip("tmux is not installed")
	}
	python, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 is not installed")
	}
	root, err := os.MkdirTemp("/tmp", "lore-view-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	if root, err = filepath.EvalSymlinks(root); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMUX_TMPDIR", root)
	t.Setenv(config.SessionRuntimeEnv, fmt.Sprintf("view-%d-%d", os.Getpid(), tmuxFixtureSeq.Add(1)))
	t.Setenv("LORE_DATA_DIR", filepath.Join(root, "data"))
	t.Setenv("TERM", "xterm-256color")
	for _, name := range []string{"TMUX", "TMUX_PANE"} {
		t.Setenv(name, "")
		os.Unsetenv(name)
	}
	child := filepath.Join(root, "child.py")
	if err := os.WriteFile(child, []byte(paneChild), 0o644); err != nil {
		t.Fatal(err)
	}
	f := tmuxFixture{root: root, tmux: tmuxPath, python: python, child: child,
		socket: filepath.Join(root, fmt.Sprintf("tmux-%d", os.Getuid()), config.TmuxServer())}
	// tmux makes this directory itself only for -L; the fixture also starts
	// servers by socket path.
	if err := os.MkdirAll(filepath.Dir(f.socket), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = exec.Command(tmuxPath, "-S", f.socket, "kill-server").Run() })
	return f
}

// run talks to the fixture's server by socket path, whatever TMUX_TMPDIR the
// test process has at the time.
func (f tmuxFixture) run(args ...string) (string, error) {
	out, err := exec.Command(f.tmux, append([]string{"-S", f.socket}, args...)...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func (f tmuxFixture) must(t *testing.T, args ...string) string {
	t.Helper()
	out, err := f.run(args...)
	if err != nil {
		t.Fatalf("tmux %v: %v: %s", args, err, out)
	}
	return out
}

func (f tmuxFixture) geometry(t *testing.T, name string) string {
	t.Helper()
	return f.must(t, "display-message", "-p", "-t", "="+name+":", "#{window_width}x#{window_height} #{window-size}")
}

func (f tmuxFixture) alive(name string) bool {
	_, err := f.run("has-session", "-t", "="+name)
	return err == nil
}

func (f tmuxFixture) clients(t *testing.T, name string) []string {
	t.Helper()
	out := f.must(t, "list-clients", "-t", "="+name, "-F", "#{client_width}x#{client_height} #{?#{m:*ignore-size*,#{client_flags}},ignore-size,plain}")
	if out == "" {
		return nil
	}
	lines := strings.Split(out, "\n")
	slices.Sort(lines)
	return lines
}

// startHarness creates the session the way a store host does, at cols x rows,
// and returns the stand-in harness's log.
func (f tmuxFixture) startHarness(t *testing.T, name string, cols, rows int) string {
	t.Helper()
	log := filepath.Join(f.root, name+".log")
	work := filepath.Join(f.root, name+"-work")
	if err := os.MkdirAll(work, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := createTmuxSession(name, work, cols, rows, nil, f.python, []string{"-I", f.child, log}); err != nil {
		t.Fatal(err)
	}
	waitFor(t, 10*time.Second, "the harness to start", func() bool { return len(paneSizes(log)) > 0 })
	return log
}

func paneLog(path, kind string) []string {
	data, _ := os.ReadFile(path)
	var out []string
	for _, line := range strings.Split(string(data), "\n") {
		if rest, ok := strings.CutPrefix(line, kind+" "); ok {
			out = append(out, rest)
		}
	}
	return out
}

func paneSizes(path string) []string  { return paneLog(path, "size") }
func paneInputs(path string) []string { return paneLog(path, "input") }

func waitFor(t *testing.T, timeout time.Duration, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(25 * time.Millisecond)
	}
}

// settle is how long a check that something does not happen waits first.
const settle = 800 * time.Millisecond

// ptyClient is a plain tmux client: the store host's own attach, or an older
// lore-tui's.
type ptyClient struct {
	cmd  *exec.Cmd
	ptmx *os.File
}

func attachPlainClient(t *testing.T, name string, cols, rows int) *ptyClient {
	t.Helper()
	cmd := tmuxAttachCommand(name)
	ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
	if err != nil {
		t.Fatal(err)
	}
	go func() { _, _ = io.Copy(io.Discard, ptmx) }()
	c := &ptyClient{cmd: cmd, ptmx: ptmx}
	t.Cleanup(c.stop)
	return c
}

func (c *ptyClient) typeLine(t *testing.T, text string) {
	t.Helper()
	if _, err := c.ptmx.Write([]byte(text + "\r")); err != nil {
		t.Fatal(err)
	}
}

func (c *ptyClient) stop() {
	if c.cmd.Process != nil {
		_ = c.cmd.Process.Kill()
	}
	_ = c.ptmx.Close()
	_ = c.cmd.Wait()
}

// viewerDriver runs a real viewer panel the way a Bubble Tea program would:
// every returned command runs on its own goroutine and its message comes back
// through Update. seen records every message the panel was given or produced.
type viewerDriver struct {
	t     *testing.T
	panel SessionPanelModel
	msgs  chan tea.Msg
	seen  []tea.Msg
}

func newViewerDriver(t *testing.T, name string, cols, rows int) *viewerDriver {
	t.Helper()
	d := &viewerDriver{t: t, panel: NewViewerSessionPanelModel("item-"+name, name), msgs: make(chan tea.Msg, 4096)}
	d.deliver(tea.WindowSizeMsg{Width: cols, Height: rows})
	d.run(d.panel.Init())
	t.Cleanup(func() { d.panel = d.panel.Cleanup() })
	return d
}

func (d *viewerDriver) run(cmd tea.Cmd) {
	if cmd != nil {
		go func() { d.msgs <- cmd() }()
	}
}

func (d *viewerDriver) deliver(msg tea.Msg) {
	if msg == nil {
		return
	}
	d.seen = append(d.seen, msg)
	if batch, ok := msg.(tea.BatchMsg); ok {
		for _, cmd := range batch {
			d.run(cmd)
		}
		return
	}
	next, cmd := d.panel.Update(msg)
	d.panel = next
	d.run(cmd)
}

func (d *viewerDriver) until(what string, timeout time.Duration, cond func(SessionPanelModel) bool) {
	d.t.Helper()
	deadline := time.After(timeout)
	for !cond(d.panel) {
		select {
		case msg := <-d.msgs:
			d.deliver(msg)
		case <-deadline:
			d.t.Fatalf("viewer of %s: timed out waiting for %s; view:\n%s", d.panel.TmuxName(), what, d.panel.View())
		}
	}
}

// pump delivers whatever arrives for a while.
func (d *viewerDriver) pump(dur time.Duration) {
	deadline := time.After(dur)
	for {
		select {
		case msg := <-d.msgs:
			d.deliver(msg)
		case <-deadline:
			return
		}
	}
}

func (d *viewerDriver) waitReady() {
	d.t.Helper()
	d.until("the session's screen", 10*time.Second, func(p SessionPanelModel) bool {
		return p.viewerClient != nil && strings.Contains(p.View(), "READY")
	})
}

func (d *viewerDriver) typeLine(text string) {
	for _, r := range text {
		d.deliver(tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	d.deliver(tea.KeyPressMsg{Code: tea.KeyEnter})
}

func (d *viewerDriver) waitEnded() {
	d.t.Helper()
	d.until("the viewer to end", 10*time.Second, func(p SessionPanelModel) bool { return p.IsDone() })
}

// assertNoOwnedSessionTraffic fails on any message an owned session's handlers
// (session end, close, quiescence and observation) act on.
func assertNoOwnedSessionTraffic(t *testing.T, drivers ...*viewerDriver) {
	t.Helper()
	for _, d := range drivers {
		for _, msg := range d.seen {
			switch msg.(type) {
			case SessionProcessStartedMsg, TerminalOutputMsg, StreamCompleteMsg, StreamErrorMsg,
				QuiescenceTickMsg, NeedsInputChangedMsg, TerminalTerminateMsg, tmuxScrollbackCapturedMsg:
				t.Errorf("viewer of %s produced owned-session message %T", d.panel.TmuxName(), msg)
			}
		}
	}
}

func TestViewerPanelsOfAnySizeLeaveThePinnedWindowAtTheHostSize(t *testing.T) {
	f := newTmuxFixture(t)
	name := "lore-host-sizes"
	log := f.startHarness(t, name, 136, 32)
	attachPlainClient(t, name, 136, 32)

	small := newViewerDriver(t, name, 80, 24)
	small.waitReady()
	big := newViewerDriver(t, name, 200, 60)
	big.waitReady()

	small.typeLine("small-1")
	waitFor(t, 5*time.Second, "small-1", func() bool { return len(paneInputs(log)) == 1 })
	big.typeLine("big-1")
	waitFor(t, 5*time.Second, "big-1", func() bool { return len(paneInputs(log)) == 2 })
	big.deliver(tea.PasteMsg{Content: "big-paste"})
	big.deliver(tea.KeyPressMsg{Code: tea.KeyEnter})
	waitFor(t, 5*time.Second, "big-paste", func() bool { return len(paneInputs(log)) == 3 })

	small.deliver(tea.WindowSizeMsg{Width: 100, Height: 30})
	waitFor(t, 5*time.Second, "the small viewer's client to report 100x30", func() bool {
		return slices.Contains(f.clients(t, name), "100x30 ignore-size")
	})
	small.typeLine("small-2")
	waitFor(t, 5*time.Second, "small-2", func() bool { return len(paneInputs(log)) == 4 })

	// An older lore-tui re-applies the global pin on every session it creates.
	f.must(t, "set", "-g", "window-size", "latest")
	small.typeLine("small-3")
	waitFor(t, 5*time.Second, "small-3", func() bool { return len(paneInputs(log)) == 5 })
	small.pump(settle)
	big.pump(settle)

	if got := f.geometry(t, name); got != "136x32 manual" {
		t.Errorf("window = %s, want the host's 136x32 with its own manual size", got)
	}
	if got := paneSizes(log); !slices.Equal(got, []string{"136 32"}) {
		t.Errorf("harness saw sizes %q, want only the host's 136 32", got)
	}
	if got, want := paneInputs(log), []string{"small-1", "big-1", "big-paste", "small-2", "small-3"}; !slices.Equal(got, want) {
		t.Errorf("pane inputs = %q, want %q", got, want)
	}
	if got, want := f.clients(t, name), []string{"100x30 ignore-size", "136x32 plain", "200x60 ignore-size"}; !slices.Equal(got, want) {
		t.Errorf("clients = %q, want %q", got, want)
	}
	if !strings.Contains(small.panel.View(), "ECHO small-3") || !strings.Contains(big.panel.View(), "ECHO small-3") {
		t.Errorf("both viewers should show the harness's reply to the other's input:\nsmall:\n%s\nbig:\n%s", small.panel.View(), big.panel.View())
	}
	assertNoOwnedSessionTraffic(t, small, big)
}

func TestViewerEndsEveryViewerWhenThePaneEnds(t *testing.T) {
	f := newTmuxFixture(t)
	name := "lore-host-ending"
	f.startHarness(t, name, 136, 32)
	attachPlainClient(t, name, 136, 32)
	first := newViewerDriver(t, name, 80, 24)
	first.waitReady()
	second := newViewerDriver(t, name, 140, 40)
	second.waitReady()

	pid, err := strconv.Atoi(f.must(t, "display-message", "-p", "-t", "="+name+":", "#{pane_pid}"))
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	for _, d := range []*viewerDriver{first, second} {
		d.waitEnded()
		if got := d.panel.ViewerEndReason(); got != ViewerSessionEnded {
			t.Errorf("viewer end reason = %q, want %q", got, ViewerSessionEnded)
		}
		if d.panel.HasError() {
			t.Errorf("a session's end is not a viewer error")
		}
		if out := d.panel.View(); out == "" {
			t.Errorf("an ended viewer should keep its last screen")
		}
	}
	assertNoOwnedSessionTraffic(t, first, second)
}

func TestViewerTellsAFailedAttachFromAnEndedSessionAndStopsOnlyItsClient(t *testing.T) {
	f := newTmuxFixture(t)
	name := "lore-host-steady"
	log := f.startHarness(t, name, 136, 32)
	panePID := f.must(t, "display-message", "-p", "-t", "="+name+":", "#{pane_pid}")

	missing := newViewerDriver(t, "lore-host-absent", 80, 24)
	missing.waitEnded()
	if got := missing.panel.ViewerEndReason(); got != ViewerAttachFailed {
		t.Fatalf("viewer of a missing session ended %q, want %q", got, ViewerAttachFailed)
	}
	if err := missing.panel.ViewerErr(); err == nil || !strings.Contains(err.Error(), "no tmux session lore-host-absent") {
		t.Fatalf("attach failure = %v, want the missing session named", err)
	}
	if view := missing.panel.View(); !strings.Contains(view, "could not attach to lore-host-absent") {
		t.Fatalf("failed viewer view = %q", view)
	}
	if !missing.panel.HasError() {
		t.Fatal("a failed attach should mark the panel as errored")
	}

	detached := newViewerDriver(t, name, 80, 24)
	detached.waitReady()
	f.must(t, "detach-client", "-s", "="+name)
	detached.waitEnded()
	if got := detached.panel.ViewerEndReason(); got != ViewerDetached {
		t.Fatalf("detached viewer ended %q, want %q", got, ViewerDetached)
	}

	closed := newViewerDriver(t, name, 80, 24)
	closed.waitReady()
	if got := f.clients(t, name); len(got) != 1 {
		t.Fatalf("clients before cleanup = %q, want the one viewer", got)
	}
	closed.panel = closed.panel.Cleanup()
	waitFor(t, 5*time.Second, "the viewer's client to leave", func() bool { return len(f.clients(t, name)) == 0 })
	closed.pump(settle)
	if closed.panel.IsDone() {
		t.Error("a cleaned-up viewer took its client's late end as the session's")
	}
	if !f.alive(name) {
		t.Fatal("cleaning up a viewer ended the session")
	}
	if got := f.must(t, "display-message", "-p", "-t", "="+name+":", "#{pane_pid}"); got != panePID {
		t.Fatalf("pane pid changed from %s to %s", panePID, got)
	}
	if got := paneSizes(log); !slices.Equal(got, []string{"136 32"}) {
		t.Errorf("harness saw sizes %q", got)
	}
	assertNoOwnedSessionTraffic(t, missing, detached, closed)
}

func TestViewerReachesTheServerUnderTheRecordedTmuxTmpdir(t *testing.T) {
	f := newTmuxFixture(t)
	name := "lore-host-recorded"
	f.startHarness(t, name, 136, 32)

	// This process now looks for tmux somewhere else, as a lore-tui started from
	// another shell does; the supervisor's record names where the host's server is.
	elsewhere, err := os.MkdirTemp("/tmp", "lore-else-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(elsewhere) })
	t.Setenv("TMUX_TMPDIR", elsewhere)
	if ViewerSessionAlive(name) {
		t.Fatal("with no record the session should not be reachable from the other TMUX_TMPDIR")
	}
	unrecorded := newViewerDriver(t, name, 80, 24)
	unrecorded.waitEnded()
	if got := unrecorded.panel.ViewerEndReason(); got != ViewerAttachFailed {
		t.Fatalf("viewer without the record ended %q, want %q", got, ViewerAttachFailed)
	}
	if err := unrecorded.panel.ViewerErr(); err == nil || !strings.Contains(err.Error(), "TMUX_TMPDIR="+elsewhere) {
		t.Fatalf("attach failure = %v, want the TMUX_TMPDIR it looked under", err)
	}

	login := config.LoginDir()
	if err := os.MkdirAll(login, 0o755); err != nil {
		t.Fatal(err)
	}
	record := fmt.Sprintf(`{"schema_version": 1, "pid": %d, "tmux_tmpdir": %q}`, os.Getpid(), f.root)
	if err := os.WriteFile(filepath.Join(login, "supervisor.json"), []byte(record), 0o644); err != nil {
		t.Fatal(err)
	}
	if !ViewerSessionAlive(name) {
		t.Fatal("liveness did not use the recorded TMUX_TMPDIR")
	}
	viewer := newViewerDriver(t, name, 80, 24)
	viewer.waitReady()
	if got := f.clients(t, name); !slices.Equal(got, []string{"80x24 ignore-size"}) {
		t.Fatalf("clients = %q, want the viewer", got)
	}

	viewer.deliver(tea.KeyPressMsg{Code: tea.KeyPgUp, Mod: tea.ModShift})
	viewer.until("the scrollback capture", 10*time.Second, func(p SessionPanelModel) bool {
		return !p.tmuxCapturePending
	})
	if viewer.panel.tmuxScrollError != "" {
		t.Fatalf("scrollback capture failed: %s", viewer.panel.tmuxScrollError)
	}
	if !slices.ContainsFunc(viewer.panel.tmuxHistory, func(line string) bool { return strings.Contains(line, "HIST-000") }) {
		t.Fatalf("scrollback did not reach the pane's history: %q", viewer.panel.tmuxHistory)
	}
	if view := viewer.panel.View(); !strings.Contains(view, "-- scrollback") {
		t.Fatalf("scrolled viewer view:\n%s", view)
	}
	if _, err := os.Stat(filepath.Join(elsewhere, fmt.Sprintf("tmux-%d", os.Getuid()), config.TmuxServer())); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a viewer started a server under its own TMUX_TMPDIR: %v", err)
	}
	assertNoOwnedSessionTraffic(t, unrecorded, viewer)
}

func TestViewerPanelIsNeverAnOwnedSession(t *testing.T) {
	viewer := NewViewerSessionPanelModel("item", "lore-host-item")
	if !viewer.IsViewer() || NewSessionPanelModel("item").IsViewer() {
		t.Fatal("IsViewer must tell a viewer from an owned panel")
	}
	if other := NewViewerSessionPanelModel("item", "lore-host-item"); other.ViewerGeneration() == viewer.ViewerGeneration() {
		t.Fatal("two viewers of one session share a generation")
	}
	if viewer.Process() != nil || viewer.Ptmx() != nil || viewer.OutputChan() != nil || viewer.PanePID() != 0 {
		t.Fatal("a viewer exposes a harness process or PTY")
	}
	if err := viewer.InjectMessage("hello", "\r", true); err == nil {
		t.Fatal("a viewer accepted an injected message")
	}
	if err := viewer.Interrupt(); err == nil {
		t.Fatal("a viewer accepted an interrupt")
	}

	for _, msg := range []tea.Msg{
		SessionProcessStartedMsg{Slug: "item", Tmux: "lore-host-item"},
		TerminalOutputMsg{Slug: "item", Data: []byte("owned output")},
		StreamCompleteMsg{Slug: "item"},
		StreamErrorMsg{Slug: "item", Err: errors.New("owned failure")},
		QuiescenceTickMsg{Slug: "item"},
		tmuxScrollbackCapturedMsg{Slug: "item", TmuxName: "lore-host-item", Lines: []string{"owned"}},
	} {
		next, cmd := viewer.Update(msg)
		if cmd != nil || next.IsDone() || next.Ptmx() != nil || strings.Contains(next.View(), "owned") {
			t.Errorf("viewer acted on owned-session %T", msg)
		}
	}

	owned := NewSessionPanelModel("item")
	owned.tmuxName = "lore-host-item"
	generation := viewer.ViewerGeneration()
	for _, msg := range []tea.Msg{
		ViewerOutputMsg{Slug: "item", Generation: generation, Data: []byte("viewer output")},
		ViewerEndedMsg{Slug: "item", TmuxName: "lore-host-item", Generation: generation, Reason: ViewerSessionEnded},
		ViewerScrollbackMsg{Slug: "item", TmuxName: "lore-host-item", Generation: generation, Lines: []string{"viewer"}},
	} {
		next, cmd := owned.Update(msg)
		if cmd != nil || next.IsDone() || strings.Contains(next.View(), "viewer output") {
			t.Errorf("owned panel acted on %T", msg)
		}
	}

	stale, _ := viewer.Update(ViewerEndedMsg{Slug: "item", TmuxName: "lore-host-item", Generation: generation + 1000, Reason: ViewerSessionEnded})
	if stale.IsDone() {
		t.Fatal("a viewer took another generation's end")
	}

	_, cmd := viewer.Update(tea.KeyPressMsg{Code: '\\', Mod: tea.ModCtrl})
	if got := firstCmdMsg(cmd); got != (ViewerTerminateMsg{Slug: "item", Generation: generation}) {
		t.Fatalf("ctrl+\\ in a viewer = %#v, want ViewerTerminateMsg", got)
	}
	viewer, _ = viewer.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	_, cmd = viewer.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if _, ok := firstCmdMsg(cmd).(TerminalDetachMsg); !ok {
		t.Fatalf("double Esc in a viewer should detach focus, got %#v", firstCmdMsg(cmd))
	}

	ended, _ := viewer.Update(ViewerEndedMsg{Slug: "item", TmuxName: "lore-host-item", Generation: generation, Reason: ViewerSessionEnded})
	if !ended.IsDone() || ended.ViewerEndReason() != ViewerSessionEnded || ended.ViewerAttachCmd() != nil {
		t.Fatal("an ended viewer should be done and not attach again")
	}
	if !strings.Contains(ended.View(), "session ended") {
		t.Fatalf("ended viewer view = %q", ended.View())
	}
	_, cmd = ended.Update(tea.KeyPressMsg{Code: 'x', Text: "x"})
	if _, ok := firstCmdMsg(cmd).(ClosedPanelInputMsg); !ok {
		t.Fatal("input to an ended viewer should be refused visibly")
	}
}

func TestViewerAttachCommandAndEnvironment(t *testing.T) {
	t.Setenv(config.SessionRuntimeEnv, "dev")
	if got, want := viewerAttachArgs("lore-host-x", true), []string{"-L", "lore-tui-dev", "attach-session", "-f", "ignore-size", "-t", "=lore-host-x"}; !slices.Equal(got, want) {
		t.Errorf("viewer attach args = %q, want %q", got, want)
	}
	if got, want := viewerAttachArgs("lore-host-x", false), []string{"-L", "lore-tui-dev", "attach-session", "-t", "=lore-host-x"}; !slices.Equal(got, want) {
		t.Errorf("viewer attach args before tmux 3.2 = %q, want %q", got, want)
	}
	for version, want := range map[string]bool{
		"tmux 3.8": true, "tmux 3.2": true, "tmux 3.2a": true, "tmux 3.10": true, "tmux 4.0": true,
		"tmux next-3.6": true, "tmux master": true, "": true,
		"tmux 3.1c": false, "tmux 3.0a": false, "tmux 2.9": false,
	} {
		if got := tmuxHasClientFlags(version); got != want {
			t.Errorf("tmuxHasClientFlags(%q) = %v, want %v", version, got, want)
		}
	}

	t.Setenv("LORE_DATA_DIR", t.TempDir())
	t.Setenv("TMUX_TMPDIR", "/tmp/own-dir")
	t.Setenv("TERM", "xterm-ghostty")
	values := func(env []string, key string) []string {
		var out []string
		for _, kv := range env {
			if v, ok := strings.CutPrefix(kv, key+"="); ok {
				out = append(out, v)
			}
		}
		return out
	}
	env := viewerTmuxEnv()
	if got := values(env, "TERM"); !slices.Equal(got, []string{"xterm-256color"}) {
		t.Errorf("viewer TERM = %q", got)
	}
	if got := values(env, "TMUX_TMPDIR"); !slices.Equal(got, []string{"/tmp/own-dir"}) {
		t.Errorf("without a record the viewer keeps its own TMUX_TMPDIR, got %q", got)
	}
	login := config.LoginDir()
	if err := os.MkdirAll(login, 0o755); err != nil {
		t.Fatal(err)
	}
	for body, want := range map[string][]string{
		`{"tmux_tmpdir": "/tmp/supervisor-dir"}`: {"/tmp/supervisor-dir"},
		`{"tmux_tmpdir": null}`:                  nil,
	} {
		if err := os.WriteFile(filepath.Join(login, "supervisor.json"), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		if got := values(viewerTmuxEnv(), "TMUX_TMPDIR"); !slices.Equal(got, want) {
			t.Errorf("record %s: viewer TMUX_TMPDIR = %q, want %q", body, got, want)
		}
	}
}

func TestTmuxWindowPinHoldsAFreshWindowAgainstPlainClients(t *testing.T) {
	f := newTmuxFixture(t)
	name := "lore-host-fresh"
	log := f.startHarness(t, name, 136, 32)
	if got := f.geometry(t, name); got != "136x32 manual" {
		t.Fatalf("new window = %s, want 136x32 with its own manual size", got)
	}
	plain := attachPlainClient(t, name, 70, 20)
	waitFor(t, 5*time.Second, "the plain client to attach", func() bool { return slices.Contains(f.clients(t, name), "70x20 plain") })
	time.Sleep(settle)
	plain.typeLine(t, "plain-1")
	waitFor(t, 5*time.Second, "plain-1", func() bool { return len(paneInputs(log)) == 1 })
	_ = plain.ptmx.Close()
	time.Sleep(settle)
	if got := f.geometry(t, name); got != "136x32 manual" {
		t.Errorf("window after a plain 70x20 client typed = %s", got)
	}
	if got := paneSizes(log); !slices.Equal(got, []string{"136 32"}) {
		t.Errorf("harness saw sizes %q, want only 136 32", got)
	}
}

func TestTmuxWindowPinAtReattachResizesAWindowLeftAtAnotherSize(t *testing.T) {
	f := newTmuxFixture(t)
	identity := mustSessionWorktree(t)
	name := "lore-old-window"
	log := filepath.Join(f.root, "old.log")
	// The way a pre-pin lore-tui made it: global latest, no size of its own.
	f.must(t, "-f", "/dev/null", "set", "-g", "window-size", "latest", ";", "set", "-g", "exit-empty", "on", ";",
		"set", "-g", "status", "off", ";",
		"new-session", "-d", "-s", name, "-x", "100", "-y", "30", "-c", identity.CanonicalPath, "--", f.python, "-I", f.child, log)
	waitFor(t, 10*time.Second, "the harness to start", func() bool { return len(paneSizes(log)) > 0 })
	old := attachPlainClient(t, name, 90, 26)
	waitFor(t, 5*time.Second, "the old client's size to take", func() bool { return f.geometry(t, name) == "90x26 latest" })
	// A client starting up discards terminal input it has not read yet.
	old.typeLine(t, "old-1")
	waitFor(t, 5*time.Second, "old-1", func() bool { return len(paneInputs(log)) == 1 })
	old.stop()

	msg := AttachTerminalCmd("reattach", name, "", "claude-code", t.TempDir(), "", "", identity, 136, 32)()
	started, ok := msg.(SessionProcessStartedMsg)
	if !ok {
		t.Fatalf("re-attach = %T %+v", msg, msg)
	}
	t.Cleanup(func() {
		_ = started.Cmd.Process.Kill()
		_ = started.Ptmx.Close()
		_ = started.Cmd.Wait()
	})
	go func() { _, _ = io.Copy(io.Discard, started.Ptmx) }()
	if got := f.geometry(t, name); got != "136x32 manual" {
		t.Fatalf("re-attached window = %s, want 136x32 with its own manual size", got)
	}
	plain := attachPlainClient(t, name, 70, 20)
	waitFor(t, 5*time.Second, "the plain client to attach", func() bool { return slices.Contains(f.clients(t, name), "70x20 plain") })
	time.Sleep(settle)
	plain.typeLine(t, "plain-1")
	waitFor(t, 5*time.Second, "plain-1", func() bool { return len(paneInputs(log)) == 2 })
	time.Sleep(settle)
	if got := f.geometry(t, name); got != "136x32 manual" {
		t.Errorf("window after a plain client typed = %s", got)
	}
	sizes := paneSizes(log)
	if len(sizes) == 0 || sizes[len(sizes)-1] != "136 32" {
		t.Errorf("harness sizes %q, want the last to be the re-attaching host's 136 32", sizes)
	}
}

func TestTmuxWindowPinRefusedAtReattachFailsTheReattach(t *testing.T) {
	f := newTmuxFixture(t)
	identity := mustSessionWorktree(t)
	name := "lore-old-unpinnable"
	f.must(t, "-f", "/dev/null", "new-session", "-d", "-s", name, "-x", "100", "-y", "30", "--", "sleep", "300")
	refuseResizeWindow(t, f)
	msg := AttachTerminalCmd("reattach", name, "", "claude-code", t.TempDir(), "", "", identity, 136, 32)()
	failed, ok := msg.(StreamErrorMsg)
	if !ok {
		if started, isStarted := msg.(SessionProcessStartedMsg); isStarted {
			_ = started.Cmd.Process.Kill()
			_ = started.Ptmx.Close()
		}
		t.Fatalf("re-attach with a refused pin = %T, want StreamErrorMsg", msg)
	}
	if !strings.Contains(failed.Err.Error(), "resize-window") {
		t.Fatalf("re-attach error = %v, want the refused pin", failed.Err)
	}
	if got := f.clients(t, name); len(got) != 0 {
		t.Fatalf("a client attached despite the refused pin: %q", got)
	}
	if !f.alive(name) {
		t.Fatal("a failed re-attach must leave the surviving session alone")
	}
}

// refuseResizeWindow puts a tmux on PATH that refuses resize-window and passes
// every other command to the real one.
func refuseResizeWindow(t *testing.T, f tmuxFixture) {
	t.Helper()
	bin := t.TempDir()
	script := "#!/bin/sh\nfor arg in \"$@\"; do\n  if [ \"$arg\" = resize-window ]; then echo 'resize-window refused' >&2; exit 1; fi\ndone\nexec " + f.tmux + " \"$@\"\n"
	if err := os.WriteFile(filepath.Join(bin, "tmux"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
}

// stageRecordingHarness puts a claude on PATH that records whether it runs in a
// tmux pane, then waits.
func stageRecordingHarness(t *testing.T, f tmuxFixture) string {
	t.Helper()
	runs := filepath.Join(f.root, "harness-runs")
	bin := t.TempDir()
	script := "#!/bin/sh\nprintf 'tmux=%s\\n' \"${TMUX:-none}\" >> " + runs + "\nexec sleep 30\n"
	if err := os.WriteFile(filepath.Join(bin, "claude"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	return runs
}

func assertNoDirectPTYRun(t *testing.T, runs string) {
	t.Helper()
	time.Sleep(settle)
	data, _ := os.ReadFile(runs)
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if line == "tmux=none" {
			t.Fatalf("the harness ran outside tmux, as a direct PTY: %q", data)
		}
	}
}

func TestTmuxWindowPinFailureFailsTheLaunchWithNoDirectPTY(t *testing.T) {
	f := newTmuxFixture(t)
	knowledgeDir := stageFakeLoreData(t, "claude-code", nil)
	runs := stageRecordingHarness(t, f)
	refuseResizeWindow(t, f)
	identity := mustSessionWorktree(t)
	d := SessionDescriptor{Type: SessionSpec, Slug: "pin-refused", Framework: "claude-code", Model: "smoke-model", SkipConfirm: true, FindingIndex: -1, Worktree: &identity}

	msg := StartTerminalCmd(d, 136, 32, knowledgeDir, SessionEnv{Instance: "pinhost"}, true)()
	failed, ok := msg.(StreamErrorMsg)
	if !ok {
		if started, isStarted := msg.(SessionProcessStartedMsg); isStarted {
			_ = started.Cmd.Process.Kill()
			_ = started.Ptmx.Close()
		}
		t.Fatalf("launch with a refused pin = %T, want StreamErrorMsg", msg)
	}
	if !strings.Contains(failed.Err.Error(), "tmux hosting failed for pin-refused") || !strings.Contains(failed.Err.Error(), "resize-window") {
		t.Fatalf("launch error = %v, want the refused pin", failed.Err)
	}
	for _, notice := range failed.Notices {
		if strings.Contains(notice.Message, "direct PTY") {
			t.Fatalf("launch announced a direct-PTY fallback: %+v", notice)
		}
	}
	if name := TmuxSessionName("pinhost", "pin-refused"); f.alive(name) {
		t.Fatalf("the half-made session %s was left running", name)
	}
	assertNoDirectPTYRun(t, runs)
}

func TestTmuxWindowPinLaunchFailsWhenTheSessionCannotBeCreated(t *testing.T) {
	f := newTmuxFixture(t)
	knowledgeDir := stageFakeLoreData(t, "claude-code", nil)
	runs := stageRecordingHarness(t, f)
	name := TmuxSessionName("pinhost", "taken")
	f.must(t, "-f", "/dev/null", "new-session", "-d", "-s", name, "-x", "50", "-y", "10", "--", "sleep", "300")
	before := f.must(t, "display-message", "-p", "-t", "="+name+":", "#{pane_pid} #{window_width}x#{window_height}")
	identity := mustSessionWorktree(t)
	d := SessionDescriptor{Type: SessionSpec, Slug: "taken", Framework: "claude-code", Model: "smoke-model", SkipConfirm: true, FindingIndex: -1, Worktree: &identity}

	msg := StartTerminalCmd(d, 136, 32, knowledgeDir, SessionEnv{Instance: "pinhost"}, true)()
	failed, ok := msg.(StreamErrorMsg)
	if !ok {
		if started, isStarted := msg.(SessionProcessStartedMsg); isStarted {
			_ = started.Cmd.Process.Kill()
			_ = started.Ptmx.Close()
		}
		t.Fatalf("launch onto a taken name = %T, want StreamErrorMsg", msg)
	}
	if !strings.Contains(failed.Err.Error(), "new-session") {
		t.Fatalf("launch error = %v, want the failed new-session", failed.Err)
	}
	if after := f.must(t, "display-message", "-p", "-t", "="+name+":", "#{pane_pid} #{window_width}x#{window_height}"); after != before {
		t.Fatalf("the session that already had the name changed: %s, then %s", before, after)
	}
	assertNoDirectPTYRun(t, runs)
}
