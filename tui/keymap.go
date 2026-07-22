package main

import (
	"strings"

	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/coordination"
	"github.com/anticorrelator/lore/tui/internal/followup"
	"github.com/anticorrelator/lore/tui/internal/settlement"
	"github.com/anticorrelator/lore/tui/internal/style"
)

// This file is the hints-only keymap registry: the single display source for
// the three keybinding surfaces (status bar, help modal, panel border
// annotations). It does NOT own dispatch — key routing stays split across the
// main router (update.go) and the sub-model Update methods. ownerLayers and
// test are audit metadata recording, per entry, which layer handles the key
// and which contract test pins it, so a hint whose handler or test disappears
// is greppable rather than silently dead.

// ownerLayer names the dispatch layer that owns a key's handler.
type ownerLayer int

const (
	// ownerRouter: handled in update.go — the global key switch or the
	// handlePanelRouting seam — before any sub-model sees the key.
	ownerRouter ownerLayer = iota
	// ownerSubModel: reaches the focused sub-model's Update via
	// routeFocusedPanel (or direct delegation for the knowledge browser).
	ownerSubModel
	// ownerModal: consumed by a modal interception block in update.go while
	// that modal is open.
	ownerModal
)

// hintSurface flags which display surfaces show an entry.
type hintSurface uint8

const (
	surfStatusBar hintSurface = 1 << iota
	surfHelp
	surfAnnot
)

// styleRole names the style-token pair an entry renders with.
type styleRole int

const (
	// roleHint: style.KeyHint key + style.Dim label (status bar and help rows).
	roleHint styleRole = iota
	// roleAnnot: annotDimS chrome + style.TitleFilter selected state (border
	// annotations, rendered through annotSpec).
	roleAnnot
)

// keymapEntry is one advertised keybinding.
type keymapEntry struct {
	key      string
	label    string
	surfaces hintSurface
	role     styleRole
	// ownerLayers lists every dispatch layer with a handler for this entry's
	// keys (e.g. "l/Enter" on the lists: l is consumed at the router seam,
	// Enter in the list sub-model).
	ownerLayers []ownerLayer
	// test names the contract test(s) pinning the binding; "" means the pin
	// lives in the owning sub-model's package tests or the row is
	// display-only (e.g. "scroll wheel").
	test string
	// helpKey / helpLabel override key/label in the help modal ("" = same).
	helpKey   string
	helpLabel string
	// labelFn overrides label at render time for state-dependent hints
	// (settlement enable/disable).
	labelFn func(m model) string
	// annot links a surfAnnot entry to the annotation spec the compositor
	// renders into the panel border.
	annot *annotSpec
}

// keymapContext identifies one hint context: an (appState, focus, mode)
// combination or a modal pseudo-state.
type keymapContext int

const (
	kmNone keymapContext = iota
	kmFollowupList
	kmFollowupTriage
	kmFollowupTriageMenu
	kmFollowupComments
	kmFollowupDetail
	kmWorkList
	kmWorkDetail
	kmSessionsList
	kmSessionsDetail
	kmCoordinationList
	// kmCoordinationDetail covers the arc detail's Status/Items/Ledger tabs;
	// kmCoordinationSessions is the Sessions tab, which adds the close verb.
	kmCoordinationDetail
	kmCoordinationSessions
	kmSettlementQueue
	// kmSettlementClaimDetail / kmSettlementVerdictDetail cover the panel's
	// one-level drill-ins (Enter on a queue row / v on the verdict log).
	kmSettlementClaimDetail
	kmSettlementVerdictDetail
	kmKnowledge
	kmTerminal
	// kmSettingsModal is the settings-configurator overlay pseudo-state; its
	// status bar is widget-driven, while this registry entry feeds help.
	kmSettingsModal
	kmOnboarding
	kmOnboardingLoading
	// kmGlobal exists only as a help-modal section for the cross-state keys.
	kmGlobal
)

// keymapSection groups a context's entries; sections with a helpTitle render,
// in registry order, as the help modal's catalog.
type keymapSection struct {
	ctx       keymapContext
	helpTitle string
	entries   []keymapEntry
}

var keymapRegistry = []keymapSection{
	{ctx: kmFollowupList, helpTitle: "Follow-Ups", entries: []keymapEntry{
		{key: "j/k", label: "navigate", surfaces: surfStatusBar | surfHelp, helpKey: "j / k",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestFollowupListStatusBarKeybindContract/j/k (navigate)"},
		{key: "l/Enter", label: "detail", surfaces: surfStatusBar | surfHelp, helpKey: "l / Enter", helpLabel: "open detail / attach session",
			labelFn: func(m model) string {
				if m.terminalMode && m.hasSessionPanel(m.followupList.CurrentID()) {
					return "attach session"
				}
				return "detail"
			},
			ownerLayers: []ownerLayer{ownerRouter, ownerSubModel},
			test:        "TestFollowupListStatusBarKeybindContract/l (detail), …/Enter (detail), TestFollowupListAttachSessionKeybindContract"},
		{key: "A", label: "dismiss", surfaces: surfStatusBar | surfHelp, helpLabel: "dismiss from list",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestFollowupListStatusBarKeybindContract/A (dismiss)"},
		{key: "D", label: "delete", surfaces: surfStatusBar | surfHelp, helpLabel: "delete from list",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestFollowupListStatusBarKeybindContract/D (delete)"},
		{key: "w", label: "work list", surfaces: surfStatusBar | surfHelp,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestFollowupListStatusBarKeybindContract/w (work list)"},
		{key: "v", label: "sessions", surfaces: surfStatusBar | surfHelp, helpLabel: "sessions view",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestSessionsEntryKeybindContract/v (sessions)"},
		{key: "t", label: "settlement", surfaces: surfStatusBar | surfHelp, helpLabel: "settlement panel",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestFollowupListStatusBarKeybindContract/t (settlement)"},
		{key: "ctrl+a", label: "open · closed", surfaces: surfHelp | surfAnnot, role: roleAnnot, helpLabel: "toggle open / closed",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestFollowupListStatusBarKeybindContract/ctrl+a (open · closed)",
			annot: &annotFollowupFilter},
		{key: "Esc", label: "exit", surfaces: surfStatusBar | surfHelp, helpLabel: "exit follow-ups",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestFollowupListStatusBarKeybindContract/Esc (exit)"},
		{key: "?", label: "help", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestHelpModalKeybindContract"},
	}},
	{ctx: kmFollowupTriage, helpTitle: "Triage Tab", entries: []keymapEntry{
		{key: "j/k", label: "navigate", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerSubModel}},
		{key: "space/x/Enter", label: "toggle", surfaces: surfStatusBar | surfHelp, helpKey: "space / x / Enter", helpLabel: "toggle selection",
			ownerLayers: []ownerLayer{ownerSubModel}},
		{key: "a", label: "all", surfaces: surfStatusBar | surfHelp, helpLabel: "select all / deselect all",
			ownerLayers: []ownerLayer{ownerSubModel}},
		{key: "p", label: "promote", surfaces: surfStatusBar | surfHelp, helpLabel: "promote with selected findings",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestPKeyTriggersConfirmModalWithSelectedComments"},
		{key: "Tab/Shift-Tab", label: "cycle tabs", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerSubModel}},
		{key: "h/Esc", label: "back to list", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestFollowupDetailStatusBarKeybindContract/h (back to list)"},
		{key: "?", label: "help", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestHelpModalKeybindContract"},
	}},
	// Transient action menu on the triage tab: status-bar only.
	{ctx: kmFollowupTriageMenu, entries: []keymapEntry{
		{key: "c", label: "chat", surfaces: surfStatusBar, ownerLayers: []ownerLayer{ownerSubModel}},
		{key: "e", label: "edit", surfaces: surfStatusBar, ownerLayers: []ownerLayer{ownerSubModel}},
		{key: "Esc", label: "cancel", surfaces: surfStatusBar, ownerLayers: []ownerLayer{ownerSubModel}},
	}},
	{ctx: kmFollowupComments, helpTitle: "Comments Tab", entries: []keymapEntry{
		{key: "a", label: "all", surfaces: surfStatusBar | surfHelp, helpLabel: "select all / deselect all",
			ownerLayers: []ownerLayer{ownerSubModel}},
		{key: "y", label: "copy", surfaces: surfStatusBar | surfHelp, helpLabel: "copy body to clipboard",
			ownerLayers: []ownerLayer{ownerSubModel}},
		{key: "E", label: "editor", surfaces: surfStatusBar | surfHelp, helpLabel: "edit body in $EDITOR",
			ownerLayers: []ownerLayer{ownerSubModel}},
		{key: "P", label: "post", surfaces: surfStatusBar | surfHelp, helpLabel: "post selected comments to PR",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestPKeyTriggersConfirmModalWithSelectedComments"},
		{key: "g", label: "summarize", surfaces: surfStatusBar | surfHelp, helpLabel: "generate thematic summary (LLM)",
			ownerLayers: []ownerLayer{ownerSubModel}},
		{key: "Tab/Shift-Tab", label: "cycle tabs", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerSubModel}},
		{key: "h/Esc", label: "back to list", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestFollowupDetailStatusBarKeybindContract/h (back to list)"},
		{key: "?", label: "help", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestHelpModalKeybindContract"},
	}},
	{ctx: kmFollowupDetail, helpTitle: "Follow-Up Detail", entries: []keymapEntry{
		{key: "Tab/Shift-Tab", label: "cycle tabs", surfaces: surfStatusBar | surfHelp, helpKey: "Tab / Shift-Tab",
			ownerLayers: []ownerLayer{ownerSubModel}},
		{key: "p", label: "promote", surfaces: surfStatusBar | surfHelp, helpLabel: "promote to work item",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestFollowupDetailStatusBarKeybindContract/p (promote)"},
		{key: "d", label: "dismiss", surfaces: surfStatusBar | surfHelp,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestFollowupDetailStatusBarKeybindContract/d (dismiss)"},
		{key: "c", label: "chat", surfaces: surfStatusBar | surfHelp, helpLabel: "chat about follow-up",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestFollowupDetailStatusBarKeybindContract/c (chat)"},
		{key: "j/k", label: "scroll", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerSubModel}},
		{key: "h/Esc", label: "back to list", surfaces: surfStatusBar | surfHelp, helpKey: "h / Esc",
			ownerLayers: []ownerLayer{ownerRouter},
			test:        "TestFollowupDetailStatusBarKeybindContract/h (back to list), …/Esc (back to list)"},
		{key: "?", label: "help", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestHelpModalKeybindContract"},
	}},
	{ctx: kmWorkList, helpTitle: "Work List", entries: []keymapEntry{
		{key: "j/k", label: "navigate", surfaces: surfStatusBar | surfHelp, helpKey: "j / k",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestWorkListStatusBarKeybindContract/j/k (navigate)"},
		{key: "l/Enter", label: "open", surfaces: surfStatusBar | surfHelp, helpKey: "l / Enter", helpLabel: "open detail / attach session",
			labelFn: func(m model) string {
				if m.terminalMode && m.hasSessionPanel(m.list.CurrentSlug()) {
					return "attach session"
				}
				return "open"
			},
			ownerLayers: []ownerLayer{ownerRouter, ownerSubModel},
			test:        "TestWorkListStatusBarKeybindContract/l (open), …/Enter (open), TestWorkListAttachSessionKeybindContract"},
		{key: "s", label: "spec", surfaces: surfStatusBar | surfHelp, helpLabel: "run spec",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestWorkListStatusBarKeybindContract/s (spec)"},
		{key: "i", label: "implement", surfaces: surfStatusBar | surfHelp, helpLabel: "run implement",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestWorkListStatusBarKeybindContract/i (implement)"},
		{key: "o", label: "coordination", surfaces: surfStatusBar | surfHelp, helpLabel: "coordination view",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestCoordinationEntryKeybindContract/o (coordination)"},
		{key: "a", label: "assign", surfaces: surfHelp, helpLabel: "assign workstream",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestWorkListStatusBarKeybindContract/a (assign workstream)"},
		{key: "N", label: "create with AI", surfaces: surfHelp, helpLabel: "create work items with AI",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestWorkListStatusBarKeybindContract/N (create work items with AI)"},
		{key: "L", label: "toggle layout", surfaces: surfHelp,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestWorkListStatusBarKeybindContract/L (toggle layout)"},
		{key: "A", label: "archive", surfaces: surfHelp, helpLabel: "archive / unarchive",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestWorkListStatusBarKeybindContract/A (archive / unarchive)"},
		{key: "D", label: "delete", surfaces: surfHelp,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestWorkListStatusBarKeybindContract/D (delete)"},
		{key: "ctrl+a", label: "active · archived", surfaces: surfHelp | surfAnnot, role: roleAnnot, helpLabel: "toggle archived",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestWorkListStatusBarKeybindContract/ctrl+a (active · archived)",
			annot: &annotWorkFilter},
		{key: "K", label: "knowledge", surfaces: surfStatusBar | surfHelp, helpLabel: "knowledge browser",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestWorkListStatusBarKeybindContract/K (knowledge)"},
		{key: "f", label: "follow-ups", surfaces: surfStatusBar | surfHelp,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestWorkListStatusBarKeybindContract/f (follow-ups)"},
		{key: "v", label: "sessions", surfaces: surfStatusBar | surfHelp, helpLabel: "sessions view",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestSessionsEntryKeybindContract/v (sessions)"},
		{key: "t", label: "settlement", surfaces: surfStatusBar | surfHelp, helpLabel: "settlement panel",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestWorkListStatusBarKeybindContract/t (settlement)"},
		{key: "S", label: "settings", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestSettingsModalStatusBarKeybindContract/S / Ctrl+, (open)"},
		{key: "q", label: "quit", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestWorkListStatusBarKeybindContract/q (quit)"},
		{key: "?", label: "help", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestHelpModalKeybindContract"},
	}},
	{ctx: kmWorkDetail, helpTitle: "Work Detail", entries: []keymapEntry{
		{key: "s", label: "spec", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestWorkDetailStatusBarKeybindContract/s (spec)"},
		{key: "i", label: "implement", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestWorkDetailStatusBarKeybindContract/i (implement)"},
		{key: "c", label: "chat", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestWorkDetailStatusBarKeybindContract/c (chat)"},
		{key: "R", label: "release", surfaces: surfStatusBar | surfHelp, helpLabel: "release review gate",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestWorkDetailStatusBarKeybindContract/R (release)"},
		{key: "Tab/Shift-Tab", label: "cycle tabs", surfaces: surfStatusBar | surfHelp, helpKey: "Tab / Shift-Tab",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestWorkDetailStatusBarKeybindContract/Tab/Shift-Tab (cycle tabs)"},
		{key: "j/k", label: "scroll", surfaces: surfStatusBar | surfHelp, helpKey: "j / k",
			ownerLayers: []ownerLayer{ownerSubModel}},
		{key: "h/Esc", label: "back to list", surfaces: surfStatusBar | surfHelp, helpKey: "h / Esc",
			ownerLayers: []ownerLayer{ownerRouter},
			test:        "TestWorkDetailStatusBarKeybindContract/h (back to list), …/Esc (back to list)"},
		{key: "?", label: "help", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestHelpModalKeybindContract"},
	}},
	{ctx: kmSessionsList, helpTitle: "Sessions", entries: []keymapEntry{
		{key: "j/k", label: "navigate", surfaces: surfStatusBar | surfHelp, helpKey: "j / k",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestSessionsListStatusBarKeybindContract/j/k (navigate)"},
		{key: "Enter", label: "attach", surfaces: surfStatusBar | surfHelp, helpLabel: "focus / attach session",
			ownerLayers: []ownerLayer{ownerSubModel, ownerRouter}, test: "TestSessionsListStatusBarKeybindContract/Enter (attach)"},
		{key: "x", label: "close", surfaces: surfStatusBar | surfHelp, helpLabel: "request close (confirm)",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestSessionsListStatusBarKeybindContract/x (close)"},
		{key: "o", label: "coordination", surfaces: surfStatusBar | surfHelp, helpLabel: "coordination view",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestCoordinationEntryKeybindContract/o (coordination)"},
		{key: "h/Esc", label: "back", surfaces: surfStatusBar | surfHelp, helpKey: "h / Esc", helpLabel: "back to work",
			ownerLayers: []ownerLayer{ownerRouter},
			test:        "TestSessionsListStatusBarKeybindContract/h (back), …/Esc (back)"},
		{key: "q", label: "quit", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestGlobalQuitKeybindContract"},
		{key: "?", label: "help", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestHelpModalKeybindContract"},
	}},
	// Sessions read-only card (right panel, external/in-flight row): status-bar only.
	{ctx: kmSessionsDetail, entries: []keymapEntry{
		{key: "x", label: "close", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestSessionsDetailStatusBarKeybindContract/x (close)"},
		{key: "h/Esc", label: "back to list", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestSessionsDetailStatusBarKeybindContract/h (back to list)"},
		{key: "?", label: "help", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestHelpModalKeybindContract"},
	}},
	{ctx: kmCoordinationList, helpTitle: "Coordination", entries: []keymapEntry{
		{key: "j/k", label: "navigate", surfaces: surfStatusBar | surfHelp, helpKey: "j / k",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestCoordinationListStatusBarKeybindContract/j/k (navigate)"},
		{key: "l/Enter", label: "detail", surfaces: surfStatusBar | surfHelp, helpKey: "l / Enter", helpLabel: "open arc detail",
			ownerLayers: []ownerLayer{ownerRouter, ownerSubModel},
			test:        "TestCoordinationListStatusBarKeybindContract/l (detail), …/Enter (detail)"},
		{key: "w", label: "work list", surfaces: surfStatusBar | surfHelp,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestCoordinationListStatusBarKeybindContract/w (work list)"},
		{key: "f", label: "follow-ups", surfaces: surfStatusBar | surfHelp,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestCoordinationListStatusBarKeybindContract/f (follow-ups)"},
		{key: "v", label: "sessions", surfaces: surfStatusBar | surfHelp, helpLabel: "sessions view",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestCoordinationListStatusBarKeybindContract/v (sessions)"},
		{key: "t", label: "settlement", surfaces: surfStatusBar | surfHelp, helpLabel: "settlement panel",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestCoordinationListStatusBarKeybindContract/t (settlement)"},
		{key: "h/Esc", label: "back", surfaces: surfStatusBar | surfHelp, helpKey: "h / Esc", helpLabel: "back to work",
			ownerLayers: []ownerLayer{ownerRouter},
			test:        "TestCoordinationListStatusBarKeybindContract/h (back), …/Esc (back)"},
		{key: "q", label: "quit", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestGlobalQuitKeybindContract"},
		{key: "?", label: "help", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestHelpModalKeybindContract"},
	}},
	{ctx: kmCoordinationDetail, helpTitle: "Coordination Detail", entries: []keymapEntry{
		{key: "Tab/Shift-Tab", label: "cycle tabs", surfaces: surfStatusBar | surfHelp, helpKey: "Tab / Shift-Tab",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestCoordinationDetailKeybindContract/Tab (cycle tabs)"},
		{key: "j/k", label: "scroll", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerSubModel}},
		{key: "h/Esc", label: "back to list", surfaces: surfStatusBar | surfHelp, helpKey: "h / Esc",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestCoordinationDetailKeybindContract/h (back to list)"},
		{key: "?", label: "help", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestHelpModalKeybindContract"},
	}},
	// Sessions tab of the coordination detail: j/k walks the arc's sessions
	// and x requests close on the selected one.
	{ctx: kmCoordinationSessions, entries: []keymapEntry{
		{key: "Tab/Shift-Tab", label: "cycle tabs", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestCoordinationDetailKeybindContract/Tab (cycle tabs)"},
		{key: "j/k", label: "sessions", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestCoordinationDetailKeybindContract/j/k (sessions)"},
		{key: "x", label: "close", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestCoordinationDetailKeybindContract/x (close)"},
		{key: "h/Esc", label: "back to list", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestCoordinationDetailKeybindContract/h (back to list)"},
		{key: "?", label: "help", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestHelpModalKeybindContract"},
	}},
	{ctx: kmSettlementQueue, helpTitle: "Settlement", entries: []keymapEntry{
		{key: "j/k", label: "queue", surfaces: surfStatusBar | surfHelp | surfAnnot, helpKey: "j / k", helpLabel: "navigate queue",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestSettlementStatusBarKeybindContract/j/k (queue)",
			annot: &annotSettlementFocus},
		{key: "Enter", label: "claim", surfaces: surfStatusBar | surfHelp, helpLabel: "open claim drill-in",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestSettlementStatusBarKeybindContract/Enter (claim)"},
		{key: "v", label: "verdicts", surfaces: surfStatusBar | surfHelp, helpLabel: "open verdict drill-in",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestSettlementStatusBarKeybindContract/v (verdicts)"},
		{key: "p", label: "pause", surfaces: surfStatusBar | surfHelp, helpLabel: "pause / resume (settlement.enabled)",
			labelFn: func(m model) string {
				if m.settlement.Status().Enabled {
					return "pause"
				}
				return "resume"
			},
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestSettlementPostureKeybindContract/p (pause), …/p (resume)"},
		{key: "s", label: "schedule", surfaces: surfStatusBar | surfHelp, helpLabel: "toggle active-hours schedule",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestSettlementPostureKeybindContract/s (schedule)"},
		{key: "m", label: "model tier", surfaces: surfStatusBar | surfHelp, helpLabel: "cycle auditor model tier",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestSettlementPostureKeybindContract/m (model tier), …/m (no tiers)"},
		{key: "x", label: "process once", surfaces: surfStatusBar | surfHelp, helpLabel: "process one batch",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestSettlementPostureKeybindContract/x (process once)"},
		{key: "S", label: "settings", surfaces: surfStatusBar | surfHelp, helpLabel: "settings modal at settlement",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestSettlementStatusBarKeybindContract/S (settings)"},
		{key: "w", label: "work", surfaces: surfStatusBar | surfHelp,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestSettlementStatusBarKeybindContract/w (work)"},
		{key: "f", label: "follow-ups", surfaces: surfStatusBar | surfHelp,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestSettlementStatusBarKeybindContract/f (follow-ups)"},
		{key: "o", label: "coordination", surfaces: surfStatusBar | surfHelp, helpLabel: "coordination view",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestCoordinationEntryKeybindContract/o (coordination)"},
		{key: "?", label: "help", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestSettlementStatusBarKeybindContract/? (help)"},
	}},
	{ctx: kmSettlementClaimDetail, helpTitle: "Settlement Claim", entries: []keymapEntry{
		{key: "j/k", label: "next/prev claim", surfaces: surfStatusBar | surfHelp | surfAnnot, helpKey: "j / k",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestSettlementClaimDrillInKeybindContract/j/k (next/prev claim)",
			annot: &annotSettlementFocus},
		{key: "Esc", label: "back", surfaces: surfStatusBar | surfHelp, helpLabel: "back to queue",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestSettlementClaimDrillInKeybindContract/Esc (back)"},
		{key: "?", label: "help", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestHelpModalKeybindContract"},
	}},
	{ctx: kmSettlementVerdictDetail, helpTitle: "Settlement Verdict", entries: []keymapEntry{
		{key: "j/k", label: "next/prev verdict", surfaces: surfStatusBar | surfHelp | surfAnnot, helpKey: "j / k",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestSettlementVerdictDrillInKeybindContract/j/k (next/prev verdict)",
			annot: &annotSettlementFocus},
		{key: "Esc", label: "back", surfaces: surfStatusBar | surfHelp, helpLabel: "back to queue",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestSettlementVerdictDrillInKeybindContract/Esc (back)"},
		{key: "?", label: "help", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestHelpModalKeybindContract"},
	}},
	{ctx: kmKnowledge, helpTitle: "Knowledge Browser", entries: []keymapEntry{
		{key: "j/k", label: "navigate", surfaces: surfStatusBar | surfHelp, helpKey: "j / k",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestBrowserJKNavigateTree"},
		{key: "l/Enter", label: "detail", surfaces: surfStatusBar | surfHelp, helpKey: "l / Enter", helpLabel: "open entry / toggle fold",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestBrowserEnterOnCategoryTogglesFold"},
		{key: "h/Esc", label: "tree", surfaces: surfStatusBar | surfHelp, helpKey: "h / Esc", helpLabel: "back to tree",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestBrowserHEscRefocusTree"},
		{key: "/", label: "search", surfaces: surfStatusBar | surfHelp,
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestKnowledgeGlobalKeybindContract/q (typed into active search, no quit)"},
		{key: "Esc", label: "exit", surfaces: surfStatusBar | surfHelp, helpLabel: "exit browser",
			ownerLayers: []ownerLayer{ownerSubModel}},
		{key: "?", label: "help", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestHelpModalKeybindContract"},
	}},
	{ctx: kmTerminal, helpTitle: "Session Panel (terminal mode)", entries: []keymapEntry{
		{key: "scroll wheel", label: "scroll output", surfaces: surfHelp,
			ownerLayers: []ownerLayer{ownerSubModel}},
		{key: "Shift+PgUp/PgDn", label: "scrollback", surfaces: surfHelp, helpKey: "Shift+PgUp / PgDn", helpLabel: "scroll output history",
			ownerLayers: []ownerLayer{ownerSubModel},
			test:        "TestTerminalScrollbackKeybindContract/Shift+PgUp (scrollback), …/Shift+PgDn (scrollback)"},
		{key: "Shift+Home/End", label: "history top / live", surfaces: surfHelp, helpKey: "Shift+Home / End", helpLabel: "jump to history top / live view",
			ownerLayers: []ownerLayer{ownerSubModel},
			test:        "TestTerminalScrollbackKeybindContract/Shift+Home (history top), …/Shift+End (live)"},
		{key: "ctrl+t", label: "detail", surfaces: surfStatusBar | surfHelp | surfAnnot, role: roleAnnot, helpLabel: "switch to detail view",
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestTerminalModeStatusBarKeybindContract/ctrl+t (detail)"},
		{key: "Esc", label: "forward to subprocess (e.g. interrupt)", surfaces: surfHelp,
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestTerminalModeStatusBarKeybindContract/Esc (forwarded to subprocess, focus kept)"},
		{key: "Esc", label: "back to list", surfaces: surfStatusBar | surfHelp, helpKey: "Esc Esc", helpLabel: "detach focus, back to list",
			ownerLayers: []ownerLayer{ownerSubModel}, test: "TestTerminalDetachKeepsTerminalView"},
		{key: "Ctrl+c", label: "terminate", surfaces: surfStatusBar | surfHelp, helpLabel: "terminate subprocess (discard when finished)",
			labelFn: func(m model) string {
				panel, ok := m.currentSessionPanel()
				switch m.state {
				case stateFollowUps:
					panel, ok = m.currentFollowupPanel()
				case stateSessions:
					panel, ok = m.currentSessionsPanel()
				}
				if ok && panel.IsDone() {
					return "discard"
				}
				return "terminate"
			},
			ownerLayers: []ownerLayer{ownerRouter},
			test:        "TestTerminalModeStatusBarKeybindContract/Ctrl+c (terminate), …/Ctrl+c (discard)"},
		{key: "Ctrl+\\", label: "terminate subprocess", surfaces: surfHelp,
			ownerLayers: []ownerLayer{ownerSubModel}},
		{key: "(all other keys)", label: "forwarded to subprocess", surfaces: surfHelp,
			ownerLayers: []ownerLayer{ownerSubModel}},
	}},
	{ctx: kmSettingsModal, helpTitle: "Settings", entries: []keymapEntry{
		{key: "j/k / ↕", label: "move", surfaces: surfHelp,
			ownerLayers: []ownerLayer{ownerModal}, test: "TestSettingsModalStatusBarKeybindContract/j/k (move), TestSettingsModalStatusBarModeHints"},
		{key: "Enter", label: "open / edit", surfaces: surfHelp,
			ownerLayers: []ownerLayer{ownerModal}, test: "TestSettingsModalStatusBarModeHints"},
		{key: "h/l", label: "select option", surfaces: surfHelp,
			ownerLayers: []ownerLayer{ownerModal}},
		{key: "a/e/d", label: "edit collections", surfaces: surfHelp,
			ownerLayers: []ownerLayer{ownerModal}},
		{key: "u", label: "unset", surfaces: surfHelp,
			ownerLayers: []ownerLayer{ownerModal}},
		{key: "U", label: "undo last change", surfaces: surfHelp,
			ownerLayers: []ownerLayer{ownerModal}},
		{key: "Esc", label: "cancel / back / close", surfaces: surfHelp,
			ownerLayers: []ownerLayer{ownerModal}, test: "TestSettingsModalStatusBarKeybindContract/Esc (close), TestSettingsModalStatusBarModeHints"},
		{key: "PgUp/PgDn", label: "scroll", surfaces: surfHelp,
			ownerLayers: []ownerLayer{ownerModal}, test: "TestSettingsModalStatusBarKeybindContract/PgDn (scroll)"},
	}},
	{ctx: kmOnboarding, entries: []keymapEntry{
		{key: "Enter", label: "initialize", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestStateOnboardingEnterDispatchesInit"},
		{key: "q", label: "quit", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestOnboardingStatusBarKeybindContract/q (quit)"},
	}},
	{ctx: kmOnboardingLoading, entries: []keymapEntry{
		{key: "", label: "Initializing...", surfaces: surfStatusBar,
			ownerLayers: []ownerLayer{ownerRouter}},
	}},
	{ctx: kmGlobal, helpTitle: "Global", entries: []keymapEntry{
		{key: "?", label: "this help", surfaces: surfHelp,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestHelpModalKeybindContract"},
		{key: "t", label: "settlement panel", surfaces: surfHelp,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestSettlementRootNavigationFromListViews"},
		{key: "S / Ctrl+,", label: "settings configurator", surfaces: surfHelp,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestSettingsModalStatusBarKeybindContract/S / Ctrl+, (open)"},
		{key: "q / Ctrl+C / Ctrl+D", label: "quit", surfaces: surfHelp,
			ownerLayers: []ownerLayer{ownerRouter}, test: "TestGlobalQuitKeybindContract"},
	}},
}

// keymapByContext indexes the registry for status-bar lookup.
var keymapByContext = func() map[keymapContext][]keymapEntry {
	idx := make(map[keymapContext][]keymapEntry, len(keymapRegistry))
	for _, sec := range keymapRegistry {
		idx[sec.ctx] = sec.entries
	}
	return idx
}()

func keymapEntries(ctx keymapContext) []keymapEntry {
	return keymapByContext[ctx]
}

// keymapContext resolves the model's current hint context. The settings
// configurator pseudo-state is handled outside this state lookup so its modal
// can render widget-driven status hints while the registry still feeds help.
func (m model) keymapContext() keymapContext {
	switch m.state {
	case stateOnboarding:
		if m.initLoading {
			return kmOnboardingLoading
		}
		return kmOnboarding
	case stateWork:
		switch {
		case m.focusedPanel == panelLeft:
			return kmWorkList
		case m.terminalMode:
			return kmTerminal
		default:
			return kmWorkDetail
		}
	case stateSessions:
		switch {
		case m.focusedPanel == panelLeft:
			return kmSessionsList
		case m.terminalMode:
			return kmTerminal
		default:
			return kmSessionsDetail
		}
	case stateCoordination:
		switch {
		case m.focusedPanel == panelLeft:
			return kmCoordinationList
		case m.coordinationDetail.ActiveTabID() == coordination.TabSessions:
			return kmCoordinationSessions
		default:
			return kmCoordinationDetail
		}
	case stateKnowledge:
		return kmKnowledge
	case stateSettlement:
		switch m.settlement.Drill() {
		case settlement.DrillClaim:
			return kmSettlementClaimDetail
		case settlement.DrillVerdict:
			return kmSettlementVerdictDetail
		}
		return kmSettlementQueue
	case stateFollowUps:
		switch {
		case m.focusedPanel == panelLeft:
			return kmFollowupList
		case m.terminalMode:
			return kmTerminal
		case m.followupDetail.ActiveTab() == followup.TabTriage && m.followupDetail.ActionMenuOpen():
			return kmFollowupTriageMenu
		case m.followupDetail.ActiveTab() == followup.TabTriage:
			return kmFollowupTriage
		case m.followupDetail.ActiveTab() == followup.TabComments:
			return kmFollowupComments
		default:
			return kmFollowupDetail
		}
	}
	return kmNone
}

// statusBarHints renders the status-bar projection of a context: one
// "key label" pair per surfStatusBar entry, in registry order.
func (m model) statusBarHints(ctx keymapContext) []string {
	keyS := style.KeyHint
	dimS := style.Dim
	var hints []string
	for _, e := range keymapEntries(ctx) {
		if e.surfaces&surfStatusBar == 0 {
			continue
		}
		label := e.label
		if e.labelFn != nil {
			label = e.labelFn(m)
		}
		if e.key == "" {
			hints = append(hints, dimS.Render(label))
			continue
		}
		hints = append(hints, keyS.Render(e.key)+" "+dimS.Render(label))
	}
	return hints
}

// annotSpec is the border-annotation form of a registry entry: a key plus the
// states it switches between, rendered as "key  state · state" with the
// selected state highlighted.
type annotSpec struct {
	key    string
	states []string
}

// Annotation specs referenced by registry entries and the compositor.
var (
	annotWorkFilter     = annotSpec{key: "ctrl+a", states: []string{"active", "archived"}}
	annotFollowupFilter = annotSpec{key: "ctrl+a", states: []string{"open", "closed"}}
	// annotSettlementFocus tracks what j/k walks: the queue at the root, or
	// claims/verdicts inside the panel's drill-ins.
	annotSettlementFocus = annotSpec{key: "j/k", states: []string{"queue", "claim", "verdict"}}
)

// annotPanelMode is the right-panel detail/terminal mode annotation; the
// terminal state label doubles as the session-lifecycle badge. A finished
// subprocess reads "terminal (done)"; a close-requested session held open (the
// initiator-gated hold) reads "terminal (done ✓)" — protocol-complete, but the
// harness is still live and readable — distinct from a process that has exited.
func annotPanelMode(done, closeRequested bool) annotSpec {
	term := "terminal"
	switch {
	case done:
		term = "terminal (done)"
	case closeRequested:
		term = "terminal (done ✓)"
	}
	return annotSpec{key: "ctrl+t", states: []string{"detail", term}}
}

// render returns the pre-rendered annotation and its visual width for
// renderBorderTitleWithAnnot, showing every state with the selected one
// highlighted.
func (a annotSpec) render(selected int) (string, int) {
	var b strings.Builder
	b.WriteString(annotDimS.Render(a.key + "  "))
	for i, s := range a.states {
		if i > 0 {
			b.WriteString(annotDimS.Render(" · "))
		}
		if i == selected {
			b.WriteString(style.TitleFilter.Render(s))
		} else {
			b.WriteString(annotDimS.Render(s))
		}
	}
	out := b.String()
	return out, lipgloss.Width(out)
}

// renderSelected is the compact variant showing only the selected state
// (settlement's "j/k  queue" / "j/k  settings" border annotation).
func (a annotSpec) renderSelected(selected int) (string, int) {
	out := annotDimS.Render(a.key+"  ") + style.TitleFilter.Render(a.states[selected])
	return out, lipgloss.Width(out)
}
