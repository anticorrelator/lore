// Package settings: theme.go binds the configurator body's style set to the
// shared presentation primitives in tui/internal/style — the promotion this
// file previously documented as pending is done, and the canonical values
// (with their file:line provenance comments) now live there.
//
// themeStyles survives as a package-private cache so the ~5,700 m.styles.X
// references in model.go/widgets.go keep working; removing the struct itself
// is deferred to the settings redesign that rewrites those files. No literal
// style values for the promoted primitive set remain here — every field is
// initialized from the shared package, so the single-source-of-truth
// property holds either way.
//
// Per the lipgloss-O(n)-allocation rule: the shared values are constructed
// once at package init in tui/internal/style; SettingsModel caches this
// struct as a field at construction time so View() never allocates a style.
package settings

import (
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/style"
)

// themeStyles bundles the body-internal style set used by SettingsModel and
// any sub-panels that render schema-driven content. Each field aliases the
// identically-named shared primitive in tui/internal/style.
type themeStyles struct {
	activeTab   lipgloss.Style
	inactiveTab lipgloss.Style
	keyHint     lipgloss.Style
	separator   lipgloss.Style
	dim         lipgloss.Style

	sevBlocking   lipgloss.Style
	sevSuggestion lipgloss.Style
	sevQuestion   lipgloss.Style

	// Section framing — the "open frame" idiom (header rule + left rail);
	// see the style package for the full rationale. The model's
	// renderSection helper composes these per frame without re-allocating.
	sectionTitle      lipgloss.Style
	sectionRule       lipgloss.Style
	sectionRail       lipgloss.Style
	sectionRailActive lipgloss.Style
	subsectionTitle   lipgloss.Style
}

// newThemeStyles binds the configurator-body style set to the shared
// primitives. Construct ONCE at SettingsModel construction; never inside
// View().
func newThemeStyles() themeStyles {
	return themeStyles{
		activeTab:   style.ActiveTab,
		inactiveTab: style.InactiveTab,
		keyHint:     style.KeyHint,
		separator:   style.Separator,
		dim:         style.Dim,

		sevBlocking:   style.SevBlocking,
		sevSuggestion: style.SevSuggestion,
		sevQuestion:   style.SevQuestion,

		sectionTitle:      style.SectionTitle,
		sectionRule:       style.SectionRule,
		sectionRail:       style.SectionRail,
		sectionRailActive: style.SectionRailActive,
		subsectionTitle:   style.SubsectionTitle,
	}
}
