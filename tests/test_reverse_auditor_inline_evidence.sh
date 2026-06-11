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

# A file carrying non-ASCII content (em-dash, accented chars, arrow) — used to
# assert the packet serializer keeps these verbatim rather than \uXXXX-escaping.
cat > "$LORE_REPO/scripts/unicode.py" <<'PY'
def render():
    label = "coût — résumé → done"
    return label
PY
git_quiet "$LORE_REPO" add -A
git_quiet "$LORE_REPO" commit -m "unicode sample"

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

# ---------------------------------------------------------------------------
echo ""
echo "Test 5b: packet serializer keeps non-ASCII evidence verbatim (ensure_ascii=False)"
cat > "$TEST_ROOT/in5b.json" <<'JSON'
{
  "artifact_id": "a5b",
  "work_item": "demo-slug",
  "curated_top_k": [
    {"claim_id": "c5b", "file": "scripts/unicode.py", "line_range": "2-2",
     "exact_snippet": "    label = \"coût — résumé → done\""}
  ],
  "change_context": {"diff_ref": null, "changed_files": ["scripts/unicode.py"]}
}
JSON
run_resolver "$TEST_ROOT/in5b.json" >/dev/null
# The on-disk packet must carry the em-dash as its literal UTF-8 byte, not a
# — escape — the whole point of ensure_ascii=False is that the judge sees
# the character it must reproduce for grounding.
if grep -q $'—' "$TEST_ROOT/out.json"; then
  pass "packet contains the literal em-dash byte"
else
  fail "em-dash not present verbatim in packet"
fi
if grep -q '\\u2014' "$TEST_ROOT/out.json"; then
  fail "packet still escapes non-ASCII as \\u2014 (ensure_ascii not disabled)"
else
  pass "packet carries no \\uXXXX escape for the em-dash"
fi
# The resolved window content round-trips the non-ASCII characters intact.
if jq_get 'd["inlined_evidence"]["claim_windows"][0]["window_text"]' | grep -q "coût — résumé → done"; then
  pass "inlined window_text preserves non-ASCII content verbatim"
else
  fail "non-ASCII window content mangled: $(jq_get 'd["inlined_evidence"]["claim_windows"][0].get("window_text",None)')"
fi

# ===========================================================================
# Deterministic re-anchoring (scripts/reanchor-omission-claim.py)
#
# Each test drives reanchor against a crafted RA emission whose exact_snippet
# quotes real file content but with a quoting/line defect, then asserts the
# full round trip: the re-anchored claim PASSES grounding-preflight --no-cascade
# (the strict on-disk validator the wrapper runs next), provenance is recorded,
# and the recomputed hash matches the rewritten snippet. Pass-through and
# tool-error contracts are checked too.
# ===========================================================================
REANCHOR="$REPO_DIR/scripts/reanchor-omission-claim.py"
PREFLIGHT="$REPO_DIR/scripts/grounding-preflight.py"

# Fixture repo with a file whose content exercises the three rungs plus the
# quoting/non-ASCII cases. The blank line between blocks keeps each target
# snippet a UNIQUE line-block (no accidental ambiguity).
RA_FIX="$TEST_ROOT/reanchor-fix"
mkdir -p "$RA_FIX/scripts"
cat > "$RA_FIX/scripts/sample.py" <<'PY'
def head():
    return 0


def gamma(x):
    y = x + 1
    return y


def quoted():
    s = "a \"b\" c"
    return s


def naci():
    label = "coût — résumé"
    return label
PY

# reanchor_then_preflight <ra-input-file> -> writes $TEST_ROOT/ra_out.json,
# echoes "<reanchor_rc>|<preflight_pass>|<preflight_reason>".
reanchor_then_preflight() {
  local in_file="$1"
  python3 "$REANCHOR" --claim-file "$in_file" --repo-root "$RA_FIX" \
    > "$TEST_ROOT/ra_out.json" 2>/dev/null
  local rc=$?
  local pf
  pf=$(python3 "$PREFLIGHT" --claim-file "$TEST_ROOT/ra_out.json" \
       --repo-root "$RA_FIX" --no-cascade 2>/dev/null)
  local pass reason
  pass=$(printf '%s' "$pf" | python3 -c 'import json,sys; print("true" if json.load(sys.stdin).get("pass") else "false")')
  reason=$(printf '%s' "$pf" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason"))')
  echo "$rc|$pass|$reason"
}

ra_out_get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$TEST_ROOT/ra_out.json" "$1"; }

echo ""
echo "Test 6: exact-substring rung — line-drifted multi-line snippet re-anchors and passes preflight"
# Quote def gamma verbatim (lines 5-7) but claim the WRONG line_range 1-3.
cat > "$TEST_ROOT/ra6.json" <<'JSON'
{
  "judge": "reverse-auditor",
  "coverage_state": "covered",
  "omission_claim": {
    "file": "scripts/sample.py",
    "line_range": "1-3",
    "exact_snippet": "def gamma(x):\n    y = x + 1\n    return y",
    "normalized_snippet_hash": "deadbeef",
    "falsifier": "f",
    "why_it_matters": "w"
  }
}
JSON
res=$(reanchor_then_preflight "$TEST_ROOT/ra6.json")
if [[ "$res" == "0|true|ok" ]]; then
  pass "drifted exact snippet re-anchored and passed preflight (rc|pass|reason = $res)"
else
  fail "expected 0|true|ok, got $res"
fi
if [[ "$(ra_out_get 'd["omission_claim"]["line_range"]')" == "5-7" ]]; then
  pass "line_range rewritten to 5-7"
else
  fail "line_range not rewritten: $(ra_out_get 'd["omission_claim"]["line_range"]')"
fi
if [[ "$(ra_out_get 'd["omission_claim"]["reanchor"]["ladder_rung"]')" == "exact-substring" ]]; then
  pass "provenance records ladder_rung=exact-substring"
else
  fail "wrong rung: $(ra_out_get 'd["omission_claim"]["reanchor"]["ladder_rung"]')"
fi
if [[ "$(ra_out_get 'd["omission_claim"]["reanchor"]["original_line_range"]')" == "1-3" ]]; then
  pass "provenance preserves original_line_range=1-3"
else
  fail "original_line_range not preserved: $(ra_out_get 'd["omission_claim"]["reanchor"]["original_line_range"]')"
fi

echo ""
echo "Test 7: diff-prefix-strip rung — +/space-prefixed snippet re-anchors to the post-image and passes preflight"
# Quote def gamma as a diff hunk body: ' '/'+'-prefixed lines.
cat > "$TEST_ROOT/ra7.json" <<'JSON'
{
  "judge": "reverse-auditor",
  "coverage_state": "covered",
  "omission_claim": {
    "file": "scripts/sample.py",
    "line_range": "5-7",
    "exact_snippet": " def gamma(x):\n+    y = x + 1\n     return y",
    "normalized_snippet_hash": "deadbeef",
    "falsifier": "f",
    "why_it_matters": "w"
  }
}
JSON
res=$(reanchor_then_preflight "$TEST_ROOT/ra7.json")
if [[ "$res" == "0|true|ok" ]]; then
  pass "diff-prefixed snippet re-anchored to post-image and passed preflight ($res)"
else
  fail "expected 0|true|ok, got $res"
fi
if [[ "$(ra_out_get 'd["omission_claim"]["reanchor"]["ladder_rung"]')" == "diff-prefix-strip" ]]; then
  pass "provenance records ladder_rung=diff-prefix-strip"
else
  fail "wrong rung: $(ra_out_get 'd["omission_claim"]["reanchor"]["ladder_rung"]')"
fi
if [[ "$(ra_out_get 'd["omission_claim"]["exact_snippet"]')" == "$(printf 'def gamma(x):\n    y = x + 1\n    return y')" ]]; then
  pass "exact_snippet rewritten to verbatim file content (prefixes stripped)"
else
  fail "exact_snippet not the post-image: $(ra_out_get 'd["omission_claim"]["exact_snippet"]')"
fi

echo ""
echo "Test 8: quoted/backslashed content round-trips through re-anchor + preflight"
# Line 12 is:    s = "a \"b\" c"   — JSON-escape the backslashes and quotes.
cat > "$TEST_ROOT/ra8.json" <<'JSON'
{
  "judge": "reverse-auditor",
  "coverage_state": "covered",
  "omission_claim": {
    "file": "scripts/sample.py",
    "line_range": "1-1",
    "exact_snippet": "    s = \"a \\\"b\\\" c\"",
    "normalized_snippet_hash": "deadbeef",
    "falsifier": "f",
    "why_it_matters": "w"
  }
}
JSON
res=$(reanchor_then_preflight "$TEST_ROOT/ra8.json")
if [[ "$res" == "0|true|ok" ]]; then
  pass "quoted/backslashed snippet re-anchored and passed preflight ($res)"
else
  fail "expected 0|true|ok, got $res"
fi

echo ""
echo "Test 9: non-ASCII content round-trips (ensure_ascii=False keeps it verbatim)"
# Line 17 carries an em-dash and accented chars: label = "coût — résumé"
cat > "$TEST_ROOT/ra9.json" <<'JSON'
{
  "judge": "reverse-auditor",
  "coverage_state": "covered",
  "omission_claim": {
    "file": "scripts/sample.py",
    "line_range": "2-2",
    "exact_snippet": "    label = \"coût — résumé\"",
    "normalized_snippet_hash": "deadbeef",
    "falsifier": "f",
    "why_it_matters": "w"
  }
}
JSON
res=$(reanchor_then_preflight "$TEST_ROOT/ra9.json")
if [[ "$res" == "0|true|ok" ]]; then
  pass "non-ASCII snippet re-anchored and passed preflight ($res)"
else
  fail "expected 0|true|ok, got $res"
fi
if [[ "$(ra_out_get 'd["omission_claim"]["exact_snippet"]')" == *"coût — résumé"* ]]; then
  pass "non-ASCII preserved verbatim in rewritten snippet"
else
  fail "non-ASCII mangled: $(ra_out_get 'd["omission_claim"]["exact_snippet"]')"
fi

echo ""
echo "Test 10: recomputed normalized_snippet_hash matches the rewritten snippet"
expected_hash=$(printf '%s' "$(ra_out_get 'd["omission_claim"]["exact_snippet"]')" | python3 "$REPO_DIR/scripts/snippet_normalize.py" --hash)
if [[ "$(ra_out_get 'd["omission_claim"]["normalized_snippet_hash"]')" == "$expected_hash" ]]; then
  pass "normalized_snippet_hash recomputed for rewritten snippet"
else
  fail "hash stale: claim=$(ra_out_get 'd["omission_claim"]["normalized_snippet_hash"]') expected=$expected_hash"
fi

echo ""
echo "Test 11: content absent from file — claim passes through untouched (no provenance) and preflight fails"
cat > "$TEST_ROOT/ra11.json" <<'JSON'
{
  "judge": "reverse-auditor",
  "coverage_state": "covered",
  "omission_claim": {
    "file": "scripts/sample.py",
    "line_range": "5-7",
    "exact_snippet": "def this_is_not_in_the_file():\n    return 999",
    "normalized_snippet_hash": "deadbeef",
    "falsifier": "f",
    "why_it_matters": "w"
  }
}
JSON
res=$(reanchor_then_preflight "$TEST_ROOT/ra11.json")
rc11="${res%%|*}"
if [[ "$rc11" == "0" && "$res" != "0|true|"* ]]; then
  pass "absent content: reanchor exits 0, preflight still fails ($res)"
else
  fail "expected exit 0 + preflight fail, got $res"
fi
if [[ "$(ra_out_get 'd["omission_claim"].get("reanchor")')" == "None" ]]; then
  pass "no provenance block on pass-through"
else
  fail "unexpected provenance on pass-through: $(ra_out_get 'd["omission_claim"].get("reanchor")')"
fi

echo ""
echo "Test 12: ambiguous match — content occurs twice, claim passes through untouched"
mkdir -p "$RA_FIX/scripts"
cat > "$RA_FIX/scripts/dup.py" <<'PY'
x = 1
x = 1
PY
cat > "$TEST_ROOT/ra12.json" <<'JSON'
{
  "judge": "reverse-auditor",
  "coverage_state": "covered",
  "omission_claim": {
    "file": "scripts/dup.py",
    "line_range": "9-9",
    "exact_snippet": "x = 1",
    "normalized_snippet_hash": "deadbeef",
    "falsifier": "f",
    "why_it_matters": "w"
  }
}
JSON
python3 "$REANCHOR" --claim-file "$TEST_ROOT/ra12.json" --repo-root "$RA_FIX" \
  > "$TEST_ROOT/ra_out.json" 2>/dev/null
rc12=$?
if [[ "$rc12" == "0" && "$(ra_out_get 'd["omission_claim"].get("reanchor")')" == "None" ]]; then
  pass "ambiguous (2 matches): exit 0, no re-anchor (untouched)"
else
  fail "expected exit 0 + untouched, rc=$rc12 reanchor=$(ra_out_get 'd["omission_claim"].get("reanchor")')"
fi

echo ""
echo "Test 13: silence emission passes through verbatim, exit 0"
cat > "$TEST_ROOT/ra13.json" <<'JSON'
{"judge": "reverse-auditor", "coverage_state": "covered", "omission_claim": null}
JSON
python3 "$REANCHOR" --claim-file "$TEST_ROOT/ra13.json" --repo-root "$RA_FIX" \
  > "$TEST_ROOT/ra_out.json" 2>/dev/null
rc13=$?
if [[ "$rc13" == "0" && "$(ra_out_get 'd["omission_claim"]')" == "None" ]]; then
  pass "silence passes through (omission_claim stays null), exit 0"
else
  fail "silence pass-through broke: rc=$rc13"
fi

echo ""
echo "Test 14: malformed input is a tool error (non-zero exit), stdout empty (wrapper falls back to original)"
printf 'not json at all' > "$TEST_ROOT/ra14.json"
out14=$(python3 "$REANCHOR" --claim-file "$TEST_ROOT/ra14.json" --repo-root "$RA_FIX" 2>/dev/null)
rc14=$?
if [[ "$rc14" != "0" && -z "$out14" ]]; then
  pass "malformed input exits non-zero ($rc14) with empty stdout"
else
  fail "expected non-zero exit + empty stdout, rc=$rc14 stdout=[$out14]"
fi

echo ""
echo "Test 15: diff-prefix snippet quoting ONLY deleted (-) lines is rejected (no re-anchor to deleted content)"
cat > "$TEST_ROOT/ra15.json" <<'JSON'
{
  "judge": "reverse-auditor",
  "coverage_state": "covered",
  "omission_claim": {
    "file": "scripts/sample.py",
    "line_range": "5-7",
    "exact_snippet": "-def gamma(x):\n-    y = x + 1\n-    return y",
    "normalized_snippet_hash": "deadbeef",
    "falsifier": "f",
    "why_it_matters": "w"
  }
}
JSON
python3 "$REANCHOR" --claim-file "$TEST_ROOT/ra15.json" --repo-root "$RA_FIX" \
  > "$TEST_ROOT/ra_out.json" 2>/dev/null
rc15=$?
if [[ "$rc15" == "0" && "$(ra_out_get 'd["omission_claim"].get("reanchor")')" == "None" ]]; then
  pass "deleted-only diff content not re-anchored (untouched, exit 0)"
else
  fail "expected untouched for deleted-only content, reanchor=$(ra_out_get 'd["omission_claim"].get("reanchor")')"
fi

echo ""
echo "Test 16: stdout is exactly one JSON object (pure-JSON invariant)"
python3 "$REANCHOR" --claim-file "$TEST_ROOT/ra6.json" --repo-root "$RA_FIX" \
  > "$TEST_ROOT/ra_out.json" 2>/dev/null
if python3 -c 'import json,sys; json.load(open(sys.argv[1])); print("ok")' "$TEST_ROOT/ra_out.json" >/dev/null 2>&1; then
  pass "stdout parses as a single JSON object"
else
  fail "stdout is not pure JSON"
fi

echo ""
echo "=== Results ==="
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" == "0" ]]
