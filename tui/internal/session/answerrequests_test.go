package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func writeAnswerRequest(t *testing.T, sessionsDir string, request AnswerRequest) {
	t.Helper()
	dir := AnswerRequestsDir(sessionsDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, request.RequestID+".json"), data, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestScanAnswerRequestsDecodesNumericOption(t *testing.T) {
	dir := t.TempDir()
	want := AnswerRequest{
		RequestID: "answer-1", Slug: "demo", TargetInstance: "amber-otter",
		Option: 2, Expect: "Would you like to run", RequestedBy: "lead",
		RequestedAt: "2026-07-16T00:00:00Z", RegistrationID: "standing-answer-v1",
	}
	writeAnswerRequest(t, dir, want)
	got := ScanAnswerRequests(dir)
	if len(got) != 1 || got[0] != want {
		t.Fatalf("scan = %+v, want [%+v]", got, want)
	}
}

func TestScanAnswerRequestsExcludesCorruptRows(t *testing.T) {
	dir := t.TempDir()
	writeAnswerRequest(t, dir, AnswerRequest{RequestID: "good", Slug: "demo", Option: 1})
	if err := os.WriteFile(filepath.Join(AnswerRequestsDir(dir), "torn.json"), []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	rows, diagnostics := ScanAnswerRequestsWithDiagnostics(dir)
	if len(rows) != 1 || rows[0].RequestID != "good" || len(diagnostics) != 1 {
		t.Fatalf("rows=%+v diagnostics=%+v", rows, diagnostics)
	}
}

func TestDeleteAnswerRequestIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	writeAnswerRequest(t, dir, AnswerRequest{RequestID: "answer-1", Slug: "demo", Option: 1})
	if err := DeleteAnswerRequest(dir, "answer-1"); err != nil {
		t.Fatal(err)
	}
	if err := DeleteAnswerRequest(dir, "answer-1"); err != nil {
		t.Fatal(err)
	}
	if got := ScanAnswerRequests(dir); len(got) != 0 {
		t.Fatalf("request survived delete: %+v", got)
	}
}
