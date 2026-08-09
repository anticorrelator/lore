#!/usr/bin/env bash
# test_kind_retrieval.sh — Pin the read-path behavior that makes the epistemic
# kind field filterable without hiding the store that predates it.
#
#   1. scripts/pk_search.py   — a missing or blank kind resolves to `fact`, and
#                               the resolver returns a plain non-empty string so
#                               a kindless entry can never be a value a filter
#                               drops. This is the inverse of the scale filter's
#                               drop-empty behavior, which sits beside it.
#   2. scripts/pk_search.py   — `expired` is a valid status the default filter
#                               excludes, reachable via include_status.
#   3. scripts/pk_markdown.py — kind and kind_status come off the footer, and
#                               kind_status stays separate from status.
#   4. scripts/capture.sh     — a kind-bearing entry from the real writer
#                               round-trips to a kind-filtered result.
#
# The kindless fixture entries are written by hand so the checks hold whether or
# not the writer emits kind; the hypothesis entry goes through capture.sh so the
# footer under test is the one the writer actually produces.

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
# Three entries share the token "flombulator". Two are hand-written with no kind
# field at all, standing in for the ~1300 entries that predate it; one of those
# is expired. The fourth comes from the writer and carries kind: hypothesis.

setup_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR/conventions/scripting" "$KNOWLEDGE_DIR/gotchas"
  echo '{"format_version": 2}' > "$KNOWLEDGE_DIR/_manifest.json"

  cat > "$KNOWLEDGE_DIR/conventions/scripting/flombulator-drain.md" << 'EOF'
# Flombulator Draining Convention

Drain the flombulator before every batch so the next run starts empty.
<!-- learned: 2026-08-01 | confidence: high | source: interactive | scale: implementation | status: current -->
EOF

  cat > "$KNOWLEDGE_DIR/gotchas/flombulator-blank-kind.md" << 'EOF'
# Flombulator Blank Kind Gotcha

A flombulator footer may carry the kind key with nothing after it.
<!-- learned: 2026-08-02 | confidence: high | source: interactive | scale: implementation | kind:  | status: current -->
EOF

  cat > "$KNOWLEDGE_DIR/gotchas/flombulator-expired.md" << 'EOF'
# Flombulator Zephyrine Timeout

The flombulator zephyrine timeout went a whole quarter without review.
<!-- learned: 2026-02-01 | confidence: high | source: interactive | scale: implementation | status: expired -->
EOF
}

# The writer's own output, not a hand-authored footer: this is what proves the
# capture path and the read path agree on the field names.
write_hypothesis_entry() {
  bash "$SCRIPT_DIR/capture.sh" --kdir "$KNOWLEDGE_DIR" --category gotchas \
    --insight "The flombulator drain may be what starves the zephyrine queue under load." \
    --scale implementation --kind hypothesis --kind-status untested \
    --skip-manifest >/dev/null 2>&1
}

echo "=== Epistemic kind read-path tests ==="
setup_store

# =============================================
# Test 1: the resolver's contract — fact, and a plain string
# =============================================
echo ""
echo "Test 1: a missing or blank kind resolves to fact"

RESOLVE_CHECK=$(python3 - "$SCRIPT_DIR" << 'PY'
import sys
sys.path.insert(0, sys.argv[1])
import pk_search

print("default:%s" % pk_search.DEFAULT_KIND)
for label, value in (("none", None), ("empty", ""), ("blank", "   ")):
    print("%s:%s" % (label, pk_search._resolve_kind(value)))
print("cased:%s" % pk_search._resolve_kind("  Hypothesis  "))

# A kindless entry must resolve to something no filter can treat as absent.
# If this ever returns None, an empty string, or a set, the kind filter has
# silently inherited the scale filter's drop-empty behavior.
resolved = pk_search._resolve_kind(None)
print("is_str:%s" % isinstance(resolved, str))
print("truthy:%s" % bool(resolved))
PY
)
assert_contains "the default kind is fact" "$RESOLVE_CHECK" "default:fact"
assert_contains "a missing kind resolves to fact" "$RESOLVE_CHECK" "none:fact"
assert_contains "an empty kind resolves to fact" "$RESOLVE_CHECK" "empty:fact"
assert_contains "a whitespace-only kind resolves to fact" "$RESOLVE_CHECK" "blank:fact"
assert_contains "a declared kind is lowercased and trimmed" "$RESOLVE_CHECK" "cased:hypothesis"
assert_contains "the resolved kind is a string, not an optional or a set" \
  "$RESOLVE_CHECK" "is_str:True"
assert_contains "the resolved kind is never falsy" "$RESOLVE_CHECK" "truthy:True"

# =============================================
# Test 2: the expired status value and the default filter
# =============================================
echo ""
echo "Test 2: expired is a valid status the default filter excludes"

STATUS_CHECK=$(python3 - "$SCRIPT_DIR" << 'PY'
import sys
sys.path.insert(0, sys.argv[1])
import pk_search
print("valid" if "expired" in pk_search.VALID_STATUS_VALUES else "missing")
print("excluded" if "expired" not in pk_search.DEFAULT_STATUS_FILTER else "included")
print(",".join(pk_search.DEFAULT_STATUS_FILTER))
print("distinct" if "retired" in pk_search.VALID_STATUS_VALUES else "collapsed")
PY
)
assert_eq "expired is a valid status value" "$(echo "$STATUS_CHECK" | sed -n 1p)" "valid"
assert_eq "expired is outside the default filter" "$(echo "$STATUS_CHECK" | sed -n 2p)" "excluded"
assert_eq "the default filter is untouched" "$(echo "$STATUS_CHECK" | sed -n 3p)" "current,corrected"
assert_eq "expired did not replace retired" "$(echo "$STATUS_CHECK" | sed -n 4p)" "distinct"

# =============================================
# Test 3: the footer parser carries both keys, and keeps them apart
# =============================================
echo ""
echo "Test 3: the footer parser returns kind and kind_status"

PARSE_CHECK=$(python3 - "$SCRIPT_DIR" << 'PY'
import sys
sys.path.insert(0, sys.argv[1])
from pk_markdown import MarkdownParser as P

declared = P._extract_metadata(
    "<!-- learned: 2026-08-09 | scale: implementation | kind: hypothesis"
    " | kind_status: untested | status: current -->"
)
print("kind:%s" % declared.get("kind"))
print("kind_status:%s" % declared.get("kind_status"))
print("entry_status:%s" % declared.get("entry_status"))

absent = P._extract_metadata("<!-- learned: 2026-08-09 | status: current -->")
print("absent_kind:%r" % absent.get("kind"))
print("absent_kind_status:%r" % absent.get("kind_status"))

# No metadata comment at all still answers with both keys present.
missing = P._extract_metadata("# Title\n\nBody with no footer.\n")
print("keys_present:%s" % ("kind" in missing and "kind_status" in missing))
PY
)
assert_contains "kind is parsed off the footer" "$PARSE_CHECK" "kind:hypothesis"
assert_contains "kind_status is parsed off the footer" "$PARSE_CHECK" "kind_status:untested"
# kind_status carries the epistemic lifecycle; status carries the entry's own.
assert_contains "kind_status does not overwrite entry status" "$PARSE_CHECK" \
  "entry_status:current"
assert_contains "an absent kind parses as None" "$PARSE_CHECK" "absent_kind:None"
assert_contains "an absent kind_status parses as None" "$PARSE_CHECK" \
  "absent_kind_status:None"
assert_contains "both keys are present with no footer at all" "$PARSE_CHECK" \
  "keys_present:True"

# =============================================
# Test 4: entries with no kind are fully reachable as fact
# =============================================
echo ""
echo "Test 4: a store with no kind field is reachable under kind=fact"

NO_BACKFILL=$(python3 - "$SCRIPT_DIR" "$KNOWLEDGE_DIR" << 'PY'
import sqlite3
import sys
sys.path.insert(0, sys.argv[1])
from pk_search import Searcher
store = sys.argv[2]
s = Searcher(store)

unfiltered = [r["file_path"] for r in s.search("flombulator", limit=10)]
as_fact = [r["file_path"] for r in s.search("flombulator", limit=10, kind="fact")]
print("unfiltered:" + ",".join(unfiltered))
print("as_fact:" + ",".join(as_fact))
print("identical:%s" % (unfiltered == as_fact))
print("count:%d" % len(as_fact))

kinds = {r.get("kind") for r in s.search("flombulator", limit=10, kind="fact")}
statuses = {r.get("kind_status") for r in s.search("flombulator", limit=10, kind="fact")}
print("result_kinds:" + ",".join(sorted(kinds)))
print("result_kind_statuses:%r" % sorted(statuses, key=lambda v: (v is not None, v)))

# Nothing is written back to the entries: the fact default is resolved when a
# row is read, so no stored kind ever reads "fact". An absent key indexes as
# NULL; a key present with an empty value indexes as the empty string, and both
# resolve the same way.
conn = sqlite3.connect(store + "/.pk_search.db")
total = conn.execute(
    "SELECT count(*) FROM entries WHERE source_type = 'knowledge'"
).fetchone()[0]
nulls = conn.execute(
    "SELECT count(*) FROM entries WHERE source_type = 'knowledge' AND kind IS NULL"
).fetchone()[0]
backfilled = conn.execute(
    "SELECT count(*) FROM entries WHERE source_type = 'knowledge' AND kind = 'fact'"
).fetchone()[0]
cols = {r[1] for r in conn.execute("PRAGMA table_info(entries)")}
conn.close()
print("stored_fact:%d" % backfilled)
print("null_kinds:%d/%d" % (nulls, total))
print("has_columns:%s" % ({"kind", "kind_status"} <= cols))
PY
)
assert_contains "the kind-filtered result set equals the unfiltered one" "$NO_BACKFILL" \
  "identical:True"
assert_contains "both kindless entries come back" "$NO_BACKFILL" "count:2"
assert_contains "every result reports kind fact" "$NO_BACKFILL" "result_kinds:fact"
assert_contains "a kindless entry has no kind_status" "$NO_BACKFILL" \
  "result_kind_statuses:[None]"
# The blank-kind entry is the one that would break under drop-empty semantics.
assert_contains "an entry whose kind key is present but empty is still reachable" \
  "$NO_BACKFILL" "gotchas/flombulator-blank-kind.md"
assert_contains "no stored kind reads fact — the default is never written back" \
  "$NO_BACKFILL" "stored_fact:0"
# The third fixture entry is the expired one, also kindless: two of the three
# have no kind key and index as NULL, while the blank-value one indexes as "".
assert_contains "an entry with no kind key indexes as NULL" "$NO_BACKFILL" \
  "null_kinds:2/3"
assert_contains "the index carries both new columns" "$NO_BACKFILL" "has_columns:True"

# =============================================
# Test 5: an expired entry is opt-in, not default-visible
# =============================================
echo ""
echo "Test 5: status expired is absent by default and present on request"

EXPIRED_CHECK=$(python3 - "$SCRIPT_DIR" "$KNOWLEDGE_DIR" << 'PY'
import sys
sys.path.insert(0, sys.argv[1])
from pk_search import Searcher
s = Searcher(sys.argv[2])

default_hits = s.search("flombulator", limit=10)
print("default_paths:" + ",".join(sorted(r["file_path"] for r in default_hits)))
print("default_withheld:%d" % s.last_status_excluded.get("expired", 0))

opt_in = s.search("flombulator", limit=10,
                  include_status=["current", "corrected", "expired"])
print("optin_paths:" + ",".join(sorted(r["file_path"] for r in opt_in)))
print("optin_withheld:%d" % s.last_status_excluded.get("expired", 0))

# The two filters compose: an expired entry with no kind is a fact.
both = s.search("flombulator", limit=10, kind="fact",
                include_status=["current", "corrected", "expired"])
print("kind_and_status:" + ",".join(sorted(r["file_path"] for r in both)))
PY
)
assert_not_contains "an expired entry is absent from an unfiltered search" \
  "$(echo "$EXPIRED_CHECK" | sed -n 1p)" "flombulator-expired.md"
assert_contains "the withheld count lands on the Searcher" "$EXPIRED_CHECK" \
  "default_withheld:1"
assert_contains "an explicit status request reaches it" "$EXPIRED_CHECK" \
  "optin_paths:conventions/scripting/flombulator-drain.md,gotchas/flombulator-blank-kind.md,gotchas/flombulator-expired.md"
assert_contains "nothing is withheld once expired is asked for" "$EXPIRED_CHECK" \
  "optin_withheld:0"
assert_contains "an expired entry with no kind is still a fact" "$EXPIRED_CHECK" \
  "kind_and_status:conventions/scripting/flombulator-drain.md,gotchas/flombulator-blank-kind.md,gotchas/flombulator-expired.md"

# =============================================
# Test 6: a writer-produced kind round-trips to a filtered result
# =============================================
echo ""
echo "Test 6: a captured hypothesis round-trips through the filter"

write_hypothesis_entry
HYPOTHESIS_FILE=$(grep -rl "kind: hypothesis" "$KNOWLEDGE_DIR/gotchas" || true)
if [[ -n "$HYPOTHESIS_FILE" ]]; then
  echo "  PASS: the writer produced a kind-bearing entry"
  PASS=$((PASS + 1))
else
  echo "  FAIL: the writer produced a kind-bearing entry"
  echo "    No entry under $KNOWLEDGE_DIR/gotchas carries 'kind: hypothesis'"
  FAIL=$((FAIL + 1))
fi

ROUNDTRIP=$(python3 - "$SCRIPT_DIR" "$KNOWLEDGE_DIR" << 'PY'
import sys
sys.path.insert(0, sys.argv[1])
from pk_search import Searcher
s = Searcher(sys.argv[2])

hits = s.search("flombulator", limit=10, kind="hypothesis")
print("paths:" + ",".join(sorted(r["file_path"] for r in hits)))
for r in hits:
    print("kind:%s|kind_status:%s|entry_status:%s" % (
        r.get("kind"), r.get("kind_status"), r.get("entry_status")))

facts = [r["file_path"] for r in s.search("flombulator", limit=10, kind="fact")]
print("in_fact_results:%s" % any("starves" in p for p in facts))

several = s.search("flombulator", limit=10, kind=["fact", "hypothesis"])
print("several:%d" % len(several))
print("unmatched:%d" % len(s.search("flombulator", limit=10, kind="question")))
PY
)
assert_contains "a kind=hypothesis search returns the captured entry" "$ROUNDTRIP" \
  "starves"
assert_contains "the result carries the captured kind and lifecycle" "$ROUNDTRIP" \
  "kind:hypothesis|kind_status:untested|entry_status:current"
assert_contains "a hypothesis is not returned as a fact" "$ROUNDTRIP" \
  "in_fact_results:False"
assert_contains "several kinds can be requested at once" "$ROUNDTRIP" "several:3"
assert_contains "an unrepresented kind returns nothing" "$ROUNDTRIP" "unmatched:0"

# =============================================
# Test 7: the schema version bump that carries the columns
# =============================================
echo ""
echo "Test 7: the index reports the schema version that added the columns"

VERSION_CHECK=$(python3 - "$SCRIPT_DIR" "$KNOWLEDGE_DIR" << 'PY'
import sqlite3
import sys
sys.path.insert(0, sys.argv[1])
from pk_search import Indexer
conn = sqlite3.connect(sys.argv[2] + "/.pk_search.db")
stored = conn.execute(
    "SELECT value FROM index_meta WHERE key = 'schema_version'"
).fetchone()[0]
conn.close()
print("matches:%s" % (int(stored) == Indexer.SCHEMA_VERSION))
print("at_least:%s" % (Indexer.SCHEMA_VERSION >= 12))
PY
)
assert_contains "the built index matches the declared schema version" "$VERSION_CHECK" \
  "matches:True"
assert_contains "the version is at or past the one that added kind" "$VERSION_CHECK" \
  "at_least:True"

# =============================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
