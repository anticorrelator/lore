#!/usr/bin/env bash
# test_kind_sections.sh — Pin the read-path column and the section engine that
# deliver non-fact knowledge alongside the ranked fact list.
#
#   1. scripts/pk_search.py   — subsystem is parsed, indexed, selected, and
#                               returned; the schema version that carries it
#                               matches the built index.
#   2. scripts/pk_search.py   — _resolve_subsystem keeps None where its
#                               neighbour _resolve_kind coalesces, pinned by
#                               value and by return shape and proved by
#                               mutating the resolver.
#   3. scripts/pk_kinds.py    — the theory section holds one entry per distinct
#                               subsystem, questions admit only `open`, and
#                               hypotheses exclude `refuted` — while all of them
#                               stay reachable by a direct kind-filtered search.
#   4. scripts/pk_kinds.py    — the presence probe gates the whole path: on a
#                               store with no non-fact entry the engine issues
#                               no search at all, which the retrieval log shows.
#   5. scripts/pk_kinds.py    — sections degrade full -> snippet -> backlink
#                               inside their slice and hand back every char they
#                               did not spend.
#
# The store comes from tests/fixtures/make-epistemic-store.sh --scaled, whose
# twelve short fact entries outrank the long non-fact ones — so the starvation
# the sections answer is observed here, not assumed.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_DIR/scripts"
FIXTURE="$REPO_DIR/tests/fixtures/make-epistemic-store.sh"
TEST_DIR=$(mktemp -d)
SCALED_DIR="$TEST_DIR/scaled"
FACTS_DIR="$TEST_DIR/facts-only"

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

echo "=== Kind section delivery tests ==="
bash "$FIXTURE" "$SCALED_DIR" --scaled >/dev/null

# =============================================
# Test 1: subsystem reaches the read path end to end
# =============================================
echo ""
echo "Test 1: subsystem is parsed, indexed, and returned"

COLUMN_CHECK=$(python3 - "$SCRIPT_DIR" "$SCALED_DIR" << 'PY'
import sqlite3
import sys
sys.path.insert(0, sys.argv[1])
from pk_markdown import MarkdownParser as P
from pk_search import Indexer, Searcher

declared = P._extract_metadata(
    "<!-- learned: 2026-08-09 | scale: subsystem | kind: theory"
    " | subsystem: quillon-router | status: current -->"
)
print("declared:%s" % declared.get("subsystem"))
absent = P._extract_metadata("<!-- learned: 2026-08-09 | status: current -->")
print("absent:%r" % absent.get("subsystem"))
missing = P._extract_metadata("# Title\n\nBody with no footer.\n")
print("key_present:%s" % ("subsystem" in missing))

s = Searcher(sys.argv[2])
theories = {r["file_path"]: r["subsystem"] for r in s.search("quillon", limit=20, kind="theory")}
print("theory_count:%d" % len(theories))
print("subsystems:%s" % ",".join(sorted(set(theories.values()))))
facts = s.search("quillon", limit=5, kind="fact")
print("fact_subsystem:%r" % facts[0]["subsystem"])
print("fact_has_key:%s" % ("subsystem" in facts[0]))

conn = sqlite3.connect(sys.argv[2] + "/.pk_search.db")
cols = {r[1] for r in conn.execute("PRAGMA table_info(entries)")}
stored = conn.execute(
    "SELECT value FROM index_meta WHERE key = 'schema_version'"
).fetchone()[0]
conn.close()
print("has_column:%s" % ("subsystem" in cols))
print("version_matches:%s" % (int(stored) == Indexer.SCHEMA_VERSION))
print("version_bumped:%s" % (Indexer.SCHEMA_VERSION >= 13))
PY
)
assert_contains "a declared subsystem is parsed off the footer" "$COLUMN_CHECK" \
  "declared:quillon-router"
assert_contains "an absent subsystem parses as None" "$COLUMN_CHECK" "absent:None"
assert_contains "the key is present with no footer at all" "$COLUMN_CHECK" \
  "key_present:True"
assert_contains "the index carries the new column" "$COLUMN_CHECK" "has_column:True"
assert_contains "the built index matches the declared schema version" "$COLUMN_CHECK" \
  "version_matches:True"
assert_contains "the schema version was bumped for the column" "$COLUMN_CHECK" \
  "version_bumped:True"
assert_contains "every fixture theory carries its subsystem" "$COLUMN_CHECK" \
  "theory_count:4"
assert_contains "both fixture subsystems come back" "$COLUMN_CHECK" \
  "subsystems:quillon-cache,quillon-router"
assert_contains "a fact result carries the key with no value" "$COLUMN_CHECK" \
  "fact_subsystem:None"
assert_contains "the key is on every result, not only theories" "$COLUMN_CHECK" \
  "fact_has_key:True"

# =============================================
# Test 2: the divergent read-time default, and the mutation that proves it
# =============================================
echo ""
echo "Test 2: a missing subsystem stays None where a missing kind becomes fact"

# _resolve_kind coalesces because most of the store predates the kind field.
# _resolve_subsystem must not: only theory declares a subsystem, and a
# coalesced sentinel would put every other entry in one shared bucket — which
# is exactly the bucket the theory section is bounded on. The mutation below
# is that generalization, applied on purpose to show the pin catches it.
DIVERGENCE=$(python3 - "$SCRIPT_DIR" "$SCALED_DIR" << 'PY'
import sys
sys.path.insert(0, sys.argv[1])
import pk_search
from pk_search import Searcher

def value_pin():
    r = pk_search._resolve_subsystem
    return (r(None) is None and r("") is None and r("   ") is None
            and r(" Quillon-Router ") == "quillon-router")

def shape_pin():
    r = pk_search._resolve_subsystem
    values = [r(None), r(""), r("   "), r("x")]
    optional_str = all(v is None or isinstance(v, str) for v in values)
    never_empty_string = all(v != "" for v in values)
    absent_is_falsy = not r(None)
    return optional_str and never_empty_string and absent_is_falsy

def delivery_pin():
    s = Searcher(sys.argv[2])
    return all(r["subsystem"] is None for r in s.search("quillon", limit=5, kind="fact"))

print("value:%s" % value_pin())
print("shape:%s" % shape_pin())
print("delivery:%s" % delivery_pin())
print("kind_never_falsy:%s" % bool(pk_search._resolve_kind(None)))

# Mutation: the neighbouring coalesce-to-a-default form.
def mutated(value):
    if value is None:
        return "unknown"
    stripped = value.strip().lower()
    return stripped if stripped else "unknown"

pk_search._resolve_subsystem = mutated
print("mutated_value:%s" % value_pin())
print("mutated_shape:%s" % shape_pin())
print("mutated_delivery:%s" % delivery_pin())
PY
)
assert_contains "a missing subsystem resolves to None" "$DIVERGENCE" "value:True"
assert_contains "the resolver returns an optional string, never an empty one" \
  "$DIVERGENCE" "shape:True"
assert_contains "a fact result reports no subsystem" "$DIVERGENCE" "delivery:True"
assert_contains "the neighbouring kind resolver still never returns falsy" \
  "$DIVERGENCE" "kind_never_falsy:True"
assert_contains "coalescing the resolver breaks the value assertion" "$DIVERGENCE" \
  "mutated_value:False"
assert_contains "coalescing the resolver breaks the shape assertion" "$DIVERGENCE" \
  "mutated_shape:False"
assert_contains "coalescing the resolver puts every entry in a named subsystem" \
  "$DIVERGENCE" "mutated_delivery:False"

# =============================================
# Test 3: an unsectioned ranked list starves the non-fact kinds
# =============================================
echo ""
echo "Test 3: the ranked list is all fact; the sections carry the rest"

STARVATION=$(python3 - "$SCRIPT_DIR" "$SCALED_DIR" << 'PY'
import sys
sys.path.insert(0, sys.argv[1])
import pk_kinds
from pk_search import Searcher
s = Searcher(sys.argv[2])

ranked = s.search("quillon", limit=10)
print("ranked_count:%d" % len(ranked))
print("ranked_kinds:%s" % ",".join(sorted({r["kind"] for r in ranked})))

result = pk_kinds.build_sections(s, "quillon", 12000)
print("section_kinds:%s" % ",".join(sec["kind"] for sec in result["sections"]))
print("searches:%d" % result["searches"])
PY
)
assert_contains "the default page is full" "$STARVATION" "ranked_count:10"
assert_contains "nothing but facts survives a single ranking" "$STARVATION" \
  "ranked_kinds:fact"
assert_contains "the sections deliver the three non-fact kinds in order" \
  "$STARVATION" "section_kinds:theory,question,hypothesis"
assert_contains "one query per section, and no more" "$STARVATION" "searches:3"

# =============================================
# Test 4: one theory per distinct subsystem
# =============================================
echo ""
echo "Test 4: three theories share a subsystem and one of them is delivered"

THEORY=$(python3 - "$SCRIPT_DIR" "$SCALED_DIR" << 'PY'
import sys
sys.path.insert(0, sys.argv[1])
import pk_kinds
from pk_search import Searcher
s = Searcher(sys.argv[2])

matched = s.search("quillon", limit=20, kind="theory")
print("matched:%d" % len(matched))
print("router_matched:%d" % sum(1 for r in matched if r["subsystem"] == "quillon-router"))

section = pk_kinds.build_sections(s, "quillon", 12000)["sections"][0]
subsystems = [e["subsystem"] for e in section["served_entries"]]
print("served:%d" % len(subsystems))
print("subsystems:%s" % ",".join(sorted(subsystems)))
print("distinct:%s" % (len(set(subsystems)) == len(subsystems)))
PY
)
assert_contains "all four theories match the query" "$THEORY" "matched:4"
assert_contains "three of them share one subsystem" "$THEORY" "router_matched:3"
assert_contains "the section delivers two theories" "$THEORY" "served:2"
assert_contains "one per distinct subsystem" "$THEORY" \
  "subsystems:quillon-cache,quillon-router"
assert_contains "no subsystem appears twice" "$THEORY" "distinct:True"

# =============================================
# Test 5: kind_status gates delivery without gating reachability
# =============================================
echo ""
echo "Test 5: a refuted hypothesis and an answered question stay findable"

GATING=$(python3 - "$SCRIPT_DIR" "$SCALED_DIR" << 'PY'
import sys
sys.path.insert(0, sys.argv[1])
import pk_kinds
from pk_search import DEFAULT_STATUS_FILTER, Searcher
s = Searcher(sys.argv[2])

result = pk_kinds.build_sections(s, "quillon", 12000)
delivered = set(pk_kinds.served_paths_from(result))
print("delivered:%s" % ",".join(sorted(delivered)))

questions = {r["kind_status"]: r["file_path"]
             for r in s.search("quillon", limit=20, kind="question")}
hypotheses = {r["kind_status"]: r["file_path"]
              for r in s.search("quillon", limit=20, kind="hypothesis")}
print("question_statuses:%s" % ",".join(sorted(questions)))
print("hypothesis_statuses:%s" % ",".join(sorted(hypotheses)))
print("answered_findable:%s" % ("answered" in questions))
print("refuted_findable:%s" % ("refuted" in hypotheses))
print("answered_delivered:%s" % (questions["answered"] in delivered))
print("dissolved_delivered:%s" % (questions["dissolved"] in delivered))
print("refuted_delivered:%s" % (hypotheses["refuted"] in delivered))
print("open_delivered:%s" % (questions["open"] in delivered))
print("untested_delivered:%s" % (hypotheses["untested"] in delivered))
print("supported_delivered:%s" % (hypotheses["supported"] in delivered))

# The epistemic rule never reaches the entry-status filter.
print("status_filter:%s" % ",".join(DEFAULT_STATUS_FILTER))
print("labels_shown:%s" % all(
    tag in result["text"] for tag in ("[open]", "[untested]", "[supported]")))
PY
)
assert_contains "an answered question is still returned by a kind search" "$GATING" \
  "answered_findable:True"
assert_contains "a refuted hypothesis is still returned by a kind search" "$GATING" \
  "refuted_findable:True"
assert_contains "an answered question is not delivered" "$GATING" \
  "answered_delivered:False"
assert_contains "a dissolved question is not delivered" "$GATING" \
  "dissolved_delivered:False"
assert_contains "a refuted hypothesis is not delivered" "$GATING" \
  "refuted_delivered:False"
assert_contains "an open question is delivered" "$GATING" "open_delivered:True"
assert_contains "an untested hypothesis is delivered" "$GATING" \
  "untested_delivered:True"
assert_contains "a supported hypothesis is delivered" "$GATING" \
  "supported_delivered:True"
assert_eq "the entry-status filter is untouched" \
  "$(echo "$GATING" | sed -n 's/^status_filter://p')" "current,corrected"
assert_contains "every delivered line carries its kind_status" "$GATING" \
  "labels_shown:True"

# =============================================
# Test 6: the presence probe gates the whole path
# =============================================
echo ""
echo "Test 6: a store with no non-fact entry costs zero searches"

mkdir -p "$FACTS_DIR/conventions"
echo '{"format_version": 2}' > "$FACTS_DIR/_manifest.json"
cat > "$FACTS_DIR/conventions/quillon-only-fact.md" << 'EOF'
# Quillon Only Fact

The quillon drains before every batch, so the quillon queue starts empty.
<!-- learned: 2026-07-01 | confidence: high | source: manual | scale: subsystem | kind: fact | status: current -->
EOF
cat > "$FACTS_DIR/conventions/quillon-legacy-entry.md" << 'EOF'
# Quillon Legacy Entry

An entry written before the kind field existed, about the quillon path.
<!-- learned: 2025-01-01 | confidence: high | source: manual | scale: subsystem | status: current -->
EOF

PROBE=$(SCALED_DIR="$SCALED_DIR" python3 - "$SCRIPT_DIR" "$FACTS_DIR" << 'PY'
import os
import sys
sys.path.insert(0, sys.argv[1])
import pk_kinds
from pk_search import Searcher
store = sys.argv[2]
s = Searcher(store)

# Build the index first so its creation is not mistaken for section traffic.
s.search("warmup", limit=1)
log = os.path.join(store, "_meta", "retrieval-log.jsonl")

def log_lines():
    if not os.path.exists(log):
        return 0
    with open(log, encoding="utf-8") as f:
        return sum(1 for _ in f)

before = log_lines()
print("probe:%s" % pk_kinds.has_non_fact_entries(s))
print("probe_records:%d" % (log_lines() - before))

before = log_lines()
result = pk_kinds.build_sections(s, "quillon", 12000)
print("searches:%d" % result["searches"])
print("section_records:%d" % (log_lines() - before))
print("text_empty:%s" % (result["text"] == ""))
print("sections:%d" % len(result["sections"]))
print("unspent:%d" % result["chars_unspent"])
print("has_non_fact:%s" % result["has_non_fact"])

# The same probe answers yes on the scaled store, so a False here is the
# store's answer and not a broken query.
print("scaled_probe:%s" % pk_kinds.has_non_fact_entries(Searcher(os.environ["SCALED_DIR"])))
PY
)
assert_contains "the probe answers no on a fact-only store" "$PROBE" "probe:False"
assert_contains "the probe writes no retrieval-log record" "$PROBE" "probe_records:0"
assert_contains "the engine issues no search" "$PROBE" "searches:0"
assert_contains "the retrieval log gains nothing for the section path" "$PROBE" \
  "section_records:0"
assert_contains "no text is produced" "$PROBE" "text_empty:True"
assert_contains "no section record is produced" "$PROBE" "sections:0"
assert_contains "the whole reservation goes back to the caller" "$PROBE" \
  "unspent:12000"
assert_contains "the result reports why it is empty" "$PROBE" "has_non_fact:False"
assert_contains "the same probe answers yes where non-fact entries exist" "$PROBE" \
  "scaled_probe:True"

# =============================================
# Test 7: degradation inside the slice, and the unspent remainder
# =============================================
echo ""
echo "Test 7: sections degrade in place and return what they did not spend"

BUDGET=$(python3 - "$SCRIPT_DIR" "$SCALED_DIR" << 'PY'
import sys
sys.path.insert(0, sys.argv[1])
import pk_kinds
from pk_search import Searcher
s = Searcher(sys.argv[2])

modes = set()
arithmetic_holds = True
never_overspends = True
no_empty_header = True
for reserve in (12000, 6000, 4000, 3000, 2400, 2000, 1500, 1000, 600, 400, 200):
    r = pk_kinds.build_sections(s, "quillon", reserve)
    if r["chars_unspent"] != reserve - len(r["text"]):
        arithmetic_holds = False
    if r["chars_used"] != len(r["text"]) or r["chars_used"] > reserve:
        never_overspends = False
    for sec in r["sections"]:
        for mode, count in sec["render_mode_counts"].items():
            if count:
                modes.add(mode)
        if sec["served_count"] == 0:
            no_empty_header = False
print("modes:%s" % ",".join(sorted(modes)))
print("arithmetic:%s" % arithmetic_holds)
print("within_reserve:%s" % never_overspends)
print("no_empty_section:%s" % no_empty_header)

roomy = pk_kinds.build_sections(s, "quillon", 12000)
print("roomy_degraded:%s" % any(sec["content_degraded"] for sec in roomy["sections"]))
print("roomy_shrunk:%s" % any(sec["shrunk_for_budget"] for sec in roomy["sections"]))

# One run where the two flags disagree across sections: theory loses an entry
# it had selected, the hypothesis section only renders its entries smaller.
tight = {sec["kind"]: sec for sec in pk_kinds.build_sections(s, "quillon", 600)["sections"]}
print("theory_degraded:%s" % tight["theory"]["content_degraded"])
print("theory_shrunk:%s" % tight["theory"]["shrunk_for_budget"])
print("theory_selected:%d" % tight["theory"]["entry_count_before_budget"])
print("theory_served:%d" % tight["theory"]["served_count"])
print("hypothesis_degraded:%s" % tight["hypothesis"]["content_degraded"])
print("hypothesis_shrunk:%s" % tight["hypothesis"]["shrunk_for_budget"])

# A section whose only candidate the caller already served contributes nothing.
open_question = [r["file_path"] for r in s.search("quillon", limit=20, kind="question")
                 if r["kind_status"] == "open"]
served = pk_kinds.build_sections(s, "quillon", 12000, served_paths=open_question)
print("kinds_after_dedupe:%s" % ",".join(sec["kind"] for sec in served["sections"]))
print("question_header:%s" % ("Open questions" in served["text"]))
print("no_blank_run:%s" % ("\n\n\n" not in served["text"]))
PY
)
assert_contains "all three render modes are reached across the sweep" "$BUDGET" \
  "modes:backlink,full,snippet"
assert_contains "the unspent count is the reservation minus the rendered size" \
  "$BUDGET" "arithmetic:True"
assert_contains "no run exceeds its reservation" "$BUDGET" "within_reserve:True"
assert_contains "no section is recorded with nothing in it" "$BUDGET" \
  "no_empty_section:True"
assert_contains "a roomy reservation degrades nothing" "$BUDGET" \
  "roomy_degraded:False"
assert_contains "a roomy reservation drops nothing" "$BUDGET" "roomy_shrunk:False"
assert_contains "a tight slice degrades the theory section" "$BUDGET" \
  "theory_degraded:True"
assert_contains "and costs it a selected entry" "$BUDGET" "theory_shrunk:True"
assert_contains "the theory section had selected two" "$BUDGET" "theory_selected:2"
assert_contains "and served one" "$BUDGET" "theory_served:1"
assert_contains "the hypothesis section degrades in the same run" "$BUDGET" \
  "hypothesis_degraded:True"
assert_contains "without losing an entry — the two flags are independent" \
  "$BUDGET" "hypothesis_shrunk:False"
assert_contains "a section deduped down to nothing is not rendered" "$BUDGET" \
  "kinds_after_dedupe:theory,hypothesis"
assert_contains "and leaves no header behind" "$BUDGET" "question_header:False"
assert_contains "and no blank run where it would have been" "$BUDGET" \
  "no_blank_run:True"

# =============================================
# Test 8: the candidate window is sized so facts cannot bury a section
# =============================================
echo ""
echo "Test 8: a theory buried under sixty dense facts is still delivered"

# The kind filter runs after SQL has cut to the top-ranked rows, so a section
# only ever chooses from a window of the ranking. Sixty facts repeating the
# query terms against one theory that mentions them once is the shape that
# fills that window — the starvation the sections exist to prevent, one level
# down. Built here rather than in the shared fixture: two sibling suites read
# that fixture and its entry counts are theirs as much as ours.
DENSE_DIR="$TEST_DIR/dense"
mkdir -p "$DENSE_DIR/conventions"
echo '{"format_version": 2}' > "$DENSE_DIR/_manifest.json"
for n in $(seq -w 1 60); do
  printf '# Widget Fact %s\nThe widget cache drains the widget buffer so widget batch %s leaves the widget queue empty.\n<!-- learned: 2026-07-01 | confidence: high | source: manual | scale: subsystem | kind: fact | status: current -->\n' \
    "$n" "$n" > "$DENSE_DIR/conventions/widget-fact-$n.md"
done
printf '# Widget Theory\nAn account of how this area fits together, covering the widget path end to end and naming why the design settled where it did rather than on the alternatives set aside.\n<!-- learned: 2026-07-02 | confidence: high | source: manual | scale: subsystem | kind: theory | subsystem: widget-cache | status: current -->\n' \
  > "$DENSE_DIR/conventions/widget-theory.md"

WINDOW=$(python3 - "$SCRIPT_DIR" "$DENSE_DIR" "$SCALED_DIR" << 'PY'
import sys
sys.path.insert(0, sys.argv[1])
import pk_kinds
from pk_search import Searcher
s = Searcher(sys.argv[2])

# The window is a property of the store, so its sizing is checked directly:
# a floor for small stores, ceil(rows / SEARCH_OVERFETCH) while that spans the
# ranked list, then a ceiling.
print("floor:%d" % pk_kinds.candidate_limit(8))
print("scaled:%d" % pk_kinds.candidate_limit(1359))
print("spans:%s" % (pk_kinds.candidate_limit(1359) * pk_kinds.SEARCH_OVERFETCH >= 1359))
print("ceiling:%d" % pk_kinds.candidate_limit(10 ** 6))

# Before any index exists the count is unavailable, and sizing falls to the
# floor rather than failing. It must not leave an empty database behind either:
# _ensure_index serves from any file that exists, so a stray one would suppress
# the real build.
import os
print("cold_rows:%d" % pk_kinds.indexed_row_count(s))
print("cold_no_db:%s" % (not os.path.exists(s.db_path)))

s.search("warmup", limit=1)
print("rows:%d" % pk_kinds.indexed_row_count(s))

# The count is taken under the same source_type restriction the search will
# apply. Work items and threads share the entries table and outnumber knowledge
# several times over on a real store, so sizing against the wrong population
# either overshoots or — the failure that matters — comes up short. An
# unrecognised source_type falls back to the whole index, matching how
# Searcher.search ignores one it does not know.
print("knowledge_rows:%d" % pk_kinds.indexed_row_count(s, "knowledge"))
print("bogus_falls_back:%s" % (
    pk_kinds.indexed_row_count(s, "nonsense") == pk_kinds.indexed_row_count(s)))

# The old sizing asked for cap * 5 = 10 for theory. That window is blind to the
# theory here, which is the defect this test exists to catch.
print("old_window_hits:%d" % len(s.search("widget cache", limit=10, kind="theory")))
print("sized_window_hits:%d" % len(
    s.search("widget cache", limit=pk_kinds.candidate_limit(pk_kinds.indexed_row_count(s)),
             kind="theory")))

result = pk_kinds.build_sections(s, "widget cache", 12000)
print("delivered:%s" % ",".join(sec["kind"] for sec in result["sections"]))
print("theory_served:%d" % sum(
    sec["served_count"] for sec in result["sections"] if sec["kind"] == "theory"))

# Discrimination: pin the old constant back and the same assertion fails, so
# this test would have caught the defect rather than passing either way.
real = pk_kinds.candidate_limit
pk_kinds.candidate_limit = lambda row_count: 10
starved = pk_kinds.build_sections(s, "widget cache", 12000)
print("old_delivered:%d" % len(starved["sections"]))
print("old_text_empty:%s" % (starved["text"] == ""))

# The residual, tested rather than asserted: the window spans the ranking only
# up to the ceiling. Past that a dense enough single-topic corpus buries the
# section again, which is what the ceiling costs.
pk_kinds.candidate_limit = lambda row_count: max(1, min(real(row_count), 3))
past_ceiling = pk_kinds.build_sections(s, "widget cache", 12000)
print("past_ceiling_delivered:%d" % len(past_ceiling["sections"]))
pk_kinds.candidate_limit = real

# Widening what is considered must not widen what is delivered.
print("caps:%s" % ",".join(
    "%s=%d" % (spec.kind, spec.cap) for spec in pk_kinds.SECTION_SPECS))
scaled = pk_kinds.build_sections(Searcher(sys.argv[3]), "quillon", 12000)
print("scaled_served:%s" % ",".join(
    "%s=%d" % (sec["kind"], sec["served_count"]) for sec in scaled["sections"]))
PY
)
assert_contains "a small store still over-fetches to its floor" "$WINDOW" "floor:10"
assert_contains "the window scales with the row count" "$WINDOW" "scaled:453"
assert_contains "and spans the whole ranked list at that size" "$WINDOW" "spans:True"
assert_contains "the window is bounded" "$WINDOW" "ceiling:4000"
assert_contains "a store with no index sizes to the floor" "$WINDOW" "cold_rows:0"
assert_contains "and no empty database is left behind" "$WINDOW" "cold_no_db:True"
assert_contains "the dense store holds sixty facts and one theory" "$WINDOW" "rows:61"
assert_contains "the count narrows with the caller's source_type" "$WINDOW" \
  "knowledge_rows:61"
assert_contains "an unknown source_type counts the whole index" "$WINDOW" \
  "bogus_falls_back:True"
assert_contains "the old window could not see the theory at all" "$WINDOW" \
  "old_window_hits:0"
assert_contains "the sized window finds it" "$WINDOW" "sized_window_hits:1"
assert_contains "the theory section is delivered" "$WINDOW" "delivered:theory"
assert_contains "carrying the buried theory" "$WINDOW" "theory_served:1"
assert_contains "the old constant delivers nothing here" "$WINDOW" "old_delivered:0"
assert_contains "and renders no text — the defect this test catches" "$WINDOW" \
  "old_text_empty:True"
assert_contains "a window narrower than the ranking starves the section again" \
  "$WINDOW" "past_ceiling_delivered:0"
assert_contains "the delivered caps are unchanged" "$WINDOW" \
  "caps:theory=2,question=3,hypothesis=3"
assert_contains "and what a store actually serves is unchanged" "$WINDOW" \
  "scaled_served:theory=2,question=1,hypothesis=2"

# =============================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
