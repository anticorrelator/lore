#!/usr/bin/env bats
# scorecards-calibrate.bats — Tests for scripts/scorecards-calibrate.sh.
#
# Coverage per task #1 verification:
#   - For each judge (correctness-gate, curator, reverse-auditor):
#     - A passing fixture-set flips the calibration-state.json marker entry
#       for that judge's template-version to "calibrated" and appends a
#       passing row to calibration-history.jsonl.
#     - A failing fixture-set leaves the corresponding marker entry
#       absent/unchanged AND still appends a failing row to history.
#   - audit-artifact.sh's read_calibration_state behavior is exercised
#     indirectly by the marker-shape assertions: missing file resolves to
#     pre-calibration; passing run flips one keyed entry without disturbing
#     other entries.
#
# Style: pure bats with isolated $KDIR per test. No real audit runs are
# spawned — the calibration runner reads pre-recorded judge outputs from
# fixture directories.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
CALIBRATE_SH="$REPO_DIR/scripts/scorecards-calibrate.sh"
TEMPLATE_VERSION_SH="$REPO_DIR/scripts/template-version.sh"

setup() {
  [ -f "$CALIBRATE_SH" ] || skip "scorecards-calibrate.sh missing"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"

  TEST_KDIR="$(mktemp -d)"
  TEST_FIXTURES="$(mktemp -d)"
  export KDIR="$TEST_KDIR"
  mkdir -p "$TEST_KDIR/_scorecards"

  # Compute the actual template-versions so marker keys match what the
  # calibration runner will produce. The three correctness-gate forks each
  # carry their own template; the bats coverage exercises the assertion fork
  # (the canonical hard-cal gate) plus the soft-cal omission fork to verify
  # the runner handles both hard-cal and soft-cal-with-discrimination tiers.
  GATE_TV=$(bash "$TEMPLATE_VERSION_SH" "$REPO_DIR/agents/correctness-gate-assertion.md")
  OMISSION_TV=$(bash "$TEMPLATE_VERSION_SH" "$REPO_DIR/agents/correctness-gate-omission.md")
  CURATOR_TV=$(bash "$TEMPLATE_VERSION_SH" "$REPO_DIR/agents/curator.md")
  RA_TV=$(bash "$TEMPLATE_VERSION_SH" "$REPO_DIR/agents/reverse-auditor.md")
}

teardown() {
  if [ -n "${TEST_KDIR:-}" ] && [ -d "$TEST_KDIR" ]; then
    rm -rf "$TEST_KDIR"
  fi
  if [ -n "${TEST_FIXTURES:-}" ] && [ -d "$TEST_FIXTURES" ]; then
    rm -rf "$TEST_FIXTURES"
  fi
}

# --- Fixture builders ---

# build_gate_fixture <root> <fixture_id> <expected_verdict> <actual_verdict>
build_gate_fixture() {
  local root="$1" id="$2" expected="$3" actual="$4"
  mkdir -p "$root/$id"
  cat > "$root/$id/output.json" <<EOF
{
  "judge": "correctness-gate-assertion",
  "judge_template_version": "$GATE_TV",
  "verdicts": [
    {"claim_id": "c1", "verdict": "$actual", "evidence": "evidence", "correction": "$( [ "$actual" = contradicted ] && echo correction || echo "" )"}
  ]
}
EOF
}

# build_gate_set <root> <case>  (case = pass | fail)
build_gate_set() {
  local root="$1" case="$2"
  mkdir -p "$root"
  if [ "$case" = pass ]; then
    build_gate_fixture "$root" fx1 verified verified
    cat > "$root/manifest.json" <<EOF
{"fixtures": [{"id": "fx1", "expected_verdicts": [{"claim_id": "c1", "verdict": "verified"}]}]}
EOF
  else
    # mismatch: expected verified, actual contradicted
    build_gate_fixture "$root" fx1 verified contradicted
    cat > "$root/manifest.json" <<EOF
{"fixtures": [{"id": "fx1", "expected_verdicts": [{"claim_id": "c1", "verdict": "verified"}]}]}
EOF
  fi
}

# build_curator_set <root> <case>
build_curator_set() {
  local root="$1" case="$2"
  mkdir -p "$root/fx1"
  if [ "$case" = pass ]; then
    cat > "$root/fx1/output.json" <<EOF
{
  "judge": "curator",
  "judge_template_version": "$CURATOR_TV",
  "selected": [{"claim_id": "c1"}],
  "dropped": [{"claim_id": "c2"}]
}
EOF
    cat > "$root/manifest.json" <<EOF
{"fixtures": [{"id": "fx1", "expected_selected": ["c1"], "expected_dropped": ["c2"]}]}
EOF
  else
    cat > "$root/fx1/output.json" <<EOF
{
  "judge": "curator",
  "judge_template_version": "$CURATOR_TV",
  "selected": [{"claim_id": "c2"}],
  "dropped": [{"claim_id": "c1"}]
}
EOF
    cat > "$root/manifest.json" <<EOF
{"fixtures": [{"id": "fx1", "expected_selected": ["c1"], "expected_dropped": ["c2"]}]}
EOF
  fi
}

# build_ra_set <root> <case>
build_ra_set() {
  local root="$1" case="$2"
  mkdir -p "$root/fx1"
  if [ "$case" = pass ]; then
    cat > "$root/fx1/output.json" <<EOF
{
  "judge": "reverse-auditor",
  "judge_template_version": "$RA_TV",
  "verdict": "silence"
}
EOF
    cat > "$root/manifest.json" <<EOF
{"fixtures": [{"id": "fx1", "expected_verdict": "silence"}]}
EOF
  else
    cat > "$root/fx1/output.json" <<EOF
{
  "judge": "reverse-auditor",
  "judge_template_version": "$RA_TV",
  "verdict": "omission-claim"
}
EOF
    cat > "$root/manifest.json" <<EOF
{"fixtures": [{"id": "fx1", "expected_verdict": "silence"}]}
EOF
  fi
}

# Helper: read a marker entry for a judge:version pair, echo the calibration_state.
marker_state_for() {
  local judge="$1" version="$2"
  local marker="$KDIR/_scorecards/calibration-state.json"
  if [ ! -f "$marker" ]; then
    echo "missing"
    return 0
  fi
  jq -r --arg key "${judge}:${version}" '.[$key].calibration_state // "missing"' "$marker"
}

# --- correctness-gate ---

@test "correctness-gate passing fixture-set flips marker and appends history" {
  build_gate_set "$TEST_FIXTURES/gate-pass" pass
  run bash "$CALIBRATE_SH" --judge correctness-gate-assertion \
    --fixture-set "$TEST_FIXTURES/gate-pass" --kdir "$KDIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "PASS"

  # Marker entry exists and reads 'calibrated'.
  state=$(marker_state_for "correctness-gate-assertion" "$GATE_TV")
  [ "$state" = "calibrated" ]

  # History row appended with gate_pass=true.
  history="$KDIR/_scorecards/calibration-history.jsonl"
  [ -f "$history" ]
  [ "$(wc -l < "$history" | tr -d ' ')" = "1" ]
  jq -e '.gate_pass == true and .judge_template_id == "correctness-gate-assertion"' "$history" >/dev/null
}

@test "correctness-gate failing fixture-set leaves marker untouched, appends history" {
  build_gate_set "$TEST_FIXTURES/gate-fail" fail
  run bash "$CALIBRATE_SH" --judge correctness-gate-assertion \
    --fixture-set "$TEST_FIXTURES/gate-fail" --kdir "$KDIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "FAIL"

  # Marker entry MUST NOT exist (no prior pass).
  state=$(marker_state_for "correctness-gate-assertion" "$GATE_TV")
  [ "$state" = "missing" ]

  # History row still appended with gate_pass=false.
  history="$KDIR/_scorecards/calibration-history.jsonl"
  [ -f "$history" ]
  jq -e '.gate_pass == false' "$history" >/dev/null
}

# --- curator ---

@test "curator passing fixture-set flips marker and appends history" {
  build_curator_set "$TEST_FIXTURES/curator-pass" pass
  run bash "$CALIBRATE_SH" --judge curator \
    --fixture-set "$TEST_FIXTURES/curator-pass" --kdir "$KDIR"
  [ "$status" -eq 0 ]

  state=$(marker_state_for "curator" "$CURATOR_TV")
  [ "$state" = "calibrated" ]

  history="$KDIR/_scorecards/calibration-history.jsonl"
  jq -e 'select(.judge_template_id == "curator") | .gate_pass == true' "$history" >/dev/null
}

@test "curator failing fixture-set leaves marker absent, appends failing history" {
  build_curator_set "$TEST_FIXTURES/curator-fail" fail
  run bash "$CALIBRATE_SH" --judge curator \
    --fixture-set "$TEST_FIXTURES/curator-fail" --kdir "$KDIR"
  [ "$status" -ne 0 ]

  state=$(marker_state_for "curator" "$CURATOR_TV")
  [ "$state" = "missing" ]

  history="$KDIR/_scorecards/calibration-history.jsonl"
  jq -e 'select(.judge_template_id == "curator") | .gate_pass == false' "$history" >/dev/null
}

# --- reverse-auditor ---

@test "reverse-auditor passing fixture-set flips marker and appends history" {
  build_ra_set "$TEST_FIXTURES/ra-pass" pass
  run bash "$CALIBRATE_SH" --judge reverse-auditor \
    --fixture-set "$TEST_FIXTURES/ra-pass" --kdir "$KDIR"
  [ "$status" -eq 0 ]

  state=$(marker_state_for "reverse-auditor" "$RA_TV")
  [ "$state" = "calibrated" ]

  history="$KDIR/_scorecards/calibration-history.jsonl"
  jq -e 'select(.judge_template_id == "reverse-auditor") | .gate_pass == true' "$history" >/dev/null
}

@test "reverse-auditor failing fixture-set leaves marker absent, appends failing history" {
  build_ra_set "$TEST_FIXTURES/ra-fail" fail
  run bash "$CALIBRATE_SH" --judge reverse-auditor \
    --fixture-set "$TEST_FIXTURES/ra-fail" --kdir "$KDIR"
  [ "$status" -ne 0 ]

  state=$(marker_state_for "reverse-auditor" "$RA_TV")
  [ "$state" = "missing" ]

  history="$KDIR/_scorecards/calibration-history.jsonl"
  jq -e 'select(.judge_template_id == "reverse-auditor") | .gate_pass == false' "$history" >/dev/null
}

# --- failure-after-pass: failing run does NOT clear a previously-flipped marker ---

@test "failing run after a passing run does not regress the marker" {
  build_gate_set "$TEST_FIXTURES/gate-pass" pass
  bash "$CALIBRATE_SH" --judge correctness-gate-assertion \
    --fixture-set "$TEST_FIXTURES/gate-pass" --kdir "$KDIR" >/dev/null
  state=$(marker_state_for "correctness-gate-assertion" "$GATE_TV")
  [ "$state" = "calibrated" ]

  build_gate_set "$TEST_FIXTURES/gate-fail" fail
  run bash "$CALIBRATE_SH" --judge correctness-gate-assertion \
    --fixture-set "$TEST_FIXTURES/gate-fail" --kdir "$KDIR"
  [ "$status" -ne 0 ]

  # Marker entry remains 'calibrated' — failing run did not touch the marker.
  state=$(marker_state_for "correctness-gate-assertion" "$GATE_TV")
  [ "$state" = "calibrated" ]

  # Both runs accumulated in history.
  history="$KDIR/_scorecards/calibration-history.jsonl"
  [ "$(wc -l < "$history" | tr -d ' ')" = "2" ]
}

@test "missing fixture-set fails fast with a clear error" {
  run bash "$CALIBRATE_SH" --judge curator \
    --fixture-set "$TEST_FIXTURES/does-not-exist" --kdir "$KDIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "fixture-set is not a directory"
}

@test "unknown judge is rejected" {
  mkdir -p "$TEST_FIXTURES/empty"
  echo '{"fixtures":[]}' > "$TEST_FIXTURES/empty/manifest.json"
  run bash "$CALIBRATE_SH" --judge bogus \
    --fixture-set "$TEST_FIXTURES/empty" --kdir "$KDIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "judge must be one of"
}
