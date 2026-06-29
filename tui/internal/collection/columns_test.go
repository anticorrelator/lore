package collection

import (
	"fmt"
	"math/rand"
	"testing"
)

// genColumns produces a random column set: 0-7 columns, widths 1-30,
// priorities 0-3 (ties common, to exercise stable ordering), ~1 in 4 flex.
func genColumns(r *rand.Rand) []Column {
	n := r.Intn(8)
	cols := make([]Column, n)
	for i := range cols {
		cols[i] = Column{
			Key:      fmt.Sprintf("c%d", i),
			Title:    fmt.Sprintf("C%d", i),
			Width:    1 + r.Intn(30),
			Priority: r.Intn(4),
			Flex:     r.Intn(4) == 0,
		}
	}
	return cols
}

func asSet(idxs []int) map[int]bool {
	s := make(map[int]bool, len(idxs))
	for _, i := range idxs {
		s[i] = true
	}
	return s
}

// TestSelectColumnsMonotonic: widening the panel never drops a column —
// the set selected at a narrower width is a subset of the set selected at
// any wider width.
func TestSelectColumnsMonotonic(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	for i := 0; i < 500; i++ {
		cols := genColumns(r)
		w1 := r.Intn(250)
		w2 := w1 + r.Intn(250)

		narrow := SelectColumns(w1, cols)
		wide := asSet(SelectColumns(w2, cols))
		for _, idx := range narrow {
			if !wide[idx] {
				t.Fatalf("case %d: column %d selected at width %d but not at wider width %d\ncols: %+v",
					i, idx, w1, w2, cols)
			}
		}
	}
}

// TestSelectColumnsBreakpointIdempotent: re-resolving at a selection's own
// minimal total width returns exactly the same selection — the width→set
// step function has stable breakpoints and cannot oscillate.
func TestSelectColumnsBreakpointIdempotent(t *testing.T) {
	r := rand.New(rand.NewSource(2))
	for i := 0; i < 500; i++ {
		cols := genColumns(r)
		w := r.Intn(250)

		selected := SelectColumns(w, cols)
		m := minTotalWidth(cols, selected)
		again := SelectColumns(m, cols)

		if len(again) != len(selected) {
			t.Fatalf("case %d: width %d selected %v (min total %d), but re-resolving at %d selected %v\ncols: %+v",
				i, w, selected, m, m, again, cols)
		}
		for j := range selected {
			if selected[j] != again[j] {
				t.Fatalf("case %d: width %d selected %v, re-resolving at min total %d selected %v\ncols: %+v",
					i, w, selected, m, again, cols)
			}
		}
	}
}

// TestSelectColumnsAlwaysFits: any non-empty selection's minimal total
// width fits within the width it was selected for.
func TestSelectColumnsAlwaysFits(t *testing.T) {
	r := rand.New(rand.NewSource(3))
	for i := 0; i < 500; i++ {
		cols := genColumns(r)
		w := r.Intn(250)
		selected := SelectColumns(w, cols)
		if len(selected) == 0 {
			continue
		}
		if m := minTotalWidth(cols, selected); m > w {
			t.Fatalf("case %d: selection %v needs %d cells but was selected for width %d\ncols: %+v",
				i, selected, m, w, cols)
		}
	}
}

// TestFitColumnsFlexInvariants: when a flex column is selected, the spare
// width is fully absorbed (row spans exactly the panel width); non-flex
// columns keep their declared width and flex columns never shrink.
func TestFitColumnsFlexInvariants(t *testing.T) {
	r := rand.New(rand.NewSource(4))
	for i := 0; i < 500; i++ {
		cols := genColumns(r)
		w := r.Intn(250)
		slots := FitColumns(w, cols)
		if len(slots) == 0 {
			continue
		}

		total := rowLead + columnGap*(len(slots)-1)
		hasFlex := false
		for _, s := range slots {
			total += s.RenderWidth
			if s.Flex {
				hasFlex = true
				if s.RenderWidth < s.Width {
					t.Fatalf("case %d: flex column %s shrank: render %d < min %d", i, s.Key, s.RenderWidth, s.Width)
				}
			} else if s.RenderWidth != s.Width {
				t.Fatalf("case %d: non-flex column %s resized: render %d != %d", i, s.Key, s.RenderWidth, s.Width)
			}
		}
		if hasFlex && total != w {
			t.Fatalf("case %d: flex row spans %d cells, want exactly %d\nslots: %+v", i, total, w, slots)
		}
		if !hasFlex && total > w {
			t.Fatalf("case %d: row spans %d cells, exceeds width %d\nslots: %+v", i, total, w, slots)
		}
	}
}

// TestSelectColumnsExamples pins concrete edge cases: empty input, zero
// and negative widths, priority-driven dropping, ties keeping input order,
// and the exact-boundary width.
func TestSelectColumnsExamples(t *testing.T) {
	cols := []Column{
		{Key: "slug", Width: 20, Priority: 0, Flex: true},
		{Key: "status", Width: 10, Priority: 0},
		{Key: "updated", Width: 8, Priority: 1},
		{Key: "pr", Width: 6, Priority: 2},
	}

	cases := []struct {
		name  string
		width int
		cols  []Column
		want  []int
	}{
		{"empty columns", 80, nil, []int{}},
		{"zero width", 0, cols, []int{}},
		{"negative width", -5, cols, []int{}},
		// lead(2)+20 = 22 — only the first priority-0 column fits.
		{"first column only", 22, cols, []int{0}},
		// 21 — not even the first column fits.
		{"below first breakpoint", 21, cols, []int{}},
		// lead(2)+20+10+gap(2) = 34 — both priority-0 columns, exactly.
		{"exact priority-0 boundary", 34, cols, []int{0, 1}},
		// One short of admitting priority-1 (needs 44).
		{"priority-1 excluded at 43", 43, cols, []int{0, 1}},
		{"priority-1 admitted at 44", 44, cols, []int{0, 1, 2}},
		{"all fit", 80, cols, []int{0, 1, 2, 3}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := SelectColumns(tc.width, tc.cols)
			if len(got) != len(tc.want) {
				t.Fatalf("SelectColumns(%d) = %v, want %v", tc.width, got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Fatalf("SelectColumns(%d) = %v, want %v", tc.width, got, tc.want)
				}
			}
		})
	}
}

// TestSelectColumnsPriorityTieKeepsInputOrder: equal priorities admit in
// input order, so the earlier column wins the remaining space.
func TestSelectColumnsPriorityTieKeepsInputOrder(t *testing.T) {
	cols := []Column{
		{Key: "a", Width: 10, Priority: 1},
		{Key: "b", Width: 10, Priority: 1},
	}
	// lead(2)+10 = 12: room for exactly one — must be the first.
	got := SelectColumns(12, cols)
	if len(got) != 1 || got[0] != 0 {
		t.Fatalf("SelectColumns(12) = %v, want [0]", got)
	}
}

// TestFitColumnsFlexRemainder: spare width splits evenly across flex
// columns with the remainder going to the first.
func TestFitColumnsFlexRemainder(t *testing.T) {
	cols := []Column{
		{Key: "a", Width: 10, Priority: 0, Flex: true},
		{Key: "b", Width: 10, Priority: 0, Flex: true},
	}
	// minTotal = 2+10+10+2 = 24; width 29 leaves spare 5 → 3 and 2.
	slots := FitColumns(29, cols)
	if len(slots) != 2 {
		t.Fatalf("FitColumns selected %d slots, want 2", len(slots))
	}
	if slots[0].RenderWidth != 13 || slots[1].RenderWidth != 12 {
		t.Fatalf("flex widths = %d, %d; want 13, 12", slots[0].RenderWidth, slots[1].RenderWidth)
	}
}

// TestModeFor pins the threshold boundary: stacked strictly below, columnar
// at and above.
func TestModeFor(t *testing.T) {
	if got := ModeFor(59, 60); got != ModeStacked {
		t.Errorf("ModeFor(59, 60) = %v, want ModeStacked", got)
	}
	if got := ModeFor(60, 60); got != ModeColumnar {
		t.Errorf("ModeFor(60, 60) = %v, want ModeColumnar", got)
	}
	if got := ModeFor(120, 60); got != ModeColumnar {
		t.Errorf("ModeFor(120, 60) = %v, want ModeColumnar", got)
	}
}
