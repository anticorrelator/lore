package main

import (
	"os"
	"path/filepath"
	"testing"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/followup"
)

// TestParityDumpWorkList writes an off-TTY View() dump of the work-list
// surface at the canonical capture geometry (170x46), for comparison against
// a live tmux capture of the same state (scripts/tui-capture.sh). Skipped
// unless LORE_PARITY_DUMP_OUT names the output path.
//
// The model is fed the same local-disk load messages the live app receives at
// startup (work index, follow-up index, settlement status, active sessions);
// PR status and doctor results are deliberately omitted (network/subprocess
// nondeterminism), so those status-bar regions may differ from the live pane.
func TestParityDumpWorkList(t *testing.T) {
	out := os.Getenv("LORE_PARITY_DUMP_OUT")
	if out == "" {
		t.Skip("LORE_PARITY_DUMP_OUT not set; parity dump is opt-in")
	}

	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}

	m := newModel(cfg, config.Prefs{Layout: config.LayoutTopBottom}, stateWork)
	m, _ = updateModel(t, m, tea.WindowSizeMsg{Width: 170, Height: 46})
	for _, cmd := range []tea.Cmd{
		loadWorkItems(cfg.WorkDir),
		followup.LoadIndexCmd(cfg.KnowledgeDir),
		loadSettlementStatus(),
		readInstancesCmd(filepath.Join(cfg.KnowledgeDir, "_sessions")),
	} {
		m, _ = updateModel(t, m, cmd())
	}

	if err := os.WriteFile(out, []byte(m.viewContent()+"\n"), 0644); err != nil {
		t.Fatalf("write %s: %v", out, err)
	}
}
