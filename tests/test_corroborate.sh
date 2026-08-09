#!/usr/bin/env bash
# test_corroborate.sh — Tests for the corroboration and kind_status writers:
# apply-correction.sh --corroborate and --set-kind-status, and the
# corroborate-append.sh front over both.
#
# Covers:
#   - A repeated observation with the same basis is a no-op, and re-wording the
#     note does not make it a second data point
#   - Changing any component of the basis does record a distinct observation
#   - A pipe or angle bracket in a note or source cannot corrupt the footer, and
#     the corroborations array still decodes afterwards
#   - Recording an observation adds no second HTML comment to the entry
#   - kind_status moves are validated against the entry's own kind, so a
#     hypothesis cannot be moved to a question's state
#   - A kind with no lifecycle refuses the move rather than inventing one
#   - kind_status is not the `status` field: settling a claim leaves the entry's
#     retrieval status alone
#   - The front owns no vocabulary — a bad direction or kind_status is refused by
#     the mutator, which is what keeps the enums single-sourced
#   - The dedupe basis excludes the note (mutation-checked at the bottom)

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_DIR/scripts"
FRONT="$SCRIPT_DIR/corroborate-append.sh"
MUTATE="$SCRIPT_DIR/apply-correction.sh"
FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/make-epistemic-store.sh"

TEST_DIR=$(mktemp -d)
KDIR="$TEST_DIR/knowledge"
HYPOTHESIS="conventions/stale-untested-hypothesis"
QUESTION="gotchas/stale-open-question"
FACT="conventions/stale-plain-fact"

PASS=0
FAIL=0

# The mutant in Test 7 has to live beside the real scripts: apply-correction.sh
# resolves lib.sh and kind-registry.sh from its own directory, so a copy
# anywhere else cannot start.
MUTANT="$SCRIPT_DIR/.apply-correction-mutant-$$.sh"

cleanup() { rm -rf "$TEST_DIR"; rm -f "$MUTANT"; }
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

setup_store() { bash "$FIXTURE" "$KDIR" >/dev/null; }

# Read the corroborations array with the same hardened decoder the writer uses,
# so a `]` inside a note cannot make this helper disagree with the code.
corroborations() {
  python3 - "$KDIR/$1.md" "$2" <<'CORR_PY'
import json, re, sys
inner = [m.group(1) for m in re.finditer(r"<!--(.*?)-->", open(sys.argv[1], encoding="utf-8").read(), re.DOTALL)][-1]
m = re.search(r"\|\s*corroborations:\s*\[", inner)
if not m:
    print("0" if sys.argv[2] == "count" else "")
    sys.exit(0)
items, _ = json.JSONDecoder().raw_decode(inner[m.end() - 1:])
what = sys.argv[2]
if what == "count":
    print(len(items))
elif what == "ids":
    print(" ".join(i["corroboration_id"] for i in items))
elif what == "notes":
    print(" | ".join(i["note"] for i in items))
elif what == "clean":
    joined = "".join(i["note"] + i["source"] for i in items)
    print("clean" if "|" not in joined and ">" not in joined else "dirty")
CORR_PY
}

# One footer field's value. The last field on the line runs up against the
# comment terminator, so strip that before trimming.
footer_field() {
  grep -oE "\| $2: [^|]+" "$KDIR/$1.md" | tail -1 \
    | sed "s/| $2: //" | sed 's/-->$//' | sed 's/ *$//'
}

comment_count() {
  python3 -c 'import re,sys; print(len(re.findall(r"<!--", open(sys.argv[1], encoding="utf-8").read())))' "$KDIR/$1.md"
}

echo "=== Corroboration and kind_status tests ==="
echo ""

# =============================================
# Test 1: the dedupe basis, and what is outside it
# =============================================
echo "Test 1: a repeated observation converges; a re-worded note is not new"
setup_store
FIRST=$(bash "$FRONT" "$HYPOTHESIS" --direction supports --source worker \
  --note "Held when I read scripts/foo.sh:12" --observed-at 2026-08-01 --kdir "$KDIR" 2>&1)
assert_contains "the first observation is recorded" "$FIRST" "supports, observed 2026-08-01 by worker"
assert_eq "one item in the array" "$(corroborations "$HYPOTHESIS" count)" "1"
FIRST_IDS=$(corroborations "$HYPOTHESIS" ids)

AGAIN=$(bash "$FRONT" "$HYPOTHESIS" --direction supports --source worker \
  --note "A completely different way of describing the same observation" \
  --observed-at 2026-08-01 --kdir "$KDIR" 2>&1)
assert_contains "the re-worded repeat is a no-op" "$AGAIN" "already carries this observation"
assert_eq "still one item" "$(corroborations "$HYPOTHESIS" count)" "1"
assert_eq "and the same id" "$(corroborations "$HYPOTHESIS" ids)" "$FIRST_IDS"
assert_contains "the original note text is what survived" "$(corroborations "$HYPOTHESIS" notes)" "Held when I read scripts/foo.sh:12"

echo ""
echo "Test 2: each basis component discriminates"
setup_store
bash "$FRONT" "$HYPOTHESIS" --direction supports --source worker \
  --note "base" --observed-at 2026-08-01 --kdir "$KDIR" >/dev/null 2>&1
bash "$FRONT" "$HYPOTHESIS" --direction undermines --source worker \
  --note "base" --observed-at 2026-08-01 --kdir "$KDIR" >/dev/null 2>&1
assert_eq "a different direction is a distinct observation" "$(corroborations "$HYPOTHESIS" count)" "2"
bash "$FRONT" "$HYPOTHESIS" --direction supports --source reviewer \
  --note "base" --observed-at 2026-08-01 --kdir "$KDIR" >/dev/null 2>&1
assert_eq "a different source is a distinct observation" "$(corroborations "$HYPOTHESIS" count)" "3"
bash "$FRONT" "$HYPOTHESIS" --direction supports --source worker \
  --note "base" --observed-at 2026-08-02 --kdir "$KDIR" >/dev/null 2>&1
assert_eq "a different observation date is a distinct observation" "$(corroborations "$HYPOTHESIS" count)" "4"
assert_eq "and all four ids are unique" \
  "$(corroborations "$HYPOTHESIS" ids | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')" "4"

# =============================================
# Test 3: footer-hostile characters
# =============================================
echo ""
echo "Test 3: a pipe or angle bracket cannot corrupt the footer"
setup_store
bash "$FRONT" "$HYPOTHESIS" --direction undermines --source 'rev|iewer' \
  --note 'failed when a > b | and the pipe should not split this' \
  --observed-at 2026-08-02 --kdir "$KDIR" >/dev/null 2>&1
assert_eq "the array still decodes" "$(corroborations "$HYPOTHESIS" count)" "1"
assert_eq "no pipe or angle bracket reached a footer value" "$(corroborations "$HYPOTHESIS" clean)" "clean"
assert_eq "the footer is still one line" \
  "$(python3 -c 'import re,sys; t=open(sys.argv[1],encoding="utf-8").read(); m=re.findall(r"<!--.*?-->", t, re.DOTALL)[-1]; print(m.count(chr(10)))' "$KDIR/$HYPOTHESIS.md")" "0"
assert_eq "the entry still holds exactly one HTML comment" "$(comment_count "$HYPOTHESIS")" "1"
assert_eq "the kind field is still readable after it" "$(footer_field "$HYPOTHESIS" kind)" "hypothesis"

# =============================================
# Test 4: kind_status is validated against the entry's own kind
# =============================================
echo ""
echo "Test 4: the lifecycle vocabulary comes from the entry's kind"
setup_store
SETTLE=$(bash "$FRONT" "$HYPOTHESIS" --kind-status supported \
  --note "Two observations point the same way." --source worker --kdir "$KDIR" 2>&1)
assert_contains "a hypothesis can be settled to supported" "$SETTLE" "kind_status untested -> supported"
assert_eq "and the footer carries it" "$(footer_field "$HYPOTHESIS" kind_status)" "supported"

REPEAT=$(bash "$FRONT" "$HYPOTHESIS" --kind-status supported --note "again" --kdir "$KDIR" 2>&1)
assert_contains "settling again is a no-op" "$REPEAT" "was already supported"

WRONG=$(bash "$FRONT" "$HYPOTHESIS" --kind-status answered --note "wrong vocabulary" --kdir "$KDIR" 2>&1)
WRONG_STATUS=$?
assert_contains "a question's value is refused for a hypothesis" "$WRONG" "is not valid for kind 'hypothesis'"
assert_contains "and the error names the legal values" "$WRONG" "untested|supported|refuted"
assert_eq "the entry was not touched" "$(footer_field "$HYPOTHESIS" kind_status)" "supported"

QSETTLE=$(bash "$FRONT" "$QUESTION" --kind-status dissolved \
  --note "The premise turned out not to hold." --kdir "$KDIR" 2>&1)
assert_contains "a question takes its own vocabulary" "$QSETTLE" "kind_status open -> dissolved"

set +e
NOLIFE=$(bash "$FRONT" "$FACT" --kind-status supported --note "no lifecycle" --kdir "$KDIR" 2>&1)
NOLIFE_STATUS=$?
set -e
assert_eq "a kind with no lifecycle exits 2" "$NOLIFE_STATUS" "2"
assert_contains "and says why" "$NOLIFE" "declares no lifecycle"

# =============================================
# Test 5: kind_status is not the retrieval status
# =============================================
# The sharpest naming constraint in this substrate: an entry written with an
# epistemic value in the `status` field would vanish from default search.
echo ""
echo "Test 5: settling a claim leaves the retrieval status alone"
setup_store
assert_eq "the entry starts current" "$(footer_field "$HYPOTHESIS" status)" "current"
bash "$FRONT" "$HYPOTHESIS" --kind-status refuted \
  --note "The undermining observation reproduced." --kdir "$KDIR" >/dev/null 2>&1
assert_eq "kind_status moved to refuted" "$(footer_field "$HYPOTHESIS" kind_status)" "refuted"
assert_eq "and status is still current" "$(footer_field "$HYPOTHESIS" status)" "current"
assert_contains "a transition record was appended" \
  "$(cat "$KDIR/$HYPOTHESIS.md")" "kind_status_transitions:"
assert_eq "the entry still holds exactly one HTML comment" "$(comment_count "$HYPOTHESIS")" "1"

# =============================================
# Test 6: the front owns no vocabulary
# =============================================
echo ""
echo "Test 6: the front validates its own shape only"
setup_store
set +e
BADDIR=$(bash "$FRONT" "$HYPOTHESIS" --direction sideways --source worker \
  --note "n" --kdir "$KDIR" 2>&1)
BADDIR_STATUS=$?
set -e
assert_eq "a bad direction is rejected" "$BADDIR_STATUS" "1"
assert_contains "by the mutator, naming the legal values" "$BADDIR" "must be 'supports' or 'undermines'"

set +e
NODIR=$(bash "$FRONT" "$HYPOTHESIS" --source worker --note "n" --kdir "$KDIR" 2>&1)
NODIR_STATUS=$?
NOSRC=$(bash "$FRONT" "$HYPOTHESIS" --direction supports --note "n" --kdir "$KDIR" 2>&1)
NONOTE=$(bash "$FRONT" "$HYPOTHESIS" --direction supports --source worker --kdir "$KDIR" 2>&1)
MIXED=$(bash "$FRONT" "$HYPOTHESIS" --kind-status refuted --direction supports --note "n" --kdir "$KDIR" 2>&1)
MISSING=$(bash "$FRONT" conventions/does-not-exist --direction supports --source w --note "n" --kdir "$KDIR" 2>&1)
set -e
assert_eq "a missing direction is caught by the front" "$NODIR_STATUS" "1"
assert_contains "missing --direction names the flag" "$NODIR" "--direction is required"
assert_contains "missing --source names the flag" "$NOSRC" "--source is required"
assert_contains "missing --note names the flag" "$NONOTE" "--note is required"
assert_contains "mixing the two modes is refused" "$MIXED" "not to --kind-status"
assert_contains "a missing entry is refused before any write" "$MISSING" "knowledge entry not found"

# =============================================
# Test 7: mutation check — is the note really outside the basis?
# =============================================
# Put the note into the dedupe basis and confirm Test 1 would go red. Without
# this, Test 1 passes just as well against a writer that hashes the whole item.
echo ""
echo "Test 7: mutation check"
python3 - "$MUTATE" "$MUTANT" <<'MUT_PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
old = 'basis = f"{rel_path}|{observed_at}|{source}|{direction}"'
new = 'basis = f"{rel_path}|{observed_at}|{source}|{direction}|{note}"'
assert old in s, "mutation point not found"
open(dst, "w", encoding="utf-8").write(s.replace(old, new))
MUT_PY
setup_store
PEER=(--verdict-source peer-verification --allow-peer-verification --kdir "$KDIR")
bash "$MUTANT" --corroborate --entry "$KDIR/$HYPOTHESIS.md" "${PEER[@]}" \
  --direction supports --corroboration-source worker \
  --corroboration-note "one wording" --observed-at 2026-08-01 >/dev/null 2>&1
bash "$MUTANT" --corroborate --entry "$KDIR/$HYPOTHESIS.md" "${PEER[@]}" \
  --direction supports --corroboration-source worker \
  --corroboration-note "another wording of the same observation" --observed-at 2026-08-01 >/dev/null 2>&1
assert_eq "with the note in the basis, a re-wording double-counts (Test 1 would go red)" \
  "$(corroborations "$HYPOTHESIS" count)" "2"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
