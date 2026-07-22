package coordination

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/sessionview"
	"github.com/anticorrelator/lore/tui/internal/work"
)

var ansiRe = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func stripANSI(s string) string { return ansiRe.ReplaceAllString(s, "") }

// --- ReadPin (sidecar schema v1) ---

func TestReadPinMissingSidecarIsPinless(t *testing.T) {
	pin, err := ReadPin(t.TempDir())
	if err != nil || pin != nil {
		t.Fatalf("missing sidecar must read as pin-less, got pin=%v err=%v", pin, err)
	}
}

func TestReadPinClearedSidecarIsPinless(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "_coordination.json"), []byte(`{"schema_version":1}`), 0o644); err != nil {
		t.Fatal(err)
	}
	pin, err := ReadPin(dir)
	if err != nil || pin != nil {
		t.Fatalf("cleared sidecar (no pin key) must read as pin-less, got pin=%v err=%v", pin, err)
	}
}

func TestReadPinSetSidecar(t *testing.T) {
	dir := t.TempDir()
	raw := `{"schema_version":1,"pin":{"instance":"calm-cedar","pinned_at":"2026-07-22T09:00:00Z","pinned_by":"dustin"}}`
	if err := os.WriteFile(filepath.Join(dir, "_coordination.json"), []byte(raw), 0o644); err != nil {
		t.Fatal(err)
	}
	pin, err := ReadPin(dir)
	if err != nil || pin == nil {
		t.Fatalf("set sidecar must read the pin, got pin=%v err=%v", pin, err)
	}
	if pin.Instance != "calm-cedar" || pin.PinnedAt != "2026-07-22T09:00:00Z" || pin.PinnedBy != "dustin" {
		t.Errorf("pin fields mismatch: %+v", pin)
	}
}

func TestReadPinCorruptSidecarSurfacesError(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "_coordination.json"), []byte(`{"schema_version":"one"`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadPin(dir); err == nil {
		t.Error("corrupt sidecar must surface an error, not read as unpinned")
	}
}

// --- ListModel ---

func TestListModelRowsAreItemsNotHeaders(t *testing.T) {
	m := NewListModel()
	m.SetArcs([]Arc{{Slug: "arc-b", Members: 2}, {Slug: "arc-a", Members: 1}})
	if m.CurrentSlug() != "arc-b" {
		t.Fatalf("cursor should rest on the first arc, got %q", m.CurrentSlug())
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if m.CurrentSlug() != "arc-a" {
		t.Fatalf("j should move to the next arc, got %q", m.CurrentSlug())
	}
	// Cursor preserved by slug across a reload.
	m.SetArcs([]Arc{{Slug: "arc-c"}, {Slug: "arc-a"}, {Slug: "arc-b"}})
	if m.CurrentSlug() != "arc-a" {
		t.Errorf("reload should preserve the cursor by slug, got %q", m.CurrentSlug())
	}
}

func TestListModelEnterEmitsArcSelected(t *testing.T) {
	m := NewListModel()
	m.SetArcs([]Arc{{Slug: "arc-a", Members: 1}})
	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("Enter should emit a selection command")
	}
	msg, ok := cmd().(ArcSelectedMsg)
	if !ok || msg.Slug != "arc-a" {
		t.Fatalf("Enter produced %v, want ArcSelectedMsg{arc-a}", msg)
	}
	_ = m
}

// --- DetailModel first-class states ---

func sizedDetail() DetailModel {
	m := NewDetailModel()
	m, _ = m.Update(tea.WindowSizeMsg{Width: 80, Height: 30})
	return m
}

func TestDetailNoArcRendersExplicitEmptyState(t *testing.T) {
	m := sizedDetail()
	if out := stripANSI(m.View()); !strings.Contains(out, "No arc selected") {
		t.Errorf("empty detail must render the no-arc state:\n%s", out)
	}
}

func TestDetailStatusBriefStates(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	if out := stripANSI(m.View()); !strings.Contains(out, "reading coordination.md") {
		t.Errorf("pre-read status must render the loading state:\n%s", out)
	}
	m.SetLedger("## Rows\n\nrow\n", "", false)
	if out := stripANSI(m.View()); !strings.Contains(out, "no Brief yet") {
		t.Errorf("ledger without ## Brief must render the first-class no-Brief state:\n%s", out)
	}
	m.SetLedger("## Brief\n\nlanded: the mirror\n", "landed: the mirror", true)
	if out := stripANSI(m.View()); !strings.Contains(out, "landed: the mirror") {
		t.Errorf("extracted Brief must render:\n%s", out)
	}
}

func TestDetailPinThreeStates(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	m.SetLedger("x", "", false)

	m.SetPin(PinAbsent, nil)
	if out := stripANSI(m.View()); !strings.Contains(out, "none — dispatch has no standing target") {
		t.Errorf("absent pin must render first-class:\n%s", out)
	}

	m.SetPin(PinLive, &Pin{Instance: "calm-cedar"})
	if out := stripANSI(m.View()); !strings.Contains(out, "calm-cedar") || !strings.Contains(out, "● live") {
		t.Errorf("live pin must name the instance and its liveness:\n%s", out)
	}

	m.SetPin(PinDead, &Pin{Instance: "swift-heron"})
	out := stripANSI(m.View())
	if !strings.Contains(out, "✗ dead") {
		t.Errorf("dead pin must render distinctly from absent and live:\n%s", out)
	}
	if !strings.Contains(out, "pin dead: swift-heron") {
		t.Errorf("dead pin must appear as an attention item:\n%s", out)
	}
}

func TestDetailStatusCountsAndAttention(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	m.SetLedger("x", "", false)
	m.SetPin(PinAbsent, nil)
	m.SetMembers([]work.WorkItem{
		{Slug: "m1", Status: "active", BlockedBy: []string{"m2"}},
		{Slug: "m2", Status: "active"},
	}, map[string]bool{"m1": true, "m2": true})
	m.SetSessions([]sessionview.SessionRow{
		{RowID: "r1", Display: "m1", Type: "implement", Local: true},
		{RowID: "r2", Display: "m2", Type: "spec", NeedsInput: true, Local: true},
		{RowID: "r3", Display: "m3", Type: "worker", InFlight: true},
	})
	out := stripANSI(m.View())
	if !strings.Contains(out, "2 live") {
		t.Errorf("in-flight spawns must not count as live sessions:\n%s", out)
	}
	if !strings.Contains(out, "blocked: m1") {
		t.Errorf("a member with an active blocker is an attention item:\n%s", out)
	}
	if !strings.Contains(out, "needs input: m2") {
		t.Errorf("a needs-input session is an attention item:\n%s", out)
	}
}

func TestDetailSessionsTabJoinAndMirrorScoping(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	m.SetSessions([]sessionview.SessionRow{
		{RowID: "remote", Display: "impl-a", Type: "implement", Instance: "inst-b", Tmux: "lore-x"},
		{RowID: "local", Display: "impl-b", Type: "implement", Instance: "inst-a", Local: true},
	})

	// Mirror capture is scoped to a displayed Sessions tab.
	if _, _, ok := m.RemoteMirror(); ok {
		t.Fatal("RemoteMirror must report nothing while the Sessions tab is hidden")
	}
	m.tabHost.SetActiveID(TabSessions)
	m.syncSessionCard()
	rowID, tmuxName, ok := m.RemoteMirror()
	if !ok || rowID != "remote" || tmuxName != "lore-x" {
		t.Fatalf("remote tmux row under the cursor must be mirrorable, got %q %q %v", rowID, tmuxName, ok)
	}
	m.SetMirror("remote", []string{"pane line one"})
	if out := stripANSI(m.View()); !strings.Contains(out, "pane line one") {
		t.Errorf("captured pane rows must render in the mirror card:\n%s", out)
	}

	// j moves to the local row: no mirror, card renders it as attach-less local.
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	if _, _, ok := m.RemoteMirror(); ok {
		t.Error("a local row must not be mirrorable")
	}
}

func TestDetailTabCycle(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	order := []string{TabStatus, TabSessions, TabItems, TabLedger}
	for i, want := range order {
		if got := m.ActiveTabID(); got != want {
			t.Fatalf("tab %d: got %q want %q", i, got, want)
		}
		m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyTab})
	}
	if m.ActiveTabID() != TabStatus {
		t.Error("Tab should wrap back to Status")
	}
}

func TestDetailLedgerRendersMarkdown(t *testing.T) {
	m := sizedDetail()
	m.SetArc("arc-a")
	m.SetLedger("# Arc Ledger\n\n- row one\n", "", false)
	m.tabHost.SetActiveID(TabLedger)
	out := stripANSI(m.View())
	if !strings.Contains(out, "Arc Ledger") || !strings.Contains(out, "• row one") {
		t.Errorf("ledger tab must render the full document through the markdown pipeline:\n%s", out)
	}
}
