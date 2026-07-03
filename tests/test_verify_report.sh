#!/usr/bin/env bash
# test_verify_report.sh — Tests for the producer-facing consumption report:
# verify-report.sh (`lore verify --report`).
#
# Covers:
#   - Scope validation: no scope and multiple scopes reject (exit 1)
#   - Empty ledger / no matching events → empty report, exit 0 (not failure)
#   - --entry: held/contradicted counts and per-event evidence lines
#     (disposition, file:line-range, source, work item) recomputable from
#     the raw ledger rows
#   - --work-item / --source: entry set resolved from capture footers;
#     zero-event entries still listed
#   - mechanical-check and adjudication events counted and itemized
#   - provenance-migration events listed with from -> to
#   - Retrieval-load join: prefetch/manifest_load loaded_paths counted,
#     search rows ignored; missing retrieval log degrades to a note
#   - Malformed ledger rows skipped with a warning, valid rows still reported
#   - --json structure matches the human counts
#   - Read-only: the report never mutates the ledger

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
REPORT="$SCRIPT_DIR/verify-report.sh"
APPEND="$SCRIPT_DIR/trust-event-append.sh"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"
LEDGER="$KNOWLEDGE_DIR/_trust/trust-events.jsonl"
ENTRY_A="conventions/entry-a.md"
ENTRY_B="conventions/entry-b.md"

PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_contains() {
  local label="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF -- "$expected"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected to contain: $expected"
    echo "    Got: $(echo "$output" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" output="$2" unexpected="$3"
  if echo "$output" | grep -qF -- "$unexpected"; then
    echo "  FAIL: $label — output contains: $unexpected"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

setup_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR/conventions" "$KNOWLEDGE_DIR/_meta"
  echo '{"format_version": 2}' > "$KNOWLEDGE_DIR/_manifest.json"
  printf '# Entry A\n\nA claim.\n\n<!-- learned: 2026-07-03 | source: lore-promote | work_item: wi-alpha | scale: implementation -->\n' \
    > "$KNOWLEDGE_DIR/$ENTRY_A"
  printf '# Entry B\n\nAnother claim.\n\n<!-- learned: 2026-07-03 | source: manual | work_item: wi-alpha | scale: implementation -->\n' \
    > "$KNOWLEDGE_DIR/$ENTRY_B"
}

seed_events() {
  bash "$APPEND" --event consumption-verification --entry-path "$ENTRY_A" \
    --source worker --disposition held \
    --file /abs/src/foo.sh --line-range 10-12 --exact-snippet 'set -euo pipefail' \
    --work-item wi-consumer --observed-at 2026-07-01T10:00:00Z \
    --kdir "$KNOWLEDGE_DIR" --json > /dev/null
  bash "$APPEND" --event consumption-verification --entry-path "$ENTRY_A" \
    --source researcher --disposition contradicted \
    --file /abs/src/bar.py --line-range 5 --exact-snippet 'return None' \
    --rationale 'code returns None, entry says it raises' \
    --work-item wi-consumer --observed-at 2026-07-02T11:00:00Z \
    --kdir "$KNOWLEDGE_DIR" --json > /dev/null
  bash "$APPEND" --event mechanical-check --entry-path "$ENTRY_A" \
    --source drift-sweep --check-name drift-anchor --target 'conventions/entry-a.md#claim' \
    --result fail --run-id run-1 --observed-at 2026-07-02T12:00:00Z \
    --kdir "$KNOWLEDGE_DIR" --json > /dev/null
  bash "$APPEND" --event adjudication --entry-path "$ENTRY_A" \
    --source audit --claim-id ver-abc123 --verdict confirmed \
    --template-id correctness-gate-assertion --template-version abcd1234 \
    --run-id run-2 --observed-at 2026-07-02T13:00:00Z \
    --kdir "$KNOWLEDGE_DIR" --json > /dev/null
}

echo "=== verify-report.sh tests ==="

echo ""
echo "Test: missing scope rejects"
setup_store
set +e
OUT=$(bash "$REPORT" --kdir "$KNOWLEDGE_DIR" 2>&1)
RC=$?
set -e
assert_eq "exit code 1" "$RC" "1"
assert_contains "names the scope flags" "$OUT" "--entry <path>, --work-item <slug>, or --source <identity>"

echo ""
echo "Test: multiple scopes reject"
set +e
OUT=$(bash "$REPORT" --entry "$ENTRY_A" --work-item wi-alpha --kdir "$KNOWLEDGE_DIR" 2>&1)
RC=$?
set -e
assert_eq "exit code 1" "$RC" "1"
assert_contains "mutually exclusive error" "$OUT" "mutually exclusive"

echo ""
echo "Test: unknown flag rejects"
set +e
OUT=$(bash "$REPORT" --entry "$ENTRY_A" --bogus x --kdir "$KNOWLEDGE_DIR" 2>&1)
RC=$?
set -e
assert_eq "exit code 1" "$RC" "1"

echo ""
echo "Test: empty ledger → empty report, exit 0"
setup_store
set +e
OUT=$(bash "$REPORT" --entry "$ENTRY_A" --kdir "$KNOWLEDGE_DIR" 2>/dev/null)
RC=$?
set -e
assert_eq "exit code 0" "$RC" "0"
assert_contains "zero events in header" "$OUT" "0 ledger events"
assert_contains "entry listed with no events" "$OUT" "no ledger events"

echo ""
echo "Test: --entry projects per-event evidence, not bare counts"
seed_events
OUT=$(bash "$REPORT" --entry "$ENTRY_A" --kdir "$KNOWLEDGE_DIR" 2>/dev/null)
assert_contains "held/contradicted counts" "$OUT" "verifications: 1 held, 1 contradicted"
assert_contains "held anchor file:line" "$OUT" "/abs/src/foo.sh:10-12"
assert_contains "held source attribution" "$OUT" "source=worker"
assert_contains "held work item" "$OUT" "work-item=wi-consumer"
assert_contains "held snippet shown" "$OUT" "set -euo pipefail"
assert_contains "contradicted anchor" "$OUT" "/abs/src/bar.py:5"
assert_contains "contradiction rationale shown" "$OUT" "code returns None, entry says it raises"
assert_contains "mechanical check itemized" "$OUT" "fail   drift-anchor target=conventions/entry-a.md#claim run=run-1"
assert_contains "mechanical check summary" "$OUT" "mechanical checks: 1 fail"
assert_contains "adjudication counts" "$OUT" "adjudications: 1 confirmed, 0 rejected"
assert_contains "adjudication template identity" "$OUT" "template=correctness-gate-assertion@abcd1234"

echo ""
echo "Test: --entry accepts a .md-less path"
OUT=$(bash "$REPORT" --entry "conventions/entry-a" --kdir "$KNOWLEDGE_DIR" 2>/dev/null)
assert_contains "resolves to the entry" "$OUT" "conventions/entry-a.md"
assert_contains "events found" "$OUT" "4 ledger events"

echo ""
echo "Test: --work-item scope resolves entries from capture footers"
OUT=$(bash "$REPORT" --work-item wi-alpha --kdir "$KNOWLEDGE_DIR" 2>/dev/null)
assert_contains "two entries in scope" "$OUT" "2 entries"
assert_contains "entry A listed" "$OUT" "$ENTRY_A"
assert_contains "entry B listed despite zero events" "$OUT" "$ENTRY_B"
assert_contains "zero-event entry is legible" "$OUT" "no ledger events"

echo ""
echo "Test: --source scope resolves entries from capture footers"
OUT=$(bash "$REPORT" --source lore-promote --kdir "$KNOWLEDGE_DIR" 2>/dev/null)
assert_contains "entry A in scope" "$OUT" "$ENTRY_A"
assert_not_contains "entry B (source=manual) excluded" "$OUT" "$ENTRY_B"

echo ""
echo "Test: no entries match scope → empty report, exit 0"
set +e
OUT=$(bash "$REPORT" --work-item no-such-item --kdir "$KNOWLEDGE_DIR" 2>/dev/null)
RC=$?
set -e
assert_eq "exit code 0" "$RC" "0"
assert_contains "empty scope is legible" "$OUT" "no entries match this scope"

echo ""
echo "Test: provenance-migration listed with from -> to"
bash "$APPEND" --event provenance-migration --entry-path "$ENTRY_A" \
  --source apply-correction --from-entry-path "conventions/entry-a-superseded-2026-07-01.md" \
  --to-entry-path "$ENTRY_A" --reason l3-supersede \
  --observed-at 2026-07-02T14:00:00Z --kdir "$KNOWLEDGE_DIR" --json > /dev/null
OUT=$(bash "$REPORT" --entry "$ENTRY_A" --kdir "$KNOWLEDGE_DIR" 2>/dev/null)
assert_contains "migration from -> to" "$OUT" "conventions/entry-a-superseded-2026-07-01.md -> $ENTRY_A"
assert_contains "old-path pointer" "$OUT" "--entry conventions/entry-a-superseded-2026-07-01.md"

echo ""
echo "Test: retrieval loads join prefetch/manifest_load, ignore search"
cat > "$KNOWLEDGE_DIR/_meta/retrieval-log.jsonl" <<EOF
{"timestamp":"2026-07-01T09:00:00Z","event":"prefetch","loaded_paths":["$ENTRY_A"]}
{"timestamp":"2026-07-02T09:00:00Z","event":"prefetch","loaded_paths":["$ENTRY_A","$ENTRY_B"]}
{"timestamp":"2026-07-02T10:00:00Z","event":"manifest_load","loaded_paths":["$ENTRY_A"]}
{"timestamp":"2026-07-02T11:00:00Z","event":"search","query":"entry-a"}
{"timestamp":"2026-02-07T21:01:54Z","budget_used":8004,"budget_total":8000}
EOF
OUT=$(bash "$REPORT" --entry "$ENTRY_A" --kdir "$KNOWLEDGE_DIR" 2>/dev/null)
assert_contains "load count with breakdown" "$OUT" "retrieval loads: 3 (manifest_load 1, prefetch 2; last 2026-07-02T10:00:00Z)"
assert_contains "search join-key note" "$OUT" "search rows carry no per-entry join key"

echo ""
echo "Test: missing retrieval log degrades to a note"
rm "$KNOWLEDGE_DIR/_meta/retrieval-log.jsonl"
ERR=$(bash "$REPORT" --entry "$ENTRY_A" --kdir "$KNOWLEDGE_DIR" 2>&1 >/dev/null)
assert_contains "legible degradation warning" "$ERR" "retrieval log not found"

echo ""
echo "Test: malformed ledger row skipped with warning, valid rows survive"
echo 'this is not json' >> "$LEDGER"
set +e
OUT=$(bash "$REPORT" --entry "$ENTRY_A" --kdir "$KNOWLEDGE_DIR" 2>/dev/null)
RC=$?
ERR=$(bash "$REPORT" --entry "$ENTRY_A" --kdir "$KNOWLEDGE_DIR" 2>&1 >/dev/null)
set -e
assert_eq "exit code 0" "$RC" "0"
assert_contains "malformed-row warning" "$ERR" "malformed ledger row skipped"
assert_contains "valid rows still counted" "$OUT" "verifications: 1 held, 1 contradicted"

echo ""
echo "Test: --json counts match the human report"
OUT=$(bash "$REPORT" --entry "$ENTRY_A" --kdir "$KNOWLEDGE_DIR" --json 2>/dev/null)
assert_eq "held count" "$(echo "$OUT" | jq -r '.entries[0].verifications.held')" "1"
assert_eq "contradicted count" "$(echo "$OUT" | jq -r '.entries[0].verifications.contradicted')" "1"
assert_eq "mechanical fail count" "$(echo "$OUT" | jq -r '.entries[0].mechanical_checks.by_result.fail')" "1"
assert_eq "adjudication confirmed" "$(echo "$OUT" | jq -r '.entries[0].adjudications.confirmed')" "1"
assert_eq "migration count" "$(echo "$OUT" | jq -r '.entries[0].migrations | length')" "1"
assert_eq "verification anchor in JSON" \
  "$(echo "$OUT" | jq -r '.entries[0].verifications.events[0].file')" "/abs/src/foo.sh"

echo ""
echo "Test: report is read-only (ledger byte-identical across runs)"
BEFORE=$(shasum "$LEDGER")
bash "$REPORT" --work-item wi-alpha --kdir "$KNOWLEDGE_DIR" > /dev/null 2>&1
bash "$REPORT" --entry "$ENTRY_A" --kdir "$KNOWLEDGE_DIR" --json > /dev/null 2>&1
AFTER=$(shasum "$LEDGER")
assert_eq "ledger unchanged" "$AFTER" "$BEFORE"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
