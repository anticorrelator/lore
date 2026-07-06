#!/usr/bin/env bats
# retro_sampling_gate.bats — the retro-sampling gate, its deferred-batch queue
# appender, and the retro_sampling.routine_rate settings key.
#
# The gate (scripts/retro-sampling-gate.sh) is consulted at the spec-finalize
# and impl-close protocol termini. It evaluates deterministic always-strata
# (new template version, first-K of a routing pair, degraded/contested closure)
# — rate-exempt — and, for routine cycles, a mechanical coin (hash of slug+date,
# RNG-free) against retro_sampling.routine_rate. DUE surfaces a retro-run prompt;
# DEFERRED appends one debt row to the queue via retro-deferred-append.sh (the
# sole writer). Outcome vocabulary is the coordinate ledger's done|deferred|skipped.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
GATE="$REPO_DIR/scripts/retro-sampling-gate.sh"
APPEND="$REPO_DIR/scripts/retro-deferred-append.sh"
SCHEMA="$REPO_DIR/adapters/settings.schema.json"

setup() {
  [ -f "$GATE" ] || skip "retro-sampling-gate.sh missing"
  [ -f "$APPEND" ] || skip "retro-deferred-append.sh missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  command -v jq >/dev/null 2>&1 || skip "jq required"

  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"
  mkdir -p "$TEST_KDIR/_scorecards"
  ROWS="$TEST_KDIR/_scorecards/rows.jsonl"
  QUEUE="$TEST_KDIR/_scorecards/retro-deferred-queue.jsonl"

  # History: template aaaaaaaaaaaa scored by OTHER items; routing pair
  # (standard, opus) appears 5×, (mechanical, opus) once — both from other-item.
  python3 - "$ROWS" <<'PYEOF'
import json, sys
def pair(jc, wm, n): return [{"judgment_class": jc, "worker_model": wm}] * n
rows = [
  {"work_item": "other-a", "template_version": "aaaaaaaaaaaa", "event_type": "impl-close",
   "task_attribution": pair("standard", "opus", 3)},
  {"work_item": "other-b", "template_version": "aaaaaaaaaaaa", "event_type": "impl-close",
   "task_attribution": pair("standard", "opus", 2) + pair("mechanical", "opus", 1)},
]
with open(sys.argv[1], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PYEOF
}

teardown() {
  [ -n "${TEST_KDIR:-}" ] && [ -d "$TEST_KDIR" ] && rm -rf "$TEST_KDIR"
  unset LORE_KNOWLEDGE_DIR
}

decision() { echo "$output" | grep '^outcome='; }
queue_rows() { [ -f "$QUEUE" ] && wc -l < "$QUEUE" | tr -d ' ' || echo 0; }

# --- Always-strata (rate-exempt) --------------------------------------------

@test "new template version forces DUE at rate 0 (rate-exempt)" {
  run bash "$GATE" --terminus spec-finalize --slug feat-x \
    --template-version bbbbbbbbbbbb --routine-rate 0 --date 2026-07-06
  [ "$status" -eq 0 ]
  decision | grep -q "outcome=due"
  decision | grep -q "stratum=new_template_version"
  [ "$(queue_rows)" -eq 0 ]   # DUE never queues
}

@test "degraded closure verdict (partial) forces DUE at rate 0" {
  run bash "$GATE" --terminus impl-close --slug feat-x \
    --template-version aaaaaaaaaaaa --verdict partial --routine-rate 0 --date 2026-07-06
  [ "$status" -eq 0 ]
  decision | grep -q "outcome=due"
  decision | grep -q "stratum=degraded_closure"
}

@test "none verdict forces DUE at rate 0" {
  run bash "$GATE" --terminus impl-close --slug feat-x \
    --template-version aaaaaaaaaaaa --verdict none --routine-rate 0 --date 2026-07-06
  decision | grep -q "outcome=due"
  decision | grep -q "stratum=degraded_closure"
}

@test "first-K of a routing pair (unseen pair, count 0 < K) forces DUE" {
  run bash "$GATE" --terminus impl-close --slug feat-x \
    --template-version aaaaaaaaaaaa --verdict full \
    --task-attribution '[{"judgment_class":"judgment-dense","worker_model":"fable"}]' \
    --routine-rate 0 --date 2026-07-06
  decision | grep -q "outcome=due"
  decision | grep -q "stratum=first_k_routing_pair"
}

@test "a well-worn routing pair (count 5 >= K=3) does NOT fire first-K" {
  run bash "$GATE" --terminus impl-close --slug feat-x \
    --template-version aaaaaaaaaaaa --verdict full \
    --task-attribution '[{"judgment_class":"standard","worker_model":"opus"}]' \
    --routine-rate 0 --date 2026-07-06
  decision | grep -q "outcome=deferred"
  decision | grep -q "stratum=routine"
}

@test "--first-k widens the routing-pair window (count 5 < K=8 fires)" {
  run bash "$GATE" --terminus impl-close --slug feat-x \
    --template-version aaaaaaaaaaaa --verdict full \
    --task-attribution '[{"judgment_class":"standard","worker_model":"opus"}]' \
    --routine-rate 0 --first-k 8 --date 2026-07-06
  decision | grep -q "outcome=due"
  decision | grep -q "stratum=first_k_routing_pair"
}

# --- Self-exclusion: the cycle's own just-written row must not mask novelty ---

@test "the current cycle's own history row does not mask new_template_version" {
  # Append THIS cycle's own telemetry row (work_item==slug) with a novel template.
  python3 - "$ROWS" <<'PYEOF'
import json, sys
row = {"work_item": "feat-self", "template_version": "dddddddddddd",
       "event_type": "impl-close",
       "task_attribution": [{"judgment_class": "judgment-dense", "worker_model": "fable"}]}
with open(sys.argv[1], "a") as f:
    f.write(json.dumps(row) + "\n")
PYEOF
  run bash "$GATE" --terminus impl-close --slug feat-self \
    --template-version dddddddddddd --verdict full \
    --task-attribution '[{"judgment_class":"judgment-dense","worker_model":"fable"}]' \
    --routine-rate 0 --date 2026-07-06
  decision | grep -q "outcome=due"
  decision | grep -q "stratum=new_template_version"
}

# --- Mechanical coin (routine cycles) ---------------------------------------
# A non-12-hex template avoids the new_template_version stratum, isolating the coin.

@test "coin is deterministic: same slug+date yields the same decision" {
  run bash "$GATE" --terminus spec-finalize --slug feat-x \
    --template-version notahash --routine-rate 0.5 --date 2026-07-06 --json
  local first; first="$(echo "$output" | grep '"coin"')"
  run bash "$GATE" --terminus spec-finalize --slug feat-x \
    --template-version notahash --routine-rate 0.5 --date 2026-07-06 --json
  local second; second="$(echo "$output" | grep '"coin"')"
  [ -n "$first" ]
  [ "$first" = "$second" ]
}

@test "different date can yield a different coin (same slug)" {
  run bash "$GATE" --terminus spec-finalize --slug feat-x \
    --template-version notahash --routine-rate 0.5 --date 2026-07-06 --json
  local a; a="$(echo "$output" | python3 -c 'import json,sys; print("%.6f" % json.loads([l for l in sys.stdin if l.strip().startswith("{")][0])["coin"])')"
  run bash "$GATE" --terminus spec-finalize --slug feat-x \
    --template-version notahash --routine-rate 0.5 --date 2026-01-01 --json
  local b; b="$(echo "$output" | python3 -c 'import json,sys; print("%.6f" % json.loads([l for l in sys.stdin if l.strip().startswith("{")][0])["coin"])')"
  [ "$a" != "$b" ]
}

@test "rate 1 samples in every routine cycle (DUE)" {
  run bash "$GATE" --terminus spec-finalize --slug feat-x \
    --template-version notahash --routine-rate 1 --date 2026-07-06
  decision | grep -q "outcome=due"
  decision | grep -q "stratum=routine"
}

@test "rate 0 defers every routine cycle (DEFERRED)" {
  run bash "$GATE" --terminus spec-finalize --slug feat-x \
    --template-version notahash --routine-rate 0 --date 2026-07-06
  decision | grep -q "outcome=deferred"
}

# --- Deferral records exactly one queue row with the ledger vocabulary -------

@test "a deferred routine cycle appends exactly one queue row, outcome=deferred" {
  [ "$(queue_rows)" -eq 0 ]
  run bash "$GATE" --terminus impl-close --slug feat-x \
    --template-version aaaaaaaaaaaa --verdict full \
    --task-attribution '[{"judgment_class":"standard","worker_model":"opus"}]' \
    --routine-rate 0 --date 2026-07-06
  [ "$status" -eq 0 ]
  [ "$(queue_rows)" -eq 1 ]
  run python3 -c '
import json, sys
r = json.loads(open(sys.argv[1]).read().strip())
assert r["kind"] == "retro_deferred", r
assert r["outcome"] == "deferred", r
assert r["cycle_id"] == "feat-x", r
assert r["event_type"] == "impl-close", r
assert r["stratum"] == "routine", r
assert r["verdict"] == "full", r
assert 0.0 <= r["coin"] < 1.0, r
' "$QUEUE"
  [ "$status" -eq 0 ]
}

@test "a DUE cycle writes no queue row (surfaced, not deferred)" {
  run bash "$GATE" --terminus spec-finalize --slug feat-x \
    --template-version bbbbbbbbbbbb --routine-rate 0 --date 2026-07-06
  [ "$(queue_rows)" -eq 0 ]
}

# --- Gate usage errors -------------------------------------------------------

@test "gate rejects an unknown terminus with exit 1" {
  run bash "$GATE" --terminus bogus --slug feat-x --template-version notahash
  [ "$status" -eq 1 ]
}

@test "gate requires --slug" {
  run bash "$GATE" --terminus spec-finalize --template-version notahash
  [ "$status" -eq 1 ]
}

# --- Appender vocabulary + validation ---------------------------------------

@test "appender defaults outcome to deferred" {
  run bash "$APPEND" --cycle-id c1 --event-type impl-close --rate 0.2 --stratum routine
  [ "$status" -eq 0 ]
  run python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().strip())["outcome"])' "$QUEUE"
  [ "$output" = "deferred" ]
}

@test "appender accepts the full done|deferred|skipped vocabulary" {
  run bash "$APPEND" --cycle-id c1 --event-type spec-finalize --outcome done --rate 0 --stratum new_template_version
  [ "$status" -eq 0 ]
  run bash "$APPEND" --cycle-id c1 --event-type impl-close --outcome skipped --rate 0 --stratum degraded_closure --verdict none
  [ "$status" -eq 0 ]
}

@test "appender rejects an out-of-vocabulary outcome" {
  run bash "$APPEND" --cycle-id c1 --event-type impl-close --outcome maybe --rate 0.2 --stratum routine
  [ "$status" -eq 1 ]
}

@test "appender rejects an unknown stratum" {
  run bash "$APPEND" --cycle-id c1 --event-type impl-close --rate 0.2 --stratum wild
  [ "$status" -eq 1 ]
}

@test "appender rejects an unknown event-type" {
  run bash "$APPEND" --cycle-id c1 --event-type retro --rate 0.2 --stratum routine
  [ "$status" -eq 1 ]
}

@test "appender rejects an out-of-range rate" {
  run bash "$APPEND" --cycle-id c1 --event-type impl-close --rate 1.5 --stratum routine
  [ "$status" -eq 1 ]
}

# --- Settings schema: retro_sampling.routine_rate ----------------------------

@test "schema accepts routine_rate at bounds and rejects out-of-range / unknown key" {
  command -v python3 >/dev/null 2>&1 || skip
  python3 -c 'import jsonschema' 2>/dev/null || skip "jsonschema not installed"
  run python3 - "$SCHEMA" <<'PYEOF'
import json, sys
import jsonschema
schema = json.load(open(sys.argv[1]))
base = {"version": 1, "tui_launch_framework": "claude-code", "harnesses": {}}
def valid(rs):
    inst = dict(base)
    if rs is not None:
        inst["retro_sampling"] = rs
    try:
        jsonschema.validate(inst, schema); return True
    except jsonschema.ValidationError:
        return False
assert valid(None)                          # absent section
assert valid({})                            # empty
assert valid({"routine_rate": 0})           # default / lower bound
assert valid({"routine_rate": 1})           # upper bound
assert valid({"routine_rate": 0.25})        # interior
assert not valid({"routine_rate": 1.5})     # above max
assert not valid({"routine_rate": -0.1})    # below min
assert not valid({"routine_rate": "0.5"})   # wrong type
assert not valid({"routine_rate": 0.5, "bogus": 1})  # closed set
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}
