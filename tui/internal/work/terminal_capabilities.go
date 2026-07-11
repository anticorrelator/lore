package work

import (
	"fmt"
	"image/color"
)

const maxOSCQueryPayload = 64

type terminalRGB struct {
	r uint16
	g uint16
	b uint16
}

// TerminalColorPair is the operator terminal's reported default foreground and
// background. A pair is constructed only when both colors are available.
type TerminalColorPair struct {
	foreground terminalRGB
	background terminalRGB
}

// NewTerminalColorPair converts the terminal's reported colors into the
// 16-bit components used by OSC default-color replies.
func NewTerminalColorPair(foreground, background color.Color) (TerminalColorPair, bool) {
	if foreground == nil || background == nil {
		return TerminalColorPair{}, false
	}
	return TerminalColorPair{
		foreground: terminalRGBFromColor(foreground),
		background: terminalRGBFromColor(background),
	}, true
}

func terminalRGBFromColor(c color.Color) terminalRGB {
	r, g, b, _ := c.RGBA()
	return terminalRGB{r: uint16(r), g: uint16(g), b: uint16(b)}
}

type defaultColorQuery uint8

const (
	foregroundColorQuery defaultColorQuery = 10
	backgroundColorQuery defaultColorQuery = 11
)

func (p TerminalColorPair) reply(query defaultColorQuery) []byte {
	c := p.foreground
	if query == backgroundColorQuery {
		c = p.background
	}
	return []byte(fmt.Sprintf("\x1b]%d;rgb:%04x/%04x/%04x\x1b\\", query, c.r, c.g, c.b))
}

type oscRecognizerState uint8

const (
	oscGround oscRecognizerState = iota
	oscEscape
	oscPayload
	oscPayloadEscape
	oscDiscard
	oscDiscardEscape
)

// defaultColorQueryRecognizer observes OSC 10/11 queries without consuming
// the PTY stream. Oversized OSC payloads are discarded until their terminator.
type defaultColorQueryRecognizer struct {
	state   oscRecognizerState
	payload [maxOSCQueryPayload]byte
	length  int
}

func (r *defaultColorQueryRecognizer) observe(data []byte) []defaultColorQuery {
	var queries []defaultColorQuery
	for _, b := range data {
		switch r.state {
		case oscGround:
			if b == '\x1b' {
				r.state = oscEscape
			}
		case oscEscape:
			if b == ']' {
				r.length = 0
				r.state = oscPayload
			} else if b != '\x1b' {
				r.state = oscGround
			}
		case oscPayload:
			switch b {
			case '\a':
				if query, ok := r.query(); ok {
					queries = append(queries, query)
				}
				r.reset()
			case '\x1b':
				r.state = oscPayloadEscape
			default:
				r.append(b)
			}
		case oscPayloadEscape:
			if b == '\\' {
				if query, ok := r.query(); ok {
					queries = append(queries, query)
				}
				r.reset()
				continue
			}
			r.append('\x1b')
			if r.state == oscDiscard {
				if b == '\x1b' {
					r.state = oscDiscardEscape
				}
				continue
			}
			r.append(b)
		case oscDiscard:
			if b == '\a' {
				r.reset()
			} else if b == '\x1b' {
				r.state = oscDiscardEscape
			}
		case oscDiscardEscape:
			if b == '\\' {
				r.reset()
			} else if b != '\x1b' {
				r.state = oscDiscard
			}
		}
	}
	return queries
}

func (r *defaultColorQueryRecognizer) append(b byte) {
	if r.length == len(r.payload) {
		r.state = oscDiscard
		return
	}
	r.payload[r.length] = b
	r.length++
	r.state = oscPayload
}

func (r *defaultColorQueryRecognizer) query() (defaultColorQuery, bool) {
	switch string(r.payload[:r.length]) {
	case "10;?":
		return foregroundColorQuery, true
	case "11;?":
		return backgroundColorQuery, true
	default:
		return 0, false
	}
}

func (r *defaultColorQueryRecognizer) reset() {
	r.state = oscGround
	r.length = 0
}
