package projection

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"syscall"
	"time"
)

// TryMaintenance admits at most two background updaters. Persistent tickets
// preserve retry order; abandoned tickets expire without a service to reap them.
// Snapshot readers never acquire this admission lock.
func TryMaintenance(store string) (*os.File, error) {
	root := filepath.Join("/tmp", fmt.Sprintf("lore-coordination-updaters-%d", os.Getuid()))
	return tryMaintenance(root, store)
}

type maintenanceTicket struct {
	Created int64 `json:"created"`
	Seen    int64 `json:"seen"`
}

func tryMaintenance(root, store string) (*os.File, error) {
	return tryMaintenanceAt(root, store, time.Now())
}

func tryMaintenanceAt(root, store string, now time.Time) (*os.File, error) {
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, err
	}
	gate, err := os.OpenFile(filepath.Join(root, "admission.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	defer gate.Close()
	if err = syscall.Flock(int(gate.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
			return nil, nil
		}
		return nil, err
	}
	key := fmt.Sprintf("%x.ticket", sha256.Sum256([]byte(store)))
	ticket := filepath.Join(root, key)
	request := maintenanceTicket{Created: now.UnixNano(), Seen: now.UnixNano()}
	if data, err := os.ReadFile(ticket); err == nil {
		var prior maintenanceTicket
		if json.Unmarshal(data, &prior) == nil && prior.Created > 0 {
			request.Created = prior.Created
		}
	}
	data, _ := json.Marshal(request)
	if err := os.WriteFile(ticket, data, 0600); err != nil {
		return nil, err
	}
	type entry struct {
		name string
		at   time.Time
	}
	var waiting []entry
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}
	for _, candidate := range entries {
		if filepath.Ext(candidate.Name()) != ".ticket" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(root, candidate.Name()))
		if err != nil {
			continue
		}
		var queued maintenanceTicket
		if json.Unmarshal(data, &queued) != nil || now.Sub(time.Unix(0, queued.Seen)) > 30*time.Second {
			_ = os.Remove(filepath.Join(root, candidate.Name()))
			continue
		}
		waiting = append(waiting, entry{candidate.Name(), time.Unix(0, queued.Created)})
	}
	sort.Slice(waiting, func(i, j int) bool {
		if waiting[i].at.Equal(waiting[j].at) {
			return waiting[i].name < waiting[j].name
		}
		return waiting[i].at.Before(waiting[j].at)
	})
	if len(waiting) == 0 || waiting[0].name != key {
		return nil, nil
	}
	for slot := 0; slot < HostLimit; slot++ {
		lease, err := os.OpenFile(filepath.Join(root, fmt.Sprintf("%d.lock", slot)), os.O_CREATE|os.O_RDWR, 0600)
		if err != nil {
			return nil, err
		}
		err = syscall.Flock(int(lease.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			_ = os.Remove(ticket)
			return lease, nil
		}
		lease.Close()
		if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EAGAIN) {
			return nil, err
		}
	}
	return nil, nil
}
