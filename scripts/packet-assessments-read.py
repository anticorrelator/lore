#!/usr/bin/env python3
"""Read-only cycle packet assessment summary, reader contract 1.

Membership comes exclusively from the captured work evidence packet_summary.
Select assessed_at in [start,end), then keep the latest observation per packet
and source transcript (append order breaks timestamp ties). Exact duplicates
collapse. Different transcripts remain separate observations, never deliveries.
Only aggregate verdict counts/reasons and opaque observation identities leave
this reader; transcript paths and verdict bodies do not. Historical schema
hashes are provenance, validated for format by the shared assessment validator.
"""

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re

from packet_schema import DELIVERY_STAGES, VERDICT_CLASSES, validate_assessment_row


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def timestamp(value):
    if not isinstance(value, str) or not re.fullmatch(
            r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)", value):
        raise ValueError("invalid RFC3339 timestamp")
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def packet_membership(work):
    if not isinstance(work, dict) or not isinstance(work.get("evidence"), dict):
        return None, "packet-envelope-unavailable"
    evidence = work["evidence"]
    sources = evidence.get("sources")
    source = sources.get("packets") if isinstance(sources, dict) else None
    if not isinstance(source, dict) or source.get("state") != "read":
        return None, "packet-source-" + (str(source.get("state", "unknown")) if isinstance(source, dict) else "unknown")
    rows = evidence.get("packet_summary")
    if not isinstance(rows, list):
        return None, "packet-summary-unavailable"
    latest = {}
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("packet_id"), str) or not row["packet_id"].strip():
            return None, "invalid-packet-summary"
        latest[row["packet_id"]] = row
    return latest, None


def packet_delivery(work):
    packets, reason = packet_membership(work)
    if packets is None:
        return {"status": "not-computable", "values": None, "reason": reason}
    stages, bindings, receipts, binding_reasons = Counter(), Counter(), Counter(), Counter()
    totals = {name: {"total": None, "included_packets": 0, "excluded_packets": 0,
                     "exclusion_reasons": Counter()} for name in ("kept", "dropped", "added")}
    synthesized = waived = invalid = 0
    for row in packets.values():
        binding = row.get("binding")
        state = binding.get("state") if isinstance(binding, dict) else None
        valid_binding = isinstance(state, str) and state in {"current", "stale", "unbound", "legacy-unbound", "unknown"}
        bindings[state if valid_binding or state == "invalid" else "unknown"] += 1
        if isinstance(binding, dict) and binding.get("reason"):
            binding_reasons[str(binding["reason"])] += 1
        invalid += not valid_binding
        stage = row.get("delivery_stage")
        known_stage = stage in DELIVERY_STAGES
        stages[stage if known_stage else "unknown"] += 1
        receipt = row.get("receipt")
        receipts[receipt if isinstance(receipt, str) and receipt in {"delivered", "unknown"} else "unknown"] += 1
        synthesis = row.get("synthesis")
        is_synthesized = valid_binding and stage == "synthesized" and isinstance(synthesis, dict)
        synthesized += is_synthesized
        waiver = row.get("synthesis_waiver")
        waived += (valid_binding and stage in ("assembled", "delivered") and isinstance(waiver, dict)
                   and all(isinstance(waiver.get(k), str) and waiver[k].strip() for k in ("by", "reason")))
        for name, total in totals.items():
            value = synthesis.get(name) if isinstance(synthesis, dict) else None
            why = ("invalid-binding" if not valid_binding else "unknown-delivery-state" if not known_stage
                   else "synthesis-unknown" if synthesis is None else "invalid-synthesis-state" if not is_synthesized
                   else "invalid-count" if type(value) is not int or value < 0 else None)
            if why:
                total["excluded_packets"] += 1
                total["exclusion_reasons"][why] += 1
            else:
                total["total"] = (total["total"] or 0) + value
                total["included_packets"] += 1
    return {"status": "available", "reason": None, "values": {
        "unique_packets": len(packets), "assembled_candidates": stages["assembled"],
        "synthesized_packets": synthesized, "waivers": waived, "unknown_states": stages["unknown"],
        "invalid_bindings": invalid, "delivery_state_counts": dict(stages),
        "binding_state_counts": dict(bindings), "binding_reason_counts": dict(binding_reasons),
        "receipt_state_counts": dict(receipts), "synthesis_counts": totals,
        "coverage_limit": "Construction and synthesis are not evidence of recipient use; receipt is reported separately."
    }}


def read_summary(kdir, work, start, end):
    packets, membership_reason = packet_membership(work)
    result = {"reader_contract_version": "1", "projection_mode": "cycle-assessment-summary",
              "coverage": "read", "status": "available", "reason": None,
              "window": {"start": start, "end": end, "field": "assessed_at", "selection": "[start,end)"},
              "coverage_limit": "Only assessments recorded within the requested window are included; later assessments require a window that includes them.",
              "membership": {"source": "cycle_work.evidence.packet_summary", "state": "read" if packets is not None else "unknown",
                             "packet_ids": sorted(packets) if packets is not None else None, "reason": membership_reason},
              "diagnostics": [], "summary": None}
    begin, finish = timestamp(start), timestamp(end)
    if begin >= finish:
        raise ValueError("window start must precede end")
    selected, seen = {}, set()
    duplicates = superseded = 0
    try:
        with (Path(kdir) / "_packets/assessments.jsonl").open(encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    result["diagnostics"].append({"reason": "malformed-json", "row_identity": hashlib.sha256(line.encode()).hexdigest()})
                    continue
                # An unrelated cycle cannot alter this projection, even when its row is invalid.
                if isinstance(row, dict) and isinstance(row.get("packet_id"), str) and packets is not None and row["packet_id"] not in packets:
                    continue
                try:
                    at = timestamp(row.get("assessed_at") if isinstance(row, dict) else None)
                except ValueError:
                    result["diagnostics"].append({"reason": "invalid-assessed-at", "row_identity": digest(row)})
                    continue
                if not begin <= at < finish:
                    continue
                errors = validate_assessment_row(row)
                # The shared validator permits per-class metadata beside a row
                # reason. Validate that metadata too before counting reasons.
                if isinstance(row, dict):
                    for name in VERDICT_CLASSES:
                        reason = row.get(name + "_not_assessable_reason")
                        if reason is not None and (not isinstance(reason, str) or not reason.strip()):
                            errors.append(name + "_not_assessable_reason must be non-empty text or null")
                if errors:
                    result["diagnostics"].append({"reason": "invalid-assessment-row", "errors": errors, "row_identity": digest(row)})
                    continue
                if packets is None:
                    continue
                identity = digest(row)
                if identity in seen:
                    duplicates += 1
                    continue
                seen.add(identity)
                key = (row["packet_id"], row["source_transcript"])
                if key in selected:
                    superseded += 1
                if key not in selected or at >= selected[key][0]:
                    selected[key] = (at, row, identity)
    except FileNotFoundError:
        result.update(coverage="absent", status="absent", reason="assessment-source-absent")
    except (OSError, UnicodeError):
        result.update(coverage="unreadable", status="not-computable", reason="assessment-source-unreadable")
    if result["diagnostics"]:
        result.update(coverage="unreadable", status="not-computable", reason="invalid-assessment-evidence")
    if packets is None:
        result.update(status="not-computable", reason=membership_reason)
    if result["status"] == "available":
        classes = {name: {"assessable_observations": 0, "findings": None,
                          "not_assessable_observations": 0, "reason_counts": Counter()} for name in VERDICT_CLASSES}
        row_reasons, schema_hashes, assessor_hashes = Counter(), Counter(), Counter()
        confirmed = 0
        observations = []
        for _, row, identity in sorted(selected.values(), key=lambda value: value[2]):
            confirmed += row["dispatch_confirmed"]
            schema_hashes[row["packet_schema_sha"]] += 1
            assessor_hashes[row["assessor_schema_sha"]] += 1
            reason = row.get("not_assessable_reason")
            if reason:
                row_reasons[reason] += 1
            observation_classes = {}
            for name, counts in classes.items():
                value = row[name]
                why = (row.get(name + "_not_assessable_reason") or reason) if value is None else None
                observation_classes[name] = {"findings": len(value) if value is not None else None, "reason": why}
                if value is None:
                    counts["not_assessable_observations"] += 1
                    counts["reason_counts"][why] += 1
                else:
                    counts["assessable_observations"] += 1
                    counts["findings"] = (counts["findings"] or 0) + len(value)
            observations.append({"packet_id": row["packet_id"], "observation_id": identity,
                                 "transcript_identity": hashlib.sha256(row["source_transcript"].encode()).hexdigest(),
                                 "assessed_at": row["assessed_at"], "dispatch_confirmed": row["dispatch_confirmed"],
                                 "not_assessable_reason": reason, "classes": observation_classes})
        covered = {row["packet_id"] for _, row, _ in selected.values()}
        result["summary"] = {"eligible_packets": len(packets), "observed_packets": len(covered),
                             "packets_without_observations": sorted(set(packets) - covered),
                             "observations": len(selected), "confirmed_observations": confirmed,
                             "unconfirmed_observations": len(selected) - confirmed,
                             "exact_duplicates_collapsed": duplicates, "superseded_observations": superseded,
                             "row_reason_counts": row_reasons, "classes": classes,
                             "packet_schema_hash_counts": schema_hashes, "assessor_schema_hash_counts": assessor_hashes,
                             "observation_summaries": observations}
    result["content_identity"] = digest(result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kdir", required=True)
    parser.add_argument("--cycle-work", required=True)
    parser.add_argument("--window-start", required=True)
    parser.add_argument("--window-end", required=True)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        work = json.loads(Path(args.cycle_work).read_text())
    except (OSError, ValueError):
        work = None
    try:
        result = read_summary(args.kdir, work, args.window_start, args.window_end)
    except ValueError as exc:
        parser.error(str(exc))
    print(json.dumps(result, sort_keys=True, ensure_ascii=False))


if __name__ == "__main__":
    main()
