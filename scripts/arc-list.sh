#!/usr/bin/env bash
# arc-list.sh — list coordination arcs as a flat list with a project column.
#
# Usage: bash arc-list.sh [--status active|closed|archived] [--project <name>] [--json]
#
# Read-only: it never creates a directory, rebuilds an index, or touches a
# record. A record that will not parse is left out of the listing and named on
# stderr, so one bad record cannot make every arc unlistable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  lore arc list [--status active|closed|archived] [--project <name>] [--json]

Lists arcs newest first, in an Active and a Complete section. Archived arcs are
out of the default listing; ask for them with --status archived.

Options:
  --status <s>      Show only arcs in this state.
  --project <name>  Show only arcs carrying this project label. Projects are
                    labels, so a name matching nothing lists nothing.
  --json            Emit rows as JSON. Every key is present on every row, with
                    project and closed_at null rather than absent when unset.
  --kdir <path>     Override the resolved knowledge dir (testing).
  --help, -h        Show this help.
EOF
}

STATUS_FILTER=""
PROJECT_FILTER=""; HAS_PROJECT=0
JSON_MODE=0
KDIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status) STATUS_FILTER="${2:-}"; shift 2 ;;
    --project) PROJECT_FILTER="${2:-}"; HAS_PROJECT=1; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*)
      if [[ $JSON_MODE -eq 1 ]]; then json_error "Unknown option '$1'"; fi
      echo "[arc] Error: unknown option '$1'" >&2; usage; exit 1 ;;
    *)
      if [[ $JSON_MODE -eq 1 ]]; then json_error "'$1' is unexpected — arc list takes no positional arguments"; fi
      echo "[arc] Error: '$1' is unexpected — arc list takes no positional arguments" >&2
      usage
      exit 1 ;;
  esac
done

fail() {
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$1"
  fi
  echo "[arc] Error: $1" >&2
  exit 1
}

case "$STATUS_FILTER" in
  ""|active|closed|archived) ;;
  *) fail "'$STATUS_FILTER' is not a status — use active, closed, or archived" ;;
esac

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

WORK_DIR="$KNOWLEDGE_DIR/_work"

ARC_WORK_DIR="$WORK_DIR" \
ARC_STATUS_FILTER="$STATUS_FILTER" \
ARC_PROJECT_FILTER="$PROJECT_FILTER" \
ARC_HAS_PROJECT_FILTER="$HAS_PROJECT" \
ARC_JSON_MODE="$JSON_MODE" \
python3 - <<'PYEOF'
import json
import os
import sys

env = os.environ
WORK_DIR = env["ARC_WORK_DIR"]
ARCS_DIR = os.path.join(WORK_DIR, "_arcs")
STATUS_FILTER = env["ARC_STATUS_FILTER"]
PROJECT_FILTER = env["ARC_PROJECT_FILTER"]
HAS_PROJECT_FILTER = env["ARC_HAS_PROJECT_FILTER"] == "1"
JSON_MODE = env["ARC_JSON_MODE"] == "1"

SECTION_OF = {"active": "active", "closed": "complete", "archived": "archived"}
SECTION_TITLE = {"active": "Active", "complete": "Complete", "archived": "Archived"}


def warn(message):
    sys.stderr.write("[arc] Warning: %s\n" % message)


wanted = {STATUS_FILTER} if STATUS_FILTER else {"active", "closed"}

rows = []
if os.path.isdir(ARCS_DIR):
    for name in sorted(os.listdir(ARCS_DIR)):
        if name.startswith("_") or name.startswith("."):
            continue
        meta_path = os.path.join(ARCS_DIR, name, "_meta.json")
        if not os.path.isfile(meta_path):
            continue
        try:
            with open(meta_path) as handle:
                record = json.load(handle)
        except ValueError:
            warn("skipping %s — the record is not valid JSON" % meta_path)
            continue
        if not isinstance(record, dict):
            warn("skipping %s — the record is not a JSON object" % meta_path)
            continue

        status = record.get("status")
        if status not in SECTION_OF:
            warn("skipping %s — status '%s' is outside active, closed, archived"
                 % (meta_path, status))
            continue
        if status not in wanted:
            continue

        project = record.get("project")
        if HAS_PROJECT_FILTER and project != PROJECT_FILTER:
            continue

        # Member counts scope to live work: a slug that has been archived, or
        # that no longer resolves at all, is not a member this arc still tracks.
        member_count = 0
        for member in record.get("members") or []:
            if not isinstance(member, str):
                continue
            if os.path.isdir(os.path.join(WORK_DIR, member)):
                member_count += 1
            elif not os.path.isdir(os.path.join(WORK_DIR, "_archive", member)):
                warn("arc '%s' lists member '%s', which resolves to no work item"
                     % (name, member))

        rows.append({
            "slug": record.get("slug") or name,
            "title": record.get("title") or "",
            "status": status,
            "section": SECTION_OF[status],
            "project": project if project else None,
            "member_count": member_count,
            "opened": record.get("opened") or None,
            "closed_at": record.get("closed_at") or None,
            "path": os.path.join("_work", "_arcs", name),
        })

rows.sort(key=lambda row: (row["opened"] or "", row["slug"]), reverse=True)

if JSON_MODE:
    print(json.dumps(rows, indent=2))
    sys.exit(0)

print('=== Arcs ===')
if not rows:
    print("")
    print("  (no arcs)")
    sys.exit(0)

for section in ("active", "complete", "archived"):
    section_rows = [row for row in rows if row["section"] == section]
    if not section_rows:
        continue
    print("")
    print("%s (%d)" % (SECTION_TITLE[section], len(section_rows)))
    slug_width = max(len(row["slug"]) for row in section_rows)
    project_width = max(len(row["project"] or "—") for row in section_rows)
    for row in section_rows:
        opened = (row["opened"] or "")[:10] or "unrecorded"
        members = "%2d member%s" % (row["member_count"], "" if row["member_count"] == 1 else "s")
        print("  %-*s  %-*s  %s  opened %s  %s" % (
            slug_width, row["slug"],
            project_width, row["project"] or "—",
            members,
            opened,
            row["title"],
        ))

if not STATUS_FILTER:
    print("")
    print("Archived arcs are listed with --status archived.")
PYEOF
