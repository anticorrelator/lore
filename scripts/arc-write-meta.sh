#!/usr/bin/env bash
# arc-write-meta.sh — sole writer of the arc record
#   _work/_arcs/<slug>/_meta.json (schema v1):
#     {"schema_version": 1, "slug", "title", "status", "anchor",
#      "project"?, "watcher_settings_path"?, "members": [...], "opened",
#      "closed_at"?}
#   `project` is omitted when unset rather than stored as an empty string, and
#   `closed_at` is absent while the arc is active. Every `lore arc` verb and the
#   arc migration shell to this script; nothing else writes the file.
#
# Usage:
#   arc-write-meta.sh --slug <slug> --op <operation> [options]
#
# schema_version, slug, and opened are immutable after creation; title, anchor,
# project, members, status, and closed_at are mutable. Writes go through
# mktemp + atomic rename, and a write whose result matches the record already on
# disk is skipped entirely.
#
# Emits {"changed": <bool>, "record": {...}} on stdout, diagnostics on stderr.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  arc-write-meta.sh --slug <slug> --op <operation> [options]

Operations:
  open         Create an active arc. Needs --title and --anchor.
  import       Create an arc carrying historical timestamps. Needs --title, and
               accepts --status, --opened, and --closed-at. Creation-only: it
               refuses an arc that already exists, so it cannot rewrite history.
  set          Update --title, --anchor, --project, or --clear-project.
  watcher-set  Record the exact settings file containing this arc's watcher.
  close        Record closure and stamp closed_at.
  archive      Record archival, preserving an existing closed_at.
  member-add   Add a work item to members. Needs --member.
  member-rm    Remove a work item from members. Needs --member.

Options:
  --slug <slug>          Arc slug (required).
  --op <operation>       Operation to apply (required).
  --record-dir <path>    Directory holding the record. Accepted only with
                         `--op import`; defaults to <kdir>/_work/_arcs/<slug>.
  --title <text>         Arc title.
  --anchor <text>        Intent statement, stored verbatim.
  --project <name>       Project label. An empty value is refused — pass
                         --clear-project to remove the label.
  --clear-project        Remove the project label.
  --watcher-settings <path>
                         Exact installed settings path. Needs `--op watcher-set`.
  --member <slug>        Work-item slug, resolved in active work items then in
                         the archive.
  --status <s>           active|closed|archived. Accepted only with --op import.
  --opened <iso8601>     Creation timestamp. Accepted only with --op import.
  --closed-at <iso8601>  Closure timestamp. Accepted only with --op import.
  --kdir <path>          Override the resolved knowledge dir (testing).
  --help, -h             Show this help.
EOF
}

SLUG=""
OP=""
RECORD_DIR=""
KDIR_OVERRIDE=""
TITLE=""; HAS_TITLE=0
ANCHOR=""; HAS_ANCHOR=0
PROJECT=""; HAS_PROJECT=0
CLEAR_PROJECT=0
MEMBER=""; HAS_MEMBER=0
STATUS=""; HAS_STATUS=0
OPENED=""; HAS_OPENED=0
CLOSED_AT=""; HAS_CLOSED_AT=0
WATCHER_SETTINGS=""; HAS_WATCHER_SETTINGS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug) SLUG="${2:-}"; shift 2 ;;
    --op) OP="${2:-}"; shift 2 ;;
    --record-dir) RECORD_DIR="${2:-}"; shift 2 ;;
    --title) TITLE="${2:-}"; HAS_TITLE=1; shift 2 ;;
    --anchor) ANCHOR="${2:-}"; HAS_ANCHOR=1; shift 2 ;;
    --project) PROJECT="${2:-}"; HAS_PROJECT=1; shift 2 ;;
    --clear-project) CLEAR_PROJECT=1; shift ;;
    --member) MEMBER="${2:-}"; HAS_MEMBER=1; shift 2 ;;
    --status) STATUS="${2:-}"; HAS_STATUS=1; shift 2 ;;
    --opened) OPENED="${2:-}"; HAS_OPENED=1; shift 2 ;;
    --closed-at) CLOSED_AT="${2:-}"; HAS_CLOSED_AT=1; shift 2 ;;
    --watcher-settings) WATCHER_SETTINGS="${2:-}"; HAS_WATCHER_SETTINGS=1; shift 2 ;;
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[arc] Error: unknown option '$1'" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$SLUG" ]]; then
  echo "[arc] Error: --slug is required" >&2
  usage
  exit 1
fi
if [[ ! "$SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "[arc] Error: '$SLUG' is not a valid arc slug — use lowercase letters, digits, and hyphens" >&2
  exit 1
fi

case "$OP" in
  open|import|set|watcher-set|close|archive|member-add|member-rm) ;;
  "") echo "[arc] Error: --op is required" >&2; usage; exit 1 ;;
  *) echo "[arc] Error: unknown operation '$OP'" >&2; usage; exit 1 ;;
esac

if [[ -n "$RECORD_DIR" && "$OP" != "import" ]]; then
  echo "[arc] Error: --record-dir is accepted only with --op import" >&2
  exit 1
fi

if [[ $HAS_PROJECT -eq 1 && $CLEAR_PROJECT -eq 1 ]]; then
  echo "[arc] Error: --project and --clear-project are mutually exclusive" >&2
  exit 1
fi
if [[ $HAS_PROJECT -eq 1 && -z "$PROJECT" ]]; then
  echo "[arc] Error: --project cannot be empty — pass --clear-project to remove the label" >&2
  exit 1
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || die "knowledge store not found at: $KNOWLEDGE_DIR"

WORK_DIR="$KNOWLEDGE_DIR/_work"
RECORD_DIR="${RECORD_DIR:-$WORK_DIR/_arcs/$SLUG}"
META_PATH="$RECORD_DIR/_meta.json"

# atomic_write leaves either the previous record or the complete new one; a
# reader never sees a torn write.
atomic_write() {
  # atomic_write <dir> <dest-path> <content>
  local dir="$1" dest="$2" content="$3" tmp
  if ! tmp="$(mktemp "$dir/.tmp._meta.XXXXXX" 2>/dev/null)"; then
    echo "[arc] Error: could not create a temporary file in $dir — the record was left as it was" >&2
    return 1
  fi
  if ! printf '%s\n' "$content" > "$tmp" || ! mv "$tmp" "$dest"; then
    rm -f "$tmp"
    echo "[arc] Error: could not write the record at $dest — the record was left as it was" >&2
    return 1
  fi
}

RECORD=$(
  ARC_OP="$OP" \
  ARC_SLUG="$SLUG" \
  ARC_META_PATH="$META_PATH" \
  ARC_WORK_DIR="$WORK_DIR" \
  ARC_NOW="$(timestamp_iso)" \
  ARC_TITLE="$TITLE" ARC_TITLE_SET="$HAS_TITLE" \
  ARC_ANCHOR="$ANCHOR" ARC_ANCHOR_SET="$HAS_ANCHOR" \
  ARC_PROJECT="$PROJECT" ARC_PROJECT_SET="$HAS_PROJECT" \
  ARC_CLEAR_PROJECT="$CLEAR_PROJECT" \
  ARC_MEMBER="$MEMBER" ARC_MEMBER_SET="$HAS_MEMBER" \
  ARC_STATUS="$STATUS" ARC_STATUS_SET="$HAS_STATUS" \
  ARC_OPENED="$OPENED" ARC_OPENED_SET="$HAS_OPENED" \
  ARC_CLOSED_AT="$CLOSED_AT" ARC_CLOSED_AT_SET="$HAS_CLOSED_AT" \
  ARC_WATCHER_SETTINGS="$WATCHER_SETTINGS" ARC_WATCHER_SETTINGS_SET="$HAS_WATCHER_SETTINGS" \
  python3 - <<'PYEOF'
import json
import os
import sys

env = os.environ
OP = env["ARC_OP"]
SLUG = env["ARC_SLUG"]
META_PATH = env["ARC_META_PATH"]
WORK_DIR = env["ARC_WORK_DIR"]
NOW = env["ARC_NOW"]

STATUSES = ("active", "closed", "archived")
KEY_ORDER = ("schema_version", "slug", "title", "status", "anchor",
             "project", "watcher_settings_path", "members", "opened", "closed_at")


def fail(message):
    sys.stderr.write("[arc] Error: %s\n" % message)
    sys.exit(1)


def warn(message):
    sys.stderr.write("[arc] Warning: %s\n" % message)


def flag(name):
    """Flag value, or None when the caller did not pass the flag at all."""
    return env[name] if env.get(name + "_SET") == "1" else None


title = flag("ARC_TITLE")
anchor = flag("ARC_ANCHOR")
project = flag("ARC_PROJECT")
clear_project = env["ARC_CLEAR_PROJECT"] == "1"
member = flag("ARC_MEMBER")
status = flag("ARC_STATUS")
opened = flag("ARC_OPENED")
closed_at = flag("ARC_CLOSED_AT")
watcher_settings = flag("ARC_WATCHER_SETTINGS")

existing = None
if os.path.exists(META_PATH):
    try:
        with open(META_PATH) as handle:
            existing = json.load(handle)
    except ValueError:
        fail("the record at %s is not valid JSON — repair it before writing" % META_PATH)
    if not isinstance(existing, dict):
        fail("the record at %s is not a JSON object" % META_PATH)

if OP in ("open", "import"):
    if existing is not None:
        if OP == "open":
            fail("an arc named '%s' already exists (%s) — pick a more specific topic, "
                 "or pass --slug to name this one yourself"
                 % (SLUG, existing.get("title") or "untitled"))
        fail("an arc named '%s' already exists — import creates records and never "
             "rewrites them" % SLUG)
else:
    if existing is None:
        fail("no arc named '%s' — expected a record at %s" % (SLUG, META_PATH))
    if existing.get("slug") not in (None, SLUG):
        fail("the record at %s carries slug '%s', not '%s'"
             % (META_PATH, existing.get("slug"), SLUG))

if OP != "import":
    for name, value in (("--status", status), ("--opened", opened), ("--closed-at", closed_at)):
        if value is not None:
            fail("%s is accepted only with --op import" % name)
if OP not in ("open", "import", "set"):
    if title is not None or anchor is not None or project is not None or clear_project:
        fail("--title, --anchor, --project, and --clear-project apply to open, import, "
             "and set — not to %s" % OP)
if OP not in ("member-add", "member-rm") and member is not None:
    fail("--member is accepted only with --op member-add or --op member-rm")
if OP != "watcher-set" and watcher_settings is not None:
    fail("--watcher-settings is accepted only with --op watcher-set")
if OP == "watcher-set" and (watcher_settings is None or not watcher_settings.strip()):
    fail("--op watcher-set requires --watcher-settings")


def resolve_member(slug):
    """Active work item, archived work item, or neither."""
    if not slug or slug != os.path.basename(slug):
        fail("'%s' is not a work-item slug" % slug)
    if os.path.isdir(os.path.join(WORK_DIR, slug)):
        return "active"
    if os.path.isdir(os.path.join(WORK_DIR, "_archive", slug)):
        return "archived"
    return None


if OP in ("open", "import"):
    if not title or not title.strip():
        fail("--title is required by --op %s" % OP)
    if OP == "open" and (not anchor or not anchor.strip()):
        fail("--anchor is required by --op open")
    record = {
        "schema_version": 1,
        "slug": SLUG,
        "title": title,
        "status": "active",
        "anchor": anchor if anchor is not None else "",
        "members": [],
        "opened": NOW,
    }
    if project is not None:
        record["project"] = project
    if OP == "import":
        if status is not None:
            if status not in STATUSES:
                fail("'%s' is not a status — use one of %s" % (status, ", ".join(STATUSES)))
            record["status"] = status
        if opened is not None:
            if not opened.strip():
                fail("--opened cannot be empty")
            record["opened"] = opened
        if closed_at is not None:
            if not closed_at.strip():
                fail("--closed-at cannot be empty")
            record["closed_at"] = closed_at
else:
    record = dict(existing)
    record["schema_version"] = 1
    record["slug"] = SLUG
    if not isinstance(record.get("members"), list):
        record["members"] = []
    current = record.get("status")

    if OP == "set":
        if title is None and anchor is None and project is None and not clear_project:
            fail("set needs at least one of --title, --anchor, --project, --clear-project")
        if title is not None:
            if not title.strip():
                fail("--title cannot be empty")
            record["title"] = title
        if anchor is not None:
            record["anchor"] = anchor
        if project is not None:
            record["project"] = project
        if clear_project:
            record.pop("project", None)
    elif OP == "watcher-set":
        if current != "active":
            fail("arc '%s' is not active; refusing to attach watcher settings" % SLUG)
        record["watcher_settings_path"] = os.path.realpath(watcher_settings)
    elif OP == "close":
        if current == "active":
            record["status"] = "closed"
            record["closed_at"] = NOW
        elif current == "closed":
            warn("arc '%s' is already closed (%s) — leaving the recorded closure in place"
                 % (SLUG, record.get("closed_at") or "closure time unrecorded"))
        elif current == "archived":
            fail("arc '%s' is archived — closing it again is not a transition this "
                 "substrate offers" % SLUG)
        else:
            fail("arc '%s' carries status '%s', which is outside %s"
                 % (SLUG, current, ", ".join(STATUSES)))
    elif OP == "archive":
        if current in ("active", "closed"):
            record["status"] = "archived"
            if not record.get("closed_at"):
                record["closed_at"] = NOW
        elif current == "archived":
            pass
        else:
            fail("arc '%s' carries status '%s', which is outside %s"
                 % (SLUG, current, ", ".join(STATUSES)))
    else:
        if member is None or not member.strip():
            fail("--member is required by --op %s" % OP)
        members = [m for m in record["members"] if isinstance(m, str)]
        if OP == "member-add":
            if resolve_member(member) is None:
                fail("work item '%s' is in neither the active work items nor the archive"
                     % member)
            members.append(member)
        else:
            if member not in members:
                warn("arc '%s' does not list '%s' as a member" % (SLUG, member))
            members = [m for m in members if m != member]
        record["members"] = sorted(set(members))

out = {}
for key in KEY_ORDER:
    if key in record:
        out[key] = record[key]
for key in sorted(record):
    if key not in out:
        out[key] = record[key]

print(json.dumps(out, indent=2))
PYEOF
) || exit 1

if [[ "$OP" == "open" || "$OP" == "import" ]]; then
  mkdir -p "$RECORD_DIR"
fi

CHANGED=true
if [[ -f "$META_PATH" && "$(cat "$META_PATH")" == "$RECORD" ]]; then
  CHANGED=false
else
  atomic_write "$RECORD_DIR" "$META_PATH" "$RECORD" || exit 1
fi

printf '{"changed": %s, "record": %s}\n' "$CHANGED" "$RECORD"
