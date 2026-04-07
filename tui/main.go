package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/anticorrelator/lore/tui/internal/config"
)

// classifyStartupState returns stateOnboarding if the knowledge store is
// uninitialized (manifest or work index missing), otherwise stateWork.
func classifyStartupState(cfg config.Config) appState {
	if _, err := os.Stat(filepath.Join(cfg.KnowledgeDir, "_manifest.json")); err != nil {
		return stateOnboarding
	}
	if _, err := os.Stat(filepath.Join(cfg.WorkDir, "_index.json")); err != nil {
		return stateOnboarding
	}
	return stateWork
}

func main() {
	// Capture panics to a crash log for debugging.
	crashLog := filepath.Join(os.TempDir(), "lore-tui-crash.log")
	defer func() {
		if r := recover(); r != nil {
			stack := fmt.Sprintf("panic: %v\n\n%s", r, debug.Stack())
			_ = os.WriteFile(crashLog, []byte(stack), 0644)
			fmt.Fprintf(os.Stderr, "TUI crashed. Stack trace written to %s\n", crashLog)
			os.Exit(1)
		}
	}()

	cfg, err := config.Load()
	if err != nil && !errors.Is(err, config.ErrNoRepo) {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	prefs := config.LoadPrefs()

	startState := stateWork
	if errors.Is(err, config.ErrNoRepo) {
		startState = stateNoRepo
	} else {
		startState = classifyStartupState(cfg)
	}

	m := model{
		state:      startState,
		config:     cfg,
		layoutMode: prefs.Layout,
		indexPath:  filepath.Join(cfg.WorkDir, "_index.json"),
	}
	p := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

