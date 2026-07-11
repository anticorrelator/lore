package main

import (
	"fmt"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/session"
)

type runtimeNoticeClass string

const (
	operatorDegradation runtimeNoticeClass = "operator-degradation"
	backgroundDiagnostic runtimeNoticeClass = "background-diagnostic"
	operationalFailure   runtimeNoticeClass = "operational-failure"
)

type runtimeNotice struct {
	Class   runtimeNoticeClass
	Code    string
	Message string
}

type diagnosticsLoggedMsg struct {
	err error
}

func degradationNotice(code, message string) runtimeNotice {
	return runtimeNotice{Class: operatorDegradation, Code: code, Message: message}
}

func (m model) routeRuntimeNotices(notices []runtimeNotice) model {
	for _, notice := range notices {
		if notice.Message == "" {
			continue
		}
		switch notice.Class {
		case operatorDegradation:
			m.statusNotice = notice.Message
		case operationalFailure:
			m.flashErr = notice.Message
		case backgroundDiagnostic:
			// Background diagnostics carry structured session.Diagnostic payloads
			// and are routed by appendDiagnosticsCmd, never through model text.
		}
	}
	return m
}

func appendDiagnosticsCmd(sessionsDir string, diagnostics []session.Diagnostic) tea.Cmd {
	if sessionsDir == "" || len(diagnostics) == 0 {
		return nil
	}
	return func() tea.Msg {
		return diagnosticsLoggedMsg{err: session.AppendDiagnostics(sessionsDir, diagnostics)}
	}
}

func diagnosticLogError(err error) string {
	return compactErr("TUI notice log", fmt.Errorf("%w", err))
}
