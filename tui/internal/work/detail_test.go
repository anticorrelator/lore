package work

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestWorkItemDetailJSONParsing(t *testing.T) {
	raw := `{
		"slug": "test-item",
		"title": "Test Item",
		"status": "active",
		"branches": ["main", "feature/test"],
		"tags": ["tui", "go"],
		"issue": "",
		"pr": "42",
		"created": "2026-02-13T22:23:14Z",
		"updated": "2026-02-24T04:55:25Z",
		"plan_content": "# Test Plan\n\nSome content here.",
		"notes_content": null,
		"has_execution_log": true,
		"has_tasks": false
	}`

	var detail WorkItemDetail
	if err := json.Unmarshal([]byte(raw), &detail); err != nil {
		t.Fatalf("Unmarshal failed: %v", err)
	}

	if detail.Slug != "test-item" {
		t.Errorf("Slug = %q, want %q", detail.Slug, "test-item")
	}
	if detail.Title != "Test Item" {
		t.Errorf("Title = %q, want %q", detail.Title, "Test Item")
	}
	if detail.Status != "active" {
		t.Errorf("Status = %q, want %q", detail.Status, "active")
	}
	if len(detail.Branches) != 2 {
		t.Errorf("Branches len = %d, want 2", len(detail.Branches))
	}
	if len(detail.Tags) != 2 {
		t.Errorf("Tags len = %d, want 2", len(detail.Tags))
	}
	if detail.PR != "42" {
		t.Errorf("PR = %q, want %q", detail.PR, "42")
	}
	if detail.PlanContent == nil {
		t.Fatal("PlanContent should not be nil")
	}
	if *detail.PlanContent != "# Test Plan\n\nSome content here." {
		t.Errorf("PlanContent = %q", *detail.PlanContent)
	}
	if detail.NotesContent != nil {
		t.Errorf("NotesContent should be nil, got %q", *detail.NotesContent)
	}
	if !detail.HasExecutionLog {
		t.Error("HasExecutionLog should be true")
	}
	if detail.HasTasks {
		t.Error("HasTasks should be false")
	}
}

func TestWorkItemDetailNullableFields(t *testing.T) {
	// Both plan_content and notes_content can be null or strings
	cases := []struct {
		name      string
		json      string
		wantPlan  bool
		wantNotes bool
	}{
		{
			name:      "both null",
			json:      `{"slug":"a","plan_content":null,"notes_content":null}`,
			wantPlan:  false,
			wantNotes: false,
		},
		{
			name:      "both present",
			json:      `{"slug":"b","plan_content":"plan","notes_content":"notes"}`,
			wantPlan:  true,
			wantNotes: true,
		},
		{
			name:      "plan null notes present",
			json:      `{"slug":"c","plan_content":null,"notes_content":"notes"}`,
			wantPlan:  false,
			wantNotes: true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var d WorkItemDetail
			if err := json.Unmarshal([]byte(tc.json), &d); err != nil {
				t.Fatalf("Unmarshal: %v", err)
			}
			if (d.PlanContent != nil) != tc.wantPlan {
				t.Errorf("PlanContent present = %v, want %v", d.PlanContent != nil, tc.wantPlan)
			}
			if (d.NotesContent != nil) != tc.wantNotes {
				t.Errorf("NotesContent present = %v, want %v", d.NotesContent != nil, tc.wantNotes)
			}
		})
	}
}

func TestLoadWorkItemDetailDirect(t *testing.T) {
	workDir := t.TempDir()
	slug := "test-direct"
	itemDir := filepath.Join(workDir, slug)
	if err := os.MkdirAll(itemDir, 0755); err != nil {
		t.Fatal(err)
	}

	meta := `{
		"slug": "test-direct",
		"title": "Direct Load Test",
		"status": "active",
		"branches": ["main", "feature/x"],
		"tags": ["test"],
		"issue": "https://github.com/org/repo/issues/1",
		"pr": "",
		"created": "2026-02-20T10:00:00Z",
		"updated": "2026-02-24T12:00:00Z"
	}`
	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(meta), 0644)
	os.WriteFile(filepath.Join(itemDir, "plan.md"), []byte("# Plan\n\nDo the thing."), 0644)
	os.WriteFile(filepath.Join(itemDir, "notes.md"), []byte("## 2026-02-24\nSome notes."), 0644)
	os.WriteFile(filepath.Join(itemDir, "tasks.json"), []byte("[]"), 0644)
	// No execution-log.md — should result in HasExecutionLog=false

	detail, err := loadWorkItemDetailDirect(workDir, slug)
	if err != nil {
		t.Fatalf("loadWorkItemDetailDirect: %v", err)
	}

	if detail.Slug != "test-direct" {
		t.Errorf("Slug = %q, want %q", detail.Slug, "test-direct")
	}
	if detail.Title != "Direct Load Test" {
		t.Errorf("Title = %q, want %q", detail.Title, "Direct Load Test")
	}
	if detail.Status != "active" {
		t.Errorf("Status = %q, want %q", detail.Status, "active")
	}
	if len(detail.Branches) != 2 || detail.Branches[0] != "main" {
		t.Errorf("Branches = %v, want [main feature/x]", detail.Branches)
	}
	if len(detail.Tags) != 1 || detail.Tags[0] != "test" {
		t.Errorf("Tags = %v, want [test]", detail.Tags)
	}
	if detail.Issue != "https://github.com/org/repo/issues/1" {
		t.Errorf("Issue = %q", detail.Issue)
	}
	if detail.PR != "" {
		t.Errorf("PR = %q, want empty string", detail.PR)
	}
	if detail.PlanContent == nil {
		t.Fatal("PlanContent should not be nil")
	}
	if *detail.PlanContent != "# Plan\n\nDo the thing." {
		t.Errorf("PlanContent = %q", *detail.PlanContent)
	}
	if detail.NotesContent == nil {
		t.Fatal("NotesContent should not be nil")
	}
	if *detail.NotesContent != "## 2026-02-24\nSome notes." {
		t.Errorf("NotesContent = %q", *detail.NotesContent)
	}
	if !detail.HasTasks {
		t.Error("HasTasks should be true")
	}
	if detail.HasExecutionLog {
		t.Error("HasExecutionLog should be false")
	}
}

func TestLoadWorkItemDetailDirectMinimal(t *testing.T) {
	workDir := t.TempDir()
	slug := "minimal"
	itemDir := filepath.Join(workDir, slug)
	os.MkdirAll(itemDir, 0755)

	// Minimal _meta.json — no optional files
	meta := `{"slug":"minimal","title":"Minimal","status":"active","created":"2026-02-24T00:00:00Z","updated":"2026-02-24T00:00:00Z"}`
	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(meta), 0644)

	detail, err := loadWorkItemDetailDirect(workDir, slug)
	if err != nil {
		t.Fatalf("loadWorkItemDetailDirect: %v", err)
	}

	if detail.PlanContent != nil {
		t.Error("PlanContent should be nil when plan.md is absent")
	}
	if detail.NotesContent != nil {
		t.Error("NotesContent should be nil when notes.md is absent")
	}
	if detail.HasTasks {
		t.Error("HasTasks should be false when tasks.json is absent")
	}
	if detail.HasExecutionLog {
		t.Error("HasExecutionLog should be false when execution-log.md is absent")
	}
	// Branches and Tags should be non-nil empty slices
	if detail.Branches == nil {
		t.Error("Branches should be non-nil (empty slice)")
	}
	if detail.Tags == nil {
		t.Error("Tags should be non-nil (empty slice)")
	}
}

func TestLoadWorkItemDetailDirectExtraFiles(t *testing.T) {
	workDir := t.TempDir()
	slug := "extra-files"
	itemDir := filepath.Join(workDir, slug)
	os.MkdirAll(itemDir, 0755)

	meta := `{"slug":"extra-files","title":"Extra Files","status":"active","created":"2026-02-26T00:00:00Z","updated":"2026-02-26T00:00:00Z"}`
	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(meta), 0644)
	os.WriteFile(filepath.Join(itemDir, "plan.md"), []byte("# Plan"), 0644)
	os.WriteFile(filepath.Join(itemDir, "notes.md"), []byte("## 2026-02-26\nNotes."), 0644)
	os.WriteFile(filepath.Join(itemDir, "research.md"), []byte("# Research\n\nSome research."), 0644)
	os.WriteFile(filepath.Join(itemDir, "context.md"), []byte("# Context\n\nBackground."), 0644)
	// Internal files and non-.md files should be excluded.
	os.WriteFile(filepath.Join(itemDir, "_internal.md"), []byte("internal"), 0644)
	os.WriteFile(filepath.Join(itemDir, "data.json"), []byte("{}"), 0644)

	detail, err := loadWorkItemDetailDirect(workDir, slug)
	if err != nil {
		t.Fatalf("loadWorkItemDetailDirect: %v", err)
	}

	if len(detail.ExtraFiles) != 2 {
		t.Fatalf("ExtraFiles len = %d, want 2", len(detail.ExtraFiles))
	}
	// os.ReadDir is lexicographic: context.md before research.md
	if detail.ExtraFiles[0].Name != "context" {
		t.Errorf("ExtraFiles[0].Name = %q, want %q", detail.ExtraFiles[0].Name, "context")
	}
	if detail.ExtraFiles[1].Name != "research" {
		t.Errorf("ExtraFiles[1].Name = %q, want %q", detail.ExtraFiles[1].Name, "research")
	}
	if detail.ExtraFiles[1].Content != "# Research\n\nSome research." {
		t.Errorf("ExtraFiles[1].Content = %q", detail.ExtraFiles[1].Content)
	}
}

func TestLoadWorkItemDetailDirectMalformedMeta(t *testing.T) {
	workDir := t.TempDir()
	slug := "bad-meta"
	itemDir := filepath.Join(workDir, slug)
	os.MkdirAll(itemDir, 0755)

	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte("not valid json{{{"), 0644)

	detail, err := loadWorkItemDetailDirect(workDir, slug)
	if err != nil {
		t.Fatalf("malformed meta should not return error, got: %v", err)
	}
	if !detail.Malformed {
		t.Error("Malformed should be true")
	}
	if detail.Slug != slug {
		t.Errorf("Slug = %q, want %q", detail.Slug, slug)
	}
	if detail.Title != "[malformed] "+slug {
		t.Errorf("Title = %q, want %q", detail.Title, "[malformed] "+slug)
	}
	if detail.Branches == nil {
		t.Error("Branches should be non-nil (empty slice)")
	}
	if detail.Tags == nil {
		t.Error("Tags should be non-nil (empty slice)")
	}
	if detail.RelatedWork == nil {
		t.Error("RelatedWork should be non-nil (empty slice)")
	}
}

func TestLoadWorkItemDetailDirectMalformedMetaReadsSiblings(t *testing.T) {
	workDir := t.TempDir()
	slug := "bad-meta-siblings"
	itemDir := filepath.Join(workDir, slug)
	os.MkdirAll(itemDir, 0755)

	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte("{corrupt}"), 0644)
	os.WriteFile(filepath.Join(itemDir, "plan.md"), []byte("# Plan\n\nStill readable."), 0644)
	os.WriteFile(filepath.Join(itemDir, "notes.md"), []byte("## 2026-03-01\nSome notes."), 0644)
	os.WriteFile(filepath.Join(itemDir, "execution-log.md"), []byte("# Log\n\nEntry."), 0644)
	os.WriteFile(filepath.Join(itemDir, "research.md"), []byte("# Research\n\nData."), 0644)

	detail, err := loadWorkItemDetailDirect(workDir, slug)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !detail.Malformed {
		t.Error("Malformed should be true")
	}
	if detail.PlanContent == nil || *detail.PlanContent != "# Plan\n\nStill readable." {
		t.Errorf("PlanContent = %v, want plan content", detail.PlanContent)
	}
	if detail.NotesContent == nil || *detail.NotesContent != "## 2026-03-01\nSome notes." {
		t.Errorf("NotesContent = %v, want notes content", detail.NotesContent)
	}
	if !detail.HasExecutionLog {
		t.Error("HasExecutionLog should be true")
	}
	if detail.ExecLogContent == nil || *detail.ExecLogContent != "# Log\n\nEntry." {
		t.Errorf("ExecLogContent = %v, want log content", detail.ExecLogContent)
	}
	if len(detail.ExtraFiles) != 1 || detail.ExtraFiles[0].Name != "research" {
		t.Errorf("ExtraFiles = %v, want [{research ...}]", detail.ExtraFiles)
	}
}

func TestLoadWorkItemDetailDirectMissingMeta(t *testing.T) {
	workDir := t.TempDir()
	_, err := loadWorkItemDetailDirect(workDir, "nonexistent")
	if err == nil {
		t.Fatal("expected error for nonexistent work item")
	}
}

func TestLoadWorkItemDetailIntegration(t *testing.T) {
	// Integration test — requires knowledge store to be available
	out, err := os.ReadFile("/dev/null") // cheap check that os works
	_ = out
	if err != nil {
		t.Skip("os.ReadFile not available")
	}

	// Use lore resolve to find the work dir
	workDir := os.Getenv("LORE_WORK_DIR")
	if workDir == "" {
		t.Skip("LORE_WORK_DIR not set; skipping integration test")
	}

	detail, err := LoadWorkItemDetail(workDir, "lore-tui-application")
	if err != nil {
		t.Skipf("work item not found: %v", err)
	}

	if detail.Slug != "lore-tui-application" {
		t.Errorf("Slug = %q, want %q", detail.Slug, "lore-tui-application")
	}
	if detail.Title == "" {
		t.Error("Title should not be empty")
	}
	if detail.Status == "" {
		t.Error("Status should not be empty")
	}
}

// TestExtraFileRendersAsTab pins the zero-code bag-of-files delivery: any
// non-canonical .md in the work-item directory rides the generic ExtraFiles
// scan (no special-casing in loadWorkItemDetailDirect) and surfaces as its own
// titled detail tab.
func TestExtraFileRendersAsTab(t *testing.T) {
	workDir := t.TempDir()
	slug := "item-with-design"
	itemDir := filepath.Join(workDir, slug)
	os.MkdirAll(itemDir, 0755)

	meta := `{"slug":"item-with-design","title":"Item With Design","status":"active",` +
		`"created":"2026-07-01T00:00:00Z","updated":"2026-07-01T00:00:00Z"}`
	os.WriteFile(filepath.Join(itemDir, "_meta.json"), []byte(meta), 0644)
	os.WriteFile(filepath.Join(itemDir, "design-notes.md"), []byte("## Decisions & rationale\n\nx"), 0644)

	detail, err := loadWorkItemDetailDirect(workDir, slug)
	if err != nil {
		t.Fatalf("loadWorkItemDetailDirect: %v", err)
	}

	var extra *ExtraFile
	for i := range detail.ExtraFiles {
		if detail.ExtraFiles[i].Name == "design-notes" {
			extra = &detail.ExtraFiles[i]
		}
	}
	if extra == nil {
		t.Fatalf("design-notes.md should appear in ExtraFiles, got %+v", detail.ExtraFiles)
	}

	m := NewDetailModel(workDir, slug)
	m, _ = m.Update(DetailLoadedMsg{Slug: slug, Detail: detail})
	found := false
	for _, tab := range m.tabHost.Tabs() {
		if tab.Label == "Design Notes" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected a 'Design Notes' tab, got %+v", m.tabHost.Tabs())
	}
}

func evidenceFixture(t *testing.T) (string, string, string) {
	t.Helper()
	repo, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	data := t.TempDir()
	if err := os.Symlink(filepath.Join(repo, "scripts"), filepath.Join(data, "scripts")); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LORE_DATA_DIR", data)
	kdir := t.TempDir()
	item := filepath.Join(kdir, "_work", "fixture")
	if err := os.MkdirAll(filepath.Join(item, "worker-reports"), 0755); err != nil {
		t.Fatal(err)
	}
	write := func(name, body string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(item, name), []byte(body), 0644); err != nil {
			t.Fatal(err)
		}
	}
	write("_meta.json", `{"title":"Fixture","status":"active"}`)
	write("tasks.json", `{"tasks":[{"id":"task-1","subject":"Task","description":"Complete task body","blockedBy":["task-0"],"close_criteria":[{"id":"check"}]}]}`)
	write("worker-reports/report.md", "Report-id: report\nStatus: completed\nFull nested report body")
	write("execution-log.md", "## 2026-09-04 | source: worker\nLegacy execution body\n")
	identity := map[string]any{"head": strings.Repeat("a", 40), "digest": strings.Repeat("a", 64), "digest_version": "1", "worktree": filepath.Join(kdir, "removed-code")}
	if err := os.MkdirAll(filepath.Join(item, "results", "r1"), 0755); err != nil {
		t.Fatal(err)
	}
	write("results/r1/output.txt", "output")
	result, _ := json.Marshal(map[string]any{"execution_attempt_id": "exec-1", "revision_id": "aaaaaaaaaaaa", "unbound_reason": "fixture", "exit": 0, "signal": nil, "timed_out": false, "output_path": "results/r1/output.txt", "output_sha256": fmt.Sprintf("%x", sha256.Sum256([]byte("output"))), "schema_version": 1, "task_id": "task-1", "criterion_id": "check", "criterion_version": fmt.Sprintf("%x", sha256.Sum256([]byte(`{"id":"check"}`))), "result_id": "r1", "state": "pass", "source_start": identity, "source_end": identity})
	write("results.jsonl", string(result)+"\n")
	return kdir, item, repo
}

func TestCanonicalEvidenceAndDeletion(t *testing.T) {
	kdir, item, repo := evidenceFixture(t)
	load := func() *WorkItemDetail {
		t.Helper()
		d, err := LoadWorkItemDetail(filepath.Join(kdir, "_work"), "fixture")
		if err != nil {
			t.Fatal(err)
		}
		return d
	}
	detail := load()
	output, err := exec.Command("python3", "-B", filepath.Join(repo, "scripts", "work-evidence.py"), "--item-dir", item, "--knowledge-dir", kdir).Output()
	if err != nil {
		t.Fatal(err)
	}
	var fromCLI, fromGo any
	if err := json.Unmarshal(output, &fromCLI); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(detail.Evidence, &fromGo); err != nil {
		t.Fatal(err)
	}
	canonicalCLI, _ := json.Marshal(fromCLI)
	canonicalGo, _ := json.Marshal(fromGo)
	if string(canonicalCLI) != string(canonicalGo) || detail.ReaderContractVersion != "2" {
		t.Fatal("TUI evidence differs from shared projection")
	}
	if !strings.Contains(string(detail.Evidence), "code-unavailable") {
		t.Fatalf("unknown code freshness omitted: %s", detail.Evidence)
	}
	if detail.TasksContent.Tasks[0].Description != "Complete task body" || detail.TasksContent.Tasks[0].BlockedBy[0] != "task-0" {
		t.Fatal("task body or dependencies lost")
	}
	if !strings.Contains(*detail.ExecLogContent, "Legacy execution body") {
		t.Fatal("legacy log lost")
	}
	before := DetailFingerprint(detail)
	if err := os.WriteFile(filepath.Join(item, "worker-reports", "report.md"), []byte("Changed nested body"), 0644); err != nil {
		t.Fatal(err)
	}
	changed := load()
	if before == DetailFingerprint(changed) {
		t.Fatal("nested report edit did not invalidate detail")
	}
	if err := os.Remove(filepath.Join(item, "worker-reports", "report.md")); err != nil {
		t.Fatal(err)
	}
	deleted := load()
	if DetailFingerprint(changed) == DetailFingerprint(deleted) || strings.Contains(string(deleted.Evidence), "Changed nested body") {
		t.Fatal("deleted report retained")
	}
	if err := os.WriteFile(filepath.Join(item, "_meta.json"), []byte("{"), 0644); err != nil {
		t.Fatal(err)
	}
	malformed := load()
	if !malformed.Malformed || !strings.Contains(string(malformed.Evidence), "result_summary") {
		t.Fatal("malformed metadata hid evidence")
	}
	archive := filepath.Join(kdir, "_work", "_archive")
	if err := os.MkdirAll(archive, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(item, filepath.Join(archive, "fixture")); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(load().Evidence), "_work/_archive/fixture") {
		t.Fatal("archived evidence not loaded")
	}
}

func TestEvidenceReaderUnavailable(t *testing.T) {
	t.Setenv("LORE_DATA_DIR", t.TempDir())
	d := &WorkItemDetail{}
	loadEvidence(d, t.TempDir(), t.TempDir())
	if !strings.Contains(string(d.Evidence), `"state":"unreadable"`) {
		t.Fatalf("reader failure disappeared: %s", d.Evidence)
	}
}
