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
// primitives — the named palette roles, the single border vocabulary,
// canonical styles (tabs, key hints, separators, dim, severity colors,
// status colors, border-title parts, section framing), spacing constants,
// and Truncate. Widget-local or harness-local styles, and unrelated text
// helpers, do not belong here; adding anything else requires its own
// rationale in a future plan.
//
// Every style is constructed exactly once at package init. Render paths must
// use these package-level values directly (or derive cached copies at model
// construction) — never re-allocate per frame.
package style

import "charm.land/lipgloss/v2"

// Palette roles. Every shared color is reached through a named semantic
// role, never a raw index at the call site. Values are 256-color indices so
// the terminal's own palette supplies the actual hues — the terminal theme
// is the theme. Role names follow the helix theme-key / k9s skin-key
// precedent noted per role.
var (
	// ColorAccent: focus, active fill, highlights (k9s
	// frame.border.focusColor). Also absorbs the former bright-blue "12"
	// markdown-heading uses.
	ColorAccent = lipgloss.Color("4")
	// ColorChrome: inactive borders, rules, separators (k9s
	// frame.border.fgColor). Absorbs the former "240" separator dim — one
	// chrome role, one text-dim role.
	ColorChrome = lipgloss.Color("238")
	// ColorDim: de-emphasized text (helix ui.text.inactive).
	ColorDim = lipgloss.Color("8")
	// ColorText: primary key/label text (helix ui.text).
	ColorText = lipgloss.Color("7")
	// ColorTextBright: bright/active text, one tier above ColorText (helix
	// ui.text.focus).
	ColorTextBright = lipgloss.Color("252")
	// ColorOnAccent: text rendered on an accent-filled background (k9s
	// views.table.header.fgColor).
	ColorOnAccent = lipgloss.Color("0")
	// ColorSelectionBg: selected-row background (k9s
	// views.table.cursorColor).
	ColorSelectionBg = lipgloss.Color("237")
	// ColorMetaKey: metadata keys, subdirectory prefixes (k9s
	// views.yaml.keyColor).
	ColorMetaKey = lipgloss.Color("6")
	// ColorCategory: category labels (helix ui.text.directory).
	ColorCategory = lipgloss.Color("5")
	// ColorSuccess: ready/enabled/success green (k9s frame.status.addColor).
	ColorSuccess = lipgloss.Color("2")
	// ColorWarn: warnings and suggestions (helix diagnostic.warning).
	ColorWarn = lipgloss.Color("3")
	// ColorDanger: destructive or blocking red (helix diagnostic.error).
	ColorDanger = lipgloss.Color("1")
	// ColorAttention: needs-a-human orange (k9s
	// frame.status.highlightcolor). Disambiguation rule: ColorAccent marks
	// active *machinery* (focused chrome AND in-progress processes — safe to
	// share because focus renders on borders/titles while progress renders
	// on row text); ColorAttention is reserved for the scarcer signal that a
	// running process is blocked on the user (e.g. needsInputStyle in
	// work/list.go). Do not spend it on ordinary in-progress states or the
	// attention pop is lost.
	ColorAttention = lipgloss.Color("214")
	// ColorMerged: GitHub's merged-purple for PR badges. Deliberately its
	// own role rather than ColorCategory (same index by coincidence): merged
	// is a status association users carry over from GitHub, and StatusDone
	// (dim) would make merged PRs read like the "--" no-PR placeholder.
	ColorMerged = lipgloss.Color("5")
	// ColorCode: inline code spans (helix markup.raw). Distinct from
	// ColorWarn — syntax vs semantics, adjacent hues by coincidence.
	ColorCode = lipgloss.Color("11")
)

// DockBorder is the ONE structural border shape for all panels AND modals.
// Focus and docked-vs-floating are signaled by border color (BorderFocused
// vs BorderBlur), never by switching corner geometry. Nested inputs inside
// modals keep this same shape and recede via a dim (ColorChrome) border.
// Centralizing the shape here makes a future shape change a one-line edit.
var DockBorder = lipgloss.RoundedBorder()

var (
	// BorderFocused: the focused-panel border — DockBorder drawn in
	// ColorAccent.
	BorderFocused = lipgloss.NewStyle().
			BorderStyle(DockBorder).
			BorderForeground(ColorAccent)
	// BorderBlur: the unfocused-panel (and nested-input) border —
	// DockBorder drawn in ColorChrome so it recedes.
	BorderBlur = lipgloss.NewStyle().
			BorderStyle(DockBorder).
			BorderForeground(ColorChrome)

	// Border-title parts (k9s frame.title.*). Titles are composed from
	// separately styled parts — name, count, filter annotation — rather
	// than one prose run.
	// TitleName: the panel name (frame.title.fgColor).
	TitleName = lipgloss.NewStyle().
			Foreground(ColorText).
			Bold(true)
	// TitleCount: the item-count annotation (frame.title.counterColor).
	TitleCount = lipgloss.NewStyle().
			Foreground(ColorChrome)
	// TitleFilter: the filter-state annotation (frame.title.filterColor).
	TitleFilter = lipgloss.NewStyle().
			Foreground(ColorAccent)

	// Status ramp (k9s frame.status.*). State is a color channel applied
	// wherever the state renders — glyph, label, and body alike.
	// StatusReady: ready / enabled / open.
	StatusReady = lipgloss.NewStyle().
			Foreground(ColorSuccess)
	// StatusActive: active / in-progress. Shares ColorAccent with focus
	// chrome by design — see the disambiguation rule on ColorAttention. An
	// in-progress item that additionally needs the user is the only state
	// that earns ColorAttention.
	StatusActive = lipgloss.NewStyle().
			Foreground(ColorAccent)
	// StatusWarn: needs attention.
	StatusWarn = lipgloss.NewStyle().
			Foreground(ColorWarn)
	// StatusError: blocked / closed / error.
	StatusError = lipgloss.NewStyle().
			Foreground(ColorDanger)
	// StatusDone: completed — dim, upright.
	StatusDone = lipgloss.NewStyle().
			Foreground(ColorDim)
	// StatusDisabled: disabled or default-unset — dim AND italic, so
	// "default" placeholders never read as merely completed.
	StatusDisabled = lipgloss.NewStyle().
			Foreground(ColorDim).
			Italic(true)
)

// Spacing values. These are values, not layout — responsive column logic
// belongs to list components, not this package.
const (
	// PadTabH is the horizontal cell padding for tab pills (matches
	// ActiveTab/InactiveTab Padding(0, 1)).
	PadTabH = 1
	// GutterH is the single-column gutter between panes and columns.
	GutterH = 1
	// RowLead is the leading column width before a list row's first cell
	// (the selection-marker width).
	RowLead = 1
)

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
