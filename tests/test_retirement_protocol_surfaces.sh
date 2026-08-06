#!/usr/bin/env bash
# test_retirement_protocol_surfaces.sh — Pin the retirement contract on its
# protocol surfaces: /memory curate disposes of commons entries by retiring
# them (reversible, on-disk, one command back), never by deleting them, and
# the trust-ledger contract documents the retirement event kind that records
# both directions.
#
# Only the settled contract is pinned — the retire verdict in curate's closed
# vocabulary, the retirement authority note and its restore recourse, the
# falsifier requirement, and the ledger kind's basis and zero weight.
# Surrounding prose may drift; the checks below must not. Assertions are over
# file contents only — nothing here invokes `lore retire`.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEMORY_SKILL="$REPO_DIR/skills/memory/SKILL.md"

# The trust-ledger contract lives in the knowledge store, not this repo.
# Honor an explicit KDIR, then fall back to the installed resolver.
if [[ -z "${KDIR:-}" ]]; then
  KDIR="$(cd "$REPO_DIR" && lore resolve 2>/dev/null || true)"
fi
TRUST_README="${KDIR:-}/architecture/trust-ledger/README.md"
if [[ ! -f "$TRUST_README" ]]; then
  echo "FATAL: trust-ledger README not reachable (KDIR='${KDIR:-}')" >&2
  echo "       Set KDIR to the knowledge store root and re-run." >&2
  exit 1
fi

PASS=0
FAIL=0

assert_file_contains() {
  local label="$1" file="$2" pattern="$3"
  if grep -qF -- "$pattern" "$file"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    File:    $file"
    echo "    Missing: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

# Prose in these documents can be hard-wrapped, so phrase checks match
# against a whitespace-flattened copy rather than individual lines.
assert_prose_contains() {
  local label="$1" file="$2" pattern="$3"
  if tr '\n' ' ' <"$file" | tr -s ' ' | grep -qF -- "$pattern"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    File:    $file"
    echo "    Missing: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_lacks() {
  local label="$1" file="$2" pattern="$3"
  if grep -qF -- "$pattern" "$file"; then
    echo "  FAIL: $label"
    echo "    File:      $file"
    echo "    Should not contain: $pattern"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

echo "=== Retirement Protocol Surface Tests ==="
echo ""

echo "Test 1: curate's disposition for commons entries is retire, not drop"
# The verdict vocabulary is closed. If the destructive verdict reappears
# beside the reversible one, deletion is the faster path and wins.
assert_file_contains "curate names the retire verdict" \
  "$MEMORY_SKILL" 'retire <path> (<trivial-reason>)'
assert_file_lacks "curate no longer names a drop verdict for commons entries" \
  "$MEMORY_SKILL" 'drop <path> (<trivial-reason>)'
assert_file_contains "the keep arm of the closed vocabulary survives" \
  "$MEMORY_SKILL" 'keep <path> (4-cond | orientation)'
assert_file_contains "the escalate arm of the closed vocabulary survives" \
  "$MEMORY_SKILL" 'escalate <path> (<abstain-reason>)'
assert_file_contains "the four trivial-reason codes are unchanged" \
  "$MEMORY_SKILL" 'low-significance | duplicate-of-survivor | high-cost-to-verify | low-surface-area'

echo ""
echo "Test 2: the retirement authority note replaces drop authority"
# The authority stays with the agent; what changes is that the objection
# surface finally has a recourse behind it — one restore command.
assert_file_contains "the authority note is titled for retirement" \
  "$MEMORY_SKILL" '**Retirement authority:**'
assert_file_lacks "the drop-authority title is gone" \
  "$MEMORY_SKILL" '**Drop authority:**'
assert_prose_contains "the note frames retirement as a claim, not a deletion" \
  "$MEMORY_SKILL" 'A retirement is a claim, not a deletion'
assert_prose_contains "the note names the restore command as the recourse" \
  "$MEMORY_SKILL" 'lore retire <path> --restore'

echo ""
echo "Test 3: the falsifier requirement is stated on both surfaces"
# The falsifier is what makes retiring cheap: the next reader checks one
# written fact instead of reconstructing a chain of reasoning.
assert_prose_contains "curate says what the falsifier is for" \
  "$MEMORY_SKILL" 'show the retirement was wrong'
assert_prose_contains "the ledger contract says what the falsifier is for" \
  "$TRUST_README" 'show the retirement was wrong'
assert_prose_contains "the ledger contract requires the falsifier to retire" \
  "$TRUST_README" 'a retirement without a falsifier is rejected before anything is written'

echo ""
echo "Test 4: backlinks no longer route to escalation"
# Retirement leaves the entry on disk with its links intact, so the old
# orphaned-backlinks escalation leg has nothing left to protect.
assert_file_lacks "the orphaned-backlinks escalation leg is gone" \
  "$MEMORY_SKILL" 'orphan backlinks'
assert_prose_contains "curate states that retirement orphans nothing" \
  "$MEMORY_SKILL" 'retirement orphans nothing'

echo ""
echo "Test 5: inbox remnants keep the drop disposition"
# Inbox files are interrupted captures, not commons entries; nothing links
# to them and no reader depends on them, so drop remains the right verb.
assert_file_contains "step 1's inbox-remnant drop is untouched" \
  "$MEMORY_SKILL" 'file to the correct category or drop'

echo ""
echo "Test 6: the ledger contract settles the retirement kind"
# One event kind carries both directions, dedupes per act, and weighs
# nothing in the fold — a relevance claim is not a truth claim.
assert_file_contains "the retirement kind has its own section" \
  "$TRUST_README" '### retirement'
assert_prose_contains "the kind carries both directions" \
  "$TRUST_README" '`retired` (the entry left default retrieval) or `restored`'
assert_file_contains "the dedupe basis keys on action and per-act id" \
  "$TRUST_README" 'event\|entry_path\|action\|retirement_id'
assert_file_contains "the fold weighs retirement at zero" \
  "$TRUST_README" '0·retirement'
assert_prose_contains "zero weight is grounded in the relevance/truth split" \
  "$TRUST_README" 'a relevance claim, not a truth claim'
assert_file_contains "the envelope enum includes the retirement kind" \
  "$TRUST_README" 'correction | retirement | adjudication'

echo ""
echo "Test 7: retired is distinguished from its status-tier neighbors"
# What separates retired from superseded|historical|resolved is the whole
# reason the kind exists: no successor, a written falsifier, one command back.
assert_prose_contains "the contract places retired beside the opt-in tier" \
  "$TRUST_README" '`retired` sits beside `superseded | historical | resolved`'
assert_prose_contains "retired names no successor" \
  "$TRUST_README" 'it names no successor'
assert_prose_contains "retired reverses with one command" \
  "$TRUST_README" 'reverses with one command'
assert_prose_contains "restoration is ungated" \
  "$TRUST_README" 'no check on who retired it'

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
