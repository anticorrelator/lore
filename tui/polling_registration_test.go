package main

import (
	"testing"

	"github.com/anticorrelator/lore/tui/internal/session"
)

func TestHostHeartbeatStillRestoresRegistration(t *testing.T) {
	m := minimalModel(stateWork, nil, nil)
	m.sessionsDir = t.TempDir()
	m.instanceName = "host"
	m.hostKey = "host-key"
	if msg := m.syncInstanceCmd()().(instanceSyncedMsg); msg.err != nil {
		t.Fatal(msg.err)
	}
	if !session.InstanceLive(m.sessionsDir, m.instanceName) {
		t.Fatal("session host lost its recovery heartbeat")
	}
}
