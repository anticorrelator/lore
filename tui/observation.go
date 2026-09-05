package main

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"

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
		if framework == "claude-code" && ccActivity.MatchString(strings.TrimSpace(row)) {
			return "claude-code-thinking-chrome-v1"
		}
	}
	return ""
}

var ccSettled = regexp.MustCompile(`^✻\s*Worked for\s*\d+(?:m\s*\d+s|s|m)?$`)

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
		if row == "" {
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
	state, known := classifyScreen(framework, snap)
	evidence := session.ObservationEvidence{Matcher: "unrecognized-screen-v1", Reason: "No supported lifecycle signature; input readiness and output silence do not establish idle."}
	if !known {
		return "unknown", evidence
	}
	if state.interactive {
		return "blocked", session.ObservationEvidence{Matcher: state.interactiveReason, Reason: "Interactive prompt owns terminal input."}
	}
	if matcher := activeScreenMatcher(framework, snap.Rows); matcher != "" {
		return "working", session.ObservationEvidence{Matcher: matcher, Reason: "Current activity chrome advertises an interruptible turn."}
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
	if err != nil || panel.MirrorError() != "" {
		return obs, snap, screenClass{}
	}
	state, _ := classifyScreen(framework, snap)
	contract, _ := config.HarnessSignatureContract(framework)
	queues, _ := config.HarnessQueuesMidGeneration(framework)
	obs.CanAcceptInput, obs.InputBlockedReason = sendReadiness(framework, panel.NeedsInput(), contract, queues, snap)
	obs.Fresh = true
	obs.Activity, obs.Evidence = classifyActivity(framework, snap)
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
	wasParked := seen && (previous.Activity == "idle" || previous.Activity == "blocked")
	event := ""
	if parked && (!wasParked || previous.Activity != obs.Activity) {
		event = session.EventNeedsInput
	}
	if obs.Activity == "working" && (!seen || previous.Activity != "working") {
		event = session.EventResumed
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
	now := time.Now()
	obs, _, _ := m.snapshotObservation(slug, now)
	return m.applySessionObservation(slug, obs, now)
}
