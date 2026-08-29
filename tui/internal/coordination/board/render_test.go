package board

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

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
		row("S2", "impl auth", []string{"S1"}, "blocked-on-input", "writer"),
		row("S3", "integrate", []string{"S1", "S2"}, "pending", "writer"),
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
}

func TestRenderGoldenFixtures(t *testing.T) {
	for _, name := range []string{"real", "minimal", "adversarial", "wide", "root_lane_reuse"} {
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
	rendered := RenderRows(rows, goldenWidth)
	if len(rendered) != 2 || rendered[0].StreamID != "root" || rendered[1].StreamID != "child" {
		t.Fatalf("render identities do not follow topological lines: %+v", rendered)
	}
	lines := Render(rows, goldenWidth)
	if rendered[0].Line != lines[0] || rendered[1].Line != lines[1] {
		t.Fatalf("identity and text render paths drifted: %+v != %q", rendered, lines)
	}
}

func TestRenderPreservesUnknownStatusTextVerbatim(t *testing.T) {
	line := Render([]Row{row("s", "novel status", nil, "future-status", "writer")}, goldenWidth)[0]
	if !strings.Contains(line, "future-status") || strings.Contains(line, "future-status (?)") {
		t.Fatalf("unknown status was rewritten: %q", line)
	}
}
