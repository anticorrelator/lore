#!/usr/bin/env bash
# test_kind_sections_session_start.sh — Pin the kind sections that
# scripts/load-knowledge.sh appends to the SessionStart payload.
#
#   1. A store carrying all four kinds renders labeled theory, question and
#      hypothesis sections after the existing content, with kind_status on
#      every non-fact line.
#   2. A store with no non-fact entry produces byte-identical output with the
#      section path on and off, reports the same [Budget] chars_used, and
#      costs no search — the presence probe answers from the index alone.
#   3. A kind with nothing to deliver renders nothing at all: no header, no
#      placeholder, no blank line.
#   4. Every entry a section served reaches the session packet with the render
#      mode it was actually delivered in.
#   5. The sections gate on their own time allowance, independent of the
#      relevance search's content-degradation budget.
#   6. An empty section set and an index that could not answer stay two
#      different observations in the zero-entry explanation.
#
# The signal load-knowledge.sh ranks on comes from the git branch, so each
# store is paired with a throwaway repo whose branch name carries the query
# terms. Stores come from tests/fixtures/make-epistemic-store.sh.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_DIR/scripts"
LOADER="$SCRIPT_DIR/load-knowledge.sh"
FIXTURE="$REPO_DIR/tests/fixtures/make-epistemic-store.sh"
TEST_DIR=$(mktemp -d)

PASS=0
FAIL=0

cleanup() {
  chmod -R u+w "$TEST_DIR" 2>/dev/null || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_contains() {
  local label="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF -- "$expected"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected to contain: $expected"
    echo "    Got: $output"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" output="$2" unexpected="$3"
  if echo "$output" | grep -qF -- "$unexpected"; then
    echo "  FAIL: $label"
    echo "    Should NOT contain: $unexpected"
    echo "    Got: $output"
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

# A repo whose branch name is the ranking signal for the paired store.
make_repo() {
  local dir="$1" branch="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q -b "$branch"
  git -C "$dir" -c user.email=test@test -c user.name=test \
    commit -q --allow-empty -m "init"
}

# run_load <repo> <kdir> [VAR=VALUE ...] — one SessionStart load, stdout only.
run_load() {
  local repo="$1" kdir="$2"
  shift 2
  (cd "$repo" && env LORE_KNOWLEDGE_DIR="$kdir" "$@" bash "$LOADER" 2>/dev/null)
}

# The payload from the first kind section header to the end of the load.
sections_only() {
  echo "$1" | sed -n '/^### /,$p'
}

echo "=== SessionStart kind section tests ==="

SCALED_DIR="$TEST_DIR/scaled"
SCALED_REPO="$TEST_DIR/scaled-repo"
bash "$FIXTURE" "$SCALED_DIR" --scaled >/dev/null
python3 "$SCRIPT_DIR/pk_cli.py" index "$SCALED_DIR" >/dev/null 2>&1 || true
make_repo "$SCALED_REPO" "quillon-router"

# =============================================
# Test 1: all four kinds — sections render, labeled, after the fact entries
# =============================================
echo ""
echo "Test 1: labeled sections follow the existing content"

SCALED_OUT=$(run_load "$SCALED_REPO" "$SCALED_DIR")
SCALED_SECTIONS=$(sections_only "$SCALED_OUT")

assert_contains "the fact list still ships" "$SCALED_OUT" "--- Relevant entries"
assert_contains "theory section renders" "$SCALED_OUT" "### Theory"
assert_contains "question section renders" "$SCALED_OUT" "### Open questions"
assert_contains "hypothesis section renders" "$SCALED_OUT" "### Hypotheses"

# Sections come after everything the loader already delivered.
FACTS_LINE=$(echo "$SCALED_OUT" | grep -n -- "--- Relevant entries" | head -1 | cut -d: -f1)
THEORY_LINE=$(echo "$SCALED_OUT" | grep -n "^### Theory$" | head -1 | cut -d: -f1)
if [[ -n "$FACTS_LINE" && -n "$THEORY_LINE" && $THEORY_LINE -gt $FACTS_LINE ]]; then
  echo "  PASS: sections are appended below the fact entries"
  PASS=$((PASS + 1))
else
  echo "  FAIL: sections are appended below the fact entries"
  echo "    facts at line ${FACTS_LINE:-none}, theory at line ${THEORY_LINE:-none}"
  FAIL=$((FAIL + 1))
fi

# Section order is claim strength: theory, then questions, then hypotheses.
SECTION_ORDER=$(echo "$SCALED_SECTIONS" | grep '^### ' | tr '\n' '|')
assert_eq "sections render in claim-strength order" "$SECTION_ORDER" \
  "### Theory|### Open questions|### Hypotheses|"

# kind_status is visible on every non-fact line. Theory declares none and
# carries its subsystem instead, which is the bound the section is capped on.
assert_contains "an open question is labeled with its kind_status" \
  "$SCALED_SECTIONS" "[open]"
assert_contains "theory lines carry their subsystem" "$SCALED_SECTIONS" \
  "[subsystem: quillon-router]"
assert_contains "the second theory is a different subsystem" "$SCALED_SECTIONS" \
  "[subsystem: quillon-cache]"

UNLABELED=$(echo "$SCALED_SECTIONS" | grep -c '^#### [^[]*(from ' || true)
assert_eq "no rendered section entry is missing its bracketed label" \
  "$UNLABELED" "0"

# kind_status selection: only `open` questions, never a `refuted` hypothesis.
assert_not_contains "an answered question is not delivered" "$SCALED_SECTIONS" \
  "Quillon Question Answered"
assert_not_contains "a dissolved question is not delivered" "$SCALED_SECTIONS" \
  "Quillon Question Dissolved"
assert_not_contains "a refuted hypothesis is not delivered" "$SCALED_SECTIONS" \
  "Quillon Hypothesis Refuted"

# The reservation is a cap, not an overrun: the payload still fits the ceiling.
SCALED_CHARS=$(echo "$SCALED_OUT" | grep -o '^\[Budget\] [0-9]*' | awk '{print $2}')
SCALED_TOTAL=$(echo "$SCALED_OUT" | sed -n 's|^\[Budget\] [0-9]*/\([0-9]*\) .*|\1|p')
if [[ -n "$SCALED_CHARS" && $SCALED_CHARS -le ${SCALED_TOTAL:-0} && $SCALED_CHARS -gt 0 ]]; then
  echo "  PASS: sections and facts together stay inside the budget"
  PASS=$((PASS + 1))
else
  echo "  FAIL: sections and facts together stay inside the budget"
  echo "    chars_used=${SCALED_CHARS:-none} budget=${SCALED_TOTAL:-none}"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Test 2: a store with no non-fact entry is untouched
# =============================================
echo ""
echo "Test 2: no non-fact entry — same bytes, same budget, no search"

FACTS_DIR="$TEST_DIR/facts-only"
FACTS_REPO="$TEST_DIR/facts-repo"
mkdir -p "$FACTS_DIR/conventions" "$FACTS_DIR/gotchas"
for n in 1 2 3 4 5 6; do
  printf '# Wibbet Convention %s\nThe wibbet handler drains the wibbet queue on batch %s.\n%s\n' \
    "$n" "$n" \
    '<!-- learned: 2026-07-01 | confidence: high | source: manual | scale: subsystem | kind: fact | status: current -->' \
    > "$FACTS_DIR/conventions/wibbet-$n.md"
done
# Entries written before the kind field existed carry no kind at all; the probe
# must read them as facts, not as an unknown kind worth sectioning.
printf '# Wibbet Legacy\nA wibbet entry from before the field existed.\n%s\n' \
  '<!-- learned: 2024-10-01 | confidence: high | source: manual | scale: subsystem | status: current -->' \
  > "$FACTS_DIR/gotchas/wibbet-legacy.md"
python3 - "$FACTS_DIR" <<'MANIFEST_PY'
import json, os, sys
kdir = sys.argv[1]
entries = []
for root, dirnames, filenames in os.walk(kdir):
    dirnames[:] = [d for d in dirnames if not d.startswith("_")]
    for name in sorted(filenames):
        if name.endswith(".md"):
            entries.append({"path": os.path.relpath(os.path.join(root, name), kdir),
                            "backlinks": []})
with open(os.path.join(kdir, "_manifest.json"), "w", encoding="utf-8") as f:
    json.dump({"format_version": 2, "entries": sorted(entries, key=lambda e: e["path"])}, f)
MANIFEST_PY
python3 "$SCRIPT_DIR/pk_cli.py" index "$FACTS_DIR" >/dev/null 2>&1 || true
make_repo "$FACTS_REPO" "wibbet-handler"

# Off vs on: LORE_KIND_SECTIONS_TIME_BUDGET=0 skips the section path entirely,
# so the OFF run is the loader's behavior before sections existed.
FACTS_OFF=$(run_load "$FACTS_REPO" "$FACTS_DIR" LORE_KIND_SECTIONS_TIME_BUDGET=0)
rm -f "$FACTS_DIR/_meta/retrieval-log.jsonl"
FACTS_ON=$(run_load "$FACTS_REPO" "$FACTS_DIR")

if [[ "$FACTS_OFF" == "$FACTS_ON" ]]; then
  echo "  PASS: output is byte-identical with the section path on and off"
  PASS=$((PASS + 1))
else
  echo "  FAIL: output is byte-identical with the section path on and off"
  echo "    diff:"
  diff <(echo "$FACTS_OFF") <(echo "$FACTS_ON") | head -20
  FAIL=$((FAIL + 1))
fi

OFF_BUDGET=$(echo "$FACTS_OFF" | grep '^\[Budget\]' | head -1)
ON_BUDGET=$(echo "$FACTS_ON" | grep '^\[Budget\]' | head -1)
assert_eq "the budget line reports the same chars_used" "$ON_BUDGET" "$OFF_BUDGET"
assert_contains "the fact entries still ship" "$FACTS_ON" "wibbet handler drains"
assert_not_contains "no section header appears at all" "$FACTS_ON" "### "

# The probe is one indexed lookup, not a search: the section queries would have
# written `caller: session-start` rows into the retrieval log had they run.
SECTION_SEARCHES=$(grep -c 'session-start' "$FACTS_DIR/_meta/retrieval-log.jsonl" 2>/dev/null || true)
assert_eq "the probe issues no search on a fact-only store" \
  "${SECTION_SEARCHES:-0}" "0"

# And the same log on the scaled store shows the section queries that did run,
# so the count above is a real zero and not a log that is never written.
SCALED_SEARCHES=$(grep -c 'session-start' "$SCALED_DIR/_meta/retrieval-log.jsonl" 2>/dev/null || true)
if [[ ${SCALED_SEARCHES:-0} -gt 0 ]]; then
  echo "  PASS: the section queries are logged when the probe admits them"
  PASS=$((PASS + 1))
else
  echo "  FAIL: the section queries are logged when the probe admits them"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Test 3: a kind with nothing to say renders nothing at all
# =============================================
echo ""
echo "Test 3: an empty section emits no header, no placeholder, no blank line"

BASE_DIR="$TEST_DIR/base"
BASE_REPO="$TEST_DIR/base-repo"
bash "$FIXTURE" "$BASE_DIR" >/dev/null
python3 "$SCRIPT_DIR/pk_cli.py" index "$BASE_DIR" >/dev/null 2>&1 || true
make_repo "$BASE_REPO" "stale-hypothesis-question"

BASE_OUT=$(run_load "$BASE_REPO" "$BASE_DIR")
BASE_SECTIONS=$(sections_only "$BASE_OUT")

assert_contains "the kinds that have entries render" "$BASE_SECTIONS" "### Hypotheses"
assert_contains "the open question renders" "$BASE_SECTIONS" "### Open questions"
# The base fixture carries no theory entry.
assert_not_contains "the kind with no entry renders no header" "$BASE_OUT" "### Theory"
assert_not_contains "no placeholder stands in for the absent section" \
  "$BASE_OUT" "(none)"

# Every header that IS rendered is followed by content, so a header is never a
# reader's only evidence and cannot be mistaken for a swallowed query error.
EMPTY_HEADERS=$(echo "$BASE_SECTIONS" | awk '
  /^### / { if (pending) empty++; pending = 1; next }
  /^$/    { next }
  { pending = 0 }
  END { if (pending) empty++; print empty + 0 }')
assert_eq "no rendered header is followed by another header or by nothing" \
  "$EMPTY_HEADERS" "0"

# =============================================
# Test 4: served section entries reach the session packet
# =============================================
echo ""
echo "Test 4: the packet records every entry a section served"

PACKET_CHECK=$(python3 - "$SCALED_DIR" "$SCALED_SECTIONS" <<'PY'
import json
import os
import re
import sys

kdir, rendered = sys.argv[1], sys.argv[2]

# Paths as the two render shapes spell them: `(from <path>)` for full and
# snippet blocks, `[[knowledge:<path>#...]]` for backlinks.
paths = set(re.findall(r"\(from ([^)]+\.md)\)", rendered))
paths |= {p + ".md" for p in re.findall(r"\[\[knowledge:([^#\]]+)#", rendered)}

rows = []
with open(os.path.join(kdir, "_packets", "packets.jsonl"), encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line:
            rows.append(json.loads(line))
delivered = {e["path"]: e["render_mode"] for e in rows[-1]["delivered_entries"]}
modes = {delivered[p] for p in paths if p in delivered}

print("rendered_count:%d" % len(paths))
print("missing_count:%d" % sum(1 for p in paths if p not in delivered))
print("modes_are_section_modes:%s" % modes.issubset({"full", "snippet", "backlink"}))
print("scope:%s" % rows[-1]["packet_scope"])
PY
)
assert_contains "the packet is a session-scope row" "$PACKET_CHECK" "scope:session"
# Two theories (one per subsystem), the one open question, two hypotheses.
assert_contains "the sections served entries to record" "$PACKET_CHECK" \
  "rendered_count:5"
assert_contains "no section entry is missing from the packet" "$PACKET_CHECK" \
  "missing_count:0"
assert_contains "each section entry carries the mode it was rendered in" \
  "$PACKET_CHECK" "modes_are_section_modes:True"

# =============================================
# Test 5: the sections have their own time allowance
# =============================================
echo ""
echo "Test 5: the section gate is independent of the relevance-search budget"

SCALED_NO_SECTIONS=$(run_load "$SCALED_REPO" "$SCALED_DIR" LORE_KIND_SECTIONS_TIME_BUDGET=0)
assert_not_contains "a spent section allowance drops the sections" \
  "$SCALED_NO_SECTIONS" "### Theory"
assert_contains "and leaves the fact entries shipping" "$SCALED_NO_SECTIONS" \
  "--- Relevant entries"

# The knob is the section path's own, sized against the hook timeout. Reusing
# TIME_BUDGET_SECS would disable sections on exactly the large stores that have
# something to put in them, while the rest of the payload still ships.
GATE_LINE=$(grep -n 'SECTION_TIME_BUDGET_SECS=' "$LOADER" | head -1)
assert_contains "the section allowance has its own override" "$GATE_LINE" \
  "LORE_KIND_SECTIONS_TIME_BUDGET"
GATE_TEST=$(grep 'SECONDS -lt \$SECTION_TIME_BUDGET_SECS' "$LOADER" || true)
assert_contains "the section call is gated on that allowance" "$GATE_TEST" \
  "SECTION_TIME_BUDGET_SECS"
assert_not_contains "and not on the content-degradation budget" "$GATE_TEST" \
  "\$TIME_BUDGET_SECS &&"

# =============================================
# Test 6: an unanswerable index is not an empty store
# =============================================
echo ""
echo "Test 6: degraded index and empty result stay distinguishable"

# Nothing in the store matches this branch's terms, and the index is healthy.
EMPTY_REPO="$TEST_DIR/empty-repo"
make_repo "$EMPTY_REPO" "zarquon-frobnicator"
NO_MATCH_OUT=$(run_load "$EMPTY_REPO" "$FACTS_DIR")
assert_contains "an empty result set says so" "$NO_MATCH_OUT" \
  "no entries resolved within budget"

# A store the indexer cannot write is a different observation entirely.
BROKEN_DIR="$TEST_DIR/broken"
bash "$FIXTURE" "$BROKEN_DIR" >/dev/null
chmod -R a-w "$BROKEN_DIR"
BROKEN_OUT=$(run_load "$BASE_REPO" "$BROKEN_DIR")
chmod -R u+w "$BROKEN_DIR"
assert_contains "an unanswerable index says so instead" "$BROKEN_OUT" \
  "no usable search index was available"
assert_not_contains "and is not reported as an empty store" "$BROKEN_OUT" \
  "no entries resolved within budget"

# Both query paths report in the same vocabulary and the explanation reads
# whichever one saw the failure.
DEGRADED_SOURCE=$(grep 'DELIVERY_DEGRADED=' "$LOADER" | head -1)
assert_contains "the section query's degraded signal feeds the explanation" \
  "$DEGRADED_SOURCE" "SECTION_DEGRADED"

# =============================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
