#!/usr/bin/env bash
# backfill-scale.sh — one-time pass to add scale: and scale_registry_version: to
# existing knowledge entries that pre-date task-1's capture.sh wiring.
#
# Usage:
#   backfill-scale.sh [--dry-run] [--limit N]
#
# --dry-run   Print proposed changes without modifying any files.
# --limit N   Process at most N entries (useful for spot-checking).
#
# Algorithm (per entry without scale:):
#   1. Read producer_role, protocol_slot, work_item from the HTML META comment.
#   2. If role + slot present: call scale-compute.sh with scope from the work item
#      (or default subsystem). Write the resolved scale value.
#   3. If neither role+slot nor work_item yields a canonical pair: write scale: unknown.
#   4. Always write scale_registry_version from scripts/scale-registry.json (or "1").
#   5. Insert both fields before the closing --> in the META comment.
#
# Idempotent: entries already containing scale: are skipped.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

DRY_RUN=false
LIMIT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --limit)   LIMIT="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

KNOWLEDGE_DIR=$(resolve_knowledge_dir)

# --- Determine scale_registry_version ---
_registry="$SCRIPT_DIR/scale-registry.json"
if [[ -f "$_registry" ]]; then
  REGISTRY_VERSION=$(python3 -c "
import json, sys
try:
    print(json.load(open(sys.argv[1])).get('version', '1'))
except Exception:
    print('1')
" "$_registry" 2>/dev/null || echo "1")
else
  REGISTRY_VERSION="1"
fi

skipped=0
updated=0
unknown_scale=0
processed=0

# Collect all category entry files (not _* dirs, not _* filenames, not root-level files)
entry_list=$(find "$KNOWLEDGE_DIR" -maxdepth 2 -name "*.md" \
  | python3 -c "
import sys, os
kdir = sys.argv[1]
for path in sys.stdin:
    path = path.strip()
    fname = os.path.basename(path)
    if fname.startswith('_'):
        continue
    parts = path.split('/')
    # must be exactly one level below KDIR (maxdepth 2 means category/file.md)
    rel = os.path.relpath(path, kdir)
    rel_parts = rel.split(os.sep)
    if len(rel_parts) != 2:
        continue
    cat = rel_parts[0]
    if cat.startswith('_'):
        continue
    print(path)
" "$KNOWLEDGE_DIR" | sort)

total=$(echo "$entry_list" | grep -c . 2>/dev/null || echo 0)

while IFS= read -r entry_path; do
  [[ -z "$entry_path" ]] && continue

  if [[ "$LIMIT" -gt 0 && "$processed" -ge "$LIMIT" ]]; then
    break
  fi

  # Skip entries without an HTML META comment (documentation/index files, not knowledge entries)
  if ! grep -q "<!-- learned:" "$entry_path" 2>/dev/null; then
    skipped=$((skipped + 1))
    continue
  fi

  # Skip entries that already have scale:
  if grep -q "| scale:" "$entry_path" 2>/dev/null; then
    skipped=$((skipped + 1))
    continue
  fi

  # Extract META block fields using python3
  read -r producer_role protocol_slot work_item <<< "$(python3 -c "
import sys, re
content = open('$entry_path'.replace(\"'\", \"'\\\\''\")).read()
m = re.search(r'<!--(.+?)-->', content, re.DOTALL)
if not m:
    print('', '', '')
    sys.exit(0)
meta = m.group(1)
def get(pat):
    r = re.search(pat + r':\s*(\S+)', meta)
    return r.group(1) if r else ''
print(get('producer_role'), get('protocol_slot'), get('work_item'))
" 2>/dev/null || echo '  ')"

  # Resolve scale
  resolved_scale=""

  if [[ -n "$producer_role" && -n "$protocol_slot" ]]; then
    if [[ -n "$work_item" ]]; then
      scope_file="$KNOWLEDGE_DIR/_work/$work_item/_meta.json"
      if [[ -f "$scope_file" ]]; then
        work_scope=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('scope', 'subsystem'))
except Exception:
    print('subsystem')
" "$scope_file" 2>/dev/null || echo "subsystem")
      else
        work_scope="subsystem"
      fi
    else
      work_scope="subsystem"
    fi

    if resolved_scale=$("$SCRIPT_DIR/scale-compute.sh" \
        --work-scope "$work_scope" \
        --role "$producer_role" \
        --slot "$protocol_slot" 2>/dev/null); then
      : # resolved_scale set from stdout
    else
      resolved_scale="unknown"
      unknown_scale=$((unknown_scale + 1))
    fi
  else
    resolved_scale="unknown"
    unknown_scale=$((unknown_scale + 1))
  fi

  new_fields=" | scale: $resolved_scale | scale_registry_version: $REGISTRY_VERSION"

  if "$DRY_RUN"; then
    echo "[dry-run] $entry_path"
    echo "          → scale: $resolved_scale | scale_registry_version: $REGISTRY_VERSION"
  else
    python3 - "$entry_path" "$new_fields" <<'PYEOF'
import sys, re

entry_path = sys.argv[1]
new_fields = sys.argv[2]

content = open(entry_path).read()

def insert_before_close(m):
    inner = m.group(1)
    return '<!--' + inner.rstrip() + new_fields + ' -->'

new_content = re.sub(r'<!--(.+?)-->', insert_before_close, content, flags=re.DOTALL)
open(entry_path, 'w').write(new_content)
PYEOF
  fi

  updated=$((updated + 1))
  processed=$((processed + 1))

done <<< "$entry_list"

echo "[backfill-scale] Scanned $total entries."
echo "[backfill-scale] Already had scale: $skipped (skipped)."
echo "[backfill-scale] Updated: $updated (scale: unknown for $unknown_scale without role+slot)."
if "$DRY_RUN"; then
  echo "[backfill-scale] Dry-run mode — no files modified."
fi
