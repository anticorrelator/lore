#!/usr/bin/env bash
# load-work.sh — SessionStart hook: show active work items, detect branch match
# Usage: bash load-work.sh
# Called by Claude Code SessionStart hook (startup, resume, compact)

set -euo pipefail

SCRIPT_NAME="load-work"

# Hook failure diagnostic trap
trap 'echo "[hook] $SCRIPT_NAME: Failed at line $LINENO with exit code $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" 2>/dev/null) || exit 0

WORK_DIR="$KNOWLEDGE_DIR/_work"

# Exit silently if no work directory
[[ -d "$WORK_DIR" ]] || exit 0

INDEX="$WORK_DIR/_index.json"

# Freshen the index before reading (catches archived items not yet reflected in stale index)
"$SCRIPT_DIR/update-work-index.sh" >/dev/null 2>/dev/null || true

# Self-heal: regenerate index if missing
if [[ ! -f "$INDEX" ]]; then
  "$SCRIPT_DIR/update-work-index.sh" 2>/dev/null || exit 0
fi

[[ -f "$INDEX" ]] || exit 0

# Check if there are any work items
WORK_COUNT=$(grep -c '"slug"' "$INDEX" 2>/dev/null || true)
WORK_COUNT=$(echo "$WORK_COUNT" | tr -d '[:space:]')
[[ "$WORK_COUNT" -gt 0 ]] || exit 0

# Parse work items, calculate dates, check staleness — single python3 pass
eval "$(python3 -c "
import json, os, time, re, sys
from datetime import datetime, timezone

work_dir = sys.argv[1]
index_path = sys.argv[2]
now = time.time()

with open(index_path) as f:
    data = json.load(f)

active_work_lines = []
stale_work_lines = []
def dir_max_mtime(path):
    \"\"\"Return max mtime across all files in a directory, or 0 if empty/missing.\"\"\"
    try:
        mtimes = [
            os.path.getmtime(os.path.join(path, f))
            for f in os.listdir(path)
            if os.path.isfile(os.path.join(path, f))
        ]
        return max(mtimes) if mtimes else 0
    except OSError:
        return 0

def relative_date(iso_str):
    if not iso_str:
        return 'unknown', -1
    try:
        # Handle both Z suffix and plain ISO
        clean = iso_str.replace('Z', '+00:00')
        dt = datetime.fromisoformat(clean)
        days = int((now - dt.timestamp()) / 86400)
        if days == 0:
            return 'today', days
        elif days == 1:
            return 'yesterday', days
        else:
            return f'{days}d ago', days
    except (ValueError, OSError):
        return 'unknown', -1

for item in data.get('plans', []):
    slug = item.get('slug', '')
    title = item.get('title', '')
    status = item.get('status', '')
    updated = item.get('updated', '')

    if status != 'active':
        continue

    rel, days_ago = relative_date(updated)

    item_dir = os.path.join(work_dir, slug)

    # Stale work: use directory-wide max mtime as activity signal
    dir_mtime = dir_max_mtime(item_dir)
    dir_age_days = int((now - dir_mtime) / 86400) if dir_mtime else -1
    if dir_age_days > 30:
        has_plan = item.get('has_plan_doc', os.path.isfile(os.path.join(item_dir, 'plan.md')))
        if has_plan:
            guidance = 'consider \`/work\` to review status'
        else:
            guidance = 'consider \`/work archive\`'
        stale_work_lines.append(
            f'[stale] {slug} — inactive {dir_age_days} days, {guidance}'
        )

    active_work_lines.append(f'- {slug}: {title} (updated {rel})')

# Shell-escape helper for single quotes
def sq(s):
    return s.replace(\"'\", \"'\\\\''\" )

# Output shell variable assignments
active = '\\n'.join(active_work_lines)
print(f\"ACTIVE_WORK='{sq(active)}'\")

stale = '\\n'.join(stale_work_lines)
print(f\"STALE_WORK='{sq(stale)}'\")
" "$WORK_DIR" "$INDEX")"

# Build output (budget: ~2000 chars)
draw_separator "Active Work"
echo ""
echo "[work] Use \`/work\` to check status before manual exploration"
echo ""

echo "$ACTIVE_WORK"

if [[ -n "$STALE_WORK" ]]; then
  echo "$STALE_WORK"
fi

# Check for orphaned ephemeral plan files
EPHEMERAL_DIR="$HOME/.claude/plans"
if [[ -d "$EPHEMERAL_DIR" ]]; then
  ORPHAN_COUNT=$(find "$EPHEMERAL_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$ORPHAN_COUNT" -gt 0 ]]; then
    echo "[work] $ORPHAN_COUNT ephemeral plan file(s) in ~/.claude/plans/ may not be persisted"
    echo "[work] Use /work list to review — persist with /work create or delete if stale"
    echo ""
  fi
fi

draw_separator
