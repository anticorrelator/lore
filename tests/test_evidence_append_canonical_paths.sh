#!/usr/bin/env bash
# test_evidence_append_canonical_paths.sh — verifies evidence-append.sh records
# `file` as a repo-relative path, so a claim captured inside a git worktree is
# still groundable after that worktree is removed.
#
# Covers:
#   1. Worktree capture: `file` and `file_relative` both land repo-relative, the
#      matching change_context.changed_files entry moves with `file`, and the
#      row passes validate-tier2.sh.
#   2. Durability: after `git worktree remove`, the recorded `file` resolves at
#      HEAD in the main checkout, and reverse-auditor-inline-evidence.py grounds
#      the claim from it.
#   3. Sibling changed_files entries under the same repo root are stripped by
#      the same derived prefix.
#   4. Capture from a plain (non-worktree) checkout is canonicalized the same
#      way — the rule is unconditional wherever a git root is derivable.
#   5. No git root: `file` is left verbatim and no file_relative is stamped.
#   6. An already-relative `file` passes through unchanged.
#   7. audit-artifact.sh's task-claims extractor carries file_relative,
#      captured_at_sha, and captured_origin_ref into claim_payload — without
#      them the resolver has no durable anchor to prefer.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
APPEND="$SCRIPTS_DIR/evidence-append.sh"
VALIDATE="$SCRIPTS_DIR/validate-tier2.sh"
NORMALIZE_PY="$SCRIPTS_DIR/snippet_normalize.py"
RESOLVER="$SCRIPTS_DIR/reverse-auditor-inline-evidence.py"

PASS=0
FAIL=0
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

TEST_ROOT="$(mktemp -d -t lore-append-canon.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

git_quiet() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}" >/dev/null 2>&1; }

SNIPPET='def alpha():
    return 1'
HASH=$(printf '%s' "$SNIPPET" | python3 "$NORMALIZE_PY" --hash)

build_row() {
  # build_row <claim_id> <file> <changed_files-json>
  python3 - "$1" "$2" "$3" "$SNIPPET" "$HASH" <<'PYEOF'
import json, sys
claim_id, file_path, changed_files, snippet, snippet_hash = sys.argv[1:6]
print(json.dumps({
    "claim_id": claim_id,
    "tier": "task-evidence",
    "claim": "alpha returns 1",
    "producer_role": "worker",
    "protocol_slot": "implement-phase-1",
    "task_id": "task-1",
    "phase_id": "phase-1",
    "scale": "implementation",
    "file": file_path,
    "line_range": "1-2",
    "exact_snippet": snippet,
    "normalized_snippet_hash": snippet_hash,
    "falsifier": "alpha returns something other than 1",
    "why_this_work_needs_it": "grounds the capture-path assertion",
    "captured_at_sha": "deadbeef",
    "change_context": {
        "diff_ref": None,
        "changed_files": json.loads(changed_files),
        "summary": "canonical-path capture fixture",
    },
}))
PYEOF
}

# --- The lore-checkout-shaped main repo plus a worktree off it ---
MAIN_REPO="$TEST_ROOT/main"
mkdir -p "$MAIN_REPO/scripts"
git_quiet "$MAIN_REPO" init
cat > "$MAIN_REPO/scripts/foo.py" <<'PY'
def alpha():
    return 1
PY
printf 'sibling\n' > "$MAIN_REPO/scripts/bar.py"
git_quiet "$MAIN_REPO" add -A
git_quiet "$MAIN_REPO" commit -m "initial"

WORKTREE="$TEST_ROOT/wt-abc123"
git_quiet "$MAIN_REPO" worktree add "$WORKTREE" HEAD

KDIR="$TEST_ROOT/kdir"
mkdir -p "$KDIR/_work/wi"
CLAIMS="$KDIR/_work/wi/task-claims.jsonl"

row_field() { python3 -c "
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
row=next(r for r in rows if r['claim_id']==sys.argv[2])
v=row
for k in sys.argv[3].split('.'):
    v=v.get(k) if isinstance(v,dict) else None
print(json.dumps(v) if not isinstance(v,str) else v)
" "$1" "$2" "$3"; }

echo "Test 1: capture inside a worktree records repo-relative file + changed_files"
ROW=$(build_row wt-1 "$WORKTREE/scripts/foo.py" \
  "[\"$WORKTREE/scripts/foo.py\", \"$WORKTREE/scripts/bar.py\"]")
(cd "$WORKTREE" && printf '%s' "$ROW" | bash "$APPEND" --kdir "$KDIR" --work-item wi >/dev/null 2>&1)
assert_eq "file is repo-relative" "$(row_field "$CLAIMS" wt-1 file)" "scripts/foo.py"
assert_eq "file_relative equals file" "$(row_field "$CLAIMS" wt-1 file_relative)" "scripts/foo.py"
assert_eq "changed_files stripped by the same prefix" \
  "$(row_field "$CLAIMS" wt-1 change_context.changed_files)" \
  '["scripts/foo.py", "scripts/bar.py"]'
assert_eq "row passes validate-tier2.sh" \
  "$(head -1 "$CLAIMS" | bash "$VALIDATE" >/dev/null 2>&1 && echo ok || echo fail)" "ok"

echo ""
echo "Test 2: the recorded reference survives worktree removal"
git_quiet "$MAIN_REPO" worktree remove --force "$WORKTREE"
assert_eq "worktree directory is gone" "$([[ -d "$WORKTREE" ]] && echo present || echo gone)" "gone"
RECORDED=$(row_field "$CLAIMS" wt-1 file)
assert_eq "recorded file resolves at HEAD in the main checkout" \
  "$(git -C "$MAIN_REPO" show "HEAD:$RECORDED" >/dev/null 2>&1 && echo ok || echo fail)" "ok"

# The audit-side resolver grounds the claim from the same recorded reference.
RA_INPUT="$TEST_ROOT/ra-input.json"
RA_OUT="$TEST_ROOT/ra-out.json"
python3 - "$CLAIMS" "$RA_INPUT" <<'PYEOF'
import json, sys
claims_path, out_path = sys.argv[1:3]
rows = [json.loads(l) for l in open(claims_path) if l.strip()]
row = next(r for r in rows if r["claim_id"] == "wt-1")
json.dump({
    "artifact_id": "wi",
    "work_item": "wi",
    "curated_top_k": [{
        "claim_id": row["claim_id"],
        "claim_text": row["claim"],
        "file": row["file"],
        "file_relative": row.get("file_relative"),
        "line_range": row["line_range"],
        "exact_snippet": row["exact_snippet"],
    }],
    "change_context": row["change_context"],
    "referenced_files": [],
}, open(out_path, "w"), indent=2)
PYEOF
python3 "$RESOLVER" "$RA_INPUT" "$RA_OUT" --lore-repo "$MAIN_REPO" --kdir "$KDIR" >/dev/null 2>&1
assert_eq "resolver grounds the post-removal claim" \
  "$(python3 -c "
import json,sys
w=json.load(open(sys.argv[1]))['inlined_evidence']['claim_windows'][0]
print(f\"{w['resolved']}|{w['content_locate_verdict']}\")
" "$RA_OUT")" "True|verified"

echo ""
echo "Test 3: capture from a plain checkout is canonicalized the same way"
ROW=$(build_row plain-1 "$MAIN_REPO/scripts/foo.py" "[\"$MAIN_REPO/scripts/foo.py\"]")
(cd "$MAIN_REPO" && printf '%s' "$ROW" | bash "$APPEND" --kdir "$KDIR" --work-item wi >/dev/null 2>&1)
assert_eq "file is repo-relative" "$(row_field "$CLAIMS" plain-1 file)" "scripts/foo.py"
assert_eq "changed_files matches file" \
  "$(row_field "$CLAIMS" plain-1 change_context.changed_files)" '["scripts/foo.py"]'

echo ""
echo "Test 4: no derivable git root — file is left verbatim"
NON_GIT="$TEST_ROOT/nogit"
mkdir -p "$NON_GIT"
printf 'def alpha():\n    return 1\n' > "$NON_GIT/foo.py"
ROW=$(build_row nogit-1 "$NON_GIT/foo.py" "[\"$NON_GIT/foo.py\"]")
(cd "$MAIN_REPO" && printf '%s' "$ROW" | bash "$APPEND" --kdir "$KDIR" --work-item wi >/dev/null 2>&1)
assert_eq "file unchanged" "$(row_field "$CLAIMS" nogit-1 file)" "$NON_GIT/foo.py"
assert_eq "file_relative absent" "$(row_field "$CLAIMS" nogit-1 file_relative)" "null"
assert_eq "changed_files unchanged" \
  "$(row_field "$CLAIMS" nogit-1 change_context.changed_files)" "[\"$NON_GIT/foo.py\"]"

echo ""
echo "Test 5: an already-relative file passes through unchanged"
ROW=$(build_row rel-1 "scripts/foo.py" '["scripts/foo.py"]')
(cd "$MAIN_REPO" && printf '%s' "$ROW" | bash "$APPEND" --kdir "$KDIR" --work-item wi >/dev/null 2>&1)
assert_eq "file unchanged" "$(row_field "$CLAIMS" rel-1 file)" "scripts/foo.py"
assert_eq "file_relative equals file" "$(row_field "$CLAIMS" rel-1 file_relative)" "scripts/foo.py"
assert_eq "changed_files unchanged" \
  "$(row_field "$CLAIMS" rel-1 change_context.changed_files)" '["scripts/foo.py"]'

echo ""
echo "Test 6: every appended row validates"
BAD=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  printf '%s' "$line" | bash "$VALIDATE" >/dev/null 2>&1 || BAD=$((BAD + 1))
done < "$CLAIMS"
assert_eq "no invalid rows in the appended file" "$BAD" "0"

echo ""
echo "Test 7: the audit extractor carries the durable anchor into claim_payload"
DRY_JSON=$(bash "$SCRIPTS_DIR/audit-artifact.sh" "$CLAIMS" --kdir "$KDIR" --dry-run --json 2>/dev/null)
payload_field() { printf '%s' "$DRY_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=next(c for c in d['claim_payload'] if c['claim_id']==sys.argv[1])
print(c.get(sys.argv[2]))
" "$1" "$2"; }
assert_eq "claim_payload carries file_relative" "$(payload_field wt-1 file_relative)" "scripts/foo.py"
assert_eq "claim_payload carries captured_at_sha" "$(payload_field wt-1 captured_at_sha)" "deadbeef"
assert_eq "claim_payload exposes captured_origin_ref" \
  "$(printf '%s' "$DRY_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=next(c for c in d['claim_payload'] if c['claim_id']=='wt-1')
print('present' if 'captured_origin_ref' in c else 'absent')
")" "present"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
