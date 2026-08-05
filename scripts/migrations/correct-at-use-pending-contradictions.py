#!/usr/bin/env python3
"""Give every unresolved contradiction recorded before the resolution gate an owner.

`lore verify contradicted` now requires the reporter to say what it did about
the contradiction — rewrite the entry, or leave a dated marker on it. Rows
written before that requirement have neither. They sat pending: a decrement
against an entry with nobody accountable for it, waiting on adjudication
machinery that is being retired.

This migration closes that cohort. For each unresolved contradiction it
decides one of two dispositions and records the reasoning in a durable
manifest:

  corrected  the contradiction is already answered — the entry was repaired
             on or after the day it was reported, or the entry is gone and
             the claim it made is out of circulation
  disputed   the observation is still live, so it becomes a dated marker on
             the entry saying what was seen and that it was never repaired

An entry's `status: corrected` is not enough on its own to claim the first
disposition. Several entries carry that status from a repair predating the
report, so only a dated corrections[] item can settle a specific one.

Nothing here can invent a repair: a legacy row names the code that falsified
the entry but never the text that should replace it. `disputed` is the honest
disposition for those, and it puts the observation where the next reader of
the entry will see it.

The migration only reads the settlement queue, to record that it left it
alone. It never enqueues.

Re-running is safe: dispositions are recomputed from current state, marker
writes are keyed by observation id, and sidecar transitions are idempotent.

Usage:
    correct-at-use-pending-contradictions.py [--kdir PATH] [--dry-run] [--json]
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

WORK_ITEM = "correct-at-use-contradictions-repair-entries-in-co"
MANIFEST_NAME = "legacy-contradiction-cohort.json"
SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_trust_compute():
    """Import trust-compute.py for its published provenance-migration resolver.

    Historical entry_path values are only resolvable through the ledger's own
    provenance-migration events; the store's git history is not evidence about
    where an entry lives now.
    """
    path = os.path.join(SCRIPTS_DIR, "trust-compute.py")
    spec = importlib.util.spec_from_file_location("trust_compute", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def read_jsonl(path: str) -> list[dict]:
    rows = []
    if not os.path.isfile(path):
        return rows
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(row, dict):
                rows.append(row)
    return rows


def find_sidecars(kdir: str) -> list[str]:
    """Every work item's contradiction sidecar, active and archived.

    `verdicts/` holds judge output that mirrors the sidecar shape; those are
    not rows the channel owns, so they stay out of the cohort.
    """
    found = []
    work_root = os.path.join(kdir, "_work")
    for dirpath, _dirnames, filenames in os.walk(work_root):
        if "consumption-contradictions.jsonl" not in filenames:
            continue
        if os.path.basename(dirpath) == "verdicts":
            continue
        found.append(os.path.join(dirpath, "consumption-contradictions.jsonl"))
    return sorted(found)


def entry_state(kdir: str, rel_path: str) -> dict:
    """What the entry says about itself: existence, status, and its repair history.

    `status: corrected` is not on its own evidence that a given contradiction
    was answered — several entries carry it from a repair that predates the
    report. Only the dated corrections[] trail can settle that, so it is
    returned alongside.
    """
    import re
    abs_path = os.path.join(kdir, rel_path)
    if not os.path.isfile(abs_path):
        return {"exists": False, "status": None, "corrections": []}
    try:
        text = open(abs_path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        return {"exists": True, "status": None, "corrections": []}

    blocks = list(re.finditer(r"<!--(.*?)-->", text, re.DOTALL))
    meta = blocks[-1].group(1) if blocks else ""
    status_match = re.search(r"\|\s*status:\s*(\S+)", meta)

    # Scoped to the corrections block: META also holds a dated disputes[]
    # array, and reading a marker's date as a repair would let this migration
    # mistake its own writes for evidence that the entry was fixed.
    corrections: list[dict] = []
    array = re.search(r"\|\s*corrections:\s*(\[.*?\])\s*(?:\||-->|$)", meta, re.DOTALL)
    if array:
        block = array.group(1)
        try:
            parsed = json.loads(block)
            corrections = [item for item in parsed if isinstance(item, dict)]
        except (json.JSONDecodeError, TypeError):
            corrections = [{"date": d} for d in re.findall(r'"date":\s*"([0-9-]+)"', block)]

    return {
        "exists": True,
        "status": status_match.group(1) if status_match else "current",
        "corrections": corrections,
    }


def repair_answering(state: dict, observed_at: str | None) -> dict | None:
    """The recorded correction that answers a report, if any.

    A repair counts only when it is dated on or after the day the
    contradiction was observed. An earlier one changed something else.
    """
    observed_day = (observed_at or "")[:10]
    if not observed_day:
        return None
    for item in state["corrections"]:
        date = str(item.get("date") or "")[:10]
        if date and date >= observed_day:
            return item
    return None


def queue_depth(kdir: str) -> int | None:
    """Live settlement queue depth, read-only.

    Recorded as an observation, not as proof: the queue has other writers, so
    the depth can move on its own between the two readings. What guarantees
    zero enqueues is that no code path here calls one.
    """
    path = os.path.join(kdir, "_settlement", "queue.json")
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            queue = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None
    items = queue.get("items") or []
    return sum(1 for item in items if item.get("status") in {"pending", "leased"})


def in_cohort(row: dict) -> bool:
    """Whether a sidecar row is one this migration owns.

    Membership has to survive the migration's own writes, or a second run
    would drop everything the first run closed and the manifest would stop
    being a record of the cohort. A row qualifies while it is still pending,
    and afterwards because this migration closes rows without a
    `settled_by_run_id` — the settlement path always records one.
    """
    status = row.get("status")
    if status == "pending":
        return True
    return status in {"verified", "contradicted"} and not row.get("settled_by_run_id")


def build_cohort(kdir: str, trust_compute) -> list[dict]:
    """Every contradiction on disk that no resolution answers, ledger and sidecar."""
    ledger = read_jsonl(os.path.join(kdir, "_trust", "trust-events.jsonl"))
    migrations = trust_compute._build_migrations(ledger, [])

    unresolved_events = [
        row for row in ledger
        if row.get("event") == "consumption-verification"
        and (row.get("payload") or {}).get("disposition") == "contradicted"
        and not (row.get("payload") or {}).get("resolution")
    ]

    pending_rows = []
    for sidecar in find_sidecars(kdir):
        for row in read_jsonl(sidecar):
            if in_cohort(row):
                row["_sidecar"] = sidecar
                pending_rows.append(row)

    # A bridged pair shares the claim id its single `lore verify` call minted.
    rows_by_claim: dict[str, dict] = {}
    for row in pending_rows:
        claim_id = (row.get("claim_payload") or {}).get("claim_id")
        if claim_id and claim_id not in rows_by_claim:
            rows_by_claim[claim_id] = row

    members = []
    paired_rows = set()

    for event in unresolved_events:
        payload = event.get("payload") or {}
        claim_id = payload.get("claim_id")
        row = rows_by_claim.get(claim_id) if claim_id else None
        if row is not None:
            paired_rows.add(id(row))
        recorded = event.get("entry_path") or ""
        resolved, _warning = trust_compute.resolve_entry_key(recorded, migrations)
        members.append({
            "event_id": event.get("event_id"),
            "claim_id": claim_id,
            "observed_at": event.get("observed_at"),
            "work_item": payload.get("work_item") or (row or {}).get("work_item"),
            "entry_path_recorded": recorded,
            "entry_path_resolved": resolved,
            "evidence": {
                "file": payload.get("file"),
                "line_range": payload.get("line_range"),
                "exact_snippet": payload.get("exact_snippet"),
                "rationale": payload.get("rationale"),
                "claim_text": payload.get("claim_text"),
                "falsifier": payload.get("falsifier"),
            },
            "_row": row,
        })

    for row in pending_rows:
        if id(row) in paired_rows:
            continue
        claim = row.get("claim_payload") or {}
        recorded = (row.get("prefetched_commons_entry") or {}).get("knowledge_path") or ""
        resolved, _warning = trust_compute.resolve_entry_key(recorded, migrations)
        members.append({
            "event_id": None,
            "claim_id": claim.get("claim_id"),
            "observed_at": row.get("created_at"),
            "work_item": row.get("work_item"),
            "entry_path_recorded": recorded,
            "entry_path_resolved": resolved,
            "evidence": {
                "file": claim.get("file"),
                "line_range": claim.get("line_range"),
                "exact_snippet": claim.get("exact_snippet"),
                "rationale": row.get("contradiction_rationale"),
                "claim_text": claim.get("claim_text"),
                "falsifier": claim.get("falsifier"),
            },
            "_row": row,
        })

    return members


def observation_id(member: dict) -> str:
    """The stable id a marker's identity derives from, so re-runs converge."""
    if member["event_id"]:
        return member["event_id"]
    row = member["_row"] or {}
    return "cc-" + str(row.get("contradiction_id") or member["claim_id"] or "unknown")


def cohort_id(member: dict) -> str:
    return "cohort-" + hashlib.sha256(observation_id(member).encode("utf-8")).hexdigest()[:12]


def dispute_note(member: dict) -> str:
    evidence = member["evidence"]
    observed = (member.get("observed_at") or "")[:10] or "an earlier cycle"
    what = evidence.get("rationale") or evidence.get("falsifier") or evidence.get("claim_text") \
        or "the code at the cited anchor did not match this entry"
    return (
        f"A reader reported on {observed} that the code contradicts this entry: "
        f"{what.strip().rstrip('.')}. The report named the falsifying code but "
        f"not a replacement, so the claim above has not been rewritten."
    )


def evidence_text(member: dict) -> str:
    evidence = member["evidence"]
    anchor = evidence.get("file") or "unknown file"
    if evidence.get("line_range"):
        anchor = f"{anchor}:{evidence['line_range']}"
    detail = evidence.get("rationale") or evidence.get("claim_text") or ""
    return f"{anchor} — {detail}".strip().rstrip("—").strip()


def run(cmd: list[str]) -> tuple[int, str, str]:
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.returncode, proc.stdout, proc.stderr


def apply_dispute(kdir: str, member: dict, date_str: str, dry_run: bool) -> tuple[str | None, str]:
    """Write the marker through the sanctioned mutator; return (dispute_id, action)."""
    entry_abs = os.path.join(kdir, member["entry_path_resolved"])
    cmd = [
        "bash", os.path.join(SCRIPTS_DIR, "apply-correction.sh"),
        "--dispute",
        "--entry", entry_abs,
        "--observation-id", observation_id(member),
        "--verdict-source", "peer-verification",
        "--allow-peer-verification",
        "--evidence", evidence_text(member),
        "--dispute-note", dispute_note(member),
        "--reported-by", "worker",
        "--date", date_str,
        "--kdir", kdir,
    ]
    if member.get("work_item"):
        cmd += ["--work-item", member["work_item"]]
    if dry_run:
        cmd.append("--dry-run")
    code, out, err = run(cmd)
    if code != 0:
        raise RuntimeError(f"dispute mutator failed for {member['entry_path_resolved']}: {err.strip()}")
    dispute_id = None
    action = "dry-run"
    for line in out.splitlines():
        if line.startswith("[dispute] result=") or line.startswith("[dry-run][dispute]   dispute_id:"):
            for token in line.split():
                if token.startswith("result="):
                    action = token.split("=", 1)[1]
                elif token.startswith("dispute_id="):
                    dispute_id = token.split("=", 1)[1]
                elif token.startswith("disp-"):
                    dispute_id = token
    return dispute_id, action


def close_sidecar_row(kdir: str, row: dict, settled_at: str, dry_run: bool) -> str:
    """Move a pending row to its terminal state through the sanctioned mutator.

    `contradicted` is the terminal that matches what the row records: a reader
    found the entry falsified, and nothing since has ruled that observation
    spurious. The manifest carries which of the two dispositions answered it.
    """
    # A row that already reached a terminal state keeps it. Re-driving a
    # different terminal would be the writer's conflicting-transition error,
    # and re-driving the same one adds nothing.
    if row.get("status") != "pending":
        return row.get("status")
    if dry_run:
        return "dry-run"
    cmd = [
        "bash", os.path.join(SCRIPTS_DIR, "consumption-contradiction-update-status.sh"),
        "--work-item", row["work_item"],
        "--contradiction-id", row["contradiction_id"],
        "--status", "contradicted",
        "--settled-at", settled_at,
        "--kdir", kdir,
        "--json",
    ]
    code, out, err = run(cmd)
    if code != 0:
        raise RuntimeError(f"sidecar transition failed for {row.get('contradiction_id')}: {err.strip()}")
    # The writer prints its JSON result and then a human line; take the object.
    for line in out.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            result = json.loads(line)
        except json.JSONDecodeError:
            continue
        if "new_status" in result:
            return result["new_status"]
    return "unknown"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="correct-at-use-pending-contradictions.py")
    parser.add_argument("--kdir", help="knowledge directory (default: lore resolve)")
    parser.add_argument("--dry-run", action="store_true",
                        help="decide and report dispositions without writing")
    parser.add_argument("--json", action="store_true", help="print the manifest to stdout")
    args = parser.parse_args(argv)

    kdir = args.kdir
    if not kdir:
        code, out, err = run([os.path.join(SCRIPTS_DIR, "resolve-repo.sh")])
        if code != 0:
            print(f"[cohort] Error: cannot resolve knowledge dir: {err.strip()}", file=sys.stderr)
            return 1
        kdir = out.strip()
    if not os.path.isdir(kdir):
        print(f"[cohort] Error: knowledge store not found at: {kdir}", file=sys.stderr)
        return 1

    trust_compute = _load_trust_compute()
    now = datetime.now(timezone.utc)
    settled_at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    date_str = now.strftime("%Y-%m-%d")

    queue_before = queue_depth(kdir)
    manifest_path = os.path.join(kdir, "_work", WORK_ITEM, MANIFEST_NAME)
    members = build_cohort(kdir, trust_compute)

    manifest_members = []
    counts = {"corrected": 0, "disputed": 0}
    for member in members:
        row = member["_row"]
        resolved = member["entry_path_resolved"]
        state = entry_state(kdir, resolved)
        repair = repair_answering(state, member["observed_at"]) if state["exists"] else None

        if not state["exists"]:
            # The entry is gone, so the claim the report falsified is out of
            # circulation. Nothing to mark, and nothing left to repair.
            disposition, basis, owner_ref, action = "corrected", "entry-retired", None, "none"
        elif repair is not None:
            disposition, basis, action = "corrected", "repaired-after-report", "none"
            owner_ref = repair.get("correction_id") or f"correction dated {repair.get('date')}"
        else:
            owner_ref, action = apply_dispute(kdir, member, date_str, args.dry_run)
            disposition, basis = "disputed", "marker-applied"
        counts[disposition] += 1

        cc_before = row.get("status") if row else None
        cc_after = close_sidecar_row(kdir, row, settled_at, args.dry_run) if row else None

        manifest_members.append({
            "cohort_id": cohort_id(member),
            "event_id": member["event_id"],
            "claim_id": member["claim_id"],
            "contradiction_id": row.get("contradiction_id") if row else None,
            "work_item": member["work_item"],
            "sidecar_path": os.path.relpath(row["_sidecar"], kdir) if row else None,
            "observed_at": member["observed_at"],
            "entry_path_recorded": member["entry_path_recorded"],
            "entry_path_resolved": resolved,
            "entry_status_found": state["status"],
            "evidence": member["evidence"],
            "disposition": disposition,
            "disposition_basis": basis,
            "owner_ref": owner_ref,
            "entry_action": action,
            "cc_status_before": cc_before,
            "cc_status_after": cc_after,
        })

    queue_after = queue_depth(kdir)
    manifest = {
        "schema_version": 1,
        "work_item": WORK_ITEM,
        "generated_at": settled_at,
        "dry_run": args.dry_run,
        "cohort_size": len(manifest_members),
        "dispositions": counts,
        "unresolved": sum(1 for m in manifest_members if m["disposition"] not in counts),
        "settlement_queue_depth_observed_before": queue_before,
        "settlement_queue_depth_observed_after": queue_after,
        "enqueues": 0,
        "enqueues_note": (
            "This migration has no enqueue path. The depth readings are "
            "observations of a queue with other writers, not a proof."
        ),
        "members": sorted(manifest_members, key=lambda m: (m["observed_at"] or "", m["cohort_id"])),
    }

    if not args.dry_run:
        os.makedirs(os.path.dirname(manifest_path), exist_ok=True)
        with open(manifest_path, "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=2, ensure_ascii=False)
            fh.write("\n")

    if args.json:
        print(json.dumps(manifest, indent=2, ensure_ascii=False))
    else:
        prefix = "[cohort][dry-run]" if args.dry_run else "[cohort]"
        print(f"{prefix} {len(manifest_members)} unresolved contradictions: "
              f"{counts['corrected']} corrected, {counts['disputed']} disputed")
        print(f"{prefix} 0 enqueues (queue depth observed {queue_before} -> {queue_after})")
        if not args.dry_run:
            print(f"{prefix} manifest: {os.path.relpath(manifest_path, kdir)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
