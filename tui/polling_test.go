package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anticorrelator/lore/tui/internal/work"
)

func TestEvidencePollingNestedDeletionAndRefresh(t *testing.T) {
	repo, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}
	data := t.TempDir()
	if err := os.Symlink(filepath.Join(repo, "scripts"), filepath.Join(data, "scripts")); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LORE_DATA_DIR", data)
	workDir := filepath.Join(t.TempDir(), "_work")
	item := filepath.Join(workDir, "fixture")
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
	write("plan.md", "Old plan")
	write("worker-reports/report.md", "Old report")
	poll := func() detailMtimeCheckedMsg {
		t.Helper()
		msg := checkDetailMtime(workDir, "fixture")().(detailMtimeCheckedMsg)
		if msg.err != nil {
			t.Fatal(msg.err)
		}
		return msg
	}
	first := poll()
	if !first.mtime.Equal(poll().mtime) {
		t.Fatal("unchanged poll is unstable")
	}
	write("worker-reports/report.md", "New report")
	changed := poll()
	if first.mtime.Equal(changed.mtime) {
		t.Fatal("nested content edit did not change poll")
	}
	m := minimalModel(stateWork, []work.WorkItem{{Slug: "fixture", Title: "Fixture", Status: "active"}}, nil)
	m.config.WorkDir = workDir
	m.lastDetailMtime = changed.mtime
	m.detail = work.NewDetailModel(workDir, "fixture")
	m.detailCache = map[string]*work.WorkItemDetail{"fixture": {Title: "stale"}}
	if err := os.Remove(filepath.Join(item, "worker-reports/report.md")); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(item, "plan.md")); err != nil {
		t.Fatal(err)
	}
	deleted := poll()
	if deleted.mtime.Equal(changed.mtime) {
		t.Fatal("deletion did not change poll")
	}
	m, cmd := m.handleDetailMtimeChecked(deleted)
	if cmd == nil || m.detailCache["fixture"] != nil {
		t.Fatal("poll did not invalidate stale detail and schedule reload")
	}
	loaded := cmd().(work.DetailLoadedMsg)
	if loaded.Err != nil {
		t.Fatal(loaded.Err)
	}
	if loaded.Detail.PlanContent != nil || strings.Contains(string(loaded.Detail.Evidence), "New report") {
		t.Fatal("refresh retained deleted files")
	}
	// The evidence source also lives outside the item tree.
	packets := filepath.Join(filepath.Dir(workDir), "_packets")
	if err := os.MkdirAll(packets, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packets, "packets.jsonl"), []byte(`{"schema_version":1,"work_item":"fixture","packet_id":"packet-1"}`+"\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if deleted.mtime.Equal(poll().mtime) {
		t.Fatal("global packet change did not refresh detail")
	}
}
