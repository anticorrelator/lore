#!/usr/bin/env bash
# test_describe_project_flags.sh — Argument grammar for describe-project.sh.
#
# Every leading-dash argument is a flag, never a slug: --help, -h, a bare
# --json with no slug, and unknown short or long flags all exit non-zero and
# leave _work/_projects/ empty. Recognized options parse the same before or
# after the slug, and a slug with --json still writes the home and emits JSON
# on a clean stdout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESCRIBE="$REPO_ROOT/scripts/describe-project.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$label"; else fail "$label" "expected '$expected', got '$actual'"; fi
}
assert_nonzero() {
  local label="$1" rc="$2"
  if [[ "$rc" -ne 0 ]]; then pass "$label"; else fail "$label" "expected non-zero exit, got 0"; fi
}
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$label"; else fail "$label" "missing '$needle'"; fi
}
assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$label"; else fail "$label" "unexpected '$needle'"; fi
}

TEST_DIR=$(mktemp -d)
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# A fresh store per case, so "no project created" is a statement about this
# invocation alone.
new_store() {
  local kdir="$TEST_DIR/store.$RANDOM.$RANDOM"
  mkdir -p "$kdir/_work"
  echo "$kdir"
}

# Names of the project homes under a store, newline-separated, empty when none.
project_homes() {
  local kdir="$1" entry out=""
  [[ -d "$kdir/_work/_projects" ]] || return 0
  for entry in "$kdir/_work/_projects"/*; do
    [[ -e "$entry" ]] || continue
    out+="${entry##*/}"$'\n'
  done
  printf '%s' "$out"
}

STDERR_FILE="$TEST_DIR/stderr"

# Run describe against a fresh store; sets RC, OUT (stdout), ERR (stderr),
# HOMES (project homes left behind).
run_describe() {
  local kdir
  kdir=$(new_store)
  set +e
  OUT=$(LORE_KNOWLEDGE_DIR="$kdir" bash "$DESCRIBE" "$@" 2>"$STDERR_FILE")
  RC=$?
  set -e
  ERR=$(cat "$STDERR_FILE")
  HOMES=$(project_homes "$kdir")
  STORE="$kdir"
}

echo "--- 1: leading-dash arguments never become slugs -----------------------"

run_describe --help
assert_nonzero "--help exits non-zero" "$RC"
assert_eq "--help creates no project" "" "$HOMES"
assert_contains "--help prints usage on stderr" "$ERR" "lore work project describe <slug>"

run_describe -h
assert_nonzero "-h exits non-zero" "$RC"
assert_eq "-h creates no project" "" "$HOMES"
assert_contains "-h prints usage on stderr" "$ERR" "lore work project describe <slug>"

run_describe --json
assert_nonzero "bare --json exits non-zero" "$RC"
assert_eq "bare --json creates no project" "" "$HOMES"
assert_contains "bare --json reports the missing slug as JSON" "$OUT" '{"error": "Missing required argument: slug"}'

run_describe --bogus
assert_nonzero "unknown long flag exits non-zero" "$RC"
assert_eq "unknown long flag creates no project" "" "$HOMES"
assert_contains "unknown long flag names itself on stderr" "$ERR" "[work] Error: Unknown flag '--bogus'"

run_describe -x
assert_nonzero "unknown short flag exits non-zero" "$RC"
assert_eq "unknown short flag creates no project" "" "$HOMES"
assert_contains "unknown short flag names itself on stderr" "$ERR" "[work] Error: Unknown flag '-x'"

run_describe
assert_nonzero "no arguments exits non-zero" "$RC"
assert_eq "no arguments creates no project" "" "$HOMES"
assert_contains "no arguments reports the missing slug" "$ERR" "[work] Error: Missing required argument: slug"

run_describe alpha-effort extra-slug
assert_nonzero "a second positional exits non-zero" "$RC"
assert_eq "a second positional creates no project" "" "$HOMES"
assert_contains "a second positional is named on stderr" "$ERR" "[work] Error: Unexpected argument 'extra-slug'"

echo "--- 2: a slug with --json still writes the home ------------------------"

run_describe alpha-effort --anchor "Ship the alpha" --json
assert_eq "slug with --json exits zero" "0" "$RC"
assert_eq "slug with --json creates the home" "alpha-effort" "$HOMES"
assert_eq "slug with --json emits JSON with created true" "True" \
  "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["created"])')"
assert_eq "slug with --json emits JSON carrying the anchor" "Ship the alpha" \
  "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')"
assert_not_contains "slug with --json keeps stdout free of text diagnostics" "$OUT" "[work]"

echo "--- 3: recognized options parse on either side of the slug -------------"

run_describe --anchor "Ship the alpha" --status "done" alpha-effort
assert_eq "options before the slug exit zero" "0" "$RC"
assert_eq "options before the slug create the home" "alpha-effort" "$HOMES"
assert_eq "options before the slug apply the anchor" "Ship the alpha" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["anchor"])' \
     "$STORE/_work/_projects/alpha-effort/_meta.json")"
assert_eq "options before the slug apply the status" "done" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' \
     "$STORE/_work/_projects/alpha-effort/_meta.json")"

run_describe --json alpha-effort
assert_eq "--json before the slug exits zero" "0" "$RC"
assert_eq "--json before the slug emits JSON" "alpha-effort" \
  "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["slug"])')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
