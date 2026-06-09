#!/usr/bin/env bash
# test_capability_incomplete_marker.sh — Regression tests for the
# capability-incomplete standing-state marker on the two orchestration-map
# surfaces (SessionStart digest + /work list) and the index projection that
# feeds them.
#
# Covers the Phase 1 verification objectives owned by the index/renderer task:
#   1. update-work-index.sh projects the nested closure subset
#      { capability_incomplete, divergence_summary, residue_followup } into
#      each active item's _index.json entry.
#   2. A full/legacy/absent-closure item normalizes to capability_incomplete
#      false (no marker leaks).
#   3. load-work.sh (SessionStart digest) renders the [capability-incomplete]
#      marker + waiting-on edge for a diverged-but-active parent, and renders
#      routine active items as plain lines.
#   4. list-work.sh (/work) renders the same marker block; routine items are
#      unaffected.
#   5. list-work.sh refreshes its read model before rendering — a divergence
#      written to _meta.json shows up without a manual update-work-index.sh.
#   6. load-work.sh preserves SessionStart silent-skip discipline (exits 0).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
UPDATE_INDEX="$SCRIPTS_DIR/update-work-index.sh"
LOAD_WORK="$SCRIPTS_DIR/load-work.sh"
LIST_WORK="$SCRIPTS_DIR/list-work.sh"

PASS=0
FAIL=0
KDIR=$(mktemp -d)

cleanup() { rm -rf "$KDIR"; }
trap cleanup EXIT

# Drive all three scripts against the temp knowledge dir; resolve-repo.sh
# short-circuits on LORE_KNOWLEDGE_DIR, and load-work.sh's agent gate stays on.
export LORE_KNOWLEDGE_DIR="$KDIR"

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected to find: $needle"
    FAIL=$((FAIL + 1))
  fi
}

assert_absent() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  FAIL: $label"
    echo "    Did not expect to find: $needle"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

write_meta() {
  mkdir -p "$KDIR/_work/$1"
  cat > "$KDIR/_work/$1/_meta.json"
}

# --- Fixtures ---------------------------------------------------------------

# Diverged-but-active parent (partial verdict).
write_meta diverged-parent <<'JSON'
{
  "slug": "diverged-parent",
  "title": "Diverged parent",
  "status": "active",
  "updated": "2026-06-09T00:00:00Z",
  "closure": {
    "verdict": "partial",
    "capability_incomplete": true,
    "capability_loop_summary": "banner shipped; residue deferred",
    "divergence_summary": "deferred the residue render to a child item",
    "residue_followup": "residue-child",
    "verdict_at": "2026-06-09T00:00:00Z",
    "intent_anchor_at_close": "anchor text"
  }
}
JSON

# Routine active item — no closure block at all.
write_meta routine-item <<'JSON'
{
  "slug": "routine-item",
  "title": "Routine active",
  "status": "active",
  "updated": "2026-06-09T00:00:00Z"
}
JSON

# Full-verdict active item — closure present but capability_incomplete false.
write_meta full-item <<'JSON'
{
  "slug": "full-item",
  "title": "Full verdict",
  "status": "active",
  "updated": "2026-06-09T00:00:00Z",
  "closure": {
    "verdict": "full",
    "capability_incomplete": false,
    "divergence_summary": null,
    "residue_followup": null
  }
}
JSON

# --- 1 & 2: projection ------------------------------------------------------

bash "$UPDATE_INDEX" "$KDIR" >/dev/null

CLOSURE_DIVERGED=$(python3 -c "
import json
d = json.load(open('$KDIR/_work/_index.json'))
m = {p['slug']: p.get('closure') for p in d['plans']}
print(json.dumps(m['diverged-parent'], sort_keys=True))
")
assert_eq "projection: diverged parent carries nested closure subset" \
  "$CLOSURE_DIVERGED" \
  '{"capability_incomplete": true, "divergence_summary": "deferred the residue render to a child item", "residue_followup": "residue-child"}'

CLOSURE_ROUTINE=$(python3 -c "
import json
d = json.load(open('$KDIR/_work/_index.json'))
m = {p['slug']: p.get('closure') for p in d['plans']}
print(m['routine-item']['capability_incomplete'])
")
assert_eq "projection: routine item normalizes capability_incomplete to false" \
  "$CLOSURE_ROUTINE" "False"

CLOSURE_FULL=$(python3 -c "
import json
d = json.load(open('$KDIR/_work/_index.json'))
m = {p['slug']: p.get('closure') for p in d['plans']}
print(m['full-item']['capability_incomplete'])
")
assert_eq "projection: full verdict normalizes capability_incomplete to false" \
  "$CLOSURE_FULL" "False"

# --- 3: load-work.sh (SessionStart digest) ---------------------------------

LOAD_OUT=$(bash "$LOAD_WORK" 2>&1)
assert_contains "digest: diverged parent shows capability-incomplete marker" \
  "$LOAD_OUT" \
  "[capability-incomplete] diverged-parent — diverged from anchor; deferred the residue render to a child item"
assert_contains "digest: parent shows waiting-on edge to residue child" \
  "$LOAD_OUT" "waiting-on: residue-child"
assert_contains "digest: routine item shows plain line" \
  "$LOAD_OUT" "- routine-item: Routine active"
assert_absent "digest: full item shows no marker" \
  "$LOAD_OUT" "[capability-incomplete] full-item"

# --- 6: silent-skip discipline (exit 0) ------------------------------------

bash "$LOAD_WORK" >/dev/null 2>&1
assert_eq "digest: hook exits 0 (silent-skip parity preserved)" "$?" "0"

# --- 4: list-work.sh (/work) -----------------------------------------------

LIST_OUT=$(bash "$LIST_WORK" 2>&1)
assert_contains "list: diverged parent shows capability-incomplete marker" \
  "$LIST_OUT" \
  "[capability-incomplete] diverged-parent — diverged from anchor; deferred the residue render to a child item"
assert_contains "list: parent shows waiting-on edge to residue child" \
  "$LIST_OUT" "waiting-on: residue-child"
assert_absent "list: full item shows no marker" \
  "$LIST_OUT" "[capability-incomplete] full-item"

# --- 5: pre-read refresh ----------------------------------------------------
# Mutate the divergence summary in _meta.json and run list-work.sh WITHOUT a
# manual index rebuild; the fresh value must appear, proving the pre-read
# refresh ran.

python3 -c "
import json
p = '$KDIR/_work/diverged-parent/_meta.json'
m = json.load(open(p))
m['closure']['divergence_summary'] = 'freshly-written-divergence'
json.dump(m, open(p, 'w'), indent=2)
"
LIST_FRESH=$(bash "$LIST_WORK" 2>&1)
assert_contains "list: pre-read refresh picks up a just-written divergence" \
  "$LIST_FRESH" \
  "[capability-incomplete] diverged-parent — diverged from anchor; freshly-written-divergence"

# --- Summary ---------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
