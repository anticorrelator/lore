package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	tea "charm.land/bubbletea/v2"
	"github.com/anticorrelator/lore/tui/internal/config"
	"github.com/anticorrelator/lore/tui/internal/session"
	"github.com/anticorrelator/lore/tui/internal/work"
)

var activityInterrupt = regexp.MustCompile(`(?i)(?:\(\s*\d+(?:\.\d+)?[smh].*\besc to interrupt\s*\)\s*$|^\s*esc\s+interrupt(?:\s|$))`)
var ccActivity = regexp.MustCompile(`^[✶✻✽✢·*] .*(?:…|\.\.\.).*\((?:.*thinking|.*\d+s)`)

func activeScreenMatcher(framework string, rows []string) string {
	rows = gateRows(rows)
	if settledScreenMatcher(framework, rows) != "" {
		for i := len(rows) - 1; i >= 0; i-- {
			row := strings.TrimSpace(rows[i])
			if ccSettled.MatchString(row) || cxSettled.MatchString(row) || ocSettled.MatchString(row) {
				rows = rows[i+1:]
				break
			}
		}
	}
	for _, row := range lastRows(rows, 18) {
		if activityInterrupt.MatchString(row) {
			switch framework {
			case "claude-code", "codex", "opencode":
				return framework + "-interrupt-chrome-v1"
			}
		}
		if framework == "claude-code" && (ccActivity.MatchString(strings.TrimSpace(row)) || ccElapsedActivity.MatchString(strings.TrimSpace(row))) {
			return "claude-code-thinking-chrome-v1"
		}
	}
	return ""
}

var reconnectFailure = regexp.MustCompile(`(?i)(reconnecting.*(?:timeout|failed)|idle timeout waiting for websocket|stream disconnected.*(?:timeout|failed))`)

const ccDuration = `(?:\d+h(?:\s+\d+m)?(?:\s+\d+s)?|\d+m(?:\s+\d+s)?|\d+(?:\.\d+)?s)`

// Claude rotates both the star glyph and the verb. A completed duration phrase
// ("for 4s", never an ellipsis) and an optional completion clock in 12- or
// 24-hour form distinguish this marker from active chrome; a missed settled
// marker silences the session's needs_input wake, so the clock is not narrowed
// to one locale's format.
var ccSettled = regexp.MustCompile(`^[✻✶✽✢]\s+[\p{L}][\p{L}\p{M}]*\s+for\s+` + ccDuration + `(?:\s+·\s+done\s+(?:[01]?\d|2[0-3]):[0-5]\d(?::[0-5]\d)?(?:\s*[AP]M)?)?$`)
var ccElapsedActivity = regexp.MustCompile(`^[✶✻✽✢✳·*]\s+[\p{L}][\p{L}\p{M}]*(?:…|\.\.\.)\s+` + ccDuration + `$`)

var ocSettled = regexp.MustCompile(`^▣\s+.+ · .+ · \d+(?:\.\d+)?(?:ms|s|m|h|d)(?: \d+(?:s|m|h))?$`)
var cxSettled = regexp.MustCompile(`^─ Worked for \d+(?:h|m|s)(?: \d+(?:m|s)){0,2} (?:• .+ )?─+$`)

func settledScreenMatcher(framework string, rows []string) string {
	rows = gateRows(rows)
	start := len(rows)
	switch framework {
	case "claude-code":
		start = ccComposerRegionStart(rows)
	case "opencode":
		for i := len(rows) - 1; i >= 0; i-- {
			if ocBottom.MatchString(rows[i]) {
				start = i
				break
			}
		}
		for start > 0 && strings.Contains(rows[start-1], "┃") {
			start--
		}
	case "codex":
		footer := cxFooterIndex(rows)
		for i := footer; i >= 0; i-- {
			if strings.HasPrefix(strings.TrimSpace(rows[i]), cxGlyph) {
				start = i
				break
			}
		}
		for i := start - 1; i >= 0; i-- {
			row := strings.TrimSpace(rows[i])
			if strings.HasPrefix(row, cxGlyph) {
				return ""
			}
			if cxSettled.MatchString(row) {
				return "codex-worked-for-v1"
			}
		}
		return ""
	default:
		return ""
	}
	for i := start - 1; i >= 0; i-- {
		row := strings.TrimSpace(rows[i])
		if row == "" || (framework == "claude-code" && row == "/diff to hide diff") {
			continue
		}
		if framework == "claude-code" && ccSettled.MatchString(row) {
			return "claude-code-worked-for-v1"
		}
		if framework == "opencode" && ocSettled.MatchString(row) {
			return "opencode-final-duration-v1"
		}
		return ""
	}
	return ""
}

func classifyActivity(framework string, snap work.ScreenSnapshot) (string, session.ObservationEvidence) {
	if framework == "claude-code" {
		snap = ccComposerPane(snap)
	}
	state, known := classifyScreen(framework, snap)
	evidence := session.ObservationEvidence{Matcher: "unrecognized-screen-v1", Reason: "No supported lifecycle signature; input readiness and output silence do not establish idle."}
	if !known {
		return "unknown", evidence
	}
	if state.interactive {
		return "blocked", session.ObservationEvidence{Matcher: state.interactiveReason, Reason: "Interactive prompt owns terminal input."}
	}
	active := activeScreenMatcher(framework, snap.Rows)
	turn := currentTurnRows(framework, snap.Rows)
	if active != "" {
		for _, row := range gateRows(turn) {
			if reconnectFailure.MatchString(row) {
				return "stalled", session.ObservationEvidence{Matcher: "connection-failure-v1", Reason: strings.TrimSpace(row)}
			}
		}
	}
	for _, row := range turn {
		if providerFailure.MatchString(strings.TrimSpace(row)) {
			return "blocked", session.ObservationEvidence{Matcher: "provider-error-v1", Reason: "Provider reports a connection or request failure; interrupt chrome does not establish healthy progress."}
		}
	}
	if active != "" {
		return "working", session.ObservationEvidence{Matcher: active, Reason: "Current activity chrome advertises an interruptible turn."}
	}
	if matcher := settledScreenMatcher(framework, snap.Rows); matcher != "" && state.composer && !state.pending && !state.heldInput {
		return "idle", session.ObservationEvidence{Matcher: matcher, Reason: "Settled-turn marker is current to the unobstructed composer; this does not establish task completion."}
	}
	return "unknown", evidence
}

func observationGeneration(ls liveSession) string {
	identity := ls.sessionID
	if identity == "" {
		identity = ls.requestID
	}
	if identity == "" {
		identity = ls.tmuxName
	}
	if !ls.started.IsZero() {
		return fmt.Sprintf("%s/%s/%d", identity, ls.requestID, ls.started.Unix())
	}
	return identity
}

func (m model) snapshotObservation(slug string, now time.Time) (session.Observation, work.ScreenSnapshot, screenClass) {
	ls := m.localSessions[slug]
	framework := m.sessionHarness(slug)
	obs := session.Observation{SchemaVersion: 1, Activity: "unknown", Authority: "none", ObservedAt: now.UTC().Format(time.RFC3339Nano), SessionID: ls.sessionID, Generation: observationGeneration(ls), Instance: m.instanceName, MaxAgeSeconds: 5, Evidence: session.ObservationEvidence{Matcher: "screen-unavailable-v1", Reason: "Terminal screen is unavailable."}}
	obs.SessionHandle = slug
	obs.NativeSessionID = ls.sessionID
	if obs.SessionID == "" {
		obs.SessionID = slug
	}
	if obs.SessionID == "" {
		obs.SessionID = obs.Generation
	}
	panel, ok := m.sessionPanels[slug]
	if !ok {
		return obs, work.ScreenSnapshot{}, screenClass{}
	}
	if panel.IsDone() {
		obs.Activity = "exited"
		obs.Authority = "runtime"
		obs.Fresh = true
		obs.Evidence = session.ObservationEvidence{Matcher: "process-exited-v1", Reason: "Hosted process has exited."}
		snap, _ := panel.ScreenState()
		return obs, snap, screenClass{}
	}
	snap, err := panel.ScreenState()
	if err != nil {
		return obs, snap, screenClass{}
	}
	state, _ := classifyScreen(framework, snap)
	contract, _ := config.HarnessSignatureContract(framework)
	queues, _ := config.HarnessQueuesMidGeneration(framework)
	obs.CanAcceptInput, obs.InputBlockedReason = sendReadiness(framework, panel.NeedsInput(), contract, queues, snap)
	obs.Fresh = true
	m.observeProgress(slug, &obs, snap, now)
	obs.Activity, obs.Evidence = classifyActivity(framework, snap)
	if last := panel.LastOutputTime(); obs.Activity == "working" && !last.IsZero() && now.Sub(last) >= 5*time.Minute {
		obs.Activity = "stalled"
		obs.Evidence = session.ObservationEvidence{Matcher: "working-output-silent-v1", Reason: "Working chrome with no terminal output for at least five minutes; inspect before interrupting, a silent tool may still be running."}
	}
	if state.numberedModal != nil {
		encoded, _ := json.Marshal(state.numberedModal)
		obs.BlockSignature = fmt.Sprintf("%x", sha256.Sum256(encoded))
	}
	if obs.Activity != "unknown" {
		obs.Authority = "screen-signature"
	}
	if obs.Activity == "idle" {
		previous, seen := m.sessionObservations[slug]
		since := m.observationSince[slug]
		if !seen || previous.Generation != obs.Generation || since.IsZero() || now.Sub(since) < 2*time.Second {
			obs.Activity = "starting"
			obs.Authority = "runtime"
			obs.Evidence = session.ObservationEvidence{Matcher: "initial-screen-settling-v1", Reason: "Initial screen must be observed across the startup/recovery settling interval."}
		}
	}
	return obs, snap, state
}

func (m model) applySessionObservation(slug string, obs session.Observation, now time.Time) (model, tea.Cmd) {
	if m.observationProgress == nil {
		m.observationProgress = make(map[string]observationProgress)
	}
	ls, tracked := m.localSessions[slug]
	if !tracked {
		return m, nil
	}
	if m.sessionObservations == nil {
		m.sessionObservations = make(map[string]session.Observation)
	}
	if m.observationSince == nil {
		m.observationSince = make(map[string]time.Time)
	}
	previous, seen := m.sessionObservations[slug]
	if m.meaningfulObservations == nil {
		m.meaningfulObservations = make(map[string]session.Observation)
	}
	meaningful, meaningfulSeen := m.meaningfulObservations[slug]
	if meaningful.Generation != obs.Generation {
		meaningfulSeen = false
	}
	if !seen || previous.Generation != obs.Generation {
		m.observationSince[slug] = now
		seen = false
	}
	m.sessionObservations[slug] = obs
	parked := obs.Activity == "idle" || obs.Activity == "blocked"
	if m.sessionIdle == nil {
		m.sessionIdle = make(map[string]bool)
	}
	m.sessionIdle[slug] = parked
	m.list, _ = m.list.Update(work.SessionStatusMsg{Slug: slug, Type: ls.typ, NeedsInput: parked})
	wasParked := meaningfulSeen && (meaningful.Activity == "idle" || meaningful.Activity == "blocked")
	event := ""
	if parked && (!wasParked || meaningful.Activity != obs.Activity) {
		event = session.EventNeedsInput
	}
	if obs.Activity == "stalled" && (!meaningfulSeen || meaningful.Activity != "stalled") {
		event = session.EventNeedsInput
	}
	if obs.Activity == "working" && (!meaningfulSeen || meaningful.Activity != "working") {
		event = session.EventResumed
	}
	if obs.Activity != "unknown" && obs.Activity != "starting" {
		m.meaningfulObservations[slug] = obs
	}
	if event == "" {
		return m, nil
	}
	ev := m.idleEventFor(slug, event, ls)
	encoded, _ := json.Marshal(obs)
	ev.Links = map[string]string{"observation": string(encoded), "session_id": obs.SessionID, "generation": obs.Generation, "observed_at": obs.ObservedAt, "activity": obs.Activity}
	return m, journalCmd(m.eventScript, m.config.KnowledgeDir, ev)
}

func (m model) reconcileSessionObservation(slug string) (model, tea.Cmd) {
	if _, ok := m.localSessions[slug]; !ok {
		return m, nil
	}
	if m.observationProgress == nil {
		m.observationProgress = make(map[string]observationProgress)
	}
	now := time.Now()
	obs, _, _ := m.snapshotObservation(slug, now)
	return m.applySessionObservation(slug, obs, now)
}

var providerFailure = regexp.MustCompile(`(?i)^\s*(?:[!⚠●⎿]\s*)?(?:reconnecting\b|stream disconnected\b|connection (?:lost|failed|error)\b|(?:api|provider|request) error\b|error (?:connecting|during streaming)\b|retrying\.{0,3}\s*\(?\d)`)

// currentTurnRows returns the harness rows above the composer that follow the
// latest submitted prompt and settled-turn marker, so an earlier turn's failure
// is not read as the current turn's. Claude tool output is blanked first: a
// failing command's own error text says nothing about the provider connection.
func currentTurnRows(framework string, rows []string) []string {
	composer := len(rows)
	switch framework {
	case "claude-code":
		rows = withoutCCToolOutput(rows)
		composer = ccComposerRegionStart(rows)
	case "codex":
		if footer := cxFooterIndex(rows); footer >= 0 {
			for i := footer; i >= 0; i-- {
				if strings.HasPrefix(strings.TrimSpace(rows[i]), cxGlyph) {
					composer = i
					break
				}
			}
		}
	case "opencode":
		for i := len(rows) - 1; i >= 0; i-- {
			if strings.Contains(rows[i], "┃") {
				composer = i
			} else if composer < len(rows) {
				break
			}
		}
	}
	for i := composer - 1; i >= 0; i-- {
		row := strings.TrimSpace(rows[i])
		glyph := "❯"
		if framework == "codex" {
			glyph = cxGlyph
		}
		if framework == "opencode" {
			glyph = ">"
		}
		if strings.HasPrefix(row, glyph+" ") && strings.TrimSpace(strings.TrimPrefix(row, glyph)) != "" {
			rows = rows[i+1:]
			break
		}
	}

	for i := len(rows) - 1; i >= 0; i-- {
		row := strings.TrimSpace(rows[i])
		if ccSettled.MatchString(row) || cxSettled.MatchString(row) || ocSettled.MatchString(row) {
			rows = rows[i+1:]
			break
		}
	}
	return lastRows(rows, 18)
}

// withoutCCToolOutput blanks Claude tool-result rows: a row led by "⎿" and the
// rows indented deeper than that glyph beneath it, across blank lines inside the
// block. A "⎿" row directly under activity chrome is the harness's own status
// line (tips, retry notices) and is kept. Blanking keeps row indices stable.
func withoutCCToolOutput(rows []string) []string {
	out := append([]string(nil), rows...)
	for i := 0; i < len(rows); i++ {
		glyph := strings.Index(rows[i], "⎿")
		if glyph < 0 || strings.TrimSpace(rows[i][:glyph]) != "" {
			continue
		}
		if i > 0 && ccActivityChrome(rows[i-1]) {
			continue
		}
		column := utf8.RuneCountInString(rows[i][:glyph])
		out[i] = ""
		last := i
		for j := i + 1; j < len(rows); j++ {
			if strings.TrimSpace(rows[j]) == "" {
				continue
			}
			if strings.Contains(rows[j], "⎿") || ccActivityChrome(rows[j]) || leadingSpaces(rows[j]) <= column {
				break
			}
			for k := last + 1; k <= j; k++ {
				out[k] = ""
			}
			last = j
		}
		i = last
	}
	return out
}

func ccActivityChrome(row string) bool {
	trimmed := strings.TrimSpace(row)
	return activityInterrupt.MatchString(row) || ccActivity.MatchString(trimmed) || ccElapsedActivity.MatchString(trimmed)
}

func leadingSpaces(row string) int {
	return utf8.RuneCountInString(row) - utf8.RuneCountInString(strings.TrimLeft(row, " "))
}

type observationProgress struct {
	generation, digest string
	at                 time.Time
}

func (m model) observeProgress(slug string, obs *session.Observation, snap work.ScreenSnapshot, now time.Time) {
	// Exclude composer and animated activity/status rows. Changed transcript
	// content is evidence of output progress, never proof a task advanced.
	rows := snap.Rows
	if m.sessionHarness(slug) == "claude-code" {
		rows = ccComposerPane(snap).Rows
		rows = rows[:ccComposerRegionStart(rows)]
	}
	var meaningful []string
	for _, row := range rows {
		row = strings.TrimSpace(row)
		if row == "" || providerFailure.MatchString(row) || activityInterrupt.MatchString(row) || ccActivity.MatchString(row) || ccElapsedActivity.MatchString(row) || strings.HasPrefix(row, "Background task") {
			continue
		}
		meaningful = append(meaningful, row)
	}
	if m.observationProgress == nil {
		return
	}
	prior := m.observationProgress[slug]
	digest := fmt.Sprintf("%x", sha256.Sum256([]byte(strings.Join(meaningful, "\n"))))
	if prior.generation != obs.Generation {
		prior = observationProgress{generation: obs.Generation}
	}
	activity, _ := classifyActivity(m.sessionHarness(slug), snap)
	if activity != "unknown" && len(meaningful) > 0 && digest != prior.digest {
		prior.digest = digest
		prior.at = now
		m.observationProgress[slug] = prior
	}
	if !prior.at.IsZero() {
		obs.ProgressObservedAt = prior.at.UTC().Format(time.RFC3339Nano)
		obs.ProgressAgeSeconds = now.Sub(prior.at).Seconds()
		obs.SuspectedStall = obs.ProgressAgeSeconds >= 120
	}
}
