#!/usr/bin/env bash
# scorecard-rollup.sh — Aggregate rows.jsonl into _current.json
#
# Usage: lore scorecard rollup [--kdir <path>] [--json]
#
# Reads $KDIR/_scorecards/rows.jsonl (append-only, one JSON object per line)
# and writes $KDIR/_scorecards/_current.json with aggregated per-(template_version, metric)
# summaries. Works on empty, one-row, and many-row inputs.
#
# Output shape (_current.json):
# {
#   "generated_at": "<ISO-8601 UTC>",
#   "source": "_scorecards/rows.jsonl",
#   "row_count": N,
#   "corrupt_row_count": N,
#   "summaries": [
#     {
#       "template_version": "<hash|null>",
#       "template_id": "<id|null>",
#       "metric": "<name|null>",
#       "kind": "scored|telemetry|consumption-contradiction|mixed",
#       "calibration_states": ["calibrated", ...],
#       "sample_count": N,             # number of rows aggregated
#       "sample_size_total": N,        # sum of row.sample_size (0 if absent)
#       "value_count": N,              # rows with numeric .value
#       "value_sum": X,
#       "value_mean": X | null,
#       "value_min": X | null,
#       "value_max": X | null,
#       "window_start": "<earliest>",
#       "window_end": "<latest>"
#     }, ...
#   ]
# }
#
# Rows missing required fields (schema_version, kind, or calibration_state)
# are counted in `corrupt_row_count`, excluded from aggregation, and emit a
# one-line warning to stderr: `[scorecard] warning: rows.jsonl:<N> corrupt —
# <reason>`. This mirrors the reader invariant documented in
# scorecard-append.sh — any row that does not pass `scorecard-append.sh`
# validation is treated as corrupt by every reader (`/retro`, `/evolve`,
# this rollup).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kdir)
      KDIR_OVERRIDE="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: scorecard-rollup.sh [--kdir <path>] [--json]" >&2
      exit 1
      ;;
  esac
done

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$msg"
  fi
  die "$msg"
}

if ! command -v jq &>/dev/null; then
  fail "jq is required but not found on PATH"
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)
fi

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  fail "knowledge store not found at: $KNOWLEDGE_DIR"
fi

SCORECARDS_DIR="$KNOWLEDGE_DIR/_scorecards"
ROWS_FILE="$SCORECARDS_DIR/rows.jsonl"
CURRENT_FILE="$SCORECARDS_DIR/_current.json"
mkdir -p "$SCORECARDS_DIR"

GENERATED_AT=$(timestamp_iso)

# --- Empty / missing rows.jsonl ---
if [[ ! -s "$ROWS_FILE" ]]; then
  jq -n \
    --arg generated_at "$GENERATED_AT" \
    '{generated_at: $generated_at, source: "_scorecards/rows.jsonl", row_count: 0, corrupt_row_count: 0, summaries: []}' \
    > "$CURRENT_FILE"
  RELPATH="${CURRENT_FILE#$KNOWLEDGE_DIR/}"
  if [[ $JSON_MODE -eq 1 ]]; then
    jq -n --arg path "$RELPATH" --argjson row_count 0 --argjson corrupt_row_count 0 \
      '{path: $path, row_count: $row_count, corrupt_row_count: $corrupt_row_count, summary_count: 0}' \
      | jq -c '.'
    exit 0
  fi
  echo "[scorecard] Rolled up 0 rows to $RELPATH"
  exit 0
fi

# --- Pre-filter parseable lines so jq -s doesn't abort on a single bad row ---
# Walk rows.jsonl once: classify each non-empty line, emit a stderr warning for
# each corrupt line (parse fail OR schema fail), and append valid lines to a
# scratch file for aggregation.
PARSEABLE=$(mktemp)
trap 'rm -f "$PARSEABLE"' EXIT

warn_corrupt() {
  local lineno="$1"
  local reason="$2"
  echo "[scorecard] warning: rows.jsonl:${lineno} corrupt — ${reason}" >&2
}

validate_row() {
  # Emits "ok" on success or a short reason string on failure.
  # Expects a single JSON object on stdin.
  jq -r '
    if (type != "object") then "row is not a JSON object"
    elif (has("schema_version") | not) or (.schema_version == null) then "missing required field: schema_version"
    elif (.kind != "scored" and .kind != "telemetry" and .kind != "consumption-contradiction") then "invalid or missing kind (must be scored|telemetry|consumption-contradiction)"
    elif (.calibration_state != "calibrated" and .calibration_state != "pre-calibration" and .calibration_state != "unknown") then "invalid or missing calibration_state"
    else "ok"
    end
  '
}

# Note: we cannot assign to `LINENO` here — it's a magic bash variable that
# reports the current script line number. Use a distinct counter name.
ROW_LINENO=0
ROW_COUNT=0
PARSE_FAILS=0
VALIDATION_FAILS=0
while IFS= read -r line || [[ -n "$line" ]]; do
  ROW_LINENO=$((ROW_LINENO + 1))
  [[ -z "${line// }" ]] && continue
  ROW_COUNT=$((ROW_COUNT + 1))
  if ! printf '%s' "$line" | jq -e '.' >/dev/null 2>&1; then
    warn_corrupt "$ROW_LINENO" "unparseable JSON"
    PARSE_FAILS=$((PARSE_FAILS + 1))
    continue
  fi
  VERDICT=$(printf '%s' "$line" | validate_row)
  if [[ "$VERDICT" != "ok" ]]; then
    warn_corrupt "$ROW_LINENO" "$VERDICT"
    VALIDATION_FAILS=$((VALIDATION_FAILS + 1))
    continue
  fi
  printf '%s\n' "$line" >> "$PARSEABLE"
done < "$ROWS_FILE"

# --- Aggregate with jq over parseable-only rows ---
# Valid rows: require schema_version + kind ∈ {scored,telemetry,consumption-contradiction} + calibration_state ∈ {calibrated,pre-calibration,unknown}
# Grouping key: (template_version, template_id, metric)
# For each group: sample_count, sample_size_total (sum of row.sample_size|0), value stats (only numeric .value),
#                 window min/max (string compare on ISO-8601 is correct), calibration_states set, kind or "mixed".
SUMMARIES_JSON=$(jq -s '
  def is_valid:
    (type == "object")
    and has("schema_version")
    and (.schema_version != null)
    and (.kind == "scored" or .kind == "telemetry" or .kind == "consumption-contradiction")
    and (.calibration_state == "calibrated" or .calibration_state == "pre-calibration" or .calibration_state == "unknown");

  def numeric_or_null:
    if (.value | type) == "number" then .value else null end;

  def min_str(a; b):
    if a == null then b
    elif b == null then a
    elif a < b then a
    else b
    end;

  def max_str(a; b):
    if a == null then b
    elif b == null then a
    elif a > b then a
    else b
    end;

  [ .[] | select(is_valid) ]
  | group_by([.template_version // null, .template_id // null, .metric // null])
  | map(
      . as $group
      | ($group | map(numeric_or_null) | map(select(. != null))) as $values
      | {
          template_version: ($group[0].template_version // null),
          template_id: ($group[0].template_id // null),
          metric: ($group[0].metric // null),
          kind: (
            ($group | map(.kind) | unique) as $kinds
            | if ($kinds | length) == 1 then $kinds[0] else "mixed" end
          ),
          calibration_states: ($group | map(.calibration_state) | unique),
          sample_count: ($group | length),
          sample_size_total: (
            $group
            | map(
                if (.sample_size | type) == "number" then .sample_size else 0 end
              )
            | add
          ),
          value_count: ($values | length),
          value_sum: (if ($values | length) > 0 then ($values | add) else 0 end),
          value_mean: (if ($values | length) > 0 then (($values | add) / ($values | length)) else null end),
          value_min: (if ($values | length) > 0 then ($values | min) else null end),
          value_max: (if ($values | length) > 0 then ($values | max) else null end),
          window_start: (
            $group
            | map(.window_start // null)
            | reduce .[] as $x (null; min_str(.; $x))
          ),
          window_end: (
            $group
            | map(.window_end // null)
            | reduce .[] as $x (null; max_str(.; $x))
          )
        }
    )
' "$PARSEABLE" 2>/dev/null || true)

if [[ -z "$SUMMARIES_JSON" ]]; then
  SUMMARIES_JSON="[]"
fi

CORRUPT_COUNT=$((PARSE_FAILS + VALIDATION_FAILS))

jq -n \
  --arg generated_at "$GENERATED_AT" \
  --argjson row_count "$ROW_COUNT" \
  --argjson corrupt_row_count "$CORRUPT_COUNT" \
  --argjson summaries "$SUMMARIES_JSON" \
  '{generated_at: $generated_at, source: "_scorecards/rows.jsonl", row_count: $row_count, corrupt_row_count: $corrupt_row_count, summaries: $summaries}' \
  > "$CURRENT_FILE"

RELPATH="${CURRENT_FILE#$KNOWLEDGE_DIR/}"
SUMMARY_COUNT=$(printf '%s' "$SUMMARIES_JSON" | jq 'length')

if [[ $JSON_MODE -eq 1 ]]; then
  jq -n \
    --arg path "$RELPATH" \
    --argjson row_count "$ROW_COUNT" \
    --argjson corrupt_row_count "$CORRUPT_COUNT" \
    --argjson summary_count "$SUMMARY_COUNT" \
    '{path: $path, row_count: $row_count, corrupt_row_count: $corrupt_row_count, summary_count: $summary_count}' \
    | jq -c '.'
  exit 0
fi

echo "[scorecard] Rolled up $ROW_COUNT rows ($CORRUPT_COUNT corrupt) into $SUMMARY_COUNT summaries → $RELPATH"
