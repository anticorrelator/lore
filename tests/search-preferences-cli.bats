#!/usr/bin/env bats
# search-preferences-cli.bats — `lore search --preferences --activity` and
# `--activities` through cli/lore on a fixture store.
#
# Coverage:
#   - --activity lists every live entry under the name in full (title line,
#     body, store-relative path), in filename order, ending with the count;
#     no query positional is needed, and both spellings of the flag parse.
#   - a repeated --activity, or a comma list, lists each name in turn.
#   - --activities prints `<name> (<count>)` per line, untagged included.
#   - --json parses for both, and a query search keeps its flat list.
#   - an unknown name exits non-zero with the known names on stderr.
#   - the flags are refused without --preferences and with a query.
#
# Style: pure bats; every test owns its store through LORE_KNOWLEDGE_DIR.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
LORE="$REPO_DIR/cli/lore"

write_pref() {
  local slug="$1" title="$2" body="$3" activity="$4" status="${5:-current}"
  local meta="<!-- learned: 2026-10-01 | confidence: high | scale: subsystem | kind: fact"
  [ -n "$activity" ] && meta="$meta | activity: $activity"
  printf '# %s\n%s\n%s | status: %s -->\n' "$title" "$body" "$meta" "$status" \
    > "$TEST_STORE/preferences/$slug.md"
}

setup() {
  TEST_ROOT="$(mktemp -d)"
  TEST_STORE="$TEST_ROOT/store"
  mkdir -p "$TEST_STORE/preferences" "$TEST_STORE/_work"
  printf '{}\n' > "$TEST_STORE/_manifest.json"
  printf '# preferences/\nCoordination and model routing live here.\n' > "$TEST_STORE/preferences/README.md"
  write_pref b-wake-loop "Idle wake turns read as dormancy" \
    "Never end an idle turn with an action word." coordination
  write_pref a-cost "Arcs price themselves before they run" \
    "Coordinators surface projected spend at arc open." "coordination, model-routing"
  write_pref c-routing "Every role routes to one model" "Routing is uniform for now." model-routing
  write_pref d-legacy "An entry filed before activities" "Still live, no activity." ""
  write_pref e-retired "A retired coordination rule" "Not in force." coordination retired
}

teardown() {
  rm -rf "$TEST_ROOT"
}

run_search() {
  run env LORE_KNOWLEDGE_DIR="$TEST_STORE" bash "$LORE" search "$@"
}

@test "--activity lists every live entry in full, in filename order, ending with the count" {
  run_search --preferences --activity coordination
  [ "$status" -eq 0 ]
  expected="# Arcs price themselves before they run
Coordinators surface projected spend at arc open.
path: preferences/a-cost.md

# Idle wake turns read as dormancy
Never end an idle turn with an action word.
path: preferences/b-wake-loop.md

Preferences for coordination: 2 entries."
  [ "$output" = "$expected" ]
}

@test "--activity=<name> and a folded name list the same entries" {
  run_search --preferences --activity=model-routing
  [ "$status" -eq 0 ]
  first="$output"
  run_search --preferences --activity "Model Routing"
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
  [[ "$output" == *"path: preferences/a-cost.md"* ]]
  [[ "$output" == *"path: preferences/c-routing.md"* ]]
  [[ "$output" == *"Preferences for model-routing: 2 entries." ]]
}

@test "--activity general with no entries says none filed" {
  run_search --preferences --activity general
  [ "$status" -eq 0 ]
  [ "$output" = "Preferences for general: none filed." ]
}

@test "a repeated --activity lists each named activity in turn, the same as a comma list" {
  run_search --preferences --activity model-routing --activity general
  [ "$status" -eq 0 ]
  expected="# Arcs price themselves before they run
Coordinators surface projected spend at arc open.
path: preferences/a-cost.md

# Every role routes to one model
Routing is uniform for now.
path: preferences/c-routing.md

Preferences for model-routing: 2 entries.

Preferences for general: none filed."
  [ "$output" = "$expected" ]
  run_search --preferences --activity "model-routing, general"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
  run_search --preferences --activity model-routing --activity general --activity Model-Routing
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "an unknown name among several prints nothing on stdout and exits non-zero" {
  run env LORE_KNOWLEDGE_DIR="$TEST_STORE" bash -c '"$0" search --preferences --activity coordination --activity nope 2>/dev/null' "$LORE"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "several activities under --json parse as a list of the per-activity objects" {
  run env LORE_KNOWLEDGE_DIR="$TEST_STORE" bash "$LORE" search --preferences --activity coordination --activity model-routing --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert [(o["activity"], o["count"]) for o in d] == [("coordination", 2), ("model-routing", 2)], d
'
}

@test "--activities prints the index, untagged included and retired excluded" {
  run_search --preferences --activities
  [ "$status" -eq 0 ]
  expected="coordination (2)
general (0)
model-routing (2)
untagged (1)"
  [ "$output" = "$expected" ]
}

@test "--activity --json parses as one object with the entries in full" {
  run env LORE_KNOWLEDGE_DIR="$TEST_STORE" bash "$LORE" search --preferences --activity coordination --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["activity"] == "coordination" and d["count"] == 2, d
assert [e["path"] for e in d["entries"]] == ["preferences/a-cost.md", "preferences/b-wake-loop.md"], d
first = d["entries"][0]
assert first["title"] == "Arcs price themselves before they run", first
assert first["body"] == "Coordinators surface projected spend at arc open.", first
assert first["activities"] == ["coordination", "model-routing"], first
assert first["status"] == "current", first
'
}

@test "--activities --json parses as the index" {
  run env LORE_KNOWLEDGE_DIR="$TEST_STORE" bash "$LORE" search --json --preferences --activities
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
rows = json.loads(sys.stdin.read())["activities"]
assert [(r["name"], r["count"]) for r in rows] == [
    ("coordination", 2), ("general", 0), ("model-routing", 2), ("untagged", 1)], rows
assert rows[3]["entries"] == [{"path": "preferences/d-legacy.md", "title": "An entry filed before activities"}], rows
'
}

@test "an unknown name exits non-zero and names the known activities on stderr" {
  run env LORE_KNOWLEDGE_DIR="$TEST_STORE" bash -c '"$0" search --preferences --activity commit-messages 2>&1 >/dev/null' "$LORE"
  [ "$status" -eq 1 ]
  [[ "$output" == *'no activity "commit-messages"'* ]]
  [[ "$output" == *"known: coordination, general, model-routing, untagged"* ]]

  run env LORE_KNOWLEDGE_DIR="$TEST_STORE" bash -c '"$0" search --preferences --activity commit-messages 2>/dev/null' "$LORE"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "an unknown name under --json reports the known names as JSON on stderr" {
  run env LORE_KNOWLEDGE_DIR="$TEST_STORE" bash -c '"$0" search --preferences --activity nope --json 2>&1 >/dev/null' "$LORE"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["known"] == ["coordination", "general", "model-routing", "untagged"], d
'
}

@test "the listing flags need --preferences" {
  run_search --activity coordination
  [ "$status" -eq 1 ]
  [[ "$output" == *"use them with lore search --preferences"* ]]
  run_search --activities --scale-set implementation
  [ "$status" -eq 1 ]
}

@test "the listing takes no query" {
  run_search --preferences "wake loop" --activity coordination
  [ "$status" -ne 0 ]
  [[ "$output" == *"take no query"* ]]
}

@test "--activity without a name is refused" {
  run_search --preferences --activity
  [ "$status" -eq 1 ]
  [[ "$output" == *"--activity needs an activity name"* ]]
}

@test "a query search keeps its flat list shape" {
  run env LORE_KNOWLEDGE_DIR="$TEST_STORE" bash "$LORE" search --preferences "projected spend arc open coordinators" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
results = json.loads(sys.stdin.read())
assert isinstance(results, list), results
'
}

@test "search --help lists the listing forms" {
  run bash "$LORE" search --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"lore search --preferences --activity <name>"* ]]
  [[ "$output" == *"lore search --preferences --activities"* ]]
}
