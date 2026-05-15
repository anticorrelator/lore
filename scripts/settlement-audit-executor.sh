#!/usr/bin/env bash
# settlement-audit-executor.sh — Convert `lore audit --json` into a settlement verdict envelope.
#
# Verdict envelope contract:
#   stdout is exactly one JSON object with:
#     verdict_envelope_version: 1
#     verdict: verified | unverified | contradicted | skipped | error
#     evidence: one-line summary, capped at 240 characters
#     correction: correction text when available, otherwise null
#     executor: {name, framework, exit_code}
#     audit: full `lore audit --json` object, or null on executor-level errors
#
# Aggregate verdict derivation from audit.correctness_gate:
#   contradicted  if contradicted > 0
#   unverified    if unverified > 0 and verified == 0
#   verified      if verified > 0 and contradicted == 0
#   skipped       if no auditable artifact/counts exist
#   error         if audit exits nonzero, audit JSON is unparseable, or input/args
#                 cannot be parsed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

EXECUTOR_NAME="settlement-audit-executor"
INPUT_JSON=$(cat)
FRAMEWORK="${LORE_FRAMEWORK:-}"
if [[ -z "$FRAMEWORK" ]]; then
  FRAMEWORK=$(resolve_active_framework 2>/dev/null || echo "unknown")
fi

emit_envelope() {
  local verdict="$1"
  local evidence="$2"
  local correction="$3"
  local exit_code="$4"
  local audit_file="${5:-}"

  python3 - "$verdict" "$evidence" "$correction" "$EXECUTOR_NAME" "$FRAMEWORK" "$exit_code" "$audit_file" <<'PYEOF'
import json
import sys

verdict, evidence, correction, name, framework, exit_code, audit_file = sys.argv[1:8]

def one_line(text):
    text = " ".join(str(text or "").split())
    if len(text) > 240:
        return text[:237] + "..."
    return text

audit = None
if audit_file:
    try:
        with open(audit_file, encoding="utf-8") as fh:
            audit = json.load(fh)
    except (OSError, json.JSONDecodeError):
        audit = None

try:
    parsed_exit_code = int(exit_code)
except ValueError:
    parsed_exit_code = 1

out = {
    "verdict_envelope_version": 1,
    "verdict": verdict,
    "evidence": one_line(evidence),
    "correction": None if correction == "" else correction,
    "executor": {
        "name": name,
        "framework": framework,
        "exit_code": parsed_exit_code,
    },
    "audit": audit,
}
print(json.dumps(out, separators=(",", ":")))
PYEOF
}

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/settlement-audit-executor-XXXXXX")
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

fields_file="$tmp_dir/input-fields.json"
if ! INPUT_JSON="$INPUT_JSON" python3 - >"$fields_file" <<'PYEOF'
import json
import os
import sys

try:
    payload = json.loads(os.environ.get("INPUT_JSON", ""))
    item = payload.get("item") or {}
    work_item = item.get("work_item") or ""
    claim_id = item.get("claim_id") or ""
except Exception as exc:
    print(json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"}))
    sys.exit(0)

if not work_item:
    print(json.dumps({"ok": False, "error": "input item.work_item is required"}))
elif not claim_id:
    print(json.dumps({"ok": False, "error": "input item.claim_id is required"}))
else:
    print(json.dumps({"ok": True, "work_item": work_item, "claim_id": claim_id}))
PYEOF
then
  echo "[settlement-executor] Error: failed to parse input payload" >&2
  emit_envelope "error" "failed to parse input payload" "" "1" ""
  exit 0
fi

input_ok=$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1])).get("ok", False)).lower())' "$fields_file")
if [[ "$input_ok" != "true" ]]; then
  input_error=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("error", "invalid input"))' "$fields_file")
  echo "[settlement-executor] Error: $input_error" >&2
  emit_envelope "error" "$input_error" "" "1" ""
  exit 0
fi

work_item=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["work_item"])' "$fields_file")
claim_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["claim_id"])' "$fields_file")

extra_args=()
if [[ -n "${LORE_SETTLEMENT_AUDIT_ARGS:-}" ]]; then
  args_file="$tmp_dir/audit-args.bin"
  args_error_file="$tmp_dir/audit-args.err"
  if ! python3 - "$LORE_SETTLEMENT_AUDIT_ARGS" >"$args_file" 2>"$args_error_file" <<'PYEOF'
import shlex
import sys

try:
    args = shlex.split(sys.argv[1])
except ValueError as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(1)

for arg in args:
    sys.stdout.buffer.write(arg.encode())
    sys.stdout.buffer.write(b"\0")
PYEOF
  then
    parse_error=$(tr '\n' ' ' <"$args_error_file" | sed 's/[[:space:]]*$//')
    echo "[settlement-executor] Error: could not parse LORE_SETTLEMENT_AUDIT_ARGS: $parse_error" >&2
    emit_envelope "error" "could not parse LORE_SETTLEMENT_AUDIT_ARGS: $parse_error" "" "2" ""
    exit 0
  fi
  if [[ -s "$args_file" ]]; then
    while IFS= read -r -d '' arg; do
      extra_args+=("$arg")
    done <"$args_file"
  fi
fi

audit_kdir=""
idx=0
while [[ $idx -lt ${#extra_args[@]} ]]; do
  case "${extra_args[$idx]}" in
    --kdir)
      next_idx=$((idx + 1))
      if [[ $next_idx -lt ${#extra_args[@]} ]]; then
        audit_kdir="${extra_args[$next_idx]}"
      fi
      ;;
  esac
  idx=$((idx + 1))
done
if [[ -z "$audit_kdir" ]]; then
  audit_kdir=$(resolve_knowledge_dir 2>/dev/null || echo "")
fi
task_claims_path=""
work_dir=""
if [[ -n "$audit_kdir" ]]; then
  # Walk the active path first, then _archive/. We pick by ARTIFACT presence,
  # not directory presence: a work item can be archived and later partially
  # recreated as a stub (_meta.json + notes.md only), leaving the audit
  # artifacts in _archive/ even though _work/<slug>/ exists. Falling back on
  # dir presence alone would pin the audit to the empty stub and emit a
  # spurious skip — that was the v1 patch bug fixed here.
  candidate_dirs=(
    "$audit_kdir/_work/$work_item"
    "$audit_kdir/_work/_archive/$work_item"
  )
  any_dir_present=0
  for candidate in "${candidate_dirs[@]}"; do
    [[ -d "$candidate" ]] || continue
    any_dir_present=1
    if [[ -f "$candidate/task-claims.jsonl" || -f "$candidate/lens-findings.json" || -f "$candidate/execution-log.md" || -f "$candidate/plan.md" ]]; then
      work_dir="$candidate"
      break
    fi
  done
  if [[ -n "$work_dir" && "$work_dir" == *"/_archive/"* ]]; then
    echo "[settlement-executor] Resolving work_item=$work_item from _archive (active dir absent or stub)" >&2
  fi
  if [[ -z "$work_dir" && "$any_dir_present" -eq 1 ]]; then
    # At least one candidate dir existed but none held an auditable artifact —
    # this is the same "no auditable artifact" condition the original guard
    # detected. Skip rather than falling through to a hopeless `lore audit <slug>`.
    echo "[settlement-executor] Skipping work_item=$work_item: no auditable artifact" >&2
    emit_envelope "skipped" "no auditable artifact for work_item=$work_item" "" "0" ""
    exit 0
  fi
fi
if [[ -n "$work_dir" && -f "$work_dir/task-claims.jsonl" ]]; then
  task_claims_path="$work_dir/task-claims.jsonl"
fi

echo "[settlement-executor] Auditing work_item=$work_item claim_id=$claim_id framework=$FRAMEWORK" >&2

audit_stdout="$tmp_dir/audit-stdout.json"
audit_stderr="$tmp_dir/audit-stderr.txt"
priority_claims_file="$tmp_dir/priority-claims.json"
python3 - "$claim_id" >"$priority_claims_file" <<'PYEOF'
import json
import sys
print(json.dumps([sys.argv[1]], separators=(",", ":")))
PYEOF

audit_target="$work_item"
if [[ -n "$task_claims_path" ]]; then
  audit_target="$task_claims_path"
fi
audit_cmd=(lore audit "$audit_target" --json)
if [[ ${#extra_args[@]} -gt 0 ]]; then
  audit_cmd+=("${extra_args[@]}")
fi
audit_cmd+=(--priority-claims "$priority_claims_file")
set +e
"${audit_cmd[@]}" >"$audit_stdout" 2>"$audit_stderr"
audit_exit=$?
set -e

audit_stderr_one_line=$(tr '\n' ' ' <"$audit_stderr" | sed 's/[[:space:]]*$//')

if [[ "$audit_exit" -ne 0 ]]; then
  if [[ -z "$audit_stderr_one_line" ]]; then
    audit_stderr_one_line="lore audit exited $audit_exit"
  fi
  echo "[settlement-executor] Error: $audit_stderr_one_line" >&2
  emit_envelope "error" "$audit_stderr_one_line" "" "$audit_exit" ""
  exit 0
fi

derivation_file="$tmp_dir/derivation.json"
if ! python3 - "$audit_stdout" "$claim_id" >"$derivation_file" <<'PYEOF'
import json
import sys

path = sys.argv[1]
priority_claim_id = sys.argv[2] if len(sys.argv) > 2 else ""
try:
    with open(path, encoding="utf-8") as fh:
        audit = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    print(json.dumps({"ok": False, "verdict": "error", "evidence": f"unparseable audit JSON: {type(exc).__name__}: {exc}", "correction": None}))
    sys.exit(0)

gate = audit.get("correctness_gate") if isinstance(audit, dict) else None
if not isinstance(gate, dict):
    print(json.dumps({"ok": True, "verdict": "skipped", "evidence": "audit produced no correctness_gate block", "correction": None}))
    sys.exit(0)

verified = int(gate.get("verified") or 0)
unverified = int(gate.get("unverified") or 0)
contradicted = int(gate.get("contradicted") or 0)
total = int(gate.get("verdicts_total") or (verified + unverified + contradicted))

if total == 0:
    verdict = "skipped"
elif contradicted > 0:
    verdict = "contradicted"
elif unverified > 0 and verified == 0:
    verdict = "unverified"
elif verified > 0 and contradicted == 0:
    verdict = "verified"
else:
    verdict = "skipped"

# Default to aggregate-summary evidence; overwritten by per-claim row below when found.
evidence = f"correctness_gate: total={total} verified={verified} unverified={unverified} contradicted={contradicted}"
correction = None
verdicts_file = audit.get("verdicts_file") if isinstance(audit, dict) else None
if verdict == "contradicted" and verdicts_file:
    # Read all contradicted rows from the correctness-gate judge, then prefer the
    # row whose claim_id matches the priority claim. Per-claim evidence is what
    # downstream apply-correction needs — the aggregate summary string is too coarse
    # to drive a body-replacement mutation. Fall back to the first contradicted row
    # if no per-claim match exists (defensive — shouldn't happen given priority-claims).
    try:
        contradicted_rows = []
        with open(verdicts_file, encoding="utf-8") as fh:
            for line in fh:
                if not line.strip():
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if (row.get("judge") == "correctness-gate"
                        and row.get("verdict") == "contradicted"):
                    contradicted_rows.append(row)
        target = None
        for row in contradicted_rows:
            if row.get("claim_id") == priority_claim_id:
                target = row
                break
        if target is None and contradicted_rows:
            target = contradicted_rows[0]
        if target is not None:
            if target.get("evidence"):
                evidence = target["evidence"]
            if target.get("correction"):
                correction = target["correction"]
    except OSError:
        pass

print(json.dumps({"ok": True, "verdict": verdict, "evidence": evidence, "correction": correction}))
PYEOF
then
  echo "[settlement-executor] Error: failed to derive verdict from audit JSON" >&2
  emit_envelope "error" "failed to derive verdict from audit JSON" "" "1" "$audit_stdout"
  exit 0
fi

derive_ok=$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1])).get("ok", False)).lower())' "$derivation_file")
verdict=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("verdict", "error"))' "$derivation_file")
evidence=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("evidence", ""))' "$derivation_file")
correction=$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get("correction"); print("" if v is None else v)' "$derivation_file")

if [[ "$derive_ok" != "true" ]]; then
  echo "[settlement-executor] Error: $evidence" >&2
  emit_envelope "error" "$evidence" "" "1" ""
  exit 0
fi

emit_envelope "$verdict" "$evidence" "$correction" "$audit_exit" "$audit_stdout"
