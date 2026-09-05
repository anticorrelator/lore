package session

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// claimSuffix marks an instance row a startup adoption scan has claimed. The
// suffix deliberately does not end in ".json" so a claimed corpse is invisible to
// the instances/*.json glob (ListInstances, ScanAdoptable) the instant it is
// renamed — one atomic rename transfers ownership away from the dead instance.
const claimSuffix = ".adopting"

// ScanAdoptable discovers ordinary dead owners, including claims whose adopter
// died. Process death is sufficient even within the heartbeat TTL; a live or
// permission-inaccessible PID is never taken. Managed manifests stay scoped to
// their dedicated host. Claims are not restored over a newer registry row.
func ScanAdoptable(sessionsDir, repo, selfName string, now time.Time) []Instance {
	paths, _ := filepath.Glob(filepath.Join(InstancesDir(sessionsDir), "*.json"))
	claims, _ := filepath.Glob(filepath.Join(InstancesDir(sessionsDir), "*.json.adopting.*"))
	paths = append(paths, claims...)
	var out []Instance
	for _, path := range paths {
		if strings.Contains(path, ".json.adopting.") {
			pid, err := strconv.Atoi(path[strings.LastIndex(path, ".")+1:])
			if err != nil || pidAlive(pid) {
				continue
			}
		}
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var inst Instance
		if json.Unmarshal(data, &inst) != nil {
			continue
		}
		if inst.Name == selfName || inst.Name == "" || inst.HostKey != "" || inst.Role == "session-host" || inst.Repo != repo || pidAlive(inst.PID) {
			continue
		}
		inst.adoptionPath = path
		out = append(out, inst)
	}
	// Full ownership supersedes a provisional launch checkpoint. Among full
	// owners, inspect the newest generation first; conflicting older identities
	// remain in their manifests rather than overwriting a same-slug survivor.
	sort.SliceStable(out, func(i, j int) bool {
		if (out[i].Role == "session-spawn") != (out[j].Role == "session-spawn") {
			return out[i].Role != "session-spawn"
		}
		if out[i].Revision != out[j].Revision {
			return out[i].Revision > out[j].Revision
		}
		return out[i].Started > out[j].Started
	})
	return out
}

// ClaimAdoptable claims the exact manifest discovered by ScanAdoptable. Renaming
// that path has one winner even when two restarting instances scan together.
func ClaimAdoptable(sessionsDir string, candidate Instance) (Instance, string, error) {
	if candidate.adoptionPath == "" {
		return ClaimInstance(sessionsDir, candidate.Name)
	}
	return claimInstancePath(candidate.adoptionPath)
}

// ClaimInstance atomically claims a dead instance's row for adoption by renaming
// it to a claim-suffixed name in the same directory. Rename is atomic on one
// filesystem, so of two fresh TUIs racing to adopt the same corpse exactly one
// rename succeeds; the loser gets a not-exist error and skips the row. On success
// it returns the parsed row and the claim path (pass to DeleteClaim when done).
func ClaimInstance(sessionsDir, name string) (Instance, string, error) {
	return claimInstancePath(instancePath(sessionsDir, name))
}

func claimInstancePath(src string) (Instance, string, error) {
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

// ReleaseClaim preserves an unresolved manifest and makes it discoverable even
// while this adopter is alive. A uniquely reserved destination prevents release
// from overwriting a newer same-name manifest. PID 0 denotes no current adopter.
func ReleaseClaim(claimPath string) (string, error) {
	base := strings.Split(filepath.Base(claimPath), ".json.adopting.")[0]
	f, err := os.CreateTemp(filepath.Dir(claimPath), base+".json.adopting.*.0")
	if err != nil {
		return "", err
	}
	path := f.Name()
	if err := f.Close(); err != nil {
		os.Remove(path)
		return "", err
	}
	if err := os.Rename(claimPath, path); err != nil {
		os.Remove(path)
		return "", err
	}
	return path, nil
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
// signal-0 liveness probe. Recycled and permission-inaccessible PIDs are treated
// as alive: ambiguous ownership must be preserved rather than stolen.
func pidAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, syscall.Signal(0))
	return err == nil || errors.Is(err, syscall.EPERM)
}

// SameSessionGeneration compares persisted process and result identity, never
// just the display slug. Sparse legacy rows cannot prove duplicate ownership.
func SameSessionGeneration(a, b Session) bool {
	if a.Slug != b.Slug || a.RequestID != b.RequestID || a.SessionID != b.SessionID || a.Tmux != b.Tmux || a.PID != b.PID || a.WorktreeID != b.WorktreeID || a.ExecutionDir != b.ExecutionDir {
		return false
	}
	if (a.Worktree == nil) != (b.Worktree == nil) {
		return false
	}
	if a.Worktree != nil && (a.Worktree.Epoch != b.Worktree.Epoch || a.Worktree.CanonicalPath != b.Worktree.CanonicalPath) {
		return false
	}
	return a.RequestID != "" || a.SessionID != "" || (a.Worktree != nil && a.Worktree.Epoch != "")
}
