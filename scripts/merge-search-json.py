#!/usr/bin/env python3
"""merge-search-json.py — Combine the two halves of `lore search --type all --json`.

The knowledge half is a flat result list, or an object carrying `results`,
`sections`, and `degraded` when the caller passed --kind-sections. The work half
is always a flat list: kind sections are asked of the knowledge pool alone, so
there is never a second `sections` array to reconcile here.

Usage: merge-search-json.py <knowledge-json> <work-json>
"""

import json
import sys


def merge(knowledge, work: list):
    """Append the work results to the knowledge half, keeping its shape.

    Raises TypeError when either half is not the shape the caller promised.
    """
    if not isinstance(work, list):
        raise TypeError(
            "the work half must be a flat result list; got "
            f"{type(work).__name__}. Kind sections are requested of the "
            "knowledge pool only."
        )
    if isinstance(knowledge, dict):
        merged = dict(knowledge)
        merged["results"] = list(knowledge.get("results", [])) + work
        return merged
    if isinstance(knowledge, list):
        return knowledge + work
    raise TypeError(
        "the knowledge half must be a flat result list or a sections object; "
        f"got {type(knowledge).__name__}."
    )


def fail(message: str) -> None:
    # stdout stays empty so a consumer parsing it never reads a partial merge.
    print(json.dumps({"error": message}), file=sys.stderr)
    sys.exit(1)


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: merge-search-json.py <knowledge-json> <work-json>")
    halves = []
    for label, raw in (("knowledge", sys.argv[1]), ("work", sys.argv[2])):
        try:
            halves.append(json.loads(raw))
        except json.JSONDecodeError as e:
            fail(f"the {label} half is not valid JSON: {e}")
    try:
        merged = merge(halves[0], halves[1])
    except TypeError as e:
        fail(str(e))
    print(json.dumps(merged, indent=2))


if __name__ == "__main__":
    main()
