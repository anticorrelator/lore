#!/usr/bin/env bats
# arc-verbs.bats — Shell-level tests for the `lore arc` verb family and the arc
# record at _work/_arcs/<slug>/_meta.json.
#
# Coverage:
#   - open: slug derivation, ledger instantiation, integer schema_version,
#     omitted project, collision and truncation refusals, --slug override.
#   - close / archive: the lifecycle table, idempotence in both, and the
#     transitions outside the table.
#   - member add|rm: set semantics, idempotence both directions, archive-aware
#     resolution, unresolvable slug refused.
#   - set: field updates and every flag-exclusivity refusal.
#   - list: default sections, filter composition, sort order, the normative JSON
#     row shape, member counts scoped to live work, malformed record omitted.
#   - list / show: proven side-effect-free by filesystem snapshot.
#   - the writer: field mutability, creation-only import, atomic write.
#   - search: arc hits reachable from `lore work search`, carrying a kind.
#   - dispatcher: usage, verb list, unknown verb, top-level registration.
#
# Style: pure bats with an isolated $TEST_KDIR per test (session-verbs.bats).

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
LORE="$REPO_DIR/cli/lore"
OPEN="$REPO_DIR/scripts/arc-open.sh"
CLOSE="$REPO_DIR/scripts/arc-close.sh"
ARCHIVE="$REPO_DIR/scripts/arc-archive.sh"
LIST="$REPO_DIR/scripts/arc-list.sh"
SHOW="$REPO_DIR/scripts/arc-show.sh"
SET="$REPO_DIR/scripts/arc-set.sh"
MEMBER="$REPO_DIR/scripts/arc-member.sh"
WRITE="$REPO_DIR/scripts/arc-write-meta.sh"
SEARCH="$REPO_DIR/scripts/search-work.sh"

setup() {
  [ -f "$OPEN" ] || skip "arc-open.sh missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  TEST_KDIR="$(mktemp -d)"
  mkdir -p "$TEST_KDIR/_work"
}

teardown() {
  if [ -n "${TEST_KDIR:-}" ] && [ -d "$TEST_KDIR" ]; then
    chmod -R u+w "$TEST_KDIR" 2>/dev/null || true
    rm -rf "$TEST_KDIR"
  fi
}

# --- Fixtures --------------------------------------------------------------

# Arc open with the standing eye left alone. Opening arms a watcher into the
# harness settings file as its last act; every test that is about the record and
# not about the eye uses this form, so none of them reaches the real settings
# file of whoever is running the suite. The arming itself is covered at the
# bottom of this file, against a HOME the test owns.
open_arc() {
  bash "$OPEN" --kdir "$TEST_KDIR" --no-watcher "$@"
}

# Arc open with arming live, pointed at a throwaway HOME. The settings target is
# resolved from capabilities.json ($HOME/.claude/settings.json on claude-code),
# so redirecting HOME is what makes the real install path testable rather than
# mocked. The owner handle is passed explicitly: resolution walks this process's
# ancestry for the harness, and the suite must not depend on what happens to be
# running it.
open_arc_arming() {
  mkdir -p "$TEST_KDIR/home"
  HOME="$TEST_KDIR/home" LORE_FRAMEWORK="${ARM_FRAMEWORK:-claude-code}" \
    bash "$OPEN" --kdir "$TEST_KDIR" --owner-pid $$ "$@"
}

seat_settings() {
  printf '%s' "$TEST_KDIR/home/.claude/settings.json"
}

# The armed watcher command in the seat settings file, or the empty string.
armed_command() {
  python3 - "$(seat_settings)" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        settings = json.load(f)
except (OSError, ValueError):
    raise SystemExit(0)
for entry in (settings.get("hooks") or {}).get("Stop") or []:
    for hook in entry.get("hooks") or []:
        if "coordinate-arm.sh" in (hook.get("command") or ""):
            print(hook["command"])
            raise SystemExit(0)
PYEOF
}

# Create a work item directory so member resolution can find it.
make_item() {
  mkdir -p "$TEST_KDIR/_work/$1"
  printf '{"slug":"%s","title":"%s"}\n' "$1" "$1" > "$TEST_KDIR/_work/$1/_meta.json"
}

make_archived_item() {
  mkdir -p "$TEST_KDIR/_work/_archive/$1"
  printf '{"slug":"%s","title":"%s"}\n' "$1" "$1" > "$TEST_KDIR/_work/_archive/$1/_meta.json"
}

# Import a record directly, so a test can place an arc in any state with any
# timestamps without walking the lifecycle to get there.
import_arc() {
  bash "$WRITE" --kdir "$TEST_KDIR" --slug "$1" --op import "${@:2}" >/dev/null
}

meta_of() {
  cat "$TEST_KDIR/_work/_arcs/$1/_meta.json"
}

field_of() {
  meta_of "$1" | python3 -c "
import json, sys
record = json.load(sys.stdin)
value = record.get('$2', '<absent>')
print(json.dumps(value) if not isinstance(value, str) else value)
"
}

snapshot() {
  find "$TEST_KDIR" \( -type f -o -type d \) -exec ls -ld {} \; | sort
  find "$TEST_KDIR" -type f -exec shasum {} \; | sort
}

# --- open ------------------------------------------------------------------

@test "open derives the slug from the title and instantiates the ledger" {
  run open_arc --title "Coordination-centric TUI view" --anchor "Arcs are findable on their own"
  [ "$status" -eq 0 ]
  [ -d "$TEST_KDIR/_work/_arcs/coordination-centric-tui-view" ]
  [ -f "$TEST_KDIR/_work/_arcs/coordination-centric-tui-view/coordination.md" ]
  grep -q "^# Coordination Ledger — Coordination-centric TUI view$" \
    "$TEST_KDIR/_work/_arcs/coordination-centric-tui-view/coordination.md"
  grep -q "^\*\*Feature under coordination:\*\* Arcs are findable on their own$" \
    "$TEST_KDIR/_work/_arcs/coordination-centric-tui-view/coordination.md"
  # The template's other structure survives verbatim.
  grep -q "^## Step Ledger$" "$TEST_KDIR/_work/_arcs/coordination-centric-tui-view/coordination.md"
}

@test "open writes schema_version as the integer 1, not a string" {
  open_arc --title "Arc one" --anchor "one" >/dev/null
  run bash -c "cat '$TEST_KDIR/_work/_arcs/arc-one/_meta.json' | python3 -c '
import json, sys
value = json.load(sys.stdin)[\"schema_version\"]
print(type(value).__name__, value)
'"
  [ "$status" -eq 0 ]
  [ "$output" = "int 1" ]
}

@test "open omits project entirely when it is not given" {
  open_arc --title "Arc one" --anchor "one" >/dev/null
  run grep -c '"project"' "$TEST_KDIR/_work/_arcs/arc-one/_meta.json"
  [ "$status" -ne 0 ]
  run bash -c "grep -c '\"\"' '$TEST_KDIR/_work/_arcs/arc-one/_meta.json'"
  [ "$status" -ne 0 ]
}

@test "open records the project label when it is given" {
  open_arc --title "Arc one" --anchor "one" --project coordination-ergonomics >/dev/null
  run field_of arc-one project
  [ "$output" = "coordination-ergonomics" ]
}

@test "open refuses an empty project label" {
  run open_arc --title "Arc one" --anchor "one" --project ""
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "project cannot be empty"
}

@test "open refuses a slug collision and names the existing arc" {
  open_arc --title "Arc one" --anchor "one" >/dev/null
  run open_arc --title "Arc one" --anchor "again"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "arc-one"
  echo "$output" | grep -q "Arc one"
  echo "$output" | grep -q -- "--slug"
}

@test "open refuses a title the length cap would clip and points at --slug" {
  run open_arc \
    --title "An extraordinarily long coordination topic title that certainly clips" \
    --anchor "x"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "clips to"
  echo "$output" | grep -q -- "--slug"
  [ ! -d "$TEST_KDIR/_work/_arcs" ] || [ -z "$(ls -A "$TEST_KDIR/_work/_arcs")" ]
}

@test "open accepts --slug as the deliberate override" {
  run open_arc \
    --title "An extraordinarily long coordination topic title that certainly clips" \
    --anchor "x" --slug long-topic
  [ "$status" -eq 0 ]
  [ -f "$TEST_KDIR/_work/_arcs/long-topic/_meta.json" ]
}

@test "open takes no positional argument" {
  run open_arc some-slug --title "Arc one" --anchor "one"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "no positional arguments"
}

@test "open preserves the anchor verbatim" {
  open_arc --title "Arc one" --anchor "  spacing   and *markup* kept  " >/dev/null
  run field_of arc-one anchor
  [ "$output" = "  spacing   and *markup* kept  " ]
}

# --- open arms the standing eye ---------------------------------------------
#
# Arming by hand was friction nobody paid reliably, and an unarmed board is a
# coordinator who cannot see a park. The ledger is where the board starts
# mattering, so the eye goes on with it — through `lore coordinate arm` itself,
# so the install and the registry write are the same ones that verb performs.

@test "open arms the standing eye by default, scoped to the new arc" {
  run open_arc_arming --title "Arc one" --anchor "one"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "standing eye armed for 'arc-one'"

  # The hook entry the harness will actually fire, carrying this arc's scope.
  run armed_command
  [ "$status" -eq 0 ]
  [[ "$output" == *"coordinate-arm.sh run"* ]]
  [[ "$output" == *"--arc arc-one"* ]]
  [[ "$output" == *"--owner-pid $$"* ]]

  # And the registry row that lets a later `lore arc close` find it.
  run python3 -c '
import json, sys
records = json.load(open(sys.argv[1]))
assert len(records) == 1, records
rec = next(iter(records.values()))
assert rec["scopes"]["arcs"] == ["arc-one"], rec
assert rec["framework"] == "claude-code", rec
print("ok")
' "$TEST_KDIR/_coordination/armed-watchers.json"
  [ "$status" -eq 0 ]
}

@test "open leaves an eye that is already armed exactly as it is" {
  open_arc_arming --title "Arc one" --anchor "one" >/dev/null 2>&1
  FIRST="$(armed_command)"

  run open_arc_arming --title "Arc two" --anchor "two"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Opened: arc-two"
  echo "$output" | grep -q "already armed"
  echo "$output" | grep -q "arc:arc-one"
  # The second open says so and stops. Installing would have replaced the entry,
  # narrowing the eye to arc-two and dropping a scope nobody asked to drop.
  echo "$output" | grep -q "it does not name 'arc-two'"
  [ "$(armed_command)" = "$FIRST" ]

  run python3 -c '
import json, sys
records = json.load(open(sys.argv[1]))
assert len(records) == 1, records
assert next(iter(records.values()))["scopes"]["arcs"] == ["arc-one"], records
print("ok")
' "$TEST_KDIR/_coordination/armed-watchers.json"
  [ "$status" -eq 0 ]
}

@test "--no-watcher opens the arc and arms nothing" {
  mkdir -p "$TEST_KDIR/home"
  run env HOME="$TEST_KDIR/home" LORE_FRAMEWORK=claude-code \
    bash "$OPEN" --kdir "$TEST_KDIR" --no-watcher --title "Arc one" --anchor "one"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Opened: arc-one"
  echo "$output" | grep -q -- "--no-watcher"
  [ ! -f "$(seat_settings)" ]
  [ ! -f "$TEST_KDIR/_coordination/armed-watchers.json" ]
}

@test "a harness with no async hook still opens the arc and says the eye is manual" {
  # codex carries a continuation channel but runs hooks synchronously; opencode
  # has neither. Neither can host the watcher, and neither may cost the arc.
  for fw in codex opencode; do
    rm -rf "$TEST_KDIR/_work/_arcs" "$TEST_KDIR/home"
    ARM_FRAMEWORK="$fw" run open_arc_arming --title "Arc $fw" --anchor "one"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Opened: arc-$fw"
    [ -f "$TEST_KDIR/_work/_arcs/arc-$fw/_meta.json" ]
    echo "$output" | grep -q "standing eye is manual on $fw"
    echo "$output" | grep -q "lore coordinate arm --arc arc-$fw --render"
    [ ! -f "$(seat_settings)" ]
  done
}

@test "an arming that cannot proceed still opens the arc" {
  # A dead owner handle is refused by `lore coordinate arm`, which is the point
  # of routing through it. The arc is the coordinator's decision being recorded;
  # watcher hygiene does not get a veto over it.
  sleep 0.1 &
  DEAD=$!
  wait "$DEAD" 2>/dev/null || true
  mkdir -p "$TEST_KDIR/home"
  run env HOME="$TEST_KDIR/home" LORE_FRAMEWORK=claude-code \
    bash "$OPEN" --kdir "$TEST_KDIR" --owner-pid "$DEAD" --title "Arc one" --anchor "one"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Opened: arc-one"
  echo "$output" | grep -q "was not armed"
  echo "$output" | grep -q "lore coordinate arm"
  [ ! -f "$(seat_settings)" ]
}

# --- close -----------------------------------------------------------------

@test "close warns about a missing report and still succeeds" {
  open_arc --title "Arc one" --anchor "one" >/dev/null
  run bash "$CLOSE" --kdir "$TEST_KDIR" arc-one
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "without a report"
  echo "$output" | grep -q "report.md"
  run field_of arc-one status
  [ "$output" = "closed" ]
}

@test "close stays quiet about the report when one is present" {
  open_arc --title "Arc one" --anchor "one" >/dev/null
  printf '# report\n' > "$TEST_KDIR/_work/_arcs/arc-one/report.md"
  run bash "$CLOSE" --kdir "$TEST_KDIR" arc-one
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "without a report"
}

@test "close is idempotent and leaves the recorded closure time alone" {
  open_arc --title "Arc one" --anchor "one" >/dev/null
  bash "$CLOSE" --kdir "$TEST_KDIR" arc-one >/dev/null 2>&1
  FIRST="$(field_of arc-one closed_at)"
  run bash "$CLOSE" --kdir "$TEST_KDIR" arc-one
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "already closed"
  [ "$(field_of arc-one closed_at)" = "$FIRST" ]
}

@test "close refuses an archived arc" {
  import_arc arc-one --title "Arc one" --status archived
  run bash "$CLOSE" --kdir "$TEST_KDIR" arc-one
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "archived"
  [ "$(field_of arc-one status)" = "archived" ]
}

@test "close refuses an unknown slug" {
  run bash "$CLOSE" --kdir "$TEST_KDIR" no-such-arc
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "no arc named"
}

# --- archive ---------------------------------------------------------------

@test "archive from closed preserves the recorded closure time" {
  open_arc --title "Arc one" --anchor "one" >/dev/null
  bash "$CLOSE" --kdir "$TEST_KDIR" arc-one >/dev/null 2>&1
  CLOSED_AT="$(field_of arc-one closed_at)"
  run bash "$ARCHIVE" --kdir "$TEST_KDIR" arc-one
  [ "$status" -eq 0 ]
  [ "$(field_of arc-one status)" = "archived" ]
  [ "$(field_of arc-one closed_at)" = "$CLOSED_AT" ]
}

@test "archive straight from active stamps a closure time" {
  open_arc --title "Arc one" --anchor "one" >/dev/null
  run bash "$ARCHIVE" --kdir "$TEST_KDIR" arc-one
  [ "$status" -eq 0 ]
  [ "$(field_of arc-one status)" = "archived" ]
  [ "$(field_of arc-one closed_at)" != "<absent>" ]
}

@test "archive is idempotent" {
  open_arc --title "Arc one" --anchor "one" >/dev/null
  bash "$ARCHIVE" --kdir "$TEST_KDIR" arc-one >/dev/null
  BEFORE="$(meta_of arc-one)"
  run bash "$ARCHIVE" --kdir "$TEST_KDIR" arc-one
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "No change"
  [ "$(meta_of arc-one)" = "$BEFORE" ]
}

@test "archive does not move the arc directory" {
  open_arc --title "Arc one" --anchor "one" >/dev/null
  bash "$ARCHIVE" --kdir "$TEST_KDIR" arc-one >/dev/null
  [ -f "$TEST_KDIR/_work/_arcs/arc-one/_meta.json" ]
  [ ! -d "$TEST_KDIR/_work/_arcs/_archive" ]
}

# --- member ----------------------------------------------------------------

@test "member add then add again is a no-op the second time" {
  make_item alpha-item
  open_arc --title "Arc one" --anchor "one" >/dev/null
  run bash "$MEMBER" --kdir "$TEST_KDIR" add arc-one alpha-item
  [ "$status" -eq 0 ]
  BEFORE="$(meta_of arc-one)"
  run bash "$MEMBER" --kdir "$TEST_KDIR" add arc-one alpha-item
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "No change"
  [ "$(meta_of arc-one)" = "$BEFORE" ]
}

@test "member rm then rm again is a no-op the second time, with a warning" {
  make_item alpha-item
  open_arc --title "Arc one" --anchor "one" >/dev/null
  bash "$MEMBER" --kdir "$TEST_KDIR" add arc-one alpha-item >/dev/null
  run bash "$MEMBER" --kdir "$TEST_KDIR" rm arc-one alpha-item
  [ "$status" -eq 0 ]
  BEFORE="$(meta_of arc-one)"
  run bash "$MEMBER" --kdir "$TEST_KDIR" rm arc-one alpha-item
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "does not list"
  [ "$(meta_of arc-one)" = "$BEFORE" ]
}

@test "member add resolves an archived work item" {
  make_archived_item old-item
  open_arc --title "Arc one" --anchor "one" >/dev/null
  run bash "$MEMBER" --kdir "$TEST_KDIR" add arc-one old-item
  [ "$status" -eq 0 ]
  meta_of arc-one | grep -q "old-item"
}

@test "member add refuses a slug that resolves to no work item" {
  open_arc --title "Arc one" --anchor "one" >/dev/null
  run bash "$MEMBER" --kdir "$TEST_KDIR" add arc-one ghost-item
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "ghost-item"
  ! meta_of arc-one | grep -q "ghost-item"
}

@test "member refuses an action that is neither add nor rm" {
  make_item alpha-item
  open_arc --title "Arc one" --anchor "one" >/dev/null
  run bash "$MEMBER" --kdir "$TEST_KDIR" toggle arc-one alpha-item
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "add or rm"
}

# --- set -------------------------------------------------------------------

@test "set updates title, anchor, and project" {
  open_arc --title "Arc one" --anchor "one" >/dev/null
  run bash "$SET" --kdir "$TEST_KDIR" arc-one --title "Arc one, renamed" --anchor "two" --project proj-a
  [ "$status" -eq 0 ]
  [ "$(field_of arc-one title)" = "Arc one, renamed" ]
  [ "$(field_of arc-one anchor)" = "two" ]
  [ "$(field_of arc-one project)" = "proj-a" ]
  # The slug is not derived again from the new title.
  [ "$(field_of arc-one slug)" = "arc-one" ]
}

@test "set --clear-project removes the key rather than emptying it" {
  open_arc --title "Arc one" --anchor "one" --project proj-a >/dev/null
  run bash "$SET" --kdir "$TEST_KDIR" arc-one --clear-project
  [ "$status" -eq 0 ]
  ! meta_of arc-one | grep -q '"project"'
}

@test "set refuses when no field flag is given" {
  open_arc --title "Arc one" --anchor "one" >/dev/null
  run bash "$SET" --kdir "$TEST_KDIR" arc-one
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "nothing to set"
}

@test "set refuses an empty project value" {
  open_arc --title "Arc one" --anchor "one" >/dev/null
  run bash "$SET" --kdir "$TEST_KDIR" arc-one --project ""
  [ "$status" -ne 0 ]
  echo "$output" | grep -q -- "--clear-project"
}

@test "set refuses --project together with --clear-project" {
  open_arc --title "Arc one" --anchor "one" >/dev/null
  run bash "$SET" --kdir "$TEST_KDIR" arc-one --project proj-a --clear-project
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "mutually exclusive"
}

@test "set leaves omitted fields untouched" {
  open_arc --title "Arc one" --anchor "one" --project proj-a >/dev/null
  bash "$SET" --kdir "$TEST_KDIR" arc-one --title "Renamed" >/dev/null
  [ "$(field_of arc-one anchor)" = "one" ]
  [ "$(field_of arc-one project)" = "proj-a" ]
}

# --- list ------------------------------------------------------------------

@test "list defaults to active and closed, hiding archived" {
  import_arc a-active --title "A" --status active --opened 2026-01-03T00:00:00Z
  import_arc b-closed --title "B" --status closed --opened 2026-01-02T00:00:00Z
  import_arc c-archived --title "C" --status archived --opened 2026-01-01T00:00:00Z
  run bash -c "bash '$LIST' --kdir '$TEST_KDIR' --json 2>/dev/null | python3 -c '
import json, sys
print(\" \".join(row[\"slug\"] for row in json.load(sys.stdin)))
'"
  [ "$status" -eq 0 ]
  [ "$output" = "a-active b-closed" ]
}

@test "list sorts by opened, newest first" {
  import_arc oldest --title "Oldest" --opened 2026-01-01T00:00:00Z
  import_arc newest --title "Newest" --opened 2026-03-01T00:00:00Z
  import_arc middle --title "Middle" --opened 2026-02-01T00:00:00Z
  run bash -c "bash '$LIST' --kdir '$TEST_KDIR' --json 2>/dev/null | python3 -c '
import json, sys
print(\" \".join(row[\"slug\"] for row in json.load(sys.stdin)))
'"
  [ "$output" = "newest middle oldest" ]
}

@test "list --status archived shows only archived arcs" {
  import_arc a-active --title "A" --status active
  import_arc c-archived --title "C" --status archived
  run bash -c "bash '$LIST' --kdir '$TEST_KDIR' --status archived --json 2>/dev/null | python3 -c '
import json, sys
print(\" \".join(row[\"slug\"] for row in json.load(sys.stdin)))
'"
  [ "$output" = "c-archived" ]
}

@test "list composes --status and --project conjunctively" {
  import_arc a1 --title "A1" --status active --project pa --opened 2026-01-02T00:00:00Z
  import_arc a2 --title "A2" --status active --project pb --opened 2026-01-01T00:00:00Z
  import_arc c1 --title "C1" --status archived --project pa
  run bash -c "bash '$LIST' --kdir '$TEST_KDIR' --status active --project pa --json 2>/dev/null | python3 -c '
import json, sys
print(\" \".join(row[\"slug\"] for row in json.load(sys.stdin)))
'"
  [ "$output" = "a1" ]
}

@test "list --project matching nothing is an empty result, not an error" {
  import_arc a1 --title "A1" --project pa
  run bash "$LIST" --kdir "$TEST_KDIR" --project no-such-project --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "list refuses an invalid --status value" {
  run bash "$LIST" --kdir "$TEST_KDIR" --status finished
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "not a status"
}

@test "list --json carries every key, with project and closed_at null when unset" {
  import_arc a-active --title "A" --status active --opened 2026-01-01T00:00:00Z
  run bash -c "bash '$LIST' --kdir '$TEST_KDIR' --json 2>/dev/null | python3 -c '
import json, sys
row = json.load(sys.stdin)[0]
expected = [\"slug\", \"title\", \"status\", \"section\", \"project\", \"member_count\", \"opened\", \"closed_at\", \"path\"]
assert sorted(row) == sorted(expected), sorted(row)
assert row[\"project\"] is None, row[\"project\"]
assert row[\"closed_at\"] is None, row[\"closed_at\"]
assert row[\"section\"] == \"active\", row[\"section\"]
assert row[\"path\"] == \"_work/_arcs/a-active\", row[\"path\"]
print(\"ok\")
'"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "list --json maps closed onto the complete section" {
  import_arc b-closed --title "B" --status closed --closed-at 2026-02-01T00:00:00Z
  run bash -c "bash '$LIST' --kdir '$TEST_KDIR' --json 2>/dev/null | python3 -c '
import json, sys
row = json.load(sys.stdin)[0]
print(row[\"section\"], row[\"closed_at\"])
'"
  [ "$output" = "complete 2026-02-01T00:00:00Z" ]
}

@test "list member_count counts live members only" {
  make_item live-one
  make_item live-two
  make_archived_item dead-one
  open_arc --title "Arc one" --anchor "one" >/dev/null
  bash "$MEMBER" --kdir "$TEST_KDIR" add arc-one live-one >/dev/null
  bash "$MEMBER" --kdir "$TEST_KDIR" add arc-one live-two >/dev/null
  bash "$MEMBER" --kdir "$TEST_KDIR" add arc-one dead-one >/dev/null
  run bash -c "bash '$LIST' --kdir '$TEST_KDIR' --json 2>/dev/null | python3 -c '
import json, sys
print(json.load(sys.stdin)[0][\"member_count\"])
'"
  [ "$output" = "2" ]
}

@test "list reports an unresolvable member rather than silently dropping it" {
  import_arc a-active --title "A" --status active
  python3 - "$TEST_KDIR/_work/_arcs/a-active/_meta.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as handle:
    record = json.load(handle)
record["members"] = ["vanished-item"]
with open(path, "w") as handle:
    json.dump(record, handle, indent=2)
    handle.write("\n")
PY
  run bash -c "bash '$LIST' --kdir '$TEST_KDIR' --json 2>&1 >/dev/null"
  echo "$output" | grep -q "vanished-item"
}

@test "list omits a malformed record, names it, and still lists the rest" {
  import_arc good-arc --title "Good" --status active
  mkdir -p "$TEST_KDIR/_work/_arcs/broken-arc"
  printf '{ not json\n' > "$TEST_KDIR/_work/_arcs/broken-arc/_meta.json"
  run bash "$LIST" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "broken-arc"
  echo "$output" | grep -q "good-arc"
  run bash -c "bash '$LIST' --kdir '$TEST_KDIR' --json 2>/dev/null | python3 -c '
import json, sys
print(\" \".join(row[\"slug\"] for row in json.load(sys.stdin)))
'"
  [ "$output" = "good-arc" ]
}

@test "list on a store with no arcs succeeds and lists nothing" {
  run bash "$LIST" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# --- show ------------------------------------------------------------------

@test "show joins the record with the arc's documents" {
  make_item alpha-item
  open_arc --title "Arc one" --anchor "one" --project proj-a >/dev/null
  bash "$MEMBER" --kdir "$TEST_KDIR" add arc-one alpha-item >/dev/null
  printf '# report\n' > "$TEST_KDIR/_work/_arcs/arc-one/report.md"
  run bash "$SHOW" --kdir "$TEST_KDIR" arc-one --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
record = json.load(sys.stdin)
assert record["documents"] == ["coordination.md", "report.md"], record["documents"]
assert record["has_report"] is True
assert record["has_ledger"] is True
assert record["members"] == ["alpha-item"], record["members"]
assert record["project"] == "proj-a"
assert record["path"] == "_work/_arcs/arc-one"
'
}

@test "show reproduces ledger rows verbatim" {
  open_arc --title "Arc one" --anchor "one" >/dev/null
  LEDGER="$TEST_KDIR/_work/_arcs/arc-one/coordination.md"
  printf '## Step Ledger\n\n| 1 | spec X | — | read-only | 2 | session | why | notify | done | full | — | abc123 |\n' > "$LEDGER"
  run bash "$SHOW" --kdir "$TEST_KDIR" arc-one
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "| 1 | spec X | — | read-only | 2 | session | why | notify | done | full | — | abc123 |"
}

@test "show refuses an unknown slug" {
  run bash "$SHOW" --kdir "$TEST_KDIR" no-such-arc
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "no arc named"
}

# --- read-only surfaces ----------------------------------------------------

@test "list and show leave the filesystem byte-identical" {
  make_item alpha-item
  open_arc --title "Arc one" --anchor "one" --project proj-a >/dev/null
  bash "$MEMBER" --kdir "$TEST_KDIR" add arc-one alpha-item >/dev/null
  import_arc b-closed --title "B" --status closed --opened 2026-01-01T00:00:00Z
  BEFORE="$(snapshot)"
  bash "$LIST" --kdir "$TEST_KDIR" >/dev/null 2>&1
  bash "$LIST" --kdir "$TEST_KDIR" --json >/dev/null 2>&1
  bash "$LIST" --kdir "$TEST_KDIR" --status archived >/dev/null 2>&1
  bash "$SHOW" --kdir "$TEST_KDIR" arc-one >/dev/null 2>&1
  bash "$SHOW" --kdir "$TEST_KDIR" arc-one --json >/dev/null 2>&1
  AFTER="$(snapshot)"
  [ "$BEFORE" = "$AFTER" ]
}

@test "list on an empty store creates no _arcs directory" {
  bash "$LIST" --kdir "$TEST_KDIR" >/dev/null 2>&1
  [ ! -e "$TEST_KDIR/_work/_arcs" ]
}

# --- the record writer -----------------------------------------------------

@test "the writer refuses --status, --opened, and --closed-at outside import" {
  open_arc --title "Arc one" --anchor "one" >/dev/null
  run bash "$WRITE" --kdir "$TEST_KDIR" --slug arc-one --op set --status archived
  [ "$status" -ne 0 ]
  echo "$output" | grep -q -- "--status is accepted only with --op import"
  run bash "$WRITE" --kdir "$TEST_KDIR" --slug arc-one --op set --opened 2020-01-01T00:00:00Z
  [ "$status" -ne 0 ]
  run bash "$WRITE" --kdir "$TEST_KDIR" --slug arc-one --op close --closed-at 2020-01-01T00:00:00Z
  [ "$status" -ne 0 ]
}

@test "the writer refuses --record-dir outside import" {
  open_arc --title "Arc one" --anchor "one" >/dev/null
  run bash "$WRITE" --kdir "$TEST_KDIR" --slug arc-one --op set --title "x" --record-dir "$TEST_KDIR/elsewhere"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q -- "--record-dir is accepted only with --op import"
}

@test "import preserves historical timestamps and is creation-only" {
  import_arc legacy --title "Legacy" --status closed \
    --opened 2026-01-01T00:00:00Z --closed-at 2026-02-01T00:00:00Z
  [ "$(field_of legacy opened)" = "2026-01-01T00:00:00Z" ]
  [ "$(field_of legacy closed_at)" = "2026-02-01T00:00:00Z" ]
  run bash "$WRITE" --kdir "$TEST_KDIR" --slug legacy --op import --title "Legacy again"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "never rewrites"
  [ "$(field_of legacy title)" = "Legacy" ]
}

@test "import writes into --record-dir when the caller stages the record elsewhere" {
  mkdir -p "$TEST_KDIR/staging"
  run bash "$WRITE" --kdir "$TEST_KDIR" --slug staged --op import --title "Staged" \
    --record-dir "$TEST_KDIR/staging"
  [ "$status" -eq 0 ]
  [ -f "$TEST_KDIR/staging/_meta.json" ]
  [ ! -e "$TEST_KDIR/_work/_arcs/staged" ]
}

@test "import refuses a status outside the three the substrate has" {
  run bash "$WRITE" --kdir "$TEST_KDIR" --slug legacy --op import --title "Legacy" --status finished
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "not a status"
  [ ! -e "$TEST_KDIR/_work/_arcs/legacy" ]
}

@test "the writer refuses an unknown operation" {
  run bash "$WRITE" --kdir "$TEST_KDIR" --slug arc-one --op reopen
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "unknown operation"
}

@test "a failed write leaves the previous record intact and no temp-file residue" {
  open_arc --title "Arc one" --anchor "one" >/dev/null
  BEFORE="$(meta_of arc-one)"
  chmod 555 "$TEST_KDIR/_work/_arcs/arc-one"
  run bash "$CLOSE" --kdir "$TEST_KDIR" arc-one
  STATUS="$status"
  chmod 755 "$TEST_KDIR/_work/_arcs/arc-one"
  [ "$STATUS" -ne 0 ]
  [ "$(meta_of arc-one)" = "$BEFORE" ]
  run bash -c "ls -A '$TEST_KDIR/_work/_arcs/arc-one' | grep -c '^\\.tmp\\.'"
  [ "$output" = "0" ]
}

@test "a no-op write does not rewrite the record file" {
  open_arc --title "Arc one" --anchor "one" >/dev/null
  bash "$ARCHIVE" --kdir "$TEST_KDIR" arc-one >/dev/null
  BEFORE="$(shasum "$TEST_KDIR/_work/_arcs/arc-one/_meta.json")"
  run bash "$ARCHIVE" --kdir "$TEST_KDIR" arc-one
  [ "$status" -eq 0 ]
  [ "$(shasum "$TEST_KDIR/_work/_arcs/arc-one/_meta.json")" = "$BEFORE" ]
}

# --- work search -----------------------------------------------------------

@test "work search reaches arc content and distinguishes it from a work item of the same slug" {
  mkdir -p "$TEST_KDIR/_work/shared-slug"
  printf '{"slug":"shared-slug","title":"Shared work item","status":"active"}\n' \
    > "$TEST_KDIR/_work/shared-slug/_meta.json"
  printf '# notes\n\nzephyrine appears here\n' > "$TEST_KDIR/_work/shared-slug/notes.md"
  import_arc shared-slug --title "Shared arc" --status active
  printf '# Coordination Ledger — Shared arc\n\n| 1 | zephyrine step | done |\n' \
    > "$TEST_KDIR/_work/_arcs/shared-slug/coordination.md"

  run bash -c "LORE_KNOWLEDGE_DIR='$TEST_KDIR' bash '$SEARCH' zephyrine --json | python3 -c '
import json, sys
rows = json.load(sys.stdin)
kinds = sorted({(row[\"kind\"], row[\"slug\"]) for row in rows})
print(kinds)
'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "('arc', 'shared-slug')"
  echo "$output" | grep -q "('work-item', 'shared-slug')"
}

@test "work search human output names arc hits as arcs" {
  import_arc findable-arc --title "Findable arc" --anchor "zephyrine anchor" --status active
  run bash -c "LORE_KNOWLEDGE_DIR='$TEST_KDIR' bash '$SEARCH' zephyrine 2>&1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Arc matches"
  echo "$output" | grep -q "\[arc\] findable-arc"
}

@test "work search reaches arcs on the grep fallback path too" {
  # The FTS backend indexes plan.md and notes.md only, so the fallback path
  # needs its own coverage: mirror scripts/ without pk_cli.py to reach it.
  FALLBACK="$(mktemp -d)"
  mkdir -p "$FALLBACK/scripts"
  for f in "$REPO_DIR"/scripts/*; do
    base="$(basename "$f")"
    [ "$base" = "pk_cli.py" ] && continue
    ln -s "$f" "$FALLBACK/scripts/$base"
  done
  import_arc findable-arc --title "Findable arc" --status active
  printf '# Coordination Ledger\n\n| 1 | zephyrine step | done |\n' \
    > "$TEST_KDIR/_work/_arcs/findable-arc/coordination.md"

  run bash -c "LORE_KNOWLEDGE_DIR='$TEST_KDIR' bash '$FALLBACK/scripts/search-work.sh' zephyrine --json | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print(\" \".join(\"%s:%s\" % (row[\"kind\"], row[\"slug\"]) for row in rows))
'"
  rm -rf "$FALLBACK"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "arc:findable-arc"
}

# --- dispatcher ------------------------------------------------------------

@test "lore arc with no args prints usage and exits non-zero" {
  run bash "$LORE" arc
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "lore arc <verb>"
}

@test "lore arc --help lists every verb" {
  run bash "$LORE" arc --help
  [ "$status" -eq 0 ]
  for verb in open close archive list show set member; do
    echo "$output" | grep -q "  $verb "
  done
}

@test "lore arc --help renders backticked verb references literally" {
  run bash "$LORE" arc --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF '`--title`'
}

@test "unknown arc verb exits non-zero with error" {
  run bash "$LORE" arc no-such-verb
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "unknown arc verb"
}

@test "unknown arc member action exits non-zero with error" {
  run bash "$LORE" arc member toggle
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "unknown arc member action"
}

@test "top-level lore usage mentions the arc subgroup" {
  run bash "$LORE" --help
  echo "$output" | grep -q "^  arc  "
}

@test "every arc verb the dispatcher names has a script behind it" {
  for verb in open close archive list show set member; do
    [ -f "$REPO_DIR/scripts/arc-$verb.sh" ]
  done
}

@test "cli/lore registers the group in all four places" {
  # The dispatcher resolves its scripts through the installed ~/.lore/scripts
  # symlink rather than from its own location, so the exec arms cannot be run
  # from a checkout that is not the installed one. Assert them by reading the
  # source; the usage tests above cover the paths that do not reach a script.
  grep -q "^arc_usage() {" "$LORE"
  grep -q "^  cat >&2 <<'EOF'$" "$LORE"
  grep -q "^cmd_arc() {" "$LORE"
  grep -q "^cmd_arc_member() {" "$LORE"
  for verb in open close archive list show set; do
    grep -qF "exec \"\$SCRIPTS_DIR/arc-$verb.sh\" \"\$@\"" "$LORE"
  done
  grep -qF 'exec "$SCRIPTS_DIR/arc-member.sh" "$@"' "$LORE"
  grep -qE '^  arc\)$' "$LORE"
  grep -qE '^    cmd_arc "\$@"$' "$LORE"
  grep -qE '^  arc +Coordination arcs' "$LORE"
}
