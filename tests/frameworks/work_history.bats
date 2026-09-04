#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  TEST_ROOT="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_ROOT/knowledge"
  export PYTHONPATH="$REPO_DIR/scripts"
  bash "$REPO_DIR/tests/fixtures/retrieval/build_store.sh" "$LORE_KNOWLEDGE_DIR"
  mkdir -p "$TEST_ROOT/bin"
  python3 - "$REPO_DIR" "$TEST_ROOT/bin/lore" <<'PY'
from pathlib import Path
import sys
root, target = sys.argv[1:]
s = (Path(root) / 'cli/lore').read_text()
s = '\n'.join('SCRIPTS_DIR=' + repr(root + '/scripts') if line.startswith('SCRIPTS_DIR=') else line for line in s.splitlines()) + '\n'
Path(target).write_text(s)
Path(target).chmod(0o755)
PY
  export PATH="$TEST_ROOT/bin:$PATH"
  cd "$TEST_ROOT"
  mv "$LORE_KNOWLEDGE_DIR/_work/fixture-item" "$TEST_ROOT/fixture-item"
  lore work create --title 'Widget pipeline consolidation' --slug fixture-item >/dev/null
  cp "$TEST_ROOT/fixture-item/plan.md" "$TEST_ROOT/fixture-item/notes.md" "$TEST_ROOT/fixture-item/tasks.json" "$LORE_KNOWLEDGE_DIR/_work/fixture-item/"
  lore work create --title 'Archived widget design' >/dev/null
  cat > "$LORE_KNOWLEDGE_DIR/_work/archived-widget-design/plan.md" <<'PLAN'
# Archived widget design

## Intent Anchor
Keep widget changes attributable.

## Design Decisions
### Cache ownership
HISTORY_DESIGN_MARKER: `scripts/widget.sh` owns invalidation because intake observes rewrites.

```markdown
## This is a code example
```

## Tasks
TASK_ONLY_MARKER: `scripts/tasks-only.sh` changes next.
PLAN
  lore work archive archived-widget-design >/dev/null
  cat > "$LORE_KNOWLEDGE_DIR/architecture/widget-theory.md" <<'THEORY'
# Widget state theory
Widget state owns invalidation.
<!-- learned: 2026-09-04 | confidence: high | scale: subsystem | kind: theory | subsystem: widget state | related_files: scripts/widget.sh -->
THEORY
  lore work note fixture-item --text 'HISTORY_NOTE_MARKER: widget state uses a single invalidation owner because intake sees rewrites.' >/dev/null
}

teardown() {
  rm -rf "$TEST_ROOT"
}

@test "why finds archived design by file with section pointer and status" {
  run lore why scripts/widget.sh:12 --limit 20
  [ "$status" -eq 0 ]
  [[ "$output" == *'### From the record'* ]]
  [[ "$output" == *'Archived widget design'*'(archived)'* ]]
  [[ "$output" == *'[[work:archived-widget-design]] — plan.md > Archived widget design / Design Decisions / Cache ownership'* ]]
  [[ "$output" == *'HISTORY_DESIGN_MARKER'* ]]
  run lore why scripts/tasks-only.sh
  [ "$status" -eq 0 ]
  [[ "$output" != *'TASK_ONLY_MARKER'* ]]
  [[ "$output" != *'### From the record'* ]]
}

@test "why finds active notes by subsystem and tradeoffs matches topics" {
  run lore why scripts/widget.sh --json --limit 20
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
rows = [r for r in json.load(sys.stdin) if r.get("source_type") == "work-history"]
assert any(r["status"] == "active" and "HISTORY_NOTE_MARKER" in r["content"] for r in rows)
assert [r["date"] for r in rows] == sorted([r["date"] for r in rows], reverse=True)
'
  run lore tradeoffs 'invalidation owner' --scale-set subsystem --limit 20
  [ "$status" -eq 0 ]
  [[ "$output" == *'### From the record'*'HISTORY_NOTE_MARKER'* ]]
}

@test "history reads never rebuild and healing updates edited and deleted sections" {
  python3 - "$LORE_KNOWLEDGE_DIR" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]) / '_work/_archive/archived-widget-design/plan.md'
p.write_text(p.read_text().replace('HISTORY_DESIGN_MARKER', 'CHANGED_DESIGN_MARKER'))
PY
  lore work list >/dev/null
  bash "$REPO_DIR/scripts/load-work.sh" >/dev/null
  run lore why scripts/widget.sh --limit 20
  [ "$status" -eq 0 ]
  [[ "$output" == *'HISTORY_DESIGN_MARKER'* ]]
  [[ "$output" != *'CHANGED_DESIGN_MARKER'* ]]
  run lore tradeoffs 'invalidation' --scale-set subsystem --limit 20 --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
rows = [r for r in json.load(sys.stdin) if r.get("source_type") == "work-history"]
assert any("HISTORY_DESIGN_MARKER" in r["content"] for r in rows)
assert all("CHANGED_DESIGN_MARKER" not in r["content"] for r in rows)
'
  lore work heal >/dev/null
  run lore why scripts/widget.sh --limit 20
  [ "$status" -eq 0 ]
  [[ "$output" == *'CHANGED_DESIGN_MARKER'* ]]
  rm "$LORE_KNOWLEDGE_DIR/_work/_archive/archived-widget-design/plan.md"
  lore work heal >/dev/null
  run lore why scripts/widget.sh --limit 20
  [ "$status" -eq 0 ]
  [[ "$output" != *'CHANGED_DESIGN_MARKER'* ]]
}

@test "incremental rebuild is a no-op for unchanged sources and follows unarchive" {
  run python3 "$REPO_DIR/scripts/pk_work_history.py" "$LORE_KNOWLEDGE_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"files_indexed": 0, "files_removed": 0'* ]]
  lore work unarchive archived-widget-design >/dev/null
  run lore why scripts/widget.sh --json --limit 20
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
rows = [r for r in json.load(sys.stdin) if r.get("slug") == "archived-widget-design"]
assert rows and all(r["status"] == "active" for r in rows)
assert all("_archive" not in r["file_path"] for r in rows)
'
}

@test "regen-tasks indexes design and rationale siblings" {
  cat > "$LORE_KNOWLEDGE_DIR/_work/fixture-item/design.md" <<'DESIGN'
# Storage design
## Owner
SIBLING_DESIGN_MARKER: `scripts/sibling.sh` stores versions.
DESIGN
  cat > "$LORE_KNOWLEDGE_DIR/_work/fixture-item/rationale-storage.md" <<'RATIONALE'
# Storage rationale
SIBLING_RATIONALE_MARKER: related_files: scripts/sibling.sh
RATIONALE
  lore work regen-tasks fixture-item --quiet >/dev/null
  run lore why scripts/sibling.sh --limit 20
  [ "$status" -eq 0 ]
  [[ "$output" == *'SIBLING_DESIGN_MARKER'* ]]
  [[ "$output" == *'SIBLING_RATIONALE_MARKER'* ]]
}

@test "history stays absent from prefetch manifests and session-start output" {
  for surface in prompt summary load manifest1 manifest2; do
    case "$surface" in
      prompt|summary) command=(lore prefetch 'widget invalidation' --scale-set subsystem --format "$surface") ;;
      load) command=(bash "$REPO_DIR/scripts/load-knowledge.sh") ;;
      manifest1) command=(bash "$REPO_DIR/scripts/resolve-manifest.sh" fixture-item 1) ;;
      manifest2) command=(bash "$REPO_DIR/scripts/resolve-manifest.sh" fixture-item 2) ;;
    esac
    run "${command[@]}"
    [ "$status" -eq 0 ]
    [[ "$output" != *'From the record'* ]]
    [[ "$output" != *'HISTORY_DESIGN_MARKER'* ]]
    [[ "$output" != *'HISTORY_NOTE_MARKER'* ]]
  done
}

@test "convention history pointer requires both work item and related file on all surfaces" {
  python3 - "$LORE_KNOWLEDGE_DIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
p = root / 'conventions/widget-naming.md'
s = p.read_text()
p.write_text(s.replace(' -->', ' | producer_role: worker | work_item: fixture-item -->'))
PY
  for surface in search prompt summary load manifest; do
    case "$surface" in
      search) command=(lore search 'widget naming' --type knowledge --scale-set subsystem) ;;
      prompt|summary) command=(lore prefetch 'widget naming' --scale-set subsystem --format "$surface") ;;
      load) command=(bash "$REPO_DIR/scripts/load-knowledge.sh") ;;
      manifest) command=(bash "$REPO_DIR/scripts/resolve-manifest.sh" fixture-item 1) ;;
    esac
    run "${command[@]}"
    [ "$status" -eq 0 ]
    [[ "$output" == *'history: lore why scripts/widget.sh'* ]]
    [[ "$output" != *'From the record'* ]]
  done
  run python3 - "$LORE_KNOWLEDGE_DIR" <<'PY'
from pathlib import Path
import sys
from pk_byline import Bylines
root = Path(sys.argv[1])
p = root / 'conventions/widget-naming.md'
original = p.read_text()
b = Bylines(root)
entry = {'file_path': str(p)}
assert '\nhistory: lore why scripts/widget.sh' in b.lines(entry)
for omitted in (' | work_item: fixture-item', ' | related_files: scripts/widget.sh'):
    p.write_text(original.replace(omitted, ''))
    assert 'history:' not in b.lines(entry)
p.write_text(original.replace('related_files: scripts/widget.sh', 'related_files: scripts/first.sh, scripts/second.sh'))
assert b.lines(entry).endswith('history: lore why scripts/first.sh')
assert 'history:' not in b.lines({'file_path': 'architecture/widget-theory.md'})
PY
  [ "$status" -eq 0 ]
}

@test "missing history remains missing on read and knowledge rebuilds preserve it" {
  run python3 - "$LORE_KNOWLEDGE_DIR" "$TEST_ROOT/empty" <<'PY'
from pathlib import Path
import sqlite3, sys
from pk_search import Indexer
from pk_work_history import lookup
root, empty = map(Path, sys.argv[1:])
empty.mkdir()
assert lookup(empty, location='scripts/widget.sh') == []
assert list(empty.iterdir()) == []
assert lookup(root, location='scripts/widget.sh')
assert 'error' not in Indexer(str(root)).index_all(force=True)
assert lookup(root, location='scripts/widget.sh')
with sqlite3.connect(root / '.pk_search.db') as conn:
    assert not conn.execute("SELECT 1 FROM entries WHERE source_type = 'work-history'").fetchone()
PY
  [ "$status" -eq 0 ]
}
