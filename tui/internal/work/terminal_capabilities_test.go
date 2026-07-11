package work

import (
	"bytes"
	"image/color"
	"strings"
	"testing"
)

func TestDefaultColorQueryRecognizerChunkSplits(t *testing.T) {
	fixtures := []struct {
		sequence string
		query    defaultColorQuery
	}{
		{"\x1b]10;?\a", foregroundColorQuery},
		{"\x1b]11;?\a", backgroundColorQuery},
		{"\x1b]10;?\x1b\\", foregroundColorQuery},
		{"\x1b]11;?\x1b\\", backgroundColorQuery},
	}
	for _, fixture := range fixtures {
		for split := 0; split <= len(fixture.sequence); split++ {
			var recognizer defaultColorQueryRecognizer
			var got []defaultColorQuery
			got = append(got, recognizer.observe([]byte(fixture.sequence[:split]))...)
			got = append(got, recognizer.observe([]byte(fixture.sequence[split:]))...)
			if len(got) != 1 || got[0] != fixture.query {
				t.Fatalf("sequence %q split %d: queries = %v, want [%d]", fixture.sequence, split, got, fixture.query)
			}
		}
	}
}

func TestDefaultColorQueryRecognizerBoundsArbitraryOSC(t *testing.T) {
	var recognizer defaultColorQueryRecognizer
	input := "\x1b]" + strings.Repeat("x", 1<<20)
	for start := 0; start < len(input); start += 97 {
		end := start + 97
		if end > len(input) {
			end = len(input)
		}
		if got := recognizer.observe([]byte(input[start:end])); len(got) != 0 {
			t.Fatalf("oversized OSC produced queries: %v", got)
		}
		if recognizer.length > maxOSCQueryPayload {
			t.Fatalf("recognizer retained %d bytes, max %d", recognizer.length, maxOSCQueryPayload)
		}
	}
	if got := recognizer.observe([]byte("\a\x1b]10;?\a")); len(got) != 1 || got[0] != foregroundColorQuery {
		t.Fatalf("recognizer did not recover after oversized OSC: %v", got)
	}
}

func TestTerminalBackendDefaultColorRepliesAndPreservesInput(t *testing.T) {
	pair, ok := NewTerminalColorPair(
		color.RGBA{R: 0x12, G: 0x34, B: 0x56, A: 0xff},
		color.RGBA{R: 0x21, G: 0x43, B: 0x65, A: 0xff},
	)
	if !ok {
		t.Fatal("complete palette rejected")
	}

	b := newTerminalBackend(40, 2)
	defer b.close()
	var replies bytes.Buffer
	b.setPtyWriter(&replies)
	b.setColorPair(pair)

	chunks := [][]byte{
		[]byte("before\x1b]10;"),
		[]byte("?\x1b\\\x1b]11;?"),
		[]byte("\a\x1b[48;2;33;67;101mafter\x1b[0m"),
	}
	for _, chunk := range chunks {
		b.write(chunk)
	}

	wantReplies := "\x1b]10;rgb:1212/3434/5656\x1b\\" +
		"\x1b]11;rgb:2121/4343/6565\x1b\\"
	if got := replies.String(); got != wantReplies {
		t.Fatalf("replies = %q, want %q", got, wantReplies)
	}
	rendered := b.renderScreen()
	if !strings.Contains(rendered, "before") || !strings.Contains(rendered, "after") {
		t.Fatalf("original stream did not reach libghostty: %q", rendered)
	}
	if !strings.Contains(rendered, "48;2;33;67;101m") {
		t.Fatalf("composer background SGR missing from rendered fixture: %q", rendered)
	}
}

func TestTerminalBackendUnknownPaletteSendsNoReply(t *testing.T) {
	b := newTerminalBackend(20, 2)
	defer b.close()
	var replies bytes.Buffer
	b.setPtyWriter(&replies)
	b.write([]byte("\x1b]10;?\a\x1b]11;?\x1b\\"))
	if replies.Len() != 0 {
		t.Fatalf("unknown palette produced fabricated replies: %q", replies.String())
	}
	if _, ok := NewTerminalColorPair(color.Black, nil); ok {
		t.Fatal("partial palette was accepted")
	}
}
