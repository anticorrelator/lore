package worktree

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The property this whole file exists to defend: cleanup removes the checkout
// and keeps every ref. The coordination worktree manager deletes those refs as
// part of its own proof, so reusing its shape here would delete exactly the
// content that makes removal safe.
func TestCleanupRemovesPublishedCheckoutAndPreservesEveryRef(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	initRepository(t, source)
	writeFile(t, filepath.Join(source, "tracked.txt"), []byte("generation A\n"))
	git(t, source, "add", "tracked.txt")
	git(t, source, "commit", "-m", "generation A")

	sessionPath := filepath.Join(root, "session")
	identity, err := Create(ctx, source, sessionPath, "session-published")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	identity, err = Transition(identity, StateActive)
	if err != nil {
		t.Fatalf("activate: %v", err)
	}
	writeFile(t, filepath.Join(sessionPath, "tracked.txt"), []byte("session result\n"))
	writeFile(t, filepath.Join(sessionPath, "session-only.txt"), []byte("new file\n"))
	identity, artifact, err := MakePublishable(ctx, identity)
	if err != nil {
		t.Fatalf("MakePublishable: %v", err)
	}
	outcome, err := Publish(ctx, identity, artifact, source)
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if outcome.Kind != OutcomePublished {
		t.Fatalf("outcome kind = %q, want %q", outcome.Kind, OutcomePublished)
	}

	capturedOID := revParse(t, source, capturedRefFor("session-published"))
	resultOID := revParse(t, source, resultRefFor("session-published"))
	adminDir := outcome.Identity.GitDir

	proof, err := CleanupSessionCheckout(ctx, outcome.Identity)
	if err != nil {
		t.Fatalf("CleanupSessionCheckout: %v", err)
	}

	if !proof.Verified || !proof.PathAbsent || !proof.RegistryAbsent || !proof.AdminDirAbsent {
		t.Fatalf("incomplete proof: %+v", proof)
	}
	if proof.RefsDisposition != "preserved" {
		t.Fatalf("refs disposition = %q, want preserved", proof.RefsDisposition)
	}
	if proof.BranchDisposition != "detached (no branch created)" {
		t.Fatalf("branch disposition = %q", proof.BranchDisposition)
	}
	if proof.ContentProvenBy != resultRefFor("session-published") {
		t.Fatalf("content proven by %q, want the result ref", proof.ContentProvenBy)
	}

	if _, err := os.Lstat(sessionPath); !os.IsNotExist(err) {
		t.Fatalf("checkout survived cleanup: %v", err)
	}
	if _, err := os.Lstat(adminDir); !os.IsNotExist(err) {
		t.Fatalf("admin directory survived cleanup: %v", err)
	}
	if listing := string(gitBytes(t, source, "worktree", "list", "--porcelain")); strings.Contains(listing, sessionPath) {
		t.Fatalf("Git registry still names the checkout:\n%s", listing)
	}

	// The refs, and the content behind them, outlive the directory.
	if got := revParse(t, source, capturedRefFor("session-published")); got != capturedOID {
		t.Fatalf("captured ref = %q, want %q", got, capturedOID)
	}
	if got := revParse(t, source, resultRefFor("session-published")); got != resultOID {
		t.Fatalf("result ref = %q, want %q", got, resultOID)
	}
	if got := string(gitBytes(t, source, "show", resultOID+":session-only.txt")); got != "new file\n" {
		t.Fatalf("session content unreadable after cleanup: %q", got)
	}
}

func TestCleanupPreservesQuarantineRefAndPatch(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	initRepository(t, source)
	writeFile(t, filepath.Join(source, "tracked.txt"), []byte("generation A\n"))
	git(t, source, "add", "tracked.txt")
	git(t, source, "commit", "-m", "generation A")

	sessionPath := filepath.Join(root, "session")
	identity, err := Create(ctx, source, sessionPath, "session-quarantined")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	identity, err = Transition(identity, StateActive)
	if err != nil {
		t.Fatalf("activate: %v", err)
	}
	writeFile(t, filepath.Join(sessionPath, "tracked.txt"), []byte("session result\n"))
	identity, artifact, err := MakePublishable(ctx, identity)
	if err != nil {
		t.Fatalf("MakePublishable: %v", err)
	}
	// Drift the destination so publishing refuses and quarantines instead.
	writeFile(t, filepath.Join(source, "tracked.txt"), []byte("host moved on\n"))
	outcome, err := Publish(ctx, identity, artifact, source)
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if outcome.Kind != OutcomeWorktreeQuarantined {
		t.Fatalf("outcome kind = %q, want %q", outcome.Kind, OutcomeWorktreeQuarantined)
	}
	quarantineOID := revParse(t, source, quarantineRefFor("session-quarantined"))
	patchPath := outcome.Artifact.PatchPath

	proof, err := CleanupSessionCheckout(ctx, outcome.Identity)
	if err != nil {
		t.Fatalf("CleanupSessionCheckout: %v", err)
	}
	if !proof.Verified {
		t.Fatalf("incomplete proof: %+v", proof)
	}
	// Result and quarantine describe the same tree whenever the session wrote
	// nothing between the two; either is a sufficient preservation proof.
	switch proof.ContentProvenBy {
	case resultRefFor("session-quarantined"), quarantineRefFor("session-quarantined"):
	default:
		t.Fatalf("content proven by %q, want the result or quarantine ref", proof.ContentProvenBy)
	}
	if got := revParse(t, source, quarantineRefFor("session-quarantined")); got != quarantineOID {
		t.Fatalf("quarantine ref = %q, want %q", got, quarantineOID)
	}
	if _, err := os.Lstat(patchPath); err != nil {
		t.Fatalf("quarantine patch did not survive cleanup: %v", err)
	}
	if got := string(gitBytes(t, source, "show", quarantineOID+":tracked.txt")); got != "session result\n" {
		t.Fatalf("quarantined session content unreadable after cleanup: %q", got)
	}
}

// A session that committed its work checks out a branch to hold it. Removing
// the checkout must release the branch, never delete it — the branch is the
// session's output, in the same class as its refs.
func TestCleanupPreservesABranchTheSessionCommittedOnto(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	initRepository(t, source)
	writeFile(t, filepath.Join(source, "tracked.txt"), []byte("generation A\n"))
	git(t, source, "add", "tracked.txt")
	git(t, source, "commit", "-m", "generation A")

	sessionPath := filepath.Join(root, "session")
	identity, err := Create(ctx, source, sessionPath, "session-branched")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	identity, err = Transition(identity, StateActive)
	if err != nil {
		t.Fatalf("activate: %v", err)
	}
	// The session commits its work onto a stream branch, the way a worker does.
	writeFile(t, filepath.Join(sessionPath, "tracked.txt"), []byte("committed work\n"))
	git(t, sessionPath, "checkout", "-b", "lore/streams/demo/s1/a1")
	git(t, sessionPath, "add", "tracked.txt")
	git(t, sessionPath, "commit", "-m", "session work")
	branchOID := revParse(t, source, "refs/heads/lore/streams/demo/s1/a1")
	if branchOID == "" {
		t.Fatal("fixture did not create the branch")
	}

	identity, artifact, err := MakePublishable(ctx, identity)
	if err != nil {
		t.Fatalf("MakePublishable: %v", err)
	}
	outcome, err := Publish(ctx, identity, artifact, source)
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}

	proof, err := CleanupSessionCheckout(ctx, outcome.Identity)
	if err != nil {
		t.Fatalf("CleanupSessionCheckout: %v", err)
	}
	if !proof.Verified {
		t.Fatalf("incomplete proof: %+v", proof)
	}
	if proof.BranchDisposition != "preserved refs/heads/lore/streams/demo/s1/a1" {
		t.Fatalf("branch disposition = %q, want the branch preserved", proof.BranchDisposition)
	}
	if _, err := os.Lstat(sessionPath); !os.IsNotExist(err) {
		t.Fatalf("checkout survived cleanup: %v", err)
	}
	if got := revParse(t, source, "refs/heads/lore/streams/demo/s1/a1"); got != branchOID {
		t.Fatalf("branch = %q, want %q — cleanup took the session's branch with the checkout", got, branchOID)
	}
	if got := string(gitBytes(t, source, "show", branchOID+":tracked.txt")); got != "committed work\n" {
		t.Fatalf("committed work unreadable after cleanup: %q", got)
	}
}

// A session that is still running is exactly what must never be removed.
func TestCleanupRefusesNonTerminalStates(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	initRepository(t, source)
	writeFile(t, filepath.Join(source, "tracked.txt"), []byte("generation A\n"))
	git(t, source, "add", "tracked.txt")
	git(t, source, "commit", "-m", "generation A")

	sessionPath := filepath.Join(root, "session")
	identity, err := Create(ctx, source, sessionPath, "session-live")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	for _, state := range []LifecycleState{StateCaptured, StateActive, StatePublishable, StateTeardownPending} {
		live := identity
		live.State = state
		if _, err := CleanupSessionCheckout(ctx, live); !errors.Is(err, ErrNotCleanupEligible) {
			t.Fatalf("state %q: err = %v, want ErrNotCleanupEligible", state, err)
		}
		if _, err := os.Lstat(sessionPath); err != nil {
			t.Fatalf("state %q: live checkout was disturbed: %v", state, err)
		}
	}
}

// Content written after the result was materialized is described by no ref, so
// removing the directory would lose it. Refusing is the required outcome.
func TestCleanupRefusesCheckoutContentNoRefDescribes(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	initRepository(t, source)
	writeFile(t, filepath.Join(source, "tracked.txt"), []byte("generation A\n"))
	git(t, source, "add", "tracked.txt")
	git(t, source, "commit", "-m", "generation A")

	sessionPath := filepath.Join(root, "session")
	identity, err := Create(ctx, source, sessionPath, "session-drifted")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	identity, err = Transition(identity, StateActive)
	if err != nil {
		t.Fatalf("activate: %v", err)
	}
	identity, artifact, err := MakePublishable(ctx, identity)
	if err != nil {
		t.Fatalf("MakePublishable: %v", err)
	}
	outcome, err := Publish(ctx, identity, artifact, source)
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}

	// The harness kept writing after teardown began.
	writeFile(t, filepath.Join(sessionPath, "late-work.txt"), []byte("not in any ref\n"))

	if _, err := CleanupSessionCheckout(ctx, outcome.Identity); err == nil {
		t.Fatal("cleanup accepted content no ref describes")
	}
	assertBytes(t, filepath.Join(sessionPath, "late-work.txt"), []byte("not in any ref\n"))
}

// The crash backstop: a checkout with no handler and no registry row left to
// speak for it, found only by scanning.
func TestSweepReclaimsAbandonedCheckoutAndSkipsLiveAndReserved(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	initRepository(t, source)
	writeFile(t, filepath.Join(source, "tracked.txt"), []byte("generation A\n"))
	git(t, source, "add", "tracked.txt")
	git(t, source, "commit", "-m", "generation A")

	worktreesDir := filepath.Join(root, "_sessions", "worktrees")
	if err := os.MkdirAll(worktreesDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	// abandoned: reached a terminal state, then the TUI died before removing it.
	abandoned := filepath.Join(worktreesDir, "abandoned")
	identity, err := Create(ctx, source, abandoned, "abandoned")
	if err != nil {
		t.Fatalf("Create abandoned: %v", err)
	}
	identity, _ = Transition(identity, StateActive)
	identity, artifact, err := MakePublishable(ctx, identity)
	if err != nil {
		t.Fatalf("MakePublishable: %v", err)
	}
	if _, err := Publish(ctx, identity, artifact, source); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	abandonedResult := revParse(t, source, resultRefFor("abandoned"))

	// live: still running, so it has only a captured ref and no registry row is
	// needed to protect it.
	live := filepath.Join(worktreesDir, "live")
	if _, err := Create(ctx, source, live, "live"); err != nil {
		t.Fatalf("Create live: %v", err)
	}

	// reserved: terminal, but a registry row still claims it.
	reservedPath := filepath.Join(worktreesDir, "reserved")
	reservedIdentity, err := Create(ctx, source, reservedPath, "reserved")
	if err != nil {
		t.Fatalf("Create reserved: %v", err)
	}
	reservedIdentity, _ = Transition(reservedIdentity, StateActive)
	reservedIdentity, reservedArtifact, err := MakePublishable(ctx, reservedIdentity)
	if err != nil {
		t.Fatalf("MakePublishable reserved: %v", err)
	}
	if _, err := Publish(ctx, reservedIdentity, reservedArtifact, source); err != nil {
		t.Fatalf("Publish reserved: %v", err)
	}

	// stranger: a directory that is not a session checkout at all.
	stranger := filepath.Join(worktreesDir, "stranger")
	if err := os.MkdirAll(stranger, 0o755); err != nil {
		t.Fatalf("mkdir stranger: %v", err)
	}
	writeFile(t, filepath.Join(stranger, "note.txt"), []byte("unrelated\n"))

	proofs, failures := SweepSessionWorktrees(ctx, worktreesDir,
		ReservedWorktreePaths([]string{reservedIdentity.CanonicalPath}))
	if len(failures) != 0 {
		t.Fatalf("sweep failures: %v", failures)
	}
	if len(proofs) != 1 || proofs[0].Epoch != "abandoned" {
		t.Fatalf("proofs = %+v, want exactly the abandoned checkout", proofs)
	}
	if !proofs[0].Verified || proofs[0].RefsDisposition != "preserved" {
		t.Fatalf("incomplete proof: %+v", proofs[0])
	}

	if _, err := os.Lstat(abandoned); !os.IsNotExist(err) {
		t.Fatalf("abandoned checkout survived the sweep: %v", err)
	}
	for name, path := range map[string]string{"live": live, "reserved": reservedPath, "stranger": stranger} {
		if _, err := os.Lstat(path); err != nil {
			t.Fatalf("sweep removed %s, which it must not touch: %v", name, err)
		}
	}
	if got := revParse(t, source, resultRefFor("abandoned")); got != abandonedResult {
		t.Fatalf("abandoned result ref = %q, want %q", got, abandonedResult)
	}
	if revParse(t, source, capturedRefFor("abandoned")) == "" {
		t.Fatal("abandoned captured ref was deleted by the sweep")
	}
}

// A sweep that already ran must be safe to run again, since it fires on every
// startup.
func TestSweepIsIdempotent(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	initRepository(t, source)
	writeFile(t, filepath.Join(source, "tracked.txt"), []byte("generation A\n"))
	git(t, source, "add", "tracked.txt")
	git(t, source, "commit", "-m", "generation A")

	worktreesDir := filepath.Join(root, "_sessions", "worktrees")
	if err := os.MkdirAll(worktreesDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	path := filepath.Join(worktreesDir, "once")
	identity, err := Create(ctx, source, path, "once")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	identity, _ = Transition(identity, StateActive)
	identity, artifact, err := MakePublishable(ctx, identity)
	if err != nil {
		t.Fatalf("MakePublishable: %v", err)
	}
	if _, err := Publish(ctx, identity, artifact, source); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	for pass := 1; pass <= 2; pass++ {
		proofs, failures := SweepSessionWorktrees(ctx, worktreesDir, nil)
		if len(failures) != 0 {
			t.Fatalf("pass %d failures: %v", pass, failures)
		}
		want := 1
		if pass == 2 {
			want = 0
		}
		if len(proofs) != want {
			t.Fatalf("pass %d proofs = %d, want %d", pass, len(proofs), want)
		}
	}
	if revParse(t, source, resultRefFor("once")) == "" {
		t.Fatal("result ref was deleted across repeated sweeps")
	}
}

func revParse(t *testing.T, path, ref string) string {
	t.Helper()
	out, err := gitOutput(context.Background(), path, nil, nil, "rev-parse", "--verify", "--quiet", ref)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}
