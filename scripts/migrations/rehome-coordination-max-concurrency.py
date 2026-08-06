#!/usr/bin/env python3
"""rehome-coordination-max-concurrency.py — move the coordination board's seat
ceiling onto its own settings key.

scripts/coordinate-status.sh used to read its ceiling from
`settlement.max_concurrency` — a key inside a block named for a different
subsystem. The board now reads `coordination.max_concurrency`. This pass copies
a live `settlement.max_concurrency` onto the new key so an existing install
keeps the ceiling its owner set instead of silently fail-closing to one seat.

Ordering: this MUST run before any pass that can remove the `settlement` block.
install.sh's retired-key prune derives its retired set from
adapters/settings.schema.json, so the moment the schema stops declaring
`settlement` the prune deletes the live value — reading it and deleting it
become the same act if unsequenced. install.sh invokes this script immediately
before that prune for exactly that reason.

Contract:
    Target — the settings.json scripts/lore_settings.py resolves
             ($LORE_DATA_DIR/config/settings.json; LORE_DATA_DIR honored).
    Output — one `rehome-coordination-max-concurrency: <outcome>` line, or a
             JSON envelope under --json.
    Exit   — 0 on a rehome AND on every no-op outcome. Non-zero is reserved for
             a settings file that cannot be read or written.

Outcomes:
    already-rehomed — `coordination.max_concurrency` is already set; left alone.
    rehomed         — copied from `settlement.max_concurrency`.
    no-source       — nothing to carry: no usable `settlement.max_concurrency`.
                      The reader's fail-closed default already matches what
                      that install was getting, so writing a value would invent
                      configuration rather than preserve it.
    no-settings     — no settings.json yet; a fresh install seeds the key from
                      adapters/settings.template.json instead.

Idempotence: the new key's presence is the completion record, so a second run
reports `already-rehomed` and writes nothing. A ceiling the owner has since
changed by hand is never overwritten.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import lore_settings  # noqa: E402

SOURCE_KEY = "settlement.max_concurrency"
TARGET_KEY = "coordination.max_concurrency"

# The shell reader accepted any stdout matching this before the rehome, so a
# stringified count was a working ceiling. Carry it across as the integer the
# schema asks for rather than dropping the user to one seat on a technicality.
_POSITIVE_INT_TEXT = re.compile(r"^[1-9][0-9]*$")


def usable_ceiling(value: object) -> int | None:
    """Return the positive seat count a value denotes, or None if it denotes none."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int) and value >= 1:
        return value
    if isinstance(value, str) and _POSITIVE_INT_TEXT.match(value):
        return int(value)
    return None


def rehome(dry_run: bool = False) -> dict:
    """Copy a live settlement ceiling onto the coordination key. Returns the outcome."""
    settings_path = lore_settings.path()
    if not os.path.exists(settings_path):
        return {"outcome": "no-settings", "settings": settings_path, "value": None}

    existing = lore_settings.get(TARGET_KEY)
    if existing is not None:
        return {
            "outcome": "already-rehomed",
            "settings": settings_path,
            "value": existing,
        }

    ceiling = usable_ceiling(lore_settings.get(SOURCE_KEY))
    if ceiling is None:
        return {"outcome": "no-source", "settings": settings_path, "value": None}

    if not dry_run:
        lore_settings.set(TARGET_KEY, ceiling)
    return {"outcome": "rehomed", "settings": settings_path, "value": ceiling}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Copy a live settlement.max_concurrency onto coordination.max_concurrency."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="report the outcome without writing settings.json",
    )
    parser.add_argument("--json", action="store_true", help="emit a JSON envelope")
    args = parser.parse_args(argv)

    try:
        result = rehome(dry_run=args.dry_run)
    except lore_settings.SettingsError as exc:
        print(f"rehome-coordination-max-concurrency: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"rehome-coordination-max-concurrency: {exc}", file=sys.stderr)
        return 1

    result["dry_run"] = args.dry_run
    if args.json:
        print(json.dumps(result, sort_keys=True))
    else:
        detail = "" if result["value"] is None else f" ({TARGET_KEY}={result['value']})"
        prefix = "would " if args.dry_run and result["outcome"] == "rehomed" else ""
        print(f"  [lore] rehome-coordination-max-concurrency: {prefix}{result['outcome']}{detail}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
