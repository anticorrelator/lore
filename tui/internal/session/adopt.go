package session

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// claimSuffix marks an instance row a startup adoption scan has claimed. The
// suffix deliberately does not end in ".json" so a claimed corpse is invisible to
// the instances/*.json glob (ListInstances, ScanAdoptable) the instant it is
// renamed — one atomic rename transfers ownership away from the dead instance.
const claimSuffix = ".adopting"

// ScanAdoptable returns the dead-instance registry rows a fresh instance may
// adopt. Unlike ListInstances it deliberately INCLUDES TTL-stale files: a dead
// owner's row is exactly the stale one, and it is the recovery manifest. A row is
// adoptable when it is not this instance's own, names this repo, and its owner is
// dead — mtime beyond LivenessTTL AND PID not alive (both, so a briefly-paused but
// live instance is never mistaken for a corpse). Corrupt rows and non-.json claim
// files are skipped.
func ScanAdoptable(sessionsDir, repo, selfName string, now time.Time) []Instance {
	matches, err := filepath.Glob(filepath.Join(InstancesDir(sessionsDir), "*.json"))
	if err != nil {
		return nil
	}
	var out []Instance
	for _, path := range matches {
		fi, err := os.Stat(path)
		if err != nil {
			continue
		}
		if now.Sub(fi.ModTime()) <= LivenessTTL {
			continue // fresh mtime — owner is heartbeating, not a corpse
		}
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var inst Instance
		if err := json.Unmarshal(data, &inst); err != nil {
			continue
		}
		if inst.Name == selfName || inst.Name == "" {
			continue
		}
		if inst.Repo != repo {
			continue
		}
		if pidAlive(inst.PID) {
			continue // stale mtime but PID still live — do not steal its sessions
		}
		out = append(out, inst)
	}
	return out
}

// ClaimInstance atomically claims a dead instance's row for adoption by renaming
// it to a claim-suffixed name in the same directory. Rename is atomic on one
// filesystem, so of two fresh TUIs racing to adopt the same corpse exactly one
// rename succeeds; the loser gets a not-exist error and skips the row. On success
// it returns the parsed row and the claim path (pass to DeleteClaim when done).
func ClaimInstance(sessionsDir, name string) (Instance, string, error) {
	src := instancePath(sessionsDir, name)
	claim := fmt.Sprintf("%s%s.%d", src, claimSuffix, os.Getpid())
	if err := os.Rename(src, claim); err != nil {
		return Instance{}, "", err // not-exist ⇒ lost the claim race (or already gone)
	}
	data, err := os.ReadFile(claim)
	if err != nil {
		return Instance{}, claim, err
	}
	var inst Instance
	if err := json.Unmarshal(data, &inst); err != nil {
		return Instance{}, claim, fmt.Errorf("parse claimed row %s: %w", claim, err)
	}
	return inst, claim, nil
}

// DeleteClaim removes a claimed corpse file. Idempotent: a missing file is not an
// error. Adoption doubles as the crash-corpse cleanup the substrate otherwise
// lacks — the claimed row is deleted once its sessions have been handled.
func DeleteClaim(claimPath string) error {
	if claimPath == "" {
		return nil
	}
	err := os.Remove(claimPath)
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

// pidAlive reports whether pid names a live process, via the standard Unix
// signal-0 liveness probe. A recycled pid can read alive; ScanAdoptable pairs this
// with the mtime-TTL staleness check so that only a stale-AND-dead row is adopted.
func pidAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	return syscall.Kill(pid, syscall.Signal(0)) == nil
}
