package worktree

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

const IdentityVersion = 1

type LifecycleState string

const (
	StateCaptured        LifecycleState = "captured"
	StateActive          LifecycleState = "active"
	StatePublishable     LifecycleState = "publishable"
	StatePublished       LifecycleState = "published"
	StateQuarantined     LifecycleState = "quarantined"
	StateTeardownPending LifecycleState = "teardown-pending"
)

type OutcomeKind string

const (
	OutcomePublished           OutcomeKind = "published"
	OutcomeRestoreRefused      OutcomeKind = "restore_refused"
	OutcomeWorktreeQuarantined OutcomeKind = "worktree_quarantined"
)

// Generation identifies both a checkout and all Git-visible content in it.
type Generation struct {
	CanonicalPath  string `json:"canonical_path"`
	GitCommonDir   string `json:"git_common_dir"`
	GitDir         string `json:"git_dir"`
	HeadOID        string `json:"head_oid"`
	IndexDigest    string `json:"index_digest"`
	WorktreeDigest string `json:"worktree_digest"`
}

// Identity is the durable, versioned ownership record for one session worktree.
type Identity struct {
	Version       int            `json:"version"`
	CanonicalPath string         `json:"canonical_path"`
	GitCommonDir  string         `json:"git_common_dir"`
	GitDir        string         `json:"git_dir"`
	Epoch         string         `json:"epoch"`
	Captured      Generation     `json:"captured"`
	TargetRef     string         `json:"target_ref"`
	TargetOID     string         `json:"target_oid"`
	State         LifecycleState `json:"state"`
}

type ResultArtifact struct {
	Ref       string `json:"ref"`
	OID       string `json:"oid"`
	PatchPath string `json:"patch_path,omitempty"`
}

type PublishOutcome struct {
	Kind     OutcomeKind    `json:"kind"`
	Identity Identity       `json:"identity"`
	Artifact ResultArtifact `json:"artifact"`
	Expected Generation     `json:"expected"`
	Observed *Generation    `json:"observed,omitempty"`
	Reason   string         `json:"reason,omitempty"`
}

type RefusalError struct {
	Kind     OutcomeKind `json:"kind"`
	Reason   string      `json:"reason"`
	Expected *Identity   `json:"expected,omitempty"`
	Observed *Identity   `json:"observed,omitempty"`
}

func (e *RefusalError) Error() string {
	return string(e.Kind) + ": " + e.Reason
}

func (i Identity) OwnsWorktree() bool {
	return i.State != StatePublished && i.State != StateQuarantined
}

func (i Identity) CleanupEligible() bool {
	return i.State == StatePublished || i.State == StateQuarantined
}

var validEpoch = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// Create captures sourcePath and seeds a detached session-owned worktree from
// that exact generation. It refuses a source that changes during capture.
func Create(ctx context.Context, sourcePath, worktreePath, epoch string) (identity Identity, err error) {
	if !validEpoch.MatchString(epoch) {
		return Identity{}, fmt.Errorf("invalid worktree epoch %q", epoch)
	}
	if strings.TrimSpace(worktreePath) == "" {
		return Identity{}, errors.New("worktree path is required")
	}

	captured, targetRef, targetOID, err := inspectGeneration(ctx, sourcePath)
	if err != nil {
		return Identity{}, err
	}
	stagedPatch, err := gitOutput(ctx, sourcePath, nil, nil, "diff", "--binary", "--cached", "HEAD", "--")
	if err != nil {
		return Identity{}, fmt.Errorf("capture staged changes: %w", err)
	}
	unstagedPatch, err := gitOutput(ctx, sourcePath, nil, nil, "diff", "--binary", "--")
	if err != nil {
		return Identity{}, fmt.Errorf("capture unstaged changes: %w", err)
	}
	untracked, err := nulList(ctx, sourcePath, "ls-files", "--others", "--exclude-standard", "-z")
	if err != nil {
		return Identity{}, fmt.Errorf("capture untracked inventory: %w", err)
	}

	targetPath, err := filepath.Abs(worktreePath)
	if err != nil {
		return Identity{}, fmt.Errorf("resolve worktree path: %w", err)
	}
	targetPath = filepath.Clean(targetPath)
	if _, statErr := os.Lstat(targetPath); !os.IsNotExist(statErr) {
		if statErr == nil {
			return Identity{}, fmt.Errorf("worktree path already exists: %s", targetPath)
		}
		return Identity{}, fmt.Errorf("inspect worktree path: %w", statErr)
	}
	if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
		return Identity{}, fmt.Errorf("create worktree parent: %w", err)
	}
	if _, err := gitOutput(ctx, sourcePath, nil, nil, "worktree", "add", "--detach", "--no-checkout", targetPath, captured.HeadOID); err != nil {
		return Identity{}, fmt.Errorf("create session worktree: %w", err)
	}
	created := true
	defer func() {
		if err != nil && created {
			_, _ = gitOutput(context.Background(), sourcePath, nil, nil, "worktree", "remove", "--force", targetPath)
		}
	}()

	if _, err = gitOutput(ctx, targetPath, nil, nil, "read-tree", captured.HeadOID); err != nil {
		return Identity{}, fmt.Errorf("initialize session index: %w", err)
	}
	if len(stagedPatch) > 0 {
		if _, err = gitOutput(ctx, targetPath, stagedPatch, nil, "apply", "--cached", "--binary", "-"); err != nil {
			return Identity{}, fmt.Errorf("seed staged changes: %w", err)
		}
	}
	if _, err = gitOutput(ctx, targetPath, nil, nil, "checkout-index", "--all", "--force"); err != nil {
		return Identity{}, fmt.Errorf("seed tracked content: %w", err)
	}
	if len(unstagedPatch) > 0 {
		if _, err = gitOutput(ctx, targetPath, unstagedPatch, nil, "apply", "--binary", "-"); err != nil {
			return Identity{}, fmt.Errorf("seed unstaged changes: %w", err)
		}
	}
	for _, relative := range untracked {
		if err = copyEntry(sourcePath, targetPath, relative); err != nil {
			return Identity{}, fmt.Errorf("seed untracked content %q: %w", relative, err)
		}
	}

	after, afterRef, afterOID, err := inspectGeneration(ctx, sourcePath)
	if err != nil {
		return Identity{}, fmt.Errorf("recheck captured generation: %w", err)
	}
	if after != captured || afterRef != targetRef || afterOID != targetOID {
		return Identity{}, &RefusalError{Kind: OutcomeRestoreRefused, Reason: "source generation changed during capture"}
	}

	sessionPath, commonDir, gitDir, err := repositoryIdentity(ctx, targetPath)
	if err != nil {
		return Identity{}, err
	}
	if commonDir != captured.GitCommonDir {
		return Identity{}, &RefusalError{Kind: OutcomeRestoreRefused, Reason: "session worktree belongs to a different Git common directory"}
	}
	epochPath := filepath.Join(gitDir, "lore-worktree-epoch")
	if err = os.WriteFile(epochPath, []byte(epoch+"\n"), 0o600); err != nil {
		return Identity{}, fmt.Errorf("write worktree epoch: %w", err)
	}

	identity = Identity{
		Version: IdentityVersion, CanonicalPath: sessionPath, GitCommonDir: commonDir,
		GitDir: gitDir, Epoch: epoch, Captured: captured, TargetRef: targetRef,
		TargetOID: targetOID, State: StateCaptured,
	}
	if err = validateRequired(identity); err != nil {
		return Identity{}, err
	}
	seeded, _, _, err := inspectGeneration(ctx, targetPath)
	if err != nil {
		return Identity{}, err
	}
	if !sameContentGeneration(captured, seeded) {
		return Identity{}, &RefusalError{Kind: OutcomeRestoreRefused, Reason: "seeded worktree does not reproduce captured generation", Expected: &identity}
	}
	if _, err = materializeRef(ctx, identity, capturedRef(identity)); err != nil {
		return Identity{}, fmt.Errorf("preserve captured generation: %w", err)
	}
	created = false
	return identity, nil
}

// ValidateIdentity rejects incomplete legacy records and path-reuse identities.
func ValidateIdentity(ctx context.Context, expected Identity) error {
	if err := validateRequired(expected); err != nil {
		return err
	}
	path, commonDir, gitDir, err := repositoryIdentity(ctx, expected.CanonicalPath)
	if err != nil {
		return &RefusalError{Kind: OutcomeRestoreRefused, Reason: err.Error(), Expected: &expected}
	}
	observed := expected
	observed.CanonicalPath, observed.GitCommonDir, observed.GitDir = path, commonDir, gitDir
	if path != expected.CanonicalPath || commonDir != expected.GitCommonDir || gitDir != expected.GitDir {
		return &RefusalError{Kind: OutcomeRestoreRefused, Reason: "worktree path or Git identity mismatch", Expected: &expected, Observed: &observed}
	}
	epochBytes, err := os.ReadFile(filepath.Join(gitDir, "lore-worktree-epoch"))
	if err != nil || strings.TrimSpace(string(epochBytes)) != expected.Epoch {
		return &RefusalError{Kind: OutcomeRestoreRefused, Reason: "worktree epoch mismatch", Expected: &expected, Observed: &observed}
	}
	return nil
}

func Transition(identity Identity, next LifecycleState) (Identity, error) {
	if err := validateRequired(identity); err != nil {
		return Identity{}, err
	}
	allowed := false
	switch identity.State {
	case StateCaptured:
		allowed = next == StateActive
	case StateActive:
		allowed = next == StatePublishable || next == StateTeardownPending || next == StateQuarantined
	case StateTeardownPending:
		allowed = next == StatePublishable || next == StateQuarantined
	case StatePublishable:
		allowed = next == StatePublished || next == StateQuarantined || next == StateTeardownPending
	}
	if !allowed {
		return Identity{}, fmt.Errorf("invalid worktree lifecycle transition %q -> %q", identity.State, next)
	}
	identity.State = next
	return identity, nil
}

func MakePublishable(ctx context.Context, identity Identity) (Identity, ResultArtifact, error) {
	if err := ValidateIdentity(ctx, identity); err != nil {
		return Identity{}, ResultArtifact{}, err
	}
	next, err := Transition(identity, StatePublishable)
	if err != nil {
		return Identity{}, ResultArtifact{}, err
	}
	artifact, err := materializeRef(ctx, identity, resultRef(identity))
	if err != nil {
		return Identity{}, ResultArtifact{}, fmt.Errorf("materialize session result: %w", err)
	}
	return next, artifact, nil
}

// Quarantine preserves the current session result as both a Git ref and a
// binary patch before making the physical worktree cleanup-eligible.
func Quarantine(ctx context.Context, identity Identity, reason string) (Identity, ResultArtifact, error) {
	if err := ValidateIdentity(ctx, identity); err != nil {
		return Identity{}, ResultArtifact{}, err
	}
	if identity.State == StateCaptured {
		return Identity{}, ResultArtifact{}, fmt.Errorf("captured worktree cannot be quarantined before activation")
	}
	artifact, err := materializeRef(ctx, identity, quarantineRef(identity))
	if err != nil {
		return Identity{}, ResultArtifact{}, fmt.Errorf("materialize quarantine result: %w", err)
	}
	patch, err := gitOutput(ctx, identity.CanonicalPath, nil, nil, "diff", "--binary", capturedRef(identity), artifact.OID, "--")
	if err != nil {
		return Identity{}, ResultArtifact{}, fmt.Errorf("build quarantine patch: %w", err)
	}
	patchDir := filepath.Join(identity.GitCommonDir, "lore-quarantine")
	if err := os.MkdirAll(patchDir, 0o700); err != nil {
		return Identity{}, ResultArtifact{}, fmt.Errorf("create quarantine directory: %w", err)
	}
	patchPath := filepath.Join(patchDir, identity.Epoch+".patch")
	if err := writeAtomic(patchPath, patch, 0o600); err != nil {
		return Identity{}, ResultArtifact{}, fmt.Errorf("write quarantine patch: %w", err)
	}
	artifact.PatchPath = patchPath
	next, err := Transition(identity, StateQuarantined)
	if err != nil {
		return Identity{}, ResultArtifact{}, err
	}
	_ = reason // persisted by the owning session substrate beside this disposition.
	return next, artifact, nil
}

func Publish(ctx context.Context, identity Identity, artifact ResultArtifact, destinationPath string) (PublishOutcome, error) {
	base := PublishOutcome{Identity: identity, Artifact: artifact, Expected: identity.Captured}
	if identity.State != StatePublishable {
		return base, fmt.Errorf("publish requires lifecycle state %q, got %q", StatePublishable, identity.State)
	}
	if err := ValidateIdentity(ctx, identity); err != nil {
		return base, err
	}
	if artifact.Ref == "" || artifact.OID == "" {
		return base, &RefusalError{Kind: OutcomeRestoreRefused, Reason: "result artifact identity is incomplete", Expected: &identity}
	}
	refOID, err := gitString(ctx, identity.CanonicalPath, "rev-parse", "--verify", artifact.Ref)
	if err != nil || refOID != artifact.OID {
		return base, &RefusalError{Kind: OutcomeRestoreRefused, Reason: "result artifact ref does not match its OID", Expected: &identity}
	}

	observed, observedRef, observedOID, inspectErr := inspectGeneration(ctx, destinationPath)
	if inspectErr != nil {
		return quarantineOutcome(ctx, identity, artifact, nil, "destination identity is unknown: "+inspectErr.Error())
	}
	base.Observed = &observed
	if observed != identity.Captured || observedRef != identity.TargetRef || observedOID != identity.TargetOID {
		return quarantineOutcome(ctx, identity, artifact, &observed, "destination generation no longer matches the captured generation")
	}
	patch, err := gitOutput(ctx, identity.CanonicalPath, nil, nil, "diff", "--binary", capturedRef(identity), artifact.OID, "--")
	if err != nil {
		return base, fmt.Errorf("build publish patch: %w", err)
	}
	if len(patch) > 0 {
		if _, err := gitOutput(ctx, destinationPath, patch, nil, "apply", "--check", "--binary", "-"); err != nil {
			return quarantineOutcome(ctx, identity, artifact, &observed, "Git integration preflight failed: "+err.Error())
		}
		latest, latestRef, latestOID, err := inspectGeneration(ctx, destinationPath)
		if err != nil || latest != identity.Captured || latestRef != identity.TargetRef || latestOID != identity.TargetOID {
			return quarantineOutcome(ctx, identity, artifact, &latest, "destination generation changed during publish preflight")
		}
		if _, err := gitOutput(ctx, destinationPath, patch, nil, "apply", "--binary", "-"); err != nil {
			return quarantineOutcome(ctx, identity, artifact, &observed, "Git integration failed: "+err.Error())
		}
	}
	next, err := Transition(identity, StatePublished)
	if err != nil {
		return base, err
	}
	return PublishOutcome{Kind: OutcomePublished, Identity: next, Artifact: artifact, Expected: identity.Captured, Observed: &observed}, nil
}

func quarantineOutcome(ctx context.Context, identity Identity, artifact ResultArtifact, observed *Generation, reason string) (PublishOutcome, error) {
	next, quarantined, err := Quarantine(ctx, identity, reason)
	if err != nil {
		return PublishOutcome{}, err
	}
	if quarantined.OID != artifact.OID {
		reason += "; session result changed after it became publishable"
	}
	return PublishOutcome{Kind: OutcomeWorktreeQuarantined, Identity: next, Artifact: quarantined, Expected: identity.Captured, Observed: observed, Reason: reason}, nil
}

func validateRequired(identity Identity) error {
	if identity.Version != IdentityVersion {
		return &RefusalError{Kind: OutcomeRestoreRefused, Reason: fmt.Sprintf("unsupported or missing worktree identity version %d", identity.Version), Expected: &identity}
	}
	if identity.CanonicalPath == "" || identity.GitCommonDir == "" || identity.GitDir == "" || identity.Epoch == "" ||
		identity.Captured.CanonicalPath == "" || identity.Captured.GitCommonDir == "" || identity.Captured.GitDir == "" ||
		identity.Captured.HeadOID == "" || identity.Captured.IndexDigest == "" || identity.Captured.WorktreeDigest == "" ||
		identity.TargetOID == "" || identity.State == "" {
		return &RefusalError{Kind: OutcomeRestoreRefused, Reason: "worktree identity is incomplete", Expected: &identity}
	}
	if !validEpoch.MatchString(identity.Epoch) {
		return &RefusalError{Kind: OutcomeRestoreRefused, Reason: "worktree epoch is invalid", Expected: &identity}
	}
	switch identity.State {
	case StateCaptured, StateActive, StatePublishable, StatePublished, StateQuarantined, StateTeardownPending:
	default:
		return &RefusalError{Kind: OutcomeRestoreRefused, Reason: "worktree lifecycle state is unknown", Expected: &identity}
	}
	return nil
}

func inspectGeneration(ctx context.Context, path string) (Generation, string, string, error) {
	canonical, commonDir, gitDir, err := repositoryIdentity(ctx, path)
	if err != nil {
		return Generation{}, "", "", err
	}
	head, err := gitString(ctx, canonical, "rev-parse", "HEAD")
	if err != nil {
		return Generation{}, "", "", fmt.Errorf("read HEAD: %w", err)
	}
	ref, err := gitString(ctx, canonical, "symbolic-ref", "-q", "HEAD")
	if err != nil {
		ref = ""
	}
	targetOID := head
	if ref != "" {
		targetOID, err = gitString(ctx, canonical, "rev-parse", ref)
		if err != nil {
			return Generation{}, "", "", fmt.Errorf("read target ref: %w", err)
		}
	}
	indexRows, err := gitOutput(ctx, canonical, nil, nil, "ls-files", "--stage", "-z")
	if err != nil {
		return Generation{}, "", "", fmt.Errorf("digest index: %w", err)
	}
	indexSum := sha256.Sum256(indexRows)
	worktreeTree, err := snapshotTree(ctx, canonical, gitDir)
	if err != nil {
		return Generation{}, "", "", fmt.Errorf("digest worktree: %w", err)
	}
	return Generation{
		CanonicalPath: canonical, GitCommonDir: commonDir, GitDir: gitDir, HeadOID: head,
		IndexDigest: hex.EncodeToString(indexSum[:]), WorktreeDigest: worktreeTree,
	}, ref, targetOID, nil
}

func repositoryIdentity(ctx context.Context, path string) (string, string, string, error) {
	root, err := gitString(ctx, path, "rev-parse", "--path-format=absolute", "--show-toplevel")
	if err != nil {
		return "", "", "", fmt.Errorf("resolve repository root: %w", err)
	}
	common, err := gitString(ctx, path, "rev-parse", "--path-format=absolute", "--git-common-dir")
	if err != nil {
		return "", "", "", fmt.Errorf("resolve Git common directory: %w", err)
	}
	gitDir, err := gitString(ctx, path, "rev-parse", "--path-format=absolute", "--git-dir")
	if err != nil {
		return "", "", "", fmt.Errorf("resolve per-worktree Git directory: %w", err)
	}
	root, err = canonicalExisting(root)
	if err != nil {
		return "", "", "", err
	}
	common, err = canonicalExisting(common)
	if err != nil {
		return "", "", "", err
	}
	gitDir, err = canonicalExisting(gitDir)
	if err != nil {
		return "", "", "", err
	}
	return root, common, gitDir, nil
}

func canonicalExisting(path string) (string, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("resolve canonical path: %w", err)
	}
	resolved, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", fmt.Errorf("resolve canonical path %q: %w", path, err)
	}
	return filepath.Clean(resolved), nil
}

func sameContentGeneration(left, right Generation) bool {
	return left.HeadOID == right.HeadOID && left.IndexDigest == right.IndexDigest && left.WorktreeDigest == right.WorktreeDigest
}

func materializeRef(ctx context.Context, identity Identity, ref string) (ResultArtifact, error) {
	tree, err := snapshotTree(ctx, identity.CanonicalPath, identity.GitDir)
	if err != nil {
		return ResultArtifact{}, err
	}
	message := []byte("lore session worktree " + identity.Epoch + "\n")
	env := []string{
		"GIT_AUTHOR_NAME=Lore", "GIT_AUTHOR_EMAIL=lore@localhost",
		"GIT_COMMITTER_NAME=Lore", "GIT_COMMITTER_EMAIL=lore@localhost",
		"GIT_AUTHOR_DATE=2000-01-01T00:00:00Z", "GIT_COMMITTER_DATE=2000-01-01T00:00:00Z",
	}
	commit, err := gitOutput(ctx, identity.CanonicalPath, message, env, "commit-tree", tree, "-p", identity.TargetOID)
	if err != nil {
		return ResultArtifact{}, err
	}
	oid := strings.TrimSpace(string(commit))
	if _, err := gitOutput(ctx, identity.CanonicalPath, nil, nil, "update-ref", ref, oid); err != nil {
		return ResultArtifact{}, err
	}
	return ResultArtifact{Ref: ref, OID: oid}, nil
}

func snapshotTree(ctx context.Context, path, gitDir string) (string, error) {
	tmp, err := os.CreateTemp(gitDir, "lore-index-*")
	if err != nil {
		return "", err
	}
	indexPath := tmp.Name()
	if err := tmp.Close(); err != nil {
		return "", err
	}
	if err := os.Remove(indexPath); err != nil {
		return "", err
	}
	defer os.Remove(indexPath)
	env := []string{"GIT_INDEX_FILE=" + indexPath}
	if _, err := gitOutput(ctx, path, nil, env, "read-tree", "HEAD"); err != nil {
		return "", err
	}
	if _, err := gitOutput(ctx, path, nil, env, "add", "-A", "--", "."); err != nil {
		return "", err
	}
	return gitStringEnv(ctx, path, env, "write-tree")
}

func capturedRef(identity Identity) string {
	return "refs/lore/worktrees/" + identity.Epoch + "/captured"
}

func resultRef(identity Identity) string {
	return "refs/lore/worktrees/" + identity.Epoch + "/result"
}

func quarantineRef(identity Identity) string {
	return "refs/lore/quarantine/" + identity.Epoch
}

func nulList(ctx context.Context, path string, args ...string) ([]string, error) {
	data, err := gitOutput(ctx, path, nil, nil, args...)
	if err != nil {
		return nil, err
	}
	if len(data) == 0 {
		return nil, nil
	}
	parts := bytes.Split(data, []byte{0})
	result := make([]string, 0, len(parts)-1)
	for _, part := range parts {
		if len(part) > 0 {
			result = append(result, string(part))
		}
	}
	return result, nil
}

func copyEntry(sourceRoot, destinationRoot, relative string) error {
	if filepath.IsAbs(relative) || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return errors.New("path escapes repository root")
	}
	source := filepath.Join(sourceRoot, relative)
	destination := filepath.Join(destinationRoot, relative)
	info, err := os.Lstat(source)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		target, err := os.Readlink(source)
		if err != nil {
			return err
		}
		return os.Symlink(target, destination)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("unsupported untracked file mode %s", info.Mode())
	}
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, info.Mode().Perm())
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(out, in)
	closeErr := out.Close()
	if copyErr != nil {
		return copyErr
	}
	return closeErr
}

func writeAtomic(path string, data []byte, mode os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-quarantine-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpPath, path)
}

func gitString(ctx context.Context, path string, args ...string) (string, error) {
	return gitStringEnv(ctx, path, nil, args...)
}

func gitStringEnv(ctx context.Context, path string, env []string, args ...string) (string, error) {
	out, err := gitOutput(ctx, path, nil, env, args...)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func gitOutput(ctx context.Context, path string, stdin []byte, env []string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, "git", append([]string{"-C", path}, args...)...)
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	cmd.Env = append(os.Environ(), env...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		message := strings.TrimSpace(stderr.String())
		if message == "" {
			message = err.Error()
		}
		return nil, errors.New(message)
	}
	return stdout.Bytes(), nil
}
