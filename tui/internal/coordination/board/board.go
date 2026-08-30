// Package board loads and renders the declaration-ordered stream DAG for one
// coordination arc. Its only data source is `lore coordinate status --json`;
// coordination.md remains owned and parsed by the status join.
package board

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os/exec"
	"strings"
)

// Row is one authored stream in an arc's coordination ledger.
type Row struct {
	Arc          string   `json:"arc"`
	ArcStatus    string   `json:"arc_status"`
	StreamID     string   `json:"stream_id"`
	Label        string   `json:"step"`
	DependsOn    []string `json:"depends_on"`
	Tree         string   `json:"tree"`
	Gate         string   `json:"gate"`
	Status       string   `json:"status"`
	Verdict      string   `json:"verdict"`
	WorkItem     *string  `json:"work_item"`
	ReviewPacket *string  `json:"review_packet"`
}

type statusProjection struct {
	CoordinationArcs    json.RawMessage `json:"coordination_arcs"`
	CoordinationStreams json.RawMessage `json:"coordination_streams"`
	Buckets             statusBuckets   `json:"buckets"`
}

type statusArc struct {
	Arc    string `json:"arc"`
	Status string `json:"status"`
}

// AttentionBucket names one sparse action projection in display order.
type AttentionBucket string

const (
	ActNow        AttentionBucket = "act_now"
	NeedsJudgment AttentionBucket = "needs_judgment"
	Waiting       AttentionBucket = "waiting"
	Reconcile     AttentionBucket = "reconcile"
)

// AttentionBucketOrder is the status contract's stable bucket order.
var AttentionBucketOrder = []AttentionBucket{ActNow, NeedsJudgment, Waiting, Reconcile}

// AttentionRow is a bucket row that explicitly addresses one arc stream.
type AttentionRow struct {
	Bucket       AttentionBucket
	Arc          string
	StreamID     string
	Title        string
	Label        string
	Gate         string
	Status       string
	Verdict      string
	WorkItem     *string
	ReviewPacket *string
}

// Attention retains each named bucket even when it has no arc-addressable rows.
type Attention map[AttentionBucket][]AttentionRow

type statusBuckets struct {
	ActNow        json.RawMessage `json:"act_now"`
	NeedsJudgment json.RawMessage `json:"needs_judgment"`
	Waiting       json.RawMessage `json:"waiting"`
	Reconcile     json.RawMessage `json:"reconcile"`
}

type statusBucketRow struct {
	Title         string `json:"title"`
	ObservedFacts struct {
		Arc          string  `json:"arc"`
		StreamID     string  `json:"stream_id"`
		Label        string  `json:"step"`
		Gate         string  `json:"gate"`
		Status       string  `json:"status"`
		Verdict      string  `json:"verdict"`
		WorkItem     *string `json:"work_item"`
		ReviewPacket *string `json:"review_packet"`
	} `json:"observed_facts"`
}

// Load returns the complete stream rows for arc in ledger declaration order.
// found distinguishes a declared arc with zero rows from an arc absent from the
// projection. Load derives a fresh board on every call and keeps no cache or
// layout state.
func Load(ctx context.Context, arc string) ([]Row, bool, error) {
	out, err := loadStatus(ctx)
	if err != nil {
		return nil, false, err
	}
	return decodeRows(bytes.NewReader(out), arc)
}

// LoadAttention returns the four sparse action buckets. Only rows carrying
// both arc and stream identity participate in this cross-arc projection.
func LoadAttention(ctx context.Context) (Attention, error) {
	out, err := loadStatus(ctx)
	if err != nil {
		return nil, err
	}
	return decodeAttention(bytes.NewReader(out))
}

func loadStatus(ctx context.Context) ([]byte, error) {
	cmd := exec.CommandContext(ctx, "lore", "coordinate", "status", "--json")
	out, err := cmd.CombinedOutput()
	if err == nil {
		return out, nil
	}
	detail := strings.TrimSpace(string(out))
	if detail == "" {
		return nil, fmt.Errorf("lore coordinate status --json: %w", err)
	}
	return nil, fmt.Errorf("lore coordinate status --json: %w: %s", err, detail)
}

func decodeRows(r io.Reader, arc string) ([]Row, bool, error) {
	var projection statusProjection
	decoder := json.NewDecoder(r)
	if err := decoder.Decode(&projection); err != nil {
		return nil, false, fmt.Errorf("decode coordinate status: %w", err)
	}
	if len(projection.CoordinationArcs) == 0 {
		return nil, false, fmt.Errorf("decode coordinate status: missing coordination_arcs")
	}
	if len(projection.CoordinationStreams) == 0 {
		return nil, false, fmt.Errorf("decode coordinate status: missing coordination_streams")
	}

	var arcs []statusArc
	if err := json.Unmarshal(projection.CoordinationArcs, &arcs); err != nil {
		return nil, false, fmt.Errorf("decode coordinate arcs: %w", err)
	}
	found := false
	for _, candidate := range arcs {
		if candidate.Arc == arc {
			found = true
			break
		}
	}

	var all []Row
	if err := json.Unmarshal(projection.CoordinationStreams, &all); err != nil {
		return nil, false, fmt.Errorf("decode coordinate streams: %w", err)
	}
	rows := make([]Row, 0, len(all))
	for _, row := range all {
		if row.Arc == arc {
			rows = append(rows, row)
		}
	}
	if len(rows) > 0 && !found {
		return nil, false, fmt.Errorf("decode coordinate status: arc %q has stream rows but no coordination_arcs entry", arc)
	}
	return rows, found, nil
}

func decodeAttention(r io.Reader) (Attention, error) {
	var projection statusProjection
	decoder := json.NewDecoder(r)
	if err := decoder.Decode(&projection); err != nil {
		return nil, fmt.Errorf("decode coordinate status: %w", err)
	}
	rawBuckets := map[AttentionBucket]json.RawMessage{
		ActNow: projection.Buckets.ActNow, NeedsJudgment: projection.Buckets.NeedsJudgment,
		Waiting: projection.Buckets.Waiting, Reconcile: projection.Buckets.Reconcile,
	}
	attention := make(Attention, len(AttentionBucketOrder))
	for _, bucket := range AttentionBucketOrder {
		raw := rawBuckets[bucket]
		if len(raw) == 0 {
			return nil, fmt.Errorf("decode coordinate status: missing bucket %s", bucket)
		}
		var rows []statusBucketRow
		if err := json.Unmarshal(raw, &rows); err != nil {
			return nil, fmt.Errorf("decode coordinate bucket %s: %w", bucket, err)
		}
		attention[bucket] = []AttentionRow{}
		for _, row := range rows {
			facts := row.ObservedFacts
			if facts.Arc == "" || facts.StreamID == "" {
				continue
			}
			attention[bucket] = append(attention[bucket], AttentionRow{
				Bucket: bucket, Arc: facts.Arc, StreamID: facts.StreamID,
				Title: row.Title, Label: facts.Label, Gate: facts.Gate,
				Status: facts.Status, Verdict: facts.Verdict,
				WorkItem: facts.WorkItem, ReviewPacket: facts.ReviewPacket,
			})
		}
	}
	return attention, nil
}
