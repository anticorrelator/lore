// Package style is the dependency-free leaf package owning the TUI's shared
// presentation primitives: the canonical lipgloss styles every surface
// (package main chrome, followup, work, knowledge, search, settlement,
// settings) renders with, plus the single rune-aware Truncate helper.
//
// This is the promotion that tui/internal/settings/theme.go documented as
// pending: the values previously mirrored there (and inlined at the
// provenance call sites noted per style) are now defined exactly once here.
// The original file:line provenance comments are preserved so the lineage of
// each value stays reviewable.
//
// Bounded contract: this package owns ONLY the shared presentation
// primitives — canonical styles (tabs, key hints, separators, dim, severity
// colors, section framing) and Truncate. Widget-local or harness-local
// styles, and unrelated text helpers, do not belong here; adding anything
// else requires its own rationale in a future plan.
//
// Every style is constructed exactly once at package init. Render paths must
// use these package-level values directly (or derive cached copies at model
// construction) — never re-allocate per frame.
package style

import "charm.land/lipgloss/v2"

var (
	// ActiveTab is the highlighted tab pill. Originally inlined at
	// tui/internal/followup/detail.go renderTabBar — Bold + Fg("0") +
	// Bg("4") + Padding(0,1).
	ActiveTab = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("0")).
			Background(lipgloss.Color("4")).
			Padding(0, 1)
	// InactiveTab is the unselected tab pill. Originally inlined at
	// tui/internal/followup/detail.go renderTabBar — Fg("7") + Bg("238") +
	// Padding(0,1).
	InactiveTab = lipgloss.NewStyle().
			Foreground(lipgloss.Color("7")).
			Background(lipgloss.Color("238")).
			Padding(0, 1)
	// KeyHint is the key name in status-bar/modal hint pairs. Originally
	// inlined at tui/view.go renderStatusBar — Fg("7") + Bold.
	KeyHint = lipgloss.NewStyle().
		Foreground(lipgloss.Color("7")).
		Bold(true)
	// Separator is the dim "·" divider between hint pairs. Originally
	// inlined at tui/view.go renderStatusBar — Fg("238").
	Separator = lipgloss.NewStyle().
			Foreground(lipgloss.Color("238"))
	// Dim is the de-emphasized text style. Originally inlined at
	// tui/internal/followup/detail.go renderMetaTab and tui/view.go
	// renderStatusBar — Fg("8").
	Dim = lipgloss.NewStyle().
		Foreground(lipgloss.Color("8"))

	// Severity colors. Originally inlined at
	// tui/internal/followup/lensfindings.go View.
	// SevBlocking — Fg("1") + Bold.
	SevBlocking = lipgloss.NewStyle().
			Foreground(lipgloss.Color("1")).
			Bold(true)
	// SevSuggestion — Fg("3").
	SevSuggestion = lipgloss.NewStyle().
			Foreground(lipgloss.Color("3"))
	// SevQuestion — Fg("8"). Same Fg as Dim by design — followup uses
	// Fg("8") for both contexts. Kept as a distinct named value so a future
	// divergence (e.g. questions get their own color) is a one-line change.
	SevQuestion = lipgloss.NewStyle().
			Foreground(lipgloss.Color("8"))

	// Section framing — the "open frame" idiom: a header rule
	// (╭─ title ────…) plus a left rail (│ ) running down the body.
	// Originally defined in tui/internal/settings/theme.go for the
	// configurator body.
	// SectionTitle: bold colored text for the section name in the header
	// rule — Fg("4") + Bold.
	SectionTitle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("4")).
			Bold(true)
	// SectionRule: the trailing ─── characters filling the header rule —
	// Fg("238"), dim so the rule recedes and the title pops.
	SectionRule = lipgloss.NewStyle().
			Foreground(lipgloss.Color("238"))
	// SectionRail: the left │ character running down a section body —
	// Fg("238") by default.
	SectionRail = lipgloss.NewStyle().
			Foreground(lipgloss.Color("238"))
	// SectionRailActive: the rail variant for the section containing the
	// focused widget — Fg("4") + Bold.
	SectionRailActive = lipgloss.NewStyle().
				Foreground(lipgloss.Color("4")).
				Bold(true)
	// SubsectionTitle: bold light-text for sub-section headers — Fg("7") +
	// Bold. One step down from SectionTitle so nested hierarchy reads at a
	// glance.
	SubsectionTitle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("7")).
			Bold(true)
)

// Truncate clips s to at most maxW visual columns, appending "…" when it
// must cut. It is rune-aware and measures with lipgloss.Width so wide
// characters count correctly. This is the TUI's single truncation
// convention — it consolidates the former per-package copies in
// work/list.go, followup/list.go, knowledge/browser.go, settlement/model.go,
// and tui/view.go.
func Truncate(s string, maxW int) string {
	if maxW <= 0 {
		return ""
	}
	if lipgloss.Width(s) <= maxW {
		return s
	}
	runes := []rune(s)
	if maxW <= 1 {
		return "…"
	}
	for i := len(runes) - 1; i >= 0; i-- {
		candidate := string(runes[:i]) + "…"
		if lipgloss.Width(candidate) <= maxW {
			return candidate
		}
	}
	return "…"
}
