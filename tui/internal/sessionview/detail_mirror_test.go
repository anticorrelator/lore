package sessionview

import (
	"strings"
	"testing"
)

// TestRemoteMirrorGating verifies only a cross-instance tmux-hosted session is
// reported as mirrorable: local panels, in-flight spawns, and direct-PTY rows
// (no tmux name) are not.
func TestRemoteMirrorGating(t *testing.T) {
	cases := []struct {
		name string
		row  SessionRow
		want bool
	}{
		{"remote tmux", SessionRow{RowID: "r1", Local: false, Tmux: "lore-b-foo"}, true},
		{"local", SessionRow{RowID: "r2", Local: true, Tmux: "lore-a-foo"}, false},
		{"remote direct-pty", SessionRow{RowID: "r3", Local: false, Tmux: ""}, false},
		{"in-flight", SessionRow{RowID: "r4", Local: false, InFlight: true, Tmux: "lore-b-foo"}, false},
	}
	for _, tc := range cases {
		m := NewDetailModel()
		m.SetSession(tc.row, true)
		if _, _, ok := m.RemoteMirror(); ok != tc.want {
			t.Errorf("%s: RemoteMirror ok = %v, want %v", tc.name, ok, tc.want)
		}
	}
}

// TestSetMirrorPinsToRow verifies a snapshot only lands when its rowID matches
// the displayed row, so a capture dispatched before the cursor moved cannot paint
// under a different session.
func TestSetMirrorPinsToRow(t *testing.T) {
	m := NewDetailModel()
	m.SetSession(SessionRow{RowID: "r1", Local: false, Tmux: "lore-b-foo", Instance: "b", Type: "implement"}, true)

	m.SetMirror("stale-row", []string{"WRONG SCREEN"})
	if got := m.View(); strings.Contains(got, "WRONG SCREEN") {
		t.Fatalf("stale-row snapshot must be dropped, got:\n%s", got)
	}

	m.SetMirror("r1", []string{"HELLO from remote"})
	if got := m.View(); !strings.Contains(got, "HELLO from remote") {
		t.Fatalf("matching snapshot should render, got:\n%s", got)
	}
}

// TestSetSessionClearsStaleMirror verifies moving to a different row drops the
// prior frame so the previous session's screen is never shown under the new one.
func TestSetSessionClearsStaleMirror(t *testing.T) {
	m := NewDetailModel()
	m.SetSession(SessionRow{RowID: "r1", Local: false, Tmux: "lore-b-foo", Instance: "b"}, true)
	m.SetMirror("r1", []string{"FRAME ONE"})

	m.SetSession(SessionRow{RowID: "r2", Local: false, Tmux: "lore-b-bar", Instance: "b"}, true)
	got := m.View()
	if strings.Contains(got, "FRAME ONE") {
		t.Fatalf("prior mirror frame must clear on row change, got:\n%s", got)
	}
	if !strings.Contains(got, "capturing live screen") {
		t.Fatalf("new row should show the capturing placeholder until first capture, got:\n%s", got)
	}
}

// TestDirectPTYCardIsLocalOnly verifies a cross-instance direct-PTY row (no tmux
// name) renders an explicit local-only state rather than a blank mirror.
func TestDirectPTYCardIsLocalOnly(t *testing.T) {
	m := NewDetailModel()
	m.SetSession(SessionRow{RowID: "r1", Local: false, Tmux: "", Instance: "b", Display: "foo", Type: "chat"}, true)
	got := m.View()
	if !strings.Contains(got, "live screen available only on its host") {
		t.Fatalf("direct-PTY card should state the local-only condition, got:\n%s", got)
	}
}
