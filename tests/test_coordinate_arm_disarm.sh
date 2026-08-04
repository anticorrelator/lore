#!/usr/bin/env bash
# test_coordinate_arm_disarm.sh — Acceptance for the disarm mode of the arm script.
#
# Covers `lore coordinate disarm`: the required --settings scope, the arm/disarm
# round trip through the harness hook adapter, the distinction between "removed
# an entry" and "there was nothing armed" (both exit 0), the preservation of
# unrelated Stop entries, and the help text's two obligations — that disarm
# belongs in arc closure, and that it does not end a window already running.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARM="$REPO_ROOT/scripts/coordinate-arm.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$label"; else fail "$label" "expected '$expected', got '$actual'"; fi
}
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$label"; else fail "$label" "missing '$needle'"; fi
}

TEST_DIR=$(mktemp -d)
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

new_store() {
  local kdir="$TEST_DIR/store.$RANDOM.$RANDOM"
  mkdir -p "$kdir/_coordination"
  echo "$kdir"
}

# How many Stop entries a settings file carries, and how many of them are ours.
stop_total() {
  python3 - "$1" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        settings = json.load(f)
except (OSError, ValueError):
    print(0)
    raise SystemExit(0)
print(len((settings.get("hooks") or {}).get("Stop") or []))
PYEOF
}

stop_armed() {
  python3 - "$1" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        settings = json.load(f)
except (OSError, ValueError):
    print(0)
    raise SystemExit(0)
entries = (settings.get("hooks") or {}).get("Stop") or []
print(sum(
    1 for e in entries
    if any("coordinate-arm.sh" in h.get("command", "") for h in e.get("hooks", []))
))
PYEOF
}

echo "== --settings is required and never defaulted =="
KDIR=$(new_store)
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" disarm --kdir "$KDIR" 2>&1); RC=$?
assert_eq "disarm without --settings exits 1" "1" "$RC"
assert_contains "the refusal explains the scope risk" "$OUT" "will not guess a scope"

echo "== --settings belongs to disarm, not to the arming surface =="
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --settings "$KDIR/s.json" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "--settings on the arming surface exits 1" "1" "$RC"
assert_contains "the message points at --install" "$OUT" "--install"

echo "== disarm takes no owner handle =="
# The arming surface refuses without one; disarm starts nothing, so it must not.
KDIR=$(new_store)
SETTINGS="$KDIR/settings.json"
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" disarm --settings "$SETTINGS" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "disarm with no owner handle exits 0" "0" "$RC"
assert_contains "an absent settings file is reported, not an error" "$OUT" "nothing to disarm"

echo "== arm --install then disarm is a round trip =="
KDIR=$(new_store)
SETTINGS="$KDIR/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
assert_eq "arming installed one entry" "1" "$(stop_armed "$SETTINGS")"
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" disarm --settings "$SETTINGS" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "disarm exits 0" "0" "$RC"
assert_eq "the armed entry is gone" "0" "$(stop_armed "$SETTINGS")"
assert_contains "the report says what was removed" "$OUT" "disarmed"
assert_contains "the report names the settings file" "$OUT" "$SETTINGS"
assert_contains "the report warns about the in-flight window" "$OUT" "one more wake is expected"

echo "== a second disarm is reported as nothing-to-do, not an error =="
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" disarm --settings "$SETTINGS" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "a repeat disarm exits 0" "0" "$RC"
assert_contains "a repeat disarm says there was nothing armed" "$OUT" "no armed watcher entry"

echo "== unrelated Stop entries survive =="
KDIR=$(new_store)
SETTINGS="$KDIR/settings.json"
cat > "$SETTINGS" <<'EOF'
{
  "hooks": {
    "Stop": [
      {"hooks": [{"type": "command", "command": "echo somebody-elses-hook"}]}
    ]
  }
}
EOF
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
assert_eq "both entries present after arming" "2" "$(stop_total "$SETTINGS")"
LORE_FRAMEWORK=claude-code bash "$ARM" disarm --settings "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
assert_eq "only ours was removed" "1" "$(stop_total "$SETTINGS")"
assert_eq "no armed entry remains" "0" "$(stop_armed "$SETTINGS")"
assert_contains "the foreign hook is intact" "$(cat "$SETTINGS")" "somebody-elses-hook"

echo "== --json reports the same outcome machine-readably =="
KDIR=$(new_store)
SETTINGS="$KDIR/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" disarm --settings "$SETTINGS" --json --kdir "$KDIR" 2>/dev/null)
assert_eq "json reports one entry removed" "1" "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["entries_removed"])' "$OUT")"
assert_eq "json names the settings file" "$SETTINGS" "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["settings"])' "$OUT")"
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" disarm --settings "$SETTINGS" --json --kdir "$KDIR" 2>/dev/null)
assert_eq "a no-op disarm reports zero removed" "0" "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["entries_removed"])' "$OUT")"

echo "== a harness with no turn-boundary continuation is told so, at exit 0 =="
KDIR=$(new_store)
OUT=$(LORE_FRAMEWORK=codex bash "$ARM" disarm --settings "$KDIR/settings.json" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "a degraded harness exits 0" "0" "$RC"
assert_contains "it explains no entry was ever installed" "$OUT" "no hook entry was ever installed"

echo "== the arming surface is unchanged =="
KDIR=$(new_store)
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "arming still refuses a missing owner handle" "1" "$RC"
assert_contains "the owner refusal still explains itself" "$OUT" "liveness handle"
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --window 100 --hook-timeout 50 --kdir "$KDIR" 2>&1); RC=$?
assert_eq "arming still refuses an inverted timeout pair" "1" "$RC"

echo "== the help text carries the closure rule and the in-flight caveat =="
OUT=$(bash "$ARM" --help 2>&1)
assert_contains "help places disarm in arc closure" "$OUT" "Disarm belongs in the arc-closure sequence"
assert_contains "help says a running window is not killed" "$OUT" "does not stop a window that is already running"
assert_contains "help names the lock the window holds" "$OUT" "per-scope lock"
assert_contains "help says --settings is never defaulted" "$OUT" "never defaulted"
assert_contains "help documents the disarm exit code" "$OUT" "(disarm) the entry was removed"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
