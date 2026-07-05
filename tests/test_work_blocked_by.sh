#!/usr/bin/env bash
# test_work_blocked_by.sh — Regression tests for the work-item `blocked_by`
# dependency-edge field (and the `ceremony_depth` scalar) across the bash
# substrate:
#
#   1. set-work-meta.sh --blocked-by appends the edge, deduplicates on re-run,
#      and update-work-index.sh projects it into active plans[] (default []).
#   2. --blocked-by rejects the whole call on a nonexistent, non-kebab, or
#      empty slug without mutating _meta.json.
#   3. Self-reference and cycle-closing edges (direct and via an intermediate
#      hop) are rejected with a non-zero exit naming the cycle; an edge onto an
#      archived target succeeds.
#   4. load-work-item.sh prints a `Blocked by:` line for items with edges and
#      omits it otherwise; --json carries blocked_by.
#   5. --ceremony-depth sets an integer 1-3 (clears on ""), rejects out-of-range
#      and non-integer values, projects into plans[], and surfaces in
#      load-work-item.sh (human line only when set; --json always).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"

PASS=0
FAIL=0
KDIR=$(mktemp -d)

cleanup() { rm -rf "$KDIR"; }
trap cleanup EXIT

export LORE_KNOWLEDGE_DIR="$KDIR"
mkdir -p "$KDIR/_work"

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected to find: $needle"
    FAIL=$((FAIL + 1))
  fi
}

assert_absent() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  FAIL: $label"
    echo "    Did not expect to find: $needle"
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

# Runs a command expecting a NON-zero exit (the whole-call rejection contract).
assert_fails() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  FAIL: $label (expected non-zero exit)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

write_meta() {
  mkdir -p "$KDIR/_work/$1"
  cat > "$KDIR/_work/$1/_meta.json"
}

meta_field() {
  # meta_field <slug> <python-expr-over-`m`>
  python3 -c "import json; m=json.load(open('$KDIR/_work/$1/_meta.json')); print($2)"
}

# --- Fixtures ----------------------------------------------------------------

for slug in item-a item-b item-c item-d; do
  write_meta "$slug" <<JSON
{
  "slug": "$slug",
  "title": "Item ${slug#item-}",
  "status": "active",
  "created": "2026-06-01T00:00:00Z",
  "updated": "2026-06-01T00:00:00Z"
}
JSON
done

mkdir -p "$KDIR/_work/_archive/archived-done"
cat > "$KDIR/_work/_archive/archived-done/_meta.json" <<'JSON'
{
  "slug": "archived-done",
  "title": "Archived Done",
  "status": "archived",
  "created": "2026-05-01T00:00:00Z",
  "updated": "2026-05-20T00:00:00Z"
}
JSON

# --- 1: append, dedupe, and index projection ---------------------------------

bash "$SCRIPTS_DIR/set-work-meta.sh" item-a --blocked-by item-b >/dev/null
assert_eq "append: --blocked-by stores the edge" \
  "$(meta_field item-a "m['blocked_by']")" "['item-b']"

bash "$SCRIPTS_DIR/set-work-meta.sh" item-a --blocked-by item-b >/dev/null
assert_eq "append: re-adding the same edge is a dedupe no-op" \
  "$(meta_field item-a "m['blocked_by']")" "['item-b']"

bash "$SCRIPTS_DIR/update-work-index.sh" "$KDIR" >/dev/null
INDEX_BLOCKED=$(python3 -c "
import json
d = json.load(open('$KDIR/_work/_index.json'))
p = {x['slug']: x for x in d['plans']}
print(p['item-a']['blocked_by'], p['item-d']['blocked_by'])
")
assert_eq "projection: plans[] row carries the edge; edgeless row defaults to []" \
  "$INDEX_BLOCKED" "['item-b'] []"

# --- 2: whole-call rejection on invalid slugs, no mutation -------------------

assert_fails "reject: nonexistent target exits non-zero" \
  bash "$SCRIPTS_DIR/set-work-meta.sh" item-a --blocked-by does-not-exist
assert_fails "reject: non-kebab target exits non-zero" \
  bash "$SCRIPTS_DIR/set-work-meta.sh" item-a --blocked-by Bad_Slug
assert_fails "reject: empty target exits non-zero" \
  bash "$SCRIPTS_DIR/set-work-meta.sh" item-a --blocked-by ""
assert_eq "reject: blocked_by unchanged after rejected calls" \
  "$(meta_field item-a "m['blocked_by']")" "['item-b']"

# --- 3: self-reference and cycle detection ----------------------------------

assert_fails "cycle: self-reference exits non-zero" \
  bash "$SCRIPTS_DIR/set-work-meta.sh" item-a --blocked-by item-a

# item-a is blocked by item-b; item-b --blocked-by item-a closes a 2-node loop.
DIRECT_OUT=$(bash "$SCRIPTS_DIR/set-work-meta.sh" item-b --blocked-by item-a 2>&1 || true)
assert_contains "cycle: direct loop rejected naming the cycle" \
  "$DIRECT_OUT" "item-b -> item-a"
assert_eq "cycle: rejected direct edge left item-b unmutated" \
  "$(meta_field item-b "m.get('blocked_by')")" "None"

# Build a->b->c, then item-c --blocked-by item-a closes the 3-node loop.
bash "$SCRIPTS_DIR/set-work-meta.sh" item-b --blocked-by item-c >/dev/null
TRANS_OUT=$(bash "$SCRIPTS_DIR/set-work-meta.sh" item-c --blocked-by item-a 2>&1 || true)
assert_contains "cycle: transitive loop rejected via intermediate hop" \
  "$TRANS_OUT" "item-c -> item-a -> item-b -> item-c"
assert_eq "cycle: rejected transitive edge left item-c unmutated" \
  "$(meta_field item-c "m.get('blocked_by')")" "None"

# --- 4: edge onto an archived target succeeds -------------------------------

bash "$SCRIPTS_DIR/set-work-meta.sh" item-a --blocked-by archived-done >/dev/null
assert_eq "archive: edge onto an archived target is accepted" \
  "$(meta_field item-a "m['blocked_by']")" "['item-b', 'archived-done']"

# --- 5: load-work-item.sh rendering (human + json) --------------------------

SHOW_A=$(bash "$SCRIPTS_DIR/load-work-item.sh" item-a 2>&1)
assert_contains "show: blocked item prints Blocked by: line" \
  "$SHOW_A" "Blocked by: item-b, archived-done"

SHOW_D=$(bash "$SCRIPTS_DIR/load-work-item.sh" item-d 2>&1)
assert_absent "show: edgeless item prints no Blocked by: line" \
  "$SHOW_D" "Blocked by:"

SHOW_A_JSON=$(bash "$SCRIPTS_DIR/load-work-item.sh" --json item-a 2>&1)
JSON_BLOCKED=$(printf '%s' "$SHOW_A_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['blocked_by'])")
assert_eq "show --json: carries blocked_by" \
  "$JSON_BLOCKED" "['item-b', 'archived-done']"

# --- 6: ceremony_depth set / clear / validation / projection ----------------

bash "$SCRIPTS_DIR/set-work-meta.sh" item-d --ceremony-depth 2 >/dev/null
assert_eq "ceremony: --ceremony-depth stores an integer" \
  "$(meta_field item-d "m['ceremony_depth']")" "2"

bash "$SCRIPTS_DIR/update-work-index.sh" "$KDIR" >/dev/null
INDEX_DEPTH=$(python3 -c "
import json
d = json.load(open('$KDIR/_work/_index.json'))
p = {x['slug']: x for x in d['plans']}
print(p['item-d']['ceremony_depth'], p['item-a']['ceremony_depth'])
")
assert_eq "ceremony: projected into plans[]; unset row defaults to 0" \
  "$INDEX_DEPTH" "2 0"

assert_fails "ceremony: out-of-range value rejected" \
  bash "$SCRIPTS_DIR/set-work-meta.sh" item-d --ceremony-depth 5
assert_fails "ceremony: non-integer value rejected" \
  bash "$SCRIPTS_DIR/set-work-meta.sh" item-d --ceremony-depth abc
assert_eq "ceremony: rejected calls leave the value unchanged" \
  "$(meta_field item-d "m['ceremony_depth']")" "2"

bash "$SCRIPTS_DIR/set-work-meta.sh" item-d --ceremony-depth "" >/dev/null
assert_eq "ceremony: empty value clears the field" \
  "$(meta_field item-d "'ceremony_depth' in m")" "False"

bash "$SCRIPTS_DIR/set-work-meta.sh" item-d --ceremony-depth 3 >/dev/null
SHOW_D2=$(bash "$SCRIPTS_DIR/load-work-item.sh" item-d 2>&1)
assert_contains "ceremony: human output prints Ceremony depth: when set" \
  "$SHOW_D2" "Ceremony depth: 3"
assert_absent "ceremony: item without depth prints no Ceremony depth: line" \
  "$SHOW_A" "Ceremony depth:"

SHOW_D_JSON=$(bash "$SCRIPTS_DIR/load-work-item.sh" --json item-d 2>&1)
JSON_DEPTH=$(printf '%s' "$SHOW_D_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['ceremony_depth'])")
assert_eq "show --json: carries ceremony_depth" "$JSON_DEPTH" "3"

# --- Results -----------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
