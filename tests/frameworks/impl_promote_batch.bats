#!/usr/bin/env bats
# impl_promote_batch.bats — Coverage for `lore impl promote-batch` (impl-promote-batch.sh)
#
# Asserts:
#   - --candidates is required; missing/unreadable/malformed file exits 1
#     BEFORE any write
#   - empty candidate list is valid input: 0/0 summary still logged, exit 0
#   - source-artifact verification against this work item's task-claims.jsonl
#     (missing ids named; empty/missing source_artifact_ids rejected;
#     cross-work-item work_item rejected; duplicate claim_id rejected)
#   - producer_role -> template-version attribution (worker/advisor/
#     implement-lead; absent role defaults to implement-lead and the
#     defaulting is logged; unknown role rejected)
#   - one `lore promote` per accepted candidate (promoted-commons.jsonl rows);
#     a promote-rejected row lands in the rejected list without aborting the
#     batch and the verb still exits 0
#   - exactly one summary execution-log entry per invocation, source impl-verb
#   - side effects limited to lore promote + summary log
#   - tri-state reference resolution passthrough; --json output shape
#
# All tests use an isolated knowledge directory via LORE_KNOWLEDGE_DIR.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE_CLI="$REPO_DIR/cli/lore"
PROMOTE_SH="$REPO_DIR/scripts/impl-promote-batch.sh"

setup() {
  [ -x "$LORE_CLI" ] || skip "cli/lore missing"
  [ -f "$PROMOTE_SH" ] || skip "impl-promote-batch.sh missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  command -v jq >/dev/null 2>&1 || skip "jq required for lore-promote.sh"

  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"
  printf '{"version": 1}\n' > "$TEST_KDIR/_manifest.json"

  WORK_DIR="$TEST_KDIR/_work"
  mkdir -p "$WORK_DIR/active-item" "$WORK_DIR/second-item"
  printf '{"title": "Active Item", "intent_anchor": "Ship it."}\n' > "$WORK_DIR/active-item/_meta.json"
  printf '{"title": "Second Item"}\n' > "$WORK_DIR/second-item/_meta.json"
  printf '{"claim_id":"c1"}\n{"claim_id":"c2"}\n' > "$WORK_DIR/active-item/task-claims.jsonl"

  CAND_FILE="$TEST_KDIR/candidates.json"
}

teardown() {
  if [ -n "${TEST_KDIR:-}" ] && [ -d "$TEST_KDIR" ]; then
    rm -rf "$TEST_KDIR"
  fi
  unset LORE_KNOWLEDGE_DIR
}

log_file() { echo "$WORK_DIR/active-item/execution-log.md"; }
commons_rows() { echo "$WORK_DIR/active-item/promoted-commons.jsonl"; }

# Valid Tier 3 candidate row; $1 claim_id, $2 producer_role ("" omits the
# field), $3 comma-separated source_artifact_ids.
make_candidate() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, sys
cid, role, sids = sys.argv[1:4]
row = {
    "claim_id": cid, "tier": "reusable", "claim": f"claim for {cid}",
    "protocol_slot": "implement-step-3", "scale": "implementation",
    "why_future_agent_cares": "because", "falsifier": "if not",
    "related_files": ["scripts/example.sh"],
    "source_artifact_ids": [s for s in sids.split(",") if s],
    "work_item": "active-item", "captured_at_sha": "abc123",
}
if role:
    row["producer_role"] = role
print(json.dumps(row))
PYEOF
}

write_candidates() {
  # Args: candidate JSON objects, one per arg — written as a JSON array.
  python3 - "$CAND_FILE" "$@" <<'PYEOF'
import json, sys
path = sys.argv[1]
rows = [json.loads(a) for a in sys.argv[2:]]
with open(path, "w") as f:
    json.dump(rows, f)
PYEOF
}

run_batch() {
  run bash "$LORE_CLI" impl promote-batch active-item --candidates "$CAND_FILE" \
    --lead-template-version aaaaaaaaaaaa --worker-template-version bbbbbbbbbbbb \
    --advisor-template-version cccccccccccc "$@"
}

# bats `run` merges stderr into $output — take the last JSON object line.
json_payload() {
  echo "$output" | python3 -c '
import json, sys
last = None
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        last = json.loads(line)
    except ValueError:
        continue
print(json.dumps(last))
'
}

# --- Required candidates file (error before any write) ------------------------

@test "missing --candidates exits 1 naming the flag, no log written" {
  run bash "$LORE_CLI" impl promote-batch active-item
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--candidates"
  [ ! -f "$(log_file)" ]
}

@test "nonexistent candidates file exits 1, no log written" {
  run bash "$LORE_CLI" impl promote-batch active-item --candidates "$TEST_KDIR/nope.json"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "not found"
  [ ! -f "$(log_file)" ]
}

@test "malformed candidates file exits 1 before any write" {
  echo "not json at all {" > "$CAND_FILE"
  run_batch
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "neither a JSON array nor JSONL"
  [ ! -f "$(log_file)" ]
  [ ! -f "$(commons_rows)" ]
}

# --- Empty batch is valid input -------------------------------------------------

@test "empty candidate array logs a 0/0 summary and exits 0" {
  echo '[]' > "$CAND_FILE"
  run_batch
  [ "$status" -eq 0 ]
  grep -q '^Tier 3 promotion summary: 0 accepted, 0 rejected$' "$(log_file)"
  grep -q '^Accepted ids: None$' "$(log_file)"
  grep -q '^Rejected reasons: None$' "$(log_file)"
  [ "$(grep -c '^## ' "$(log_file)")" -eq 1 ]
}

# --- Accepted path ---------------------------------------------------------------

@test "valid candidate promotes via lore promote and lands in promoted-commons.jsonl" {
  write_candidates "$(make_candidate t3-good worker c1,c2)"
  run_batch
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "1 accepted, 0 rejected"
  [ -f "$(commons_rows)" ]
  python3 - "$(commons_rows)" <<'PYEOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(rows) == 1
assert rows[0]["claim_id"] == "t3-good"
assert rows[0]["entry_path"]
PYEOF
}

@test "summary log entry has source impl-verb, accepted ids, and 12-hex Template-version" {
  write_candidates "$(make_candidate t3-good worker c1,c2)"
  run_batch
  [ "$status" -eq 0 ]
  grep -q "source: impl-verb" "$(log_file)"
  grep -q '^Tier 3 promotion summary: 1 accepted, 0 rejected$' "$(log_file)"
  grep -q '^Accepted ids: t3-good$' "$(log_file)"
  grep -qE '^Template-version: [0-9a-f]{12}$' "$(log_file)"
}

@test "exactly one execution-log entry per invocation even with rejections" {
  write_candidates "$(make_candidate t3-good worker c1)" "$(make_candidate t3-bad worker missing-id)"
  run_batch
  [ "$status" -eq 0 ]
  [ "$(grep -c '^## ' "$(log_file)")" -eq 1 ]
}

@test "side effects are limited to lore promote artifacts and the summary log" {
  write_candidates "$(make_candidate t3-good worker c1,c2)"
  run_batch
  [ "$status" -eq 0 ]
  for f in "$WORK_DIR/active-item"/*; do
    case "$(basename "$f")" in
      _meta.json|task-claims.jsonl|execution-log.md|promoted-commons.jsonl) ;;
      *) echo "unexpected file: $f"; false ;;
    esac
  done
}

# --- Source-artifact verification -------------------------------------------------

@test "candidate citing missing claim_ids is rejected with the ids named" {
  write_candidates "$(make_candidate t3-stale worker c1,nope-9)"
  run_batch
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "0 accepted, 1 rejected"
  echo "$output" | grep -q "missing claim_ids: nope-9"
  grep -q "missing claim_ids: nope-9" "$(log_file)"
  [ ! -f "$(commons_rows)" ]
}

@test "candidate with empty source_artifact_ids is rejected" {
  write_candidates "$(make_candidate t3-rootless worker "")"
  run_batch
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "source_artifact_ids missing or empty"
}

@test "cross-work-item candidate is rejected" {
  cand=$(make_candidate t3-foreign worker c1 | python3 -c 'import json,sys; r=json.load(sys.stdin); r["work_item"]="second-item"; print(json.dumps(r))')
  write_candidates "$cand"
  run_batch
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "cross-work-item"
  [ ! -f "$(commons_rows)" ]
}

@test "duplicate claim_id in the batch rejects the second occurrence" {
  write_candidates "$(make_candidate t3-dup worker c1)" "$(make_candidate t3-dup worker c2)"
  run_batch
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "1 accepted, 1 rejected"
  echo "$output" | grep -q "duplicate claim_id"
}

@test "candidate missing claim_id is rejected with a positional label" {
  echo '[{"tier": "reusable"}]' > "$CAND_FILE"
  run_batch
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "candidate-1"
  echo "$output" | grep -q "missing claim_id"
}

# --- producer_role -> template-version attribution ---------------------------------

@test "worker candidate is attributed the worker template version" {
  write_candidates "$(make_candidate t3-w worker c1)"
  run_batch --json
  [ "$status" -eq 0 ]
  json_payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
a = d["accepted"][0]
assert a["producer_role"] == "worker"
assert a["template_version"] == "bbbbbbbbbbbb"
assert a["producer_role_defaulted"] is False
'
}

@test "absent producer_role defaults to implement-lead with lead attribution and a log note" {
  write_candidates "$(make_candidate t3-nolead "" c1)"
  run_batch --json
  [ "$status" -eq 0 ]
  json_payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
a = d["accepted"][0]
assert a["producer_role"] == "implement-lead"
assert a["template_version"] == "aaaaaaaaaaaa"
assert a["producer_role_defaulted"] is True
'
  grep -q '^Producer-role defaulting: t3-nolead (defaulted to implement-lead)$' "$(log_file)"
}

@test "unmappable producer_role is rejected, not promoted" {
  write_candidates "$(make_candidate t3-res researcher c1)"
  run_batch
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no template-version attribution for producer_role 'researcher'"
  [ ! -f "$(commons_rows)" ]
}

# --- lore promote rejection is contained --------------------------------------------

@test "promote-rejected row lands in rejected list without aborting the batch" {
  bad=$(make_candidate t3-invalid worker c1 | python3 -c 'import json,sys; r=json.load(sys.stdin); del r["falsifier"]; print(json.dumps(r))')
  write_candidates "$bad" "$(make_candidate t3-good worker c2)"
  run_batch
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "1 accepted, 1 rejected"
  echo "$output" | grep -q "lore promote rejected"
  python3 - "$(commons_rows)" <<'PYEOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert [r["claim_id"] for r in rows] == ["t3-good"]
PYEOF
}

# --- JSONL input format ---------------------------------------------------------------

@test "JSONL candidates file is accepted" {
  { make_candidate t3-a worker c1; make_candidate t3-b advisor c2; } > "$CAND_FILE"
  run_batch
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "2 accepted, 0 rejected"
}

# --- Reference resolution: tri-state passthrough ----------------------------------------

@test "no-match reference exits 1" {
  echo '[]' > "$CAND_FILE"
  run bash "$LORE_CLI" impl promote-batch no-such-item-zzz --candidates "$CAND_FILE"
  [ "$status" -eq 1 ]
}

@test "ambiguous reference exits 2" {
  echo '[]' > "$CAND_FILE"
  cat > "$WORK_DIR/_index.json" <<'EOF'
{
  "version": 1,
  "plans": [
    {"slug": "active-item", "title": "Active Item", "tags": ["shared-tag"], "branches": []},
    {"slug": "second-item", "title": "Second Item", "tags": ["shared-tag"], "branches": []}
  ],
  "archived": []
}
EOF
  run bash "$LORE_CLI" impl promote-batch shared-tag --candidates "$CAND_FILE"
  [ "$status" -eq 2 ]
}

@test "archived work item is rejected" {
  echo '[]' > "$CAND_FILE"
  mkdir -p "$WORK_DIR/_archive/done-item"
  printf '{"title": "Done Item"}\n' > "$WORK_DIR/_archive/done-item/_meta.json"
  run bash "$LORE_CLI" impl promote-batch done-item --candidates "$CAND_FILE"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "archived"
}

# --- JSON output -------------------------------------------------------------------------

@test "--json returns accepted/rejected lists with counts and log path" {
  write_candidates "$(make_candidate t3-good worker c1)" "$(make_candidate t3-bad worker missing-id)"
  run_batch --json
  [ "$status" -eq 0 ]
  json_payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["slug"] == "active-item"
assert d["candidates_total"] == 2
assert d["accepted_count"] == 1
assert d["rejected_count"] == 1
assert d["accepted"][0]["claim_id"] == "t3-good"
assert d["rejected"][0]["claim_id"] == "t3-bad"
assert "missing claim_ids" in d["rejected"][0]["reason"]
assert d["log_path"].endswith("execution-log.md")
'
}

@test "--json on validation error returns error object with exit 1" {
  run bash "$LORE_CLI" impl promote-batch active-item --json
  [ "$status" -eq 1 ]
  json_payload | python3 -c 'import json, sys; d = json.loads(sys.stdin.read()); assert "error" in d'
}
