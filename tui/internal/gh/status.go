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
