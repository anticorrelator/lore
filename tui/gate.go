package main

import (
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

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
	// sendReasonUnsubmitted is the post-inject terminal: the gate passed and the
	// paste reached the composer, but a bounded observation never confirmed the
	// submit took (the composer still held the payload after one retry). It is a
	// truthful refusal, not a gate decision — no message was delivered.
	sendReasonUnsubmitted = "unsubmitted"
)

// screenMatcher pairs the pure screen-state predicates a harness needs. composer
// and interactive drive the readiness gate and close ladder; pending/heldInput
// drive post-inject verification by reporting a composer still holding unsent
// payload. placeholder/redactPlaceholder cover faint harness example text: it is
// idle-ready chrome, but peek must not report it as real composer content.
type screenMatcher struct {
	composer          func(rows []string) bool
	interactive       func(rows []string) bool
	choices           func(rows []string) optionGeometry
	pending           func(rows []string) bool
	placeholder       func(rows []string, ansiRows []string) bool
	heldInput         func(rows []string, ansiRows []string) bool
	redactPlaceholder func(rows []string, ansiRows []string) []string
}

// screenMatchers ports the executable matchers from
// tests/probes/session_injection/_driver.py (the capability row's `matcher`
// field is their human-readable description). Keyed by framework: a framework
// absent here has no gate implementation and the send/peek path refuses with
// no-contract rather than guessing a signature. Only claude-code carries a
// pending matcher — the paste-collapse swallow is a live-observed claude-code
// behavior; codex/opencode held-content signatures are unprobed, so their
// verification relies on the shared generating/empty-ready signals.
var screenMatchers = map[string]screenMatcher{
	"claude-code": {
		composer:          ccComposerReady,
		interactive:       ccInteractivePrompt,
		choices:           ccModalOptions,
		pending:           ccComposerPending,
		placeholder:       ccComposerPlaceholder,
		heldInput:         ccComposerHeldInput,
		redactPlaceholder: ccRedactComposerPlaceholder,
	},
	"codex":    {composer: cxComposerReady, interactive: cxPermissionModal, choices: cxModalOptions},
	"opencode": {composer: ocComposerReady, interactive: ocPermissionModal},
}

type screenClass struct {
	composer         bool
	interactive      bool
	selectedOption   int
	availableOptions []int
	pending          bool
	placeholder      bool
	heldInput        bool
}

// closeObservation is one close tick's view of a panel: process lifecycle and
// the timer-derived idle edge paired with one shared screen classification.
// Keeping the full screenClass here makes composer and interactive meaning come
// from the same matcher set used by send and peek.
type closeObservation struct {
	done        bool
	quiescent   bool
	screen      screenClass
	screenKnown bool
}

func (o closeObservation) interactive() bool {
	return !o.done && o.screenKnown && o.screen.interactive
}

func (o closeObservation) idleComposer() bool {
	return !o.done && o.screenKnown && o.screen.composer && !o.screen.pending && !o.screen.heldInput
}

func (o closeObservation) generating() bool {
	return !o.done && !o.quiescent && !o.interactive() && !o.idleComposer()
}

func classifyScreen(framework string, snap work.ScreenSnapshot) (screenClass, bool) {
	mm, ok := screenMatchers[framework]
	if !ok {
		return screenClass{}, false
	}
	rows := gateRows(snap.Rows)
	ansiRows := splitANSIRows(snap.ANSI)
	state := screenClass{
		composer:    mm.composer != nil && mm.composer(rows),
		interactive: mm.interactive != nil && mm.interactive(rows),
		pending:     mm.pending != nil && mm.pending(rows),
		placeholder: mm.placeholder != nil && mm.placeholder(rows, ansiRows),
		heldInput:   mm.heldInput != nil && mm.heldInput(rows, ansiRows),
	}
	if mm.choices != nil {
		geometry := mm.choices(rows)
		state.selectedOption = geometry.selected
		state.availableOptions = append([]int(nil), geometry.available...)
	}
	return state, true
}

// optionGeometry is the numbered choice state parsed from one interactive
// screen. available preserves rendered row order; selected is the displayed
// option number carrying the selection glyph. A modal may be interactive while
// this structure is empty, in which case it is observable but not answerable.
type optionGeometry struct {
	selected  int
	available []int
}

var numberedOptionRow = regexp.MustCompile(`^\s*([❯›>])?\s*(\d+)[.)]\s+\S`)

func parseNumberedOptions(rows []string) optionGeometry {
	geometry := optionGeometry{}
	seen := make(map[int]bool)
	selectedCount := 0
	for _, row := range rows {
		match := numberedOptionRow.FindStringSubmatch(row)
		if len(match) != 3 {
			continue
		}
		option, err := strconv.Atoi(match[2])
		if err != nil || option < 1 {
			continue
		}
		if !seen[option] {
			seen[option] = true
			geometry.available = append(geometry.available, option)
		}
		if match[1] != "" {
			selectedCount++
			geometry.selected = option
		}
	}
	if selectedCount != 1 {
		geometry.selected = 0
	}
	return geometry
}

// classifyCloseObservation pairs the panel's lifecycle/idle state with the
// shared harness screen classifier. Callers provide one ScreenSnapshot, so a
// close tick cannot make its generation and prompt decisions from different
// terminal paints.
func classifyCloseObservation(framework string, done, quiescent bool, snap work.ScreenSnapshot) closeObservation {
	state, ok := classifyScreen(framework, snap)
	return closeObservation{
		done:        done,
		quiescent:   quiescent,
		screen:      state,
		screenKnown: ok,
	}
}

// sendObs is the post-inject observation: the paste was submitted, the composer
// still holds it, or the screen can't be classified this tick.
type sendObs int

const (
	obsUnobservable sendObs = iota // transient repaint — no confident read yet
	obsSubmitted                   // the turn started, or the composer is empty-ready again
	obsPending                     // the composer still holds the unsent payload
)

// observeSend classifies a post-inject screen for the deferred-outcome loop. It
// checks the held-payload signature first (the swallow leaves the composer
// non-empty regardless of the quiescence timer edge), then treats a generating
// session or a composer that re-matches its empty-ready signature as submitted.
// quiescent is the panel's needs_input edge. A framework with no matcher, or a
// screen that matches neither shape, reads unobservable so the caller waits
// rather than guessing.
func observeSend(framework string, quiescent bool, snap work.ScreenSnapshot) sendObs {
	state, ok := classifyScreen(framework, snap)
	if !ok {
		return obsUnobservable
	}
	if state.pending || state.heldInput {
		return obsPending
	}
	if !quiescent {
		return obsSubmitted
	}
	if state.composer && !state.interactive {
		return obsSubmitted
	}
	return obsUnobservable
}

// sendReadiness is the strict injection gate (D2): ready only when the session is
// quiescent AND the composer signature matches AND the interactive-prompt
// signature does not. reason is "" when ready; otherwise one of generating|
// modal|no-signature|no-contract. needs_input is the quiescence edge and is NOT treated as a
// stronger signal than quiescent — both are the same timer edge, so the screen
// check (not the idle flag) is what distinguishes composer-idle from modal-idle.
func sendReadiness(framework string, quiescent, hasContract bool, snap work.ScreenSnapshot) (bool, string) {
	if !hasContract {
		return false, sendReasonNoContract
	}
	if _, ok := screenMatchers[framework]; !ok {
		return false, sendReasonNoContract
	}
	if !quiescent {
		return false, sendReasonGenerating
	}
	state, _ := classifyScreen(framework, snap)
	if state.interactive {
		return false, sendReasonModal
	}
	if state.pending || state.heldInput || !state.composer {
		return false, sendReasonNoSignature
	}
	return true, ""
}

// interactivePromptState is the close-ladder/readiness shared modal predicate:
// any interactive prompt (permission/approval or option-select question) blocks
// protocol-terminus teardown until the modal-hold bound resolves it.
func interactivePromptState(framework string, snap work.ScreenSnapshot) bool {
	state, ok := classifyScreen(framework, snap)
	return ok && state.interactive
}

// peekRows returns the plain rows a peek response should expose. It preserves the
// snapshot rows except for matcher-owned placeholder redaction, so faint example
// prompt text never masquerades as real held composer input.
func peekRows(framework string, snap work.ScreenSnapshot) []string {
	rows := append([]string(nil), snap.Rows...)
	mm, ok := screenMatchers[framework]
	if !ok || mm.redactPlaceholder == nil {
		return rows
	}
	return mm.redactPlaceholder(rows, splitANSIRows(snap.ANSI))
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

func splitANSIRows(ansi string) []string {
	if ansi == "" {
		return nil
	}
	return strings.Split(ansi, "\n")
}

func noContractNotice(framework string) runtimeNotice {
	return degradationNotice(
		"interaction-contract-unavailable",
		"no interaction contract for "+framework+"; session send/peek/answer refused",
	)
}

func lastRows(rows []string, n int) []string {
	if len(rows) <= n {
		return rows
	}
	return rows[len(rows)-n:]
}

// --- claude-code: a '❯' prompt row flanked by two full-width '─' rules. ---
var (
	ccRule      = regexp.MustCompile(`─{80,}`)
	ccPrompt    = regexp.MustCompile(`^\s*[❯>](\s|$)`)
	ccProceed   = regexp.MustCompile(`(?i)do you want to (proceed|run|allow)`)
	ccFooter    = regexp.MustCompile(`(?i)esc to cancel|tab to amend|ctrl\+e to explain`)
	ccSelect    = regexp.MustCompile(`(?i)enter\s+to\s+select|select.*enter|↑|↓|up/down|arrow keys`)
	ccOption    = regexp.MustCompile(`[❯>]?\s*\d[.)]\s`)
	ccSelected  = regexp.MustCompile(`^\s*[❯>]\s+\S`)
	ccPasteChip = regexp.MustCompile(`\[Pasted text #\d+`)
)

func ccComposerReady(rows []string) bool {
	// Interactive prompts render in-band inside the composer chrome, so their
	// option rows ("❯ 1. Yes") and box rules can satisfy the structural anchors;
	// ready means visible AND unobstructed, so negate prompts first.
	if ccInteractivePrompt(rows) {
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

func ccInteractivePrompt(rows []string) bool {
	return ccPermissionModal(rows) || ccOptionSelectModal(rows)
}

func ccModalOptions(rows []string) optionGeometry {
	if !ccInteractivePrompt(rows) {
		return optionGeometry{}
	}
	return parseNumberedOptions(lastRows(rows, 16))
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

func ccOptionSelectModal(rows []string) bool {
	tail := lastRows(ccComposerRegion(rows), 16)
	txt := strings.Join(tail, "\n")
	if !ccSelect.MatchString(txt) {
		return false
	}
	options := 0
	candidates := 0
	selected := false
	for _, r := range tail {
		trimmed := strings.TrimSpace(r)
		if trimmed == "" || ccRule.MatchString(r) || ccSelect.MatchString(r) {
			continue
		}
		candidates++
		optionLine := ccOption.MatchString(r) || ccSelected.MatchString(r)
		if ccSelected.MatchString(r) {
			selected = true
		}
		if optionLine {
			options++
		}
	}
	return options >= 2 || (selected && candidates >= 3)
}

// ccComposerPending reports that claude-code's composer is still holding an
// unsent pasted payload — the paste-collapse swallow the deferred-outcome loop
// must catch. A large paste renders as a "[Pasted text #N]" chip; once submitted
// the chip moves up into the transcript, so the search is scoped to the composer
// region (the bottom "rule / prompt / rule / hint" band) to tell a still-pending
// composer from a sent chip scrolled into history.
func ccComposerPending(rows []string) bool {
	for _, r := range ccComposerRegion(rows) {
		if ccPasteChip.MatchString(r) {
			return true
		}
	}
	return false
}

func ccComposerPlaceholder(rows []string, ansiRows []string) bool {
	_, hasText, allFaint, ok := ccPromptSuffixStyle(rows, ansiRows)
	return ok && hasText && allFaint
}

func ccComposerHeldInput(rows []string, ansiRows []string) bool {
	_, hasText, allFaint, ok := ccPromptSuffixStyle(rows, ansiRows)
	return ok && hasText && !allFaint
}

func ccRedactComposerPlaceholder(rows []string, ansiRows []string) []string {
	out := append([]string(nil), rows...)
	idx, hasText, allFaint, ok := ccPromptSuffixStyle(gateRows(rows), ansiRows)
	if !ok || !hasText || !allFaint || idx < 0 || idx >= len(out) {
		return out
	}
	out[idx] = promptPrefix(out[idx])
	return out
}

// ccComposerRegion returns the bottom composer band: everything from the
// second-to-last full-width rule onward, which spans the prompt row a pending
// chip sits on and excludes the transcript above. With fewer than two rules
// (a partial repaint) it falls back to the last few rows.
func ccComposerRegion(rows []string) []string {
	return rows[ccComposerRegionStart(rows):]
}

func ccComposerRegionStart(rows []string) int {
	var ruleIdx []int
	for i, r := range rows {
		if ccRule.MatchString(r) {
			ruleIdx = append(ruleIdx, i)
		}
	}
	if len(ruleIdx) >= 2 {
		return ruleIdx[len(ruleIdx)-2]
	}
	if len(rows) <= 4 {
		return 0
	}
	return len(rows) - 4
}

func ccPromptLineIndex(rows []string) int {
	start := ccComposerRegionStart(rows)
	for i := start; i < len(rows); i++ {
		if ccPrompt.MatchString(rows[i]) {
			return i
		}
	}
	return -1
}

func ccPromptSuffixStyle(rows []string, ansiRows []string) (idx int, hasText, allFaint, ok bool) {
	idx = ccPromptLineIndex(rows)
	if idx < 0 || idx >= len(ansiRows) {
		return idx, false, false, false
	}
	styled := parseSGRFaint(ansiRows[idx])
	start, promptOK := promptSuffixStart(styled.text)
	if !promptOK {
		return idx, false, false, false
	}
	allFaint = true
	for i := start; i < len(styled.text); i++ {
		if unicode.IsSpace(styled.text[i]) {
			continue
		}
		hasText = true
		if i >= len(styled.faint) || !styled.faint[i] {
			allFaint = false
		}
	}
	return idx, hasText, allFaint, true
}

type styledText struct {
	text  []rune
	faint []bool
}

func parseSGRFaint(line string) styledText {
	var out styledText
	faint := false
	for i := 0; i < len(line); {
		if line[i] == '\x1b' && i+1 < len(line) && line[i+1] == '[' {
			j := i + 2
			for j < len(line) && line[j] != 'm' {
				j++
			}
			if j < len(line) {
				applyFaintSGR(line[i+2:j], &faint)
				i = j + 1
				continue
			}
		}
		r, size := utf8.DecodeRuneInString(line[i:])
		if r == utf8.RuneError && size == 0 {
			break
		}
		out.text = append(out.text, r)
		out.faint = append(out.faint, faint)
		i += size
	}
	return out
}

func applyFaintSGR(params string, faint *bool) {
	if params == "" {
		*faint = false
		return
	}
	for _, p := range strings.Split(params, ";") {
		if p == "" {
			p = "0"
		}
		code, err := strconv.Atoi(p)
		if err != nil {
			continue
		}
		switch code {
		case 0:
			*faint = false
		case 2:
			*faint = true
		case 22:
			*faint = false
		}
	}
}

func promptSuffixStart(text []rune) (int, bool) {
	i := 0
	for i < len(text) && unicode.IsSpace(text[i]) {
		i++
	}
	if i >= len(text) || (text[i] != '❯' && text[i] != '>') {
		return 0, false
	}
	i++
	for i < len(text) && unicode.IsSpace(text[i]) {
		i++
	}
	return i, true
}

func promptPrefix(row string) string {
	runes := []rune(row)
	start, ok := promptSuffixStart(runes)
	if !ok {
		return row
	}
	return string(runes[:start])
}

// --- codex: footer status line "<model> <effort> · <cwd>" + a '›' input row. ---
var (
	cxFooter      = regexp.MustCompile(`(minimal|low|medium|high|xhigh)\s+·\s`)
	cxModalAnchor = regexp.MustCompile(`(?i)would you like to run|press enter to confirm or esc|enter\s+to\s+(confirm|select)|select.*enter|use.*(?:↑|↓).*enter|up/down|arrow keys`)
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
	geometry := cxModalOptions(rows)
	return geometry.selected > 0 && len(geometry.available) >= 2
}

func cxModalOptions(rows []string) optionGeometry {
	tail := lastRows(rows, 18)
	text := strings.Join(tail, "\n")
	// A current composer footer means any modal-looking rows above it are
	// scrollback, not the active input surface.
	if cxFooter.MatchString(text) || !cxModalAnchor.MatchString(text) {
		return optionGeometry{}
	}
	geometry := parseNumberedOptions(tail)
	if geometry.selected == 0 || len(geometry.available) < 2 {
		return optionGeometry{}
	}
	return geometry
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
