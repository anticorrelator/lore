package main

import (
	"bytes"
	"reflect"

	tea "github.com/charmbracelet/bubbletea"
)

// shiftEnterMsg is synthesized from the kitty keyboard protocol CSI u sequence \x1b[13;2u.
// It signals Shift+Enter in modal text inputs (insert newline).
type shiftEnterMsg struct{}

// translateCSIu converts kitty keyboard protocol CSI u sequences to synthetic tea.Msg values.
// bubbletea delivers unrecognized escape sequences as an unexported unknownCSISequenceMsg ([]uint8),
// accessible only via reflect. This mirrors the pattern used in specpanel.go.
//
// Kitty mode 1 (disambiguate) sends ALL keys as CSI u: ESC [ <codepoint> [; <modifiers>] u
// where codepoint is the Unicode value and modifiers encode shift(2), alt(3), ctrl(5), etc.
// We must translate every key the modals use, not just a handful — otherwise the textarea
// can't receive typed characters and the modal freezes (same failure as the first attempt).
func translateCSIu(msg tea.Msg) tea.Msg {
	v := reflect.ValueOf(msg)
	if v.Kind() != reflect.Slice || v.Type().Elem().Kind() != reflect.Uint8 {
		return msg
	}
	b := v.Bytes()

	// Parse CSI u format: ESC [ <codepoint> [; <modifiers>] u
	if len(b) < 4 || b[0] != 0x1b || b[1] != '[' || b[len(b)-1] != 'u' {
		return msg
	}
	// Extract the parameter string between '[' and 'u'
	params := b[2 : len(b)-1]

	var codepoint, modifiers int
	if idx := bytes.IndexByte(params, ';'); idx >= 0 {
		codepoint = parseDecimal(params[:idx])
		modifiers = parseDecimal(params[idx+1:])
	} else {
		codepoint = parseDecimal(params)
		modifiers = 1 // default: no modifiers
	}

	if codepoint < 0 {
		return msg // malformed
	}

	// Kitty modifier bits: 1=none, 2=shift, 3=alt, 4=shift+alt, 5=ctrl,
	// 6=ctrl+shift, 7=ctrl+alt, 8=ctrl+shift+alt
	// The value is 1-based (1 means no modifiers).
	modBits := modifiers - 1
	hasShift := modBits&0x01 != 0
	hasAlt := modBits&0x02 != 0
	hasCtrl := modBits&0x04 != 0

	// Shift+Enter → custom shiftEnterMsg (bubbletea has no KeyShiftEnter).
	if codepoint == 13 && hasShift && !hasAlt && !hasCtrl {
		return shiftEnterMsg{}
	}

	// Map special codepoints to bubbletea key types.
	if kt, ok := csiuSpecialKeys[codepoint]; ok {
		return tea.KeyMsg{Type: kt, Alt: hasAlt}
	}

	// Ctrl+<letter> → map to bubbletea's KeyCtrl* constants.
	if hasCtrl && codepoint >= 'a' && codepoint <= 'z' {
		ctrlType := tea.KeyCtrlA + tea.KeyType(codepoint-'a')
		return tea.KeyMsg{Type: ctrlType, Alt: hasAlt}
	}

	// Printable characters → tea.KeyMsg with Runes.
	if codepoint >= 32 {
		r := rune(codepoint)
		return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}, Alt: hasAlt}
	}

	return msg
}

// parseDecimal parses a decimal integer from a byte slice. Returns -1 on error.
func parseDecimal(b []byte) int {
	if len(b) == 0 {
		return -1
	}
	n := 0
	for _, c := range b {
		if c < '0' || c > '9' {
			return -1
		}
		n = n*10 + int(c-'0')
	}
	return n
}

// csiuSpecialKeys maps kitty CSI u codepoints to bubbletea key types.
var csiuSpecialKeys = map[int]tea.KeyType{
	9:   tea.KeyTab,
	13:  tea.KeyEnter,
	27:  tea.KeyEscape,
	127: tea.KeyBackspace,
}
