#!/usr/bin/env bash
# Contract tests for the canonical consumption-contradiction append/update writers.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPEND="$REPO_DIR/scripts/consumption-contradiction-append.sh"
UPDATE="$REPO_DIR/scripts/consumption-contradiction-update-status.sh"
TEST_DIR=$(mktemp -d)
KDIR="$TEST_DIR/knowledge"
SLUG="writer-fixture"
PASS=0
FAIL=0
trap 'rm -rf "$TEST_DIR"' EXIT

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected=$expected actual=$actual)"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (missing=$expected)"
    FAIL=$((FAIL + 1))
  fi
}

setup_store() {
  rm -rf "$KDIR"
  mkdir -p "$KDIR/_work/$SLUG" "$KDIR/_work/_archive" "$KDIR/_scorecards"
  echo '{"format_version":2}' > "$KDIR/_manifest.json"
}

append_row() {
  local status="${1:-pending}" cid="${2:-ctr-writer}"
  "$APPEND" \
    --work-item "$SLUG" --source worker --producer-role impl-worker \
    --protocol-slot implement-step-3 --cycle-id cycle-1 \
    --knowledge-path architecture/audit-pipeline/contract --heading Contract \
    --contradiction-rationale "code disagrees" --claim-id claim-1 \
    --claim-text "one claim" --file /tmp/example.py --line-range 10-12 \
    --exact-snippet 'value = 1' --falsifier "value changes" \
    --status "$status" --contradiction-id "$cid" --kdir "$KDIR" >/dev/null
}

echo "=== consumption-contradiction writer contract ==="

setup_store
append_row contradicted ctr-append-contradicted
ROW=$(cat "$KDIR/_work/$SLUG/consumption-contradictions.jsonl")
assert_eq "append accepts canonical contradicted" "$(jq -r .status <<<"$ROW")" "contradicted"

setup_store
EXIT=0
ERR=$(append_row rejected ctr-rejected 2>&1) || EXIT=$?
assert_eq "append rejects retired rejected token" "$EXIT" "1"
assert_contains "append error names canonical contradicted token" "$ERR" "contradicted"

setup_store
append_row pending ctr-active
BEFORE=$(jq -c 'del(.status)' "$KDIR/_work/$SLUG/consumption-contradictions.jsonl")
OUT=$("$UPDATE" --kdir "$KDIR" --work-item "$SLUG" --contradiction-id ctr-active \
  --status verified --settled-at 2026-06-01T02:03:04Z --settled-by-run-id run-active --json)
JSON=$(printf '%s\n' "$OUT" | head -n1)
ROW=$(cat "$KDIR/_work/$SLUG/consumption-contradictions.jsonl")
assert_eq "active transition reports applied" "$(jq -r .status <<<"$JSON")" "applied"
assert_eq "active transition reports active location" "$(jq -r .sidecar_location <<<"$JSON")" "active"
assert_eq "active status becomes verified" "$(jq -r .status <<<"$ROW")" "verified"
assert_eq "writer preserves supplied completion time" "$(jq -r .settled_at <<<"$ROW")" "2026-06-01T02:03:04Z"
assert_eq "writer records settling run" "$(jq -r .settled_by_run_id <<<"$ROW")" "run-active"
assert_eq "all non-settlement fields are preserved" "$(jq -c 'del(.status,.settled_at,.settled_by_run_id)' <<<"$ROW")" "$BEFORE"

HASH1=$(shasum -a 256 "$KDIR/_work/$SLUG/consumption-contradictions.jsonl" | awk '{print $1}')
OUT=$("$UPDATE" --kdir "$KDIR" --work-item "$SLUG" --contradiction-id ctr-active \
  --status verified --settled-at 2026-06-02T00:00:00Z --settled-by-run-id run-other --json)
JSON=$(printf '%s\n' "$OUT" | head -n1)
HASH2=$(shasum -a 256 "$KDIR/_work/$SLUG/consumption-contradictions.jsonl" | awk '{print $1}')
assert_eq "same-terminal retry is idempotent" "$(jq -r .status <<<"$JSON")" "idempotent"
assert_eq "idempotent retry is byte preserving" "$HASH2" "$HASH1"

EXIT=0
ERR=$("$UPDATE" --kdir "$KDIR" --work-item "$SLUG" --contradiction-id ctr-active \
  --status contradicted --settled-at 2026-06-02T00:00:00Z 2>&1) || EXIT=$?
assert_eq "conflicting terminal rewrite is refused" "$EXIT" "1"
assert_contains "conflict error carries both terminal states" "$ERR" "verified->contradicted"
assert_eq "conflict leaves original terminal status" "$(jq -r .status "$KDIR/_work/$SLUG/consumption-contradictions.jsonl")" "verified"

setup_store
append_row pending ctr-archive
mkdir -p "$KDIR/_work/_archive/$SLUG"
mv "$KDIR/_work/$SLUG/consumption-contradictions.jsonl" "$KDIR/_work/_archive/$SLUG/"
rmdir "$KDIR/_work/$SLUG"
OUT=$("$UPDATE" --kdir "$KDIR" --work-item "$SLUG" --contradiction-id ctr-archive \
  --status contradicted --settled-at 2026-05-01T00:00:00+00:00 --json)
JSON=$(printf '%s\n' "$OUT" | head -n1)
assert_eq "archived sidecar is reachable" "$(jq -r .sidecar_location <<<"$JSON")" "archive"
assert_eq "archived row takes contradicted unchanged" "$(jq -r .status "$KDIR/_work/_archive/$SLUG/consumption-contradictions.jsonl")" "contradicted"

mkdir -p "$KDIR/_work/$SLUG"
cp "$KDIR/_work/_archive/$SLUG/consumption-contradictions.jsonl" "$KDIR/_work/$SLUG/consumption-contradictions.jsonl"
EXIT=0
ERR=$("$UPDATE" --kdir "$KDIR" --work-item "$SLUG" --contradiction-id ctr-archive \
  --status contradicted --settled-at 2026-05-01T00:00:00Z 2>&1) || EXIT=$?
assert_eq "active/archive duplicate is refused" "$EXIT" "1"
assert_contains "ambiguity error identifies active/archive" "$ERR" "ambiguous active/archive identity"

setup_store
append_row pending ctr-validation
EXIT=0
ERR=$("$UPDATE" --kdir "$KDIR" --contradiction-id ctr-validation --status verified \
  --settled-at 2026-01-01T00:00:00Z 2>&1) || EXIT=$?
assert_eq "work-item identity is required" "$EXIT" "1"
assert_contains "missing identity error names work-item" "$ERR" "--work-item is required"

EXIT=0
ERR=$("$UPDATE" --kdir "$KDIR" --work-item "$SLUG" --contradiction-id ctr-validation \
  --status rejected --settled-at 2026-01-01T00:00:00Z 2>&1) || EXIT=$?
assert_eq "retired updater status is rejected" "$EXIT" "1"
assert_contains "updater error names contradicted" "$ERR" "contradicted"

EXIT=0
ERR=$("$UPDATE" --kdir "$KDIR" --work-item "$SLUG" --contradiction-id ctr-validation \
  --status verified --settled-at 'not-a-time' 2>&1) || EXIT=$?
assert_eq "invalid settlement timestamp is rejected in writer" "$EXIT" "1"
assert_contains "timestamp error identifies settled-at" "$ERR" "--settled-at"
assert_eq "validation failures leave row pending" "$(jq -r .status "$KDIR/_work/$SLUG/consumption-contradictions.jsonl")" "pending"

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
