#!/usr/bin/env bash
# capture.sh — Capture an insight to the knowledge store
# Usage: lore capture --insight "..." --scale "<bucket>" [--context "..."] [--category "..."] [--confidence "..."] [--related-files "..."] [--source "..."] [--example "..."]
#        [--producer-role "..."] [--protocol-slot "..."] [--template-version "..."] [--capturer-role "..."] [--source-artifact-ids "..."]
#        [--captured-at-branch "..."] [--captured-at-sha "..."] [--captured-at-merge-base-sha "..."] [--work-item "..."]
#
# Writes an individual entry file to the category directory (e.g., conventions/<slug>.md).
#
# Provenance flags (omitted-field convention):
#   --producer-role         Role of the agent that produced the insight (e.g., researcher, worker, lead).
#   --protocol-slot         Protocol slot in which the insight emerged (e.g., capture, synthesis, review).
#   --template-version      Template-version hash of the producing agent template (see scripts/template-version.sh).
#   --capturer-role         Role of the agent writing this capture (set only when different from producer — lead-synthesis path).
#   --source-artifact-ids   Comma-separated artifact IDs the capture synthesizes from (lead-synthesis path).
#
# Branch-provenance flags (always-present convention):
#   --captured-at-branch          Branch at capture time. Defaults to `git rev-parse --abbrev-ref HEAD`; falls back to "null".
#   --captured-at-sha             HEAD commit SHA at capture time. Defaults to `git rev-parse HEAD`; falls back to "null".
#   --captured-at-merge-base-sha  Merge-base of HEAD against origin/main. Defaults to `git merge-base origin/main HEAD`;
#                                 falls back to "null" when the repo, origin/main, or merge-base is unavailable.
#   All three fields are emitted on every capture — with their resolved value OR the literal string "null". No network access.
#
# Scale:
#   --scale <bucket>  Required. One of: application, architectural, subsystem, implementation.
#     The caller declares scale explicitly; no formula derivation at capture time.
#
# Convention: when a provenance flag is omitted OR passed an empty string, the corresponding field is OMITTED from the
# HTML metadata comment block (rather than emitted with an empty value). This keeps legacy captures visually identical
# to pre-Phase-1 captures and avoids empty-field noise. The branch-provenance trio is a deliberate exception — each
# field is always emitted so downstream reconciliation can distinguish "not yet introduced" from "resolved to null".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
INSIGHT=""
CONTEXT=""
CATEGORY=""
CONFIDENCE="high"
RELATED_FILES=""
SOURCE="manual"
EXAMPLE=""
PRODUCER_ROLE=""
PROTOCOL_SLOT=""
TEMPLATE_VERSION=""
CAPTURER_ROLE=""
SOURCE_ARTIFACT_IDS=""
CAPTURED_AT_BRANCH=""
CAPTURED_AT_SHA=""
CAPTURED_AT_MERGE_BASE_SHA=""
WORK_ITEM=""
SCALE=""
JSON_MODE=0
SKIP_MANIFEST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --insight)
      INSIGHT="$2"
      shift 2
      ;;
    --context)
      CONTEXT="$2"
      shift 2
      ;;
    --category)
      CATEGORY="$2"
      shift 2
      ;;
    --confidence)
      CONFIDENCE="$2"
      shift 2
      ;;
    --related-files)
      RELATED_FILES="$2"
      shift 2
      ;;
    --source)
      SOURCE="$2"
      shift 2
      ;;
    --example)
      EXAMPLE="$2"
      shift 2
      ;;
    --producer-role)
      PRODUCER_ROLE="$2"
      shift 2
      ;;
    --protocol-slot)
      PROTOCOL_SLOT="$2"
      shift 2
      ;;
    --template-version)
      TEMPLATE_VERSION="$2"
      shift 2
      ;;
    --capturer-role)
      CAPTURER_ROLE="$2"
      shift 2
      ;;
    --source-artifact-ids)
      SOURCE_ARTIFACT_IDS="$2"
      shift 2
      ;;
    --captured-at-branch)
      CAPTURED_AT_BRANCH="$2"
      shift 2
      ;;
    --captured-at-sha)
      CAPTURED_AT_SHA="$2"
      shift 2
      ;;
    --captured-at-merge-base-sha)
      CAPTURED_AT_MERGE_BASE_SHA="$2"
      shift 2
      ;;
    --work-item)
      WORK_ITEM="$2"
      shift 2
      ;;
    --scale)
      SCALE="$2"
      shift 2
      ;;
    --scale=*)
      SCALE="${1#--scale=}"
      shift
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    --skip-manifest)
      SKIP_MANIFEST=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: capture.sh --insight \"...\" [--context \"...\"] [--category \"...\"] [--confidence \"...\"] [--related-files \"...\"] [--source \"...\"] [--example \"...\"] [--producer-role \"...\"] [--protocol-slot \"...\"] [--template-version \"...\"] [--capturer-role \"...\"] [--source-artifact-ids \"...\"] [--captured-at-branch \"...\"] [--captured-at-sha \"...\"] [--captured-at-merge-base-sha \"...\"] [--work-item \"...\"] [--json] [--skip-manifest]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$INSIGHT" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "--insight is required"
  fi
  die "--insight is required"
fi

if [[ -z "$SCALE" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "--scale is required; use one of: application, architectural, subsystem, implementation"
  fi
  die "--scale is required; use one of: application, architectural, subsystem, implementation"
fi

_VALID_SCALES=$("$SCRIPT_DIR/scale-registry.sh" get-ids 2>/dev/null || echo "implementation subsystem architectural application")
_scale_valid=0
for _s in $_VALID_SCALES; do
  if [[ "$SCALE" == "$_s" ]]; then
    _scale_valid=1
    break
  fi
done
if [[ $_scale_valid -eq 0 ]]; then
  _enum_list=$(echo "$_VALID_SCALES" | tail -r 2>/dev/null || echo "$_VALID_SCALES" | awk '{lines[NR]=$0} END{for(i=NR;i>=1;i--) print lines[i]}')
  _enum_list=$(echo "$_enum_list" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "scale must be one of: $_enum_list"
  fi
  die "scale must be one of: $_enum_list"
fi

# --- Provenance validator ---
if [[ -z "$PRODUCER_ROLE" || -z "$PROTOCOL_SLOT" ]]; then
  echo "[capture] WARNING: Missing provenance — --producer-role=${PRODUCER_ROLE}, --protocol-slot=${PROTOCOL_SLOT}." >&2
  echo "[capture] Captures without provenance cannot be scale-typed and degrade renormalize drift detection." >&2
  echo "[capture] If this is a manual /remember, pass --producer-role and --protocol-slot explicitly." >&2
fi

# --- Resolve knowledge directory ---
KNOWLEDGE_DIR=$(resolve_knowledge_dir)

# --- Verify knowledge store exists ---
if [[ ! -f "$KNOWLEDGE_DIR/_manifest.json" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "No knowledge store found at: $KNOWLEDGE_DIR"
  fi
  die "No knowledge store found at: $KNOWLEDGE_DIR. Run \`lore init\` to initialize one."
fi

# --- Default category ---
if [[ -z "$CATEGORY" ]]; then
  CATEGORY="conventions"
fi

# --- Generate title from first ~8 words of insight, title-cased ---
generate_title() {
  local text="$1"
  # Take first ~8 words, title-case each (macOS-compatible via awk)
  echo "$text" | awk '{for(i=1;i<=NF && i<=8;i++){$i=toupper(substr($i,1,1)) substr($i,2)}; NF=(NF>8?8:NF); print}'
}

TITLE=$(generate_title "$INSIGHT")
SLUG=$(slugify "$TITLE")

# --- Determine target directory ---
DATE_TODAY=$(date +"%Y-%m-%d")

# Category maps directly to directory (e.g., conventions, domains/evaluators)
TARGET_DIR="$KNOWLEDGE_DIR/$CATEGORY"
mkdir -p "$TARGET_DIR"

# --- Build metadata comment ---
META="<!-- learned: $DATE_TODAY | confidence: $CONFIDENCE | source: $SOURCE"
if [[ -n "$RELATED_FILES" ]]; then
  META="$META | related_files: $RELATED_FILES"
fi
if [[ -n "$PRODUCER_ROLE" ]]; then
  META="$META | producer_role: $PRODUCER_ROLE"
fi
if [[ -n "$PROTOCOL_SLOT" ]]; then
  META="$META | protocol_slot: $PROTOCOL_SLOT"
fi
if [[ -n "$TEMPLATE_VERSION" ]]; then
  META="$META | template_version: $TEMPLATE_VERSION"
fi
if [[ -n "$CAPTURER_ROLE" ]]; then
  META="$META | capturer_role: $CAPTURER_ROLE"
fi
if [[ -n "$SOURCE_ARTIFACT_IDS" ]]; then
  META="$META | source_artifact_ids: $SOURCE_ARTIFACT_IDS"
fi
if [[ -n "$WORK_ITEM" ]]; then
  META="$META | work_item: $WORK_ITEM"
fi

# Scale is always declared by the caller — emit directly.
META="$META | scale: $SCALE"
_registry="$SCRIPT_DIR/scale-registry.json"
if [[ -f "$_registry" ]]; then
  _scale_registry_version=$(python3 -c "
import json, sys
try:
    print(json.load(open(sys.argv[1])).get('version', '1'))
except Exception:
    print('1')
" "$_registry" 2>/dev/null || echo "1")
else
  _scale_registry_version="1"
fi
META="$META | scale_registry_version: $_scale_registry_version"

# Branch-provenance trio (always emitted). Fill from git when the caller did
# not pass an explicit value; fall back to "null" on any git failure so capture
# never aborts because of repo state.
if [[ -z "$CAPTURED_AT_BRANCH" ]]; then
  CAPTURED_AT_BRANCH=$(captured_at_branch)
fi
if [[ -z "$CAPTURED_AT_SHA" ]]; then
  CAPTURED_AT_SHA=$(captured_at_sha)
fi
if [[ -z "$CAPTURED_AT_MERGE_BASE_SHA" ]]; then
  CAPTURED_AT_MERGE_BASE_SHA=$(captured_at_merge_base_sha)
fi
META="$META | captured_at_branch: $CAPTURED_AT_BRANCH"
META="$META | captured_at_sha: $CAPTURED_AT_SHA"
META="$META | captured_at_merge_base_sha: $CAPTURED_AT_MERGE_BASE_SHA"
META="$META | status: current"
META="$META -->"

# --- Write individual entry file ---
TARGET_FILE="$TARGET_DIR/${SLUG}.md"

# Avoid overwriting existing entries — keep final stem ≤ MAX_SLUG_LENGTH
if [[ -f "$TARGET_FILE" ]]; then
  SLUG_BASE="$SLUG"
  COUNTER=2
  while true; do
    SUFFIX="-${COUNTER}"
    TRIMMED="${SLUG_BASE:0:$((MAX_SLUG_LENGTH - ${#SUFFIX}))}"
    TRIMMED="${TRIMMED%-}"
    CANDIDATE="${TRIMMED}${SUFFIX}"
    if [[ ! -f "$TARGET_DIR/${CANDIDATE}.md" ]]; then
      break
    fi
    COUNTER=$((COUNTER + 1))
  done
  TARGET_FILE="$TARGET_DIR/${CANDIDATE}.md"
fi

{
  echo "# $TITLE"
  echo "$INSIGHT"
  if [[ -n "$EXAMPLE" ]]; then
    echo "**Example:** $EXAMPLE"
  fi
  echo "$META"
} > "$TARGET_FILE"

RELPATH="${TARGET_FILE#$KNOWLEDGE_DIR/}"

# --- Infer parent edges from /spec researcher assertions ---
if [[ -n "$WORK_ITEM" ]]; then
  "$SCRIPT_DIR/infer-parent-edges.sh" --entry "$TARGET_FILE" --work-item "$WORK_ITEM" 2>/dev/null || true
fi

# --- Append to capture log ---
# Schema: timestamp,source,category,confidence,template_version
# The `template_version` column was added in Phase 2 (work item 02-durable-signal-foundation).
# Readers must tolerate legacy rows lacking this column — a missing trailing field is treated as empty.
LOG_FILE="$KNOWLEDGE_DIR/_capture_log.csv"
if [[ ! -f "$LOG_FILE" ]]; then
  echo "timestamp,source,category,confidence,template_version" > "$LOG_FILE"
fi
echo "$(timestamp_iso),$SOURCE,$CATEGORY,$CONFIDENCE,$TEMPLATE_VERSION" >> "$LOG_FILE"

# --- Run manifest update ---
if [[ $SKIP_MANIFEST -eq 0 ]]; then
  "$SCRIPT_DIR/update-manifest.sh" > /dev/null 2>&1 || true
fi

# --- Output ---
if [[ $JSON_MODE -eq 1 ]]; then
  JSON_RESULT=$(python3 -c "
import json, sys
d = {'path': sys.argv[1], 'category': sys.argv[2], 'title': sys.argv[3], 'confidence': sys.argv[4]}
print(json.dumps(d))
" "$RELPATH" "$CATEGORY" "$TITLE" "$CONFIDENCE")
  json_output "$JSON_RESULT"
fi

echo "[capture] Filed to $RELPATH"
