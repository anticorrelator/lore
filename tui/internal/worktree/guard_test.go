package worktree

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestRefusedPublishPreservesBothTreesAndQuarantineReproducesSession(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	initRepository(t, source)

	hostA := []byte("host generation A\x00\xff\n")
	streamA := []byte("stream generation A\r\n")
	writeFile(t, filepath.Join(source, "host.marker"), hostA)
	writeFile(t, filepath.Join(source, "stream.marker"), streamA)
	git(t, source, "add", "host.marker", "stream.marker")
	git(t, source, "commit", "-m", "generation A")

	sessionPath := filepath.Join(root, "session")
	identity, err := Create(ctx, source, sessionPath, "session-a")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	identity, err = Transition(identity, StateActive)
	if err != nil {
		t.Fatalf("activate: %v", err)
	}

	hostSession := []byte("host written by stale session\x00\x01\n")
	streamSession := []byte("stream result\x00\xfe\r\n")
	writeFile(t, filepath.Join(sessionPath, "host.marker"), hostSession)
	writeFile(t, filepath.Join(sessionPath, "stream.marker"), streamSession)
	writeFile(t, filepath.Join(sessionPath, "session-only.bin"), []byte{0, 1, 2, 255})
	identity, artifact, err := MakePublishable(ctx, identity)
	if err != nil {
		t.Fatalf("MakePublishable: %v", err)
	}

	hostB := []byte("host generation B must survive\x00\xfd\n")
	streamB := []byte("parallel stream generation B\x00\xfc\n")
	writeFile(t, filepath.Join(source, "host.marker"), hostB)
	writeFile(t, filepath.Join(source, "stream.marker"), streamB)
	beforeHost := readFile(t, filepath.Join(source, "host.marker"))
	beforeStream := readFile(t, filepath.Join(source, "stream.marker"))

	outcome, err := Publish(ctx, identity, artifact, source)
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if outcome.Kind != OutcomeWorktreeQuarantined {
		t.Fatalf("outcome kind = %q, want %q", outcome.Kind, OutcomeWorktreeQuarantined)
	}
	if outcome.Identity.State != StateQuarantined || !outcome.Identity.CleanupEligible() {
		t.Fatalf("quarantined disposition = %+v", outcome.Identity)
	}
	if outcome.Artifact.Ref == "" || outcome.Artifact.OID == "" || outcome.Artifact.PatchPath == "" {
		t.Fatalf("incomplete quarantine artifact: %+v", outcome.Artifact)
	}
	assertBytes(t, filepath.Join(source, "host.marker"), beforeHost)
	assertBytes(t, filepath.Join(source, "stream.marker"), beforeStream)
	assertBytes(t, filepath.Join(sessionPath, "host.marker"), hostSession)
	assertBytes(t, filepath.Join(sessionPath, "stream.marker"), streamSession)

	if got := gitBytes(t, source, "show", outcome.Artifact.Ref+":host.marker"); !bytes.Equal(got, hostSession) {
		t.Fatalf("quarantine ref host.marker = %q, want %q", got, hostSession)
	}
	if got := gitBytes(t, source, "show", outcome.Artifact.Ref+":stream.marker"); !bytes.Equal(got, streamSession) {
		t.Fatalf("quarantine ref stream.marker = %q, want %q", got, streamSession)
	}
	if got := gitBytes(t, source, "show", outcome.Artifact.Ref+":session-only.bin"); !bytes.Equal(got, []byte{0, 1, 2, 255}) {
		t.Fatalf("quarantine ref session-only.bin = %v", got)
	}

	replay := filepath.Join(root, "replay")
	git(t, source, "worktree", "add", "--detach", replay, capturedRef(identity))
	patch := readFile(t, outcome.Artifact.PatchPath)
	gitInput(t, replay, patch, "apply", "--binary", "-")
	assertBytes(t, filepath.Join(replay, "host.marker"), hostSession)
	assertBytes(t, filepath.Join(replay, "stream.marker"), streamSession)
	assertBytes(t, filepath.Join(replay, "session-only.bin"), []byte{0, 1, 2, 255})
}

func TestCreateSeedsExactIndexWorktreeAndUntrackedGeneration(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	initRepository(t, source)
	writeFile(t, filepath.Join(source, "tracked.txt"), []byte("base\n"))
	git(t, source, "add", "tracked.txt")
	git(t, source, "commit", "-m", "base")

	writeFile(t, filepath.Join(source, "tracked.txt"), []byte("staged\n"))
	git(t, source, "add", "tracked.txt")
	working := []byte("working bytes\x00\xff\n")
	untracked := []byte{0, 3, 9, 255, '\n'}
	writeFile(t, filepath.Join(source, "tracked.txt"), working)
	writeFile(t, filepath.Join(source, "untracked.bin"), untracked)

	identity, err := Create(ctx, source, filepath.Join(root, "session"), "exact-seed")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if identity.Version != IdentityVersion || identity.State != StateCaptured {
		t.Fatalf("identity = %+v", identity)
	}
	assertBytes(t, filepath.Join(identity.CanonicalPath, "tracked.txt"), working)
	assertBytes(t, filepath.Join(identity.CanonicalPath, "untracked.bin"), untracked)
	if got := gitBytes(t, identity.CanonicalPath, "show", ":tracked.txt"); !bytes.Equal(got, []byte("staged\n")) {
		t.Fatalf("seeded index = %q, want staged bytes", got)
	}
	if err := ValidateIdentity(ctx, identity); err != nil {
		t.Fatalf("ValidateIdentity: %v", err)
	}
}

func TestIdentityRejectsLegacyAndEpochReuse(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	initRepository(t, source)
	writeFile(t, filepath.Join(source, "tracked"), []byte("base"))
	git(t, source, "add", "tracked")
	git(t, source, "commit", "-m", "base")

	identity, err := Create(ctx, source, filepath.Join(root, "session"), "epoch-one")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	legacy := identity
	legacy.Version = 0
	var refusal *RefusalError
	if err := ValidateIdentity(ctx, legacy); !errors.As(err, &refusal) || refusal.Kind != OutcomeRestoreRefused {
		t.Fatalf("legacy validation error = %#v, want typed refusal", err)
	}
	writeFile(t, filepath.Join(identity.GitDir, "lore-worktree-epoch"), []byte("epoch-two\n"))
	if err := ValidateIdentity(ctx, identity); !errors.As(err, &refusal) || refusal.Kind != OutcomeRestoreRefused {
		t.Fatalf("epoch validation error = %#v, want typed refusal", err)
	}
}

func TestPublishExactGenerationFastForwardsCommittedTip(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	initRepository(t, source)
	writeFile(t, filepath.Join(source, "tracked"), []byte("base\n"))
	git(t, source, "add", "tracked")
	git(t, source, "commit", "-m", "base")

	identity, err := Create(ctx, source, filepath.Join(root, "session"), "publish")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	identity, _ = Transition(identity, StateActive)
	result := []byte("session result\x00\xff\n")
	writeFile(t, filepath.Join(identity.CanonicalPath, "tracked"), result)
	git(t, identity.CanonicalPath, "switch", "-c", "result")
	git(t, identity.CanonicalPath, "add", "tracked")
	git(t, identity.CanonicalPath, "commit", "-m", "result")
	tip := strings.TrimSpace(string(gitBytes(t, identity.CanonicalPath, "rev-parse", "HEAD")))
	identity, artifact, err := MakePublishable(ctx, identity)
	if err != nil {
		t.Fatalf("MakePublishable: %v", err)
	}
	outcome, err := Publish(ctx, identity, artifact, source)
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if outcome.Kind != OutcomePublished || outcome.Identity.State != StatePublished {
		t.Fatalf("outcome = %+v", outcome)
	}
	assertBytes(t, filepath.Join(source, "tracked"), result)
	if got := strings.TrimSpace(string(gitBytes(t, source, "rev-parse", "HEAD"))); got != tip || outcome.Artifact.OID != tip {
		t.Fatalf("destination HEAD = %s, artifact = %s, want committed tip %s", got, outcome.Artifact.OID, tip)
	}
	if got := gitBytes(t, source, "status", "--porcelain"); len(got) != 0 {
		t.Fatalf("publish left uncommitted changes: %s", got)
	}
}

func TestPublishQuarantinesUnsafeResults(t *testing.T) {
	for _, tc := range []struct {
		name   string
		reason string
		change func(*testing.T, string, Identity)
	}{
		{"base-diverged", "base-diverged", func(t *testing.T, source string, identity Identity) {
			git(t, source, "commit", "--allow-empty", "-m", "destination advanced")
		}},
		{"worktree-unstaged", "worktree-dirty", func(t *testing.T, source string, identity Identity) {
			writeFile(t, filepath.Join(identity.CanonicalPath, "tracked"), []byte("uncommitted\x00\xff"))
		}},
		{"worktree-staged", "worktree-dirty", func(t *testing.T, source string, identity Identity) {
			writeFile(t, filepath.Join(identity.CanonicalPath, "tracked"), []byte("staged"))
			git(t, identity.CanonicalPath, "add", "tracked")
		}},
		{"worktree-untracked", "worktree-dirty", func(t *testing.T, source string, identity Identity) {
			writeFile(t, filepath.Join(identity.CanonicalPath, "untracked"), []byte("untracked"))
		}},
		{"destination-unstaged", "destination-dirty", func(t *testing.T, source string, identity Identity) {
			writeFile(t, filepath.Join(source, "tracked"), []byte("keep\x00\xff"))
		}},
		{"destination-staged", "destination-dirty", func(t *testing.T, source string, identity Identity) {
			writeFile(t, filepath.Join(source, "tracked"), []byte("keep staged"))
			git(t, source, "add", "tracked")
		}},
		{"destination-untracked", "destination-dirty", func(t *testing.T, source string, identity Identity) {
			writeFile(t, filepath.Join(source, "untracked"), []byte("keep untracked"))
		}},
		{"destination-ref-locked", "Git fast-forward failed: ref transaction did not confirm prepare", func(t *testing.T, source string, identity Identity) {
			writeFile(t, filepath.Join(source, ".git", "refs", "heads", "main.lock"), []byte("existing lock"))
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx := context.Background()
			root := t.TempDir()
			source := filepath.Join(root, "source")
			initRepository(t, source)
			writeFile(t, filepath.Join(source, "tracked"), []byte("base"))
			git(t, source, "add", ".")
			git(t, source, "commit", "-m", "base")
			identity, err := Create(ctx, source, filepath.Join(root, "session"), "unsafe")
			if err != nil {
				t.Fatal(err)
			}
			identity, _ = Transition(identity, StateActive)
			writeFile(t, filepath.Join(identity.CanonicalPath, "tracked"), []byte("committed result"))
			git(t, identity.CanonicalPath, "add", ".")
			git(t, identity.CanonicalPath, "commit", "-m", "result")
			tc.change(t, source, identity)
			assertQuarantinedUnchanged(t, source, identity, tc.reason)
		})
	}
}

func TestPublishDivergentStreamRegression(t *testing.T) {
	for _, advanceAfterSpawn := range []bool{false, true} {
		name := "destination-unchanged-since-spawn"
		if advanceAfterSpawn {
			name = "destination-advanced-after-spawn"
		}
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			root := t.TempDir()
			source := filepath.Join(root, "control")
			initRepository(t, source)
			writeFile(t, filepath.Join(source, "tracked"), []byte("old base\x00\xff"))
			git(t, source, "add", ".")
			git(t, source, "commit", "-m", "common base")
			git(t, source, "branch", "stream")
			writeFile(t, filepath.Join(source, "tracked"), []byte("new control bytes\x00\xfe"))
			writeFile(t, filepath.Join(source, "main-only"), []byte("keep newer file"))
			git(t, source, "add", ".")
			git(t, source, "commit", "-m", "unrelated control change")
			identity, err := Create(ctx, source, filepath.Join(root, "session"), "divergent-stream")
			if err != nil {
				t.Fatal(err)
			}
			identity, _ = Transition(identity, StateActive)
			git(t, identity.CanonicalPath, "switch", "stream")
			writeFile(t, filepath.Join(identity.CanonicalPath, "stream-only"), []byte("stream result\x00\xfd"))
			git(t, identity.CanonicalPath, "add", ".")
			git(t, identity.CanonicalPath, "commit", "-m", "stream result")
			if advanceAfterSpawn {
				writeFile(t, filepath.Join(source, "another-main-only"), []byte("keep post-spawn file"))
				git(t, source, "add", ".")
				git(t, source, "commit", "-m", "control advanced after spawn")
			}
			outcome := assertQuarantinedUnchanged(t, source, identity, "base-diverged")
			t.Logf("refused divergent stream: reason=%s base=%s destination=%s tip=%s; destination files, HEAD, and index byte-identical; quarantine=%s patch retained", outcome.Reason, identity.Captured.HeadOID, outcome.Observed.HeadOID, outcome.WorktreeHeadOID, outcome.Artifact.Ref)
		})
	}
}

func assertQuarantinedUnchanged(t *testing.T, source string, identity Identity, reason string) PublishOutcome {
	t.Helper()
	ctx := context.Background()
	before := checkoutBytes(t, source)
	indexPath := strings.TrimSpace(string(gitBytes(t, source, "rev-parse", "--path-format=absolute", "--git-path", "index")))
	index := readFile(t, indexPath)
	head := gitBytes(t, source, "rev-parse", "HEAD")
	identity, artifact, err := MakePublishable(ctx, identity)
	if err != nil {
		t.Fatal(err)
	}
	outcome, err := Publish(ctx, identity, artifact, source)
	if err != nil {
		t.Fatal(err)
	}
	if outcome.Kind != OutcomeWorktreeQuarantined || outcome.Reason != reason || !outcome.Identity.CleanupEligible() {
		t.Fatalf("outcome = %+v, want quarantine %s", outcome, reason)
	}
	if after := checkoutBytes(t, source); !reflect.DeepEqual(before, after) {
		t.Fatalf("destination files changed: before=%v after=%v", before, after)
	}
	assertBytes(t, indexPath, index)
	if after := gitBytes(t, source, "rev-parse", "HEAD"); !bytes.Equal(head, after) {
		t.Fatal("destination HEAD changed")
	}
	if outcome.Artifact.Ref != quarantineRef(identity) || len(readFile(t, outcome.Artifact.PatchPath)) == 0 {
		t.Fatal("quarantine ref or patch missing")
	}
	if got := strings.TrimSpace(string(gitBytes(t, source, "rev-parse", outcome.Artifact.Ref))); got != outcome.Artifact.OID {
		t.Fatal("quarantine ref not pinned")
	}
	return outcome
}

func checkoutBytes(t *testing.T, root string) map[string]string {
	t.Helper()
	files := map[string]string{}
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if path == filepath.Join(root, ".git") {
			return filepath.SkipDir
		}
		if !info.IsDir() {
			files[path] = string(readFile(t, path))
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return files
}

func TestTeardownPendingRetainsOwnership(t *testing.T) {
	identity := completeIdentityForTransition()
	active, err := Transition(identity, StateActive)
	if err != nil {
		t.Fatalf("activate: %v", err)
	}
	pending, err := Transition(active, StateTeardownPending)
	if err != nil {
		t.Fatalf("teardown pending: %v", err)
	}
	if !pending.OwnsWorktree() || pending.CleanupEligible() {
		t.Fatalf("teardown-pending must retain ownership: %+v", pending)
	}
}

func completeIdentityForTransition() Identity {
	return Identity{
		Version: IdentityVersion, CanonicalPath: "/session", GitCommonDir: "/common", GitDir: "/gitdir",
		Epoch: "transition", Captured: Generation{CanonicalPath: "/source", GitCommonDir: "/common", GitDir: "/source-git", HeadOID: "head", IndexDigest: "index", WorktreeDigest: "worktree"},
		TargetRef: "refs/heads/main", TargetOID: "head", State: StateCaptured,
	}
}

func initRepository(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
	git(t, path, "init", "-b", "main")
	git(t, path, "config", "user.name", "Test")
	git(t, path, "config", "user.email", "test@example.com")
}

func writeFile(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

func readFile(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func assertBytes(t *testing.T, path string, want []byte) {
	t.Helper()
	if got := readFile(t, path); !bytes.Equal(got, want) {
		t.Fatalf("%s = %v, want %v", path, got, want)
	}
}

func git(t *testing.T, path string, args ...string) {
	t.Helper()
	_ = gitBytes(t, path, args...)
}

func gitBytes(t *testing.T, path string, args ...string) []byte {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", path}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return out
}

func gitInput(t *testing.T, path string, input []byte, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", path}, args...)...)
	cmd.Stdin = bytes.NewReader(input)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}
