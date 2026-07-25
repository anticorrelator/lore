#!/usr/bin/env bash
# test_evidence_canonicalize_worktree_paths.sh — tests for the backfill driver
# that re-expresses Tier 2 `file` references pointing into removed worktrees.
#
# Covers:
#   1. Strip derivation from the row's own file/file_relative pair, including a
#      nested file_relative and a worktree root with no conventional name.
#   2. Dry-run by default: classification only, nothing written.
#   3. Depth-limited enumeration: _work/<slug>/verdicts/task-claims.jsonl is
#      never read or mutated.
#   4. Worktree-absence gating, per row and per file.
#   5. Precondition refusals: no derivable prefix, duplicate claim_id, `file`
#      absent from changed_files.
#   6. Confinement refusal when the writer touches a field beyond the reference.
#   7. Idempotent replay, including that a replay does not overwrite the
#      manifest and verification report of the run that did the work.
#   8. --verify re-deriving both artifacts from a committed pre-image, and
#      catching a row whose other fields drifted.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
DRIVER="$SCRIPTS_DIR/evidence-canonicalize-worktree-paths.py"
UPDATE="$SCRIPTS_DIR/evidence-update.sh"
VALIDATE="$SCRIPTS_DIR/validate-tier2.sh"
NORMALIZE_PY="$SCRIPTS_DIR/snippet_normalize.py"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

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

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected to contain: $needle"
    echo "    Actual:              $haystack"
    FAIL=$((FAIL + 1))
  fi
}

# Emit one valid Tier 2 row. Overrides are key=JSON-value pairs.
build_row() {
  python3 - "$NORMALIZE_PY" "$@" <<'PYEOF'
import hashlib, json, re, sys

norm_py = sys.argv[1]
snippet = "def handler():\n    return 1\n"
normalized = re.sub(r"\s+", " ", snippet).strip()
row = {
    "claim_id": "c-1",
    "tier": "task-evidence",
    "claim": "handler returns 1",
    "producer_role": "worker",
    "protocol_slot": "implement-step-3",
    "task_id": "task-1",
    "phase_id": "phase-1",
    "scale": "implementation",
    "file": "/gone/wt/scripts/a.py",
    "line_range": "1-2",
    "exact_snippet": snippet,
    "normalized_snippet_hash": hashlib.sha256(normalized.encode()).hexdigest(),
    "falsifier": "handler returns something else",
    "why_this_work_needs_it": "grounds the fixture",
    "captured_at_sha": "deadbeef",
    "change_context": {
        "diff_ref": "deadbeef",
        "changed_files": ["/gone/wt/scripts/a.py"],
        "summary": "fixture change",
    },
    "file_relative": "scripts/a.py",
    "captured_origin_ref": None,
}
for arg in sys.argv[2:]:
    k, v = arg.split("=", 1)
    row[k] = json.loads(v)
print(json.dumps(row, separators=(",", ":")))
PYEOF
}

new_store() {
  # new_store <name> -> echoes the kdir path
  local kdir="$TEST_DIR/$1"
  mkdir -p "$kdir/_work" "$kdir/_work/_archive"
  echo "$kdir"
}

line_of() {
  # line_of <file> <claim_id> <jq-filter>
  python3 -c '
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    row = json.loads(line)
    if row.get("claim_id") == sys.argv[2]:
        print(json.dumps(row.get(sys.argv[3])))
        break
' "$1" "$2" "$3"
}

sha_of_file() { shasum -a 256 "$1" | awk '{print $1}'; }

echo "=== Fixture sanity: the built row validates ==="
assert_eq "fixture row passes validate-tier2.sh" \
  "$(build_row | "$VALIDATE" >/dev/null 2>&1 && echo ok || echo no)" "ok"

echo
echo "=== Test 1: strip derivation and the coupled changed_files strip ==="
KDIR=$(new_store t1)
mkdir -p "$KDIR/_work/alpha"
GONE="$TEST_DIR/t1-tree/_sessions/worktrees/20260101T000000Z-abcdef"
build_row \
  "file=\"$GONE/scripts/nested/deep/a.py\"" \
  'file_relative="scripts/nested/deep/a.py"' \
  "change_context={\"diff_ref\":\"deadbeef\",\"changed_files\":[\"$GONE/scripts/nested/deep/a.py\",\"$GONE/docs/readme.md\",\"/elsewhere/untouched.py\"],\"summary\":\"fixture change\"}" \
  > "$KDIR/_work/alpha/task-claims.jsonl"
mkdir -p "$KDIR/_work/alpha-artifacts"
OUT=$(python3 "$DRIVER" --kdir "$KDIR" --apply --artifact-dir "$KDIR/_work/alpha-artifacts" 2>&1)
assert_eq "file rewritten to file_relative" \
  "$(line_of "$KDIR/_work/alpha/task-claims.jsonl" c-1 file)" '"scripts/nested/deep/a.py"'
assert_eq "every changed_files entry under the derived prefix stripped; others verbatim" \
  "$(line_of "$KDIR/_work/alpha/task-claims.jsonl" c-1 change_context | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["changed_files"]))')" \
  '["scripts/nested/deep/a.py", "docs/readme.md", "/elsewhere/untouched.py"]'
assert_contains "run reports one repair" "$OUT" "repaired 1"
assert_eq "row still validates after mutation" \
  "$(cat "$KDIR/_work/alpha/task-claims.jsonl" | "$VALIDATE" >/dev/null 2>&1 && echo ok)" "ok"
assert_eq "pre-image manifest written" \
  "$([[ -f "$KDIR/_work/alpha-artifacts/canonicalize-worktree-paths-manifest.json" ]] && echo yes)" "yes"
assert_eq "verification report written" \
  "$([[ -f "$KDIR/_work/alpha-artifacts/canonicalize-worktree-paths-verification.md" ]] && echo yes)" "yes"
assert_contains "manifest records the pre-image sha256" \
  "$(cat "$KDIR/_work/alpha-artifacts/canonicalize-worktree-paths-manifest.json")" '"pre_image_sha256"'
assert_contains "verification report confirms confinement" \
  "$(cat "$KDIR/_work/alpha-artifacts/canonicalize-worktree-paths-verification.md")" \
  "rows repaired and re-verified as confined: 1 / 1"

echo
echo "=== Test 2: strip derivation ignores worktree naming conventions ==="
KDIR=$(new_store t2)
mkdir -p "$KDIR/_work/beta" "$KDIR/_work/beta-artifacts"
ODD="$TEST_DIR/t2-tree/some/unconventional/checkout-dir"
build_row "file=\"$ODD/scripts/a.py\"" \
  "change_context={\"diff_ref\":\"deadbeef\",\"changed_files\":[\"$ODD/scripts/a.py\"],\"summary\":\"fixture change\"}" \
  > "$KDIR/_work/beta/task-claims.jsonl"
BEFORE=$(sha_of_file "$KDIR/_work/beta/task-claims.jsonl")
OUT=$(python3 "$DRIVER" --kdir "$KDIR" --apply --artifact-dir "$KDIR/_work/beta-artifacts" 2>&1)
assert_eq "a dangling path without /worktrees/ is not in the cohort" \
  "$(sha_of_file "$KDIR/_work/beta/task-claims.jsonl")" "$BEFORE"
assert_contains "no candidates reported" "$OUT" "nothing to repair"
# The same row under a /worktrees/ root is repaired, and the prefix comes from
# the pair rather than from the segment after /worktrees/.
KDIR=$(new_store t2b)
mkdir -p "$KDIR/_work/beta" "$KDIR/_work/beta-artifacts"
DEEP="$TEST_DIR/t2b/_coordination/worktrees/trees/wt-abc123"
build_row "file=\"$DEEP/scripts/a.py\"" \
  "change_context={\"diff_ref\":\"deadbeef\",\"changed_files\":[\"$DEEP/scripts/a.py\"],\"summary\":\"fixture change\"}" \
  > "$KDIR/_work/beta/task-claims.jsonl"
mkdir -p "$TEST_DIR/t2b/_coordination/worktrees/trees"
python3 "$DRIVER" --kdir "$KDIR" --apply --artifact-dir "$KDIR/_work/beta-artifacts" >/dev/null 2>&1
assert_eq "prefix is the git root from the pair, not the segment after /worktrees/" \
  "$(line_of "$KDIR/_work/beta/task-claims.jsonl" c-1 file)" '"scripts/a.py"'

echo
echo "=== Test 3: dry-run by default writes nothing ==="
KDIR=$(new_store t3)
mkdir -p "$KDIR/_work/gamma" "$KDIR/_work/gamma-artifacts"
GONE="$TEST_DIR/t3-tree/_sessions/worktrees/wt-gone"
build_row "file=\"$GONE/scripts/a.py\"" \
  "change_context={\"diff_ref\":\"deadbeef\",\"changed_files\":[\"$GONE/scripts/a.py\"],\"summary\":\"fixture change\"}" \
  > "$KDIR/_work/gamma/task-claims.jsonl"
BEFORE=$(sha_of_file "$KDIR/_work/gamma/task-claims.jsonl")
OUT=$(python3 "$DRIVER" --kdir "$KDIR" 2>&1)
assert_eq "bare invocation leaves the file byte-identical" \
  "$(sha_of_file "$KDIR/_work/gamma/task-claims.jsonl")" "$BEFORE"
assert_eq "bare invocation writes no artifacts" \
  "$(find "$KDIR/_work/gamma-artifacts" -mindepth 1 | wc -l | tr -d ' ')" "0"
assert_contains "dry-run classifies the row as repairable" "$OUT" "1 repairable"
assert_contains "dry-run says it wrote nothing" "$OUT" "dry-run wrote nothing"

echo
echo "=== Test 4: enumeration never descends into verdicts/ ==="
KDIR=$(new_store t4)
mkdir -p "$KDIR/_work/delta/verdicts" "$KDIR/_work/_archive/epsilon" "$KDIR/_work/delta-artifacts"
GONE="$TEST_DIR/t4-tree/_sessions/worktrees/wt-gone"
build_row "file=\"$GONE/scripts/a.py\"" \
  "change_context={\"diff_ref\":\"deadbeef\",\"changed_files\":[\"$GONE/scripts/a.py\"],\"summary\":\"fixture change\"}" \
  > "$KDIR/_work/delta/verdicts/task-claims.jsonl"
build_row 'claim_id="c-arch"' "file=\"$GONE/scripts/b.py\"" 'file_relative="scripts/b.py"' \
  "change_context={\"diff_ref\":\"deadbeef\",\"changed_files\":[\"$GONE/scripts/b.py\"],\"summary\":\"fixture change\"}" \
  > "$KDIR/_work/_archive/epsilon/task-claims.jsonl"
VERDICT_BEFORE=$(sha_of_file "$KDIR/_work/delta/verdicts/task-claims.jsonl")
OUT=$(python3 "$DRIVER" --kdir "$KDIR" --apply --artifact-dir "$KDIR/_work/delta-artifacts" 2>&1)
assert_eq "verdict-envelope file byte-identical" \
  "$(sha_of_file "$KDIR/_work/delta/verdicts/task-claims.jsonl")" "$VERDICT_BEFORE"
assert_contains "only the archived producer row was repaired" "$OUT" "repaired 1"
assert_eq "archived producer row repaired" \
  "$(line_of "$KDIR/_work/_archive/epsilon/task-claims.jsonl" c-arch file)" '"scripts/b.py"'

echo
echo "=== Test 5: worktree-absence gating, per row and per file ==="
KDIR=$(new_store t5)
mkdir -p "$KDIR/_work/zeta" "$KDIR/_work/zeta-artifacts"
LIVE="$TEST_DIR/t5-tree/_sessions/worktrees/wt-live"
GONE="$TEST_DIR/t5-tree/_sessions/worktrees/wt-gone"
mkdir -p "$LIVE/scripts"
{
  build_row 'claim_id="c-live"' "file=\"$LIVE/scripts/a.py\"" \
    "change_context={\"diff_ref\":\"deadbeef\",\"changed_files\":[\"$LIVE/scripts/a.py\"],\"summary\":\"fixture change\"}"
  build_row 'claim_id="c-dead"' "file=\"$GONE/scripts/a.py\"" \
    "change_context={\"diff_ref\":\"deadbeef\",\"changed_files\":[\"$GONE/scripts/a.py\"],\"summary\":\"fixture change\"}"
} > "$KDIR/_work/zeta/task-claims.jsonl"
BEFORE=$(sha_of_file "$KDIR/_work/zeta/task-claims.jsonl")
set +e
OUT=$(python3 "$DRIVER" --kdir "$KDIR" --apply --artifact-dir "$KDIR/_work/zeta-artifacts" 2>&1)
RC=$?
set -e
assert_contains "both rows deferred while the file has a live capturing session" "$OUT" "2 deferred"
assert_eq "nothing mutated" "$(sha_of_file "$KDIR/_work/zeta/task-claims.jsonl")" "$BEFORE"
assert_eq "deferral is not a failure" "$RC" "0"
# Once the worktree is reclaimed, a later run picks the rows up.
rm -rf "$LIVE"
OUT=$(python3 "$DRIVER" --kdir "$KDIR" --apply --artifact-dir "$KDIR/_work/zeta-artifacts" 2>&1)
assert_contains "reclaimed worktree makes both rows repairable" "$OUT" "repaired 2"
assert_eq "previously-live row now canonical" \
  "$(line_of "$KDIR/_work/zeta/task-claims.jsonl" c-live file)" '"scripts/a.py"'

echo
echo "=== Test 6: preconditions refuse, and refusal mutates nothing ==="
# 6a: no derivable strip prefix.
KDIR=$(new_store t6a)
mkdir -p "$KDIR/_work/eta" "$KDIR/_work/eta-artifacts"
GONE="$TEST_DIR/t6a-tree/_sessions/worktrees/wt-gone"
{
  build_row 'claim_id="c-bad"' "file=\"$GONE/scripts/a.py\"" 'file_relative="scripts/other.py"' \
    "change_context={\"diff_ref\":\"deadbeef\",\"changed_files\":[\"$GONE/scripts/a.py\"],\"summary\":\"fixture change\"}"
  build_row 'claim_id="c-ok"' "file=\"$GONE/scripts/b.py\"" 'file_relative="scripts/b.py"' \
    "change_context={\"diff_ref\":\"deadbeef\",\"changed_files\":[\"$GONE/scripts/b.py\"],\"summary\":\"fixture change\"}"
} > "$KDIR/_work/eta/task-claims.jsonl"
BEFORE=$(sha_of_file "$KDIR/_work/eta/task-claims.jsonl")
set +e
OUT=$(python3 "$DRIVER" --kdir "$KDIR" --apply --artifact-dir "$KDIR/_work/eta-artifacts" 2>&1)
RC=$?
set -e
assert_eq "refusal exits non-zero" "$RC" "1"
assert_contains "refusal names the missing suffix relationship" "$OUT" "does not end with '/' + file_relative"
assert_eq "no row mutated, including the healthy sibling" \
  "$(sha_of_file "$KDIR/_work/eta/task-claims.jsonl")" "$BEFORE"

# 6b: duplicate claim_id in the same file.
KDIR=$(new_store t6b)
mkdir -p "$KDIR/_work/theta" "$KDIR/_work/theta-artifacts"
GONE="$TEST_DIR/t6b-tree/_sessions/worktrees/wt-gone"
{
  build_row 'claim_id="c-dup"' "file=\"$GONE/scripts/a.py\"" \
    "change_context={\"diff_ref\":\"deadbeef\",\"changed_files\":[\"$GONE/scripts/a.py\"],\"summary\":\"fixture change\"}"
  build_row 'claim_id="c-dup"' "file=\"$GONE/scripts/b.py\"" 'file_relative="scripts/b.py"' \
    "change_context={\"diff_ref\":\"deadbeef\",\"changed_files\":[\"$GONE/scripts/b.py\"],\"summary\":\"fixture change\"}"
} > "$KDIR/_work/theta/task-claims.jsonl"
BEFORE=$(sha_of_file "$KDIR/_work/theta/task-claims.jsonl")
set +e
OUT=$(python3 "$DRIVER" --kdir "$KDIR" --apply --artifact-dir "$KDIR/_work/theta-artifacts" 2>&1)
RC=$?
set -e
assert_eq "duplicate claim_id refused" "$RC" "1"
assert_contains "refusal explains the first-match hazard" "$OUT" "occurs 2 times in this file"
assert_eq "duplicate-id file untouched" "$(sha_of_file "$KDIR/_work/theta/task-claims.jsonl")" "$BEFORE"

# 6c: `file` absent from changed_files.
KDIR=$(new_store t6c)
mkdir -p "$KDIR/_work/iota" "$KDIR/_work/iota-artifacts"
GONE="$TEST_DIR/t6c-tree/_sessions/worktrees/wt-gone"
build_row "file=\"$GONE/scripts/a.py\"" \
  "change_context={\"diff_ref\":\"deadbeef\",\"changed_files\":[\"$GONE/scripts/z.py\"],\"summary\":\"fixture change\"}" \
  > "$KDIR/_work/iota/task-claims.jsonl"
set +e
OUT=$(python3 "$DRIVER" --kdir "$KDIR" --apply --artifact-dir "$KDIR/_work/iota-artifacts" 2>&1)
RC=$?
set -e
assert_eq "row whose changed_files omits file is refused" "$RC" "1"
assert_contains "refusal names the coupling" "$OUT" "does not contain \`file\` verbatim"

echo
echo "=== Test 7: confinement refusal when the writer touches another field ==="
KDIR=$(new_store t7)
mkdir -p "$KDIR/_work/kappa" "$KDIR/_work/kappa-artifacts"
GONE="$TEST_DIR/t7-tree/_sessions/worktrees/wt-gone"
build_row "file=\"$GONE/scripts/a.py\"" \
  "change_context={\"diff_ref\":\"deadbeef\",\"changed_files\":[\"$GONE/scripts/a.py\"],\"summary\":\"fixture change\"}" \
  > "$KDIR/_work/kappa/task-claims.jsonl"
# A writer stand-in that performs the requested merge and also edits `claim`.
STUB="$TEST_DIR/overreaching-update.sh"
cat > "$STUB" <<STUBEOF
#!/usr/bin/env bash
set -euo pipefail
MERGE=\$(cat)
printf '%s' "\$MERGE" | bash "$UPDATE" "\$@"
python3 - "\$@" <<'PY'
import json, sys
path = sys.argv[sys.argv.index("--task-claims-path") + 1]
cid = sys.argv[sys.argv.index("--claim-id") + 1]
out = []
for line in open(path, encoding="utf-8"):
    s = line.strip()
    if s:
        row = json.loads(s)
        if row.get("claim_id") == cid:
            row["claim"] = "an unrelated edit"
            line = json.dumps(row, separators=(",", ":")) + "\n"
    out.append(line)
open(path, "w", encoding="utf-8").writelines(out)
PY
STUBEOF
chmod +x "$STUB"
set +e
OUT=$(python3 "$DRIVER" --kdir "$KDIR" --apply --artifact-dir "$KDIR/_work/kappa-artifacts" \
  --evidence-update "$STUB" 2>&1)
RC=$?
set -e
assert_eq "confinement violation exits non-zero" "$RC" "1"
assert_contains "violation is reported" "$OUT" "CONFINEMENT VIOLATION"
assert_contains "the offending field is named" "$OUT" "field changed outside the reference: claim"
assert_contains "the run stops rather than continuing" "$OUT" "stopping"

echo
echo "=== Test 8: idempotent replay ==="
KDIR=$(new_store t8)
mkdir -p "$KDIR/_work/lambda" "$KDIR/_work/lambda-artifacts"
GONE="$TEST_DIR/t8-tree/_sessions/worktrees/wt-gone"
build_row "file=\"$GONE/scripts/a.py\"" \
  "change_context={\"diff_ref\":\"deadbeef\",\"changed_files\":[\"$GONE/scripts/a.py\"],\"summary\":\"fixture change\"}" \
  > "$KDIR/_work/lambda/task-claims.jsonl"
python3 "$DRIVER" --kdir "$KDIR" --apply --artifact-dir "$KDIR/_work/lambda-artifacts" >/dev/null 2>&1
AFTER_FIRST=$(sha_of_file "$KDIR/_work/lambda/task-claims.jsonl")
set +e
OUT=$(python3 "$DRIVER" --kdir "$KDIR" --apply --artifact-dir "$KDIR/_work/lambda-artifacts" --json 2>&1)
RC=$?
set -e
assert_eq "replay exits zero" "$RC" "0"
assert_eq "replay leaves the file byte-identical" \
  "$(sha_of_file "$KDIR/_work/lambda/task-claims.jsonl")" "$AFTER_FIRST"
assert_contains "replay applies nothing" "$OUT" '"applied": 0'
assert_contains "replay finds no candidates" "$OUT" '"candidates": 0'
OUT=$(python3 "$DRIVER" --kdir "$KDIR" --json 2>&1)
assert_contains "dry-run replay also reports zero candidates" "$OUT" '"candidates": 0'

echo
echo "=== Test 9: replay does not overwrite the artifacts of the run that did the work ==="
KDIR=$(new_store t9)
mkdir -p "$KDIR/_work/mu" "$KDIR/_work/mu-artifacts"
GONE="$TEST_DIR/t9-tree/_sessions/worktrees/wt-gone"
build_row "file=\"$GONE/scripts/a.py\"" \
  "change_context={\"diff_ref\":\"deadbeef\",\"changed_files\":[\"$GONE/scripts/a.py\"],\"summary\":\"fixture change\"}" \
  > "$KDIR/_work/mu/task-claims.jsonl"
python3 "$DRIVER" --kdir "$KDIR" --apply --artifact-dir "$KDIR/_work/mu-artifacts" >/dev/null 2>&1
MANIFEST_SHA=$(sha_of_file "$KDIR/_work/mu-artifacts/canonicalize-worktree-paths-manifest.json")
REPORT_SHA=$(sha_of_file "$KDIR/_work/mu-artifacts/canonicalize-worktree-paths-verification.md")
OUT=$(python3 "$DRIVER" --kdir "$KDIR" --apply --artifact-dir "$KDIR/_work/mu-artifacts" 2>&1)
assert_contains "replay says it wrote nothing" "$OUT" "wrote nothing"
assert_eq "manifest of the real run preserved" \
  "$(sha_of_file "$KDIR/_work/mu-artifacts/canonicalize-worktree-paths-manifest.json")" "$MANIFEST_SHA"
assert_eq "verification report of the real run preserved" \
  "$(sha_of_file "$KDIR/_work/mu-artifacts/canonicalize-worktree-paths-verification.md")" "$REPORT_SHA"

echo
echo "=== Test 10: --verify re-derives the artifacts from a committed pre-image ==="
KDIR=$(new_store t10)
mkdir -p "$KDIR/_work/nu" "$KDIR/_work/nu-artifacts"
GONE="$TEST_DIR/t10-tree/_sessions/worktrees/wt-gone"
build_row "file=\"$GONE/scripts/a.py\"" \
  "change_context={\"diff_ref\":\"deadbeef\",\"changed_files\":[\"$GONE/scripts/a.py\"],\"summary\":\"fixture change\"}" \
  > "$KDIR/_work/nu/task-claims.jsonl"
git -C "$KDIR" init -q
git -C "$KDIR" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$KDIR" -c user.email=t@t -c user.name=t commit -qm "pre-image"
BASELINE=$(git -C "$KDIR" rev-parse HEAD)
python3 "$DRIVER" --kdir "$KDIR" --apply --artifact-dir "$KDIR/_work/nu-artifacts" >/dev/null 2>&1
rm -f "$KDIR/_work/nu-artifacts/canonicalize-worktree-paths-"*
OUT=$(python3 "$DRIVER" --kdir "$KDIR" --verify --baseline "$BASELINE" --artifact-dir "$KDIR/_work/nu-artifacts" 2>&1)
assert_contains "verify re-derives the repair from the baseline" "$OUT" "1 repaired"
assert_contains "verify finds no unexplained line deltas" "$OUT" "0 confinement problem(s), 0 unexplained line delta(s)"
assert_contains "verify report confirms confinement independently" \
  "$(cat "$KDIR/_work/nu-artifacts/canonicalize-worktree-paths-verification.md")" \
  "rows repaired and re-verified as confined: 1 / 1"
assert_contains "verify report names its baseline" \
  "$(cat "$KDIR/_work/nu-artifacts/canonicalize-worktree-paths-verification.md")" \
  "pre-image taken from the knowledge store at"
# An unrelated edit to another row shows up as an unexplained line delta.
python3 - "$KDIR/_work/nu/task-claims.jsonl" <<'PY'
import json, sys
p = sys.argv[1]
rows = [json.loads(line) for line in open(p, encoding="utf-8") if line.strip()]
rows[0]["claim"] = "tampered"
open(p, "w", encoding="utf-8").write("".join(json.dumps(r, separators=(",", ":")) + "\n" for r in rows))
PY
set +e
OUT=$(python3 "$DRIVER" --kdir "$KDIR" --verify --baseline "$BASELINE" --artifact-dir "$KDIR/_work/nu-artifacts" 2>&1)
RC=$?
set -e
assert_eq "verify flags a row whose other fields drifted" "$RC" "1"
assert_contains "verify names the drifted field" \
  "$(cat "$KDIR/_work/nu-artifacts/canonicalize-worktree-paths-verification.md")" \
  "field changed outside the reference: claim"

echo
echo "======================================"
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
