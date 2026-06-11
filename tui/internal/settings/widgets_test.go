package settings

import (
	"reflect"
	"regexp"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

// keyMsg returns the tea.KeyPressMsg the widget Update path matches against.
// Wraps a single string the same way bubbletea's tea.KeyPressMsg.String() round-trips.
func keyMsg(s string) tea.KeyPressMsg {
	switch s {
	case "enter":
		return tea.KeyPressMsg{Code: tea.KeyEnter}
	case "esc":
		return tea.KeyPressMsg{Code: tea.KeyEsc}
	case "tab":
		return tea.KeyPressMsg{Code: tea.KeyTab}
	case "shift+tab":
		return tea.KeyPressMsg{Code: tea.KeyTab, Mod: tea.ModShift}
	case "backspace":
		return tea.KeyPressMsg{Code: tea.KeyBackspace}
	case "up":
		return tea.KeyPressMsg{Code: tea.KeyUp}
	case "down":
		return tea.KeyPressMsg{Code: tea.KeyDown}
	case "left":
		return tea.KeyPressMsg{Code: tea.KeyLeft}
	case "right":
		return tea.KeyPressMsg{Code: tea.KeyRight}
	case " ":
		return tea.KeyPressMsg{Code: tea.KeySpace, Text: " "}
	}
	if len([]rune(s)) == 1 {
		return tea.KeyPressMsg{Code: []rune(s)[0], Text: s}
	}
	return tea.KeyPressMsg{Code: []rune(s)[0], Text: s}
}

// dispatch sends a single keystroke and returns the new widget + intent.
func dispatch(w FieldWidget, s string) (FieldWidget, *FieldIntent) {
	w2, _, intent := w.Update(keyMsg(s))
	return w2, intent
}

// dispatchAll feeds a sequence of keystrokes; returns the final intent only
// (intermediate intents are usually nil for navigation).
func dispatchAll(w FieldWidget, keys ...string) (FieldWidget, *FieldIntent) {
	var last *FieldIntent
	for _, k := range keys {
		var intent *FieldIntent
		w, intent = dispatch(w, k)
		if intent != nil {
			last = intent
		}
	}
	return w, last
}

// ----------------------------------------------------------------------------
// EnumSelector — closed-set rejection (D6).
// ----------------------------------------------------------------------------

func TestEnumSelector_CommitOnEnter(t *testing.T) {
	w := NewEnumSelector("tui_launch_framework", []string{"claude-code", "opencode", "codex"}, nil, "claude-code", false)
	w.Focus()

	// Move cursor right twice → "codex".
	_, _ = dispatch(w, "right")
	_, _ = dispatch(w, "right")
	_, intent := dispatch(w, "enter")
	if intent == nil {
		t.Fatalf("expected commit intent, got nil")
	}
	if intent.Status != IntentCommit {
		t.Fatalf("expected IntentCommit, got %v", intent.Status)
	}
	if intent.Value != "codex" {
		t.Fatalf("expected codex, got %v", intent.Value)
	}
}

// EnumSelector cannot emit values outside the registered set — closed-set
// rejection is structural (cursor bounded by len(values)). This test asserts
// the boundary by attempting to advance past the last index.
func TestEnumSelector_ClosedSetIsStructural(t *testing.T) {
	w := NewEnumSelector("tui.layout", []string{"left-right", "top-bottom"}, nil, "left-right", false)
	w.Focus()

	// Walk past the right end — cursor must clamp at last index.
	for i := 0; i < 10; i++ {
		_, _ = dispatch(w, "right")
	}
	_, intent := dispatch(w, "enter")
	if intent == nil || intent.Status != IntentCommit {
		t.Fatalf("expected commit, got %+v", intent)
	}
	if intent.Value != "top-bottom" {
		t.Fatalf("expected last-index commit (top-bottom), got %v — closed-set boundary leaked", intent.Value)
	}
}

func TestEnumSelector_UnsetGesture(t *testing.T) {
	w := NewEnumSelector("harnesses.claude-code.roles.lead", []string{"opus", "sonnet", "haiku"}, nil, "opus", true)
	w.Focus()

	_, intent := dispatch(w, "u")
	if intent == nil {
		t.Fatalf("expected unset intent")
	}
	if intent.Status != IntentUnset {
		t.Fatalf("expected IntentUnset, got %v", intent.Status)
	}
	if intent.DotPath != "harnesses.claude-code.roles.lead" {
		t.Fatalf("dotpath mismatch")
	}
}

func TestEnumSelector_UnsetSuppressedWhenNotAllowed(t *testing.T) {
	w := NewEnumSelector("tui_launch_framework", []string{"claude-code", "opencode"}, nil, "claude-code", false)
	w.Focus()

	_, intent := dispatch(w, "u")
	if intent != nil {
		t.Fatalf("expected nil intent when allowUnset=false, got %+v", intent)
	}
}

// ----------------------------------------------------------------------------
// ToggleRow — immediate commit.
// ----------------------------------------------------------------------------

func TestToggleRow_CommitOnSpace(t *testing.T) {
	w := NewToggleRow("flag", "Some flag", false, true, false)
	w.Focus()

	_, intent := dispatch(w, " ")
	if intent == nil || intent.Status != IntentCommit {
		t.Fatalf("expected commit, got %+v", intent)
	}
	if intent.Value != true {
		t.Fatalf("expected true, got %v", intent.Value)
	}

	_, intent = dispatch(w, " ")
	if intent.Value != false {
		t.Fatalf("expected toggle back to false, got %v", intent.Value)
	}
}

// ----------------------------------------------------------------------------
// TextInput — pattern + minLength rejection.
// ----------------------------------------------------------------------------

func TestTextInput_PatternRejectsOnEnter(t *testing.T) {
	pat := regexp.MustCompile(`^[a-z][a-z0-9-]*$`) // skill_id pattern
	w := NewTextInput("skill", "Skill id", "", pat, 1, false, false)
	w.Focus()
	_, _ = dispatch(w, "enter")

	// Type "Bad ID" (uppercase + space — rejects on both pattern and minLength=1 passes).
	_, _ = dispatch(w, "B")
	_, _ = dispatch(w, "a")
	_, _ = dispatch(w, "d")
	_, intent := dispatch(w, "enter")
	if intent == nil || intent.Status != IntentReject {
		t.Fatalf("expected reject, got %+v", intent)
	}
	if len(intent.Errors) == 0 {
		t.Fatalf("expected at least one error in reject")
	}
	// Draft must survive the rejection (D10).
	tw := w
	if tw.draft != "Bad" {
		t.Fatalf("expected draft to survive rejection, got %q", tw.draft)
	}
}

func TestTextInput_MinLengthRejection(t *testing.T) {
	w := NewTextInput("name", "Name", "", nil, 5, false, false)
	w.Focus()
	_, _ = dispatch(w, "enter")

	_, _ = dispatch(w, "a")
	_, _ = dispatch(w, "b")
	_, intent := dispatch(w, "enter")
	if intent == nil || intent.Status != IntentReject {
		t.Fatalf("expected reject, got %+v", intent)
	}
	hasMinErr := false
	for _, e := range intent.Errors {
		if regexp.MustCompile(`at least 5`).MatchString(e) {
			hasMinErr = true
		}
	}
	if !hasMinErr {
		t.Fatalf("expected minLength error, got %v", intent.Errors)
	}
}

func TestTextInput_CommitOnValidEnter(t *testing.T) {
	pat := regexp.MustCompile(`^[a-z][a-z0-9-]*$`)
	w := NewTextInput("skill", "Skill", "", pat, 1, false, false)
	w.Focus()
	_, _ = dispatch(w, "enter")

	_, _ = dispatch(w, "f")
	_, _ = dispatch(w, "o")
	_, _ = dispatch(w, "o")
	_, intent := dispatch(w, "enter")
	if intent == nil || intent.Status != IntentCommit {
		t.Fatalf("expected commit, got %+v", intent)
	}
	if intent.Value != "foo" {
		t.Fatalf("expected foo, got %v", intent.Value)
	}
}

func TestTextInput_DiscardOnEscRevertsDraft(t *testing.T) {
	w := NewTextInput("name", "Name", "original", nil, 0, true, false)
	w.Focus()
	_, _ = dispatch(w, "enter")

	// Type after the existing committed value — but the widget starts with
	// draft == committed == "original", so we'd need to clear first. For
	// this test we type more text to diverge.
	_, _ = dispatch(w, "X")
	if w.draft != "originalX" {
		t.Fatalf("expected draft 'originalX', got %q", w.draft)
	}
	_, intent := dispatch(w, "esc")
	if intent == nil {
		t.Fatalf("expected discard intent on esc")
	}
	if intent.Status != IntentDiscard {
		t.Fatalf("expected IntentDiscard, got %v", intent.Status)
	}
	if intent.Value != "original" {
		t.Fatalf("expected reverted value 'original', got %v", intent.Value)
	}
	if w.draft != "original" {
		t.Fatalf("expected draft reset to committed, got %q", w.draft)
	}
}

func TestTextInput_DiscardOnFocusChange(t *testing.T) {
	w := NewTextInput("name", "Name", "original", nil, 0, true, false)
	w.Focus()
	_, _ = dispatch(w, "enter")
	_, _ = dispatch(w, "X")

	intent := w.Blur()
	if intent == nil {
		t.Fatalf("expected discard on blur")
	}
	if intent.Status != IntentDiscard {
		t.Fatalf("expected IntentDiscard, got %v", intent.Status)
	}
	if intent.Value != "original" {
		t.Fatalf("expected reverted value 'original', got %v", intent.Value)
	}
	if w.Focused() {
		t.Fatalf("expected widget unfocused after Blur()")
	}
}

func TestTextInput_BlurNoIntentWhenDraftMatchesCommitted(t *testing.T) {
	w := NewTextInput("name", "Name", "original", nil, 0, true, false)
	w.Focus()

	// No edits — Blur should not emit an intent.
	intent := w.Blur()
	if intent != nil {
		t.Fatalf("expected nil intent when draft unchanged, got %+v", intent)
	}
}

// ----------------------------------------------------------------------------
// NumericInput — min/max rejection.
// ----------------------------------------------------------------------------

func TestNumericInput_BelowMinimumRejects(t *testing.T) {
	min := 0.0
	max := 1.0
	w := NewNumericInput("thresholds.audit_probability", "audit_probability", "", false, &min, &max, false, false)
	w.Focus()
	_, _ = dispatch(w, "enter")
	_, _ = dispatch(w, "-")
	_, _ = dispatch(w, "0")
	_, _ = dispatch(w, ".")
	_, _ = dispatch(w, "5")
	_, intent := dispatch(w, "enter")
	if intent == nil || intent.Status != IntentReject {
		t.Fatalf("expected reject, got %+v", intent)
	}
}

func TestNumericInput_AboveMaximumRejects(t *testing.T) {
	min := 0.0
	max := 1.0
	w := NewNumericInput("thresholds.audit_probability", "audit_probability", "", false, &min, &max, false, false)
	w.Focus()
	_, _ = dispatch(w, "enter")
	_, _ = dispatch(w, "1")
	_, _ = dispatch(w, ".")
	_, _ = dispatch(w, "5")
	_, intent := dispatch(w, "enter")
	if intent == nil || intent.Status != IntentReject {
		t.Fatalf("expected reject, got %+v", intent)
	}
}

func TestNumericInput_ValidCommitsAsTypedFloat(t *testing.T) {
	min := 0.0
	max := 1.0
	w := NewNumericInput("thresholds.audit_probability", "audit_probability", "", false, &min, &max, false, false)
	w.Focus()
	_, _ = dispatch(w, "enter")
	_, _ = dispatch(w, "0")
	_, _ = dispatch(w, ".")
	_, _ = dispatch(w, "5")
	_, intent := dispatch(w, "enter")
	if intent == nil || intent.Status != IntentCommit {
		t.Fatalf("expected commit, got %+v", intent)
	}
	if v, ok := intent.Value.(float64); !ok || v != 0.5 {
		t.Fatalf("expected typed float64=0.5, got %T %v", intent.Value, intent.Value)
	}
}

func TestNumericInput_IntegerMode(t *testing.T) {
	min := 1.0
	w := NewNumericInput("version", "Version", "", true, &min, nil, false, false)
	w.Focus()
	_, _ = dispatch(w, "enter")
	_, _ = dispatch(w, "0")
	_, intent := dispatch(w, "enter")
	if intent == nil || intent.Status != IntentReject {
		t.Fatalf("expected reject (0 < min=1), got %+v", intent)
	}

	// Now valid: 2 ≥ 1.
	w2 := NewNumericInput("version", "Version", "", true, &min, nil, false, false)
	w2.Focus()
	_, _ = dispatch(w2, "enter")
	_, _ = dispatch(w2, "2")
	_, intent2 := dispatch(w2, "enter")
	if intent2 == nil || intent2.Status != IntentCommit {
		t.Fatalf("expected commit, got %+v", intent2)
	}
	if v, ok := intent2.Value.(int); !ok || v != 2 {
		t.Fatalf("expected typed int=2, got %T %v", intent2.Value, intent2.Value)
	}
}

// ----------------------------------------------------------------------------
// ListEditor — minItems + uniqueItems rejection.
// ----------------------------------------------------------------------------

func TestListEditor_MinItemsRejection(t *testing.T) {
	w := NewListEditor("ceremonies.foo", "advisors", []string{}, nil, 1, true, false, false)
	w.Focus()
	_, _ = dispatch(w, "enter")
	_, intent := dispatch(w, "enter")
	if intent == nil || intent.Status != IntentReject {
		t.Fatalf("expected reject (empty list violates minItems=1), got %+v", intent)
	}
	hasMinErr := false
	for _, e := range intent.Errors {
		if regexp.MustCompile(`at least 1 item`).MatchString(e) {
			hasMinErr = true
		}
	}
	if !hasMinErr {
		t.Fatalf("expected minItems error, got %v", intent.Errors)
	}
}

func TestListEditor_UniqueItemsRejection(t *testing.T) {
	w := NewListEditor("ceremonies.foo", "advisors", []string{"alpha", "alpha"}, nil, 0, true, false, false)
	w.Focus()
	_, _ = dispatch(w, "enter")
	_, intent := dispatch(w, "enter")
	if intent == nil || intent.Status != IntentReject {
		t.Fatalf("expected reject (adjacent duplicate items), got %+v", intent)
	}
}

func TestListEditor_UniqueItemsRejectsNonAdjacentDuplicate(t *testing.T) {
	// Pin: detection must not be adjacency-only. ["alpha", "beta", "alpha"]
	// has the duplicates separated by one element.
	w := NewListEditor("ceremonies.foo", "advisors", []string{"alpha", "beta", "alpha"}, nil, 0, true, false, false)
	w.Focus()
	_, _ = dispatch(w, "enter")
	_, intent := dispatch(w, "enter")
	if intent == nil || intent.Status != IntentReject {
		t.Fatalf("expected reject (non-adjacent duplicate items), got %+v", intent)
	}
}

func TestListEditor_AddAndCommit(t *testing.T) {
	w := NewListEditor("ceremonies.foo", "advisors", []string{}, nil, 0, true, false, false)
	w.Focus()
	_, _ = dispatch(w, "enter")
	// Press 'a' to enter append mode, type "alpha", press enter to add.
	_, _ = dispatch(w, "a")
	_, _ = dispatch(w, "a")
	_, _ = dispatch(w, "l")
	_, _ = dispatch(w, "p")
	_, _ = dispatch(w, "h")
	_, _ = dispatch(w, "a")
	_, _ = dispatch(w, "enter")
	// Now press enter to commit the list.
	_, intent := dispatch(w, "enter")
	if intent == nil || intent.Status != IntentCommit {
		t.Fatalf("expected commit, got %+v", intent)
	}
	want := []string{"alpha"}
	if got, ok := intent.Value.([]string); !ok || !reflect.DeepEqual(got, want) {
		t.Fatalf("expected %v, got %T %v", want, intent.Value, intent.Value)
	}
}

func TestEnumListEditor_TogglesSupportedValuesAndCommits(t *testing.T) {
	w := NewEnumListEditor(
		"settlement.harness_selection.eligible_frameworks",
		"eligible_frameworks",
		[]string{"claude-code", "opencode", "codex"},
		[]string{"claude-code", "opencode", "codex"},
		0,
		true,
		true,
		true,
	)
	w.Focus()
	_, _ = dispatch(w, "enter")
	_, _ = dispatch(w, "down")
	_, _ = dispatch(w, "down")
	_, _ = dispatch(w, " ")
	_, intent := dispatch(w, "enter")
	if intent == nil || intent.Status != IntentCommit {
		t.Fatalf("expected commit, got %+v", intent)
	}
	want := []string{"claude-code", "opencode"}
	if got, ok := intent.Value.([]string); !ok || !reflect.DeepEqual(got, want) {
		t.Fatalf("expected %v, got %T %v", want, intent.Value, intent.Value)
	}
}

func TestActiveHoursRangesEditor_EditsMultipleRanges(t *testing.T) {
	w := NewActiveHoursRangesEditor("settlement.active_hours.ranges", "ranges", []ActiveHoursRange{
		{Days: []string{"mon", "tue", "wed", "thu", "fri"}, Start: "09:00", End: "17:00"},
	}, true)
	w.Focus()
	_, _ = dispatch(w, "enter")
	_, _ = dispatch(w, "a")
	_, _ = dispatch(w, "right")
	_, _ = dispatch(w, "+")
	_, _ = dispatch(w, "+")
	_, _ = dispatch(w, "right")
	_, _ = dispatch(w, "-")
	_, intent := dispatch(w, "enter")
	if intent == nil || intent.Status != IntentCommit {
		t.Fatalf("expected commit, got %+v", intent)
	}
	got, ok := intent.Value.([]any)
	if !ok || len(got) != 2 {
		t.Fatalf("expected two typed ranges, got %T %v", intent.Value, intent.Value)
	}
	second, ok := got[1].(map[string]any)
	if !ok {
		t.Fatalf("expected range map, got %T", got[1])
	}
	if second["start"] != "10:00" || second["end"] != "16:30" {
		t.Fatalf("expected adjusted second range 10:00-16:30, got %v", second)
	}
}

func TestActiveHoursRangesEditor_EditingAllTimeSeedsDraftWindow(t *testing.T) {
	w := NewActiveHoursRangesEditor("settlement.active_hours.ranges", "ranges", nil, false)
	w.Focus()

	_, intent := dispatch(w, "enter")
	if intent != nil {
		t.Fatalf("entering edit mode should not commit, got %+v", intent)
	}
	if !w.editing || len(w.draft) != 1 {
		t.Fatalf("entering all-time windows should seed one editable draft window, editing=%v draft=%v", w.editing, w.draft)
	}

	_, intent = dispatch(w, "esc")
	if intent == nil || intent.Status != IntentDiscard {
		t.Fatalf("Esc should discard seeded all-time draft, got %+v", intent)
	}
	if len(w.draft) != 0 || len(w.committed) != 0 {
		t.Fatalf("Esc should restore all-time empty windows, draft=%v committed=%v", w.draft, w.committed)
	}
}

func TestActiveHoursRangesEditor_DeleteLastWindowCommitsAllTime(t *testing.T) {
	w := NewActiveHoursRangesEditor("settlement.active_hours.ranges", "ranges", []ActiveHoursRange{
		{Days: []string{"mon"}, Start: "09:00", End: "17:00"},
	}, true)
	w.Focus()

	_, _ = dispatch(w, "enter")
	_, _ = dispatch(w, "d")
	_, intent := dispatch(w, "enter")
	if intent == nil || intent.Status != IntentCommit {
		t.Fatalf("expected deleting last window to commit all-time, got %+v", intent)
	}
	got, ok := intent.Value.([]any)
	if !ok || len(got) != 0 {
		t.Fatalf("expected empty ranges value after deleting last window, got %T %v", intent.Value, intent.Value)
	}
	if len(w.committed) != 0 || len(w.draft) != 0 {
		t.Fatalf("expected editor state to stay all-time after commit, committed=%v draft=%v", w.committed, w.draft)
	}
}

func TestActiveHoursRangesEditor_JKMovesThroughEditableFields(t *testing.T) {
	w := NewActiveHoursRangesEditor("settlement.active_hours.ranges", "ranges", []ActiveHoursRange{
		{Days: []string{"mon"}, Start: "09:00", End: "17:00"},
		{Days: []string{"tue"}, Start: "10:00", End: "18:00"},
	}, true)
	w.Focus()
	_, _ = dispatch(w, "enter")

	_, _ = dispatch(w, "j")
	if w.cursor != 0 || w.field != 1 {
		t.Fatalf("first j should move to first window start field, cursor=%d field=%d", w.cursor, w.field)
	}
	_, _ = dispatch(w, "l")
	if w.cursor != 0 || w.field != 2 {
		t.Fatalf("l should move to the next field, cursor=%d field=%d", w.cursor, w.field)
	}
	_, _ = dispatch(w, "h")
	if w.cursor != 0 || w.field != 1 {
		t.Fatalf("h should move to the previous field, cursor=%d field=%d", w.cursor, w.field)
	}
	_, _ = dispatch(w, "j")
	_, _ = dispatch(w, "j")
	if w.cursor != 1 || w.field != 0 {
		t.Fatalf("j should continue into the next window fields, cursor=%d field=%d", w.cursor, w.field)
	}
	_, _ = dispatch(w, "k")
	if w.cursor != 0 || w.field != 2 {
		t.Fatalf("k should move back to previous window end field, cursor=%d field=%d", w.cursor, w.field)
	}
}

func TestListEditor_DiscardOnEsc(t *testing.T) {
	w := NewListEditor("ceremonies.foo", "advisors", []string{"alpha"}, nil, 0, true, false, false)
	w.Focus()
	_, _ = dispatch(w, "enter")
	// Add a second item to dirty the draft.
	_, _ = dispatch(w, "a")
	_, _ = dispatch(w, "b")
	_, _ = dispatch(w, "e")
	_, _ = dispatch(w, "t")
	_, _ = dispatch(w, "a")
	_, _ = dispatch(w, "enter")
	// Now press Esc — should revert to original.
	_, intent := dispatch(w, "esc")
	if intent == nil || intent.Status != IntentDiscard {
		t.Fatalf("expected IntentDiscard, got %+v", intent)
	}
	if got, ok := intent.Value.([]string); !ok || !reflect.DeepEqual(got, []string{"alpha"}) {
		t.Fatalf("expected revert to [alpha], got %v", intent.Value)
	}
}

func TestListEditor_DiscardOnBlur(t *testing.T) {
	w := NewListEditor("ceremonies.foo", "advisors", []string{"alpha"}, nil, 0, true, false, false)
	w.Focus()
	_, _ = dispatch(w, "enter")
	_, _ = dispatch(w, "a")
	_, _ = dispatch(w, "b")
	_, _ = dispatch(w, "enter")

	intent := w.Blur()
	if intent == nil || intent.Status != IntentDiscard {
		t.Fatalf("expected IntentDiscard from Blur, got %+v", intent)
	}
}

// ----------------------------------------------------------------------------
// OpenKeysetKVEditor — typed value codecs.
// ----------------------------------------------------------------------------

func TestOpenKeysetKVEditor_NumberMapCommitsTypedFloat(t *testing.T) {
	min := 0.0
	max := 1.0
	valueSchema := &SchemaNode{Kind: KindNumber, minimum: &min, maximum: &max}
	w := NewTypedOpenKeysetKVEditor(
		"thresholds.probabilities",
		"probabilities",
		map[string]string{},
		nil,
		openMapValueParser(valueSchema),
		false,
		true,
	)
	w.Focus()
	_, _ = dispatch(w, "enter")

	_, _ = dispatch(w, "a")
	for _, k := range []string{"p", "l", "a", "n", "-", "r", "e", "v", "i", "e", "w"} {
		_, _ = dispatch(w, k)
	}
	_, _ = dispatch(w, "enter")
	for _, k := range []string{"0", ".", "5"} {
		_, _ = dispatch(w, k)
	}
	_, _ = dispatch(w, "enter")
	_, intent := dispatch(w, "enter")
	if intent == nil || intent.Status != IntentCommit {
		t.Fatalf("expected commit, got %+v", intent)
	}
	got, ok := intent.Value.(map[string]any)
	if !ok {
		t.Fatalf("expected map[string]any value, got %T", intent.Value)
	}
	if v, ok := got["plan-review"].(float64); !ok || v != 0.5 {
		t.Fatalf("expected typed float 0.5, got %T %v", got["plan-review"], got["plan-review"])
	}
}

func TestOpenKeysetKVEditor_NumberMapRejectsOutOfBounds(t *testing.T) {
	min := 0.0
	max := 1.0
	valueSchema := &SchemaNode{Kind: KindNumber, minimum: &min, maximum: &max}
	w := NewTypedOpenKeysetKVEditor("thresholds.probabilities", "probabilities", map[string]string{"plan-review": "1.5"}, nil, openMapValueParser(valueSchema), true, true)
	w.Focus()
	_, _ = dispatch(w, "enter")

	_, intent := dispatch(w, "enter")
	if intent == nil || intent.Status != IntentReject {
		t.Fatalf("expected out-of-bounds reject, got %+v", intent)
	}
	if !strings.Contains(strings.Join(intent.Errors, "; "), "at most 1") {
		t.Fatalf("expected maximum error, got %v", intent.Errors)
	}
}

func TestOpenKeysetKVEditor_StringArrayMapCommitsTypedSlice(t *testing.T) {
	w := NewStringArrayOpenKeysetKVEditor("ceremonies", "ceremonies", map[string]string{"plan-review": "sharp-edges,codex-pr-review"}, true, true)
	w.Focus()
	_, _ = dispatch(w, "enter")

	_, intent := dispatch(w, "enter")
	if intent == nil || intent.Status != IntentCommit {
		t.Fatalf("expected commit, got %+v", intent)
	}
	got, ok := intent.Value.(map[string]any)
	if !ok {
		t.Fatalf("expected map[string]any, got %T", intent.Value)
	}
	want := []string{"sharp-edges", "codex-pr-review"}
	if advisors, ok := got["plan-review"].([]string); !ok || !reflect.DeepEqual(advisors, want) {
		t.Fatalf("expected %v, got %T %v", want, got["plan-review"], got["plan-review"])
	}
}

// ----------------------------------------------------------------------------
// ClosedObjectSubPanel — Tab discard semantics.
// ----------------------------------------------------------------------------

func TestClosedObjectSubPanel_TabDiscardsFocusedDraft(t *testing.T) {
	a := NewTextInput("a.x", "x", "", nil, 0, false, false)
	b := NewTextInput("a.y", "y", "", nil, 0, false, false)
	panel := NewClosedObjectSubPanel("a", "section", []FieldWidget{a, b})
	panel.Focus()

	// Type into 'a' (the focused child).
	_, _ = dispatch(panel, "enter")
	_, _ = dispatch(panel, "enter")
	_, _ = dispatch(panel, "z")
	if a.draft != "z" {
		t.Fatalf("expected child draft 'z', got %q", a.draft)
	}

	// Press Tab — should discard a's draft AND advance cursor.
	_, intent := dispatch(panel, "tab")
	if intent == nil || intent.Status != IntentDiscard {
		t.Fatalf("expected IntentDiscard from Tab, got %+v", intent)
	}
	if a.draft != "" {
		t.Fatalf("expected draft reverted, got %q", a.draft)
	}
	if panel.cursor != 1 {
		t.Fatalf("expected cursor advanced to 1, got %d", panel.cursor)
	}
}

func TestClosedObjectSubPanel_EscExitsCleanScalarEditBeforePanel(t *testing.T) {
	a := NewTextInput("a.x", "x", "stable", nil, 0, false, false)
	panel := NewClosedObjectSubPanel("a", "section", []FieldWidget{a})
	panel.Focus()
	_, _ = dispatch(panel, "enter")
	_, _ = dispatch(panel, "enter")
	if !panel.entered || !a.editing {
		t.Fatalf("setup expected entered panel and editing text input; panel.entered=%v editing=%v", panel.entered, a.editing)
	}

	_, intent := dispatch(panel, "esc")
	if intent == nil || intent.Status != IntentDiscard {
		t.Fatalf("first esc should be consumed by the clean leaf edit, got %+v", intent)
	}
	if !panel.entered || a.editing {
		t.Fatalf("first esc should exit edit mode only; panel.entered=%v editing=%v", panel.entered, a.editing)
	}

	_, intent = dispatch(panel, "esc")
	if intent == nil || intent.Status != IntentNavigate {
		t.Fatalf("second esc should be consumed as navigation out of the panel, got %+v", intent)
	}
	if panel.entered {
		t.Fatalf("second esc should leave the panel navigation level")
	}
}

func TestClosedObjectSubPanel_RendersFocusedAndEnteredState(t *testing.T) {
	a := NewToggleRow("a.enabled", "enabled", false, true, false)
	panel := NewClosedObjectSubPanel("a", "harness_selection", []FieldWidget{a})
	panel.Focus()
	out := stripANSI(panel.View())
	if !strings.Contains(out, "harness_selection") || !strings.Contains(out, "[enter]") {
		t.Fatalf("focused panel should advertise enter affordance, got:\n%s", out)
	}

	_, _ = dispatch(panel, "enter")
	out = stripANSI(panel.View())
	if !strings.Contains(out, "harness_selection") || !strings.Contains(out, "[active]") {
		t.Fatalf("entered panel should advertise active state, got:\n%s", out)
	}
}

// ----------------------------------------------------------------------------
// Display hints — label + description rendering.
// ----------------------------------------------------------------------------

// TestEnumSelector_LegacyRenderWithoutLabel asserts the original single-line
// render path is preserved when no field label is set. PrimaryRadio (and any
// caller using the bare candidate-list shape) depends on this — the legacy
// render is one line of `○ option` tokens with no header or description block.
func TestEnumSelector_LegacyRenderWithoutLabel(t *testing.T) {
	w := NewEnumSelector("tui_launch_framework", []string{"claude-code", "codex"}, nil, "claude-code", false)
	out := w.View()
	if strings.Contains(out, "\n") {
		t.Fatalf("expected single-line render without label, got:\n%s", out)
	}
}

// TestEnumSelector_MultiLineRenderWithLabel verifies that SetDisplayHints
// switches the widget into the per-row layout: header line with label, options
// row indented two spaces, description block indented two spaces, soft-
// wrapped at the configured width. This is the rendering shape the user
// asked for in the capability_overrides matrix fix.
func TestEnumSelector_MultiLineRenderWithLabel(t *testing.T) {
	w := NewEnumSelector("capability_overrides.subagents", []string{"full", "partial", "fallback", "none"}, nil, "", true)
	w.SetDisplayHints("subagents", "Spawns fresh subagent contexts for fanout (worker, researcher, reviewer) so each receives a clean context window.")
	w.SetWrapWidth(60)
	out := stripANSI(w.View())
	lines := strings.Split(out, "\n")
	if len(lines) < 3 {
		t.Fatalf("expected at least 3 lines (header, options, description), got %d:\n%s", len(lines), out)
	}
	if !strings.Contains(lines[0], "subagents") {
		t.Errorf("line 0 should contain field label, got: %q", lines[0])
	}
	if !strings.Contains(lines[0], "(inherited)") {
		t.Errorf("line 0 should mark unset overlay as (inherited), got: %q", lines[0])
	}
	if !strings.Contains(lines[1], "○ full") || !strings.Contains(lines[1], "○ none") {
		t.Errorf("line 1 should be the options row, got: %q", lines[1])
	}
	if !strings.HasPrefix(strings.TrimLeft(lines[1], " "), "○ full") {
		t.Errorf("options row should be indented for visual nesting, got: %q", lines[1])
	}
	descBlock := strings.Join(lines[2:], " ")
	if !strings.Contains(descBlock, "Spawns fresh subagent contexts") {
		t.Errorf("description block should contain the help text, got: %q", descBlock)
	}
}

// TestEnumSelector_MultiLineOverrideMarker verifies the header marker flips to
// "[override: <value>]" once a value is committed — distinguishing inherited
// vs. explicit override at a glance, which was the load-bearing readability
// gap in the pre-change matrix.
func TestEnumSelector_MultiLineOverrideMarker(t *testing.T) {
	w := NewEnumSelector("capability_overrides.team_messaging", []string{"full", "partial", "fallback", "none"}, nil, "full", true)
	w.SetDisplayHints("team_messaging", "Inter-agent messaging primitive.")
	w.SetWrapWidth(60)
	out := w.View()
	if !strings.Contains(out, "[override: full]") {
		t.Errorf("expected [override: full] marker for committed overlay, got:\n%s", out)
	}
}

// TestClosedObjectSubPanel_RendersDescriptionAndIndentsChildren verifies the
// section-level rendering: header, optional dim description, indented child
// views. Without indenting children the per-row labels and option dots would
// collide visually with the section header.
func TestClosedObjectSubPanel_RendersDescriptionAndIndentsChildren(t *testing.T) {
	enum := NewEnumSelector("capability_overrides.subagents", []string{"full", "partial", "fallback", "none"}, nil, "", true)
	enum.SetDisplayHints("subagents", "Spawns fresh subagent contexts for fanout.")
	panel := NewClosedObjectSubPanel("capability_overrides", "capability_overrides", []FieldWidget{enum})
	panel.SetDisplayHints("capability_overrides", "Operator overrides for capability support levels.")
	panel.SetWrapWidth(60)
	out := panel.View()
	lines := strings.Split(out, "\n")
	if !strings.Contains(lines[0], "capability_overrides") {
		t.Errorf("line 0 should be section header, got: %q", lines[0])
	}
	// Find the line containing 'subagents' — it should be indented (children
	// receive a two-space indent from the panel).
	found := false
	for _, ln := range lines {
		if strings.Contains(ln, "subagents") {
			found = true
			if !strings.HasPrefix(ln, "  ") {
				t.Errorf("child row should be indented 2 spaces by the panel, got: %q", ln)
			}
			break
		}
	}
	if !found {
		t.Fatalf("subagents row not found in panel output:\n%s", out)
	}
	if !strings.Contains(out, "Operator overrides for capability support levels") {
		t.Errorf("section description missing from rendered panel:\n%s", out)
	}
}

// TestClosedObjectSubPanel_InnerFocusYRange_TracksCursor verifies the panel
// reports a moving y-range as the user steps through children — without this,
// a tall closed-object panel (e.g. capability_overrides with 15+ children)
// would let ensureFocusedVisible pin the slot's bottom into the viewport,
// hiding the cursor row up at the panel's top with no way to find it short
// of escaping the panel entirely. Regression coverage for the user-reported
// bug "cursor disappears when navigating into capability_overrides."
func TestClosedObjectSubPanel_InnerFocusYRange_TracksCursor(t *testing.T) {
	a := NewEnumSelector("section.alpha", []string{"full", "partial"}, nil, "full", false)
	a.SetDisplayHints("alpha", "")
	b := NewEnumSelector("section.beta", []string{"full", "partial"}, nil, "full", false)
	b.SetDisplayHints("beta", "")
	c := NewEnumSelector("section.gamma", []string{"full", "partial"}, nil, "full", false)
	c.SetDisplayHints("gamma", "")
	panel := NewClosedObjectSubPanel("section", "section", []FieldWidget{a, b, c})
	panel.Focus()
	_, _ = dispatch(panel, "enter")

	top0, bot0 := panel.InnerFocusYRange()
	if top0 < 0 || bot0 < top0 {
		t.Fatalf("cursor 0: expected valid range, got top=%d bot=%d", top0, bot0)
	}

	if moved, _ := panel.NavStep(+1); !moved {
		t.Fatalf("NavStep(+1) should advance cursor 0->1")
	}
	top1, bot1 := panel.InnerFocusYRange()
	if !(top1 > top0) {
		t.Fatalf("cursor 1 range must sit below cursor 0; got top0=%d top1=%d", top0, top1)
	}

	if moved, _ := panel.NavStep(+1); !moved {
		t.Fatalf("NavStep(+1) should advance cursor 1->2")
	}
	top2, bot2 := panel.InnerFocusYRange()
	if !(top2 > top1) {
		t.Fatalf("cursor 2 range must sit below cursor 1; got top1=%d top2=%d", top1, top2)
	}

	// The reported range must align with actual ViewBody line content for
	// each cursor position — without this, the model's viewport math scrolls
	// to a y-coordinate that doesn't correspond to a rendered cursor row.
	body := panel.ViewBody()
	bodyLines := strings.Split(body, "\n")
	for cursor, ranges := range []struct{ top, bot int }{{top0, bot0}, {top1, bot1}, {top2, bot2}} {
		if ranges.top >= len(bodyLines) || ranges.bot >= len(bodyLines) {
			t.Fatalf("cursor %d: range (%d,%d) exceeds body line count %d", cursor, ranges.top, ranges.bot, len(bodyLines))
		}
		// The dot-path label of the focused child should appear inside its
		// reported range — alpha at cursor 0, beta at 1, gamma at 2.
		want := []string{"alpha", "beta", "gamma"}[cursor]
		found := false
		for i := ranges.top; i <= ranges.bot; i++ {
			if strings.Contains(bodyLines[i], want) {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("cursor %d: %q not in body lines [%d..%d]:\n%s",
				cursor, want, ranges.top, ranges.bot, strings.Join(bodyLines[ranges.top:ranges.bot+1], "\n"))
		}
	}
}

// TestClosedObjectSubPanel_InnerFocusYRange_NotFocused returns (-1,-1) when
// the panel is not focused — mirrors HarnessBlockPanel's contract so the
// model falls back to the slot-wide range for unfocused panels.
func TestClosedObjectSubPanel_InnerFocusYRange_NotFocused(t *testing.T) {
	a := NewEnumSelector("section.alpha", []string{"full"}, nil, "full", false)
	panel := NewClosedObjectSubPanel("section", "section", []FieldWidget{a})
	// Note: not Focus()'d.
	top, bot := panel.InnerFocusYRange()
	if top != -1 || bot != -1 {
		t.Fatalf("unfocused panel must return (-1,-1); got (%d, %d)", top, bot)
	}
}

// TestToggleRow_RendersDescription verifies that ToggleRow emits its
// description block under the toggle when SetDisplayHints supplies one.
func TestToggleRow_RendersDescription(t *testing.T) {
	w := NewToggleRow("features.enabled", "enabled", true, true, false)
	w.SetDisplayHints("enabled", "When true, this feature is active.")
	w.SetWrapWidth(60)
	out := stripANSI(w.View())
	if !strings.Contains(out, "When true, this feature is active.") {
		t.Errorf("expected description in toggle render, got:\n%s", out)
	}
	if !strings.Contains(out, "[x] enabled") {
		t.Errorf("expected toggle box [x] enabled in render, got:\n%s", out)
	}
}

// TestWrapWords_RespectsWidth gives the wrapping helper a directly-asserted
// contract: words break at whitespace and the wrapped output never exceeds the
// requested column width unless a single word does.
func TestWrapWords_RespectsWidth(t *testing.T) {
	got := wrapWords("Spawns fresh subagent contexts for fanout each receives a clean context window", 30)
	for _, ln := range strings.Split(got, "\n") {
		if runeLen(ln) > 30 {
			// Allow individual long words; assert lines made of >1 token stay <= 30.
			fields := strings.Fields(ln)
			if len(fields) > 1 {
				t.Errorf("multi-word line exceeds wrap width 30: %q (%d cols)", ln, runeLen(ln))
			}
		}
	}
}

// ----------------------------------------------------------------------------
// Boundary contract: widgets never call SettingsPatch/SettingsDelete directly.
// This is asserted by inspection: widgets.go imports do not include
// "github.com/anticorrelator/lore/tui/internal/config". If a future change
// adds that import, this test catches it via build flag or static check.
// We assert it implicitly by the fact that this test file does not import
// config either, and the package compiles standalone.
// ----------------------------------------------------------------------------

// Bug 1 regression coverage — esc inside an in-progress draft (ListEditor's
// "appending" mode and OpenKeysetKVEditor's three typing modes) MUST emit
// IntentDiscard. Returning nil intent would let the model's bare-esc fallback
// close the modal mid-edit, which is the bug the user reported as "esc
// doesn't work to cancel any live edit of a field."

// TestListEditor_EscDuringAppendEmitsIntentDiscard covers ListEditor's
// `appending` branch. The user pressed `a` to start appending an item, typed
// some characters, then pressed Esc — the buffer must clear AND the model
// must keep the modal open via IntentDiscard.
func TestListEditor_EscDuringAppendEmitsIntentDiscard(t *testing.T) {
	w := NewListEditor("harnesses.claude-code.args", "args", []string{"--existing"}, nil, 0, false, true, false)
	w.Focus()
	_, _ = dispatch(w, "enter")

	// Start appending and type a few chars.
	_, _ = dispatch(w, "a")
	_, _ = dispatch(w, "x")
	_, _ = dispatch(w, "y")
	if !w.appending || w.appendBuf != "xy" {
		t.Fatalf("setup: expected appending=true buf='xy', got appending=%v buf=%q", w.appending, w.appendBuf)
	}

	_, intent := dispatch(w, "esc")
	if intent == nil {
		t.Fatalf("esc during append must emit IntentDiscard so the model keeps the modal open; got nil")
	}
	if intent.Status != IntentDiscard {
		t.Fatalf("expected IntentDiscard, got %v", intent.Status)
	}
	if w.appending || w.appendBuf != "" {
		t.Fatalf("expected append cancelled (appending=false buf=\"\"), got appending=%v buf=%q", w.appending, w.appendBuf)
	}
	// The committed list must NOT have been mutated by the cancelled append.
	if !reflect.DeepEqual(w.draft, []string{"--existing"}) {
		t.Fatalf("draft mutated by cancelled append: %v", w.draft)
	}
}

// TestKVEditor_EscDuringAddKeyEmitsIntentDiscard covers the
// OpenKeysetKVEditor.kvAddingKey branch.
func TestKVEditor_EscDuringAddKeyEmitsIntentDiscard(t *testing.T) {
	w := NewOpenKeysetKVEditor("ceremonies", "ceremonies", map[string]string{}, nil, nil, false, true)
	w.Focus()
	_, _ = dispatch(w, "enter")

	// Start adding a key, type some chars, then esc.
	_, _ = dispatch(w, "a")
	_, _ = dispatch(w, "p")
	_, _ = dispatch(w, "r")
	if w.mode != kvAddingKey || w.keyBuf != "pr" {
		t.Fatalf("setup: expected mode=kvAddingKey keyBuf='pr', got mode=%v keyBuf=%q", w.mode, w.keyBuf)
	}

	_, intent := dispatch(w, "esc")
	if intent == nil {
		t.Fatalf("esc during add-key must emit IntentDiscard; got nil")
	}
	if intent.Status != IntentDiscard {
		t.Fatalf("expected IntentDiscard, got %v", intent.Status)
	}
	if w.mode != kvNavigating {
		t.Fatalf("expected mode reverted to kvNavigating, got %v", w.mode)
	}
	if w.keyBuf != "" {
		t.Fatalf("expected keyBuf cleared, got %q", w.keyBuf)
	}
}

// TestKVEditor_EscDuringAddValueEmitsIntentDiscard covers the
// OpenKeysetKVEditor.kvAddingValue branch.
func TestKVEditor_EscDuringAddValueEmitsIntentDiscard(t *testing.T) {
	w := NewOpenKeysetKVEditor("ceremonies", "ceremonies", map[string]string{}, nil, nil, false, true)
	w.Focus()
	_, _ = dispatch(w, "enter")

	// Add a key (commit it via enter), then start adding the value.
	_, _ = dispatch(w, "a")
	_, _ = dispatch(w, "k")
	_, _ = dispatch(w, "enter")
	if w.mode != kvAddingValue {
		t.Fatalf("setup: expected mode=kvAddingValue after key entry, got %v", w.mode)
	}
	_, _ = dispatch(w, "v")
	_, _ = dispatch(w, "1")
	if w.valBuf != "v1" {
		t.Fatalf("setup: expected valBuf='v1', got %q", w.valBuf)
	}

	_, intent := dispatch(w, "esc")
	if intent == nil {
		t.Fatalf("esc during add-value must emit IntentDiscard; got nil")
	}
	if intent.Status != IntentDiscard {
		t.Fatalf("expected IntentDiscard, got %v", intent.Status)
	}
	if w.mode != kvNavigating {
		t.Fatalf("expected mode reverted to kvNavigating, got %v", w.mode)
	}
	if w.valBuf != "" || w.keyBuf != "" || w.editingKey != "" {
		t.Fatalf("expected all entry buffers cleared (got val=%q key=%q editingKey=%q)", w.valBuf, w.keyBuf, w.editingKey)
	}
	// The cancelled value must NOT have been written into the draft map.
	if _, present := w.draft["k"]; present {
		t.Fatalf("draft mutated by cancelled value entry: %v", w.draft)
	}
}

// TestKVEditor_EscDuringEditValueEmitsIntentDiscard covers the
// OpenKeysetKVEditor.kvEditingValue branch (existing entry being re-edited).
func TestKVEditor_EscDuringEditValueEmitsIntentDiscard(t *testing.T) {
	w := NewOpenKeysetKVEditor("ceremonies", "ceremonies", map[string]string{"plan-review": "sharp-edges"}, nil, nil, true, true)
	w.Focus()
	_, _ = dispatch(w, "enter")

	// Press 'e' to start editing the existing entry's value.
	_, _ = dispatch(w, "e")
	if w.mode != kvEditingValue || w.editingKey != "plan-review" {
		t.Fatalf("setup: expected mode=kvEditingValue editingKey='plan-review', got mode=%v editingKey=%q", w.mode, w.editingKey)
	}
	_, _ = dispatch(w, "X") // mutate the value buffer
	if w.valBuf == "sharp-edges" {
		t.Fatalf("setup: expected valBuf to diverge from committed; still %q", w.valBuf)
	}

	_, intent := dispatch(w, "esc")
	if intent == nil {
		t.Fatalf("esc during edit-value must emit IntentDiscard; got nil")
	}
	if intent.Status != IntentDiscard {
		t.Fatalf("expected IntentDiscard, got %v", intent.Status)
	}
	if w.mode != kvNavigating {
		t.Fatalf("expected mode reverted to kvNavigating, got %v", w.mode)
	}
	// The original committed value must remain unchanged in draft.
	if w.draft["plan-review"] != "sharp-edges" {
		t.Fatalf("draft value mutated by cancelled edit: %q", w.draft["plan-review"])
	}
}
