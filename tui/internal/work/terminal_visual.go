package work

import (
	"image/color"

	libghostty "go.mitchellh.com/libghostty"
)

// TerminalCursorShape is the cursor shape exposed by the embedded terminal.
type TerminalCursorShape uint8

const (
	TerminalCursorBlock TerminalCursorShape = iota
	TerminalCursorUnderline
	TerminalCursorBar
)

// TerminalCursor describes the viewport-relative cursor for a rendered frame.
type TerminalCursor struct {
	X, Y  int
	Shape TerminalCursorShape
	Blink bool
	Color *color.RGBA
}

// TerminalVisual contains presentation metadata synchronized with styled rows.
type TerminalVisual struct {
	Cursor *TerminalCursor
}

func (b *terminalBackend) readTerminalVisual() TerminalVisual {
	visible, err := b.rs.CursorVisible()
	if err != nil || !visible {
		return TerminalVisual{}
	}
	hasPosition, err := b.rs.CursorViewportHasValue()
	if err != nil || !hasPosition {
		return TerminalVisual{}
	}
	x, err := b.rs.CursorViewportX()
	if err != nil {
		return TerminalVisual{}
	}
	y, err := b.rs.CursorViewportY()
	if err != nil {
		return TerminalVisual{}
	}
	ghosttyShape, err := b.rs.CursorVisualStyle()
	if err != nil {
		return TerminalVisual{}
	}
	blink, err := b.rs.CursorBlinking()
	if err != nil {
		return TerminalVisual{}
	}

	shape := TerminalCursorBlock
	switch ghosttyShape {
	case libghostty.CursorVisualStyleUnderline:
		shape = TerminalCursorUnderline
	case libghostty.CursorVisualStyleBar:
		shape = TerminalCursorBar
	case libghostty.CursorVisualStyleBlock, libghostty.CursorVisualStyleBlockHollow:
		shape = TerminalCursorBlock
	}

	var cursorColor *color.RGBA
	if colors, err := b.rs.Colors(); err == nil && colors.CursorHasValue {
		cursorColor = &color.RGBA{
			R: colors.Cursor.R,
			G: colors.Cursor.G,
			B: colors.Cursor.B,
			A: 0xff,
		}
	}

	return TerminalVisual{Cursor: &TerminalCursor{
		X:     int(x),
		Y:     int(y),
		Shape: shape,
		Blink: blink,
		Color: cursorColor,
	}}
}

// TerminalVisual returns presentation metadata only while the live styled
// frame is visible. Readiness and peek continue to use ScreenState.
func (m SessionPanelModel) TerminalVisual() TerminalVisual {
	if m.backend == nil || !m.open || m.done || m.scrollOffset > 0 || m.cachedRender == "" {
		return TerminalVisual{}
	}
	return m.backend.visual
}
