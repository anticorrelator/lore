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
#   error         if audit exits nonzero (other than exit 3), audit JSON is
#                 unparseable, or input/args cannot be parsed.
#
# Exit 3 is informational, not failure: the audit completed and printed its
# full verdict JSON, exiting 3 only to flag that the reverse-auditor omission
# claim was routed to audit-attempts.jsonl. Exit-3 stdout derives a real
# verdict by the rules above.

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

# settlement.auditor_model scopes a judge-model override to settlement-executed
# audits: exporting LORE_MODEL_JUDGE feeds resolve_model_for_role's env layer,
# so audit-artifact.sh needs no resolution changes and standalone `lore audit`
# runs are untouched. When the setting is present it overrides any inherited
# LORE_MODEL_JUDGE; when absent the inherited/normal resolution stays intact.
SETTLEMENT_SETTINGS_FILE="${LORE_SETTLEMENT_SETTINGS_FILE:-${LORE_DATA_DIR:-$HOME/.lore}/config/settings.json}"
if [[ -f "$SETTLEMENT_SETTINGS_FILE" ]] && command -v jq >/dev/null 2>&1; then
  AUDITOR_MODEL=$(jq -r '.settlement.auditor_model // empty' "$SETTLEMENT_SETTINGS_FILE" 2>/dev/null || true)
  if [[ -n "$AUDITOR_MODEL" ]]; then
    export LORE_MODEL_JUDGE="$AUDITOR_MODEL"
  fi
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
    kind = item.get("kind") or "task-claim"
    # source_id is the natural id of the source row: claim_id for task-claim,
    # candidate_id for omission, contradiction_id for consumption-contradiction.
    # Older queue items only carry claim_id; fall back so historical rows still
    # process. The executor forwards this as `lore audit --kind <K> --id <ID>`.
    source_id = item.get("source_id") or item.get("claim_id") or item.get("candidate_id") or item.get("contradiction_id") or ""
    claim_id = item.get("claim_id") or source_id
except Exception as exc:
    print(json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"}))
    sys.exit(0)

if not work_item:
    print(json.dumps({"ok": False, "error": "input item.work_item is required"}))
elif not source_id:
    print(json.dumps({"ok": False, "error": "input item.source_id (or claim_id) is required"}))
else:
    print(json.dumps({"ok": True, "work_item": work_item, "claim_id": claim_id, "kind": kind, "source_id": source_id}))
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
kind=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kind"])' "$fields_file")
source_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_id"])' "$fields_file")

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

# Map kind to its sole source filename. Mirrors KIND_SOURCES in
# settlement-processor.py — both must agree.
source_filename=""
case "$kind" in
  task-claim)                 source_filename="task-claims.jsonl" ;;
  omission)                   source_filename="audit-candidates.jsonl" ;;
  consumption-contradiction)  source_filename="consumption-contradictions.jsonl" ;;
  commons)                    source_filename="promoted-commons.jsonl" ;;
  *)
    echo "[settlement-executor] Error: unknown kind '$kind'" >&2
    emit_envelope "error" "unknown kind: $kind" "" "1" ""
    exit 0
    ;;
esac

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
    if [[ -f "$candidate/$source_filename" ]]; then
      work_dir="$candidate"
      break
    fi
  done
  if [[ -n "$work_dir" && "$work_dir" == *"/_archive/"* ]]; then
    echo "[settlement-executor] Resolving work_item=$work_item from _archive (active dir absent or stub)" >&2
  fi
  if [[ -z "$work_dir" && "$any_dir_present" -eq 1 ]]; then
    # At least one candidate dir existed but none held the per-kind source
    # file — skip rather than driving the audit on a missing source.
    echo "[settlement-executor] Skipping work_item=$work_item kind=$kind: no $source_filename" >&2
    emit_envelope "skipped" "no auditable artifact for work_item=$work_item kind=$kind" "" "0" ""
    exit 0
  fi
fi

echo "[settlement-executor] Auditing work_item=$work_item kind=$kind id=$source_id framework=$FRAMEWORK" >&2

audit_stdout="$tmp_dir/audit-stdout.json"
audit_stderr="$tmp_dir/audit-stderr.txt"

audit_cmd=(lore audit --kind "$kind" --id "$source_id" --work-item "$work_item" --json)
if [[ ${#extra_args[@]} -gt 0 ]]; then
  audit_cmd+=("${extra_args[@]}")
fi
set +e
"${audit_cmd[@]}" >"$audit_stdout" 2>"$audit_stderr"
audit_exit=$?
set -e

audit_stderr_one_line=$(tr '\n' ' ' <"$audit_stderr" | sed 's/[[:space:]]*$//')

# Exit 3 is informational, not failure: `lore audit` completed and printed a
# full verdict JSON, then exited 3 only to signal that the reverse-auditor
# omission claim was routed to audit-attempts.jsonl (grounding preflight
# failed). Its stdout carries a complete gate/curator/RA summary, so it derives
# a real verdict by the normal rules. Treating it as fatal discarded that
# summary and converted adjudicated claims into verdict=error. Every other
# non-zero exit is a genuine failure and keeps the error-envelope path.
if [[ "$audit_exit" -ne 0 && "$audit_exit" -ne 3 ]]; then
  if [[ -z "$audit_stderr_one_line" ]]; then
    audit_stderr_one_line="lore audit exited $audit_exit"
  fi
  echo "[settlement-executor] Error: $audit_stderr_one_line" >&2
  emit_envelope "error" "$audit_stderr_one_line" "" "$audit_exit" ""
  exit 0
fi
if [[ "$audit_exit" -eq 3 ]]; then
  echo "[settlement-executor] audit exit 3 (grounding preflight routed omission to audit-attempts); deriving verdict from stdout" >&2
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
    #
    # The verdicts file is written by audit-artifact.sh as one ENVELOPE per judge
    # run, each carrying a nested `verdicts: [...]` array of per-claim rows.
    # `settlement-record-append.sh`'s contract documents a flat-row variant; we
    # accept both for forward compatibility — descend into `verdicts[]` when
    # present, otherwise treat the line itself as the row.
    try:
        contradicted_rows = []
        with open(verdicts_file, encoding="utf-8") as fh:
            for line in fh:
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(record, dict):
                    continue
                if record.get("judge") != "correctness-gate":
                    continue
                inner = record.get("verdicts")
                if isinstance(inner, list):
                    candidate_rows = [r for r in inner if isinstance(r, dict)]
                else:
                    candidate_rows = [record]
                for row in candidate_rows:
                    if row.get("verdict") == "contradicted":
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
