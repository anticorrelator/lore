package session

import (
	"regexp"
	"testing"
	"testing/quick"
)

var singleWord = regexp.MustCompile(`^[a-z]+$`)

// TestWordListsAreScreened enforces the naming-collision convention: no word in
// either list may be a built-in concept, and every word must be a plain
// lowercase token so every generated pair conforms to namePattern.
func TestWordListsAreScreened(t *testing.T) {
	for _, w := range append(append([]string{}, adjectives...), nouns...) {
		if !singleWord.MatchString(w) {
			t.Errorf("word %q is not a plain lowercase token", w)
		}
		if IsReserved(w) {
			t.Errorf("word %q collides with a built-in concept", w)
		}
	}
}

// TestGeneratedPairsConform checks that every adjective-noun combination is a
// valid instance name.
func TestGeneratedPairsConform(t *testing.T) {
	for _, a := range adjectives {
		for _, n := range nouns {
			name := a + "-" + n
			if !namePattern.MatchString(name) {
				t.Errorf("pair %q does not match namePattern", name)
			}
		}
	}
}

// TestDisambiguateAvoidsLiveNames is the collision property: for any base name,
// disambiguation against a directory where that base is already live never
// returns the live name.
func TestDisambiguateAvoidsLiveNames(t *testing.T) {
	f := func(seed uint16) bool {
		dir := t.TempDir()
		base := adjectives[int(seed)%len(adjectives)] + "-" + nouns[int(seed/7)%len(nouns)]
		if err := WriteInstance(dir, Instance{Name: base, PID: 1}); err != nil {
			t.Fatal(err)
		}
		got := disambiguate(dir, base)
		return got != base && !InstanceLive(dir, got)
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 200}); err != nil {
		t.Error(err)
	}
}

func TestGenerateNameOverride(t *testing.T) {
	dir := t.TempDir()
	name, err := GenerateName(dir, "My Instance")
	if err != nil {
		t.Fatalf("valid override rejected: %v", err)
	}
	if name != "my-instance" {
		t.Fatalf("override normalization = %q, want my-instance", name)
	}
}

func TestGenerateNameOverrideCollisionSuffixes(t *testing.T) {
	dir := t.TempDir()
	if err := WriteInstance(dir, Instance{Name: "my-instance", PID: 1}); err != nil {
		t.Fatal(err)
	}
	name, err := GenerateName(dir, "my-instance")
	if err != nil {
		t.Fatal(err)
	}
	if name == "my-instance" || InstanceLive(dir, name) {
		t.Fatalf("override collision not disambiguated: %q", name)
	}
}

func TestGenerateNameRejectsBadOverrides(t *testing.T) {
	dir := t.TempDir()
	cases := map[string]string{
		"path-like":     "../evil",
		"slashes":       "a/b",
		"empty-normal":  "!!!",
		"reserved":      "settlement",
		"reserved-work": "work",
	}
	for name, override := range cases {
		if _, err := GenerateName(dir, override); err == nil {
			t.Errorf("%s: override %q should have been rejected", name, override)
		}
	}
}

func TestGenerateNameDefaultConforms(t *testing.T) {
	dir := t.TempDir()
	name, err := GenerateName(dir, "")
	if err != nil {
		t.Fatal(err)
	}
	if !namePattern.MatchString(name) {
		t.Fatalf("generated default name %q does not conform", name)
	}
}
