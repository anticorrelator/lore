package main

import (
	"slices"
	"strings"
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
	ccOptionSelectRows = []string{
		rule,
		"Choose the next step",
		"❯ 1. Run the verification",
		"  2. Leave it for later",
		"Enter to select",
		rule,
	}
	ccGhostRows = []string{
		rule,
		"❯ commit this",
		rule,
		"  ? for shortcuts",
	}
	ccGhostANSI = strings.Join([]string{
		rule,
		"❯ \x1b[0;2mcommit this\x1b[0m",
		rule,
		"  ? for shortcuts",
	}, "\n")
	ccHeldRows = []string{
		rule,
		"❯ real typed input",
		rule,
		"  ? for shortcuts",
	}
	ccHeldANSI = strings.Join(ccHeldRows, "\n")

	cxComposerRows = []string{
		"› ",
		"gpt-5-codex  medium · ~/work/lore",
	}
	cxModalRows = []string{
		"Would you like to run the following command?",
		"$ rm -rf build",
		"› 1. Yes, proceed (y)",
		"  2. Yes, and don't ask again",
		"  3. No (esc)",
		"Press enter to confirm or esc to cancel",
	}
	cxOptionSelectRows = []string{
		"Choose the next step",
		"  1. Run the verification",
		"› 2. Leave it for later",
		"  4. Cancel",
		"Use ↑ and ↓, then Enter to select",
	}
	cxApproveSuggestionRows = []string{
		"› Implement the approved change",
		"gpt-5-codex  medium · ~/work/lore",
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
		if !mm.interactive(c.modal) {
			t.Errorf("%s: interactive matcher should fire on modal rows", c.harness)
		}
		if mm.interactive(c.composer) {
			t.Errorf("%s: interactive matcher must NOT fire on a composer-ready screen", c.harness)
		}
	}
	if !screenMatchers["claude-code"].interactive(ccOptionSelectRows) {
		t.Error("claude-code: interactive matcher should fire on option-select rows")
	}
	if screenMatchers["claude-code"].composer(ccOptionSelectRows) {
		t.Error("claude-code: composer matcher must NOT fire on an option-select modal")
	}

	for _, tc := range []struct {
		name      string
		framework string
		rows      []string
		selected  int
		available []int
	}{
		{"claude-code permission", "claude-code", ccModalRows, 1, []int{1, 2, 3}},
		{"claude-code option select", "claude-code", ccOptionSelectRows, 1, []int{1, 2}},
		{"codex approval", "codex", cxModalRows, 1, []int{1, 2, 3}},
		{"codex generic option select", "codex", cxOptionSelectRows, 2, []int{1, 2, 4}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state, ok := classifyScreen(tc.framework, work.ScreenSnapshot{Rows: tc.rows})
			if !ok || !state.interactive {
				t.Fatalf("classification = %+v known=%v, want interactive", state, ok)
			}
			if state.selectedOption != tc.selected || !slices.Equal(state.availableOptions, tc.available) {
				t.Fatalf("choice geometry = selected %d available %v, want selected %d available %v",
					state.selectedOption, state.availableOptions, tc.selected, tc.available)
			}
		})
	}
}

func TestCodexApproveSuggestionIsHealthyComposer(t *testing.T) {
	state, ok := classifyScreen("codex", work.ScreenSnapshot{Rows: cxApproveSuggestionRows})
	if !ok {
		t.Fatal("codex classifier unavailable")
	}
	if state.interactive || !state.composer {
		t.Fatalf("approved suggestion classified as %+v, want noninteractive composer", state)
	}
}

func TestSendReadiness(t *testing.T) {
	snapComposer := work.ScreenSnapshot{Rows: ccComposerRows}
	snapModal := work.ScreenSnapshot{Rows: ccModalRows}
	snapOptionSelect := work.ScreenSnapshot{Rows: ccOptionSelectRows}
	snapOther := work.ScreenSnapshot{Rows: []string{"thinking...", "some output"}}
	snapGhost := work.ScreenSnapshot{Rows: ccGhostRows, ANSI: ccGhostANSI}
	snapHeld := work.ScreenSnapshot{Rows: ccHeldRows, ANSI: ccHeldANSI}

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
		{"option-select-modal", "claude-code", true, true, snapOptionSelect, false, sendReasonModal},
		{"faint-placeholder-ready", "claude-code", true, true, snapGhost, true, ""},
		{"real-held-input-not-ready", "claude-code", true, true, snapHeld, false, sendReasonNoSignature},
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

func TestClassifyCloseObservationUsesSharedScreenClass(t *testing.T) {
	// The screen classifier can identify an idle composer before the timer edge
	// flips NeedsInput, so close must not mistake that paint for active generation.
	composer := classifyCloseObservation("claude-code", false, false, work.ScreenSnapshot{Rows: ccComposerRows})
	if !composer.screenKnown || !composer.screen.composer || composer.interactive() || composer.generating() {
		t.Fatalf("idle composer observation = %+v, want known composer idle", composer)
	}

	modal := classifyCloseObservation("claude-code", false, false, work.ScreenSnapshot{Rows: ccOptionSelectRows})
	if !modal.interactive() || modal.generating() {
		t.Fatalf("option-select observation = %+v, want interactive and not generating", modal)
	}

	generating := classifyCloseObservation("claude-code", false, false, work.ScreenSnapshot{Rows: []string{"working..."}})
	if !generating.generating() || generating.interactive() {
		t.Fatalf("active-turn observation = %+v, want generating", generating)
	}

	unknown := classifyCloseObservation("ghostwriter", false, false, work.ScreenSnapshot{Rows: ccComposerRows})
	if unknown.screenKnown || !unknown.generating() {
		t.Fatalf("unknown-framework observation = %+v, want conservative generating", unknown)
	}

	done := classifyCloseObservation("claude-code", true, false, work.ScreenSnapshot{Rows: ccOptionSelectRows})
	if done.generating() || done.interactive() {
		t.Fatalf("done observation = %+v, want neither generating nor interactive", done)
	}
}

func TestPeekRowsRedactsFaintPlaceholder(t *testing.T) {
	got := peekRows("claude-code", work.ScreenSnapshot{Rows: ccGhostRows, ANSI: ccGhostANSI})
	if strings.Contains(strings.Join(got, "\n"), "commit this") {
		t.Fatalf("peek rows leaked faint placeholder text: %#v", got)
	}
	if got[1] != "❯ " {
		t.Fatalf("peek rows prompt row = %q, want prompt only", got[1])
	}

	held := peekRows("claude-code", work.ScreenSnapshot{Rows: ccHeldRows, ANSI: ccHeldANSI})
	if !strings.Contains(strings.Join(held, "\n"), "real typed input") {
		t.Fatalf("peek rows redacted real held input: %#v", held)
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
