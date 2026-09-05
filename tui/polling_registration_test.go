package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/anticorrelator/lore/tui/internal/session"
)

func TestRemovedInstanceStopsPollingWithoutReregistering(t *testing.T) {
	m := minimalModel(stateCoordination, nil, nil)
	m.sessionsDir = t.TempDir()
	m.instanceName = "removed-ui"
	m.config.WorkDir = t.TempDir()
	m.config.KnowledgeDir = t.TempDir()
	if err := session.WriteInstance(m.sessionsDir, session.Instance{Name: m.instanceName}); err != nil {
		t.Fatal(err)
	}
	if _, cmd := m.handleIndexPollTick(); cmd == nil {
		t.Fatal("registered UI did not poll")
	}
	if err := session.RemoveInstance(m.sessionsDir, m.instanceName); err != nil {
		t.Fatal(err)
	}
	stopped, cmd := m.handleIndexPollTick()
	if cmd != nil || !stopped.pollingStopped {
		t.Fatal("removed UI scheduled more polling")
	}
	msg := stopped.syncInstanceCmd()().(instanceSyncedMsg)
	if !os.IsNotExist(msg.err) {
		t.Fatalf("heartbeat recreated registration: %v", msg.err)
	}
	if _, err := os.Stat(filepath.Join(session.InstancesDir(m.sessionsDir), m.instanceName+".json")); !os.IsNotExist(err) {
		t.Fatal("registration reappeared")
	}
	if _, cmd := stopped.handleIndexPollTick(); cmd != nil {
		t.Fatal("late tick resumed polling")
	}
}

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
