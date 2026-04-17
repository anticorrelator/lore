package followup

import (
	"fmt"
	"os"
	"path/filepath"
)

// ResolveDir returns the on-disk directory for a followup id, checking the
// active tier first and then _followups/_archive/. Mirrors resolve_followup_dir
// in scripts/lib.sh so the TUI and shell layer agree on lookup semantics.
func ResolveDir(knowledgeDir, id string) (string, error) {
	active := filepath.Join(knowledgeDir, "_followups", id)
	if info, err := os.Stat(active); err == nil && info.IsDir() {
		return active, nil
	}
	archived := filepath.Join(knowledgeDir, "_followups", "_archive", id)
	if info, err := os.Stat(archived); err == nil && info.IsDir() {
		return archived, nil
	}
	return "", fmt.Errorf("followup %q not found in _followups or _followups/_archive", id)
}
