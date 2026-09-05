package work

import (
	"context"
	"fmt"
	libghostty "go.mitchellh.com/libghostty"
	"os/exec"
	"strings"
	"time"
)

type HistoryCapture struct {
	ScreenBuffer string
	Rows         []string
	RetainedRows int
	Truncated    bool
	Source       string
}

func (m SessionPanelModel) HistorySnapshot(maxRows, maxBytes int) (HistoryCapture, error) {
	result := HistoryCapture{Source: "libghostty-scrollback"}
	if m.backend == nil || m.backend.closed {
		return result, fmt.Errorf("terminal history unavailable")
	}
	result.ScreenBuffer = "unknown"
	if screen, err := m.backend.term.ActiveScreen(); err == nil {
		result.ScreenBuffer = "primary"
		if screen == libghostty.ScreenAlternate {
			result.ScreenBuffer = "alternate"
		}
	}
	total := m.backend.totalLines()
	result.RetainedRows = total
	height, err := m.backend.term.Rows()
	if err != nil || height == 0 {
		return result, fmt.Errorf("terminal dimensions unavailable")
	}
	remaining := maxBytes
	end := total
	for end > 0 && len(result.Rows) < maxRows && remaining > 0 {
		start := end - int(height)
		if start < 0 {
			start = 0
		}
		chunk := m.backend.readScrollback(start, end)
		if len(chunk) != end-start {
			return result, fmt.Errorf("terminal history read incomplete")
		}
		kept := []string{}
		for i := len(chunk) - 1; i >= 0 && len(result.Rows)+len(kept) < maxRows; i-- {
			if len(chunk[i])+1 > remaining {
				result.Truncated = true
				break
			}
			kept = append([]string{chunk[i]}, kept...)
			remaining -= len(chunk[i]) + 1
		}
		result.Rows = append(kept, result.Rows...)
		if len(kept) != len(chunk) {
			break
		}
		end = start
	}
	result.Truncated = result.Truncated || len(result.Rows) < total
	return result, nil
}

type historyTailWriter struct {
	data      []byte
	limit     int
	rows      int
	truncated bool
}

func (w *historyTailWriter) Write(data []byte) (int, error) {
	n := len(data)
	w.rows += strings.Count(string(data), "\n")
	if len(data) >= w.limit {
		w.data = append(w.data[:0], data[len(data)-w.limit:]...)
		w.truncated = true
		return n, nil
	}
	if len(w.data)+len(data) > w.limit {
		drop := len(w.data) + len(data) - w.limit
		copy(w.data, w.data[drop:])
		w.data = w.data[:len(w.data)-drop]
		w.truncated = true
	}
	w.data = append(w.data, data...)
	return n, nil
}

func CaptureTmuxHistory(name string, maxRows, maxBytes int) (HistoryCapture, error) {
	result := HistoryCapture{Source: "tmux-capture-pane", ScreenBuffer: "active-unknown"}
	if name == "" {
		return result, fmt.Errorf("empty tmux session")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, tmuxBinary, "-L", tmuxServerLabel, "capture-pane", "-p", "-e", "-S", "-", "-t", name)
	output := historyTailWriter{limit: maxBytes}
	cmd.Stdout = &output
	if err := cmd.Run(); err != nil {
		return result, fmt.Errorf("tmux history unavailable: %w", err)
	}
	text := strings.ReplaceAll(string(output.data), "\r\n", "\n")
	if output.truncated {
		if i := strings.IndexByte(text, '\n'); i >= 0 {
			text = text[i+1:]
		} else {
			text = ""
		}
	}
	rows := strings.Split(strings.TrimSuffix(text, "\n"), "\n")
	if text == "" {
		rows = nil
	}
	result.RetainedRows = output.rows
	result.Truncated = output.truncated || len(rows) > maxRows
	if len(rows) > maxRows {
		rows = rows[len(rows)-maxRows:]
	}
	result.Rows = rows
	return result, nil
}
