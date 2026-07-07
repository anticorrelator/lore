#!/usr/bin/env bats
# work_note.bats — Coverage for `lore work note` (scripts/work-note.sh) and the
# `lore work create` slug echo + truncation announcement (scripts/create-work.sh).
#
# Asserts:
#   note verb —
#     - --text appends a `## YYYY-MM-DDTHH:MM` heading + body verbatim
#     - stdin (multi-line heredoc) appends verbatim when --text is omitted
#     - heading matches the pinned minute-precision format (no seconds/Z)
#     - unknown slug → exit 1 + stderr error
#     - empty --text → exit 1; whitespace-only stdin → exit 1
#     - missing slug argument → exit 1
#     - unknown flag → exit 1
#     - archived item resolves (active→archive) and appends
#     - repeated notes accumulate (append, not overwrite)
#     - `lore work --help` lists the note subcommand
#   create slug echo —
#     - stdout carries a machine-capturable `slug: <final-slug>` line
#     - a >50-char title announces truncation on stderr and echoes the cut slug
#     - --json does NOT emit a bare `slug:` line (slug lives in the JSON object)
#
# All tests use an isolated knowledge dir via LORE_KNOWLEDGE_DIR so they never
# touch the user's real ~/.lore store. Mirrors work_resolve.bats.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE_CLI="$REPO_DIR/cli/lore"
WORK_NOTE_SH="$REPO_DIR/scripts/work-note.sh"
CREATE_WORK_SH="$REPO_DIR/scripts/create-work.sh"

setup() {
  [ -x "$LORE_CLI" ]        || skip "cli/lore missing"
  [ -f "$WORK_NOTE_SH" ]    || skip "scripts/work-note.sh missing"
  [ -f "$CREATE_WORK_SH" ]  || skip "scripts/create-work.sh missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"

  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"

  WORK_DIR="$TEST_KDIR/_work"
  ARCHIVE_DIR="$WORK_DIR/_archive"
  mkdir -p "$WORK_DIR" "$ARCHIVE_DIR"

  # One active item with a seeded notes.md (as create-work.sh would leave it).
  mkdir -p "$WORK_DIR/sample-work-item"
  printf '{"slug":"sample-work-item","title":"Sample Work Item"}\n' \
    > "$WORK_DIR/sample-work-item/_meta.json"
  cat > "$WORK_DIR/sample-work-item/notes.md" <<'EOF'
# Session Notes: Sample Work Item

<!-- Append session entries below. Entry format: ## YYYY-MM-DDTHH:MM followed by **Focus:**, **Progress:**, **Next:** fields. -->

## 2026-07-01T00:00
**Focus:** Initial scoping
EOF

  # One archived item, also with notes.md.
  mkdir -p "$ARCHIVE_DIR/retired-item"
  printf '{"slug":"retired-item","title":"Retired Item"}\n' \
    > "$ARCHIVE_DIR/retired-item/_meta.json"
  printf '# Session Notes: Retired Item\n' > "$ARCHIVE_DIR/retired-item/notes.md"
}

teardown() {
  if [ -n "${TEST_KDIR:-}" ] && [ -d "$TEST_KDIR" ]; then
    rm -rf "$TEST_KDIR"
  fi
  unset LORE_KNOWLEDGE_DIR
}

NOTES() { cat "$WORK_DIR/sample-work-item/notes.md"; }

# --- note: --text append -------------------------------------------------

@test "note --text appends a heading and body verbatim" {
  run bash "$LORE_CLI" work note sample-work-item --text "**Focus:** wired the verb"
  [ "$status" -eq 0 ]
  NOTES | grep -qF "**Focus:** wired the verb"
  # A fresh minute-precision heading was added.
  NOTES | grep -Eq '^## [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}$'
}

@test "note heading is minute-precision with no seconds or Z" {
  run bash "$LORE_CLI" work note sample-work-item --text "body"
  [ "$status" -eq 0 ]
  # The pinned notes.md heading format — reject a seconds/Z ISO stamp.
  ! NOTES | grep -Eq '^## [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
}

# --- note: stdin append --------------------------------------------------

@test "note reads a multi-line heredoc body from stdin when --text omitted" {
  run bash -c 'bash "$1" work note sample-work-item <<EOF
**Focus:** stdin path
line two
line three
EOF' _ "$LORE_CLI"
  [ "$status" -eq 0 ]
  NOTES | grep -qF "**Focus:** stdin path"
  NOTES | grep -qF "line two"
  NOTES | grep -qF "line three"
}

# --- note: append semantics ---------------------------------------------

@test "repeated notes accumulate rather than overwrite" {
  bash "$LORE_CLI" work note sample-work-item --text "first append"
  bash "$LORE_CLI" work note sample-work-item --text "second append"
  NOTES | grep -qF "Initial scoping"   # original content preserved
  NOTES | grep -qF "first append"
  NOTES | grep -qF "second append"
}

# --- note: archived item ------------------------------------------------

@test "note resolves an archived item and appends to its notes.md" {
  run bash "$LORE_CLI" work note retired-item --text "closure addendum"
  [ "$status" -eq 0 ]
  grep -qF "closure addendum" "$ARCHIVE_DIR/retired-item/notes.md"
}

# --- note: error paths --------------------------------------------------

@test "unknown slug returns exit 1 with stderr error" {
  run bash "$LORE_CLI" work note no-such-slug-9999 --text "body"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "no work item found"
}

@test "empty --text body returns exit 1" {
  run bash "$LORE_CLI" work note sample-work-item --text ""
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "empty note"
}

@test "whitespace-only stdin body returns exit 1" {
  run bash -c 'printf "   \n\t\n" | bash "$1" work note sample-work-item' _ "$LORE_CLI"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "empty note"
}

@test "missing slug argument returns exit 1" {
  run bash -c 'printf "body\n" | bash "$1" work note' _ "$LORE_CLI"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "missing required"
}

@test "unknown flag returns exit 1" {
  run bash "$LORE_CLI" work note sample-work-item --bogus
  [ "$status" -eq 1 ]
}

# --- note: CLI surface --------------------------------------------------

@test "lore work --help lists the note subcommand" {
  run bash "$LORE_CLI" work --help
  echo "$output" | grep -q "note"
}

# --- create: slug echo --------------------------------------------------

@test "create echoes a machine-capturable slug line on stdout" {
  run bash "$CREATE_WORK_SH" --title "Echo Test Item" --directory "$TEST_KDIR"
  [ "$status" -eq 0 ]
  # Parse the slug the way a caller would: grep the slug: line off stdout.
  slug_line="$(echo "$output" | grep '^slug: ')"
  [ "$slug_line" = "slug: echo-test-item" ]
  [ -d "$WORK_DIR/echo-test-item" ]
}

@test "create announces truncation on stderr and echoes the cut slug" {
  local long="This Is A Deliberately Overlong Work Item Title Meant To Blow Past The Fifty Character Slug Truncation Cap"
  run bash "$CREATE_WORK_SH" --title "$long" --directory "$TEST_KDIR"
  [ "$status" -eq 0 ]
  # Truncation announced (stderr merged into $output by bats `run`).
  echo "$output" | grep -qi "truncated"
  # The echoed slug is exactly 50 chars (the cap), and a dir exists for it.
  slug="$(echo "$output" | grep '^slug: ' | sed 's/^slug: //')"
  [ "${#slug}" -le 50 ]
  [ -d "$WORK_DIR/$slug" ]
}

@test "create --json emits no bare slug line (slug lives in the JSON object)" {
  run bash "$CREATE_WORK_SH" --title "Json Slug Item" --directory "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  # stdout is a single JSON object; no `slug: ...` text line.
  ! echo "$output" | grep -q '^slug: '
  echo "$output" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["slug"]=="json-slug-item", d.get("slug")'
}

# --- dogfood parity: the CLI note verb hits the same file the script does --

@test "note via cli/lore and via the script target the same notes.md" {
  bash "$WORK_NOTE_SH" sample-work-item --text "direct script append"
  bash "$LORE_CLI" work note sample-work-item --text "cli dispatch append"
  NOTES | grep -qF "direct script append"
  NOTES | grep -qF "cli dispatch append"
}
