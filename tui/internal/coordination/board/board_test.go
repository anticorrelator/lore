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

  "coordination_arcs": [
    {"arc":"other","status":"closed"},
    {"arc":"wanted","status":"active"}
  ],
  "coordination_streams": [
    {"arc":"other","arc_status":"closed","stream_id":"x","step":"Other","depends_on":[],"tree":"writer","gate":"notify","status":"done","verdict":"full"},
    {"arc":"wanted","arc_status":"active","stream_id":"b","step":"Second declaration","depends_on":["a"],"tree":"read-only","gate":"flag","status":"pending","verdict":"—","work_item":"item-b","review_packet":"packets/b.md"},
    {"arc":"wanted","arc_status":"active","stream_id":"a","step":"Third declaration","depends_on":[],"tree":"writer","gate":"notify","status":"done","verdict":"full","work_item":null,"review_packet":null}
  ]
}`
	rows, found, err := decodeRows(strings.NewReader(raw), "wanted")
	if err != nil {
		t.Fatal(err)
	}
	if !found {
		t.Fatal("wanted arc should be present in coordination_arcs")
	}
	if len(rows) != 2 || rows[0].StreamID != "b" || rows[1].StreamID != "a" {
		t.Fatalf("projection order changed: %+v", rows)
	}
	if rows[0].Label != "Second declaration" || rows[0].Gate != "flag" || rows[0].Verdict != "—" {
		t.Errorf("authored board cells were not decoded: %+v", rows[0])
	}
	if rows[0].ArcStatus != "active" {
		t.Errorf("arc lifecycle status was not decoded: %+v", rows[0])
	}
	if rows[0].WorkItem == nil || *rows[0].WorkItem != "item-b" || rows[0].ReviewPacket == nil || *rows[0].ReviewPacket != "packets/b.md" {
		t.Errorf("declared navigation fields were not decoded: %+v", rows[0])
	}
	if rows[1].WorkItem != nil || rows[1].ReviewPacket != nil {
		t.Errorf("nullable navigation fields changed meaning: %+v", rows[1])
	}
}

func TestDecodeRowsDistinguishesPresentEmptyAndAbsent(t *testing.T) {
	raw := `{"coordination_arcs":[{"arc":"empty","status":"active"}],"coordination_streams":[]}`
	rows, found, err := decodeRows(strings.NewReader(raw), "empty")
	if err != nil || !found || len(rows) != 0 {
		t.Fatalf("present empty arc = rows:%+v found:%v err:%v", rows, found, err)
	}
	rows, found, err = decodeRows(strings.NewReader(raw), "absent")
	if err != nil || found || len(rows) != 0 {
		t.Fatalf("absent arc = rows:%+v found:%v err:%v", rows, found, err)
	}
}

func TestDecodeAttentionKeepsNamedSparseBucketsAndExplicitIdentity(t *testing.T) {
	raw := `{
  "coordination_streams": [],
  "buckets": {
    "act_now": [
      {"title":"work task","observed_facts":{"slug":"item-only"}},
      {"title":"ready","observed_facts":{"arc":"arc-a","stream_id":"s1","step":"Ready","gate":"hold","status":"future-status","verdict":"future-verdict","work_item":"item-a","review_packet":"packet.md"}}
    ],
    "needs_judgment": [],
    "waiting": [{"title":"missing stream","observed_facts":{"arc":"arc-a"}}],
    "reconcile": [{"title":"unknown row","observed_facts":{"arc":"arc-b","stream_id":"s2","step":"Unknown","gate":"future-gate","status":"future-status","verdict":"future-verdict","work_item":null,"review_packet":null}}]
  }
}`
	attention, err := decodeAttention(strings.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	if len(attention) != len(AttentionBucketOrder) || attention[NeedsJudgment] == nil || attention[Waiting] == nil {
		t.Fatalf("named empty buckets were not retained: %#v", attention)
	}
	if got := attention[ActNow]; len(got) != 1 || got[0].Arc != "arc-a" || got[0].StreamID != "s1" {
		t.Fatalf("arc-addressable attention rows = %+v", got)
	} else if got[0].Status != "future-status" || got[0].Gate != "hold" || got[0].Verdict != "future-verdict" {
		t.Fatalf("open vocabulary changed during decode: %+v", got[0])
	} else if got[0].WorkItem == nil || *got[0].WorkItem != "item-a" || got[0].ReviewPacket == nil || *got[0].ReviewPacket != "packet.md" {
		t.Fatalf("attention navigation identity missing: %+v", got[0])
	}
	if got := attention[Reconcile]; len(got) != 1 || got[0].WorkItem != nil || got[0].ReviewPacket != nil || got[0].Gate != "future-gate" {
		t.Fatalf("unknown/null attention facts changed during decode: %+v", got)
	}
}

func TestDecodeAttentionRequiresEveryNamedBucket(t *testing.T) {
	_, err := decodeAttention(strings.NewReader(`{"buckets":{"act_now":[],"needs_judgment":[],"waiting":[]}}`))
	if err == nil || !strings.Contains(err.Error(), "missing bucket reconcile") {
		t.Fatalf("missing attention bucket should be explicit, got %v", err)
	}
}

func TestDecodeRowsRequiresCompleteStreamProjection(t *testing.T) {
	if _, _, err := decodeRows(strings.NewReader(`{"coordination_arcs":[]}`), "arc"); err == nil || !strings.Contains(err.Error(), "missing coordination_streams") {
		t.Fatalf("missing full projection should be explicit, got %v", err)
	}
	if _, _, err := decodeRows(strings.NewReader(`{"coordination_streams":[]}`), "arc"); err == nil || !strings.Contains(err.Error(), "missing coordination_arcs") {
		t.Fatalf("missing arc projection should be explicit, got %v", err)
	}
}

func TestDecodeRowsRejectsMalformedJSON(t *testing.T) {
	if _, _, err := decodeRows(strings.NewReader(`{"coordination_streams":`), "arc"); err == nil {
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
printf '%s\n' '{"coordination_arcs":[{"arc":"wanted","status":"active"}],"coordination_streams":[{"arc":"wanted","arc_status":"active","stream_id":"s1","step":"Joined","depends_on":[],"tree":"writer","gate":"notify","status":"done","verdict":"full"}]}'
`
	if err := os.WriteFile(command, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	rows, found, err := Load(context.Background(), "wanted")
	if err != nil {
		t.Fatal(err)
	}
	if !found {
		t.Fatal("Load lost the declared arc identity")
	}
	if len(rows) != 1 || rows[0].StreamID != "s1" || rows[0].Label != "Joined" {
		t.Fatalf("Load returned %+v", rows)
	}
}
