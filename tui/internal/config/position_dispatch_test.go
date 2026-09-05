package config

import "testing"

func TestPositionActivationUsesCapabilities(t *testing.T) {
	setupFakeLoreData(t, "codex", nil)
	for _, framework := range []string{"claude-code", "codex", "opencode"} {
		operation, err := HarnessPositionActivation(framework)
		if err != nil || operation != "native_launch" {
			t.Fatalf("%s: %s %v", framework, operation, err)
		}
	}
	if _, err := HarnessPositionActivation("unregistered"); err == nil {
		t.Fatal("unknown framework admitted")
	}
}
