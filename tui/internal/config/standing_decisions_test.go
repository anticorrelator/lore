package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func modalRegistrationFixture() map[string]any {
	return map[string]any{
		"enabled":   true,
		"framework": "codex",
		"signature": map[string]any{
			"kind":  NumberedModalSignatureV1,
			"title": "Additional safety checks",
			"options": []map[string]any{
				{"number": 1, "label": "Retry with a faster model"},
				{"number": 2, "label": "Keep waiting"},
				{"number": 3, "label": "Learn more"},
			},
		},
		"answer":        map[string]any{"option": 2, "expect": "Additional safety checks"},
		"registered_by": "user",
		"registered_at": "2026-07-21T00:00:00Z",
		"rationale":     "Keep the current protocol session on its selected model.",
	}
}

func writeStandingDecisions(t *testing.T, entries map[string]any) {
	t.Helper()
	dataDir := setupFakeLoreData(t, "codex", nil)
	path := filepath.Join(dataDir, "config", "settings.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatal(err)
	}
	doc["standing_decisions"] = map[string]any{"modal_answers": entries}
	data, err = json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

func additionalSafetySignature() NumberedModalSignature {
	return NumberedModalSignature{
		Kind:  NumberedModalSignatureV1,
		Title: "Additional safety checks",
		Options: []ModalAnswerOption{
			{Number: 1, Label: "Retry with a faster model"},
			{Number: 2, Label: "Keep waiting"},
			{Number: 3, Label: "Learn more"},
		},
	}
}

func TestMatchModalAnswerRequiresExactSignature(t *testing.T) {
	writeStandingDecisions(t, map[string]any{
		"codex-additional-safety-checks-keep-waiting-v1": modalRegistrationFixture(),
	})
	got, ok := MatchModalAnswer("codex", additionalSafetySignature())
	if !ok || got.ID != "codex-additional-safety-checks-keep-waiting-v1" || got.Answer.Option != 2 {
		t.Fatalf("match = %+v, ok=%v", got, ok)
	}

	cases := []struct {
		name      string
		framework string
		mutate    func(*NumberedModalSignature)
	}{
		{"framework", "claude-code", func(*NumberedModalSignature) {}},
		{"title", "codex", func(s *NumberedModalSignature) { s.Title += "!" }},
		{"option label", "codex", func(s *NumberedModalSignature) { s.Options[1].Label = "Wait" }},
		{"option order", "codex", func(s *NumberedModalSignature) { s.Options[0], s.Options[1] = s.Options[1], s.Options[0] }},
		{"extra option", "codex", func(s *NumberedModalSignature) {
			s.Options = append(s.Options, ModalAnswerOption{Number: 4, Label: "Cancel"})
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			signature := additionalSafetySignature()
			tc.mutate(&signature)
			if _, ok := MatchModalAnswer(tc.framework, signature); ok {
				t.Fatal("mismatched signature activated registration")
			}
		})
	}
}

func TestMalformedDisabledAndAmbiguousRegistrationsAreInactive(t *testing.T) {
	malformed := modalRegistrationFixture()
	malformed["unexpected"] = true
	disabled := modalRegistrationFixture()
	disabled["enabled"] = false
	writeStandingDecisions(t, map[string]any{
		"malformed": malformed,
		"disabled":  disabled,
	})
	if got, err := LoadModalAnswerRegistrations(); err != nil || len(got) != 0 {
		t.Fatalf("registrations = %+v, err=%v", got, err)
	}

	writeStandingDecisions(t, map[string]any{"one": modalRegistrationFixture(), "two": modalRegistrationFixture()})
	if _, ok := MatchModalAnswer("codex", additionalSafetySignature()); ok {
		t.Fatal("duplicate exact registrations must fail closed")
	}
}
