#!/usr/bin/env bash
# batch-capture.sh — Capture multiple insights from a JSON array in one call
# Usage: lore batch-capture --file captures.json [--json]
#
# Input JSON format: array of objects with the same fields as `lore capture`:
#   [{"insight": "...", "scale": "implementation", "context": "...", "category": "...",
#     "confidence": "high", "related_files": "...", "source": "...", "example": "..."}, ...]
#
# Required fields per entry: insight, scale
# Optional fields: context, category, confidence, related_files, source, example
#   scale must be one of: abstract, architecture, subsystem, implementation
#
# Calls capture.sh --skip-manifest for each entry, then runs update-manifest.sh once.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

FILE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      FILE="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage: batch-capture.sh --file <path> [--json]

Capture multiple insights from a JSON array file.

Options:
  --file <path>   Path to JSON file containing array of capture entries
  --json          Output result as JSON
  -h, --help      Show this help message

Input JSON format:
  [{"insight": "...", "scale": "implementation", "category": "...", "confidence": "high", ...}, ...]

Required per entry: insight, scale
Optional per entry: context, category, confidence, related_files, source, example
scale must be one of: abstract, architecture, subsystem, implementation
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: batch-capture.sh --file <path> [--json]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$FILE" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "--file is required"
  fi
  die "--file is required"
fi

if [[ ! -f "$FILE" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "File not found: $FILE"
  fi
  die "File not found: $FILE"
fi

# --- Validate and parse the JSON array ---
ENTRY_COUNT=$(python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except json.JSONDecodeError as e:
    print('JSON_PARSE_ERROR: ' + str(e), file=sys.stderr)
    sys.exit(1)
if not isinstance(data, list):
    print('JSON_TYPE_ERROR: expected a JSON array', file=sys.stderr)
    sys.exit(2)
print(len(data))
" "$FILE") || {
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Invalid input file: $FILE"
  fi
  die "Invalid input file: $FILE"
}

if [[ "$ENTRY_COUNT" -eq 0 ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_output '{"succeeded": 0, "failed": 0, "total": 0, "failed_indices": []}'
  fi
  echo "[batch-capture] No entries to process"
  exit 0
fi

# --- Iterate entries and call capture.sh --skip-manifest ---
SUCCEEDED=0
FAILED=0
FAILED_INDICES=()
TMP_ERR=$(mktemp)

for ((i = 0; i < ENTRY_COUNT; i++)); do
  # Extract each field and build NUL-delimited arg list
  if ! python3 -c "
import json, sys, os
data = json.load(open(sys.argv[1]))
entry = data[int(sys.argv[2])]

if 'insight' not in entry or not str(entry.get('insight', '')).strip():
    print('missing required field: insight', file=sys.stderr)
    sys.exit(1)

if 'scale' not in entry or not str(entry.get('scale', '')).strip():
    print('missing required field: scale', file=sys.stderr)
    sys.exit(1)

args = ['--insight', entry['insight'], '--scale', entry['scale']]
if entry.get('context'):
    args += ['--context', entry['context']]
if entry.get('category'):
    args += ['--category', entry['category']]
if entry.get('confidence'):
    args += ['--confidence', entry['confidence']]
if entry.get('related_files'):
    args += ['--related-files', entry['related_files']]
if entry.get('source'):
    args += ['--source', entry['source']]
if entry.get('example'):
    args += ['--example', entry['example']]

os.write(1, b'\x00'.join(a.encode() for a in args))
" "$FILE" "$i" 2>"$TMP_ERR" | xargs -0 "$SCRIPT_DIR/capture.sh" --skip-manifest > /dev/null 2>&1; then
    ERR=$(cat "$TMP_ERR" 2>/dev/null)
    echo "[batch-capture] Entry $((i+1))/$ENTRY_COUNT: failed${ERR:+ — $ERR}" >&2
    FAILED=$((FAILED + 1))
    FAILED_INDICES+=("$i")
  else
    SUCCEEDED=$((SUCCEEDED + 1))
  fi
done

rm -f "$TMP_ERR"

# --- Run manifest update once ---
"$SCRIPT_DIR/update-manifest.sh" > /dev/null 2>&1 || true

# --- Output summary ---
if [[ $JSON_MODE -eq 1 ]]; then
  INDICES_JSON=$(python3 -c "import json,sys; print(json.dumps([int(x) for x in sys.argv[1:]]))" "${FAILED_INDICES[@]+"${FAILED_INDICES[@]}"}")
  JSON_RESULT=$(python3 -c "
import json, sys
d = {'succeeded': int(sys.argv[1]), 'failed': int(sys.argv[2]), 'total': int(sys.argv[3]), 'failed_indices': json.loads(sys.argv[4])}
print(json.dumps(d))
" "$SUCCEEDED" "$FAILED" "$ENTRY_COUNT" "$INDICES_JSON")
  json_output "$JSON_RESULT"
fi

echo "[batch-capture] $SUCCEEDED/$ENTRY_COUNT captured successfully${FAILED:+, $FAILED failed}"

if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
exit 0
