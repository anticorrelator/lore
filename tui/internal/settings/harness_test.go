package settings

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

// loadCapabilitiesFrameworks reads adapters/capabilities.json from a fixture
// path and returns the ordered list of framework ids. The test exists to
// guarantee PrimaryRadio enumerates exactly what the capabilities file says
// — a hardcoded list would silently drift when a new framework is added.
func loadCapabilitiesFrameworks(t *testing.T, path string) []string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read capabilities fixture: %v", err)
	}
	var doc struct {
		Frameworks map[string]struct {
			DisplayName string `json:"display_name"`
		} `json:"frameworks"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("parse capabilities fixture: %v", err)
	}
	out := make([]string, 0, len(doc.Frameworks))
	for k := range doc.Frameworks {
		out = append(out, k)
	}
	// Sort for deterministic test ordering — actual radio order in
	// production is whatever the host SettingsModel injects (which can
	// preserve capabilities.json declaration order via a streaming parser
	// or a separate enumeration pass).
	sortStrings(out)
	return out
}

func sortStrings(xs []string) {
	for i := 1; i < len(xs); i++ {
		for j := i; j > 0 && xs[j-1] > xs[j]; j-- {
			xs[j-1], xs[j] = xs[j], xs[j-1]
		}
	}
}

// writeCapabilitiesFixture writes a minimal capabilities.json with the given
// framework keyset to a temp file and returns the path. Used to assert
// PrimaryRadio enumerates from the injected fixture (no hardcoded list).
func writeCapabilitiesFixture(t *testing.T, frameworks []string) string {
	t.Helper()
	dir := t.TempDir()
	fpath := filepath.Join(dir, "capabilities.json")
	fw := make(map[string]any, len(frameworks))
	for _, id := range frameworks {
		fw[id] = map[string]any{
			"id":           id,
			"display_name": strings.Title(id),
		}
	}
	doc := map[string]any{
		"version":    "1.0",
		"frameworks": fw,
	}
	raw, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		t.Fatalf("marshal fixture: %v", err)
	}
	if err := os.WriteFile(fpath, raw, 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	return fpath
}

// ----------------------------------------------------------------------------
// PrimaryRadio.
// ----------------------------------------------------------------------------

func TestPrimaryRadio_EnumeratesFromInjectedCapabilities(t *testing.T) {
	// Custom keyset that does NOT match the production capabilities.json —
	// proves the widget reads from the injected list and has no hardcoded
	// fallback.
	fixture := []string{"alpha", "beta", "gamma", "delta"}
	path := writeCapabilitiesFixture(t, fixture)
	enumerated := loadCapabilitiesFrameworks(t, path)

	w := NewPrimaryRadio("tui_launch_framework", enumerated, nil, "alpha")

	got := w.Options()
	if len(got) != len(fixture) {
		t.Fatalf("expected %d options, got %d", len(fixture), len(got))
	}
	for _, id := range fixture {
		found := false
		for _, o := range got {
			if o == id {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("expected %q in options, got %v", id, got)
		}
	}
}

func TestPrimaryRadio_CommitOnEnter(t *testing.T) {
	w := NewPrimaryRadio("tui_launch_framework", []string{"claude-code", "opencode", "codex"}, nil, "claude-code")
	w.Focus()

	// Each movement commits instantly (changed-only contract); the second
	// press carries the final value, and Enter afterwards is a no-op.
	_, _ = dispatch(w, "right")
	_, intent := dispatch(w, "right")
	if intent == nil {
		t.Fatalf("expected commit intent, got nil")
	}
	if intent.Status != IntentCommit {
		t.Fatalf("expected IntentCommit, got %v", intent.Status)
	}
	if intent.Value != "codex" {
		t.Fatalf("expected codex, got %v", intent.Value)
	}
	if intent.DotPath != "tui_launch_framework" {
		t.Fatalf("expected dotpath tui_launch_framework, got %q", intent.DotPath)
	}
	if _, intent := dispatch(w, "enter"); intent != nil {
		t.Fatalf("enter after instant commit should emit nothing, got %+v", intent)
	}
}

func TestPrimaryRadio_MovementCommitsInstantly(t *testing.T) {
	w := NewPrimaryRadio("tui_launch_framework", []string{"claude-code", "opencode", "codex"}, nil, "claude-code")
	w.Focus()

	_, intent := dispatch(w, "right")
	if intent == nil || intent.Status != IntentCommit {
		t.Fatalf("right should commit the moved selection, got %+v", intent)
	}
	if intent.Value != "opencode" || w.current != 1 {
		t.Fatalf("expected opencode/current=1, got value=%v current=%d", intent.Value, w.current)
	}

	_, intent = dispatch(w, "left")
	if intent == nil || intent.Status != IntentCommit {
		t.Fatalf("left should commit the moved selection, got %+v", intent)
	}
	if intent.Value != "claude-code" || w.current != 0 {
		t.Fatalf("expected claude-code/current=0, got value=%v current=%d", intent.Value, w.current)
	}
}

// PrimaryRadio's closed-set rejection is structural: cursor cannot exceed
// len(options)-1, so no keystroke sequence can emit a value outside the set.
func TestPrimaryRadio_CursorBoundedToOptions(t *testing.T) {
	w := NewPrimaryRadio("tui_launch_framework", []string{"a", "b"}, nil, "a")
	w.Focus()

	// The first press commits the move; the remaining 49 clamp at the
	// boundary as no-ops. Track the last commit seen across the walk.
	var lastCommit *FieldIntent
	for i := 0; i < 50; i++ {
		if _, intent := dispatch(w, "right"); intent != nil {
			lastCommit = intent
		}
	}
	if lastCommit == nil || lastCommit.Status != IntentCommit {
		t.Fatalf("expected commit during right walk, got %+v", lastCommit)
	}
	if lastCommit.Value != "b" || w.current != 1 {
		t.Fatalf("cursor leaked past last option: got value=%v current=%d", lastCommit.Value, w.current)
	}
	lastCommit = nil
	for i := 0; i < 50; i++ {
		if _, intent := dispatch(w, "left"); intent != nil {
			lastCommit = intent
		}
	}
	if lastCommit == nil || lastCommit.Value != "a" || w.current != 0 {
		t.Fatalf("cursor leaked past first option: got %+v current=%d", lastCommit, w.current)
	}
}

// PrimaryRadio must refuse keystrokes that don't correspond to navigation /
// commit gestures. Typing free-form characters does NOT mutate the cursor or
// emit any intent — closed-set is enforced both at the boundary and the
// keystroke surface.
func TestPrimaryRadio_RejectsNonNavigationKeys(t *testing.T) {
	w := NewPrimaryRadio("tui_launch_framework", []string{"claude-code", "opencode"}, nil, "claude-code")
	w.Focus()

	for _, k := range []string{"x", "z", "1", "/"} {
		_, intent := dispatch(w, k)
		if intent != nil {
			t.Fatalf("expected no intent on key %q, got %+v", k, intent)
		}
	}
	if w.cursor != 0 {
		t.Fatalf("cursor must not move on non-navigation keys, got %d", w.cursor)
	}
}

func TestPrimaryRadio_RendersCurrentSelectionMarker(t *testing.T) {
	w := NewPrimaryRadio("tui_launch_framework", []string{"claude-code", "opencode", "codex"}, nil, "opencode")
	view := w.View()
	if !strings.Contains(view, "(•) opencode") {
		t.Fatalf("expected selection marker on opencode, got: %s", view)
	}
	for _, other := range []string{"claude-code", "codex"} {
		if !strings.Contains(view, "( ) "+other) {
			t.Fatalf("expected unselected marker on %s, got: %s", other, view)
		}
	}
}

// ----------------------------------------------------------------------------
// HarnessBlockPanel — D9 absent / explicit-empty / explicit non-empty.
// ----------------------------------------------------------------------------

// makeArgsWidget returns a ListEditor configured for harness args.
func makeArgsWidget(dotPath string, current []string) FieldWidget {
	return NewListEditor(dotPath, "args", current, nil, 0, false, true, false)
}

// makeRolesWidget returns an OpenKeysetKVEditor configured for a roles
// overlay (string -> string capability id).
func makeRolesWidget(dotPath string, current map[string]string) FieldWidget {
	return NewOpenKeysetKVEditor(dotPath, "roles", current, nil, nil, true, true)
}

// TestHarnessBlockPanel_AbsentOverlayTabThroughDoesNotEmitCommit is the
// core D9 invariant: tabbing through a panel where roles and ceremonies are
// absent (nil widgets) must produce zero IntentCommit messages — regardless
// of how many tab gestures the user issues.
func TestHarnessBlockPanel_AbsentOverlayTabThroughDoesNotEmitCommit(t *testing.T) {
	args := makeArgsWidget("harnesses.claude-code.args", []string{"--flag"})
	panel := NewHarnessBlockPanel("claude-code", true, nil, args, nil, nil, HarnessEffective{
		Roles:      map[string]string{"lead": "opus"},
		Ceremonies: map[string][]string{"plan-review": {"sharp-edges"}},
	})
	panel.Focus()

	for i := 0; i < 10; i++ {
		_, intent := dispatch(panel, "tab")
		if intent != nil && intent.Status == IntentCommit {
			t.Fatalf("tab through absent overlay emitted IntentCommit: %+v", intent)
		}
	}
}

// TestHarnessBlockPanel_AbsentOverlayRendersInherited proves the absent state
// is visually distinguishable per D9.
func TestHarnessBlockPanel_AbsentOverlayRendersInherited(t *testing.T) {
	args := makeArgsWidget("harnesses.claude-code.args", []string{})
	panel := NewHarnessBlockPanel("claude-code", true, nil, args, nil, nil, HarnessEffective{
		Roles: map[string]string{"lead": "opus"},
	})

	view := panel.View()
	if !strings.Contains(view, "(inherited)") {
		t.Fatalf("expected (inherited) marker for absent overlay, got:\n%s", view)
	}
	if !strings.Contains(view, "lead=opus") {
		t.Fatalf("expected effective roles to render alongside (inherited), got:\n%s", view)
	}
}

// TestHarnessBlockPanel_ExplicitEmptyDistinctFromAbsent verifies the
// three-way distinction D9 requires: passing a non-nil but empty roles
// widget renders differently from passing nil.
func TestHarnessBlockPanel_ExplicitEmptyDistinctFromAbsent(t *testing.T) {
	args := makeArgsWidget("harnesses.claude-code.args", []string{})

	// Absent — nil widget.
	absentPanel := NewHarnessBlockPanel("claude-code", true, nil, args, nil, nil, HarnessEffective{})
	absentView := absentPanel.View()

	// Explicit-empty — non-nil widget, empty draft.
	emptyRoles := makeRolesWidget("harnesses.claude-code.roles", map[string]string{})
	args2 := makeArgsWidget("harnesses.claude-code.args", []string{})
	emptyPanel := NewHarnessBlockPanel("claude-code", true, nil, args2, emptyRoles, nil, HarnessEffective{})
	emptyView := emptyPanel.View()

	if absentView == emptyView {
		t.Fatalf("absent and explicit-empty must render differently. View:\n%s", absentView)
	}
	if !strings.Contains(absentView, "(inherited)") {
		t.Fatalf("expected absent view to contain (inherited): %s", absentView)
	}
	// Explicit-empty should NOT show (inherited) for the override column —
	// the widget is materialized, just empty.
	rolesSection := extractOverlaySection(emptyView, "roles:")
	if strings.Contains(rolesSection, "override:  (inherited)") {
		t.Fatalf("explicit-empty roles must not show (inherited) in override column.\nroles section:\n%s\nfull view:\n%s", rolesSection, emptyView)
	}
}

// extractOverlaySection returns the lines of view from "<label>" through the
// next overlay header or end-of-view. Used to inspect a single overlay's
// rendered output without conflation across overlays.
func extractOverlaySection(view, label string) string {
	lines := strings.Split(view, "\n")
	var (
		out    []string
		inside bool
	)
	for _, line := range lines {
		if strings.Contains(line, label) {
			inside = true
		} else if inside && strings.HasPrefix(strings.TrimSpace(line), "ceremonies:") && label != "ceremonies:" {
			break
		}
		if inside {
			out = append(out, line)
		}
	}
	return strings.Join(out, "\n")
}

// TestHarnessBlockPanel_ExplicitNonEmptyRendersOverride proves the third
// state: a populated override displays the override column with content
// (not "(inherited)"), and effective alongside.
func TestHarnessBlockPanel_ExplicitNonEmptyRendersOverride(t *testing.T) {
	args := makeArgsWidget("harnesses.claude-code.args", []string{})
	roles := makeRolesWidget("harnesses.claude-code.roles", map[string]string{"lead": "sonnet"})
	panel := NewHarnessBlockPanel("claude-code", true, nil, args, roles, nil, HarnessEffective{
		Roles: map[string]string{"lead": "sonnet"},
	})

	view := panel.View()
	rolesSection := extractOverlaySection(view, "roles:")
	if strings.Contains(rolesSection, "override:  (inherited)") {
		t.Fatalf("explicit non-empty must not show (inherited) for override.\nroles section:\n%s\nfull view:\n%s", rolesSection, view)
	}
	if !strings.Contains(view, "lead = sonnet") {
		t.Fatalf("expected harness-local roles to include lead=sonnet, got:\n%s", view)
	}
}

// TestHarnessBlockPanel_UnsetGestureOnExplicitOverrideEmitsIntentUnset
// verifies the D9 unset flow: pressing 'u' on an explicit override emits
// IntentUnset with the correct dot path so SettingsModel can route to
// SettingsDelete.
func TestHarnessBlockPanel_UnsetGestureOnExplicitOverrideEmitsIntentUnset(t *testing.T) {
	args := makeArgsWidget("harnesses.claude-code.args", []string{})
	// allowUnset=true is required for the unset gesture; the OpenKeysetKVEditor
	// constructor accepts that as the trailing param.
	roles := NewOpenKeysetKVEditor("harnesses.claude-code.roles", "roles", map[string]string{"lead": "sonnet"}, nil, nil, true, true)
	panel := NewHarnessBlockPanel("claude-code", true, nil, args, roles, nil, HarnessEffective{})
	panel.Focus()
	_, _ = dispatch(panel, "enter")

	// Tab order is enabled → args → roles. Two tabs land on roles.
	_, _ = dispatch(panel, "tab")
	_, _ = dispatch(panel, "tab")

	// Now on the roles widget; press 'u' to unset.
	_, intent := dispatch(panel, "u")
	if intent == nil {
		t.Fatalf("expected intent from unset gesture, got nil")
	}
	if intent.Status != IntentUnset {
		t.Fatalf("expected IntentUnset, got %v", intent.Status)
	}
	if intent.DotPath != "harnesses.claude-code.roles" {
		t.Fatalf("expected dotpath harnesses.claude-code.roles, got %q", intent.DotPath)
	}
}

// TestHarnessBlockPanel_UnsetGestureOnAbsentOverlayCannotFire — there is no
// child widget to dispatch to, so 'u' is a no-op. The overlay cannot be
// "unset" because it isn't set.
func TestHarnessBlockPanel_UnsetGestureOnAbsentOverlayCannotFire(t *testing.T) {
	args := makeArgsWidget("harnesses.claude-code.args", []string{})
	panel := NewHarnessBlockPanel("claude-code", true, nil, args, nil, nil, HarnessEffective{})
	panel.Focus()

	for _, k := range []string{"tab", "u", "tab", "u"} {
		_, intent := dispatch(panel, k)
		if intent != nil && intent.Status == IntentUnset {
			t.Fatalf("absent overlay must not produce IntentUnset; got %+v", intent)
		}
	}
}

// TestHarnessBlockPanel_TabCyclesOnlyMaterializedChildren proves cursor never
// lands on absent overlays — the user cannot accidentally tab into a
// non-widget and trigger a nil-dispatch panic. The per-harness enabled toggle
// is always materialized (constructed by NewHarnessBlockPanel), so it occupies
// logical slot 0; args sits at slot 1, and absent overlays compress the rest.
func TestHarnessBlockPanel_TabCyclesOnlyMaterializedChildren(t *testing.T) {
	args := makeArgsWidget("harnesses.claude-code.args", []string{})
	// Only enabled toggle (always present) + args + ceremonies; roles absent.
	cer := NewOpenKeysetKVEditor("harnesses.claude-code.ceremonies", "ceremonies", map[string]string{"plan-review": "sharp-edges"}, nil, nil, true, true)
	panel := NewHarnessBlockPanel("claude-code", true, nil, args, nil, cer, HarnessEffective{})
	panel.Focus()

	if c, _ := panel.childAt(0); c == nil {
		t.Fatalf("expected enabled toggle at logical 0, got nil")
	} else if _, ok := c.(*harnessEnabledToggle); !ok {
		t.Fatalf("expected *harnessEnabledToggle at logical 0, got %T", c)
	}
	if c, _ := panel.childAt(1); c != args {
		t.Fatalf("expected args at logical 1, got %T", c)
	}
	if c, _ := panel.childAt(2); c != cer {
		t.Fatalf("expected ceremonies at logical 2 (roles skipped), got %T", c)
	}
	if c, _ := panel.childAt(3); c != nil {
		t.Fatalf("expected nothing at logical 3, got %T", c)
	}
}

func TestHarnessEnabledToggle_DoesNotFlipWhenToggleSuppressed(t *testing.T) {
	toggle := func(string, bool) tea.Cmd { return nil }
	w := newHarnessEnabledToggle("claude-code", true, toggle)
	w.Focus()

	_, cmd, intent := w.Update(keyMsg(" "))
	if cmd != nil {
		t.Fatalf("suppressed toggle should not return a command")
	}
	if intent != nil {
		t.Fatalf("enabled toggle should not emit field intents, got %+v", intent)
	}
	if !w.current {
		t.Fatalf("visible state flipped even though the model suppressed the toggle")
	}
}

// TestHarnessBlockPanel_EffectiveColumnRendersAllThreeStates makes the
// absent / explicit-empty / explicit non-empty distinction load-bearing on
// the effective-column rendering: absent or explicit-empty both can show
// effective state inherited from the parent.
func TestHarnessBlockPanel_EffectiveColumnRendersAllThreeStates(t *testing.T) {
	args := makeArgsWidget("harnesses.claude-code.args", []string{})

	// Case 1: absent override + populated effective from inheritance.
	absent := NewHarnessBlockPanel("claude-code", true, nil, args, nil, nil, HarnessEffective{
		Roles: map[string]string{"lead": "opus"},
	})
	if !strings.Contains(absent.View(), "lead=opus") {
		t.Fatalf("absent overlay must surface effective inherited value")
	}

	// Case 2: explicit-empty harness-local roles.
	emptyRoles := makeRolesWidget("harnesses.claude-code.roles", map[string]string{})
	args2 := makeArgsWidget("harnesses.claude-code.args", []string{})
	explicit := NewHarnessBlockPanel("claude-code", true, nil, args2, emptyRoles, nil, HarnessEffective{})
	view := stripANSI(explicit.View())
	if !strings.Contains(view, "roles: (0 entries)") {
		t.Fatalf("explicit-empty harness-local roles must show an empty editor, got:\n%s", view)
	}

	// Case 3: explicit non-empty harness-local roles.
	roles3 := makeRolesWidget("harnesses.claude-code.roles", map[string]string{"lead": "haiku"})
	args3 := makeArgsWidget("harnesses.claude-code.args", []string{})
	override := NewHarnessBlockPanel("claude-code", true, nil, args3, roles3, nil, HarnessEffective{
		Roles: map[string]string{"lead": "haiku"},
	})
	if !strings.Contains(override.View(), "lead = haiku") {
		t.Fatalf("explicit non-empty harness-local roles must surface in the editor")
	}
}

// TestHarnessBlockPanel_TabThroughAbsentOverlayDoesNotMaterializeWidget — the
// load-bearing safety property: after any number of tabs through a panel
// where roles is absent, the panel's roles field is still nil. Auto-
// materialization is the explicit anti-pattern D9 prevents.
func TestHarnessBlockPanel_TabThroughAbsentOverlayDoesNotMaterializeWidget(t *testing.T) {
	args := makeArgsWidget("harnesses.claude-code.args", []string{})
	panel := NewHarnessBlockPanel("claude-code", true, nil, args, nil, nil, HarnessEffective{})
	panel.Focus()

	for i := 0; i < 5; i++ {
		_, _ = dispatch(panel, "tab")
		_, _ = dispatch(panel, "shift+tab")
	}
	if panel.roles != nil {
		t.Fatalf("absent overlay materialized to a widget after tab-through")
	}
	if panel.ceremonies != nil {
		t.Fatalf("absent ceremonies materialized to a widget after tab-through")
	}
}

// ----------------------------------------------------------------------------
// NavRuneConsumer delegates to the active inner child so the panel only
// claims j/k while a child is *actively typing* (TextInput, or list/kv
// editors mid-draft). In every other state — including an unopened panel or
// a selected ListEditor/OpenKeysetKVEditor — the panel releases j/k so the
// model can run settings navigation.
// ----------------------------------------------------------------------------

// TestHarnessBlockPanel_ConsumesNavRunes_DelegatesToActiveChild proves the
// container delegates to its current child and that the delegation respects
// the child's editing-vs-navigating mode. Cursor on enabled toggle → no
// claim. Cursor on selected args ListEditor → no claim. Cursor on args
// ListEditor mid-append → claim (j/k typed into the buffer).
func TestHarnessBlockPanel_ConsumesNavRunes_DelegatesToActiveChild(t *testing.T) {
	args := makeArgsWidget("harnesses.claude-code.args", []string{"a", "b"})
	panel := NewHarnessBlockPanel("claude-code", true, nil, args, nil, nil, HarnessEffective{})
	panel.Focus()

	// The selected but unopened panel releases nav runes to top-level movement.
	if panel.ConsumesNavRunes() {
		t.Fatalf("unentered panel must not claim nav runes")
	}
	_, _ = dispatch(panel, "enter")

	// Cursor 0 = enabled toggle — never claims nav runes.
	if panel.ConsumesNavRunes() {
		t.Fatalf("with cursor on enabled toggle, panel must not claim nav runes")
	}
	_, _ = dispatch(panel, "tab") // advance to args (ListEditor in nav mode)
	if panel.ConsumesNavRunes() {
		t.Fatalf("with cursor on selected args ListEditor, panel must not claim nav runes")
	}

	// Enter append mode on the ListEditor — now the child is typing, so the
	// panel must claim nav runes so j/k get typed into the buffer.
	_, _ = dispatch(panel, "enter")
	_, _ = dispatch(panel, "a")
	if !panel.ConsumesNavRunes() {
		t.Fatalf("with cursor on args ListEditor mid-append, panel must claim nav runes (j/k must reach the append buffer)")
	}
}

// TestHarnessBlockPanel_ConsumesNavRunes_FalseWhenEmpty defends against the
// degenerate case (no children) used by tests and forward-compat.
func TestHarnessBlockPanel_ConsumesNavRunes_FalseWhenEmpty(t *testing.T) {
	// Empty panel — no enabled toggle (constructed with nil callback that
	// still produces a toggle), no args. Use a panel constructed with
	// only a placeholder args widget then drop it.
	panel := &HarnessBlockPanel{}
	if panel.ConsumesNavRunes() {
		t.Fatalf("empty panel must not claim nav runes")
	}
}

// ----------------------------------------------------------------------------
// Bug 2B: InnerFocusYRange must report the inner cursor's y-range within the
// panel's own View() so the host viewport scrolls to the active child rather
// than pinning the panel's bottom on tall harness blocks.
// ----------------------------------------------------------------------------

// TestHarnessBlockPanel_InnerFocusYRange_TracksCursor proves the reported
// range moves as the user tabs through inner children.
func TestHarnessBlockPanel_InnerFocusYRange_TracksCursor(t *testing.T) {
	args := makeArgsWidget("harnesses.claude-code.args", []string{"--alpha"})
	roles := NewOpenKeysetKVEditor("harnesses.claude-code.roles", "roles", map[string]string{"lead": "opus"}, nil, nil, true, true)
	panel := NewHarnessBlockPanel("claude-code", true, nil, args, roles, nil, HarnessEffective{})
	panel.Focus()
	_, _ = dispatch(panel, "enter")

	top0, bot0 := panel.InnerFocusYRange()
	if top0 < 0 || bot0 < top0 {
		t.Fatalf("cursor 0 (enabled): expected valid range, got top=%d bot=%d", top0, bot0)
	}

	_, _ = dispatch(panel, "tab") // advance to args
	top1, bot1 := panel.InnerFocusYRange()
	if top1 < 0 || bot1 < top1 {
		t.Fatalf("cursor 1 (args): expected valid range, got top=%d bot=%d", top1, bot1)
	}
	if !(top1 > top0) {
		t.Fatalf("expected args range to be below enabled-toggle range; got enabled top=%d args top=%d", top0, top1)
	}

	_, _ = dispatch(panel, "tab") // advance to roles
	top2, bot2 := panel.InnerFocusYRange()
	if top2 < 0 || bot2 < top2 {
		t.Fatalf("cursor 2 (roles): expected valid range, got top=%d bot=%d", top2, bot2)
	}
	if !(top2 > top1) {
		t.Fatalf("expected roles range to be below args range; got args top=%d roles top=%d", top1, top2)
	}
}

// TestHarnessBlockPanel_InnerFocusYRange_NotFocused returns (-1,-1) when the
// panel itself is not focused — the model uses this signal as a fall-back to
// the slot-wide range. Without the negative return, an unfocused panel could
// short-circuit the scroll math with stale offsets.
func TestHarnessBlockPanel_InnerFocusYRange_NotFocused(t *testing.T) {
	args := makeArgsWidget("harnesses.claude-code.args", []string{})
	panel := NewHarnessBlockPanel("claude-code", true, nil, args, nil, nil, HarnessEffective{})
	// Note: not Focus()'d.
	top, bot := panel.InnerFocusYRange()
	if top != -1 || bot != -1 {
		t.Fatalf("unfocused panel must return (-1,-1); got (%d, %d)", top, bot)
	}
}

// TestHarnessBlockPanel_InnerFocusYRange_OffsetsAlignWithViewLines proves the
// reported range matches the line offsets in the panel's actual View()
// output — without this guarantee, the model's viewport math would scroll
// to a y-coordinate that doesn't correspond to a rendered cursor row.
func TestHarnessBlockPanel_InnerFocusYRange_OffsetsAlignWithViewLines(t *testing.T) {
	args := makeArgsWidget("harnesses.claude-code.args", []string{"--alpha"})
	panel := NewHarnessBlockPanel("claude-code", true, nil, args, nil, nil, HarnessEffective{})
	panel.Focus()
	_, _ = dispatch(panel, "enter")
	_, _ = dispatch(panel, "tab") // advance to args slot

	top, bot := panel.InnerFocusYRange()
	if top < 0 {
		t.Fatalf("expected valid range for args slot, got top=%d", top)
	}

	view := panel.View()
	lines := strings.Split(view, "\n")
	if top >= len(lines) {
		t.Fatalf("reported top=%d exceeds view line count %d", top, len(lines))
	}
	if bot >= len(lines) {
		t.Fatalf("reported bot=%d exceeds view line count %d", bot, len(lines))
	}
	// The args row must contain the args label somewhere within [top,bot].
	found := false
	for i := top; i <= bot; i++ {
		if strings.Contains(lines[i], "args") {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected an 'args'-bearing line in [top=%d, bot=%d]; lines=%q", top, bot, lines[top:bot+1])
	}
}

// ----------------------------------------------------------------------------
// Bug 3A regression: when overlay widgets are passed in (non-nil),
// HarnessBlockPanel adds them to the navigable child list and renders their
// View() in the override column.
// ----------------------------------------------------------------------------

// TestHarnessBlockPanel_NonNilOverlaysAreNavigable proves that providing a
// real overlay widget makes it part of the tab-cycle (Phase 1 wired only
// nil overlays; the user-reported bug 3A asked for editable overlays).
func TestHarnessBlockPanel_NonNilOverlaysAreNavigable(t *testing.T) {
	args := makeArgsWidget("harnesses.claude-code.args", []string{})
	roles := NewOpenKeysetKVEditor("harnesses.claude-code.roles", "roles", map[string]string{"lead": "opus"}, nil, nil, true, true)
	cer := NewOpenKeysetKVEditor("harnesses.claude-code.ceremonies", "ceremonies", map[string]string{"plan-review": "sharp-edges"}, nil, nil, true, true)
	panel := NewHarnessBlockPanel("claude-code", true, nil, args, roles, cer, HarnessEffective{})
	panel.Focus()

	// Slot order with everything materialized: enabled (0), args (1), roles
	// (2), ceremonies (3).
	if c, _ := panel.childAt(0); c == nil {
		t.Fatalf("expected enabled at slot 0")
	}
	if c, _ := panel.childAt(1); c != args {
		t.Fatalf("expected args at slot 1; got %T", c)
	}
	if c, _ := panel.childAt(2); c != roles {
		t.Fatalf("expected roles at slot 2; got %T", c)
	}
	if c, _ := panel.childAt(3); c != cer {
		t.Fatalf("expected ceremonies at slot 3; got %T", c)
	}
	if c, _ := panel.childAt(4); c != nil {
		t.Fatalf("expected nothing past slot 3; got %T", c)
	}
}

func TestPrimaryRadio_NoOpPressesEmitNoCommit(t *testing.T) {
	w := NewPrimaryRadio("tui_launch_framework", []string{"claude-code", "opencode", "codex"}, nil, "claude-code")
	w.Focus()

	if _, intent := dispatch(w, "left"); intent != nil {
		t.Fatalf("boundary left on committed option should emit nothing, got %+v", intent)
	}
	if _, intent := dispatch(w, "enter"); intent != nil {
		t.Fatalf("enter on committed option should emit nothing, got %+v", intent)
	}
	_, _ = dispatch(w, "right")
	_, _ = dispatch(w, "right")
	if _, intent := dispatch(w, "right"); intent != nil {
		t.Fatalf("boundary right on committed option should emit nothing, got %+v", intent)
	}
}
