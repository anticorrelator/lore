package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/coordination"
	"github.com/anticorrelator/lore/tui/internal/followup"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/sessionview"
	"github.com/anticorrelator/lore/tui/internal/work"
)

type startupSnapshot struct {
	state   appState
	arcs    []coordination.Arc
	skipped int
}

// classifyStartup returns onboarding for an uninitialized store. An initialized
// store opens coordination only when an arc explicitly declares itself active.
func classifyStartup(cfg config.Config) startupSnapshot {
	if _, err := os.Stat(filepath.Join(cfg.KnowledgeDir, "_manifest.json")); err != nil {
		return startupSnapshot{state: stateOnboarding}
	}
	if _, err := os.Stat(filepath.Join(cfg.WorkDir, "_index.json")); err != nil {
		return startupSnapshot{state: stateOnboarding}
	}

	arcs, skipped := coordination.ScanArcs(cfg.WorkDir)
	state := stateWork
	for _, arc := range arcs {
		if arc.Status == coordination.StatusActive {
			state = stateCoordination
			break
		}
	}
	return startupSnapshot{state: state, arcs: arcs, skipped: skipped}
}

func classifyStartupState(cfg config.Config) appState {
	return classifyStartup(cfg).state
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
		state:              startState,
		config:             cfg,
		layoutMode:         prefs.Layout,
		indexPath:          filepath.Join(cfg.WorkDir, "_index.json"),
		list:               work.NewListModel(nil),
		followupList:       followup.NewListModel(nil),
		sessionsList:       sessionview.NewListModel(),
		sessionsDetail:     sessionview.NewDetailModel(),
		coordinationList:   coordination.NewListModel(),
		coordinationDetail: coordination.NewDetailModel(),
	}
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--session-host" {
		os.Exit(sessionHostMain(os.Args[2:]))
	}
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
	var startupArcs []coordination.Arc
	startupSkipped := 0
	if errors.Is(err, config.ErrNoRepo) {
		startState = stateNoRepo
	} else {
		startup := classifyStartup(cfg)
		startState = startup.state
		startupArcs = startup.arcs
		startupSkipped = startup.skipped
	}

	m := newModel(cfg, prefs, startState)
	m.coordinationList.SetArcs(startupArcs, startupSkipped)

	// Resolve this instance's session-substrate identity. A generated word-pair
	// name is collision-checked against live instances; an explicit
	// LORE_TUI_INSTANCE override that is empty, path-like, or reserved after
	// normalization is a fatal startup error (fail loudly on a bad override).
	if cfg.KnowledgeDir != "" {
		sessionsDir := filepath.Join(cfg.KnowledgeDir, "_sessions")
		name, nameErr := session.GenerateName(sessionsDir, os.Getenv("LORE_TUI_INSTANCE"))
		if nameErr != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", nameErr)
			os.Exit(1)
		}
		m.instanceName = name
		m.sessionsDir = sessionsDir
		m.eventScript = filepath.Join(os.Getenv("HOME"), ".lore/scripts/session-event-append.sh")
		m.expiryScript = filepath.Join(os.Getenv("HOME"), ".lore/scripts/session-request-expire.sh")
		m.spendScript = filepath.Join(os.Getenv("HOME"), ".lore/scripts/session-spend.sh")
		m.instanceStartedISO = time.Now().UTC().Format("2006-01-02T15:04:05Z")
		m.buildSHA, m.buildTime = resolveBuildIdentity()
		m.normalizedProjectDir = config.NormalizeProjectDir(cfg.ProjectDir)

		// D3 host-capability gate: probe tmux once at startup. When absent or
		// opted out, sessions degrade to the direct-PTY path (TUI-lifetime-bound,
		// no crash recovery), announced once via the house degradation pattern.
		var tmuxDetail string
		m.tmuxEnabled, tmuxDetail = work.TmuxAvailable()
		if !m.tmuxEnabled {
			fmt.Fprintf(os.Stderr, "[lore] degraded: tmux hosting off (%s); sessions are TUI-lifetime-bound and will not survive crash/restart\n", tmuxDetail)
		}
	}

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
