#!/usr/bin/env python3
"""Schema validation for the `_packets/` substrate — single source of truth.

Two row kinds share this module:
  - packet rows      (`_packets/packets.jsonl`,     written by packet-append.sh)
  - assessment rows  (`_packets/assessments.jsonl`, written by packet-assessment-append.sh)

Bash writers invoke it via stdin:

    python3 "$SCRIPT_DIR/packet_schema.py" --kind packet     < row.json
    python3 "$SCRIPT_DIR/packet_schema.py" --kind assessment < row.json
    python3 "$SCRIPT_DIR/packet_schema.py" --sha   # sha256 of this module's bytes

Exit 0 on a valid row (silent); exit 1 with one `packet-schema: <error>` line
per violation on stderr. Python callers import validate_packet_row /
validate_assessment_row directly.

`--sha` prints the sha256 of this file's bytes — the value writers stamp as
`packet_schema_sha` so readers can detect which schema revision validated a
row. Validation checks the stamp's format only (64-char hex), not its value:
rows are validated once at write time, and a reader comparing shas across
rows is how schema drift is detected.

Packets accept schema versions "1" and "2"; assessments retain version "1".
Version 2 binds task packets to a committed revision and dispatch attempt.
Unknown extra fields remain accepted.

Synthesis. A row at delivery_stage "assembled" is a candidate set: one
retrieval pass, nobody's judgment yet. A row at "synthesized" supersedes it
under the same packet_id and carries a `synthesis` object — who judged it,
which delivered paths were kept, which were dropped and why, which were added
and why. Dropped and kept are disjoint; every dropped or added path names a
reason. A row at any other stage carries no `synthesis`. A dispatcher that
hands an assembled packet on records a `synthesis_waiver` (who, why) instead;
readers treat an assembled packet with neither as not ready to hand on.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

PACKET_SCOPES = ("session", "task")
DELIVERY_STAGES = ("assembled", "synthesized", "delivered")
# Union of the two delivery surfaces' vocabularies: the dispatch manifest
# renders full|snippet|backlink (pk_manifest.py degradation ladder); the
# session loader renders full|summary|skipped (load-knowledge.sh budget
# accounting). Entries record whichever mode they actually experienced.
RENDER_MODES = ("full", "summary", "snippet", "backlink", "skipped")
RANKING_PATHS = ("search-order", "composite-rerank")
VERDICT_CLASSES = ("unused", "harmful", "missing", "unattributed_retrieval")

_SHA256_HEX = frozenset("0123456789abcdef")


def _is_sha256_hex(v) -> bool:
    return isinstance(v, str) and len(v) == 64 and set(v) <= _SHA256_HEX


def _is_template_version(v) -> bool:
    return isinstance(v, str) and len(v) == 12 and set(v) <= _SHA256_HEX


def _is_nonempty_str(v) -> bool:
    return isinstance(v, str) and v != ""


def _is_int(v) -> bool:
    # bool is an int subclass; a True chars_used must not validate.
    return isinstance(v, int) and not isinstance(v, bool)


def schema_sha() -> str:
    """sha256 of this module's bytes — the packet_schema_sha stamp value."""
    with open(os.path.realpath(__file__), "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def _check_stamps(row: dict, errors: list[str], versions=("1",)) -> None:
    """Stamps common to both row kinds (writer-applied; see writer headers)."""
    if row.get("schema_version") not in versions:
        errors.append("schema_version must be one of " + "|".join(versions))
    if not _is_sha256_hex(row.get("packet_schema_sha")):
        errors.append("packet_schema_sha must be a 64-char lowercase sha256 hex string")
    if not _is_nonempty_str(row.get("model")):
        errors.append("model must be a non-empty string")
    for key in ("captured_at_branch", "captured_at_sha", "captured_at_merge_base_sha"):
        if key not in row:
            errors.append(f"{key} key is required (string or null)")
        elif row[key] is not None and not _is_nonempty_str(row[key]):
            errors.append(f"{key} must be a non-empty string or null")


def _check_delivered_entry(entry, idx: int, errors: list[str]) -> None:
    prefix = f"delivered_entries[{idx}]"
    if not isinstance(entry, dict):
        errors.append(f"{prefix} must be an object")
        return
    if not _is_nonempty_str(entry.get("path")):
        errors.append(f"{prefix}.path must be a non-empty string")
    if entry.get("render_mode") not in RENDER_MODES:
        errors.append(f"{prefix}.render_mode must be one of {'|'.join(RENDER_MODES)}")
    if entry.get("ranking_path") not in RANKING_PATHS:
        errors.append(f"{prefix}.ranking_path must be one of {'|'.join(RANKING_PATHS)}")
    trust = entry.get("trust")
    if not isinstance(trust, dict):
        errors.append(f"{prefix}.trust must be an object")
        return
    score = trust.get("score", "missing")
    if score == "missing" or not (
        score is None or (isinstance(score, (int, float)) and not isinstance(score, bool))
    ):
        errors.append(f"{prefix}.trust.score must be a number or null")
    if not _is_nonempty_str(trust.get("status")):
        errors.append(f"{prefix}.trust.status must be a non-empty string")
    if not _is_nonempty_str(trust.get("confidence")):
        errors.append(f"{prefix}.trust.confidence must be a non-empty string")
    if "correction_recency" not in trust:
        errors.append(f"{prefix}.trust.correction_recency key is required (string or null)")
    elif trust["correction_recency"] is not None and not _is_nonempty_str(
        trust["correction_recency"]
    ):
        errors.append(f"{prefix}.trust.correction_recency must be a non-empty string or null")


def _check_reasoned_paths(items, name: str, errors: list[str]) -> list[str]:
    paths: list[str] = []
    if not isinstance(items, list):
        errors.append(f"synthesis.{name} must be an array")
        return paths
    for idx, item in enumerate(items):
        prefix = f"synthesis.{name}[{idx}]"
        if not isinstance(item, dict):
            errors.append(f"{prefix} must be an object")
            continue
        if not _is_nonempty_str(item.get("path")):
            errors.append(f"{prefix}.path must be a non-empty string")
        else:
            paths.append(item["path"])
        if not _is_nonempty_str(item.get("reason")):
            errors.append(f"{prefix}.reason must be a non-empty string")
    return paths


def _check_synthesis(row: dict, errors: list[str]) -> None:
    """The synthesis record travels only on synthesized rows; a waiver only on unsynthesized ones."""
    stage = row.get("delivery_stage")
    synthesis = row.get("synthesis")
    waiver = row.get("synthesis_waiver")
    if stage == "synthesized":
        if not isinstance(synthesis, dict):
            errors.append("synthesis must be an object when delivery_stage is \"synthesized\"")
            return
        if not _is_nonempty_str(synthesis.get("by")):
            errors.append("synthesis.by must be a non-empty string")
        if not _is_nonempty_str(synthesis.get("synthesized_at")):
            errors.append("synthesis.synthesized_at must be a non-empty string (ISO 8601)")
        kept = synthesis.get("kept")
        if not isinstance(kept, list) or any(not _is_nonempty_str(k) for k in kept):
            errors.append("synthesis.kept must be an array of non-empty path strings")
            kept = []
        dropped = _check_reasoned_paths(synthesis.get("dropped"), "dropped", errors)
        added = _check_reasoned_paths(synthesis.get("added"), "added", errors)
        if set(kept) & set(dropped):
            errors.append("synthesis.kept and synthesis.dropped must be disjoint")
        if set(added) & (set(kept) | set(dropped)):
            errors.append("synthesis.added must not repeat a kept or dropped path")
        if waiver is not None:
            errors.append("synthesis_waiver must be absent on a synthesized row")
        return
    if synthesis is not None:
        errors.append("synthesis must be absent unless delivery_stage is \"synthesized\"")
    if waiver is not None:
        if not isinstance(waiver, dict) or not _is_nonempty_str(waiver.get("by")) or not _is_nonempty_str(waiver.get("reason")):
            errors.append("synthesis_waiver must be an object with non-empty by and reason")


def validate_packet_row(row) -> list[str]:
    """Return a list of violations for a packet (delivery) row; empty == valid."""
    if not isinstance(row, dict):
        return ["row must be a JSON object"]
    errors: list[str] = []

    if not _is_nonempty_str(row.get("packet_id")):
        errors.append("packet_id must be a non-empty string")

    scope = row.get("packet_scope")
    if scope not in PACKET_SCOPES:
        errors.append(f"packet_scope must be one of {'|'.join(PACKET_SCOPES)}")
    if row.get("delivery_stage") not in DELIVERY_STAGES:
        errors.append(f"delivery_stage must be one of {'|'.join(DELIVERY_STAGES)}")

    # Experiment join keys. All keys must be present; nullability varies.
    for key in ("session_id", "work_item", "arm", "task_scale_set"):
        if key not in row:
            errors.append(f"{key} key is required (string or null)")
        elif row[key] is not None and not _is_nonempty_str(row[key]):
            errors.append(f"{key} must be a non-empty string or null")
    if "phase" not in row:
        errors.append("phase key is required (string, integer, or null)")
    elif row["phase"] is not None and not (_is_nonempty_str(row["phase"]) or _is_int(row["phase"])):
        errors.append("phase must be a non-empty string, integer, or null")

    # task_id is null exactly for session-scope rows.
    if "task_id" not in row:
        errors.append("task_id key is required (string, or null for session scope)")
    else:
        task_id = row["task_id"]
        if scope == "task" and not _is_nonempty_str(task_id):
            errors.append("task_id must be a non-empty string when packet_scope is \"task\"")
        elif scope == "session" and task_id is not None:
            errors.append("task_id must be null when packet_scope is \"session\"")
        elif task_id is not None and not _is_nonempty_str(task_id):
            errors.append("task_id must be a non-empty string or null")

    entries = row.get("delivered_entries", "missing")
    if entries == "missing" or not isinstance(entries, list):
        errors.append("delivered_entries must be an array")
    else:
        for idx, entry in enumerate(entries):
            _check_delivered_entry(entry, idx, errors)
        empty_reason = row.get("empty_reason")
        if len(entries) == 0:
            if not _is_nonempty_str(empty_reason):
                errors.append(
                    "empty_reason must be a non-empty string when delivered_entries is empty"
                )
        elif empty_reason is not None:
            errors.append("empty_reason must be absent or null when delivered_entries is non-empty")

    budget = row.get("budget")
    if not isinstance(budget, dict):
        errors.append("budget must be an object")
    else:
        for key, minimum in (("chars_used", 0), ("chars_budget", 1)):
            if key not in budget:
                errors.append(f"budget.{key} key is required (integer or null)")
            elif budget[key] is not None and not (_is_int(budget[key]) and budget[key] >= minimum):
                errors.append(f"budget.{key} must be an integer >= {minimum} or null")

    if not _is_nonempty_str(row.get("delivered_at")):
        errors.append("delivered_at must be a non-empty string (ISO 8601)")

    if not _is_sha256_hex(row.get("trust_compute_sha")):
        errors.append("trust_compute_sha must be a 64-char lowercase sha256 hex string")
    if "template_version" not in row:
        errors.append("template_version key is required (12-char hex or null)")
    elif row["template_version"] is not None and not _is_template_version(row["template_version"]):
        errors.append("template_version must be a 12-char lowercase hex string or null")

    _check_synthesis(row, errors)

    if row.get("schema_version") == "2":
        if scope != "task":
            errors.append('schema 2 requires packet_scope "task"')
        for key in ("work_item", "dispatch_attempt_id"):
            if not _is_nonempty_str(row.get(key)):
                errors.append(f"{key} must be a non-empty string for schema 2")
        if not _is_template_version(row.get("revision_id")):
            errors.append("revision_id must be a 12-char lowercase hex string for schema 2")
        if "source_head" not in row or (row["source_head"] is not None and not _is_nonempty_str(row["source_head"])):
            errors.append("source_head is required (non-empty string or null) for schema 2")
    _check_stamps(row, errors, ("1", "2"))
    return errors


def validate_assessment_row(row) -> list[str]:
    """Return a list of violations for an assessment (verdict) row; empty == valid."""
    if not isinstance(row, dict):
        return ["row must be a JSON object"]
    errors: list[str] = []

    if not _is_nonempty_str(row.get("packet_id")):
        errors.append("packet_id must be a non-empty string")
    if not _is_nonempty_str(row.get("assessed_at")):
        errors.append("assessed_at must be a non-empty string (ISO 8601)")
    if not _is_sha256_hex(row.get("assessor_schema_sha")):
        errors.append("assessor_schema_sha must be a 64-char lowercase sha256 hex string")
    if not _is_nonempty_str(row.get("source_transcript")):
        errors.append("source_transcript must be a non-empty string")
    if not isinstance(row.get("dispatch_confirmed"), bool):
        errors.append("dispatch_confirmed must be a boolean")

    # Row-level not_assessable_reason: the whole packet was unassessable.
    row_reason = row.get("not_assessable_reason")
    if row_reason is not None and not _is_nonempty_str(row_reason):
        errors.append("not_assessable_reason must be a non-empty string or null")
    row_unassessable = _is_nonempty_str(row_reason)

    for cls in VERDICT_CLASSES:
        if cls not in row:
            errors.append(f"{cls} key is required (array of objects, or null)")
            continue
        value = row[cls]
        if value is None:
            # Null means "this class was not assessable" and needs a reason —
            # per-class, unless the row-level reason already covers everything.
            if not row_unassessable and not _is_nonempty_str(
                row.get(f"{cls}_not_assessable_reason")
            ):
                errors.append(
                    f"{cls}_not_assessable_reason must be a non-empty string when {cls} is null"
                )
        elif isinstance(value, list):
            if row_unassessable:
                errors.append(
                    f"{cls} must be null when the row-level not_assessable_reason is set"
                )
            for idx, verdict in enumerate(value):
                if not isinstance(verdict, dict):
                    errors.append(f"{cls}[{idx}] must be an object")
        else:
            errors.append(f"{cls} must be an array of objects, or null")

    _check_stamps(row, errors)
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--kind", choices=("packet", "assessment"))
    group.add_argument("--sha", action="store_true", help="print this module's sha256 and exit")
    args = parser.parse_args()

    if args.sha:
        print(schema_sha())
        return 0

    try:
        row = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"packet-schema: row is not valid JSON: {exc}", file=sys.stderr)
        return 1

    validate = validate_packet_row if args.kind == "packet" else validate_assessment_row
    errors = validate(row)
    for error in errors:
        print(f"packet-schema: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
