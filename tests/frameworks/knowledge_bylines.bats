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
  bash "$REPO_DIR/scripts/update-work-index.sh" >/dev/null
}

teardown() {
  rm -rf "$TEST_ROOT"
}

stamp() {
  python3 - "$LORE_KNOWLEDGE_DIR" "${1:-fixture-item}" <<'PY'
from pathlib import Path
import datetime, sys
root, work = sys.argv[1:]
p = Path(root) / 'conventions/widget-naming.md'
s = p.read_text().replace('2025-02-20', datetime.date.today().isoformat())
p.write_text(s.replace(' -->', f' | producer_role: worker | work_item: {work} -->'))
PY
}

@test "search puts role title and age below the entry heading" {
  stamp
  run lore search 'widget naming' --type knowledge --scale-set subsystem --limit 10
  [ "$status" -eq 0 ]
  [[ "$output" == *$'Heading: Widget Naming\n  captured by a worker during "Widget pipeline consolidation", today'* ]]
}

@test "all entry surfaces omit absent provenance and unresolved work titles" {
  for surface in search prompt summary load manifest; do
    case "$surface" in
      search) command=(lore search 'widget naming' --type knowledge --scale-set subsystem) ;;
      prompt|summary) command=(lore prefetch 'widget naming' --scale-set subsystem --format "$surface") ;;
      load) command=(bash "$REPO_DIR/scripts/load-knowledge.sh") ;;
      manifest) command=(bash "$REPO_DIR/scripts/resolve-manifest.sh" fixture-item 1) ;;
    esac
    run "${command[@]}"
    [ "$status" -eq 0 ]
    [[ "$output" != *'captured by'* ]]
  done
  stamp missing-work
  for surface in search prompt summary load manifest; do
    case "$surface" in
      search) command=(lore search 'widget naming' --type knowledge --scale-set subsystem) ;;
      prompt|summary) command=(lore prefetch 'widget naming' --scale-set subsystem --format "$surface") ;;
      load) command=(bash "$REPO_DIR/scripts/load-knowledge.sh") ;;
      manifest) command=(bash "$REPO_DIR/scripts/resolve-manifest.sh" fixture-item 1) ;;
    esac
    run "${command[@]}"
    [ "$status" -eq 0 ]
    [[ "$output" == *'captured by a worker, today'* ]]
    [[ "$output" != *'during "missing-work"'* ]]
  done
}

@test "prefetch and both prior knowledge manifest formats include the byline" {
  stamp
  for format in prompt summary; do
    run lore prefetch 'widget naming' --scale-set subsystem --format "$format"
    [ "$status" -eq 0 ]
    [[ "$output" == *'captured by a worker during "Widget pipeline consolidation", today'* ]]
  done
  for phase in 1 2; do
    run bash "$REPO_DIR/scripts/resolve-manifest.sh" fixture-item "$phase"
    [ "$status" -eq 0 ]
    [[ "$output" == *'captured by a worker during "Widget pipeline consolidation", today'* ]]
  done
}

@test "session loading includes bylines for direct and ranked entries" {
  stamp
  run bash "$REPO_DIR/scripts/load-knowledge.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'# Widget Naming\ncaptured by a worker during "Widget pipeline consolidation", today'* ]]
  sed -i.bak '/See \[\[knowledge:/d' "$LORE_KNOWLEDGE_DIR/_work/fixture-item/notes.md"
  run bash "$REPO_DIR/scripts/load-knowledge.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'# Widget Naming\ncaptured by a worker during "Widget pipeline consolidation", today'* ]]
}

@test "correction writes and renders separate attribution without replacing capture" {
  stamp
  run bash "$REPO_DIR/scripts/apply-correction.sh" \
    --entry "$LORE_KNOWLEDGE_DIR/conventions/widget-naming.md" \
    --allow-peer-verification --verdict-source peer-verification \
    --verdict-id byline-test --observation-id byline-test \
    --reported-by reviewer --work-item fixture-item \
    --evidence 'fixture review' --superseded-text 'kebab-case slugs' --replacement-text 'stable slugs'
  [ "$status" -eq 0 ]
  run lore search 'widget naming' --type knowledge --scale-set subsystem
  [ "$status" -eq 0 ]
  [[ "$output" == *'captured by a worker during "Widget pipeline consolidation", today'* ]]
  [[ "$output" == *'corrected by a reviewer during "Widget pipeline consolidation", today'* ]]
}

@test "kind sections and degraded entry blocks retain bylines" {
  stamp
  run python3 - "$LORE_KNOWLEDGE_DIR" <<'PY'
import sys
from pk_byline import Bylines
from pk_kinds import _Renderer
from pk_manifest import _entry_full_block, _entry_snippet_block, _entry_backlink_block
entry = {'file_path': 'conventions/widget-naming.md', 'heading': 'Widget Naming', 'snippet': 'widget', 'kind': 'hypothesis', 'kind_status': 'untested'}
bylines = Bylines(sys.argv[1])
renderer = _Renderer(sys.argv[1])
for fn in (renderer.full, renderer.snippet, renderer.backlink):
    assert 'captured by a worker during "Widget pipeline consolidation", today' in fn(entry)
for fn in (_entry_full_block, _entry_snippet_block, _entry_backlink_block):
    assert 'captured by a worker during "Widget pipeline consolidation", today' in fn(entry, bylines)
PY
  [ "$status" -eq 0 ]
}

@test "bylines handle partial provenance dates and model-like roles" {
  run python3 - "$LORE_KNOWLEDGE_DIR" <<'PY'
import datetime, sys
from pk_byline import Bylines, _metadata
b = Bylines(sys.argv[1])
today = datetime.date.today()
assert b._line('captured', 'worker', None, (today-datetime.timedelta(days=12)).isoformat()) == 'captured by a worker, 12 days ago'
assert b._line('captured', 'worker', None, (today-datetime.timedelta(days=1)).isoformat()) == 'captured by a worker, 1 day ago'
assert b._line('captured', 'worker', None, None) == 'captured by a worker'
assert b._line('captured', None, None, today.isoformat()) == ''
assert b._line('captured', 'gpt-6-astra', 'missing', None) == ''
assert b._line('captured', None, 'fixture-item', None) == 'captured during "Widget pipeline consolidation"'
assert _metadata('<!-- learned: today | corrections: [{"evidence":"a | b"}] | work_item: ok -->')['work_item'] == 'ok'
PY
  [ "$status" -eq 0 ]
}

@test "session budget includes the byline before choosing full entries" {
  stamp
  run python3 - "$LORE_KNOWLEDGE_DIR" <<'PYTEST'
import sys
from pk_byline import Bylines
b = Bylines(sys.argv[1])
entry = {'file_path': 'conventions/widget-naming.md', 'heading': 'Widget Naming', 'content': '# Widget Naming\nBody'}
small = b.budget({'full': [entry], 'titles_only': [], 'budget_total': len(entry['content'])})
assert small['full'] == []
assert small['titles_only'][0]['heading'] == 'Widget Naming'
large = b.budget({'full': [entry], 'titles_only': [], 'budget_total': 1000})
assert 'captured by a worker' in large['full'][0]['content']
assert large['budget_used'] == len(large['full'][0]['content'])
PYTEST
  [ "$status" -eq 0 ]
}
