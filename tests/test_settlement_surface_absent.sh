#!/usr/bin/env bash
# test_settlement_surface_absent.sh — Pin the removal of the out-of-band
# settlement pipeline and the consumption-contradiction channel.
#
# Verification here is community-driven: the agent reading an entry corrects it
# or leaves a dated dispute for the next reader. Nothing queues entries for
# out-of-band adjudication, and nothing should reintroduce a surface that does.
#
# Every check is an absence. Deleting the suites that exercised the removed
# forms proves the forms are gone today; it says nothing about a later change
# putting one back. A test that fails the moment `lore settlement` dispatches
# again, or the moment `settlement` reappears in the settings schema, does.
#
# Falsifiers: restore any deleted script under scripts/, re-add a `settlement`
# or `consumption-contradiction` dispatch case to cli/lore, or re-declare the
# `settlement` property in adapters/settings.schema.json — each fails a check
# below by name.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LORE="$REPO_DIR/cli/lore"
SCHEMA="$REPO_DIR/adapters/settings.schema.json"
TEMPLATE="$REPO_DIR/adapters/settings.template.json"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; shift; for line in "$@"; do echo "    $line"; done; FAIL=$((FAIL + 1)); }

# A retired verb is one the dispatcher does not recognize: it must report an
# unknown command and exit non-zero, not print its own usage.
assert_verb_retired() {
  local verb="$1"
  local out status
  out=$(bash "$LORE" "$verb" --help 2>&1)
  status=$?
  if [[ $status -eq 0 ]]; then
    fail "lore $verb exits non-zero" "exit status: $status" "output: ${out%%$'\n'*}"
    return
  fi
  if ! printf '%s' "$out" | grep -qF "unknown command '$verb'"; then
    fail "lore $verb reports an unknown command" "output: ${out%%$'\n'*}"
    return
  fi
  pass "lore $verb is not a reachable subcommand"
}

assert_absent_from_help() {
  local token="$1"
  if bash "$LORE" --help 2>&1 | grep -qF -- "$token"; then
    fail "lore --help does not advertise '$token'"
  else
    pass "lore --help does not advertise '$token'"
  fi
}

assert_script_gone() {
  local rel="$1"
  if [[ -e "$REPO_DIR/$rel" ]]; then
    fail "$rel is removed" "still present at $REPO_DIR/$rel"
  else
    pass "$rel is removed"
  fi
}

echo "=== Settlement surface absence ==="
echo ""
echo "Retired command-line verbs"
assert_verb_retired settlement
assert_verb_retired consumption-contradiction
assert_verb_retired drift-sweep

echo ""
echo "Command listing"
assert_absent_from_help "settlement"
assert_absent_from_help "consumption-contradiction"
assert_absent_from_help "drift-sweep"

echo ""
echo "Removed producers and readers"
for rel in \
  scripts/settlement-processor.py \
  scripts/settlement-queue.sh \
  scripts/settlement-queue-process.sh \
  scripts/settlement-audit-executor.sh \
  scripts/settlement-record-append.sh \
  scripts/consumption-contradiction-append.sh \
  scripts/consumption-contradiction-read.sh \
  scripts/consumption-contradiction-update-status.sh \
  scripts/confirmer-sample.sh \
  scripts/drift-sweep.sh \
  scripts/drift-sweep.py; do
  assert_script_gone "$rel"
done

echo ""
echo "No surviving script invokes a removed one"
# Comments may still mention a removed script by name; an invocation is what
# breaks. Match the call shapes: "$SCRIPT_DIR/x.sh", "$SCRIPTS_DIR/x.sh",
# "scripts/x.sh". This file names every removed script by design, so it is
# excluded from its own scan.
#
# Reach: shell-style invocations only. A path assembled at runtime — Python's
# os.path.join(SCRIPTS_DIR, "x.sh"), say — is not matched here.
REMOVED_RE='(settlement-processor\.py|settlement-queue\.sh|settlement-queue-process\.sh|settlement-audit-executor\.sh|settlement-record-append\.sh|consumption-contradiction-(append|read|update-status)\.sh|confirmer-sample\.sh|drift-sweep\.(sh|py))'
INVOCATIONS=$(grep -rInE "(bash |python3 |exec |\| *)?[\"']?(\\\$SCRIPTS?_DIR/|\\\$REPO_SCRIPTS/|scripts/)$REMOVED_RE" \
  "$REPO_DIR/scripts" "$REPO_DIR/cli" "$REPO_DIR/githooks" "$REPO_DIR/tests" 2>/dev/null \
  | grep -vE ':[0-9]+: *#' \
  | grep -v "$(basename "${BASH_SOURCE[0]}")" || true)
if [[ -n "$INVOCATIONS" ]]; then
  fail "no surviving file invokes a removed script" "$INVOCATIONS"
else
  pass "no surviving file invokes a removed script"
fi

echo ""
echo "Settings surface"
if SCHEMA="$SCHEMA" TEMPLATE="$TEMPLATE" python3 - <<'PYEOF'
import json, os, sys
with open(os.environ["SCHEMA"]) as fh:
    schema = json.load(fh)
with open(os.environ["TEMPLATE"]) as fh:
    template = json.load(fh)
errs = []
if "settlement" in schema.get("properties", {}):
    errs.append("schema declares a settlement property")
if "settlement_config" in schema.get("$defs", {}):
    errs.append("schema defines settlement_config")
if "settlement" in template:
    errs.append("template ships a settlement block")
if "max_concurrency" not in schema["$defs"]["coordination_config"]["properties"]:
    errs.append("coordination.max_concurrency is not declared — the seat ceiling has nowhere to live")
if template.get("coordination", {}).get("max_concurrency") is None:
    errs.append("template ships no coordination ceiling")
for e in errs:
    print(e, file=sys.stderr)
sys.exit(1 if errs else 0)
PYEOF
then
  pass "settlement is absent from the schema and template, and the coordination ceiling is declared"
else
  fail "settlement is absent from the schema and template, and the coordination ceiling is declared"
fi

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]]
