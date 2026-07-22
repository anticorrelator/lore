// Package coordination backs the coordination-centric TUI view: an arc list
// (projects whose home carries a coordination.md ledger) with a four-tab
// detail — Status, Sessions, Items, Ledger. The package renders host-pushed
// state and does no disk I/O of its own except ReadPin, which callers invoke
// inside a tea.Cmd.
package coordination

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// Arc is one coordination arc: a project whose home contains coordination.md.
type Arc struct {
	Slug    string
	Members int
}

// Pin is the sticky dispatch pin from _coordination.json (schema v1). Field
// types must match the sidecar exactly — the sole writer is
// scripts/coordinate-pin.sh, and the pin key is omitted entirely when cleared.
type Pin struct {
	Instance string `json:"instance"`
	PinnedAt string `json:"pinned_at"`
	PinnedBy string `json:"pinned_by,omitempty"`
}

type pinSidecar struct {
	SchemaVersion int  `json:"schema_version"`
	Pin           *Pin `json:"pin"`
}

// PinStatus is the derived pin state. Liveness is never stored in the
// sidecar: readers join Pin.Instance against the session registry's mtime TTL
// at read time. Absent, live, and dead are three distinct first-class states.
type PinStatus int

const (
	PinAbsent PinStatus = iota
	PinLive
	PinDead
)

// ReadPin reads the pin sidecar in the given project home. A missing sidecar
// or a sidecar with no pin key both return (nil, nil) — pin-less is a
// first-class state, not an error. A malformed sidecar returns the parse
// error so it surfaces instead of silently reading as unpinned.
func ReadPin(homeDir string) (*Pin, error) {
	data, err := os.ReadFile(filepath.Join(homeDir, "_coordination.json"))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var sc pinSidecar
	if err := json.Unmarshal(data, &sc); err != nil {
		return nil, err
	}
	return sc.Pin, nil
}
