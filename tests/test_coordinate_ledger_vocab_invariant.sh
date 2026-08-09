#!/usr/bin/env bash
# Guard the canonical ledger vocabulary: the Tree, Status, and Verdict tokens the
# coordination ledger is written in and the board join validates.
#
# The ledger is hand-written and the join branches on these three columns. A
# column whose declared vocabulary drifts from the join's does not degrade a row,
# it removes the row from the board — the seat reads a stream nobody is
# dispatching. The INVARIANT block in skills/coordinate/SKILL.md declares the
# vocabulary and says the test reads it; this file is that test.
#
# Scope: the three columns the join validates. The block also pins gate mechanism
# and retro outcome, which no reader branches on today — there is no second set
# to compare them against, and inventing one here would assert a contract that
# does not exist.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO_DIR/skills/coordinate/SKILL.md"
STATUS="$REPO_DIR/scripts/coordinate-status.sh"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$label"; else fail "$label" "expected '$expected', got '$actual'"; fi
}

echo "=== coordinate ledger vocabulary invariant ==="

for file in "$SKILL" "$STATUS"; do
  [[ -f "$file" ]] || { fail "missing input $file"; echo "Results: $PASS passed, $FAIL failed"; exit 1; }
done

# One reader for both sides, emitting `<key><TAB><sorted tokens>` lines. The
# parametric `blocked-on:<ref>` is reported under its own key on each side: the
# block writes it as a token, the join as a prefix test, and comparing the fixed
# tokens without it would let the prefix quietly disappear.
TOKENS="$(python3 - "$SKILL" "$STATUS" <<'PYEOF'
import re
import sys

skill_path, status_path = sys.argv[1], sys.argv[2]
skill = open(skill_path, encoding="utf-8").read()
status = open(status_path, encoding="utf-8").read()

block = ""
match = re.search(r"<!--\s*INVARIANT[^>]*?canonical ledger vocabulary(.*?)-->", skill, re.S)
if match:
    block = match.group(1)

PARAMETRIC = "blocked-on:<ref>"


def block_tokens(label):
    """The `|`-separated token list on the block's `<label>:` line.

    A trailing parenthetical annotates the column for a reader; it is not part of
    the vocabulary, so the line is cut at the first `(`.
    """
    found = re.search(rf"^\s*{label}\s*:(.*)$", block, re.M)
    if not found:
        return []
    text = found.group(1).split("(")[0].replace("-->", "")
    return sorted({token.strip() for token in text.split("|") if token.strip()})


def validation_set(name):
    """The literal tokens of a `NAME = {...}` set in the join."""
    found = re.search(rf"^{name}\s*=\s*\{{([^}}]*)\}}", status, re.M)
    if not found:
        return []
    return sorted(set(re.findall(r'"([^"]+)"', found.group(1))))


def expected_messages():
    """The `(expected ...)` texts of the three Reconcile refusals.

    Each message is built from adjacent f-string fragments across several source
    lines, so the fragments are joined before matching — the message a seat reads
    is the concatenation, not any one line.
    """
    joined = re.sub(r'"\s*f"', "", status)
    return re.findall(r"\(expected ([^)]*)\)", joined)


tree_block = block_tokens("tree")
status_block = block_tokens("step status")
verdict_block = block_tokens("step verdict")

print("block_tree\t%s" % " ".join(tree_block))
print("join_tree\t%s" % " ".join(validation_set("LEDGER_TREES")))
print("block_status\t%s" % " ".join(t for t in status_block if t != PARAMETRIC))
print("join_status\t%s" % " ".join(validation_set("LEDGER_STATUSES")))
print("block_verdict\t%s" % " ".join(verdict_block))
print("join_verdict\t%s" % " ".join(validation_set("LEDGER_VERDICTS")))

# The parametric status: declared as a token in the block, honoured as a prefix
# test in the join.
print("block_parametric\t%s" % ("yes" if PARAMETRIC in status_block else "no"))
prefix = re.search(r'prefix\s*=\s*"blocked-on:"', status)
print("join_parametric\t%s" % ("yes" if prefix else "no"))

# Every fixed token has to reach the seat: a set extended without its refusal
# message leaves the seat reading an expected-value list that is missing the
# value it should have used.
messages = " || ".join(expected_messages())
missing = [token for token in set(tree_block + status_block + verdict_block)
           if token not in messages]
print("unnamed_in_refusals\t%s" % " ".join(sorted(missing)))
print("refusal_messages\t%d" % len(expected_messages()))
PYEOF
)" || { fail "vocabulary extraction failed"; echo "Results: $PASS passed, $FAIL failed"; exit 1; }

field() { printf '%s\n' "$TOKENS" | awk -F'\t' -v key="$1" '$1 == key {print $2}'; }

BLOCK_TREE="$(field block_tree)"
BLOCK_STATUS="$(field block_status)"
BLOCK_VERDICT="$(field block_verdict)"

# A block that stopped parsing would make every comparison below trivially pass.
if [[ -n "$BLOCK_TREE" && -n "$BLOCK_STATUS" && -n "$BLOCK_VERDICT" ]]; then
  pass "the INVARIANT block declares all three validated columns"
else
  fail "the INVARIANT block declares all three validated columns" \
    "tree='$BLOCK_TREE' status='$BLOCK_STATUS' verdict='$BLOCK_VERDICT'"
fi

# Set equality in both directions, one string compare per column.
assert_eq "tree: block and join agree" "$BLOCK_TREE" "$(field join_tree)"
assert_eq "status: block and join agree" "$BLOCK_STATUS" "$(field join_status)"
assert_eq "verdict: block and join agree" "$BLOCK_VERDICT" "$(field join_verdict)"

# The terms the block was written to pin, so a block rewritten to match a drifted
# join in the same commit still fails.
assert_eq "tree tokens are writer and read-only" "read-only writer" "$BLOCK_TREE"
assert_eq "fixed status tokens are the canonical five" \
  "blocked-on-input done dropped in-flight pending" "$BLOCK_STATUS"
assert_eq "verdict tokens are the canonical three" "full none partial" "$BLOCK_VERDICT"

assert_eq "the block declares the parametric blocked-on status" "yes" "$(field block_parametric)"
assert_eq "the join honours blocked-on as a prefix" "yes" "$(field join_parametric)"

assert_eq "all three columns refuse with an expected-value list" "3" "$(field refusal_messages)"
assert_eq "every ledger token is named in a refusal message" "" "$(field unnamed_in_refusals)"

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
