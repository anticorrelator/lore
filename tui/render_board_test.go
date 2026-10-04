package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anticorrelator/lore/tui/internal/coordination/board"
)

const renderBoardProjection = `{
  "coordination_arcs": [{"arc":"wanted","status":"active"},{"arc":"empty","status":"active"}],
  "coordination_streams": [
    {"arc":"wanted","arc_status":"active","stream_id":"s2","step":"Build on the spec","depends_on":["s1"],"tree":"writer","gate":"hold","status":"pending","verdict":"—"},
    {"arc":"wanted","arc_status":"active","stream_id":"s1","step":"Write the spec","depends_on":[],"tree":"writer","gate":"flag","status":"done","verdict":"full"},
    {"arc":"wanted","arc_status":"active","stream_id":"s3","step":"Ask the owner","depends_on":[],"tree":"writer","gate":"notify","status":"blocked-on-input","verdict":"—"}
  ]
}`

func fakeCoordinateRead(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	payload := filepath.Join(dir, "projection.json")
	if err := os.WriteFile(payload, []byte(renderBoardProjection), 0o644); err != nil {
		t.Fatal(err)
	}
	script := `#!/bin/sh
if [ "$*" != "coordinate read --refresh --json" ]; then
  echo "unexpected arguments: $*" >&2
  exit 9
fi
cat "` + payload + `"
`
	if err := os.WriteFile(filepath.Join(dir, "lore"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func runRenderBoard(t *testing.T, args ...string) (int, string, string) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	code := renderBoardMain(args, &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

func TestRenderBoardTextPrintsTheRenderedRails(t *testing.T) {
	fakeCoordinateRead(t)
	code, stdout, stderr := runRenderBoard(t, "--arc", "wanted", "--width", "80")
	if code != 0 {
		t.Fatalf("exit %d, stderr %q", code, stderr)
	}
	lines := strings.Split(strings.TrimSuffix(stdout, "\n"), "\n")
	if len(lines) != 3 {
		t.Fatalf("want one line per stream, got %d:\n%s", len(lines), stdout)
	}
	wants := []struct{ id, words string }{
		{"s1", "done"},
		{"s2", "queued · held for you"},
		{"s3", "waiting on you"},
	}
	for i, want := range wants {
		if !strings.Contains(lines[i], " "+want.id+" ") || !strings.HasSuffix(lines[i], "  "+want.words) {
			t.Errorf("line %d = %q, want stream %s ending in %q", i, lines[i], want.id, want.words)
		}
	}
}

func TestRenderBoardJSONCarriesStreamIdentityAndMetadataOffset(t *testing.T) {
	fakeCoordinateRead(t)
	code, stdout, stderr := runRenderBoard(t, "--arc", "wanted", "--width", "80", "--json")
	if code != 0 {
		t.Fatalf("exit %d, stderr %q", code, stderr)
	}
	var got struct {
		Arc   string `json:"arc"`
		Width int    `json:"width"`
		Rows  []struct {
			StreamID string `json:"stream_id"`
			Lines    []struct {
				Text       string `json:"text"`
				MetadataAt int    `json:"metadata_at"`
			} `json:"lines"`
		} `json:"rows"`
	}
	if err := json.Unmarshal([]byte(stdout), &got); err != nil {
		t.Fatalf("output is not JSON: %v\n%s", err, stdout)
	}
	if got.Arc != "wanted" || got.Width != 80 || len(got.Rows) != 3 {
		t.Fatalf("envelope = %+v", got)
	}
	wantIDs := []string{"s1", "s2", "s3"}
	wantWords := []string{"done", "queued · held for you", "waiting on you"}
	for i, row := range got.Rows {
		if row.StreamID != wantIDs[i] || len(row.Lines) != 1 {
			t.Fatalf("row %d = %+v, want stream %s with one line", i, row, wantIDs[i])
		}
		line := row.Lines[0]
		if line.MetadataAt < 0 || line.Text[line.MetadataAt:] != wantWords[i] {
			t.Errorf("row %s metadata = %q at %d, want %q", row.StreamID, line.Text, line.MetadataAt, wantWords[i])
		}
	}
}

func TestRenderBoardEmptyArcPrintsNoRows(t *testing.T) {
	fakeCoordinateRead(t)
	code, stdout, stderr := runRenderBoard(t, "--arc", "empty", "--width", "80", "--json")
	if code != 0 || strings.TrimSpace(stdout) != `{"arc":"empty","width":80,"rows":[]}` {
		t.Fatalf("exit %d, stdout %q, stderr %q", code, stdout, stderr)
	}
}

func TestRenderBoardRefusesUnknownArc(t *testing.T) {
	fakeCoordinateRead(t)
	code, stdout, stderr := runRenderBoard(t, "--arc", "missing", "--width", "80")
	if code != 1 || stdout != "" || !strings.Contains(stderr, `unknown arc "missing"`) {
		t.Fatalf("exit %d, stdout %q, stderr %q", code, stdout, stderr)
	}
}

func TestRenderBoardUsage(t *testing.T) {
	code, stdout, _ := runRenderBoard(t, "--help")
	if code != 0 || !strings.HasPrefix(stdout, "Usage: lore coordinate board --arc <slug> --width <n> [--json]") {
		t.Fatalf("--help exit %d:\n%s", code, stdout)
	}
	for _, args := range [][]string{
		{"--width", "80"},
		{"--arc", "wanted"},
		{"--arc", "wanted", "--width", "0"},
		{"--arc", "wanted", "--width", "80", "extra"},
		{"--bogus"},
	} {
		code, stdout, stderr := runRenderBoard(t, args...)
		if code != 2 || stdout != "" || !strings.Contains(stderr, "Usage: lore coordinate board") {
			t.Errorf("%q: exit %d, stdout %q, stderr %q", args, code, stdout, stderr)
		}
	}
}

func TestRenderBoardMatchesTheViewRenderer(t *testing.T) {
	fakeCoordinateRead(t)
	_, stdout, _ := runRenderBoard(t, "--arc", "wanted", "--width", "57")
	var rows []board.Row
	var projection struct {
		Streams []board.Row `json:"coordination_streams"`
	}
	if err := json.Unmarshal([]byte(renderBoardProjection), &projection); err != nil {
		t.Fatal(err)
	}
	for _, row := range projection.Streams {
		if row.Arc == "wanted" {
			rows = append(rows, row)
		}
	}
	if want := strings.Join(board.Render(rows, 57), "\n") + "\n"; stdout != want {
		t.Fatalf("verb output drifted from board.Render:\n--- got ---\n%s--- want ---\n%s", stdout, want)
	}
}
