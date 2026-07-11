package work

import (
	"fmt"
	"slices"
	"strings"
	"testing"
)

func TestTmuxLaunchCapabilityContractHarnessMatrix(t *testing.T) {
	t.Setenv("TERM", "operator-term")
	t.Setenv("COLORTERM", "operator-value")
	t.Setenv("TMUX", "stale")
	t.Setenv("TMUX_PANE", "%99")

	fixtures := []struct {
		framework string
		binary    string
	}{
		{"claude-code", "claude"},
		{"codex", "codex"},
		{"opencode", "opencode"},
	}
	for _, fixture := range fixtures {
		t.Run(fixture.framework, func(t *testing.T) {
			args := tmuxSessionArgs("lore-test-session", 80, 24,
				[]string{"LORE_FRAMEWORK=" + fixture.framework, "COLORTERM=wrong"},
				fixture.binary, []string{"--fixture"})
			joined := strings.Join(args, "\x00")
			for _, stale := range []string{"TERM=operator-term", "COLORTERM=operator-value", "COLORTERM=wrong", "TMUX=stale", "TMUX_PANE=%99"} {
				if strings.Contains(joined, stale) {
					t.Errorf("tmux args leaked %q: %v", stale, args)
				}
			}
			if strings.Count(joined, "COLORTERM=truecolor") != 1 {
				t.Errorf("tmux args COLORTERM count = %d, want 1: %v", strings.Count(joined, "COLORTERM=truecolor"), args)
			}
			if !strings.Contains(joined, "LORE_FRAMEWORK="+fixture.framework) {
				t.Errorf("tmux args lost framework identity: %v", args)
			}
			wantTail := []string{"--", fixture.binary, "--fixture"}
			if !slices.Equal(args[len(args)-len(wantTail):], wantTail) {
				t.Errorf("tmux command tail = %v, want %v", args[len(args)-len(wantTail):], wantTail)
			}
		})
	}
}

func TestTmuxCapabilityPinsPreserveExistingOptions(t *testing.T) {
	wantPins := [][2]string{
		{"default-terminal", "tmux-256color"},
		{"escape-time", "0"},
		{"exit-empty", "on"},
		{"history-limit", fmt.Sprint(tmuxHistoryLimit)},
		{"prefix", "none"},
		{"prefix2", "none"},
		{"status", "off"},
		{"remain-on-exit", "off"},
		{"window-size", "latest"},
	}
	got := tmuxOptionPins()
	if len(got) != len(wantPins)*5 {
		t.Fatalf("option pin args = %v", got)
	}
	for i, pin := range wantPins {
		if !slices.Equal(got[i*5:i*5+5], []string{"set", "-g", pin[0], pin[1], ";"}) {
			t.Errorf("pin %d = %v, want %v", i, got[i*5:i*5+5], pin)
		}
	}
	if got := tmuxRGBFeaturePin(); !slices.Equal(got, []string{"set", "-as", "terminal-features", ",*:RGB", ";"}) {
		t.Errorf("RGB feature pin = %v", got)
	}
}
