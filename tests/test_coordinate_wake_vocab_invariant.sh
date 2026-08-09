#!/usr/bin/env bash
# Guard the canonical wake vocabulary: the tiers and authorities the watch verb
# emits, the prose that teaches them, and the reference that documents them.
#
# The seat reads live wakes through the words the skill taught it. A token
# renamed in the verb and left standing in the prose costs nothing at parse time
# and everything at read time — the seat waits for a tier that no longer exists,
# or reads a tier it was never taught. The INVARIANT block in skills/coordinate/
# SKILL.md declares the vocabulary and claims this test asserts set equality
# against the verb in both directions; that claim is what this file makes true.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO_DIR/skills/coordinate/SKILL.md"
REFERENCE="$REPO_DIR/skills/coordinate/session-reference.md"
WATCH="$REPO_DIR/scripts/coordinate-watch.sh"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$label"; else fail "$label" "expected '$expected', got '$actual'"; fi
}

echo "=== coordinate wake vocabulary invariant ==="

for file in "$SKILL" "$REFERENCE" "$WATCH"; do
  [[ -f "$file" ]] || { fail "missing input $file"; echo "Results: $PASS passed, $FAIL failed"; exit 1; }
done

# Both sides are extracted by one reader so the block and the verb are parsed
# against the same idea of a token. Output is four `<key><TAB><sorted tokens>`
# lines; an empty token list is itself a failure the assertions below catch.
TOKENS="$(python3 - "$SKILL" "$WATCH" <<'PYEOF'
import re
import sys

skill_path, watch_path = sys.argv[1], sys.argv[2]
skill = open(skill_path, encoding="utf-8").read()
watch = open(watch_path, encoding="utf-8").read()

# The declaring block, found by what it says it is rather than by line number.
block = ""
match = re.search(r"<!--\s*INVARIANT[^>]*?canonical wake vocabulary(.*?)-->", skill, re.S)
if match:
    block = match.group(1)


def block_tokens(label):
    """The `|`-separated token list on the block's `<label>:` line."""
    found = re.search(rf"^\s*{label}\s*:(.*)$", block, re.M)
    if not found:
        return []
    text = found.group(1).split("(")[0].replace("-->", "")
    return sorted({token.strip() for token in text.split("|") if token.strip()})


def emitted(names):
    """Literal values assigned to any of <names> anywhere in the verb.

    Assignments whose value is a variable or a substitution carry the token from
    somewhere else in the same file, so skipping them loses nothing: only the
    literal that first names a tier or an authority has to match the prose. The
    token shape (lowercase, `-` or `_` inside) is what excludes the rest of a
    substitution's quoted fragments.
    """
    pattern = rf"^[ \t]*(?:{'|'.join(names)})[ \t]*=.*$"
    tokens = set()
    for line in re.findall(pattern, watch, re.M):
        for literal in re.findall(r'"([^"$\n]*)"', line):
            if re.fullmatch(r"[a-z][a-z_-]*", literal):
                tokens.add(literal)
    return sorted(tokens)


print("block_tier\t%s" % " ".join(block_tokens("wake tier")))
print("verb_tier\t%s" % " ".join(emitted(["WAKE_TIER", "tier"])))
print("block_authority\t%s" % " ".join(block_tokens("authority")))
print("verb_authority\t%s" % " ".join(emitted(["WAKE_AUTHORITY"])))
PYEOF
)" || { fail "vocabulary extraction failed"; echo "Results: $PASS passed, $FAIL failed"; exit 1; }

field() { printf '%s\n' "$TOKENS" | awk -F'\t' -v key="$1" '$1 == key {print $2}'; }

BLOCK_TIER="$(field block_tier)"
VERB_TIER="$(field verb_tier)"
BLOCK_AUTHORITY="$(field block_authority)"
VERB_AUTHORITY="$(field verb_authority)"

# A block that stopped parsing would make every set comparison trivially pass.
if [[ -n "$BLOCK_TIER" && -n "$BLOCK_AUTHORITY" ]]; then
  pass "the INVARIANT block declares both vocabularies"
else
  fail "the INVARIANT block declares both vocabularies" "tiers='$BLOCK_TIER' authorities='$BLOCK_AUTHORITY'"
fi

# Set equality in both directions: the assertion is a single string compare of
# sorted token lists, so a token on either side alone shows up in the diff.
assert_eq "wake tiers: block and verb agree" "$BLOCK_TIER" "$VERB_TIER"
assert_eq "wake authorities: block and verb agree" "$BLOCK_AUTHORITY" "$VERB_AUTHORITY"

# The block pins the vocabulary the seat is taught; these are the terms it was
# written to pin, so a silent rewrite of the block itself does not pass by
# agreeing with a verb renamed in the same commit.
assert_eq "wake tiers are the canonical four" "advisory aged_advisory confirmed quiet" "$BLOCK_TIER"
assert_eq "wake authorities are the canonical four" "hook-row none owner-handle screen-signature" "$BLOCK_AUTHORITY"

# session-reference.md is where the seat reads what a tier or an authority means.
# A renamed token that reaches only the verb and the block leaves the reference
# explaining vocabulary nobody emits.
REFERENCE_TEXT="$(tr '\n' ' ' < "$REFERENCE" | tr -s ' ')"
for token in $BLOCK_TIER $BLOCK_AUTHORITY; do
  case "$REFERENCE_TEXT" in
    *'`'"$token"'`'*) pass "session-reference.md names \`$token\`" ;;
    *) fail "session-reference.md names \`$token\`" "not found in backticks" ;;
  esac
done

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
