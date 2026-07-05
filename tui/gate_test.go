package main

import (
	"testing"

	"github.com/anticorrelator/lore/tui/internal/work"
)

// Representative composer-ready and permission-modal screen rows per harness,
// shaped after the anchors the capability-row matchers key on (the live ground
// truth is pinned by tests/probes/session_injection/test_matchers.py against the
// recorded observations; these mirror the same discrimination in Go).
var (
	rule = "────────────────────────────────────────────────────────────────────────────────────"

	ccComposerRows = []string{
		rule,
		"❯ ",
		rule,
		"  ? for shortcuts",
	}
	// Modal fixtures deliberately carry the composer chrome too (rules, footer
	// status row, box borders): the permission modal renders in-band, so a
	// structural composer match alone would false-positive as ready. The gate's
	// composer matchers must negate the modal, and these fixtures exercise that.
	ccModalRows = []string{
		rule,
		"Bash command",
		"  touch /tmp/x",
		"Do you want to proceed?",
		"❯ 1. Yes",
		"  2. Yes, and don't ask again",
		"  3. No, and tell Claude what to do differently (esc)",
		"Esc to cancel · Tab to amend · ctrl+e to explain",
		rule,
	}

	cxComposerRows = []string{
		"› ",
		"gpt-5-codex  medium · ~/work/lore",
	}
	cxModalRows = []string{
		"› ",
		"gpt-5-codex  medium · ~/work/lore",
		"Would you like to run the following command?",
		"$ rm -rf build",
		"› 1. Yes, proceed (y)",
		"  2. Yes, and don't ask again",
		"  3. No (esc)",
		"Press enter to confirm or esc to cancel",
	}

	ocComposerRows = []string{
		"┃ Ask anything...",
		"╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀",
		"/ commands",
	}
	ocModalRows = []string{
		"┃ △ Permission required",
		"╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀",
		"/ commands",
		"$ rm -rf build",
		"Allow once   Allow always   Reject",
	}
)

func TestComposerMatchersDiscriminate(t *testing.T) {
	cases := []struct {
		harness  string
		composer []string
		modal    []string
	}{
		{"claude-code", ccComposerRows, ccModalRows},
		{"codex", cxComposerRows, cxModalRows},
		{"opencode", ocComposerRows, ocModalRows},
	}
	for _, c := range cases {
		mm := screenMatchers[c.harness]
		if !mm.composer(c.composer) {
			t.Errorf("%s: composer matcher should fire on composer-ready rows", c.harness)
		}
		if mm.composer(c.modal) {
			t.Errorf("%s: composer matcher must NOT fire on a permission modal", c.harness)
		}
		if !mm.permission(c.modal) {
			t.Errorf("%s: permission matcher should fire on modal rows", c.harness)
		}
		if mm.permission(c.composer) {
			t.Errorf("%s: permission matcher must NOT fire on a composer-ready screen", c.harness)
		}
	}
}

func TestSendReadiness(t *testing.T) {
	snapComposer := work.ScreenSnapshot{Rows: ccComposerRows}
	snapModal := work.ScreenSnapshot{Rows: ccModalRows}
	snapOther := work.ScreenSnapshot{Rows: []string{"thinking...", "some output"}}

	// Live regression (real claude-code idle session): the prompt row renders as
	// "❯ commit this" — a NBSP after the glyph plus a ghost-text suggestion.
	// Go's regexp \s is ASCII-only, so without gateRows normalization the composer
	// anchor ^\s*[❯>](\s|$) misses this and the gate wrongly refuses no-signature.
	snapNBSP := work.ScreenSnapshot{Rows: []string{
		rule,
		"❯ commit this",
		rule,
		"  ? for shortcuts",
	}}

	cases := []struct {
		name       string
		framework  string
		quiescent  bool
		hasCon     bool
		snap       work.ScreenSnapshot
		wantReady  bool
		wantReason string
	}{
		{"ready", "claude-code", true, true, snapComposer, true, ""},
		{"ready-nbsp-live-composer", "claude-code", true, true, snapNBSP, true, ""},
		{"mid-generation", "claude-code", false, true, snapComposer, false, sendReasonGenerating},
		{"permission-modal", "claude-code", true, true, snapModal, false, sendReasonModal},
		{"no-composer-signature", "claude-code", true, true, snapOther, false, sendReasonNoSignature},
		{"no-contract", "claude-code", true, false, snapComposer, false, sendReasonNoContract},
		{"unknown-framework", "ghostwriter", true, true, snapComposer, false, sendReasonNoContract},
	}
	for _, c := range cases {
		ready, reason := sendReadiness(c.framework, c.quiescent, c.hasCon, c.snap)
		if ready != c.wantReady || reason != c.wantReason {
			t.Errorf("%s: got (ready=%v reason=%q), want (ready=%v reason=%q)",
				c.name, ready, reason, c.wantReady, c.wantReason)
		}
	}
}

// TestGateNormalizesUnicodeSpace pins the live NBSP bug and its fix: the raw
// ported matcher misses a NBSP after the prompt glyph (Go's regexp \s is
// ASCII-only, Python's is not), but the gate normalizes Unicode spaces to ASCII
// at the matching boundary, so the same real idle screen reads composer-ready.
func TestGateNormalizesUnicodeSpace(t *testing.T) {
	nbsp := []string{rule, "❯ commit this", rule, "  ? for shortcuts"}
	if ccComposerReady(nbsp) {
		t.Fatal("expected raw ccComposerReady to miss the NBSP prompt (Go \\s is ASCII-only)")
	}
	if ready, reason := sendReadiness("claude-code", true, true, work.ScreenSnapshot{Rows: nbsp}); !ready || reason != "" {
		t.Fatalf("gate should read the NBSP composer as ready; got ready=%v reason=%q", ready, reason)
	}
	if got := gateRows([]string{"❯ x"})[0]; got != "❯ x" {
		t.Fatalf("gateRows NBSP normalization = %q, want %q", got, "❯ x")
	}
}
