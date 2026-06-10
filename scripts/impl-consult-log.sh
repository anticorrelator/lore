#!/usr/bin/env bash
# impl-consult-log.sh — File a consultation the lead has already answered
# Usage: impl-consult-log.sh <ref> --consultation-id <id> --worker <name> --domain <domain>
#        --handler <lead|skill|agent> --question <text> --answer <text>
#        [--skill-template-version <hash>] [--advisor-template-version <hash>]
#        [--template-version <hash>] [--json]
#
# Judgment in, filing out: the answer is the lead's already-made judgment and
# this script never produces or amends it. Missing answer or consultation
# metadata is a non-zero usage error before any write.
#
# Per-handler field contract (R = required, - = must be omitted):
#
#   handler   --skill-template-version   --advisor-template-version
#   lead                -                            -
#   skill               R                            -
#   agent               -                            R
#
# Side effects (both provenance-stamped):
#   1. Appends one record to the work item's consultation-transcript.jsonl —
#      this script is the sole sanctioned writer of that file. The record is
#      the durable form of the lead's per-run consultation transcript that
#      required-consultation acknowledgement checks intersect against.
#   2. Appends one entry to execution-log.md (via write-execution-log.sh,
#      --source impl-verb) in the Step 4.0 consultation log format; question
#      and answer are JSON-string encoded so multi-line values survive as
#      single log lines.
#
# Exit codes:
#   0  consultation filed; transcript/log identifiers on stdout
#   1  validation error / no work-item match
#   2  ambiguous work-item reference

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

VALID_HANDLERS="lead|skill|agent"

REF=""
CONSULTATION_ID=""
WORKER=""
DOMAIN=""
HANDLER=""
QUESTION=""
ANSWER=""
SKILL_TV=""
ADVISOR_TV=""
TEMPLATE_VERSION=""
JSON_MODE=0
QUESTION_SET=0
ANSWER_SET=0
SKILL_TV_SET=0
ADVISOR_TV_SET=0

usage() {
  cat >&2 <<EOF
Usage: lore impl consult-log <ref> --consultation-id <id> --worker <name> --domain <domain>
                             --handler <lead|skill|agent> --question <text> --answer <text>
                             [--skill-template-version <hash>] [--advisor-template-version <hash>]
                             [--template-version <hash>] [--json]

Files a consultation the lead has already answered: appends the transcript
record (consultation-transcript.jsonl) and the execution-log entry, both
provenance-stamped. The answer is required — this script never infers it.

Per-handler fields: --skill-template-version on skill; --advisor-template-version
on agent. All other combinations are rejected.

Exit codes: 0 filed (identifiers on stdout), 1 error/no match, 2 ambiguous reference
EOF
}

fail() {
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$1"
  fi
  echo "[impl] Error: $1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --consultation-id)
      CONSULTATION_ID="${2:-}"
      shift 2
      ;;
    --consultation-id=*)
      CONSULTATION_ID="${1#--consultation-id=}"
      shift
      ;;
    --worker)
      WORKER="${2:-}"
      shift 2
      ;;
    --worker=*)
      WORKER="${1#--worker=}"
      shift
      ;;
    --domain)
      DOMAIN="${2:-}"
      shift 2
      ;;
    --domain=*)
      DOMAIN="${1#--domain=}"
      shift
      ;;
    --handler)
      HANDLER="${2:-}"
      shift 2
      ;;
    --handler=*)
      HANDLER="${1#--handler=}"
      shift
      ;;
    --question)
      QUESTION="${2:-}"
      QUESTION_SET=1
      shift 2
      ;;
    --question=*)
      QUESTION="${1#--question=}"
      QUESTION_SET=1
      shift
      ;;
    --answer)
      ANSWER="${2:-}"
      ANSWER_SET=1
      shift 2
      ;;
    --answer=*)
      ANSWER="${1#--answer=}"
      ANSWER_SET=1
      shift
      ;;
    --skill-template-version)
      SKILL_TV="${2:-}"
      SKILL_TV_SET=1
      shift 2
      ;;
    --skill-template-version=*)
      SKILL_TV="${1#--skill-template-version=}"
      SKILL_TV_SET=1
      shift
      ;;
    --advisor-template-version)
      ADVISOR_TV="${2:-}"
      ADVISOR_TV_SET=1
      shift 2
      ;;
    --advisor-template-version=*)
      ADVISOR_TV="${1#--advisor-template-version=}"
      ADVISOR_TV_SET=1
      shift
      ;;
    --template-version)
      TEMPLATE_VERSION="${2:-}"
      shift 2
      ;;
    --template-version=*)
      TEMPLATE_VERSION="${1#--template-version=}"
      shift
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      fail "Unknown flag: $1"
      ;;
    *)
      if [[ -z "$REF" ]]; then
        REF="$1"
      else
        fail "Unexpected extra argument: $1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$REF" ]]; then
  usage
  fail "Missing required argument: <ref>"
fi

[[ -n "$CONSULTATION_ID" ]] || fail "--consultation-id is required"
[[ -n "$WORKER" ]] || fail "--worker is required"
[[ -n "$DOMAIN" ]] || fail "--domain is required"

if [[ -z "$HANDLER" ]]; then
  fail "--handler is required ($VALID_HANDLERS)"
fi

case "$HANDLER" in
  lead|skill|agent) ;;
  *)
    fail "--handler must be one of: $VALID_HANDLERS (got '$HANDLER')"
    ;;
esac

if [[ $QUESTION_SET -eq 0 || -z "$QUESTION" ]]; then
  fail "--question is required (the worker's consultation question)"
fi
if [[ $ANSWER_SET -eq 0 || -z "$ANSWER" ]]; then
  fail "--answer is required (the lead's already-made answer; this script never infers it)"
fi

# --- Per-handler field-presence contract -------------------------------------
case "$HANDLER" in
  lead)
    if [[ $SKILL_TV_SET -eq 1 ]]; then
      fail "handler 'lead' does not take --skill-template-version"
    fi
    if [[ $ADVISOR_TV_SET -eq 1 ]]; then
      fail "handler 'lead' does not take --advisor-template-version"
    fi
    ;;
  skill)
    if [[ $SKILL_TV_SET -eq 0 || -z "$SKILL_TV" ]]; then
      fail "handler 'skill' requires --skill-template-version <hash>"
    fi
    if [[ $ADVISOR_TV_SET -eq 1 ]]; then
      fail "handler 'skill' does not take --advisor-template-version"
    fi
    ;;
  agent)
    if [[ $ADVISOR_TV_SET -eq 0 || -z "$ADVISOR_TV" ]]; then
      fail "handler 'agent' requires --advisor-template-version <hash>"
    fi
    if [[ $SKILL_TV_SET -eq 1 ]]; then
      fail "handler 'agent' does not take --skill-template-version"
    fi
    ;;
esac

# --- Resolve the work-item reference (tri-state exit passthrough) ------------
set +e
RESOLVED=$(bash "$SCRIPT_DIR/resolve-work-ref.sh" "$REF")
RESOLVE_RC=$?
set -e
if [[ $RESOLVE_RC -ne 0 ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    printf '{"error": "could not resolve work-item reference (exit %s)"}\n' "$RESOLVE_RC"
  fi
  exit "$RESOLVE_RC"
fi

SLUG=$(printf '%s\n' "$RESOLVED" | head -1)
ARCHIVED=$(printf '%s\n' "$RESOLVED" | sed -n '2p')

if [[ "$ARCHIVED" == "true" ]]; then
  fail "work item '$SLUG' is archived — consultations file against active items"
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
ITEM_DIR="$KNOWLEDGE_DIR/_work/$SLUG"

if [[ ! -f "$ITEM_DIR/_meta.json" ]]; then
  fail "missing _meta.json for work item '$SLUG'"
fi

# --- Provenance: stamp the producing template's version at emission ----------
# Default derives from the implement skill template; --template-version overrides.
if [[ -z "$TEMPLATE_VERSION" ]]; then
  REPO_DIR="$(dirname "$(cd "$SCRIPT_DIR" && pwd -P)")"
  SKILL_TEMPLATE="$REPO_DIR/skills/implement/SKILL.md"
  if [[ -f "$SKILL_TEMPLATE" ]]; then
    TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" "$SKILL_TEMPLATE" 2>/dev/null || true)
  fi
fi

REPLIED_AT=$(timestamp_iso)
CAPTURED_SHA=$(captured_at_sha)
TRANSCRIPT_FILE="$ITEM_DIR/consultation-transcript.jsonl"

# --- Transcript record (this script is its sole sanctioned writer) -----------
TRANSCRIPT_ROW=$(python3 - "$CONSULTATION_ID" "$WORKER" "$DOMAIN" "$HANDLER" \
  "$SKILL_TV" "$ADVISOR_TV" "$QUESTION" "$ANSWER" "$REPLIED_AT" \
  "$TEMPLATE_VERSION" "$CAPTURED_SHA" <<'PYEOF'
import json, sys
(cid, worker, domain, handler, skill_tv, advisor_tv,
 question, answer, replied_at, tv, sha) = sys.argv[1:12]
print(json.dumps({
    "consultation_id": cid,
    "worker": worker,
    "domain": domain,
    "handler": handler,
    "skill_template_version": skill_tv or None,
    "advisor_template_version": advisor_tv or None,
    "question": question,
    "answer": answer,
    "replied_at": replied_at,
    "template_version": tv or None,
    "captured_at_sha": None if sha == "null" else sha,
}, ensure_ascii=False))
PYEOF
)

printf '%s\n' "$TRANSCRIPT_ROW" >> "$TRANSCRIPT_FILE"
TRANSCRIPT_RECORD=$(grep -c '[^[:space:]]' "$TRANSCRIPT_FILE" || true)

# --- Execution-log entry via the sole writer ----------------------------------
json_string() {
  printf '%s' "$1" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))'
}

HANDLER_TV_LINE=""
case "$HANDLER" in
  skill) HANDLER_TV_LINE="Skill template-version: $SKILL_TV"$'\n' ;;
  agent) HANDLER_TV_LINE="Advisor template-version: $ADVISOR_TV"$'\n' ;;
esac

BODY=$(printf 'Consultation: %s\nWorker: %s\nDomain: %s\nConsultation-handler: %s\n%sQuestion: %s\nAnswer summary: %s' \
  "$CONSULTATION_ID" "$WORKER" "$DOMAIN" "$HANDLER" "$HANDLER_TV_LINE" \
  "$(json_string "$QUESTION")" "$(json_string "$ANSWER")")

WLOG_ARGS=(--slug "$SLUG" --source impl-verb)
if [[ -n "$TEMPLATE_VERSION" ]]; then
  WLOG_ARGS+=(--template-version "$TEMPLATE_VERSION")
fi

if ! printf '%s\n' "$BODY" | bash "$SCRIPT_DIR/write-execution-log.sh" "${WLOG_ARGS[@]}" >/dev/null; then
  fail "execution-log append failed for '$SLUG' (transcript record $TRANSCRIPT_RECORD was written)"
fi

# --- Output -------------------------------------------------------------------
if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$(python3 - "$SLUG" "$CONSULTATION_ID" "$WORKER" "$DOMAIN" "$HANDLER" \
    "$TRANSCRIPT_FILE" "$TRANSCRIPT_RECORD" "$ITEM_DIR/execution-log.md" "$REPLIED_AT" <<'PYEOF'
import json, sys
slug, cid, worker, domain, handler, tpath, trecord, lpath, replied_at = sys.argv[1:10]
print(json.dumps({
    "slug": slug,
    "consultation_id": cid,
    "worker": worker,
    "domain": domain,
    "handler": handler,
    "transcript_path": tpath,
    "transcript_record": int(trecord),
    "log_path": lpath,
    "replied_at": replied_at,
}, ensure_ascii=False))
PYEOF
)"
fi

echo "[impl] Consultation '$CONSULTATION_ID' filed for $SLUG (handler: $HANDLER)"
echo "[impl] Transcript record appended: $TRANSCRIPT_FILE (record $TRANSCRIPT_RECORD)"
echo "[impl] Execution-log entry appended: $ITEM_DIR/execution-log.md"
