package board

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/mattn/go-runewidth"
)

const goldenWidth = 120

func row(id, label string, dependencies []string, status, tree string) Row {
	return Row{
		Arc: "fixture", StreamID: id, Label: label, DependsOn: dependencies,
		Status: status, Tree: tree, Gate: "notify", Verdict: "—",
	}
}

var renderFixtures = map[string][]Row{
	"real": {
		row("1", "fix session-start delivery race", nil, "done", "writer"),
		row("2", "capture settlement experiment", nil, "done", "writer"),
		row("6", "capture hardening: sibling-store refusal", nil, "done", "writer"),
		row("3", "/spec full: orientation rewrite", []string{"2"}, "done", "writer"),
		row("7", "implement rewrite; STOP at owner gate", []string{"3"}, "in-flight", "writer"),
		row("8", "age-gate transient modal wakes", nil, "done", "writer"),
		row("4", "vocabulary sweep: courtroom register", []string{"3"}, "pending", "writer"),
		row("5", "protocol-layer sorting", []string{"3"}, "pending", "read-only"),
	},
	"minimal": {
		row("S1", "spec auth", nil, "done", "writer"),
		func() Row {
			r := row("S2", "impl auth", []string{"S1"}, "blocked-on-input", "writer")
			r.Gate = "hold"
			return r
		}(),
		func() Row {
			r := row("S3", "integrate", []string{"S1", "S2"}, "pending", "writer")
			r.Gate, r.Verdict = "flag", "full"
			return r
		}(),
	},
	"adversarial": {
		row("a", "schema", nil, "done", "writer"),
		row("b", "left leg", []string{"a"}, "in-flight", "writer"),
		row("c", "right leg", []string{"a"}, "blocked-on:b", "writer"),
		row("d", "diamond join", []string{"b", "c"}, "pending", "writer"),
		row("e", "refers to ghost", []string{"zz"}, "pending", "writer"),
		row("f", "abandoned path", []string{"a"}, "dropped", "writer"),
		row("g", "novel status", nil, "parked-for-review", "read-only"),
		row("x", "cycle one", []string{"y"}, "pending", "writer"),
		row("y", "cycle two", []string{"x"}, "pending", "writer"),
	},
	"wide": {
		row("root", "walking skeleton", nil, "done", "writer"),
		row("w1", "worker one", []string{"root"}, "done", "writer"),
		row("w2", "worker two", []string{"root"}, "in-flight", "writer"),
		row("w3", "worker three", []string{"root"}, "in-flight", "writer"),
		row("w4", "worker four", []string{"root"}, "pending", "writer"),
		row("w5", "worker five", []string{"root"}, "blocked-on-input", "writer"),
		row("join", "assemble + verify", []string{"w1", "w2", "w3", "w4", "w5"}, "pending", "writer"),
	},
	"root_lane_reuse": {
		row("a", "first root", nil, "done", "writer"),
		row("b", "child ends its rail", []string{"a"}, "done", "writer"),
		row("c", "next root", nil, "pending", "writer"),
	},
	"wrapped": {
		row("long", "capture protocol evolution guidance without truncating any part of the authored step description even when it needs a continuation line", nil, "in-flight", "writer"),
	},
}

func TestRenderGoldenFixtures(t *testing.T) {
	for _, name := range []string{"real", "minimal", "adversarial", "wide", "root_lane_reuse", "wrapped"} {
		t.Run(name, func(t *testing.T) {
			got := strings.Join(Render(renderFixtures[name], goldenWidth), "\n") + "\n"
			path := filepath.Join("testdata", name+".golden")
			want, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if got != string(want) {
				t.Errorf("render differs from %s\ngot:\n%s\nwant:\n%s", path, got, want)
			}
		})
	}
}

func TestRenderIsPureAndWidthBounded(t *testing.T) {
	rows := renderFixtures["adversarial"]
	first := Render(rows, 72)
	second := Render(rows, 72)
	if !reflect.DeepEqual(first, second) {
		t.Fatalf("same input rendered differently:\n%q\n%q", first, second)
	}
	for _, line := range first {
		if got := runewidth.StringWidth(line); got > 72 {
			t.Errorf("line is %d cells wide, want <= 72: %q", got, line)
		}
	}
	for width := 1; width <= 40; width++ {
		for _, line := range Render(rows, width) {
			if got := runewidth.StringWidth(line); got > width {
				t.Errorf("width %d produced %d cells: %q", width, got, line)
			}
		}
	}
}

func TestRootDoesNotReuseLaneFreedOnPreviousRow(t *testing.T) {
	lines := Render(renderFixtures["root_lane_reuse"], goldenWidth)
	if len(lines) != 3 || !strings.HasPrefix(lines[2], "   ○") {
		t.Fatalf("next root must move off the just-freed first lane:\n%s", strings.Join(lines, "\n"))
	}
}

func TestZeroWidthReturnsOneEmptyCellPerRow(t *testing.T) {
	got := Render(renderFixtures["minimal"], 0)
	if !reflect.DeepEqual(got, []string{"", "", ""}) {
		t.Fatalf("zero-width render = %q", got)
	}
}

func TestRenderRowsPairsTopologicalTextWithIdentity(t *testing.T) {
	rows := []Row{
		row("child", "declared first", []string{"root"}, "pending", "writer"),
		row("root", "declared second", nil, "done", "writer"),
	}
	rendered := RenderRows(rows, goldenWidth, 0)
	if len(rendered) != 2 || rendered[0].StreamID != "root" || rendered[1].StreamID != "child" {
		t.Fatalf("render identities do not follow topological lines: %+v", rendered)
	}
	lines := Render(rows, goldenWidth)
	if rendered[0].Lines[0].Text != lines[0] || rendered[1].Lines[0].Text != lines[1] {
		t.Fatalf("identity and text render paths drifted: %+v != %q", rendered, lines)
	}
}

func TestOverflowingDescriptionRemainsOnePhysicalNavigationRow(t *testing.T) {
	rendered := RenderRows(renderFixtures["wrapped"], goldenWidth, 0)
	if len(rendered) != 1 || len(rendered[0].Lines) != 1 || !rendered[0].Overflow {
		t.Fatalf("overflowing node must remain one physical row marked for marquee: %+v", rendered)
	}
	line := rendered[0].Lines[0].Text
	if !strings.Contains(line, "capture protocol evolution guidance") || !strings.Contains(line, "…  running") {
		t.Fatalf("phase-zero marquee did not show the stable start and pinned status: %q", line)
	}
}

func TestRenderPreservesUnknownStatusTextVerbatim(t *testing.T) {
	line := Render([]Row{row("s", "novel status", nil, "future-status", "writer")}, goldenWidth)[0]
	if !strings.Contains(line, "future-status") || strings.Contains(line, "future-status (?)") {
		t.Fatalf("unknown status was rewritten: %q", line)
	}
}

func TestStatusWordsArePlainAndDefaultsHidden(t *testing.T) {
	cases := []struct {
		name, status, verdict, gate, want string
	}{
		{"done full", "done", "full", "notify", "done"},
		{"done partial", "done", "partial", "notify", "done · partial"},
		{"done none", "done", "none", "notify", "done · nothing landed"},
		{"running", "in-flight", "—", "notify", "running"},
		{"blocked input", "blocked-on-input", "—", "notify", "needs you"},
		{"blocked ref", "blocked-on:2", "—", "notify", "waiting on 2"},
		{"hold deduplicates", "blocked-on-input", "—", "hold", "needs you"},
		{"flag", "pending", "—", "flag", "queued · flagged for your review"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := row("s", "label", nil, tc.status, "read-only")
			r.Verdict, r.Gate = tc.verdict, tc.gate
			line := Render([]Row{r}, 80)[0]
			if !strings.HasSuffix(line, tc.want) {
				t.Fatalf("line %q does not end in %q", line, tc.want)
			}
			if strings.Contains(line, " ro") {
				t.Fatalf("read-only default leaked into status words: %q", line)
			}
		})
	}
}

func TestPendingDependenciesAndWarningsUsePlainWords(t *testing.T) {
	rows := []Row{
		row("a", "first", nil, "in-flight", "writer"),
		row("b", "second", []string{"a", "ghost"}, "pending", "writer"),
	}
	line := Render(rows, 100)[1]
	for _, want := range []string{"waiting on a", "⚠ unknown step ghost"} {
		if !strings.Contains(line, want) {
			t.Fatalf("plain warning %q missing from %q", want, line)
		}
	}
}

func TestWikilinksAreStrippedFromDisplayedLabel(t *testing.T) {
	r := row("s", "Readable headline ([[work:slug]], [[knowledge:path#Heading|alias]])", nil, "done", "writer")
	line := Render([]Row{r}, 100)[0]
	if strings.Contains(line, "[[") || !strings.Contains(line, "Readable headline") {
		t.Fatalf("display label retained a wikilink or lost its headline: %q", line)
	}
}

func TestMarqueeSharesBeatAndLeavesFittingRowsStill(t *testing.T) {
	rows := []Row{
		row("long", strings.Repeat("abcdefghij", 10), nil, "done", "writer"),
		row("fit", "short label", nil, "done", "writer"),
	}
	start := RenderRows(rows, 72, 0)
	dwell := RenderRows(rows, 72, marqueeStartDwellTicks)
	mid := RenderRows(rows, 72, marqueeStartDwellTicks+5)
	if start[0].Lines[0].Text != dwell[0].Lines[0].Text {
		t.Fatal("overflowing row moved during the three-second start dwell")
	}
	if start[0].Lines[0].Text == mid[0].Lines[0].Text || !strings.Contains(mid[0].Lines[0].Text, "…") {
		t.Fatalf("overflowing row did not glide after the dwell:\n%s\n%s", start[0].Lines[0].Text, mid[0].Lines[0].Text)
	}
	if start[1].Lines[0].Text != mid[1].Lines[0].Text || start[1].Overflow {
		t.Fatalf("fitting row moved on the shared beat:\n%s\n%s", start[1].Lines[0].Text, mid[1].Lines[0].Text)
	}
}

func TestMarqueeClipsUnicodeOnDisplayCells(t *testing.T) {
	r := row("wide", strings.Repeat("界", 40)+" complete", nil, "in-flight", "writer")
	for _, phase := range []int{0, marqueeStartDwellTicks + 7, 1000} {
		line := RenderRows([]Row{r}, 60, phase)[0].Lines[0].Text
		if !utf8.ValidString(line) {
			t.Fatalf("phase %d split a UTF-8 sequence: %q", phase, line)
		}
		if got := runewidth.StringWidth(line); got > 60 {
			t.Fatalf("phase %d rendered %d display cells, want <= 60: %q", phase, got, line)
		}
	}
}

func TestMetadataStartsAtPinnedColumn(t *testing.T) {
	rows := []Row{
		row("a", "short", nil, "done", "writer"),
		row("b", "a substantially longer label", nil, "done", "writer"),
	}
	rendered := RenderRows(rows, 90, 0)
	for _, r := range rendered {
		if len(r.Lines) != 1 || r.Lines[0].MetadataAt < 0 {
			t.Fatalf("row has no single pinned metadata suffix: %+v", r)
		}
		if got := runewidth.StringWidth(r.Lines[0].Text[:r.Lines[0].MetadataAt]); got != 86 {
			t.Fatalf("metadata starts at display column %d, want 86: %q", got, r.Lines[0].Text)
		}
	}
}

func coordinationPrimaryTUIRows() []Row {
	return []Row{
		{Arc: "coordination-primary-tui", StreamID: "1", Label: "pipe-pane live-mirror spike: capture-pane history + pipe-pane stream splice fidelity, send-keys round-trip, size-neutrality proof ([[work:pipe-pane-live-mirror-spike]])", Tree: "read-only", Gate: "notify", Status: "done", Verdict: "full"},
		{Arc: "coordination-primary-tui", StreamID: "2", Label: "DAG board package: Go renderer of coordinate-status --json stream rows (rails layout, pinned rules from prototype), plus the data layer that shells out to the same join ([[work:dag-board-package-status-join-rail-renderer]])", Tree: "writer", Gate: "notify", Status: "done", Verdict: "full"},
		{Arc: "coordination-primary-tui", StreamID: "3", Label: "coordination view restructure: landing state, detail-tab collapse (Brief + DAG + ticker; ledger/report as drill-ins), cross-arc attention strip, owner-gate surface", DependsOn: []string{"2"}, Tree: "writer", Gate: "flag", Status: "done", Verdict: "full"},
		{Arc: "coordination-primary-tui", StreamID: "4", Label: "live writable drill-in: capture+pipe-pane into the ghostty-backed panel + send-keys write path; retire 5s snapshot mirrors ([[work:live-writable-drill-in-pipe-pane-mirror]])", DependsOn: []string{"1"}, Tree: "writer", Gate: "notify", Status: "done", Verdict: "full"},
		{Arc: "coordination-primary-tui", StreamID: "5", Label: "narrow top-level sessions view to non-arc sessions (chat, ad-hoc, orphans); arc-owned sessions navigate via DAG rows ([[work:narrow-sessions-view-to-non-arc]])", DependsOn: []string{"3", "4"}, Tree: "writer", Gate: "notify", Status: "done", Verdict: "full"},
	}
}

func renderAtPhase(rows []Row, width, phase int) string {
	var lines []string
	for _, rendered := range RenderRows(rows, width, phase) {
		for _, line := range rendered.Lines {
			lines = append(lines, line.Text)
		}
	}
	return strings.Join(lines, "\n") + "\n"
}

func TestOwnerPanelDumpFixtures(t *testing.T) {
	phaseRows := []Row{
		row("long", "This older ledger headline is intentionally long enough to move across the shared marquee window while its status stays pinned", nil, "in-flight", "writer"),
		row("fit", "Short headline stays put", nil, "done", "writer"),
	}
	cases := []struct {
		name  string
		rows  []Row
		width int
		phase int
	}{
		{"owner_panel_coordination_primary_tui_width100.txt", coordinationPrimaryTUIRows(), 100, 0},
		{"owner_panel_coordination_primary_tui_width160.txt", coordinationPrimaryTUIRows(), 160, 0},
		{"owner_panel_marquee_width100_phase0.txt", phaseRows, 100, 0},
		{"owner_panel_marquee_width100_mid_glide.txt", phaseRows, 100, marqueeStartDwellTicks + 12},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := renderAtPhase(tc.rows, tc.width, tc.phase)
			for _, line := range strings.Split(strings.TrimSuffix(got, "\n"), "\n") {
				if runewidth.StringWidth(line) > tc.width {
					t.Fatalf("dump line exceeds width %d: %q", tc.width, line)
				}
			}
			if strings.Contains(got, "[[") || strings.Count(got, "\n") != len(tc.rows) {
				t.Fatalf("dump must be wikilink-free with one physical line per row:\n%s", got)
			}
			path := filepath.Join("testdata", tc.name)
			want, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("reading %s: %v\n--- render ---\n%s", path, err, got)
			}
			if got != string(want) {
				t.Fatalf("dump differs from %s\n--- got ---\n%s--- want ---\n%s", path, got, want)
			}
		})
	}
}
