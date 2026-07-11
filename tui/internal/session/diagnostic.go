package session

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Diagnostic describes a non-fatal substrate row that was excluded from a
// tolerant scan. Callers decide where to surface it.
type Diagnostic struct {
	Source  string `json:"source"`
	Path    string `json:"path"`
	Message string `json:"message"`
}

type diagnosticLogRow struct {
	Timestamp string `json:"timestamp"`
	Class     string `json:"class"`
	Source    string `json:"source"`
	Path      string `json:"path"`
	Message   string `json:"message"`
}

func corruptDiagnostic(source, path string, err error) Diagnostic {
	return Diagnostic{Source: source, Path: path, Message: fmt.Sprintf("corrupt row excluded: %v", err)}
}

// AppendDiagnostics appends diagnostics to the TUI-owned structured notice log.
func AppendDiagnostics(sessionsDir string, diagnostics []Diagnostic) error {
	if len(diagnostics) == 0 {
		return nil
	}
	if err := os.MkdirAll(sessionsDir, 0o755); err != nil {
		return fmt.Errorf("create sessions dir: %w", err)
	}
	var buf bytes.Buffer
	for _, d := range diagnostics {
		row := diagnosticLogRow{
			Timestamp: time.Now().UTC().Format(time.RFC3339),
			Class:     "background-diagnostic",
			Source:    d.Source,
			Path:      d.Path,
			Message:   d.Message,
		}
		data, err := json.Marshal(row)
		if err != nil {
			return fmt.Errorf("marshal diagnostic: %w", err)
		}
		buf.Write(data)
		buf.WriteByte('\n')
	}
	f, err := os.OpenFile(filepath.Join(sessionsDir, "tui-notices.jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("open TUI notice log: %w", err)
	}
	defer f.Close()
	if _, err := f.Write(buf.Bytes()); err != nil {
		return fmt.Errorf("append TUI notice log: %w", err)
	}
	return nil
}
