#!/usr/bin/env bash
# evolve-prepare.sh — Publish the deterministic evidence queue for one /evolve run.
#
# The verb freezes source state and computes evidence sufficiency. It does not
# recommend a verdict, select a proposal, adjudicate a cluster, or edit a target.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SINCE=""
JSON_MODE=0

usage() {
  cat >&2 <<'EOF'
Usage: lore evolve prepare [--since <RFC3339>] [--json]

Publish a content-addressed queue-v1 snapshot from the journal, scorecard,
template registry, accepted clusters, contradiction sidecars, and prior evolve
filings. Eligibility is evidence arithmetic only; the evolve lead owns verdicts
and target-file edits.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { usage; exit 1; }; SINCE="$2"; shift 2 ;;
    --since=*) SINCE="${1#--since=}"; [[ -n "$SINCE" ]] || { usage; exit 1; }; shift ;;
    --json) JSON_MODE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "[evolve prepare] Refused: unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

KDIR=$(resolve_knowledge_dir)
ROLE=$(resolve_role)

python3 - "$KDIR" "$ROLE" "$SINCE" "$JSON_MODE" <<'PY'
import datetime as dt
import glob
import hashlib
import json
import os
import re
import sys
import tempfile
from collections import defaultdict

kdir, role, since_raw, json_mode_raw = sys.argv[1:]
json_mode = json_mode_raw == "1"

JOURNAL = os.path.join(kdir, "_meta", "effectiveness-journal.jsonl")
ROWS = os.path.join(kdir, "_scorecards", "rows.jsonl")
REGISTRY = os.path.join(kdir, "_scorecards", "template-registry.json")
CLUSTERS = os.path.join(kdir, "_evolve", "accepted-clusters.jsonl")
QUEUE_DIR = os.path.join(kdir, "_evolve", "review-queues")
FILING_DIR = os.path.join(kdir, "_evolve", "review-filings")

ELIGIBILITY = {"eligible", "no_op", "abstained", "not_computable"}
SOURCE_COVERAGE = {"read", "absent", "unreadable", "stale", "not_computable"}
GATE_PATHS = {"primary", "correction", "claim-retraction", "recurring-failure", "carry-forward"}
FORBIDDEN_QUEUE_KEYS = {
    "recommended_verdict", "recommendation", "selected", "approved",
    "decision", "verdict", "edit", "edit_text", "application",
}

def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")

def sha(data):
    return hashlib.sha256(data).hexdigest()

def normalize_rfc3339(raw):
    if not raw:
        return None
    try:
        parsed = dt.datetime.fromisoformat(raw[:-1] + "+00:00" if raw.endswith("Z") else raw)
        if parsed.tzinfo is None:
            raise ValueError("timezone required")
        return parsed.astimezone(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    except Exception as exc:
        raise ValueError(f"--since must be an RFC3339 timestamp with timezone: {exc}")

def response(status, exit_code, queue=None, warnings=None, error=None):
    out = {
        "schema_version": 1,
        "operation": "prepare",
        "status": status,
        "exit_code": exit_code,
        "queue": queue,
        "filing": None,
        "decision_accepted": None,
        "filing_complete": None,
        "completed_sinks": [],
        "missing_sinks": [],
        "warnings": warnings or [],
        "error": error,
    }
    if json_mode:
        print(json.dumps(out, ensure_ascii=False, separators=(",", ":")))
    else:
        if status == "refused":
            print(f"[evolve prepare] refused: {error['message']}", file=sys.stderr)
            if error.get("repair_target"):
                print(f"Repair target: {error['repair_target']}", file=sys.stderr)
        else:
            print(f"[evolve prepare] {status}: queue={queue['id']}")
            print(f"Artifact: {queue['path']}")
            print(f"SHA-256: {queue['sha256']}")
            for warning in warnings or []:
                print(f"Warning: {warning}")
    raise SystemExit(exit_code)

def refuse(code, message, repair_target, warnings=None):
    response("refused", 1, warnings=warnings,
             error={"code": code, "message": message, "repair_target": repair_target})

try:
    since = normalize_rfc3339(since_raw)
except ValueError as exc:
    refuse("invalid_since", str(exc), "supply --since with an explicit RFC3339 timezone")

def read_bytes(path):
    try:
        with open(path, "rb") as fh:
            return fh.read(), "read", None
    except FileNotFoundError:
        return b"", "absent", "source_absent"
    except OSError as exc:
        return b"", "unreadable", f"read_failed:{exc}"

def parse_jsonl_bytes(raw, source_name):
    rows, problems = [], []
    offset = 0
    lines = raw.splitlines(keepends=True)
    for ordinal, physical in enumerate(lines, 1):
        content = physical[:-1] if physical.endswith(b"\n") else physical
        if content.endswith(b"\r"):
            content = content[:-1]
        if not content.strip():
            offset += len(physical)
            continue
        try:
            obj = json.loads(content)
            if not isinstance(obj, dict):
                raise ValueError("row is not an object")
            rows.append({"ordinal": ordinal, "raw": content, "physical": physical,
                         "offset_end": offset + len(physical), "object": obj})
        except Exception as exc:
            problems.append({"ordinal": ordinal, "raw": content,
                             "physical": physical, "offset_end": offset + len(physical),
                             "reason": f"invalid_{source_name}_row:{exc}"})
        offset += len(physical)
    return rows, problems

journal_raw, journal_coverage, journal_reason = read_bytes(JOURNAL)
if journal_coverage == "unreadable":
    refuse("journal_unreadable", "the effectiveness journal could not be read",
           JOURNAL)
journal_rows, journal_bad = parse_jsonl_bytes(journal_raw, "journal")

# A malformed final physical row may be torn. Hold it outside the frozen range;
# malformed interior rows remain explicit queue items and the later valid row
# proves that advancing past them is safe.
last_valid_ordinal = journal_rows[-1]["ordinal"] if journal_rows else 0
trailing_bad = [r for r in journal_bad if r["ordinal"] > last_valid_ordinal]
interior_bad = [r for r in journal_bad if r["ordinal"] <= last_valid_ordinal]
warnings = []
if trailing_bad:
    warnings.append("trailing malformed journal input excluded from the upper cutoff")
if interior_bad:
    warnings.append(f"{len(interior_bad)} interior malformed journal row(s) retained as invalid queue items")

def journal_cursor(row):
    obj = row["object"]
    return {
        "timestamp": obj.get("timestamp"),
        "row_ordinal": row["ordinal"],
        "row_sha256": sha(row["raw"]),
    }

if journal_rows:
    upper_row = journal_rows[-1]
    upper_cursor = journal_cursor(upper_row)
    prefix_end = upper_row["offset_end"]
else:
    upper_row = None
    upper_cursor = {"timestamp": None, "row_ordinal": 0, "row_sha256": sha(b"")}
    prefix_end = 0
upper_cursor["journal_identity"] = sha(journal_raw[:prefix_end])

completed_filing_ids = set()
for row in journal_rows:
    obj = row["object"]
    if obj.get("role") != "evolve":
        continue
    context = obj.get("context") or ""
    if context.startswith("evolve-filing:"):
        completed_filing_ids.add(context.split(":", 1)[1])

filing_sources = []
for path in sorted(glob.glob(os.path.join(FILING_DIR, "*.json"))):
    raw, coverage, reason = read_bytes(path)
    record = {"path": path, "raw": raw, "coverage": coverage, "reason": reason, "object": None}
    if coverage == "read":
        try:
            obj = json.loads(raw)
            if not isinstance(obj, dict) or obj.get("schema_version") != 1 or not obj.get("filing_id"):
                raise ValueError("not a filing-v1 object")
            record["object"] = obj
        except Exception as exc:
            record["coverage"] = "unreadable"
            record["reason"] = f"invalid_filing:{exc}"
    filing_sources.append(record)

incomplete = [r for r in filing_sources if r["object"] and r["object"]["filing_id"] not in completed_filing_ids]
if incomplete:
    target = incomplete[-1]["path"]
    refuse("accepted_filing_incomplete",
           "an authoritative evolve filing is accepted but its sanctioned sink fanout is incomplete",
           f"retry lore evolve file using {target}")

completed_filings = [r for r in filing_sources if r["object"] and r["object"]["filing_id"] in completed_filing_ids]
completed_filings.sort(key=lambda r: (r["object"].get("accepted_at") or "", r["object"]["filing_id"]))
predecessor_filing = completed_filings[-1]["object"] if completed_filings else None

lower_cursor = None
cutoff_basis = "all-time"
predecessor = None
if predecessor_filing:
    lower_cursor = (predecessor_filing.get("cutoff") or {}).get("upper")
    if not isinstance(lower_cursor, dict):
        refuse("invalid_predecessor", "the latest completed filing has no valid upper cutoff",
               "repair the completed filing/cutoff marker pair")
    ordinal = lower_cursor.get("row_ordinal")
    if not isinstance(ordinal, int) or ordinal < 0 or ordinal > upper_cursor["row_ordinal"]:
        refuse("journal_prefix_drift", "the prior cutoff is outside the current journal",
               "restore the append-only journal prefix used by the predecessor filing")
    if ordinal:
        candidates = [r for r in journal_rows if r["ordinal"] == ordinal]
        if not candidates or sha(candidates[0]["raw"]) != lower_cursor.get("row_sha256"):
            refuse("journal_prefix_drift", "the prior cutoff row no longer matches the journal prefix",
                   "restore the exact predecessor journal boundary")
    predecessor = {"filing_id": predecessor_filing["filing_id"], "cutoff": lower_cursor}
    cutoff_basis = "completed-filing"
elif not since:
    legacy = [r for r in journal_rows if r["object"].get("role") == "evolve"]
    if legacy:
        lower_cursor = journal_cursor(legacy[-1])
        lower_cursor["journal_identity"] = sha(journal_raw[:legacy[-1]["offset_end"]])
        cutoff_basis = "legacy-evolve-row"

if since:
    cutoff_basis = "since-override"
    lower_cursor = None
    predecessor = ({"filing_id": predecessor_filing["filing_id"],
                    "cutoff": (predecessor_filing.get("cutoff") or {}).get("upper")}
                   if predecessor_filing else None)

lower_ordinal = lower_cursor.get("row_ordinal", 0) if lower_cursor else 0

def in_range(row):
    if row["ordinal"] > upper_cursor["row_ordinal"]:
        return False
    if since:
        stamp = row["object"].get("timestamp")
        return isinstance(stamp, str) and stamp >= since
    return row["ordinal"] > lower_ordinal

range_rows = [r for r in journal_rows if in_range(r)]
range_bad = [r for r in interior_bad if r["ordinal"] > lower_ordinal]

score_raw, score_coverage, score_reason = read_bytes(ROWS)
score_rows, score_bad = parse_jsonl_bytes(score_raw, "scorecard") if score_coverage == "read" else ([], [])
if score_bad:
    score_coverage, score_reason = "unreadable", f"{len(score_bad)} invalid scorecard row(s)"

registry_raw, registry_coverage, registry_reason = read_bytes(REGISTRY)
registry_obj = None
if registry_coverage == "read":
    try:
        registry_obj = json.loads(registry_raw)
        if not isinstance(registry_obj, dict) or not isinstance(registry_obj.get("entries"), list):
            raise ValueError("entries must be an array")
    except Exception as exc:
        registry_coverage, registry_reason = "unreadable", f"invalid_registry:{exc}"

cluster_raw, cluster_coverage, cluster_reason = read_bytes(CLUSTERS)
cluster_rows, cluster_bad = parse_jsonl_bytes(cluster_raw, "accepted_cluster") if cluster_coverage == "read" else ([], [])
if cluster_bad:
    cluster_coverage, cluster_reason = "unreadable", f"{len(cluster_bad)} invalid accepted-cluster row(s)"

contradiction_paths = sorted(
    glob.glob(os.path.join(kdir, "_work", "*", "consumption-contradictions.jsonl")) +
    glob.glob(os.path.join(kdir, "_work", "_archive", "*", "consumption-contradictions.jsonl"))
)
contradictions = []
contradiction_chunks = []
contradiction_coverage = "absent" if not contradiction_paths else "read"
contradiction_reason = "source_absent" if not contradiction_paths else None
for path in contradiction_paths:
    raw, coverage, reason = read_bytes(path)
    contradiction_chunks.append(canonical({"path": os.path.relpath(path, kdir), "sha256": sha(raw)}))
    if coverage != "read":
        contradiction_coverage, contradiction_reason = "unreadable", reason
        continue
    parsed, bad = parse_jsonl_bytes(raw, "contradiction")
    if bad:
        contradiction_coverage = "unreadable"
        contradiction_reason = f"invalid contradiction rows in {os.path.relpath(path, kdir)}"
        continue
    for row in parsed:
        obj = row["object"]
        obj["_source_path"] = os.path.relpath(path, kdir)
        contradictions.append(obj)

filing_identity = sha(b"".join(canonical({"path": os.path.relpath(r["path"], kdir), "sha256": sha(r["raw"])}) for r in filing_sources))
contradiction_identity = sha(b"".join(contradiction_chunks))

def manifest_row(source_id, reader, resolved, coverage, raw, reason=None, cursor=None, content_identity=None, row_warnings=None):
    if coverage not in SOURCE_COVERAGE:
        coverage = "not_computable"
    return {
        "source_id": source_id,
        "reader": reader,
        "resolved_source": resolved,
        "coverage": coverage,
        "content_identity": content_identity if content_identity is not None else (sha(raw) if coverage == "read" else None),
        "cursor": cursor,
        "warnings": row_warnings or [],
        "reason": reason,
    }

source_manifest = [
    manifest_row("journal", "raw-jsonl-range", "_meta/effectiveness-journal.jsonl", journal_coverage,
                 journal_raw[:prefix_end], journal_reason, upper_cursor, upper_cursor["journal_identity"], warnings),
    manifest_row("scorecard_rows", "raw-jsonl", "_scorecards/rows.jsonl", score_coverage,
                 score_raw, score_reason),
    manifest_row("template_registry", "json-object", "_scorecards/template-registry.json", registry_coverage,
                 registry_raw, registry_reason),
    manifest_row("accepted_clusters", "raw-jsonl", "_evolve/accepted-clusters.jsonl", cluster_coverage,
                 cluster_raw, cluster_reason),
    manifest_row("consumption_contradictions", "active-and-archive-jsonl", "_work/{active,_archive}/**/consumption-contradictions.jsonl",
                 contradiction_coverage, b"", contradiction_reason, content_identity=contradiction_identity),
    manifest_row("prior_filings", "completed-filings", "_evolve/review-filings/*.json",
                 "read" if filing_sources else "absent", b"", "source_absent" if not filing_sources else None,
                 content_identity=filing_identity),
]

degraded_windows = set()
for row in journal_rows:
    obj = row["object"]
    if obj.get("role") != "retro":
        continue
    scores = obj.get("scores") if isinstance(obj.get("scores"), dict) else {}
    if scores.get("window_state") == "pipeline-degraded":
        for value in (obj.get("window_id"), obj.get("work_item"), obj.get("timestamp")):
            if value:
                degraded_windows.add(str(value))

registry_pairs = set()
if registry_coverage == "read":
    for entry in registry_obj.get("entries", []):
        if isinstance(entry, dict) and entry.get("template_id") and entry.get("template_version"):
            registry_pairs.add((str(entry["template_id"]), str(entry["template_version"])))

def score_degraded(obj):
    values = [obj.get("window_id"), obj.get("work_item"), obj.get("window_end"), obj.get("window_start")]
    return any(str(v) in degraded_windows for v in values if v is not None)

def parse_proposal(observation):
    if not isinstance(observation, str):
        return None, ["observation_not_string"]
    pattern = re.compile(
        r"^\s*Target:\s*(?P<target>.*?)\s*\|\s*Change type:\s*(?P<change_type>.*?)\s*\|\s*"
        r"Section:\s*(?P<section>.*?)\s*\|\s*Suggestion:\s*(?P<suggestion>.*?)\s*\|\s*Evidence:\s*(?P<evidence>.*)\s*$",
        re.S,
    )
    match = pattern.match(observation)
    if not match:
        return None, ["invalid_proposal_shape"]
    proposal = {key: value.strip() for key, value in match.groupdict().items()}
    missing = [f"missing_{key}" for key, value in proposal.items() if not value]
    return (proposal if not missing else None), missing

def group_key(proposal):
    return {"target": proposal["target"], "change_type": proposal["change_type"]}

def arithmetic(numerator, floor, threshold=None, denominator=None, value=None):
    return {
        "calculation_version": "queue-v1",
        "numerator": numerator,
        "denominator": denominator if denominator is not None else floor,
        "sample_floor": floor,
        "value": numerator if value is None else value,
        "threshold": threshold if threshold is not None else f">={floor}",
    }

def eligibility(status, reasons, refs=None, calc=None):
    assert status in ELIGIBILITY
    return {"status": status, "reasons": reasons, "evidence_refs": refs or [], "arithmetic": calc}

def evidence_text(proposal):
    return proposal["suggestion"] + " | " + proposal["evidence"]

def cited_metric_and_sample(proposal):
    text = evidence_text(proposal)
    metric = re.search(r"(?:metric|metric_name)\s*[=:]\s*([A-Za-z0-9_.-]+)", text, re.I)
    sample = re.search(r"(?:sample_size|sample size|n)\s*[=:]\s*(\d+)", text, re.I)
    return (metric.group(1) if metric else None, int(sample.group(1)) if sample else None)

def gate_primary(proposal):
    if score_coverage != "read" or registry_coverage != "read":
        return eligibility("not_computable", ["scorecard_or_registry_unavailable"])
    metric, cited_n = cited_metric_and_sample(proposal)
    candidates = [r["object"] for r in score_rows]
    if metric:
        candidates = [r for r in candidates if r.get("metric") == metric]
    reasons = []
    if not candidates:
        reasons.append("no_eligible_template_row")
    elif all((r.get("tier") or "telemetry") == "telemetry" for r in candidates):
        reasons.append("telemetry_only")
    elif all(r.get("tier") != "template" for r in candidates):
        reasons.append("wrong_tier")
    elif all(r.get("calibration_state") != "calibrated" for r in candidates if r.get("tier") == "template"):
        reasons.append("pre_calibration_only")
    eligible_rows = [r for r in candidates if r.get("tier") == "template" and r.get("kind") == "scored" and
                     r.get("calibration_state") == "calibrated" and
                     (str(r.get("template_id")), str(r.get("template_version"))) in registry_pairs and
                     not score_degraded(r)]
    if not eligible_rows:
        template_rows = [r for r in candidates if r.get("tier") == "template" and r.get("kind") == "scored" and r.get("calibration_state") == "calibrated"]
        if template_rows and all((str(r.get("template_id")), str(r.get("template_version"))) not in registry_pairs for r in template_rows):
            reasons = ["unregistered_template_only"]
        elif template_rows and all(score_degraded(r) for r in template_rows):
            reasons = ["pipeline_degraded_window_only"]
        return eligibility("no_op", reasons or ["no_eligible_template_row"])
    if metric is None or cited_n is None:
        return eligibility("no_op", ["missing_metric_or_sample_citation"])
    matched = [r for r in eligible_rows if int(r.get("sample_size") or 0) == cited_n]
    if not matched:
        return eligibility("no_op", ["no_eligible_template_row"])
    row = matched[-1]
    refs = [{"source_id": "scorecard_rows", "metric": row.get("metric"),
             "template_id": row.get("template_id"), "template_version": row.get("template_version"),
             "window_start": row.get("window_start"), "window_end": row.get("window_end")}]
    if cited_n < 7:
        return eligibility("abstained", ["below_sample_floor"], refs, arithmetic(cited_n, 7))
    return eligibility("eligible", [], refs, arithmetic(cited_n, 7))

def gate_correction(proposal):
    if score_coverage != "read":
        return eligibility("not_computable", ["scorecard_unavailable"])
    metric, cited_n = cited_metric_and_sample(proposal)
    candidates = [r["object"] for r in score_rows if r["object"].get("tier") == "correction" and
                  r["object"].get("kind") == "scored" and not score_degraded(r["object"])]
    if metric:
        candidates = [r for r in candidates if r.get("metric") == metric]
    candidates = [r for r in candidates if r.get("calibration_state") in {"calibrated", "pre-calibration"}]
    if not candidates:
        return eligibility("no_op", ["no_eligible_correction_row"])
    if metric is None or cited_n is None:
        return eligibility("no_op", ["missing_metric_or_sample_citation"])
    matched = [r for r in candidates if int(r.get("sample_size") or 0) == cited_n]
    if not matched:
        return eligibility("no_op", ["no_eligible_correction_row"])
    row = matched[-1]
    refs = [{"source_id": "scorecard_rows", "metric": row.get("metric"),
             "template_id": row.get("template_id"), "template_version": row.get("template_version")}]
    if cited_n < 4:
        return eligibility("abstained", ["below_sample_floor"], refs, arithmetic(cited_n, 4))
    return eligibility("eligible", [], refs, arithmetic(cited_n, 4))

def gate_retraction(proposal):
    if contradiction_coverage == "unreadable":
        return eligibility("not_computable", ["contradiction_source_unreadable"])
    if contradiction_coverage == "absent":
        return eligibility("not_computable", ["contradiction_source_absent"])
    text = evidence_text(proposal)
    id_match = re.search(r"contradiction_id\s*[=:]\s*([A-Za-z0-9_.:-]+)", text, re.I)
    path_match = re.search(r"knowledge_path\s*[=:]\s*([^|,;]+)", text, re.I)
    verified = [r for r in contradictions if r.get("status") == "verified"]
    if id_match:
        verified = [r for r in verified if r.get("contradiction_id") == id_match.group(1)]
    if path_match:
        wanted = path_match.group(1).strip()
        verified = [r for r in verified if ((r.get("prefetched_commons_entry") or {}).get("knowledge_path") == wanted)]
    if not verified:
        return eligibility("no_op", ["no_verified_contradiction"])
    row = sorted(verified, key=lambda r: (r.get("settled_at") or r.get("created_at") or "", r.get("contradiction_id") or ""))[-1]
    ref = {"source_id": "consumption_contradictions", "contradiction_id": row.get("contradiction_id"),
           "knowledge_path": (row.get("prefetched_commons_entry") or {}).get("knowledge_path"),
           "source_path": row.get("_source_path")}
    return eligibility("eligible", [], [ref], arithmetic(1, 1))

accepted_by_pair = defaultdict(list)
if cluster_coverage == "read":
    for record in cluster_rows:
        row = record["object"]
        if row.get("schema_version") not in {1, "1"} or row.get("vocabulary_version") not in {None, 1, "1"}:
            cluster_coverage, cluster_reason = "unreadable", "unsupported accepted-cluster schema declaration"
            accepted_by_pair.clear()
            break
        target = row.get("target")
        for change_type in row.get("change_types") or []:
            accepted_by_pair[(target, change_type)].append(row)

def gate_recurring(proposal):
    if cluster_coverage == "unreadable":
        return eligibility("not_computable", ["accepted_cluster_source_unreadable"])
    if cluster_coverage == "absent":
        return eligibility("not_computable", ["accepted_cluster_source_absent"])
    rows = [r for r in accepted_by_pair.get((proposal["target"], proposal["change_type"]), [])
            if r.get("consumed_at_run_id") is None]
    distinct = sorted({str(w) for row in rows for w in (row.get("work_items") or []) if w})
    refs = [{"source_id": "accepted_clusters", "cluster_id": r.get("cluster_id"),
             "accepted_at_run_id": r.get("accepted_at_run_id")} for r in rows]
    if not rows:
        return eligibility("no_op", ["no_accepted_cluster"], [], arithmetic(0, 3))
    if len(distinct) < 3:
        return eligibility("abstained", ["below_sample_floor"], refs, arithmetic(len(distinct), 3))
    return eligibility("eligible", [], refs, arithmetic(len(distinct), 3))

def gate(proposal):
    change_type = proposal["change_type"]
    if change_type == "doctrine-correction":
        return "correction", gate_correction(proposal)
    if change_type in {"claim-retraction", "falsified-doctrine"}:
        return "claim-retraction", gate_retraction(proposal)
    if change_type == "recurring-failure":
        return "recurring-failure", gate_recurring(proposal)
    return "primary", gate_primary(proposal)

items = []
proposal_source_rows = [r for r in range_rows if r["object"].get("role") in {"retro-evolution", "self-test-evolution"}]
for row in proposal_source_rows:
    obj = row["object"]
    proposal, parse_reasons = parse_proposal(obj.get("observation"))
    cursor = journal_cursor(row)
    cursor["journal_identity"] = upper_cursor["journal_identity"]
    item_id = sha(canonical({"source_cursor": cursor, "source_role": obj.get("role")}))[:24]
    if proposal is None:
        items.append({
            "item_id": item_id,
            "source_role": obj.get("role"),
            "source_cursor": cursor,
            "work_item": obj.get("work_item"),
            "parse": {"status": "invalid", "reasons": parse_reasons, "raw_sha256": sha(row["raw"])},
            "proposal": None,
            "group_key": None,
            "gate_path": None,
            "eligibility": eligibility("not_computable", parse_reasons),
        })
        continue
    path, outcome = gate(proposal)
    items.append({
        "item_id": item_id,
        "source_role": obj.get("role"),
        "source_cursor": cursor,
        "work_item": obj.get("work_item"),
        "parse": {"status": "parsed", "reasons": [], "raw_sha256": sha(row["raw"])},
        "proposal": proposal,
        "group_key": group_key(proposal),
        "gate_path": path,
        "eligibility": outcome,
    })

for bad in range_bad:
    item_id = sha(canonical({"ordinal": bad["ordinal"], "raw_sha256": sha(bad["raw"])}))[:24]
    items.append({
        "item_id": item_id,
        "source_role": None,
        "source_cursor": {"timestamp": None, "row_ordinal": bad["ordinal"], "row_sha256": sha(bad["raw"]),
                          "journal_identity": upper_cursor["journal_identity"]},
        "work_item": None,
        "parse": {"status": "invalid", "reasons": [bad["reason"]], "raw_sha256": sha(bad["raw"])},
        "proposal": None,
        "group_key": None,
        "gate_path": None,
        "eligibility": eligibility("not_computable", [bad["reason"]]),
    })

# Completed filings are a closed source of unresolved work. Copy only proposal
# facts from their original queue; application/verdict state never enters queue-v1.
existing_ids = {item["item_id"] for item in items}
for record in completed_filings:
    filing = record["object"]
    queue_id = filing.get("queue_id")
    queue_path = os.path.join(QUEUE_DIR, f"{queue_id}.json")
    try:
        prior_queue = json.load(open(queue_path, encoding="utf-8"))
    except Exception:
        continue
    prior_items = {row.get("item_id"): row for row in prior_queue.get("items", []) if isinstance(row, dict)}
    for decision in filing.get("decisions") or []:
        if not isinstance(decision, dict):
            continue
        escalation = decision.get("escalation") if isinstance(decision.get("escalation"), dict) else {}
        application = decision.get("application") if isinstance(decision.get("application"), dict) else {}
        carry = ((decision.get("verdict") == "escalate" and escalation.get("resolution") in {"pending", "defer"}) or
                 application.get("outcome") in {"failed", "deferred"})
        original = prior_items.get(decision.get("item_id"))
        if not carry or not original or original.get("item_id") in existing_ids or not original.get("proposal"):
            continue
        copied = {key: original.get(key) for key in
                  ("item_id", "work_item", "parse", "proposal", "group_key")}
        copied.update({
            "source_role": "evolve-filing",
            "source_cursor": {"filing_id": filing.get("filing_id"), "original_source_cursor": original.get("source_cursor")},
            "gate_path": "carry-forward",
            "eligibility": eligibility("eligible", ["carried_forward_incomplete_decision"],
                                       [{"source_id": "prior_filings", "filing_id": filing.get("filing_id")}]),
        })
        items.append(copied)
        existing_ids.add(copied["item_id"])

items.sort(key=lambda item: (
    (item.get("source_cursor") or {}).get("row_ordinal", 10**18),
    item.get("item_id") or "",
))

groups_map = defaultdict(list)
for item in items:
    key = item.get("group_key")
    if key:
        groups_map[(key["target"], key["change_type"])].append(item["item_id"])
groups = [{"target": target, "change_type": change_type, "item_ids": ids}
          for (target, change_type), ids in sorted(groups_map.items())]

raw_recurring = defaultdict(lambda: {"work_items": set(), "item_ids": []})
for item in items:
    proposal = item.get("proposal")
    if not proposal or item.get("source_role") != "retro-evolution":
        continue
    if item.get("source_cursor") and isinstance(item["source_cursor"], dict):
        source_row = next((r for r in journal_rows if r["ordinal"] == item["source_cursor"].get("row_ordinal")), None)
        if source_row and str(source_row["object"].get("context") or "").startswith("retro-backfill:"):
            continue
    key = (proposal["target"], proposal["change_type"])
    if item.get("work_item"):
        raw_recurring[key]["work_items"].add(item["work_item"])
    raw_recurring[key]["item_ids"].append(item["item_id"])

recurring_clusters = []
for (target, change_type), data in sorted(raw_recurring.items()):
    work_items = sorted(data["work_items"])
    if len(work_items) < 3:
        continue
    candidate_id = sha(canonical({"target": target, "change_types": [change_type], "work_items": work_items}))[:16]
    recurring_clusters.append({"candidate_id": candidate_id, "target": target, "change_type": change_type,
                               "work_items": work_items, "item_ids": data["item_ids"],
                               "arithmetic": arithmetic(len(work_items), 3)})

summary_counts = {state: sum(1 for item in items if item["eligibility"]["status"] == state)
                  for state in sorted(ELIGIBILITY)}
summary = {
    "items_total": len(items),
    "eligibility": summary_counts,
    "groups_total": len(groups),
    "recurring_candidates_total": len(recurring_clusters),
    "parse_invalid_total": sum(1 for item in items if item["parse"]["status"] == "invalid"),
}

cutoff = {
    "basis": cutoff_basis,
    "lower": lower_cursor,
    "upper": upper_cursor,
    "interval": "(lower,upper]",
    "since_override": since,
}
input_shape = {"schema_version": 1, "lower": lower_cursor, "since_override": since, "role": role}
input_fingerprint = sha(canonical(input_shape))
source_shape = {
    "sources": [{key: row[key] for key in ("source_id", "coverage", "content_identity", "cursor", "reason")}
                for row in source_manifest],
    "gate_registry": sorted(GATE_PATHS),
    "eligibility_registry": sorted(ELIGIBILITY),
    "calculation_version": "queue-v1",
}
source_fingerprint = sha(canonical(source_shape))
queue_id = sha(canonical({"input_fingerprint": input_fingerprint, "source_fingerprint": source_fingerprint}))
queue_run_id = f"evolve-queue-{queue_id[:16]}"

queue = {
    "schema_version": 1,
    "queue_id": queue_id,
    "input_fingerprint": input_fingerprint,
    "source_fingerprint": source_fingerprint,
    "artifact_sha256": None,
    "run": {"queue_run_id": queue_run_id, "role": role, "mode": "local", "predecessor": predecessor},
    "cutoff": cutoff,
    "due_claim": {"attempted": False, "outcome_ids": [], "disposition": "not-applicable", "warning": None},
    "source_manifest": source_manifest,
    "items": items,
    "groups": groups,
    "recurring_clusters": recurring_clusters,
    "summary": summary,
    "provenance": {"producer": "evolve-prepare.sh", "schema_version": 1,
                   "captured_at": upper_cursor.get("timestamp"),
                   "judgment_boundary": "evidence-sufficiency-only"},
}

def assert_negative_schema(value, path="$"):
    if isinstance(value, dict):
        for key, nested in value.items():
            if key in FORBIDDEN_QUEUE_KEYS:
                raise ValueError(f"forbidden queue field {path}.{key}")
            assert_negative_schema(nested, f"{path}.{key}")
    elif isinstance(value, list):
        for index, nested in enumerate(value):
            assert_negative_schema(nested, f"{path}[{index}]")

assert_negative_schema(queue)
queue["artifact_sha256"] = sha(canonical({key: value for key, value in queue.items() if key != "artifact_sha256"}))
artifact_bytes = canonical(queue)
artifact_file_sha = sha(artifact_bytes)

os.makedirs(QUEUE_DIR, exist_ok=True)
artifact_path = os.path.join(QUEUE_DIR, f"{queue_id}.json")
status = "created"
if os.path.exists(artifact_path):
    try:
        current = open(artifact_path, "rb").read()
        obj = json.loads(current)
        claimed = obj.get("artifact_sha256")
        actual_claim = sha(canonical({key: value for key, value in obj.items() if key != "artifact_sha256"}))
        if obj.get("schema_version") != 1 or obj.get("queue_id") != queue_id or claimed != actual_claim:
            raise ValueError("identity or self-hash mismatch")
        if current != artifact_bytes:
            refuse("queue_identity_collision", "existing queue identity has different canonical bytes",
                   artifact_path, warnings)
        status = "reused"
    except SystemExit:
        raise
    except Exception as exc:
        refuse("corrupt_queue", f"existing queue artifact is invalid: {exc}", artifact_path, warnings)
else:
    fd, temp_path = tempfile.mkstemp(prefix=".review-queue.", dir=QUEUE_DIR)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(artifact_bytes)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(temp_path, artifact_path)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)

relative = os.path.relpath(artifact_path, kdir)
response(status, 0,
         queue={"path": relative, "id": queue_id, "sha256": artifact_file_sha,
                "artifact_sha256": queue["artifact_sha256"]},
         warnings=warnings)
PY
