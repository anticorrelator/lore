#!/usr/bin/env bash
# regen-tasks.sh — Regenerate tasks.json from plan.md for a work item
# Usage: bash regen-tasks.sh <slug> [--quiet]
# Calls generate-tasks.py, writes tasks.json, then heals the work index.
# --quiet: suppress per-phase diagnostics output (for scripted usage)

set -euo pipefail

QUIET=false
INSTALL_REVISION=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet) QUIET=true; shift ;;
    --install-revision) INSTALL_REVISION="$2"; shift 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

if [[ ${#POSITIONAL[@]} -lt 1 ]]; then
  echo "[work] Error: Missing work item slug." >&2
  echo "Usage: regen-tasks.sh <slug> [--quiet]" >&2
  exit 1
fi

SLUG="${POSITIONAL[0]}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_ITEM_DIR="$KNOWLEDGE_DIR/_work/$SLUG"
PLAN_FILE="$WORK_ITEM_DIR/plan.md"
TASKS_FILE="$WORK_ITEM_DIR/tasks.json"

if [[ ! -d "$WORK_ITEM_DIR" ]]; then
  echo "[work] Error: Work item not found: $SLUG" >&2
  exit 1
fi

if [[ ! -f "$PLAN_FILE" ]]; then
  echo "[work] Error: No plan.md found for: $SLUG" >&2
  echo "Run /spec first to create a plan." >&2
  exit 1
fi

if [[ -z "$INSTALL_REVISION" && -e "$WORK_ITEM_DIR/revisions.jsonl" ]]; then
  exec bash "$SCRIPT_DIR/plan-revise.sh" "$SLUG" --reason "record authored plan state"
fi

if [[ -n "$INSTALL_REVISION" ]]; then
  OUTPUT=$(python3 - "$WORK_ITEM_DIR" "$INSTALL_REVISION" <<'PYINSTALL'
import fcntl, hashlib, json, os, pathlib, sys
item = pathlib.Path(sys.argv[1])
fd = int(os.environ.get('LORE_PLAN_PUBLICATION_LOCK_FD', '-1'))
try:
    if os.fstat(fd).st_ino != os.stat(item / 'revisions/.publication.lock').st_ino:
        raise ValueError('publication lock descriptor mismatch')
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except (OSError, ValueError):
    sys.exit('revision task installation requires the publication lock')
rows = [json.loads(line) for line in (item / 'revisions.jsonl').read_text().splitlines()]
head = next(r for r in reversed(rows) if r.get('record_type', 'revision') == 'revision')
if head['revision_id'] != sys.argv[2]:
    sys.exit('only the committed head can replace live tasks')
source = (item / head['tasks_path']).resolve()
if not source.is_relative_to(item.resolve()):
    sys.exit('snapshot outside item')
raw = source.read_bytes()
if hashlib.sha256(raw).hexdigest() != head['tasks_sha256']:
    sys.exit('committed task snapshot digest mismatch')
if json.loads(raw).get('revision_id') != head['revision_id']:
    sys.exit('committed task snapshot revision mismatch')
temporary = item / '.tasks.json.publish'
with open(temporary, 'wb') as stream:
    stream.write(raw)
    stream.flush()
    os.fsync(stream.fileno())
os.replace(temporary, item / 'tasks.json')
directory = os.open(item, os.O_RDONLY)
try:
    os.fsync(directory)
finally:
    os.close(directory)
sys.stdout.write(raw.decode())
PYINSTALL
  )
else
  GENERATOR_ARGS=("$PLAN_FILE" --knowledge-dir "$KNOWLEDGE_DIR" --slug "$SLUG")
  $QUIET || GENERATOR_ARGS+=(--diagnostics)
  OUTPUT=$(python3 "$SCRIPT_DIR/generate-tasks.py" "${GENERATOR_ARGS[@]}")
  printf '%s\n' "$OUTPUT" > "$TASKS_FILE.tmp"
  mv "$TASKS_FILE.tmp" "$TASKS_FILE"
fi

# Summarize the generated JSON. tasks[] is authoritative when present; a
# document carrying only phases[] is summarized through the fallback.
SUMMARY=$(echo "$OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
tasks = d.get('tasks')
if isinstance(tasks, list):
    print(len(tasks), 'tasks')
elif isinstance(d.get('phases'), list):
    phases = d['phases']
    print(sum(len(p['tasks']) for p in phases), 'tasks across', len(phases), 'phases')
else:
    sys.exit('[work] Error: generated tasks.json carries neither tasks[] nor phases[]')
print(d['plan_checksum'][:8])
") || exit 1
CHECKSUM=$(echo "$SUMMARY" | tail -1)

echo "[work] Regenerated $(echo "$SUMMARY" | head -1). New checksum: $CHECKSUM"

# Update _meta.json timestamp
update_meta_timestamp "$WORK_ITEM_DIR"

# Update work index unconditionally so _index.json mtime always changes.
# heal-work.sh only rebuilds _index.json when item count changes, which means
# the TUI (which polls _index.json mtime to detect changes) would miss a
# tasks.json appearing for an existing item and keep showing "needs tasks".
bash "$SCRIPT_DIR/update-work-index.sh" >/dev/null

python3 "$SCRIPT_DIR/pk_work_history.py" "$KNOWLEDGE_DIR" >/dev/null || true
