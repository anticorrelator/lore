package settings

import (
	"reflect"
	"testing"
)

func assertStatusHints(t *testing.T, got []StatusHint, want ...StatusHint) {
	t.Helper()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("StatusHints() mismatch\n got: %#v\nwant: %#v", got, want)
	}
}

func TestStatusHints_TextInputModes(t *testing.T) {
	w := NewTextInput("name", "name", "old", nil, 0, true, true)
	w.Focus()

	assertStatusHints(t, w.StatusHints(),
		StatusHint{Key: "enter", Label: "edit"},
		StatusHint{Key: "u", Label: "unset"},
	)

	_, _ = dispatch(w, "enter")
	assertStatusHints(t, w.StatusHints(),
		StatusHint{Key: "enter/↕", Label: "save"},
		StatusHint{Key: "esc", Label: "revert"},
	)

	_, _ = dispatch(w, "esc")
	assertStatusHints(t, w.StatusHints(),
		StatusHint{Key: "enter", Label: "edit"},
		StatusHint{Key: "u", Label: "unset"},
	)
}

func TestStatusHints_ListEditorModes(t *testing.T) {
	w := NewListEditor("tags", "tags", []string{"alpha"}, nil, 0, true, true, true)
	w.Focus()

	assertStatusHints(t, w.StatusHints(),
		StatusHint{Key: "enter", Label: "open"},
		StatusHint{Key: "u", Label: "unset"},
	)

	_, _ = dispatch(w, "enter")
	assertStatusHints(t, w.StatusHints(),
		StatusHint{Key: "a", Label: "add"},
		StatusHint{Key: "d", Label: "delete"},
		StatusHint{Key: "↕", Label: "move"},
		StatusHint{Key: "esc", Label: "done"},
	)

	_, _ = dispatch(w, "a")
	assertStatusHints(t, w.StatusHints(),
		StatusHint{Key: "enter", Label: "confirm"},
		StatusHint{Key: "esc", Label: "cancel"},
	)

	selector := NewEnumListEditor("modes", "modes", []string{"a"}, []string{"a", "b"}, 0, true, true, true)
	selector.Focus()
	_, _ = dispatch(selector, "enter")
	assertStatusHints(t, selector.StatusHints(),
		StatusHint{Key: "space", Label: "toggle"},
		StatusHint{Key: "↕", Label: "move"},
		StatusHint{Key: "esc", Label: "done"},
	)
}

func TestStatusHints_OpenKeysetKVModes(t *testing.T) {
	w := NewOpenKeysetKVEditor("roles", "roles", map[string]string{"lead": "sonnet"}, nil, nil, true, true)
	w.Focus()

	assertStatusHints(t, w.StatusHints(),
		StatusHint{Key: "enter", Label: "open"},
		StatusHint{Key: "u", Label: "unset"},
	)

	_, _ = dispatch(w, "enter")
	assertStatusHints(t, w.StatusHints(),
		StatusHint{Key: "a", Label: "add"},
		StatusHint{Key: "e", Label: "edit"},
		StatusHint{Key: "d", Label: "delete"},
		StatusHint{Key: "↕", Label: "move"},
		StatusHint{Key: "esc", Label: "done"},
	)

	_, _ = dispatch(w, "a")
	assertStatusHints(t, w.StatusHints(),
		StatusHint{Key: "enter", Label: "next"},
		StatusHint{Key: "esc", Label: "cancel"},
	)

	for _, key := range []string{"w", "o", "r", "k", "e", "r"} {
		_, _ = dispatch(w, key)
	}
	_, _ = dispatch(w, "enter")
	assertStatusHints(t, w.StatusHints(),
		StatusHint{Key: "enter", Label: "save"},
		StatusHint{Key: "esc", Label: "cancel"},
	)

	_, _ = dispatch(w, "esc")
	_, _ = dispatch(w, "e")
	assertStatusHints(t, w.StatusHints(),
		StatusHint{Key: "enter", Label: "save"},
		StatusHint{Key: "esc", Label: "cancel"},
	)
}

func TestStatusHints_ActiveHoursRangesModes(t *testing.T) {
	w := NewActiveHoursRangesEditor("settlement.active_hours.ranges", "ranges", []ActiveHoursRange{
		{Days: []string{"mon"}, Start: "09:00", End: "17:00"},
	}, true)
	w.Focus()

	assertStatusHints(t, w.StatusHints(), StatusHint{Key: "enter", Label: "open"})

	_, _ = dispatch(w, "enter")
	assertStatusHints(t, w.StatusHints(),
		StatusHint{Key: "↕", Label: "field"},
		StatusHint{Key: "h/l", Label: "field"},
		StatusHint{Key: "+/-", Label: "time"},
		StatusHint{Key: "1-7", Label: "days"},
		StatusHint{Key: "a", Label: "add"},
		StatusHint{Key: "d", Label: "delete"},
		StatusHint{Key: "esc", Label: "done"},
	)
}

func TestStatusHints_ContainerDelegationAndEscBack(t *testing.T) {
	togglePanel := NewClosedObjectSubPanel("panel", "panel", []FieldWidget{
		NewToggleRow("panel.enabled", "enabled", true, true, false),
	})
	togglePanel.Focus()

	assertStatusHints(t, togglePanel.StatusHints(), StatusHint{Key: "enter", Label: "open"})

	_, _ = dispatch(togglePanel, "enter")
	assertStatusHints(t, togglePanel.StatusHints(),
		StatusHint{Key: "space", Label: "toggle"},
		StatusHint{Key: "esc", Label: "back"},
	)

	textPanel := NewClosedObjectSubPanel("panel", "panel", []FieldWidget{
		NewTextInput("panel.name", "name", "old", nil, 0, true, false),
	})
	textPanel.Focus()
	_, _ = dispatch(textPanel, "enter")
	_, _ = dispatch(textPanel, "enter")
	assertStatusHints(t, textPanel.StatusHints(),
		StatusHint{Key: "enter/↕", Label: "save"},
		StatusHint{Key: "esc", Label: "revert"},
	)
}

func TestSettingsModelStatusHints_Suffixes(t *testing.T) {
	m, _, _ := newTestModel(t, nil)
	assertStatusHints(t, m.StatusHints(),
		StatusHint{Key: "j/k", Label: "move"},
		StatusHint{Key: "enter", Label: "open"},
		StatusHint{Key: "esc", Label: "close"},
	)

	m.lastWrite.armed = true
	assertStatusHints(t, m.StatusHints(),
		StatusHint{Key: "j/k", Label: "move"},
		StatusHint{Key: "enter", Label: "open"},
		StatusHint{Key: "U", Label: "undo"},
		StatusHint{Key: "esc", Label: "close"},
	)

	m.FocusDotPath("name")
	assertStatusHints(t, m.StatusHints(),
		StatusHint{Key: "j/k", Label: "move"},
		StatusHint{Key: "enter", Label: "edit"},
		StatusHint{Key: "U", Label: "undo"},
		StatusHint{Key: "esc", Label: "close"},
	)

	_, _ = m.Update(keyMsg("enter"))
	assertStatusHints(t, m.StatusHints(),
		StatusHint{Key: "enter/↕", Label: "save"},
		StatusHint{Key: "esc", Label: "revert"},
	)
}

func TestSettingsModelStatusHints_EscCloseOnlyAtTopLevel(t *testing.T) {
	m, _, _ := newTestModel(t, nil)
	m.FocusDotPath("name")
	if !hasStatusHintKey(m.StatusHints(), "esc") {
		t.Fatalf("focused top-level scalar should advertise esc close: %#v", m.StatusHints())
	}

	m.FocusDotPath("closed_obj")
	_, _ = m.Update(keyMsg("enter"))
	// j/k still moves rows inside the entered container, so the baseline
	// nav hint stays; esc reads "back" (one level), never "close".
	assertStatusHints(t, m.StatusHints(),
		StatusHint{Key: "j/k", Label: "move"},
		StatusHint{Key: "enter", Label: "edit"},
		StatusHint{Key: "esc", Label: "back"},
	)
}
