package gh

import (
	"encoding/json"
	"testing"
)

func TestPRStatusBadge(t *testing.T) {
	tests := []struct {
		state          string
		reviewDecision string
		want           string
	}{
		{"OPEN", "APPROVED", "OPEN·APPROVED"},
		{"OPEN", "CHANGES_REQUESTED", "OPEN·CHANGES_REQUESTED"},
		{"OPEN", "REVIEW_REQUIRED", "OPEN·REVIEW_REQUIRED"},
		{"OPEN", "", "OPEN"},
		{"MERGED", "", "MERGED"},
		{"CLOSED", "", "CLOSED"},
	}

	for _, tt := range tests {
		p := PRStatus{State: tt.state, ReviewDecision: tt.reviewDecision}
		got := p.Badge()
		if got != tt.want {
			t.Errorf("Badge(%q, %q) = %q, want %q", tt.state, tt.reviewDecision, got, tt.want)
		}
	}
}

func TestPRStatusJSONParsing(t *testing.T) {
	raw := `[
		{"number":42,"title":"Add feature","state":"OPEN","url":"https://github.com/org/repo/pull/42","reviewDecision":"APPROVED"},
		{"number":7,"title":"Fix bug","state":"MERGED","url":"https://github.com/org/repo/pull/7","reviewDecision":""}
	]`

	var prs []PRStatus
	if err := json.Unmarshal([]byte(raw), &prs); err != nil {
		t.Fatalf("Unmarshal failed: %v", err)
	}

	if len(prs) != 2 {
		t.Fatalf("expected 2 PRs, got %d", len(prs))
	}

	if prs[0].Number != 42 || prs[0].State != "OPEN" || prs[0].ReviewDecision != "APPROVED" {
		t.Errorf("unexpected first PR: %+v", prs[0])
	}

	if prs[1].Number != 7 || prs[1].State != "MERGED" || prs[1].ReviewDecision != "" {
		t.Errorf("unexpected second PR: %+v", prs[1])
	}
}

func TestPRNumberToKey(t *testing.T) {
	if got := prNumberToKey(42); got != "42" {
		t.Errorf("prNumberToKey(42) = %q, want %q", got, "42")
	}
	if got := prNumberToKey(0); got != "0" {
		t.Errorf("prNumberToKey(0) = %q, want %q", got, "0")
	}
}
