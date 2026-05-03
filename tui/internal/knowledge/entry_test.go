package knowledge

import (
	"strings"
	"testing"
)

// Real-world fixtures sampled from the live knowledge store. Keep these as
// verbatim strings so format drift is caught by the parser tests.
const (
	legacyComment = `<!-- learned: 2026-04-01 | confidence: high | source: manual | related_files: a.md,b.md -->`

	newCaptureComment = `<!-- learned: 2026-04-29 | confidence: unaudited | source: lore-promote | related_files: scripts/load-knowledge.sh,scripts/load-threads.sh | producer_role: worker | protocol_slot: implement-step-3 | template_version: 68bb71c2a0b1 | source_artifact_ids: load-knowledge-pending-captures-signal-p1-1 | work_item: condense-oversized-claude-md-fragments | scale: subsystem | captured_at_branch: memory-refactor | captured_at_sha: 813696ee72f0303f617f1715222df2ed8ea59cef | captured_at_merge_base_sha: 91b82fdf0da6802003dd2d66a7de25f61d91fc8a | status: current -->`

	edgeSynopsisComment = `<!-- entry_id: architecture/harness/persistence-architecture | requesting_scale: subsystem | synthesized_at: 2026-04-28T17:46:50Z | parent_content_hash: 3414be116c86c664245cc346e1de855dd86af7cd805bffe48dfec82ac9684b20 | parent_template_version: unknown | synopsis_status: fallback -->`
)

func TestParseEntryMeta_LegacyFormat(t *testing.T) {
	meta := parseEntryMeta("body text\n\n" + legacyComment)
	if meta.Learned != "2026-04-01" {
		t.Errorf("Learned = %q, want %q", meta.Learned, "2026-04-01")
	}
	if meta.Confidence != "high" {
		t.Errorf("Confidence = %q, want %q", meta.Confidence, "high")
	}
	if meta.Source != "manual" {
		t.Errorf("Source = %q, want %q", meta.Source, "manual")
	}
	if got, want := meta.RelatedFiles, []string{"a.md", "b.md"}; !equalSlices(got, want) {
		t.Errorf("RelatedFiles = %v, want %v", got, want)
	}
}

func TestParseEntryMeta_NewCaptureFormat(t *testing.T) {
	meta := parseEntryMeta("body text\n\n" + newCaptureComment)

	// Legacy fields still populated.
	if meta.Learned != "2026-04-29" {
		t.Errorf("Learned = %q", meta.Learned)
	}
	if meta.Confidence != "unaudited" {
		t.Errorf("Confidence = %q", meta.Confidence)
	}
	if meta.Source != "lore-promote" {
		t.Errorf("Source = %q", meta.Source)
	}

	// New named fields surfaced for footer display.
	if meta.Scale != "subsystem" {
		t.Errorf("Scale = %q, want subsystem", meta.Scale)
	}
	if meta.WorkItem != "condense-oversized-claude-md-fragments" {
		t.Errorf("WorkItem = %q", meta.WorkItem)
	}

	// Open-schema fields preserved on the map for any future renderer.
	if got := meta.Fields["template_version"]; got != "68bb71c2a0b1" {
		t.Errorf("Fields[template_version] = %q", got)
	}
	if got := meta.Fields["status"]; got != "current" {
		t.Errorf("Fields[status] = %q", got)
	}
	if got := meta.Fields["captured_at_branch"]; got != "memory-refactor" {
		t.Errorf("Fields[captured_at_branch] = %q", got)
	}
}

func TestParseEntryMeta_EdgeSynopsisSchema(t *testing.T) {
	// Edge synopses use a completely disjoint key set. The parser should still
	// populate Fields and not panic; legacy named fields will be empty.
	meta := parseEntryMeta(edgeSynopsisComment + "\n\nbody")

	if meta.Learned != "" || meta.Confidence != "" || meta.Source != "" {
		t.Errorf("legacy fields should be empty for edge synopsis, got %+v", meta)
	}
	if got := meta.Fields["entry_id"]; got != "architecture/harness/persistence-architecture" {
		t.Errorf("Fields[entry_id] = %q", got)
	}
	if got := meta.Fields["requesting_scale"]; got != "subsystem" {
		t.Errorf("Fields[requesting_scale] = %q", got)
	}
	if got := meta.Fields["synopsis_status"]; got != "fallback" {
		t.Errorf("Fields[synopsis_status] = %q", got)
	}
}

func TestParseEntryMeta_NoComment(t *testing.T) {
	meta := parseEntryMeta("just body, no metadata\n")
	if meta.Learned != "" || meta.Scale != "" || len(meta.RelatedFiles) != 0 {
		t.Errorf("expected zero meta, got %+v", meta)
	}
	if meta.Fields == nil {
		t.Error("Fields should be non-nil even when no comment matched")
	}
}

func TestStripMetaComment_RemovesAllSchemas(t *testing.T) {
	cases := []struct {
		name string
		body string
	}{
		{"legacy", "# Title\n\nbody\n\n" + legacyComment + "\n"},
		{"new", "# Title\n\nbody\n\n" + newCaptureComment + "\n"},
		{"edge_synopsis", edgeSynopsisComment + "\n\n# Synopsis body\n"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := stripMetaComment(tc.body)
			if strings.Contains(out, "<!--") {
				t.Errorf("comment leaked into rendered body: %q", out)
			}
		})
	}
}

func TestStripMetaComment_PreservesNonMetaComments(t *testing.T) {
	// The inbox header and similar free-text comments must survive — they don't
	// have the pipe-delimited "key: value" structure.
	in := "<!-- Append new entries below this line. -->\n\nentry body\n"
	out := stripMetaComment(in)
	if !strings.Contains(out, "Append new entries below this line.") {
		t.Errorf("non-meta comment was incorrectly stripped: %q", out)
	}
}

func equalSlices(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
