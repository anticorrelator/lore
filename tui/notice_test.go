package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anticorrelator/lore/tui/internal/session"
)

type noticeFixture struct {
	Code        string `json:"code"`
	Class       string `json:"class"`
	Destination string `json:"destination"`
}

func TestNoticeFixtureDestinations(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("testdata", "alt-screen-stderr", "notice-cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixtures []noticeFixture
	if err := json.Unmarshal(data, &fixtures); err != nil {
		t.Fatal(err)
	}
	if len(fixtures) < 9 {
		t.Fatalf("fixture count = %d, want launch, close, gate, registry, queue, and request witnesses", len(fixtures))
	}
	for _, fixture := range fixtures {
		switch fixture.Class {
		case string(operatorDegradation):
			m := (model{}).routeRuntimeNotices([]runtimeNotice{degradationNotice(fixture.Code, fixture.Code)})
			if fixture.Destination != "status" || m.statusNotice != fixture.Code {
				t.Errorf("fixture %s routed to status %q", fixture.Code, m.statusNotice)
			}
		case "background-diagnostic":
			if fixture.Destination != "tui-notices.jsonl" {
				t.Errorf("fixture %s destination = %q", fixture.Code, fixture.Destination)
			}
		default:
			t.Errorf("fixture %s has unknown class %q", fixture.Code, fixture.Class)
		}
	}
}

func TestBackgroundDiagnosticsUseDurableLogWithoutReplacingStatus(t *testing.T) {
	dir := t.TempDir()
	m := model{sessionsDir: dir, statusNotice: "operator notice"}
	cmd := appendDiagnosticsCmd(dir, []session.Diagnostic{{Source: "queue-pending", Path: "bad.json", Message: "corrupt row excluded"}})
	if cmd == nil {
		t.Fatal("appendDiagnosticsCmd returned nil")
	}
	msg := cmd().(diagnosticsLoggedMsg)
	if msg.err != nil {
		t.Fatal(msg.err)
	}
	if m.statusNotice != "operator notice" {
		t.Fatalf("background diagnostic replaced status notice: %q", m.statusNotice)
	}
	data, err := os.ReadFile(filepath.Join(dir, "tui-notices.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"class":"background-diagnostic"`) {
		t.Fatalf("notice log = %s", data)
	}
}

func TestStatusNoticeRendersBelowOperationalErrors(t *testing.T) {
	m := model{statusNotice: "graceful close unavailable"}
	if got := m.renderStatusBar(80); !strings.Contains(got, m.statusNotice) {
		t.Fatalf("status bar = %q, want operator notice", got)
	}
	m.flashErr = "close failed"
	got := m.renderStatusBar(80)
	if !strings.Contains(got, m.flashErr) || strings.Contains(got, m.statusNotice) {
		t.Fatalf("status bar precedence = %q", got)
	}
}
