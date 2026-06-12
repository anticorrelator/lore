#!/usr/bin/env bash
# test_work_project_grouping.sh — Regression tests for the work-item `project`
# grouping field across the bash substrate:
#
#   1. create-work.sh --project persists the slugified value in _meta.json.
#   2. update-work-index.sh projects `project` into active plans[] AND
#      archived rows.
#   3. set-work-meta.sh --project slugifies on write; --project "" clears.
#   4. list-work.sh renders grouped sections first (recency-ordered, members
#      recency-sorted) with ungrouped items in a flat tail; a no-project store
#      renders without any section artifacts.
#   5. load-work.sh (SessionStart digest) renders project sections with
#      indented member lines; ungrouped lines keep the legacy format.
#   6. load-work-item.sh prints a Project: line for grouped items and none
#      for legacy items.
#   7. heal-work.sh orphan regeneration writes a _meta.json carrying
#      project/scope/intent_anchor (template parity with create-work.sh).

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

write_meta() {
  mkdir -p "$KDIR/_work/$1"
  cat > "$KDIR/_work/$1/_meta.json"
}

# --- Fixtures ----------------------------------------------------------------

write_meta grouped-new <<'JSON'
{
  "slug": "grouped-new",
  "title": "Grouped New",
  "status": "active",
  "project": "tui-rework",
  "created": "2026-06-01T00:00:00Z",
  "updated": "2026-06-10T00:00:00Z"
}
JSON

write_meta grouped-old <<'JSON'
{
  "slug": "grouped-old",
  "title": "Grouped Old",
  "status": "active",
  "project": "tui-rework",
  "created": "2026-05-01T00:00:00Z",
  "updated": "2026-06-01T00:00:00Z"
}
JSON

write_meta other-group <<'JSON'
{
  "slug": "other-group",
  "title": "Other Group",
  "status": "active",
  "project": "side-effort",
  "created": "2026-06-01T00:00:00Z",
  "updated": "2026-06-11T00:00:00Z"
}
JSON

# Legacy item: no project field at all.
write_meta legacy-item <<'JSON'
{
  "slug": "legacy-item",
  "title": "Legacy Item",
  "status": "active",
  "created": "2026-06-01T00:00:00Z",
  "updated": "2026-06-09T00:00:00Z"
}
JSON

mkdir -p "$KDIR/_work/_archive/archived-member"
cat > "$KDIR/_work/_archive/archived-member/_meta.json" <<'JSON'
{
  "slug": "archived-member",
  "title": "Archived Member",
  "status": "archived",
  "project": "tui-rework",
  "created": "2026-05-01T00:00:00Z",
  "updated": "2026-05-20T00:00:00Z"
}
JSON

# --- 1: create-work.sh --project slugifies on write -------------------------

bash "$SCRIPTS_DIR/create-work.sh" --title "Flag Created" --project "TUI Rework" >/dev/null 2>&1
CREATED_PROJECT=$(python3 -c "
import json
print(json.load(open('$KDIR/_work/flag-created/_meta.json'))['project'])
")
assert_eq "create: --project 'TUI Rework' stored as slug" "$CREATED_PROJECT" "tui-rework"

# --- 2: index projection (active + archived) --------------------------------

bash "$SCRIPTS_DIR/update-work-index.sh" "$KDIR" >/dev/null

INDEX_PROJECTS=$(python3 -c "
import json
d = json.load(open('$KDIR/_work/_index.json'))
plans = {p['slug']: p.get('project') for p in d['plans']}
archived = {p['slug']: p.get('project') for p in d['archived']}
print(plans['grouped-new'], plans['legacy-item'] == '', archived['archived-member'])
")
assert_eq "projection: active rows and archived rows carry project; legacy defaults to empty" \
  "$INDEX_PROJECTS" "tui-rework True tui-rework"

# --- 3: set-work-meta.sh --project set / clear -------------------------------

bash "$SCRIPTS_DIR/set-work-meta.sh" legacy-item --project "New Effort" >/dev/null
SET_PROJECT=$(python3 -c "
import json
print(json.load(open('$KDIR/_work/legacy-item/_meta.json'))['project'])
")
assert_eq "set: --project 'New Effort' stored as slug" "$SET_PROJECT" "new-effort"

bash "$SCRIPTS_DIR/set-work-meta.sh" legacy-item --project "" >/dev/null
CLEARED=$(python3 -c "
import json
print('project' in json.load(open('$KDIR/_work/legacy-item/_meta.json')))
")
assert_eq "set: --project '' clears membership" "$CLEARED" "False"

# --- 4: list-work.sh grouped rendering ---------------------------------------

LIST_OUT=$(bash "$SCRIPTS_DIR/list-work.sh" 2>&1)
assert_contains "list: tui-rework section header with member count" \
  "$LIST_OUT" "tui-rework (3)"
assert_contains "list: side-effort section header" \
  "$LIST_OUT" "side-effort (1)"
assert_contains "list: ungrouped legacy item still listed" \
  "$LIST_OUT" "legacy-item"

# Section order: tui-rework leads because its newest member (flag-created)
# was created just now, beating side-effort's 06-11 member.
TUI_LINE=$(printf '%s\n' "$LIST_OUT" | grep -nF "tui-rework (" | cut -d: -f1)
SIDE_LINE=$(printf '%s\n' "$LIST_OUT" | grep -nF "side-effort (" | cut -d: -f1)
if [[ "$TUI_LINE" -lt "$SIDE_LINE" ]]; then
  echo "  PASS: list: project sections ordered by most-recent member update"
  PASS=$((PASS + 1))
else
  echo "  FAIL: list: project sections ordered by most-recent member update"
  echo "    tui-rework at line $TUI_LINE, side-effort at line $SIDE_LINE"
  FAIL=$((FAIL + 1))
fi

# Members recency-sorted within section: grouped-new (06-10) above grouped-old (06-01).
NEW_LINE=$(printf '%s\n' "$LIST_OUT" | grep -n "^  grouped-new" | cut -d: -f1)
OLD_LINE=$(printf '%s\n' "$LIST_OUT" | grep -n "^  grouped-old" | cut -d: -f1)
if [[ "$NEW_LINE" -lt "$OLD_LINE" ]]; then
  echo "  PASS: list: members recency-sorted within section"
  PASS=$((PASS + 1))
else
  echo "  FAIL: list: members recency-sorted within section"
  FAIL=$((FAIL + 1))
fi

ALL_OUT=$(bash "$SCRIPTS_DIR/list-work.sh" --all 2>&1)
assert_contains "list --all: archived member shows its project" \
  "$ALL_OUT" "archived-member: Archived Member project:tui-rework"

# --- 5: load-work.sh digest grouping -----------------------------------------

LOAD_OUT=$(bash "$SCRIPTS_DIR/load-work.sh" 2>&1)
assert_contains "digest: project section header" "$LOAD_OUT" "tui-rework (3):"
assert_contains "digest: member line indented under section" \
  "$LOAD_OUT" "  - grouped-new: Grouped New"
assert_contains "digest: ungrouped item keeps legacy flat line" \
  "$LOAD_OUT" "- legacy-item: Legacy Item"

# --- 6: load-work-item.sh Project: line --------------------------------------

SHOW_OUT=$(bash "$SCRIPTS_DIR/load-work-item.sh" grouped-new 2>&1)
assert_contains "show: grouped item prints Project: line" "$SHOW_OUT" "Project: tui-rework"

SHOW_LEGACY=$(bash "$SCRIPTS_DIR/load-work-item.sh" legacy-item 2>&1)
assert_absent "show: legacy item prints no Project: line" "$SHOW_LEGACY" "Project:"

# --- 7: heal-work.sh orphan template parity ----------------------------------

mkdir -p "$KDIR/_work/orphan-dir"
bash "$SCRIPTS_DIR/heal-work.sh" >/dev/null
ORPHAN_FIELDS=$(python3 -c "
import json
m = json.load(open('$KDIR/_work/orphan-dir/_meta.json'))
print(m.get('project') == '', m.get('scope'), 'intent_anchor' in m)
")
assert_eq "heal: orphan meta carries project/scope/intent_anchor" \
  "$ORPHAN_FIELDS" "True subsystem True"

# --- 8: no-project store renders without section artifacts -------------------

KDIR2=$(mktemp -d)
mkdir -p "$KDIR2/_work/plain-item"
cat > "$KDIR2/_work/plain-item/_meta.json" <<'JSON'
{
  "slug": "plain-item",
  "title": "Plain Item",
  "status": "active",
  "created": "2026-06-01T00:00:00Z",
  "updated": "2026-06-09T00:00:00Z"
}
JSON
PLAIN_OUT=$(LORE_KNOWLEDGE_DIR="$KDIR2" bash "$SCRIPTS_DIR/list-work.sh" 2>&1)
assert_contains "list: no-project store lists the item" "$PLAIN_OUT" "plain-item"
assert_absent "list: no-project store has no section separators between header and rows" \
  "$PLAIN_OUT" "(1)"
rm -rf "$KDIR2"

# --- Results -----------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
