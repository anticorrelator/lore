#!/usr/bin/env bash
# retro-export.sh — Export redacted retro/scorecard bundle for federated pooling
#
# Usage:
#   lore retro export --redact [--since <date>] [--out <path>] [--contributor-id <id>] [--json]
#
# Produces a self-contained JSON bundle for submission to a maintainer's
# `lore retro import`. Bundle shape is the retro-export.v1 envelope from
# `_research/multi-user-evolution-design.md`: envelope + scorecard cells
# (aggregated by template/version/metric) + retro/behavioral records
# (redacted). Paths, branch names, commits, usernames, and unredacted file
# excerpts are stripped by construction — this script does not emit them
# into the bundle.
#
# SCOPE: contributor-facing verb. No role gate. Anyone can export.
# The bundle carries signal about templates, not the contributor's
# private commons doctrine.
#
# --redact is REQUIRED (kept explicit so invocation intent is unambiguous).
# --since defaults to the timestamp of the last `lore retro export` log
# entry, or to the earliest retro in the journal if no prior export.
# --out defaults to `./retro-export-<YYYY-MM-DD>-<contributor_id>.json`.
# --contributor-id defaults to the `contributor_id` field in
# `~/.lore/config/settings.json`, or to the sha256 prefix of the user's
# git config email if no config is set. See multi-user-evolution-design.md
# §9 for the pseudonym stability contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REDACT_FLAG=0
SINCE=""
OUT=""
CONTRIBUTOR_ID=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --redact)
      REDACT_FLAG=1
      shift
      ;;
    --since)
      SINCE="$2"
      shift 2
      ;;
    --out)
      OUT="$2"
      shift 2
      ;;
    --contributor-id)
      CONTRIBUTOR_ID="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    -h|--help)
      sed -n '2,27p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: lore retro export --redact [--since <date>] [--out <path>] [--contributor-id <id>] [--json]" >&2
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

if [[ $REDACT_FLAG -ne 1 ]]; then
  fail "--redact is required (invocation intent must be explicit)"
fi

if ! command -v jq &>/dev/null; then
  fail "jq is required but not found on PATH"
fi

if ! command -v python3 &>/dev/null; then
  fail "python3 is required but not found on PATH"
fi

KDIR=$(resolve_knowledge_dir)
[[ -d "$KDIR" ]] || fail "knowledge store not found at: $KDIR"

# --- Resolve contributor_id ---
if [[ -z "$CONTRIBUTOR_ID" ]]; then
  LORE_SETTINGS="$HOME/.lore/config/settings.json"
  if [[ -f "$LORE_SETTINGS" ]]; then
    CONTRIBUTOR_ID=$(jq -r '.contributor_id // ""' "$LORE_SETTINGS" 2>/dev/null || echo "")
  fi
fi
if [[ -z "$CONTRIBUTOR_ID" ]]; then
  # Pseudonym fallback: sha256 prefix of git config user.email. Stable
  # across re-installs as long as the user keeps the same email.
  EMAIL=$(git config --global user.email 2>/dev/null || echo "anonymous@local")
  CONTRIBUTOR_ID=$(printf '%s' "$EMAIL" | python3 -c 'import hashlib,sys; print("pool-" + hashlib.sha256(sys.stdin.read().encode()).hexdigest()[:12])')
fi

# --- Resolve SINCE ---
JOURNAL_FILE="$KDIR/_meta/effectiveness-journal.jsonl"
if [[ -z "$SINCE" ]]; then
  if [[ -f "$JOURNAL_FILE" ]]; then
    LAST_EXPORT=$(jq -r 'select(.role == "retro-export") | .timestamp' "$JOURNAL_FILE" 2>/dev/null | tail -1)
    if [[ -n "$LAST_EXPORT" && "$LAST_EXPORT" != "null" ]]; then
      SINCE="$LAST_EXPORT"
    fi
  fi
fi
[[ -z "$SINCE" ]] && SINCE="1970-01-01T00:00:00Z"

# --- Resolve OUT ---
TODAY=$(date -u +"%Y-%m-%d")
[[ -z "$OUT" ]] && OUT="./retro-export-${TODAY}-${CONTRIBUTOR_ID}.json"

# --- Build envelope ---
EXPORT_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')
EXPORTED_AT_WEEK=$(date -u +"%G-W%V")
LORE_VERSION=$(grep -m1 '^LORE_VERSION=' "$SCRIPT_DIR/../cli/lore" 2>/dev/null | sed -E 's/.*"([^"]*)".*/\1/' || echo "unknown")

# Base template manifest hash: sha256 of concatenated template files in the repo.
# This pins the export to a specific template generation.
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST_HASH="unknown"
if [[ -d "$REPO_DIR/skills" && -d "$REPO_DIR/agents" ]]; then
  MANIFEST_HASH=$(find "$REPO_DIR/skills" "$REPO_DIR/agents" -type f -name "*.md" 2>/dev/null | sort | xargs cat 2>/dev/null | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null || echo "unknown")
fi

# --- Collect scorecard cells ---
# Aggregate rows.jsonl by (template_id, template_version, metric) over the
# SINCE window. Drop rows with kind != scored (telemetry never exports as
# a scored cell; telemetry_rows_count is tallied separately for context).
ROWS_FILE="$KDIR/_scorecards/rows.jsonl"
CELLS_JSON="[]"
TELEMETRY_ROW_COUNT=0
if [[ -f "$ROWS_FILE" && -s "$ROWS_FILE" ]]; then
  CELLS_JSON=$(python3 "$SCRIPT_DIR/retro-export-aggregate-cells.py" "$ROWS_FILE" "$SINCE" "$CONTRIBUTOR_ID" 2>/dev/null || echo "[]")
  TELEMETRY_ROW_COUNT=$(jq -c 'select(.kind == "telemetry")' "$ROWS_FILE" 2>/dev/null | wc -l | tr -d ' ')
fi

# --- Collect retro/behavioral records ---
# Read journal entries with role "retro" or "retro-behavioral-health" since
# SINCE. Redact: strip context field (may contain slug), strip work-item
# (slug paths), keep observation prose and scores.
RETROS_JSON="[]"
if [[ -f "$JOURNAL_FILE" ]]; then
  RETROS_JSON=$(python3 "$SCRIPT_DIR/retro-export-collect-retros.py" "$JOURNAL_FILE" "$SINCE" 2>/dev/null || echo "[]")
fi

# --- Assemble bundle ---
BUNDLE=$(jq -n \
  --arg schema_version "retro-export.v1" \
  --arg export_id "$EXPORT_ID" \
  --arg exported_at_week "$EXPORTED_AT_WEEK" \
  --arg contributor_id "$CONTRIBUTOR_ID" \
  --arg base_template_manifest_hash "$MANIFEST_HASH" \
  --arg lore_version "$LORE_VERSION" \
  --arg redaction_policy "paths-and-identities-removed-v1" \
  --arg since "$SINCE" \
  --argjson cells "$CELLS_JSON" \
  --argjson retros "$RETROS_JSON" \
  --argjson telemetry_row_count "$TELEMETRY_ROW_COUNT" \
  '{
    envelope: {
      schema_version: $schema_version,
      export_id: $export_id,
      exported_at_week: $exported_at_week,
      contributor_id: $contributor_id,
      base_template_manifest_hash: $base_template_manifest_hash,
      lore_version: $lore_version,
      redaction_policy: $redaction_policy,
      since: $since
    },
    scorecard_cells: $cells,
    retros: $retros,
    telemetry_row_count: $telemetry_row_count
  }')

# --- Write bundle ---
printf '%s\n' "$BUNDLE" > "$OUT"

# --- Log the export to journal so next export's SINCE advances correctly ---
if [[ -f "$SCRIPT_DIR/journal.sh" ]]; then
  OBS="Exported retro bundle: cells=$(jq 'length' <<<"$CELLS_JSON"), retros=$(jq 'length' <<<"$RETROS_JSON"), since=$SINCE, contributor=$CONTRIBUTOR_ID, out=$OUT"
  "$SCRIPT_DIR/journal.sh" write \
    --observation "$OBS" \
    --context "retro-export" \
    --role "retro-export" 2>/dev/null || true
fi

CELL_COUNT=$(jq 'length' <<<"$CELLS_JSON")
RETRO_COUNT=$(jq 'length' <<<"$RETROS_JSON")

if [[ $JSON_MODE -eq 1 ]]; then
  jq -n \
    --arg path "$OUT" \
    --arg contributor_id "$CONTRIBUTOR_ID" \
    --arg since "$SINCE" \
    --argjson cell_count "$CELL_COUNT" \
    --argjson retro_count "$RETRO_COUNT" \
    '{path: $path, contributor_id: $contributor_id, since: $since, cell_count: $cell_count, retro_count: $retro_count}'
  exit 0
fi

echo "[retro-export] Wrote bundle to $OUT"
echo "  contributor_id: $CONTRIBUTOR_ID"
echo "  since:          $SINCE"
echo "  cells:          $CELL_COUNT"
echo "  retros:         $RETRO_COUNT"
echo ""
echo "Transport the bundle to the maintainer via email / DM / drive / gist."
echo "The bundle contains no paths, branches, commits, or unredacted file excerpts."
