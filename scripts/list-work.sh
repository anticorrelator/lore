#!/usr/bin/env bash
# list-work.sh — List all active work items with summary info
# Usage: bash list-work.sh [--all] [--status <status>]
# Reads _index.json and formats a table of work items.
# --all: include archived items
# --status: filter by status (active, completed, archived)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_DIR="$KNOWLEDGE_DIR/_work"

if [[ ! -d "$WORK_DIR" ]]; then
  echo "[work] Error: No work directory found. Run /work create first." >&2
  exit 1
fi

INDEX="$WORK_DIR/_index.json"

# Freshen the index before reading so a just-written divergence (or archive)
# shows up immediately, not on the next run.
"$SCRIPT_DIR/update-work-index.sh" >/dev/null 2>/dev/null || true

# Self-heal: regenerate index if missing
if [[ ! -f "$INDEX" ]]; then
  "$SCRIPT_DIR/update-work-index.sh" 2>/dev/null || true
fi

if [[ ! -f "$INDEX" ]]; then
  echo "[work] Error: No work index found and could not regenerate." >&2
  exit 1
fi

# Parse arguments
SHOW_ALL=false
FILTER_STATUS=""
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      SHOW_ALL=true
      shift
      ;;
    --status)
      FILTER_STATUS="$2"
      shift 2
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    *)
      echo "[work] Error: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# JSON output: return the plans array from _index.json directly
# With --all, also return the archived array
if [[ "$JSON_OUTPUT" == true ]]; then
  if [[ "$SHOW_ALL" == true ]]; then
    python3 -c "
import json, sys
with open('$INDEX') as f:
    data = json.load(f)
result = {'plans': data.get('plans', []), 'archived': data.get('archived', [])}
print(json.dumps(result))
"
  else
    python3 -c "
import json, sys
with open('$INDEX') as f:
    data = json.load(f)
print(json.dumps(data.get('plans', [])))
"
  fi
  exit 0
fi

TERM_WIDTH="$(term_width)"

# Project records feed only the header status token; counts come from the
# index projections. One "slug<TAB>status" line per record, dual-reading the
# directory homes and any unmigrated legacy flat records.
PROJECT_RECORD_STATUSES=""
if [[ -d "$WORK_DIR/_projects" ]]; then
  PROJECT_RECORD_STATUSES="$(project_record_statuses "$WORK_DIR")"
fi

python3 - "$INDEX" "$WORK_DIR/_archive" "$FILTER_STATUS" "$SHOW_ALL" "$TERM_WIDTH" "$PROJECT_RECORD_STATUSES" << 'PYEOF'
import json
import os
import sys
import time
from datetime import datetime, timezone

index_path, archive_dir, filter_status, show_all, term_width, record_status_raw = sys.argv[1:]
show_all = show_all == "true"
try:
    term_width = int(term_width)
except ValueError:
    term_width = 100
term_width = max(term_width, 100)


def draw_separator(title=""):
    if not title:
        print("─" * term_width)
        return
    decorated = f"── {title} "
    remaining = max(term_width - len(decorated), 1)
    print(decorated + ("─" * remaining))


def parse_epoch(value):
    if not value:
        return 0
    raw = str(value)
    candidates = [raw]
    if raw.endswith("Z"):
        candidates.append(raw[:-1] + "+00:00")
        candidates.append(raw[:-1])
    for candidate in candidates:
        try:
            dt = datetime.fromisoformat(candidate)
        except ValueError:
            continue
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp())
    return 0


def relative_date(value):
    epoch = parse_epoch(value)
    if epoch == 0:
        return "unknown"
    days_ago = int((time.time() - epoch) // 86400)
    if days_ago == 0:
        return "today"
    if days_ago == 1:
        return "yesterday"
    return f"{days_ago}d ago"


def truncate(value, width):
    value = str(value)
    if len(value) <= width:
        return value
    if width <= 2:
        return value[:width]
    return value[: width - 2] + ".."


def column_widths(columns):
    fixed_total = sum(col["size"] for col in columns if col["type"] == "fixed")
    flex_total = sum(col["size"] for col in columns if col["type"] == "flex")
    gaps = len(columns) - 1
    indent = 2
    flex_space = max(term_width - indent - fixed_total - gaps, 0)

    widths = []
    for col in columns:
        if col["type"] == "fixed":
            widths.append(col["size"])
        elif flex_total > 0:
            widths.append(max(flex_space * col["size"] // flex_total, 10))
        else:
            widths.append(10)
    return widths


def format_row(values, widths, columns):
    rendered = []
    for value, width, col in zip(values, widths, columns):
        value = truncate(value, width)
        if col["align"] == "right":
            rendered.append(value.rjust(width))
        else:
            rendered.append(value.ljust(width))
    print("  " + " ".join(rendered))


def render_header(widths, columns):
    format_row([col["name"] for col in columns], widths, columns)
    format_row(["-" * width for width in widths], widths, columns)


def render_table(rows, columns):
    widths = column_widths(columns)
    render_header(widths, columns)
    for row in rows:
        format_row(row, widths, columns)


with open(index_path) as f:
    data = json.load(f)

plans = data.get("plans", [])
if filter_status:
    plans = [item for item in plans if item.get("status", "") == filter_status]

archived = data.get("archived")
if archived is None:
    if os.path.isdir(archive_dir):
        archived = [
            name
            for name in os.listdir(archive_dir)
            if os.path.isdir(os.path.join(archive_dir, name))
        ]
    else:
        archived = []

# Archived rollup counts come from the archived[] projection; the legacy
# dirname fallback carries no project field and contributes nothing.
archived_counts = {}
for item in archived:
    if isinstance(item, dict):
        project = str(item.get("project", "") or "")
        if project:
            archived_counts[project] = archived_counts.get(project, 0) + 1

record_status = {}
for line in record_status_raw.splitlines():
    if "\t" in line:
        name, _, status = line.partition("\t")
        record_status[name] = status.strip()


def project_header(name, active_count):
    header = name
    status = record_status.get(name, "")
    if status and status != "active":
        header += f" [{status}]"
    header += f" — {active_count} active"
    archived_count = archived_counts.get(name, 0)
    if archived_count:
        header += f", {archived_count} archived"
    return header


rows = []
has_any_issue = False
has_any_pr = False
project_rows = {}
ungrouped_rows = []
for item in plans:
    issue = str(item.get("issue", "") or "")
    pr = str(item.get("pr", "") or "")
    has_any_issue = has_any_issue or bool(issue)
    has_any_pr = has_any_pr or bool(pr)
    row = {
        "slug": str(item.get("slug", "")),
        "status": str(item.get("status", "")),
        "updated": relative_date(item.get("updated", "")),
        "issue": f"#{issue}" if issue else "",
        "pr": f"#{pr}" if pr else "",
        "plan": "yes" if item.get("has_plan_doc") else "no",
    }
    rows.append(row)
    project = str(item.get("project", "") or "")
    if project:
        project_rows.setdefault(project, []).append(
            (parse_epoch(item.get("updated", "")), row)
        )
    else:
        ungrouped_rows.append(row)

draw_separator("Work Items")
print()

if not rows:
    if filter_status:
        print(f"No work items with status: {filter_status}")
    else:
        print("No active work items.")
else:
    columns = [
        {"name": "SLUG", "type": "flex", "size": 100, "align": "left"},
        {"name": "STATUS", "type": "fixed", "size": 8, "align": "left"},
        {"name": "UPDATED", "type": "fixed", "size": 10, "align": "left"},
    ]
    fields = ["slug", "status", "updated"]
    if has_any_issue:
        columns.append({"name": "ISSUE", "type": "fixed", "size": 8, "align": "left"})
        fields.append("issue")
    if has_any_pr:
        columns.append({"name": "PR", "type": "fixed", "size": 8, "align": "left"})
        fields.append("pr")
    columns.append({"name": "PLAN", "type": "fixed", "size": 4, "align": "left"})
    fields.append("plan")
    # A project record file makes the project a section even with no active
    # members (e.g. a done project whose members are all archived).
    for name in record_status:
        project_rows.setdefault(name, [])
    if not project_rows:
        render_table([[row[field] for field in fields] for row in rows], columns)
    else:
        # Grouped sections lead, projects ordered by most-recent member
        # update (member-less record sections sort last); ungrouped items
        # follow in index order under their own titled section so the tail
        # reads as a sibling of project groups.
        widths = column_widths(columns)
        render_header(widths, columns)
        ordered_projects = sorted(
            project_rows.items(),
            key=lambda kv: max((epoch for epoch, _ in kv[1]), default=0),
            reverse=True,
        )
        for project, members in ordered_projects:
            draw_separator(project_header(project, len(members)))
            for _, row in sorted(members, key=lambda m: m[0], reverse=True):
                format_row([row[field] for field in fields], widths, columns)
        if ungrouped_rows:
            draw_separator(f"ungrouped — {len(ungrouped_rows)} active")
            for row in ungrouped_rows:
                format_row([row[field] for field in fields], widths, columns)

print()
print(f"Active: {len(rows)} | Archived: {len(archived)}")

# Active parents that diverged from their anchor at /implement close stay in
# the list but are not routine: name what diverged and the child holding the gap.
diverged = [
    item for item in plans
    if str(item.get("status", "")) == "active"
    and (item.get("closure") or {}).get("capability_incomplete") is True
]
if diverged:
    print()
    for item in diverged:
        slug = str(item.get("slug", ""))
        closure = item.get("closure") or {}
        summary = closure.get("divergence_summary") or "capability incomplete"
        print(f"[capability-incomplete] {slug} — diverged from anchor; {summary}")
        residue = closure.get("residue_followup")
        if residue:
            print(f"  waiting-on: {residue}")

# Active items under a review gate get a marker (this surface has no shared
# renderer with load-work.sh — the marker is applied to each independently).
gated = [
    item for item in plans
    if str(item.get("status", "")) == "active"
    and isinstance(item.get("review"), dict)
    and item["review"].get("mechanism") in ("flag", "hold")
]
if gated:
    print()
    for item in gated:
        slug = str(item.get("slug", ""))
        review = item["review"]
        mechanism = review.get("mechanism")
        reason = review.get("reason") or ""
        gated_at = review.get("gated_at", "")
        epoch = parse_epoch(gated_at)
        age = f"{int((time.time() - epoch) // 86400)}d" if epoch else "unknown"
        if mechanism == "hold":
            print(f"[review-hold] {slug} — held {age} — {reason}")
        else:
            print(f"[review-flag] {slug} — flagged {age}, unread — show or clear")

if show_all and archived:
    print()
    print("--- Archived ---")
    for item in archived:
        if isinstance(item, str):
            print(f"  {item}")
            continue
        slug = str(item.get("slug", ""))
        title = str(item.get("title", slug))
        refs = ""
        project = str(item.get("project", "") or "")
        if project:
            refs += f" project:{project}"
        issue = str(item.get("issue", "") or "")
        pr = str(item.get("pr", "") or "")
        if issue:
            refs += f" issue:#{issue}"
        if pr:
            refs += f" pr:#{pr}"
        print(f"  {slug}: {title}{refs}")

print()
draw_separator()
PYEOF
