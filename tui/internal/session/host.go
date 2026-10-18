package session

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/anticorrelator/lore/tui/internal/config"
)

// StoreHostKey is the host key of the session host serving the store at kdir,
// a symlink-resolved path, in the named runtime ("" for the default runtime):
// the first 24 hex digits of sha256(kdir), or of sha256(kdir NUL "runtime" NUL
// runtime) under a named runtime. The queue and registry are shared by every
// runtime and claims match on this key, so the runtime name is part of it.
func StoreHostKey(kdir, runtime string) string {
	material := kdir
	if runtime != "" {
		material += "\x00runtime\x00" + runtime
	}
	sum := sha256.Sum256([]byte(material))
	return hex.EncodeToString(sum[:])[:24]
}

// HostRecoveryKeys is the set of host keys whose dead registry rows the store
// host with key own adopts: own, and, in the default runtime only, every key
// whose <sessionsDir>/hosts/<K>/migrated.json names own as its destination. A
// named runtime adopts its own key alone, because a legacy per-checkout key
// carries no runtime name and may index another runtime's records.
func HostRecoveryKeys(sessionsDir, own string) (map[string]bool, error) {
	runtime, err := config.SessionRuntime()
	if err != nil {
		return nil, err
	}
	keys := map[string]bool{own: true}
	if runtime != "" {
		return keys, nil
	}
	records, err := filepath.Glob(filepath.Join(sessionsDir, "hosts", "*", "migrated.json"))
	if err != nil {
		return nil, err
	}
	for _, path := range records {
		b, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var record struct {
			From string `json:"from"`
			To   string `json:"to"`
		}
		if json.Unmarshal(b, &record) == nil && record.To == own && record.From != "" {
			keys[record.From] = true
		}
	}
	return keys, nil
}

// adoptableRuntime reports whether a row written in runtime rowRuntime may be
// adopted by a process in runtime. A row without the field decodes as "", the
// default runtime, which is the only runtime that may adopt such a row.
func adoptableRuntime(rowRuntime, runtime string) bool {
	return rowRuntime == runtime
}

// ScanHostAdoptable runs only while the caller holds this host's runtime lock.
// A row belongs to the host when its host key is in keys and it was written in
// this process's runtime; no checkout is compared, since a store host serves
// every checkout of its store. An alive predecessor is never stolen, and the
// heartbeat TTL plays no part.
func ScanHostAdoptable(dir string, keys map[string]bool, self string) ([]Instance, error) {
	runtime, err := config.SessionRuntime()
	if err != nil {
		return nil, err
	}
	owned := func(inst Instance) bool { return keys[inst.HostKey] && adoptableRuntime(inst.Runtime, runtime) }
	claims, err := filepath.Glob(filepath.Join(InstancesDir(dir), "*.json.adopting.*"))
	if err != nil {
		return nil, err
	}
	for _, path := range claims {
		b, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		var inst Instance
		if err = json.Unmarshal(b, &inst); err != nil {
			continue // An unidentifiable row is preserved for diagnosis, never claimed.
		}
		if !owned(inst) {
			continue
		}
		pid, _ := strconv.Atoi(path[strings.LastIndex(path, ".")+1:])
		if pidAlive(pid) || pidAlive(inst.PID) {
			continue
		}
		original := strings.Split(path, ".json.adopting.")[0] + ".json"
		if _, err = os.Stat(original); os.IsNotExist(err) {
			if err = os.Rename(path, original); err != nil {
				return nil, err
			}
		} else if err != nil {
			return nil, err
		} else {
			// A previous recovery transferred the same manifest before dying. Merge
			// ownership before removing the redundant claim; never discard sessions.
			b, err = os.ReadFile(original)
			if err != nil {
				return nil, err
			}
			var current Instance
			if err = json.Unmarshal(b, &current); err != nil {
				return nil, err
			}
			if !owned(current) || pidAlive(current.PID) {
				return nil, fmt.Errorf("recovery claim conflicts with live ownership: %s", path)
			}
			// An existing newer snapshot may have closed a session. Never merge
			// older membership back into it. Only retire a fully duplicated claim;
			// otherwise preserve both records for explicit reconciliation.
			for _, old := range inst.Sessions {
				found := false
				for _, live := range current.Sessions {
					if SameSessionGeneration(old, live) {
						found = true
						break
					}
				}
				if !found {
					return nil, fmt.Errorf("recovery claim retains conflicting generation: %s", path)
				}
			}

			if err = os.Remove(path); err != nil {
				return nil, err
			}
		}
	}
	paths, err := filepath.Glob(filepath.Join(InstancesDir(dir), "*.json"))
	if err != nil {
		return nil, err
	}
	var out []Instance
	for _, path := range paths {
		b, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		var inst Instance
		if err = json.Unmarshal(b, &inst); err != nil {
			continue // No scoped ownership can be established.
		}
		if !owned(inst) || inst.Name == self || pidAlive(inst.PID) {
			continue
		}
		out = append(out, inst)
	}
	sort.SliceStable(out, func(i, j int) bool {
		return out[i].Role != "session-host-spawn" && out[j].Role == "session-host-spawn"
	})
	return out, nil
}

// OwnershipInstances includes dead and adoption-claimed owners: heartbeat age
// does not release a workspace reservation.
func OwnershipInstances(dir string) ([]Instance, error) {
	paths, err := filepath.Glob(filepath.Join(InstancesDir(dir), "*.json*"))
	if err != nil {
		return nil, err
	}
	var rows []Instance
	for _, path := range paths {
		b, err := os.ReadFile(path)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return nil, err
		}
		var row Instance
		if err = json.Unmarshal(b, &row); err != nil {
			return nil, err
		}
		rows = append(rows, row)
	}
	return rows, nil
}
func ProcessAlive(pid int) bool { return pidAlive(pid) }
