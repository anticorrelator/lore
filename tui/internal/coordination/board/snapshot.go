package board

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"github.com/anticorrelator/lore/tui/internal/projection"
	"github.com/anticorrelator/lore/tui/internal/session"
)

type ArcSummary struct {
	Slug, Title, Status, Project, Opened, ClosedAt string
	Members                                        []string
}

type Snapshot struct {
	statusProjection
	SchemaVersion   string         `json:"schema_version"`
	Store           string         `json:"store"`
	ArchiveIdentity string         `json:"archive_identity"`
	Epoch           string         `json:"epoch"`
	WorkCounts      map[string]int `json:"work_counts"`
	Generation      uint64         `json:"generation"`
	NextUpdate      float64        `json:"next_update"`
	Arcs            []ArcSummary   `json:"arcs"`
	Skipped         int            `json:"skipped"`
	Coverage        struct {
		State        string `json:"state"`
		ObservedAt   string `json:"observed_at"`
		ReconciledAt string `json:"reconciled_at"`
		Error        string `json:"error"`
	} `json:"coverage"`
	Details map[string]struct {
		Events []session.Event `json:"events"`
		Loaded bool            `json:"loaded"`
		Error  string          `json:"error"`
	} `json:"details"`
	Activity  map[string]string `json:"activity"`
	Rows      []Row             `json:"-"`
	Found     bool              `json:"-"`
	Attention Attention         `json:"-"`
}

func readSnapshot(store, arc string) (Snapshot, error) {
	var snapshot Snapshot
	data, err := os.ReadFile(filepath.Join(store, "_coordination", "display.json"))
	if err != nil {
		return snapshot, err
	}
	if err = json.Unmarshal(data, &snapshot); err != nil {
		return snapshot, err
	}
	resolved, err := filepath.EvalSymlinks(store)
	if err != nil {
		return snapshot, err
	}
	resolved, _ = filepath.Abs(resolved)
	if snapshot.SchemaVersion != "1" || snapshot.Store != resolved || snapshot.Epoch == "" {
		return snapshot, fmt.Errorf("coordination snapshot identity or version is incompatible")
	}
	snapshot.Rows, snapshot.Found, err = rowsFromProjection(snapshot.statusProjection, arc)
	if err != nil {
		return snapshot, err
	}
	snapshot.Attention, err = attentionFromProjection(snapshot.statusProjection)
	return snapshot, err
}

// LoadSnapshot reads the atomic export directly. Only the nonblocking store
// owner starts Python; other instances return the last committed generation.
func LoadSnapshot(ctx context.Context, store, arc string) (Snapshot, error) {
	resolved, resolveErr := filepath.EvalSymlinks(store)
	if resolveErr != nil {
		return Snapshot{}, resolveErr
	}
	store, resolveErr = filepath.Abs(resolved)
	if resolveErr != nil {
		return Snapshot{}, resolveErr
	}
	before, readErr := readSnapshot(store, arc)
	now := float64(time.Now().UnixNano()) / 1e9
	due := readErr != nil || now >= before.NextUpdate
	if readErr == nil && now > before.NextUpdate+5 {
		before.Coverage.State = "stale"
	}
	needsDetail := arc != "" && !before.Details[arc].Loaded
	root := filepath.Join(store, "_coordination")
	if due || needsDetail {
		if err := os.MkdirAll(root, 0700); err != nil {
			return before, err
		}
		if arc != "" {
			if filepath.Base(arc) != arc || arc == "." || arc == ".." {
				return before, fmt.Errorf("invalid arc identity")
			}
			requests := filepath.Join(root, "display-requests")
			if err := os.MkdirAll(requests, 0700); err != nil {
				return before, err
			}
			file, err := os.OpenFile(filepath.Join(requests, arc), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
			if err == nil {
				file.Close()
			} else if !errors.Is(err, os.ErrExist) {
				return before, err
			}
		}
		lease, err := os.OpenFile(filepath.Join(root, "display.lock"), os.O_CREATE|os.O_RDWR, 0600)
		if err != nil {
			return before, err
		}
		defer lease.Close()
		if err = syscall.Flock(int(lease.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err == nil {
			// A winner may have published while this reader was opening its
			// lease. Recheck before paying interpreter startup.
			latest, latestErr := readSnapshot(store, arc)
			if latestErr == nil && now < latest.NextUpdate && (arc == "" || latest.Details[arc].Loaded) {
				return latest, nil
			}
			admission, admissionErr := projection.TryMaintenance(store)
			if admissionErr != nil {
				return before, admissionErr
			}
			if admission == nil {
				before.Coverage.State = "stale"
				return before, readErr
			}
			defer admission.Close()
			cmd := exec.CommandContext(ctx, "lore", "coordinate", "read", "--kdir", store, "--refresh", "--json", "--lease-fd", "3")
			cmd.ExtraFiles = []*os.File{lease, admission}
			if _, err = projection.SnapshotOutput(ctx, cmd, true); err != nil {
				return before, fmt.Errorf("coordination refresh: %w", err)
			}
			return readSnapshot(store, arc)
		} else if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EAGAIN) {
			return before, err
		}
	}
	return before, readErr
}
