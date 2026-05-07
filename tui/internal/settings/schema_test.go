package settings

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"os"
)

// writeFixture writes a JSON schema string to a temp file and returns the path.
// Per the task constraint, tests use fixture files instead of mutating
// adapters/settings.schema.json.
func writeFixture(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "fixture.schema.json")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	return p
}

func TestLoadSchema_KindsAndConstraints(t *testing.T) {
	body := `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"type": "object",
		"additionalProperties": false,
		"properties": {
			"flag": {"type": "boolean", "description": "a toggle"},
			"name": {"type": "string", "pattern": "^[a-z]+$", "minLength": 1},
			"count": {"type": "integer", "minimum": 0},
			"ratio": {"type": "number", "minimum": 0, "maximum": 1},
			"layout": {"type": "string", "enum": ["left", "right"]},
			"tags": {
				"type": "array",
				"items": {"type": "string"},
				"minItems": 1,
				"uniqueItems": true
			}
		},
		"required": ["flag"]
	}`
	p := writeFixture(t, body)

	s, err := LoadSchema(p)
	if err != nil {
		t.Fatalf("LoadSchema: %v", err)
	}
	if s.Root.Kind != KindObjectClosed {
		t.Fatalf("root kind = %v, want closed object", s.Root.Kind)
	}
	if got, want := s.Root.PropertyOrder, []string{"flag", "name", "count", "ratio", "layout", "tags"}; !equalStrings(got, want) {
		t.Fatalf("property order = %v, want %v", got, want)
	}
	if got, want := s.Root.Required, []string{"flag"}; !equalStrings(got, want) {
		t.Fatalf("required = %v, want %v", got, want)
	}

	flag := s.Root.Properties["flag"]
	if flag.Kind != KindBoolean || flag.Description != "a toggle" {
		t.Fatalf("flag node mismatch: kind=%v desc=%q", flag.Kind, flag.Description)
	}

	name := s.Root.Properties["name"]
	if name.Kind != KindString {
		t.Fatalf("name kind = %v, want string", name.Kind)
	}
	if name.Pattern != "^[a-z]+$" || name.PatternCompiled == nil {
		t.Fatalf("name pattern not compiled: pattern=%q compiled=%v", name.Pattern, name.PatternCompiled)
	}
	if !name.PatternCompiled.MatchString("abc") || name.PatternCompiled.MatchString("ABC") {
		t.Fatalf("compiled pattern semantics wrong")
	}
	if v, ok := name.MinLengthConstraint(); !ok || v != 1 {
		t.Fatalf("name minLength = (%d, %v), want (1, true)", v, ok)
	}

	count := s.Root.Properties["count"]
	if count.Kind != KindInteger {
		t.Fatalf("count kind = %v", count.Kind)
	}
	if v, ok := count.MinimumConstraint(); !ok || v != 0 {
		t.Fatalf("count minimum = (%v, %v), want (0, true)", v, ok)
	}
	if _, ok := count.MaximumConstraint(); ok {
		t.Fatalf("count maximum was set, expected absent")
	}

	ratio := s.Root.Properties["ratio"]
	if ratio.Kind != KindNumber {
		t.Fatalf("ratio kind = %v", ratio.Kind)
	}
	if v, ok := ratio.MaximumConstraint(); !ok || v != 1 {
		t.Fatalf("ratio maximum = (%v, %v)", v, ok)
	}

	layout := s.Root.Properties["layout"]
	if layout.Kind != KindEnum {
		t.Fatalf("layout kind = %v, want enum", layout.Kind)
	}
	if got, want := layout.Enum, []string{"left", "right"}; !equalStrings(got, want) {
		t.Fatalf("layout enum = %v, want %v", got, want)
	}

	tags := s.Root.Properties["tags"]
	if tags.Kind != KindArray {
		t.Fatalf("tags kind = %v, want array", tags.Kind)
	}
	if tags.Items == nil || tags.Items.Kind != KindString {
		t.Fatalf("tags items not string-kind: %+v", tags.Items)
	}
	if v, ok := tags.MinItemsConstraint(); !ok || v != 1 {
		t.Fatalf("tags minItems = (%v, %v)", v, ok)
	}
	if !tags.UniqueItems {
		t.Fatalf("tags uniqueItems = false, want true")
	}
}

func TestLoadSchema_RefResolution(t *testing.T) {
	body := `{
		"type": "object",
		"additionalProperties": false,
		"properties": {
			"role": {"$ref": "#/$defs/role_value"}
		},
		"$defs": {
			"role_value": {
				"type": "string",
				"minLength": 1,
				"description": "a role binding"
			}
		}
	}`
	p := writeFixture(t, body)

	s, err := LoadSchema(p)
	if err != nil {
		t.Fatalf("LoadSchema: %v", err)
	}
	role := s.Root.Properties["role"]
	if role.Kind != KindString {
		t.Fatalf("ref-resolved role kind = %v, want string", role.Kind)
	}
	if role.SourceRef != "#/$defs/role_value" {
		t.Fatalf("SourceRef = %q, want #/$defs/role_value", role.SourceRef)
	}
	if v, ok := role.MinLengthConstraint(); !ok || v != 1 {
		t.Fatalf("ref minLength = (%d, %v), want (1, true)", v, ok)
	}
	if role.Description != "a role binding" {
		t.Fatalf("description not propagated through ref: %q", role.Description)
	}
	if _, ok := s.Defs["role_value"]; !ok {
		t.Fatalf("Defs[role_value] missing")
	}
}

func TestLoadSchema_OpenKeysetObject(t *testing.T) {
	body := `{
		"type": "object",
		"additionalProperties": {
			"type": "array",
			"items": {"type": "string", "pattern": "^[a-z]+$"},
			"uniqueItems": true,
			"minItems": 0
		}
	}`
	p := writeFixture(t, body)

	s, err := LoadSchema(p)
	if err != nil {
		t.Fatalf("LoadSchema: %v", err)
	}
	if s.Root.Kind != KindObjectOpen {
		t.Fatalf("kind = %v, want open object", s.Root.Kind)
	}
	v := s.Root.OpenValueSchema()
	if v == nil || v.Kind != KindArray {
		t.Fatalf("value schema not an array: %+v", v)
	}
	if v.Items.Kind != KindString || v.Items.Pattern == "" {
		t.Fatalf("array element constraints lost: %+v", v.Items)
	}
}

func TestLoadSchema_ClosedKeysetAccessors(t *testing.T) {
	body := `{
		"type": "object",
		"additionalProperties": false,
		"properties": {"a": {"type": "boolean"}, "b": {"type": "boolean"}}
	}`
	s, err := LoadSchema(writeFixture(t, body))
	if err != nil {
		t.Fatalf("LoadSchema: %v", err)
	}
	props, order := s.Root.ClosedProperties()
	if len(props) != 2 {
		t.Fatalf("props count = %d", len(props))
	}
	if !equalStrings(order, []string{"a", "b"}) {
		t.Fatalf("order = %v", order)
	}
	defer func() {
		if r := recover(); r == nil {
			t.Fatal("expected panic on OpenValueSchema for closed kind")
		}
	}()
	_ = s.Root.OpenValueSchema()
}

func TestLoadSchema_UnsupportedConstructs(t *testing.T) {
	cases := map[string]string{
		"oneOf":                 `{"type":"object","additionalProperties":false,"oneOf":[{"type":"object","additionalProperties":false}]}`,
		"anyOf":                 `{"type":"object","additionalProperties":false,"anyOf":[{"type":"object","additionalProperties":false}]}`,
		"allOf":                 `{"type":"object","additionalProperties":false,"allOf":[{"type":"object","additionalProperties":false}]}`,
		"if":                    `{"type":"object","additionalProperties":false,"if":{"type":"object","additionalProperties":false}}`,
		"not":                   `{"type":"object","additionalProperties":false,"not":{"type":"object","additionalProperties":false}}`,
		"unevaluatedProperties": `{"type":"object","additionalProperties":false,"unevaluatedProperties":false}`,
		"propertyNames":         `{"type":"object","additionalProperties":false,"propertyNames":{"type":"string"}}`,
		"patternProperties":     `{"type":"object","additionalProperties":false,"patternProperties":{"^x$":{"type":"string"}}}`,
		"contains":              `{"type":"array","items":{"type":"string"},"contains":{"type":"string"}}`,
		"prefixItems":           `{"type":"array","items":{"type":"string"},"prefixItems":[{"type":"string"}]}`,
		"dependentSchemas":      `{"type":"object","additionalProperties":false,"dependentSchemas":{"a":{"type":"object","additionalProperties":false}}}`,
		"dependentRequired":     `{"type":"object","additionalProperties":false,"dependentRequired":{"a":["b"]}}`,
		"additionalProperties:true": `{"type":"object","additionalProperties":true}`,
		"additionalProperties:absent": `{"type":"object","properties":{"x":{"type":"string"}}}`,
		"additionalProperties:mixed": `{"type":"object","additionalProperties":{"type":"string"},"properties":{"x":{"type":"string"}}}`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := LoadSchema(writeFixture(t, body))
			if err == nil {
				t.Fatalf("expected error for %s", name)
			}
			u, ok := IsUnsupportedConstruct(err)
			if !ok {
				t.Fatalf("error not *UnsupportedConstructError: %v", err)
			}
			// Sanity-check the construct field is set; the prefix differs
			// for the additionalProperties variants (they encode the modifier).
			if !strings.Contains(u.Construct, strings.SplitN(name, ":", 2)[0]) {
				t.Fatalf("construct mismatch: got %q, name %q", u.Construct, name)
			}
		})
	}
}

func TestLoadSchema_BadRegexIsMalformed(t *testing.T) {
	body := `{"type":"string","pattern":"["}`
	_, err := LoadSchema(writeFixture(t, body))
	if err == nil {
		t.Fatal("expected error")
	}
	if _, ok := IsUnsupportedConstruct(err); ok {
		t.Fatalf("bad regex must be malformed-schema, not unsupported-construct: %v", err)
	}
	if !strings.Contains(err.Error(), "invalid regex") {
		t.Fatalf("unexpected error message: %v", err)
	}
}

func TestLoadSchema_MixedTypeEnumRejected(t *testing.T) {
	body := `{"enum":[1,"foo"]}`
	_, err := LoadSchema(writeFixture(t, body))
	if err == nil {
		t.Fatal("expected error")
	}
	if _, ok := IsUnsupportedConstruct(err); ok {
		t.Fatalf("mixed-type enum must be malformed, not unsupported: %v", err)
	}
}

func TestLoadSchema_UnresolvedRefIsMalformed(t *testing.T) {
	body := `{"type":"object","additionalProperties":false,"properties":{"x":{"$ref":"#/$defs/missing"}}}`
	_, err := LoadSchema(writeFixture(t, body))
	if err == nil {
		t.Fatal("expected error")
	}
	if _, ok := IsUnsupportedConstruct(err); ok {
		t.Fatalf("unresolved ref must be malformed, not unsupported: %v", err)
	}
	if !strings.Contains(err.Error(), "unresolved $ref") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestLoadSchema_RefCycleDetected(t *testing.T) {
	body := `{
		"$ref": "#/$defs/a",
		"$defs": {
			"a": {"$ref": "#/$defs/b"},
			"b": {"$ref": "#/$defs/a"}
		}
	}`
	_, err := LoadSchema(writeFixture(t, body))
	if err == nil {
		t.Fatal("expected cycle error")
	}
	if !strings.Contains(err.Error(), "cycle") {
		t.Fatalf("expected cycle error, got: %v", err)
	}
}

func TestLoadSchema_NonRefRefRejected(t *testing.T) {
	// $ref pointing outside #/$defs/ is unsupported.
	body := `{"$ref": "https://example.com/schema.json"}`
	_, err := LoadSchema(writeFixture(t, body))
	if err == nil {
		t.Fatal("expected error")
	}
	u, ok := IsUnsupportedConstruct(err)
	if !ok {
		t.Fatalf("external $ref must be unsupported-construct: %v", err)
	}
	if u.Construct != "$ref" {
		t.Fatalf("construct = %q", u.Construct)
	}
}

func TestLoadSchema_MissingFile(t *testing.T) {
	_, err := LoadSchema(filepath.Join(t.TempDir(), "no-such-file.json"))
	if err == nil {
		t.Fatal("expected error for missing file")
	}
	var u *UnsupportedConstructError
	if errors.As(err, &u) {
		t.Fatalf("missing-file error must NOT be UnsupportedConstructError: %v", err)
	}
}

func TestSchemaNode_AccessorsZeroSafe(t *testing.T) {
	var n *SchemaNode
	if _, ok := n.MinLengthConstraint(); ok {
		t.Fatal("nil receiver MinLengthConstraint must return false")
	}
	if _, ok := n.MinimumConstraint(); ok {
		t.Fatal("nil receiver MinimumConstraint must return false")
	}
	if _, ok := n.MaximumConstraint(); ok {
		t.Fatal("nil receiver MaximumConstraint must return false")
	}
	if _, ok := n.MinItemsConstraint(); ok {
		t.Fatal("nil receiver MinItemsConstraint must return false")
	}
}

func TestLoadSchema_MinLengthZeroIsExplicit(t *testing.T) {
	// Distinguishing minLength=0 (explicit "empty allowed") from absent
	// is the disambiguation reason for pointer-backed constraints.
	body := `{"type":"string","minLength":0}`
	s, err := LoadSchema(writeFixture(t, body))
	if err != nil {
		t.Fatalf("LoadSchema: %v", err)
	}
	v, ok := s.Root.MinLengthConstraint()
	if !ok || v != 0 {
		t.Fatalf("minLength = (%d, %v), want (0, true)", v, ok)
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
