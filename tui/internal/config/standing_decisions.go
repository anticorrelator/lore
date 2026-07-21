package config

import (
	"bytes"
	"encoding/json"
	"io"
	"regexp"
	"sort"
	"strings"
	"time"
)

const NumberedModalSignatureV1 = "numbered-modal-v1"

var standingDecisionID = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)

type ModalAnswerOption struct {
	Number int    `json:"number"`
	Label  string `json:"label"`
}

type NumberedModalSignature struct {
	Kind    string              `json:"kind"`
	Title   string              `json:"title"`
	Options []ModalAnswerOption `json:"options"`
}

type ModalAnswerChoice struct {
	Option int    `json:"option"`
	Expect string `json:"expect"`
}

type ModalAnswerRegistration struct {
	ID           string                 `json:"-"`
	Enabled      bool                   `json:"enabled"`
	Framework    string                 `json:"framework"`
	Signature    NumberedModalSignature `json:"signature"`
	Answer       ModalAnswerChoice      `json:"answer"`
	RegisteredBy string                 `json:"registered_by"`
	RegisteredAt string                 `json:"registered_at"`
	Rationale    string                 `json:"rationale"`
}

func decodeClosedRegistration(raw json.RawMessage) (ModalAnswerRegistration, bool) {
	var registration ModalAnswerRegistration
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&registration); err != nil {
		return ModalAnswerRegistration{}, false
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return ModalAnswerRegistration{}, false
	}
	return registration, true
}

func validModalAnswerRegistration(id string, registration ModalAnswerRegistration, frameworks map[string]capabilitiesProfile) bool {
	if !standingDecisionID.MatchString(id) || registration.Framework == "" {
		return false
	}
	if _, ok := frameworks[registration.Framework]; !ok {
		return false
	}
	if registration.Signature.Kind != NumberedModalSignatureV1 ||
		registration.Signature.Title == "" || strings.TrimSpace(registration.Signature.Title) != registration.Signature.Title ||
		len(registration.Signature.Options) < 2 || registration.Answer.Option < 1 ||
		registration.Answer.Expect == "" || registration.RegisteredBy != "user" ||
		strings.TrimSpace(registration.Rationale) == "" {
		return false
	}
	if _, err := time.Parse(time.RFC3339, registration.RegisteredAt); err != nil {
		return false
	}
	seen := make(map[int]bool, len(registration.Signature.Options))
	answerPresent := false
	for _, option := range registration.Signature.Options {
		if option.Number < 1 || seen[option.Number] || option.Label == "" || strings.TrimSpace(option.Label) != option.Label {
			return false
		}
		seen[option.Number] = true
		answerPresent = answerPresent || option.Number == registration.Answer.Option
	}
	return answerPresent
}

// LoadModalAnswerRegistrations returns validated registrations keyed by stable
// id. Malformed and disabled entries are inactive; malformed settings JSON is
// returned as an error so callers fail closed.
func LoadModalAnswerRegistrations() (map[string]ModalAnswerRegistration, error) {
	section, err := SettingsSection("standing_decisions")
	if err != nil {
		return nil, err
	}
	var standing struct {
		ModalAnswers map[string]json.RawMessage `json:"modal_answers"`
	}
	if err := json.Unmarshal(section, &standing); err != nil {
		return nil, err
	}
	caps, err := loadCapabilitiesFile()
	if err != nil {
		return nil, err
	}
	out := make(map[string]ModalAnswerRegistration)
	for id, raw := range standing.ModalAnswers {
		registration, ok := decodeClosedRegistration(raw)
		if !ok || !registration.Enabled || !validModalAnswerRegistration(id, registration, caps.Frameworks) {
			continue
		}
		registration.ID = id
		out[id] = registration
	}
	return out, nil
}

// MatchModalAnswer returns the sole validated exact registration for a live
// signature. Duplicate registrations for the same signature are ambiguous and
// therefore inactive.
func MatchModalAnswer(framework string, signature NumberedModalSignature) (ModalAnswerRegistration, bool) {
	registrations, err := LoadModalAnswerRegistrations()
	if err != nil {
		return ModalAnswerRegistration{}, false
	}
	ids := make([]string, 0, len(registrations))
	for id := range registrations {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	var match ModalAnswerRegistration
	found := false
	for _, id := range ids {
		candidate := registrations[id]
		if candidate.Framework != framework || candidate.Signature.Kind != signature.Kind ||
			candidate.Signature.Title != signature.Title || len(candidate.Signature.Options) != len(signature.Options) {
			continue
		}
		equal := true
		for i := range candidate.Signature.Options {
			if candidate.Signature.Options[i] != signature.Options[i] {
				equal = false
				break
			}
		}
		if !equal {
			continue
		}
		if found {
			return ModalAnswerRegistration{}, false
		}
		match, found = candidate, true
	}
	return match, found
}
