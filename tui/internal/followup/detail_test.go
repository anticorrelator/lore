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
		t.Errorf("active tab = %v, want TabComments (default when sidecar present)", updated.ActiveTab())
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

	// Should start on TabComments (index 2) since sidecar is present.
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
