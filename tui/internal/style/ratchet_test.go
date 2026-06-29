package style

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"testing"
)

// TestInlineColorLiteralRatchet enforces the palette discipline this package
// declares: every shared color is reached through a named semantic role,
// never a raw index at the call site (see the palette comment in style.go).
//
// It walks every non-test .go file under tui/ (excluding this package, which
// is the one place literals are allowed) and counts raw lipgloss.Color(...)
// constructions. Counts are compared against the checked-in allowlist of
// known stragglers below.
//
// This is a RATCHET, not a snapshot:
//   - A file exceeding its allowance fails — a new inline literal was
//     introduced. Fix it by using a style.Color* role (add a new role with a
//     rationale if no existing one fits semantically — do not launder a new
//     meaning through a role that merely shares the index).
//   - A file below its allowance also fails — literals were cleaned up, so
//     tighten the allowlist entry to lock in the improvement.
//
// The allowlist should only ever shrink. Most entries are owned by Track C
// (component extraction / settings redesign) or Track A (specpanel.go) and
// will be retired when those rewrites land.
var inlineColorAllowlist = map[string]int{
	"internal/followup/reviewcards.go": 11,
	"internal/search/panel.go":         5,
	"internal/search/popup.go":         2,
	"internal/work/execlog.go":         8,
	"internal/work/notes.go":           4,
	"internal/work/plantab.go":         1,
	"internal/work/specpanel.go":       2,
	"internal/work/tasks.go":           4,
}

var inlineColorPattern = regexp.MustCompile(`lipgloss\.(?:ANSI)?Color\(`)

func TestInlineColorLiteralRatchet(t *testing.T) {
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot resolve test file path")
	}
	styleDir := filepath.Dir(thisFile)
	tuiRoot := filepath.Clean(filepath.Join(styleDir, "..", ".."))

	counts := map[string]int{}
	err := filepath.WalkDir(tuiRoot, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			// Skip this package: style.go is where literals are defined once.
			if filepath.Clean(path) == styleDir {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		n := len(inlineColorPattern.FindAllIndex(data, -1))
		if n == 0 {
			return nil
		}
		rel, err := filepath.Rel(tuiRoot, path)
		if err != nil {
			return err
		}
		counts[filepath.ToSlash(rel)] = n
		return nil
	})
	if err != nil {
		t.Fatalf("walking %s: %v", tuiRoot, err)
	}

	var failures []string
	for file, got := range counts {
		allowed := inlineColorAllowlist[file]
		switch {
		case got > allowed:
			failures = append(failures, fmt.Sprintf(
				"%s: %d inline lipgloss.Color literal(s), allowlist permits %d — use a named style.Color* role instead of a raw index",
				file, got, allowed))
		case got < allowed:
			failures = append(failures, fmt.Sprintf(
				"%s: %d inline literal(s) but allowlist permits %d — literals were cleaned up; tighten the allowlist entry to %d to lock in the improvement",
				file, got, allowed, got))
		}
	}
	for file, allowed := range inlineColorAllowlist {
		if _, present := counts[file]; !present {
			failures = append(failures, fmt.Sprintf(
				"%s: allowlisted for %d literal(s) but has none (or no longer exists) — remove its allowlist entry",
				file, allowed))
		}
	}

	if len(failures) > 0 {
		sort.Strings(failures)
		t.Errorf("inline color literal ratchet violated:\n  %s", strings.Join(failures, "\n  "))
	}
}
