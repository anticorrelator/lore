#!/usr/bin/env bash
# test_work_project_entity.sh — Regression tests for the project home substrate
# (_work/_projects/<slug>/) and the `lore work project` verb family:
#
#   1. describe-project.sh creates a directory home (_meta.json + overview.md)
#      defaulting to status active; updates preserve omitted fields; --status
#      validates the closed enum.
#   2. show-project.sh renders record fields plus active AND archived members
#      and delivers every additional document in the home; a recordless project
#      with members gets a members-only view with a no-record notice; no record
#      and no members is a non-zero error.
#   3. Scanner protection: heal-work.sh fabricates no _meta.json under
#      _projects/ (only migrates flat records), list-work.sh shows no _projects
#      row, and search-work.sh returns no _projects-labeled result.
#   4. Rollup headers append the declared-status token only when a record
#      exists with status != active.
#   5. Near-match label guard: create-work.sh --project and set-work-meta.sh
#      --project warn on stderr for edit-distance-close labels and still
#      complete the mutation; distinct labels stay silent.
#   6. archive-project.sh confirms unless --yes, archives every active member,
#      keeps going past per-member failures (non-zero exit, record status
#      unchanged), flips a pre-existing record to archived in place on a clean
#      sweep, and never creates a record for label-only projects.
#   7. Write-boundary identity gate: reusing a name that matches an archived
#      project (record-backed OR label-only) is a hard error on all three write
#      paths (create/set/describe) naming both resolution paths; --reuse-project
#      (create/set) and --reuse (describe) proceed and reactivate.
#   8. Migration: a legacy flat record migrates to the directory home on heal
#      and on first mutating touch (describe); read surfaces dual-read.

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

assert_file() {
  local label="$1" path="$2"
  if [[ -f "$path" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected file to exist: $path"
    FAIL=$((FAIL + 1))
  fi
}

assert_no_file() {
  local label="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected path to be absent: $path"
    FAIL=$((FAIL + 1))
  fi
}

write_meta() {
  mkdir -p "$KDIR/_work/$1"
  cat > "$KDIR/_work/$1/_meta.json"
}

# Read a field from a project home's _meta.json.
home_field() {
  python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" \
    "$KDIR/_work/_projects/$1/_meta.json" "$2"
}

# Read the project field from a work item's _meta.json (empty when unset).
item_project() {
  python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('project',''))" \
    "$KDIR/_work/$1/_meta.json"
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

# --- 1: describe creates a directory home with defaults -----------------------

bash "$SCRIPTS_DIR/describe-project.sh" "Alpha Effort" \
  --anchor "Ship the alpha" --description "Alpha body text" >/dev/null
HOME="$KDIR/_work/_projects/alpha-effort"
assert_file "describe: _meta.json created at _projects/alpha-effort/" "$HOME/_meta.json"
assert_file "describe: overview.md created at _projects/alpha-effort/" "$HOME/overview.md"
assert_eq "describe: omitted status defaults to active" "$(home_field alpha-effort status)" "active"
assert_eq "describe: anchor persisted in _meta.json" "$(home_field alpha-effort anchor)" "Ship the alpha"
assert_contains "describe: description persisted as overview.md body" \
  "$(cat "$HOME/overview.md")" "Alpha body text"

# --- 2: show renders record plus active AND archived members ------------------

SHOW_OUT=$(bash "$SCRIPTS_DIR/show-project.sh" alpha-effort 2>&1)
assert_contains "show: record anchor rendered" "$SHOW_OUT" "Anchor: Ship the alpha"
assert_contains "show: record description rendered" "$SHOW_OUT" "Alpha body text"
assert_contains "show: active member listed" "$SHOW_OUT" "member-one: Member One"
assert_contains "show: archived member listed" "$SHOW_OUT" "member-gone: Member Gone"

# --- 3: describe update preserves omitted fields; enum validated ---------------

bash "$SCRIPTS_DIR/describe-project.sh" alpha-effort --status done >/dev/null
assert_eq "describe update: status flipped to done" "$(home_field alpha-effort status)" "done"
assert_eq "describe update: omitted anchor preserved" "$(home_field alpha-effort anchor)" "Ship the alpha"
assert_contains "describe update: omitted description preserved" \
  "$(cat "$HOME/overview.md")" "Alpha body text"

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
assert_no_file "heal: no _meta.json fabricated directly under _projects/" \
  "$KDIR/_work/_projects/_meta.json"
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
assert_eq "create: near-match mutation still completes" "$(item_project near-item)" "alpha-efort"

SET_ERR=$(bash "$SCRIPTS_DIR/set-work-meta.sh" beta-item --project "beta-sde" 2>&1 >/dev/null)
assert_contains "set: near-match label warns on stderr" \
  "$SET_ERR" "[work] Warning: project 'beta-sde' is close to existing project 'beta-side'"
assert_eq "set: near-match mutation still completes" "$(item_project beta-item)" "beta-sde"

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
assert_eq "archive: record status unchanged after member failure" \
  "$(home_field alpha-effort status)" "done"

# --- 10: clean sweep flips a pre-existing record to archived in place ----------

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
assert_eq "archive: pre-existing record flipped to archived in place" \
  "$(home_field gamma-run status)" "archived"
assert_file "archive: archived home stays in _projects/ (no move)" \
  "$KDIR/_work/_projects/gamma-run/_meta.json"

# --- 11: label-only project archives without creating a record -----------------

BETA_ARCH=$(bash "$SCRIPTS_DIR/archive-project.sh" beta-side --yes 2>&1)
assert_contains "archive: label-only project reports no record to update" \
  "$BETA_ARCH" "[work] No project record to update (label-only project)"
assert_no_file "archive: label-only project gains no record" \
  "$KDIR/_work/_projects/beta-side/_meta.json"
assert_no_file "archive: label-only project gains no flat record" \
  "$KDIR/_work/_projects/beta-side.md"

# --- 12: write-boundary gate — record-backed archived identity -----------------

# Build a project with an archived-status record.
bash "$SCRIPTS_DIR/describe-project.sh" "Retired Effort" --description "retired body" >/dev/null
bash "$SCRIPTS_DIR/describe-project.sh" retired-effort --status archived >/dev/null
assert_eq "gate setup: retired-effort record is archived" "$(home_field retired-effort status)" "archived"

# create: rejected without --reuse-project, before any item directory is made.
set +e
CREATE_GATE=$(bash "$SCRIPTS_DIR/create-work.sh" --title "Rejoin Retired" \
  --project "retired-effort" 2>&1 >/dev/null)
CREATE_GATE_RC=$?
set -e
assert_exit_nonzero "create: archived name rejected without --reuse-project" "$CREATE_GATE_RC"
assert_contains "create: gate error names the reuse path" "$CREATE_GATE" "--reuse-project"
assert_contains "create: gate error names the rename path" "$CREATE_GATE" "choose a different name"
assert_no_file "create: gate blocks item creation" "$KDIR/_work/rejoin-retired/_meta.json"

# create --reuse-project: proceeds and reactivates the record to active.
bash "$SCRIPTS_DIR/create-work.sh" --title "Rejoin Retired" \
  --project "retired-effort" --reuse-project >/dev/null 2>&1
assert_eq "create --reuse-project: record reactivated to active" \
  "$(home_field retired-effort status)" "active"
assert_eq "create --reuse-project: item joined the project" \
  "$(item_project rejoin-retired)" "retired-effort"

# set: build a second archived-record project, gate the reassignment.
bash "$SCRIPTS_DIR/describe-project.sh" "Set Gate Proj" --description "x" >/dev/null
bash "$SCRIPTS_DIR/describe-project.sh" set-gate-proj --status archived >/dev/null
write_meta reassign-me <<'JSON'
{
  "slug": "reassign-me",
  "title": "Reassign Me",
  "status": "active",
  "created": "2026-06-01T00:00:00Z",
  "updated": "2026-06-10T00:00:00Z"
}
JSON
bash "$SCRIPTS_DIR/update-work-index.sh" "$KDIR" >/dev/null
set +e
SET_GATE=$(bash "$SCRIPTS_DIR/set-work-meta.sh" reassign-me --project "set-gate-proj" 2>&1 >/dev/null)
SET_GATE_RC=$?
set -e
assert_exit_nonzero "set: archived name rejected without --reuse-project" "$SET_GATE_RC"
assert_contains "set: gate error names the reuse path" "$SET_GATE" "--reuse-project"
assert_eq "set: gate blocks the reassignment" "$(item_project reassign-me)" ""

bash "$SCRIPTS_DIR/set-work-meta.sh" reassign-me --project "set-gate-proj" --reuse-project >/dev/null 2>&1
assert_eq "set --reuse-project: record reactivated to active" \
  "$(home_field set-gate-proj status)" "active"
assert_eq "set --reuse-project: item joined the project" \
  "$(item_project reassign-me)" "set-gate-proj"

# describe: gate on the record-writing path itself.
bash "$SCRIPTS_DIR/describe-project.sh" "Describe Gate Proj" --description "orig" >/dev/null
bash "$SCRIPTS_DIR/describe-project.sh" describe-gate-proj --status archived >/dev/null
set +e
DESC_GATE=$(bash "$SCRIPTS_DIR/describe-project.sh" describe-gate-proj --description "new" 2>&1 >/dev/null)
DESC_GATE_RC=$?
set -e
assert_exit_nonzero "describe: archived name rejected without --reuse" "$DESC_GATE_RC"
assert_contains "describe: gate error names the reuse path" "$DESC_GATE" "--reuse"
assert_eq "describe: gate blocks the update" "$(home_field describe-gate-proj status)" "archived"

bash "$SCRIPTS_DIR/describe-project.sh" describe-gate-proj --description "new" --reuse >/dev/null
assert_eq "describe --reuse: record reactivated to active" \
  "$(home_field describe-gate-proj status)" "active"
assert_contains "describe --reuse: update applied" \
  "$(cat "$KDIR/_work/_projects/describe-gate-proj/overview.md")" "new"

# --- 13: write-boundary gate — label-only archived identity (D2 common case) ---

write_meta labelonly-member <<'JSON'
{
  "slug": "labelonly-member",
  "title": "Labelonly Member",
  "status": "active",
  "project": "labelonly-proj",
  "created": "2026-06-01T00:00:00Z",
  "updated": "2026-06-10T00:00:00Z"
}
JSON
bash "$SCRIPTS_DIR/update-work-index.sh" "$KDIR" >/dev/null
bash "$SCRIPTS_DIR/archive-work.sh" labelonly-member >/dev/null
bash "$SCRIPTS_DIR/update-work-index.sh" "$KDIR" >/dev/null

set +e
LO_GATE=$(bash "$SCRIPTS_DIR/create-work.sh" --title "Rejoin Labelonly" \
  --project "labelonly-proj" 2>&1 >/dev/null)
LO_GATE_RC=$?
set -e
assert_exit_nonzero "create: label-only archived identity rejected without --reuse-project" "$LO_GATE_RC"
assert_contains "create: label-only gate error names the reuse path" "$LO_GATE" "--reuse-project"

bash "$SCRIPTS_DIR/create-work.sh" --title "Rejoin Labelonly" \
  --project "labelonly-proj" --reuse-project >/dev/null 2>&1
assert_eq "create --reuse-project: item joined label-only project" \
  "$(item_project rejoin-labelonly)" "labelonly-proj"
assert_no_file "create --reuse-project: label-only reuse creates no record" \
  "$KDIR/_work/_projects/labelonly-proj/_meta.json"

# --- 14: migration — legacy flat record migrates on heal -----------------------

write_meta legacy-member <<'JSON'
{
  "slug": "legacy-member",
  "title": "Legacy Member",
  "status": "active",
  "project": "legacy-proj",
  "created": "2026-06-01T00:00:00Z",
  "updated": "2026-06-10T00:00:00Z"
}
JSON
mkdir -p "$KDIR/_work/_projects"
cat > "$KDIR/_work/_projects/legacy-proj.md" <<'EOF'
# Legacy Proj

**Status:** done
**Anchor:** legacy anchor

Legacy body text
EOF
bash "$SCRIPTS_DIR/update-work-index.sh" "$KDIR" >/dev/null
bash "$SCRIPTS_DIR/heal-work.sh" >/dev/null
assert_file "heal migration: directory home created" \
  "$KDIR/_work/_projects/legacy-proj/_meta.json"
assert_no_file "heal migration: flat record removed" \
  "$KDIR/_work/_projects/legacy-proj.md"
assert_eq "heal migration: anchor preserved" "$(home_field legacy-proj anchor)" "legacy anchor"
assert_eq "heal migration: status preserved" "$(home_field legacy-proj status)" "done"
assert_contains "heal migration: body preserved as overview.md" \
  "$(cat "$KDIR/_work/_projects/legacy-proj/overview.md")" "Legacy body text"
MIGRATED_LIST=$(bash "$SCRIPTS_DIR/list-work.sh" 2>&1)
assert_contains "heal migration: list still renders section with status token" \
  "$MIGRATED_LIST" "legacy-proj [done] — 1 active"

# --- 15: migration — mutating touch (describe) migrates a flat record ----------

cat > "$KDIR/_work/_projects/touch-proj.md" <<'EOF'
# Touch Proj

**Status:** active
**Anchor:** old anchor

old body
EOF
bash "$SCRIPTS_DIR/describe-project.sh" touch-proj --anchor "new anchor" >/dev/null
assert_file "touch migration: directory home created" \
  "$KDIR/_work/_projects/touch-proj/_meta.json"
assert_no_file "touch migration: flat record removed" \
  "$KDIR/_work/_projects/touch-proj.md"
assert_eq "touch migration: update applied over migrated fields" \
  "$(home_field touch-proj anchor)" "new anchor"
assert_contains "touch migration: pre-existing body preserved" \
  "$(cat "$KDIR/_work/_projects/touch-proj/overview.md")" "old body"

# --- 16: show delivers every home document (bag-of-files) ----------------------

bash "$SCRIPTS_DIR/describe-project.sh" "Doc Proj" --description "overview body" >/dev/null
echo "coordination ledger content" > "$KDIR/_work/_projects/doc-proj/coordination.md"
DOC_OUT=$(bash "$SCRIPTS_DIR/show-project.sh" doc-proj 2>&1)
assert_contains "show: overview body delivered" "$DOC_OUT" "overview body"
assert_contains "show: extra document header delivered" \
  "$DOC_OUT" "--- Document: coordination.md ---"
assert_contains "show: extra document content delivered" \
  "$DOC_OUT" "coordination ledger content"

# --- Results -----------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
