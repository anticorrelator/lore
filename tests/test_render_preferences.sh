#!/usr/bin/env bash
# test_render_preferences.sh — contract test for scripts/render-preferences.sh.
#
# The renderer is a thin wrapper over `pk_activities.py block`: the text it
# prints must be the module's, byte for byte, whether the activities come from
# a command's row in the STARTS table or are named directly, and --json must
# pass the module's object through. Exercised against a fixture store.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/render-preferences.sh"
MODULE="$REPO_DIR/scripts/pk_activities.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

KDIR="$TMP/store"
mkdir -p "$KDIR/preferences/nested"
printf '{}\n' > "$KDIR/_manifest.json"

entry() {
  local rel="$1" title="$2" body="$3" footer="$4"
  mkdir -p "$(dirname "$KDIR/$rel")"
  printf '# %s\n%s\n<!-- %s -->\n' "$title" "$body" "$footer" > "$KDIR/$rel"
}

entry preferences/a-cost.md "Arcs price themselves before running" \
  $'Coordinators surface projected spend.\n\nA second paragraph stays in the block.' \
  "learned: 2026-10-01 | activity: coordination | status: current"
entry preferences/b-routing.md "Every role routes to one model" \
  "Routing is uniform for now." \
  "learned: 2026-10-01 | activity: model-routing, coordination | status: current"
entry preferences/nested/c-scoping.md "Scope the whole goal" \
  "Do not defer parts of the stated goal." \
  "learned: 2026-10-01 | activity: work-scoping"
entry preferences/d-retired.md "A retired coordination rule" \
  "Never printed." \
  "learned: 2026-07-01 | activity: coordination | status: retired"
printf '# preferences/\nMentions coordination.\n' > "$KDIR/preferences/README.md"

echo "=== render-preferences.sh ==="

# --- --command: activities from the STARTS table, in the table's order --------
echo "Command lookup"
out="$(bash "$SCRIPT" --kdir "$KDIR" --command "arc open")" && rc=0 || rc=$?
check "arc open renders (exit 0)" '[[ $rc -eq 0 ]]'
expected="$(python3 "$MODULE" --kdir "$KDIR" block coordination model-routing)"
check "text is pk_activities.py block for the command's activities" '[[ "$out" == "$expected" ]]'
check "coordination block first, with its count" '[[ "$(printf "%s\n" "$out" | head -1)" == "Preferences for coordination (2):" ]]'
check "model-routing block follows" 'grep -qx "Preferences for model-routing (1):" <<<"$out"'
check "entry body is delivered in full" 'grep -qx "  A second paragraph stays in the block." <<<"$out"'
check "an entry under two activities is under both" '[[ "$(grep -c "^- Every role routes to one model$" <<<"$out")" -eq 2 ]]'
check "each block ends with the listing command" 'grep -qx "Full set: lore search --preferences --activity model-routing" <<<"$out"'
check "retired entries are not printed" '! grep -q "retired coordination rule" <<<"$out"'
check "README is not an entry" '! grep -q "Mentions coordination" <<<"$out"'

out="$(bash "$SCRIPT" --kdir "$KDIR" --command "spec start")"
check "spec start prints work-scoping from a nested entry" 'grep -qx "  Do not defer parts of the stated goal." <<<"$out"'

# --- --activity: names given directly, as words or repeated flags --------------
echo "Named activities"
words="$(bash "$SCRIPT" --kdir "$KDIR" --activity work-scoping coordination)"
repeated="$(bash "$SCRIPT" --kdir "$KDIR" --activity work-scoping --activity coordination)"
expected="$(python3 "$MODULE" --kdir "$KDIR" block work-scoping coordination)"
check "several names after one flag render in the order given" '[[ "$words" == "$expected" ]]'
check "a repeated flag renders the same text" '[[ "$repeated" == "$words" ]]'

# --- the empty form ------------------------------------------------------------
echo "Empty form"
out="$(bash "$SCRIPT" --kdir "$KDIR" --command "arc close")"
check "an activity no entry carries prints none filed" '[[ "$out" == "Preferences for human-writing: none filed." ]]'
EMPTY="$TMP/empty-store"
mkdir -p "$EMPTY"
out="$(bash "$SCRIPT" --kdir "$EMPTY" --activity general)"
check "a store with no preferences/ prints none filed" '[[ "$out" == "Preferences for general: none filed." ]]'

# --- --json passes the module's object through ---------------------------------
echo "JSON form"
json="$(bash "$SCRIPT" --kdir "$KDIR" --command "arc open" --json)"
expected="$(python3 "$MODULE" --kdir "$KDIR" --json block coordination model-routing)"
check "--json output is the module's object" '[[ "$json" == "$expected" ]]'
check "--json parses with activities and text" \
  'python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d[\"activities\"]==[\"coordination\",\"model-routing\"]; assert d[\"text\"].startswith(\"Preferences for coordination (2):\")" "$json"'
text="$(bash "$SCRIPT" --kdir "$KDIR" --command "arc open")"
check "--json text equals the human text" \
  'python3 -c "import json,sys; assert json.loads(sys.argv[1])[\"text\"].rstrip(\"\n\")==sys.argv[2]" "$json" "$text"'

# --- refusals --------------------------------------------------------------------
echo "Refusals"
refused() { local err; err="$(bash "$SCRIPT" "$@" 2>&1 >/dev/null)" && return 1; printf '%s' "$err"; }
err="$(refused --command "arc open")" && check "missing --kdir is refused" 'grep -q -- "--kdir is required" <<<"$err"' || fail "missing --kdir is refused"
err="$(refused --kdir "$TMP/nowhere" --command "arc open")" && check "a store that does not exist is refused" 'grep -q "not found" <<<"$err"' || fail "a store that does not exist is refused"
err="$(refused --kdir "$KDIR")" && check "neither --command nor --activity is refused" 'grep -q -- "--command" <<<"$err"' || fail "neither --command nor --activity is refused"
err="$(refused --kdir "$KDIR" --command "arc open" --activity general)" && check "both --command and --activity are refused" 'grep -q "not both" <<<"$err"' || fail "both --command and --activity are refused"
err="$(refused --kdir "$KDIR" --command "no such verb")" && check "a command the table starts nothing for is refused by name" 'grep -q "no such verb" <<<"$err"' || fail "a command the table starts nothing for is refused by name"
err="$(refused --kdir "$KDIR" --activity "Not_Valid")" && check "a name outside the alphabet is refused" 'grep -q "not a valid activity name" <<<"$err"' || fail "a name outside the alphabet is refused"
err="$(refused --kdir "$KDIR" --activity)" && check "--activity with no name is refused" 'grep -q "at least one name" <<<"$err"' || fail "--activity with no name is refused"
err="$(refused --kdir "$KDIR" --bogus)" && check "an unknown argument is refused" 'grep -q "unknown argument" <<<"$err"' || fail "an unknown argument is refused"

# --- help prints the whole header ------------------------------------------------
echo "Help"
help="$(bash "$SCRIPT" --help)"
check "--help prints the header's last line" 'grep -q "outside \[a-z0-9-\]\." <<<"$help"'
check "--help prints the usage lines" 'grep -q -- "--activity <name>\.\.\. \[--json\]" <<<"$help"'

echo ""
echo "=== Results ==="
echo "$PASS/$((PASS + FAIL)) passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
