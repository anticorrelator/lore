#!/usr/bin/env bash
# test_coordinate_status.sh — End-to-end acceptance for the read-only composer.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COORDINATE="$REPO_ROOT/scripts/coordinate-status.sh"
CLI="$REPO_ROOT/cli/lore"
TEST_DIR=$(mktemp -d)
BASE="$TEST_DIR/base"

# The composer reads its seat ceiling from settings.json. Left unpinned, that is
# whatever the developer's machine happens to hold, and the ready-stream cases
# below are decided by it. Pin a data dir so the ceiling is a fixture.
export LORE_DATA_DIR="$TEST_DIR/data"
mkdir -p "$LORE_DATA_DIR/config"
cat >"$LORE_DATA_DIR/config/settings.json" <<'JSON'
{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]}},"coordination":{"max_concurrency":10}}
JSON

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
{"event":"close_failed","event_id":"1889880106a9a922","request_id":"request-1","slug":"failed-work","reason":"interactive-prompt"}
{"event":"close_failed","event_id":"fail-2","request_id":"request-2","slug":"recovered-work","reason":"transient"}
{"event":"closed","event_id":"closed-2","request_id":"spawn-2","slug":"recovered-work","links":{"close_requests":"[\"request-2\"]"}}
{"event":"close_failed","event_id":"648b75f906159750","request_id":"request-3","slug":"top-level-only","reason":"transient"}
{"event":"closed","event_id":"closed-3","request_id":"request-3","slug":"top-level-only"}
{"event":"close_failed","event_id":"1a91175bc35f694b","request_id":"request-4","slug":"same-slug","session_type":"implement","reason":"transient"}
{"event":"closed","event_id":"closed-4","request_id":"other-request","slug":"same-slug","session_type":"implement","links":{"close_requests":"[\"unrelated\"]"}}
{"event":"close_failed","event_id":"1d77a8b177268b18","request_id":"request-frozen-4","slug":"legacy-unmatched","reason":"transient"}
{"event":"close_failed","event_id":"retired-dead","request_id":"request-dead","slug":"retired-work","reason":"target-instance-dead"}
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
assert_eq "Needs judgment contains ceremony, retro, and four frozen unmatched close failures" "6" "$(jq -r '.bucket_counts.needs_judgment' "$JSON_OUT")"
assert_eq "matched close_failed is not surfaced" "0" \
  "$(jq -r '[.buckets.needs_judgment[] | select(.observed_facts.request_id?=="request-2")] | length' "$JSON_OUT")"
assert_eq "matching top-level closed.request_id without declaration clears nothing" "1" \
  "$(jq -r '[.buckets.needs_judgment[] | select(.observed_facts.request_id?=="request-3")] | length' "$JSON_OUT")"
assert_eq "same slug and type with unrelated declaration clears nothing" "1" \
  "$(jq -r '[.buckets.needs_judgment[] | select(.observed_facts.request_id?=="request-4")] | length' "$JSON_OUT")"
assert_eq "dead-target retirement is not unmatched recovery" "0" \
  "$(jq -r '[.buckets.needs_judgment[] | select(.observed_facts.request_id?=="request-dead")] | length' "$JSON_OUT")"
assert_eq "all four frozen pre-extension failures remain visible" "4" \
  "$(jq -r '[.buckets.needs_judgment[] | select(.observed_facts.event_id? as $id | ["1889880106a9a922","648b75f906159750","1a91175bc35f694b","1d77a8b177268b18"] | index($id))] | length' "$JSON_OUT")"
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

# A ceremony obligation leaves the board only when a correlated transition
# records it as handled. The fixture's pre-transition row carries no
# outcome_id, so it must stay visible either way — absence is unhandled, not
# an error.
CASE="$TEST_DIR/ceremony-handled"
cp -R "$BASE" "$CASE"
cat >> "$CASE/_scorecards/rows.jsonl" <<'JSONL'
{"schema_version":"1","kind":"telemetry","tier":"telemetry","calibration_state":"unknown","event_type":"ceremony-resolution","metric":"ceremony_resolution_outcome","outcome":"needs-decision","disposition":"unhandled","ceremony":"spec-design","advisor":"codex-design-review","harness":"codex","reason":"two-round cap reached","corrective_action":"lead adjudication required","timestamp":"2026-07-09T01:00:00Z","outcome_id":"ceremony-handled-1","source_artifact_ids":[]}
{"schema_version":"1","kind":"telemetry","tier":"telemetry","calibration_state":"unknown","event_type":"ceremony-resolution","metric":"ceremony_resolution_outcome","outcome":"needs-decision","disposition":"unhandled","ceremony":"spec-design","advisor":"codex-design-review","harness":"codex","reason":"two-round cap reached","corrective_action":"lead adjudication required","timestamp":"2026-07-09T02:00:00Z","outcome_id":"ceremony-open-1","source_artifact_ids":[]}
JSONL
CEREMONY_OPEN_JSON="$TEST_DIR/ceremony-open.json"
bash "$COORDINATE" --kdir "$CASE" --json > "$CEREMONY_OPEN_JSON"
assert_eq "an unhandled ceremony outcome is on the board" "3" \
  "$(jq -r '[.buckets.needs_judgment[] | select(.kind=="unhandled-ceremony")] | length' "$CEREMONY_OPEN_JSON")"

cat >> "$CASE/_scorecards/rows.jsonl" <<'JSONL'
{"schema_version":"1","kind":"telemetry","tier":"telemetry","calibration_state":"unknown","event_type":"ceremony-resolution","metric":"ceremony_resolution_outcome","record_type":"disposition","outcome":"needs-decision","disposition":"handled","outcome_id":"ceremony-handled-1","ceremony":"spec-design","advisor":"codex-design-review","action":"adjudicated","handled_by":"coordinate","handled_at":"2026-07-09T03:00:00Z","timestamp":"2026-07-09T03:00:00Z","source_artifact_ids":[]}
JSONL
CEREMONY_HANDLED_JSON="$TEST_DIR/ceremony-handled.json"
bash "$COORDINATE" --kdir "$CASE" --json > "$CEREMONY_HANDLED_JSON"
assert_eq "a handled ceremony outcome leaves the board" "0" \
  "$(jq -r '[.buckets.needs_judgment[] | select(.kind=="unhandled-ceremony" and .observed_facts.outcome_id?=="ceremony-handled-1")] | length' "$CEREMONY_HANDLED_JSON")"
assert_eq "its uncorrelated siblings stay on the board" "2" \
  "$(jq -r '[.buckets.needs_judgment[] | select(.kind=="unhandled-ceremony")] | length' "$CEREMONY_HANDLED_JSON")"
assert_eq "the transition row is not itself an obligation" "0" \
  "$(jq -r '[.buckets.needs_judgment[] | select(.observed_facts.record_type?=="disposition")] | length' "$CEREMONY_HANDLED_JSON")"
assert_eq "the handled vocabulary is known, so the source stays ok" "ok" \
  "$(jq -r '.source_manifest[] | select(.source_id=="scorecard-rows") | .read_status' "$CEREMONY_HANDLED_JSON")"

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


# --- coordination ledgers live in the arc record ---------------------------
# The board resolves _work/_arcs/<slug>/coordination.md. These cases assert the
# corrected behaviour: a ledger that is read renders streams, and a ledger that
# is not read says so instead of rendering as an empty one.

RECONCILE="$REPO_ROOT/scripts/coordinate-reconcile.py"

write_arc() {
  local kdir="$1" arc="$2" status="$3"
  mkdir -p "$kdir/_work/_arcs/$arc"
  cat > "$kdir/_work/_arcs/$arc/_meta.json" <<JSON
{"schema_version":1,"slug":"$arc","title":"$arc","status":"$status","members":[]}
JSON
}

write_worktree_identity() {
  local kdir="$1" id="$2" item="$3" stream="$4" attempt="$5"
  mkdir -p "$kdir/_coordination/worktrees/registry"
  cat > "$kdir/_coordination/worktrees/registry/$id.json" <<JSON
{"schema_version":1,"worktree_id":"$id","execution_dir":"$TEST_DIR/$id","temporary_branch":"refs/heads/$id","git_common_dir":"$TEST_DIR/$id/.git","allocation_base_sha":"base-$id","owner_item":"$item","stream_id":"$stream","attempt_id":"$attempt","owner":{"kind":"seat","id":"seat-1"},"lease":{"duration_seconds":900,"renewed_at":"2026-07-21T00:00:00Z","expires_at":"2099-07-21T00:15:00Z"},"guard_identity":{},"state":"quiescent","lifecycle":[]}
JSON
}

# Case 1: an active arc whose ledger the board reads.
LIVE="$TEST_DIR/arc-live"
setup_store "$LIVE"
write_arc "$LIVE" live-arc active
cat > "$LIVE/_work/_arcs/live-arc/coordination.md" <<'EOF'
| # | Step | Depends on | Tree | Status | Verdict |
|---|---|---|---|---|---|
| s-inflight | Live step | — | writer | in-flight | — |
| s-prefreeze | Allocated step | — | writer | pending | — |
| s-ready | Untouched step | — | writer | pending | — |
| s-readonly | Dispatched read-only step | — | read-only | pending | — |
| s-accepted | Accepted read-only step | — | read-only | pending | — |
EOF
write_worktree_identity "$LIVE" wt-prefreeze live-arc s-prefreeze a1
python3 "$RECONCILE" register-attempt --kdir "$LIVE" --slug live-arc \
  --stream s-prefreeze --attempt a1 --tree writer --worktree-id wt-prefreeze --json >/dev/null
python3 "$RECONCILE" register-attempt --kdir "$LIVE" --slug live-arc \
  --stream s-readonly --attempt a1 --tree read-only --json >/dev/null
python3 "$RECONCILE" register-attempt --kdir "$LIVE" --slug live-arc \
  --stream s-accepted --attempt a1 --tree read-only --json >/dev/null
python3 "$RECONCILE" advance-attempt --kdir "$LIVE" --slug live-arc \
  --stream s-accepted --attempt a1 --expected-status coord_dispatched \
  --to coord_report_accepted --json >/dev/null
write_arc "$LIVE" closed-arc closed
cat > "$LIVE/_work/_arcs/closed-arc/coordination.md" <<'EOF'
| # | Step | Depends on | Tree | Status | Verdict |
|---|---|---|---|---|---|
| s-closed | Step in a closed arc | — | writer | pending | — |
EOF

LIVE_JSON="$TEST_DIR/arc-live.json"
bash "$COORDINATE" --kdir "$LIVE" --json > "$LIVE_JSON"
assert_eq "arc ledger under _work/_arcs is read" "1" \
  "$(jq -r '.coordination_dispatch.ledger_scan.ledgers_read' "$LIVE_JSON")"
assert_eq "the arc ledger's stream rows are counted" "5" \
  "$(jq -r '.coordination_dispatch.ledger_scan.streams_read' "$LIVE_JSON")"
assert_eq "a live stream is an active attempt" "3" \
  "$(jq -r '.coordination_dispatch.active_attempts' "$LIVE_JSON")"
assert_eq "a read ledger with dispatchable streams names no reason" "null" \
  "$(jq -r '.coordination_dispatch.ledger_scan.reason' "$LIVE_JSON")"
assert_eq "an untouched pending stream is ready" "1" \
  "$(jq -r '[.buckets.act_now[] | select(.kind=="ready-stream" and .observed_facts.stream_id=="s-ready")] | length' "$LIVE_JSON")"
assert_eq "a stream whose attempt was accepted is released for dispatch" "1" \
  "$(jq -r '[.buckets.act_now[] | select(.kind=="ready-stream" and .observed_facts.stream_id=="s-accepted")] | length' "$LIVE_JSON")"
assert_eq "an allocated attempt is never redispatched" "0" \
  "$(jq -r '[.buckets.act_now[] | select(.observed_facts.stream_id?=="s-prefreeze")] | length' "$LIVE_JSON")"
assert_eq "an allocated attempt holds its stream under Waiting" "coord_allocated" \
  "$(jq -r '[.buckets.waiting[] | select(.kind=="active-stream-attempt" and .observed_facts.stream_id=="s-prefreeze")][0].observed_facts.attempt_status' "$LIVE_JSON")"
assert_eq "a dispatched read-only attempt is never redispatched" "0" \
  "$(jq -r '[.buckets.act_now[] | select(.observed_facts.stream_id?=="s-readonly")] | length' "$LIVE_JSON")"
assert_eq "a stream with no attempt records the absence explicitly" "false" \
  "$(jq -r '[.buckets.act_now[] | select(.observed_facts.stream_id?=="s-ready")][0].observed_facts.attempt_present' "$LIVE_JSON")"
assert_eq "the ledger locator points into the arc record" "true" \
  "$(jq -r '[.buckets[][] | select(.evidence.locator | startswith("_work/_arcs/live-arc/coordination.md#L"))] | length > 0' "$LIVE_JSON")"
assert_eq "a closed arc's ledger is not projected" "0" \
  "$(jq -r '[.buckets[][] | select(.observed_facts.stream_id?=="s-closed")] | length' "$LIVE_JSON")"
assert_contains "human render names the ledger scan" \
  "$(bash "$COORDINATE" --kdir "$LIVE")" "Coordination dispatch"

# Case 2: a record written before the lifecycle statuses existed.
LEGACY="$TEST_DIR/arc-legacy"
setup_store "$LEGACY"
write_arc "$LEGACY" legacy-arc active
cat > "$LEGACY/_work/_arcs/legacy-arc/coordination.md" <<'EOF'
| # | Step | Depends on | Tree | Status | Verdict |
|---|---|---|---|---|---|
| s-nostatus | Attempt without a status | — | writer | pending | — |
| s-merge | Attempt awaiting composition | — | writer | pending | — |
EOF
mkdir -p "$LEGACY/_coordination/reconciliation/legacy-arc"
cat > "$LEGACY/_coordination/reconciliation/legacy-arc/streams.json" <<'JSON'
{
  "schema_version": 2,
  "work_item": "legacy-arc",
  "updated_at": "2026-07-21T00:00:00Z",
  "streams": [
    {"stream_id": "s-nostatus", "tree": "writer", "depends_on": [],
     "attempts": [{"attempt_id": "a1", "updated_at": "2026-07-21T00:00:00Z"}]},
    {"stream_id": "s-merge", "tree": "writer", "depends_on": [],
     "attempts": [{"attempt_id": "a1", "status": "merge_ready", "updated_at": "2026-07-21T00:00:00Z"}]}
  ]
}
JSON
LEGACY_JSON="$TEST_DIR/arc-legacy.json"
bash "$COORDINATE" --kdir "$LEGACY" --json > "$LEGACY_JSON"
assert_eq "an attempt with no status is not dispatchable" "0" \
  "$(jq -r '[.buckets.act_now[] | select(.observed_facts.stream_id?=="s-nostatus")] | length' "$LEGACY_JSON")"
assert_eq "an absent status renders as absent, not as a default" "null" \
  "$(jq -r '[.buckets.waiting[] | select(.observed_facts.stream_id?=="s-nostatus")][0].observed_facts.attempt_status' "$LEGACY_JSON")"
assert_eq "an absent status is marked unrecorded" "false" \
  "$(jq -r '[.buckets.waiting[] | select(.observed_facts.stream_id?=="s-nostatus")][0].observed_facts.attempt_status_recorded' "$LEGACY_JSON")"
assert_eq "an attempt awaiting composition is not dispatchable" "0" \
  "$(jq -r '[.buckets.act_now[] | select(.observed_facts.stream_id?=="s-merge")] | length' "$LEGACY_JSON")"
assert_eq "a v2 record is read without error" "0" \
  "$(jq -r '[.buckets.reconcile[] | select(.kind=="coordination-reconciliation-invalid")] | length' "$LEGACY_JSON")"

# Case 3: the four ways the board can end up with nothing to dispatch stay
# distinguishable from one another.
NO_DIR="$TEST_DIR/arc-absent"
setup_store "$NO_DIR"
NO_DIR_JSON="$TEST_DIR/arc-absent.json"
bash "$COORDINATE" --kdir "$NO_DIR" --json > "$NO_DIR_JSON"
assert_eq "an absent arc directory is named as unread" "absent" \
  "$(jq -r '.coordination_dispatch.ledger_scan.read_status' "$NO_DIR_JSON")"
assert_contains "an absent arc directory names its locator in the reason" \
  "$(jq -r '.coordination_dispatch.ledger_scan.reason' "$NO_DIR_JSON")" "_work/_arcs"

NO_LEDGER="$TEST_DIR/arc-no-ledger"
setup_store "$NO_LEDGER"
write_arc "$NO_LEDGER" ledgerless active
NO_LEDGER_JSON="$TEST_DIR/arc-no-ledger.json"
bash "$COORDINATE" --kdir "$NO_LEDGER" --json > "$NO_LEDGER_JSON"
assert_eq "an arc without a ledger reports the directory as read" "ok" \
  "$(jq -r '.coordination_dispatch.ledger_scan.read_status' "$NO_LEDGER_JSON")"
assert_eq "an arc without a ledger is still counted" "1" \
  "$(jq -r '.coordination_dispatch.ledger_scan.arcs_active' "$NO_LEDGER_JSON")"
assert_contains "an arc without a ledger names that as the reason" \
  "$(jq -r '.coordination_dispatch.ledger_scan.reason' "$NO_LEDGER_JSON")" "carries a readable coordination.md"

EMPTY_LEDGER="$TEST_DIR/arc-empty-ledger"
setup_store "$EMPTY_LEDGER"
write_arc "$EMPTY_LEDGER" empty-arc active
cat > "$EMPTY_LEDGER/_work/_arcs/empty-arc/coordination.md" <<'EOF'
# Coordination Ledger

No step ledger has been written yet.
EOF
EMPTY_JSON="$TEST_DIR/arc-empty-ledger.json"
bash "$COORDINATE" --kdir "$EMPTY_LEDGER" --json > "$EMPTY_JSON"
assert_eq "a ledger with no stream table is read" "1" \
  "$(jq -r '.coordination_dispatch.ledger_scan.ledgers_read' "$EMPTY_JSON")"
assert_contains "an empty ledger reads differently from an unread one" \
  "$(jq -r '.coordination_dispatch.ledger_scan.reason' "$EMPTY_JSON")" "no stream rows"
assert_eq "the four zero-ready reasons are four different strings" "4" \
  "$(printf '%s\n%s\n%s\n%s\n' \
    "$(jq -r '.coordination_dispatch.ledger_scan.reason' "$NO_DIR_JSON")" \
    "$(jq -r '.coordination_dispatch.ledger_scan.reason' "$NO_LEDGER_JSON")" \
    "$(jq -r '.coordination_dispatch.ledger_scan.reason' "$EMPTY_JSON")" \
    "$(jq -r '.coordination_dispatch.ledger_scan.reason' "$LEGACY_JSON")" | sort -u | wc -l | tr -d ' ')"

BAD_ARC="$TEST_DIR/arc-unreadable"
setup_store "$BAD_ARC"
mkdir -p "$BAD_ARC/_work/_arcs/broken"
printf '{torn' > "$BAD_ARC/_work/_arcs/broken/_meta.json"
BAD_ARC_JSON="$TEST_DIR/arc-unreadable.json"
bash "$COORDINATE" --kdir "$BAD_ARC" --json > "$BAD_ARC_JSON"
assert_eq "an unreadable arc record becomes a Reconcile row" "1" \
  "$(jq -r '[.buckets.reconcile[] | select(.kind=="coordination-arc-record-invalid")] | length' "$BAD_ARC_JSON")"

BAD_LEDGER="$TEST_DIR/arc-bad-ledger"
setup_store "$BAD_LEDGER"
write_arc "$BAD_LEDGER" broken-ledger active
cat > "$BAD_LEDGER/_work/_arcs/broken-ledger/coordination.md" <<'EOF'
| # | Step | Depends on | Tree | Status | Verdict |
|---|---|---|---|---|---|
| — | Row with no stream identity | — | writer | pending | — |
EOF
BAD_LEDGER_JSON="$TEST_DIR/arc-bad-ledger.json"
bash "$COORDINATE" --kdir "$BAD_LEDGER" --json > "$BAD_LEDGER_JSON"
assert_eq "a malformed ledger becomes a Reconcile row at the arc locator" "1" \
  "$(jq -r '[.buckets.reconcile[] | select(.kind=="coordination-ledger-invalid" and (.evidence.locator=="_work/_arcs/broken-ledger/coordination.md"))] | length' "$BAD_LEDGER_JSON")"

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
