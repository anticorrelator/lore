package main

import (
	"os"
	"runtime/debug"
	"time"
)

// buildTimeLayout is the substrate's canonical UTC vintage form — the orderable
// quantity min_vintage filtering compares against. Every tier of
// resolveBuildIdentity emits buildTime in this layout.
const buildTimeLayout = "2006-01-02T15:04:05Z"

// buildSHA and buildTime are injected at build time via
//
//	-ldflags "-X main.buildSHA=<short-sha> -X main.buildTime=<commit-date-utc>"
//
// (see install.sh). buildTime is the commit's committer-date in buildTimeLayout.
// Both stay empty for any build that never passed those ldflags (a plain
// `go build`, an IDE run, `go run`), in which case resolveBuildIdentity falls
// back to the binary's own Go-native VCS stamps, then to its mtime.
var (
	buildSHA  string
	buildTime string
)

// resolveBuildIdentity returns this binary's (sha, buildTime) build vintage
// through a three-tier fallback:
//
//  1. ldflags — a release build (install.sh) carries both vars verbatim.
//  2. Go-native VCS stamps — a plain `go build` in a checkout embeds
//     vcs.revision/vcs.time/vcs.modified via debug.ReadBuildInfo(); the
//     revision becomes the SHA (with a -dirty suffix when the tree was
//     modified, matching git-describe) and vcs.time the buildTime. This is
//     more truthful than mtime and, unlike ldflags, needs no special build.
//  3. binary mtime — when neither of the above is present, the vintage degrades
//     to the executable's mtime (its compile time) with an empty SHA — honest
//     and still orderable against a min_vintage requirement.
//
// When even the executable's mtime is unreadable, vintage is fully unknown
// ("", "") and the instance is never rejected by min_vintage filtering.
func resolveBuildIdentity() (sha, buildTimeISO string) {
	if buildSHA != "" || buildTime != "" {
		return buildSHA, buildTime
	}
	if sha, buildTimeISO, ok := buildIdentityFromVCS(); ok {
		return sha, buildTimeISO
	}
	exe, err := os.Executable()
	if err != nil {
		return "", ""
	}
	fi, err := os.Stat(exe)
	if err != nil {
		return "", ""
	}
	return "", fi.ModTime().UTC().Format(buildTimeLayout)
}

// buildIdentityFromVCS reads this binary's Go-native VCS build stamps. ok is
// false when no build info is embedded (statically stripped, or a toolchain
// that recorded no vcs.revision, e.g. a `go test` binary).
func buildIdentityFromVCS() (sha, buildTimeISO string, ok bool) {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return "", "", false
	}
	return buildIdentityFromVCSSettings(info.Settings)
}

// buildIdentityFromVCSSettings derives the (sha, buildTime) vintage from Go's
// native VCS build settings. It is the pure core of buildIdentityFromVCS,
// split out so the fallback logic is testable without a VCS-stamped binary.
//
// vcs.revision is the full commit SHA, abbreviated here to the 7-char short
// form install.sh's ldflags path advertises; a modified working tree
// (vcs.modified=true) earns a -dirty suffix, because a dirty build's SHA is not
// the commit it claims. vcs.time is the committer-date, reformatted from its
// RFC3339 stamp into buildTimeLayout. ok is false when no vcs.revision is
// recorded — there is nothing more truthful than mtime to offer.
func buildIdentityFromVCSSettings(settings []debug.BuildSetting) (sha, buildTimeISO string, ok bool) {
	var revision, vcsTime string
	var modified bool
	for _, s := range settings {
		switch s.Key {
		case "vcs.revision":
			revision = s.Value
		case "vcs.time":
			vcsTime = s.Value
		case "vcs.modified":
			modified = s.Value == "true"
		}
	}
	if revision == "" {
		return "", "", false
	}
	sha = shortSHA(revision)
	if modified {
		sha += "-dirty"
	}
	if vcsTime != "" {
		if t, err := time.Parse(time.RFC3339, vcsTime); err == nil {
			vcsTime = t.UTC().Format(buildTimeLayout)
		} else {
			// A stamp we cannot parse is not a trustworthy orderable; drop it
			// rather than advertise a non-canonical buildTime. The SHA still
			// rides through.
			vcsTime = ""
		}
	}
	return sha, vcsTime, true
}

// shortSHA abbreviates a full commit SHA to git's conventional 7-char short
// form, matching the display width install.sh's `git rev-parse --short` path
// produces.
func shortSHA(revision string) string {
	if len(revision) > 7 {
		return revision[:7]
	}
	return revision
}
