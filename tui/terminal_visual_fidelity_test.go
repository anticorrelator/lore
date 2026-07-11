package main

import (
	"encoding/json"
	"image/color"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/work"
)

type rootVisualFixture struct {
	BackgroundSpan [2]int   `json:"background_span"`
	BackgroundRGB  [3]uint8 `json:"background_rgb"`
	FaintSpan      [2]int   `json:"faint_span"`
	InverseCells   []int    `json:"inverse_cells"`
	Cursor         struct {
		X        int      `json:"x"`
		Y        int      `json:"y"`
		Blink    bool     `json:"blink"`
		ColorRGB [3]uint8 `json:"color_rgb"`
	} `json:"cursor"`
}

func loadRootVisualFixture(t *testing.T) (rootVisualFixture, []byte) {
	t.Helper()
	var fixture rootVisualFixture
	metadata, err := os.ReadFile(filepath.Join("internal", "work", "testdata", "terminal-visual-fidelity.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(metadata, &fixture); err != nil {
		t.Fatal(err)
	}
	encoded, err := os.ReadFile(filepath.Join("internal", "work", "testdata", "terminal-visual-fidelity.ansi"))
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := strconv.Unquote(`"` + strings.TrimSpace(string(encoded)) + `"`)
	if err != nil {
		t.Fatal(err)
	}
	return fixture, []byte(decoded)
}

type frameCellState struct {
	HasBackground bool
	Background    [3]uint8
	Faint         bool
	Inverse       bool
}

func parseFrameCells(content string) [][]frameCellState {
	rows := [][]frameCellState{{}}
	state := frameCellState{}
	for i := 0; i < len(content); {
		if content[i] == '\x1b' && i+1 < len(content) && content[i+1] == '[' {
			end := i + 2
			for end < len(content) && (content[end] < '@' || content[end] > '~') {
				end++
			}
			if end < len(content) {
				if content[end] == 'm' {
					applyFrameSGR(&state, content[i+2:end])
				}
				i = end + 1
				continue
			}
		}
		if content[i] == '\n' {
			rows = append(rows, []frameCellState{})
			i++
			continue
		}
		_, size := utf8.DecodeRuneInString(content[i:])
		rows[len(rows)-1] = append(rows[len(rows)-1], state)
		i += size
	}
	return rows
}

func applyFrameSGR(state *frameCellState, sequence string) {
	if sequence == "" {
		sequence = "0"
	}
	parts := strings.Split(sequence, ";")
	for i := 0; i < len(parts); i++ {
		code, _ := strconv.Atoi(parts[i])
		switch code {
		case 0:
			*state = frameCellState{}
		case 2:
			state.Faint = true
		case 22:
			state.Faint = false
		case 7:
			state.Inverse = true
		case 27:
			state.Inverse = false
		case 48:
			if i+4 < len(parts) && parts[i+1] == "2" {
				r, _ := strconv.Atoi(parts[i+2])
				g, _ := strconv.Atoi(parts[i+3])
				b, _ := strconv.Atoi(parts[i+4])
				state.HasBackground = true
				state.Background = [3]uint8{uint8(r), uint8(g), uint8(b)}
				i += 4
			}
		case 49:
			state.HasBackground = false
			state.Background = [3]uint8{}
		}
	}
}

func fixtureRootModel(t *testing.T, layout config.LayoutMode, stream []byte) model {
	t.Helper()
	m := workContractModel()
	m.layoutMode = layout
	m.terminalMode = true
	panel := work.NewSessionPanelModel("item-1")
	panel, _ = panel.Update(tea.WindowSizeMsg{Width: m.rightPanelWidth() - 2, Height: m.detailPanelHeight()})
	panel, _ = panel.Update(work.TerminalOutputMsg{Slug: "item-1", Data: stream})
	m.setSessionPanel("item-1", panel)
	return m
}

func assertOuterFixtureAttributes(t *testing.T, fixture rootVisualFixture, cells [][]frameCellState, originX, originY int) {
	t.Helper()
	row := originY + fixture.Cursor.Y
	if row >= len(cells) {
		t.Fatalf("outer row %d missing from %d rows", row, len(cells))
	}
	for x := fixture.BackgroundSpan[0]; x <= fixture.BackgroundSpan[1]; x++ {
		absoluteX := originX + x
		if absoluteX >= len(cells[row]) {
			t.Fatalf("outer cell (%d,%d) missing", absoluteX, row)
		}
		cell := cells[row][absoluteX]
		if !cell.HasBackground || cell.Background != fixture.BackgroundRGB {
			t.Errorf("outer cell (%d,%d) background = present:%v rgb:%v, want %v", absoluteX, row, cell.HasBackground, cell.Background, fixture.BackgroundRGB)
		}
	}
	for x := fixture.FaintSpan[0]; x <= fixture.FaintSpan[1]; x++ {
		if !cells[row][originX+x].Faint {
			t.Errorf("outer cell (%d,%d) is not faint", originX+x, row)
		}
	}
	for _, x := range fixture.InverseCells {
		if !cells[row][originX+x].Inverse {
			t.Errorf("outer cell (%d,%d) is not inverse", originX+x, row)
		}
	}
}

func TestTerminalVisualFidelityOuterComposition(t *testing.T) {
	fixture, stream := loadRootVisualFixture(t)
	for _, layout := range []config.LayoutMode{config.LayoutLeftRight, config.LayoutTopBottom} {
		t.Run(string(layout), func(t *testing.T) {
			m := fixtureRootModel(t, layout, stream)
			view := m.View()
			originX, originY := terminalViewportOrigin(layout, m)
			assertOuterFixtureAttributes(t, fixture, parseFrameCells(view.Content), originX, originY)

			if view.Cursor == nil {
				t.Fatal("frame cursor missing")
			}
			if view.Cursor.X != originX+fixture.Cursor.X || view.Cursor.Y != originY+fixture.Cursor.Y {
				t.Errorf("frame cursor = (%d,%d), want (%d,%d)", view.Cursor.X, view.Cursor.Y, originX+fixture.Cursor.X, originY+fixture.Cursor.Y)
			}
			if view.Cursor.Shape != tea.CursorBar || view.Cursor.Blink != fixture.Cursor.Blink {
				t.Errorf("frame cursor shape/blink = %v/%v, want bar/%v", view.Cursor.Shape, view.Cursor.Blink, fixture.Cursor.Blink)
			}
			gotColor := color.RGBAModel.Convert(view.Cursor.Color).(color.RGBA)
			if [3]uint8{gotColor.R, gotColor.G, gotColor.B} != fixture.Cursor.ColorRGB {
				t.Errorf("frame cursor color = %v, want %v", gotColor, fixture.Cursor.ColorRGB)
			}
			if strings.Contains(view.Content, "\x1b[?25") || strings.Contains(view.Content, "\x1b[5 q") {
				t.Error("cursor control bytes leaked into frame content")
			}
		})
	}
}

func TestTerminalCursorSuppressionAndBounds(t *testing.T) {
	_, stream := loadRootVisualFixture(t)
	m := fixtureRootModel(t, config.LayoutLeftRight, stream)

	m.showHelp = true
	if cursor := m.embeddedTerminalCursor(); cursor != nil {
		t.Errorf("replacement surface published cursor: %+v", cursor)
	}

	m = workContractModel()
	m.terminalMode = true
	m.setSessionPanel("item-1", work.NewSessionPanelModel("item-1"))
	if cursor := m.embeddedTerminalCursor(); cursor != nil {
		t.Errorf("not-yet-rendered panel published cursor: %+v", cursor)
	}

	if cursor := projectTerminalCursor(work.TerminalCursor{X: 30, Y: 2}, 0, 0, 20, 10, 120, 40); cursor != nil {
		t.Errorf("out-of-viewport cursor was not clipped: %+v", cursor)
	}
}
