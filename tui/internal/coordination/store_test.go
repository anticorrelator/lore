package coordination

import (
	"os"
	"path/filepath"
	"testing"
)

// writeArc seeds one arc record. raw is written verbatim so tests can supply
// records that omit keys or fail to parse.
func writeArc(t *testing.T, workDir, name, raw string) {
	t.Helper()
	dir := ArcDir(workDir, name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "_meta.json"), []byte(raw), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestScanArcsMissingStoreIsEmptyNotAnError(t *testing.T) {
	arcs, skipped := ScanArcs(t.TempDir())
	if len(arcs) != 0 || skipped != 0 {
		t.Errorf("a store that does not exist yet reads as empty, got %d arcs / %d skipped", len(arcs), skipped)
	}
}

// The store keeps its own machine state beside the arcs. Underscore- and
// dot-prefixed entries are that state, not arcs, and are passed over without
// counting as unreadable records.
func TestScanArcsSkipsUnderscoreAndDotEntries(t *testing.T) {
	wd := t.TempDir()
	writeArc(t, wd, "real", `{"slug":"real","status":"active","opened":"2026-07-20T00:00:00Z"}`)
	writeArc(t, wd, "_migration-scratch", `{"slug":"x","status":"active"}`)
	writeArc(t, wd, ".hidden", `{"slug":"y","status":"active"}`)
	if err := os.WriteFile(filepath.Join(wd, "_arcs", "_migration-manifest.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}

	arcs, skipped := ScanArcs(wd)
	if len(arcs) != 1 || arcs[0].Slug != "real" {
		t.Fatalf("only the arc directory should produce a row, got %+v", arcs)
	}
	if skipped != 0 {
		t.Errorf("namespace entries are not unreadable records, got %d skipped", skipped)
	}
}

// A record with no usable status is malformed. It is skipped and counted —
// never given a status the record does not declare.
func TestScanArcsSkipsAndCountsMalformedRecords(t *testing.T) {
	wd := t.TempDir()
	writeArc(t, wd, "good", `{"slug":"good","status":"active","opened":"2026-07-20T00:00:00Z"}`)
	writeArc(t, wd, "unparseable", `{"slug":"unparseable","status":`)
	writeArc(t, wd, "no-status", `{"slug":"no-status"}`)
	writeArc(t, wd, "odd-status", `{"slug":"odd-status","status":"paused"}`)
	if err := os.MkdirAll(ArcDir(wd, "no-record"), 0o755); err != nil {
		t.Fatal(err)
	}

	arcs, skipped := ScanArcs(wd)
	if len(arcs) != 1 || arcs[0].Slug != "good" {
		t.Fatalf("only the well-formed record should produce a row, got %+v", arcs)
	}
	if skipped != 3 {
		t.Errorf("unparseable, status-less, and out-of-set records should count as skipped, got %d", skipped)
	}
}

// The record omits project and closed_at when it has no value for them; the
// row always carries both.
func TestScanArcsToleratesOmittedProjectAndClosedAt(t *testing.T) {
	wd := t.TempDir()
	writeArc(t, wd, "bare", `{"slug":"bare","title":"Bare","status":"active","members":[],"opened":"2026-07-20T00:00:00Z"}`)

	arcs, _ := ScanArcs(wd)
	if len(arcs) != 1 {
		t.Fatalf("want one arc, got %d", len(arcs))
	}
	a := arcs[0]
	if a.Project != "" || a.ClosedAt != "" {
		t.Errorf("omitted keys should normalize to empty, got project=%q closed_at=%q", a.Project, a.ClosedAt)
	}
	if a.Title != "Bare" || a.Section != SectionActive {
		t.Errorf("row should carry the record's title and its section, got %+v", a)
	}
}

func TestScanArcsSortsByOpenedThenSlugDescending(t *testing.T) {
	wd := t.TempDir()
	writeArc(t, wd, "older", `{"slug":"older","status":"active","opened":"2026-07-01T00:00:00Z"}`)
	writeArc(t, wd, "newer", `{"slug":"newer","status":"active","opened":"2026-07-20T00:00:00Z"}`)
	writeArc(t, wd, "tie-a", `{"slug":"tie-a","status":"active","opened":"2026-07-10T00:00:00Z"}`)
	writeArc(t, wd, "tie-b", `{"slug":"tie-b","status":"active","opened":"2026-07-10T00:00:00Z"}`)

	arcs, _ := ScanArcs(wd)
	var got []string
	for _, a := range arcs {
		got = append(got, a.Slug)
	}
	want := []string{"newer", "tie-b", "tie-a", "older"}
	for i := range want {
		if i >= len(got) || got[i] != want[i] {
			t.Fatalf("newest first, slug descending on a tie: got %v want %v", got, want)
		}
	}
}

// Membership is declared; the count is what still resolves to live work.
func TestScanArcsCountsOnlyActiveMembers(t *testing.T) {
	wd := t.TempDir()
	for _, slug := range []string{"live-one", "live-two"} {
		if err := os.MkdirAll(filepath.Join(wd, slug), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(wd, "_archive", "retired"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeArc(t, wd, "arc", `{"slug":"arc","status":"active","opened":"2026-07-20T00:00:00Z",`+
		`"members":["live-one","live-two","retired","never-existed"]}`)

	arcs, _ := ScanArcs(wd)
	if len(arcs) != 1 {
		t.Fatalf("want one arc, got %d", len(arcs))
	}
	if arcs[0].Items != 2 {
		t.Errorf("archived and unresolvable members should not count, got %d", arcs[0].Items)
	}
	if len(arcs[0].Members) != 4 {
		t.Errorf("the declared membership stays whole for the detail joins, got %v", arcs[0].Members)
	}
}

// A project label is not membership: an arc can carry a label while declaring
// no members at all, which is the case the label join used to misread.
func TestScanArcsKeepsLabelSeparateFromMembership(t *testing.T) {
	wd := t.TempDir()
	if err := os.MkdirAll(filepath.Join(wd, "labeled-item"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeArc(t, wd, "arc", `{"slug":"arc","status":"active","project":"shared-label","members":[],"opened":"2026-07-20T00:00:00Z"}`)

	arcs, _ := ScanArcs(wd)
	if len(arcs) != 1 {
		t.Fatalf("want one arc, got %d", len(arcs))
	}
	if arcs[0].Project != "shared-label" {
		t.Errorf("the label should survive as a column value, got %q", arcs[0].Project)
	}
	if arcs[0].Items != 0 || len(arcs[0].Members) != 0 {
		t.Errorf("items sharing the label are not members, got %d items %v", arcs[0].Items, arcs[0].Members)
	}
}

func TestArcClosedReadsDeclaredStatus(t *testing.T) {
	for status, want := range map[string]bool{
		StatusActive:   false,
		StatusClosed:   true,
		StatusArchived: true,
	} {
		if got := (Arc{Status: status}).Closed(); got != want {
			t.Errorf("status %q: Closed()=%v want %v", status, got, want)
		}
	}
}
