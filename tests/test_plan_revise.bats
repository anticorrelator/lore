#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
REVISE="$REPO_DIR/scripts/plan-revise.sh"

setup() {
  export LORE_KNOWLEDGE_DIR="$(mktemp -d)"
  export LORE_DATA_DIR="$(mktemp -d)"
  export LORE_FRAMEWORK=claude-code
  ITEM="$LORE_KNOWLEDGE_DIR/_work/revision-fixture"
  mkdir -p "$ITEM"
  printf '%s\n' '{"title":"Revision Fixture","status":"active","intent_anchor":"Keep the intended behavior."}' > "$ITEM/_meta.json"
  cat > "$ITEM/plan.md" <<'EOF'
# Revision fixture

## Intent Anchor
Keep the intended behavior.

**Scope delta:** none

## Tasks

**Merge rationale:** One related feature.

### Task 1: Build alpha
**Deliverable:** Alpha module.
**Files:** `src/alpha.py`
**Close criteria:**
```json
[{"id":"alpha-check","intent":"Alpha works","argv":["python3","-c","print('alpha')"],"cwd":".","timeout":10,"expected_exit":0}]
```
- [ ] Build alpha [class: mechanical]

### Task 2: Build beta
**Deliverable:** Beta module.
**Files:** `src/beta.py`
- [ ] Build beta [class: mechanical] [depends-on: task-1]
EOF
  cat > "$ITEM/decisions.json" <<'EOF'
{"anchor_coverage":{"disposition":"covered","by":"designer","note":"Both tasks implement the anchor."},"review_requirement":{"disposition":"pending","by":"designer","note":"Review scope is still being considered."},"dispatch_decision":{"disposition":"proceed","by":"coordinator","note":"Proceed while the review judgment is outstanding.","task_ids":["task-1","task-2"],"prior_review_refs":[]}}
EOF
  cd "$REPO_DIR"
}

teardown() {
  rm -rf "$LORE_KNOWLEDGE_DIR" "$LORE_DATA_DIR"
  unset LORE_KNOWLEDGE_DIR LORE_DATA_DIR LORE_FRAMEWORK LORE_PLAN_REVISE_FAIL_AT
}

revise() { bash "$REVISE" revision-fixture "$@"; }
adopt() { revise --decisions "$ITEM/decisions.json"; }
head_id() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision_id"])' "$ITEM/tasks.json"; }
row_count() { wc -l < "$ITEM/revisions.jsonl" | tr -d ' '; }
projection() { python3 "$REPO_DIR/scripts/work-evidence.py" --item-dir "$ITEM" --knowledge-dir "$LORE_KNOWLEDGE_DIR"; }
replace_plan() {
  python3 - "$ITEM/plan.md" "$1" "$2" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text(p.read_text().replace(sys.argv[2],sys.argv[3]))
PY
}

@test "first adoption records full immutable task and plan snapshots with pending authored decisions" {
  run revise
  [ "$status" -eq 0 ]
  [ "$(row_count)" = 1 ]
  run python3 - "$ITEM" <<'PY'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); r=json.loads((p/'revisions.jsonl').read_text())
assert r['kind']=='semantic' and r['predecessor'] is None
assert r['anchor_coverage']['disposition']=='pending'
assert r['dispatch_decision'] is None
for kind in ('plan','tasks'):
    assert hashlib.sha256((p/r[kind+'_path']).read_bytes()).hexdigest()==r[kind+'_sha256']
t=json.loads((p/'tasks.json').read_text())
assert t['revision_id']==r['revision_id']
assert t['tasks'][0]['close_criteria'][0]['criterion_version']
assert 'alpha-check' in t['tasks'][0]['description']
PY
  [ "$status" -eq 0 ]
  run projection
  [ "$status" -eq 0 ]
  [[ "$output" == *'"publication_state":"current"'* ]]
}

@test "unchanged regeneration preserves exact tasks bytes and one deterministic revision" {
  adopt
  cp "$ITEM/tasks.json" "$ITEM/expected-tasks"
  before="$(head_id)"
  run bash "$REPO_DIR/scripts/regen-tasks.sh" revision-fixture --quiet
  [ "$status" -eq 0 ]
  [ "$(row_count)" = 1 ]
  [ "$(head_id)" = "$before" ]
  cmp "$ITEM/tasks.json" "$ITEM/expected-tasks"
}

@test "checkbox publication is progress and inherits the prior authored decision" {
  adopt
  before="$(head_id)"
  run bash "$REPO_DIR/scripts/update-plan-checkbox.sh" revision-fixture 'Build alpha'
  [ "$status" -eq 0 ]
  [ "$(row_count)" = 2 ]
  run python3 - "$ITEM" "$before" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);r=json.loads((p/'revisions.jsonl').read_text().splitlines()[-1])
assert r['kind']=='progress'
assert r['inherited_from_revision']==sys.argv[2]
assert r['dispatch_decision']['disposition']=='proceed'
assert len(json.loads((p/'tasks.json').read_text())['tasks'])==2
PY
  [ "$status" -eq 0 ]
}

@test "semantic criterion changes cannot be labeled progress and get a new criterion identity" {
  adopt
  replace_plan "print('alpha')" "print('changed')"
  run revise --kind progress
  [ "$status" -ne 0 ]
  [[ "$output" == *'semantic plan bytes'* ]]
  [ "$(row_count)" = 1 ]
  run revise
  [ "$status" -eq 0 ]
  run python3 - "$ITEM" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);rows=[json.loads(x) for x in (p/'revisions.jsonl').read_text().splitlines()]
a,b=[json.loads((p/r['tasks_path']).read_text()) for r in rows]
assert a['tasks'][0]['close_criteria'][0]['criterion_version']!=b['tasks'][0]['close_criteria'][0]['criterion_version']
assert rows[-1]['change_categories']['criterion']==['task-1']
assert rows[-1]['anchor_coverage']['disposition']=='pending'
PY
  [ "$status" -eq 0 ]
}

@test "authoritative task heading IDs survive changed task subjects" {
  adopt
  replace_plan 'Build alpha' 'Rename alpha'
  run revise
  [ "$status" -eq 0 ]
  run python3 - "$ITEM/tasks.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); assert x['tasks'][0]['id']=='task-1'
assert x['tasks'][1]['blockedBy']==['task-1']
PY
  [ "$status" -eq 0 ]
}

@test "structural anchor refusal preserves prior committed generation" {
  adopt
  before="$(head_id)"
  replace_plan 'Keep the intended behavior.' 'Different anchor.'
  run revise
  [ "$status" -ne 0 ]
  [[ "$output" == *'body diverges'* ]]
  [ "$(head_id)" = "$before" ]
  [ "$(row_count)" = 1 ]
}

@test "missing and cyclic dependencies are rejected before commit" {
  replace_plan '[depends-on: task-1]' '[depends-on: task-99]'
  run revise
  [ "$status" -ne 0 ]
  [ ! -e "$ITEM/revisions.jsonl" ]
  replace_plan '[depends-on: task-99]' '[depends-on: task-1]'
  replace_plan 'Build alpha [class: mechanical]' 'Build alpha [class: mechanical] [depends-on: task-2]'
  run revise
  [ "$status" -ne 0 ]
  [ ! -e "$ITEM/revisions.jsonl" ]
}

@test "retry after staging publishes exactly one revision" {
  export LORE_PLAN_REVISE_FAIL_AT=after-staging
  run revise
  [ "$status" -ne 0 ]
  [ ! -e "$ITEM/revisions.jsonl" ]
  unset LORE_PLAN_REVISE_FAIL_AT
  run revise
  [ "$status" -eq 0 ]
  [ "$(row_count)" = 1 ]
  run projection
  [[ "$output" == *'"publication_state":"current"'* ]]
}

@test "retry after partial snapshot creation reuses immutable generation time" {
  export LORE_PLAN_REVISE_FAIL_AT=after-plan-snapshot
  run revise
  [ "$status" -ne 0 ]
  [ ! -e "$ITEM/revisions.jsonl" ]
  unset LORE_PLAN_REVISE_FAIL_AT
  run revise
  [ "$status" -eq 0 ]
  [ "$(row_count)" = 1 ]
}

@test "retry after ledger commit repairs projection without another revision" {
  export LORE_PLAN_REVISE_FAIL_AT=after-ledger
  run revise
  [ "$status" -ne 0 ]
  [ "$(row_count)" = 1 ]
  [ ! -e "$ITEM/tasks.json" ]
  run projection
  [[ "$output" == *'"publication_state":"incomplete"'* ]]
  unset LORE_PLAN_REVISE_FAIL_AT
  run revise --reconcile
  [ "$status" -eq 0 ]
  [ "$(row_count)" = 1 ]
  run projection
  [[ "$output" == *'"publication_state":"current"'* ]]
}

@test "failure before task replacement cannot dispatch the old generation" {
  adopt
  before="$(head_id)"
  replace_plan "print('alpha')" "print('changed')"
  export LORE_PLAN_REVISE_FAIL_AT=before-tasks
  run revise
  [ "$status" -ne 0 ]
  [ "$(head_id)" = "$before" ]
  [ "$(row_count)" = 2 ]
  run bash "$REPO_DIR/scripts/load-tasks.sh" revision-fixture
  [ "$status" -ne 0 ]
  [[ "$output" == *'incomplete revision publication'* ]]
  unset LORE_PLAN_REVISE_FAIL_AT
  run revise --reconcile
  [ "$status" -eq 0 ]
  [ "$(row_count)" = 2 ]
}

@test "competing predecessor updates cannot fork a committed predecessor" {
  adopt
  before="$(head_id)"
  replace_plan "print('alpha')" "print('second')"
  revise --expected-predecessor "$before"
  replace_plan "print('second')" "print('third')"
  run revise --expected-predecessor "$before"
  [ "$status" -ne 0 ]
  [[ "$output" == *'competing predecessor'* ]]
  [ "$(row_count)" = 2 ]
}

@test "decision replay is immutable and never changes revision head" {
  revise
  before="$(head_id)"
  revise --decision-for "$before" --decision-id dispatch-1 --decisions "$ITEM/decisions.json"
  revise --decision-for "$before" --decision-id dispatch-1 --decisions "$ITEM/decisions.json"
  [ "$(row_count)" = 2 ]
  [ "$(head_id)" = "$before" ]
  run python3 - "$REPO_DIR/scripts/work-evidence.py" "$ITEM" "$LORE_KNOWLEDGE_DIR" <<'PY'
import runpy,sys
x=runpy.run_path(sys.argv[1])['publication_for_dispatch'](sys.argv[2],sys.argv[3])
assert x['blocked']=={},x
PY
  [ "$status" -eq 0 ]
  run revise --decision-for 000000000000 --decision-id invalid --decisions "$ITEM/decisions.json"
  [ "$status" -ne 0 ]
}

@test "loader and common reader never regenerate drifted tasks" {
  adopt
  cp "$ITEM/tasks.json" "$ITEM/expected-tasks"
  replace_plan "print('alpha')" "print('drift')"
  run bash "$REPO_DIR/scripts/load-tasks.sh" revision-fixture
  [ "$status" -ne 0 ]
  run projection
  [ "$status" -eq 0 ]
  cmp "$ITEM/tasks.json" "$ITEM/expected-tasks"
  [ "$(row_count)" = 1 ]
}

@test "open reconciles drift then reports the exact pending authored decision" {
  adopt
  replace_plan "print('alpha')" "print('drift')"
  run bash "$REPO_DIR/scripts/impl-open.sh" revision-fixture --all --json
  [ "$status" -ne 0 ]
  [[ "$output" == *'pending anchor coverage decision'* ]]
  [ "$(row_count)" = 2 ]
  run projection
  [[ "$output" == *'"publication_state":"current"'* ]]
}

@test "torn commit tail recovers only from a unique durable transaction intent" {
  adopt
  python3 - "$ITEM/revisions.jsonl" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);p.write_bytes(p.read_bytes()[:-15])
PY
  run projection
  [[ "$output" == *'"publication_state":"incomplete"'* ]]
  run revise --reconcile
  [ "$status" -eq 0 ]
  [ "$(row_count)" = 1 ]
  printf '{"unprovable"' >> "$ITEM/revisions.jsonl"
  run revise --reconcile
  [ "$status" -ne 0 ]
  [[ "$output" == *'no unique staged transaction'* ]]
}

@test "pending task decisions survive an unrelated later semantic revision" {
  adopt
  replace_plan "print('alpha')" "print('pending-alpha')"
  revise
  alpha_revision="$(head_id)"
  replace_plan 'Beta module.' 'A changed beta output.'
  revise
  run python3 - "$REPO_DIR/scripts/work-evidence.py" "$ITEM" "$LORE_KNOWLEDGE_DIR" "$alpha_revision" <<'PY'
import runpy,sys
x=runpy.run_path(sys.argv[1])['project'](sys.argv[2],sys.argv[3])['revision']['dispatch']
assert x['schema_version']==1 and x['state']=='read',x
assert set(x['blocked'])=={'task-1','task-2'},x
assert x['tasks']['task-1']['coverage_revision_id']==sys.argv[4],x
PY
  [ "$status" -eq 0 ]
}

@test "subset dispatch decisions compose and survive progress without replacing other tasks" {
  revise
  before="$(head_id)"
  python3 - "$ITEM" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); d=json.loads((p/'decisions.json').read_text())
d['dispatch_decision']['task_ids']=['task-1'];(p/'alpha.json').write_text(json.dumps(d))
d={'dispatch_decision':{'disposition':'wait','by':'coordinator','note':'Beta is waiting.','task_ids':['task-2']}}
(p/'beta.json').write_text(json.dumps(d))
PY
  revise --decision-for "$before" --decision-id alpha --decisions "$ITEM/alpha.json"
  revise --decision-for "$before" --decision-id beta --decisions "$ITEM/beta.json"
  run bash "$REPO_DIR/scripts/update-plan-checkbox.sh" revision-fixture 'Build alpha'
  [ "$status" -eq 0 ]
  run python3 - "$REPO_DIR/scripts/work-evidence.py" "$ITEM" "$LORE_KNOWLEDGE_DIR" "$before" <<'PY'
import runpy,sys
x=runpy.run_path(sys.argv[1])['project'](sys.argv[2],sys.argv[3])['revision']['dispatch']
assert x['blocked']=={'task-2':'authored dispatch decision is wait'},x
assert x['tasks']['task-1']['dispatch']['disposition']=='proceed'
assert x['tasks']['task-1']['dispatch_revision_id']==sys.argv[4]
assert x['tasks']['task-2']['dispatch']['disposition']=='wait'
PY
  [ "$status" -eq 0 ]
}

@test "recovering an older commit preserves newer authored plan bytes" {
  adopt
  replace_plan "print('alpha')" "print('second')"
  export LORE_PLAN_REVISE_FAIL_AT=after-ledger
  run revise
  [ "$status" -ne 0 ]
  unset LORE_PLAN_REVISE_FAIL_AT
  replace_plan "print('second')" "print('third')"
  cp "$ITEM/plan.md" "$ITEM/expected-plan"
  run revise --reconcile
  [ "$status" -eq 0 ]
  cmp "$ITEM/plan.md" "$ITEM/expected-plan"
  [ "$(row_count)" = 3 ]
  run projection
  [[ "$output" == *'"publication_state":"current"'* ]]
}

@test "parallel exact retries serialize to one predecessor and one revision" {
  revise > "$ITEM/first-output" 2>&1 &
  first=$!
  revise > "$ITEM/second-output" 2>&1 &
  second=$!
  wait "$first"
  wait "$second"
  [ "$(row_count)" = 1 ]
  run projection
  [[ "$output" == *'"publication_state":"current"'* ]]
}

@test "legacy next-batch refuses semantic drift through adoption before dispatch" {
  run bash "$REPO_DIR/scripts/regen-tasks.sh" revision-fixture --quiet
  [ "$status" -eq 0 ]
  replace_plan "print('alpha')" "print('drifted-legacy')"
  run bash "$REPO_DIR/scripts/impl-next-batch.sh" revision-fixture --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'pending anchor coverage decision'* ]]
  [ "$(row_count)" = 1 ]
}

@test "explicit coverage on a later semantic revision settles carried pending tasks" {
  adopt
  replace_plan "print('alpha')" "print('pending')"
  revise
  replace_plan 'Beta module.' 'Changed beta output.'
  revise --decisions "$ITEM/decisions.json"
  run python3 - "$REPO_DIR/scripts/work-evidence.py" "$ITEM" "$LORE_KNOWLEDGE_DIR" <<'PY'
import runpy,sys
x=runpy.run_path(sys.argv[1])['project'](sys.argv[2],sys.argv[3])['revision']['dispatch']
assert x['blocked']=={},x
assert x['tasks']['task-1']['coverage_revision_id']==x['tasks']['task-2']['coverage_revision_id']
PY
  [ "$status" -eq 0 ]
}

@test "checkbox mutation refuses semantic drift before changing the live plan" {
  adopt
  replace_plan "print('alpha')" "print('semantic')"
  cp "$ITEM/plan.md" "$ITEM/expected-plan"
  run bash "$REPO_DIR/scripts/update-plan-checkbox.sh" revision-fixture 'Build alpha'
  [ "$status" -ne 0 ]
  [[ "$output" == *'semantic plan bytes must be revised'* ]]
  cmp "$ITEM/plan.md" "$ITEM/expected-plan"
  [ "$(row_count)" = 1 ]
}

@test "authored input replays after ledger failure without a second revision" {
  export LORE_PLAN_REVISE_FAIL_AT=after-ledger
  run adopt
  [ "$status" -ne 0 ]
  unset LORE_PLAN_REVISE_FAIL_AT
  run adopt
  [ "$status" -eq 0 ]
  [ "$(row_count)" = 1 ]
}

@test "completed projection recovery also refreshes its publication marker" {
  adopt
  id="$(head_id)"
  rm "$ITEM/revisions/.transactions/revision/$id/published.json"
  run revise --reconcile
  [ "$status" -eq 0 ]
  [ -f "$ITEM/revisions/.transactions/revision/$id/published.json" ]
  [ "$(row_count)" = 1 ]
}

@test "open repairs missing first-generation tasks and honors explicit proceed with pending review" {
  export LORE_PLAN_REVISE_FAIL_AT=after-ledger
  run adopt
  [ "$status" -ne 0 ]
  unset LORE_PLAN_REVISE_FAIL_AT
  run bash "$REPO_DIR/scripts/impl-open.sh" revision-fixture --all --json --fallback-scale-set implementation
  [ "$status" -eq 0 ]
  [ -f "$ITEM/tasks.json" ]
  [ "$(row_count)" = 1 ]
  [[ "$output" == *'"TeamCreate"'* ]]
}

@test "revision-stamped tasks without their ledger are refused by readers and writers" {
  adopt
  mv "$ITEM/revisions.jsonl" "$ITEM/saved-ledger"
  run bash "$REPO_DIR/scripts/load-tasks.sh" revision-fixture
  [ "$status" -ne 0 ]
  [[ "$output" == *'missing-revision-history'* ]]
  run revise
  [ "$status" -ne 0 ]
  [[ "$output" == *'revision-stamped tasks have no revision history'* ]]
}

@test "semantic edge and task-local scope edits retain distinct change categories" {
  adopt
  replace_plan ' [depends-on: task-1]' ''
  revise
  python3 - "$ITEM/plan.md" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);p.write_text(p.read_text().replace('**Deliverable:** Alpha module.','**Deliverable:** Alpha module.\n**Scope:**\n- Preserve backward compatibility.'))
PY
  revise
  run python3 - "$ITEM/revisions.jsonl" <<'PY'
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1])]
assert rows[1]['change_categories']['edge']==['task-2'],rows[1]
assert rows[2]['change_categories']['constraint']==['task-1'],rows[2]
PY
  [ "$status" -eq 0 ]
}
