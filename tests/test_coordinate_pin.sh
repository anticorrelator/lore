#!/usr/bin/env bash
# test_coordinate_pin.sh — Acceptance for the coordination pin sidecar writer.
#
# Covers the sole-writer verb `lore coordinate pin`: set/clear/read modes, the
# schema-v1 shape (pin omitted when cleared, pinned_by omit-when-empty),
# missing-home refusal, atomic writes, and derived (never stored) liveness.
# The round-trip property drives many generated inputs through the
# write -> read -> clear cycle and asserts the decoded pin equals the input.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="$REPO_ROOT/scripts/coordinate-pin.sh"

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
assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$label"; else fail "$label" "unexpected '$needle'"; fi
}

TEST_DIR=$(mktemp -d)
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# A fresh knowledge store with one project home and an empty instance registry.
new_store() {
  local kdir="$TEST_DIR/store.$RANDOM"
  mkdir -p "$kdir/_work/_projects/demo" "$kdir/_sessions/instances"
  echo "$kdir"
}

# jq-free field read from the sidecar JSON, via the same python the verb uses.
sidecar_field() {
  local file="$1" path="$2"
  python3 - "$file" "$path" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError):
    print("<unreadable>"); sys.exit(0)
node = data
for key in sys.argv[2].split("."):
    if isinstance(node, dict) and key in node:
        node = node[key]
    else:
        print("<absent>"); sys.exit(0)
print(node if not isinstance(node, (dict, list)) else json.dumps(node))
PYEOF
}

echo "== read of an unpinned project =="
KDIR=$(new_store)
OUT=$(bash "$PIN" demo --kdir "$KDIR")
assert_contains "text read reports no pin" "$OUT" "pin: (none)"
OUT=$(bash "$PIN" demo --json --kdir "$KDIR")
assert_eq "json read reports pinned false" '{"project":"demo","pinned":false}' "$OUT"

echo "== set writes schema v1 with pin =="
KDIR=$(new_store)
bash "$PIN" demo alice-tui --pinned-by carol --kdir "$KDIR" >/dev/null
SIDECAR="$KDIR/_work/_projects/demo/_coordination.json"
assert_eq "schema_version is 1" "1" "$(sidecar_field "$SIDECAR" schema_version)"
assert_eq "pin.instance recorded" "alice-tui" "$(sidecar_field "$SIDECAR" pin.instance)"
assert_eq "pin.pinned_by recorded" "carol" "$(sidecar_field "$SIDECAR" pin.pinned_by)"
assert_not_contains "no liveness stored in sidecar" "$(cat "$SIDECAR")" "live"

echo "== pinned_by omitted when empty =="
KDIR=$(new_store)
env -u LORE_SESSION_INSTANCE USER="" bash "$PIN" demo solo-tui --kdir "$KDIR" >/dev/null
SIDECAR="$KDIR/_work/_projects/demo/_coordination.json"
assert_eq "pin.instance recorded" "solo-tui" "$(sidecar_field "$SIDECAR" pin.instance)"
assert_eq "pin.pinned_by absent" "<absent>" "$(sidecar_field "$SIDECAR" pin.pinned_by)"

echo "== liveness is derived, not stored =="
KDIR=$(new_store)
bash "$PIN" demo live-tui --kdir "$KDIR" >/dev/null
# No registry row yet -> dead.
OUT=$(bash "$PIN" demo --json --kdir "$KDIR")
assert_contains "no registry row reads dead" "$OUT" '"live":false'
# A fresh registry row within the 30s TTL -> live.
echo '{"name":"live-tui"}' > "$KDIR/_sessions/instances/live-tui.json"
OUT=$(bash "$PIN" demo --json --kdir "$KDIR")
assert_contains "fresh registry row reads live" "$OUT" '"live":true'
# An aged row (mtime older than TTL) -> dead, with no rewrite of the sidecar.
touch -t 202001010000 "$KDIR/_sessions/instances/live-tui.json"
OUT=$(bash "$PIN" demo --json --kdir "$KDIR")
assert_contains "aged registry row reads dead" "$OUT" '"live":false'

echo "== clear removes the pin key, keeps schema validity =="
KDIR=$(new_store)
bash "$PIN" demo temp-tui --pinned-by carol --kdir "$KDIR" >/dev/null
bash "$PIN" demo --clear --kdir "$KDIR" >/dev/null
SIDECAR="$KDIR/_work/_projects/demo/_coordination.json"
assert_eq "schema_version survives clear" "1" "$(sidecar_field "$SIDECAR" schema_version)"
assert_eq "pin key gone after clear" "<absent>" "$(sidecar_field "$SIDECAR" pin)"
OUT=$(bash "$PIN" demo --json --kdir "$KDIR")
assert_eq "read after clear is unpinned" '{"project":"demo","pinned":false}' "$OUT"

echo "== clear on an unpinned project is a no-op =="
KDIR=$(new_store)
OUT=$(bash "$PIN" demo --clear --kdir "$KDIR")
assert_contains "no-op clear reports no pin" "$OUT" "no pin set"
[[ -f "$KDIR/_work/_projects/demo/_coordination.json" ]] && fail "no-op clear left no sidecar" "file exists" || pass "no-op clear left no sidecar"

echo "== missing home is refused, never created =="
KDIR=$(new_store)
OUT=$(bash "$PIN" ghost bob-tui --kdir "$KDIR" 2>&1); RC=$?
assert_eq "set on missing home exits non-zero" "1" "$RC"
assert_contains "refusal names the missing home" "$OUT" "has no home"
[[ -d "$KDIR/_work/_projects/ghost" ]] && fail "refusal did not create home" "dir exists" || pass "refusal did not create home"

echo "== --clear and instance are mutually exclusive =="
KDIR=$(new_store)
OUT=$(bash "$PIN" demo alice-tui --clear --kdir "$KDIR" 2>&1); RC=$?
assert_eq "conflicting args exit non-zero" "1" "$RC"
assert_contains "conflict message shown" "$OUT" "takes no <instance>"

echo "== round-trip property: decode(write(x)) == x over generated inputs =="
ROUNDTRIP_OK=1
for i in $(seq 1 40); do
  KDIR=$(new_store)
  # Generate an instance name and actor from a safe alphanumeric+dash alphabet.
  INST=$(LC_ALL=C tr -dc 'a-z0-9-' </dev/urandom 2>/dev/null | head -c $((RANDOM % 12 + 1)))
  INST="i${INST}"   # guarantee non-empty, leading alnum
  ACTOR_LEN=$((RANDOM % 10))   # 0 exercises the omit-when-empty branch
  if [[ $ACTOR_LEN -gt 0 ]]; then
    ACTOR=$(LC_ALL=C tr -dc 'a-z0-9-' </dev/urandom 2>/dev/null | head -c "$ACTOR_LEN")
  else
    ACTOR=""
  fi
  if [[ -n "$ACTOR" ]]; then
    bash "$PIN" demo "$INST" --pinned-by "$ACTOR" --kdir "$KDIR" >/dev/null
  else
    env -u LORE_SESSION_INSTANCE USER="" bash "$PIN" demo "$INST" --kdir "$KDIR" >/dev/null
  fi
  SIDECAR="$KDIR/_work/_projects/demo/_coordination.json"
  GOT_INST=$(sidecar_field "$SIDECAR" pin.instance)
  GOT_ACTOR=$(sidecar_field "$SIDECAR" pin.pinned_by)
  GOT_VER=$(sidecar_field "$SIDECAR" schema_version)
  if [[ "$GOT_INST" != "$INST" || "$GOT_VER" != "1" ]]; then
    ROUNDTRIP_OK=0; echo "    mismatch inst: wrote '$INST' read '$GOT_INST' (v=$GOT_VER)"; rm -rf "$KDIR"; break
  fi
  if [[ -n "$ACTOR" ]]; then
    [[ "$GOT_ACTOR" == "$ACTOR" ]] || { ROUNDTRIP_OK=0; echo "    mismatch actor: wrote '$ACTOR' read '$GOT_ACTOR'"; rm -rf "$KDIR"; break; }
  else
    [[ "$GOT_ACTOR" == "<absent>" ]] || { ROUNDTRIP_OK=0; echo "    empty actor persisted: '$GOT_ACTOR'"; rm -rf "$KDIR"; break; }
  fi
  # Clearing returns the store to the unpinned form.
  bash "$PIN" demo --clear --kdir "$KDIR" >/dev/null
  [[ "$(sidecar_field "$SIDECAR" pin)" == "<absent>" ]] || { ROUNDTRIP_OK=0; echo "    pin survived clear"; rm -rf "$KDIR"; break; }
  rm -rf "$KDIR"
done
if [[ $ROUNDTRIP_OK -eq 1 ]]; then pass "round-trip holds across generated inputs"; else fail "round-trip property"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
