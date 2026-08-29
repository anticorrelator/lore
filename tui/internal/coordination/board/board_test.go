package board

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDecodeRowsFiltersArcAndPreservesProjectionOrder(t *testing.T) {
	raw := `{
  "coordination_streams": [
    {"arc":"other","stream_id":"x","step":"Other","depends_on":[],"tree":"writer","gate":"notify","status":"done","verdict":"full"},
    {"arc":"wanted","stream_id":"b","step":"Second declaration","depends_on":["a"],"tree":"read-only","gate":"flag","status":"pending","verdict":"—"},
    {"arc":"wanted","stream_id":"a","step":"Third declaration","depends_on":[],"tree":"writer","gate":"notify","status":"done","verdict":"full"}
  ]
}`
	rows, err := decodeRows(strings.NewReader(raw), "wanted")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 || rows[0].StreamID != "b" || rows[1].StreamID != "a" {
		t.Fatalf("projection order changed: %+v", rows)
	}
	if rows[0].Label != "Second declaration" || rows[0].Gate != "flag" || rows[0].Verdict != "—" {
		t.Errorf("authored board cells were not decoded: %+v", rows[0])
	}
}

func TestDecodeRowsRequiresCompleteStreamProjection(t *testing.T) {
	if _, err := decodeRows(strings.NewReader(`{"buckets":{}}`), "arc"); err == nil || !strings.Contains(err.Error(), "missing coordination_streams") {
		t.Fatalf("missing full projection should be explicit, got %v", err)
	}
}

func TestDecodeRowsRejectsMalformedJSON(t *testing.T) {
	if _, err := decodeRows(strings.NewReader(`{"coordination_streams":`), "arc"); err == nil {
		t.Fatal("malformed status JSON must return an error")
	}
}

func TestLoadRunsTheStatusJoin(t *testing.T) {
	dir := t.TempDir()
	command := filepath.Join(dir, "lore")
	script := `#!/bin/sh
if [ "$*" != "coordinate status --json" ]; then
  echo "unexpected arguments: $*" >&2
  exit 9
fi
printf '%s\n' '{"coordination_streams":[{"arc":"wanted","stream_id":"s1","step":"Joined","depends_on":[],"tree":"writer","gate":"notify","status":"done","verdict":"full"}]}'
`
	if err := os.WriteFile(command, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	rows, err := Load(context.Background(), "wanted")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].StreamID != "s1" || rows[0].Label != "Joined" {
		t.Fatalf("Load returned %+v", rows)
	}
}
