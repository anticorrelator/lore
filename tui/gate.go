package main

import (
	"fmt"
	"os"
	"regexp"
	"strings"
	"unicode"

	"github.com/anticorrelator/lore/tui/internal/work"
)

// Send-readiness refusal reasons (D2/D4). The first four are gate decisions;
// unsafe-payload is decided at the injection write; internalError covers a
// screen-read or PTY-write failure that is not itself a gate refusal but still
// consumes the request and journals an outcome.
const (
	sendReasonGenerating  = "generating"
	sendReasonModal       = "modal"
	sendReasonNoSignature = "no-signature"
	sendReasonNoContract  = "no-contract"
	sendReasonUnsafe      = "unsafe-payload"
	sendReasonInternal    = "error"
)

// screenMatcher pairs the two pure screen-state predicates a harness needs for
// the readiness gate. They operate on the plain-text screen rows.
type screenMatcher struct {
	composer   func(rows []string) bool
	permission func(rows []string) bool
}

// screenMatchers ports the executable matchers from
// tests/probes/session_injection/_driver.py (the capability row's `matcher`
// field is their human-readable description). Keyed by framework: a framework
// absent here has no gate implementation and the send/peek path refuses with
// no-contract rather than guessing a signature.
var screenMatchers = map[string]screenMatcher{
	"claude-code": {composer: ccComposerReady, permission: ccPermissionModal},
	"codex":       {composer: cxComposerReady, permission: cxPermissionModal},
	"opencode":    {composer: ocComposerReady, permission: ocPermissionModal},
}

// sendReadiness is the strict injection gate (D2): ready only when the session is
// quiescent AND the composer signature matches AND the permission signature does
// not. reason is "" when ready; otherwise one of generating|modal|no-signature|
// no-contract. needs_input is the quiescence edge and is NOT treated as a
// stronger signal than quiescent — both are the same timer edge, so the screen
// check (not the idle flag) is what distinguishes composer-idle from modal-idle.
func sendReadiness(framework string, quiescent, hasContract bool, snap work.ScreenSnapshot) (bool, string) {
	if !hasContract {
		return false, sendReasonNoContract
	}
	mm, ok := screenMatchers[framework]
	if !ok {
		return false, sendReasonNoContract
	}
	if !quiescent {
		return false, sendReasonGenerating
	}
	rows := gateRows(snap.Rows)
	if mm.permission(rows) {
		return false, sendReasonModal
	}
	if !mm.composer(rows) {
		return false, sendReasonNoSignature
	}
	return true, ""
}

// gateRows normalizes snapshot rows for signature matching: every non-ASCII
// Unicode space the emulator can emit (NBSP U+00A0, the U+2000-block spaces,
// U+202F, U+205F, U+3000, …) is mapped to an ASCII space. Go's regexp \s is
// ASCII-only ([\t\n\f\r ]) whereas the reference Python matchers rely on \s
// matching Unicode whitespace — claude-code renders its idle prompt as
// "❯ <ghost text>", so without this the composer anchor ^\s*[❯>](\s|$)
// misses a real idle composer and the gate wrongly refuses no-signature. One
// normalization point keeps every ported regex honest without widening each
// pattern. Applied only for matching; peek still reports the real screen rows.
func gateRows(rows []string) []string {
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = strings.Map(func(c rune) rune {
			if c > unicode.MaxASCII && unicode.IsSpace(c) {
				return ' '
			}
			return c
		}, r)
	}
	return out
}

// noteNoContract emits the degrade-explicitly stderr notice a send/peek refusal
// carries when the harness has no probed interaction contract, so the refusal is
// visible as a missing capability rather than a silent decline — the same
// pattern the close ladder uses for an absent graceful_exit_sequence. Callers
// invoke it once per refused request (requests are consumed once), never per tick.
func noteNoContract(framework string) {
	fmt.Fprintf(os.Stderr,
		"[lore] degraded: no interaction contract for framework %q (composer/permission signature unprobed); session send/peek refused with no-contract, not guessing a signature\n",
		framework)
}

func lastRows(rows []string, n int) []string {
	if len(rows) <= n {
		return rows
	}
	return rows[len(rows)-n:]
}

// --- claude-code: a '❯' prompt row flanked by two full-width '─' rules. ---
var (
	ccRule    = regexp.MustCompile(`─{80,}`)
	ccPrompt  = regexp.MustCompile(`^\s*[❯>](\s|$)`)
	ccProceed = regexp.MustCompile(`(?i)do you want to (proceed|run|allow)`)
	ccFooter  = regexp.MustCompile(`(?i)esc to cancel|tab to amend|ctrl\+e to explain`)
	ccOption  = regexp.MustCompile(`[❯>]?\s*\d[.)]\s`)
)

func ccComposerReady(rows []string) bool {
	// The permission modal renders in-band inside the composer chrome, so its
	// option rows ("❯ 1. Yes") and the box rules can satisfy the structural
	// anchors; ready means visible AND unobstructed, so negate the modal first.
	if ccPermissionModal(rows) {
		return false
	}
	rules := 0
	prompt := false
	for _, r := range rows {
		if ccRule.MatchString(r) {
			rules++
		}
		if ccPrompt.MatchString(r) {
			prompt = true
		}
	}
	return prompt && rules >= 2
}

func ccPermissionModal(rows []string) bool {
	tail := lastRows(rows, 14)
	txt := strings.Join(tail, "\n")
	proceed := ccProceed.MatchString(txt)
	footer := ccFooter.MatchString(txt)
	options := 0
	for _, r := range tail {
		if ccOption.MatchString(r) {
			options++
		}
	}
	return (proceed || footer) && options >= 2
}

// --- codex: footer status line "<model> <effort> · <cwd>" + a '›' input row. ---
var (
	cxFooter   = regexp.MustCompile(`(minimal|low|medium|high|xhigh)\s+·\s`)
	cxApproval = regexp.MustCompile(`(?i)would you like to run|press enter to confirm or esc|yes, proceed|and tell codex what to do|allow.*command|approve`)
)

const cxGlyph = "›"

func cxComposerReady(rows []string) bool {
	// The approval modal usually drops the footer status row, but negate it
	// explicitly so a partial repaint that still shows the footer is not read
	// as composer-ready.
	if cxPermissionModal(rows) {
		return false
	}
	footerIdx := -1
	for i, r := range rows {
		if cxFooter.MatchString(r) {
			footerIdx = i
			break
		}
	}
	if footerIdx < 0 {
		return false
	}
	for i := footerIdx; i >= 0; i-- {
		if strings.HasPrefix(strings.TrimLeft(rows[i], " \t"), cxGlyph) {
			return true
		}
	}
	return false
}

func cxPermissionModal(rows []string) bool {
	for _, r := range rows {
		if cxApproval.MatchString(r) {
			return true
		}
	}
	return false
}

// --- opencode: '╹▀+' bottom border + a 'commands' key-hint + the '┃' left border. ---
var (
	ocBottom  = regexp.MustCompile(`╹▀{5,}`)
	ocActions = regexp.MustCompile(`Allow once\s+Allow always\s+Reject`)
)

func ocComposerReady(rows []string) bool {
	// The permission modal renders in-band inside the composer box, so the
	// border/hint anchors stay on screen; ready means visible AND unobstructed,
	// so negate the modal first.
	if ocPermissionModal(rows) {
		return false
	}
	bottom, hint, left := false, false, false
	for _, r := range rows {
		if ocBottom.MatchString(r) {
			bottom = true
		}
		if strings.Contains(r, "commands") {
			hint = true
		}
		if strings.Contains(r, "┃") {
			left = true
		}
	}
	return bottom && hint && left
}

func ocPermissionModal(rows []string) bool {
	perm, action := false, false
	for _, r := range rows {
		if strings.Contains(r, "Permission required") {
			perm = true
		}
		if ocActions.MatchString(r) {
			action = true
		}
	}
	return perm && action
}
