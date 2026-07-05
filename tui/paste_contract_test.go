package main

import (
	"strings"
	"testing"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/search"
)

// These tests enforce the inputmsg contract (see internal/inputmsg): every
// surface that owns a focused text input must receive bracketed-paste
// (tea.PasteMsg), and every multiline input must honor the shared newline
// chord (Shift+Enter / Alt+Enter). Modal intercept blocks gate on
// tea.KeyPressMsg, which paste is not — a new modal that forgets to route
// PasteMsg silently drops pasted text into background panel routing. When
// you add an input-owning surface, add a subtest here.

func paste(content string) tea.PasteMsg {
	return tea.PasteMsg{Content: content}
}

// TestModalPasteContract verifies that bracketed paste reaches the focused
// text input of every root-level modal, including multi-line content for
// textareas, and that the modal stays open.
func TestModalPasteContract(t *testing.T) {
	t.Run("spec confirm modal textarea", func(t *testing.T) {
		nm, _ := updateModel(t, specConfirmModel(), paste("hello\nworld"))
		if got := nm.sessionConfirmInput.Value(); got != "hello\nworld" {
			t.Errorf("expected pasted text in textarea, got %q", got)
		}
		if !nm.sessionConfirmActive {
			t.Error("modal should stay open on paste")
		}
	})

	t.Run("AI modal textarea", func(t *testing.T) {
		m := minimalModel(stateWork, nil, nil)
		m.width, m.height = 100, 40
		ta := newModalTextarea()
		ta.Focus()
		m.aiInput = ta
		m.aiInputActive = true

		nm, _ := updateModel(t, m, paste("create three items\nwith details"))
		if got := nm.aiInput.Value(); got != "create three items\nwith details" {
			t.Errorf("expected pasted text in textarea, got %q", got)
		}
		if !nm.aiInputActive {
			t.Error("modal should stay open on paste")
		}
	})

	t.Run("assign modal textinput", func(t *testing.T) {
		m := minimalModel(stateWork, nil, nil)
		m.width, m.height = 100, 40
		ti := textinput.New()
		ti.Focus()
		m.assignInput = ti
		m.assignActive = true
		m.assignErr = "stale error"
		m.assignLabelIdx = 2

		nm, _ := updateModel(t, m, paste("coordination"))
		if got := nm.assignInput.Value(); got != "coordination" {
			t.Errorf("expected pasted text in input, got %q", got)
		}
		if !nm.assignActive {
			t.Error("modal should stay open on paste")
		}
		if nm.assignErr != "" {
			t.Error("paste should clear the error line like typed input does")
		}
		if nm.assignLabelIdx != -1 {
			t.Error("paste should reset the label-cycle cursor like typed input does")
		}
	})

	t.Run("assign modal paste clears near-match confirm", func(t *testing.T) {
		m := minimalModel(stateWork, nil, nil)
		m.width, m.height = 100, 40
		ti := textinput.New()
		ti.Focus()
		m.assignInput = ti
		m.assignActive = true
		m.assignNearMatch = "coordination"

		nm, _ := updateModel(t, m, paste("x"))
		if nm.assignNearMatch != "" {
			t.Error("paste should return from near-match confirm to editing")
		}
	})

	t.Run("popup search textinput", func(t *testing.T) {
		m := minimalModel(stateWork, nil, nil)
		m.width, m.height = 100, 40
		m.popup = search.New(nil, "Search Work Items")
		m.popupActive = true

		nm, _ := updateModel(t, m, paste("routing tranche"))
		if got := nm.popup.InputValue(); got != "routing tranche" {
			t.Errorf("expected pasted text in popup input, got %q", got)
		}
		if !nm.popupActive {
			t.Error("popup should stay open on paste")
		}
		if nm.popupLastQuery != "routing tranche" {
			t.Errorf("paste should drive the debounced search pipeline, lastQuery=%q", nm.popupLastQuery)
		}
	})
}

// TestModalPasteAppendsAtCursor guards paste composing with typed input
// rather than replacing it.
func TestModalPasteAppendsAtCursor(t *testing.T) {
	m := specConfirmModel()
	for _, c := range "ab" {
		m, _ = updateModel(t, m, press(c))
	}
	m, _ = updateModel(t, m, paste("PASTED"))
	if got := m.sessionConfirmInput.Value(); got != "abPASTED" {
		t.Errorf("expected paste at cursor after typed text, got %q", got)
	}
}

// TestNewlineChordContract verifies both chords (Shift+Enter and the
// Alt+Enter fallback) insert a newline in every multiline modal input, and
// that multi-line drafts survive chord + paste interleaving.
func TestNewlineChordContract(t *testing.T) {
	chords := map[string]tea.KeyPressMsg{
		"shift+enter": press(tea.KeyEnter, tea.ModShift),
		"alt+enter":   press(tea.KeyEnter, tea.ModAlt),
	}
	for name, chord := range chords {
		t.Run("spec confirm "+name, func(t *testing.T) {
			nm, _ := updateModel(t, specConfirmModel(), chord)
			if got := nm.sessionConfirmInput.Value(); got != "\n" {
				t.Errorf("expected newline, got %q", got)
			}
			if !nm.sessionConfirmActive {
				t.Error("modal should stay open on newline chord")
			}
		})
	}

	t.Run("chord and paste interleave", func(t *testing.T) {
		m := specConfirmModel()
		m, _ = updateModel(t, m, paste("line one"))
		m, _ = updateModel(t, m, press(tea.KeyEnter, tea.ModShift))
		m, _ = updateModel(t, m, paste("line two"))
		if got := m.sessionConfirmInput.Value(); !strings.Contains(got, "line one\nline two") {
			t.Errorf("expected interleaved multi-line draft, got %q", got)
		}
	})
}
