#!/usr/bin/env bash
# test_capture_activity.sh — capture.sh's activity field for preferences/.
#
# Covers: the refusal of a preference with no activity and of an unknown one,
# both listing the existing names; --new-activity admitting a name; the footer
# field in its one- and two-name forms; folding of case and spaces; refusal of
# --activity and --new-activity on other categories; the check running after
# store resolution and category defaulting; the preference-writing block after
# filing (stderr under --json); and the batch-capture.sh and lore-promote.sh
# seams that forward the flags.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
TEST_DIR=$(mktemp -d)
KDIR="$TEST_DIR/store"
CAPTURE_SH="$SCRIPT_DIR/capture.sh"
BATCH_CAPTURE_SH="$SCRIPT_DIR/batch-capture.sh"
PROMOTE_SH="$SCRIPT_DIR/lore-promote.sh"

PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; shift; for line in "$@"; do echo "    $line"; done; FAIL=$((FAIL + 1)); }

assert_equals() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "Expected: $3" "Got:      $2"; fi
}

assert_contains() {
  if printf '%s\n' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "Expected to contain: $3" "Got: $(printf '%s\n' "$2" | head -5)"; fi
}

assert_not_contains() {
  if printf '%s\n' "$2" | grep -qF -- "$3"; then fail "$1" "Did not expect: $3"; else pass "$1"; fi
}

assert_file_contains() {
  if [[ -f "$2" ]] && grep -qF -- "$3" "$2"; then
    pass "$1"
  else
    fail "$1" "Expected $2 to contain: $3" "Got: $(tail -1 "$2" 2>/dev/null || echo '<missing>')"
  fi
}

entry_count() {
  find "$KDIR/preferences" -name '*.md' ! -name README.md | wc -l | tr -d ' '
}

write_pref() {
  local slug="$1" title="$2" body="$3" activity="$4" status="${5:-current}"
  local meta="<!-- learned: 2026-10-01 | confidence: high | scale: subsystem | kind: fact"
  [[ -n "$activity" ]] && meta="$meta | activity: $activity"
  printf '# %s\n%s\n%s | status: %s -->\n' "$title" "$body" "$meta" "$status" > "$KDIR/preferences/$slug.md"
}

setup_store() {
  rm -rf "$KDIR"
  mkdir -p "$KDIR/preferences"
  printf '{}\n' > "$KDIR/_manifest.json"
  printf '# preferences/\nThe project working style.\n' > "$KDIR/preferences/README.md"
  write_pref coordination-cost "Arcs price themselves before they run" "Coordinators surface projected spend at arc open." coordination
  write_pref pr-bodies-plain "PR bodies describe what shipped" "No chronology in a PR body." pr-bodies
  write_pref titles-state-the-rule "A preference title states the rule itself" "Write the title as the line a diff is held against." preference-writing
  write_pref legacy "An entry filed before activities" "Still live." ""
  write_pref retired-one "A retired preference" "Not in force." retired-only retired
}

# Run capture against the fixture store; OUT gets stdout, ERR stderr, RC the status.
capture() {
  local out_file="$TEST_DIR/out" err_file="$TEST_DIR/err"
  bash "$CAPTURE_SH" --kdir "$KDIR" --scale subsystem --producer-role worker --protocol-slot test \
    --skip-manifest "$@" >"$out_file" 2>"$err_file"
  RC=$?
  OUT=$(cat "$out_file")
  ERR=$(cat "$err_file")
}

EXISTING="existing: coordination, general, pr-bodies, preference-writing"

echo "=== Capture Activity Tests ==="

echo ""
echo "Test 1: a preference with no --activity is refused, naming the existing activities"
setup_store
capture --category preferences --insight "Some preference without an activity"
assert_equals "exit status is 1" "$RC" "1"
assert_equals "refusal names the existing set (retired and untagged excluded)" "$ERR" \
  "[capture] Error: --activity is required for --category preferences; $EXISTING"
assert_equals "nothing was filed" "$(entry_count)" "5"

echo ""
echo "Test 2: an unknown activity is refused unless --new-activity is passed"
setup_store
capture --category preferences --insight "Commit subjects are sentence case" --activity commit-msg
assert_equals "exit status is 1" "$RC" "1"
assert_equals "refusal names the existing set and the way to create one" "$ERR" \
  "[capture] Error: --activity \"commit-msg\" is not an existing activity ($EXISTING); pass --new-activity to create it"
assert_equals "nothing was filed" "$(entry_count)" "5"
capture --category preferences --insight "Retired names do not count" --activity retired-only
assert_contains "a name only a retired entry carries is unknown" "$ERR" "is not an existing activity"

capture --category preferences --insight "Commit subjects are sentence case" \
  --title "Commit subjects are sentence case" --activity commit-messages --new-activity
assert_equals "--new-activity admits the name" "$RC" "0"
NEW_FILE="$KDIR/preferences/commit-subjects-are-sentence-case.md"
assert_file_contains "footer carries the new activity" "$NEW_FILE" "| activity: commit-messages |"
capture --category preferences --insight "Another"
assert_contains "the new name joins the vocabulary" "$ERR" \
  "existing: commit-messages, coordination, general, pr-bodies, preference-writing"

echo ""
echo "Test 3: known activities file with the footer field, folded and comma-joined"
setup_store
capture --category preferences --insight "Arcs open with a spend estimate" \
  --title "Arcs open with a spend estimate" --activity coordination
assert_equals "a known activity files" "$RC" "0"
assert_contains "filed line" "$OUT" "[capture] Filed to preferences/arcs-open-spend-estimate.md"
assert_file_contains "one-name footer" "$KDIR/preferences/arcs-open-spend-estimate.md" "| activity: coordination |"

capture --category preferences --insight "PR text is plain for release notes" \
  --title "PR text is plain for release notes" --activity "PR Bodies,Coordination"
assert_equals "two folded names file" "$RC" "0"
assert_file_contains "two-name footer, folded" "$KDIR/preferences/pr-text-is-plain-release-notes.md" \
  "| activity: pr-bodies, coordination |"

capture --category preferences --insight "General rule" --title "A general rule" --activity=general
assert_equals "general is always known, --activity= form works" "$RC" "0"
assert_file_contains "general footer" "$KDIR/preferences/general-rule.md" "| activity: general |"

capture --category preferences --insight "Three" --activity "pr-bodies,coordination,general"
assert_equals "three names are refused" "$RC" "1"
assert_contains "refusal says at most two" "$ERR" "--activity takes at most 2 names"
capture --category preferences --insight "Reserved" --activity untagged --new-activity
assert_contains "untagged is reserved" "$ERR" "is reserved"
capture --category preferences --insight "Bad" --activity "commit_msg" --new-activity
assert_contains "names outside [a-z0-9-] are refused" "$ERR" "is not a valid activity name"

echo ""
echo "Test 4: --activity and --new-activity do not apply to other categories"
setup_store
capture --category conventions --insight "A convention" --activity coordination
assert_equals "--activity on conventions exits 1" "$RC" "1"
assert_equals "--activity refusal" "$ERR" \
  "[capture] Error: --activity does not apply to --category \"conventions\"; it belongs to preferences entries"
capture --category gotchas --insight "A gotcha" --new-activity
assert_equals "--new-activity refusal" "$ERR" \
  "[capture] Error: --new-activity does not apply to --category \"gotchas\"; it belongs to preferences entries"
capture --insight "Default category" --activity coordination
assert_contains "the check runs after the category defaults to conventions" "$ERR" \
  "--activity does not apply to --category \"conventions\""
[[ -d "$KDIR/conventions" ]] && fail "no convention was filed" "found $KDIR/conventions" || pass "no convention was filed"

capture --category conventions --insight "A plain convention" --title "A plain convention"
assert_equals "a convention without --activity still files" "$RC" "0"
assert_not_contains "no activity field on a convention" "$(cat "$KDIR/conventions/plain-convention.md")" "activity:"
assert_not_contains "no preference block after a convention" "$OUT" "Preferences for"

echo ""
echo "Test 5: the check runs after store resolution"
MISSING="$TEST_DIR/no-store"
mkdir -p "$MISSING"
OUT_MISSING=$(bash "$CAPTURE_SH" --kdir "$MISSING" --scale subsystem --category preferences --insight "x" 2>&1)
assert_contains "a missing store is reported before the activity" "$OUT_MISSING" "No knowledge store found"
assert_not_contains "no activity refusal for a missing store" "$OUT_MISSING" "--activity is required"

echo ""
echo "Test 6: after filing a preference, capture prints the preference-writing block"
setup_store
capture --category preferences --insight "Rules are written as the rule" --title "Rules are written as the rule" \
  --activity preference-writing
assert_equals "files" "$RC" "0"
assert_contains "block header on stdout counts the new entry" "$OUT" "Preferences for preference-writing (2):"
assert_contains "block carries an existing title" "$OUT" "- A preference title states the rule itself"
assert_contains "block carries the body, indented" "$OUT" "  Write the title as the line a diff is held against."
assert_contains "block ends with the listing command" "$OUT" \
  "Full set: lore search --preferences --activity preference-writing"
FIRST_LINE=$(printf '%s\n' "$OUT" | head -1)
assert_equals "the filed line still comes first" "$FIRST_LINE" "[capture] Filed to preferences/rules-are-written-as-rule.md"

rm -f "$KDIR/preferences/titles-state-the-rule.md" "$KDIR/preferences/rules-are-written-as-rule.md"
capture --category preferences --insight "Coordination rule" --title "Coordination rule" --activity coordination
assert_contains "an empty preference-writing activity says none filed" "$OUT" \
  "Preferences for preference-writing: none filed."

echo ""
echo "Test 7: under --json stdout stays one JSON value and the block goes to stderr"
setup_store
capture --category preferences --insight "JSON mode rule" --title "JSON mode rule" --activity pr-bodies --json
assert_equals "files" "$RC" "0"
PARSED=$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["path"])' 2>&1)
assert_equals "stdout parses as one JSON object" "$PARSED" "preferences/json-mode-rule.md"
assert_contains "block on stderr" "$ERR" "Preferences for preference-writing (1):"
assert_not_contains "no block on stdout" "$OUT" "Preferences for"

capture --category preferences --insight "JSON refusal" --json
assert_equals "refusal exits 1 under --json" "$RC" "1"
REFUSAL=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["error"])' 2>&1)
assert_equals "refusal is the JSON error" "$REFUSAL" "--activity is required for --category preferences; $EXISTING"

echo ""
echo "Test 8: batch-capture.sh forwards activity and new_activity and surfaces refusals"
setup_store
BATCH_FILE="$TEST_DIR/batch.json"
cat > "$BATCH_FILE" <<'JSON'
[
  {"insight": "Batch with no activity", "scale": "subsystem", "category": "preferences"},
  {"insight": "Batch unknown", "scale": "subsystem", "category": "preferences", "activity": "commit-msg"},
  {"insight": "Batch known", "title": "Batch known activity", "scale": "subsystem", "category": "preferences", "activity": "coordination"},
  {"insight": "Batch list", "title": "Batch list activities", "scale": "subsystem", "category": "preferences",
   "activity": ["commit-messages", "pr-bodies"], "new_activity": true}
]
JSON
BATCH_ERR=$(LORE_KNOWLEDGE_DIR="$KDIR" bash "$BATCH_CAPTURE_SH" --file "$BATCH_FILE" 2>&1 >/dev/null)
assert_contains "missing activity surfaces capture's refusal" "$BATCH_ERR" \
  "Entry 1/4: failed — [capture] Error: --activity is required for --category preferences; $EXISTING"
assert_contains "unknown activity surfaces capture's refusal" "$BATCH_ERR" \
  "Entry 2/4: failed — [capture] Error: --activity \"commit-msg\" is not an existing activity"
assert_file_contains "activity forwarded" "$KDIR/preferences/batch-known-activity.md" "| activity: coordination |"
assert_file_contains "list activity and new_activity forwarded" "$KDIR/preferences/batch-list-activities.md" \
  "| activity: commit-messages, pr-bodies |"

echo ""
echo "Test 9: lore-promote.sh forwards --activity"
if ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP: jq not available — lore-promote.sh seam not exercised"
else
  ROW_FILE="$TEST_DIR/tier3.json"
  cat > "$ROW_FILE" <<'JSON'
{"claim_id": "promote-seam-activity-01",
 "tier": "reusable",
 "claim": "Promotion into preferences carries the activity to the entry writer",
 "producer_role": "worker",
 "protocol_slot": "implement-step-3",
 "scale": "implementation",
 "why_future_agent_cares": "A preference promoted without an activity is refused by capture",
 "falsifier": "A planned capture invocation for a preferences promotion with no --activity",
 "related_files": ["scripts/lore-promote.sh"],
 "source_artifact_ids": ["t2-activity-seam"],
 "work_item": "preferences-by-activity",
 "confidence": "unaudited",
 "captured_at_sha": "0000000000000000000000000000000000000000"}
JSON
  PROMOTE_OUT=$(LORE_KNOWLEDGE_DIR="$KDIR" bash "$PROMOTE_SH" --file "$ROW_FILE" --work-item preferences-by-activity \
    --category preferences --activity coordination --dry-run 2>&1)
  assert_contains "planned capture invocation carries --activity" "$PROMOTE_OUT" "--activity coordination"
  PROMOTE_HELP=$(bash "$PROMOTE_SH" --help)
  assert_contains "help documents --activity" "$PROMOTE_HELP" "--activity <name>[,<name>]"
  assert_contains "help reaches the header's last line" "$PROMOTE_HELP" "2+ propagated from capture.sh"
fi

echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
