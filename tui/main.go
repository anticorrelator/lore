package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/followup"
	"github.com/anticorrelator/lore/tui/internal/settlement"
	"github.com/anticorrelator/lore/tui/internal/work"
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

// newModel constructs the root model with its list sub-models initialized.
//
// followupList in particular MUST be built via NewListModel here. The
// follow-up index is loaded in the background (the startup batch and the
// mtime poll both fire LoadIndexCmd while the app sits in stateWork), and its
// IndexLoadedMsg handler updates the list *in place* via SetItems — unlike the
// work list, which is rebuilt via NewListModel on every load. A zero-value
// followupList therefore keeps nil columns and stackedBelow=0, so ModeFor
// always selects the columnar path and FitColumns yields no slots: every row
// renders as blank padding (the selected row as a highlighted empty bar) even
// though navigation and detail prefetch work. The stale `if Items()==0`
// guard in the f-handler does not save us, because the background load has
// already populated items by the time the user opens the panel.
func newModel(cfg config.Config, prefs config.Prefs, startState appState) model {
	return model{
		state:        startState,
		config:       cfg,
		layoutMode:   prefs.Layout,
		indexPath:    filepath.Join(cfg.WorkDir, "_index.json"),
		settlement:   settlement.NewModel(),
		list:         work.NewListModel(nil),
		followupList: followup.NewListModel(nil),
	}
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

	m := newModel(cfg, prefs, startState)

	// Best-effort settings panel initialization. A nil panel disables the
	// configurator open key but does not block startup — the modal is a
	// non-load-bearing affordance (the underlying CLI surfaces are still
	// reachable). Schema errors are intentionally non-fatal here per D1:
	// SettingsModel.View renders an inline error banner.
	if startState != stateNoRepo {
		if panel, _ := initSettingsPanel(); panel != nil {
			m.settingsPanel = panel
		}
	}
	// Terminal modes (alt screen, mouse) are view state in bubbletea v2:
	// the root View() applies them on every render.
	p := tea.NewProgram(m)
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
