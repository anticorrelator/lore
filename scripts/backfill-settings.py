#!/usr/bin/env python3
"""Add missing schema-declared top-level settings from the shipped template.

This upgrade pass is deliberately shallower than a recursive merge. A top-level
key already present in settings.json belongs to the user in its entirety, so the
template never fills missing nested members inside that key. Only a top-level
key that is both declared by the closed schema and present in the template can
be copied into an existing settings document.

The pass is atomic and fail-closed. An unreadable or malformed schema, template,
or settings file produces a non-zero exit and leaves settings.json untouched.
An absent settings file is a silent no-op, matching the create-only migration in
install.sh: fresh installs are seeded directly from the template instead.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from typing import Any


def load_json_object(path: str, label: str) -> dict[str, Any]:
    """Read a JSON object or raise a refusal-oriented ValueError."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            value = json.load(handle)
    except OSError as exc:
        raise ValueError(f"{label} unreadable at {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"{label} is not valid JSON at {path}: {exc}") from exc

    if not isinstance(value, dict):
        raise ValueError(f"{label} root is not an object at {path}")
    return value


def schema_allowed_keys(schema_path: str) -> set[str]:
    """Return the closed schema's declared top-level property names."""
    schema = load_json_object(schema_path, "schema")
    if schema.get("additionalProperties") is not False:
        raise ValueError(
            f"schema at {schema_path} does not set additionalProperties:false at "
            "the root -- it cannot authoritatively bound top-level backfill keys"
        )
    properties = schema.get("properties")
    if not isinstance(properties, dict) or not properties:
        raise ValueError(f"schema at {schema_path} has no top-level properties map")
    return set(properties)


def backfill(settings_path: str, schema_path: str, template_path: str) -> list[str]:
    """Copy missing eligible top-level keys and return their names."""
    allowed = schema_allowed_keys(schema_path)
    template = load_json_object(template_path, "template")
    try:
        with open(settings_path, "r", encoding="utf-8") as handle:
            original = handle.read()
        settings = json.loads(original)
    except OSError as exc:
        raise ValueError(f"settings unreadable at {settings_path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(
            f"settings is not valid JSON at {settings_path}: {exc}"
        ) from exc

    if not isinstance(settings, dict):
        raise ValueError(f"settings root is not an object at {settings_path}")

    added = [key for key in template if key in allowed and key not in settings]
    if not added:
        return []

    for key in added:
        settings[key] = template[key]

    # Splice only the new members into the original JSON text. Re-serializing
    # the whole document would preserve Python values but rewrite the bytes of
    # every existing top-level value (number spelling, whitespace, key order).
    # The add-only contract is stronger: bytes already owned by the user stay
    # exactly as written.
    closing = len(original.rstrip()) - 1
    if closing < 0 or original[closing] != "}":
        raise ValueError(f"settings root is not an object at {settings_path}")
    rendered = json.dumps(
        {key: template[key] for key in added}, indent=2, sort_keys=False
    ).splitlines()
    member_block = "\n".join(rendered[1:-1])

    if settings.keys() - set(added):
        insertion_at = closing
        while insertion_at > 0 and original[insertion_at - 1].isspace():
            insertion_at -= 1
        preserved_inner_whitespace = original[insertion_at:closing] or "\n"
        updated = (
            original[:insertion_at]
            + ","
            + preserved_inner_whitespace
            + member_block
            + "\n"
            + original[closing:]
        )
    else:
        preserved_inner_whitespace = original[1:closing] or "\n"
        updated = (
            original[:1]
            + preserved_inner_whitespace
            + member_block
            + "\n"
            + original[closing:]
        )

    config_dir = os.path.dirname(settings_path) or "."
    fd, tmp_path = tempfile.mkstemp(
        prefix=".settings.", suffix=".tmp", dir=config_dir
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(updated)
        os.replace(tmp_path, settings_path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

    return added


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Add missing schema-declared top-level settings from the template."
        )
    )
    parser.add_argument("--settings", required=True, help="settings.json to update")
    parser.add_argument("--schema", required=True, help="authoritative settings schema")
    parser.add_argument("--template", required=True, help="shipped settings template")
    args = parser.parse_args(argv)

    if not os.path.exists(args.settings):
        return 0

    try:
        added = backfill(args.settings, args.schema, args.template)
    except ValueError as exc:
        print(f"backfill-settings: {exc}", file=sys.stderr)
        return 1

    if added:
        print(f"  [lore] backfilled: {', '.join(added)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
