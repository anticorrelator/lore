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

# No-op the hook when the lore agent integration is disabled. The disable
# check used to live in resolve-repo.sh; moved here so the CLI / TUI can
# still resolve the knowledge dir while harness hooks stay quiet.
lore_agent_enabled || exit 0

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

# Project records feed only the header status token; counts come from the
# index projections. One "slug<TAB>status" line per record file.
PROJECT_RECORD_STATUSES=""
if [[ -d "$WORK_DIR/_projects" ]]; then
  for record in "$WORK_DIR/_projects"/*.md; do
    [[ -f "$record" ]] || continue
    pslug=$(basename "$record" .md)
    PROJECT_RECORD_STATUSES+="${pslug}"$'\t'"$(project_record_field "$WORK_DIR" "$pslug" Status)"$'\n'
  done
fi

# Parse work items, calculate dates, check staleness — single python3 pass
eval "$(python3 -c "
import json, os, time, re, sys
from datetime import datetime, timezone

work_dir = sys.argv[1]
index_path = sys.argv[2]
record_status_raw = sys.argv[3] if len(sys.argv) > 3 else ''
now = time.time()

with open(index_path) as f:
    data = json.load(f)

record_status = {}
for line in record_status_raw.splitlines():
    if '\t' in line:
        name, _, status = line.partition('\t')
        record_status[name] = status.strip()

# Archived rollup counts come from the archived[] projection.
archived_counts = {}
for item in data.get('archived') or []:
    if isinstance(item, dict):
        project = str(item.get('project', '') or '')
        if project:
            archived_counts[project] = archived_counts.get(project, 0) + 1

def project_header(name, active_count):
    header = name
    status = record_status.get(name, '')
    if status and status != 'active':
        header += f' [{status}]'
    header += f' — {active_count} active'
    archived_count = archived_counts.get(name, 0)
    if archived_count:
        header += f', {archived_count} archived'
    return header

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
        return 'unknown', -1, 0
    try:
        # Handle both Z suffix and plain ISO
        clean = iso_str.replace('Z', '+00:00')
        dt = datetime.fromisoformat(clean)
        epoch = dt.timestamp()
        days = int((now - epoch) / 86400)
        if days == 0:
            return 'today', days, epoch
        elif days == 1:
            return 'yesterday', days, epoch
        else:
            return f'{days}d ago', days, epoch
    except (ValueError, OSError):
        return 'unknown', -1, 0

grouped_items = {}
ungrouped_items = []
for item in data.get('plans', []):
    slug = item.get('slug', '')
    title = item.get('title', '')
    status = item.get('status', '')
    updated = item.get('updated', '')

    if status != 'active':
        continue

    rel, days_ago, epoch = relative_date(updated)

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

    # A parent that diverged from its anchor at /implement close stays active
    # but is not routine: surface what diverged and the child holding the gap.
    item_lines = []
    closure = item.get('closure') or {}
    if closure.get('capability_incomplete') is True:
        summary = closure.get('divergence_summary') or 'capability incomplete'
        item_lines.append(
            f'[capability-incomplete] {slug} — diverged from anchor; {summary}'
        )
        residue = closure.get('residue_followup')
        if residue:
            item_lines.append(f'  waiting-on: {residue}')
    else:
        item_lines.append(f'- {slug}: {title} (updated {rel})')

    project = str(item.get('project', '') or '')
    if project:
        grouped_items.setdefault(project, []).append((epoch, item_lines))
    else:
        ungrouped_items.append(item_lines)

# Project sections lead, ordered by most-recent member update; members are
# recency-sorted within. When any project section exists, ungrouped items get
# their own 'ungrouped — N active' section (N counts items, not lines) with
# the same member indent; with no projects they stay flat, unchanged from
# before.
for project, members in sorted(
    grouped_items.items(), key=lambda kv: max(e for e, _ in kv[1]), reverse=True
):
    active_work_lines.append(f'{project_header(project, len(members))}:')
    for _, item_lines in sorted(members, key=lambda m: m[0], reverse=True):
        for line in item_lines:
            active_work_lines.append(f'  {line}')
if grouped_items and ungrouped_items:
    active_work_lines.append(f'ungrouped — {len(ungrouped_items)} active:')
    for item_lines in ungrouped_items:
        for line in item_lines:
            active_work_lines.append(f'  {line}')
else:
    for item_lines in ungrouped_items:
        active_work_lines.extend(item_lines)

# Shell-escape helper for single quotes
def sq(s):
    return s.replace(\"'\", \"'\\\\''\" )

# Output shell variable assignments
active = '\\n'.join(active_work_lines)
print(f\"ACTIVE_WORK='{sq(active)}'\")

stale = '\\n'.join(stale_work_lines)
print(f\"STALE_WORK='{sq(stale)}'\")
" "$WORK_DIR" "$INDEX" "$PROJECT_RECORD_STATUSES")"

# Pending session requests (D7): surface cold-start coordination requests waiting
# in _sessions/requests/pending/ so a request enqueued while no TUI is alive is
# visible to the next session. Rows are written tmp+atomic-rename, so a reader
# never sees a torn row; a genuinely malformed row is excluded-with-warning to
# stderr and skipped. Capped to protect the ~2000-char budget.
SESSION_REQUESTS=""
PENDING_DIR="$KNOWLEDGE_DIR/_sessions/requests/pending"
if [[ -d "$PENDING_DIR" ]]; then
  SESSION_REQUESTS=$(python3 - "$PENDING_DIR" <<'PYEOF' || true
import json, os, sys, time
from datetime import datetime

pending_dir = sys.argv[1]
now = time.time()

def rel_age(iso_str):
    if not iso_str:
        return 'unknown age'
    try:
        dt = datetime.fromisoformat(iso_str.replace('Z', '+00:00'))
        days = int((now - dt.timestamp()) / 86400)
        if days <= 0:
            return 'today'
        if days == 1:
            return 'yesterday'
        return f'{days}d ago'
    except (ValueError, OSError):
        return 'unknown age'

lines = []
for name in sorted(os.listdir(pending_dir)):
    if not name.endswith('.json'):
        continue
    path = os.path.join(pending_dir, name)
    try:
        with open(path) as f:
            row = json.load(f)
    except (OSError, ValueError) as exc:
        print(f'[session] warning: {name} corrupt — {exc}; excluded', file=sys.stderr)
        continue
    typ = row.get('type') or '?'
    slug = row.get('slug') or '(no slug)'
    target = row.get('target_instance') or 'any'
    age = rel_age(row.get('requested_at', ''))
    lines.append(f'[session-request] {typ} {slug} → {target} ({age})')

CAP = 8
if len(lines) > CAP:
    overflow = len(lines) - CAP
    lines = lines[:CAP] + [f'[session-request] +{overflow} more pending']
print('\n'.join(lines))
PYEOF
)
fi

# Build output (budget: ~2000 chars)
draw_separator "Active Work"
echo ""
echo "[work] Use \`/work\` to check status before manual exploration"
echo ""

echo "$ACTIVE_WORK"

if [[ -n "$STALE_WORK" ]]; then
  echo "$STALE_WORK"
fi

if [[ -n "$SESSION_REQUESTS" ]]; then
  echo "$SESSION_REQUESTS"
fi

# Check for orphaned ephemeral plan files. The path is harness-specific —
# Claude Code keeps them at ~/.claude/plans/, other harnesses may have a
# different surface or none at all. harness_path_or_empty returns the
# absolute path on supported harnesses or an empty string on unsupported /
# config error — both silent skips so a session-start hook never fails
# loudly on a missing capability.
EPHEMERAL_DIR=$(harness_path_or_empty ephemeral_plans)
if [[ -n "$EPHEMERAL_DIR" && -d "$EPHEMERAL_DIR" ]]; then
  ORPHAN_COUNT=$(find "$EPHEMERAL_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$ORPHAN_COUNT" -gt 0 ]]; then
    echo "[work] $ORPHAN_COUNT ephemeral plan file(s) in $EPHEMERAL_DIR may not be persisted"
    echo "[work] Use /work list to review — persist with /work create or delete if stale"
    echo ""
  fi
fi

draw_separator
