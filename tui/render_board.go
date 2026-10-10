package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"time"

	"github.com/anticorrelator/lore/tui/internal/coordination/board"
)

// renderBoardFlag is a variable, not a constant, so its bytes stay in the
// binary: the compiler turns a comparison against a short constant string into
// integer compares, leaving nothing to find. cli/lore looks for these bytes in
// the installed lore-tui before running it, because an older binary ignores the
// flag and opens the full-screen TUI.
var renderBoardFlag = "--render-board"

const renderBoardUsage = `Usage: lore coordinate board --arc <slug> --width <n> [--json]

Print one arc's stream board as the coordination view draws it: one line per
stream, rails and status words included. Reads the active-arc snapshot from
'lore coordinate read --refresh --json'.

Options:
  --arc <slug>   The arc to render (required)
  --width <n>    Line width in display cells, at least 1 (required)
  --json         Emit {arc, width, rows:[{stream_id, lines:[{text, metadata_at}]}]}
                 metadata_at is the byte offset into the UTF-8 text where the
                 status words begin, or -1 when the line has none
  --help, -h     Show this help

Exit status: 0 rendered, 1 unknown arc or unreadable snapshot, 2 usage error,
3 the installed lore-tui is missing or older than this command (run lore rebuild).
`

type renderedBoard struct {
	Arc   string             `json:"arc"`
	Width int                `json:"width"`
	Rows  []renderedBoardRow `json:"rows"`
}

type renderedBoardRow struct {
	StreamID string              `json:"stream_id"`
	Lines    []renderedBoardLine `json:"lines"`
}

type renderedBoardLine struct {
	Text       string `json:"text"`
	MetadataAt int    `json:"metadata_at"`
}

func renderBoardMain(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("lore coordinate board", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	arc := fs.String("arc", "", "")
	width := fs.Int("width", 0, "")
	asJSON := fs.Bool("json", false, "")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			fmt.Fprint(stdout, renderBoardUsage)
			return 0
		}
		fmt.Fprintf(stderr, "lore coordinate board: %v\n\n%s", err, renderBoardUsage)
		return 2
	}
	switch {
	case fs.NArg() != 0:
		fmt.Fprintf(stderr, "lore coordinate board: unexpected argument %q\n\n%s", fs.Arg(0), renderBoardUsage)
		return 2
	case *arc == "":
		fmt.Fprintf(stderr, "lore coordinate board: --arc is required\n\n%s", renderBoardUsage)
		return 2
	case *width < 1:
		fmt.Fprintf(stderr, "lore coordinate board: --width must be at least 1\n\n%s", renderBoardUsage)
		return 2
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	rows, found, err := board.Load(ctx, *arc)
	if err != nil {
		fmt.Fprintf(stderr, "lore coordinate board: %v\n", err)
		return 1
	}
	if !found {
		fmt.Fprintf(stderr, "lore coordinate board: unknown arc %q: it is not in the coordination snapshot\n", *arc)
		return 1
	}

	rendered := board.RenderRows(rows, *width, 0)
	if !*asJSON {
		for _, row := range rendered {
			for _, line := range row.Lines {
				fmt.Fprintln(stdout, line.Text)
			}
		}
		return 0
	}
	out := renderedBoard{Arc: *arc, Width: *width, Rows: make([]renderedBoardRow, 0, len(rendered))}
	for _, row := range rendered {
		lines := make([]renderedBoardLine, 0, len(row.Lines))
		for _, line := range row.Lines {
			lines = append(lines, renderedBoardLine{Text: line.Text, MetadataAt: line.MetadataAt})
		}
		out.Rows = append(out.Rows, renderedBoardRow{StreamID: row.StreamID, Lines: lines})
	}
	encoder := json.NewEncoder(stdout)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(out); err != nil {
		fmt.Fprintf(stderr, "lore coordinate board: %v\n", err)
		return 1
	}
	return 0
}
