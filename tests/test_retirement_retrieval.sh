#!/usr/bin/env bash
# test_retirement_retrieval.sh — Pin the four read-path call sites that make
# entry retirement visible, reversible, and cheap to notice.
#
#   1. scripts/pk_search.py     — `retired` is a valid status, excluded from the
#                                 default filter, reachable via include_status,
#                                 and counted on the Searcher.
#   2. scripts/pk_cli.py        — default `search` and `prefetch` report how many
#                                 matches retirement withheld and name the flag.
#   3. scripts/generate-index.sh — retired entries stay listed, annotated with
#                                 their retirement date.
#   4. scripts/load-knowledge.sh — the session-start stale scan leaves retired
#                                 entries off the review list.
#
# The fixture store is built by hand: retired entries are written with
# `status: retired` in their META block directly, so these checks hold whether
# or not the `lore retire` write path is on disk.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_DIR/scripts"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"

PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
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

# --- Fixture -----------------------------------------------------------------
# Two entries share the token "flombulator" so a default search matches both and
# returns one; "zephyrine" belongs to the retired entry alone, so a search for it
# returns nothing at all and the notice is the only thing a searcher gets back.

RETIREMENT_META='status: retired | retirements: [{"date": "2026-08-06", "retirement_id": "ret-a1b2c3d4e5f6", "reason": "The flombulator queue it describes was deleted.", "falsifier": "A surviving caller of the flombulator queue.", "prior_status": "current"}]'

setup_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR/conventions/scripting"
  echo '{"format_version": 2}' > "$KNOWLEDGE_DIR/_manifest.json"

  cat > "$KNOWLEDGE_DIR/conventions/scripting/flombulator-live.md" << 'EOF'
# Flombulator Draining Convention

Drain the flombulator before every batch so the next run starts empty.
<!-- learned: 2026-08-01 | confidence: high | source: interactive | scale: implementation | status: current -->
EOF

  cat > "$KNOWLEDGE_DIR/conventions/scripting/flombulator-retired.md" << EOF
# Flombulator Zephyrine Handshake

The flombulator zephyrine handshake ran before every drain.
<!-- learned: 2026-05-02 | confidence: high | source: interactive | scale: implementation | $RETIREMENT_META -->
EOF
}

run_search() {
  python3 "$SCRIPT_DIR/pk_cli.py" search "$KNOWLEDGE_DIR" "$@"
}

echo "=== Retirement read-path tests ==="
setup_store

# =============================================
# Test 1: pk_search.py — the status value and the default filter
# =============================================
echo ""
echo "Test 1: retired is a valid status the default filter excludes"

STATUS_CHECK=$(python3 - "$SCRIPT_DIR" << 'PY'
import sys
sys.path.insert(0, sys.argv[1])
import pk_search
print("valid" if "retired" in pk_search.VALID_STATUS_VALUES else "missing")
print("excluded" if "retired" not in pk_search.DEFAULT_STATUS_FILTER else "included")
print(",".join(pk_search.DEFAULT_STATUS_FILTER))
PY
)
assert_eq "retired is a valid status value" "$(echo "$STATUS_CHECK" | sed -n 1p)" "valid"
assert_eq "retired is outside the default filter" "$(echo "$STATUS_CHECK" | sed -n 2p)" "excluded"
assert_eq "the default filter is untouched" "$(echo "$STATUS_CHECK" | sed -n 3p)" "current,corrected"

# =============================================
# Test 2: pk_search.py — the withheld count rides on the Searcher
# =============================================
echo ""
echo "Test 2: search() records what the status filter withheld"

COUNT_CHECK=$(python3 - "$SCRIPT_DIR" "$KNOWLEDGE_DIR" << 'PY'
import sys
sys.path.insert(0, sys.argv[1])
from pk_search import Searcher

searcher = Searcher(sys.argv[2])

default_hits = searcher.search("flombulator", limit=10)
print("default_paths:" + ",".join(sorted(r["file_path"] for r in default_hits)))
print("default_withheld:%d" % searcher.last_status_excluded.get("retired", 0))
print("return_type:%s" % type(default_hits).__name__)

opt_in_hits = searcher.search(
    "flombulator", limit=10, include_status=["current", "corrected", "retired"]
)
print("optin_paths:" + ",".join(sorted(r["file_path"] for r in opt_in_hits)))
print("optin_withheld:%d" % searcher.last_status_excluded.get("retired", 0))
PY
)
assert_contains "default search returns the live entry" "$COUNT_CHECK" \
  "default_paths:conventions/scripting/flombulator-live.md"
assert_not_contains "default search does not return the retired entry" \
  "$(echo "$COUNT_CHECK" | sed -n 1p)" "flombulator-retired.md"
assert_contains "the withheld count lands on the Searcher" "$COUNT_CHECK" \
  "default_withheld:1"
assert_contains "search() still returns a list" "$COUNT_CHECK" "return_type:list"
assert_contains "--include-status retired reaches the entry" "$COUNT_CHECK" \
  "optin_paths:conventions/scripting/flombulator-live.md,conventions/scripting/flombulator-retired.md"
assert_contains "nothing is withheld once retired is asked for" "$COUNT_CHECK" \
  "optin_withheld:0"

# =============================================
# Test 3: pk_cli.py — the search notice fires on the default path
# =============================================
echo ""
echo "Test 3: default search reports what retirement withheld"

SEARCH_OUT=$(run_search "flombulator" --limit 5 2>/dev/null)
assert_contains "the notice states the count" "$SEARCH_OUT" "1 matching entry is retired"
assert_contains "the notice names the flag that reaches it" "$SEARCH_OUT" \
  "--include-status retired"
# Colleague register, not a warning: no severity label in front of the line.
assert_not_contains "the notice is not framed as a warning" "$SEARCH_OUT" "Warning:"
assert_not_contains "the notice is not framed as an error" "$SEARCH_OUT" "Error:"

# The notice fires with no flag and no threshold — including when the query
# matched nothing else at all, which is the case that most needs it.
ZERO_OUT=$(run_search "zephyrine" --limit 5 2>/dev/null)
assert_contains "a zero-result search still reports the withholding" "$ZERO_OUT" \
  "--include-status retired"

# Asking for retired entries leaves nothing to report.
OPT_IN_OUT=$(run_search "flombulator" --limit 5 --include-status current --include-status corrected --include-status retired 2>/dev/null)
assert_not_contains "no notice once retired entries are included" "$OPT_IN_OUT" \
  "--include-status retired"
assert_contains "the retired entry is in the opt-in results" "$OPT_IN_OUT" \
  "flombulator-retired.md"

# =============================================
# Test 4: pk_cli.py — --json stdout stays parseable
# =============================================
echo ""
echo "Test 4: the notice keeps off a --json stdout"

JSON_OUT=$(run_search "flombulator" --limit 5 --json 2>/dev/null)
JSON_ERR=$(run_search "flombulator" --limit 5 --json 2>&1 >/dev/null)
if echo "$JSON_OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  echo "  PASS: --json stdout parses as JSON"
  PASS=$((PASS + 1))
else
  echo "  FAIL: --json stdout parses as JSON"
  echo "    Got: $JSON_OUT"
  FAIL=$((FAIL + 1))
fi
assert_contains "the notice moves to stderr under --json" "$JSON_ERR" \
  "--include-status retired"

# =============================================
# Test 5: pk_cli.py — prefetch reports it too
# =============================================
echo ""
echo "Test 5: prefetch reports what retirement withheld"

PREFETCH_OUT=$(python3 "$SCRIPT_DIR/pk_cli.py" prefetch "$KNOWLEDGE_DIR" "flombulator" \
  --scale-set implementation --format summary 2>/dev/null || true)
assert_contains "prefetch names the flag that reaches retired entries" "$PREFETCH_OUT" \
  "--include-status retired"

# The empty-block case: prefetch returns early with no output, and the notice is
# the whole of what a caller gets.
PREFETCH_ZERO=$(python3 "$SCRIPT_DIR/pk_cli.py" prefetch "$KNOWLEDGE_DIR" "zephyrine" \
  --scale-set implementation --format summary 2>/dev/null || true)
assert_contains "an empty prefetch block still carries the notice" "$PREFETCH_ZERO" \
  "--include-status retired"

# =============================================
# Test 6: generate-index.sh — annotate, never hide
# =============================================
echo ""
echo "Test 6: lore index annotates retired entries"

INDEX_OUT=$(LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR" bash "$SCRIPT_DIR/generate-index.sh" "$KNOWLEDGE_DIR" 2>&1)
assert_contains "the retired entry is still listed" "$INDEX_OUT" \
  "**Flombulator Zephyrine Handshake**"
assert_contains "the listing carries the retirement date" "$INDEX_OUT" \
  "**Flombulator Zephyrine Handshake** [retired 2026-08-06]"
assert_contains "its summary still renders" "$INDEX_OUT" \
  "The flombulator zephyrine handshake ran before every drain."
assert_not_contains "a live entry gains no annotation" "$INDEX_OUT" \
  "**Flombulator Draining Convention** [retired"
assert_contains "both entries are counted" "$INDEX_OUT" "## conventions (2 entries)"

# =============================================
# Test 7: load-knowledge.sh — the stale scan skips retired entries
# =============================================
echo ""
echo "Test 7: the session-start stale scan leaves retired entries alone"

# Both legs of the scan: mtime older than the 90-day threshold, and the
# low-confidence grep. A retired entry qualifies for both and appears in neither.
mkdir -p "$KNOWLEDGE_DIR/gotchas"
cat > "$KNOWLEDGE_DIR/gotchas/stale-live.md" << 'EOF'
# Stale Live Gotcha

Untouched for a long time and still in service.
<!-- learned: 2025-01-01 | confidence: high | source: interactive | status: current -->
EOF
cat > "$KNOWLEDGE_DIR/gotchas/stale-retired.md" << EOF
# Stale Retired Gotcha

Untouched for a long time and already dispositioned.
<!-- learned: 2025-01-01 | confidence: high | source: interactive | $RETIREMENT_META -->
EOF
cat > "$KNOWLEDGE_DIR/gotchas/lowconf-live.md" << 'EOF'
# Low Confidence Live Gotcha

Held loosely and still in service.
<!-- learned: 2026-08-01 | confidence: low | source: interactive | status: current -->
EOF
cat > "$KNOWLEDGE_DIR/gotchas/lowconf-retired.md" << EOF
# Low Confidence Retired Gotcha

Held loosely and already dispositioned.
<!-- learned: 2026-08-01 | confidence: low | source: interactive | $RETIREMENT_META -->
EOF

touch -t 202401010000 "$KNOWLEDGE_DIR/gotchas/stale-live.md" \
  "$KNOWLEDGE_DIR/gotchas/stale-retired.md"

LOAD_OUT=$(LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR" bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1 || true)
STALE_LINE=$(echo "$LOAD_OUT" | grep '^\[Stale\]' || true)

assert_contains "an old live entry is still flagged" "$STALE_LINE" "gotchas/stale-live.md"
assert_not_contains "an old retired entry is not flagged" "$STALE_LINE" \
  "gotchas/stale-retired.md"
assert_contains "a low-confidence live entry is still flagged" "$STALE_LINE" \
  "gotchas/lowconf-live.md"
assert_not_contains "a low-confidence retired entry is not flagged" "$STALE_LINE" \
  "gotchas/lowconf-retired.md"
# Category counts answer "how big is the store" — a retired entry is still in it.
assert_contains "retired entries still count toward the store size" "$LOAD_OUT" \
  "**gotchas/** (4 entries)"
assert_contains "the store total counts them too" "$LOAD_OUT" \
  "[knowledge] 6 entries across 2 categories"

# =============================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
