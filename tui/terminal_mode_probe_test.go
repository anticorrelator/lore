package main

// Contract tests for the terminal-mode interaction contract: global keys
// resolve by focus (not by whether a session merely exists), the manual
// ctrl+t view choice survives navigation, Esc-Esc detaches focus only,
// ctrl+c quits from the list and terminates/discards only with the terminal
// focused, and lore scrollback lives on the shift-modified scroll keys while
// plain scroll keys reach the PTY. Tests drive the real Update path and are
// named by the hint text they pin (see keymap.go test refs).

import (
	"bytes"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/work"
)

// activeUnfocusedModel: stateWork, spec panel on item-1, cursor on item-1,
// terminalMode true, focus on the left list — the state the app lands in
// after launching a spec from the confirm modal (sessionLaunchedFromModal).
func activeUnfocusedModel() model {
	m := workContractModel()
	m.setSessionPanel("item-1", work.NewSessionPanelModel("item-1"))
	m.terminalMode = true
	m.focusedPanel = panelLeft
	return m
}

// doneSessionPanel returns a finished session panel, which qualifies for the ctrl+t
// toggle-to-terminal branch without needing a live PTY.
func doneSessionPanel(slug string) work.SessionPanelModel {
	p := work.NewSessionPanelModel(slug)
	p, _ = p.Update(work.StreamCompleteMsg{Slug: slug})
	return p
}

func isQuitCmd(cmd tea.Cmd) bool {
	if cmd == nil {
		return false
	}
	_, ok := cmd().(tea.QuitMsg)
	return ok
}

// TestActiveUnfocusedWorkListKeybindContract: with a session running but the
// list focused, the status bar advertises the full kmWorkList hint set and
// every advertised key performs its list-side action.
func TestActiveUnfocusedWorkListKeybindContract(t *testing.T) {
	t.Run("status bar advertises work-list hints", func(t *testing.T) {
		m := activeUnfocusedModel()
		if got := m.keymapContext(); got != kmWorkList {
			t.Fatalf("active-unfocused context = %v, want kmWorkList", got)
		}
		hints := stripANSI(strings.Join(m.statusBarHints(kmWorkList), " · "))
		for _, want := range []string{"q quit", "? help", "K knowledge", "S settings", "f follow-ups"} {
			if !strings.Contains(hints, want) {
				t.Errorf("status bar does not advertise %q (hints: %s)", want, hints)
			}
		}
	})
	t.Run("q (quit)", func(t *testing.T) {
		_, cmd := updateModel(t, activeUnfocusedModel(), press('q'))
		if !isQuitCmd(cmd) {
			t.Error("q should quit when the list has focus, even with a session running")
		}
	})
	t.Run("? (help)", func(t *testing.T) {
		nm, _ := updateModel(t, activeUnfocusedModel(), press('?'))
		if !nm.showHelp {
			t.Error("? should open the help modal when the list has focus")
		}
	})
	t.Run("K (knowledge)", func(t *testing.T) {
		nm, _ := updateModel(t, activeUnfocusedModel(), press('K'))
		if nm.state != stateKnowledge {
			t.Errorf("K should enter the knowledge browser, state = %v", nm.state)
		}
	})
	t.Run("S (settings)", func(t *testing.T) {
		setupFakeLoreData(t, `{"version": 1}`)
		nm, _ := updateModel(t, activeUnfocusedModel(), press('S'))
		if !nm.settingsActive {
			t.Error("S should open the settings configurator when the list has focus")
		}
	})
	t.Run("f (follow-ups)", func(t *testing.T) {
		nm, _ := updateModel(t, activeUnfocusedModel(), press('f'))
		if nm.state != stateFollowUps {
			t.Errorf("f should switch to follow-ups, state = %v", nm.state)
		}
	})
	t.Run("t (settlement)", func(t *testing.T) {
		nm, _ := updateModel(t, activeUnfocusedModel(), press('t'))
		if nm.state != stateSettlement {
			t.Errorf("t should switch to settlement, state = %v", nm.state)
		}
		if nm.terminalMode {
			t.Error("terminalMode should reset when leaving the work view")
		}
	})
	t.Run("ctrl+t (detail · terminal)", func(t *testing.T) {
		m := activeUnfocusedModel()
		m.setSessionPanel("item-1", doneSessionPanel("item-1"))
		nm, _ := updateModel(t, m, press('t', tea.ModCtrl))
		if nm.terminalMode {
			t.Error("ctrl+t from the left panel should switch the right panel to detail")
		}
		if nm.focusedPanel != panelLeft {
			t.Error("ctrl+t from the left panel must not move focus")
		}
		nm, _ = updateModel(t, nm, press('t', tea.ModCtrl))
		if !nm.terminalMode {
			t.Error("a second ctrl+t should switch back to the terminal")
		}
	})
	t.Run("/ (search popup)", func(t *testing.T) {
		nm, _ := updateModel(t, activeUnfocusedModel(), press('/'))
		if !nm.popupActive {
			t.Error("/ should open the search popup")
		}
	})
	t.Run("A (archive / unarchive)", func(t *testing.T) {
		nm, _ := updateModel(t, activeUnfocusedModel(), press('A'))
		if nm.confirmAction != "archive" {
			t.Errorf("confirmAction = %q, want archive", nm.confirmAction)
		}
	})
	t.Run("s (attach focus to running terminal)", func(t *testing.T) {
		nm, cmd := updateModel(t, activeUnfocusedModel(), press('s'))
		if cmd == nil {
			t.Fatal("s produced no command")
		}
		nm, _ = updateModel(t, nm, cmd())
		if nm.focusedPanel != panelRight || !nm.terminalMode {
			t.Errorf("s did not attach: focus=%v terminalMode=%v", nm.focusedPanel, nm.terminalMode)
		}
	})
}

// TestGlobalQuitKeybindContract pins the kmGlobal "q / Ctrl+C / Ctrl+D quit"
// row: each quits whenever the terminal is not focused, including with a
// session running in the background.
func TestGlobalQuitKeybindContract(t *testing.T) {
	t.Run("q (quit)", func(t *testing.T) {
		_, cmd := updateModel(t, activeUnfocusedModel(), press('q'))
		if !isQuitCmd(cmd) {
			t.Error("q should quit with the list focused")
		}
	})
	t.Run("Ctrl+C (quit)", func(t *testing.T) {
		_, cmd := updateModel(t, activeUnfocusedModel(), press('c', tea.ModCtrl))
		if !isQuitCmd(cmd) {
			t.Error("ctrl+c should quit with the list focused, not terminate the hovered session")
		}
	})
	t.Run("Ctrl+D (quit)", func(t *testing.T) {
		_, cmd := updateModel(t, activeUnfocusedModel(), press('d', tea.ModCtrl))
		if !isQuitCmd(cmd) {
			t.Error("ctrl+d should quit")
		}
	})
}

// TestTerminalFocusedKeysForwardToSubprocess: with the terminal focused, the
// keys the global guards release (q, ?, K, S, f) reach the PTY instead of
// triggering their list-side actions.
func TestTerminalFocusedKeysForwardToSubprocess(t *testing.T) {
	newFixture := func(t *testing.T) (model, *os.File) {
		t.Helper()
		r, w, err := os.Pipe()
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { r.Close(); w.Close() })
		m := workContractModel()
		panel := work.NewSessionPanelModel("item-1")
		panel = panel.SetPtmx(w, nil, nil)
		m.setSessionPanel("item-1", panel)
		m.terminalMode = true
		m.focusedPanel = panelRight
		return m, r
	}
	for _, key := range []rune{'q', '?', 'K', 'S', 'f'} {
		t.Run(fmt.Sprintf("%c (forwarded to subprocess)", key), func(t *testing.T) {
			m, r := newFixture(t)
			nm, cmd := updateModel(t, m, press(key))
			if isQuitCmd(cmd) {
				t.Fatalf("%c quit the app despite terminal focus", key)
			}
			if nm.showHelp || nm.settingsActive || nm.state != stateWork {
				t.Fatalf("%c triggered a list-side action despite terminal focus", key)
			}
			if err := r.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
				t.Fatal(err)
			}
			buf := make([]byte, 8)
			n, err := r.Read(buf)
			if err != nil {
				t.Fatalf("expected %c forwarded to the PTY: %v", key, err)
			}
			if got, want := buf[:n], []byte(string(key)); !bytes.Equal(got, want) {
				t.Errorf("PTY received %q, want %q", got, want)
			}
		})
	}
}

// TestCtrlTChoicePersistsAcrossNavigation pins the per-item view preference:
// choosing the detail view over a running terminal survives a cursor
// round-trip instead of being re-derived away.
func TestCtrlTChoicePersistsAcrossNavigation(t *testing.T) {
	m := workContractModel()
	m.setSessionPanel("item-1", doneSessionPanel("item-1"))
	m.terminalMode = true
	m.focusedPanel = panelRight

	m, _ = updateModel(t, m, press('t', tea.ModCtrl)) // choose detail view
	if m.terminalMode {
		t.Fatal("ctrl+t did not switch to detail")
	}
	m, _ = updateModel(t, m, press(tea.KeyEscape)) // back to list
	if m.focusedPanel != panelLeft {
		t.Fatal("esc did not return focus to list")
	}
	m, _ = updateModel(t, m, press('j')) // item-2 (no panel)
	if m.terminalMode {
		t.Fatal("terminalMode true on item without panel")
	}
	m, _ = updateModel(t, m, press('k')) // back to item-1
	if m.terminalMode {
		t.Error("detail choice lost: navigation re-enabled terminalMode")
	}

	// Choosing the terminal again clears the preference, restoring auto-show.
	m, _ = updateModel(t, m, press('t', tea.ModCtrl))
	if !m.terminalMode {
		t.Fatal("ctrl+t did not switch back to terminal")
	}
	m, _ = updateModel(t, m, press('j'))
	m, _ = updateModel(t, m, press('k'))
	if !m.terminalMode {
		t.Error("auto-show should resume after the user switches back to the terminal")
	}
}

// TestTerminalDetachKeepsTerminalView pins the "Esc Esc — detach focus, back
// to list" hint: detach moves focus only; the right panel keeps the terminal.
func TestTerminalDetachKeepsTerminalView(t *testing.T) {
	m := workContractModel()
	m.setSessionPanel("item-1", work.NewSessionPanelModel("item-1"))
	m.terminalMode = true
	m.focusedPanel = panelRight
	nm, _ := updateModel(t, m, work.TerminalDetachMsg{Slug: "item-1"})
	if nm.focusedPanel != panelLeft {
		t.Error("detach did not move focus to list")
	}
	if !nm.terminalMode {
		t.Error("detach must keep the right panel on the terminal")
	}
}

// TestWorkListAttachSessionKeybindContract pins the kmWorkList "l/Enter"
// state-aware label and its dispatch: with a session shown for the hovered
// item the hint reads "attach session" and both keys attach to it.
func TestWorkListAttachSessionKeybindContract(t *testing.T) {
	t.Run("label reads attach session when terminal shown", func(t *testing.T) {
		m := activeUnfocusedModel()
		hints := stripANSI(strings.Join(m.statusBarHints(kmWorkList), " · "))
		if !strings.Contains(hints, "l/Enter attach session") {
			t.Errorf("hints do not advertise attach session: %s", hints)
		}
	})
	t.Run("label reads open without a session", func(t *testing.T) {
		m := workContractModel()
		hints := stripANSI(strings.Join(m.statusBarHints(kmWorkList), " · "))
		if !strings.Contains(hints, "l/Enter open") {
			t.Errorf("hints do not advertise open: %s", hints)
		}
	})
	t.Run("label reads open when detail view chosen", func(t *testing.T) {
		m := activeUnfocusedModel()
		m, _ = updateModel(t, m, press('t', tea.ModCtrl)) // choose detail
		hints := stripANSI(strings.Join(m.statusBarHints(kmWorkList), " · "))
		if !strings.Contains(hints, "l/Enter open") {
			t.Errorf("hints should fall back to open when the right panel shows detail: %s", hints)
		}
	})
	t.Run("l (attach session)", func(t *testing.T) {
		nm, _ := updateModel(t, activeUnfocusedModel(), press('l'))
		if nm.focusedPanel != panelRight || !nm.terminalMode {
			t.Errorf("l did not attach: focus=%v terminalMode=%v", nm.focusedPanel, nm.terminalMode)
		}
	})
	t.Run("Enter (attach session)", func(t *testing.T) {
		nm, cmd := updateModel(t, activeUnfocusedModel(), press(tea.KeyEnter))
		if cmd == nil {
			t.Fatal("Enter produced no command")
		}
		nm, _ = updateModel(t, nm, cmd())
		if nm.focusedPanel != panelRight || !nm.terminalMode {
			t.Errorf("Enter did not attach: focus=%v terminalMode=%v", nm.focusedPanel, nm.terminalMode)
		}
	})
}

// followupActiveUnfocusedModel mirrors activeUnfocusedModel on the follow-up
// side: session on fu-1, cursor on fu-1, terminal shown, list focused.
func followupActiveUnfocusedModel(t *testing.T) model {
	t.Helper()
	m := followupContractModel()
	m.width = 120
	m.height = 40
	m.setSessionPanel("fu-1", work.NewSessionPanelModel("fu-1"))
	m.terminalMode = true
	m.focusedPanel = panelLeft
	return m
}

// TestFollowupListAttachSessionKeybindContract pins the kmFollowupList
// "l/Enter" state-aware label and its dispatch.
func TestFollowupListAttachSessionKeybindContract(t *testing.T) {
	t.Run("label reads attach session when terminal shown", func(t *testing.T) {
		m := followupActiveUnfocusedModel(t)
		_ = m.loadFollowupDetail("fu-1") // sync detail to the hovered item
		hints := stripANSI(strings.Join(m.statusBarHints(kmFollowupList), " · "))
		if !strings.Contains(hints, "l/Enter attach session") {
			t.Errorf("hints do not advertise attach session: %s", hints)
		}
	})
	t.Run("l (attach session)", func(t *testing.T) {
		nm, _ := updateModel(t, followupActiveUnfocusedModel(t), press('l'))
		if nm.focusedPanel != panelRight || !nm.terminalMode {
			t.Errorf("l did not attach: focus=%v terminalMode=%v", nm.focusedPanel, nm.terminalMode)
		}
	})
	t.Run("Enter (attach session)", func(t *testing.T) {
		nm, cmd := updateModel(t, followupActiveUnfocusedModel(t), press(tea.KeyEnter))
		if cmd == nil {
			t.Fatal("Enter produced no command")
		}
		nm, _ = updateModel(t, nm, cmd())
		if nm.focusedPanel != panelRight || !nm.terminalMode {
			t.Errorf("Enter did not attach: focus=%v terminalMode=%v", nm.focusedPanel, nm.terminalMode)
		}
	})
}

// TestFollowupActiveUnfocusedKeybindContract: follow-up analog of the
// active-unfocused state — advertised list keys work with the list focused.
func TestFollowupActiveUnfocusedKeybindContract(t *testing.T) {
	t.Run("w (work list)", func(t *testing.T) {
		nm, _ := updateModel(t, followupActiveUnfocusedModel(t), press('w'))
		if nm.state != stateWork {
			t.Errorf("w should return to the work list, state = %v", nm.state)
		}
	})
	t.Run("q (quit)", func(t *testing.T) {
		_, cmd := updateModel(t, followupActiveUnfocusedModel(t), press('q'))
		if !isQuitCmd(cmd) {
			t.Error("q should quit with the list focused")
		}
	})
	t.Run("Ctrl+C (quit)", func(t *testing.T) {
		_, cmd := updateModel(t, followupActiveUnfocusedModel(t), press('c', tea.ModCtrl))
		if !isQuitCmd(cmd) {
			t.Error("ctrl+c should quit with the list focused")
		}
	})
}

// scrollbackFixture builds a terminal-focused model whose spec panel has real
// scrollback content (more lines than the viewport) and a pipe standing in
// for the PTY, so tests can assert both scroll movement and PTY writes.
func scrollbackFixture(t *testing.T) (model, *os.File) {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { r.Close(); w.Close() })

	panel := work.NewSessionPanelModel("item-1")
	panel, _ = panel.Update(tea.WindowSizeMsg{Width: 40, Height: 6})
	var data []byte
	for i := 0; i < 40; i++ {
		data = append(data, []byte(fmt.Sprintf("line %d\r\n", i))...)
	}
	panel, _ = panel.Update(work.TerminalOutputMsg{Slug: "item-1", Data: data})
	panel = panel.SetPtmx(w, nil, nil)

	m := workContractModel()
	m.setSessionPanel("item-1", panel)
	m.terminalMode = true
	m.focusedPanel = panelRight
	return m, r
}

func panelView(t *testing.T, m model) string {
	t.Helper()
	panel, ok := m.sessionPanels["item-1"]
	if !ok {
		t.Fatal("spec panel missing")
	}
	return panel.View()
}

// inScrollback reports whether the panel renders the scrollback window (the
// position indicator only appears with a non-zero scroll offset).
func inScrollback(t *testing.T, m model) bool {
	return strings.Contains(stripANSI(panelView(t, m)), "-- scrollback (")
}

// expectNoPTYWrite fails if any byte arrives on the pipe within the window.
func expectNoPTYWrite(t *testing.T, r *os.File) {
	t.Helper()
	if err := r.SetReadDeadline(time.Now().Add(50 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 8)
	if n, err := r.Read(buf); err == nil {
		t.Fatalf("unexpected PTY write: %q", buf[:n])
	}
}

// expectPTYWrite fails unless the pipe receives exactly want.
func expectPTYWrite(t *testing.T, r *os.File, want []byte) {
	t.Helper()
	if err := r.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 16)
	n, err := r.Read(buf)
	if err != nil {
		t.Fatalf("expected PTY write %q: %v", want, err)
	}
	if !bytes.Equal(buf[:n], want) {
		t.Fatalf("PTY received %q, want %q", buf[:n], want)
	}
}

// TestTerminalScrollbackKeybindContract pins the kmTerminal shifted-scroll
// hints: shift-modified PgUp/PgDn/Home/End move lore scrollback without
// touching the PTY, while the plain keys forward their legacy encodings to
// the subprocess and leave the view live.
func TestTerminalScrollbackKeybindContract(t *testing.T) {
	t.Run("Shift+PgUp (scrollback)", func(t *testing.T) {
		m, r := scrollbackFixture(t)
		nm, _ := updateModel(t, m, press(tea.KeyPgUp, tea.ModShift))
		if !inScrollback(t, nm) {
			t.Error("shift+pgup should scroll into history")
		}
		expectNoPTYWrite(t, r)
	})
	t.Run("Shift+PgDn (scrollback)", func(t *testing.T) {
		m, r := scrollbackFixture(t)
		nm, _ := updateModel(t, m, press(tea.KeyPgUp, tea.ModShift))
		nm, _ = updateModel(t, nm, press(tea.KeyPgDown, tea.ModShift))
		if inScrollback(t, nm) {
			t.Error("shift+pgdn should scroll back toward the live view")
		}
		expectNoPTYWrite(t, r)
	})
	t.Run("Shift+Home (history top)", func(t *testing.T) {
		m, r := scrollbackFixture(t)
		nm, _ := updateModel(t, m, press(tea.KeyHome, tea.ModShift))
		if !inScrollback(t, nm) {
			t.Error("shift+home should jump to the top of the buffer")
		}
		expectNoPTYWrite(t, r)
	})
	t.Run("Shift+End (live)", func(t *testing.T) {
		m, r := scrollbackFixture(t)
		nm, _ := updateModel(t, m, press(tea.KeyHome, tea.ModShift))
		nm, _ = updateModel(t, nm, press(tea.KeyEnd, tea.ModShift))
		if inScrollback(t, nm) {
			t.Error("shift+end should snap back to the live view")
		}
		expectNoPTYWrite(t, r)
	})
	for _, tc := range []struct {
		name string
		code rune
	}{
		{"PgUp (forwarded to subprocess)", tea.KeyPgUp},
		{"PgDn (forwarded to subprocess)", tea.KeyPgDown},
		{"Home (forwarded to subprocess)", tea.KeyHome},
		{"End (forwarded to subprocess)", tea.KeyEnd},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m, r := scrollbackFixture(t)
			nm, _ := updateModel(t, m, press(tc.code))
			if inScrollback(t, nm) {
				t.Errorf("plain %s must not move lore scrollback", tc.name)
			}
			expectPTYWrite(t, r, work.KeyToBytes(press(tc.code)))
		})
	}
}
