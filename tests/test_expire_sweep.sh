#!/usr/bin/env bash
# test_expire_sweep.sh — Tests for the epistemic expiry sweep: expire-sweep.py's
# candidate selection, expire-sweep.sh's write path, and the `expired` entry
# status it lands.
#
# The sweep is the only thing in this substrate that mutates entries unattended
# and appends to a durable ledger, so the tests that matter most are the ones
# asserting what it does NOT touch. Wherever the claim is "nothing changed", the
# assertion hashes the entry tree and the ledger rather than reading stdout — a
# summary line saying "no changes" is exactly what a broken sweep would also
# print.
#
# Covers, in the order these properties are worth protecting:
#   - Recency comes from declared footer timestamps, not filesystem mtime: an
#     entry with an old `learned` date but a recent corroboration is NOT a
#     candidate, and touching every file does not change the candidate set
#   - A second run over an already-swept store mutates no entry and appends no
#     ledger row (state-convergent idempotency, checked by hash)
#   - --dry-run creates no ledger file and leaves every entry byte-identical
#   - Selection rules, one case each: stale-untested, stale-open, fresh-untested,
#     stale-but-settled, fact, footerless, already-retired
#   - Expire then restore returns the status the entry held, not `current`
#   - `expired` and `retired` are distinguishable in both the entry status and
#     the retirement id prefix
#   - An expired entry keeps its file, its path, and its body, and carries a
#     reason and falsifier with no footer-hostile characters
#   - The documented interruption behavior: entry mutated with no ledger event,
#     a later sweep skips it, and recovery by name appends the event the sweep
#     would have written
#   - The sweep reports as `expire-sweep` in the ledger
#
# Two of these are mutation-checked at the bottom: the suite deliberately breaks
# the timestamp-source rule and the already-expired skip and asserts that the
# corresponding tests go red, so we know the suite constrains the code rather
# than merely accompanying it.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_DIR/scripts"
SWEEP="$SCRIPT_DIR/expire-sweep.sh"
EMIT="$SCRIPT_DIR/expire-sweep.py"
MUTATE="$SCRIPT_DIR/apply-correction.sh"
RETIRE="$SCRIPT_DIR/retire-append.sh"
FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/make-epistemic-store.sh"

TEST_DIR=$(mktemp -d)
KDIR="$TEST_DIR/knowledge"
LEDGER="$KDIR/_trust/trust-events.jsonl"

# Fixed so day arithmetic in the assertions never depends on when the suite runs.
TODAY="2026-08-09"
DAYS=180

PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"; echo "    Expected: $expected"; echo "    Actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF -- "$expected"; then
    echo "  PASS: $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"; echo "    Expected to contain: $expected"
    echo "    Got: $(echo "$output" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" output="$2" unexpected="$3"
  if echo "$output" | grep -qF -- "$unexpected"; then
    echo "  FAIL: $label"; echo "    Expected NOT to contain: $unexpected"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"; PASS=$((PASS + 1))
  fi
}

setup_store() { bash "$FIXTURE" "$KDIR" >/dev/null; }

# Every .md in the store, content-hashed. The whole point of using this over
# stdout is that it catches a write the summary line does not mention.
tree_hash() {
  find "$KDIR" -name '*.md' -type f -exec shasum {} \; | sort | shasum | awk '{print $1}'
}

ledger_hash() {
  if [[ -f "$LEDGER" ]]; then shasum "$LEDGER" | awk '{print $1}'; else echo "absent"; fi
}

candidates() {
  python3 "$EMIT" "$KDIR" --days "$DAYS" --today "$TODAY" "$@" \
    | python3 -c 'import json,sys; print(" ".join(sorted(c["entry_path"] for c in json.load(sys.stdin)["candidates"])))'
}

skipped_count() {
  python3 "$EMIT" "$KDIR" --days "$DAYS" --today "$TODAY" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['skipped']['$1'])"
}

footer_status() {
  grep -oE '\| status: [a-z]+' "$KDIR/$1" | tail -1 | awk '{print $3}'
}

echo "=== Expiry sweep tests ==="
echo ""

# =============================================
# Test 1: recency is declared, not filesystem
# =============================================
# The guarantee most likely to be lost in a refactor: any store-wide rewrite
# resets mtime uniformly, so an mtime-based sweep would expire everything at
# once. Both halves are asserted — a recent corroboration on an old entry
# protects it, and touching every file changes nothing.
echo "Test 1: recency comes from declared footer timestamps, not mtime"
setup_store
SELECTED=$(candidates)
assert_contains "the stale untested hypothesis is a candidate" "$SELECTED" "conventions/stale-untested-hypothesis.md"
assert_not_contains "an old entry corroborated recently is NOT a candidate" "$SELECTED" "conventions/recently-corroborated-hypothesis.md"

BEFORE_SET="$SELECTED"
find "$KDIR" -name '*.md' -exec touch {} +
assert_eq "touching every file leaves the candidate set unchanged" "$(candidates)" "$BEFORE_SET"

OLD_LEARNED=$(grep -oE 'learned: [0-9-]+' "$KDIR/conventions/recently-corroborated-hypothesis.md" | awk '{print $2}')
assert_eq "the protected entry's own learned date is genuinely old" "$OLD_LEARNED" "2025-03-01"

# =============================================
# Test 2: a second run writes nothing
# =============================================
echo ""
echo "Test 2: a second run over an already-swept store writes nothing"
setup_store
bash "$SWEEP" --days "$DAYS" --today "$TODAY" --kdir "$KDIR" >/dev/null 2>&1
FIRST_TREE=$(tree_hash)
FIRST_LEDGER=$(ledger_hash)
assert_eq "the first run appended two ledger rows" "$(wc -l < "$LEDGER" | tr -d ' ')" "2"

SECOND_OUT=$(bash "$SWEEP" --days "$DAYS" --today "$TODAY" --kdir "$KDIR" 2>&1)
assert_eq "second run leaves every entry byte-identical" "$(tree_hash)" "$FIRST_TREE"
assert_eq "second run appends no ledger row" "$(ledger_hash)" "$FIRST_LEDGER"
assert_contains "and says so" "$SECOND_OUT" "no changes"
assert_eq "the emitter skipped them as already out of the default set" "$(skipped_count already_out_of_default)" "3"

# =============================================
# Test 3: --dry-run writes nothing at all
# =============================================
echo ""
echo "Test 3: --dry-run leaves the store untouched"
setup_store
DRY_TREE=$(tree_hash)
DRY_OUT=$(bash "$SWEEP" --days "$DAYS" --today "$TODAY" --kdir "$KDIR" --dry-run 2>&1)
assert_eq "no entry changed" "$(tree_hash)" "$DRY_TREE"
assert_eq "no ledger file was created" "$(ledger_hash)" "absent"
assert_contains "the run reports what it would do" "$DRY_OUT" "would be expired"
assert_contains "and says nothing was written" "$DRY_OUT" "nothing was written"

# A real run afterwards must behave exactly like a first run — the dry run left
# no state that could make the second attempt converge early.
REAL_OUT=$(bash "$SWEEP" --days "$DAYS" --today "$TODAY" --kdir "$KDIR" 2>&1)
assert_contains "a real run afterwards still expires both" "$REAL_OUT" "2 expired"

# =============================================
# Test 4: selection rules, one case each
# =============================================
echo ""
echo "Test 4: candidate selection"
setup_store
SELECTED=$(candidates)
assert_contains "stale + untested hypothesis selected" "$SELECTED" "conventions/stale-untested-hypothesis.md"
assert_contains "stale + open question selected" "$SELECTED" "gotchas/stale-open-question.md"
assert_not_contains "fresh untested hypothesis not selected" "$SELECTED" "conventions/fresh-untested-hypothesis.md"
assert_not_contains "stale but settled hypothesis not selected" "$SELECTED" "conventions/stale-supported-hypothesis.md"
assert_not_contains "a plain fact is never selected" "$SELECTED" "conventions/stale-plain-fact.md"
assert_not_contains "an entry with no kind is never selected" "$SELECTED" "conventions/legacy-no-kind.md"
assert_not_contains "an already-retired entry is not selected" "$SELECTED" "conventions/already-retired-hypothesis.md"
assert_eq "exactly two candidates" "$(echo "$SELECTED" | wc -w | tr -d ' ')" "2"
assert_eq "kinds with no lifecycle are counted as skipped" "$(skipped_count no_lifecycle)" "2"
assert_eq "the settled hypothesis is counted as skipped" "$(skipped_count settled)" "1"
assert_eq "--kind narrows the scan" "$(candidates --kind question)" "gotchas/stale-open-question.md"

# =============================================
# Test 5: expired is not retired
# =============================================
echo ""
echo "Test 5: expired and retired stay distinguishable"
setup_store
bash "$SWEEP" --days "$DAYS" --today "$TODAY" --kdir "$KDIR" >/dev/null 2>&1
assert_eq "the swept entry lands on expired" "$(footer_status gotchas/stale-open-question.md)" "expired"

# A hand retirement on a different entry, for contrast.
bash "$MUTATE" --retire --entry "$KDIR/conventions/stale-plain-fact.md" \
  --verdict-source peer-verification --allow-peer-verification --kdir "$KDIR" \
  --reason "Superseded by the newer note." --falsifier "A caller still reads it." \
  --date "$TODAY" >/dev/null 2>&1
assert_eq "a hand retirement still lands on retired" "$(footer_status conventions/stale-plain-fact.md)" "retired"

EXPIRED_ID=$(grep -oE '"retirement_id": "[a-z]+-[0-9a-f]+"' "$KDIR/gotchas/stale-open-question.md" | tail -1)
RETIRED_ID=$(grep -oE '"retirement_id": "[a-z]+-[0-9a-f]+"' "$KDIR/conventions/stale-plain-fact.md" | tail -1)
assert_contains "an expiry id is prefixed exp-" "$EXPIRED_ID" '"exp-'
assert_contains "a retirement id is prefixed ret-" "$RETIRED_ID" '"ret-'
assert_contains "the ledger records the expiry result status" \
  "$(jq -c 'select(.entry_path == "gotchas/stale-open-question.md") | .payload.result_status' "$LEDGER")" "expired"
assert_contains "and attributes it to the sweep" \
  "$(jq -r 'select(.entry_path == "gotchas/stale-open-question.md") | .source' "$LEDGER")" "expire-sweep"

# =============================================
# Test 6: the expired entry stays readable and actionable
# =============================================
echo ""
echo "Test 6: an expired entry keeps its file and carries an actionable record"
setup_store
BODY_BEFORE=$(sed -n '2p' "$KDIR/gotchas/stale-open-question.md")
bash "$SWEEP" --days "$DAYS" --today "$TODAY" --kdir "$KDIR" >/dev/null 2>&1
assert_eq "the file is still at its original path" "$([[ -f "$KDIR/gotchas/stale-open-question.md" ]] && echo yes)" "yes"
assert_eq "its body prose is untouched" "$(sed -n '2p' "$KDIR/gotchas/stale-open-question.md")" "$BODY_BEFORE"
ENTRY_TEXT=$(cat "$KDIR/gotchas/stale-open-question.md")
assert_contains "the kind-specific footer fields survive" "$ENTRY_TEXT" "where_looked:"
assert_contains "a dated marker names the expiry" "$ENTRY_TEXT" "**Expired ${TODAY}.**"
assert_contains "the marker states what would overturn it" "$ENTRY_TEXT" "Overturned if:"
assert_contains "and names the command that brings it back" "$ENTRY_TEXT" "--restore"

# The reason and falsifier ride inside a JSON array on the footer's single
# pipe-joined line, so neither may carry a character that splits it.
assert_eq "the footer array still decodes with no pipe or angle bracket in it" \
  "$(python3 - "$KDIR/gotchas/stale-open-question.md" <<'FOOTER_PY'
import json, re, sys
inner = [m.group(1) for m in re.finditer(r"<!--(.*?)-->", open(sys.argv[1], encoding="utf-8").read(), re.DOTALL)][-1]
m = re.search(r"\|\s*retirements:\s*\[", inner)
items, _ = json.JSONDecoder().raw_decode(inner[m.end() - 1:])
text = items[-1]["reason"] + items[-1]["falsifier"]
print("clean" if ("|" not in text and ">" not in text and items[-1]["reason"] and items[-1]["falsifier"]) else "dirty")
FOOTER_PY
)" "clean"

# =============================================
# Test 7: restore returns the status the entry held
# =============================================
echo ""
echo "Test 7: expire then restore"
setup_store
# Give the entry a non-default prior status so a hardcoded 'current' would show.
python3 - "$KDIR/conventions/stale-untested-hypothesis.md" <<'PRIOR_PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read().replace("| status: current", "| status: corrected")
open(p, "w", encoding="utf-8").write(s)
PRIOR_PY
bash "$SWEEP" --days "$DAYS" --today "$TODAY" --kdir "$KDIR" >/dev/null 2>&1
assert_eq "it expired" "$(footer_status conventions/stale-untested-hypothesis.md)" "expired"
RESTORE_OUT=$(bash "$RETIRE" conventions/stale-untested-hypothesis --restore \
  --note "Wanted for the retrieval audit." --source interactive --date "$TODAY" --kdir "$KDIR" 2>&1)
assert_eq "restore returns the status it held, not current" \
  "$(footer_status conventions/stale-untested-hypothesis.md)" "corrected"
assert_contains "and reports that status" "$RESTORE_OUT" "restored to status corrected"

# =============================================
# Test 8: the documented interruption behavior
# =============================================
echo ""
echo "Test 8: an interrupted transaction, and how it recovers"
setup_store
# The interruption: the entry mutation lands, the ledger append never happens.
bash "$MUTATE" --retire --result-status expired \
  --entry "$KDIR/gotchas/stale-open-question.md" \
  --verdict-source peer-verification --allow-peer-verification --kdir "$KDIR" \
  --reason "Open with nothing recorded." --falsifier "A recorded observation." \
  --reported-by expire-sweep --date "$TODAY" >/dev/null 2>&1
assert_eq "the entry is expired" "$(footer_status gotchas/stale-open-question.md)" "expired"
assert_eq "and no ledger event exists" "$(ledger_hash)" "absent"

INTERRUPTED_ID=$(python3 - "$KDIR/gotchas/stale-open-question.md" <<'ID_PY'
import json, re, sys
inner = [m.group(1) for m in re.finditer(r"<!--(.*?)-->", open(sys.argv[1], encoding="utf-8").read(), re.DOTALL)][-1]
m = re.search(r"\|\s*retirements:\s*\[", inner)
items, _ = json.JSONDecoder().raw_decode(inner[m.end() - 1:])
print(items[-1]["retirement_id"])
ID_PY
)

# Documented behavior: a later sweep does NOT heal it, because the candidate
# scan skips entries already out of the default result set.
SWEEP_OUT=$(bash "$SWEEP" --days "$DAYS" --today "$TODAY" --kdir "$KDIR" 2>&1)
assert_not_contains "a later sweep does not touch the interrupted entry" \
  "$SWEEP_OUT" "gotchas/stale-open-question.md"
assert_eq "so its ledger row is still missing" \
  "$(jq -r 'select(.entry_path == "gotchas/stale-open-question.md") | .payload.retirement_id' "$LEDGER" 2>/dev/null | wc -l | tr -d ' ')" "0"

# Recovery is by name, and it lands the row the sweep would have written.
RECOVER_OUT=$(bash "$RETIRE" gotchas/stale-open-question \
  --reason "Open with nothing recorded." --falsifier "A recorded observation." \
  --source interactive --date "$TODAY" --kdir "$KDIR" 2>&1)
assert_contains "recovery leaves the entry alone" "$RECOVER_OUT" "nothing further to record on the entry"
assert_eq "and appends the missing row under the expiry id the sweep derived" \
  "$(jq -r 'select(.entry_path == "gotchas/stale-open-question.md") | .payload.retirement_id' "$LEDGER")" "$INTERRUPTED_ID"
assert_eq "carrying the expired result status" \
  "$(jq -r 'select(.entry_path == "gotchas/stale-open-question.md") | .payload.result_status' "$LEDGER")" "expired"
assert_eq "and only one marker is on the entry" \
  "$(grep -c "\*\*Expired ${TODAY}\.\*\*" "$KDIR/gotchas/stale-open-question.md")" "1"

# =============================================
# Test 9: the emitter writes nothing, ever
# =============================================
echo ""
echo "Test 9: the candidate emitter is write-free"
setup_store
EMIT_TREE=$(tree_hash)
python3 "$EMIT" "$KDIR" --days "$DAYS" --today "$TODAY" >/dev/null
assert_eq "running the emitter changes no entry" "$(tree_hash)" "$EMIT_TREE"
assert_eq "and creates no ledger" "$(ledger_hash)" "absent"
assert_eq "a zero-day threshold still writes nothing" \
  "$(python3 "$EMIT" "$KDIR" --days 0 --today "$TODAY" >/dev/null; tree_hash)" "$EMIT_TREE"

# =============================================
# Test 10: mutation checks — does this suite constrain the code?
# =============================================
# Break the two properties that matter most and confirm the tests above go red.
# A suite that passes against deliberately broken code is decoration.
echo ""
echo "Test 10: mutation checks"
MUTANT_DIR="$TEST_DIR/mutant"
mkdir -p "$MUTANT_DIR"
# The emitter reads the kind registry from its own directory, so a mutant copied
# elsewhere needs the registry beside it.
ln -sf "$SCRIPT_DIR/kind-registry.sh" "$MUTANT_DIR/kind-registry.sh"
ln -sf "$SCRIPT_DIR/kind-registry.json" "$MUTANT_DIR/kind-registry.json"

# Mutant A: recency from filesystem mtime instead of declared footer dates.
python3 - "$EMIT" "$MUTANT_DIR/emit-mtime.py" <<'MUT_A_PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
old = "        since = last_declared_activity(fields, arrays)"
new = ("        import datetime as _dt\n"
       "        since = _dt.date.fromtimestamp(os.path.getmtime(path))")
assert old in s, "mutation point A not found"
open(dst, "w", encoding="utf-8").write(s.replace(old, new))
MUT_A_PY
setup_store
find "$KDIR" -name '*.md' -exec touch {} +
MUTANT_A_OUT=$(python3 "$MUTANT_DIR/emit-mtime.py" "$KDIR" --days "$DAYS" --today "$TODAY" \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["candidates"]))')
assert_eq "mtime-based recency finds nothing after a store-wide touch (Test 1 would go red)" "$MUTANT_A_OUT" "0"

# Mutant B: drop the already-out-of-the-default-set skip.
python3 - "$EMIT" "$MUTANT_DIR/emit-noskip.py" <<'MUT_B_PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
old = 'OUT_OF_DEFAULT_STATUSES = ("expired", "retired")'
new = 'OUT_OF_DEFAULT_STATUSES = ()'
assert old in s, "mutation point B not found"
open(dst, "w", encoding="utf-8").write(s.replace(old, new))
MUT_B_PY
setup_store
bash "$SWEEP" --days "$DAYS" --today "$TODAY" --kdir "$KDIR" >/dev/null 2>&1
MUTANT_B_OUT=$(python3 "$MUTANT_DIR/emit-noskip.py" "$KDIR" --days "$DAYS" --today "$TODAY" \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["candidates"]))')
if [[ "$MUTANT_B_OUT" -gt 0 ]]; then
  echo "  PASS: dropping the skip re-proposes swept entries (Test 2 would go red)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: dropping the skip changed nothing — Test 2 does not constrain the skip"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
