#!/usr/bin/env python3
"""expire-sweep.py — compute expiry candidates for unresolved knowledge entries.

Writes nothing. It reads the store, decides which entries have sat unresolved
long enough to leave the default result set, and prints them as JSON for
expire-sweep.sh, which owns every write.

An entry is a candidate when all of these hold:

  - Its `kind` declares a lifecycle in scripts/kind-registry.json (hypothesis
    and question do; fact and theory do not, and never expire).
  - Its `kind_status` is that kind's unresolved state — the first status the
    registry lists for the kind, which is the state an entry is written in
    before anyone settles it (`untested` for a hypothesis, `open` for a
    question).
  - Its entry `status` still puts it in the default result set. An entry already
    `expired` or `retired` is skipped, which is what makes a second run over the
    same store write nothing.
  - Nothing has touched it in --days days.

"Touched" comes from timestamps the entry declares about itself: the `learned`
and `updated` footer dates, plus the newest date in each footer provenance array
(corroborations, corrections, disputes, retirements, restorations,
confidence_advances, kind_status_transitions). Filesystem mtime is deliberately
not consulted — any store-wide rewrite resets it uniformly and would make the
whole store look untouched on the same day.

Usage:
    expire-sweep.py <kdir> [--days N] [--limit N] [--kind ID]...
                           [--today YYYY-MM-DD]

Output: a JSON object on stdout, diagnostics on stderr.

    {
      "generated_at": "<ISO-8601>",
      "threshold_days": 180,
      "scanned": 1293,
      "candidates": [
        {"entry_path": "conventions/x.md", "kind": "hypothesis",
         "kind_status": "untested", "last_declared_activity": "2025-06-01",
         "days_untouched": 434, "reason": "...", "falsifier": "..."}
      ],
      "skipped": {"<why>": <count>}
    }

`reason` and `falsifier` are generated here because this is where the dates and
the registry vocabulary are; the orchestrator passes them through to the entry.

Exit codes:
    0   the scan ran (an empty candidate list is a normal result)
    1   usage error
    2   the knowledge store or the kind registry could not be read
"""

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys

DEFAULT_DAYS = 180

META_RE = re.compile(r"<!--(.*?)-->", re.DOTALL)
KV_RE = re.compile(r"(\w+):\s*([^|>]+?)(?=\s*\||\s*$)")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
ISO_DATE_IN_TEXT = re.compile(r"\d{4}-\d{2}-\d{2}")

# Footer arrays whose items carry a date. Every one of them is written by
# apply-correction.sh when something happens to the entry, which is what makes
# them engagement signals rather than edit noise.
PROVENANCE_ARRAYS = (
    "corroborations",
    "corrections",
    "disputes",
    "retirements",
    "restorations",
    "confidence_advances",
    "kind_status_transitions",
)

# Entry statuses that already sit outside the default result set. Re-expiring one
# would be a no-op at the mutator anyway; skipping here keeps the candidate list
# honest about what a run would actually change.
OUT_OF_DEFAULT_STATUSES = ("expired", "retired")


def registry_kinds(script_dir):
    """{kind_id: [status, ...]} read through the registry's own reader CLI.

    Going through kind-registry.sh rather than loading the JSON keeps one
    accessor for the vocabulary, so this scan cannot drift from the writer's
    idea of which statuses a kind has.
    """
    reader = os.path.join(script_dir, "kind-registry.sh")

    def read(*args):
        proc = subprocess.run(
            ["bash", reader, *args], capture_output=True, text=True
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"kind-registry.sh {' '.join(args)} failed: {proc.stderr.strip()}"
            )
        return [line for line in proc.stdout.splitlines() if line.strip()]

    return {kind: read("get-statuses", kind) for kind in read("get-ids")}


def parse_footer(text):
    """(fields, arrays) from the entry's metadata comment, or (None, None).

    The block is the last HTML comment carrying `learned:` — the last block is
    what apply-correction.sh mutates, and the `learned:` test is what the
    retrieval parser uses to tell a footer from an ordinary comment.
    """
    blocks = [m.group(1) for m in META_RE.finditer(text)]
    candidates = [b for b in blocks if "learned:" in b] or blocks
    if not candidates:
        return None, None
    inner = candidates[-1]

    fields = {}
    for match in KV_RE.finditer(inner):
        key, value = match.group(1), match.group(2).strip()
        if key not in fields:
            fields[key] = value

    arrays = {}
    for field in PROVENANCE_ARRAYS:
        match = re.search(r"\|\s*" + field + r":\s*\[", inner)
        if not match:
            continue
        start = match.end() - 1
        try:
            items, _ = json.JSONDecoder().raw_decode(inner[start:])
        except ValueError:
            continue
        if isinstance(items, list):
            arrays[field] = items
    return fields, arrays


def parse_date(value):
    if not value:
        return None
    value = value.strip()
    match = ISO_DATE_IN_TEXT.match(value)
    if not match:
        return None
    try:
        return dt.date.fromisoformat(match.group(0))
    except ValueError:
        return None


def last_declared_activity(fields, arrays):
    """The newest date the entry declares about itself, or None."""
    dates = []
    for key in ("learned", "updated"):
        parsed = parse_date(fields.get(key))
        if parsed:
            dates.append(parsed)
    for items in arrays.values():
        for item in items:
            if not isinstance(item, dict):
                continue
            for key in ("observed_at", "date"):
                parsed = parse_date(str(item.get(key, "")))
                if parsed:
                    dates.append(parsed)
    return max(dates) if dates else None


def iter_entries(kdir):
    """Every knowledge entry file, in sorted order.

    `_`-prefixed names are the store's machine-substrate namespace and every
    content-rendering surface skips them; so does this one.
    """
    for root, dirnames, filenames in os.walk(kdir):
        dirnames[:] = sorted(
            d for d in dirnames if not d.startswith("_") and not d.startswith(".")
        )
        for name in sorted(filenames):
            if not name.endswith(".md") or name.startswith("_"):
                continue
            if name == "README.md":
                continue
            yield os.path.join(root, name)


def phrase_list(values):
    values = list(values)
    if not values:
        return ""
    if len(values) == 1:
        return values[0]
    return ", ".join(values[:-1]) + " or " + values[-1]


def describe(kind, kind_status, settled_statuses, days, since, rel_path):
    """The reason and falsifier the entry will carry.

    Stewardship, not a verdict: the reason says what has not happened rather
    than what the claim is worth, and the falsifier names what would bring the
    entry back.

    Both strings end up inside the entry's single-line footer, where "|" and ">"
    cannot survive — so no angle-bracket placeholders here, or the orchestrator's
    sanitizer will blank them out mid-sentence.
    """
    settled = phrase_list(settled_statuses)
    if kind == "question":
        reason = (
            f"Open for {days} days — nobody has recorded where they looked or what "
            f"answered it since {since}. Expiring it clears the unresolved shelf "
            f"without declaring the question unanswerable."
        )
    else:
        reason = (
            f"{kind_status.capitalize()} for {days} days — nothing has been recorded "
            f"for or against it since {since}. Expiring it clears the unresolved "
            f"shelf without deciding the claim."
        )
    falsifier = (
        f"One observation recorded either way, or a kind_status of {settled}. "
        f"Either means this was still live work, and "
        f"`lore retire {rel_path} --restore` brings it back at the status it "
        f"held before."
    )
    return reason, falsifier


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("kdir")
    parser.add_argument("--days", type=int, default=DEFAULT_DAYS)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument(
        "--kind",
        action="append",
        default=[],
        help="restrict the scan to this kind (repeatable)",
    )
    parser.add_argument("--today", default="")
    args = parser.parse_args()

    if args.days < 0:
        print("[expire-sweep] error: --days must not be negative", file=sys.stderr)
        return 1
    if not os.path.isdir(args.kdir):
        print(
            f"[expire-sweep] error: knowledge store not found: {args.kdir}",
            file=sys.stderr,
        )
        return 2

    if args.today:
        if not DATE_RE.match(args.today):
            print(
                "[expire-sweep] error: --today must match YYYY-MM-DD",
                file=sys.stderr,
            )
            return 1
        today = dt.date.fromisoformat(args.today)
    else:
        today = dt.datetime.now(dt.timezone.utc).date()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    try:
        kinds = registry_kinds(script_dir)
    except (RuntimeError, OSError) as e:
        print(f"[expire-sweep] error: {e}", file=sys.stderr)
        return 2

    # A kind's first declared status is the one an entry is written in before
    # anyone settles it, so that is the state a clock can run out on.
    expirable = {
        kind: (statuses[0], statuses[1:])
        for kind, statuses in kinds.items()
        if statuses
    }
    if args.kind:
        unknown = [k for k in args.kind if k not in kinds]
        if unknown:
            print(
                f"[expire-sweep] error: unknown kind(s): {', '.join(unknown)}",
                file=sys.stderr,
            )
            return 1
        expirable = {k: v for k, v in expirable.items() if k in args.kind}

    candidates = []
    skipped = {
        "no_footer": 0,
        "no_lifecycle": 0,
        "settled": 0,
        "already_out_of_default": 0,
        "no_declared_date": 0,
        "fresh": 0,
    }
    scanned = 0

    for path in iter_entries(args.kdir):
        try:
            text = open(path, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            skipped["no_footer"] += 1
            continue
        scanned += 1
        fields, arrays = parse_footer(text)
        if fields is None:
            skipped["no_footer"] += 1
            continue

        kind = (fields.get("kind") or "fact").strip() or "fact"
        if kind not in expirable:
            skipped["no_lifecycle"] += 1
            continue
        unresolved, settled_statuses = expirable[kind]
        if (fields.get("kind_status") or "").strip() != unresolved:
            skipped["settled"] += 1
            continue
        if (fields.get("status") or "current").strip() in OUT_OF_DEFAULT_STATUSES:
            skipped["already_out_of_default"] += 1
            continue

        since = last_declared_activity(fields, arrays)
        if since is None:
            skipped["no_declared_date"] += 1
            continue
        days = (today - since).days
        if days < args.days:
            skipped["fresh"] += 1
            continue

        rel_path = os.path.relpath(path, args.kdir)
        reason, falsifier = describe(
            kind, unresolved, settled_statuses, days, since.isoformat(), rel_path
        )
        candidates.append(
            {
                "entry_path": rel_path,
                "kind": kind,
                "kind_status": unresolved,
                "last_declared_activity": since.isoformat(),
                "days_untouched": days,
                "reason": reason,
                "falsifier": falsifier,
            }
        )

    candidates.sort(key=lambda c: (-c["days_untouched"], c["entry_path"]))
    truncated = False
    if args.limit > 0 and len(candidates) > args.limit:
        candidates = candidates[: args.limit]
        truncated = True

    json.dump(
        {
            "generated_at": dt.datetime.now(dt.timezone.utc)
            .replace(microsecond=0)
            .isoformat()
            .replace("+00:00", "Z"),
            "threshold_days": args.days,
            "as_of": today.isoformat(),
            "scanned": scanned,
            "truncated": truncated,
            "candidates": candidates,
            "skipped": skipped,
        },
        sys.stdout,
        indent=2,
    )
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
