package gh

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
)

// PRStatus holds the review state of a single pull request.
type PRStatus struct {
	Number         int    `json:"number"`
	Title          string `json:"title"`
	State          string `json:"state"`          // OPEN, CLOSED, MERGED
	URL            string `json:"url"`
	ReviewDecision string `json:"reviewDecision"` // APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or ""
}

// Badge returns a short display string combining state and review decision.
// Examples: "OPEN·APPROVED", "OPEN·CHANGES_REQUESTED", "MERGED", "OPEN".
func (p PRStatus) Badge() string {
	if p.ReviewDecision == "" {
		return p.State
	}
	return p.State + "·" + p.ReviewDecision
}

// LoadPRStatus runs `gh pr list` once and returns a map keyed by PR number
// as a string (e.g. "42"), matching the format used in _meta.json's `pr` field.
func LoadPRStatus(ctx context.Context) (map[string]PRStatus, error) {
	cmd := exec.CommandContext(ctx, "gh", "pr", "list",
		"--json", "number,title,state,url,reviewDecision",
		"--limit", "100",
		"--state", "all",
	)

	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	var prs []PRStatus
	if err := json.Unmarshal(out, &prs); err != nil {
		return nil, err
	}

	m := make(map[string]PRStatus, len(prs))
	for _, pr := range prs {
		key := prNumberToKey(pr.Number)
		m[key] = pr
	}

	return m, nil
}

// prNumberToKey converts a PR number to the string key format used in _meta.json.
func prNumberToKey(n int) string {
	return fmt.Sprintf("%d", n)
}

// MergeClassification is the normalized merge-readiness category derived from
// the joint (mergeable, mergeStateStatus) fields.
type MergeClassification int

const (
	MergeOK      MergeClassification = iota // MERGEABLE + CLEAN
	MergeWarn                               // BEHIND
	MergeBlocked                            // CONFLICTING or DIRTY
	MergeUnknown                            // UNKNOWN or unrecognized
)

// MergeStatus holds the merge-readiness fields returned by `gh pr view
// --json state,mergeable,mergeStateStatus`. All fields are plain strings
// matching the GraphQL enum values. State is consulted first so that merged
// and closed PRs do not fall into the unknown bucket (GitHub reports
// mergeable=UNKNOWN/mergeStateStatus=UNKNOWN once a PR is no longer open).
type MergeStatus struct {
	State            string `json:"state"`
	Mergeable        string `json:"mergeable"`
	MergeStateStatus string `json:"mergeStateStatus"`
}

// Classification returns the normalized MergeClassification derived from the
// (State, Mergeable, MergeStateStatus) triple. The model collapses to three
// operatively-meaningful buckets: OK for an open PR a reviewer can act on,
// Blocked for an open PR whose conflicts prevent review progress, and Unknown
// (rendered dim) for terminal states where the review is no longer operative.
func (s MergeStatus) Classification() MergeClassification {
	if s.State == "MERGED" || s.State == "CLOSED" {
		return MergeUnknown
	}
	if s.Mergeable == "CONFLICTING" || s.MergeStateStatus == "DIRTY" {
		return MergeBlocked
	}
	return MergeOK
}

// Label returns a short human-readable string describing the merge status.
func (s MergeStatus) Label() string {
	switch s.State {
	case "MERGED":
		return "merged"
	case "CLOSED":
		return "closed"
	}
	if s.Mergeable == "CONFLICTING" || s.MergeStateStatus == "DIRTY" {
		return "conflicts"
	}
	return "open"
}

// LoadMergeStatus runs `gh pr view <pr> --repo <owner>/<repo> --json state,mergeable,mergeStateStatus`
// and returns the parsed MergeStatus. Follows the LoadPRStatus convention.
func LoadMergeStatus(ctx context.Context, owner, repo string, pr int) (MergeStatus, error) {
	cmd := exec.CommandContext(ctx, "gh", "pr", "view", fmt.Sprintf("%d", pr),
		"--repo", fmt.Sprintf("%s/%s", owner, repo),
		"--json", "state,mergeable,mergeStateStatus",
	)

	out, err := cmd.Output()
	if err != nil {
		return MergeStatus{}, err
	}

	var status MergeStatus
	if err := json.Unmarshal(out, &status); err != nil {
		return MergeStatus{}, err
	}

	return status, nil
}
