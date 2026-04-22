#!/usr/bin/env bash
# template-registry-register.sh — Register a (template_id, template_version) pair
# in $KDIR/_scorecards/template-registry.json with INSERT OR IGNORE semantics.
#
# Usage:
#   template-registry-register.sh --template-id <id> --template-version <hash> --template-path <path>
#                                  [--description <text>] [--kdir <path>] [--json]
#
# Registry schema (template-registry.json):
# {
#   "schema_version": "1",
#   "entries": [
#     {
#       "template_id": "<id>",
#       "template_version": "<12-char hash>",
#       "template_path": "<relative or absolute path>",
#       "first_seen": "<ISO8601 UTC>",
#       "description": null | "<human-readable>"
#     }, ...
#   ]
# }
#
# INSERT OR IGNORE semantics: if an entry with the same (template_id, template_version)
# pair already exists, this script is a silent no-op (exit 0, status: "exists").
# First write wins; subsequent writers skip. This matches the concurrency contract
# described in task-35 for auto-register-at-first-spawn.
#
# Concurrency: the registry is updated via tmpfile + atomic rename (mv). Two
# concurrent writes may race, but the loser is harmless — both writes produce
# an equivalent row for a new pair, and both are no-ops for an existing pair.
# Consumers (/retro, /evolve) read the file at a later time and see the
# winning version. Not safe for high-rate concurrent writes, but sufficient for
# agent-spawn registration which is inherently low-frequency and idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

TEMPLATE_ID=""
TEMPLATE_VERSION=""
TEMPLATE_PATH=""
DESCRIPTION=""
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --template-id)
      TEMPLATE_ID="$2"
      shift 2
      ;;
    --template-version)
      TEMPLATE_VERSION="$2"
      shift 2
      ;;
    --template-path)
      TEMPLATE_PATH="$2"
      shift 2
      ;;
    --description)
      DESCRIPTION="$2"
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
      sed -n '2,35p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: template-registry-register.sh --template-id <id> --template-version <hash> --template-path <path> [--description <text>] [--kdir <path>] [--json]" >&2
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

if [[ -z "$TEMPLATE_ID" ]]; then
  fail "--template-id is required"
fi
if [[ -z "$TEMPLATE_VERSION" ]]; then
  fail "--template-version is required"
fi
if [[ -z "$TEMPLATE_PATH" ]]; then
  fail "--template-path is required"
fi

if ! command -v jq &>/dev/null; then
  fail "jq is required but not found on PATH"
fi

# --- Resolve knowledge directory ---
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)
fi

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  fail "knowledge store not found at: $KNOWLEDGE_DIR"
fi

SCORECARDS_DIR="$KNOWLEDGE_DIR/_scorecards"
REGISTRY_FILE="$SCORECARDS_DIR/template-registry.json"
mkdir -p "$SCORECARDS_DIR"

# Seed the README on first scorecard-dir use (consistency with scorecard-append.sh).
if [[ ! -f "$SCORECARDS_DIR/README.md" ]]; then
  "$SCRIPT_DIR/seed-scorecards-readme.sh" "$SCORECARDS_DIR" 2>/dev/null || true
fi

# --- Initialize registry if missing ---
if [[ ! -f "$REGISTRY_FILE" ]]; then
  printf '{"schema_version":"1","entries":[]}\n' > "$REGISTRY_FILE"
fi

# --- INSERT OR IGNORE ---
# Check existence first to short-circuit (ignore path is hot).
EXISTS=$(jq --arg id "$TEMPLATE_ID" --arg ver "$TEMPLATE_VERSION" \
  '[.entries[] | select(.template_id == $id and .template_version == $ver)] | length > 0' \
  "$REGISTRY_FILE" 2>/dev/null || echo "false")

RELPATH="${REGISTRY_FILE#$KNOWLEDGE_DIR/}"

if [[ "$EXISTS" == "true" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    jq -n \
      --arg path "$RELPATH" \
      --arg template_id "$TEMPLATE_ID" \
      --arg template_version "$TEMPLATE_VERSION" \
      '{path: $path, template_id: $template_id, template_version: $template_version, status: "exists"}' \
      | jq -c '.'
    exit 0
  fi
  # Silent no-op on insert-or-ignore hit, per the documented concurrency contract.
  exit 0
fi

# --- Build new entry ---
FIRST_SEEN=$(timestamp_iso)
DESC_JSON=$(
  if [[ -z "$DESCRIPTION" ]]; then
    echo 'null'
  else
    jq -n --arg d "$DESCRIPTION" '$d'
  fi
)

NEW_ENTRY=$(jq -n \
  --arg template_id "$TEMPLATE_ID" \
  --arg template_version "$TEMPLATE_VERSION" \
  --arg template_path "$TEMPLATE_PATH" \
  --arg first_seen "$FIRST_SEEN" \
  --argjson description "$DESC_JSON" \
  '{template_id: $template_id, template_version: $template_version, template_path: $template_path, first_seen: $first_seen, description: $description}')

# --- Atomic tmpfile rename ---
TMP_FILE=$(mktemp "$REGISTRY_FILE.tmp.XXXXXX")
trap 'rm -f "$TMP_FILE"' EXIT

jq --argjson entry "$NEW_ENTRY" '.entries += [$entry]' "$REGISTRY_FILE" > "$TMP_FILE"
mv "$TMP_FILE" "$REGISTRY_FILE"

if [[ $JSON_MODE -eq 1 ]]; then
  jq -n \
    --arg path "$RELPATH" \
    --arg template_id "$TEMPLATE_ID" \
    --arg template_version "$TEMPLATE_VERSION" \
    --arg first_seen "$FIRST_SEEN" \
    '{path: $path, template_id: $template_id, template_version: $template_version, first_seen: $first_seen, status: "registered"}' \
    | jq -c '.'
  exit 0
fi

echo "[registry] Registered $TEMPLATE_ID @ $TEMPLATE_VERSION → $RELPATH"
