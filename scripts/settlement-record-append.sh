#!/usr/bin/env bash
# settlement-record-append.sh — Append a judge verdict to an artifact's settlement record
#
# Usage:
#   lore audit record append --work-item <slug> --artifact-id <id> --verdict '<json>'
#   echo '<json>' | settlement-record-append.sh --work-item <slug> --artifact-id <id>
#   settlement-record-append.sh --work-item <slug> --artifact-id <id> [--kdir <path>] [--json]
#
# Reads a single JSON object (via --verdict or stdin), validates it against the
# per-judge output contract, and appends one JSON line to
# $KDIR/_work/<slug>/verdicts/<artifact-id>.jsonl. Creates the verdicts/
# directory and file on first use.
#
# SOLE-WRITER INVARIANT (companion to scorecard-append.sh):
#   settlement-record-append.sh / `lore audit record append` is the only
#   sanctioned writer of the per-artifact verdicts JSONL. No other script,
#   skill, agent prompt, or human process may append, edit, or truncate that
#   file directly. The wrapper scripts/audit-artifact.sh invokes this writer
#   once per judge verdict during a single `lore audit <artifact-id>` run;
#   tasks 12/17/22 (judge wiring) call it through the wrapper, never the
#   judge agents themselves.
#
# Why separate from scorecard-append.sh:
#   - scorecard-append.sh appends quantitative rollups to a single global file
#     ($KDIR/_scorecards/rows.jsonl) — one row per metric, aggregated across
#     artifacts for /retro and /evolve consumption.
#   - settlement-record-append.sh appends qualitative per-claim verdicts to a
#     per-artifact file — one row per judge-verdict emission, preserving the
#     claim-local evidence that produced the rollup numbers.
#   Splitting them keeps each writer's concern single: rows.jsonl is read by
#   /retro + /evolve; verdicts/<artifact-id>.jsonl is read by backtrace
#   tools that need to answer "which specific claims caused this scorecard
#   cell to drop?"
#
# Verdict shape (see architecture/audit-pipeline/contract.md for full spec):
#   {
#     "artifact_id":          "<work-item slug or absolute path>",
#     "judge":                "correctness-gate | curator | reverse-auditor",
#     "judge_template_version": "<12-char hash>",
#     "claim_id":             "<stable id within artifact; e.g. finding-0>",
#     "verdict":              "verified | unverified | contradicted |
#                              selected | dropped | omission-claim |
#                              silence",
#     "evidence":             "<optional; judge-dependent>",
#     "rationale":            "<optional; required on 'contradicted' and
#                              'dropped' verdicts>",
#     "correction":           "<optional; only present on 'contradicted'>",
#     "written_at":           "<ISO-8601 timestamp, filled by writer>"
#   }
#
# Required fields (hard-validated at write time):
#   artifact_id, judge, claim_id, verdict
#
# Field `written_at` is injected by this writer if absent, so callers may
# omit it. All other fields are passed through verbatim.
#
# Callers MUST NOT write to `$KDIR/_work/<slug>/verdicts/` through any other
# path. Direct-write bypasses are treated as corrupt by the rollup pipeline —
# scripts/audit-artifact.sh and future `lore audit record list` readers will
# emit `[settlement] warning: verdicts/<artifact>.jsonl:<N> corrupt —
# <reason>` to stderr and EXCLUDE the row from backtrace.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

WORK_ITEM=""
ARTIFACT_ID=""
VERDICT=""
KDIR_OVERRIDE=""
JSON_MODE=0

usage() {
  cat >&2 <<EOF
Usage: settlement-record-append.sh --work-item <slug> --artifact-id <id>
                                   [--verdict '<json>'] [--kdir <path>]
                                   [--json]

Appends one JSONL line per judge verdict to
\$KDIR/_work/<slug>/verdicts/<artifact-id>.jsonl. Verdict JSON is read
from --verdict, or from stdin if --verdict is omitted.

See architecture/audit-pipeline/contract.md for the full verdict shape and
the sole-writer invariant.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-item)
      WORK_ITEM="$2"
      shift 2
      ;;
    --artifact-id)
      ARTIFACT_ID="$2"
      shift 2
      ;;
    --verdict)
      VERDICT="$2"
      shift 2
      ;;
    --kdir)
      KDIR_OVERRIDE="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[settlement] Error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    printf '{"ok": false, "error": %s}\n' "$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  fi
  echo "[settlement] Error: $msg" >&2
  exit 1
}

if [[ -z "$WORK_ITEM" ]]; then
  fail "--work-item is required"
fi
if [[ -z "$ARTIFACT_ID" ]]; then
  fail "--artifact-id is required"
fi

# Guard against path-traversal — work-item slug must be a plain slug, not a
# path fragment. Same posture as scorecard-append.sh.
if [[ "$WORK_ITEM" =~ [/.] ]] && [[ "$WORK_ITEM" != "$(basename "$WORK_ITEM")" ]]; then
  fail "--work-item must be a plain slug (no path separators)"
fi

# Normalize artifact-id for use as a filename: replace / with _ and strip
# anything that isn't a standard filename character. Preserves uniqueness
# because the full artifact_id is also stored inside the row's JSON.
ARTIFACT_FILENAME=$(printf '%s' "$ARTIFACT_ID" | tr '/' '_' | tr -cd 'A-Za-z0-9._-')
if [[ -z "$ARTIFACT_FILENAME" ]]; then
  fail "artifact-id '$ARTIFACT_ID' produced an empty filename after sanitization"
fi

# --- Read verdict from stdin if not provided via flag ---
if [[ -z "$VERDICT" ]]; then
  if [[ -t 0 ]]; then
    fail "no verdict provided: pass --verdict '<json>' or pipe JSON on stdin"
  fi
  VERDICT=$(cat)
fi

if [[ -z "${VERDICT// }" ]]; then
  fail "verdict is empty"
fi

# --- Validate JSON structure and required fields (jq-based) ---
if ! command -v jq &>/dev/null; then
  fail "jq is required but not found on PATH"
fi

if ! printf '%s' "$VERDICT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  fail "verdict must be a JSON object"
fi

# judge must be one of the three canonical values
if ! printf '%s' "$VERDICT" | jq -e '
  .judge == "correctness-gate" or .judge == "curator" or .judge == "reverse-auditor"
' >/dev/null 2>&1; then
  fail "verdict.judge must be one of: correctness-gate, curator, reverse-auditor"
fi

# claim_id must be a non-empty string
if ! printf '%s' "$VERDICT" | jq -e 'has("claim_id") and (.claim_id | type == "string") and (.claim_id | length > 0)' >/dev/null 2>&1; then
  fail "verdict.claim_id must be a non-empty string"
fi

# verdict field must be present and non-empty
if ! printf '%s' "$VERDICT" | jq -e 'has("verdict") and (.verdict | type == "string") and (.verdict | length > 0)' >/dev/null 2>&1; then
  fail "verdict.verdict must be a non-empty string"
fi

# --- Resolve knowledge dir + work item dir ---
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR="$KDIR_OVERRIDE"
else
  KDIR=$(resolve_knowledge_dir)
fi

if [[ ! -d "$KDIR" ]]; then
  fail "knowledge directory not found: $KDIR"
fi

ITEM_DIR="$KDIR/_work/$WORK_ITEM"
if [[ ! -d "$ITEM_DIR" ]]; then
  fail "work item not found: $WORK_ITEM (expected at $ITEM_DIR)"
fi

VERDICTS_DIR="$ITEM_DIR/verdicts"
mkdir -p "$VERDICTS_DIR"

TARGET_FILE="$VERDICTS_DIR/$ARTIFACT_FILENAME.jsonl"

# --- Inject artifact_id + written_at if absent, emit single-line JSON ---
# Use python3 for the inject step to guarantee compact single-line JSON
# output; jq's -c flag works too but python's json module is already
# required elsewhere in the repo and avoids a jq single-line edge case
# (trailing newlines, unicode escaping) that would corrupt JSONL.
LINE=$(printf '%s' "$VERDICT" | ARTIFACT_ID_ENV="$ARTIFACT_ID" python3 -c '
import json, os, sys
from datetime import datetime, timezone

verdict = json.load(sys.stdin)
if "artifact_id" not in verdict or not verdict.get("artifact_id"):
    verdict["artifact_id"] = os.environ["ARTIFACT_ID_ENV"]
if "written_at" not in verdict or not verdict.get("written_at"):
    verdict["written_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
print(json.dumps(verdict, sort_keys=True))
')

# --- Append atomically ---
printf '%s\n' "$LINE" >> "$TARGET_FILE"

if [[ $JSON_MODE -eq 1 ]]; then
  printf '{"ok": true, "target": %s, "line": %s}\n' \
    "$(printf '%s' "$TARGET_FILE" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "$(printf '%s' "$LINE" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
else
  echo "[settlement] Verdict appended to $TARGET_FILE"
fi
