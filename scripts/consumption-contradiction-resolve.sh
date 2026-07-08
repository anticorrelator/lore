#!/usr/bin/env bash
# consumption-contradiction-resolve.sh — Resolve a consumption-contradiction row.
#
# Canonical resolver for `_work/<slug>/consumption-contradictions.jsonl`.
# Transitions rows through the live lifecycle:
#   pending -> accepted | declined | remediated
#   accepted -> remediated
#
# Accepted/remediated transitions require calibrated verdict evidence already
# present in _scorecards/rows.jsonl. Remediation additionally writes a
# calibrated correction row, applies the commons correction, then marks the
# sidecar row remediated.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: consumption-contradiction-resolve.sh <contradiction_id>
           --status pending|accepted|declined|remediated
           --resolved-by <agent-or-human>
           [--work-item <slug>]
           [--verdict-id <id>]
           [--verdict-source correctness-gate|reverse-auditor]
           [--correction-target claim|observation|doctrine]
           [--entry <path>]
           [--evidence <file:line quote>]
           [--superseded-text <snippet>]
           [--replacement-text <snippet>]
           [--date YYYY-MM-DD]
           [--kdir <path>]
           [--json]

Accepted and remediated contradictions require a calibrated scorecard row for
--verdict-id before any commons mutation is allowed. Remediation applies the
commons correction before transitioning the sidecar row to remediated.
EOF
}

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "[consumption-contradiction] $msg"
  fi
  echo "[consumption-contradiction] Error: $msg" >&2
  exit 1
}

CONTRADICTION_ID=""
TARGET_STATUS=""
RESOLVED_BY=""
WORK_ITEM=""
VERDICT_ID=""
VERDICT_SOURCE="correctness-gate"
CORRECTION_TARGET="claim"
ENTRY_PATH=""
EVIDENCE=""
SUPERSEDED_TEXT=""
REPLACEMENT_TEXT=""
DATE_TODAY=$(date +"%Y-%m-%d")
KDIR_OVERRIDE=""
JSON_MODE=0

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

case "$1" in
  --help|-h) usage; exit 0 ;;
  --*)
    echo "[consumption-contradiction] Error: first argument must be <contradiction_id>, not a flag" >&2
    usage
    exit 1
    ;;
  *)
    CONTRADICTION_ID="$1"
    shift
    ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)             TARGET_STATUS="$2";      shift 2 ;;
    --resolved-by)        RESOLVED_BY="$2";        shift 2 ;;
    --work-item)          WORK_ITEM="$2";          shift 2 ;;
    --verdict-id)         VERDICT_ID="$2";         shift 2 ;;
    --verdict-source)     VERDICT_SOURCE="$2";     shift 2 ;;
    --correction-target)  CORRECTION_TARGET="$2";  shift 2 ;;
    --entry)              ENTRY_PATH="$2";         shift 2 ;;
    --evidence)           EVIDENCE="$2";           shift 2 ;;
    --superseded-text)    SUPERSEDED_TEXT="$2";    shift 2 ;;
    --replacement-text)   REPLACEMENT_TEXT="$2";   shift 2 ;;
    --date)               DATE_TODAY="$2";         shift 2 ;;
    --kdir)               KDIR_OVERRIDE="$2";      shift 2 ;;
    --json)               JSON_MODE=1;             shift ;;
    --help|-h)            usage; exit 0 ;;
    *)
      echo "[consumption-contradiction] Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

[[ -n "$CONTRADICTION_ID" ]] || fail "<contradiction_id> is required"
[[ -n "$TARGET_STATUS" ]] || fail "--status is required"
[[ -n "$RESOLVED_BY" ]] || fail "--resolved-by is required"

case "$TARGET_STATUS" in
  pending|accepted|declined|remediated) : ;;
  *) fail "--status must be 'pending', 'accepted', 'declined', or 'remediated' (got '$TARGET_STATUS')" ;;
esac

case "$VERDICT_SOURCE" in
  correctness-gate|reverse-auditor) : ;;
  *) fail "--verdict-source must be 'correctness-gate' or 'reverse-auditor' (got '$VERDICT_SOURCE')" ;;
esac

case "$CORRECTION_TARGET" in
  claim|observation|doctrine) : ;;
  *) fail "--correction-target must be 'claim', 'observation', or 'doctrine' (got '$CORRECTION_TARGET')" ;;
esac

if [[ "$TARGET_STATUS" == "pending" ]]; then
  fail "resolver cannot transition rows back to pending"
fi

if [[ "$TARGET_STATUS" == "accepted" || "$TARGET_STATUS" == "remediated" ]]; then
  [[ -n "$VERDICT_ID" ]] || fail "--verdict-id is required for accepted/remediated transitions"
fi

if [[ "$TARGET_STATUS" == "remediated" ]]; then
  for _pair in \
    "entry:$ENTRY_PATH" \
    "evidence:$EVIDENCE" \
    "superseded-text:$SUPERSEDED_TEXT" \
    "replacement-text:$REPLACEMENT_TEXT"
  do
    _flag="${_pair%%:*}"
    _val="${_pair#*:}"
    [[ -n "$_val" ]] || fail "--$_flag is required for remediated transitions"
  done
fi

if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required but not found on PATH"
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR="$KDIR_OVERRIDE"
else
  KDIR=$(resolve_knowledge_dir)
fi
[[ -d "$KDIR" ]] || fail "knowledge store not found at: $KDIR"

ROWS_FILE="$KDIR/_scorecards/rows.jsonl"

locate_row() {
  python3 - "$KDIR" "$CONTRADICTION_ID" "$WORK_ITEM" <<'PYEOF'
import json, os, sys

kdir, contradiction_id, work_item = sys.argv[1:4]
work_base = os.path.join(kdir, "_work")
found = None

if work_item:
    candidates = [os.path.join(work_base, work_item, "consumption-contradictions.jsonl")]
else:
    candidates = []
    if os.path.isdir(work_base):
        for name in sorted(os.listdir(work_base)):
            sidecar = os.path.join(work_base, name, "consumption-contradictions.jsonl")
            if os.path.isfile(sidecar):
                candidates.append(sidecar)

for sidecar in candidates:
    if not os.path.isfile(sidecar):
        continue
    with open(sidecar, encoding="utf-8") as f:
        for idx, line in enumerate(f):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                row = json.loads(stripped)
            except json.JSONDecodeError:
                continue
            if row.get("contradiction_id") == contradiction_id:
                found = {
                    "sidecar": sidecar,
                    "line_index": idx,
                    "row": row,
                    "work_item": row.get("work_item") or os.path.basename(os.path.dirname(sidecar)),
                }
                break
    if found:
        break

print(json.dumps(found or {"error": "not_found"}))
PYEOF
}

ROW_CONTEXT=$(locate_row)
if [[ "$(printf '%s' "$ROW_CONTEXT" | jq -r '.error // ""')" == "not_found" ]]; then
  fail "contradiction_id '$CONTRADICTION_ID' not found"
fi

CURRENT_STATUS=$(printf '%s' "$ROW_CONTEXT" | jq -r '.row.status // "pending"')
SIDECAR=$(printf '%s' "$ROW_CONTEXT" | jq -r '.sidecar')
ROW_WORK_ITEM=$(printf '%s' "$ROW_CONTEXT" | jq -r '.work_item')
KNOWLEDGE_PATH=$(printf '%s' "$ROW_CONTEXT" | jq -r '.row.prefetched_commons_entry.knowledge_path // ""')
CLAIM_ID=$(printf '%s' "$ROW_CONTEXT" | jq -r '.row.claim_payload.claim_id // ""')
CLAIM_TEXT=$(printf '%s' "$ROW_CONTEXT" | jq -r '.row.claim_payload.claim_text // ""')

if [[ "$CURRENT_STATUS" == "$TARGET_STATUS" ]]; then
  OUT=$(jq -n \
    --arg contradiction_id "$CONTRADICTION_ID" \
    --arg status "$CURRENT_STATUS" \
    --arg sidecar "${SIDECAR#$KDIR/}" \
    '{status:"ok", idempotent:true, contradiction_id:$contradiction_id, current_status:$status, sidecar:$sidecar}')
  if [[ $JSON_MODE -eq 1 ]]; then
    json_output "$OUT"
  fi
  echo "[consumption-contradiction] Contradiction $CONTRADICTION_ID already $CURRENT_STATUS"
  exit 0
fi

case "$CURRENT_STATUS:$TARGET_STATUS" in
  pending:accepted|pending:declined|pending:remediated|accepted:remediated) : ;;
  *)
    fail "invalid transition: $CURRENT_STATUS -> $TARGET_STATUS"
    ;;
esac

has_calibrated_verdict() {
  [[ -f "$ROWS_FILE" ]] || return 1
  python3 - "$ROWS_FILE" "$VERDICT_ID" <<'PYEOF'
import json, sys
rows_file, verdict_id = sys.argv[1:3]
with open(rows_file, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        ids = {row.get("verdict_id"), row.get("calibrated_by_verdict_id")}
        ids.update(row.get("verdict_ids") or [])
        if verdict_id in ids and row.get("calibration_state") == "calibrated":
            sys.exit(0)
sys.exit(1)
PYEOF
}

evidence_row_exists() {
  [[ -f "$ROWS_FILE" ]] || return 1
  python3 - "$ROWS_FILE" "$CONTRADICTION_ID" "$VERDICT_ID" <<'PYEOF'
import json, sys
rows_file, contradiction_id, verdict_id = sys.argv[1:4]
with open(rows_file, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if (
            row.get("kind") == "consumption-contradiction"
            and row.get("tier") == "correction"
            and row.get("contradiction_id") == contradiction_id
            and row.get("calibrated_by_verdict_id") == verdict_id
            and row.get("calibration_state") == "calibrated"
        ):
            sys.exit(0)
sys.exit(1)
PYEOF
}

emit_correction_evidence() {
  if evidence_row_exists; then
    return 0
  fi

  local now rel_entry row_json
  now=$(timestamp_iso)
  rel_entry="$KNOWLEDGE_PATH"
  if [[ -n "$ENTRY_PATH" ]]; then
    rel_entry="${ENTRY_PATH#$KDIR/}"
  fi

  row_json=$(python3 - "$CONTRADICTION_ID" "$ROW_WORK_ITEM" "$VERDICT_ID" \
                  "$VERDICT_SOURCE" "$CORRECTION_TARGET" "$rel_entry" \
                  "$CLAIM_ID" "$CLAIM_TEXT" "$now" <<'PYEOF'
import json, sys
(
    contradiction_id, work_item, verdict_id, verdict_source, correction_target,
    entry_path, claim_id, claim_text, now
) = sys.argv[1:10]
print(json.dumps({
    "schema_version": "1",
    "kind": "consumption-contradiction",
    "tier": "correction",
    "calibration_state": "calibrated",
    "metric": "commons_correction",
    "value": 1,
    "sample_size": 1,
    "window_start": now,
    "window_end": now,
    "granularity": "claim-local",
    "verdict_source": verdict_source,
    "contradiction_id": contradiction_id,
    "work_item": work_item,
    "claim_id": claim_id,
    "claim_text": claim_text,
    "corrected_entry_path": entry_path,
    "correction_target": correction_target,
    "calibrated_by_verdict_id": verdict_id,
    "verdict_id": verdict_id,
    "source_artifact_ids": [contradiction_id],
}, ensure_ascii=False))
PYEOF
)

  "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KDIR" --row "$row_json" >/dev/null
}

entry_already_corrected() {
  [[ -n "$ENTRY_PATH" && -f "$ENTRY_PATH" ]] || return 1
  python3 - "$ENTRY_PATH" "$VERDICT_ID" <<'PYEOF'
import json, re, sys
entry_path, verdict_id = sys.argv[1:3]
try:
    text = open(entry_path, encoding="utf-8").read()
except (OSError, UnicodeDecodeError):
    sys.exit(1)
m = re.search(r"\|\s*corrections:\s*(\[.*?\])\s*(?:-->|\|)", text, re.DOTALL)
if not m:
    sys.exit(1)
try:
    items = json.loads(m.group(1))
except json.JSONDecodeError:
    sys.exit(1)
for item in items:
    if isinstance(item, dict) and item.get("verdict_id") == verdict_id:
        sys.exit(0)
sys.exit(1)
PYEOF
}

transition_sidecar() {
  local status="$1"
  local now="$2"
  local rel_entry="${ENTRY_PATH#$KDIR/}"
  python3 - "$SIDECAR" "$CONTRADICTION_ID" "$status" "$RESOLVED_BY" "$now" \
            "$VERDICT_ID" "$VERDICT_SOURCE" "$rel_entry" "$CORRECTION_TARGET" <<'PYEOF'
import json, os, sys, tempfile

sidecar, contradiction_id, target_status, resolved_by, now, verdict_id, verdict_source, entry_path, correction_target = sys.argv[1:10]
with open(sidecar, encoding="utf-8") as f:
    lines = f.readlines()

out_lines = []
changed = False
for line in lines:
    stripped = line.strip()
    if not stripped:
        out_lines.append(line)
        continue
    try:
        row = json.loads(stripped)
    except json.JSONDecodeError:
        out_lines.append(line)
        continue
    if row.get("contradiction_id") != contradiction_id:
        out_lines.append(line)
        continue

    row["status"] = target_status
    row["resolved_by"] = resolved_by
    if not row.get("resolved_at"):
        row["resolved_at"] = now
    if target_status in {"accepted", "remediated"}:
        row["accepted_by_verdict_id"] = verdict_id
        row["accepted_by_verdict_source"] = verdict_source
        row["accepted_at"] = row.get("accepted_at") or now
    if target_status == "remediated":
        row["remediated_at"] = now
        row["remediated_by"] = resolved_by
        row["correction"] = {
            "entry_path": entry_path,
            "correction_target": correction_target,
            "calibrated_by_verdict_id": verdict_id,
        }
    out_lines.append(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
    changed = True

if not changed:
    print(json.dumps({"status": "not_found"}))
    sys.exit(0)

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(sidecar))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.writelines(out_lines)
    os.replace(tmp, sidecar)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise

print(json.dumps({"status": "ok"}))
PYEOF
}

if [[ "$TARGET_STATUS" == "accepted" || "$TARGET_STATUS" == "remediated" ]]; then
  if ! has_calibrated_verdict; then
    echo "[consumption-contradiction] Error: calibrated verdict evidence not found for verdict_id=$VERDICT_ID; refusing $TARGET_STATUS transition" >&2
    exit 4
  fi
  emit_correction_evidence
fi

if [[ "$TARGET_STATUS" == "remediated" ]]; then
  if [[ ! -f "$ENTRY_PATH" ]]; then
    fail "entry not found: $ENTRY_PATH"
  fi
  if entry_already_corrected; then
    :
  else
    APPLY_ARGS=(
      --entry "$ENTRY_PATH"
      --verdict-id "$VERDICT_ID"
      --verdict-source "$VERDICT_SOURCE"
      --evidence "$EVIDENCE"
      --superseded-text "$SUPERSEDED_TEXT"
      --replacement-text "$REPLACEMENT_TEXT"
      --date "$DATE_TODAY"
      --kdir "$KDIR"
    )
    if [[ $JSON_MODE -eq 1 ]]; then
      APPLY_OUT=$("$SCRIPT_DIR/apply-correction.sh" "${APPLY_ARGS[@]}" 2>&1) || {
        echo "$APPLY_OUT" >&2
        json_error "[consumption-contradiction] commons correction failed"
      }
    else
      "$SCRIPT_DIR/apply-correction.sh" "${APPLY_ARGS[@]}"
    fi
  fi
fi

NOW=$(timestamp_iso)
TRANSITION_RESULT=$(transition_sidecar "$TARGET_STATUS" "$NOW")
if [[ "$(printf '%s' "$TRANSITION_RESULT" | jq -r '.status')" != "ok" ]]; then
  fail "failed to update sidecar for contradiction_id=$CONTRADICTION_ID"
fi

REL_SIDECAR="${SIDECAR#$KDIR/}"
OUT=$(jq -n \
  --arg contradiction_id "$CONTRADICTION_ID" \
  --arg previous_status "$CURRENT_STATUS" \
  --arg status "$TARGET_STATUS" \
  --arg sidecar "$REL_SIDECAR" \
  --arg resolved_at "$NOW" \
  '{status:"ok", idempotent:false, contradiction_id:$contradiction_id, previous_status:$previous_status, current_status:$status, sidecar:$sidecar, resolved_at:$resolved_at}')

if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$OUT"
fi

echo "[consumption-contradiction] Contradiction $CONTRADICTION_ID transitioned $CURRENT_STATUS -> $TARGET_STATUS (sidecar: $REL_SIDECAR)"
