#!/usr/bin/env bash
# Acceptance coverage for the identity-scoped arm/disarm surface.

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

# The sandbox may deny the host process table. This suite tests the process
# contract through a deterministic authority instead of weakening assertions.
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-p 101"|"-p 202") exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE_BIN/ps"
export PATH="$FAKE_BIN:$PATH"

new_store() {
  local kdir="$TEST_DIR/store.$RANDOM.$RANDOM"
  mkdir -p "$kdir/_coordination" "$kdir/_work"
  printf '%s\n' "$kdir"
}

add_arc() {
  local kdir="$1" slug="$2"
  bash "$ARC_OPEN" --kdir "$kdir" --no-watcher --slug "$slug" \
    --title "$slug" --anchor "acceptance fixture" >/dev/null 2>&1
}

watcher_count() {
  python3 - "$1" <<'PY'
import json, sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    print(0); raise SystemExit
print(sum(
    "coordinate-arm.sh" in hook.get("command", "")
    for entry in (value.get("hooks") or {}).get("Stop") or []
    for hook in entry.get("hooks") or []
))
PY
}

watcher_commands() {
  python3 - "$1" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in (value.get("hooks") or {}).get("Stop") or []:
    for hook in entry.get("hooks") or []:
        command = hook.get("command", "")
        if "coordinate-arm.sh" in command:
            print(command)
PY
}

echo "== identity is required for disarm =="
KDIR=$(new_store)
SETTINGS="$KDIR/settings.json"
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" disarm --settings "$SETTINGS" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "unattributed disarm is refused" "1" "$RC"
assert_contains "the refusal names identity selectors" "$OUT" "attributed disarm requires"

echo "== rendered commands carry canonical normalized identity =="
add_arc "$KDIR" beta
add_arc "$KDIR" alpha
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 101 --arc beta --arc alpha --arc beta \
  --render --kdir "$KDIR" 2>&1); RC=$?
CANONICAL_KDIR=$(cd "$KDIR" && pwd -P)
assert_eq "render succeeds" "0" "$RC"
assert_contains "the canonical store is embedded" "$OUT" "--kdir $CANONICAL_KDIR"
assert_contains "the owner is embedded" "$OUT" "--owner-pid 101"
assert_contains "arcs are sorted and deduplicated" "$OUT" "--arc alpha --arc beta --window"

echo "== settings hold multiple watcher identities =="
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 101 --arc alpha \
  --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 202 --arc alpha \
  --install "$SETTINGS" --kdir "$KDIR" >/dev/null 2>&1
assert_eq "foreign identities coexist" "2" "$(watcher_count "$SETTINGS")"
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 101 --arc alpha \
  --install "$SETTINGS" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "same-identity replacement succeeds" "0" "$RC"
assert_eq "replacement does not duplicate or erase foreign entries" "2" "$(watcher_count "$SETTINGS")"
assert_contains "replacement reports its identity" "$OUT" "replaced watcher identity"

echo "== disarm removes only its attributed identity =="
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" disarm --owner-pid 101 --arc alpha \
  --settings "$SETTINGS" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "attributed disarm succeeds" "0" "$RC"
assert_eq "one foreign identity remains" "1" "$(watcher_count "$SETTINGS")"
assert_contains "the removal names its owner" "$OUT" "owner pid 101"
assert_contains "the removal names its scope" "$OUT" "scope arc:alpha"
assert_contains "the final-window contract is explicit" "$OUT" "one final wake is expected"
assert_contains "the foreign owner remains installed" "$(watcher_commands "$SETTINGS")" "--owner-pid 202"

echo "== legacy entries are reported and require an explicit sweep =="
LEGACY="$KDIR/legacy.json"
python3 - "$LEGACY" <<PY
import json, sys
json.dump({"hooks":{"Stop":[{"hooks":[{"type":"command","command":"LORE_FRAMEWORK=claude-code bash ~/.lore/scripts/coordinate-arm.sh run --owner-pid 101 --window 60"}]}]}}, open(sys.argv[1], "w"))
PY
OUT=$(LORE_FRAMEWORK=claude-code bash "$ARM" disarm --owner-pid 101 \
  --settings "$LEGACY" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "ordinary disarm leaves legacy entries" "0" "$RC"
assert_eq "legacy entry remains" "1" "$(watcher_count "$LEGACY")"
assert_contains "legacy entry is surfaced" "$OUT" "legacy watcher left"
LORE_FRAMEWORK=claude-code bash "$ARM" disarm --legacy-sweep \
  --settings "$LEGACY" --kdir "$KDIR" >/dev/null 2>&1
assert_eq "explicit legacy sweep removes it" "0" "$(watcher_count "$LEGACY")"

echo "== arc close disarms only a solely attributable identity =="
SOLE=$(new_store)
add_arc "$SOLE" solo
SOLE_SETTINGS="$SOLE/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 101 --arc solo \
  --install "$SOLE_SETTINGS" --kdir "$SOLE" >/dev/null 2>&1
OUT=$(bash "$ARC_CLOSE" solo --settings "$SOLE_SETTINGS" --kdir "$SOLE" 2>&1); RC=$?
assert_eq "close succeeds" "0" "$RC"
assert_eq "sole watcher is removed" "0" "$(watcher_count "$SOLE_SETTINGS")"
assert_contains "close names the removed identity" "$OUT" "owner pid 101"
assert_contains "close names the canonical store" "$OUT" "$SOLE"

echo "== arc close leaves a wider identity installed =="
WIDE=$(new_store)
add_arc "$WIDE" first
add_arc "$WIDE" second
WIDE_SETTINGS="$WIDE/settings.json"
LORE_FRAMEWORK=claude-code bash "$ARM" --owner-pid 101 --arc first --arc second \
  --install "$WIDE_SETTINGS" --kdir "$WIDE" >/dev/null 2>&1
OUT=$(bash "$ARC_CLOSE" first --settings "$WIDE_SETTINGS" --kdir "$WIDE" 2>&1); RC=$?
assert_eq "wide-scope close succeeds" "0" "$RC"
assert_eq "wide identity remains" "1" "$(watcher_count "$WIDE_SETTINGS")"
assert_contains "close explains why it left the identity" "$OUT" "covers 'first' and more"
assert_contains "close names both arcs" "$OUT" "scope arc:first, arc:second"

echo "== help documents the new contract =="
OUT=$(bash "$ARM" --help 2>&1)
assert_contains "help documents attributed disarm" "$OUT" "same canonical identity selectors"
assert_contains "help documents legacy sweep" "$OUT" "--legacy-sweep"
assert_contains "help preserves final-window semantics" "$OUT" "does not stop a window already running"
assert_contains "help documents identity-scoped entries" "$OUT" "same canonical store, owner, and normalized"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
