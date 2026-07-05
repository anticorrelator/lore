package session

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func writeJSON(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestScanAndDeleteSendRequests(t *testing.T) {
	dir := t.TempDir()
	writeJSON(t, filepath.Join(SendRequestsDir(dir), "r1.json"),
		`{"request_id":"r1","slug":"demo","target_instance":"amber-otter","body":"hi"}`)
	writeJSON(t, filepath.Join(SendRequestsDir(dir), "bad.json"), `{not json`)

	rows := ScanSendRequests(dir)
	if len(rows) != 1 || rows[0].RequestID != "r1" || rows[0].Body != "hi" {
		t.Fatalf("scan send-requests = %+v", rows)
	}
	if err := DeleteSendRequest(dir, "r1"); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if err := DeleteSendRequest(dir, "r1"); err != nil {
		t.Fatalf("delete of missing row must be idempotent: %v", err)
	}
	if got := ScanSendRequests(dir); len(got) != 0 {
		t.Fatalf("expected empty after delete, got %+v", got)
	}
}

func TestPeekResponseRoundtripAndGC(t *testing.T) {
	dir := t.TempDir()
	resp := PeekResponse{
		RequestID:     "p1",
		Slug:          "demo",
		CapturedAt:    "2026-07-05T00:00:00Z",
		Ready:         true,
		Rows:          []string{"row one", "row two"},
		BlockedReason: "",
	}
	if err := WritePeekResponse(dir, resp); err != nil {
		t.Fatalf("write response: %v", err)
	}
	path := filepath.Join(PeekResponsesDir(dir), "p1.json")
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("response file missing: %v", err)
	}
	// No tmp files left behind by the atomic-rename write.
	tmps, _ := filepath.Glob(filepath.Join(PeekResponsesDir(dir), ".tmp.*"))
	if len(tmps) != 0 {
		t.Fatalf("stray tmp files: %v", tmps)
	}

	// GC leaves a fresh response untouched but reclaims an aged one.
	GCPeekResponses(dir, time.Hour)
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("fresh response GC'd prematurely: %v", err)
	}
	old := time.Now().Add(-2 * time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	GCPeekResponses(dir, time.Hour)
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("aged response should have been GC'd, stat err=%v", err)
	}
}
