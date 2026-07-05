package session

import (
	"fmt"
	"math/rand"
	"regexp"
	"strings"
)

// namePattern is the canonical instance-name shape: a lowercase leader then 2–47
// more [a-z0-9-] chars (total length 3–48). Generated word-pairs already
// conform; overrides are normalized to it.
var namePattern = regexp.MustCompile(`^[a-z][a-z0-9-]{2,47}$`)

const nameMaxLen = 48

// reservedWords are lore/harness/Claude built-in concept words. An instance name
// must never be mistakable for one of these — a fresh agent typing
// `--instance settlement` should never wonder whether it is addressing a
// concept. Both the generator word lists and the LORE_TUI_INSTANCE override are
// screened against this set.
var reservedWords = map[string]bool{
	"work": true, "spec": true, "plan": true, "plans": true, "thread": true,
	"threads": true, "settlement": true, "session": true, "sessions": true,
	"knowledge": true, "memory": true, "capture": true, "remember": true,
	"retro": true, "evolve": true, "followup": true, "scorecard": true,
	"lore": true, "agent": true, "task": true, "tasks": true, "implement": true,
	"chat": true, "digest": true, "notes": true, "index": true, "review": true,
	"explore": true, "bootstrap": true, "curate": true, "heal": true,
}

// adjectives and nouns are curated so every pair is memorable, path-safe, and
// free of built-in-concept collisions (enforced by names_test.go).
var adjectives = []string{
	"amber", "azure", "brisk", "calm", "clever", "coral", "dusky", "eager",
	"ember", "fleet", "gentle", "golden", "hazel", "ivory", "jade", "keen",
	"lively", "mellow", "nimble", "olive", "placid", "quiet", "rosy", "sable",
	"swift", "teal", "umber", "vivid", "warm", "zephyr",
}

var nouns = []string{
	"otter", "heron", "cedar", "maple", "comet", "falcon", "gecko", "harbor",
	"island", "jaguar", "kestrel", "lantern", "meadow", "nebula", "orchid",
	"pebble", "quartz", "raven", "sparrow", "thistle", "urchin", "violet",
	"willow", "yarrow", "beacon", "canyon", "delta", "fjord", "grotto", "summit",
}

// GenerateName resolves this instance's name. When env (LORE_TUI_INSTANCE) is
// set it is normalized and used, suffixed numerically if it collides with a live
// instance; an invalid override returns an error so startup can surface it.
// Otherwise a random adjective-noun pair is drawn, regenerating on collision.
func GenerateName(sessionsDir, env string) (string, error) {
	if strings.TrimSpace(env) != "" {
		base, err := normalizeOverride(env)
		if err != nil {
			return "", err
		}
		return disambiguate(sessionsDir, base), nil
	}
	// Try fresh pairs first; fall back to numeric disambiguation if every draw
	// collides (only possible with an implausible number of live instances).
	for i := 0; i < 20; i++ {
		name := randomPair()
		if !InstanceLive(sessionsDir, name) {
			return name, nil
		}
	}
	return disambiguate(sessionsDir, randomPair()), nil
}

// normalizeOverride maps a raw LORE_TUI_INSTANCE value to a path-safe id. A
// path-like value (slashes, dot segments), an empty result, or a value that
// normalizes onto a reserved concept is rejected with an error rather than
// silently rewritten — an explicit override is a user intent worth failing
// loudly on.
func normalizeOverride(raw string) (string, error) {
	trimmed := strings.TrimSpace(raw)
	if strings.ContainsAny(trimmed, "/\\") || strings.Contains(trimmed, "..") {
		return "", fmt.Errorf("LORE_TUI_INSTANCE %q is path-like; use a plain name", raw)
	}
	lower := strings.ToLower(trimmed)
	var b strings.Builder
	for _, r := range lower {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
		case r == '-' || r == '_' || r == ' ':
			b.WriteByte('-')
		}
	}
	name := strings.Trim(b.String(), "-")
	if name == "" {
		return "", fmt.Errorf("LORE_TUI_INSTANCE %q normalizes to an empty name", raw)
	}
	if len(name) > nameMaxLen {
		name = strings.Trim(name[:nameMaxLen], "-")
	}
	if IsReserved(name) {
		return "", fmt.Errorf("LORE_TUI_INSTANCE %q is a reserved concept name", raw)
	}
	if !namePattern.MatchString(name) {
		return "", fmt.Errorf("LORE_TUI_INSTANCE %q is not a valid instance name after normalization", raw)
	}
	return name, nil
}

// disambiguate returns base if no live instance holds it, otherwise base-2,
// base-3, … until a free name is found (the registry filename is the claim, so a
// stale name is reusable).
func disambiguate(sessionsDir, base string) string {
	if !InstanceLive(sessionsDir, base) {
		return base
	}
	for n := 2; ; n++ {
		candidate := fmt.Sprintf("%s-%d", base, n)
		if len(candidate) > nameMaxLen {
			candidate = candidate[:nameMaxLen]
		}
		if !InstanceLive(sessionsDir, candidate) {
			return candidate
		}
	}
}

// randomPair draws one adjective-noun name.
func randomPair() string {
	return adjectives[rand.Intn(len(adjectives))] + "-" + nouns[rand.Intn(len(nouns))]
}

// IsReserved reports whether a bare word collides with a built-in concept.
func IsReserved(word string) bool {
	return reservedWords[strings.ToLower(word)]
}
