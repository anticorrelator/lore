package style

import (
	"image/color"
	"testing"

	"charm.land/lipgloss/v2"
)

// Assertions here compare color values via lipgloss getters rather than
// matching substrings of rendered output: lipgloss v2 always emits ANSI
// from Style.Render (profile degradation happens in the program writer),
// so rendered-substring assertions are SGR-fragile by construction.

func TestPaletteRoleIndices(t *testing.T) {
	cases := []struct {
		name string
		got  color.Color
		idx  string
	}{
		{"ColorAccent", ColorAccent, "4"},
		{"ColorChrome", ColorChrome, "238"},
		{"ColorDim", ColorDim, "8"},
		{"ColorText", ColorText, "7"},
		{"ColorTextBright", ColorTextBright, "252"},
		{"ColorOnAccent", ColorOnAccent, "0"},
		{"ColorSelectionBg", ColorSelectionBg, "237"},
		{"ColorMetaKey", ColorMetaKey, "6"},
		{"ColorCategory", ColorCategory, "5"},
		{"ColorSuccess", ColorSuccess, "2"},
		{"ColorWarn", ColorWarn, "3"},
		{"ColorDanger", ColorDanger, "1"},
		{"ColorAttention", ColorAttention, "214"},
		{"ColorMerged", ColorMerged, "5"},
		{"ColorCode", ColorCode, "11"},
	}
	for _, c := range cases {
		if c.got != lipgloss.Color(c.idx) {
			t.Errorf("%s = %v, want color index %s", c.name, c.got, c.idx)
		}
	}
}

func TestDockBorderIsRounded(t *testing.T) {
	if DockBorder != lipgloss.RoundedBorder() {
		t.Errorf("DockBorder = %+v, want lipgloss.RoundedBorder()", DockBorder)
	}
}

func TestBorderVariantsShareShapeAndDifferByColor(t *testing.T) {
	if got := BorderFocused.GetBorderStyle(); got != DockBorder {
		t.Errorf("BorderFocused border style = %+v, want DockBorder", got)
	}
	if got := BorderBlur.GetBorderStyle(); got != DockBorder {
		t.Errorf("BorderBlur border style = %+v, want DockBorder", got)
	}
	focusSides := []struct {
		side string
		got  color.Color
	}{
		{"top", BorderFocused.GetBorderTopForeground()},
		{"right", BorderFocused.GetBorderRightForeground()},
		{"bottom", BorderFocused.GetBorderBottomForeground()},
		{"left", BorderFocused.GetBorderLeftForeground()},
	}
	for _, s := range focusSides {
		if s.got != ColorAccent {
			t.Errorf("BorderFocused %s foreground = %v, want ColorAccent", s.side, s.got)
		}
	}
	blurSides := []struct {
		side string
		got  color.Color
	}{
		{"top", BorderBlur.GetBorderTopForeground()},
		{"right", BorderBlur.GetBorderRightForeground()},
		{"bottom", BorderBlur.GetBorderBottomForeground()},
		{"left", BorderBlur.GetBorderLeftForeground()},
	}
	for _, s := range blurSides {
		if s.got != ColorChrome {
			t.Errorf("BorderBlur %s foreground = %v, want ColorChrome", s.side, s.got)
		}
	}
}

func TestTitleParts(t *testing.T) {
	if got := TitleName.GetForeground(); got != ColorText {
		t.Errorf("TitleName foreground = %v, want ColorText", got)
	}
	if !TitleName.GetBold() {
		t.Error("TitleName should be bold")
	}
	if got := TitleCount.GetForeground(); got != ColorChrome {
		t.Errorf("TitleCount foreground = %v, want ColorChrome", got)
	}
	if got := TitleFilter.GetForeground(); got != ColorAccent {
		t.Errorf("TitleFilter foreground = %v, want ColorAccent", got)
	}
}

func TestStatusRamp(t *testing.T) {
	cases := []struct {
		name string
		s    lipgloss.Style
		fg   color.Color
	}{
		{"StatusReady", StatusReady, ColorSuccess},
		{"StatusActive", StatusActive, ColorAccent},
		{"StatusWarn", StatusWarn, ColorWarn},
		{"StatusError", StatusError, ColorDanger},
		{"StatusDone", StatusDone, ColorDim},
		{"StatusDisabled", StatusDisabled, ColorDim},
	}
	for _, c := range cases {
		if got := c.s.GetForeground(); got != c.fg {
			t.Errorf("%s foreground = %v, want %v", c.name, got, c.fg)
		}
	}
}

// StatusDisabled must read differently from StatusDone even though both are
// dim: disabled is italic, done is upright.
func TestStatusDisabledDistinctFromDone(t *testing.T) {
	if !StatusDisabled.GetItalic() {
		t.Error("StatusDisabled should be italic")
	}
	if StatusDone.GetItalic() {
		t.Error("StatusDone should not be italic")
	}
}

func TestSpacingValues(t *testing.T) {
	if PadTabH != 1 {
		t.Errorf("PadTabH = %d, want 1", PadTabH)
	}
	if GutterH != 1 {
		t.Errorf("GutterH = %d, want 1", GutterH)
	}
	if RowLead != 1 {
		t.Errorf("RowLead = %d, want 1", RowLead)
	}
}

// Baseline exports predate this token vocabulary; downstream phases assume
// their values are unchanged.
func TestBaselineExportsUnchanged(t *testing.T) {
	if got := ActiveTab.GetForeground(); got != lipgloss.Color("0") {
		t.Errorf("ActiveTab foreground = %v, want 0", got)
	}
	if got := ActiveTab.GetBackground(); got != lipgloss.Color("4") {
		t.Errorf("ActiveTab background = %v, want 4", got)
	}
	if got := InactiveTab.GetBackground(); got != lipgloss.Color("238") {
		t.Errorf("InactiveTab background = %v, want 238", got)
	}
	if got := KeyHint.GetForeground(); got != lipgloss.Color("7") {
		t.Errorf("KeyHint foreground = %v, want 7", got)
	}
	if got := Separator.GetForeground(); got != lipgloss.Color("238") {
		t.Errorf("Separator foreground = %v, want 238", got)
	}
	if got := Dim.GetForeground(); got != lipgloss.Color("8") {
		t.Errorf("Dim foreground = %v, want 8", got)
	}
	if got := SevBlocking.GetForeground(); got != lipgloss.Color("1") {
		t.Errorf("SevBlocking foreground = %v, want 1", got)
	}
	if got := SevSuggestion.GetForeground(); got != lipgloss.Color("3") {
		t.Errorf("SevSuggestion foreground = %v, want 3", got)
	}
	if got := SevQuestion.GetForeground(); got != lipgloss.Color("8") {
		t.Errorf("SevQuestion foreground = %v, want 8", got)
	}
}
