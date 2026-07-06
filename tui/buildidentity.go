package main

import "os"

// buildSHA and buildTime are injected at build time via
//
//	-ldflags "-X main.buildSHA=<short-sha> -X main.buildTime=<commit-date-utc>"
//
// (see install.sh). buildTime is the commit's committer-date in the substrate's
// canonical UTC form (2006-01-02T15:04:05Z). Both stay empty for a `go run` /
// dev build that never passed the ldflags, in which case resolveBuildIdentity
// falls back to the binary's mtime.
var (
	buildSHA  string
	buildTime string
)

// resolveBuildIdentity returns this binary's (sha, buildTime) build vintage. A
// release build carries both from ldflags. A dev/go-run build carries neither,
// so the vintage degrades to the binary's own mtime (its compile time) with an
// empty SHA — honest and still orderable against a min_vintage requirement. When
// even the executable's mtime is unreadable, vintage is fully unknown ("", "")
// and the instance is never rejected by min_vintage filtering.
func resolveBuildIdentity() (sha, buildTimeISO string) {
	if buildSHA != "" || buildTime != "" {
		return buildSHA, buildTime
	}
	exe, err := os.Executable()
	if err != nil {
		return "", ""
	}
	fi, err := os.Stat(exe)
	if err != nil {
		return "", ""
	}
	return "", fi.ModTime().UTC().Format("2006-01-02T15:04:05Z")
}
