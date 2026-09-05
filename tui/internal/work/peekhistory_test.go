package work

import (
	tea "charm.land/bubbletea/v2"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCaptureTmuxHistoryBoundedAndClientless(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "args")
	fixture := "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$HISTORY_TEST_ARGS\"\ni=0\nwhile [ $i -lt 1000 ]; do printf '\\033[31mrow-%04d 界\\033[0m\\n' \"$i\"; i=$((i+1)); done\n"
	if err := os.WriteFile(filepath.Join(dir, "tmux"), []byte(fixture), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	t.Setenv("HISTORY_TEST_ARGS", log)
	capture, err := CaptureTmuxHistory("isolated", 80, 1200)
	if err != nil {
		t.Fatal(err)
	}
	size := 0
	for _, row := range capture.Rows {
		size += len(row) + 1
	}
	if !capture.Truncated || capture.RetainedRows != 1000 || size > 1200 || len(capture.Rows) > 80 || !strings.Contains(capture.Rows[len(capture.Rows)-1], "row-0999") {
		t.Fatalf("capture=%+v bytes=%d", capture, size)
	}
	args, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	if string(args) != "-L\nlore-tui\ncapture-pane\n-p\n-e\n-S\n-\n-t\nisolated\n" {
		t.Fatalf("mutating or attaching command: %s", args)
	}
}

func TestHistoryTailWriterPreservesBound(t *testing.T) {
	writer := historyTailWriter{limit: 20}
	for _, chunk := range []string{"first\n", strings.Repeat("x", 100) + "\n", "last\n"} {
		if n, err := writer.Write([]byte(chunk)); n != len(chunk) || err != nil {
			t.Fatal(n, err)
		}
	}
	if len(writer.data) > 20 || !writer.truncated || writer.rows != 3 || !strings.HasSuffix(string(writer.data), "last\n") {
		t.Fatalf("writer=%+v", writer)
	}
}

func TestNativeHistoryPreservesViewAndDescribesAlternateScreen(t *testing.T) {
	panel := NewSessionPanelModel("test")
	panel, _ = panel.Update(tea.WindowSizeMsg{Width: 80, Height: 8})
	panel, _ = panel.Update(TerminalOutputMsg{Slug: "test", Data: []byte(strings.Repeat("primary-history\r\n", 30))})
	panel.scrollOffset = 10
	panel.cachedRender = "existing-scroll-view"
	capture, err := panel.HistorySnapshot(5000, 2*1024*1024)
	if err != nil || capture.ScreenBuffer != "primary" || capture.RetainedRows < 30 {
		t.Fatalf("native=%+v err=%v", capture, err)
	}
	if panel.scrollOffset != 10 || panel.cachedRender != "existing-scroll-view" {
		t.Fatal("history mutated user scroll view")
	}
	panel, _ = panel.Update(TerminalOutputMsg{Slug: "test", Data: []byte("\x1b[?1049hALTERNATE")})
	capture, err = panel.HistorySnapshot(5000, 2*1024*1024)
	if err != nil || capture.ScreenBuffer != "alternate" || strings.Contains(strings.Join(capture.Rows, "\n"), "primary-history") {
		t.Fatalf("alternate invents primary retention: %+v %v", capture, err)
	}
}
