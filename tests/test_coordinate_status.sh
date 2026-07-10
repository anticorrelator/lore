#!/usr/bin/env bash
# test_coordinate_status.sh — End-to-end acceptance for the read-only composer.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COORDINATE="$REPO_ROOT/scripts/coordinate-status.sh"
CLI="$REPO_ROOT/cli/lore"
TEST_DIR=$(mktemp -d)
BASE="$TEST_DIR/base"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$label"; else fail "$label" "expected '$expected', got '$actual'"; fi
}
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$label"; else fail "$label" "missing '$needle'"; fi
}
assert_zero() { if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "exit=$2"; fi; }

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

snapshot_store() {
  local store="$1" destination="$2"
  python3 - "$store" > "$destination" <<'PY'
import hashlib, json, os, stat, sys
root = os.path.abspath(sys.argv[1])
rows = []
for current, dirs, files in os.walk(root):
    dirs.sort(); files.sort()
    for name in ["."] + dirs + files:
        path = current if name == "." else os.path.join(current, name)
        st = os.lstat(path)
        rel = os.path.relpath(path, root)
        row = {
            "path": rel,
            "mode": stat.S_IMODE(st.st_mode),
            "size": st.st_size,
            "mtime_ns": st.st_mtime_ns,
            "ctime_ns": st.st_ctime_ns,
            "kind": "dir" if stat.S_ISDIR(st.st_mode) else "file",
        }
        if stat.S_ISREG(st.st_mode):
            with open(path, "rb") as fh:
                row["sha256"] = hashlib.sha256(fh.read()).hexdigest()
        rows.append(row)
print(json.dumps(rows, sort_keys=True, separators=(",", ":")))
PY
}

setup_store() {
  local kdir="$1"
  rm -rf "$kdir"
  mkdir -p "$kdir/_work/actionable" "$kdir/_work/blocked" \
    "$kdir/_work/merged-item" "$kdir/_work/no-evidence" \
    "$kdir/_sessions/instances" "$kdir/_scorecards" "$kdir/_evolve"

  cat > "$kdir/_work/_index.json" <<'JSON'
{
  "version": 1,
  "repo": "fixture",
  "last_updated": "2026-07-09T00:00:00Z",
  "plans": [
    {"slug":"actionable","title":"Actionable","status":"active","blocked_by":[],"has_plan_doc":true,"has_execution_log":false},
    {"slug":"blocked","title":"Blocked","status":"active","blocked_by":["dependency"],"has_plan_doc":true,"has_execution_log":false},
    {"slug":"merged-item","title":"Merged item","status":"active","blocked_by":[],"has_plan_doc":false,"has_execution_log":true},
    {"slug":"no-evidence","title":"No evidence","status":"active","blocked_by":[],"has_plan_doc":true,"has_execution_log":false}
  ],
  "archived": []
}
JSON
  cat > "$kdir/_work/actionable/_meta.json" <<'JSON'
{"slug":"actionable","title":"Actionable","status":"active","blocked_by":[]}
JSON
  cat > "$kdir/_work/actionable/plan.md" <<'EOF'
## Phases
- [ ] Ship the actionable fixture
EOF
  cat > "$kdir/_work/actionable/tasks.json" <<'JSON'
{"phases":[{"tasks":[{"id":"task-a","subject":"Ship the actionable fixture","blockedBy":[]}]}]}
JSON

  cat > "$kdir/_work/blocked/_meta.json" <<'JSON'
{"slug":"blocked","title":"Blocked","status":"active","blocked_by":["dependency"],"not_before":"2099-01-01T00:00:00Z"}
JSON
  cat > "$kdir/_work/blocked/plan.md" <<'EOF'
## Phases
- [ ] Ship the blocked fixture
EOF
  cat > "$kdir/_work/blocked/tasks.json" <<'JSON'
{"phases":[{"tasks":[{"id":"task-b","subject":"Ship the blocked fixture","blockedBy":[]}]}]}
JSON

  cat > "$kdir/_work/merged-item/_meta.json" <<'JSON'
{"slug":"merged-item","title":"Merged item","status":"merged","blocked_by":[],"merge_commit":"abc123"}
JSON
  cat > "$kdir/_work/merged-item/notes.md" <<'EOF'
## 2026-07-09T00:00
**Status:** archived
EOF

  cat > "$kdir/_work/no-evidence/_meta.json" <<'JSON'
{"slug":"no-evidence","title":"No evidence","status":"active"}
JSON
  cat > "$kdir/_work/no-evidence/plan.md" <<'EOF'
## Phases
- [ ] This task has no declared DAG evidence
EOF

  cat > "$kdir/_sessions/instances/fixture-tui.json" <<'JSON'
{"name":"fixture-tui","pid":42,"sessions":[{"slug":"live-work","type":"implement","session_id":"sess-1"}]}
JSON
  cat > "$kdir/_sessions/events.jsonl" <<'JSONL'
{"event":"close_failed","event_id":"fail-1","request_id":"request-1","slug":"failed-work","reason":"interactive-prompt"}
{"event":"close_failed","event_id":"fail-2","request_id":"request-2","slug":"recovered-work","reason":"transient"}
{"event":"closed","event_id":"closed-2","request_id":"spawn-2","slug":"recovered-work","links":{"close_requests":"[\"request-2\"]"}}
{"event":"close_failed","event_id":"fail-3","request_id":"request-3","slug":"top-level-only","reason":"transient"}
{"event":"closed","event_id":"closed-3","request_id":"request-3","slug":"top-level-only"}
{"event":"close_failed","event_id":"fail-4","request_id":"request-4","slug":"same-slug","session_type":"implement","reason":"transient"}
{"event":"closed","event_id":"closed-4","request_id":"other-request","slug":"same-slug","session_type":"implement","links":{"close_requests":"[\"unrelated\"]"}}
JSONL

  cat > "$kdir/_scorecards/rows.jsonl" <<'JSONL'
{"schema_version":"1","kind":"telemetry","tier":"telemetry","calibration_state":"unknown","event_type":"ceremony-resolution","metric":"ceremony_resolution_outcome","outcome":"needs-decision","disposition":"unhandled","ceremony":"spec-post-plan","advisor":"codex-plan-review","harness":"codex","reason":"advisor unavailable","corrective_action":"run registered advisor","timestamp":"2026-07-09T00:00:00Z","source_artifact_ids":[]}
{"schema_version":"1","kind":"telemetry","tier":"telemetry","calibration_state":"unknown","metric":"experiment_window","window_id":"window-1","window_start":"2026-07-01T00:00:00Z","window_end":"2099-01-01T00:00:00Z"}
JSONL
  cat > "$kdir/_scorecards/retro-deferred-queue.jsonl" <<'JSONL'
{"schema_version":"2","kind":"retro_deferred","record_type":"outcome","outcome_id":"due-1","cycle_id":"cycle-1","event_type":"impl-close","outcome":"due","disposition":"unhandled","reason":"always-stratum","ts":"2026-07-09T00:00:00Z"}
JSONL
  cat > "$kdir/_evolve/accepted-clusters.jsonl" <<'JSONL'
{"schema_version":"1","vocabulary_version":"1","cluster_id":"cluster-ready","target":"skills/spec/SKILL.md","change_types":["evidence-gap"],"work_items":["wi-1"],"journal_row_refs":[],"accepted_at":"2026-07-09T00:00:00Z","accepted_at_run_id":"run-1","accepted_by_maintainer_decision":"merge","consumed_at_run_id":null}
{"schema_version":"1","vocabulary_version":"1","cluster_id":"cluster-done","target":"skills/retro/SKILL.md","change_types":["ceiling-raise"],"work_items":["wi-2"],"journal_row_refs":[],"accepted_at":"2026-07-09T00:00:00Z","accepted_at_run_id":"run-1","accepted_by_maintainer_decision":"merge","consumed_at_run_id":"run-2"}
JSONL
}

echo "=== test_coordinate_status.sh ==="
setup_store "$BASE"

BEFORE="$TEST_DIR/before.json"
AFTER_JSON="$TEST_DIR/after-json.json"
AFTER_HUMAN="$TEST_DIR/after-human.json"
JSON_OUT="$TEST_DIR/status.json"
HUMAN_OUT="$TEST_DIR/status.txt"

snapshot_store "$BASE" "$BEFORE"
bash "$COORDINATE" --kdir "$BASE" --json > "$JSON_OUT"
RC=$?
assert_zero "JSON render exits zero" "$RC"
snapshot_store "$BASE" "$AFTER_JSON"
assert_eq "JSON render mutates no file, directory, content, mode, size, mtime, or ctime" \
  "$(cat "$BEFORE")" "$(cat "$AFTER_JSON")"

bash "$COORDINATE" --kdir "$BASE" > "$HUMAN_OUT"
RC=$?
assert_zero "human render exits zero" "$RC"
snapshot_store "$BASE" "$AFTER_HUMAN"
assert_eq "human render mutates no file, directory, content, mode, size, mtime, or ctime" \
  "$(cat "$BEFORE")" "$(cat "$AFTER_HUMAN")"

assert_eq "projection schema version" "1" "$(jq -r '.schema_version' "$JSON_OUT")"
assert_eq "manifest always contains five required sources" "5" "$(jq -r '.source_manifest | length' "$JSON_OUT")"
assert_eq "manifest source set is fixed" \
  "evolve-staging,retro-queue,scorecard-rows,session-journal,work-index" \
  "$(jq -r '[.source_manifest[].source_id] | sort | join(",")' "$JSON_OUT")"
assert_eq "healthy fixture reports all sources ok" "5" \
  "$(jq -r '[.source_manifest[] | select(.read_status=="ok")] | length' "$JSON_OUT")"
assert_eq "every manifest row carries the complete contract" "true" \
  "$(jq -r 'all(.source_manifest[]; (.source_id|length)>0 and (.read_status|length)>0 and (.observed_at|length)>0 and (.schema_version|length)>0 and (.vocabulary_version|length)>0 and (.locator|length)>0 and has("error"))' "$JSON_OUT")"

assert_eq "Act now contains task plus unconsumed evolve cluster" "2" "$(jq -r '.bucket_counts.act_now' "$JSON_OUT")"
assert_eq "Needs judgment contains ceremony, retro, and three unmatched close failures" "5" "$(jq -r '.bucket_counts.needs_judgment' "$JSON_OUT")"
assert_eq "matched close_failed is not surfaced" "0" \
  "$(jq -r '[.buckets.needs_judgment[] | select(.observed_facts.request_id?=="request-2")] | length' "$JSON_OUT")"
assert_eq "matching top-level closed.request_id without declaration clears nothing" "1" \
  "$(jq -r '[.buckets.needs_judgment[] | select(.observed_facts.request_id?=="request-3")] | length' "$JSON_OUT")"
assert_eq "same slug and type with unrelated declaration clears nothing" "1" \
  "$(jq -r '[.buckets.needs_judgment[] | select(.observed_facts.request_id?=="request-4")] | length' "$JSON_OUT")"
assert_eq "Waiting contains live session, blocker, not_before, and window" "4" "$(jq -r '.bucket_counts.waiting' "$JSON_OUT")"
assert_eq "unresolvable ceremony is visible" "1" \
  "$(jq -r '[.buckets.needs_judgment[] | select(.kind=="unhandled-ceremony")] | length' "$JSON_OUT")"
assert_eq "unhandled retro DUE is visible" "1" \
  "$(jq -r '[.buckets.needs_judgment[] | select(.kind=="unhandled-due")] | length' "$JSON_OUT")"
assert_eq "unconsumed evolve cluster is visible" "1" \
  "$(jq -r '[.buckets.act_now[] | select(.observed_facts.cluster_id?=="cluster-ready")] | length' "$JSON_OUT")"
assert_eq "consumed evolve cluster is not actionable" "0" \
  "$(jq -r '[.buckets.act_now[] | select(.observed_facts.cluster_id?=="cluster-done")] | length' "$JSON_OUT")"
assert_eq "explicit not_before is visible" "1" \
  "$(jq -r '[.buckets.waiting[] | select(.kind=="work-not-before")] | length' "$JSON_OUT")"
assert_eq "index/meta disagreement is preserved" "1" \
  "$(jq -r '[.buckets.reconcile[] | select(.kind=="work-index-meta-conflict" and .observed_facts.slug=="merged-item")] | length' "$JSON_OUT")"
assert_eq "merged-but-active evidence is preserved" "1" \
  "$(jq -r '[.buckets.reconcile[] | select(.kind=="merged-but-active")] | length' "$JSON_OUT")"
assert_eq "notes/status conflict is preserved" "1" \
  "$(jq -r '[.buckets.reconcile[] | select(.kind=="notes-status-conflict")] | length' "$JSON_OUT")"
assert_eq "absent task/DAG evidence becomes Reconcile" "1" \
  "$(jq -r '[.buckets.reconcile[] | select(.kind=="work-action-evidence-gap" and .observed_facts.slug=="no-evidence")] | length' "$JSON_OUT")"
assert_eq "absent task/DAG evidence never becomes Act now" "0" \
  "$(jq -r '[.buckets.act_now[] | select(.observed_facts.slug?=="no-evidence")] | length' "$JSON_OUT")"
assert_eq "explicit item blocker prevents local task DAG from becoming Act now" "0" \
  "$(jq -r '[.buckets.act_now[] | select(.observed_facts.slug?=="blocked")] | length' "$JSON_OUT")"
assert_eq "conflicting blocked/unblocked facts remain visible under Reconcile" "1" \
  "$(jq -r '[.buckets.reconcile[] | select(.kind=="work-action-wait-conflict")] | length' "$JSON_OUT")"
assert_eq "all projected rows expose identity, facts, locator, and literal rule" "true" \
  "$(jq -r '[.buckets[][]] | all(.[]; (.id|length)>0 and (.source_id|length)>0 and (.observed_facts|type)=="object" and (.evidence.locator|length)>0 and (.classification.rule_id|length)>0 and (.classification.rule_text|length)>0)' "$JSON_OUT")"
assert_eq "output has no priority field" "0" \
  "$(jq -r '[paths(objects) as $p | getpath($p) | select(type=="object" and has("priority"))] | length' "$JSON_OUT")"
assert_contains "ordering is explicitly neutral" "$(jq -r '.ordering' "$JSON_OUT")" "not priority"

for heading in "Coverage manifest" "Act now" "Needs judgment" "Waiting" "Reconcile"; do
  assert_contains "human render includes $heading" "$(cat "$HUMAN_OUT")" "$heading"
done
assert_contains "human render includes evidence facts" "$(cat "$HUMAN_OUT")" "facts={"
assert_contains "human render includes literal rules" "$(cat "$HUMAN_OUT")" "rule=needs.ceremony.unhandled"

SECOND_JSON="$TEST_DIR/status-second.json"
bash "$COORDINATE" --kdir "$BASE" --json > "$SECOND_JSON"
assert_eq "repeated reads produce stable row identities" \
  "$(jq -c '[.buckets[][] | .id] | sort' "$JSON_OUT")" \
  "$(jq -c '[.buckets[][] | .id] | sort' "$SECOND_JSON")"

CLI_JSON=$(bash "$CLI" coordinate status --kdir "$BASE" --json)
assert_eq "CLI dispatch reaches projection" "1" "$(printf '%s' "$CLI_JSON" | jq -r '.schema_version')"

MALFORMED="$TEST_DIR/malformed"
setup_store "$MALFORMED"
cat >> "$MALFORMED/_sessions/events.jsonl" <<'JSONL'
{"event":"close_failed","event_id":"fail-malformed","request_id":"request-malformed","slug":"malformed-recovery","reason":"transient"}
{"event":"closed","event_id":"closed-malformed","request_id":"spawn-malformed","slug":"malformed-recovery","links":{"close_requests":"not-json"}}
JSONL
MALFORMED_JSON="$TEST_DIR/malformed.json"
bash "$COORDINATE" --kdir "$MALFORMED" --json > "$MALFORMED_JSON"
assert_eq "malformed close_requests is a named session-journal coverage gap" "1" \
  "$(jq -r '[.source_manifest[] | select(.source_id=="session-journal" and .read_status=="gap" and (.error|contains("malformed closed.links.close_requests")))] | length' "$MALFORMED_JSON")"
assert_eq "malformed declaration clears nothing" "1" \
  "$(jq -r '[.buckets.needs_judgment[] | select(.observed_facts.request_id?=="request-malformed")] | length' "$MALFORMED_JSON")"
CLI_HELP=$(bash "$CLI" coordinate --help 2>&1)
assert_contains "coordinate help advertises status" "$CLI_HELP" "status"

SCRIPT_TEXT=$(cat "$COORDINATE")
assert_contains "call graph invokes published session list reader" "$SCRIPT_TEXT" 'run_reader("session-list.sh")'
assert_contains "call graph invokes published session event reader" "$SCRIPT_TEXT" 'run_reader("session-events.sh")'
assert_contains "call graph invokes published retro fold" "$SCRIPT_TEXT" 'run_reader("retro-queue.sh", "queue")'
for forbidden in "update-work-index.sh" "write-execution-log.sh" "lore work" "mkdir -p" "open(.*,'w'"; do
  if grep -Fq "$forbidden" "$COORDINATE"; then
    fail "call graph excludes writer pattern $forbidden"
  else
    pass "call graph excludes writer pattern $forbidden"
  fi
done

# Every required source fails open but loud when removed; the manifest remains
# five rows and evidence from the other sources remains visible.
for source in work-index session-journal scorecard-rows retro-queue evolve-staging; do
  CASE="$TEST_DIR/missing-$source"
  cp -R "$BASE" "$CASE"
  case "$source" in
    work-index) rm "$CASE/_work/_index.json" ;;
    session-journal) rm "$CASE/_sessions/events.jsonl" ;;
    scorecard-rows) rm "$CASE/_scorecards/rows.jsonl" ;;
    retro-queue) rm "$CASE/_scorecards/retro-deferred-queue.jsonl" ;;
    evolve-staging) rm "$CASE/_evolve/accepted-clusters.jsonl" ;;
  esac
  CASE_JSON="$TEST_DIR/missing-$source.json"
  bash "$COORDINATE" --kdir "$CASE" --json > "$CASE_JSON"
  assert_eq "$source removal still renders all five manifest rows" "5" "$(jq -r '.source_manifest|length' "$CASE_JSON")"
  assert_eq "$source removal is named in the manifest" "1" \
    "$(jq -r --arg s "$source" '[.source_manifest[] | select(.source_id==$s and .read_status!="ok" and (.error|length)>0)] | length' "$CASE_JSON")"
  assert_eq "$source removal emits a Reconcile gap row" "1" \
    "$(jq -r --arg s "$source" '[.buckets.reconcile[] | select(.source_id==$s and .kind=="source-gap")] | length' "$CASE_JSON")"
  assert_eq "$source removal preserves evidence from another source" "true" \
    "$(jq -r --arg s "$source" '[.buckets[][] | select(.source_id!=$s and .kind!="source-gap")] | length > 0' "$CASE_JSON")"
done

# Unknown/missing declarations and unknown vocabulary are gaps, while valid
# sibling evidence remains visible.
CASE="$TEST_DIR/unknown-contracts"
cp -R "$BASE" "$CASE"
jq '.version=9' "$CASE/_work/_index.json" > "$TEST_DIR/index-9" && mv "$TEST_DIR/index-9" "$CASE/_work/_index.json"
echo '{"event":"future_event","event_id":"future-1"}' >> "$CASE/_sessions/events.jsonl"
echo '{"schema_version":"9","kind":"telemetry"}' >> "$CASE/_scorecards/rows.jsonl"
echo '{"schema_version":"1","cluster_id":"legacy","consumed_at_run_id":null}' >> "$CASE/_evolve/accepted-clusters.jsonl"
UNKNOWN_JSON="$TEST_DIR/unknown-contracts.json"
bash "$COORDINATE" --kdir "$CASE" --json > "$UNKNOWN_JSON"
for source in work-index session-journal scorecard-rows evolve-staging; do
  assert_eq "$source unknown/missing declaration or vocabulary becomes a named gap" "1" \
    "$(jq -r --arg s "$source" '[.source_manifest[] | select(.source_id==$s and .read_status=="gap" and (.error|length)>0)] | length' "$UNKNOWN_JSON")"
done
assert_eq "valid scorecard evidence survives an unknown-version sibling row" "1" \
  "$(jq -r '[.buckets.needs_judgment[] | select(.kind=="unhandled-ceremony")] | length' "$UNKNOWN_JSON")"
assert_eq "valid evolve evidence survives a missing-version sibling row" "1" \
  "$(jq -r '[.buckets.act_now[] | select(.observed_facts.cluster_id?=="cluster-ready")] | length' "$UNKNOWN_JSON")"

CASE="$TEST_DIR/malformed-native-readers"
cp -R "$BASE" "$CASE"
printf '{torn' >> "$CASE/_sessions/events.jsonl"
printf '%s\n' 'not-json' >> "$CASE/_scorecards/retro-deferred-queue.jsonl"
MALFORMED_JSON="$TEST_DIR/malformed-native-readers.json"
bash "$COORDINATE" --kdir "$CASE" --json > "$MALFORMED_JSON"
assert_eq "session reader trailing-byte signal becomes a named gap" "1" \
  "$(jq -r '[.source_manifest[] | select(.source_id=="session-journal" and .read_status=="gap" and (.error|contains("trailing bytes")))] | length' "$MALFORMED_JSON")"
assert_eq "retro native malformed-row count becomes a named gap" "1" \
  "$(jq -r '[.source_manifest[] | select(.source_id=="retro-queue" and .read_status=="gap" and (.error|contains("malformed")))] | length' "$MALFORMED_JSON")"

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
