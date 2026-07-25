#!/usr/bin/env python3
"""prune-retired-settings.py — drop top-level settings keys the schema rejects.

Runs from install.sh against ~/.lore/config/settings.json. Existing installs
accumulate top-level blocks whose keys were later retired from the schema;
because adapters/settings.schema.json is `additionalProperties: false` at the
root, a stale block fails `lore doctor`'s schema check on every run. This pass
removes them so an upgrade heals the file instead of flagging it forever.

Authority boundary: the SCHEMA decides what is retired, never this script and
never a list maintained alongside it. "Absent from the schema's top-level
`properties`" and "rejected by the schema" are the same statement when
additionalProperties is false, so the derivation is exact rather than a
heuristic. The predecessor of this script hardcoded `("settlement", "capture")`;
`settlement` was re-introduced to the schema in 884c20b and the tuple was never
revisited, so every install silently deleted live settlement configuration --
including `max_concurrency`, whose absence fail-closes the coordination
concurrency ceiling to 1. A hand-maintained list cannot drift from the schema if
there is no hand-maintained list.

Nested keys are out of scope: this prunes the top level only. Sub-object drift
is doctor's business, and removing an inner key is far more likely to be a
schema bug than a retirement.

Contract:
    Input  — --settings PATH (the settings.json to prune, in place)
             --schema PATH   (the authoritative schema to derive from)
    Output — one `pruned: <keys>` line and one `backup: <path>` line on stdout
             when keys were removed; silence when there was nothing to do.
    Exit   — 0 on a successful prune AND on a no-op. Non-zero is reserved for
             conditions under which pruning would be unsound (unreadable or
             unparseable schema, schema that admits additional properties,
             unreadable settings file). The caller warns and leaves the file
             untouched -- refusing to prune costs a doctor warning, while
             pruning on a bad derivation costs the user's configuration.

Recovery: the pre-prune file is copied to `<settings>.bak` before the atomic
replace, and only when there is something to prune. A prune that removes the
wrong key is therefore recoverable by hand, which the previous unconditional
os.replace made impossible.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile


def schema_allowed_keys(schema_path: str) -> set[str]:
    """Top-level property names the schema accepts.

    Raises ValueError when the schema cannot support the derivation -- either it
    is not readable/parseable, or it permits additional properties, in which case
    "absent from properties" no longer implies "rejected".
    """
    try:
        with open(schema_path, "r", encoding="utf-8") as f:
            schema = json.load(f)
    except OSError as exc:
        raise ValueError(f"schema unreadable at {schema_path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"schema is not valid JSON at {schema_path}: {exc}") from exc

    if not isinstance(schema, dict):
        raise ValueError(f"schema root is not an object at {schema_path}")

    if schema.get("additionalProperties") is not False:
        raise ValueError(
            f"schema at {schema_path} does not set additionalProperties:false at "
            "the root -- unknown top-level keys are legal, so no key can be "
            "derived as retired"
        )

    properties = schema.get("properties")
    if not isinstance(properties, dict) or not properties:
        raise ValueError(f"schema at {schema_path} has no top-level properties map")

    return set(properties)


def retired_keys(doc: dict, allowed: set[str]) -> list[str]:
    """Top-level keys present in the document but absent from the schema."""
    return sorted(k for k in doc if k not in allowed)


def prune(settings_path: str, schema_path: str) -> list[str]:
    """Remove schema-rejected top-level keys in place. Returns what was removed."""
    allowed = schema_allowed_keys(schema_path)

    try:
        with open(settings_path, "r", encoding="utf-8") as f:
            doc = json.load(f)
    except OSError as exc:
        raise ValueError(f"settings unreadable at {settings_path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(
            f"settings is not valid JSON at {settings_path}: {exc}"
        ) from exc

    if not isinstance(doc, dict):
        return []

    removed = retired_keys(doc, allowed)
    if not removed:
        return []

    # Back up the original bytes before anything is overwritten. Copied rather
    # than re-serialized so the backup is the file the user actually had.
    backup_path = settings_path + ".bak"
    shutil.copy2(settings_path, backup_path)

    for key in removed:
        doc.pop(key, None)

    config_dir = os.path.dirname(settings_path) or "."
    fd, tmp_path = tempfile.mkstemp(prefix=".settings.", suffix=".tmp", dir=config_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(doc, f, indent=2, sort_keys=True)
            f.write("\n")
        os.replace(tmp_path, settings_path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

    return removed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Prune top-level settings keys the schema no longer accepts."
    )
    parser.add_argument("--settings", required=True, help="settings.json to prune")
    parser.add_argument("--schema", required=True, help="authoritative settings schema")
    args = parser.parse_args(argv)

    if not os.path.exists(args.settings):
        return 0

    try:
        removed = prune(args.settings, args.schema)
    except ValueError as exc:
        print(f"prune-retired-settings: {exc}", file=sys.stderr)
        return 1

    if removed:
        print(f"  [lore] pruned: {', '.join(removed)}")
        print(f"  [lore] backup: {args.settings}.bak")
    return 0


if __name__ == "__main__":
    sys.exit(main())
