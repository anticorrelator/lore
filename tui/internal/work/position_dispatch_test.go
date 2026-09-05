package work

import (
	"encoding/json"
	"github.com/anticorrelator/lore/tui/internal/worktree"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPositionMaterializationRefusesIncompatibleDescriptors(t *testing.T) {
	for _, d := range []SessionDescriptor{
		{Type: SessionChat, Model: "opaque", PositionContext: json.RawMessage(`{}`)},
		{Type: SessionWorker, PositionContext: json.RawMessage(`{}`)},
	} {
		if _, err := materializePosition(d, "codex", "/unallocated", "/unused"); err == nil {
			t.Fatal("invalid descriptor admitted")
		}
	}
	legacy, err := materializePosition(SessionDescriptor{Type: SessionWorker, ExtraContext: "legacy"}, "codex", "/unallocated", "/unused")
	if err != nil || legacy != nil {
		t.Fatal("legacy started binding")
	}
}

func TestPositionSeatOwnerCannotBypassSessionHost(t *testing.T) {
	identity := mustSessionWorktree(t)
	kdir := t.TempDir()
	registry := filepath.Join(kdir, "_coordination", "worktrees", "registry")
	if err := os.MkdirAll(registry, 0755); err != nil {
		t.Fatal(err)
	}
	placement := worktree.ManagedPlacement{SchemaVersion: 1, WorktreeID: "seat", ExecutionDir: identity.CanonicalPath, State: "reserved", Owner: worktree.ManagedOwner{Kind: "seat", ID: "manager"}, GuardIdentity: identity}
	data, _ := json.Marshal(placement)
	if err := os.WriteFile(filepath.Join(registry, "seat.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	d := SessionDescriptor{Type: SessionWorker, Worktree: &identity, WorktreeID: "seat", ExecutionDir: identity.CanonicalPath, Model: "opaque", PositionContext: json.RawMessage(`{"position_preparation":{}}`)}
	msg := StartTerminalCmd(d, 80, 24, kdir, SessionEnv{}, false)()
	failed, ok := msg.(StreamErrorMsg)
	if !ok || !strings.Contains(failed.Err.Error(), "cannot host a session") {
		t.Fatalf("seat owner admitted: %+v", msg)
	}
}
