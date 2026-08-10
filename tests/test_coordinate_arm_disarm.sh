#!/usr/bin/env bash
# test_coordinate_arm_disarm.sh — Acceptance for the disarm mode of the arm script.
#
# Covers `lore coordinate disarm`: the required --settings scope, the arm/disarm
# round trip through the harness hook adapter, the distinction between "removed
# an entry" and "there was nothing armed" (both exit 0), the preservation of
# unrelated Stop entries, and the help text's two obligations — that disarm
# belongs in arc closure, and that it does not end a window already running.
#
# Covers, too, the record that makes closure able to act on any of that: what
# `--install` writes into `_coordination/armed-watchers.json`, that disarm never
# leaves a record behind its hook entry, and what `lore arc close` does with a
# record it can attribute solely to the closing arc versus one it cannot. The
# through-line of the close cases is that none of them can fail a close.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARM="$REPO_ROOT/scripts/coordinate-arm.sh"
ARC_OPEN="$REPO_ROOT/scripts/arc-open.sh"
ARC_CLOSE="$REPO_ROOT/scripts/arc-close.sh"

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

# A store with one open arc in it, for the closure cases. --no-watcher because
# opening now arms the standing eye into the harness settings file, and every
# case below arms its own watcher at a path it controls; an arc open that also
# armed would write to the real settings file of whoever runs this suite.
new_arc_store() {
  local slug="$1" kdir
  kdir="$(new_store)"
  mkdir -p "$kdir/_work"
  bash "$ARC_OPEN" --kdir "$kdir" --no-watcher --title "$slug" --anchor "acceptance fixture" >/dev/null 2>&1
  echo "$kdir"
}

# The record keys on the absolute, symlink-resolved settings path, the same way
# both surfaces compute it — so the test resolves it too rather than assuming
# the string it passed in comes back unchanged.
record_key() {
  python3 - "$1" <<'PYEOF'
import os, sys
print(os.path.realpath(os.path.expanduser(sys.argv[1])))
PYEOF
}

# 1 when the record file holds an entry for this settings path, 0 otherwise —
# including when there is no record file at all.
record_has() {
  python3 - "$1/_coordination/armed-watchers.json" "$(record_key "$2")" <<'PYEOF'
import json, os, sys
path, key = sys.argv[1], sys.argv[2]
if not os.path.exists(path):
    print(0)
    raise SystemExit(0)
try:
    with open(path, encoding="utf-8") as f:
        records = json.load(f)
except (OSError, ValueError):
    print(0)
    raise SystemExit(0)
print(1 if key in records else 0)
PYEOF
}

# One field out of a record, addressed as a python expression over `rec`.
record_field() {
  python3 - "$1/_coordination/armed-watchers.json" "$(record_key "$2")" "$3" <<'PYEOF'
import json, sys
path, key, expr = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as f:
    rec = json.load(f)[key]
print(eval(expr))  # noqa: S307 - test-local field accessor
PYEOF
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

# The armed entry's command line, verbatim, out of a settings file. The install
# read-back matches on exactly this string, so the tests compare it to the
# command --render prints rather than to a substring of it.
installed_command() {
  python3 - "$1" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        settings = json.load(f)
except (OSError, ValueError):
    raise SystemExit(0)
for entry in (settings.get("hooks") or {}).get("Stop") or []:
    for hook in entry.get("hooks") or []:
        if "coordinate-arm.sh" in hook.get("command", ""):
            print(hook["command"])
            raise SystemExit(0)
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

echo "== a bare arm refuses rather than printing something that reads as armed =="
# The defect this covers: `lore coordinate arm` without --install printed the
# watcher command and the hook entry and exited 0, arming nothing. Two seats read
# that as an armed eye and went blind — one of them for over an hour, with its
# worker finished and parked the whole time.
KDIR=$(new_store)
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc alpha-arc --kdir "$KDIR" 2>&1); RC=$?
assert_eq "a bare arm exits 1" "1" "$RC"
assert_contains "the refusal says nothing was armed" "$OUT" "nothing was armed"
assert_contains "it names the mode that arms" "$OUT" "--install <settings.json>"
assert_contains "it names the mode that only prints" "$OUT" "--render"
if [[ "$OUT" != *"Stop hook entry:"* ]]; then
  pass "the refusal does not print an entry that could be mistaken for an armed one"
else
  fail "the refusal does not print an entry that could be mistaken for an armed one" "printed the hook entry anyway"
fi
assert_eq "a bare arm writes no record" "0" "$([[ -f "$KDIR/_coordination/armed-watchers.json" ]] && echo 1 || echo 0)"

echo "== --render keeps print-only available, and says what it did not do =="
KDIR=$(new_store)
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc alpha-arc --render --kdir "$KDIR" 2>&1); RC=$?
assert_eq "--render exits 0" "0" "$RC"
assert_contains "it still prints the hook entry" "$OUT" "Stop hook entry:"
assert_contains "it still prints the watcher command" "$OUT" "coordinate-arm.sh run --owner-pid 1"
assert_contains "the scope asked for is on the printed command" "$OUT" "--arc alpha-arc"
assert_contains "it states that nothing is armed" "$OUT" "NOTHING IS ARMED"
assert_contains "it names the way to actually arm" "$OUT" "--install <settings.json>"
assert_contains "it says a rendered entry leaves no record" "$OUT" "removing it by hand"
assert_eq "--render writes no record" "0" "$([[ -f "$KDIR/_coordination/armed-watchers.json" ]] && echo 1 || echo 0)"

echo "== --install and --render are not combinable =="
KDIR=$(new_store)
SETTINGS="$KDIR/settings.json"
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --install "$SETTINGS" --render --kdir "$KDIR" 2>&1); RC=$?
assert_eq "passing both exits 1" "1" "$RC"
assert_contains "the refusal contrasts the two" "$OUT" "deliberately writes nothing"
assert_eq "and nothing was written" "0" "$([[ -f "$SETTINGS" ]] && echo 1 || echo 0)"

echo "== --json says which of the two happened =="
KDIR=$(new_store)
SETTINGS="$KDIR/settings.json"
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --render --json --kdir "$KDIR" 2>/dev/null)
assert_eq "render reports armed: false" "False" "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["armed"])' "$OUT")"
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --install "$SETTINGS" --json --kdir "$KDIR" 2>/dev/null)
assert_eq "install reports armed: true" "True" "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["armed"])' "$OUT")"

echo "== a degraded harness refuses a bare arm too, and names --render =="
KDIR=$(new_store)
OUT=$(LORE_FRAMEWORK=codex bash "$ARM" --owner-pid 1 --arc some-arc --kdir "$KDIR" 2>&1); RC=$?
assert_eq "the bare arm exits 1" "1" "$RC"
assert_contains "it says there is no entry to install here" "$OUT" "no hook entry"
assert_contains "it carries the seat-run command" "$OUT" "coordinate-arm.sh run --owner-pid 1"
assert_contains "it names --render as the way to print it" "$OUT" "--render"
OUT=$(LORE_FRAMEWORK=codex bash "$ARM" --owner-pid 1 --arc some-arc --render --kdir "$KDIR" 2>&1); RC=$?
assert_eq "--render on a degraded harness exits 0" "0" "$RC"
assert_contains "it still says the watcher is seat-run" "$OUT" "re-arm it after each wake"

echo "== --render belongs to the arming surface only =="
KDIR=$(new_store)
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" disarm --settings "$KDIR/settings.json" --render --kdir "$KDIR" 2>&1); RC=$?
assert_eq "disarm --render exits 1" "1" "$RC"
assert_contains "the refusal says where --render belongs" "$OUT" "--render belongs to the arming surface"

echo "== an install is verified against the settings file, not the adapter's word =="
KDIR=$(new_store)
SETTINGS="$KDIR/settings.json"
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc alpha-arc --install "$SETTINGS" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "the install exits 0" "0" "$RC"
assert_contains "the report says the entry was read back" "$OUT" "read back"
# The read-back matches the command exactly, so the entry in the file and the
# command --render prints have to be the same string, not merely similar.
RENDERED=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc alpha-arc --render --kdir "$KDIR" 2>/dev/null \
  | grep -m1 '^  LORE_FRAMEWORK=' | sed 's/^  //')
assert_eq "the installed command is the rendered command, verbatim" "$RENDERED" "$(installed_command "$SETTINGS")"

echo "== a handle that dies with the command is refused, not armed =="
# The `$$` warning sat in this script's own refusal text and in its --help, and
# nothing checked it. `lore` execs straight through to this script, so a `$$` on
# the command line arrives as this process when the caller's shell is replaced
# and as its parent when it is not.
KDIR=$(new_store)
OUT=$(LORE_FRAMEWORK=claude-code bash -c 'exec bash "$1" --owner-pid $$ --kdir "$2"' \
  _ "$ARM" "$KDIR" 2>&1); RC=$?
assert_eq "arming with the verb's own pid exits 1" "1" "$RC"
assert_contains "the refusal says whose process that pid is" "$OUT" "this command's own process"
assert_contains "the refusal names the failure it prevents" "$OUT" "never re-arms"

OUT=$(LORE_FRAMEWORK=claude-code bash -c 'bash "$1" --owner-pid $$ --kdir "$2"; exit $?' \
  _ "$ARM" "$KDIR" 2>&1); RC=$?
assert_eq "arming with the invoking shell's pid exits 1" "1" "$RC"
assert_contains "the refusal names the caller's shell" "$OUT" "the shell that invoked this command"

sleep 0.1 &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null
SETTINGS="$KDIR/settings.json"
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid "$DEAD_PID" --install "$SETTINGS" \
  --kdir "$KDIR" 2>&1); RC=$?
assert_eq "arming with a dead pid exits 1" "1" "$RC"
assert_contains "the dead-handle refusal says the process is not there" "$OUT" "no such process"
assert_eq "the refused arm installed nothing" "0" "$([[ -f "$SETTINGS" ]] && echo 1 || echo 0)"
assert_eq "the refused arm recorded nothing" "0" "$(record_has "$KDIR" "$SETTINGS")"

# `run` is the other side of the same handle and must not inherit the guard: the
# harness runs the armed hook as a direct child of the process the pid names, so
# owner == parent is the correct arrangement there rather than the mistake.
KDIR=$(new_store)
OUT=$(LORE_FRAMEWORK=claude-code LORE_ARM_ERROR_BACKOFF_SECONDS=1 \
  bash -c 'bash "$1" run --owner-pid $$ --window 1 --kdir "$2"; exit $?' \
  _ "$ARM" "$KDIR" 2>&1); RC=$?
assert_eq "the watcher window still accepts its parent as the owner" "2" "$RC"

echo "== a degraded harness refuses --install with the command it wants run =="
# The refusal used to send the caller to "the printed watcher command" and then
# exit before printing one.
KDIR=$(new_store)
OUT=$(LORE_FRAMEWORK=codex bash "$ARM" --owner-pid 1 --arc some-arc \
  --install "$KDIR/settings.json" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "the refusal exits 1" "1" "$RC"
assert_contains "it carries the watcher command itself" "$OUT" "coordinate-arm.sh run --owner-pid 1"
assert_contains "the command it prints carries the scope that was asked for" "$OUT" "--arc some-arc"
assert_contains "it says nothing was written" "$OUT" "Nothing was written"
assert_eq "and nothing was" "0" "$([[ -f "$KDIR/settings.json" ]] && echo 1 || echo 0)"

echo "== the help text carries the closure rule and the in-flight caveat =="
OUT=$(bash "$ARM" --help 2>&1)
assert_contains "help places disarm in arc closure" "$OUT" "Disarm belongs in the arc-closure sequence"
assert_contains "help says a running window is not killed" "$OUT" "does not stop a window that is already running"
assert_contains "help names the lock the window holds" "$OUT" "per-scope lock"
assert_contains "help says --settings is never defaulted" "$OUT" "never defaulted"
assert_contains "help documents the disarm exit code" "$OUT" "(disarm) the entry was removed"

echo "== (a) arm --install records what it installed; a bare arm records nothing =="
KDIR=$(new_store)
SETTINGS="$KDIR/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc alpha-arc \
  --window 120 --hook-timeout 180 --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
assert_eq "the record exists after an installing arm" "1" "$(record_has "$KDIR" "$SETTINGS")"
assert_eq "the record carries the arc scope" "alpha-arc" "$(record_field "$KDIR" "$SETTINGS" 'rec["scopes"]["arcs"][0]')"
assert_eq "the record carries no slug scope" "0" "$(record_field "$KDIR" "$SETTINGS" 'len(rec["scopes"]["slugs"])')"
assert_eq "the record names the framework that installed it" "claude-code" "$(record_field "$KDIR" "$SETTINGS" 'rec["framework"]')"
assert_eq "the record carries the owner handle" "pid 1" "$(record_field "$KDIR" "$SETTINGS" 'rec["owner"]')"
assert_eq "the record carries the window it armed" "120" "$(record_field "$KDIR" "$SETTINGS" 'rec["window_seconds"]')"
assert_eq "the record carries the hook timeout" "180" "$(record_field "$KDIR" "$SETTINGS" 'rec["hook_timeout_seconds"]')"

# Whoever installs the printed entry by hand owns removing it by hand, so a
# rendering arm must leave no record claiming otherwise.
KDIR=$(new_store)
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc alpha-arc --render --kdir "$KDIR" 2>&1); RC=$?
assert_eq "--render exits 0" "0" "$RC"
assert_eq "an arm without --install writes no record" "0" "$([[ -f "$KDIR/_coordination/armed-watchers.json" ]] && echo 1 || echo 0)"

echo "== (b) disarm removes the hook entry and the record together =="
KDIR=$(new_store)
SETTINGS="$KDIR/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc alpha-arc --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
LORE_FRAMEWORK=claude-code bash "$ARM" disarm --settings "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
assert_eq "the hook entry is gone" "0" "$(stop_armed "$SETTINGS")"
assert_eq "the record is gone with it" "0" "$(record_has "$KDIR" "$SETTINGS")"

echo "== (c) arc close disarms a watcher scoped solely to the closing arc =="
KDIR=$(new_arc_store solo-arc)
SETTINGS="$KDIR/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc solo-arc --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
OUT=$(bash "$ARC_CLOSE" solo-arc --kdir "$KDIR" 2>&1); RC=$?
assert_eq "the close still exits 0" "0" "$RC"
assert_contains "the close is still recorded" "$OUT" "[arc] Closed: solo-arc"
assert_contains "the close names the watcher it switched off" "$OUT" "the only scope on the watcher"
assert_contains "the disarm surface reports what it removed" "$OUT" "disarmed: removed 1 watcher entry"
assert_eq "the hook entry is gone" "0" "$(stop_armed "$SETTINGS")"
assert_eq "the record is gone with it" "0" "$(record_has "$KDIR" "$SETTINGS")"

# The closure record is the thing that must survive all of this.
assert_eq "the arc is recorded closed" "closed" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$KDIR/_work/_arcs/solo-arc/_meta.json")"

echo "== (c2) --json close keeps a parseable contract on stdout =="
KDIR=$(new_arc_store json-arc)
SETTINGS="$KDIR/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc json-arc --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
OUT=$(bash "$ARC_CLOSE" json-arc --json --kdir "$KDIR" 2>/dev/null); RC=$?
assert_eq "the json close exits 0" "0" "$RC"
assert_eq "stdout is the arc record and nothing else" "json-arc" "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["slug"])' "$OUT" 2>/dev/null)"
assert_eq "the watcher was still disarmed" "0" "$(stop_armed "$SETTINGS")"

echo "== (d) a wider-scoped watcher is named, never switched off =="
KDIR=$(new_arc_store shared-arc)
SETTINGS="$KDIR/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc shared-arc --arc other-arc \
  --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
OUT=$(bash "$ARC_CLOSE" shared-arc --kdir "$KDIR" 2>&1); RC=$?
assert_eq "the close still exits 0" "0" "$RC"
assert_contains "the close is still recorded" "$OUT" "[arc] Closed: shared-arc"
assert_contains "the callout says the eye covers more than this arc" "$OUT" "covers 'shared-arc' and more"
assert_contains "the callout names the scope it will not judge" "$OUT" "arc:other-arc"
# The recorded path, not the one the test typed: the callout is meant to be
# pasted, so it must name the file the record actually keys on.
assert_contains "the callout names the exact command to run" "$OUT" "lore coordinate disarm --settings $(record_key "$SETTINGS")"
assert_eq "the hook entry is left armed" "1" "$(stop_armed "$SETTINGS")"
assert_eq "the record is left alone" "1" "$(record_has "$KDIR" "$SETTINGS")"

# A slug scope alongside the arc is the same call: the watcher answers to
# something this closure has no say over.
KDIR=$(new_arc_store slugged-arc)
SETTINGS="$KDIR/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc slugged-arc --slug some-item \
  --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
OUT=$(bash "$ARC_CLOSE" slugged-arc --kdir "$KDIR" 2>&1)
assert_contains "an item scope also makes the eye wider than the arc" "$OUT" "slug:some-item"
assert_eq "the hook entry is left armed" "1" "$(stop_armed "$SETTINGS")"

echo "== (e) a hook entry with no record still disarms =="
KDIR=$(new_store)
SETTINGS="$KDIR/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc alpha-arc --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
rm -f "$KDIR/_coordination/armed-watchers.json"
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" disarm --settings "$SETTINGS" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "disarm without a record exits 0" "0" "$RC"
assert_contains "disarm still reports the removal" "$OUT" "disarmed"
assert_eq "the hook entry is gone" "0" "$(stop_armed "$SETTINGS")"

echo "== (f) a record whose settings file is gone does not fail the close =="
KDIR=$(new_arc_store vanished-arc)
SETTINGS="$KDIR/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc vanished-arc --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
rm -f "$SETTINGS"
OUT=$(bash "$ARC_CLOSE" vanished-arc --kdir "$KDIR" 2>&1); RC=$?
assert_eq "the close still exits 0" "0" "$RC"
assert_contains "the close is still recorded" "$OUT" "[arc] Closed: vanished-arc"
assert_contains "the disarm reports the missing file rather than claiming a removal" "$OUT" "nothing to disarm: no settings file"
assert_eq "the stale record is cleared" "0" "$(record_has "$KDIR" "$SETTINGS")"
# The close states the attribution, which is its own to make, and leaves the
# outcome to the surface that measured it. It used to announce "— disarming it."
# on every exit-0 disarm, printed directly above "nothing to disarm".
assert_contains "the close states only that it ran disarm" "$OUT" "so this close ran disarm on it:"
if [[ "$OUT" != *"disarming it."* ]]; then
  pass "the close claims no removal the disarm did not report"
else
  fail "the close claims no removal the disarm did not report" "announced a disarm above 'nothing to disarm'"
fi

echo "== a closing arc no watcher names is silent about watchers =="
KDIR=$(new_arc_store lonely-arc)
SETTINGS="$KDIR/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc unrelated-arc --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
OUT=$(bash "$ARC_CLOSE" lonely-arc --kdir "$KDIR" 2>&1); RC=$?
assert_eq "the close exits 0" "0" "$RC"
assert_eq "another arc's eye is untouched" "1" "$(stop_armed "$SETTINGS")"
if [[ "$OUT" != *"Standing eye"* && "$OUT" != *"lore coordinate disarm"* ]]; then
  pass "an unrelated watcher draws no callout"
else
  fail "an unrelated watcher draws no callout" "close mentioned a watcher it has no claim on"
fi

echo "== an unreadable record is a warning, not a failed close =="
KDIR=$(new_arc_store corrupt-arc)
printf 'not json at all\n' > "$KDIR/_coordination/armed-watchers.json"
OUT=$(bash "$ARC_CLOSE" corrupt-arc --kdir "$KDIR" 2>&1); RC=$?
assert_eq "the close still exits 0" "0" "$RC"
assert_contains "the close is still recorded" "$OUT" "[arc] Closed: corrupt-arc"
assert_contains "the unreadable record is called out" "$OUT" "could not read"

echo "== the help text explains the record and its standing =="
OUT=$(bash "$ARM" --help 2>&1)
assert_contains "help names the record file" "$OUT" "armed-watchers.json"
assert_contains "help says the record is not the authority" "$OUT" "discovery metadata, never authority"
assert_contains "help says a bare arm records nothing" "$OUT" "Arming without"

echo "== the help text carries the arm-or-render contract =="
assert_contains "help states the two modes are a required choice" "$OUT" "Arming and rendering are separate requests"
assert_contains "help documents --render" "$OUT" "--render"
assert_contains "help says the install is read back" "$OUT" "reading the settings file back"
assert_contains "help's exit codes cover the bare arm" "$OUT" "neither --install nor --render"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
