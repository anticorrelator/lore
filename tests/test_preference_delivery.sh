#!/usr/bin/env bash
# test_preference_delivery.sh — the verbs that start an activity print its
# preferences in full after their own output.
#
# On a fixture store, `arc open`, `arc close`, `spec start` and `impl start`
# each print the block for the activities pk_activities.STARTS declares for
# them: on stdout in human mode, on stderr under --json, where stdout must still
# parse as one JSON value. The block comes from the store the verb resolved
# (--kdir for the arc verbs, LORE_KNOWLEDGE_DIR for the start verbs), never
# from another one in the environment, and a verb that fails prints none.
# spec discover, which reads spec start's --json output, still gets one JSON
# value from it.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$REPO_DIR/scripts"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# --- Isolated environment: no operator settings, no real store ---------------
# impl start needs PyYAML, which may sit in the user site-packages that Python
# finds through HOME; keep that location when HOME moves.
PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null || true)}"
[[ -z "$PYTHONUSERBASE" ]] || export PYTHONUSERBASE
export HOME="$TMP/home"
export LORE_DATA_DIR="$HOME/.lore"
mkdir -p "$LORE_DATA_DIR/config"
printf '%s\n' '{"version":2,"tui_launch_framework":"claude-code","routes":{"default":"claude-code/default"},"harnesses":{"claude-code":{"args":[],"native_models":{"default":"opus"}}}}' \
  > "$LORE_DATA_DIR/config/settings.json"
export LORE_FRAMEWORK=claude-code
export LORE_MODEL_LEAD=claude-code/test-lead-model
export LORE_MODEL_WORKER=claude-code/test-worker-model
export LORE_MODEL_ADVISOR=claude-code/test-advisor-model

PROJECT="$TMP/project"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q
git -C "$PROJECT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$PROJECT" checkout -qb delivery-test-branch
cd "$PROJECT"

entry() {
  local kdir="$1" rel="$2" title="$3" body="$4" activity="$5"
  mkdir -p "$(dirname "$kdir/$rel")"
  printf '# %s\n%s\n<!-- learned: 2026-10-01 | confidence: high | activity: %s | status: current -->\n' \
    "$title" "$body" "$activity" > "$kdir/$rel"
}

KDIR="$TMP/store"
mkdir -p "$KDIR/_work"
printf '{}\n' > "$KDIR/_manifest.json"
entry "$KDIR" preferences/coord.md "Arcs price themselves before running" "Coordinators surface projected spend." coordination
entry "$KDIR" preferences/route.md "Every role routes to one model" "Routing is uniform for now." "model-routing"
entry "$KDIR" preferences/human.md "Reports stand on their own" "A reader with no context can follow the report." human-writing
entry "$KDIR" preferences/scope.md "Scope the whole goal" "Do not defer parts of the stated goal." work-scoping

# A second store in the environment. A verb that read it instead of the store it
# resolved would print these titles.
DECOY="$TMP/decoy"
mkdir -p "$DECOY/_work"
printf '{}\n' > "$DECOY/_manifest.json"
entry "$DECOY" preferences/decoy.md "Decoy coordination rule" "From the wrong store." coordination
entry "$DECOY" preferences/decoy-human.md "Decoy writing rule" "From the wrong store." human-writing

mkdir -p "$KDIR/_work/start-item"
printf '%s\n' '{"title":"Start Item","status":"active","intent_anchor":"Deliver startup."}' > "$KDIR/_work/start-item/_meta.json"
printf '%s\n' '# Start Item' '' '## Strategy' 'Use verbs.' '' '## Phases' '### Phase 1: Build' '- [ ] Build it [class: standard]' '' '## Open Questions' '- None.' \
  > "$KDIR/_work/start-item/plan.md"

mkdir -p "$KDIR/_work/widget-pipeline"
printf '%s\n' '{"title":"Widget Pipeline","status":"active","intent_anchor":"Ship widgets."}' > "$KDIR/_work/widget-pipeline/_meta.json"
printf '%s\n' '# Widget Pipeline' '' '## Phases' '### Phase 1: Build' '- [ ] build alpha' '- [ ] build beta' \
  > "$KDIR/_work/widget-pipeline/plan.md"

OUT="$TMP/out"
ERR="$TMP/err"

# run_verb <label> <cmd...>: runs the verb with stdout and stderr kept apart.
run_verb() {
  local label="$1"; shift
  if "$@" >"$OUT" 2>"$ERR"; then
    RC=0
  else
    RC=$?
  fi
  [[ $RC -eq 0 ]] || { echo "    ($label exited $RC)"; sed 's/^/    stderr: /' "$ERR" | head -5; }
}

line_of() { { grep -n -F -- "$1" "$2" || true; } | head -1 | cut -d: -f1; }

# assert_human <verb> <own-output marker> <activity:title:body>...
assert_human() {
  local verb="$1" marker="$2"; shift 2
  check "$verb: exits 0" '[[ $RC -eq 0 ]]'
  local spec activity title body own first
  for spec in "$@"; do
    activity="${spec%%:*}"; spec="${spec#*:}"; title="${spec%%:*}"; body="${spec#*:}"
    check "$verb: stdout carries the $activity block" 'grep -qx "Preferences for $activity (1):" "$OUT"'
    check "$verb: stdout carries the $activity entry in full" 'grep -qx -- "- $title" "$OUT" && grep -qx "  $body" "$OUT"'
  done
  own="$(line_of "$marker" "$OUT")"
  first="$(line_of "Preferences for " "$OUT")"
  check "$verb: the block follows the verb's own output" '[[ -n "$own" && -n "$first" && $own -lt $first ]]'
  check "$verb: stderr carries no block" '! grep -q "Preferences for " "$ERR"'
  check "$verb: nothing from another store" '! grep -q "Decoy" "$OUT" "$ERR"'
}

# assert_json <verb> <activity:title:body>...
assert_json() {
  local verb="$1"; shift
  check "$verb --json: exits 0" '[[ $RC -eq 0 ]]'
  check "$verb --json: stdout parses as one JSON value" \
    'python3 -c "import json,sys; json.loads(open(sys.argv[1]).read())" "$OUT"'
  check "$verb --json: stdout carries no block" '! grep -q "Preferences for " "$OUT"'
  local spec activity title body
  for spec in "$@"; do
    activity="${spec%%:*}"; spec="${spec#*:}"; title="${spec%%:*}"; body="${spec#*:}"
    check "$verb --json: stderr carries the $activity block" 'grep -qx "Preferences for $activity (1):" "$ERR"'
    check "$verb --json: stderr carries the $activity entry in full" 'grep -qx -- "- $title" "$ERR" && grep -qx "  $body" "$ERR"'
  done
  check "$verb --json: nothing from another store" '! grep -q "Decoy" "$OUT" "$ERR"'
}

COORD="coordination:Arcs price themselves before running:Coordinators surface projected spend."
ROUTE="model-routing:Every role routes to one model:Routing is uniform for now."
HUMAN="human-writing:Reports stand on their own:A reader with no context can follow the report."
SCOPE="work-scoping:Scope the whole goal:Do not defer parts of the stated goal."

echo "=== Preference delivery at the verbs that start an activity ==="

echo "arc open"
run_verb "arc open" env LORE_KNOWLEDGE_DIR="$DECOY" bash "$SCRIPTS/arc-open.sh" --kdir "$KDIR" --no-watcher --title "Arc one" --anchor "one"
assert_human "arc open" "[arc] Opened: arc-one" "$COORD" "$ROUTE"
check "arc open: coordination comes before model-routing, as STARTS lists them" \
  '[[ $(line_of "Preferences for coordination" "$OUT") -lt $(line_of "Preferences for model-routing" "$OUT") ]]'
run_verb "arc open --json" env LORE_KNOWLEDGE_DIR="$DECOY" bash "$SCRIPTS/arc-open.sh" --kdir "$KDIR" --no-watcher --title "Arc two" --anchor "two" --json
assert_json "arc open" "$COORD" "$ROUTE"
check "arc open --json: stdout is the arc record" \
  'python3 -c "import json,sys; assert json.load(open(sys.argv[1]))[\"slug\"]==\"arc-two\"" "$OUT"'

echo "arc open refused"
run_verb "arc open (collision)" bash "$SCRIPTS/arc-open.sh" --kdir "$KDIR" --no-watcher --title "Arc one" --anchor "again"
check "a refused open exits non-zero" '[[ $RC -ne 0 ]]'
check "a refused open prints no block" '! grep -q "Preferences for " "$OUT" "$ERR"'

echo "arc close"
run_verb "arc close" env LORE_KNOWLEDGE_DIR="$DECOY" bash "$SCRIPTS/arc-close.sh" --kdir "$KDIR" arc-one
assert_human "arc close" "[arc] Closed: arc-one" "$HUMAN"
run_verb "arc close --json" env LORE_KNOWLEDGE_DIR="$DECOY" bash "$SCRIPTS/arc-close.sh" --kdir "$KDIR" arc-two --json
assert_json "arc close" "$HUMAN"
check "arc close --json: stdout is the closed record" \
  'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[\"slug\"]==\"arc-two\" and d[\"status\"]==\"closed\"" "$OUT"'

echo "spec start"
run_verb "spec start" env LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPTS/spec-start.sh" start-item
assert_human "spec start" "[spec start] start-item" "$SCOPE"
run_verb "spec start --json" env LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPTS/spec-start.sh" start-item --json
assert_json "spec start" "$SCOPE"
check "spec start --json: stdout is the start struct" \
  'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[\"schema_version\"]==1 and d[\"slug\"]==\"start-item\"" "$OUT"'
run_verb "spec start (unseen input)" env LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPTS/spec-start.sh" a-brand-new-capability --json
check "spec start on an unseen input still delivers work-scoping" 'grep -qx "Preferences for work-scoping (1):" "$ERR"'

echo "spec discover"
# spec discover reads spec start's --json output; the block on spec start's
# stderr must not reach the JSON it parses.
run_verb "spec discover" env LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPTS/spec-discover.sh" start-item --json
check "spec discover exits 0 over a store with work-scoping preferences" '[[ $RC -eq 0 ]]'
check "spec discover --json: stdout parses as one JSON value" \
  'python3 -c "import json,sys; json.loads(open(sys.argv[1]).read())" "$OUT"'
check "spec discover prints no block of its own" '! grep -q "Preferences for " "$OUT" "$ERR"'

echo "impl start"
run_verb "impl start" env LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPTS/impl-start.sh" widget-pipeline
assert_human "impl start" "[impl start] Widget Pipeline" "$ROUTE"
run_verb "impl start --json" env LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPTS/impl-start.sh" widget-pipeline --json
assert_json "impl start" "$ROUTE"
check "impl start --json: stdout is the start struct" \
  'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[\"slug\"]==\"widget-pipeline\" and d[\"plan\"][\"unchecked_tasks\"]==2" "$OUT"'
run_verb "impl start (no match)" env LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPTS/impl-start.sh" absolutely-no-such-thing-9999 --json
check "a failed impl start exits non-zero" '[[ $RC -ne 0 ]]'
check "a failed impl start prints no block" '! grep -q "Preferences for " "$OUT" "$ERR"'

echo ""
echo "=== Results ==="
echo "$PASS/$((PASS + FAIL)) passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
