package main

import (
	"os"
	"testing"

	"github.com/anticorrelator/lore/tui/internal/session"
)

// TestResolveBuildIdentityLdflags asserts the -ldflags path: when the injected
// package vars are set, resolveBuildIdentity returns them verbatim (no mtime
// fallback). This is the release-build vintage.
func TestResolveBuildIdentityLdflags(t *testing.T) {
	origSHA, origTime := buildSHA, buildTime
	t.Cleanup(func() { buildSHA, buildTime = origSHA, origTime })

	buildSHA, buildTime = "abc1234", "2026-07-06T02:12:38Z"
	sha, ts := resolveBuildIdentity()
	if sha != "abc1234" || ts != "2026-07-06T02:12:38Z" {
		t.Fatalf("ldflags identity = (%q, %q), want the injected values", sha, ts)
	}
}

// TestResolveBuildIdentityFallback asserts the dev/go-run path: with no injected
// vars, vintage degrades to the binary's mtime and an empty SHA.
func TestResolveBuildIdentityFallback(t *testing.T) {
	origSHA, origTime := buildSHA, buildTime
	t.Cleanup(func() { buildSHA, buildTime = origSHA, origTime })

	buildSHA, buildTime = "", ""
	sha, ts := resolveBuildIdentity()
	if sha != "" {
		t.Fatalf("dev build should carry no SHA, got %q", sha)
	}
	if ts == "" {
		t.Fatal("dev build should fall back to a non-empty mtime vintage")
	}
}

// TestInstanceRowStampsVintage is the end-to-end stamp: the vintage resolved at
// startup rides instanceRow() onto the registry row and survives a write/read
// round-trip through the session package.
func TestInstanceRowStampsVintage(t *testing.T) {
	m := model{
		instanceName:       "amber-otter",
		instanceStartedISO: "2026-07-06T00:00:00Z",
		buildSHA:           "1dfdd89",
		buildTime:          "2026-07-06T02:12:38Z",
	}
	row := m.instanceRow()
	if row.BuildSHA != "1dfdd89" || row.BuildTime != "2026-07-06T02:12:38Z" {
		t.Fatalf("instanceRow did not stamp vintage: %+v", row)
	}

	dir := t.TempDir()
	if err := session.WriteInstance(dir, row); err != nil {
		t.Fatal(err)
	}
	got := session.ListInstances(dir)
	if len(got) != 1 || got[0].BuildSHA != "1dfdd89" || got[0].BuildTime != "2026-07-06T02:12:38Z" {
		t.Fatalf("vintage did not survive the registry round-trip: %+v", got)
	}
	_ = os.Getpid() // instanceRow stamps the real pid; nothing to assert here.
}
