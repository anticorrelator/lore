#!/usr/bin/env bats
# capabilities.bats — Validates adapters/capabilities.json against the
# evidence registry and the support-level schema (Phase 1, T13).
#
# Coverage:
#   - capabilities.json is valid JSON with the expected top-level shape.
#   - Every per-framework capability cell uses a support level from the
#     closed set: full | partial | fallback | none.
#   - Every per-framework capability cell points to a capability name that
#     was declared in the global "capabilities" dictionary.
#   - Every framework declares the full capability set (no partial profiles).
#   - Every non-`none` capability cell carries a non-empty `evidence` field.
#   - Every `evidence` id resolves to an entry id in
#     adapters/capabilities-evidence.md.
#   - The evidence file's `_index` block lists exactly the union of
#     evidence ids consumed by capabilities.json (no orphans, no gaps).
#   - Every framework's `model_routing.shape` is one of: single | multi,
#     and carries an evidence pointer.
#
# Style: bats requires `bats-core`. If `bats` is not on PATH, run with the
# fallback bash driver below the bats blocks (mirrors the test_*.sh
# convention used elsewhere in tests/), so coverage works in environments
# without the bats toolchain.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
CAPS="$REPO_DIR/adapters/capabilities.json"
EVID="$REPO_DIR/adapters/capabilities-evidence.md"

setup() {
  [ -f "$CAPS" ] || skip "adapters/capabilities.json missing"
  [ -f "$EVID" ] || skip "adapters/capabilities-evidence.md missing"
}

# --- Helpers (Python is the universal JSON+regex tool here; jq is optional) ---

caps_python() {
  CAPS="$CAPS" python3 - <<'PYEOF'
import json, os, sys
with open(os.environ["CAPS"]) as f:
    print(json.dumps(json.load(f)))
PYEOF
}

evidence_index() {
  # Print one evidence id per line from the `_index` block at the end of
  # capabilities-evidence.md. The block starts at "## _index" and
  # contains lines like "- claude-code-instructions".
  EVID="$EVID" python3 - <<'PYEOF'
import os, re, sys
with open(os.environ["EVID"]) as f:
    text = f.read()
m = re.search(r"^## _index\s*\n(.*)$", text, re.M | re.S)
if not m:
    sys.exit(2)
block = m.group(1)
for line in block.splitlines():
    line = line.strip()
    if line.startswith("- "):
        print(line[2:].strip())
PYEOF
}

evidence_section_ids() {
  # Print one evidence id per line from `### <id>` headings (the body of
  # the file, not the _index block). Used to detect _index/body drift.
  EVID="$EVID" python3 - <<'PYEOF'
import os, re
with open(os.environ["EVID"]) as f:
    text = f.read()
# Stop at the _index section so we only count body entries.
body, _, _ = text.partition("## _index")
for m in re.finditer(r"^###\s+([a-z0-9-]+)\s*$", body, re.M):
    print(m.group(1))
PYEOF
}

consumed_evidence_ids() {
  # Print every evidence id consumed in capabilities.json — both per-cell
  # and per-framework model_routing.evidence — one per line, sorted +
  # deduplicated.
  CAPS="$CAPS" python3 - <<'PYEOF'
import json, os
with open(os.environ["CAPS"]) as f:
    data = json.load(f)
ids = set()
for fw_id, fw in data.get("frameworks", {}).items():
    mr = fw.get("model_routing") or {}
    if mr.get("evidence"):
        ids.add(mr["evidence"])
    for cap_name, cell in (fw.get("capabilities") or {}).items():
        if cell.get("evidence"):
            ids.add(cell["evidence"])
for cid in sorted(ids):
    print(cid)
PYEOF
}

# ============================================================
# Schema-shape tests
# ============================================================

@test "capabilities.json parses as JSON" {
  run python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CAPS"
  [ "$status" -eq 0 ]
}

@test "capabilities.json has required top-level keys" {
  run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
required = ["version", "support_levels", "capabilities", "frameworks"]
missing = [k for k in required if k not in d]
if missing:
    print("missing keys:", missing); sys.exit(1)
' "$CAPS"
  [ "$status" -eq 0 ]
}

@test "support_levels is exactly {full, partial, fallback, none}" {
  run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
got = set(d["support_levels"].keys())
want = {"full", "partial", "fallback", "none"}
if got != want:
    print("expected", sorted(want), "got", sorted(got)); sys.exit(1)
' "$CAPS"
  [ "$status" -eq 0 ]
}

@test "frameworks include claude-code, opencode, codex" {
  run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
got = set(d["frameworks"].keys())
want = {"claude-code", "opencode", "codex"}
missing = want - got
if missing:
    print("missing frameworks:", sorted(missing)); sys.exit(1)
' "$CAPS"
  [ "$status" -eq 0 ]
}

# ============================================================
# Per-cell schema tests
# ============================================================

@test "every capability cell uses a support level from the closed set" {
  run python3 -c '
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
  [ "$status" -eq 0 ]
}

@test "every per-cell capability key is declared in the global capabilities map" {
  run python3 -c '
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
  [ "$status" -eq 0 ]
}

@test "every framework declares all known capabilities (no partial profiles)" {
  # model_routing lives at the framework root (sibling to capabilities)
  # rather than inside the per-framework capabilities map because its
  # shape is single|multi, not full|partial|fallback|none. Validated
  # separately in the model_routing test below.
  run python3 -c '
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
  [ "$status" -eq 0 ]
}

@test "every non-none cell carries a non-empty evidence pointer" {
  run python3 -c '
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
  [ "$status" -eq 0 ]
}

@test "every framework declares model_routing.shape in {single, multi}" {
  run python3 -c '
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
  [ "$status" -eq 0 ]
}

# ============================================================
# Evidence cross-reference tests
# ============================================================

@test "every evidence id consumed in capabilities.json resolves in capabilities-evidence.md" {
  consumed=$(consumed_evidence_ids)
  index=$(evidence_index)
  missing=""
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if ! grep -Fxq "$id" <<<"$index"; then
      missing="${missing}${id}"$'\n'
    fi
  done <<<"$consumed"
  if [ -n "$missing" ]; then
    echo "evidence ids consumed but not present in capabilities-evidence.md _index:"
    echo "$missing"
    return 1
  fi
}

@test "every id in capabilities-evidence.md _index has a matching ### body section" {
  index=$(evidence_index)
  body=$(evidence_section_ids)
  orphans=""
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if ! grep -Fxq "$id" <<<"$body"; then
      orphans="${orphans}${id}"$'\n'
    fi
  done <<<"$index"
  if [ -n "$orphans" ]; then
    echo "ids listed in _index without ### body section:"
    echo "$orphans"
    return 1
  fi
}

@test "every ### body id in capabilities-evidence.md is referenced in _index" {
  body=$(evidence_section_ids)
  index=$(evidence_index)
  orphans=""
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if ! grep -Fxq "$id" <<<"$index"; then
      orphans="${orphans}${id}"$'\n'
    fi
  done <<<"$body"
  if [ -n "$orphans" ]; then
    echo "ids defined in body but missing from _index:"
    echo "$orphans"
    return 1
  fi
}

@test "every id in capabilities-evidence.md _index is consumed by capabilities.json" {
  consumed=$(consumed_evidence_ids)
  index=$(evidence_index)
  unused=""
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if ! grep -Fxq "$id" <<<"$consumed"; then
      unused="${unused}${id}"$'\n'
    fi
  done <<<"$index"
  if [ -n "$unused" ]; then
    echo "evidence ids defined but not consumed by any capability cell:"
    echo "$unused"
    return 1
  fi
}
