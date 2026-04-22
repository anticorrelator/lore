#!/usr/bin/env bash
# audit-queue-route.sh — Route a reverse-auditor emission to the pass or fail queue
#
# Given a reverse-auditor emission and its grounding-preflight verdict, append
# one JSONL row to either:
#   $KDIR/_work/<slug>/audit-candidates.jsonl  (preflight passed)
#   $KDIR/_work/<slug>/audit-attempts.jsonl    (preflight failed)
#
# This is the mechanical routing stage that sits between the reverse-auditor
# and the correctness-gate — only claims that resolve to real evidence
# pointers reach the correctness-gate for truth adjudication.
#
# Usage:
#   audit-queue-route.sh \
#       --work-item <slug> \
#       --emission <json-file-or-inline> \
#       --preflight <json-file-or-inline> \
#       [--kdir <path>] \
#       [--verdict-source <source>]  # default: reverse-auditor
#
# --emission is the reverse-auditor output per the audit contract
#   (architecture/audit-pipeline/contract.md), either the full object with
#   `omission_claim` + `judge_template_version`, or the bare claim payload.
#
# --preflight is grounding-preflight.py's JSON output:
#   {"pass": true/false, "reason": "...", "detail": "..."}
#
# Routing semantics:
#   * preflight.pass == true  → audit-candidates.jsonl with status
#                               "pending_correctness_gate"
#   * preflight.pass == false → audit-attempts.jsonl with the preflight
#                               reason surfaced
#   * preflight.reason == "silence" → neither file gets written; exit 0
#     (silence is not a failure, it's no-op telemetry handled by the
#     reverse-auditor rollup directly)
#
# Row schemas (per the plan and contract doc):
#
# audit-candidates.jsonl (passed preflight):
#   {
#     "candidate_id":   "<uuid-like>",
#     "verdict_source": "reverse-auditor",
#     "work_item":      "<slug>",
#     "file":           "<from claim>",
#     "line_range":     "<from claim>",
#     "falsifier":      "<from claim>",
#     "rationale":      "<why-it-matters / why_it_matters from claim>",
#     "status":         "pending_correctness_gate",
#     "created_at":     "<ISO-8601>"
#   }
#
# audit-attempts.jsonl (failed preflight):
#   {
#     "attempt_id":     "<uuid-like>",
#     "verdict_source": "reverse-auditor",
#     "work_item":      "<slug>",
#     "claim_payload":  { ... full claim as emitted ... },
#     "reason":         "file-missing | line-out-of-range |
#                        snippet-mismatch | field-missing",
#     "detail":         "<from preflight.detail, optional>",
#     "created_at":     "<ISO-8601>"
#   }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

WORK_ITEM=""
EMISSION_INPUT=""
PREFLIGHT_INPUT=""
KDIR_OVERRIDE=""
VERDICT_SOURCE="reverse-auditor"

usage() {
  sed -n '2,52p' "$0" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-item)      WORK_ITEM="$2";        shift 2 ;;
    --emission)       EMISSION_INPUT="$2";   shift 2 ;;
    --preflight)      PREFLIGHT_INPUT="$2";  shift 2 ;;
    --kdir)           KDIR_OVERRIDE="$2";    shift 2 ;;
    --verdict-source) VERDICT_SOURCE="$2";   shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)
      echo "[queue] Error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

fail() {
  echo "[queue] Error: $1" >&2
  exit 1
}

[[ -n "$WORK_ITEM"       ]] || fail "--work-item is required"
[[ -n "$EMISSION_INPUT"  ]] || fail "--emission is required (path or inline JSON)"
[[ -n "$PREFLIGHT_INPUT" ]] || fail "--preflight is required (path or inline JSON)"

# --- Resolve kdir ---
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR="$KDIR_OVERRIDE"
else
  KDIR=$(resolve_knowledge_dir)
fi

[[ -d "$KDIR" ]] || fail "knowledge directory not found: $KDIR"

ITEM_DIR="$KDIR/_work/$WORK_ITEM"
[[ -d "$ITEM_DIR" ]] || fail "work item not found: $WORK_ITEM (expected at $ITEM_DIR)"

# --- Read inputs (path or inline JSON) ---
read_json() {
  local src="$1"
  local label="$2"
  if [[ -f "$src" ]]; then
    cat "$src"
  elif printf '%s' "$src" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    printf '%s' "$src"
  else
    fail "$label is neither a valid file path nor valid JSON: $src"
  fi
}

EMISSION_JSON=$(read_json "$EMISSION_INPUT" "--emission")
PREFLIGHT_JSON=$(read_json "$PREFLIGHT_INPUT" "--preflight")

# --- Route based on preflight pass/fail ---
# The Python script below does the work: parses both inputs, handles the
# silence short-circuit, generates the row with auto-injected fields, and
# writes to the correct file. Passing through python keeps JSON semantics
# correct (UUID generation, timestamp formatting, nested claim_payload).

EMISSION_JSON="$EMISSION_JSON" \
PREFLIGHT_JSON="$PREFLIGHT_JSON" \
WORK_ITEM_ENV="$WORK_ITEM" \
VERDICT_SOURCE_ENV="$VERDICT_SOURCE" \
ITEM_DIR_ENV="$ITEM_DIR" \
python3 <<'PYEOF'
import json
import os
import sys
import uuid
from datetime import datetime, timezone

emission = json.loads(os.environ["EMISSION_JSON"])
preflight = json.loads(os.environ["PREFLIGHT_JSON"])
work_item = os.environ["WORK_ITEM_ENV"]
verdict_source = os.environ["VERDICT_SOURCE_ENV"]
item_dir = os.environ["ITEM_DIR_ENV"]

# Silence short-circuit — neither file gets written. This is the canonical
# "no-op" case per the contract (reverse-auditor emitted ∅).
reason = preflight.get("reason", "")
if reason == "silence":
    print("[queue] silence: no row appended (reverse-auditor emitted ∅)")
    sys.exit(0)

pass_flag = bool(preflight.get("pass"))

# Extract the underlying claim object from the emission. Supports both the
# full reverse-auditor output shape (nested omission_claim) and the bare
# claim shape (contract's resolved-input compatibility).
if "omission_claim" in emission and emission["omission_claim"]:
    claim = emission["omission_claim"]
elif "omission_claim" in emission and emission["omission_claim"] is None:
    # Reverse-auditor said null but preflight didn't return "silence" —
    # treat as a shape bug, fail loudly.
    print("[queue] Error: emission.omission_claim is null but preflight reason is not 'silence'", file=sys.stderr)
    sys.exit(1)
elif "file" in emission or "line_range" in emission:
    claim = emission
else:
    print("[queue] Error: emission does not contain omission_claim or a bare claim shape", file=sys.stderr)
    sys.exit(1)

now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

if pass_flag:
    # audit-candidates.jsonl — row with pending_correctness_gate status
    why = claim.get("why_it_matters") or claim.get("why-it-matters") or ""
    row = {
        "candidate_id":  f"cand-{uuid.uuid4().hex[:12]}",
        "verdict_source": verdict_source,
        "work_item":     work_item,
        "file":          claim.get("file"),
        "line_range":    claim.get("line_range"),
        "falsifier":     claim.get("falsifier"),
        "rationale":     why,
        "status":        "pending_correctness_gate",
        "created_at":    now_iso,
    }
    target = os.path.join(item_dir, "audit-candidates.jsonl")
    with open(target, "a") as fh:
        fh.write(json.dumps(row, sort_keys=True) + "\n")
    print(f"[queue] candidate appended (preflight pass): {target}")
    print(json.dumps({"queue": "candidates", "row": row}))
else:
    # audit-attempts.jsonl — row tagged with the preflight reason
    row = {
        "attempt_id":    f"att-{uuid.uuid4().hex[:12]}",
        "verdict_source": verdict_source,
        "work_item":     work_item,
        "claim_payload": claim,
        "reason":        reason or "unknown",
        "detail":        preflight.get("detail") or "",
        "created_at":    now_iso,
    }
    target = os.path.join(item_dir, "audit-attempts.jsonl")
    with open(target, "a") as fh:
        fh.write(json.dumps(row, sort_keys=True) + "\n")
    print(f"[queue] attempt appended (preflight fail: {row['reason']}): {target}")
    print(json.dumps({"queue": "attempts", "row": row}))
PYEOF
