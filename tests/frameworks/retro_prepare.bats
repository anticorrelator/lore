#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
PREPARE="$REPO_DIR/scripts/retro-prepare.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"
  mkdir -p "$TEST_KDIR/_work/cycle-a" "$TEST_KDIR/_scorecards" "$TEST_KDIR/_meta" "$TEST_KDIR/_sessions"
  printf '{"schema_version":"1"}\n' > "$TEST_KDIR/_manifest.json"
  printf '{"title":"Cycle A","status":"active","created":"2026-07-01T00:00:00Z","updated":"2026-07-02T00:00:00Z"}\n' > "$TEST_KDIR/_work/cycle-a/_meta.json"
  printf '# Plan\n\n- [x] one\n- [ ] two\n[[knowledge:one]]\n' > "$TEST_KDIR/_work/cycle-a/plan.md"
  printf '# Notes\n' > "$TEST_KDIR/_work/cycle-a/notes.md"
  : > "$TEST_KDIR/_scorecards/rows.jsonl"
  printf '{"schema_version":1}\n' > "$TEST_KDIR/_scorecards/_current.json"
  : > "$TEST_KDIR/_sessions/events.jsonl"
  : > "$TEST_KDIR/_meta/effectiveness-journal.jsonl"
}

teardown() {
  rm -rf "${TEST_KDIR:-}"
  unset LORE_KNOWLEDGE_DIR
}

json_line() { echo "$output" | grep '^{' | tail -1; }

@test "prepare freezes the v1 source fact calculation and response registries" {
  run bash "$PREPARE" cycle-a --window-start 2026-07-01T00:00:00Z --window-end 2026-07-02T00:00:00Z --json
  [ "$status" -eq 0 ]
  run python3 - "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json" <<'PY'
import json,sys,hashlib
p=json.load(open(sys.argv[1]))
assert set(p)=={"schema_version","pack_id","input_fingerprint","source_fingerprint","artifact_sha256","cycle","window","due_claim","source_manifest","facts","calculations","fixed_health","provenance"}
assert [r["source_id"] for r in p["source_manifest"]]==["cycle_work","due_queue","settlement","scorecard_rows","scorecard_current","session_events","journal","consumer_contradiction_lifecycle"]
assert set(p["facts"])=={"cycle_artifacts","task_context_backlinks","concerns_contradictions","session_retrieval_friction_packets","review_events","scale_signals","scorecard_eligibility_deltas","telemetry_attribution_rework","settlement_health_inputs"}
assert [r["calculation_id"] for r in p["calculations"]]==["channel_contract_drift","scorecard_delta_readiness","template_headline_readiness","audit_lag","audit_realization","trigger_realization","grounding_failure_rate","candidate_queue_backlog","judge_liveness","consumer_contradiction_routing"]
body={k:v for k,v in p.items() if k!="artifact_sha256"}
assert p["artifact_sha256"]==hashlib.sha256(json.dumps(body,ensure_ascii=False,sort_keys=True,separators=(",",":")).encode()).hexdigest()
PY
  [ "$status" -eq 0 ]
}

@test "absence and below-floor evidence are never green" {
  run bash "$PREPARE" cycle-a --window-start 2026-07-01T00:00:00Z --window-end 2026-07-02T00:00:00Z --json
  [ "$status" -eq 0 ]
  run jq -e '
    ([.source_manifest[] | select(.source_id=="consumer_contradiction_lifecycle") | .coverage=="not-computable" and .reason=="no-published-reader"] | all) and
    ([.calculations[] | select(.calculation_id=="candidate_queue_backlog") | .disposition=="not-computable"] | all) and
    ([.calculations[] | select(.calculation_id=="consumer_contradiction_routing") | .disposition=="not-computable"] | all) and
    ([.calculations[] | select(.calculation_id=="template_headline_readiness") | .disposition=="abstained" and .reason=="below-sample"] | all) and
    .fixed_health.state=="not-computable"
  ' "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
  [ "$status" -eq 0 ]
}

@test "exact replay is reused and keeps one prepare marker" {
  run bash "$PREPARE" cycle-a --window-start 2026-07-01T00:00:00Z --window-end 2026-07-02T00:00:00Z --json
  [ "$status" -eq 0 ]
  run bash "$PREPARE" cycle-a --window-start 2026-07-01T00:00:00Z --window-end 2026-07-02T00:00:00Z --json
  [ "$status" -eq 0 ]
  json_line | jq -e '.status=="reused" and .artifact.id!=null and .judgment_accepted==null'
  [ "$(grep -c '^Retro-prepare-atom:' "$TEST_KDIR/_work/cycle-a/execution-log.md")" -eq 1 ]
}

@test "matching pack without marker recovers the marker" {
  run bash "$PREPARE" cycle-a --window-start 2026-07-01T00:00:00Z --window-end 2026-07-02T00:00:00Z --json
  [ "$status" -eq 0 ]
  rm "$TEST_KDIR/_work/cycle-a/execution-log.md"
  run bash "$PREPARE" cycle-a --window-start 2026-07-01T00:00:00Z --window-end 2026-07-02T00:00:00Z --json
  [ "$status" -eq 0 ]
  json_line | jq -e '.status=="recovered"'
  [ "$(grep -c '^Retro-prepare-atom:' "$TEST_KDIR/_work/cycle-a/execution-log.md")" -eq 1 ]
}

@test "a new window replaces an unaccepted pack" {
  run bash "$PREPARE" cycle-a --window-start 2026-07-01T00:00:00Z --window-end 2026-07-02T00:00:00Z --json
  [ "$status" -eq 0 ]
  run bash "$PREPARE" cycle-a --window-start 2026-07-02T00:00:00Z --window-end 2026-07-03T00:00:00Z --json
  [ "$status" -eq 0 ]
  json_line | jq -e '.status=="replaced"'
}

@test "an accepted filing freezes pack replacement" {
  run bash "$PREPARE" cycle-a --window-start 2026-07-01T00:00:00Z --window-end 2026-07-02T00:00:00Z --json
  [ "$status" -eq 0 ]
  printf '{"schema_version":1}\n' > "$TEST_KDIR/_work/cycle-a/retro-filing.json"
  run bash "$PREPARE" cycle-a --window-start 2026-07-02T00:00:00Z --window-end 2026-07-03T00:00:00Z --json
  [ "$status" -eq 1 ]
  json_line | jq -e '.status=="refused" and .error.code=="accepted-pack-frozen"'
}

@test "prepare refuses missing or unordered explicit bounds" {
  run bash "$PREPARE" cycle-a --window-start 2026-07-01T00:00:00Z --json
  [ "$status" -eq 1 ]
  run bash "$PREPARE" cycle-a --window-start 2026-07-02T00:00:00Z --window-end 2026-07-01T00:00:00Z --json
  [ "$status" -eq 1 ]
}

@test "source byte changes alter source and pack fingerprints" {
  run bash "$PREPARE" cycle-a --window-start 2026-07-01T00:00:00Z --window-end 2026-07-02T00:00:00Z --json
  [ "$status" -eq 0 ]
  first="$(jq -r '.source_fingerprint+" "+.pack_id' "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json")"
  printf '{"schema_version":1,"kind":"telemetry","tier":"telemetry","calibration_state":"unknown"}\n' >> "$TEST_KDIR/_scorecards/rows.jsonl"
  run bash "$PREPARE" cycle-a --window-start 2026-07-01T00:00:00Z --window-end 2026-07-02T00:00:00Z --json
  [ "$status" -eq 0 ]
  second="$(jq -r '.source_fingerprint+" "+.pack_id' "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json")"
  [ "$first" != "$second" ]
}
