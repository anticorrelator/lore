package worktree

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// ManagedOwner is the durable process/tmux ownership recorded by the sole
// coordination worktree manager.
type ManagedOwner struct {
	Kind       string `json:"kind"`
	ID         string `json:"id"`
	PID        int    `json:"pid,omitempty"`
	TmuxName   string `json:"tmux_name,omitempty"`
	TmuxServer string `json:"tmux_server,omitempty"`
}

// TransitionManagedPlacement asks the sole manager to advance one outer
// lifecycle state. The manager performs all validation and is the only writer.
func TransitionManagedPlacement(ctx context.Context, knowledgeDir, worktreeID, next string) error {
	return runManager(ctx, knowledgeDir, "transition", "--worktree-id", worktreeID, "--to", next)
}

// RenewManagedPlacement refreshes one live owner's lease through the sole manager.
func RenewManagedPlacement(ctx context.Context, knowledgeDir, worktreeID, ownerID string) error {
	return runManager(ctx, knowledgeDir, "renew", "--worktree-id", worktreeID, "--owner-id", ownerID)
}

// SweepManagedPlacements runs the manager's bounded stale-owner maintenance pass.
func SweepManagedPlacements(ctx context.Context, knowledgeDir string) error {
	return runManager(ctx, knowledgeDir, "sweep")
}

func runManager(ctx context.Context, knowledgeDir, verb string, args ...string) error {
	managerArgs := append([]string{"coordinate", "worktree", verb}, args...)
	managerArgs = append(managerArgs, "--kdir", knowledgeDir, "--json")
	if out, err := exec.CommandContext(ctx, "lore", managerArgs...).CombinedOutput(); err != nil {
		return fmt.Errorf("lore %s: %w: %s", strings.Join(managerArgs, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

// ManagedPlacement is the read-only projection the session host consumes from
// the manager registry. The manager scripts remain the sole writers.
type ManagedPlacement struct {
	SchemaVersion int          `json:"schema_version"`
	WorktreeID    string       `json:"worktree_id"`
	ExecutionDir  string       `json:"execution_dir"`
	State         string       `json:"state"`
	Owner         ManagedOwner `json:"owner"`
	GuardIdentity Identity     `json:"guard_identity"`
}

// ValidateManagedPlacement verifies that the hard request tuple still names the
// same live manager row and physical Git worktree. It never mutates the row.
func ValidateManagedPlacement(ctx context.Context, knowledgeDir, worktreeID, executionDir string, expected *Identity) (ManagedPlacement, error) {
	if !validEpoch.MatchString(worktreeID) {
		return ManagedPlacement{}, fmt.Errorf("invalid managed worktree id %q", worktreeID)
	}
	if executionDir == "" || !filepath.IsAbs(executionDir) {
		return ManagedPlacement{}, fmt.Errorf("managed execution directory must be absolute")
	}
	if expected == nil {
		return ManagedPlacement{}, fmt.Errorf("managed placement is missing guard identity")
	}
	rowPath := filepath.Join(knowledgeDir, "_coordination", "worktrees", "registry", worktreeID+".json")
	data, err := os.ReadFile(rowPath)
	if err != nil {
		return ManagedPlacement{}, fmt.Errorf("read managed worktree registry: %w", err)
	}
	var row ManagedPlacement
	if err := json.Unmarshal(data, &row); err != nil {
		return ManagedPlacement{}, fmt.Errorf("parse managed worktree registry: %w", err)
	}
	if row.SchemaVersion != 1 || row.WorktreeID != worktreeID || row.ExecutionDir != executionDir {
		return ManagedPlacement{}, fmt.Errorf("managed worktree registry identity mismatch")
	}
	if row.Owner.ID == "" || (row.Owner.Kind != "session" && row.Owner.Kind != "seat") {
		return ManagedPlacement{}, fmt.Errorf("managed worktree owner is incomplete")
	}
	if row.GuardIdentity != *expected {
		// A spawn retry can replay the immutable captured request after the first
		// idempotent bind advanced the manager's guard identity to active. Accept
		// exactly that one canonical transition; every other mismatch is refused.
		activated, transitionErr := Transition(*expected, StateActive)
		if transitionErr != nil || row.GuardIdentity != activated {
			return ManagedPlacement{}, fmt.Errorf("managed worktree guard identity mismatch")
		}
	}
	canonical, err := canonicalExisting(executionDir)
	if err != nil {
		return ManagedPlacement{}, err
	}
	if canonical != executionDir || canonical != row.GuardIdentity.CanonicalPath {
		return ManagedPlacement{}, fmt.Errorf("managed execution directory does not match canonical guard path")
	}
	if err := ValidateIdentity(ctx, row.GuardIdentity); err != nil {
		return ManagedPlacement{}, err
	}
	return row, nil
}
