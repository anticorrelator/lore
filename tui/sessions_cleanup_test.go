package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/worktree"
)

// closedSessionWorktree stands up a real repository, runs one session checkout
// through to a terminal state, and returns the store root, the repository and
// the published identity.
func closedSessionWorktree(t *testing.T, epoch string) (string, string, worktree.Identity) {
	t.Helper()
	ctx := context.Background()
	root := t.TempDir()
	repo := filepath.Join(root, "repo")
	if err := os.MkdirAll(repo, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{"init", "-b", "main"},
		{"config", "user.email", "lore@localhost"},
		{"config", "user.name", "Lore"},
	} {
		if out, err := exec.Command("git", append([]string{"-C", repo}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	if err := os.WriteFile(filepath.Join(repo, "tracked.txt"), []byte("generation A\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"add", "tracked.txt"}, {"commit", "-m", "generation A"}} {
		if out, err := exec.Command("git", append([]string{"-C", repo}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}

	path := filepath.Join(root, "_sessions", "worktrees", epoch)
	identity, err := worktree.Create(ctx, repo, path, epoch)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	identity, err = worktree.Transition(identity, worktree.StateActive)
	if err != nil {
		t.Fatalf("activate: %v", err)
	}
	if err := os.WriteFile(filepath.Join(path, "session-only.txt"), []byte("session output\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	identity, artifact, err := worktree.MakePublishable(ctx, identity)
	if err != nil {
		t.Fatalf("MakePublishable: %v", err)
	}
	outcome, err := worktree.Publish(ctx, identity, artifact, repo)
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}
	return root, repo, outcome.Identity
}

func refOID(t *testing.T, repo, ref string) string {
	t.Helper()
	out, err := exec.Command("git", "-C", repo, "rev-parse", "--verify", "--quiet", ref).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// The close path's whole job: once a session's disposition has landed, its
// checkout is reclaimed and everything that records what the session produced
// stays readable.
func TestCloseReclaimsSessionCheckoutAndKeepsItsRefs(t *testing.T) {
	_, repo, identity := closedSessionWorktree(t, "20260725T000000Z-closed")

	capturedBefore := refOID(t, repo, "refs/lore/worktrees/20260725T000000Z-closed/captured")
	resultBefore := refOID(t, repo, "refs/lore/worktrees/20260725T000000Z-closed/result")
	if capturedBefore == "" || resultBefore == "" {
		t.Fatal("fixture did not preserve the session refs")
	}

	cmd := sessionWorktreeCleanupCmd("demo", liveSession{worktree: &identity})
	if cmd == nil {
		t.Fatal("close path produced no cleanup for a terminal session-owned checkout")
	}
	msg, ok := cmd().(sessionWorktreeCleanedMsg)
	if !ok {
		t.Fatalf("cleanup Cmd returned %T", cmd())
	}
	if msg.err != nil {
		t.Fatalf("cleanup: %v", msg.err)
	}
	if !msg.proof.Verified || !msg.proof.PathAbsent || !msg.proof.RegistryAbsent || !msg.proof.AdminDirAbsent {
		t.Fatalf("incomplete proof: %+v", msg.proof)
	}
	if msg.proof.RefsDisposition != "preserved" {
		t.Fatalf("refs disposition = %q, want preserved", msg.proof.RefsDisposition)
	}

	if _, err := os.Lstat(identity.CanonicalPath); !os.IsNotExist(err) {
		t.Fatalf("checkout survived close: %v", err)
	}
	if got := refOID(t, repo, "refs/lore/worktrees/20260725T000000Z-closed/captured"); got != capturedBefore {
		t.Fatalf("captured ref = %q, want %q", got, capturedBefore)
	}
	if got := refOID(t, repo, "refs/lore/worktrees/20260725T000000Z-closed/result"); got != resultBefore {
		t.Fatalf("result ref = %q, want %q", got, resultBefore)
	}
	out, err := exec.Command("git", "-C", repo, "show", resultBefore+":session-only.txt").Output()
	if err != nil || string(out) != "session output\n" {
		t.Fatalf("session output unreadable after close: %q (%v)", out, err)
	}
}

// A managed session executes in a tree the coordination worktree manager owns.
// The session close path must leave it entirely alone.
func TestCloseNeverReclaimsAManagedTree(t *testing.T) {
	_, _, identity := closedSessionWorktree(t, "20260725T000000Z-managed")

	ls := liveSession{worktree: &identity, worktreeID: "wt-1", executionDir: identity.CanonicalPath}
	if cmd := sessionWorktreeCleanupCmd("demo", ls); cmd != nil {
		t.Fatal("close path tried to reclaim a manager-owned tree")
	}
	if _, err := os.Lstat(identity.CanonicalPath); err != nil {
		t.Fatalf("managed tree was disturbed: %v", err)
	}
}

func TestCloseLeavesNonTerminalAndLegacySessionsAlone(t *testing.T) {
	_, _, identity := closedSessionWorktree(t, "20260725T000000Z-live")

	live := identity
	live.State = worktree.StateActive
	if cmd := sessionWorktreeCleanupCmd("demo", liveSession{worktree: &live}); cmd != nil {
		t.Fatal("close path tried to reclaim an active checkout")
	}
	if cmd := sessionWorktreeCleanupCmd("demo", liveSession{}); cmd != nil {
		t.Fatal("close path tried to reclaim a legacy session with no worktree identity")
	}
	if _, err := os.Lstat(identity.CanonicalPath); err != nil {
		t.Fatalf("live checkout was disturbed: %v", err)
	}
}

// The backstop for a TUI killed mid-teardown: no handler ever ran, no registry
// row survives, and the sweep is the only thing that will ever visit the tree.
func TestStartupSweepReclaimsCrashLeakedCheckouts(t *testing.T) {
	root, repo, identity := closedSessionWorktree(t, "20260725T000000Z-crashed")

	m := model{
		config:      config.Config{KnowledgeDir: root, ProjectDir: root},
		sessionsDir: filepath.Join(root, "_sessions"),
	}
	msg, ok := m.sweepSessionWorktreesCmd()().(sessionWorktreeSweptMsg)
	if !ok {
		t.Fatal("sweep Cmd returned the wrong message type")
	}
	if len(msg.failures) != 0 {
		t.Fatalf("sweep failures: %v", msg.failures)
	}
	if len(msg.proofs) != 1 || msg.proofs[0].Epoch != "20260725T000000Z-crashed" {
		t.Fatalf("proofs = %+v, want the crash-leaked checkout", msg.proofs)
	}
	if _, err := os.Lstat(identity.CanonicalPath); !os.IsNotExist(err) {
		t.Fatalf("leaked checkout survived the sweep: %v", err)
	}
	if refOID(t, repo, "refs/lore/worktrees/20260725T000000Z-crashed/result") == "" {
		t.Fatal("sweep deleted the result ref it exists to preserve")
	}
}

// A checkout a registry row still claims is held back even when it would
// otherwise qualify — the sweep never races an instance that may still be using
// its tree.
func TestStartupSweepHoldsBackCheckoutsARegistryRowClaims(t *testing.T) {
	root, _, identity := closedSessionWorktree(t, "20260725T000000Z-claimed")

	sessionsDir := filepath.Join(root, "_sessions")
	if err := session.WriteInstance(sessionsDir, session.Instance{
		Name: "other", PID: os.Getpid(), Repo: "repo",
		Sessions: []session.Session{{Slug: "demo", Worktree: &identity}},
	}); err != nil {
		t.Fatal(err)
	}

	m := model{config: config.Config{KnowledgeDir: root, ProjectDir: root}, sessionsDir: sessionsDir}
	msg := m.sweepSessionWorktreesCmd()().(sessionWorktreeSweptMsg)
	if len(msg.proofs) != 0 || len(msg.failures) != 0 {
		t.Fatalf("sweep touched a claimed checkout: proofs=%+v failures=%v", msg.proofs, msg.failures)
	}
	if _, err := os.Lstat(identity.CanonicalPath); err != nil {
		t.Fatalf("claimed checkout was removed: %v", err)
	}
}
