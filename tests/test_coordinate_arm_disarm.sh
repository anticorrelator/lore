#!/usr/bin/env bash
# test_coordinate_arm_disarm.sh — Acceptance for the disarm mode of the arm script.
#
# Covers `lore coordinate disarm`: the required --settings scope, the arm/disarm
# round trip through the harness hook adapter, the distinction between "removed
# an entry" and "there was nothing armed" (both exit 0), the preservation of
# unrelated Stop entries, and the help text's two obligations — that disarm
# belongs in arc closure, and that it does not end a window already running.
#
# Covers, too, how closure finds a watcher nobody remembers arming: the installed
# hook entry carries its own scope on its command line, and `lore arc close`
# reads it — disarming an eye it can attribute solely to the closing arc, naming
# one it cannot. The through-line of the close cases is that none of them can
# fail a close.
#
# And the four ways a window can end up not running for the seat that armed it:
# the arming defaults that set the cadence, the ancestry check that keeps another
# session's turn boundary out of this seat's window, the per-scope log that says
# which of those happened, and the arm-time refusals — an unresolvable scope, and
# an install that displaces somebody else's entry.

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

# An arc record in an existing store. Arming refuses a scope that resolves to no
# arc in the store it is arming from, so every case that arms for an arc opens
# that arc first. --no-watcher because opening now arms the standing eye into the
# harness settings file, and every case below arms its own watcher at a path it
# controls; an arc open that also armed would write to the real settings file of
# whoever runs this suite.
add_arc() {
  local kdir="$1" slug="$2"
  mkdir -p "$kdir/_work"
  bash "$ARC_OPEN" --kdir "$kdir" --no-watcher --slug "$slug" \
    --title "$slug" --anchor "acceptance fixture" >/dev/null 2>&1
}

# A store with one open arc in it, for the closure cases.
new_arc_store() {
  local slug="$1" kdir
  kdir="$(new_store)"
  add_arc "$kdir" "$slug"
  echo "$kdir"
}

# The record keys on the absolute, symlink-resolved settings path, the same way
# both surfaces compute it — so the test resolves it too rather than assuming
# The tokens following <flag> on the installed watcher command, space-joined.
# This is the record: the entry says what it watches.
armed_flag_values() {
  python3 - "$1" "$2" <<'PYEOF'
import json, shlex, sys
path, flag = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as f:
        settings = json.load(f)
except (OSError, ValueError):
    print("")
    raise SystemExit(0)
out = []
for entry in (settings.get("hooks") or {}).get("Stop") or []:
    for hook in entry.get("hooks") or []:
        command = hook.get("command") or ""
        if "coordinate-arm.sh" not in command:
            continue
        argv = shlex.split(command)
        out += [argv[i + 1] for i, t in enumerate(argv)
                if t == flag and i + 1 < len(argv)]
print(" ".join(out))
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

echo "== the defaults are the cadence a seat can count on =="
# Ten minutes is the floor: a window ends at least that often, and a board with
# nothing to report ends it with a quiet wake rather than with silence. The hook
# timeout stays above the window, so the harness kill remains a backstop.
KDIR=$(new_store)
SETTINGS="$KDIR/settings.json"
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --install "$SETTINGS" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "arming with no --window exits 0" "0" "$RC"
assert_eq "the armed watcher carries the ten-minute window" "600" "$(armed_flag_values "$SETTINGS" --window)"
assert_eq "and the hook entry's timeout is above it" "660" "$(python3 -c '
import json,sys
for entry in json.load(open(sys.argv[1]))["hooks"]["Stop"]:
    for hook in entry["hooks"]:
        if "coordinate-arm.sh" in hook["command"]:
            print(hook["timeout"])
' "$SETTINGS")"
assert_contains "and the report states the pair" "$OUT" "watcher window 600s inside a 660s hook timeout"

echo "== a scope that resolves to nothing is refused, not armed =="
# The installed entry carries no store path, so every window resolves the scope
# from the running session's directory — an arc missing from the store being
# armed from is an entry that errors at every window and wakes nobody.
KDIR=$(new_store)
SETTINGS="$KDIR/settings.json"
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc ghost-arc --render --kdir "$KDIR" 2>&1); RC=$?
assert_eq "rendering an unresolvable scope exits 1" "1" "$RC"
assert_contains "the refusal names the arc" "$OUT" "ghost-arc"
assert_contains "and the store it was looked for in" "$OUT" "$KDIR"
assert_eq "and nothing was installed" "0" "$([[ -f "$SETTINGS" ]] && echo 1 || echo 0)"
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc ghost-arc --install "$SETTINGS" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "installing one exits 1 too" "1" "$RC"
assert_eq "and still writes no settings file" "0" "$([[ -f "$SETTINGS" ]] && echo 1 || echo 0)"
# An arc opens before it has members, and opening one arms the eye, so an empty
# members[] is a note rather than a refusal.
KDIR=$(new_arc_store fresh-arc)
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc fresh-arc --render --kdir "$KDIR" 2>&1); RC=$?
assert_eq "an arc with no members yet still arms" "0" "$RC"
assert_contains "with a note that it scopes to nothing so far" "$OUT" "declares no members yet"

echo "== an install says whose watcher it displaced =="
# One settings file holds one watcher entry: the marker matches the script, not
# the seat, so arming into a file another seat armed switches that seat's eye off.
KDIR=$(new_arc_store first-arc)
SETTINGS="$KDIR/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc first-arc --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid $$ --install "$SETTINGS" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "the second install exits 0" "0" "$RC"
assert_contains "it reports that it replaced an entry" "$OUT" "replaced a watcher entry"
assert_contains "it names the displaced entry's owner" "$OUT" "owner pid 1"
assert_contains "it names the displaced entry's scope" "$OUT" "scope arc first-arc"
assert_eq "and the file still holds exactly one" "1" "$(stop_armed "$SETTINGS")"
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --install "$SETTINGS" --json --kdir "$KDIR" 2>/dev/null)
assert_contains "--json carries the same report" "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["displaced"])' "$OUT")" "owner pid $$"
# A file with no watcher entry displaces nothing, and says nothing about it.
KDIR=$(new_store)
SETTINGS="$KDIR/settings.json"
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --install "$SETTINGS" --kdir "$KDIR" 2>&1)
if [[ "$OUT" != *"replaced a watcher entry"* ]]; then
  pass "a first install reports no displacement"
else
  fail "a first install reports no displacement" "reported replacing something that was not there"
fi

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

echo "== --render keeps print-only available, and says what it did not do =="
KDIR=$(new_arc_store alpha-arc)
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc alpha-arc --render --kdir "$KDIR" 2>&1); RC=$?
assert_eq "--render exits 0" "0" "$RC"
assert_contains "it still prints the hook entry" "$OUT" "Stop hook entry:"
assert_contains "it still prints the watcher command" "$OUT" "coordinate-arm.sh run --owner-pid 1"
assert_contains "the scope asked for is on the printed command" "$OUT" "--arc alpha-arc"
assert_contains "it states that nothing is armed" "$OUT" "NOTHING IS ARMED"
assert_contains "it names the way to actually arm" "$OUT" "--install <settings.json>"
assert_contains "it says a rendered entry is the caller's to remove" "$OUT" "removing it by hand"

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
KDIR=$(new_arc_store some-arc)
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
KDIR=$(new_arc_store alpha-arc)
SETTINGS="$KDIR/settings.json"
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc alpha-arc --install "$SETTINGS" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "the install exits 0" "0" "$RC"
assert_contains "the report says the entry was read back" "$OUT" "read back"
# The read-back matches the command exactly, so the entry in the file and the
# command --render prints have to be the same string, not merely similar.
RENDERED=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc alpha-arc --render --kdir "$KDIR" 2>/dev/null \
  | grep -m1 '^  LORE_FRAMEWORK=' | sed 's/^  //')
assert_eq "the installed command is the rendered command, verbatim" "$RENDERED" "$(installed_command "$SETTINGS")"

echo "== a dead handle is refused, not armed =="
KDIR=$(new_store)
sleep 0.1 &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null
SETTINGS="$KDIR/settings.json"
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid "$DEAD_PID" --install "$SETTINGS" \
  --kdir "$KDIR" 2>&1); RC=$?
assert_eq "arming with a dead pid exits 1" "1" "$RC"
assert_contains "the dead-handle refusal says the process is not there" "$OUT" "no such process"
assert_eq "the refused arm installed nothing" "0" "$([[ -f "$SETTINGS" ]] && echo 1 || echo 0)"

# `run` is the other side of the same handle and must not inherit the guard: the
# harness runs the armed hook as a direct child of the process the pid names, so
# owner == parent is the correct arrangement there rather than the mistake.
KDIR=$(new_store)
OUT=$(LORE_FRAMEWORK=claude-code LORE_ARM_ERROR_BACKOFF_SECONDS=1 \
  bash -c 'bash "$1" run --owner-pid $$ --window 1 --kdir "$2"; exit $?' \
  _ "$ARM" "$KDIR" 2>&1); RC=$?
assert_eq "the watcher window still accepts its parent as the owner" "2" "$RC"
assert_contains "and the window it opened is in the log" "$(cat "$KDIR/_coordination/arm-window.log")" "disposition=opened"

echo "== the window is the armed seat's, and nobody else's =="
# The entry lives in a settings file every session on the machine reads, so every
# session's turn boundary runs it. A firing that does not descend from the seat
# the entry names is that other session's turn boundary, and it must leave the
# window alone: the seat's own firing has to find the lock free.
KDIR=$(new_store)
sleep 30 &
FOREIGN_PID=$!
OUT=$(LORE_FRAMEWORK=claude-code bash -c 'bash "$1" run --owner-pid "$2" --window 30 --kdir "$3"; exit $?' \
  _ "$ARM" "$FOREIGN_PID" "$KDIR" 2>&1); RC=$?
assert_eq "a firing for a seat this process does not descend from exits 0" "0" "$RC"
assert_eq "and delivers no wake" "" "$OUT"
LIVE_WATCHERS=$(ps -Ao command | grep -c "[c]oordinate-watch.sh.*$KDIR")
assert_eq "and forks no watcher" "0" "$LIVE_WATCHERS"
kill "$FOREIGN_PID" 2>/dev/null
wait "$FOREIGN_PID" 2>/dev/null

echo "== the window log tells a refused firing from a losing one =="
# Both exit 0 with nothing on any stream, so without this file the two are the
# same event from outside — which is what made a dead wake chain take transcript
# forensics to diagnose.
WINDOW_LOG="$KDIR/_coordination/arm-window.log"
FOREIGN_LINE=$(grep "disposition=foreign" "$WINDOW_LOG" | tail -1)
assert_contains "the refused firing names the owner it was armed for" "$FOREIGN_LINE" "owner=$FOREIGN_PID"
assert_contains "and names the process that ran it" "$FOREIGN_LINE" "pid="
assert_contains "and that process's parent" "$FOREIGN_LINE" "ppid="

# A second firing for the same scope while a window is open: the lock is the
# guard, and losing it is a different event from being refused as foreign.
python3 - "$KDIR/_coordination/arm-window.lock" <<'PYEOF' &
import fcntl, sys, time
handle = open(sys.argv[1], "w")
fcntl.flock(handle, fcntl.LOCK_EX)
time.sleep(20)
PYEOF
HOLDER_PID=$!
sleep 1
OUT=$(LORE_FRAMEWORK=claude-code bash -c 'bash "$1" run --owner-pid $$ --window 1 --kdir "$2"; exit $?' \
  _ "$ARM" "$KDIR" 2>&1); RC=$?
kill "$HOLDER_PID" 2>/dev/null
wait "$HOLDER_PID" 2>/dev/null
assert_eq "a firing that loses the per-scope lock exits 0" "0" "$RC"
assert_contains "and says so in the log" "$(tail -1 "$WINDOW_LOG")" "disposition=lock-held"
assert_eq "so the two dispositions are distinguishable" "1" "$(grep -c 'disposition=lock-held' "$WINDOW_LOG")"

echo "== a degraded harness refuses --install with the command it wants run =="
# The refusal used to send the caller to "the printed watcher command" and then
# exit before printing one.
KDIR=$(new_arc_store some-arc)
OUT=$(LORE_FRAMEWORK=codex bash "$ARM" --owner-pid 1 --arc some-arc \
  --install "$KDIR/settings.json" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "the refusal exits 1" "1" "$RC"
assert_contains "it carries the watcher command itself" "$OUT" "coordinate-arm.sh run --owner-pid 1"
assert_contains "the command it prints carries the scope that was asked for" "$OUT" "--arc some-arc"
assert_contains "it says nothing was written" "$OUT" "Nothing was written"
assert_eq "and nothing was" "0" "$([[ -f "$KDIR/settings.json" ]] && echo 1 || echo 0)"

echo "== the help text carries the closure rule and the in-flight caveat =="
OUT=$(bash "$ARM" --help 2>&1)
# Help is a fixed line range over the header, so a longer header silently loses
# its tail unless the range moves with it. The last line of the header is the
# canary: if it prints, nothing in between was truncated.
assert_contains "help reaches the last line of the header" "$OUT" "so neither is a refusal"
assert_contains "help explains whose firing opens a window" "$OUT" "A window runs only for the seat that armed it"
assert_contains "help names the window log and its only writer" "$OUT" "arm-window<scope>.log"
assert_contains "help says a scope is checked before it is armed" "$OUT" "A scope is checked before it is armed"
assert_contains "help places disarm in arc closure" "$OUT" "Disarm belongs in the arc-closure sequence"
assert_contains "help says a running window is not killed" "$OUT" "does not stop a window that is already running"
assert_contains "help names the lock the window holds" "$OUT" "per-scope lock"
assert_contains "help says --settings is never defaulted" "$OUT" "never defaulted"
assert_contains "help documents the disarm exit code" "$OUT" "(disarm) the entry was removed"

echo "== (a) the installed entry carries the scope a later closure reads =="
KDIR=$(new_arc_store alpha-arc)
SETTINGS="$KDIR/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc alpha-arc \
  --window 120 --hook-timeout 180 --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
assert_eq "the entry carries the arc scope" "alpha-arc" "$(armed_flag_values "$SETTINGS" --arc)"
assert_eq "the entry carries the owner handle" "1" "$(armed_flag_values "$SETTINGS" --owner-pid)"
assert_eq "the entry carries the window it armed" "120" "$(armed_flag_values "$SETTINGS" --window)"
assert_contains "the entry names the framework that installed it" "$(installed_command "$SETTINGS")" "LORE_FRAMEWORK=claude-code"

# Whoever installs the printed entry by hand owns removing it by hand: nothing is
# written anywhere, so there is no settings file for a closure to read.
KDIR=$(new_arc_store alpha-arc)
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc alpha-arc --render --kdir "$KDIR" 2>&1); RC=$?
assert_eq "--render exits 0" "0" "$RC"
assert_eq "an arm without --install writes no settings file" "0" "$([[ -f "$KDIR/settings.json" ]] && echo 1 || echo 0)"

echo "== (b) disarm removes the hook entry, which is the whole record =="
KDIR=$(new_arc_store alpha-arc)
SETTINGS="$KDIR/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc alpha-arc --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
LORE_FRAMEWORK=claude-code bash "$ARM" disarm --settings "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
assert_eq "the hook entry is gone" "0" "$(stop_armed "$SETTINGS")"
assert_eq "and with it the scope any closure could have read" "" "$(armed_flag_values "$SETTINGS" --arc)"

echo "== (c) arc close disarms a watcher scoped solely to the closing arc =="
KDIR=$(new_arc_store solo-arc)
SETTINGS="$KDIR/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc solo-arc --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
OUT=$(bash "$ARC_CLOSE" solo-arc --settings "$SETTINGS" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "the close still exits 0" "0" "$RC"
assert_contains "the close is still recorded" "$OUT" "[arc] Closed: solo-arc"
assert_contains "the close names the watcher it switched off" "$OUT" "the only scope on the watcher"
assert_contains "the disarm surface reports what it removed" "$OUT" "disarmed: removed 1 watcher entry"
assert_eq "the hook entry is gone" "0" "$(stop_armed "$SETTINGS")"

# The closure record is the thing that must survive all of this.
assert_eq "the arc is recorded closed" "closed" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$KDIR/_work/_arcs/solo-arc/_meta.json")"

echo "== (c2) --json close keeps a parseable contract on stdout =="
KDIR=$(new_arc_store json-arc)
SETTINGS="$KDIR/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc json-arc --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
OUT=$(bash "$ARC_CLOSE" json-arc --json --settings "$SETTINGS" --kdir "$KDIR" 2>/dev/null); RC=$?
assert_eq "the json close exits 0" "0" "$RC"
assert_eq "stdout is the arc record and nothing else" "json-arc" "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["slug"])' "$OUT" 2>/dev/null)"
assert_eq "the watcher was still disarmed" "0" "$(stop_armed "$SETTINGS")"

echo "== (d) a wider-scoped watcher is named, never switched off =="
KDIR=$(new_arc_store shared-arc)
add_arc "$KDIR" other-arc
SETTINGS="$KDIR/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc shared-arc --arc other-arc \
  --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
OUT=$(bash "$ARC_CLOSE" shared-arc --settings "$SETTINGS" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "the close still exits 0" "0" "$RC"
assert_contains "the close is still recorded" "$OUT" "[arc] Closed: shared-arc"
assert_contains "the callout says the eye covers more than this arc" "$OUT" "covers 'shared-arc' and more"
assert_contains "the callout names the scope it will not judge" "$OUT" "arc:other-arc"
# The callout is meant to be pasted, so it names the settings file the close
# actually read.
assert_contains "the callout names the exact command to run" "$OUT" "lore coordinate disarm --settings $SETTINGS"
assert_eq "the hook entry is left armed" "1" "$(stop_armed "$SETTINGS")"
assert_eq "the scope it will not judge is still on the entry" "shared-arc other-arc" "$(armed_flag_values "$SETTINGS" --arc)"

echo "== (e) an entry installed by hand still disarms, and a close still reads it =="
KDIR=$(new_arc_store handmade-arc)
SETTINGS="$KDIR/settings.json"
# No arm ran here at all: the entry was pasted in, which is exactly the case the
# retired registry could not see.
python3 - "$SETTINGS" "$REPO_ROOT/scripts/coordinate-arm.sh" <<'PYEOF'
import json, sys
settings_path, arm_path = sys.argv[1], sys.argv[2]
command = "LORE_FRAMEWORK=claude-code bash %s run --owner-pid 1 --arc handmade-arc --window 120" % arm_path
json.dump({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": command, "timeout": 180}]}]}},
          open(settings_path, "w"))
PYEOF
OUT=$(bash "$ARC_CLOSE" handmade-arc --settings "$SETTINGS" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "the close still exits 0" "0" "$RC"
assert_contains "the close finds the hand-installed eye" "$OUT" "the only scope on the watcher"
assert_eq "and disarms it" "0" "$(stop_armed "$SETTINGS")"

echo "== (f) a settings file that is gone does not fail the close =="
KDIR=$(new_arc_store vanished-arc)
SETTINGS="$KDIR/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc vanished-arc --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
rm -f "$SETTINGS"
OUT=$(bash "$ARC_CLOSE" vanished-arc --settings "$SETTINGS" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "the close still exits 0" "0" "$RC"
assert_contains "the close is still recorded" "$OUT" "[arc] Closed: vanished-arc"
if [[ "$OUT" != *"Standing eye"* ]]; then
  pass "a settings file that is gone carries no eye to call out"
else
  fail "a settings file that is gone carries no eye to call out" "close named a watcher it could not read"
fi

echo "== a closing arc no watcher names is silent about watchers =="
KDIR=$(new_arc_store lonely-arc)
add_arc "$KDIR" unrelated-arc
SETTINGS="$KDIR/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 1 --arc unrelated-arc --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
OUT=$(bash "$ARC_CLOSE" lonely-arc --settings "$SETTINGS" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "the close exits 0" "0" "$RC"
assert_eq "another arc's eye is untouched" "1" "$(stop_armed "$SETTINGS")"
if [[ "$OUT" != *"Standing eye"* && "$OUT" != *"lore coordinate disarm"* ]]; then
  pass "an unrelated watcher draws no callout"
else
  fail "an unrelated watcher draws no callout" "close mentioned a watcher it has no claim on"
fi

echo "== an unreadable settings file is a warning, not a failed close =="
KDIR=$(new_arc_store corrupt-arc)
SETTINGS="$KDIR/settings.json"
printf 'not json at all\n' > "$SETTINGS"
OUT=$(bash "$ARC_CLOSE" corrupt-arc --settings "$SETTINGS" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "the close still exits 0" "0" "$RC"
assert_contains "the close is still recorded" "$OUT" "[arc] Closed: corrupt-arc"
assert_contains "the unreadable settings file is called out" "$OUT" "could not read"

echo "== the help text explains how a closure finds the watcher =="
OUT=$(bash "$ARM" --help 2>&1)
assert_contains "help says the entry carries its own scope" "$OUT" "carries its own scope"
assert_contains "help says nothing is mirrored elsewhere" "$OUT" "Nothing is recorded anywhere"
assert_contains "help says arc close reads the entry" "$OUT" "reads the entry"

echo "== the help text carries the arm-or-render contract =="
assert_contains "help states the two modes are a required choice" "$OUT" "Arming and rendering are separate requests"
assert_contains "help documents --render" "$OUT" "--render"
assert_contains "help says the install is read back" "$OUT" "reading the settings file back"
assert_contains "help's exit codes cover the bare arm" "$OUT" "neither --install nor --render"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
