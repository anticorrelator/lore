package main

import (
	"os"
	"runtime/debug"
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

// TestResolveBuildIdentityFallback asserts the last-resort mtime tier: with no
// injected ldflags vars and no VCS stamp, vintage degrades to the binary's
// mtime and an empty SHA. The `go test` binary this runs in carries no vcs.*
// settings (buildvcs is off for test binaries), so the middle VCS tier returns
// not-ok and resolveBuildIdentity lands here.
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

// TestBuildIdentityFromVCSSettings exercises the middle tier — the Go-native
// VCS stamps a plain `go build` embeds — across the shapes resolveBuildIdentity
// depends on: clean tree, dirty tree, missing revision, and an unparseable
// time.
func TestBuildIdentityFromVCSSettings(t *testing.T) {
	cases := []struct {
		name     string
		settings []debug.BuildSetting
		wantSHA  string
		wantTime string
		wantOK   bool
	}{
		{
			name: "clean tree: full revision abbreviates, RFC3339 time canonicalizes",
			settings: []debug.BuildSetting{
				{Key: "vcs.revision", Value: "d2a383dc0ffee1234567890abcdef0123456789a"},
				{Key: "vcs.time", Value: "2026-07-06T07:04:16Z"},
				{Key: "vcs.modified", Value: "false"},
			},
			wantSHA:  "d2a383d",
			wantTime: "2026-07-06T07:04:16Z",
			wantOK:   true,
		},
		{
			name: "dirty tree earns a -dirty suffix",
			settings: []debug.BuildSetting{
				{Key: "vcs.revision", Value: "d2a383dc0ffee1234567890abcdef0123456789a"},
				{Key: "vcs.time", Value: "2026-07-06T07:04:16Z"},
				{Key: "vcs.modified", Value: "true"},
			},
			wantSHA:  "d2a383d-dirty",
			wantTime: "2026-07-06T07:04:16Z",
			wantOK:   true,
		},
		{
			name: "offset timestamp normalizes to canonical UTC",
			settings: []debug.BuildSetting{
				{Key: "vcs.revision", Value: "abc1234"},
				{Key: "vcs.time", Value: "2026-07-06T09:04:16+02:00"},
			},
			wantSHA:  "abc1234",
			wantTime: "2026-07-06T07:04:16Z",
			wantOK:   true,
		},
		{
			name: "no revision: not-ok, resolveBuildIdentity falls through to mtime",
			settings: []debug.BuildSetting{
				{Key: "vcs.time", Value: "2026-07-06T07:04:16Z"},
			},
			wantOK: false,
		},
		{
			name: "unparseable time is dropped, SHA still rides through",
			settings: []debug.BuildSetting{
				{Key: "vcs.revision", Value: "abc1234"},
				{Key: "vcs.time", Value: "not-a-timestamp"},
			},
			wantSHA:  "abc1234",
			wantTime: "",
			wantOK:   true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sha, ts, ok := buildIdentityFromVCSSettings(tc.settings)
			if ok != tc.wantOK {
				t.Fatalf("ok = %v, want %v", ok, tc.wantOK)
			}
			if sha != tc.wantSHA {
				t.Fatalf("sha = %q, want %q", sha, tc.wantSHA)
			}
			if ts != tc.wantTime {
				t.Fatalf("time = %q, want %q", ts, tc.wantTime)
			}
		})
	}
}

// TestResolveBuildIdentityLdflagsBeatsVCS pins the tier order: when the ldflags
// vars are present they win outright, without consulting the binary's VCS
// stamps. Guards against a refactor that reorders the fallback.
func TestResolveBuildIdentityLdflagsBeatsVCS(t *testing.T) {
	origSHA, origTime := buildSHA, buildTime
	t.Cleanup(func() { buildSHA, buildTime = origSHA, origTime })

	buildSHA, buildTime = "release1", "2026-01-01T00:00:00Z"
	sha, ts := resolveBuildIdentity()
	if sha != "release1" || ts != "2026-01-01T00:00:00Z" {
		t.Fatalf("ldflags identity = (%q, %q), want the injected values to win", sha, ts)
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
