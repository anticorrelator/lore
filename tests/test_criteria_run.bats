#!/usr/bin/env bats
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

setup() {
  export LORE_KNOWLEDGE_DIR="$(mktemp -d)"
  export LORE_DATA_DIR="$(mktemp -d)"
  export LORE_FRAMEWORK=codex
  ITEM="$LORE_KNOWLEDGE_DIR/_work/criteria-fixture"
  CODE="$LORE_DATA_DIR/code"
  mkdir -p "$ITEM" "$CODE"
  git -C "$CODE" init -q
  git -C "$CODE" config user.name Fixture
  git -C "$CODE" config user.email fixture@example.test
  printf 'tracked\n' > "$CODE/tracked"
  git -C "$CODE" add tracked
  git -C "$CODE" commit -qm initial
  printf '%s\n' '{"title":"Criteria fixture","status":"active","intent_anchor":"Observe actual commands."}' > "$ITEM/_meta.json"
  cd "$REPO_DIR"
}
teardown() { rm -rf "$LORE_KNOWLEDGE_DIR" "$LORE_DATA_DIR"; }

# Fixture input is authored plan text; every result is produced by the real runner.
plan() {
  python3 - "$ITEM/plan.md" "$1" <<'PY'
import json,sys
c=json.loads(sys.argv[2]);c={"id":"check","intent":"Observe the declared behavior","argv":["python3","-c","print('observed')"],"cwd":".","timeout":5,"expected_exit":0,**c}
open(sys.argv[1],'w').write('''# Criteria fixture
## Intent Anchor
Observe actual commands.

**Scope delta:** none

## Tasks
**Merge rationale:** One command boundary.

### Task 1: Observe execution
**Deliverable:** Observed behavior.
**Files:** `tracked`
**Close criteria:**
```json
'''+json.dumps([c])+'''
```
- [ ] Observe execution [class: mechanical]
''')
PY
  bash "$REPO_DIR/scripts/plan-revise.sh" criteria-fixture >/dev/null
  RID="$(jq -r .revision_id "$ITEM/tasks.json")"
}
execute() {
  bash "$REPO_DIR/scripts/criteria-run.sh" criteria-fixture task-1 check --revision "$RID" \
    --execution-worktree "$CODE" --unbound-reason 'Direct verification' "$@" 2> "$LORE_DATA_DIR/stderr"
}
row() { tail -n 1 "$ITEM/results.jsonl" | jq -r "$1"; }
project() { python3 "$REPO_DIR/scripts/work-evidence.py" --item-dir "$ITEM" --knowledge-dir "$LORE_KNOWLEDGE_DIR"; }
recover() { bash "$REPO_DIR/scripts/criteria-run.sh" criteria-fixture --recover "$1"; }

@test "runner preserves exact argv cwd output and whole criterion identity" {
  mkdir "$CODE/with spaces"
  plan '{"argv":["python3","-c","import os,sys; print(repr(sys.argv[1:])); print(os.getcwd()); print(\"stderr\",file=sys.stderr)","a b","$HOME",";",""],"cwd":"with spaces"}'
  run execute
  [ "$status" -eq 0 ]
  [ "$(row .state)" = pass ]
  [ "$(row .reason)" = expected-exit ]
  [ "$(row .cwd)" = 'with spaces' ]
  jq -e --arg cwd "$(cd "$CODE/with spaces" && pwd -P)" '.resolved_cwd==$cwd and .argv[-1]=="" and .argv[-3]=="$HOME"' "$ITEM/results.jsonl"
  grep -F "['a b', '\$HOME', ';', '']" "$ITEM/$(row .output_path)"
  grep -F stderr "$ITEM/$(row .output_path)"
  run project
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"current"'* ]]
}

@test "expected and unexpected exit signal and timeout remain distinguishable" {
  plan '{"argv":["python3","-c","raise SystemExit(7)"],"expected_exit":7}'
  run execute; [ "$status" -eq 0 ]; [ "$(row .exit)" = 7 ]
  plan '{"argv":["python3","-c","raise SystemExit(7)"]}'
  run execute; [ "$status" -eq 1 ]; [ "$(row .reason)" = unexpected-exit ]
  plan '{"argv":["python3","-c","import os,signal;os.kill(os.getpid(),signal.SIGTERM)"]}'
  run execute; [ "$status" -eq 1 ]; [ "$(row .reason)" = signal ]; [ "$(row .signal)" = 15 ]
  plan '{"argv":["python3","-c","import time;time.sleep(20)"],"timeout":0.2}'
  run execute; [ "$status" -eq 1 ]; [ "$(row .reason)" = timeout ]; [ "$(row .timed_out)" = true ]
}

@test "missing executable cwd escaped symlink and source root produce unavailable facts" {
  plan '{"argv":["/does/not/exist"]}'
  run execute; [ "$status" -eq 2 ]; [ "$(row .reason)" = executable-unavailable ]
  plan '{"cwd":"missing"}'
  run execute; [ "$status" -eq 2 ]; [ "$(row .reason)" = cwd-unavailable ]
  ln -s "$LORE_KNOWLEDGE_DIR" "$CODE/outside"
  plan '{"cwd":"outside"}'
  run execute; [ "$status" -eq 2 ]; [ "$(row .reason)" = cwd-unavailable ]
  plan '{}'
  mv "$CODE" "$CODE-removed"
  run execute; [ "$status" -eq 2 ]; [ "$(row .state)" = unavailable ]
}

@test "applicability records observed applicable and inapplicable outcomes only" {
  plan '{"applicability":{"argv":["python3","-c","print(\"predicate\");raise SystemExit(8)"],"cwd":".","timeout":5,"applicable_exit":8,"inapplicable_exit":9}}'
  run execute; [ "$status" -eq 0 ]; [ "$(row .state)" = pass ]
  [ "$(row .applicability.observation.exit)" = 8 ]
  grep predicate "$ITEM/$(row .applicability.observation.output_path)"
  plan '{"argv":["python3","-c","open(\"must-not-run\",\"w\").write(\"bad\")"],"applicability":{"argv":["python3","-c","raise SystemExit(9)"],"cwd":".","timeout":5,"applicable_exit":8,"inapplicable_exit":9}}'
  run execute; [ "$status" -eq 0 ]; [ "$(row .state)" = skipped ]
  [ ! -e "$CODE/must-not-run" ]
  [ "$(row .applicability.observation.exit)" = 9 ]
}

@test "unexpected applicability exit signal timeout launch and output faults are unavailable" {
  for predicate in \
    '{"argv":["python3","-c","raise SystemExit(4)"],"cwd":".","timeout":5,"applicable_exit":0,"inapplicable_exit":1}' \
    '{"argv":["python3","-c","import os,signal;os.kill(os.getpid(),signal.SIGTERM)"],"cwd":".","timeout":5,"applicable_exit":0,"inapplicable_exit":1}' \
    '{"argv":["python3","-c","import time;time.sleep(20)"],"cwd":".","timeout":0.2,"applicable_exit":0,"inapplicable_exit":1}' \
    '{"argv":["/does/not/exist"],"cwd":".","timeout":5,"applicable_exit":0,"inapplicable_exit":1}'; do
    plan "{\"applicability\":$predicate}"
    run execute; [ "$status" -eq 2 ]; [ "$(row .state)" = unavailable ]
    [[ "$(row .reason)" == applicability-* ]]
  done
  plan '{"applicability":{"argv":["python3","-c","print(\"condition\")"],"cwd":".","timeout":5,"applicable_exit":0,"inapplicable_exit":1}}'
  export LORE_CRITERIA_FAIL_AT=output-write
  run execute; [ "$status" -eq 2 ]; [ "$(row .reason)" = applicability-output-persistence-failed ]
}

@test "output write and fsync failures never publish pass" {
  plan '{}'
  for fault in output-write output-sync; do
    export LORE_CRITERIA_FAIL_AT="$fault"
    run execute; [ "$status" -eq 2 ]
    [ "$(row .state)" = unavailable ]; [ "$(row .reason)" = output-persistence-failed ]
    [ "$(row .output_sha256)" = null ]
  done
}

@test "caller cannot provide a command result skip exit or output override" {
  plan '{}'
  for flag in --command --argv --result --state --exit --output --skip --expected-exit --execution-sequence; do
    run execute "$flag" pass
    [ "$status" -eq 3 ]; [ ! -f "$ITEM/results.jsonl" ]; [ ! -d "$ITEM/results" ]
  done
  run bash "$REPO_DIR/scripts/criteria-run.sh" criteria-fixture task-1 check --execution-worktree "$CODE"
  [ "$status" -eq 3 ]; [ ! -d "$ITEM/results" ]
}

@test "historical selection stays frozen and command-only changes make old rows stale" {
  plan '{}'
  first="$RID"
  execute >/dev/null
  cp "$ITEM/results.jsonl" "$LORE_DATA_DIR/original"
  first_output="$(row .output_path)"
  cp "$ITEM/$first_output" "$LORE_DATA_DIR/old-output"
  plan '{"argv":["python3","-c","print(\"new command\")"]}'
  RID="$first"
  execute >/dev/null
  [ "$(row .revision_id)" = "$first" ]
  grep observed "$ITEM/$(row .output_path)"
  cmp "$LORE_DATA_DIR/old-output" "$ITEM/$first_output"
  head -n 1 "$ITEM/results.jsonl" > "$LORE_DATA_DIR/old-row"
  cmp "$LORE_DATA_DIR/original" "$LORE_DATA_DIR/old-row"
  project > "$LORE_DATA_DIR/projection"
  jq -e '.result_summary[0].freshness | .state=="stale" and (.reasons|index("criterion-version-mismatch"))' "$LORE_DATA_DIR/projection"
}

@test "same HEAD tracked untracked index and mode changes alter current source identity" {
  plan '{}'
  execute >/dev/null
  printf 'dirty\n' >> "$CODE/tracked"
  project > "$LORE_DATA_DIR/p"
  jq -e '.result_summary[0].freshness.reasons|index("source-code-mismatch")' "$LORE_DATA_DIR/p"
  git -C "$CODE" checkout -- tracked
  printf new > "$CODE/untracked"
  project > "$LORE_DATA_DIR/p"
  jq -e '.result_summary[0].freshness.reasons|index("source-code-mismatch")' "$LORE_DATA_DIR/p"
  rm "$CODE/untracked"
  chmod +x "$CODE/tracked"
  project > "$LORE_DATA_DIR/p"
  jq -e '.result_summary[0].freshness.reasons|index("source-code-mismatch")' "$LORE_DATA_DIR/p"
  chmod -x "$CODE/tracked"
  printf staged >> "$CODE/tracked"
  git -C "$CODE" add tracked
  git -C "$CODE" show HEAD:tracked > "$CODE/tracked"
  project > "$LORE_DATA_DIR/p"
  jq -e '.result_summary[0].freshness.reasons|index("source-code-mismatch")' "$LORE_DATA_DIR/p"
}

@test "changes during execution are stale and removed live worktree is unknown" {
  plan '{"argv":["python3","-c","open(\"tracked\",\"a\").write(\"changed\");print(\"ran\")"]}'
  execute >/dev/null
  project > "$LORE_DATA_DIR/p"
  jq -e '.result_summary[0].freshness.reasons|index("code-changed-during-execution")' "$LORE_DATA_DIR/p"
  plan '{}'
  execute >/dev/null
  mv "$CODE" "$CODE-removed"
  project > "$LORE_DATA_DIR/p"
  jq -e '.result_summary[0].freshness|.state=="unknown" and (.reasons|index("code-unavailable"))' "$LORE_DATA_DIR/p"
}

@test "publication recovery preserves output and never executes a completed command twice" {
  plan '{"argv":["python3","-c","from pathlib import Path;p=Path(\"counter\");p.write_text(str(int(p.read_text())+1) if p.exists() else \"1\");print(\"ran once\")"]}'
  for fault in after-completion before-publication partial-publication; do
    export LORE_CRITERIA_FAIL_AT="$fault"
    run execute; [ "$status" -eq 3 ]
    result_id="$(jq -r 'select(.status=="allocated")|.result_id' "$LORE_DATA_DIR/stderr")"
    before="$(cat "$CODE/counter")"
    cp "$ITEM/results/$result_id/output.out" "$LORE_DATA_DIR/original-output"
    unset LORE_CRITERIA_FAIL_AT
    run recover "$result_id"; [ "$status" -eq 0 ]
    [ "$(cat "$CODE/counter")" = "$before" ]
    cmp "$LORE_DATA_DIR/original-output" "$ITEM/results/$result_id/output.out"
    cp "$ITEM/results.jsonl" "$LORE_DATA_DIR/original-ledger"
    run recover "$result_id"; [ "$status" -eq 0 ]
    cmp "$LORE_DATA_DIR/original-ledger" "$ITEM/results.jsonl"
    run bash "$REPO_DIR/scripts/criteria-run.sh" criteria-fixture --recover "$result_id" --revision ffffffffffff
    [ "$status" -eq 3 ]
  done
}

@test "allocated interrupted attempt recovers unavailable without running and changed output refuses" {
  plan '{"argv":["python3","-c","open(\"must-not-run\",\"w\").write(\"bad\")"]}'
  export LORE_CRITERIA_FAIL_AT=after-allocation
  run execute; [ "$status" -eq 3 ]
  result_id="$(jq -r 'select(.status=="allocated")|.result_id' "$LORE_DATA_DIR/stderr")"
  unset LORE_CRITERIA_FAIL_AT
  run recover "$result_id"; [ "$status" -eq 2 ]
  [ "$(row .reason)" = interrupted-without-durable-completion ]
  [ ! -e "$CODE/must-not-run" ]
  plan '{}'
  export LORE_CRITERIA_FAIL_AT=after-completion
  run execute; [ "$status" -eq 3 ]
  result_id="$(jq -r 'select(.status=="allocated")|.result_id' "$LORE_DATA_DIR/stderr")"
  unset LORE_CRITERIA_FAIL_AT
  printf tampered >> "$ITEM/results/$result_id/output.out"
  run recover "$result_id"; [ "$status" -eq 3 ]
  [ "$(wc -l < "$ITEM/results.jsonl" | tr -d ' ')" = 1 ]
}

@test "packet determines revision and dispatch while executions allocate separate attempts" {
  plan '{}'
  source_head="$(jq -r .source_head "$ITEM/revisions.jsonl")"
  packet="$(jq -nc --arg rid "$RID" --arg head "$source_head" '{packet_id:"packet-run",packet_scope:"task",delivery_stage:"assembled",session_id:"session",work_item:"criteria-fixture",phase:1,task_id:"task-1",arm:null,task_scale_set:"subsystem,implementation",delivered_entries:[],empty_reason:"Test fixture",budget:{chars_used:0,chars_budget:100},revision_id:$rid,source_head:$head,dispatch_attempt_id:"dispatch-original"}')"
  bash "$REPO_DIR/scripts/packet-append.sh" --row "$packet" --kdir "$LORE_KNOWLEDGE_DIR"
  for conflict in '--revision ffffffffffff' '--dispatch-attempt-id wrong' '--unbound-reason wrong'; do
    run bash "$REPO_DIR/scripts/criteria-run.sh" criteria-fixture task-1 check --packet-id packet-run --execution-worktree "$CODE" $conflict
    [ "$status" -eq 3 ]; [ ! -d "$ITEM/results" ]
  done
  run bash "$REPO_DIR/scripts/criteria-run.sh" criteria-fixture task-2 check --packet-id packet-run --execution-worktree "$CODE"
  [ "$status" -eq 3 ]; [ ! -d "$ITEM/results" ]
  for attempt in 1 2; do
    run bash "$REPO_DIR/scripts/criteria-run.sh" criteria-fixture task-1 check --packet-id packet-run --execution-worktree "$CODE"
    [ "$status" -eq 0 ]
  done
  jq -se '.[0].dispatch_attempt_id==.[1].dispatch_attempt_id and .[0].execution_attempt_id!=.[1].execution_attempt_id and .[0].result_id!=.[1].result_id' "$ITEM/results.jsonl"
}

@test "in-worktree store excludes only own result publication and retains older evidence changes" {
  mv "$LORE_KNOWLEDGE_DIR" "$CODE/store"
  export LORE_KNOWLEDGE_DIR="$CODE/store"
  ITEM="$LORE_KNOWLEDGE_DIR/_work/criteria-fixture"
  plan '{}'
  execute >/dev/null
  project > "$LORE_DATA_DIR/p"
  jq -e '.result_summary[0].freshness.state=="current"' "$LORE_DATA_DIR/p"
  [ "$(row .source_end.digest_version)" = 2 ]
  execute >/dev/null
  project > "$LORE_DATA_DIR/p"
  jq -e '.result_summary[0].freshness.state=="current"' "$LORE_DATA_DIR/p"
  python3 - "$ITEM/results.jsonl" <<'PY'
import json,sys
p=sys.argv[1]; rows=open(p).readlines();r=json.loads(rows[0]);r['reason']='older evidence changed';rows[0]=json.dumps(r)+'\n';open(p,'w').writelines(rows)
PY
  project > "$LORE_DATA_DIR/p"
  jq -e '.result_summary[0].freshness.reasons|index("source-code-mismatch")' "$LORE_DATA_DIR/p"
}

@test "timeout closes escaped descendant output pipe within a finite drain interval" {
  plan '{"argv": ["python3", "-c", "import os,time;pid=os.fork();os.setsid() if pid==0 else None;open(\"escaped-pid\",\"w\").write(str(os.getpid())) if pid==0 else None;print(\"parent done\",flush=True);time.sleep(15) if pid==0 else None"], "timeout": 0.3}'
  before="$SECONDS"
  run execute
  elapsed=$((SECONDS-before))
  printf 'runner status=%s output=%s\n' "$status" "$output"
  cat "$LORE_DATA_DIR/stderr"
  [ "$status" -eq 1 ]; [ "$(row .reason)" = timeout ]
  [ "$elapsed" -lt 6 ]
  grep 'parent done' "$ITEM/$(row .output_path)"
  if [ -f "$CODE/escaped-pid" ]; then kill -KILL "$(cat "$CODE/escaped-pid")" 2>/dev/null || true; fi
}

@test "supervisor interruption publishes unavailable and refuses concurrent recovery" {
  plan '{"argv":["python3","-c","import time;print(\"started\",flush=True);time.sleep(20)"],"timeout":10}'
  python3 - "$REPO_DIR/scripts/criteria-run.sh" "$CODE" "$RID" "$ITEM" <<'PY'
import json,os,pathlib,signal,subprocess,sys,time
script,code,rid,item=sys.argv[1:];item=pathlib.Path(item)
p=subprocess.Popen(['bash',script,'criteria-fixture','task-1','check','--revision',rid,'--execution-worktree',code,'--unbound-reason','Direct verification'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
allocated=json.loads(p.stderr.readline());base=item/'results'/allocated['result_id']
for _ in range(100):
    if (base/'output-process.json').exists(): break
    time.sleep(.02)
else: raise AssertionError('child did not start')
r=subprocess.run(['bash',script,'criteria-fixture','--recover',allocated['result_id']],capture_output=True,text=True)
assert r.returncode==3 and 'still supervised' in r.stderr,r
supervisor=json.loads((base/'output-process.json').read_text())['supervisor_pid']
os.kill(supervisor,signal.SIGTERM)
out,err=p.communicate(timeout=5);assert p.returncode==2,(out,err)
row=json.loads(out)['result'];assert row['state']=='unavailable' and row['reason']=='supervision-interrupted',row
PY
}

@test "symlink ledger refuses publication while durable completion remains recoverable" {
  plan '{"argv":["python3","-c","import os;from pathlib import Path;(Path(os.environ[\"LORE_KNOWLEDGE_DIR\"])/\"_work/criteria-fixture/results.jsonl\").symlink_to(Path(os.environ[\"LORE_DATA_DIR\"])/\"other-file\");print(\"observed\")"]}' 
  target="$LORE_DATA_DIR/other-file"
  printf original > "$target"
  run execute; [ "$status" -eq 3 ]
  [ "$(cat "$target")" = original ]
  result_id="$(jq -r 'select(.status=="allocated")|.result_id' "$LORE_DATA_DIR/stderr")"
  [ -f "$ITEM/results/$result_id/completion.json" ]
  rm "$ITEM/results.jsonl"
  run recover "$result_id"; [ "$status" -eq 0 ]
}

@test "recovering older execution after a newer failure does not replace latest attempt" {
  plan '{"argv":["python3","-c","from pathlib import Path;raise SystemExit(4 if Path(\"fail-now\").exists() else 0)"]}'
  export LORE_CRITERIA_FAIL_AT=after-completion
  run execute; [ "$status" -eq 3 ]
  old_id="$(jq -r 'select(.status=="allocated")|.result_id' "$LORE_DATA_DIR/stderr")"
  unset LORE_CRITERIA_FAIL_AT
  touch "$CODE/fail-now"
  run execute; [ "$status" -eq 1 ]
  newer="$(row .result_id)"
  cp "$ITEM/results.jsonl" "$LORE_DATA_DIR/newer-row"
  run recover "$old_id"; [ "$status" -eq 0 ]
  head -1 "$ITEM/results.jsonl" > "$LORE_DATA_DIR/still-newer"
  cmp "$LORE_DATA_DIR/newer-row" "$LORE_DATA_DIR/still-newer"
  project > "$LORE_DATA_DIR/p"
  jq -e --arg id "$newer" '.result_summary[0]|.result_id==$id and .state=="fail"' "$LORE_DATA_DIR/p"
  jq -se '.[0].execution_sequence > .[1].execution_sequence' "$ITEM/results.jsonl"
  if [ -n "${LORE_CRITERIA_AUDIT_ROOT:-}" ]; then
    mkdir -p "$LORE_CRITERIA_AUDIT_ROOT/ordering"
    cp -R "$ITEM" "$LORE_CRITERIA_AUDIT_ROOT/ordering/item"
    cp "$LORE_DATA_DIR/p" "$LORE_CRITERIA_AUDIT_ROOT/ordering/projection.json"
  fi
}

@test "allocation remains above published sequence when an older output directory is missing" {
  plan '{}'
  execute >/dev/null
  first="$(row .result_id)"
  sequence="$(row .execution_sequence)"
  mv "$ITEM/results/$first" "$LORE_DATA_DIR/saved-result"
  execute >/dev/null
  [ "$(row .execution_sequence)" -gt "$sequence" ]
  mv "$LORE_DATA_DIR/saved-result" "$ITEM/results/$first"
}

@test "killed supervisor recovery retains start identity and never reexecutes child" {
  plan '{"argv":["python3","-c","import time;from pathlib import Path;p=Path(\"started-count\");p.write_text(str(int(p.read_text())+1) if p.exists() else \"1\");time.sleep(20)"],"timeout":10}'
  python3 - "$REPO_DIR/scripts/criteria-run.sh" "$CODE" "$RID" "$ITEM" <<'PY'
import json,os,pathlib,signal,subprocess,sys,time
script,code,rid,item=sys.argv[1:];item=pathlib.Path(item)
p=subprocess.Popen(['bash',script,'criteria-fixture','task-1','check','--revision',rid,'--execution-worktree',code,'--unbound-reason','Direct verification'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
allocated=json.loads(p.stderr.readline());base=item/'results'/allocated['result_id']
for _ in range(100):
    if (base/'output-process.json').exists() and (pathlib.Path(code)/'started-count').exists(): break
    time.sleep(.02)
else: raise AssertionError('child did not start')
process=json.loads((base/'output-process.json').read_text())
os.kill(process['supervisor_pid'],signal.SIGKILL)
os.kill(process['pid'],signal.SIGKILL)
p.communicate(timeout=5)
assert not (base/'completion.json').exists()
r=subprocess.run(['bash',script,'criteria-fixture','--recover',allocated['result_id']],capture_output=True,text=True)
assert r.returncode==2,(r.stdout,r.stderr)
row=json.loads(r.stdout)['result'];assert row['reason']=='interrupted-without-durable-completion',row
assert row['source_start']['state']=='read' and row['source_end']['state']=='read'
assert (pathlib.Path(code)/'started-count').read_text()=='1'
PY
}
