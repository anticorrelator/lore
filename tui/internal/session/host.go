package session

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// ScanHostAdoptable runs only while the caller holds this host's runtime lock.
// Host identity and exact source placement scope recovery independently of the
// instance heartbeat TTL. An alive predecessor is never stolen.
func ScanHostAdoptable(dir, key, source, self string) ([]Instance, error) {
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
		if inst.HostKey != key || inst.ProjectDir != source {
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
			if current.HostKey != key || current.ProjectDir != source || pidAlive(current.PID) {
				return nil, fmt.Errorf("recovery claim conflicts with live ownership: %s", path)
			}
			known := map[string]bool{}
			for _, s := range current.Sessions {
				known[s.Slug] = true
			}
			for _, s := range inst.Sessions {
				if !known[s.Slug] {
					current.Sessions = append(current.Sessions, s)
				}
			}
			if err = WriteInstance(dir, current); err != nil {
				return nil, err
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
		if inst.HostKey != key || inst.ProjectDir != source || inst.Name == self || pidAlive(inst.PID) {
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
