package followup

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
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
		Severity:         "high",
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
	if updated.Severity() != "high" {
		t.Errorf("Severity() = %q, want %q", updated.Severity(), "high")
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
