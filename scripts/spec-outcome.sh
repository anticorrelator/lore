#!/usr/bin/env bash
# spec-outcome.sh — File a lead-normalized /spec ceremony outcome.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REF=""; SLUG=""; CEREMONY=""; ADVISOR=""; ATTEMPT_ID=""; OUTCOME=""; VERDICT=""
EVIDENCE_FILE=""; REASON=""; JSON_MODE=0

usage() {
  cat >&2 <<'EOF'
Usage: lore spec outcome <ref> --ceremony <spec-design|spec-post-plan>
       --advisor <name> --attempt-id <id>
       --outcome <completed|failed|skipped|needs-decision>
       --verdict <raw-token> --evidence-manifest <json-file>
       [--reason <text>] [--json]

File a ceremony result already normalized by the lead. The verb validates,
persists, and recovers bookkeeping; it never infers evaluator disposition.
EOF
}

emit() {
  local status="$1" outcome_id="$2" message="${3:-}" exit_code="${4:-0}"
  if [[ $JSON_MODE -eq 1 ]]; then
    python3 - "$status" "$outcome_id" "$SLUG" "$CEREMONY" "$OUTCOME" "$message" <<'PY'
import json, sys
status, oid, slug, ceremony, outcome, message = sys.argv[1:]
print(json.dumps({"schema_version":1, "status":status, "slug":slug or None,
                  "ceremony":ceremony or None, "outcome":outcome or None,
                  "outcome_id":oid or None, "error":message or None}, ensure_ascii=False))
PY
  else
    if [[ $exit_code -eq 0 ]]; then
      echo "[spec outcome] $status: $CEREMONY/$ADVISOR ($OUTCOME)"
      echo "Outcome id: $outcome_id"
    else
      echo "[spec outcome] $status: $message" >&2
      [[ -z "$outcome_id" ]] || echo "Outcome id: $outcome_id" >&2
    fi
  fi
  exit "$exit_code"
}

require_value() { [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || emit refused "" "$1 requires a non-empty value" 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ceremony) require_value --ceremony "${2:-}"; CEREMONY="$2"; shift 2 ;;
    --ceremony=*) CEREMONY="${1#--ceremony=}"; shift ;;
    --advisor) require_value --advisor "${2:-}"; ADVISOR="$2"; shift 2 ;;
    --advisor=*) ADVISOR="${1#--advisor=}"; shift ;;
    --attempt-id) require_value --attempt-id "${2:-}"; ATTEMPT_ID="$2"; shift 2 ;;
    --attempt-id=*) ATTEMPT_ID="${1#--attempt-id=}"; shift ;;
    --outcome) require_value --outcome "${2:-}"; OUTCOME="$2"; shift 2 ;;
    --outcome=*) OUTCOME="${1#--outcome=}"; shift ;;
    --verdict) require_value --verdict "${2:-}"; VERDICT="$2"; shift 2 ;;
    --verdict=*) VERDICT="${1#--verdict=}"; shift ;;
    --evidence-manifest) require_value --evidence-manifest "${2:-}"; EVIDENCE_FILE="$2"; shift 2 ;;
    --evidence-manifest=*) EVIDENCE_FILE="${1#--evidence-manifest=}"; shift ;;
    --reason) require_value --reason "${2:-}"; REASON="$2"; shift 2 ;;
    --reason=*) REASON="${1#--reason=}"; shift ;;
    --json) JSON_MODE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) emit refused "" "unknown flag: $1" 1 ;;
    *) [[ -z "$REF" ]] || emit refused "" "unexpected extra argument: $1" 1; REF="$1"; shift ;;
  esac
done

[[ -n "$REF" ]] || { usage; emit refused "" "missing required argument: <ref>" 1; }
for declaration in CEREMONY ADVISOR ATTEMPT_ID OUTCOME VERDICT EVIDENCE_FILE; do
  if [[ -z "${!declaration}" ]]; then
    declaration_name=$(printf '%s' "$declaration" | tr '[:upper:]_' '[:lower:]-')
    emit refused "" "missing required declaration: $declaration_name" 1
  fi
done
case "$CEREMONY" in spec-design|spec-post-plan) ;; *) emit refused "" "invalid ceremony '$CEREMONY'" 1 ;; esac
case "$OUTCOME" in completed|failed|skipped|needs-decision) ;; *) emit refused "" "invalid outcome '$OUTCOME'" 1 ;; esac
[[ -f "$EVIDENCE_FILE" && -r "$EVIDENCE_FILE" ]] || emit refused "" "evidence manifest is not readable: $EVIDENCE_FILE" 1
if [[ "$OUTCOME" == "skipped" || "$OUTCOME" == "needs-decision" ]]; then
  [[ -n "$REASON" ]] || emit refused "" "--reason is required for outcome '$OUTCOME'" 1
else
  [[ -z "$REASON" ]] || emit refused "" "--reason must be omitted for outcome '$OUTCOME'" 1
fi

set +e
RESOLVED=$(bash "$SCRIPT_DIR/resolve-work-ref.sh" "$REF" 2>&1)
RESOLVE_RC=$?
set -e
if [[ $RESOLVE_RC -ne 0 ]]; then printf '%s\n' "$RESOLVED" >&2; exit "$RESOLVE_RC"; fi
SLUG=$(printf '%s\n' "$RESOLVED" | head -1)
ARCHIVED=$(printf '%s\n' "$RESOLVED" | sed -n '2p')
[[ "$ARCHIVED" == "false" ]] || emit refused "" "work item '$SLUG' is archived" 1

KDIR=$(resolve_knowledge_dir)
ITEM_DIR="$KDIR/_work/$SLUG"
LOG_FILE="$ITEM_DIR/execution-log.md"
ROWS_FILE="$KDIR/_scorecards/rows.jsonl"
LEAD_TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" "$LORE_REPO_DIR/skills/spec/SKILL.md" 2>/dev/null) \
  || emit refused "" "spec lead template version could not be resolved" 1

set +e
VALIDATED=$(python3 - "$EVIDENCE_FILE" "$SLUG" "$CEREMONY" "$ADVISOR" "$ATTEMPT_ID" "$OUTCOME" "$VERDICT" "$REASON" <<'PY'
import hashlib, json, sys
path, slug, ceremony, advisor, attempt, outcome, verdict, reason = sys.argv[1:]
allowed = {"schema_version", "evaluator_locator", "evaluator_template_version", "framework", "model",
           "final_round", "disposition_ledger_sha256", "source_plan_sha256"}
try: evidence = json.load(open(path, encoding="utf-8"))
except Exception as exc:
    print(f"invalid evidence manifest: {exc}", file=sys.stderr); raise SystemExit(1)
if not isinstance(evidence, dict) or set(evidence) != allowed:
    print("evidence manifest must declare exactly: " + ", ".join(sorted(allowed)), file=sys.stderr); raise SystemExit(1)
if evidence.get("schema_version") != 1:
    print("evidence schema_version must be the integer 1", file=sys.stderr); raise SystemExit(1)
if outcome in {"completed", "failed"}:
    missing = [k for k in allowed - {"schema_version"} if evidence.get(k) is None or evidence.get(k) == ""]
    if missing:
        print("completed/failed evidence fields may not be null: " + ", ".join(sorted(missing)), file=sys.stderr); raise SystemExit(1)
for key in ("evaluator_locator", "framework", "model"):
    value = evidence.get(key)
    if value is not None and (not isinstance(value, str) or not value):
        print(f"{key} must be a non-empty string or null", file=sys.stderr); raise SystemExit(1)
template = evidence.get("evaluator_template_version")
if template is not None and (not isinstance(template, str) or len(template) != 12 or any(c not in "0123456789abcdef" for c in template)):
    print("evaluator_template_version must be null or 12 lowercase hex characters", file=sys.stderr); raise SystemExit(1)
for key in ("disposition_ledger_sha256", "source_plan_sha256"):
    value = evidence.get(key)
    if value is not None and (not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value)):
        print(f"{key} must be null or a lowercase sha256", file=sys.stderr); raise SystemExit(1)
if not isinstance(evidence.get("final_round"), (int, type(None))) or isinstance(evidence.get("final_round"), bool):
    print("final_round must be an integer or null", file=sys.stderr); raise SystemExit(1)

def canonical(value): return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
evidence_hash = hashlib.sha256(canonical(evidence)).hexdigest()
semantic = {"slug":slug, "ceremony":ceremony, "advisor":advisor, "attempt_id":attempt,
            "outcome":outcome, "verdict":verdict, "evidence_manifest_sha256":evidence_hash}
outcome_id = hashlib.sha256(canonical(semantic)).hexdigest()
record = {"schema_version":1, "outcome_id":outcome_id, **semantic,
          "reason": reason or None, "evidence": evidence}
print(json.dumps({"outcome_id":outcome_id, "evidence_hash":evidence_hash,
                  "record":record}, ensure_ascii=False, separators=(",", ":")))
PY
)
VALIDATE_RC=$?
set -e
[[ $VALIDATE_RC -eq 0 ]] || emit refused "" "evidence manifest validation failed" 1

OUTCOME_ID=$(jq -r '.outcome_id' <<<"$VALIDATED")
RECORD=$(jq -c '.record' <<<"$VALIDATED")

# The execution-log record is authoritative. Reusing an attempt id with any
# different semantic field is a collision, never an inferred retry.
EXISTING=$(python3 - "$LOG_FILE" "$ATTEMPT_ID" <<'PY'
import json, re, sys
path, attempt = sys.argv[1:]
matches=[]
try: text=open(path, encoding="utf-8").read()
except FileNotFoundError: text=""
for m in re.finditer(r"(?m)^Spec-outcome-record: (\{.*\})$", text):
    try: row=json.loads(m.group(1))
    except Exception: continue
    if row.get("attempt_id")==attempt:
        matches.append(row)
print(json.dumps(matches[-1] if matches else None, ensure_ascii=False))
PY
)
if [[ "$EXISTING" != "null" ]]; then
  EXISTING_ID=$(jq -r '.outcome_id // empty' <<<"$EXISTING")
  [[ "$EXISTING_ID" == "$OUTCOME_ID" ]] || emit refused "$OUTCOME_ID" "attempt-id collision: '$ATTEMPT_ID' already names a different semantic outcome" 1
fi

write_scorecard() {
  local timestamp row
  timestamp=$(timestamp_iso)
  row=$(jq -cn --arg slug "$SLUG" --arg outcome_id "$OUTCOME_ID" --arg ceremony "$CEREMONY" \
    --arg advisor "$ADVISOR" --arg harness "$(jq -r '.record.evidence.framework // "unavailable"' <<<"$VALIDATED")" \
    --arg reason "$REASON" --arg timestamp "$timestamp" \
    '{schema_version:"1",kind:"telemetry",tier:"telemetry",calibration_state:"unknown",
      event_type:"ceremony-resolution",metric:"ceremony_resolution_outcome",
      outcome:"needs-decision",disposition:"unhandled",ceremony:$ceremony,advisor:$advisor,
      harness:$harness,reason:$reason,
      corrective_action:"Lead adjudication is required before the spec protocol can consume this ceremony result.",
      timestamp:$timestamp,work_item:$slug,source_artifact_ids:[$slug],outcome_id:$outcome_id}')
  bash "$SCRIPT_DIR/scorecard-append.sh" --row "$row" >/dev/null
}

scorecard_present() {
  [[ -f "$ROWS_FILE" ]] && jq -e --arg id "$OUTCOME_ID" 'select(.outcome_id == $id)' "$ROWS_FILE" >/dev/null 2>&1
}

if [[ "$EXISTING" == "null" ]]; then
  if ! printf 'Spec verb: outcome\nSpec-outcome-record: %s\nOutcome-id: %s\nCeremony: %s\nAdvisor: %s\nAttempt-id: %s\nOutcome: %s\nRaw-verdict: %s\nEvidence-manifest-sha256: %s\nReason: %s\n' \
    "$RECORD" "$OUTCOME_ID" "$CEREMONY" "$ADVISOR" "$ATTEMPT_ID" "$OUTCOME" "$VERDICT" \
    "$(jq -r '.evidence_hash' <<<"$VALIDATED")" "${REASON:-None}" \
    | bash "$SCRIPT_DIR/write-execution-log.sh" --slug "$SLUG" --source spec-verb --template-version "$LEAD_TEMPLATE_VERSION" >/dev/null; then
    emit refused "$OUTCOME_ID" "authoritative execution-log filing failed" 1
  fi
  if [[ "$OUTCOME" == "needs-decision" ]]; then
    if write_scorecard; then emit completed "$OUTCOME_ID"; else emit partial "$OUTCOME_ID" "authoritative outcome filed; auxiliary ceremony-resolution append failed — retry the same command" 1; fi
  fi
  emit completed "$OUTCOME_ID"
fi

if [[ "$OUTCOME" == "needs-decision" ]] && ! scorecard_present; then
  if write_scorecard; then emit recovered "$OUTCOME_ID"; else emit partial "$OUTCOME_ID" "authoritative outcome exists; auxiliary ceremony-resolution append still fails" 1; fi
fi
emit reused "$OUTCOME_ID"
