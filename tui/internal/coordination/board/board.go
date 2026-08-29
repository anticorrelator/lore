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
	Arc       string   `json:"arc"`
	StreamID  string   `json:"stream_id"`
	Label     string   `json:"step"`
	DependsOn []string `json:"depends_on"`
	Tree      string   `json:"tree"`
	Gate      string   `json:"gate"`
	Status    string   `json:"status"`
	Verdict   string   `json:"verdict"`
}

type statusProjection struct {
	CoordinationStreams json.RawMessage `json:"coordination_streams"`
}

// Load returns the complete stream rows for arc in ledger declaration order.
// It derives a fresh board on every call and keeps no cache or layout state.
func Load(ctx context.Context, arc string) ([]Row, error) {
	cmd := exec.CommandContext(ctx, "lore", "coordinate", "status", "--json")
	out, err := cmd.CombinedOutput()
	if err != nil {
		detail := strings.TrimSpace(string(out))
		if detail == "" {
			return nil, fmt.Errorf("lore coordinate status --json: %w", err)
		}
		return nil, fmt.Errorf("lore coordinate status --json: %w: %s", err, detail)
	}
	return decodeRows(bytes.NewReader(out), arc)
}

func decodeRows(r io.Reader, arc string) ([]Row, error) {
	var projection statusProjection
	decoder := json.NewDecoder(r)
	if err := decoder.Decode(&projection); err != nil {
		return nil, fmt.Errorf("decode coordinate status: %w", err)
	}
	if len(projection.CoordinationStreams) == 0 {
		return nil, fmt.Errorf("decode coordinate status: missing coordination_streams")
	}

	var all []Row
	if err := json.Unmarshal(projection.CoordinationStreams, &all); err != nil {
		return nil, fmt.Errorf("decode coordinate streams: %w", err)
	}
	rows := make([]Row, 0, len(all))
	for _, row := range all {
		if row.Arc == arc {
			rows = append(rows, row)
		}
	}
	return rows, nil
}
