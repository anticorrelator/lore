package worktree

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Session worktree cleanup reclaims the physical checkout once a session has
// reached a terminal lifecycle state, and proves the reclaim the same way the
// coordination worktree manager does: path absent, Git registry no longer naming
// it, admin directory gone, temporary-branch disposition recorded.
//
// It differs from the manager's proof in exactly one place, deliberately. The
// manager deletes refs/lore/worktrees/<epoch>/{captured,result} as part of its
// proof, keeping only refs/lore/quarantine/<epoch>, which it pins at the
// temporary branch tip on the way out. For a session tree the result and
// quarantine refs *are* the preservation — they are the only remaining record of
// what the session produced. Cleanup therefore requires them to exist going in,
// requires the live checkout content to already be reachable from one of them,
// and re-verifies every one of them by OID after the directory is gone.
// Deleting them would convert this from disk hygiene into silent data loss.

// RefOID names a preserved ref and the object it pointed at.
type RefOID struct {
	Ref string `json:"ref"`
	OID string `json:"oid"`
}

// CleanupProof is the evidence that one session checkout was reclaimed without
// losing anything. Verified is true only when every assertion below held.
type CleanupProof struct {
	Epoch string `json:"epoch"`
	Path  string `json:"path"`
	// PathAbsent, RegistryAbsent and AdminDirAbsent are the removal assertions:
	// the directory is gone, `git worktree list` no longer names it, and its
	// per-worktree admin directory under .git/worktrees is gone.
	PathAbsent     bool `json:"path_absent"`
	RegistryAbsent bool `json:"git_registry_absent"`
	AdminDirAbsent bool `json:"admin_dir_absent"`
	// BranchDisposition records what happened to the checkout's branch. Session
	// checkouts start detached, so this is either "detached (no branch created)"
	// or "preserved <ref>" for a session that committed onto a branch. It is
	// never "deleted" — a session's branch is work product.
	BranchDisposition string `json:"branch_disposition"`
	// RefsDisposition is always "preserved" for a session checkout. It is the
	// inverse of the manager's "deleted" and is asserted, not assumed.
	// PreservedRefs carries every ref that had to survive, including the branch.
	RefsDisposition string   `json:"guard_refs_disposition"`
	PreservedRefs   []RefOID `json:"preserved_refs"`
	// ContentProvenBy names the ref whose tree matched the live checkout content,
	// i.e. the ref that makes deleting the directory lossless.
	ContentProvenBy string `json:"content_proven_by"`
	Verified        bool   `json:"verified"`
}

// ErrNotCleanupEligible reports a checkout that has not proven itself terminal.
// It is an ordinary, expected outcome: the directory is left exactly as it was.
var ErrNotCleanupEligible = errors.New("session worktree is not cleanup-eligible")

// ErrContentUnproven reports a terminal checkout whose bytes on disk could not
// be matched to any preserved ref, either because no ref's tree equals them or
// because they could not be digested at all. It is a refusal, not a failure:
// it is returned before anything is removed, so the directory is exactly as it
// was. Retrying cannot change the answer. Someone has to preserve that content
// in a ref or discard it by hand, so a caller reports the checkout as retained
// and carries on.
var ErrContentUnproven = errors.New("session worktree content is not proven preserved")

// checkout is the physical facts about one session worktree directory — enough
// to remove it and to prove the removal, without a persisted identity record.
// The close path derives one from the identity it already holds; the crash
// backstop derives one by inspecting the directory, because by then there is no
// live handler left to ask.
type checkout struct {
	Path         string
	Epoch        string
	GitCommonDir string
	GitDir       string
}

func checkoutFromIdentity(identity Identity) checkout {
	return checkout{
		Path:         identity.CanonicalPath,
		Epoch:        identity.Epoch,
		GitCommonDir: identity.GitCommonDir,
		GitDir:       identity.GitDir,
	}
}

// CleanupSessionCheckout reclaims the checkout for a session whose worktree has
// reached Published or Quarantined. It is the close path's counterpart to
// Create: the session is over, its result is preserved as refs, and the working
// copy on disk is now pure cost.
func CleanupSessionCheckout(ctx context.Context, identity Identity) (CleanupProof, error) {
	if err := validateRequired(identity); err != nil {
		return CleanupProof{Epoch: identity.Epoch, Path: identity.CanonicalPath}, err
	}
	if !identity.CleanupEligible() {
		return CleanupProof{Epoch: identity.Epoch, Path: identity.CanonicalPath},
			fmt.Errorf("%w: lifecycle state %q", ErrNotCleanupEligible, identity.State)
	}
	return removeCheckout(ctx, checkoutFromIdentity(identity))
}

// SweepSessionWorktrees is the crash-resume backstop. A TUI killed mid-teardown
// never reaches the close path, so its checkout is left behind with no handler
// and no registry row to speak for it — the one case where scanning is the only
// way to find the work.
//
// reserved names canonical paths that a registry row still claims; those are
// skipped outright. Every remaining entry has to carry its own proof: a matching
// epoch marker, a result or quarantine ref (which only a session that reached at
// least publishable can have), and live content already reachable from one of
// its preserved refs. An entry that cannot prove all three is left alone — a
// leaked directory is a survivable cost, a wrongly deleted one is not.
//
// Entries that are not terminal are silent, because that is the normal state
// of a live session's tree. A terminal entry whose content cannot be proven
// preserved is reported in Retained rather than Failures: nothing was touched,
// and one such tree must not stop a caller from reclaiming the rest or from
// serving new sessions.
func SweepSessionWorktrees(ctx context.Context, worktreesDir string, reserved map[string]bool) SweepResult {
	entries, err := os.ReadDir(worktreesDir)
	if err != nil {
		if os.IsNotExist(err) {
			return SweepResult{}
		}
		return SweepResult{Failures: []error{fmt.Errorf("scan session worktrees: %w", err)}}
	}
	var result SweepResult
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		path := filepath.Join(worktreesDir, entry.Name())
		canonical, err := canonicalExisting(path)
		if err != nil {
			continue
		}
		if reserved[canonical] || reserved[path] {
			continue
		}
		c, err := inspectCheckout(ctx, canonical)
		if err != nil || c.Epoch != entry.Name() {
			// Not a session checkout this build owns: no epoch marker, no longer a
			// Git worktree, or a directory whose name and marker disagree.
			continue
		}
		if _, _, err := preservationEvidence(ctx, c); err != nil {
			continue // still live, or never reached a terminal state
		}
		proof, err := removeCheckout(ctx, c)
		switch {
		case err == nil:
			result.Proofs = append(result.Proofs, proof)
		case errors.Is(err, ErrNotCleanupEligible):
		case errors.Is(err, ErrContentUnproven):
			result.Retained = append(result.Retained, fmt.Errorf("%s: %w", c.Epoch, err))
		default:
			result.Failures = append(result.Failures, fmt.Errorf("%s: %w", c.Epoch, err))
		}
	}
	return result
}

// SweepResult is what one sweep did. Proofs are the checkouts it reclaimed.
// Retained are terminal checkouts it left in place because their content could
// not be proven preserved (ErrContentUnproven). A later sweep gives the same
// answer until someone preserves or discards that content. Failures are
// checkouts whose removal started and did not finish, plus a scan that could
// not read the directory.
type SweepResult struct {
	Proofs   []CleanupProof
	Retained []error
	Failures []error
}

// ReservedWorktreePaths canonicalizes the checkout paths a caller wants held
// back from a sweep. Canonicalization matters because registry rows store
// symlink-resolved paths while a directory scan sees whatever the parent path
// literally is.
func ReservedWorktreePaths(paths []string) map[string]bool {
	reserved := make(map[string]bool, len(paths)*2)
	for _, path := range paths {
		if path == "" {
			continue
		}
		reserved[path] = true
		if canonical, err := canonicalExisting(path); err == nil {
			reserved[canonical] = true
		}
	}
	return reserved
}

func inspectCheckout(ctx context.Context, path string) (checkout, error) {
	canonical, commonDir, gitDir, err := repositoryIdentity(ctx, path)
	if err != nil {
		return checkout{}, err
	}
	epochBytes, err := os.ReadFile(filepath.Join(gitDir, "lore-worktree-epoch"))
	if err != nil {
		return checkout{}, fmt.Errorf("read worktree epoch: %w", err)
	}
	epoch := strings.TrimSpace(string(epochBytes))
	if !validEpoch.MatchString(epoch) {
		return checkout{}, fmt.Errorf("worktree epoch is invalid")
	}
	return checkout{Path: canonical, Epoch: epoch, GitCommonDir: commonDir, GitDir: gitDir}, nil
}

// preservationEvidence collects the refs that must outlive this checkout and
// reports whether the session ever reached a terminal state. The result and
// quarantine refs are written only by MakePublishable and Quarantine, both of
// which require an activated session, so the presence of either is the terminal
// proof — an in-flight session has only its captured ref.
func preservationEvidence(ctx context.Context, c checkout) ([]RefOID, bool, error) {
	terminalRefs := []string{resultRefFor(c.Epoch), quarantineRefFor(c.Epoch)}
	all := append([]string{capturedRefFor(c.Epoch)}, terminalRefs...)
	var preserved []RefOID
	terminal := false
	for _, ref := range all {
		oid, err := gitString(ctx, c.GitCommonDir, "rev-parse", "--verify", "--quiet", ref)
		if err != nil || oid == "" {
			continue
		}
		preserved = append(preserved, RefOID{Ref: ref, OID: oid})
		for _, t := range terminalRefs {
			if ref == t {
				terminal = true
			}
		}
	}
	if !terminal {
		return preserved, false, fmt.Errorf("%w: no result or quarantine ref for epoch %s", ErrNotCleanupEligible, c.Epoch)
	}
	return preserved, true, nil
}

func removeCheckout(ctx context.Context, c checkout) (CleanupProof, error) {
	proof := CleanupProof{Epoch: c.Epoch, Path: c.Path, RefsDisposition: "preserved"}

	preserved, _, err := preservationEvidence(ctx, c)
	if err != nil {
		proof.PreservedRefs = preserved
		return proof, err
	}

	// Session checkouts are created detached, but a session that committed its
	// work checks out a branch to hold it. That branch is work product, not
	// scaffolding: `git worktree remove` releases the checkout and leaves the
	// branch in refs/heads, so it joins the preserved set and is re-verified
	// after removal rather than deleted along with the directory. This is the
	// second place a session tree diverges from a manager-owned one, which
	// deletes its temporary branch as part of its proof.
	branchDisposition := "detached (no branch created)"
	if branch, err := gitString(ctx, c.Path, "symbolic-ref", "-q", "HEAD"); err == nil && branch != "" {
		oid, err := gitString(ctx, c.GitCommonDir, "rev-parse", "--verify", "--quiet", branch)
		if err != nil || oid == "" {
			return proof, fmt.Errorf("session worktree holds unresolvable branch %s", branch)
		}
		preserved = append(preserved, RefOID{Ref: branch, OID: oid})
		branchDisposition = "preserved " + branch
	}
	proof.PreservedRefs = preserved
	proof.BranchDisposition = branchDisposition

	// Nothing may be removed until the bytes on disk are provably reachable from
	// a ref that survives the removal. A checkout that drifted after its result
	// was materialized holds content no ref describes, so it is left alone.
	contentRef := "terminal refs (checkout already absent)"
	var errContent error
	if _, statErr := os.Lstat(c.Path); os.IsNotExist(statErr) {
		proof.BranchDisposition = "checkout already absent; branches unchanged"
	} else if statErr != nil {
		errContent = statErr
	} else {
		contentRef, errContent = contentPreservedBy(ctx, c, preserved)
		if errContent != nil {
			if _, statErr := os.Lstat(c.Path); os.IsNotExist(statErr) {
				// Hosts sharing a store sweep the same directory, so another one can
				// finish reclaiming this checkout while it is being digested. With the
				// directory gone there is no content left to prove, and the
				// assertions below still check that removal was complete.
				contentRef, errContent = "terminal refs (checkout removed concurrently)", nil
				proof.BranchDisposition = "checkout removed concurrently; branches unchanged"
			}
		}
	}
	err = errContent
	if err != nil {
		return proof, err
	}
	proof.ContentProvenBy = contentRef

	if _, err := gitOutput(ctx, c.GitCommonDir, nil, nil, "worktree", "remove", "--force", c.Path); err != nil {
		// A checkout Git has already forgotten still needs its directory gone;
		// only a directory that survives the attempt is a real failure.
		if _, statErr := os.Lstat(c.Path); statErr == nil {
			return proof, fmt.Errorf("remove session worktree: %w", err)
		}
	}
	// Prune clears the per-worktree admin directory under .git/worktrees for any
	// checkout whose directory is gone, including ones a previous crash left
	// half-removed.
	if _, err := gitOutput(ctx, c.GitCommonDir, nil, nil, "worktree", "prune"); err != nil {
		return proof, fmt.Errorf("prune worktree registry: %w", err)
	}

	if _, statErr := os.Lstat(c.Path); os.IsNotExist(statErr) {
		proof.PathAbsent = true
	}
	registered, err := registeredWorktreePaths(ctx, c.GitCommonDir)
	if err != nil {
		return proof, err
	}
	proof.RegistryAbsent = !registered[c.Path]
	if _, statErr := os.Lstat(c.GitDir); os.IsNotExist(statErr) {
		proof.AdminDirAbsent = true
	}

	// The whole point of the operation: every preserved ref still resolves to the
	// object it named before removal.
	for _, ref := range preserved {
		oid, err := gitString(ctx, c.GitCommonDir, "rev-parse", "--verify", "--quiet", ref.Ref)
		if err != nil || oid != ref.OID {
			return proof, fmt.Errorf("preserved ref %s did not survive cleanup", ref.Ref)
		}
	}

	proof.Verified = proof.PathAbsent && proof.RegistryAbsent && proof.AdminDirAbsent
	if !proof.Verified {
		return proof, fmt.Errorf("session worktree cleanup left residue at %s", c.Path)
	}
	return proof, nil
}

// digestCheckout is snapshotTree, held in a variable so a test can reproduce
// another host reclaiming the checkout while this one is digesting it.
var digestCheckout = snapshotTree

// contentPreservedBy returns the ref whose tree equals the checkout's current
// content. Any preserved ref counts: matching captured means the session changed
// nothing, matching result or quarantine means its output was materialized.
func contentPreservedBy(ctx context.Context, c checkout, preserved []RefOID) (string, error) {
	live, err := digestCheckout(ctx, c.Path, c.GitDir)
	if err != nil {
		return "", fmt.Errorf("%w: digest session worktree at %s: %v", ErrContentUnproven, c.Path, err)
	}
	for _, ref := range preserved {
		tree, err := gitString(ctx, c.GitCommonDir, "rev-parse", "--verify", "--quiet", ref.OID+"^{tree}")
		if err != nil {
			continue
		}
		if tree == live {
			return ref.Ref, nil
		}
	}
	return "", fmt.Errorf("%w: content at %s is not reachable from any preserved ref", ErrContentUnproven, c.Path)
}

func registeredWorktreePaths(ctx context.Context, repositoryPath string) (map[string]bool, error) {
	listing, err := gitOutput(ctx, repositoryPath, nil, nil, "worktree", "list", "--porcelain")
	if err != nil {
		return nil, fmt.Errorf("list worktree registry: %w", err)
	}
	paths := make(map[string]bool)
	for _, line := range strings.Split(string(listing), "\n") {
		rest, ok := strings.CutPrefix(strings.TrimRight(line, "\r"), "worktree ")
		if !ok {
			continue
		}
		abs, err := filepath.Abs(rest)
		if err != nil {
			continue
		}
		paths[filepath.Clean(abs)] = true
		if canonical, err := canonicalExisting(abs); err == nil {
			paths[canonical] = true
		}
	}
	return paths, nil
}

func capturedRefFor(epoch string) string   { return "refs/lore/worktrees/" + epoch + "/captured" }
func resultRefFor(epoch string) string     { return "refs/lore/worktrees/" + epoch + "/result" }
func quarantineRefFor(epoch string) string { return "refs/lore/quarantine/" + epoch }

// SortProofs orders proofs by epoch so a reclaim summary reads deterministically.
func SortProofs(proofs []CleanupProof) {
	sort.Slice(proofs, func(i, j int) bool { return proofs[i].Epoch < proofs[j].Epoch })
}
