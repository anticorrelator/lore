#!/usr/bin/env python3
"""Validate JSON documents against lore's JSON Schemas with the standard library.

Lore installs on whatever python3 (3.9+) a machine has, with nothing from pip,
so validation cannot depend on the third-party ``jsonschema`` package. This
module implements the JSON Schema 2020-12 keywords lore's schemas use, with
the same accept/reject results as ``jsonschema`` for them (tests/test_portability.py
checks parity whenever jsonschema happens to be installed).

A schema that uses a keyword this module does not implement is refused with
SchemaError rather than silently half-checked: adding such a keyword to
adapters/settings.schema.json fails ``lore doctor`` loudly until it is
implemented here. ``format`` is an annotation, as it is for
``jsonschema.validate`` by default.

Usage:
    python3 lore_schema.py <schema.json> <instance.json>
        exit 0  valid
        exit 1  invalid; prints "validation failed at <path>: <message>"
        exit 2  unreadable input or unsupported schema

API:
    validate(instance, schema)   raise ValidationError for the first error
    errors(instance, schema)     list of every ValidationError
    is_valid(instance, schema)   bool
"""

from __future__ import annotations

import json
import re
import sys

# Keywords that carry no assertion.
_ANNOTATIONS = frozenset({
    "$schema", "$id", "$comment", "$anchor", "title", "description", "default",
    "examples", "deprecated", "readOnly", "writeOnly", "format",
})
_DEFS = frozenset({"$defs", "definitions"})
_ASSERTIONS = frozenset({
    "type", "enum", "const",
    "properties", "required", "additionalProperties", "patternProperties",
    "minProperties", "maxProperties",
    "items", "minItems", "maxItems", "uniqueItems",
    "minLength", "maxLength", "pattern",
    "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum",
    "allOf", "anyOf", "oneOf", "not", "$ref",
})


class SchemaError(Exception):
    """The schema uses something this validator does not implement."""


class ValidationError(Exception):
    def __init__(self, message: str, path=()):
        super().__init__(message)
        self.message = message
        self.path = tuple(path)

    @property
    def path_str(self) -> str:
        return "/".join(str(p) for p in self.path) or "<root>"

    def __str__(self) -> str:
        return f"validation failed at {self.path_str}: {self.message}"


def _is_number(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


_TYPES = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
    "number": _is_number,
    "integer": lambda v: _is_number(v) and (isinstance(v, int) or float(v).is_integer()),
}


def _equal(a, b) -> bool:
    """JSON equality: booleans are not numbers, 1 equals 1.0."""
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if _is_number(a) and _is_number(b):
        return a == b
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(_equal(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(_equal(x, y) for x, y in zip(a, b))
    return type(a) is type(b) and a == b


class _Validator:
    def __init__(self, root):
        self.root = root
        self._check_schema(root, "#")

    # --- schema walk: refuse what is not implemented ---------------------

    def _resolve(self, ref: str):
        if not ref.startswith("#"):
            raise SchemaError(f"only local $ref is supported, got {ref!r}")
        node = self.root
        pointer = ref[1:]
        if pointer:
            if not pointer.startswith("/"):
                raise SchemaError(f"unsupported $ref {ref!r}")
            for part in pointer[1:].split("/"):
                part = part.replace("~1", "/").replace("~0", "~")
                if isinstance(node, dict) and part in node:
                    node = node[part]
                elif isinstance(node, list) and part.isdigit() and int(part) < len(node):
                    node = node[int(part)]
                else:
                    raise SchemaError(f"unresolvable $ref {ref!r}")
        return node

    def _check_schema(self, schema, where: str) -> None:
        if isinstance(schema, bool):
            return
        if not isinstance(schema, dict):
            raise SchemaError(f"schema at {where} is not an object or boolean")
        for key, value in schema.items():
            here = f"{where}/{key}"
            if key in _ANNOTATIONS:
                continue
            if key in _DEFS:
                for name, sub in value.items():
                    self._check_schema(sub, f"{here}/{name}")
                continue
            if key not in _ASSERTIONS:
                raise SchemaError(f"unsupported keyword {key!r} at {where}")
            if key in ("properties", "patternProperties"):
                for name, sub in value.items():
                    if key == "patternProperties":
                        re.compile(name)
                    self._check_schema(sub, f"{here}/{name}")
            elif key in ("additionalProperties", "not"):
                self._check_schema(value, here)
            elif key == "items":
                if isinstance(value, list):
                    raise SchemaError(f"array-form items at {where} is not 2020-12; use prefixItems")
                self._check_schema(value, here)
            elif key in ("allOf", "anyOf", "oneOf"):
                if not isinstance(value, list) or not value:
                    raise SchemaError(f"{key} at {where} must be a non-empty array")
                for i, sub in enumerate(value):
                    self._check_schema(sub, f"{here}/{i}")
            elif key == "$ref":
                self._resolve(value)
            elif key == "pattern":
                re.compile(value)
            elif key == "type":
                names = value if isinstance(value, list) else [value]
                unknown = [n for n in names if n not in _TYPES]
                if unknown:
                    raise SchemaError(f"unknown type {unknown} at {where}")

    # --- instance walk ---------------------------------------------------

    def errors(self, instance, schema, path):
        if schema is True:
            return
        if schema is False:
            yield ValidationError(f"{instance!r} is not allowed here (false schema)", path)
            return

        if "$ref" in schema:
            yield from self.errors(instance, self._resolve(schema["$ref"]), path)

        if "type" in schema:
            names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
            if not any(_TYPES[n](instance) for n in names):
                expected = names[0] if len(names) == 1 else names
                yield ValidationError(f"{instance!r} is not of type {expected!r}", path)
        if "enum" in schema and not any(_equal(instance, e) for e in schema["enum"]):
            yield ValidationError(f"{instance!r} is not one of {schema['enum']!r}", path)
        if "const" in schema and not _equal(instance, schema["const"]):
            yield ValidationError(f"{schema['const']!r} was expected, got {instance!r}", path)

        if isinstance(instance, dict):
            props = schema.get("properties", {})
            patterns = schema.get("patternProperties", {})
            for name in schema.get("required", []):
                if name not in instance:
                    yield ValidationError(f"{name!r} is a required property", path)
            extras = []
            for key, value in instance.items():
                matched = False
                if key in props:
                    matched = True
                    yield from self.errors(value, props[key], path + (key,))
                for pattern, sub in patterns.items():
                    if re.search(pattern, key):
                        matched = True
                        yield from self.errors(value, sub, path + (key,))
                if not matched:
                    extras.append(key)
            if "additionalProperties" in schema and extras:
                additional = schema["additionalProperties"]
                if additional is False:
                    names = ", ".join(repr(k) for k in extras)
                    verb = "was" if len(extras) == 1 else "were"
                    yield ValidationError(f"Additional properties are not allowed ({names} {verb} unexpected)", path)
                else:
                    for key in extras:
                        yield from self.errors(instance[key], additional, path + (key,))
            if "minProperties" in schema and len(instance) < schema["minProperties"]:
                yield ValidationError(f"{instance!r} has too few properties", path)
            if "maxProperties" in schema and len(instance) > schema["maxProperties"]:
                yield ValidationError(f"{instance!r} has too many properties", path)

        if isinstance(instance, list):
            if "items" in schema:
                for i, item in enumerate(instance):
                    yield from self.errors(item, schema["items"], path + (i,))
            if "minItems" in schema and len(instance) < schema["minItems"]:
                yield ValidationError(f"{instance!r} should have at least {schema['minItems']} item(s)", path)
            if "maxItems" in schema and len(instance) > schema["maxItems"]:
                yield ValidationError(f"{instance!r} should have at most {schema['maxItems']} item(s)", path)
            if schema.get("uniqueItems"):
                for i, a in enumerate(instance):
                    if any(_equal(a, b) for b in instance[i + 1:]):
                        yield ValidationError(f"{instance!r} has non-unique elements", path)
                        break

        if isinstance(instance, str):
            if "minLength" in schema and len(instance) < schema["minLength"]:
                yield ValidationError(f"{instance!r} is too short (minLength {schema['minLength']})", path)
            if "maxLength" in schema and len(instance) > schema["maxLength"]:
                yield ValidationError(f"{instance!r} is too long (maxLength {schema['maxLength']})", path)
            if "pattern" in schema and not re.search(schema["pattern"], instance):
                yield ValidationError(f"{instance!r} does not match {schema['pattern']!r}", path)

        if _is_number(instance):
            if "minimum" in schema and instance < schema["minimum"]:
                yield ValidationError(f"{instance!r} is less than the minimum of {schema['minimum']!r}", path)
            if "maximum" in schema and instance > schema["maximum"]:
                yield ValidationError(f"{instance!r} is greater than the maximum of {schema['maximum']!r}", path)
            if "exclusiveMinimum" in schema and instance <= schema["exclusiveMinimum"]:
                yield ValidationError(f"{instance!r} is not greater than {schema['exclusiveMinimum']!r}", path)
            if "exclusiveMaximum" in schema and instance >= schema["exclusiveMaximum"]:
                yield ValidationError(f"{instance!r} is not less than {schema['exclusiveMaximum']!r}", path)

        for sub in schema.get("allOf", []):
            yield from self.errors(instance, sub, path)
        if "anyOf" in schema and not any(self._ok(instance, s, path) for s in schema["anyOf"]):
            yield ValidationError(f"{instance!r} is not valid under any of the given schemas", path)
        if "oneOf" in schema:
            passing = sum(1 for s in schema["oneOf"] if self._ok(instance, s, path))
            if passing == 0:
                yield ValidationError(f"{instance!r} is not valid under any of the given schemas", path)
            elif passing > 1:
                yield ValidationError(f"{instance!r} is valid under each of {passing} oneOf schemas", path)
        if "not" in schema and self._ok(instance, schema["not"], path):
            yield ValidationError(f"{instance!r} should not be valid under {schema['not']!r}", path)

    def _ok(self, instance, schema, path) -> bool:
        return next(iter(self.errors(instance, schema, path)), None) is None


def errors(instance, schema) -> list:
    """Every validation error, in schema order. Raises SchemaError."""
    return list(_Validator(schema).errors(instance, schema, ()))


def validate(instance, schema) -> None:
    """Raise ValidationError for the first error. Raises SchemaError."""
    v = _Validator(schema)
    first = next(iter(v.errors(instance, schema, ())), None)
    if first is not None:
        raise first


def is_valid(instance, schema) -> bool:
    v = _Validator(schema)
    return v._ok(instance, schema, ())


def main(argv) -> int:
    if len(argv) != 3:
        print("usage: lore_schema.py <schema.json> <instance.json>", file=sys.stderr)
        return 2
    try:
        with open(argv[1], encoding="utf-8") as f:
            schema = json.load(f)
        with open(argv[2], encoding="utf-8") as f:
            instance = json.load(f)
    except (OSError, ValueError) as exc:
        print(f"cannot read input: {exc}")
        return 2
    try:
        validate(instance, schema)
    except SchemaError as exc:
        print(f"schema not supported by lore_schema: {exc}")
        return 2
    except ValidationError as exc:
        print(exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
