package main

// Compatibility capture for the side-by-side disposition decision: composes
// the accepted work-list treatment (grouped rollup headers) and the accepted
// detail treatment (digest tab) in the left-right layout, as evidence of how
// the winners behave in the fixed 40-column left panel. Untracked prototype
// file; delete freely after the judgment record lands.
//
// Run: LORE_MOCKUP_DUMP=1 go test -run TestMockupDumpCompatSideBySide -v

import (
	"testing"

	"github.com/anticorrelator/lore/tui/internal/config"
)

func TestMockupDumpCompatSideBySide(t *testing.T) {
	requireMockupDump(t)

	dumpMockup(t, "compat-sidebyside-winners", func(t *testing.T) string {
		m := newMockupModel(t, stateWork, config.LayoutLeftRight,
			mockupWidth, mockupHeight, axisAWorkItems(), mockupFollowupItems())
		m = withPRStatuses(m, axisAPRStatuses())
		m = withWorkDetail(t, m, axisBRichDetail())

		// Axis A winner: rollup grouped rows at side-by-side list dims
		// (fixed 40-col left panel, below the stacked threshold).
		width, height := m.listDims()
		rollups := make(map[string]string)
		rows := axisAGroupedRows(axisAWorkItems(), map[string]bool{}, rollups)
		cl := axisAList(axisAColumns(), rows, width, height, "settlement-verdict-drill-in")
		cl.SetDecorator(axisARollupDecorator(width, rollups))

		cfg := m.buildPaneConfig()
		cfg.listView = cl.View()
		// Axis B winner: digest tab body at the side-by-side right panel width.
		cfg.detailView = axisBDigestTabBody(axisBRichDetail(), m.rightPanelWidth())
		return m.viewSideBySide(cfg)
	})
}
