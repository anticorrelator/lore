#!/usr/bin/env bats
# implement-fabrication-guard.bats — Verdict-fabrication guard in
# skills/implement/SKILL.md Step 4 §3 (D6).
#
# The guard sits between worker-report acceptance (§1-2) and the existing
# advisor-impact-rollup invocation (§4 after renumbering). It consumes the
# transcript provider per the canonical consumer pattern
# (`get_provider()` -> catch UnsupportedFrameworkError -> `provider_status()`
# gate -> operation calls) and routes to one of three branches:
#
#   (a) Provider OK + every claimed advisor verified in the transcript ->
#       invoke advisor-impact-rollup unchanged with all consultations.
#   (b) Provider OK + at least one claimed advisor not seen in the transcript
#       spawn events -> log `fabrication-guard: skipped <name>` per unverified
#       entry and forward only the verified subset to the rollup. Verified
#       entries still flow.
#   (c) Provider returns `unavailable` or `partial` (with the spawn surface
#       degraded) -> log `fabrication-guard: provider-<status>; rollup skipped`
#       and do NOT invoke the rollup at all. Verify-or-skip default; do NOT
#       fall through to today's verbatim-trust behavior.
#
# The guard is metadata-only — worker task acceptance is unaffected; only
# the advisor scorecard attribution changes. This bats file mirrors the
# Step 4 §3 algorithm in test-side bash helpers (same pattern as
# scorecard-rollup-snapshots.bats's `select_prior_snapshot`) because the
# guard lives in skill prose, not in a standalone script.
#
# Style: pure bats. Skips cleanly when prerequisites are missing.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
SKILL_FILE="$REPO_DIR/skills/implement/SKILL.md"
ROLLUP_SH="$REPO_DIR/scripts/advisor-impact-rollup.sh"
APPEND_SH="$REPO_DIR/scripts/scorecard-append.sh"
WRITE_LOG_SH="$REPO_DIR/scripts/write-execution-log.sh"
PROVIDER_PKG="$REPO_DIR/adapters/transcripts"

setup() {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  [ -f "$SKILL_FILE" ] || skip "skills/implement/SKILL.md missing"
  [ -f "$ROLLUP_SH" ] || skip "scripts/advisor-impact-rollup.sh missing"
  [ -f "$APPEND_SH" ] || skip "scripts/scorecard-append.sh missing"
  [ -f "$WRITE_LOG_SH" ] || skip "scripts/write-execution-log.sh missing"
  [ -f "$PROVIDER_PKG/__init__.py" ] || skip "adapters/transcripts package missing"

  # Hermetic knowledge dir — write-execution-log.sh + advisor-impact-rollup.sh
  # both resolve via resolve_knowledge_dir(), which short-circuits on
  # $LORE_KNOWLEDGE_DIR (resolve-repo.sh:23-26).
  WORK_SLUG="fabrication-guard-fixture"
  KDIR="$(mktemp -d)"
  mkdir -p "$KDIR/_scorecards" "$KDIR/_work/$WORK_SLUG"
  printf '%s' '{"format_version": 2}' > "$KDIR/_manifest.json"
  : > "$KDIR/_work/$WORK_SLUG/execution-log.md"
  export LORE_KNOWLEDGE_DIR="$KDIR"
  export KDIR

  TRANSCRIPT_FIXTURE="$(mktemp -t fabguard-fixture.XXXXXX.jsonl)"
}

teardown() {
  if [ -n "${TRANSCRIPT_FIXTURE:-}" ] && [ -f "$TRANSCRIPT_FIXTURE" ]; then
    rm -f "$TRANSCRIPT_FIXTURE"
  fi
  if [ -n "${KDIR:-}" ] && [ -d "$KDIR" ]; then
    rm -rf "$KDIR"
  fi
}

# Build a Claude-Code-shaped transcript fixture that records advisor spawn
# events. The advisor-spawn shape mirrors what `/implement` Step 3.5b
# produces: a TaskCreate tool_use entry whose `input.name` is the advisor
# name (e.g. "supply-chain-risk-auditor-advisor").
write_transcript_fixture() {
  local advisor_names="$1"  # space-separated
  python3 - "$TRANSCRIPT_FIXTURE" $advisor_names <<'PYEOF'
import json, sys
fixture_path = sys.argv[1]
advisor_names = sys.argv[2:]
entries = [
    {"sessionId": "fab-sess-1", "timestamp": "2026-05-08T08:00:00Z",
     "type": "human",
     "message": {"role": "user", "content": "/implement audit-scorecard-plumbing-follow-ups-w03-settlement"}},
]
for i, name in enumerate(advisor_names):
    entries.append({
        "sessionId": "fab-sess-1",
        "timestamp": f"2026-05-08T08:00:{i+1:02d}Z",
        "type": "assistant",
        "message": {"role": "assistant",
                    "content": [
                        {"type": "tool_use", "name": "TaskCreate",
                         "input": {"name": name, "subagent_type": "general-purpose"}},
                    ]},
    })
with open(fixture_path, "w") as f:
    for e in entries:
        f.write(json.dumps(e) + "\n")
PYEOF
}

# Test-side mirror of the Step 4 §3 guard algorithm. Returns a JSON object
# on stdout: {"branch": "a"|"b"|"c", "verified": [...], "rollup_payload": [...]}
# and emits the canonical fabrication-guard log lines to execution-log.md
# via write-execution-log.sh.
#
# Inputs:
#   $1 — path to consultations JSON (array of objects, each with
#        advisor_template_version + spawned_as_name fields)
#   $2 — path to transcript fixture
#   $3 — `claude-code` (full) | `unavailable` (force degraded) | `partial`
#   $4 — slug
fabrication_guard() {
  local cons_path="$1"
  local transcript_path="$2"
  local force_status="$3"
  local slug="$4"

  REPO_DIR="$REPO_DIR" \
  TRANSCRIPT_PATH="$transcript_path" \
  FORCE_STATUS="$force_status" \
  CONS_PATH="$cons_path" \
  python3 <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ['REPO_DIR'])
from adapters.transcripts import get_provider, UnsupportedFrameworkError

cons_path = os.environ['CONS_PATH']
transcript_path = os.environ['TRANSCRIPT_PATH']
force_status = os.environ['FORCE_STATUS']

with open(cons_path) as f:
    consultations = json.load(f)

# Branch (c) short-circuit when caller wants to simulate a degraded provider.
if force_status in ("unavailable", "partial"):
    out = {"branch": "c", "status": force_status,
           "verified": [], "rollup_payload": [],
           "log_lines": [f"fabrication-guard: provider-{force_status}; rollup skipped"]}
    print(json.dumps(out))
    sys.exit(0)

# Branch (a) / (b): consult the transcript provider per the canonical pattern.
try:
    provider = get_provider('claude-code')
except UnsupportedFrameworkError:
    out = {"branch": "c", "status": "unavailable",
           "verified": [], "rollup_payload": [],
           "log_lines": ["fabrication-guard: provider-unavailable; rollup skipped"]}
    print(json.dumps(out))
    sys.exit(0)

status, reason = provider.provider_status()
if status == 'unavailable':
    out = {"branch": "c", "status": "unavailable",
           "verified": [], "rollup_payload": [],
           "log_lines": ["fabrication-guard: provider-unavailable; rollup skipped"]}
    print(json.dumps(out))
    sys.exit(0)

# Two-pass extraction: parse_transcript() for ordering / tool_names filter,
# read_raw_lines()[msg.index] for raw input (the spawned name lives in
# input.name on the TaskCreate tool_use, which the normalized schema does
# not surface). This is the documented two-pass pattern.
msgs = provider.parse_transcript(transcript_path)
raw = provider.read_raw_lines(transcript_path)
spawned_names = set()
for m in msgs:
    if 'TaskCreate' not in (m.get('tool_names') or []):
        continue
    line = raw[m['index']]
    try:
        rec = json.loads(line)
    except (json.JSONDecodeError, KeyError):
        continue
    blocks = (((rec.get('message') or {}).get('content')) or [])
    for b in blocks:
        if b.get('type') == 'tool_use' and b.get('name') == 'TaskCreate':
            nm = (b.get('input') or {}).get('name')
            if nm:
                spawned_names.add(nm)

verified = []
log_lines = []
for c in consultations:
    name = c.get('spawned_as_name')
    if name and name in spawned_names:
        verified.append(c)
    else:
        # Identifier emitted in the log: prefer name, fall back to template version.
        ident = name or c.get('advisor_template_version') or '<unknown>'
        log_lines.append(f"fabrication-guard: skipped {ident}")

branch = "a" if len(verified) == len(consultations) else "b"
out = {
    "branch": branch,
    "status": status,
    "verified": verified,
    "rollup_payload": verified,
    "log_lines": log_lines,
}
print(json.dumps(out))
PYEOF
}

# Helper: write the fabrication-guard log lines to execution-log.md the
# same way Step 4 §3 prescribes (one write-execution-log.sh invocation per
# line, source=implement-lead).
write_guard_log_lines() {
  local lines_json="$1"
  local slug="$2"
  echo "$lines_json" | python3 -c '
import json, sys, subprocess, os
lines = json.load(sys.stdin)
slug = sys.argv[1]
write_log = sys.argv[2]
for line in lines:
    subprocess.run(
        ["bash", write_log, "--slug", slug, "--source", "implement-lead",
         "--template-version", "test-lead-tv"],
        input=line + "\n", text=True, check=True,
        env={**os.environ, "LORE_KNOWLEDGE_DIR": os.environ["KDIR"]},
    )
' "$slug" "$WRITE_LOG_SH"
}

# Helper: invoke the real advisor-impact-rollup against a verified-payload
# JSON array, attribute everything to KDIR. Returns rollup script status.
run_rollup() {
  local payload_json="$1"
  local slug="$2"
  bash "$ROLLUP_SH" \
    --consultations-json "$payload_json" \
    --work-item "$slug" \
    --kdir "$KDIR" >/dev/null 2>&1
}

# Helper: count rows in $KDIR/_scorecards/rows.jsonl whose template_version
# equals the given hash (i.e. attribution rows for this advisor).
rollup_rows_for() {
  local advisor_tv="$1"
  local rows_file="$KDIR/_scorecards/rows.jsonl"
  [ -f "$rows_file" ] || { echo 0; return; }
  jq -c --arg tv "$advisor_tv" 'select(.template_version == $tv)' "$rows_file" | wc -l | tr -d ' '
}

# ============================================================
# Branch (a) — provider OK, all entries verified, rollup runs unchanged.
# ============================================================

@test "branch (a): provider full + all advisors verified -> rollup invoked, no fabrication-guard log line" {
  ADVISOR_TV="aaaaaaaaaaaa"
  ADVISOR_NAME="supply-chain-risk-auditor-advisor"

  write_transcript_fixture "$ADVISOR_NAME"

  CONS=$(mktemp)
  cat > "$CONS" <<EOF
[{"advisor_template_version":"$ADVISOR_TV","spawned_as_name":"$ADVISOR_NAME","query_summary":"q","advice_summary":"a","was_followed":true}]
EOF

  result=$(fabrication_guard "$CONS" "$TRANSCRIPT_FIXTURE" "claude-code" "$WORK_SLUG")
  rm -f "$CONS"

  branch=$(echo "$result" | jq -r '.branch')
  [ "$branch" = "a" ]

  # No log lines emitted on branch (a).
  log_count=$(echo "$result" | jq -r '.log_lines | length')
  [ "$log_count" = "0" ]

  # Forward verified payload to the real rollup.
  payload=$(echo "$result" | jq -c '.rollup_payload')
  run_rollup "$payload" "$WORK_SLUG"

  # Rollup wrote two rows attributed to this advisor (consultation_rate +
  # advice_followed_rate per the script header).
  rows=$(rollup_rows_for "$ADVISOR_TV")
  [ "$rows" = "2" ]

  # execution-log.md does NOT contain a fabrication-guard line for branch (a).
  ! grep -q '^fabrication-guard:' "$KDIR/_work/$WORK_SLUG/execution-log.md" || \
    { echo "unexpected fabrication-guard log line in branch (a)"; cat "$KDIR/_work/$WORK_SLUG/execution-log.md"; return 1; }
}

# ============================================================
# Branch (b) — provider OK, mismatch on one advisor: rollup runs WITHOUT the
# fabricated entry, log emits `fabrication-guard: skipped <name>`.
# ============================================================

@test "branch (b): one fabricated advisor -> rollup invoked without fabricated entry, log records skip" {
  REAL_TV="bbbbbbbbbbbb"
  REAL_NAME="real-advisor"
  FAKE_TV="ffffffffffff"
  FAKE_NAME="ghost-advisor"

  # Only the real advisor is spawned in the transcript.
  write_transcript_fixture "$REAL_NAME"

  CONS=$(mktemp)
  cat > "$CONS" <<EOF
[
  {"advisor_template_version":"$REAL_TV","spawned_as_name":"$REAL_NAME","query_summary":"q","advice_summary":"a","was_followed":true},
  {"advisor_template_version":"$FAKE_TV","spawned_as_name":"$FAKE_NAME","query_summary":"q2","advice_summary":"a2","was_followed":false,"rationale_if_not_followed":"disagreed"}
]
EOF

  result=$(fabrication_guard "$CONS" "$TRANSCRIPT_FIXTURE" "claude-code" "$WORK_SLUG")
  rm -f "$CONS"

  branch=$(echo "$result" | jq -r '.branch')
  [ "$branch" = "b" ]

  # Exactly one log line, naming the fabricated advisor.
  log_count=$(echo "$result" | jq -r '.log_lines | length')
  [ "$log_count" = "1" ]
  log_line=$(echo "$result" | jq -r '.log_lines[0]')
  [ "$log_line" = "fabrication-guard: skipped $FAKE_NAME" ]

  # Verified payload contains only the real advisor.
  verified_count=$(echo "$result" | jq -r '.verified | length')
  [ "$verified_count" = "1" ]
  verified_tv=$(echo "$result" | jq -r '.verified[0].advisor_template_version')
  [ "$verified_tv" = "$REAL_TV" ]

  # Persist the log line via the canonical writer, then run the rollup.
  log_lines=$(echo "$result" | jq -c '.log_lines')
  write_guard_log_lines "$log_lines" "$WORK_SLUG"

  payload=$(echo "$result" | jq -c '.rollup_payload')
  run_rollup "$payload" "$WORK_SLUG"

  # Real advisor got two rows; fake advisor got zero.
  real_rows=$(rollup_rows_for "$REAL_TV")
  fake_rows=$(rollup_rows_for "$FAKE_TV")
  [ "$real_rows" = "2" ]
  [ "$fake_rows" = "0" ]

  # execution-log.md contains the fabrication-guard line.
  grep -q "fabrication-guard: skipped $FAKE_NAME" "$KDIR/_work/$WORK_SLUG/execution-log.md"
}

# ============================================================
# Branch (c) — provider unavailable: rollup NOT invoked, log line records
# the provider status. Verify-or-skip default, NOT fall-through.
# ============================================================

@test "branch (c): provider unavailable -> rollup NOT invoked, log records provider status" {
  ADVISOR_TV="cccccccccccc"
  ADVISOR_NAME="some-advisor"

  write_transcript_fixture "$ADVISOR_NAME"

  CONS=$(mktemp)
  cat > "$CONS" <<EOF
[{"advisor_template_version":"$ADVISOR_TV","spawned_as_name":"$ADVISOR_NAME","query_summary":"q","advice_summary":"a","was_followed":true}]
EOF

  result=$(fabrication_guard "$CONS" "$TRANSCRIPT_FIXTURE" "unavailable" "$WORK_SLUG")
  rm -f "$CONS"

  branch=$(echo "$result" | jq -r '.branch')
  [ "$branch" = "c" ]

  # Exactly one log line, naming the provider status.
  log_count=$(echo "$result" | jq -r '.log_lines | length')
  [ "$log_count" = "1" ]
  log_line=$(echo "$result" | jq -r '.log_lines[0]')
  [ "$log_line" = "fabrication-guard: provider-unavailable; rollup skipped" ]

  # Verified payload is empty — branch (c) does NOT fall through.
  verified_count=$(echo "$result" | jq -r '.verified | length')
  [ "$verified_count" = "0" ]
  payload_count=$(echo "$result" | jq -r '.rollup_payload | length')
  [ "$payload_count" = "0" ]

  # Persist the log line. Do NOT invoke the rollup.
  log_lines=$(echo "$result" | jq -c '.log_lines')
  write_guard_log_lines "$log_lines" "$WORK_SLUG"

  # No rows for this advisor (rollup was skipped).
  rows=$(rollup_rows_for "$ADVISOR_TV")
  [ "$rows" = "0" ]

  # execution-log.md contains the provider-unavailable line.
  grep -q "fabrication-guard: provider-unavailable; rollup skipped" \
    "$KDIR/_work/$WORK_SLUG/execution-log.md"

  # Sanity: rows.jsonl must not exist (or, if it does, must be empty for
  # this advisor).
  if [ -f "$KDIR/_scorecards/rows.jsonl" ]; then
    matches=$(jq -c --arg tv "$ADVISOR_TV" 'select(.template_version == $tv)' \
      "$KDIR/_scorecards/rows.jsonl" | wc -l | tr -d ' ')
    [ "$matches" = "0" ]
  fi
}

# ============================================================
# Step 4 §3 prose anchors — guard against the SKILL.md text drifting away
# from the three documented branches. These are doc-anchored regression
# guards (same shape as the README-anchored asserts in transcripts.bats).
# ============================================================

@test "SKILL.md Step 4 §3 names the three branches and the verify-or-skip default" {
  # Branch labels appear in prose.
  grep -q "Provider OK and every claimed advisor is verified" "$SKILL_FILE"
  grep -q "Mismatch" "$SKILL_FILE"
  grep -q "Provider returns \`unavailable\`" "$SKILL_FILE"

  # Verify-or-skip default is explicit.
  grep -q "Do NOT fall through to today's verbatim-trust behavior" "$SKILL_FILE"

  # Canonical log line shapes are documented verbatim so consumers (this
  # bats file, /retro, future audit tooling) can match them.
  grep -q "fabrication-guard: skipped" "$SKILL_FILE"
  grep -q "fabrication-guard: provider-" "$SKILL_FILE"

  # Canonical consumer pattern is named.
  grep -q "get_provider()" "$SKILL_FILE"
  grep -q "provider_status()" "$SKILL_FILE"
  grep -q "UnsupportedFrameworkError" "$SKILL_FILE"
}
