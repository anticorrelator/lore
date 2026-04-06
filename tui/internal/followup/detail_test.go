package followup

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestLoadFollowUpDetailValid(t *testing.T) {
	knowledgeDir := t.TempDir()
	id := "test-followup"
	itemDir := filepath.Join(knowledgeDir, "_followups", id)
	os.MkdirAll(itemDir, 0755)

	meta := `{
		"id": "test-followup",
		"title": "Test Follow-Up",
		"status": "open",
		"severity": "high",
		"source": "review",
		"attachments": [],
		"suggested_actions": [],
		"created": "2026-03-01T00:00:00Z",
		"updated": "2026-03-01T00:00:00Z"
	}`
	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(meta), 0644)
	os.WriteFile(filepath.Join(itemDir, "finding.md"), []byte("# Finding\n\nDetails here."), 0644)

	detail, err := LoadFollowUpDetail(knowledgeDir, id)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if detail.ID != "test-followup" {
		t.Errorf("ID = %q, want %q", detail.ID, "test-followup")
	}
	if detail.Title != "Test Follow-Up" {
		t.Errorf("Title = %q, want %q", detail.Title, "Test Follow-Up")
	}
	if detail.Malformed {
		t.Error("Malformed should be false for valid meta")
	}
	if detail.FindingContent != "# Finding\n\nDetails here." {
		t.Errorf("FindingContent = %q", detail.FindingContent)
	}
}

func TestLoadFollowUpDetailMalformedMeta(t *testing.T) {
	knowledgeDir := t.TempDir()
	id := "bad-meta"
	itemDir := filepath.Join(knowledgeDir, "_followups", id)
	os.MkdirAll(itemDir, 0755)

	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte("not valid json{{{"), 0644)

	detail, err := LoadFollowUpDetail(knowledgeDir, id)
	if err != nil {
		t.Fatalf("malformed meta should not return error, got: %v", err)
	}
	if !detail.Malformed {
		t.Error("Malformed should be true")
	}
	if detail.ID != id {
		t.Errorf("ID = %q, want %q", detail.ID, id)
	}
	if !strings.Contains(detail.Title, "[malformed]") {
		t.Errorf("Title = %q, want it to contain [malformed]", detail.Title)
	}
	if !strings.Contains(detail.Title, id) {
		t.Errorf("Title = %q, want it to contain %q", detail.Title, id)
	}
}

func TestLoadFollowUpDetailMalformedMetaReadsFinding(t *testing.T) {
	knowledgeDir := t.TempDir()
	id := "bad-meta-with-finding"
	itemDir := filepath.Join(knowledgeDir, "_followups", id)
	os.MkdirAll(itemDir, 0755)

	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte("{corrupt}"), 0644)
	os.WriteFile(filepath.Join(itemDir, "finding.md"), []byte("# Sibling Finding\n\nStill readable."), 0644)

	detail, err := LoadFollowUpDetail(knowledgeDir, id)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !detail.Malformed {
		t.Error("Malformed should be true")
	}
	if detail.FindingContent != "# Sibling Finding\n\nStill readable." {
		t.Errorf("FindingContent = %q, want sibling content", detail.FindingContent)
	}
}

func TestLoadFollowUpDetailMissingMeta(t *testing.T) {
	knowledgeDir := t.TempDir()
	_, err := LoadFollowUpDetail(knowledgeDir, "nonexistent")
	if err == nil {
		t.Fatal("expected error for missing _meta.json")
	}
}

func TestLoadFollowUpDetailMissingFinding(t *testing.T) {
	knowledgeDir := t.TempDir()
	id := "no-finding"
	itemDir := filepath.Join(knowledgeDir, "_followups", id)
	os.MkdirAll(itemDir, 0755)

	meta := `{"id":"no-finding","title":"No Finding","status":"open","severity":"low","source":"test","attachments":[],"suggested_actions":[],"created":"2026-03-01T00:00:00Z","updated":"2026-03-01T00:00:00Z"}`
	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(meta), 0644)
	// no finding.md written

	detail, err := LoadFollowUpDetail(knowledgeDir, id)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if detail.FindingContent != "" {
		t.Errorf("FindingContent should be empty, got %q", detail.FindingContent)
	}
	if detail.Malformed {
		t.Error("Malformed should be false for valid meta")
	}
}

// --- Sidecar loading tests ---

func TestLoadFollowUpDetailSidecarPresent(t *testing.T) {
	knowledgeDir := t.TempDir()
	id := "with-sidecar"
	itemDir := filepath.Join(knowledgeDir, "_followups", id)
	os.MkdirAll(itemDir, 0755)

	meta := `{"id":"with-sidecar","title":"With Sidecar","status":"open","severity":"high","source":"pr-review","attachments":[],"suggested_actions":[],"created":"2026-03-01T00:00:00Z","updated":"2026-03-01T00:00:00Z"}`
	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(meta), 0644)

	sidecar := `{
		"pr": 42,
		"owner": "anticorrelator",
		"repo": "lore",
		"head_sha": "abc123",
		"comments": [
			{"id":"c1","path":"main.go","line":10,"body":"Fix this.","selected":true,"severity":"high","lenses":["correctness"],"confidence":0.9}
		]
	}`
	os.WriteFile(filepath.Join(itemDir, "proposed-comments.json"), []byte(sidecar), 0644)

	detail, err := LoadFollowUpDetail(knowledgeDir, id)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if detail.ProposedComments == nil {
		t.Fatal("ProposedComments should be non-nil when sidecar exists")
	}
	if detail.ProposedComments.PR != 42 {
		t.Errorf("PR = %d, want 42", detail.ProposedComments.PR)
	}
	if detail.ProposedComments.Owner != "anticorrelator" {
		t.Errorf("Owner = %q, want %q", detail.ProposedComments.Owner, "anticorrelator")
	}
	if detail.ProposedComments.HeadSHA != "abc123" {
		t.Errorf("HeadSHA = %q, want %q", detail.ProposedComments.HeadSHA, "abc123")
	}
	if len(detail.ProposedComments.Comments) != 1 {
		t.Fatalf("Comments len = %d, want 1", len(detail.ProposedComments.Comments))
	}
	c := detail.ProposedComments.Comments[0]
	if c.ID != "c1" || c.Path != "main.go" || c.Line != 10 {
		t.Errorf("Comment = %+v, unexpected values", c)
	}
	if !c.Selected {
		t.Error("Comment should be selected")
	}
}

func TestLoadFollowUpDetailSidecarAbsent(t *testing.T) {
	knowledgeDir := t.TempDir()
	id := "no-sidecar"
	itemDir := filepath.Join(knowledgeDir, "_followups", id)
	os.MkdirAll(itemDir, 0755)

	meta := `{"id":"no-sidecar","title":"No Sidecar","status":"open","severity":"low","source":"test","attachments":[],"suggested_actions":[],"created":"2026-03-01T00:00:00Z","updated":"2026-03-01T00:00:00Z"}`
	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(meta), 0644)

	detail, err := LoadFollowUpDetail(knowledgeDir, id)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if detail.ProposedComments != nil {
		t.Errorf("ProposedComments should be nil when sidecar absent, got %+v", detail.ProposedComments)
	}
}

func TestLoadFollowUpDetailSidecarMalformed(t *testing.T) {
	knowledgeDir := t.TempDir()
	id := "bad-sidecar"
	itemDir := filepath.Join(knowledgeDir, "_followups", id)
	os.MkdirAll(itemDir, 0755)

	meta := `{"id":"bad-sidecar","title":"Bad Sidecar","status":"open","severity":"low","source":"test","attachments":[],"suggested_actions":[],"created":"2026-03-01T00:00:00Z","updated":"2026-03-01T00:00:00Z"}`
	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(meta), 0644)
	os.WriteFile(filepath.Join(itemDir, "proposed-comments.json"), []byte("{not valid json!!}"), 0644)

	detail, err := LoadFollowUpDetail(knowledgeDir, id)
	if err != nil {
		t.Fatalf("malformed sidecar should not cause error, got: %v", err)
	}
	if detail.ProposedComments != nil {
		t.Errorf("ProposedComments should be nil for malformed sidecar, got %+v", detail.ProposedComments)
	}
	if detail.Malformed {
		t.Error("Malformed should be false — only _meta.json malformation sets this")
	}
}

func TestLoadFollowUpDetailSidecarBareArray(t *testing.T) {
	knowledgeDir := t.TempDir()
	id := "bare-array-sidecar"
	itemDir := filepath.Join(knowledgeDir, "_followups", id)
	os.MkdirAll(itemDir, 0755)

	meta := `{"id":"bare-array-sidecar","title":"Bare Array","status":"open","severity":"high","source":"pr-review","attachments":[],"suggested_actions":[],"created":"2026-03-01T00:00:00Z","updated":"2026-03-01T00:00:00Z"}`
	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(meta), 0644)

	// Bare array — the format produced by /pr-review skill.
	sidecar := `[
		{"path":"main.go","line":49,"body":"Consider using a constant here."},
		{"path":"util.go","line":12,"body":"This could be simplified."}
	]`
	os.WriteFile(filepath.Join(itemDir, "proposed-comments.json"), []byte(sidecar), 0644)

	detail, err := LoadFollowUpDetail(knowledgeDir, id)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if detail.ProposedComments == nil {
		t.Fatal("ProposedComments should be non-nil for bare-array sidecar")
	}
	if len(detail.ProposedComments.Comments) != 2 {
		t.Fatalf("Comments len = %d, want 2", len(detail.ProposedComments.Comments))
	}
	c := detail.ProposedComments.Comments[0]
	if c.Path != "main.go" || c.Line != 49 {
		t.Errorf("Comment[0] = %+v, unexpected values", c)
	}
}

// --- DetailModel tests ---

func writeFollowUpFixture(t *testing.T, knowledgeDir, id, metaJSON, findingContent string) {
	t.Helper()
	itemDir := filepath.Join(knowledgeDir, "_followups", id)
	if err := os.MkdirAll(itemDir, 0755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	if err := os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(metaJSON), 0644); err != nil {
		t.Fatalf("WriteFile meta: %v", err)
	}
	if findingContent != "" {
		if err := os.WriteFile(filepath.Join(itemDir, "finding.md"), []byte(findingContent), 0644); err != nil {
			t.Fatalf("WriteFile finding: %v", err)
		}
	}
}

func TestDetailModelSetIDTriggersLoad(t *testing.T) {
	knowledgeDir := t.TempDir()
	id := "model-load-test"
	meta := `{"id":"model-load-test","title":"Model Load Test","status":"open","severity":"medium","source":"ci","attachments":[],"suggested_actions":[],"created":"2026-03-01T00:00:00Z","updated":"2026-03-01T00:00:00Z"}`
	writeFollowUpFixture(t, knowledgeDir, id, meta, "# Heading\n\nFirst line.\nSecond line.")

	m := NewDetailModel(knowledgeDir)
	cmd := m.SetID(id)
	if cmd == nil {
		t.Fatal("SetID should return a non-nil Cmd")
	}
	if m.CurrentID() != id {
		t.Errorf("CurrentID = %q, want %q", m.CurrentID(), id)
	}

	// Execute the command to get the DetailLoadedMsg.
	msg := cmd()
	loaded, ok := msg.(DetailLoadedMsg)
	if !ok {
		t.Fatalf("cmd() returned %T, want DetailLoadedMsg", msg)
	}
	if loaded.Err != nil {
		t.Fatalf("DetailLoadedMsg.Err = %v", loaded.Err)
	}
	if loaded.Detail == nil {
		t.Fatal("DetailLoadedMsg.Detail is nil")
	}
	if loaded.Detail.Title != "Model Load Test" {
		t.Errorf("Title = %q, want %q", loaded.Detail.Title, "Model Load Test")
	}
}

func TestDetailModelSetIDSameIDNoOp(t *testing.T) {
	knowledgeDir := t.TempDir()
	id := "same-id-test"
	meta := `{"id":"same-id-test","title":"Same ID","status":"open","severity":"low","source":"test","attachments":[],"suggested_actions":[],"created":"2026-03-01T00:00:00Z","updated":"2026-03-01T00:00:00Z"}`
	writeFollowUpFixture(t, knowledgeDir, id, meta, "")

	m := NewDetailModel(knowledgeDir)
	m.SetID(id)

	// Setting the same ID again should be a no-op.
	cmd := m.SetID(id)
	if cmd != nil {
		t.Error("SetID with same ID should return nil Cmd")
	}
}

func TestDetailModelHandlesDetailLoadedMsg(t *testing.T) {
	knowledgeDir := t.TempDir()
	id := "handle-msg-test"
	meta := `{"id":"handle-msg-test","title":"Handle Msg","status":"pending","severity":"high","source":"pr","attachments":[],"suggested_actions":[],"created":"2026-03-01T00:00:00Z","updated":"2026-03-01T00:00:00Z"}`
	writeFollowUpFixture(t, knowledgeDir, id, meta, "Some finding text.")

	m := NewDetailModel(knowledgeDir)
	m.SetID(id)

	detail := &FollowUpDetail{
		ID:               id,
		Title:            "Handle Msg",
		Status:           "pending",
		FindingContent:   "Some finding text.",
		Attachments:      []Attachment{},
		SuggestedActions: []SuggestedAction{},
	}
	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})
	if updated.Title() != "Handle Msg" {
		t.Errorf("Title() = %q, want %q", updated.Title(), "Handle Msg")
	}
	if updated.Status() != "pending" {
		t.Errorf("Status() = %q, want %q", updated.Status(), "pending")
	}
}

func TestDetailModelHandlesDetailLoadedMsgWrongID(t *testing.T) {
	knowledgeDir := t.TempDir()
	id := "correct-id"
	meta := `{"id":"correct-id","title":"Correct","status":"open","severity":"low","source":"test","attachments":[],"suggested_actions":[],"created":"2026-03-01T00:00:00Z","updated":"2026-03-01T00:00:00Z"}`
	writeFollowUpFixture(t, knowledgeDir, id, meta, "")

	m := NewDetailModel(knowledgeDir)
	m.SetID(id)

	// A DetailLoadedMsg for a different ID should be ignored.
	detail := &FollowUpDetail{ID: "other-id", Title: "Other", Attachments: []Attachment{}, SuggestedActions: []SuggestedAction{}}
	updated, _ := m.Update(DetailLoadedMsg{ID: "other-id", Detail: detail})
	if updated.Title() != "" {
		t.Errorf("Title() = %q, want %q (model should not update for wrong ID)", updated.Title(), "")
	}
}

func TestDetailModelClearIDAllowsReload(t *testing.T) {
	knowledgeDir := t.TempDir()
	id := "clear-id-test"
	meta := `{"id":"clear-id-test","title":"Clear ID","status":"open","severity":"low","source":"test","attachments":[],"suggested_actions":[],"created":"2026-03-01T00:00:00Z","updated":"2026-03-01T00:00:00Z"}`
	writeFollowUpFixture(t, knowledgeDir, id, meta, "")

	m := NewDetailModel(knowledgeDir)
	m.SetID(id)

	// After ClearID, setting the same ID again should produce a new load Cmd.
	m.ClearID()
	cmd := m.SetID(id)
	if cmd == nil {
		t.Error("SetID after ClearID should return a non-nil Cmd")
	}
}

// --- FindingExcerpt tests ---

func TestFindingExcerptSkipsHeadings(t *testing.T) {
	detail := &FollowUpDetail{
		FindingContent: "# Title Heading\n\n## Section\n\nFirst real line.\nSecond real line.\nThird real line.\nFourth line (over limit).",
	}
	m := DetailModel{detail: detail}
	excerpt := m.FindingExcerpt()
	if strings.Contains(excerpt, "#") {
		t.Errorf("FindingExcerpt should skip heading lines, got: %q", excerpt)
	}
	// Expect exactly the first 3 non-heading, non-empty lines joined by spaces.
	want := "First real line. Second real line. Third real line."
	if excerpt != want {
		t.Errorf("FindingExcerpt = %q, want %q", excerpt, want)
	}
}

func TestFindingExcerptLimitThreeLines(t *testing.T) {
	detail := &FollowUpDetail{
		FindingContent: "Line one.\nLine two.\nLine three.\nLine four.",
	}
	m := DetailModel{detail: detail}
	excerpt := m.FindingExcerpt()
	// Should join exactly the first 3 lines with spaces.
	want := "Line one. Line two. Line three."
	if excerpt != want {
		t.Errorf("FindingExcerpt = %q, want %q", excerpt, want)
	}
}

func TestFindingExcerptEmptyFinding(t *testing.T) {
	detail := &FollowUpDetail{FindingContent: ""}
	m := DetailModel{detail: detail}
	if m.FindingExcerpt() != "" {
		t.Errorf("FindingExcerpt should be empty for empty FindingContent")
	}
}

func TestFindingExcerptNilDetail(t *testing.T) {
	m := DetailModel{}
	if m.FindingExcerpt() != "" {
		t.Errorf("FindingExcerpt should be empty for nil detail")
	}
}

func TestFindingExcerptOnlyHeadings(t *testing.T) {
	detail := &FollowUpDetail{
		FindingContent: "# Heading One\n## Heading Two\n### Heading Three\n",
	}
	m := DetailModel{detail: detail}
	if m.FindingExcerpt() != "" {
		t.Errorf("FindingExcerpt should be empty when all lines are headings, got: %q", m.FindingExcerpt())
	}
}

// --- DetailModel + ReviewCardsModel integration tests ---

func TestDetailModelUsesReviewCardsWhenSidecarPresent(t *testing.T) {
	m := NewDetailModel("/tmp/test")
	m.width = 80
	m.height = 40

	id := "with-sidecar"
	m.SetID(id)

	detail := &FollowUpDetail{
		ID:               id,
		Title:            "With Sidecar",
		Status:           "open",
		Source:           "review",
		FindingContent:   "# Finding\n\nSome finding content.",
		Attachments:      []Attachment{},
		SuggestedActions: []SuggestedAction{},
		ProposedComments: &ProposedReview{
			PR:      42,
			Owner:   "anticorrelator",
			Repo:    "lore",
			HeadSHA: "abc123",
			Comments: []ProposedComment{
				{ID: "c1", Path: "main.go", Line: 10, Body: "Fix this.", Selected: true, Severity: "high"},
			},
		},
	}

	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})

	// Three tabs: Meta, Finding, Comments.
	if len(updated.tabs) != 3 {
		t.Errorf("tabs len = %d, want 3 (Meta+Finding+Comments)", len(updated.tabs))
	}
	if updated.ActiveTab() != TabComments {
		t.Errorf("active tab = %v, want TabComments (default when comments present)", updated.ActiveTab())
	}
	if updated.reviewCards == nil {
		t.Fatal("reviewCards should be initialized")
	}

	// View should contain tab bar labels.
	out := updated.View()
	if !strings.Contains(out, "Comments") {
		t.Error("View should contain Comments tab label")
	}
	if !strings.Contains(out, "Finding") {
		t.Error("View should contain Finding tab label")
	}
}

func TestDetailModelUsesViewportWhenNoSidecar(t *testing.T) {
	m := NewDetailModel("/tmp/test")
	m.width = 80
	m.height = 40

	id := "no-sidecar"
	m.SetID(id)

	detail := &FollowUpDetail{
		ID:               id,
		Title:            "No Sidecar",
		Status:           "open",
		Source:           "test",
		FindingContent:   "# Finding\n\nDetails here.",
		Attachments:      []Attachment{},
		SuggestedActions: []SuggestedAction{},
	}

	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})

	// Two tabs only: Meta and Finding (no Comments tab without sidecar).
	if len(updated.tabs) != 2 {
		t.Errorf("tabs len = %d, want 2 (Meta+Finding)", len(updated.tabs))
	}
	if updated.activeTab != 1 {
		t.Errorf("activeTab = %d, want 1 (TabFinding)", updated.activeTab)
	}
	if updated.reviewCards != nil {
		t.Error("reviewCards should be nil when no sidecar")
	}

	out := updated.View()
	if out == "" {
		t.Error("View should not be empty for loaded detail without sidecar")
	}
	if strings.Contains(out, "Comments") {
		t.Error("View should not contain Comments tab label when no sidecar")
	}
}

func TestDetailModelTabCyclesThroughTabs(t *testing.T) {
	m := NewDetailModel("/tmp/test")
	m.width = 80
	m.height = 40

	id := "tab-cycle-test"
	m.SetID(id)

	detail := &FollowUpDetail{
		ID:               id,
		Title:            "Tab Cycle Test",
		Status:           "open",
		Source:           "review",
		FindingContent:   "# Finding\n\nFinding body text here.",
		Attachments:      []Attachment{},
		SuggestedActions: []SuggestedAction{},
		ProposedComments: &ProposedReview{
			PR:      10,
			Owner:   "test",
			Repo:    "repo",
			HeadSHA: "def456",
			Comments: []ProposedComment{
				{ID: "c1", Path: "a.go", Line: 5, Body: "Card content.", Selected: false, Severity: "low"},
			},
		},
	}

	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})

	// Should start on TabComments (default when comments present).
	if updated.ActiveTab() != TabComments {
		t.Fatalf("initial tab = %v, want TabComments", updated.ActiveTab())
	}
	startIdx := updated.activeTab

	// Tab forward wraps through all tabs.
	updated, _ = updated.Update(tea.KeyMsg{Type: tea.KeyTab})
	wantNext := (startIdx + 1) % len(updated.tabs)
	if updated.activeTab != wantNext {
		t.Errorf("after tab: activeTab = %d, want %d", updated.activeTab, wantNext)
	}

	// Shift+Tab cycles backward.
	updated, _ = updated.Update(tea.KeyMsg{Type: tea.KeyShiftTab})
	if updated.activeTab != startIdx {
		t.Errorf("after shift+tab: activeTab = %d, want %d", updated.activeTab, startIdx)
	}
}

func TestDetailModelTabCyclesWithoutComments(t *testing.T) {
	m := NewDetailModel("/tmp/test")
	m.width = 80
	m.height = 40

	id := "no-comments"
	m.SetID(id)

	detail := &FollowUpDetail{
		ID:               id,
		Title:            "No Comments",
		Status:           "open",
		Source:           "test",
		FindingContent:   "# Finding",
		Attachments:      []Attachment{},
		SuggestedActions: []SuggestedAction{},
	}

	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})

	// Without sidecar: 2 tabs (Meta=0, Finding=1), starts on Finding.
	if len(updated.tabs) != 2 {
		t.Fatalf("tabs len = %d, want 2", len(updated.tabs))
	}

	// Tab forward: Meta(0) -> Finding(1) -> Meta(0) wraps correctly.
	updated, _ = updated.Update(tea.KeyMsg{Type: tea.KeyTab})
	if updated.activeTab != 0 {
		t.Errorf("after tab from Finding: activeTab = %d, want 0 (Meta)", updated.activeTab)
	}

	updated, _ = updated.Update(tea.KeyMsg{Type: tea.KeyTab})
	if updated.activeTab != 1 {
		t.Errorf("after tab from Meta: activeTab = %d, want 1 (Finding)", updated.activeTab)
	}
}

func TestDetailModelClearIDResetsCardState(t *testing.T) {
	m := NewDetailModel("/tmp/test")
	m.width = 80
	m.height = 40

	id := "clear-cards"
	m.SetID(id)

	detail := &FollowUpDetail{
		ID:               id,
		Title:            "Clear Cards",
		Status:           "open",
		Source:           "review",
		FindingContent:   "# Finding",
		Attachments:      []Attachment{},
		SuggestedActions: []SuggestedAction{},
		ProposedComments: &ProposedReview{
			Comments: []ProposedComment{
				{ID: "c1", Path: "x.go", Line: 1, Body: "Comment.", Severity: "low"},
			},
		},
	}

	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})
	if len(updated.tabs) == 0 {
		t.Fatal("tabs should be populated after load")
	}

	updated.ClearID()
	if updated.tabs != nil {
		t.Errorf("tabs should be nil after ClearID, got %v", updated.tabs)
	}
	if updated.activeTab != 0 {
		t.Errorf("activeTab should be 0 after ClearID, got %d", updated.activeTab)
	}
	if updated.reviewCards != nil {
		t.Error("reviewCards should be nil after ClearID")
	}
}

func TestDetailModelKeyRoutesToActiveTab(t *testing.T) {
	m := NewDetailModel("/tmp/test")
	m.width = 80
	m.height = 40

	id := "key-routing"
	m.SetID(id)

	detail := &FollowUpDetail{
		ID:               id,
		Title:            "Key Routing",
		Status:           "open",
		Source:           "review",
		FindingContent:   "# Finding",
		Attachments:      []Attachment{},
		SuggestedActions: []SuggestedAction{},
		ProposedComments: &ProposedReview{
			Comments: []ProposedComment{
				{ID: "c1", Path: "a.go", Line: 1, Body: "One.", Severity: "low"},
				{ID: "c2", Path: "b.go", Line: 2, Body: "Two.", Severity: "low"},
			},
		},
	}

	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})

	// Sidecar present: default active tab is TabComments.
	if updated.ActiveTab() != TabComments {
		t.Fatalf("active tab = %v, want TabComments", updated.ActiveTab())
	}
	if updated.reviewCards.cursor != 0 {
		t.Fatalf("initial cards cursor = %d, want 0", updated.reviewCards.cursor)
	}

	// j key routes to reviewCards when active tab is TabComments.
	updated, _ = updated.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	if updated.reviewCards.cursor != 1 {
		t.Errorf("after j on Comments tab: cards cursor = %d, want 1", updated.reviewCards.cursor)
	}

	// Switch to Finding tab, keys should route to viewport (cursor stays at reviewCards).
	updated.activeTab = updated.tabIndexFor(TabFinding)
	if updated.ActiveTab() != TabFinding {
		t.Fatalf("active tab = %v, want TabFinding after manual switch", updated.ActiveTab())
	}
	// j key on Finding tab should not change reviewCards cursor.
	cardsCursorBefore := updated.reviewCards.cursor
	updated, _ = updated.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	if updated.reviewCards.cursor != cardsCursorBefore {
		t.Errorf("j on Finding tab: reviewCards cursor changed from %d to %d (should not)", cardsCursorBefore, updated.reviewCards.cursor)
	}
}

func TestDetailModelWriteSidecarMsgReachesInactiveComments(t *testing.T) {
	m := NewDetailModel("/tmp/test")
	m.width = 80
	m.height = 40

	id := "sidecar-msg-test"
	m.SetID(id)

	detail := &FollowUpDetail{
		ID:               id,
		Title:            "Sidecar Msg Test",
		Status:           "open",
		Source:           "review",
		FindingContent:   "# Finding",
		Attachments:      []Attachment{},
		SuggestedActions: []SuggestedAction{},
		ProposedComments: &ProposedReview{
			Comments: []ProposedComment{
				{ID: "c1", Path: "a.go", Line: 1, Body: "One.", Severity: "low"},
			},
		},
	}

	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})

	// Switch away from Comments tab to Finding.
	updated.activeTab = updated.tabIndexFor(TabFinding)
	if updated.ActiveTab() != TabFinding {
		t.Fatalf("active tab = %v, want TabFinding", updated.ActiveTab())
	}

	// WriteSidecarMsg should still be forwarded to reviewCards regardless of active tab.
	writeErr := WriteSidecarMsg{Err: nil}
	updated, _ = updated.Update(writeErr)
	// reviewCards should still be non-nil (not lost by the write message).
	if updated.reviewCards == nil {
		t.Error("reviewCards should remain non-nil after WriteSidecarMsg while on Finding tab")
	}
}

func TestDetailModelWindowSizeMsgForwardsToAllTabs(t *testing.T) {
	m := NewDetailModel("/tmp/test")
	m.width = 80
	m.height = 40

	id := "window-size-test"
	m.SetID(id)

	detail := &FollowUpDetail{
		ID:               id,
		Title:            "Window Size Test",
		Status:           "open",
		Source:           "review",
		FindingContent:   "# Finding",
		Attachments:      []Attachment{},
		SuggestedActions: []SuggestedAction{},
		ProposedComments: &ProposedReview{
			Comments: []ProposedComment{
				{ID: "c1", Path: "a.go", Line: 1, Body: "One.", Severity: "low"},
			},
		},
	}

	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})

	// Switch to Meta tab to verify WindowSizeMsg still updates viewport and reviewCards.
	updated.activeTab = updated.tabIndexFor(TabMeta)

	updated, _ = updated.Update(tea.WindowSizeMsg{Width: 120, Height: 50})

	if updated.width != 120 || updated.height != 50 {
		t.Errorf("dimensions = %dx%d, want 120x50", updated.width, updated.height)
	}
	// Viewport should be sized to inner content dimensions.
	wantW := updated.contentWidth()
	wantH := updated.contentHeight()
	if updated.viewport.Width != wantW {
		t.Errorf("viewport.Width = %d, want %d", updated.viewport.Width, wantW)
	}
	if updated.viewport.Height != wantH {
		t.Errorf("viewport.Height = %d, want %d", updated.viewport.Height, wantH)
	}
	// reviewCards should have received the updated dimensions.
	if updated.reviewCards == nil {
		t.Fatal("reviewCards should remain non-nil after WindowSizeMsg")
	}
}

func TestDetailModelMetaTabRendersMetadata(t *testing.T) {
	m := NewDetailModel("/tmp/test")
	m.width = 80
	m.height = 40

	id := "meta-render-test"
	m.SetID(id)

	detail := &FollowUpDetail{
		ID:     id,
		Title:  "Meta Render Test",
		Status: "open",
		Source: "pr-review",
		Attachments: []Attachment{
			{Type: "pr", Ref: "anticorrelator/lore#42"},
		},
		SuggestedActions: []SuggestedAction{
			{Type: "inline-comments"},
		},
		FindingContent: "# Finding",
	}

	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})

	// Switch to Meta tab.
	updated.activeTab = updated.tabIndexFor(TabMeta)
	if updated.ActiveTab() != TabMeta {
		t.Fatalf("active tab = %v, want TabMeta", updated.ActiveTab())
	}

	out := updated.View()
	if !strings.Contains(out, "open") {
		t.Errorf("View on Meta tab should contain status 'open', got:\n%s", out)
	}
	if !strings.Contains(out, "pr-review") {
		t.Errorf("View on Meta tab should contain source 'pr-review', got:\n%s", out)
	}
	if !strings.Contains(out, "anticorrelator/lore#42") {
		t.Errorf("View on Meta tab should contain attachment ref, got:\n%s", out)
	}
}

// --- DetailModel accessor tests ---

func TestDetailModelSelectedCountNilReviewCards(t *testing.T) {
	m := NewDetailModel("")
	if m.SelectedCount() != 0 {
		t.Errorf("SelectedCount on unloaded model = %d, want 0", m.SelectedCount())
	}
}

func TestDetailModelSelectedCountWithComments(t *testing.T) {
	m := NewDetailModel("")
	m.width = 80
	m.height = 40
	id := "sel-count"
	m.SetID(id)

	detail := &FollowUpDetail{
		ID:     id,
		Title:  "Sel Count",
		Status: "open",
		Source: "test",
		Attachments:      []Attachment{},
		SuggestedActions: []SuggestedAction{},
		ProposedComments: &ProposedReview{
			PR: 1, Owner: "o", Repo: "r", HeadSHA: "sha",
			Comments: []ProposedComment{
				{ID: "c1", Path: "a.go", Line: 1, Body: "A.", Severity: "high", Selected: true},
				{ID: "c2", Path: "b.go", Line: 2, Body: "B.", Severity: "low", Selected: false},
			},
		},
	}

	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})
	if updated.SelectedCount() != 1 {
		t.Errorf("SelectedCount = %d, want 1", updated.SelectedCount())
	}
}

// --- ReviewEvent persistence tests ---

func TestLoadFollowUpDetailPreservesReviewEvent(t *testing.T) {
	knowledgeDir := t.TempDir()
	id := "review-event-sidecar"
	itemDir := filepath.Join(knowledgeDir, "_followups", id)
	os.MkdirAll(itemDir, 0755)

	meta := `{"id":"review-event-sidecar","title":"Review Event","status":"open","severity":"high","source":"pr-review","attachments":[],"suggested_actions":[],"created":"2026-03-01T00:00:00Z","updated":"2026-03-01T00:00:00Z"}`
	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(meta), 0644)

	sidecar := `{
		"pr": 7,
		"owner": "anticorrelator",
		"repo": "lore",
		"head_sha": "sha1",
		"review_event": "APPROVE",
		"comments": [
			{"id":"c1","path":"main.go","line":1,"body":"LGTM.","selected":true,"severity":"low","lenses":[],"confidence":0.9}
		]
	}`
	os.WriteFile(filepath.Join(itemDir, "proposed-comments.json"), []byte(sidecar), 0644)

	detail, err := LoadFollowUpDetail(knowledgeDir, id)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if detail.ProposedComments == nil {
		t.Fatal("ProposedComments should be non-nil")
	}
	if detail.ProposedComments.ReviewEvent != "APPROVE" {
		t.Errorf("ReviewEvent = %q, want %q", detail.ProposedComments.ReviewEvent, "APPROVE")
	}
}

func TestDetailModelReviewEventNilReviewCards(t *testing.T) {
	m := NewDetailModel("")
	// reviewCards is nil (no sidecar loaded) — ReviewEvent() must return "COMMENT".
	if m.ReviewEvent() != "COMMENT" {
		t.Errorf("ReviewEvent() = %q, want %q when reviewCards is nil", m.ReviewEvent(), "COMMENT")
	}
}

func TestDetailModelReviewEventRoundTrip(t *testing.T) {
	knowledgeDir := t.TempDir()
	id := "review-event-roundtrip"
	itemDir := filepath.Join(knowledgeDir, "_followups", id)
	os.MkdirAll(itemDir, 0755)

	meta := `{"id":"review-event-roundtrip","title":"Round Trip","status":"open","severity":"high","source":"pr-review","attachments":[],"suggested_actions":[],"created":"2026-03-01T00:00:00Z","updated":"2026-03-01T00:00:00Z"}`
	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(meta), 0644)

	// Write initial sidecar with ReviewEvent="APPROVE".
	review := &ProposedReview{
		PR:          99,
		Owner:       "anticorrelator",
		Repo:        "lore",
		HeadSHA:     "abc",
		ReviewEvent: "APPROVE",
		Comments: []ProposedComment{
			{ID: "c1", Path: "x.go", Line: 5, Body: "Nice.", Severity: "low", Selected: true},
		},
	}
	cmd := WriteSidecarCmd(knowledgeDir, id, review)
	msg := cmd()
	if wsm, ok := msg.(WriteSidecarMsg); !ok || wsm.Err != nil {
		t.Fatalf("WriteSidecarCmd failed: %v", msg)
	}

	// Reload and verify ReviewEvent is preserved.
	detail, err := LoadFollowUpDetail(knowledgeDir, id)
	if err != nil {
		t.Fatalf("unexpected reload error: %v", err)
	}
	if detail.ProposedComments == nil {
		t.Fatal("ProposedComments should be non-nil after reload")
	}
	if detail.ProposedComments.ReviewEvent != "APPROVE" {
		t.Errorf("ReviewEvent after round-trip = %q, want %q", detail.ProposedComments.ReviewEvent, "APPROVE")
	}
}

func TestDetailModelHasPRMetadataReturnsFalseWhenNil(t *testing.T) {
	m := NewDetailModel("")
	if m.HasPRMetadata() {
		t.Error("HasPRMetadata should be false when no detail loaded")
	}
}

func TestDetailModelHasPRMetadataReturnsFalseWithIncompleteMetadata(t *testing.T) {
	m := NewDetailModel("")
	m.width = 80
	m.height = 40
	id := "no-meta"
	m.SetID(id)

	// Missing PR number → incomplete metadata.
	detail := &FollowUpDetail{
		ID:     id,
		Title:  "No Meta",
		Status: "open",
		Source: "test",
		Attachments:      []Attachment{},
		SuggestedActions: []SuggestedAction{},
		ProposedComments: &ProposedReview{
			PR: 0, Owner: "o", Repo: "r", HeadSHA: "sha",
			Comments: []ProposedComment{{ID: "c1", Path: "a.go", Line: 1, Body: "A.", Severity: "low"}},
		},
	}
	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})
	if updated.HasPRMetadata() {
		t.Error("HasPRMetadata should be false when PR=0")
	}
}

func TestDetailModelHasPRMetadataReturnsTrueWithCompleteMetadata(t *testing.T) {
	m := NewDetailModel("")
	m.width = 80
	m.height = 40
	id := "has-meta"
	m.SetID(id)

	detail := &FollowUpDetail{
		ID:     id,
		Title:  "Has Meta",
		Status: "open",
		Source: "test",
		Attachments:      []Attachment{},
		SuggestedActions: []SuggestedAction{},
		ProposedComments: &ProposedReview{
			PR: 42, Owner: "anticorrelator", Repo: "lore", HeadSHA: "abc123",
			Comments: []ProposedComment{{ID: "c1", Path: "a.go", Line: 1, Body: "A.", Severity: "high"}},
		},
	}
	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})
	if !updated.HasPRMetadata() {
		t.Error("HasPRMetadata should be true with complete PR metadata")
	}
}

func TestDetailModelPRNumberReturnsCorrectValue(t *testing.T) {
	m := NewDetailModel("")
	m.width = 80
	m.height = 40
	id := "pr-number"
	m.SetID(id)

	detail := &FollowUpDetail{
		ID:     id,
		Title:  "PR Num",
		Status: "open",
		Source: "test",
		Attachments:      []Attachment{},
		SuggestedActions: []SuggestedAction{},
		ProposedComments: &ProposedReview{
			PR: 99, Owner: "o", Repo: "r", HeadSHA: "sha",
			Comments: []ProposedComment{{ID: "c1", Path: "a.go", Line: 1, Body: "A.", Severity: "low"}},
		},
	}
	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})
	if updated.PRNumber() != 99 {
		t.Errorf("PRNumber = %d, want 99", updated.PRNumber())
	}
}

// --- D19 sidecar rule tests ---

func TestLoadFollowUpDetailD19WrapperWithValidMetaZeroCommentsPreserved(t *testing.T) {
	// D19 Case 1: wrapper with valid PR metadata and zero comments → keep ProposedComments.
	knowledgeDir := t.TempDir()
	id := "d19-case1"
	itemDir := filepath.Join(knowledgeDir, "_followups", id)
	os.MkdirAll(itemDir, 0755)

	meta := `{"id":"d19-case1","title":"D19 Case 1","status":"open","source":"test","attachments":[],"suggested_actions":[],"created":"2026-03-01T00:00:00Z","updated":"2026-03-01T00:00:00Z"}`
	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(meta), 0644)

	sidecar := `{"pr":42,"owner":"anticorrelator","repo":"lore","head_sha":"abc123","comments":[]}`
	os.WriteFile(filepath.Join(itemDir, "proposed-comments.json"), []byte(sidecar), 0644)

	detail, err := LoadFollowUpDetail(knowledgeDir, id)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if detail.ProposedComments == nil {
		t.Fatal("D19 Case 1: ProposedComments should be preserved (valid metadata, zero comments)")
	}
	if detail.ProposedComments.PR != 42 {
		t.Errorf("PR = %d, want 42", detail.ProposedComments.PR)
	}
}

func TestLoadFollowUpDetailD19WrapperWithoutValidMetaZeroCommentsDropped(t *testing.T) {
	// D19 Case 2: wrapper without valid metadata and zero comments → nil.
	knowledgeDir := t.TempDir()
	id := "d19-case2"
	itemDir := filepath.Join(knowledgeDir, "_followups", id)
	os.MkdirAll(itemDir, 0755)

	meta := `{"id":"d19-case2","title":"D19 Case 2","status":"open","source":"test","attachments":[],"suggested_actions":[],"created":"2026-03-01T00:00:00Z","updated":"2026-03-01T00:00:00Z"}`
	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(meta), 0644)

	// No owner/repo/PR/HeadSHA → not valid metadata.
	sidecar := `{"pr":0,"owner":"","repo":"","head_sha":"","comments":[]}`
	os.WriteFile(filepath.Join(itemDir, "proposed-comments.json"), []byte(sidecar), 0644)

	detail, err := LoadFollowUpDetail(knowledgeDir, id)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if detail.ProposedComments != nil {
		t.Errorf("D19 Case 2: ProposedComments should be nil (no metadata, zero comments), got %+v", detail.ProposedComments)
	}
}

func TestLoadFollowUpDetailD19BareArrayZeroCommentsDropped(t *testing.T) {
	// D19 Case 3: bare array with zero comments → nil.
	knowledgeDir := t.TempDir()
	id := "d19-case3"
	itemDir := filepath.Join(knowledgeDir, "_followups", id)
	os.MkdirAll(itemDir, 0755)

	meta := `{"id":"d19-case3","title":"D19 Case 3","status":"open","source":"test","attachments":[],"suggested_actions":[],"created":"2026-03-01T00:00:00Z","updated":"2026-03-01T00:00:00Z"}`
	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(meta), 0644)

	// Empty bare array.
	sidecar := `[]`
	os.WriteFile(filepath.Join(itemDir, "proposed-comments.json"), []byte(sidecar), 0644)

	detail, err := LoadFollowUpDetail(knowledgeDir, id)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if detail.ProposedComments != nil {
		t.Errorf("D19 Case 3: ProposedComments should be nil (bare array, zero comments), got %+v", detail.ProposedComments)
	}
}

func TestLoadFollowUpDetailAuthorField(t *testing.T) {
	knowledgeDir := t.TempDir()
	id := "author-test"
	itemDir := filepath.Join(knowledgeDir, "_followups", id)
	os.MkdirAll(itemDir, 0755)

	meta := `{"id":"author-test","title":"Author Test","status":"open","author":"alice","source":"test","attachments":[],"suggested_actions":[],"created":"2026-03-01T00:00:00Z","updated":"2026-03-01T00:00:00Z"}`
	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(meta), 0644)

	detail, err := LoadFollowUpDetail(knowledgeDir, id)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if detail.Author != "alice" {
		t.Errorf("Author = %q, want %q", detail.Author, "alice")
	}
}

func TestLoadFollowUpDetailAuthorFieldMissing(t *testing.T) {
	// Backward compatibility: _meta.json without "author" field should result in Author == "".
	knowledgeDir := t.TempDir()
	id := "no-author-test"
	itemDir := filepath.Join(knowledgeDir, "_followups", id)
	os.MkdirAll(itemDir, 0755)

	meta := `{"id":"no-author-test","title":"No Author Test","status":"open","source":"test","attachments":[],"suggested_actions":[],"created":"2026-03-01T00:00:00Z","updated":"2026-03-01T00:00:00Z"}`
	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(meta), 0644)

	detail, err := LoadFollowUpDetail(knowledgeDir, id)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if detail.Author != "" {
		t.Errorf("Author = %q, want empty string for meta without author field", detail.Author)
	}
}

// --- LensFindings integration tests ---

// testDetailWithLensFindings returns a FollowUpDetail with both proposed comments and lens findings.
func testDetailWithLensFindings() *FollowUpDetail {
	return &FollowUpDetail{
		ID:               "lens-test",
		Title:            "Lens Findings Test",
		Status:           "open",
		Source:           "review",
		FindingContent:   "# Finding\n\nSome content.",
		Attachments:      []Attachment{},
		SuggestedActions: []SuggestedAction{},
		ProposedComments: &ProposedReview{
			PR: 42, Owner: "test", Repo: "repo", HeadSHA: "abc",
			Comments: []ProposedComment{
				{ID: "c1", Path: "a.go", Line: 1, Body: "Fix.", Selected: true, Severity: "high"},
			},
		},
		LensFindings: &LensReview{
			PR: 42, WorkItem: "wi",
			Findings: []LensFinding{
				{Severity: "blocking", File: "b.go", Line: 5, Body: "Critical.", Lens: "security", Disposition: "action"},
			},
		},
	}
}

func TestDetailModelTabVisibilityWithLensFindings(t *testing.T) {
	m := NewDetailModel("/tmp/test")
	m.width = 80
	m.height = 40

	id := "lens-test"
	m.SetID(id)
	detail := testDetailWithLensFindings()

	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})

	// Four tabs: Meta, Finding, Findings, Comments.
	if len(updated.tabs) != 4 {
		t.Errorf("tabs len = %d, want 4 (Meta+Finding+Findings+Comments)", len(updated.tabs))
	}

	// Verify tab order.
	wantOrder := []Tab{TabMeta, TabFinding, TabTriage, TabComments}
	for i, want := range wantOrder {
		if i < len(updated.tabs) && updated.tabs[i].id != want {
			t.Errorf("tab[%d].id = %v, want %v", i, updated.tabs[i].id, want)
		}
	}

	if updated.lensFindings == nil {
		t.Fatal("lensFindings should be initialized")
	}

	out := updated.View()
	if !strings.Contains(out, "Triage") {
		t.Error("View should contain Triage tab label")
	}
}

func TestDetailModelTabVisibilityWithoutLensFindings(t *testing.T) {
	m := NewDetailModel("/tmp/test")
	m.width = 80
	m.height = 40

	id := "no-lens"
	m.SetID(id)
	detail := &FollowUpDetail{
		ID:               id,
		Title:            "No Lens",
		Status:           "open",
		Source:           "review",
		FindingContent:   "# Finding",
		Attachments:      []Attachment{},
		SuggestedActions: []SuggestedAction{},
		ProposedComments: &ProposedReview{
			PR: 10, Owner: "test", Repo: "repo", HeadSHA: "def",
			Comments: []ProposedComment{
				{ID: "c1", Path: "a.go", Line: 1, Body: "Fix.", Severity: "low"},
			},
		},
	}

	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})

	// Three tabs: Meta, Finding, Comments — no Findings.
	if len(updated.tabs) != 3 {
		t.Errorf("tabs len = %d, want 3 (Meta+Finding+Comments)", len(updated.tabs))
	}
	for _, tab := range updated.tabs {
		if tab.id == TabTriage {
			t.Error("TabTriage should not appear when LensFindings is nil")
		}
	}
	if updated.lensFindings != nil {
		t.Error("lensFindings should be nil when no sidecar")
	}
}

func TestDetailModelDefaultTabTriagePreferred(t *testing.T) {
	m := NewDetailModel("/tmp/test")
	m.width = 80
	m.height = 40

	id := "default-tab"
	m.SetID(id)
	detail := testDetailWithLensFindings()

	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})

	// Default tab should be TabTriage when lens findings are present.
	if updated.ActiveTab() != TabTriage {
		t.Errorf("default tab = %v, want TabTriage", updated.ActiveTab())
	}
}

func TestDetailModelDefaultTabCommentsWhenNoFindings(t *testing.T) {
	m := NewDetailModel("/tmp/test")
	m.width = 80
	m.height = 40

	id := "comments-default"
	m.SetID(id)
	detail := &FollowUpDetail{
		ID: id, Title: "Comments Default", Status: "open", Source: "review",
		FindingContent:   "# Finding",
		Attachments:      []Attachment{},
		SuggestedActions: []SuggestedAction{},
		ProposedComments: &ProposedReview{
			PR: 10, Owner: "test", Repo: "repo", HeadSHA: "def",
			Comments: []ProposedComment{
				{ID: "c1", Path: "a.go", Line: 1, Body: "Fix.", Severity: "low"},
			},
		},
	}

	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})

	if updated.ActiveTab() != TabComments {
		t.Errorf("default tab = %v, want TabComments when no lens findings", updated.ActiveTab())
	}
}

func TestDetailModelKeyDelegationToLensFindings(t *testing.T) {
	m := NewDetailModel("/tmp/test")
	m.width = 80
	m.height = 40

	id := "key-delegation"
	m.SetID(id)
	review := &LensReview{
		PR: 1, WorkItem: "wi",
		Findings: []LensFinding{
			{Severity: "blocking", File: "a.go", Line: 1, Body: "First.", Lens: "x", Disposition: "action"},
			{Severity: "suggestion", File: "b.go", Line: 2, Body: "Second.", Lens: "y", Disposition: "open"},
		},
	}
	detail := &FollowUpDetail{
		ID: id, Title: "Key Delegation", Status: "open", Source: "review",
		FindingContent:   "# Finding",
		Attachments:      []Attachment{},
		SuggestedActions: []SuggestedAction{},
		LensFindings:     review,
	}

	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})

	// Should default to TabTriage.
	if updated.ActiveTab() != TabTriage {
		t.Fatalf("active tab = %v, want TabTriage", updated.ActiveTab())
	}

	// j should be delegated to LensFindingsModel (cursor moves down).
	updated, _ = updated.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	if updated.lensFindings.cursor != 1 {
		t.Errorf("after j: lensFindings cursor = %d, want 1", updated.lensFindings.cursor)
	}

	// f should cycle disposition filter.
	updated, _ = updated.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'f'}})
	if updated.lensFindings.filter != DispFilterAction {
		t.Errorf("after f: lensFindings filter = %d, want DispFilterAction", updated.lensFindings.filter)
	}
}

func TestDetailModelTabPreservationAcrossReload(t *testing.T) {
	m := NewDetailModel("/tmp/test")
	m.width = 80
	m.height = 40

	id := "tab-preserve"
	m.SetID(id)
	detail := testDetailWithLensFindings()

	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})

	// Switch to Comments tab.
	for updated.ActiveTab() != TabComments {
		updated, _ = updated.Update(tea.KeyMsg{Type: tea.KeyTab})
	}
	if updated.ActiveTab() != TabComments {
		t.Fatalf("active tab = %v, want TabComments", updated.ActiveTab())
	}

	// Preserve and reload.
	updated.PreserveTab()

	// Simulate reload with same detail.
	updated, _ = updated.Update(DetailLoadedMsg{ID: id, Detail: detail})

	if updated.ActiveTab() != TabComments {
		t.Errorf("after reload: active tab = %v, want TabComments (preserved)", updated.ActiveTab())
	}
}

func TestDetailModelTabPreservationByIDNotIndex(t *testing.T) {
	m := NewDetailModel("/tmp/test")
	m.width = 80
	m.height = 40

	id := "tab-id-preserve"
	m.SetID(id)
	detail := testDetailWithLensFindings()

	updated, _ := m.Update(DetailLoadedMsg{ID: id, Detail: detail})

	// Navigate to TabTriage.
	for updated.ActiveTab() != TabTriage {
		updated, _ = updated.Update(tea.KeyMsg{Type: tea.KeyTab})
	}
	updated.PreserveTab()

	// Reload with detail that no longer has ProposedComments — Findings tab shifts index.
	detailNoComments := &FollowUpDetail{
		ID: id, Title: "No Comments", Status: "open", Source: "review",
		FindingContent:   "# Finding",
		Attachments:      []Attachment{},
		SuggestedActions: []SuggestedAction{},
		LensFindings:     detail.LensFindings,
	}
	updated, _ = updated.Update(DetailLoadedMsg{ID: id, Detail: detailNoComments})

	// Tab should still be TabTriage despite index change.
	if updated.ActiveTab() != TabTriage {
		t.Errorf("after reload with fewer tabs: active tab = %v, want TabTriage (preserved by ID)", updated.ActiveTab())
	}
}

func TestLoadFollowUpDetailLensFindingsSidecar(t *testing.T) {
	knowledgeDir := t.TempDir()
	id := "with-lens"
	itemDir := filepath.Join(knowledgeDir, "_followups", id)
	os.MkdirAll(itemDir, 0755)

	meta := `{"id":"with-lens","title":"With Lens","status":"open","source":"review","attachments":[],"suggested_actions":[],"created":"2026-03-01T00:00:00Z","updated":"2026-03-01T00:00:00Z"}`
	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(meta), 0644)

	lensJSON := `{"pr":42,"work_item":"wi","findings":[{"severity":"blocking","title":"Test","file":"a.go","line":1,"body":"Bug.","lens":"correctness","disposition":"action","rationale":""}]}`
	os.WriteFile(filepath.Join(itemDir, "lens-findings.json"), []byte(lensJSON), 0644)

	detail, err := LoadFollowUpDetail(knowledgeDir, id)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if detail.LensFindings == nil {
		t.Fatal("LensFindings should be populated from sidecar")
	}
	if len(detail.LensFindings.Findings) != 1 {
		t.Errorf("findings len = %d, want 1", len(detail.LensFindings.Findings))
	}
}

func TestLoadFollowUpDetailLensFindingsEmptyFindings(t *testing.T) {
	knowledgeDir := t.TempDir()
	id := "empty-lens"
	itemDir := filepath.Join(knowledgeDir, "_followups", id)
	os.MkdirAll(itemDir, 0755)

	meta := `{"id":"empty-lens","title":"Empty Lens","status":"open","source":"test","attachments":[],"suggested_actions":[],"created":"2026-03-01T00:00:00Z","updated":"2026-03-01T00:00:00Z"}`
	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(meta), 0644)

	// Empty findings array → nil (no tab).
	os.WriteFile(filepath.Join(itemDir, "lens-findings.json"), []byte(`{"pr":1,"work_item":"","findings":[]}`), 0644)

	detail, err := LoadFollowUpDetail(knowledgeDir, id)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if detail.LensFindings != nil {
		t.Error("LensFindings should be nil for empty findings array")
	}
}

func TestLoadFollowUpDetailLensFindingsMalformed(t *testing.T) {
	knowledgeDir := t.TempDir()
	id := "bad-lens"
	itemDir := filepath.Join(knowledgeDir, "_followups", id)
	os.MkdirAll(itemDir, 0755)

	meta := `{"id":"bad-lens","title":"Bad Lens","status":"open","source":"test","attachments":[],"suggested_actions":[],"created":"2026-03-01T00:00:00Z","updated":"2026-03-01T00:00:00Z"}`
	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(meta), 0644)

	// Malformed JSON → nil (no tab).
	os.WriteFile(filepath.Join(itemDir, "lens-findings.json"), []byte("not valid json{{{"), 0644)

	detail, err := LoadFollowUpDetail(knowledgeDir, id)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if detail.LensFindings != nil {
		t.Error("LensFindings should be nil for malformed JSON")
	}
}

// --- DetailModel IsEditing and tab suppression tests ---

func testDetailWithReviewCards(t *testing.T) DetailModel {
	t.Helper()
	review := &ProposedReview{
		PR:      1,
		Owner:   "o",
		Repo:    "r",
		HeadSHA: "abc",
		Comments: []ProposedComment{
			{ID: "c1", Path: "f.go", Line: 1, Body: "body1", Selected: false, Severity: "medium"},
			{ID: "c2", Path: "g.go", Line: 2, Body: "body2", Selected: false, Severity: "low"},
		},
	}
	m := NewDetailModel("/tmp")
	m.width = 80
	m.height = 40
	rc := NewReviewCardsModel("/tmp", "test", review)
	rc, _ = rc.Update(tea.WindowSizeMsg{Width: 80, Height: 40})
	m.reviewCards = &rc
	m.tabs = m.buildTabs()
	// Set active tab to TabComments.
	m.activeTab = m.tabIndexFor(TabComments)
	return m
}

func TestDetailModelIsEditingFalseWhenNoReviewCards(t *testing.T) {
	m := NewDetailModel("/tmp")
	if m.IsEditing() {
		t.Error("IsEditing should be false when reviewCards is nil")
	}
}

func TestDetailModelIsEditingDelegatesToReviewCards(t *testing.T) {
	m := testDetailWithReviewCards(t)

	if m.IsEditing() {
		t.Fatal("IsEditing should be false before editing starts")
	}

	// Enter edit mode via 'e' key forwarded through the detail model.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'e'}})

	if !m.IsEditing() {
		t.Error("IsEditing should be true after 'e' on TabComments")
	}
}

func TestDetailModelKeyEventsForwardedToReviewCardsOnTabComments(t *testing.T) {
	m := testDetailWithReviewCards(t)
	// cursor is at 0 in the reviewCards; press 'j' to advance.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	if m.reviewCards.cursor != 1 {
		t.Errorf("j forwarded to reviewCards: cursor = %d, want 1", m.reviewCards.cursor)
	}
}

func TestDetailModelTabSuppressedDuringEditing(t *testing.T) {
	m := testDetailWithReviewCards(t)
	tabBefore := m.activeTab

	// Enter edit mode.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'e'}})
	if !m.IsEditing() {
		t.Fatal("must be editing for this test to be meaningful")
	}

	// Tab should not cycle tabs while editing.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyTab})
	if m.activeTab != tabBefore {
		t.Errorf("tab during editing changed activeTab from %d to %d", tabBefore, m.activeTab)
	}

	// Shift+tab should also not cycle.
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyShiftTab})
	if m.activeTab != tabBefore {
		t.Errorf("shift+tab during editing changed activeTab from %d to %d", tabBefore, m.activeTab)
	}
}
