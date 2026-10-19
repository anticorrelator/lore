package sessionview

import (
	"strings"
	"testing"
)

func TestRegistrySessionCardDescribesSessionNotHost(t *testing.T) {
	m := NewDetailModel()
	m.SetSession(SessionRow{
		RowID: "r1", Local: true, Tmux: "lore-store-host-foo", Instance: "store-host",
		Display: "foo", Type: "implement", Initiator: "human", Started: "now",
	}, true)
	got := m.View()
	for _, want := range []string{
		"type", "implement", "activity", "running", "x  request close",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("registry session card missing %q:\n%s", want, got)
		}
	}
	for _, stale := range []string{"another instance", "read-only", "remote"} {
		if strings.Contains(got, stale) {
			t.Errorf("registry session card says %q:\n%s", stale, got)
		}
	}
}

func TestInFlightCardLeadsWithSpawningAndOffersNoClose(t *testing.T) {
	m := NewDetailModel()
	m.SetSession(SessionRow{RowID: "inflight|q1", InFlight: true, Instance: "store-host", Display: "foo", Type: "chat"}, true)
	got := m.View()
	if !strings.Contains(got, "spawning — queued, not yet live") {
		t.Fatalf("in-flight card must lead with the spawning condition, got:\n%s", got)
	}
	if strings.Contains(got, "request close") || strings.Contains(got, "another instance") {
		t.Fatalf("in-flight card offers close or names another instance:\n%s", got)
	}
}
