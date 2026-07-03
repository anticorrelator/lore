#!/usr/bin/env bash
# test_work_project_entity.sh — Regression tests for the project record
# substrate (_work/_projects/) and the `lore work project` verb family:
#
#   1. describe-project.sh creates a record defaulting to **Status:** active;
#      updates preserve omitted fields; --status validates the closed enum.
#   2. show-project.sh renders record fields plus active AND archived members;
#      a recordless project with members gets a members-only view with a
#      no-record notice; no record and no members is a non-zero error.
#   3. Scanner protection: heal-work.sh fabricates no _meta.json under
#      _projects/, list-work.sh shows no _projects row, and search-work.sh
#      returns no _projects-labeled result.
#   4. Rollup headers append the declared-status token only when a record
#      exists with status != active.
#   5. Near-match label guard: create-work.sh --project and set-work-meta.sh
#      --project warn on stderr for edit-distance-close labels and still
#      complete the mutation; distinct labels stay silent.
#   6. archive-project.sh confirms unless --yes, archives every active member,
#      keeps going past per-member failures (non-zero exit, record status
#      unchanged), flips a pre-existing record to archived on a clean sweep,
#      and never creates a record for label-only projects.

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

assert_exit_nonzero() {
  local label="$1" rc="$2"
  if [[ "$rc" -ne 0 ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected non-zero exit, got 0"
    FAIL=$((FAIL + 1))
  fi
}

write_meta() {
  mkdir -p "$KDIR/_work/$1"
  cat > "$KDIR/_work/$1/_meta.json"
}

# --- Fixtures ----------------------------------------------------------------

write_meta member-one <<'JSON'
{
  "slug": "member-one",
  "title": "Member One",
  "status": "active",
  "project": "alpha-effort",
  "created": "2026-06-01T00:00:00Z",
  "updated": "2026-06-10T00:00:00Z"
}
JSON

write_meta member-two <<'JSON'
{
  "slug": "member-two",
  "title": "Member Two",
  "status": "active",
  "project": "alpha-effort",
  "created": "2026-05-01T00:00:00Z",
  "updated": "2026-06-01T00:00:00Z"
}
JSON

write_meta beta-item <<'JSON'
{
  "slug": "beta-item",
  "title": "Beta Item",
  "status": "active",
  "project": "beta-side",
  "created": "2026-06-01T00:00:00Z",
  "updated": "2026-06-05T00:00:00Z"
}
JSON

mkdir -p "$KDIR/_work/_archive/member-gone"
cat > "$KDIR/_work/_archive/member-gone/_meta.json" <<'JSON'
{
  "slug": "member-gone",
  "title": "Member Gone",
  "status": "archived",
  "project": "alpha-effort",
  "created": "2026-04-01T00:00:00Z",
  "updated": "2026-05-01T00:00:00Z"
}
JSON

bash "$SCRIPTS_DIR/update-work-index.sh" "$KDIR" >/dev/null

# --- 1: describe creates a record with defaults -------------------------------

bash "$SCRIPTS_DIR/describe-project.sh" "Alpha Effort" \
  --anchor "Ship the alpha" --description "Alpha body text" >/dev/null
RECORD="$KDIR/_work/_projects/alpha-effort.md"
if [[ -f "$RECORD" ]]; then
  echo "  PASS: describe: record created at _projects/alpha-effort.md"
  PASS=$((PASS + 1))
else
  echo "  FAIL: describe: record created at _projects/alpha-effort.md"
  FAIL=$((FAIL + 1))
fi
RECORD_TEXT=$(cat "$RECORD")
assert_contains "describe: omitted status defaults to active" \
  "$RECORD_TEXT" "**Status:** active"
assert_contains "describe: anchor persisted as bold field" \
  "$RECORD_TEXT" "**Anchor:** Ship the alpha"
assert_contains "describe: description persisted as freeform body" \
  "$RECORD_TEXT" "Alpha body text"

# --- 2: show renders record plus active AND archived members ------------------

SHOW_OUT=$(bash "$SCRIPTS_DIR/show-project.sh" alpha-effort 2>&1)
assert_contains "show: record anchor rendered" "$SHOW_OUT" "Anchor: Ship the alpha"
assert_contains "show: record description rendered" "$SHOW_OUT" "Alpha body text"
assert_contains "show: active member listed" "$SHOW_OUT" "member-one: Member One"
assert_contains "show: archived member listed" "$SHOW_OUT" "member-gone: Member Gone"

# --- 3: describe update preserves omitted fields; enum validated ---------------

bash "$SCRIPTS_DIR/describe-project.sh" alpha-effort --status done >/dev/null
RECORD_TEXT=$(cat "$RECORD")
assert_contains "describe update: status flipped to done" \
  "$RECORD_TEXT" "**Status:** done"
assert_contains "describe update: omitted anchor preserved" \
  "$RECORD_TEXT" "**Anchor:** Ship the alpha"
assert_contains "describe update: omitted description preserved" \
  "$RECORD_TEXT" "Alpha body text"

set +e
ENUM_ERR=$(bash "$SCRIPTS_DIR/describe-project.sh" alpha-effort --status bogus 2>&1)
ENUM_RC=$?
set -e
assert_exit_nonzero "describe: invalid --status rejected" "$ENUM_RC"
assert_contains "describe: enum error names valid values" \
  "$ENUM_ERR" "Invalid --status 'bogus'. Valid values: active done archived"

# --- 4: status token on rollup headers only when record status != active ------

LIST_OUT=$(bash "$SCRIPTS_DIR/list-work.sh" 2>&1)
assert_contains "list: declared-status token on non-active record" \
  "$LIST_OUT" "alpha-effort [done] — 2 active, 1 archived"
assert_contains "list: recordless project header has no token" \
  "$LIST_OUT" "beta-side — 1 active"
assert_absent "list: recordless project never gains a token" \
  "$LIST_OUT" "beta-side ["

LOAD_OUT=$(bash "$SCRIPTS_DIR/load-work.sh" 2>&1)
assert_contains "digest: declared-status token on non-active record" \
  "$LOAD_OUT" "alpha-effort [done] — 2 active, 1 archived:"

# --- 5: scanner protection for _projects/ -------------------------------------

bash "$SCRIPTS_DIR/heal-work.sh" >/dev/null
if [[ ! -f "$KDIR/_work/_projects/_meta.json" ]]; then
  echo "  PASS: heal: no _meta.json fabricated under _projects/"
  PASS=$((PASS + 1))
else
  echo "  FAIL: heal: no _meta.json fabricated under _projects/"
  FAIL=$((FAIL + 1))
fi
LIST_OUT=$(bash "$SCRIPTS_DIR/list-work.sh" 2>&1)
assert_absent "list: no _projects row after heal" "$LIST_OUT" "_projects"

SEARCH_OUT=$(bash "$SCRIPTS_DIR/search-work.sh" "Ship the alpha" 2>&1)
assert_absent "search: record content not surfaced as a work item" \
  "$SEARCH_OUT" "_projects"

# --- 6: show for recordless project with members; absence errors ---------------

BETA_OUT=$(bash "$SCRIPTS_DIR/show-project.sh" beta-side 2>&1)
assert_contains "show: recordless project renders no-record notice" \
  "$BETA_OUT" "(no project record"
assert_contains "show: recordless project still lists members" \
  "$BETA_OUT" "beta-item: Beta Item"

set +e
ABSENT_OUT=$(bash "$SCRIPTS_DIR/show-project.sh" no-such-project 2>&1)
ABSENT_RC=$?
set -e
assert_exit_nonzero "show: no record and no members exits non-zero" "$ABSENT_RC"
assert_contains "show: absence error is [work]-prefixed" \
  "$ABSENT_OUT" "[work] Error: No project record or members found for: no-such-project"

# --- 7: near-match label guard on both write paths ----------------------------

# Exact-label and distant-label silence, checked before any near label exists.
EXACT_ERR=$(bash "$SCRIPTS_DIR/set-work-meta.sh" member-one --project "alpha-effort" 2>&1 >/dev/null)
assert_absent "set: exact existing label stays silent" \
  "$EXACT_ERR" "[work] Warning: project"
DISTINCT_ERR=$(bash "$SCRIPTS_DIR/set-work-meta.sh" member-one --project "totally-unrelated" 2>&1 >/dev/null)
assert_absent "set: distant label stays silent" \
  "$DISTINCT_ERR" "[work] Warning: project"
bash "$SCRIPTS_DIR/set-work-meta.sh" member-one --project "alpha-effort" >/dev/null 2>&1

CREATE_ERR=$(bash "$SCRIPTS_DIR/create-work.sh" --title "Near Item" \
  --project "alpha-efort" 2>&1 >/dev/null)
assert_contains "create: near-match label warns on stderr" \
  "$CREATE_ERR" "[work] Warning: project 'alpha-efort' is close to existing project 'alpha-effort'"
CREATED_PROJECT=$(python3 -c "
import json
print(json.load(open('$KDIR/_work/near-item/_meta.json'))['project'])
")
assert_eq "create: near-match mutation still completes" "$CREATED_PROJECT" "alpha-efort"

SET_ERR=$(bash "$SCRIPTS_DIR/set-work-meta.sh" beta-item --project "beta-sde" 2>&1 >/dev/null)
assert_contains "set: near-match label warns on stderr" \
  "$SET_ERR" "[work] Warning: project 'beta-sde' is close to existing project 'beta-side'"
SET_PROJECT=$(python3 -c "
import json
print(json.load(open('$KDIR/_work/beta-item/_meta.json'))['project'])
")
assert_eq "set: near-match mutation still completes" "$SET_PROJECT" "beta-sde"

# Restore beta-item's label for the archive tests below (warns about the
# now-existing beta-sde near label; that noise is expected here).
bash "$SCRIPTS_DIR/set-work-meta.sh" beta-item --project "beta-side" >/dev/null 2>&1

# --- 8: archive-project confirmation gate --------------------------------------

set +e
ABORT_OUT=$(echo "n" | bash "$SCRIPTS_DIR/archive-project.sh" alpha-effort 2>&1)
ABORT_RC=$?
set -e
assert_exit_nonzero "archive: declined confirmation exits non-zero" "$ABORT_RC"
if [[ -d "$KDIR/_work/member-one" && -d "$KDIR/_work/member-two" ]]; then
  echo "  PASS: archive: declined confirmation archives nothing"
  PASS=$((PASS + 1))
else
  echo "  FAIL: archive: declined confirmation archives nothing"
  FAIL=$((FAIL + 1))
fi

# --- 9: per-member failure — continue, exit non-zero, record untouched ---------

# Force a failure on the first member (glob order) via an archive collision.
mkdir -p "$KDIR/_work/_archive/member-one"
set +e
FAIL_OUT=$(bash "$SCRIPTS_DIR/archive-project.sh" alpha-effort --yes 2>&1)
FAIL_RC=$?
set -e
assert_exit_nonzero "archive: member failure exits non-zero" "$FAIL_RC"
assert_contains "archive: member failure reported as warning" \
  "$FAIL_OUT" "[work] Warning: failed to archive member 'member-one'"
if [[ -f "$KDIR/_work/_archive/member-two/_meta.json" ]]; then
  echo "  PASS: archive: remaining members still attempted after a failure"
  PASS=$((PASS + 1))
else
  echo "  FAIL: archive: remaining members still attempted after a failure"
  FAIL=$((FAIL + 1))
fi
assert_contains "archive: record status unchanged after member failure" \
  "$(cat "$RECORD")" "**Status:** done"

# --- 10: clean sweep flips a pre-existing record to archived -------------------

write_meta gamma-member <<'JSON'
{
  "slug": "gamma-member",
  "title": "Gamma Member",
  "status": "active",
  "project": "gamma-run",
  "created": "2026-06-01T00:00:00Z",
  "updated": "2026-06-10T00:00:00Z"
}
JSON
bash "$SCRIPTS_DIR/describe-project.sh" gamma-run --anchor "g" >/dev/null

GAMMA_OUT=$(bash "$SCRIPTS_DIR/archive-project.sh" gamma-run --yes 2>&1)
assert_contains "archive: clean sweep reports archived member count" \
  "$GAMMA_OUT" "Archived project 'gamma-run': 1 member(s) archived"
if [[ -f "$KDIR/_work/_archive/gamma-member/_meta.json" ]]; then
  echo "  PASS: archive: active member moved to _archive"
  PASS=$((PASS + 1))
else
  echo "  FAIL: archive: active member moved to _archive"
  FAIL=$((FAIL + 1))
fi
assert_contains "archive: pre-existing record flipped to archived" \
  "$(cat "$KDIR/_work/_projects/gamma-run.md")" "**Status:** archived"

# --- 11: label-only project archives without creating a record -----------------

BETA_ARCH=$(bash "$SCRIPTS_DIR/archive-project.sh" beta-side --yes 2>&1)
assert_contains "archive: label-only project reports no record to update" \
  "$BETA_ARCH" "[work] No project record to update (label-only project)"
if [[ ! -f "$KDIR/_work/_projects/beta-side.md" ]]; then
  echo "  PASS: archive: label-only project gains no record"
  PASS=$((PASS + 1))
else
  echo "  FAIL: archive: label-only project gains no record"
  FAIL=$((FAIL + 1))
fi

# --- Results -----------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
