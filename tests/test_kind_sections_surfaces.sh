#!/usr/bin/env bash
# test_kind_sections_surfaces.sh — Tests for the surfaces that append kind
# sections to their own output: the search CLI, and the two agent-prompt
# injectors.
#
# Every check runs the scripts in THIS checkout directly
# (`python3 "$SCRIPT_DIR/pk_cli.py" ...`). Do not reach for the `lore` wrapper:
# it resolves its script directory through the ~/.lore/scripts symlink to the
# installed repo, so a `lore search` here would exercise code this suite is not
# testing and report a result that has nothing to do with the working tree.
#
# Covers, for the search surface:
#   - All three sections render after the ranked result blocks on a store
#     carrying every kind, with kind_status visible on each non-fact line
#   - Section membership follows the kind_status rules: an answered or
#     dissolved question and a refuted hypothesis are not delivered
#   - A section whose candidates the ranked list already served renders
#     nothing at all — no header, no placeholder, no blank run
#   - `--json` alone stays the flat array `tui/internal/knowledge/search.go`
#     decodes, byte-identical even where non-fact entries exist
#   - `--json --kind-sections` is an object carrying results and sections
#   - `--budget`'s two-tier payload is untouched, and asking for sections
#     alongside it is refused rather than silently dropped
#   - On a store with no non-fact entry, stdout and stderr are byte-identical
#     to the same command built from the parent commit
#
# and for the `lore search` wrapper that sits in front of it:
#   - `--kind-sections` reaches pk_cli.py under every `--type` value, and the
#     default `--type all` returns the object rather than crashing its merge
#   - Sections are requested of the knowledge pool alone, so no kind is
#     represented twice in a merged object
#   - The merge concatenates both pools' results while keeping whichever shape
#     the knowledge half returned, and refuses a half it cannot combine
#
# for the prefetch injector:
#   - All three sections render after the entry blocks, and the whole block
#     still fits the prompt ceiling — so the sections were paid for out of the
#     entry budget rather than added on top of it
#   - On a store with no non-fact entry, both formats are byte-identical to the
#     same command built from the parent commit
#
# and for the manifest resolver:
#   - Kind sections render after the `### Focal:` and `### Adjacent:` sections,
#     neither axis nested inside the other
#   - The `<!-- _RM_PATHS=... -->` side channel keeps its literal prefix, suffix
#     and single trailing line, and now names the section entries too
#   - The `manifest_load` record keeps every per-section field it carries today
#     and gains one record per kind section, `content_degraded` and
#     `shrunk_for_budget` still read independently
#   - On a store with no non-fact entry the bundle is byte-identical to the
#     same command built from the parent commit
#
# The byte-identity checks diff against a scripts/ tree assembled from the
# parent commit's copy of the file under test plus the working tree's siblings,
# which isolates this change from the ones already staged around it.

set -uo pipefail

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

# A scripts/ tree whose named files come from the parent commit and whose
# siblings come from the working tree. Prints the directory.
baseline_scripts() {
  local dir="$TEST_DIR/baseline-$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp "$SCRIPT_DIR"/*.py "$dir/"
  local f
  for f in "$@"; do
    git -C "$REPO_DIR" show "HEAD:scripts/$f" > "$dir/$f" 2>/dev/null || {
      echo "  SETUP FAIL: cannot read scripts/$f from the parent commit" >&2
      return 1
    }
  done
  echo "$dir"
}

# Strips every entry carrying a non-fact kind, leaving a store the presence
# probe answers False for — the legacy path each surface must leave unchanged.
make_facts_only_store() {
  local dir="$1"
  bash "$FIXTURE" "$dir" >/dev/null
  rm -f "$dir"/conventions/*hypothesis*.md "$dir"/gotchas/*question*.md
  python3 - "$dir" <<'PY'
import json, os, sys
kdir = sys.argv[1]
path = os.path.join(kdir, "_manifest.json")
with open(path, encoding="utf-8") as f:
    manifest = json.load(f)
manifest["entries"] = [
    e for e in manifest["entries"] if os.path.isfile(os.path.join(kdir, e["path"]))
]
with open(path, "w", encoding="utf-8") as f:
    json.dump(manifest, f)
PY
}

# The scaled store plus a handful of long facts, so a ranked page of facts
# alone overruns the 12000-char prompt ceiling. Without that the ceiling never
# binds and a budget assertion over it proves nothing. The count is kept small
# on purpose: `kind` is filtered after the FTS5 cut, so a store with enough
# facts to fill that cut leaves the section queries nothing to filter.
make_wide_store() {
  local dir="$1" src="$2" i body para
  rm -rf "$dir"
  cp -R "$src" "$dir"
  rm -f "$dir/.pk_search.db"
  para="The quillon router drains the quillon buffer before the quillon cache reads it, so a quillon batch that reaches the quillon queue has already passed the quillon drain. Quillon callers that skip the quillon drain observe a quillon queue the quillon cache has not seen."
  body="$para $para $para $para $para $para $para $para"
  for i in $(seq 20 25); do
    printf '# Quillon Bulk Fact %s\n%s\n%s\n' "$i" "$body" \
      '<!-- learned: 2026-07-01 | confidence: high | source: manual | scale: subsystem | kind: fact | status: current -->' \
      > "$dir/conventions/quillon/quillon-bulk-fact-$i.md"
  done
  python3 - "$dir" <<'PY'
import json, os, sys
kdir = sys.argv[1]
entries = []
for root, dirnames, filenames in os.walk(kdir):
    dirnames[:] = [d for d in dirnames if not d.startswith("_")]
    for name in sorted(filenames):
        if name.endswith(".md"):
            entries.append({"path": os.path.relpath(os.path.join(root, name), kdir),
                            "backlinks": []})
manifest = {"format_version": 2, "entries": sorted(entries, key=lambda e: e["path"])}
with open(os.path.join(kdir, "_manifest.json"), "w", encoding="utf-8") as f:
    json.dump(manifest, f)
PY
}

echo "=== Kind section surface tests ==="
bash "$FIXTURE" "$SCALED_DIR" --scaled >/dev/null
make_facts_only_store "$FACTS_DIR"

# =============================================
# Search surface
# =============================================

# ---------------------------------------------
# Test 1: sections render after the ranked list, labeled and kind_status-visible
# ---------------------------------------------
echo ""
echo "Test 1: the human render appends all three sections"

RENDER=$(python3 "$SCRIPT_DIR/pk_cli.py" search "$SCALED_DIR" quillon \
  --scale-set subsystem --limit 12 2>/dev/null)

assert_contains "the theory section is labeled" "$RENDER" "### Theory"
assert_contains "the question section is labeled" "$RENDER" "### Open questions"
assert_contains "the hypothesis section is labeled" "$RENDER" "### Hypotheses"

# Ordering: every section header falls after the last ranked result block.
printf '%s\n' "$RENDER" > "$TEST_DIR/render.txt"
RENDER_ORDER=$(python3 - "$TEST_DIR/render.txt" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
last_result = text.rfind("--- Result ")
first_section = text.find("\n### ")
print("sections_follow_results:%s" % (last_result < first_section))
print("section_order:%s" % ",".join(
    line[4:] for line in text.splitlines() if line.startswith("### ")))
PY
)
assert_contains "the sections come after the ranked result blocks" "$RENDER_ORDER" \
  "sections_follow_results:True"
assert_contains "and run theory, questions, hypotheses" "$RENDER_ORDER" \
  "section_order:Theory,Open questions,Hypotheses"

assert_contains "an open question carries its kind_status" "$RENDER" \
  "Quillon Question Open [open]"
assert_contains "an untested hypothesis carries its kind_status" "$RENDER" \
  "Quillon Hypothesis Untested [untested]"
assert_contains "a supported hypothesis carries its kind_status" "$RENDER" \
  "Quillon Hypothesis Supported [supported]"
assert_contains "a theory carries the subsystem it accounts for" "$RENDER" \
  "[subsystem: quillon-router]"

# Every line a section renders is labeled — the check is over the rendered
# lines themselves, so a new render mode cannot slip an unlabeled one through.
LABELS=$(python3 - "$TEST_DIR/render.txt" <<'PY'
import re
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.find("\n### ")
lines = text[start:].splitlines() if start >= 0 else []
served = [ln for ln in lines
          if ln.startswith("#### ") or ln.startswith("- [[")]
unlabeled = [ln for ln in served if not re.search(r"\[[^]]+\]\s*(\(from |$)", ln)]
print("served_lines:%d" % len(served))
print("unlabeled:%d" % len(unlabeled))
PY
)
assert_contains "the sections served five entries" "$LABELS" "served_lines:5"
assert_contains "and every one of them is labeled" "$LABELS" "unlabeled:0"

# ---------------------------------------------
# Test 2: kind_status decides membership, and undelivered is not unfindable
# ---------------------------------------------
echo ""
echo "Test 2: the kind_status rules hold at the surface"

assert_not_contains "an answered question is not delivered" "$RENDER" \
  "Quillon Question Answered ["
assert_not_contains "a dissolved question is not delivered" "$RENDER" \
  "Quillon Question Dissolved ["
assert_not_contains "a refuted hypothesis is not delivered" "$RENDER" \
  "Quillon Hypothesis Refuted ["

REFUTED=$(python3 "$SCRIPT_DIR/pk_cli.py" search "$SCALED_DIR" refuted \
  --scale-set subsystem --json 2>/dev/null | python3 -c \
  "import json,sys; print(','.join(r['heading'] for r in json.load(sys.stdin)))")
assert_contains "but a direct search still returns it" "$REFUTED" \
  "Quillon Hypothesis Refuted"

# ---------------------------------------------
# Test 3: an empty section emits nothing at all
# ---------------------------------------------
echo ""
echo "Test 3: a section with nothing to say is silent"

# At this limit the ranked list already carries the only deliverable question,
# so the question section dedupes to empty while the other two still render.
DEDUPED=$(python3 "$SCRIPT_DIR/pk_cli.py" search "$SCALED_DIR" quillon \
  --scale-set subsystem --limit 14 2>/dev/null)
assert_contains "the theory section still renders" "$DEDUPED" "### Theory"
assert_contains "the hypothesis section still renders" "$DEDUPED" "### Hypotheses"
assert_not_contains "the emptied section leaves no header" "$DEDUPED" \
  "### Open questions"

printf '%s\n' "$DEDUPED" > "$TEST_DIR/deduped.txt"
BLANKS=$(python3 - "$TEST_DIR/deduped.txt" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
print("blank_run:%s" % ("\n\n\n" in text))
PY
)
assert_contains "and no blank run where it would have been" "$BLANKS" \
  "blank_run:False"

# Every section empty: no header, and nothing appended after the last result.
ALL_EMPTY=$(python3 "$SCRIPT_DIR/pk_cli.py" search "$SCALED_DIR" quillon \
  --scale-set subsystem --limit 22 2>/dev/null)
assert_not_contains "with every section deduped away, no header appears" \
  "$ALL_EMPTY" "### "

# A query nothing matches keeps its one-line answer.
NO_MATCH=$(python3 "$SCRIPT_DIR/pk_cli.py" search "$SCALED_DIR" zzznomatchzzz \
  --scale-set subsystem 2>/dev/null)
assert_eq "an unmatched query renders exactly its no-results line" "$NO_MATCH" \
  'No results for "zzznomatchzzz"'

# ---------------------------------------------
# Test 4: the JSON shapes
# ---------------------------------------------
echo ""
echo "Test 4: --json stays flat; --kind-sections is an object"

FLAT=$(python3 "$SCRIPT_DIR/pk_cli.py" search "$SCALED_DIR" quillon \
  --scale-set subsystem --limit 12 --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("type:%s" % type(d).__name__)
print("count:%d" % len(d))
print("kinds:%s" % ",".join(sorted({r.get("kind") or "" for r in d})))
print("decoder_keys:%s" % all(
    k in d[0] for k in ("heading", "file_path", "source_type", "category",
                        "confidence", "learned_date", "structural_importance",
                        "score", "snippet")))
')
assert_contains "--json alone parses as an array" "$FLAT" "type:list"
assert_contains "holding exactly --limit results" "$FLAT" "count:12"
assert_contains "no section entry is spliced into the flat list" "$FLAT" \
  "kinds:fact"
assert_contains "and every field the TUI decoder names is present" "$FLAT" \
  "decoder_keys:True"

OBJ=$(python3 "$SCRIPT_DIR/pk_cli.py" search "$SCALED_DIR" quillon \
  --scale-set subsystem --limit 12 --json --kind-sections 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("type:%s" % type(d).__name__)
print("keys:%s" % ",".join(sorted(d)))
print("results:%d" % len(d["results"]))
print("sections:%s" % ",".join(s["kind"] for s in d["sections"]))
print("served:%s" % ",".join(str(s["served_count"]) for s in d["sections"]))
print("statuses:%s" % ",".join(
    str(e["kind_status"]) for s in d["sections"] for e in s["served_entries"]))
print("degraded:%r" % d["degraded"])
')
assert_contains "--kind-sections parses as an object" "$OBJ" "type:dict"
assert_contains "carrying results, sections, and the degraded reading" "$OBJ" \
  "keys:degraded,results,sections"
assert_contains "the results list is the same flat list" "$OBJ" "results:12"
assert_contains "the sections arrive in delivery order" "$OBJ" \
  "sections:theory,question,hypothesis"
assert_contains "with their served counts" "$OBJ" "served:2,1,2"
assert_contains "and each served entry's kind_status" "$OBJ" \
  "statuses:None,None,open,supported,untested"
assert_contains "a healthy index reports no degradation" "$OBJ" "degraded:None"

# ---------------------------------------------
# Test 5: --budget is untouched, and refuses to pretend otherwise
# ---------------------------------------------
echo ""
echo "Test 5: the two-tier budget payload keeps its shape"

BUDGET=$(python3 "$SCRIPT_DIR/pk_cli.py" search "$SCALED_DIR" quillon \
  --scale-set subsystem --budget 4000 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("keys:%s" % ",".join(sorted(d)))
print("hook_reads:%s" % all(
    k in d for k in ("full", "titles_only")))
print("full_fields:%s" % all(
    ("file_path" in r and "content" in r) for r in d["full"]))
print("titles_fields:%s" % all(
    ("file_path" in r and "heading" in r) for r in d["titles_only"]))
print("no_sections:%s" % ("sections" not in d))
')
assert_contains "the payload still carries what the hook reads" "$BUDGET" \
  "hook_reads:True"
assert_contains "with file_path and content on every full entry" "$BUDGET" \
  "full_fields:True"
assert_contains "and file_path and heading on every title" "$BUDGET" \
  "titles_fields:True"
assert_contains "and no sections key grafted onto it" "$BUDGET" "no_sections:True"

REFUSAL_OUT=$(python3 "$SCRIPT_DIR/pk_cli.py" search "$SCALED_DIR" quillon \
  --scale-set subsystem --budget 4000 --kind-sections 2>"$TEST_DIR/refusal.err")
REFUSAL_RC=$?
REFUSAL_ERR=$(cat "$TEST_DIR/refusal.err")
assert_eq "asking for sections with --budget exits non-zero" "$REFUSAL_RC" "1"
assert_eq "and writes nothing to stdout" "$REFUSAL_OUT" ""
assert_contains "the refusal is structured, as it is a JSON output mode" \
  "$(echo "$REFUSAL_ERR" | python3 -c 'import json,sys; print("error_key:%s" % ("error" in json.load(sys.stdin)))')" \
  "error_key:True"
assert_contains "and names the flag it refused" "$REFUSAL_ERR" "--kind-sections"

# ---------------------------------------------
# Test 6: a store with no non-fact entry is left exactly as it was
# ---------------------------------------------
echo ""
echo "Test 6: the no-non-fact-entry path is byte-identical to the parent commit"

BASE_DIR=$(baseline_scripts pk_cli.py) || FAIL=$((FAIL + 1))
if grep -q "kind-sections" "$BASE_DIR/pk_cli.py"; then
  echo "  NOTE: the parent commit already carries --kind-sections, so the"
  echo "        comparison below no longer contrasts before with after."
fi

for variant in "" "--json" "--budget 4000"; do
  # shellcheck disable=SC2086
  python3 "$BASE_DIR/pk_cli.py" search "$FACTS_DIR" stale --scale-set implementation \
    $variant >"$TEST_DIR/base.out" 2>"$TEST_DIR/base.err"
  # shellcheck disable=SC2086
  python3 "$SCRIPT_DIR/pk_cli.py" search "$FACTS_DIR" stale --scale-set implementation \
    $variant >"$TEST_DIR/new.out" 2>"$TEST_DIR/new.err"
  label="${variant:-plain}"
  if cmp -s "$TEST_DIR/base.out" "$TEST_DIR/new.out"; then
    assert_eq "stdout is unchanged ($label)" "same" "same"
  else
    assert_eq "stdout is unchanged ($label)" \
      "$(diff "$TEST_DIR/base.out" "$TEST_DIR/new.out" | head -20)" "same"
  fi
  if cmp -s "$TEST_DIR/base.err" "$TEST_DIR/new.err"; then
    assert_eq "stderr is unchanged ($label)" "same" "same"
  else
    assert_eq "stderr is unchanged ($label)" \
      "$(diff "$TEST_DIR/base.err" "$TEST_DIR/new.err" | head -20)" "same"
  fi
done

# The same holds for --json on a store that DOES carry non-fact entries: the
# flat list is the contract, and nothing about it moves.
python3 "$BASE_DIR/pk_cli.py" search "$SCALED_DIR" quillon --scale-set subsystem \
  --json >"$TEST_DIR/base.out" 2>/dev/null
python3 "$SCRIPT_DIR/pk_cli.py" search "$SCALED_DIR" quillon --scale-set subsystem \
  --json >"$TEST_DIR/new.out" 2>/dev/null
if cmp -s "$TEST_DIR/base.out" "$TEST_DIR/new.out"; then
  assert_eq "--json is unchanged even where sections exist" "same" "same"
else
  assert_eq "--json is unchanged even where sections exist" \
    "$(diff "$TEST_DIR/base.out" "$TEST_DIR/new.out" | head -20)" "same"
fi

# On the facts-only store the section path has nothing to offer, and says so
# with an empty list rather than an absent key.
EMPTY=$(python3 "$SCRIPT_DIR/pk_cli.py" search "$FACTS_DIR" stale \
  --scale-set implementation --json --kind-sections 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("sections:%d" % len(d["sections"]))
print("has_results:%s" % (len(d["results"]) > 0))
')
assert_contains "no sections come back from a store with no non-fact entry" \
  "$EMPTY" "sections:0"
assert_contains "while the ranked list still answers" "$EMPTY" "has_results:True"

# =============================================
# The `lore search` wrapper
# =============================================
#
# `cli/lore` hard-resolves SCRIPTS_DIR through the ~/.lore/scripts symlink to
# the INSTALLED repo, and resolves the knowledge dir by shelling out to
# resolve-repo.sh. Running the real `lore` binary here would therefore drive
# installed scripts against the real store — installed pk_cli.py has no
# --kind-sections flag and would reject it, so such a test reports on code
# nobody in this checkout wrote. The wrapper under test is instead a copy with
# exactly those two resolutions repointed, and the copy is verified to have
# taken both rewrites before anything runs. Do not "simplify" this back to
# calling `lore` directly.

echo ""
echo "Test 7: the wrapper carries --kind-sections to every --type"

WRAPPER_DIR="$TEST_DIR/wrapper-store"
bash "$FIXTURE" "$WRAPPER_DIR" --scaled >/dev/null
# A work-pool entry, so the merge has two real halves to combine.
mkdir -p "$WRAPPER_DIR/_work/quillon-work-item"
printf '{"slug":"quillon-work-item","title":"Quillon Work Item","status":"active"}\n' \
  > "$WRAPPER_DIR/_work/quillon-work-item/_meta.json"
printf '# Quillon Work Item\n\n## Session note\n\nThe quillon router work item tracks the quillon migration.\n' \
  > "$WRAPPER_DIR/_work/quillon-work-item/notes.md"

TEST_LORE="$TEST_DIR/lore-under-test"
sed -e "s|^SCRIPTS_DIR=.*|SCRIPTS_DIR=\"$SCRIPT_DIR\"|" \
    -e "s|^  \"\$SCRIPTS_DIR/resolve-repo.sh\"$|  echo \"\$LORE_TEST_KDIR\"|" \
    "$REPO_DIR/cli/lore" > "$TEST_LORE"
chmod +x "$TEST_LORE"
if grep -q "^SCRIPTS_DIR=\"$SCRIPT_DIR\"$" "$TEST_LORE" \
   && grep -q 'echo "\$LORE_TEST_KDIR"' "$TEST_LORE"; then
  assert_eq "the wrapper copy points at this checkout" "repointed" "repointed"
else
  assert_eq "the wrapper copy points at this checkout" \
    "one of the two rewrites did not match cli/lore — the test would run against installed code" \
    "repointed"
fi
export LORE_TEST_KDIR="$WRAPPER_DIR"

# The default type. This is the invocation that crashed before the wrapper knew
# the flag: two objects reached a merge that could only add two lists.
ALL_OBJ=$("$TEST_LORE" search quillon --scale-set subsystem --limit 12 \
  --json --kind-sections 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("type:%s" % type(d).__name__)
print("keys:%s" % ",".join(sorted(d)))
print("key_order:%s" % ",".join(d))
print("results:%d" % len(d["results"]))
print("sections:%s" % ",".join(s["kind"] for s in d["sections"]))
print("one_per_kind:%s" % (
    len(d["sections"]) == len({s["kind"] for s in d["sections"]})))
')
assert_contains "the default --type all returns an object" "$ALL_OBJ" "type:dict"
assert_contains "carrying results, sections, and degraded" "$ALL_OBJ" \
  "keys:degraded,results,sections"
assert_contains "with results first, as the single-pool object has them" \
  "$ALL_OBJ" "key_order:results,sections,degraded"
assert_contains "the ranked results survive the merge" "$ALL_OBJ" "results:12"
assert_contains "all three sections come through" "$ALL_OBJ" \
  "sections:theory,question,hypothesis"
assert_contains "and no kind appears twice — only one pool was asked" "$ALL_OBJ" \
  "one_per_kind:True"

ALL_FLAT=$("$TEST_LORE" search quillon --scale-set subsystem --limit 12 --json \
  2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("type:%s" % type(d).__name__)
print("count:%d" % len(d))
')
assert_contains "--type all without the flag is still a flat list" "$ALL_FLAT" \
  "type:list"
assert_contains "of the same length as before" "$ALL_FLAT" "count:12"

KNOW_OBJ=$("$TEST_LORE" search quillon --scale-set subsystem --limit 12 \
  --type knowledge --json --kind-sections 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("type:%s" % type(d).__name__)
print("sections:%s" % ",".join(s["kind"] for s in d["sections"]))
')
assert_contains "--type knowledge returns the object" "$KNOW_OBJ" "type:dict"
assert_contains "with its sections intact" "$KNOW_OBJ" \
  "sections:theory,question,hypothesis"

WORK_OBJ=$("$TEST_LORE" search quillon --scale-set subsystem \
  --type work --json --kind-sections 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("type:%s" % type(d).__name__)
print("sections:%d" % len(d["sections"]))
')
assert_contains "--type work returns the object too" "$WORK_OBJ" "type:dict"
assert_contains "and no sections, since the work pool declares no kinds" \
  "$WORK_OBJ" "sections:0"

WRAPPER_HUMAN=$("$TEST_LORE" search quillon --scale-set subsystem --limit 12 \
  --type knowledge 2>/dev/null)
assert_contains "the wrapper's human render appends the theory section" \
  "$WRAPPER_HUMAN" "### Theory"
assert_contains "the question section" "$WRAPPER_HUMAN" "### Open questions"
assert_contains "and the hypothesis section" "$WRAPPER_HUMAN" "### Hypotheses"

# =============================================
echo ""
echo "Test 8: the merge combines two real halves without reshaping either"

# Both halves are produced by this checkout's pk_cli.py. The work half is
# fetched without --scale-set: work entries index with no declared scale, so a
# scale-filtered search — which is the only kind the wrapper issues — can never
# return one. Through the wrapper the work half is therefore always empty, and
# the concatenation is only observable here.
python3 "$SCRIPT_DIR/pk_cli.py" search "$WRAPPER_DIR" quillon \
  --scale-set subsystem --limit 12 --json --kind-sections \
  > "$TEST_DIR/half_knowledge.json" 2>/dev/null
python3 "$SCRIPT_DIR/pk_cli.py" search "$WRAPPER_DIR" quillon \
  --json --type work > "$TEST_DIR/half_work.json" 2>/dev/null
python3 "$SCRIPT_DIR/pk_cli.py" search "$WRAPPER_DIR" quillon \
  --scale-set subsystem --limit 12 --json \
  > "$TEST_DIR/half_knowledge_flat.json" 2>/dev/null

MERGED=$(python3 "$SCRIPT_DIR/merge-search-json.py" \
  "$(cat "$TEST_DIR/half_knowledge.json")" "$(cat "$TEST_DIR/half_work.json")" \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("type:%s" % type(d).__name__)
print("results:%d" % len(d["results"]))
print("tail_is_work:%s" % (d["results"][-1].get("source_type") == "work"))
print("head_is_knowledge:%s" % (d["results"][0].get("source_type") == "knowledge"))
print("sections:%s" % ",".join(s["kind"] for s in d["sections"]))
')
WORK_COUNT=$(python3 -c "import json,sys; print(len(json.load(open('$TEST_DIR/half_work.json'))))")
assert_eq "the work half is genuinely non-empty here" "$WORK_COUNT" "1"
assert_contains "merging an object half with a list half keeps the object" \
  "$MERGED" "type:dict"
assert_contains "and concatenates both halves' results" "$MERGED" "results:13"
assert_contains "knowledge first" "$MERGED" "head_is_knowledge:True"
assert_contains "work appended after it" "$MERGED" "tail_is_work:True"
assert_contains "with the knowledge half's sections carried through" "$MERGED" \
  "sections:theory,question,hypothesis"

MERGED_FLAT=$(python3 "$SCRIPT_DIR/merge-search-json.py" \
  "$(cat "$TEST_DIR/half_knowledge_flat.json")" "$(cat "$TEST_DIR/half_work.json")" \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("type:%s" % type(d).__name__)
print("count:%d" % len(d))
')
assert_contains "two list halves still merge to a flat list" "$MERGED_FLAT" \
  "type:list"
assert_contains "holding every result from both" "$MERGED_FLAT" "count:13"

# A work half that arrived as an object means the flag was routed to both
# pools — a wrapper bug, and the merge says so rather than guessing.
BAD_OUT=$(python3 "$SCRIPT_DIR/merge-search-json.py" \
  "$(cat "$TEST_DIR/half_knowledge.json")" "$(cat "$TEST_DIR/half_knowledge.json")" \
  2>"$TEST_DIR/merge.err")
BAD_RC=$?
assert_eq "an object work half is refused" "$BAD_RC" "1"
assert_eq "with nothing on stdout" "$BAD_OUT" ""
assert_contains "and a structured error naming the cause" \
  "$(python3 -c 'import json,sys; print("error:%s" % ("error" in json.load(open(sys.argv[1]))))' "$TEST_DIR/merge.err")" \
  "error:True"
assert_contains "that says which half was wrong" "$(cat "$TEST_DIR/merge.err")" \
  "work half"

MALFORMED_OUT=$(python3 "$SCRIPT_DIR/merge-search-json.py" "not json" "[]" \
  2>"$TEST_DIR/malformed.err")
MALFORMED_RC=$?
assert_eq "malformed input is refused too" "$MALFORMED_RC" "1"
assert_eq "with nothing on stdout" "$MALFORMED_OUT" ""
assert_contains "naming the half that failed to parse" \
  "$(cat "$TEST_DIR/malformed.err")" "knowledge half"

# =============================================
# The prefetch injector
# =============================================

echo ""
echo "Test 9: prefetch appends its sections inside the char ceiling"

WIDE_DIR="$TEST_DIR/wide"
make_wide_store "$WIDE_DIR" "$SCALED_DIR"

PREFETCH=$(python3 "$SCRIPT_DIR/pk_cli.py" prefetch "$WIDE_DIR" quillon \
  --scale-set subsystem --limit 18 2>/dev/null)
printf '%s\n' "$PREFETCH" > "$TEST_DIR/prefetch.txt"

assert_contains "the block still opens with its own header" "$PREFETCH" \
  "## Prior Knowledge"
assert_contains "the theory section is labeled" "$PREFETCH" "### Theory"
assert_contains "the question section is labeled" "$PREFETCH" "### Open questions"
assert_contains "the hypothesis section is labeled" "$PREFETCH" "### Hypotheses"
assert_contains "an open question carries its kind_status" "$PREFETCH" \
  "Quillon Question Open [open] (from"
assert_contains "a theory carries the subsystem it accounts for" "$PREFETCH" \
  "[subsystem: quillon-router]"
assert_not_contains "a refuted hypothesis is still not delivered" "$PREFETCH" \
  "Quillon Hypothesis Refuted ["

# Entry blocks and section headers are both `### `; the entry blocks are the
# ones naming a source file. The budget assertion is the one with teeth: the
# ceiling is 12000 and the sections spend ~3000 of it, so a body that stayed
# under the ceiling is a body whose sections came out of the entry budget
# rather than on top of it. The slack is the single newline print() adds per
# emitted block.
PREFETCH_SHAPE=$(python3 - "$TEST_DIR/prefetch.txt" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
body = text[text.index("\n", text.index("Results from knowledge store")) + 1:]
lines = body.splitlines()
last_entry = max(i for i, ln in enumerate(lines)
                 if ln.startswith("### ") and " (from " in ln)
first_section = min(i for i, ln in enumerate(lines) if ln == "### Theory")
print("sections_follow_entries:%s" % (last_entry < first_section))
print("section_order:%s" % ",".join(
    ln[4:] for ln in lines if ln.startswith("### ") and " (from " not in ln))
print("within_ceiling:%s" % (len(body) <= 12200))
print("body_chars:%d" % len(body))
PY
)
assert_contains "the sections come after every entry block" "$PREFETCH_SHAPE" \
  "sections_follow_entries:True"
assert_contains "and run theory, questions, hypotheses" "$PREFETCH_SHAPE" \
  "section_order:Theory,Open questions,Hypotheses"
assert_contains "the sections were paid for out of the entry budget" \
  "$PREFETCH_SHAPE" "within_ceiling:True"

# Every line the sections render is labeled, checked over the rendered lines
# so a new render mode cannot slip an unlabeled one through.
PREFETCH_LABELS=$(python3 - "$TEST_DIR/prefetch.txt" <<'PY'
import re
import sys
text = open(sys.argv[1], encoding="utf-8").read()
lines = text[text.index("\n### Theory\n"):].splitlines()
served = [ln for ln in lines if ln.startswith("#### ") or ln.startswith("- [[")]
unlabeled = [ln for ln in served if not re.search(r"\[[^]]+\]\s*(\(from |$)", ln)]
print("served_lines:%d" % len(served))
print("unlabeled:%d" % len(unlabeled))
PY
)
assert_contains "the sections served entries" "$PREFETCH_LABELS" "served_lines:5"
assert_contains "and every one of them is labeled" "$PREFETCH_LABELS" "unlabeled:0"

# ---------------------------------------------
# Test 10: prefetch on a store with no non-fact entry
# ---------------------------------------------
echo ""
echo "Test 10: prefetch's no-non-fact-entry path is byte-identical to the parent commit"

INJECTOR_BASE=$(baseline_scripts pk_prefetch.py pk_manifest.py) || FAIL=$((FAIL + 1))

for variant in "" "--format summary"; do
  # shellcheck disable=SC2086
  python3 "$INJECTOR_BASE/pk_cli.py" prefetch "$FACTS_DIR" stale \
    --scale-set implementation $variant >"$TEST_DIR/base.out" 2>"$TEST_DIR/base.err"
  # shellcheck disable=SC2086
  python3 "$SCRIPT_DIR/pk_cli.py" prefetch "$FACTS_DIR" stale \
    --scale-set implementation $variant >"$TEST_DIR/new.out" 2>"$TEST_DIR/new.err"
  label="${variant:-prompt}"
  if cmp -s "$TEST_DIR/base.out" "$TEST_DIR/new.out"; then
    assert_eq "prefetch stdout is unchanged ($label)" "same" "same"
  else
    assert_eq "prefetch stdout is unchanged ($label)" \
      "$(diff "$TEST_DIR/base.out" "$TEST_DIR/new.out" | head -20)" "same"
  fi
  if cmp -s "$TEST_DIR/base.err" "$TEST_DIR/new.err"; then
    assert_eq "prefetch stderr is unchanged ($label)" "same" "same"
  else
    assert_eq "prefetch stderr is unchanged ($label)" \
      "$(diff "$TEST_DIR/base.err" "$TEST_DIR/new.err" | head -20)" "same"
  fi
done

FACTS_PREFETCH=$(python3 "$SCRIPT_DIR/pk_cli.py" prefetch "$FACTS_DIR" stale \
  --scale-set implementation 2>/dev/null)
assert_not_contains "no section header appears on a facts-only store" \
  "$FACTS_PREFETCH" "### Theory"
assert_not_contains "nor an empty questions header" "$FACTS_PREFETCH" \
  "### Open questions"

# =============================================
# The manifest injector
# =============================================

echo ""
echo "Test 11: the resolved manifest places kind sections after its topic sections"

MANIFEST_DIRECTIVE='{"version":2,"topics":[
  {"topic":"quillon buffer batch","role":"focal","scale_set":["subsystem"],"limit":4},
  {"topic":"quillon router theory","role":"adjacent","scale_set":["subsystem"],"limit":2}]}'
MANIFEST_LOG="$SCALED_DIR/_meta/retrieval-log.jsonl"
rm -f "$MANIFEST_LOG"

python3 "$SCRIPT_DIR/pk_cli.py" resolve-manifest "$SCALED_DIR" \
  --slug kind-sections-fixture --phase 1 --task-id t9 \
  --delivery-json "$TEST_DIR/delivery.json" \
  --directive "$MANIFEST_DIRECTIVE" >"$TEST_DIR/manifest.txt" 2>/dev/null
MANIFEST=$(cat "$TEST_DIR/manifest.txt")

assert_contains "the bundle still opens with its own header" "$MANIFEST" \
  "## Prior Knowledge"
assert_contains "the focal section keeps its spelling" "$MANIFEST" \
  "### Focal: quillon buffer batch"
assert_contains "the adjacent section keeps its spelling" "$MANIFEST" \
  "### Adjacent: quillon router theory"
assert_contains "the theory section is labeled" "$MANIFEST" "### Theory"
assert_contains "the question section is labeled" "$MANIFEST" "### Open questions"
assert_contains "the hypothesis section is labeled" "$MANIFEST" "### Hypotheses"
assert_contains "an open question carries its kind_status" "$MANIFEST" \
  "Quillon Question Open [open] (from"

MANIFEST_ORDER=$(python3 - "$TEST_DIR/manifest.txt" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
headers = [ln for ln in lines if ln.startswith("### ")]
topic_last = max(i for i, ln in enumerate(headers)
                 if ln.startswith("### Focal:") or ln.startswith("### Adjacent:"))
kind_first = min(i for i, ln in enumerate(headers)
                 if not (ln.startswith("### Focal:") or ln.startswith("### Adjacent:")))
print("kinds_follow_topics:%s" % (topic_last < kind_first))
print("header_order:%s" % ",".join(headers))
PY
)
assert_contains "the kind sections come after every topic section" \
  "$MANIFEST_ORDER" "kinds_follow_topics:True"
assert_contains "and neither axis is nested inside the other" "$MANIFEST_ORDER" \
  "header_order:### Focal: quillon buffer batch,### Adjacent: quillon router theory,### Theory,### Open questions,### Hypotheses"

# The stdout side channel: still one trailing line, still the literal prefix
# and suffix, now also naming what the sections served.
RM_PATHS=$(python3 - "$TEST_DIR/manifest.txt" <<'PY'
import sys
lines = [ln for ln in open(sys.argv[1], encoding="utf-8").read().splitlines()
         if "_RM_PATHS" in ln]
print("marker_lines:%d" % len(lines))
if len(lines) == 1:
    line = lines[0]
    print("prefix:%s" % line.startswith("<!-- _RM_PATHS="))
    print("suffix:%s" % line.endswith(" -->"))
    csv = line[len("<!-- _RM_PATHS="):-len(" -->")]
    paths = [p for p in csv.split(",") if p]
    print("is_last_line:%s" % (line == open(sys.argv[1], encoding="utf-8").read().rstrip("\n").splitlines()[-1]))
    print("has_question:%s" % any("quillon-question-open" in p for p in paths))
    print("has_hypothesis:%s" % any("quillon-hypothesis" in p for p in paths))
    print("unique:%s" % (len(paths) == len(set(paths))))
PY
)
assert_contains "exactly one marker line is emitted" "$RM_PATHS" "marker_lines:1"
assert_contains "with its literal prefix" "$RM_PATHS" "prefix:True"
assert_contains "and its literal suffix" "$RM_PATHS" "suffix:True"
assert_contains "as the last line of the bundle" "$RM_PATHS" "is_last_line:True"
assert_contains "the served question is named in it" "$RM_PATHS" "has_question:True"
assert_contains "and the served hypothesis too" "$RM_PATHS" "has_hypothesis:True"
assert_contains "with no path listed twice" "$RM_PATHS" "unique:True"

# Telemetry: the topic records keep every field they carry today, and the kind
# records arrive beside them carrying the two degradation flags separately.
TELEMETRY=$(python3 - "$MANIFEST_LOG" <<'PY'
import json
import sys
rows = [json.loads(ln) for ln in open(sys.argv[1], encoding="utf-8") if ln.strip()]
row = [r for r in rows if r.get("event") == "manifest_load"][-1]
existing = {"manifest_version", "topic", "section_role", "requested_k", "raw_count",
            "served_count", "deduped_count", "served_paths", "chars_used",
            "chars_budget", "render_mode_counts", "content_degraded",
            "shrunk_for_budget", "entry_count_before_budget"}
topic_secs = [s for s in row["sections"] if s["section_role"] != "kind"]
kind_secs = [s for s in row["sections"] if s["section_role"] == "kind"]
print("topic_sections:%d" % len(topic_secs))
print("topic_fields_intact:%s" % all(existing <= set(s) for s in topic_secs))
print("kinds:%s" % ",".join(s["kind"] for s in kind_secs))
print("kind_flags_present:%s" % all(
    isinstance(s["content_degraded"], bool) and isinstance(s["shrunk_for_budget"], bool)
    for s in kind_secs))
# The distinction the two flags exist to keep: a section that rendered its
# entries smaller is not a section that lost entries it had selected.
print("kind_flags_differ:%s" % any(
    s["content_degraded"] and not s["shrunk_for_budget"] for s in kind_secs))
served = [p for s in row["sections"] for p in s["served_paths"]]
print("loaded_covers_sections:%s" % (row["loaded_paths"] == served))
PY
)
assert_contains "both topic sections are still recorded" "$TELEMETRY" \
  "topic_sections:2"
assert_contains "with every per-section field they carry today" "$TELEMETRY" \
  "topic_fields_intact:True"
assert_contains "and the kind sections are recorded beside them" "$TELEMETRY" \
  "kinds:theory,question,hypothesis"
assert_contains "each carrying both degradation flags" "$TELEMETRY" \
  "kind_flags_present:True"
assert_contains "as two independent readings" "$TELEMETRY" \
  "kind_flags_differ:True"
assert_contains "and loaded_paths covers what the sections served" "$TELEMETRY" \
  "loaded_covers_sections:True"

DELIVERY=$(python3 - "$TEST_DIR/delivery.json" <<'PY'
import json
import sys
snap = json.load(open(sys.argv[1], encoding="utf-8"))
kind_entries = [e for e in snap["entries"] if e["section_role"] == "kind"]
print("kind_entries:%s" % (len(kind_entries) > 0))
print("modes_present:%s" % all(e["render_mode"] in ("full", "snippet", "backlink")
                               for e in kind_entries))
print("trust_present:%s" % all("trust" in e for e in kind_entries))
PY
)
assert_contains "the delivery snapshot records the section entries" "$DELIVERY" \
  "kind_entries:True"
assert_contains "with the mode each was rendered in" "$DELIVERY" "modes_present:True"
assert_contains "and a trust reading apiece" "$DELIVERY" "trust_present:True"

# ---------------------------------------------
# Test 12: the manifest on a store with no non-fact entry
# ---------------------------------------------
echo ""
echo "Test 12: the manifest's no-non-fact-entry path is byte-identical to the parent commit"

FACTS_DIRECTIVE='{"version":2,"topics":[
  {"topic":"stale widget","role":"focal","scale_set":["implementation"],"limit":4}]}'
python3 "$INJECTOR_BASE/pk_cli.py" resolve-manifest "$FACTS_DIR" --slug facts \
  --phase 1 --directive "$FACTS_DIRECTIVE" >"$TEST_DIR/base.out" 2>"$TEST_DIR/base.err"
python3 "$SCRIPT_DIR/pk_cli.py" resolve-manifest "$FACTS_DIR" --slug facts \
  --phase 1 --directive "$FACTS_DIRECTIVE" >"$TEST_DIR/new.out" 2>"$TEST_DIR/new.err"
if cmp -s "$TEST_DIR/base.out" "$TEST_DIR/new.out"; then
  assert_eq "manifest stdout is unchanged" "same" "same"
else
  assert_eq "manifest stdout is unchanged" \
    "$(diff "$TEST_DIR/base.out" "$TEST_DIR/new.out" | head -20)" "same"
fi
if cmp -s "$TEST_DIR/base.err" "$TEST_DIR/new.err"; then
  assert_eq "manifest stderr is unchanged" "same" "same"
else
  assert_eq "manifest stderr is unchanged" \
    "$(diff "$TEST_DIR/base.err" "$TEST_DIR/new.err" | head -20)" "same"
fi

FACTS_MANIFEST=$(cat "$TEST_DIR/new.out")
assert_not_contains "no section header appears on a facts-only store" \
  "$FACTS_MANIFEST" "### Theory"
assert_contains "and the marker line is still there" "$FACTS_MANIFEST" \
  "<!-- _RM_PATHS="

# Every entry in the stores above is under the 500-char snippet cut, so a
# change to how full mode sources its text would slip past the comparison — the
# rendered block would be the snippet either way. This store carries entries
# past that cut, which is where full mode and snippet mode can diverge.
LONG_FACTS_DIR="$TEST_DIR/long-facts"
rm -rf "$LONG_FACTS_DIR"
cp -R "$FACTS_DIR" "$LONG_FACTS_DIR"
rm -f "$LONG_FACTS_DIR/.pk_search.db"
LONG_PARA="The stale widget intake drains its buffer before the assembly cache reads it, so a batch that reaches the release queue has already passed the drain stage and carries no pending widget."
for n in 1 2; do
  printf '# Long Stale Fact %s\n%s %s %s %s %s %s\n%s\n' "$n" \
    "$LONG_PARA" "$LONG_PARA" "$LONG_PARA" "$LONG_PARA" "$LONG_PARA" "$LONG_PARA" \
    '<!-- learned: 2026-07-01 | confidence: high | source: manual | scale: implementation | kind: fact | status: current -->' \
    > "$LONG_FACTS_DIR/conventions/long-stale-fact-$n.md"
done
python3 - "$LONG_FACTS_DIR" <<'PY'
import json, os, sys
kdir = sys.argv[1]
entries = []
for root, dirnames, filenames in os.walk(kdir):
    dirnames[:] = [d for d in dirnames if not d.startswith("_")]
    for name in sorted(filenames):
        if name.endswith(".md"):
            entries.append({"path": os.path.relpath(os.path.join(root, name), kdir),
                            "backlinks": []})
manifest = {"format_version": 2, "entries": sorted(entries, key=lambda e: e["path"])}
with open(os.path.join(kdir, "_manifest.json"), "w", encoding="utf-8") as f:
    json.dump(manifest, f)
PY

LONG_DIRECTIVE='{"version":2,"topics":[
  {"topic":"stale widget drain","role":"focal","scale_set":["implementation"],"limit":4}]}'
python3 "$INJECTOR_BASE/pk_cli.py" resolve-manifest "$LONG_FACTS_DIR" --slug longfacts \
  --phase 1 --directive "$LONG_DIRECTIVE" >"$TEST_DIR/base.out" 2>/dev/null
python3 "$SCRIPT_DIR/pk_cli.py" resolve-manifest "$LONG_FACTS_DIR" --slug longfacts \
  --phase 1 --directive "$LONG_DIRECTIVE" >"$TEST_DIR/new.out" 2>/dev/null
LONG_RENDERED=$(python3 - "$TEST_DIR/new.out" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.find("#### Long Stale Fact")
block = text[start:text.find("\n#### ", start + 1)] if start >= 0 else ""
print("entry_rendered:%s" % (start >= 0))
print("past_snippet_cut:%s" % (len(block) > 520))
PY
)
assert_contains "the long entry really is in the bundle" "$LONG_RENDERED" \
  "entry_rendered:True"
assert_contains "and really does run past the snippet cut" "$LONG_RENDERED" \
  "past_snippet_cut:True"
if cmp -s "$TEST_DIR/base.out" "$TEST_DIR/new.out"; then
  assert_eq "manifest stdout is unchanged on entries past the snippet cut" "same" "same"
else
  assert_eq "manifest stdout is unchanged on entries past the snippet cut" \
    "$(diff "$TEST_DIR/base.out" "$TEST_DIR/new.out" | head -20)" "same"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
