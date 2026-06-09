#!/usr/bin/env bash
# test_reverse_auditor_inline_evidence.sh — verifies the RA-scoped evidence
# resolver (scripts/reverse-auditor-inline-evidence.py) inlines claim windows
# and diff hunks, sets content_locate_verdict correctly, and honors the two
# Phase 2 conditions: archive-path fallback + change-under-audit diff-hunk
# selection bound to diff_ref with null/absent handling.
#
# Strategy: build two throwaway git repos (a lore-checkout-shaped repo and a
# KDIR-shaped repo with an archived _work file), drive the resolver against
# crafted RA inputs, and assert on the emitted inlined packet.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$REPO_DIR/scripts/reverse-auditor-inline-evidence.py"

PASS=0
FAIL=0
fail() { printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); }
pass() { printf '  PASS: %s\n' "$*"; PASS=$((PASS + 1)); }

TEST_ROOT="$(mktemp -d -t lore-ra-inline.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

git_quiet() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}" >/dev/null 2>&1; }

# --- lore-checkout-shaped repo: scripts/foo.py with two commits ---
LORE_REPO="$TEST_ROOT/lore"
mkdir -p "$LORE_REPO/scripts"
git_quiet "$LORE_REPO" init
cat > "$LORE_REPO/scripts/foo.py" <<'PY'
def alpha():
    return 1


def beta():
    return 2
PY
git_quiet "$LORE_REPO" add -A
git_quiet "$LORE_REPO" commit -m "initial foo"
FIRST_SHA=$(git -C "$LORE_REPO" rev-parse HEAD)

# An unrelated second commit — this is the session-boundary diff_ref that did
# NOT touch foo.py (the change-under-audit hunk-selection condition).
echo "unrelated" > "$LORE_REPO/scripts/other.txt"
git_quiet "$LORE_REPO" add -A
git_quiet "$LORE_REPO" commit -m "unrelated change"
BOUNDARY_SHA=$(git -C "$LORE_REPO" rev-parse HEAD)

# --- KDIR-shaped repo: an ARCHIVED _work file (archive-path fallback) ---
KDIR="$TEST_ROOT/kdir"
mkdir -p "$KDIR/_work/_archive/demo-slug"
git_quiet "$KDIR" init
cat > "$KDIR/_work/_archive/demo-slug/notes.md" <<'MD'
# Notes
archived line one
archived line two
MD
git_quiet "$KDIR" add -A
git_quiet "$KDIR" commit -m "archived work item"

run_resolver() {
  # $1 = ra-input json file ; $2 = diff_ref ; writes $TEST_ROOT/out.json
  local in_file="$1"
  python3 "$RESOLVER" "$in_file" "$TEST_ROOT/out.json" \
    --lore-repo "$LORE_REPO" --kdir "$KDIR" >/dev/null 2>&1
  echo $?
}

jq_get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$TEST_ROOT/out.json" "$1"; }

echo "=== reverse-auditor inline-evidence resolver tests ==="

# ---------------------------------------------------------------------------
echo ""
echo "Test 1: verified snippet — claim window resolves with content_locate_verdict=verified"
cat > "$TEST_ROOT/in1.json" <<JSON
{
  "artifact_id": "a1",
  "work_item": "demo-slug",
  "curated_top_k": [
    {"claim_id": "c1", "file": "scripts/foo.py", "line_range": "5-6",
     "exact_snippet": "def beta():\n    return 2"}
  ],
  "change_context": {"diff_ref": "$BOUNDARY_SHA", "changed_files": ["scripts/foo.py"]}
}
JSON
rc=$(run_resolver "$TEST_ROOT/in1.json")
if [[ "$rc" == "0" ]]; then
  pass "resolver exits 0"
else
  fail "resolver exited $rc"
fi
if [[ "$(jq_get 'd["inlined_evidence"]["claim_windows"][0]["resolved"]')" == "True" ]]; then
  pass "claim window resolved=true"
else
  fail "claim window not resolved: $(jq_get 'd["inlined_evidence"]["claim_windows"][0]')"
fi
if [[ "$(jq_get 'd["inlined_evidence"]["claim_windows"][0]["content_locate_verdict"]')" == "verified" ]]; then
  pass "content_locate_verdict=verified on snippet-anchored window"
else
  fail "expected verified, got $(jq_get 'd["inlined_evidence"]["claim_windows"][0]["content_locate_verdict"]')"
fi

# ---------------------------------------------------------------------------
echo ""
echo "Test 2: change-under-audit diff-hunk — diff_ref did NOT touch the file, hunk still resolves to the file's real change commit"
# diff_ref is BOUNDARY_SHA (the unrelated commit). A bare `git show <diff_ref> -- foo.py`
# would be empty; the resolver derives the file's change commit instead.
if [[ "$(jq_get 'd["inlined_evidence"]["diff_hunks"][0]["resolved"]')" == "True" ]]; then
  pass "diff hunk resolved despite diff_ref not touching the file"
else
  fail "diff hunk not resolved: $(jq_get 'd["inlined_evidence"]["diff_hunks"][0]')"
fi
if jq_get 'd["inlined_evidence"]["diff_hunks"][0]["diff_text"]' | grep -q "def beta"; then
  pass "diff hunk carries the real change surface (def beta)"
else
  fail "diff hunk missing expected content"
fi

# ---------------------------------------------------------------------------
echo ""
echo "Test 3: null diff_ref — hunk falls back to HEAD history"
cat > "$TEST_ROOT/in3.json" <<JSON
{
  "artifact_id": "a3",
  "work_item": "demo-slug",
  "curated_top_k": [],
  "change_context": {"diff_ref": null, "changed_files": ["scripts/foo.py"]}
}
JSON
run_resolver "$TEST_ROOT/in3.json" >/dev/null
if [[ "$(jq_get 'd["inlined_evidence"]["diff_hunks"][0]["resolved"]')" == "True" ]]; then
  pass "diff hunk resolved with null diff_ref (HEAD fallback)"
else
  fail "null diff_ref did not fall back to HEAD: $(jq_get 'd["inlined_evidence"]["diff_hunks"][0]')"
fi

# ---------------------------------------------------------------------------
echo ""
echo "Test 4: archive-path fallback — _work/<slug>/ absent at HEAD resolves under _work/_archive/<slug>/"
cat > "$TEST_ROOT/in4.json" <<'JSON'
{
  "artifact_id": "a4",
  "work_item": "demo-slug",
  "curated_top_k": [
    {"claim_id": "c4", "file": "_work/demo-slug/notes.md", "line_range": "2-3",
     "exact_snippet": "archived line one"}
  ],
  "change_context": {"diff_ref": null, "changed_files": ["_work/demo-slug/notes.md"]}
}
JSON
run_resolver "$TEST_ROOT/in4.json" >/dev/null
if [[ "$(jq_get 'd["inlined_evidence"]["claim_windows"][0]["resolved"]')" == "True" ]]; then
  pass "archived _work claim window resolved via archive fallback"
else
  fail "archive fallback failed: $(jq_get 'd["inlined_evidence"]["claim_windows"][0]')"
fi
if jq_get 'd["inlined_evidence"]["claim_windows"][0].get("resolved_file_relative","")' | grep -q "_archive"; then
  pass "resolved_file_relative names the _archive path"
else
  fail "resolved path did not use _archive: $(jq_get 'd["inlined_evidence"]["claim_windows"][0].get("resolved_file_relative",None)')"
fi

# ---------------------------------------------------------------------------
echo ""
echo "Test 5: provenance-lost — file absent at HEAD and archive marks the window unresolved"
cat > "$TEST_ROOT/in5.json" <<'JSON'
{
  "artifact_id": "a5",
  "work_item": "demo-slug",
  "curated_top_k": [
    {"claim_id": "c5", "file": "scripts/ghost.py", "line_range": "1-2",
     "exact_snippet": "does not exist"}
  ],
  "change_context": {"diff_ref": null, "changed_files": ["scripts/ghost.py"]}
}
JSON
run_resolver "$TEST_ROOT/in5.json" >/dev/null
if [[ "$(jq_get 'd["inlined_evidence"]["claim_windows"][0]["resolved"]')" == "False" ]]; then
  pass "absent file window resolved=false"
else
  fail "expected unresolved window for absent file"
fi
if [[ "$(jq_get 'd["inlined_evidence"]["claim_windows"][0]["content_locate_verdict"]')" == "provenance-lost" ]]; then
  pass "content_locate_verdict=provenance-lost on absent file"
else
  fail "expected provenance-lost, got $(jq_get 'd["inlined_evidence"]["claim_windows"][0]["content_locate_verdict"]')"
fi

echo ""
echo "=== Results ==="
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" == "0" ]]
