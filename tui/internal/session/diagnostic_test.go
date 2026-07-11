package session

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestAppendDiagnosticsWritesStructuredJSONL(t *testing.T) {
	dir := t.TempDir()
	diagnostics := []Diagnostic{{Source: "instance-registry", Path: "/tmp/bad.json", Message: "corrupt row excluded"}}
	if err := AppendDiagnostics(dir, diagnostics); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(filepath.Join(dir, "tui-notices.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	if !scanner.Scan() {
		t.Fatalf("missing notice row: %v", scanner.Err())
	}
	var row diagnosticLogRow
	if err := json.Unmarshal(scanner.Bytes(), &row); err != nil {
		t.Fatal(err)
	}
	if row.Class != "background-diagnostic" || row.Source != diagnostics[0].Source || row.Path != diagnostics[0].Path {
		t.Errorf("row = %#v", row)
	}
}
