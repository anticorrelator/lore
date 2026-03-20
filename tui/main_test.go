package main

import (
	"fmt"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// fakeCSIMsg simulates bubbletea's unexported unknownCSISequenceMsg,
// which is a []byte ([]uint8 under the hood). The reflect check in
// translateCSIu detects any []uint8 slice, so this plain []byte works.
type fakeCSIMsg []byte

func TestTranslateCSIuEnter(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[13u"))
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyEnter {
		t.Errorf("expected KeyEnter, got %v", km.Type)
	}
}

func TestTranslateCSIuEsc(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[27u"))
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyEscape {
		t.Errorf("expected KeyEscape, got %v", km.Type)
	}
}

func TestTranslateCSIuTab(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[9u"))
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyTab {
		t.Errorf("expected KeyTab, got %v", km.Type)
	}
}

func TestTranslateCSIuBackspace(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[127u"))
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyBackspace {
		t.Errorf("expected KeyBackspace, got %v", km.Type)
	}
}

func TestTranslateCSIuShiftEnter(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[13;2u"))
	got := translateCSIu(msg)
	if _, ok := got.(shiftEnterMsg); !ok {
		t.Fatalf("expected shiftEnterMsg, got %T", got)
	}
}

func TestTranslateCSIuAltEnter(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[13;3u"))
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyEnter {
		t.Errorf("expected KeyEnter, got %v", km.Type)
	}
	if !km.Alt {
		t.Errorf("expected Alt=true")
	}
}

func TestTranslateCSIuCtrlC(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[99;5u"))
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyCtrlC {
		t.Errorf("expected KeyCtrlC, got %v", km.Type)
	}
}

func TestTranslateCSIuCtrlD(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[100;5u"))
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyCtrlD {
		t.Errorf("expected KeyCtrlD, got %v", km.Type)
	}
}

func TestTranslateCSIuPrintableChar(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[97u"))
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyRunes {
		t.Errorf("expected KeyRunes, got %v", km.Type)
	}
	if len(km.Runes) != 1 || km.Runes[0] != 'a' {
		t.Errorf("expected Runes=['a'], got %v", km.Runes)
	}
}

func TestTranslateCSIuAltPrintable(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[49;3u"))
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyRunes {
		t.Errorf("expected KeyRunes, got %v", km.Type)
	}
	if !km.Alt {
		t.Errorf("expected Alt=true")
	}
	if len(km.Runes) != 1 || km.Runes[0] != '1' {
		t.Errorf("expected Runes=['1'], got %v", km.Runes)
	}
}

func TestTranslateCSIuSpace(t *testing.T) {
	msg := fakeCSIMsg([]byte("\x1b[32u"))
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyRunes {
		t.Errorf("expected KeyRunes, got %v", km.Type)
	}
	if len(km.Runes) != 1 || km.Runes[0] != ' ' {
		t.Errorf("expected Runes=[' '], got %v", km.Runes)
	}
}

func TestTranslateCSIuNonCSIPassthrough(t *testing.T) {
	msg := tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'a'}}
	got := translateCSIu(msg)
	km, ok := got.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", got)
	}
	if km.Type != tea.KeyRunes || len(km.Runes) != 1 || km.Runes[0] != 'a' {
		t.Errorf("expected unchanged KeyMsg{Runes: ['a']}, got %v", km)
	}
}

func TestTranslateCSIuNonUFinalPassthrough(t *testing.T) {
	// CSI sequence that doesn't end in 'u' should pass through.
	msg := fakeCSIMsg([]byte("\x1b[13~"))
	got := translateCSIu(msg)
	if _, ok := got.(fakeCSIMsg); !ok {
		t.Fatalf("expected fakeCSIMsg passthrough, got %T", got)
	}
}

// --- Keybind contract tests ---
//
// These verify that every keybind advertised in a modal's render function
// produces the correct tea.Msg when sent as a kitty CSI u sequence.
// If a new keybind is added to a modal's UI but the CSI u parser can't
// translate it, these tests fail — catching the regression before it ships.

// csiuSeq builds a CSI u byte sequence: ESC [ <codepoint> [; <modifier>] u
func csiuSeq(codepoint int, modifier int) fakeCSIMsg {
	if modifier <= 1 {
		return fakeCSIMsg([]byte(fmt.Sprintf("\x1b[%du", codepoint)))
	}
	return fakeCSIMsg([]byte(fmt.Sprintf("\x1b[%d;%du", codepoint, modifier)))
}

// TestSpecConfirmModalKeybindContract verifies that the keybinds displayed in
// renderSpecConfirmModal (Alt+1, Alt+2, Enter, Esc, Shift+Enter) all produce
// the correct tea.Msg via translateCSIu.
func TestSpecConfirmModalKeybindContract(t *testing.T) {
	tests := []struct {
		label   string
		seq     fakeCSIMsg
		checkFn func(t *testing.T, msg tea.Msg)
	}{
		{
			label: "Enter (launch)",
			seq:   csiuSeq(13, 1),
			checkFn: func(t *testing.T, msg tea.Msg) {
				km := assertKeyMsg(t, msg)
				if km.Type != tea.KeyEnter {
					t.Errorf("expected KeyEnter, got %v", km.Type)
				}
			},
		},
		{
			label: "Esc (cancel)",
			seq:   csiuSeq(27, 1),
			checkFn: func(t *testing.T, msg tea.Msg) {
				km := assertKeyMsg(t, msg)
				if km.Type != tea.KeyEscape {
					t.Errorf("expected KeyEscape, got %v", km.Type)
				}
			},
		},
		{
			label: "Shift+Enter (newline)",
			seq:   csiuSeq(13, 2),
			checkFn: func(t *testing.T, msg tea.Msg) {
				if _, ok := msg.(shiftEnterMsg); !ok {
					t.Fatalf("expected shiftEnterMsg, got %T", msg)
				}
			},
		},
		{
			label: "Alt+1 (toggle short mode)",
			seq:   csiuSeq('1', 3),
			checkFn: func(t *testing.T, msg tea.Msg) {
				km := assertKeyMsg(t, msg)
				assertKeyString(t, km, "alt+1")
			},
		},
		{
			label: "Alt+2 (toggle skip confirm)",
			seq:   csiuSeq('2', 3),
			checkFn: func(t *testing.T, msg tea.Msg) {
				km := assertKeyMsg(t, msg)
				assertKeyString(t, km, "alt+2")
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.label, func(t *testing.T) {
			tt.checkFn(t, translateCSIu(tt.seq))
		})
	}
}

// TestAIModalKeybindContract verifies keybinds used by the AI input modal.
func TestAIModalKeybindContract(t *testing.T) {
	tests := []struct {
		label   string
		seq     fakeCSIMsg
		checkFn func(t *testing.T, msg tea.Msg)
	}{
		{
			label: "Enter (submit)",
			seq:   csiuSeq(13, 1),
			checkFn: func(t *testing.T, msg tea.Msg) {
				km := assertKeyMsg(t, msg)
				if km.Type != tea.KeyEnter {
					t.Errorf("expected KeyEnter, got %v", km.Type)
				}
			},
		},
		{
			label: "Esc (cancel)",
			seq:   csiuSeq(27, 1),
			checkFn: func(t *testing.T, msg tea.Msg) {
				km := assertKeyMsg(t, msg)
				if km.Type != tea.KeyEscape {
					t.Errorf("expected KeyEscape, got %v", km.Type)
				}
			},
		},
		{
			label: "Shift+Enter (newline)",
			seq:   csiuSeq(13, 2),
			checkFn: func(t *testing.T, msg tea.Msg) {
				if _, ok := msg.(shiftEnterMsg); !ok {
					t.Fatalf("expected shiftEnterMsg, got %T", msg)
				}
			},
		},
		{
			label: "Alt+Enter (newline)",
			seq:   csiuSeq(13, 3),
			checkFn: func(t *testing.T, msg tea.Msg) {
				km := assertKeyMsg(t, msg)
				if km.Type != tea.KeyEnter {
					t.Errorf("expected KeyEnter, got %v", km.Type)
				}
				if !km.Alt {
					t.Error("expected Alt=true")
				}
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.label, func(t *testing.T) {
			tt.checkFn(t, translateCSIu(tt.seq))
		})
	}
}

// TestTypedCharactersInKittyMode verifies that regular character input
// is correctly translated from CSI u to KeyRunes. This prevents the
// "modal freezes because typed characters don't reach the textarea" regression.
func TestTypedCharactersInKittyMode(t *testing.T) {
	chars := "abcdefghijklmnopqrstuvwxyz0123456789 "
	for _, c := range chars {
		t.Run(fmt.Sprintf("char_%c", c), func(t *testing.T) {
			got := translateCSIu(csiuSeq(int(c), 1))
			km := assertKeyMsg(t, got)
			if km.Type != tea.KeyRunes {
				t.Errorf("char %c: expected KeyRunes, got %v", c, km.Type)
			}
			if len(km.Runes) != 1 || km.Runes[0] != c {
				t.Errorf("char %c: expected rune %c, got %v", c, c, km.Runes)
			}
		})
	}
}

// --- Test helpers ---

func assertKeyMsg(t *testing.T, msg tea.Msg) tea.KeyMsg {
	t.Helper()
	km, ok := msg.(tea.KeyMsg)
	if !ok {
		t.Fatalf("expected tea.KeyMsg, got %T", msg)
	}
	return km
}

func assertKeyString(t *testing.T, km tea.KeyMsg, want string) {
	t.Helper()
	if km.String() != want {
		t.Errorf("expected %q, got %q", want, km.String())
	}
}
