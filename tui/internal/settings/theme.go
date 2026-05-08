// Package settings: theme.go pins the lipgloss style values the configurator
// modal body uses, mirroring the canonical values currently inlined in
// tui/internal/followup/detail.go and tui/view.go.
//
// Per D3 of the work item plan: chrome (border, modal box, status bar) is
// reused from the host (package main) via the body-vs-chrome split (D2);
// body-internal styles are NOT yet promoted to a shared package, so this
// file duplicates them as named constants with file:line provenance comments.
// Any future drift between this file and the followup-source-of-truth is a
// review-visible divergence rather than a silent rendering inconsistency.
//
// Per D3's lipgloss-O(n)-allocation note: every style is constructed exactly
// once at package init via newThemeStyles(); SettingsModel caches the returned
// struct as a field at construction time so View() never allocates a style.
package settings

import "github.com/charmbracelet/lipgloss"

// themeStyles bundles the body-internal style set used by SettingsModel and
// any sub-panels that render schema-driven content. Each field's source-of-
// truth file:line is documented at construction (newThemeStyles).
type themeStyles struct {
	// activeTab matches the active tab style in
	// tui/internal/followup/detail.go:864-873.
	activeTab lipgloss.Style
	// inactiveTab matches the inactive tab style in
	// tui/internal/followup/detail.go:864-873.
	inactiveTab lipgloss.Style
	// keyHint matches the key-hint style in tui/view.go:464-470 (renderStatusBar).
	keyHint lipgloss.Style
	// separator matches the status-bar separator style in tui/view.go:464-470.
	separator lipgloss.Style
	// dim matches the dim/inherited style in
	// tui/internal/followup/detail.go:810 (renderMetaTab) — also used in
	// tui/view.go:465 for the status-bar dim style. Same Fg("8").
	dim lipgloss.Style
	// sevBlocking matches the blocking-severity style in
	// tui/internal/followup/lensfindings.go:266 (Fg("1")+Bold).
	sevBlocking lipgloss.Style
	// sevSuggestion matches the suggestion-severity style in
	// tui/internal/followup/lensfindings.go:267 (Fg("3")).
	sevSuggestion lipgloss.Style
	// sevQuestion matches the question-severity style in
	// tui/internal/followup/lensfindings.go:268 (Fg("8")). Note: same Fg as
	// dim by design — followup uses Fg("8") for both contexts. Kept as a
	// distinct named field so a future divergence (e.g., questions get a
	// different color) is a single-line change here.
	sevQuestion lipgloss.Style

	// Section framing — added per the codex configurator-readability consult.
	// The configurator renders each major section as an "open frame": a header
	// rule (╭─ title ────...) plus a left rail (│ ) running down the body. The
	// idiom replaces the inverted activeTab pill (which read like tab
	// navigation, not a section header) and gives the eye hard reset points
	// without the horizontal-budget cost of full lipgloss.Border boxes.
	//
	// sectionTitle: bold colored text for the section name in the header rule.
	// Same Fg as PrimaryRadio's activeStyle so committed-current and section-
	// header colors align ("primary harness" reads at the same intensity as
	// "(•) codex" inside it). Allocate-once per D3.
	sectionTitle lipgloss.Style
	// sectionRule: the trailing ─── horizontal characters that fill out the
	// header rule to the body width. Dim (Fg 238) so the rule recedes and the
	// title pops.
	sectionRule lipgloss.Style
	// sectionRail: the left │ character running down the section body. Dim by
	// default; when the section contains the focused widget, the model swaps
	// to sectionRailActive so the user can see at a glance which section their
	// keystrokes will affect.
	sectionRail       lipgloss.Style
	sectionRailActive lipgloss.Style
	// subsectionTitle: bold light-text for sub-section headers inside a
	// section's body (e.g., capture > core / structural_signals). One step
	// down from sectionTitle so nested hierarchy reads at a glance without
	// the visual noise of nested frames.
	subsectionTitle lipgloss.Style
}

// newThemeStyles allocates the configurator-body style set. Construct ONCE
// at SettingsModel construction; never inside View() per the lipgloss
// O(n)-per-frame gotcha. Values are exact-match against the followup-source-
// of-truth call sites — the per-field comments on themeStyles record the
// originating file:line.
func newThemeStyles() themeStyles {
	return themeStyles{
		// tui/internal/followup/detail.go:864-868 — Bold + Fg("0") + Bg("4") + Padding(0,1)
		activeTab: lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("0")).
			Background(lipgloss.Color("4")).
			Padding(0, 1),
		// tui/internal/followup/detail.go:870-873 — Fg("7") + Bg("238") + Padding(0,1)
		inactiveTab: lipgloss.NewStyle().
			Foreground(lipgloss.Color("7")).
			Background(lipgloss.Color("238")).
			Padding(0, 1),
		// tui/view.go:466 — Fg("7") + Bold
		keyHint: lipgloss.NewStyle().
			Foreground(lipgloss.Color("7")).
			Bold(true),
		// tui/view.go:467 — Fg("238")
		separator: lipgloss.NewStyle().
			Foreground(lipgloss.Color("238")),
		// tui/internal/followup/detail.go:810 (and tui/view.go:465) — Fg("8")
		dim: lipgloss.NewStyle().
			Foreground(lipgloss.Color("8")),
		// tui/internal/followup/lensfindings.go:266 — Fg("1") + Bold
		sevBlocking: lipgloss.NewStyle().
			Foreground(lipgloss.Color("1")).
			Bold(true),
		// tui/internal/followup/lensfindings.go:267 — Fg("3")
		sevSuggestion: lipgloss.NewStyle().
			Foreground(lipgloss.Color("3")),
		// tui/internal/followup/lensfindings.go:268 — Fg("8")
		sevQuestion: lipgloss.NewStyle().
			Foreground(lipgloss.Color("8")),

		// Section framing styles — see field comments on themeStyles for the
		// rationale. Constructed once here per D3; the model's renderSection
		// helper composes them per frame without re-allocating.
		sectionTitle: lipgloss.NewStyle().
			Foreground(lipgloss.Color("4")).
			Bold(true),
		sectionRule: lipgloss.NewStyle().
			Foreground(lipgloss.Color("238")),
		sectionRail: lipgloss.NewStyle().
			Foreground(lipgloss.Color("238")),
		sectionRailActive: lipgloss.NewStyle().
			Foreground(lipgloss.Color("4")).
			Bold(true),
		subsectionTitle: lipgloss.NewStyle().
			Foreground(lipgloss.Color("7")).
			Bold(true),
	}
}
