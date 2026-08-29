package sessionview

import (
	"strings"
	"testing"
)

func TestRemoteTmuxCardAdvertisesLiveDrillInWithoutScreenContent(t *testing.T) {
	m := NewDetailModel()
	m.SetSession(SessionRow{
		RowID: "r1", Local: false, Tmux: "lore-b-foo", Instance: "b",
		Display: "foo", Type: "implement", Initiator: "human", Started: "now",
	}, true)
	got := m.View()
	for _, want := range []string{
		"read-only — runs on another instance",
		"live drill-in available — Enter opens the remote tmux pane",
		"type", "implement", "instance", "b", "activity", "running",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("remote tmux card missing %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "capturing") || strings.Contains(got, "mirror") {
		t.Fatalf("passive card must not render snapshot state:\n%s", got)
	}
}

func TestRemoteCardWithoutTmuxIdentityMakesLiveScreenStateExplicit(t *testing.T) {
	m := NewDetailModel()
	m.SetSession(SessionRow{RowID: "r1", Local: false, Tmux: "", Instance: "b", Display: "foo", Type: "chat"}, true)
	got := m.View()
	if !strings.Contains(got, "live screen unavailable — tmux identity unknown") {
		t.Fatalf("card without tmux identity must state the unavailable live-screen condition, got:\n%s", got)
	}
}
