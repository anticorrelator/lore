#!/usr/bin/env python3
"""trust-compute: the published pure fold over the trust ledger.

Computes per-entry trust from `$KDIR/_trust/trust-events.jsonl` (contract:
architecture/trust-ledger/README.md in the knowledge store). Displayed trust
is never a stored field — this fold is recomputable from the raw ledger by
anyone, and this module is the single published definition of f(ledger).

The fold:

    signal(entry) = 1.0*held         - 2.0*contradicted
                  + 0.5*confirm_held - 1.0*confirm_contradicted
                  + 0.25*check_pass  - 0.5*check_fail
                  + 1.0*adj_confirmed - 2.0*adj_rejected
    trust(entry)  = signal / (1 + |signal|)        # open interval (-1, 1)

Negative outcomes weigh double their positive counterparts: acting on
falsified knowledge costs more than re-verifying held knowledge. Cheap
confirmations (a repo-state verdict without a code anchor) weigh half a
grounded verification — above mechanical checks, below anchored testimony —
preserving the same negative-doubles-positive symmetry. Mechanical checks
weigh below agent verifications because they are cheap and narrow. The
saturating map bounds any single entry's rank influence and makes each
marginal event worth less than the last.

Absence of ledger rows for an entry is an explicit unobserved state, not an
error and not a score of "distrusted" — callers receive None and map it to
rank-neutral 0.0 themselves.

Rows are deduped by event_id; malformed rows are excluded with a warning
(readers never re-validate rows the writer accepted — exclusion here covers
only rows the fold cannot attribute: broken JSON, missing envelope fields,
unknown event kinds). `provenance-migration` events redirect an entry key
forward without rewriting historical rows; unresolvable chains (loops,
conflicting targets) warn and leave rows attributed to their recorded path.

CLI:
    trust-compute.py <knowledge_dir> [--entry REL_PATH]... [--json]
"""

import argparse
import hashlib
import json
import os
import sys

LEDGER_RELPATH = os.path.join("_trust", "trust-events.jsonl")

EVENT_KINDS = (
    "consumption-verification",
    "mechanical-check",
    "adjudication",
    "provenance-migration",
    "trust-confirmation",
)

# Fold weights — protocol constants published here and in the contract doc.
WEIGHT_HELD = 1.0
WEIGHT_CONTRADICTED = -2.0
WEIGHT_CONFIRM_HELD = 0.5
WEIGHT_CONFIRM_CONTRADICTED = -1.0
WEIGHT_CHECK_PASS = 0.25
WEIGHT_CHECK_FAIL = -0.5
WEIGHT_ADJ_CONFIRMED = 1.0
WEIGHT_ADJ_REJECTED = -2.0

_COUNT_KEYS = (
    "held",
    "contradicted",
    "confirm_held",
    "confirm_contradicted",
    "check_pass",
    "check_fail",
    "check_other",
    "adj_confirmed",
    "adj_rejected",
)


# ---------------------------------------------------------------------------
# event_id recomputation (dedupe-bases table, contract doc section 4)
# ---------------------------------------------------------------------------

def compute_event_id(row: dict) -> str | None:
    """Recompute a row's event_id from its canonical pipe-joined basis.

    Must reproduce the writer's basis byte-identically; returns None when the
    row lacks the fields the basis needs.
    """
    event = row.get("event")
    payload = row.get("payload") or {}
    try:
        if event == "consumption-verification":
            basis = "|".join([
                event,
                row["entry_path"],
                payload["disposition"],
                row["source"],
                payload["file"],
                payload["line_range"],
            ])
        elif event == "mechanical-check":
            basis = "|".join([
                event,
                row["entry_path"],
                payload["check_name"],
                payload["target"],
                payload["result"],
                payload["run_id"],
            ])
        elif event == "adjudication":
            basis = "|".join([
                event,
                row["entry_path"],
                payload["claim_id"],
                payload["verdict"],
                payload["template_id"],
                payload["template_version"],
                payload["run_id"],
            ])
        elif event == "provenance-migration":
            basis = "|".join([
                event,
                payload["from_entry_path"],
                payload["to_entry_path"],
                payload["reason"],
            ])
        elif event == "trust-confirmation":
            basis = "|".join([
                event,
                row["entry_path"],
                payload["verdict"],
                row["source"],
                payload["sha"],
            ])
        else:
            return None
    except (KeyError, TypeError):
        return None
    return hashlib.sha256(basis.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------------
# JSONL codec
# ---------------------------------------------------------------------------

def serialize_row(row: dict) -> str:
    """One ledger row -> one JSONL line (no trailing newline)."""
    return json.dumps(row, ensure_ascii=False, separators=(",", ":"))


def parse_ledger_line(line: str) -> tuple[dict | None, str | None]:
    """One JSONL line -> (row, None) or (None, warning)."""
    stripped = line.strip()
    if not stripped:
        return None, None
    try:
        row = json.loads(stripped)
    except json.JSONDecodeError as e:
        return None, f"unparseable ledger line: {e}"
    if not isinstance(row, dict):
        return None, "ledger line is not a JSON object"
    return row, None


def read_ledger(ledger_path: str) -> tuple[list[dict], list[str]]:
    """Read all rows from a ledger file. Missing file -> ([], [])."""
    rows: list[dict] = []
    warnings: list[str] = []
    try:
        with open(ledger_path, encoding="utf-8") as f:
            for lineno, line in enumerate(f, 1):
                row, warning = parse_ledger_line(line)
                if warning:
                    warnings.append(f"line {lineno}: {warning}")
                elif row is not None:
                    rows.append(row)
    except FileNotFoundError:
        pass
    return rows, warnings


# ---------------------------------------------------------------------------
# The fold
# ---------------------------------------------------------------------------

def _validate_row(row: dict) -> str | None:
    """Return a warning string for rows the fold cannot attribute, else None."""
    event = row.get("event")
    if event not in EVENT_KINDS:
        return f"unknown event kind {event!r}"
    if not isinstance(row.get("event_id"), str) or not row["event_id"]:
        return f"missing event_id on {event} row"
    payload = row.get("payload")
    if not isinstance(payload, dict):
        return f"missing payload on {event} row"
    if event == "provenance-migration":
        if not payload.get("from_entry_path") or not payload.get("to_entry_path"):
            return "provenance-migration row missing from/to entry paths"
    elif not isinstance(row.get("entry_path"), str) or not row["entry_path"]:
        return f"missing entry_path on {event} row"
    return None


def _build_migrations(rows: list[dict], warnings: list[str]) -> dict[str, str]:
    """from_entry_path -> to_entry_path map; conflicting targets drop the key."""
    targets: dict[str, set[str]] = {}
    for row in rows:
        if row.get("event") != "provenance-migration":
            continue
        payload = row["payload"]
        targets.setdefault(payload["from_entry_path"], set()).add(payload["to_entry_path"])

    migrations: dict[str, str] = {}
    for from_path, to_paths in targets.items():
        if len(to_paths) > 1:
            warnings.append(
                f"conflicting migration targets for {from_path!r}: "
                f"{sorted(to_paths)}; rows stay under their recorded paths"
            )
        else:
            migrations[from_path] = next(iter(to_paths))
    return migrations


def resolve_entry_key(path: str, migrations: dict[str, str]) -> tuple[str, str | None]:
    """Follow the migration chain forward to the entry's current key.

    Returns (terminal_key, None) or, on a loop, (path unchanged, warning).
    """
    seen = {path}
    current = path
    while current in migrations:
        current = migrations[current]
        if current in seen:
            return path, (
                f"migration loop involving {path!r}; rows stay under their recorded paths"
            )
        seen.add(current)
    return current, None


def fold_rows(rows: list[dict]) -> tuple[dict[str, dict], dict[str, str], list[str]]:
    """Pure fold: ledger rows -> ({entry_key: summary}, migrations, warnings).

    Each summary is {"score": float, "signal": float, "counts": {...}}.
    Order-independent (scores derive from event counts, deduped by event_id)
    and idempotent under replay of already-seen rows.
    """
    warnings: list[str] = []
    deduped: list[dict] = []
    seen_ids: set[str] = set()
    for row in rows:
        warning = _validate_row(row)
        if warning:
            warnings.append(warning)
            continue
        if row["event_id"] in seen_ids:
            continue
        seen_ids.add(row["event_id"])
        deduped.append(row)

    migrations = _build_migrations(deduped, warnings)

    counts: dict[str, dict[str, int]] = {}
    for row in deduped:
        event = row["event"]
        if event == "provenance-migration":
            continue
        key, warning = resolve_entry_key(row["entry_path"], migrations)
        if warning:
            warnings.append(warning)
        entry_counts = counts.setdefault(key, {k: 0 for k in _COUNT_KEYS})
        payload = row["payload"]
        if event == "consumption-verification":
            disposition = payload.get("disposition")
            if disposition == "held":
                entry_counts["held"] += 1
            elif disposition == "contradicted":
                entry_counts["contradicted"] += 1
            else:
                warnings.append(f"unknown disposition {disposition!r}; row ignored")
        elif event == "mechanical-check":
            result = payload.get("result")
            if result == "pass":
                entry_counts["check_pass"] += 1
            elif result == "fail":
                entry_counts["check_fail"] += 1
            else:
                entry_counts["check_other"] += 1
        elif event == "adjudication":
            verdict = payload.get("verdict")
            if verdict == "confirmed":
                entry_counts["adj_confirmed"] += 1
            elif verdict == "rejected":
                entry_counts["adj_rejected"] += 1
            else:
                warnings.append(f"unknown verdict {verdict!r}; row ignored")
        elif event == "trust-confirmation":
            verdict = payload.get("verdict")
            if verdict == "held":
                entry_counts["confirm_held"] += 1
            elif verdict == "contradicted":
                entry_counts["confirm_contradicted"] += 1
            else:
                warnings.append(f"unknown confirmation verdict {verdict!r}; row ignored")

    scores: dict[str, dict] = {}
    for key, entry_counts in counts.items():
        signal = (
            WEIGHT_HELD * entry_counts["held"]
            + WEIGHT_CONTRADICTED * entry_counts["contradicted"]
            + WEIGHT_CONFIRM_HELD * entry_counts["confirm_held"]
            + WEIGHT_CONFIRM_CONTRADICTED * entry_counts["confirm_contradicted"]
            + WEIGHT_CHECK_PASS * entry_counts["check_pass"]
            + WEIGHT_CHECK_FAIL * entry_counts["check_fail"]
            + WEIGHT_ADJ_CONFIRMED * entry_counts["adj_confirmed"]
            + WEIGHT_ADJ_REJECTED * entry_counts["adj_rejected"]
        )
        scores[key] = {
            "score": signal / (1.0 + abs(signal)),
            "signal": signal,
            "counts": entry_counts,
        }

    return scores, migrations, sorted(set(warnings))


def compute_trust(knowledge_dir: str) -> tuple[dict[str, dict], dict[str, str], list[str]]:
    """Fold the store's ledger: (scores, migrations, warnings).

    A missing ledger file means every entry is unobserved — empty scores,
    no warnings.
    """
    ledger_path = os.path.join(os.path.abspath(knowledge_dir), LEDGER_RELPATH)
    rows, read_warnings = read_ledger(ledger_path)
    scores, migrations, fold_warnings = fold_rows(rows)
    return scores, migrations, sorted(set(read_warnings + fold_warnings))


def score_for_entry(
    scores: dict[str, dict], migrations: dict[str, str], rel_path: str
) -> dict | None:
    """Summary for one entry's KDIR-relative path, or None when unobserved."""
    key, _ = resolve_entry_key(rel_path, migrations)
    return scores.get(key)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _format_entry(key: str, summary: dict) -> str:
    c = summary["counts"]
    return (
        f"{summary['score']:+.3f}  held={c['held']} contradicted={c['contradicted']} "
        f"confirm=+{c['confirm_held']}/-{c['confirm_contradicted']} "
        f"checks=+{c['check_pass']}/-{c['check_fail']} "
        f"adj=+{c['adj_confirmed']}/-{c['adj_rejected']}  {key}"
    )


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="trust-compute.py",
        description="Recompute per-entry trust from the raw trust ledger.",
    )
    ap.add_argument("knowledge_dir", help="Path to the knowledge store directory")
    ap.add_argument(
        "--entry", action="append", default=[],
        help="KDIR-relative entry path to report (repeatable; default: all observed)",
    )
    ap.add_argument("--json", action="store_true", help="Emit JSON")
    args = ap.parse_args(argv)

    scores, migrations, warnings = compute_trust(args.knowledge_dir)

    if args.entry:
        selected = {}
        for rel in args.entry:
            summary = score_for_entry(scores, migrations, rel)
            selected[rel] = summary  # None = unobserved
    else:
        selected = dict(sorted(scores.items()))

    for warning in warnings:
        print(f"[trust-compute] warning: {warning}", file=sys.stderr)

    if args.json:
        print(json.dumps({"entries": selected, "warnings": warnings}, indent=2))
        return 0

    if not selected:
        print("(no observed entries)")
        return 0
    for key, summary in selected.items():
        if summary is None:
            print(f"unobserved  {key}")
        else:
            print(_format_entry(key, summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
