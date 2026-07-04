#!/usr/bin/env bats
# test_packet_append.bats — Shell-level tests for the _packets/ sole writers.
#
# Coverage per task #1 verification:
#   - A valid v1 row appends exactly one compacted line to
#     $KDIR/_packets/packets.jsonl; a row missing a required field exits
#     non-zero and leaves the file (and the _packets/ dir) untouched.
#   - Re-running the same append twice produces two rows (append-supersede,
#     no dedupe), and the seed-README states this posture together with the
#     prompt-context invariant.
#   - The assessment writer owns assessments.jsonl with the same
#     validate-before-disk contract.
#
# Style: pure bats with isolated $KDIR per test (scorecards-calibrate.bats).

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
PACKET_APPEND="$REPO_DIR/scripts/packet-append.sh"
ASSESSMENT_APPEND="$REPO_DIR/scripts/packet-assessment-append.sh"

setup() {
  [ -f "$PACKET_APPEND" ] || skip "packet-append.sh missing"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"

  TEST_KDIR="$(mktemp -d)"

  VALID_PACKET_ROW='{
    "packet_id": "pkt-bats-1",
    "packet_scope": "task",
    "delivery_stage": "assembled",
    "session_id": "sess-1",
    "work_item": "context-packet-as-evaluable-delivery-unit",
    "phase": 1,
    "task_id": "task-1",
    "arm": null,
    "task_scale_set": "subsystem,implementation",
    "delivered_entries": [
      {"path": "conventions/foo.md", "render_mode": "full", "ranking_path": "search-order",
       "trust": {"score": 0.667, "status": "current", "confidence": "high", "correction_recency": null}}
    ],
    "budget": {"chars_used": 1200, "chars_budget": 8000}
  }'

  VALID_ASSESSMENT_ROW='{
    "packet_id": "pkt-bats-1",
    "assessor_schema_sha": "0000000000000000000000000000000000000000000000000000000000000000",
    "source_transcript": "/sessions/abc.jsonl",
    "dispatch_confirmed": true,
    "unused": [],
    "harmful": [],
    "missing": [{"topic": "mkdir locks", "rationale": "worker re-derived from source"}],
    "unattributed_retrieval": []
  }'
}

teardown() {
  if [ -n "${TEST_KDIR:-}" ] && [ -d "$TEST_KDIR" ]; then
    rm -rf "$TEST_KDIR"
  fi
}

@test "valid packet row appends exactly one compacted line" {
  run bash "$PACKET_APPEND" --row "$VALID_PACKET_ROW" --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]

  ROWS="$TEST_KDIR/_packets/packets.jsonl"
  [ -f "$ROWS" ]
  [ "$(wc -l < "$ROWS" | tr -d ' ')" = "1" ]

  # Compact: exactly one line, valid JSON, writer stamps present.
  run jq -e '
    .schema_version == "1"
    and (.packet_schema_sha | test("^[0-9a-f]{64}$"))
    and (.trust_compute_sha | test("^[0-9a-f]{64}$"))
    and (.model == "unrecorded")
    and (.delivered_at != "")
    and (.template_version == null)
    and (has("captured_at_branch") and has("captured_at_sha") and has("captured_at_merge_base_sha"))
  ' "$ROWS"
  [ "$status" -eq 0 ]
}

@test "row missing a required field exits non-zero and leaves the store untouched" {
  BAD_ROW=$(printf '%s' "$VALID_PACKET_ROW" | jq 'del(.budget)')
  run bash "$PACKET_APPEND" --row "$BAD_ROW" --kdir "$TEST_KDIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "budget"

  # Validation precedes any disk touch: no _packets/ dir was created.
  [ ! -e "$TEST_KDIR/_packets" ]
}

@test "reject after a prior append leaves existing rows untouched" {
  bash "$PACKET_APPEND" --row "$VALID_PACKET_ROW" --kdir "$TEST_KDIR"
  BEFORE=$(cat "$TEST_KDIR/_packets/packets.jsonl")

  BAD_ROW=$(printf '%s' "$VALID_PACKET_ROW" | jq '.packet_scope = "bogus"')
  run bash "$PACKET_APPEND" --row "$BAD_ROW" --kdir "$TEST_KDIR"
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_KDIR/_packets/packets.jsonl")" = "$BEFORE" ]
}

@test "same append twice produces two rows (append-supersede, no dedupe)" {
  bash "$PACKET_APPEND" --row "$VALID_PACKET_ROW" --kdir "$TEST_KDIR"
  bash "$PACKET_APPEND" --row "$VALID_PACKET_ROW" --kdir "$TEST_KDIR"
  [ "$(wc -l < "$TEST_KDIR/_packets/packets.jsonl" | tr -d ' ')" = "2" ]
}

@test "seed-README states append-supersede posture and prompt-context invariant" {
  bash "$PACKET_APPEND" --row "$VALID_PACKET_ROW" --kdir "$TEST_KDIR"
  README="$TEST_KDIR/_packets/README.md"
  [ -f "$README" ]
  grep -q "Append-supersede posture (no dedupe)" "$README"
  grep -q "running the same append twice produces two" "$README"
  grep -q "Prompt-context invariant" "$README"
  grep -q "Sole-writer invariant" "$README"
}

@test "session scope requires null task_id" {
  BAD_ROW=$(printf '%s' "$VALID_PACKET_ROW" | jq '.packet_scope = "session" | .delivery_stage = "delivered"')
  run bash "$PACKET_APPEND" --row "$BAD_ROW" --kdir "$TEST_KDIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "task_id"

  GOOD_ROW=$(printf '%s' "$BAD_ROW" | jq '.task_id = null')
  run bash "$PACKET_APPEND" --row "$GOOD_ROW" --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
}

@test "empty delivered_entries requires empty_reason" {
  BAD_ROW=$(printf '%s' "$VALID_PACKET_ROW" | jq '.delivered_entries = []')
  run bash "$PACKET_APPEND" --row "$BAD_ROW" --kdir "$TEST_KDIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "empty_reason"

  GOOD_ROW=$(printf '%s' "$BAD_ROW" | jq '.empty_reason = "no entries above relevance floor"')
  run bash "$PACKET_APPEND" --row "$GOOD_ROW" --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
}

@test "--json emits a machine-readable receipt" {
  run bash "$PACKET_APPEND" --row "$VALID_PACKET_ROW" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.appended == true and .packet_id == "pkt-bats-1" and .packet_scope == "task"'
}

@test "assessment writer appends a valid row and stamps it" {
  run bash "$ASSESSMENT_APPEND" --row "$VALID_ASSESSMENT_ROW" --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]

  ROWS="$TEST_KDIR/_packets/assessments.jsonl"
  [ -f "$ROWS" ]
  [ "$(wc -l < "$ROWS" | tr -d ' ')" = "1" ]
  run jq -e '
    .schema_version == "1"
    and (.packet_schema_sha | test("^[0-9a-f]{64}$"))
    and (.assessed_at != "")
    and (.dispatch_confirmed == true)
  ' "$ROWS"
  [ "$status" -eq 0 ]
}

@test "assessment row with null verdict class and no reason is rejected" {
  BAD_ROW=$(printf '%s' "$VALID_ASSESSMENT_ROW" | jq '.missing = null')
  run bash "$ASSESSMENT_APPEND" --row "$BAD_ROW" --kdir "$TEST_KDIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "missing_not_assessable_reason"
  [ ! -e "$TEST_KDIR/_packets" ]

  GOOD_ROW=$(printf '%s' "$BAD_ROW" | jq '.missing_not_assessable_reason = "transcript truncated"')
  run bash "$ASSESSMENT_APPEND" --row "$GOOD_ROW" --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
}
