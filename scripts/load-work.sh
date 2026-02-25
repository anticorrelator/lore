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

# Get current git branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

# Parse work items, check branch match, calculate dates, check staleness — single python3 pass
eval "$(python3 -c "
import json, os, time, re, sys
from datetime import datetime, timezone

work_dir = sys.argv[1]
index_path = sys.argv[2]
current_branch = sys.argv[3]
now = time.time()

with open(index_path) as f:
    data = json.load(f)

active_work_lines = []
stale_work_lines = []
notes_stale_lines = []
branch_match = ''
last_entry = ''

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

def get_last_notes_section(notes_path, max_lines=8):
    \"\"\"Extract last ## section from notes.md, up to max_lines.\"\"\"
    try:
        with open(notes_path) as f:
            lines = f.readlines()
    except (OSError, IOError):
        return ''
    # Find all ## heading positions
    headings = [i for i, l in enumerate(lines) if l.startswith('## ')]
    if not headings:
        return ''
    start = headings[-1]
    section = lines[start:start + max_lines]
    return ''.join(section).rstrip()

for item in data.get('plans', []):
    slug = item.get('slug', '')
    title = item.get('title', '')
    status = item.get('status', '')
    updated = item.get('updated', '')

    if status != 'active':
        continue

    rel, days_ago = relative_date(updated)

    # Branch match: read _meta.json for branches array
    if current_branch and not branch_match:
        meta_path = os.path.join(work_dir, slug, '_meta.json')
        if os.path.isfile(meta_path):
            try:
                with open(meta_path) as mf:
                    meta = json.load(mf)
                if current_branch in meta.get('branches', []):
                    branch_match = slug
                    notes_path = os.path.join(work_dir, slug, 'notes.md')
                    if os.path.isfile(notes_path):
                        last_entry = get_last_notes_section(notes_path)
            except (json.JSONDecodeError, OSError):
                pass

    # Stale work (>30 days since updated)
    if days_ago > 30:
        stale_work_lines.append(
            f'- {slug} — inactive {days_ago} days, consider \`/work archive\`'
        )

    active_work_lines.append(f'- {slug}: {title} (updated {rel})')

    # Notes.md staleness check (>14 days since file modification)
    notes_path = os.path.join(work_dir, slug, 'notes.md')
    if os.path.isfile(notes_path):
        try:
            mtime = os.path.getmtime(notes_path)
            age_days = int((now - mtime) / 86400)
            if age_days > 14:
                notes_stale_lines.append(
                    f'[Stale] Work item \"{slug}\" has no activity in {age_days} days'
                )
        except OSError:
            pass

# Shell-escape helper for single quotes
def sq(s):
    return s.replace(\"'\", \"'\\\\''\" )

# Output shell variable assignments
print(f\"BRANCH_MATCH='{sq(branch_match)}'\")
print(f\"LAST_ENTRY='{sq(last_entry)}'\")

active = '\\n'.join(active_work_lines)
print(f\"ACTIVE_WORK='{sq(active)}'\")

stale = '\\n'.join(stale_work_lines)
print(f\"STALE_WORK='{sq(stale)}'\")

notes_stale = '\\n'.join(notes_stale_lines)
print(f\"NOTES_STALE='{sq(notes_stale)}'\")
" "$WORK_DIR" "$INDEX" "$CURRENT_BRANCH")"

# Build output (budget: ~2000 chars)
draw_separator "Active Work"
echo ""
echo "[work] Use \`/work\` to check status before manual exploration"
echo ""

if [[ -n "$BRANCH_MATCH" ]]; then
  META_FILE="$WORK_DIR/$BRANCH_MATCH/_meta.json"
  MATCH_TITLE=$(json_field "title" "$META_FILE")
  echo "[Current branch matches: $MATCH_TITLE]"
  if [[ -n "${LAST_ENTRY:-}" ]]; then
    echo "$LAST_ENTRY" | head -6
  fi
  echo ""
fi

echo "$ACTIVE_WORK"

if [[ -n "$STALE_WORK" ]]; then
  echo "$STALE_WORK"
fi

if [[ -n "$NOTES_STALE" ]]; then
  echo "$NOTES_STALE"
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
