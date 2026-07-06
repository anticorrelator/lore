package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// writeSpendStub writes an executable bash stub at <dir>/session-spend.sh that
// prints `body` verbatim on stdout and exits 0 — standing in for the real
// session-spend.sh so closedSpend's merge/degrade branches can be exercised
// without a live transcript.
func writeSpendStub(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "session-spend.sh")
	script := "#!/usr/bin/env bash\ncat <<'EOF'\n" + body + "\nEOF\n"
	if err := os.WriteFile(path, []byte(script), 0755); err != nil {
		t.Fatalf("write spend stub: %v", err)
	}
	return path
}

func decodeSpend(t *testing.T, raw json.RawMessage) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("closedSpend produced non-JSON %q: %v", string(raw), err)
	}
	return m
}

// TestClosedSpend_NoBindingDurationOnly: without a session id (or script, or
// harness) closedSpend never shells out and returns the duration-only shape with
// the explicit degradation marker.
func TestClosedSpend_NoBindingDurationOnly(t *testing.T) {
	got := decodeSpend(t, closedSpend("", "", "", "/cwd", 42))
	if got["duration_seconds"] != float64(42) {
		t.Errorf("duration_seconds = %v, want 42", got["duration_seconds"])
	}
	if got["basis"] != "duration-only" {
		t.Errorf("basis = %v, want duration-only", got["basis"])
	}
	if _, ok := got["total_tokens"]; ok {
		t.Errorf("duration-only spend must not carry token fields: %v", got)
	}
}

// TestClosedSpend_MergesTokenFields: a transcript-basis probe result is overlaid
// onto the duration base — token fields and basis:transcript survive, and
// duration_seconds is stamped TUI-side (the helper never emits it).
func TestClosedSpend_MergesTokenFields(t *testing.T) {
	stub := writeSpendStub(t, `{"input_tokens":100,"output_tokens":50,"total_tokens":150,"harness":"claude-code","basis":"transcript","model":"claude-opus"}`)
	got := decodeSpend(t, closedSpend(stub, "claude-code", "abc-123", "/cwd", 7))

	if got["basis"] != "transcript" {
		t.Errorf("basis = %v, want transcript (probe result should win over the duration-only base)", got["basis"])
	}
	if got["duration_seconds"] != float64(7) {
		t.Errorf("duration_seconds = %v, want 7 (stamped TUI-side)", got["duration_seconds"])
	}
	if got["total_tokens"] != float64(150) {
		t.Errorf("total_tokens = %v, want 150", got["total_tokens"])
	}
	if got["model"] != "claude-opus" {
		t.Errorf("model = %v, want claude-opus", got["model"])
	}
}

// TestClosedSpend_HelperDegradedStaysDurationOnly: when the helper itself
// degrades ({"basis":"duration-only"}), the closed row carries that basis plus
// the merged duration — no token fields appear.
func TestClosedSpend_HelperDegradedStaysDurationOnly(t *testing.T) {
	stub := writeSpendStub(t, `{"basis":"duration-only"}`)
	got := decodeSpend(t, closedSpend(stub, "claude-code", "abc-123", "/cwd", 9))
	if got["basis"] != "duration-only" {
		t.Errorf("basis = %v, want duration-only", got["basis"])
	}
	if got["duration_seconds"] != float64(9) {
		t.Errorf("duration_seconds = %v, want 9", got["duration_seconds"])
	}
	if _, ok := got["total_tokens"]; ok {
		t.Errorf("degraded probe must not introduce token fields: %v", got)
	}
}

// TestClosedSpend_UnparseableOutputDegrades: non-JSON probe output falls back to
// the duration-only shape rather than propagating garbage into the journal.
func TestClosedSpend_UnparseableOutputDegrades(t *testing.T) {
	stub := writeSpendStub(t, `not json at all`)
	got := decodeSpend(t, closedSpend(stub, "claude-code", "abc-123", "/cwd", 3))
	if got["basis"] != "duration-only" {
		t.Errorf("basis = %v, want duration-only on unparseable output", got["basis"])
	}
	if got["duration_seconds"] != float64(3) {
		t.Errorf("duration_seconds = %v, want 3", got["duration_seconds"])
	}
}
