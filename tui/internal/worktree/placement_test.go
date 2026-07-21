package worktree

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestValidateManagedPlacementRequiresExactRegistryProjection(t *testing.T) {
	source := filepath.Join(t.TempDir(), "source")
	initRepository(t, source)
	writeFile(t, filepath.Join(source, "marker"), []byte("base\n"))
	git(t, source, "add", "marker")
	git(t, source, "commit", "-m", "base")
	identity, err := Create(context.Background(), source, filepath.Join(t.TempDir(), "managed"), "managed-epoch")
	if err != nil {
		t.Fatal(err)
	}
	kdir := t.TempDir()
	registry := filepath.Join(kdir, "_coordination", "worktrees", "registry")
	if err := os.MkdirAll(registry, 0o755); err != nil {
		t.Fatal(err)
	}
	row := ManagedPlacement{
		SchemaVersion: 1, WorktreeID: "tree-1", ExecutionDir: identity.CanonicalPath,
		State: "reserved", Owner: ManagedOwner{Kind: "session", ID: "worker-1"}, GuardIdentity: identity,
	}
	data, err := json.Marshal(row)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(registry, "tree-1.json"), data, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := ValidateManagedPlacement(context.Background(), kdir, "tree-1", identity.CanonicalPath, &identity); err != nil {
		t.Fatalf("valid placement refused: %v", err)
	}
	if _, err := ValidateManagedPlacement(context.Background(), kdir, "tree-1", source, &identity); err == nil {
		t.Fatal("execution-dir mismatch was accepted")
	}
	other := identity
	other.Epoch = "other-epoch"
	if _, err := ValidateManagedPlacement(context.Background(), kdir, "tree-1", identity.CanonicalPath, &other); err == nil {
		t.Fatal("guard identity mismatch was accepted")
	}
}
