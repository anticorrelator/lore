package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

type generationVector struct {
	Name string `json:"name"`
	Row  struct {
		SessionID string `json:"session_id"`
		RequestID string `json:"request_id"`
		Tmux      string `json:"tmux"`
		Started   string `json:"started"`
	} `json:"row"`
	Generation string `json:"generation"`
}

func loadGenerationVectors(t *testing.T) []generationVector {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "tests", "fixtures", "session-generation-vectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Vectors []generationVector `json:"vectors"`
	}
	if err := json.Unmarshal(data, &file); err != nil {
		t.Fatal(err)
	}
	if len(file.Vectors) == 0 {
		t.Fatal("the vector file holds no vectors")
	}
	return file.Vectors
}

// The same vectors are checked against scripts/session_target.py generation()
// by tests/test_session_generation_vectors.py.
func TestGenerationMatchesSharedVectors(t *testing.T) {
	for _, v := range loadGenerationVectors(t) {
		t.Run(v.Name, func(t *testing.T) {
			var started time.Time
			if v.Row.Started != "" {
				var err error
				if started, err = time.Parse(time.RFC3339Nano, v.Row.Started); err != nil {
					t.Fatal(err)
				}
			}
			if got := Generation(v.Row.SessionID, v.Row.RequestID, v.Row.Tmux, started); got != v.Generation {
				t.Fatalf("Generation = %q, want %q", got, v.Generation)
			}
		})
	}
}

// A pane learns its generation from the launch's own clock reading; the host
// re-derives it from the registry row, which keeps whole seconds.
func TestGenerationOfALaunchTimeEqualsItsRegistryForm(t *testing.T) {
	for _, nanos := range []int{0, 1, 499_999_999, 500_000_000, 999_999_999} {
		launched := time.Date(2026, 10, 18, 7, 4, 5, nanos, time.Local)
		stored, err := time.Parse("2006-01-02T15:04:05Z", launched.UTC().Format("2006-01-02T15:04:05Z"))
		if err != nil {
			t.Fatal(err)
		}
		pane := Generation("sid", "rid", "tmux", launched)
		host := Generation("sid", "rid", "tmux", stored)
		if pane != host || pane != "sid/rid/"+strconv.FormatInt(launched.Unix(), 10) {
			t.Errorf("nanos %d: pane %q, host %q", nanos, pane, host)
		}
	}
}
