#!/usr/bin/env bash
# test_frameworks_capabilities.sh — Bash mirror of tests/frameworks/capabilities.bats
#
# Why mirror: the canonical artifact named in the multi-framework-agent-support
# plan (Phase 1, T13) is a `.bats` file, but the existing tests/ directory uses
# `test_*.sh` bash runners and bats is not installed in CI yet. This script
# runs the same validations so coverage works without the bats toolchain;
# both files MUST stay in sync. If a check is added here, mirror it to
# tests/frameworks/capabilities.bats and vice versa.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAPS="$REPO_DIR/adapters/capabilities.json"
EVID="$REPO_DIR/adapters/capabilities-evidence.md"

PASS=0
FAIL=0

assert_ok() {
  local label="$1"
  shift
  if "$@" >/tmp/cap-test-out 2>&1; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    sed 's/^/    /' /tmp/cap-test-out
    FAIL=$((FAIL + 1))
  fi
}

# --- Setup checks ---
if [[ ! -f "$CAPS" ]]; then
  echo "SKIP: $CAPS missing"
  exit 0
fi
if [[ ! -f "$EVID" ]]; then
  echo "SKIP: $EVID missing"
  exit 0
fi

# --- Schema-shape ---

check_json_parses() {
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CAPS"
}

check_top_level_keys() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
required = ["version", "support_levels", "capabilities", "frameworks"]
missing = [k for k in required if k not in d]
if missing:
    print("missing keys:", missing); sys.exit(1)
' "$CAPS"
}

check_support_levels() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
got = set(d["support_levels"].keys())
want = {"full", "partial", "fallback", "none"}
if got != want:
    print("expected", sorted(want), "got", sorted(got)); sys.exit(1)
' "$CAPS"
}

check_frameworks_present() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
got = set(d["frameworks"].keys())
want = {"claude-code", "opencode", "codex"}
missing = want - got
if missing:
    print("missing frameworks:", sorted(missing)); sys.exit(1)
' "$CAPS"
}

# --- Per-cell schema ---

check_support_level_closed_set() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
allowed = set(d["support_levels"].keys())
bad = []
for fw_id, fw in d["frameworks"].items():
    for cap, cell in (fw.get("capabilities") or {}).items():
        s = cell.get("support")
        if s not in allowed:
            bad.append(f"{fw_id}.{cap}.support={s!r}")
if bad:
    print("invalid support levels:")
    for b in bad: print(" ", b)
    sys.exit(1)
' "$CAPS"
}

check_per_cell_capability_declared() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
declared = set(d["capabilities"].keys())
bad = []
for fw_id, fw in d["frameworks"].items():
    for cap in (fw.get("capabilities") or {}).keys():
        if cap not in declared:
            bad.append(f"{fw_id}.capabilities.{cap}")
if bad:
    print("undeclared capability keys:")
    for b in bad: print(" ", b)
    sys.exit(1)
' "$CAPS"
}

check_no_partial_profiles() {
  # model_routing lives at the framework root (sibling to capabilities)
  # rather than inside the per-framework capabilities map because its
  # shape is single|multi, not full|partial|fallback|none. Validate
  # routing separately via check_model_routing.
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
declared = set(d["capabilities"].keys()) - {"model_routing"}
bad = []
for fw_id, fw in d["frameworks"].items():
    have = set((fw.get("capabilities") or {}).keys())
    missing = declared - have
    if missing:
        bad.append((fw_id, sorted(missing)))
if bad:
    for fw_id, m in bad:
        print(f"{fw_id} missing:", m)
    sys.exit(1)
' "$CAPS"
}

check_evidence_present_for_non_none() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
bad = []
for fw_id, fw in d["frameworks"].items():
    for cap, cell in (fw.get("capabilities") or {}).items():
        if cell.get("support") == "none":
            continue
        ev = cell.get("evidence")
        if not isinstance(ev, str) or not ev.strip():
            bad.append(f"{fw_id}.{cap}")
if bad:
    print("non-none cells without evidence pointer:")
    for b in bad: print(" ", b)
    sys.exit(1)
' "$CAPS"
}

check_model_routing() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
allowed = {"single", "multi"}
bad = []
for fw_id, fw in d["frameworks"].items():
    mr = fw.get("model_routing") or {}
    shape = mr.get("shape")
    ev = mr.get("evidence")
    if shape not in allowed:
        bad.append(f"{fw_id}.model_routing.shape={shape!r}")
    if not isinstance(ev, str) or not ev.strip():
        bad.append(f"{fw_id}.model_routing.evidence missing")
if bad:
    for b in bad: print(b)
    sys.exit(1)
' "$CAPS"
}

# --- Evidence cross-reference ---

evidence_index() {
  EVID="$EVID" python3 - <<'PYEOF'
import os, re, sys
with open(os.environ["EVID"]) as f:
    text = f.read()
m = re.search(r"^## _index\s*\n(.*)$", text, re.M | re.S)
if not m: sys.exit(2)
for line in m.group(1).splitlines():
    line = line.strip()
    if line.startswith("- "):
        print(line[2:].strip())
PYEOF
}

evidence_section_ids() {
  EVID="$EVID" python3 - <<'PYEOF'
import os, re
with open(os.environ["EVID"]) as f:
    text = f.read()
body, _, _ = text.partition("## _index")
for m in re.finditer(r"^###\s+([a-z0-9-]+)\s*$", body, re.M):
    print(m.group(1))
PYEOF
}

consumed_evidence_ids() {
  CAPS="$CAPS" python3 - <<'PYEOF'
import json, os
with open(os.environ["CAPS"]) as f:
    data = json.load(f)
ids = set()
for fw_id, fw in data.get("frameworks", {}).items():
    mr = fw.get("model_routing") or {}
    if mr.get("evidence"): ids.add(mr["evidence"])
    for cap, cell in (fw.get("capabilities") or {}).items():
        if cell.get("evidence"): ids.add(cell["evidence"])
for cid in sorted(ids): print(cid)
PYEOF
}

check_consumed_resolve_in_index() {
  consumed=$(consumed_evidence_ids)
  index=$(evidence_index)
  missing=""
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    grep -Fxq "$id" <<<"$index" || missing+="${id}"$'\n'
  done <<<"$consumed"
  if [[ -n "$missing" ]]; then
    echo "evidence ids consumed but not present in capabilities-evidence.md _index:"
    echo "$missing"
    return 1
  fi
  return 0
}

check_index_has_body_sections() {
  index=$(evidence_index)
  body=$(evidence_section_ids)
  orphans=""
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    grep -Fxq "$id" <<<"$body" || orphans+="${id}"$'\n'
  done <<<"$index"
  if [[ -n "$orphans" ]]; then
    echo "ids listed in _index without ### body section:"
    echo "$orphans"
    return 1
  fi
  return 0
}

check_body_sections_in_index() {
  body=$(evidence_section_ids)
  index=$(evidence_index)
  orphans=""
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    grep -Fxq "$id" <<<"$index" || orphans+="${id}"$'\n'
  done <<<"$body"
  if [[ -n "$orphans" ]]; then
    echo "ids defined in body but missing from _index:"
    echo "$orphans"
    return 1
  fi
  return 0
}

check_no_unused_evidence() {
  consumed=$(consumed_evidence_ids)
  index=$(evidence_index)
  unused=""
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    grep -Fxq "$id" <<<"$consumed" || unused+="${id}"$'\n'
  done <<<"$index"
  if [[ -n "$unused" ]]; then
    echo "evidence ids defined but not consumed by any capability cell:"
    echo "$unused"
    return 1
  fi
  return 0
}

# --- Run all ---

echo "== Schema shape =="
assert_ok "capabilities.json parses as JSON"                          check_json_parses
assert_ok "capabilities.json has required top-level keys"             check_top_level_keys
assert_ok "support_levels is exactly {full, partial, fallback, none}" check_support_levels
assert_ok "frameworks include claude-code, opencode, codex"           check_frameworks_present

echo "== Per-cell schema =="
assert_ok "every cell uses a support level from the closed set"       check_support_level_closed_set
assert_ok "every per-cell capability key is declared globally"        check_per_cell_capability_declared
assert_ok "every framework declares all known capabilities"           check_no_partial_profiles
assert_ok "every non-none cell carries a non-empty evidence pointer"  check_evidence_present_for_non_none
assert_ok "every framework's model_routing.shape and evidence valid"  check_model_routing

echo "== Evidence cross-reference =="
assert_ok "every consumed evidence id resolves in _index"             check_consumed_resolve_in_index
assert_ok "every _index id has a matching ### body section"           check_index_has_body_sections
assert_ok "every ### body id is referenced in _index"                 check_body_sections_in_index
assert_ok "every _index id is consumed by some capability cell"       check_no_unused_evidence

echo ""
echo "Total: $((PASS + FAIL)) | PASS: $PASS | FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
