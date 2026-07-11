package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// writeCloseRequest plants a close-request row at close-requests/<id>.json.
func writeCloseRequest(t *testing.T, sessionsDir string, cr CloseRequest) {
	t.Helper()
	dir := CloseRequestsDir(sessionsDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(cr)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, cr.RequestID+".json"), data, 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestScanCloseRequests_DecodesRows: a well-formed bash-written row round-trips
// through the Go reader with every field intact.
func TestScanCloseRequests_DecodesRows(t *testing.T) {
	dir := t.TempDir()
	want := CloseRequest{
		RequestID:      "20260705T000000Z-abcd",
		Slug:           "demo",
		TargetInstance: "amber-otter",
		Reason:         "protocol_terminus",
		RequestedBy:    "amber-otter",
		RequestedAt:    "2026-07-05T00:00:00Z",
	}
	writeCloseRequest(t, dir, want)

	got := ScanCloseRequests(dir)
	if len(got) != 1 {
		t.Fatalf("scan returned %d rows, want 1", len(got))
	}
	if got[0] != want {
		t.Fatalf("row = %+v, want %+v", got[0], want)
	}
}

// TestScanCloseRequests_ExcludesCorruptRow: a torn/corrupt row is dropped with a
// diagnostic while valid siblings still return (reader tolerance, not abort).
func TestScanCloseRequests_ExcludesCorruptRow(t *testing.T) {
	dir := t.TempDir()
	writeCloseRequest(t, dir, CloseRequest{RequestID: "good", Slug: "demo", TargetInstance: "me"})
	if err := os.WriteFile(filepath.Join(CloseRequestsDir(dir), "torn.json"), []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}

	got := ScanCloseRequests(dir)
	if len(got) != 1 || got[0].RequestID != "good" {
		t.Fatalf("scan = %+v, want only the good row", got)
	}
}

// TestScanCloseRequests_AbsentDir: no directory yields no rows and no panic.
func TestScanCloseRequests_AbsentDir(t *testing.T) {
	if got := ScanCloseRequests(t.TempDir()); got != nil {
		t.Fatalf("scan of absent dir = %+v, want nil", got)
	}
}

// TestScanCloseRequests_ToleratesUnknownFields: a forward-extended writer that
// adds a field the reader does not know must not break decoding of the fields it
// does know.
func TestScanCloseRequests_ToleratesUnknownFields(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(CloseRequestsDir(dir), 0o755); err != nil {
		t.Fatal(err)
	}
	row := `{"request_id":"r1","slug":"demo","target_instance":"me","reason":"human","future_field":42}`
	if err := os.WriteFile(filepath.Join(CloseRequestsDir(dir), "r1.json"), []byte(row), 0o644); err != nil {
		t.Fatal(err)
	}
	got := ScanCloseRequests(dir)
	if len(got) != 1 || got[0].Slug != "demo" || got[0].Reason != "human" {
		t.Fatalf("scan = %+v, want the known fields decoded", got)
	}
}

// TestDeleteCloseRequest_RemovesAndIsIdempotent: delete consumes the row, and a
// repeat delete on the now-missing file is not an error.
func TestDeleteCloseRequest_RemovesAndIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	writeCloseRequest(t, dir, CloseRequest{RequestID: "r1", Slug: "demo", TargetInstance: "me"})

	if err := DeleteCloseRequest(dir, "r1"); err != nil {
		t.Fatalf("first delete: %v", err)
	}
	if got := ScanCloseRequests(dir); len(got) != 0 {
		t.Fatalf("row still present after delete: %+v", got)
	}
	if err := DeleteCloseRequest(dir, "r1"); err != nil {
		t.Fatalf("idempotent delete errored: %v", err)
	}
}
