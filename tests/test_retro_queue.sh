#!/usr/bin/env bash
# test_retro_queue.sh — Durable DUE queue fold and monotonic disposition tests.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPEND="$REPO_ROOT/scripts/retro-deferred-append.sh"
QUEUE_FRONT="$REPO_ROOT/scripts/retro-queue.sh"
COORDINATE="$REPO_ROOT/scripts/coordinate-status.sh"
CLI="$REPO_ROOT/cli/lore"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$label"; else fail "$label" "expected '$expected', got '$actual'"; fi
}
assert_zero() { if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "exit=$2"; fi; }
assert_nonzero() { if [[ "$2" -ne 0 ]]; then pass "$1"; else fail "$1" "exit=0"; fi; }

KDIR=$(mktemp -d)
trap 'rm -rf "$KDIR"' EXIT
mkdir -p "$KDIR/_scorecards"
QUEUE="$KDIR/_scorecards/retro-deferred-queue.jsonl"

echo "=== test_retro_queue.sh ==="

bash "$APPEND" --cycle-id orphaned-cycle --event-type session-orphaned --outcome due \
  --outcome-id retro-due-orphaned-fixed --disposition unhandled --reason always-stratum \
  --rate 1 --stratum instance_death --kdir "$KDIR" >/dev/null
assert_zero "session-orphaned instance_death DUE is accepted" "$?"
LINES_AFTER_ORPHAN_DUE=$(wc -l < "$QUEUE" | tr -d '[:space:]')
bash "$APPEND" --cycle-id orphaned-cycle --event-type session-orphaned --outcome due \
  --outcome-id retro-due-orphaned-fixed --disposition unhandled --reason always-stratum \
  --rate 1 --stratum instance_death --kdir "$KDIR" >/dev/null
assert_zero "session-orphaned DUE retry succeeds" "$?"
assert_eq "session-orphaned DUE retry appends no duplicate" "$LINES_AFTER_ORPHAN_DUE" \
  "$(wc -l < "$QUEUE" | tr -d '[:space:]')"

# Legacy grammar remains accepted and readable.
for outcome in "done" "deferred" "skipped"; do
  bash "$APPEND" --cycle-id "legacy-$outcome" --event-type spec-finalize \
    --outcome "$outcome" --rate 0 --stratum routine --kdir "$KDIR" >/dev/null
  assert_zero "legacy outcome '$outcome' remains accepted" "$?"
done

# Two DUE decisions for the same cycle are distinct point events.
for reason in always-stratum coin; do
  bash "$APPEND" --cycle-id cycle-a --event-type impl-close --outcome due \
    --disposition unhandled --reason "$reason" --rate 0.5 --stratum routine \
    --coin 0.1 --kdir "$KDIR" >/dev/null
  assert_zero "DUE outcome '$reason' appended" "$?"
done

STATUS=$(bash "$QUEUE_FRONT" queue --kdir "$KDIR" --json)
RC=$?
assert_zero "queue fold exits zero" "$RC"
assert_eq "queue fold declares fold version" "2" \
  "$(printf '%s' "$STATUS" | jq -r '.fold_version')"
assert_eq "queue fold declares vocabulary version" "1" \
  "$(printf '%s' "$STATUS" | jq -r '.vocabulary_version')"
assert_eq "two repeated DUE decisions retain distinct identities" "2" \
  "$(printf '%s' "$STATUS" | jq -r '[.unhandled_due[] | select(.cycle_id=="cycle-a") | .outcome_id] | unique | length')"
assert_eq "legacy deferred row remains visible" "1" \
  "$(printf '%s' "$STATUS" | jq -r '.counts.deferred')"
assert_eq "default fold reports both DUE identities unhandled" "2" \
  "$(printf '%s' "$STATUS" | jq -r '[.unhandled_due[] | select(.cycle_id=="cycle-a")] | length')"

CLI_STATUS=$(bash "$CLI" retro queue --kdir "$KDIR" --json)
assert_eq "lore retro queue exposes the same unhandled fold" "2" \
  "$(printf '%s' "$CLI_STATUS" | jq -r '[.unhandled_due[] | select(.cycle_id=="cycle-a")] | length')"

OID=$(printf '%s' "$STATUS" | jq -r '.unhandled_due[0].outcome_id')
bash "$QUEUE_FRONT" handle --outcome-id "$OID" --action dispatched \
  --handled-by coordinator --kdir "$KDIR" >/dev/null
assert_zero "handle by outcome identity appends transition" "$?"

LINES_AFTER_FIRST=$(wc -l < "$QUEUE" | tr -d '[:space:]')
bash "$QUEUE_FRONT" handle --outcome-id "$OID" --action dispatched \
  --handled-by coordinator --kdir "$KDIR" >/dev/null
assert_zero "identical handling retry is an idempotent success" "$?"
assert_eq "idempotent retry appends no row" "$LINES_AFTER_FIRST" \
  "$(wc -l < "$QUEUE" | tr -d '[:space:]')"

bash "$QUEUE_FRONT" handle --outcome-id "$OID" --action skipped \
  --handled-by coordinator --kdir "$KDIR" >/dev/null 2>&1
assert_nonzero "conflicting second action fails loudly" "$?"

# Cycle handling claims every remaining unhandled identity and ignores the
# already-adjudicated identity rather than trying to transition it again.
bash "$QUEUE_FRONT" handle --cycle-id cycle-a --action dispatched \
  --handled-by coordinator --kdir "$KDIR" >/dev/null
assert_zero "cycle-wide handling claims only remaining unhandled identities" "$?"

STATUS=$(bash "$QUEUE_FRONT" queue --kdir "$KDIR" --json)
assert_eq "handled identities leave the unhandled fold" "0" \
  "$(printf '%s' "$STATUS" | jq -r '[.unhandled_due[] | select(.cycle_id=="cycle-a")] | length')"
assert_eq "handled fold retains both identities" "2" \
  "$(printf '%s' "$STATUS" | jq -r '.counts.handled_due')"
printf '%s' "$STATUS" | jq -e '
  all(.handled_due[];
      .handling.disposition == "handled" and
      .handling.action == "dispatched" and
      .handling.handled_by == "coordinator" and
      (.handling.handled_at | length) > 0)
' >/dev/null
assert_zero "handled rows carry action, actor, and writer-stamped time" "$?"

LINES_BEFORE_CYCLE_RETRY=$(wc -l < "$QUEUE" | tr -d '[:space:]')
bash "$QUEUE_FRONT" handle --cycle-id cycle-a --action skipped \
  --handled-by retro-lead --kdir "$KDIR" >/dev/null
assert_zero "cycle-wide claim is a no-op after prior coordinator handling" "$?"
assert_eq "cycle-wide no-op does not append a conflicting transition" "$LINES_BEFORE_CYCLE_RETRY" \
  "$(wc -l < "$QUEUE" | tr -d '[:space:]')"

# Exercise every authoritative handled-action token through the writer and read
# it back through the fold so the reader's mirrored vocabulary cannot drift.
for action in deferred skipped; do
  bash "$APPEND" --cycle-id "action-$action" --event-type spec-finalize --outcome due \
    --disposition unhandled --reason coin --rate 1 --stratum routine --coin 0.1 \
    --kdir "$KDIR" >/dev/null
  action_oid=$(jq -r --arg cycle "action-$action" \
    'select(.record_type == "outcome" and .cycle_id == $cycle) | .outcome_id' "$QUEUE")
  bash "$QUEUE_FRONT" handle --outcome-id "$action_oid" --action "$action" \
    --handled-by coordinator --kdir "$KDIR" >/dev/null
  assert_zero "handled action '$action' round-trips through the appender" "$?"
done
ACTION_STATUS=$(bash "$QUEUE_FRONT" queue --kdir "$KDIR" --json)
assert_eq "queue fold mirrors dispatched|deferred|skipped action vocabulary" \
  "deferred,dispatched,skipped" \
  "$(printf '%s' "$ACTION_STATUS" | jq -r '[.handled_due[].handling.action, .unhandled_due[].handling.action // empty] | unique | sort | join(",")')"
bash "$QUEUE_FRONT" handle --outcome-id "$OID" --action maybe \
  --handled-by coordinator --kdir "$KDIR" >/dev/null 2>&1
assert_nonzero "appender rejects action tokens outside the closed vocabulary" "$?"

WRITER_ACTIONS=$(sed -n '/case "\$ACTION" in/,/) ;;/p' "$APPEND" \
  | grep -E 'dispatched\|deferred\|skipped' | head -1 \
  | sed -E 's/^[[:space:]]*//; s/\).*$//' | tr '|' '\n' | sort -u | tr '\n' ' ')
MIRROR_ACTIONS=$(grep -E '^RETRO_ACTION_VOCAB=' "$COORDINATE" | head -1 \
  | sed -E 's/^RETRO_ACTION_VOCAB="([^"]*)".*/\1/' | tr ' ' '\n' \
  | sort -u | tr '\n' ' ')
assert_eq "coordinate retro action mirror matches the sole appender" \
  "$WRITER_ACTIONS" "$MIRROR_ACTIONS"

# No DUE for a cycle is a successful no-op, which keeps direct /retro claiming fail-open.
bash "$CLI" retro handle --cycle-id absent --action dispatched \
  --handled-by retro-lead --kdir "$KDIR" >/dev/null
assert_zero "lore retro handle treats a cycle with no DUE as a no-op" "$?"

# Historical fixtures are local data, never copied from the live queue.
python3 - "$KDIR" "$QUEUE_FRONT" <<'PY'
import json, pathlib, subprocess, sys
root, front = pathlib.Path(sys.argv[1]), sys.argv[2]
fixture = root / 'historical'
fixture.mkdir()
(fixture / '_scorecards').mkdir()
queue = fixture / '_scorecards/retro-deferred-queue.jsonl'
cycle = 'implement-runs-on-packets-positions-standalone-com'
ids = ['retro-due-fbc86be878f847b295ec342a09d0b0c5',
       'retro-due-473a9cc0745043849a628ae38cfe457f']
def due(oid, ts, cycle=cycle, event='spec-finalize'):
    return dict(schema_version='2', kind='retro_deferred', record_type='outcome',
                outcome_id=oid, cycle_id=cycle, event_type=event, outcome='due',
                disposition='unhandled', ts=ts, reason='always-stratum',
                stratum='new_template_version', rate=1)
def transition(row, action, ts, actor='coordinate'):
    return dict(schema_version='2', kind='retro_deferred', record_type='disposition',
                outcome_id=row['outcome_id'], cycle_id=row['cycle_id'],
                event_type=row['event_type'], outcome='due', disposition='handled',
                action=action, handled_by=actor, ts=ts, handled_at=ts)
def write(rows):
    queue.write_text(''.join(json.dumps(r, sort_keys=True) + '\n' for r in rows))
    return queue.read_bytes()
def call(*args, success=True):
    result = subprocess.run(['bash', front, *args, '--kdir', str(fixture), '--json'],
                            capture_output=True, text=True)
    assert (result.returncode == 0) == success, (args, result.stdout, result.stderr)
    return json.loads(result.stdout) if success else result

a=due(ids[0], '2026-09-01T11:57:34Z')
b=due(ids[1], '2026-09-01T15:08:24Z', event='impl-close')
rows=[a,b,transition(a,'deferred','2026-09-01T15:14:04Z'),
          transition(b,'deferred','2026-09-01T15:14:05Z')]
original=write(rows)
fold=call('queue')
assert [r['outcome_id'] for r in fold['unhandled_due']]==ids
assert all(r['disposition']=='unhandled' and r['handling']['action']=='deferred'
           for r in fold['unhandled_due'])
assert queue.read_bytes()==original
replay=call('handle','--cycle-id',cycle,'--action','deferred','--handled-by','coordinate')
assert (replay['matched'],replay['appended'],replay['idempotent'])==(2,0,2)
assert queue.read_bytes()==original
claimed=call('handle','--cycle-id',cycle,'--action','dispatched','--handled-by','retro-lead')
assert claimed['outcome_ids']==ids and claimed['appended']==2
later=queue.read_bytes()
assert later.startswith(original) and len(later.splitlines())==6
assert call('queue')['counts']['unhandled_due']==0
assert call('handle','--cycle-id',cycle,'--action','dispatched','--handled-by','retro-lead')['appended']==0
for oid in ids:
    assert call('handle','--outcome-id',oid,'--action','dispatched','--handled-by','retro-lead')['idempotent']==1
    for action,actor in [('skipped','retro-lead'),('deferred','coordinate'),('dispatched','someone-else')]:
        call('handle','--outcome-id',oid,'--action',action,'--handled-by',actor,success=False)
assert queue.read_bytes()==later

# Recreate the 19-deferral shape across cycles, plus never-disposed and terminal
# outcomes. The writer's eligible set must exactly match the reader's set.
rows19=list(rows)
for n in range(17):
    row=due(f'census-{n}', '2026-09-01T12:00:00Z', cycle=f'other-{n%3}')
    rows19.extend([row,transition(row,'deferred','2026-09-01T15:00:00Z')])
fresh=due('fresh','2026-09-01T12:00:00Z')
terminal=due('terminal','2026-09-01T12:00:00Z')
rows19.extend([fresh,terminal,transition(terminal,'skipped','2026-09-01T15:00:00Z')])
original=write(rows19)
fold=call('queue')
assert sum(r.get('handling',{}).get('action')=='deferred' for r in fold['unhandled_due'])==19
expected={r['outcome_id'] for r in fold['unhandled_due'] if r['cycle_id']==cycle}
claim=call('handle','--cycle-id',cycle,'--action','skipped','--handled-by','retro-lead')
assert set(claim['outcome_ids'])==expected==set(ids+['fresh'])
assert queue.read_bytes().startswith(original)
assert call('queue')['counts']['unhandled_due']==17
for oid in ids:
    assert call('handle','--outcome-id',oid,'--action','skipped','--handled-by','retro-lead')['idempotent']==1
    call('handle','--outcome-id',oid,'--action','dispatched','--handled-by','retro-lead',success=False)

# A changed deferring actor is a new nonterminal transition; same latest actor
# and action replay exactly, even though older handling rows differ.
original=write(rows)
call('handle','--outcome-id',ids[0],'--action','deferred','--handled-by','reviewer')
assert len(queue.read_bytes().splitlines())==5 and queue.read_bytes().startswith(original)
assert call('handle','--outcome-id',ids[0],'--action','deferred','--handled-by','reviewer')['idempotent']==1
assert call('handle','--outcome-id',ids[0],'--action','skipped','--handled-by','reviewer')['appended']==1

# Append order decides ties and clock reversals. Window bounds select outcome
# times, while transitions use only the exclusive upper bound.
start,end='2026-09-01T10:00:00Z','2026-09-01T20:00:00Z'
window_rows=[]
for oid,ts,transitions in [
    ('at-start',start,[('deferred','2026-09-01T11:00:00Z'),('skipped','2026-09-01T11:00:00Z')]),
    ('before-start','2026-09-01T09:59:59Z',[('deferred','2026-09-01T12:00:00Z')]),
    ('at-end',end,[]),
    ('terminal-before-start',start,[('dispatched','2026-09-01T09:00:00Z')]),
    ('terminal-at-end',start,[('deferred',start),('dispatched',end)]),
    ('clock-reversal',start,[('deferred','2026-09-01T12:00:00Z'),('skipped','2026-09-01T11:00:00Z')]),
    ('offset-start','2026-09-01T06:00:00-04:00',[]),
]:
    row=due(oid,ts)
    window_rows.append(row)
    window_rows.extend(transition(row,action,time) for action,time in transitions)
window_rows.extend(dict(schema_version='1',outcome=action,cycle_id=cycle,ts=start)
                   for action in ['done','deferred','skipped'])
original=write(window_rows)
bounded=call('queue','--cycle-id',cycle,'--window-start',start,'--window-end',end)
assert {r['outcome_id'] for r in bounded['unhandled_due']}=={'terminal-at-end','offset-start'}
assert {r['outcome_id'] for r in bounded['handled_due']}=={'at-start','terminal-before-start','clock-reversal'}
assert bounded['counts']['deferred']==bounded['counts']['done']==bounded['counts']['skipped']==1
assert bounded['window_semantics']['transitions']=='transition time < end; no lower bound'
assert call('queue')['counts']['handled_due']==4
assert queue.read_bytes()==original
# With no cutoff, the cycle claim matches the full reader even after ties.
expected={r['outcome_id'] for r in call('queue')['unhandled_due']}
claimed=call('handle','--cycle-id',cycle,'--action','dispatched','--handled-by','retro-lead')
assert set(claimed['outcome_ids'])==expected
assert call('queue')['counts']['unhandled_due']==0
assert queue.read_bytes().startswith(original)
for args in [('--window-start',start),('--window-start',end,'--window-end',start),
             ('--window-start',start,'--window-end',start)]:
    call('queue',*args,success=False)
print('Historical transitions, 19-deferral eligibility, replay/conflicts, and outcome windows passed')
PY
assert_zero "isolated historical and bounded transition fixtures" "$?"

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
