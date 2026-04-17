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

func TestMergeStatusJSONParsing(t *testing.T) {
	tests := []struct {
		raw              string
		wantMergeable    string
		wantMergeState   string
	}{
		{
			raw:            `{"mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN"}`,
			wantMergeable:  "MERGEABLE",
			wantMergeState: "CLEAN",
		},
		{
			raw:            `{"mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN"}`,
			wantMergeable:  "UNKNOWN",
			wantMergeState: "UNKNOWN",
		},
		{
			raw:            `{"mergeable": "CONFLICTING", "mergeStateStatus": "DIRTY"}`,
			wantMergeable:  "CONFLICTING",
			wantMergeState: "DIRTY",
		},
	}

	for _, tt := range tests {
		var s MergeStatus
		if err := json.Unmarshal([]byte(tt.raw), &s); err != nil {
			t.Fatalf("Unmarshal(%q) failed: %v", tt.raw, err)
		}
		if s.Mergeable != tt.wantMergeable {
			t.Errorf("Mergeable = %q, want %q", s.Mergeable, tt.wantMergeable)
		}
		if s.MergeStateStatus != tt.wantMergeState {
			t.Errorf("MergeStateStatus = %q, want %q", s.MergeStateStatus, tt.wantMergeState)
		}
	}
}

func TestMergeStatusClassification(t *testing.T) {
	tests := []struct {
		state            string
		mergeable        string
		mergeStateStatus string
		wantClass        MergeClassification
		wantLabel        string
	}{
		// Open PRs collapse into two buckets: operative ("open") or blocked ("conflicts").
		// BEHIND/BLOCKED/UNSTABLE/UNKNOWN all present as "open" because the review is still
		// actionable — the check state is not the reviewer's concern.
		{"OPEN", "MERGEABLE", "CLEAN", MergeOK, "open"},
		{"OPEN", "MERGEABLE", "BEHIND", MergeOK, "open"},
		{"OPEN", "MERGEABLE", "UNSTABLE", MergeOK, "open"},
		{"OPEN", "MERGEABLE", "BLOCKED", MergeOK, "open"},
		{"OPEN", "UNKNOWN", "UNKNOWN", MergeOK, "open"},
		{"OPEN", "CONFLICTING", "DIRTY", MergeBlocked, "conflicts"},
		{"OPEN", "CONFLICTING", "CLEAN", MergeBlocked, "conflicts"},
		{"OPEN", "MERGEABLE", "DIRTY", MergeBlocked, "conflicts"},

		// Terminal PR states — review no longer operative; rendered dim via MergeUnknown.
		{"MERGED", "UNKNOWN", "UNKNOWN", MergeUnknown, "merged"},
		{"CLOSED", "UNKNOWN", "UNKNOWN", MergeUnknown, "closed"},
	}

	for _, tt := range tests {
		s := MergeStatus{State: tt.state, Mergeable: tt.mergeable, MergeStateStatus: tt.mergeStateStatus}
		if got := s.Classification(); got != tt.wantClass {
			t.Errorf("Classification(%q, %q, %q) = %v, want %v", tt.state, tt.mergeable, tt.mergeStateStatus, got, tt.wantClass)
		}
		if got := s.Label(); got != tt.wantLabel {
			t.Errorf("Label(%q, %q, %q) = %q, want %q", tt.state, tt.mergeable, tt.mergeStateStatus, got, tt.wantLabel)
		}
	}
}
