// Package settings implements the schema-driven Bubble Tea configurator
// modal body for ~/.lore/config/settings.json.
//
// schema.go owns the loader: it parses adapters/settings.schema.json, eagerly
// resolves $ref pointers to #/$defs/<name>, classifies object nodes as
// closed-keyset vs open-keyset, and surfaces typed enum sets and per-field
// constraint metadata (pattern, minLength, minimum, maximum, minItems,
// uniqueItems) the widget layer (widgets.go, task 3) and SettingsModel
// (model.go, task 4) walk for default-by-type dispatch and commit-time
// validation.
//
// Per D1 of the work item plan (tui-settings-configurator-schema-driven-
// rendering): the loader supports ONLY the verified-current taxonomy
// (enum, boolean, string, integer, number, array, closed-keyset object,
// open-keyset object, $ref). Any construct outside that set returns
// *UnsupportedConstructError, which the host renders as a "construct not
// supported by configurator" banner inside the modal rather than silently
// rendering a partial widget. Eager $ref resolution makes "supported"
// a load-time guarantee on the returned tree, not a render-time check
// the widget layer has to repeat.
package settings

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
)

// NodeKind discriminates SchemaNode value-shapes. Exactly one kind applies
// per node post-resolution. Add a new kind only when a new construct enters
// the verified-current taxonomy (D1).
type NodeKind int

const (
	// KindUnknown is the zero value; a fully-loaded tree never contains it.
	KindUnknown NodeKind = iota
	KindBoolean
	KindString
	KindInteger
	KindNumber
	KindEnum
	KindArray
	KindObjectClosed
	KindObjectOpen
)

func (k NodeKind) String() string {
	switch k {
	case KindBoolean:
		return "boolean"
	case KindString:
		return "string"
	case KindInteger:
		return "integer"
	case KindNumber:
		return "number"
	case KindEnum:
		return "enum"
	case KindArray:
		return "array"
	case KindObjectClosed:
		return "object<closed>"
	case KindObjectOpen:
		return "object<open>"
	default:
		return "unknown"
	}
}

// SchemaNode is a normalized JSON Schema fragment after $ref resolution.
//
// Optionality of constraint fields is hidden behind comma-ok accessors
// (MinLengthConstraint, MinimumConstraint, MaximumConstraint,
// MinItemsConstraint) — the underlying *int / *float64 fields are
// unexported so a widget-layer caller cannot accidentally dereference
// a nil pointer. Comma-ok at the call site is a compile error if the
// bool is dropped, where a forgotten nil-check on a pointer field is a
// runtime panic at the worst possible moment (commit-time validation).
type SchemaNode struct {
	Kind        NodeKind
	Description string

	// SourceRef records the originating $defs name when this node was
	// produced by resolving a $ref (e.g. "#/$defs/role_value"). Empty
	// when the node was inline. Diagnostic only — the resolved fields
	// (Enum, Pattern, etc.) are the source of truth for runtime
	// validation per D6; SourceRef must NOT be re-resolved by callers.
	SourceRef string

	// Enum is populated when Kind == KindEnum. Order is preserved from
	// the schema declaration. All values are strings — the loader rejects
	// non-string enums as malformed-schema (the verified-current taxonomy
	// has no mixed-type enums).
	Enum []string

	// Pattern is the raw regex source as written in the schema (Kind ==
	// KindString). Empty when no pattern constraint applies.
	// PatternCompiled is the pre-compiled regex; nil iff Pattern is "".
	// Compile errors surface at LoadSchema time as malformed-schema, not
	// at validate time — bad patterns and unsupported constructs both
	// prevent the configurator from opening, so they share the same fail
	// path.
	Pattern         string
	PatternCompiled *regexp.Regexp

	// Optional constraints — accessed via the comma-ok methods below.
	minLength *int
	minimum   *float64
	maximum   *float64
	minItems  *int

	// UniqueItems applies when Kind == KindArray. Defaults to false when
	// the keyword is absent.
	UniqueItems bool

	// Items describes the element schema when Kind == KindArray. Always
	// non-nil for array kinds.
	Items *SchemaNode

	// Properties holds the declared keyset for object kinds. PropertyOrder
	// preserves the schema declaration order so the widget layer renders
	// fields deterministically (Go map iteration is randomized).
	Properties    map[string]*SchemaNode
	PropertyOrder []string
	Required      []string

	// AdditionalProperties is non-nil exactly when Kind == KindObjectOpen
	// and carries the value-schema for dynamic keys. Mixed shapes
	// (Properties non-empty AND additionalProperties: <schema>) are
	// rejected at load — the verified-current taxonomy has no mixed
	// objects and admitting them now is a forward-compat surface that
	// can't be tested against.
	AdditionalProperties *SchemaNode
}

// MinLengthConstraint returns the minLength constraint and whether it was
// declared. minLength=0 is meaningful (the schema can express "explicit
// empty allowed"), so absence and zero must remain distinguishable.
func (n *SchemaNode) MinLengthConstraint() (int, bool) {
	if n == nil || n.minLength == nil {
		return 0, false
	}
	return *n.minLength, true
}

// MinimumConstraint returns the minimum numeric bound and whether it was
// declared. Used by integer and number widgets at commit-time validation
// per D10.
func (n *SchemaNode) MinimumConstraint() (float64, bool) {
	if n == nil || n.minimum == nil {
		return 0, false
	}
	return *n.minimum, true
}

// MaximumConstraint returns the maximum numeric bound and whether it was
// declared.
func (n *SchemaNode) MaximumConstraint() (float64, bool) {
	if n == nil || n.maximum == nil {
		return 0, false
	}
	return *n.maximum, true
}

// MinItemsConstraint returns the minItems constraint and whether it was
// declared. Applies to KindArray nodes.
func (n *SchemaNode) MinItemsConstraint() (int, bool) {
	if n == nil || n.minItems == nil {
		return 0, false
	}
	return *n.minItems, true
}

// ClosedProperties returns the closed keyset for an object node. Panics if
// Kind != KindObjectClosed — wrong-kind access is a programming error in
// the widget layer, not a runtime condition. Pair with kind discrimination
// at the call site.
func (n *SchemaNode) ClosedProperties() (map[string]*SchemaNode, []string) {
	if n.Kind != KindObjectClosed {
		panic(fmt.Sprintf("settings: ClosedProperties called on %s node", n.Kind))
	}
	return n.Properties, n.PropertyOrder
}

// OpenValueSchema returns the value-schema for dynamic keys on an open-keyset
// object node. Panics if Kind != KindObjectOpen.
func (n *SchemaNode) OpenValueSchema() *SchemaNode {
	if n.Kind != KindObjectOpen {
		panic(fmt.Sprintf("settings: OpenValueSchema called on %s node", n.Kind))
	}
	return n.AdditionalProperties
}

// Schema is the loaded schema with the resolved root and a snapshot of the
// raw $defs (also fully resolved). Defs is exposed for diagnostic affordances
// (e.g. "show definition" tooltips); the runtime validators consume Root.
type Schema struct {
	Root *SchemaNode
	Defs map[string]*SchemaNode
}

// UnsupportedConstructError signals a JSON Schema construct outside the
// verified-current taxonomy. The configurator opens with this error rendered
// as the modal body so a future schema edit cannot silently route around D1.
//
// Path is the dotted path within the schema document (e.g.
// "properties.foo.oneOf"). Construct names the offending keyword.
type UnsupportedConstructError struct {
	Path      string
	Construct string
	Detail    string
}

func (e *UnsupportedConstructError) Error() string {
	if e.Detail != "" {
		return fmt.Sprintf("settings: unsupported schema construct %q at %s: %s", e.Construct, e.Path, e.Detail)
	}
	return fmt.Sprintf("settings: unsupported schema construct %q at %s", e.Construct, e.Path)
}

// unsupportedConstructs lists keywords the loader rejects. Note `then`/`else`
// are intentionally NOT in this list — they are only meaningful inside `if`,
// and flagging them at arbitrary nodes would noisily reject a future schema
// author who legitimately names a property "then". Detecting `if` already
// catches the construct.
var unsupportedConstructs = []string{
	"oneOf",
	"anyOf",
	"allOf",
	"if",
	"not",
	"unevaluatedProperties",
	"dependentSchemas",
	"dependentRequired",
	"propertyNames",
	"patternProperties",
	"contains",
	"prefixItems",
}

// LoadSchema reads and parses a JSON Schema file at path. The path is
// injectable so tests use a fixture file rather than mutating the live
// adapters/settings.schema.json (testability contract per task 1).
//
// Errors fall into two categories:
//   - Malformed schema (file IO error, JSON parse error, unresolvable $ref,
//     ref cycle, bad regex pattern, non-string enum value). Returned as a
//     wrapped error. Caller treats as "schema file broken — refuse to open
//     the configurator at all."
//   - *UnsupportedConstructError. Caller uses errors.As to render the
//     "construct not supported by configurator" message inline in the
//     modal per the verification gate.
func LoadSchema(path string) (*Schema, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("settings: open schema %s: %w", path, err)
	}
	defer f.Close()

	raw, err := io.ReadAll(f)
	if err != nil {
		return nil, fmt.Errorf("settings: read schema %s: %w", path, err)
	}

	// First pass: parse into a generic ordered tree to preserve property
	// declaration order. encoding/json into map[string]any randomizes key
	// order; an orderedMap walker over the token stream preserves it. The
	// schema is small (~275 lines today) so the double-pass overhead is
	// negligible — the alternative is shipping a custom JSON parser, which
	// we don't.
	root, err := parseOrdered(raw)
	if err != nil {
		return nil, fmt.Errorf("settings: parse schema %s: %w", path, err)
	}

	rootMap, ok := root.(*orderedMap)
	if !ok {
		return nil, fmt.Errorf("settings: schema root must be an object, got %T", root)
	}

	// Resolve $defs first so $ref lookups during root resolution can find
	// them. $defs themselves may reference other $defs (no cycles in the
	// current schema, but defended against).
	defsRaw := lookupOrdered(rootMap, "$defs")
	defs := map[string]*SchemaNode{}
	if defsRaw != nil {
		defsMap, ok := defsRaw.(*orderedMap)
		if !ok {
			return nil, fmt.Errorf("settings: $defs must be an object, got %T", defsRaw)
		}
		// Build a placeholder map so $ref resolution during def resolution
		// can detect cycles via the visiting-set rather than infinite
		// recursion.
		defsRawByName := map[string]any{}
		for _, k := range defsMap.keys {
			defsRawByName[k] = defsMap.values[k]
		}
		for _, k := range defsMap.keys {
			node, err := resolveNode(defsMap.values[k], "#/$defs/"+k, defsRawByName, map[string]bool{})
			if err != nil {
				return nil, err
			}
			defs[k] = node
		}
	}

	// Now resolve the root with a defs-by-name lookup map for $ref.
	defsRawByName := map[string]any{}
	if defsRaw != nil {
		dm := defsRaw.(*orderedMap)
		for _, k := range dm.keys {
			defsRawByName[k] = dm.values[k]
		}
	}
	rootNode, err := resolveNode(rootMap, "#", defsRawByName, map[string]bool{})
	if err != nil {
		return nil, err
	}

	return &Schema{Root: rootNode, Defs: defs}, nil
}

// resolveNode walks one schema fragment and returns its SchemaNode form.
// path is the JSON-pointer-ish dotted path used in error messages.
// defsByName is the raw $defs map (for $ref lookup). visiting tracks $ref
// names currently on the resolution stack — re-encountering one signals a
// cycle.
func resolveNode(raw any, path string, defsByName map[string]any, visiting map[string]bool) (*SchemaNode, error) {
	m, ok := raw.(*orderedMap)
	if !ok {
		return nil, fmt.Errorf("settings: expected object at %s, got %T", path, raw)
	}

	// $ref short-circuits everything else per JSON Schema convention.
	if refRaw, ok := m.values["$ref"]; ok {
		ref, ok := refRaw.(string)
		if !ok {
			return nil, fmt.Errorf("settings: $ref at %s must be a string, got %T", path, refRaw)
		}
		const prefix = "#/$defs/"
		if !strings.HasPrefix(ref, prefix) {
			return nil, &UnsupportedConstructError{
				Path:      path,
				Construct: "$ref",
				Detail:    fmt.Sprintf("only %s<name> is supported, got %q", prefix, ref),
			}
		}
		name := strings.TrimPrefix(ref, prefix)
		target, ok := defsByName[name]
		if !ok {
			return nil, fmt.Errorf("settings: unresolved $ref %q at %s", ref, path)
		}
		if visiting[name] {
			return nil, fmt.Errorf("settings: $ref cycle detected at %s -> %q", path, ref)
		}
		visiting[name] = true
		defer delete(visiting, name)
		resolved, err := resolveNode(target, "#/$defs/"+name, defsByName, visiting)
		if err != nil {
			return nil, err
		}
		// Clone the resolved node so future patches stamping per-call-site
		// hints don't alias across distinct ref-sites. The cost is minor
		// against a schema this size.
		clone := *resolved
		clone.SourceRef = ref
		return &clone, nil
	}

	// Reject unsupported constructs at every node — load-time guarantee
	// per D1.
	for _, kw := range unsupportedConstructs {
		if _, present := m.values[kw]; present {
			return nil, &UnsupportedConstructError{Path: path, Construct: kw}
		}
	}

	node := &SchemaNode{}
	if d, ok := m.values["description"].(string); ok {
		node.Description = d
	}

	// Type discrimination. The schema either declares a "type" or an "enum".
	// Mixed-type enums (e.g. `enum: [1, "foo"]`) are out of taxonomy.
	if enumRaw, ok := m.values["enum"]; ok {
		arr, ok := enumRaw.([]any)
		if !ok {
			return nil, fmt.Errorf("settings: enum at %s must be an array, got %T", path, enumRaw)
		}
		vals := make([]string, 0, len(arr))
		for i, v := range arr {
			s, ok := v.(string)
			if !ok {
				return nil, fmt.Errorf("settings: enum value at %s[%d] must be a string (mixed-type enums are out of taxonomy), got %T", path, i, v)
			}
			vals = append(vals, s)
		}
		node.Kind = KindEnum
		node.Enum = vals
		// minLength on a string enum is unusual but not malformed; the
		// verified-current schema doesn't combine them, so we don't carry
		// extra string constraints when enum is set.
		return node, nil
	}

	typeRaw, hasType := m.values["type"]
	if !hasType {
		return nil, fmt.Errorf("settings: missing \"type\" (and not an enum or $ref) at %s", path)
	}
	typeStr, ok := typeRaw.(string)
	if !ok {
		return nil, fmt.Errorf("settings: \"type\" at %s must be a string, got %T (union types are out of taxonomy)", path, typeRaw)
	}

	switch typeStr {
	case "boolean":
		node.Kind = KindBoolean
	case "string":
		node.Kind = KindString
		if pat, ok := m.values["pattern"].(string); ok {
			node.Pattern = pat
			compiled, err := regexp.Compile(pat)
			if err != nil {
				return nil, fmt.Errorf("settings: invalid regex pattern %q at %s: %w", pat, path, err)
			}
			node.PatternCompiled = compiled
		}
		if v, ok := m.values["minLength"]; ok {
			n, err := asInt(v, path+".minLength")
			if err != nil {
				return nil, err
			}
			node.minLength = &n
		}
	case "integer":
		node.Kind = KindInteger
		if v, ok := m.values["minimum"]; ok {
			f, err := asFloat(v, path+".minimum")
			if err != nil {
				return nil, err
			}
			node.minimum = &f
		}
		if v, ok := m.values["maximum"]; ok {
			f, err := asFloat(v, path+".maximum")
			if err != nil {
				return nil, err
			}
			node.maximum = &f
		}
	case "number":
		node.Kind = KindNumber
		if v, ok := m.values["minimum"]; ok {
			f, err := asFloat(v, path+".minimum")
			if err != nil {
				return nil, err
			}
			node.minimum = &f
		}
		if v, ok := m.values["maximum"]; ok {
			f, err := asFloat(v, path+".maximum")
			if err != nil {
				return nil, err
			}
			node.maximum = &f
		}
	case "array":
		node.Kind = KindArray
		itemsRaw, ok := m.values["items"]
		if !ok {
			return nil, fmt.Errorf("settings: array at %s missing \"items\" schema", path)
		}
		items, err := resolveNode(itemsRaw, path+".items", defsByName, visiting)
		if err != nil {
			return nil, err
		}
		node.Items = items
		if v, ok := m.values["minItems"]; ok {
			n, err := asInt(v, path+".minItems")
			if err != nil {
				return nil, err
			}
			node.minItems = &n
		}
		if v, ok := m.values["uniqueItems"]; ok {
			b, ok := v.(bool)
			if !ok {
				return nil, fmt.Errorf("settings: uniqueItems at %s must be bool, got %T", path, v)
			}
			node.UniqueItems = b
		}
	case "object":
		if err := resolveObject(m, node, path, defsByName, visiting); err != nil {
			return nil, err
		}
	default:
		return nil, &UnsupportedConstructError{
			Path:      path,
			Construct: "type:" + typeStr,
			Detail:    "verified-current taxonomy: boolean, string, integer, number, array, object, enum",
		}
	}

	return node, nil
}

func resolveObject(m *orderedMap, node *SchemaNode, path string, defsByName map[string]any, visiting map[string]bool) error {
	// Closed-vs-open keyset detection.
	//   additionalProperties: false           -> KindObjectClosed
	//   additionalProperties: <schema object> -> KindObjectOpen
	//   additionalProperties: true OR absent  -> reject (the verified-
	//                                            current taxonomy commits
	//                                            to closed-set guarantees;
	//                                            silently relaxing them is
	//                                            the regression D1 forbids)
	apRaw, hasAP := m.values["additionalProperties"]
	if !hasAP {
		return &UnsupportedConstructError{
			Path:      path,
			Construct: "additionalProperties:absent",
			Detail:    "object schemas must declare additionalProperties:false (closed) or additionalProperties:<schema> (open); absent default would silently relax closed-set rejection",
		}
	}

	hasProperties := false
	if propsRaw, ok := m.values["properties"]; ok {
		propsMap, ok := propsRaw.(*orderedMap)
		if !ok {
			return fmt.Errorf("settings: properties at %s must be an object, got %T", path, propsRaw)
		}
		props := map[string]*SchemaNode{}
		order := make([]string, 0, len(propsMap.keys))
		for _, k := range propsMap.keys {
			child, err := resolveNode(propsMap.values[k], path+".properties."+k, defsByName, visiting)
			if err != nil {
				return err
			}
			props[k] = child
			order = append(order, k)
		}
		node.Properties = props
		node.PropertyOrder = order
		hasProperties = len(order) > 0
	}

	if reqRaw, ok := m.values["required"]; ok {
		arr, ok := reqRaw.([]any)
		if !ok {
			return fmt.Errorf("settings: required at %s must be an array, got %T", path, reqRaw)
		}
		req := make([]string, 0, len(arr))
		for i, v := range arr {
			s, ok := v.(string)
			if !ok {
				return fmt.Errorf("settings: required[%d] at %s must be a string, got %T", i, path, v)
			}
			req = append(req, s)
		}
		node.Required = req
	}

	switch ap := apRaw.(type) {
	case bool:
		if ap {
			return &UnsupportedConstructError{
				Path:      path,
				Construct: "additionalProperties:true",
				Detail:    "open-keyset objects must declare a value-schema, not the bare keyword `true`",
			}
		}
		node.Kind = KindObjectClosed
	case *orderedMap:
		if hasProperties {
			// Mixed shapes (declared properties + dynamic value-schema) are
			// rejected. The verified-current schema has none; admitting them
			// now is a forward-compat surface that can't be tested against.
			return &UnsupportedConstructError{
				Path:      path,
				Construct: "additionalProperties:mixed",
				Detail:    "object cannot mix declared `properties` with dynamic `additionalProperties:<schema>` — verified-current taxonomy permits one or the other",
			}
		}
		valueSchema, err := resolveNode(apRaw, path+".additionalProperties", defsByName, visiting)
		if err != nil {
			return err
		}
		node.AdditionalProperties = valueSchema
		node.Kind = KindObjectOpen
	default:
		return fmt.Errorf("settings: additionalProperties at %s must be bool or object, got %T", path, apRaw)
	}

	return nil
}

// asInt coerces a JSON number (parsed as float64 by encoding/json) to int.
// Rejects fractional values — JSON Schema "integer" is integer-valued.
func asInt(v any, path string) (int, error) {
	switch x := v.(type) {
	case float64:
		if x != float64(int(x)) {
			return 0, fmt.Errorf("settings: integer constraint at %s has fractional value %v", path, x)
		}
		return int(x), nil
	case int:
		return x, nil
	case json.Number:
		i, err := x.Int64()
		if err != nil {
			return 0, fmt.Errorf("settings: integer constraint at %s: %w", path, err)
		}
		return int(i), nil
	default:
		return 0, fmt.Errorf("settings: integer constraint at %s must be a number, got %T", path, v)
	}
}

func asFloat(v any, path string) (float64, error) {
	switch x := v.(type) {
	case float64:
		return x, nil
	case int:
		return float64(x), nil
	case json.Number:
		f, err := x.Float64()
		if err != nil {
			return 0, fmt.Errorf("settings: numeric constraint at %s: %w", path, err)
		}
		return f, nil
	default:
		return 0, fmt.Errorf("settings: numeric constraint at %s must be a number, got %T", path, v)
	}
}

// IsUnsupportedConstruct reports whether err (or any wrapped cause) is an
// *UnsupportedConstructError. Convenience wrapper so callers don't import
// errors twice.
func IsUnsupportedConstruct(err error) (*UnsupportedConstructError, bool) {
	var u *UnsupportedConstructError
	if errors.As(err, &u) {
		return u, true
	}
	return nil, false
}

// orderedMap preserves JSON object key declaration order. The standard
// encoding/json decodes objects into map[string]any, which Go iterates in
// randomized order — fatal for the configurator's stable widget layout.
type orderedMap struct {
	keys   []string
	values map[string]any
}

func lookupOrdered(m *orderedMap, key string) any {
	if m == nil {
		return nil
	}
	return m.values[key]
}

// parseOrdered decodes raw JSON into a tree where every object is an
// *orderedMap (preserving declaration order) and every array/scalar uses
// the standard encoding/json shape.
func parseOrdered(raw []byte) (any, error) {
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.UseNumber()
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	val, err := decodeValue(dec, tok)
	if err != nil {
		return nil, err
	}
	// Reject trailing tokens — guards against silently accepting concatenated
	// JSON documents.
	if dec.More() {
		return nil, errors.New("trailing data after top-level JSON value")
	}
	return val, nil
}

func decodeValue(dec *json.Decoder, tok json.Token) (any, error) {
	switch t := tok.(type) {
	case json.Delim:
		switch t {
		case '{':
			return decodeObject(dec)
		case '[':
			return decodeArray(dec)
		default:
			return nil, fmt.Errorf("unexpected delimiter %v", t)
		}
	case string:
		return t, nil
	case bool:
		return t, nil
	case json.Number:
		// Promote to float64 to keep parity with the standard map[string]any
		// shape callers expect; the asInt/asFloat helpers handle precision.
		f, err := t.Float64()
		if err != nil {
			return nil, err
		}
		return f, nil
	case nil:
		return nil, nil
	default:
		return nil, fmt.Errorf("unsupported token type %T", tok)
	}
}

func decodeObject(dec *json.Decoder) (*orderedMap, error) {
	m := &orderedMap{values: map[string]any{}}
	for dec.More() {
		keyTok, err := dec.Token()
		if err != nil {
			return nil, err
		}
		key, ok := keyTok.(string)
		if !ok {
			return nil, fmt.Errorf("expected object key, got %T", keyTok)
		}
		valTok, err := dec.Token()
		if err != nil {
			return nil, err
		}
		val, err := decodeValue(dec, valTok)
		if err != nil {
			return nil, err
		}
		if _, dup := m.values[key]; !dup {
			m.keys = append(m.keys, key)
		}
		m.values[key] = val
	}
	// Consume closing '}'
	if _, err := dec.Token(); err != nil {
		return nil, err
	}
	return m, nil
}

func decodeArray(dec *json.Decoder) ([]any, error) {
	out := []any{}
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return nil, err
		}
		val, err := decodeValue(dec, tok)
		if err != nil {
			return nil, err
		}
		out = append(out, val)
	}
	if _, err := dec.Token(); err != nil {
		return nil, err
	}
	return out, nil
}
