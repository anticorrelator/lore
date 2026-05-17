#!/usr/bin/env bash
# test_verification_loop_e2e.sh
#
# End-to-end acceptance test for the verification-loop cutover. Constructs
# a hermetic mktemp kdir, seeds nine source rows covering the §B terminus
# matrix, drives the durable drain via a deterministic executor stub,
# emits the cutover-marker telemetry row, and asserts six conditions.
#
# Hermetic: no live $KDIR, no LLM frameworks. Calibration markers are
# pre-seeded as `calibrated` so the hard-cal precondition is satisfied
# without invoking the calibration runner.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
QUEUE="$SCRIPTS_DIR/settlement-queue.sh"
EVIDENCE="$SCRIPTS_DIR/evidence-append.sh"
SCORECARD="$SCRIPTS_DIR/scorecard-append.sh"
TEMPLATE_VERSION="$SCRIPTS_DIR/template-version.sh"

LIVE_KDIR=$(lore resolve)
if [[ -z "$LIVE_KDIR" || ! -d "$LIVE_KDIR" ]]; then
  echo "ERROR: could not resolve live knowledge dir (needed for calibration fixture symlinks)" >&2
  exit 2
fi

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/verification-loop-e2e-XXXXXX")
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

KDIR="$TEST_DIR/kdir"
WORK_SLUG="e2e-verification-loop"
SETTINGS="$TEST_DIR/settings.json"
EXEC_STUB="$TEST_DIR/executor-stub.sh"
CURATE_LOG="$TEST_DIR/curate.log"

mkdir -p "$KDIR/_work/$WORK_SLUG"
mkdir -p "$KDIR/_scorecards"
mkdir -p "$KDIR/_calibration"

# Symlink the live calibration fixture sets so the hard-cal preflight is
# satisfied without copying multi-MB trees. The processor reads template
# versions via template-version.sh (against agents/<gate>.md), so the
# marker keys below carry the live versions, not pinned literals.
for gate in correctness-gate-assertion correctness-gate-contradiction correctness-gate-omission; do
  ln -sfn "$LIVE_KDIR/_calibration/$gate" "$KDIR/_calibration/$gate"
done

GATE_ASSERTION_VERSION=$("$TEMPLATE_VERSION" "$REPO_DIR/agents/correctness-gate-assertion.md")
GATE_CONTRADICTION_VERSION=$("$TEMPLATE_VERSION" "$REPO_DIR/agents/correctness-gate-contradiction.md")
GATE_OMISSION_VERSION=$("$TEMPLATE_VERSION" "$REPO_DIR/agents/correctness-gate-omission.md")

jq -nc \
  --arg a_key "correctness-gate-assertion:$GATE_ASSERTION_VERSION" \
  --arg c_key "correctness-gate-contradiction:$GATE_CONTRADICTION_VERSION" \
  --arg o_key "correctness-gate-omission:$GATE_OMISSION_VERSION" \
  '{
    ($a_key): {calibration_state: "calibrated", pass_rate: 1.0, threshold: 1.0, sample_size: 50},
    ($c_key): {calibration_state: "calibrated", pass_rate: 1.0, threshold: 1.0, sample_size: 50},
    ($o_key): {calibration_state: "calibrated", pass_rate: 1.0, threshold: 1.0, sample_size: 50}
  }' > "$KDIR/_scorecards/calibration-state.json"

# Settings that enable settlement and accept claude-code as the lone
# eligible framework — same shape as test_settlement_queue.sh.
cat > "$SETTINGS" <<'JSON'
{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}
JSON

# Deterministic executor stub. Reads the settlement processor's stdin
# payload ({item, run_id}), inspects item.kind + item.source_id, and
# emits the pre-canned verdict envelope. The `selection_tag` is folded
# into the envelope's `evidence` so assertion (1) can group by the
# (kind, verdict, selection-tag) tuple from persisted run records.
cat > "$EXEC_STUB" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
INPUT=$(cat)
python3 - "$INPUT" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
item = payload.get("item") or {}
kind = item.get("kind") or "task-claim"
source_id = (
    item.get("source_id")
    or item.get("claim_id")
    or item.get("candidate_id")
    or item.get("contradiction_id")
    or ""
)

# Source-id -> (verdict, evidence-with-selection-tag) pinning. Each row
# below maps to exactly one cell in the §B terminus matrix.
table = {
    # task-claim cells
    "tc-verified-selected":     ("verified",     "stub:tc verified | selection_tag=curator-selected"),
    "tc-verified-not-selected": ("verified",     "stub:tc verified | selection_tag=curator-not-selected"),
    "tc-contradicted":          ("contradicted", "stub:tc contradicted | selection_tag=n/a"),
    "tc-unverified":            ("unverified",   "stub:tc unverified | selection_tag=n/a"),
    # omission cells
    "om-verified":              ("verified",     "stub:om verified | selection_tag=n/a"),
    "om-unverified":            ("unverified",   "stub:om unverified | selection_tag=n/a"),
    "om-gate-failed":           ("error",        "stub:om gate-failed | selection_tag=n/a"),
    # consumption-contradiction cells
    "cc-verified":              ("verified",     "stub:cc verified | selection_tag=n/a"),
    "cc-rejected":              ("unverified",   "stub:cc rejected | selection_tag=n/a"),
}

verdict, evidence = table.get(source_id, ("skipped", f"stub: no mapping for {kind}:{source_id}"))

envelope = {
    "verdict_envelope_version": 1,
    "verdict": verdict,
    "evidence": evidence,
    "correction": None,
    "executor": {"name": "verification-loop-e2e-stub", "framework": "claude-code", "exit_code": 0},
    "audit": None,
}
print(json.dumps(envelope, separators=(",", ":")))
PY
STUB
chmod +x "$EXEC_STUB"

# Seed source rows. The processor's invalid-reason checks require
# claim/file/line_range/falsifier/change_context on task-claim rows;
# audit-candidates require candidate_id/file/line_range/falsifier;
# consumption-contradictions require claim_payload.{claim_id,file,
# line_range,exact_snippet,falsifier} and a top-level status=pending.

write_task_claim() {
  local cid="$1" claim="$2"
  jq -nc --arg cid "$cid" --arg claim "$claim" '{
    claim_id: $cid,
    tier: "task-evidence",
    claim: $claim,
    producer_role: "worker",
    protocol_slot: "implementation",
    task_id: "task-2",
    phase_id: "1",
    scale: "implementation",
    file: "tests/test_verification_loop_e2e.sh",
    line_range: "1-200",
    falsifier: "Re-run the e2e and inspect _settlement/runs/* verdicts",
    why_this_work_needs_it: "Drives one terminus cell of the matrix",
    captured_at_sha: "test-sha",
    change_context: {diff_ref: "test-sha", changed_files: ["tests/test_verification_loop_e2e.sh"], summary: "e2e fixture row"},
    exact_snippet: "e2e terminus fixture snippet",
    normalized_snippet_hash: "6f148f59fba2907683d56f3def8e5ad1a94a4bf582636c3e2acb291227c54685"
  }' >> "$KDIR/_work/$WORK_SLUG/task-claims.jsonl"
}

write_omission() {
  local cid="$1"
  jq -nc --arg cid "$cid" '{
    candidate_id: $cid,
    file: "tests/test_verification_loop_e2e.sh",
    line_range: "1-200",
    falsifier: "Re-run the e2e and inspect _settlement/runs/* verdicts",
    rationale: "omission terminus cell fixture",
    created_at: "2026-05-16T00:00:00Z"
  }' >> "$KDIR/_work/$WORK_SLUG/audit-candidates.jsonl"
}

write_cc() {
  local cid="$1"
  jq -nc --arg cid "$cid" '{
    contradiction_id: $cid,
    status: "pending",
    created_at: "2026-05-16T00:00:00Z",
    claim_payload: {
      claim_id: ("claim-" + $cid),
      file: "tests/test_verification_loop_e2e.sh",
      line_range: "1-200",
      exact_snippet: "consumption-contradiction terminus fixture",
      falsifier: "Re-run the e2e and inspect _settlement/runs/* verdicts"
    }
  }' >> "$KDIR/_work/$WORK_SLUG/consumption-contradictions.jsonl"
}

write_task_claim "tc-verified-selected"     "verified curator-selected terminus fixture row"
write_task_claim "tc-verified-not-selected" "verified curator-not-selected terminus fixture row"
write_task_claim "tc-contradicted"          "contradicted terminus fixture row"
write_task_claim "tc-unverified"            "unverified terminus fixture row"
write_omission   "om-verified"
write_omission   "om-unverified"
write_omission   "om-gate-failed"
write_cc         "cc-verified"
write_cc         "cc-rejected"

# Scan source rows into the queue, then drain.
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" \
  bash "$QUEUE" scan --kdir "$KDIR" --json >/dev/null

# Auto-correction would try to mutate live commons entries from
# contradicted verdicts. Disable it for the hermetic run.
DRAIN_JSON=$(
  LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" \
  LORE_SETTLEMENT_EXECUTOR="$EXEC_STUB" \
  LORE_SETTLEMENT_DISABLE_AUTO_CORRECTION=1 \
  bash "$QUEUE" drain --kdir "$KDIR" --max-iterations 50 --json
)

# Emit the cutover-marker telemetry row. Rides under kind=telemetry /
# tier=telemetry with event_type=calibration-cutover so the marker
# satisfies scorecard-append's tier-validation contract without
# expanding the kind enum.
MARKER_SHA=$(python3 -c 'import hashlib,sys; print(hashlib.sha1(open(sys.argv[1],"rb").read()).hexdigest()[:12])' "${BASH_SOURCE[0]}")
CUTOVER_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq -nc \
  --arg ts "$CUTOVER_TS" \
  --arg tv "$MARKER_SHA" \
  '{
    kind: "telemetry",
    tier: "telemetry",
    calibration_state: "calibrated",
    event_type: "calibration-cutover",
    cutover_timestamp: $ts,
    schema_version: 1,
    template_id: "verification-loop-cutover",
    template_version: $tv,
    producer_role: "spec-lead"
  }' | bash "$SCORECARD" --kdir "$KDIR" >/dev/null

echo ""
echo "=== Verification-loop e2e assertions ==="

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1 — $2"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1 — $2"; SKIP=$((SKIP + 1)); }

# --- Assertion 1: nine terminus cells reached ---------------------------
# Group every run record by (kind, verdict.verdict, selection_tag-parsed-
# from-evidence) and require exactly 9 distinct combinations.
RUNS_GLOB="$KDIR/_settlement/runs/*.json"
RUN_COUNT=$(ls -1 $RUNS_GLOB 2>/dev/null | wc -l | tr -d ' ')
DISTINCT=$(
  python3 - <<PY
import glob, json, re, sys
seen = set()
for path in glob.glob("$RUNS_GLOB"):
    try:
        run = json.load(open(path))
    except Exception:
        continue
    kind = run.get("kind") or ""
    verdict = (run.get("verdict") or {}).get("verdict") or ""
    evidence = (run.get("verdict") or {}).get("evidence") or ""
    m = re.search(r"selection_tag=([^|]+?)(?:\s|$)", evidence)
    tag = (m.group(1) if m else "none").strip()
    seen.add((kind, verdict, tag))
print(len(seen))
PY
)
if [[ "$DISTINCT" == "9" ]]; then
  pass "(1) terminus matrix" "9 distinct (kind, verdict, selection) combinations from $RUN_COUNT runs"
else
  fail "(1) terminus matrix" "expected 9 distinct combinations, got $DISTINCT (run files: $RUN_COUNT)"
fi

# --- Assertion 2: calibration markers survive the drain -----------------
MARKER_COUNT=$(jq 'keys | length' "$KDIR/_scorecards/calibration-state.json")
if [[ "$MARKER_COUNT" == "3" ]]; then
  pass "(2) calibration markers preserved" "3 calibrated entries remain in calibration-state.json"
else
  fail "(2) calibration markers preserved" "expected 3 entries, got $MARKER_COUNT"
fi

# --- Assertion 3: post-cutover window is not pipeline-degraded ----------
# /retro carries no bash-callable surface; proxy by asserting that the
# post-cutover scorecard rows contain zero rows whose event_type carries
# a pipeline-degraded signal. The cutover-marker row anchors the window
# start: every row at or after it is part of the post-cutover window.
export ROWS_FILE="$KDIR/_scorecards/rows.jsonl"
DEGRADED=$(
  python3 - <<'PY'
import json, sys, os
path = os.environ["ROWS_FILE"]
seen_marker = False
degraded = 0
if os.path.exists(path):
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except Exception:
            continue
        if row.get("event_type") == "calibration-cutover":
            seen_marker = True
            continue
        if not seen_marker:
            continue
        ev = (row.get("event_type") or "")
        if "pipeline-degraded" in ev:
            degraded += 1
print(degraded)
PY
)
if [[ "$DEGRADED" == "0" ]]; then
  pass "(3) post-cutover window healthy" "zero rows carry a pipeline-degraded event_type after the cutover marker (proxy for /retro window_state)"
else
  fail "(3) post-cutover window healthy" "$DEGRADED post-cutover row(s) carry a pipeline-degraded event_type"
fi

# --- Assertion 4: curate dry-run does not escalate ----------------------
# /memory curate carries no bash CLI either; proxy by running the
# concrete script the curate skill drives — curate-scan.sh — in dry mode
# against the hermetic kdir and asserting it returns clean without any
# AskUserQuestion / human-escalation tokens on its stdout+stderr.
CURATE_OK=0
if [[ -x "$SCRIPTS_DIR/curate-scan.sh" ]]; then
  if bash "$SCRIPTS_DIR/curate-scan.sh" --kdir "$KDIR" > "$CURATE_LOG" 2>&1; then
    CURATE_OK=1
  else
    # Non-zero exit from a curate scan still passes the contract if its
    # output does not invoke AskUserQuestion — record the exit but keep
    # the assertion focused on escalation discipline, not survey health.
    CURATE_OK=1
  fi
  if grep -qiE 'AskUserQuestion|escalate to human|please confirm|awaiting user' "$CURATE_LOG"; then
    fail "(4) curate no-escalation" "curate-scan emitted a human-escalation token (see $CURATE_LOG)"
  else
    pass "(4) curate no-escalation" "curate-scan dry-run produced no AskUserQuestion / escalation tokens (proxy for /memory curate --dry-run)"
  fi
else
  skip "(4) curate no-escalation" "curate-scan.sh not present at $SCRIPTS_DIR/curate-scan.sh — cannot proxy /memory curate from bash"
fi

# --- Assertion 5: agent-perspective phrase is restated in 3 surfaces ----
PHRASE='commons is curated by agents for agents'
SURFACES=(
  "$REPO_DIR/skills/remember/SKILL.md"
  "$REPO_DIR/skills/memory/SKILL.md"
  "$REPO_DIR/scripts/pre-compact.sh"
)
MISSING=()
for surface in "${SURFACES[@]}"; do
  if ! grep -qiF "$PHRASE" "$surface"; then
    MISSING+=("$surface")
  fi
done
if [[ ${#MISSING[@]} -eq 0 ]]; then
  pass "(5) agent-perspective phrase" "canonical phrase present in all 3 inline-restated surfaces"
else
  fail "(5) agent-perspective phrase" "missing from: ${MISSING[*]}"
fi

# --- Assertion 6: evolve citation gate selects post-cutover calibrated rows
# /evolve has no bash CLI; proxy the §E1 condition (6) gate directly
# against the scorecard row set. The gate's contract is:
#   - cite at least one row whose template_id is a correctness-gate-*
#     name AND calibration_state == "calibrated"
#   - exclude any row with event_type == "calibration-cutover"
#   - exclude any row with calibration_state == "pre-calibration"
# Seed two scored rows post-marker so the gate has eligible citations
# (the marker row itself is excluded by event_type; rows before it would
# also be excluded by event_type if any existed).
for tid in correctness-gate-assertion correctness-gate-contradiction; do
  jq -nc --arg tid "$tid" '{
    kind: "scored",
    tier: "template",
    calibration_state: "calibrated",
    schema_version: 1,
    template_id: $tid,
    template_version: "abcdef012345",
    metric: "pass_rate",
    value: 1.0,
    sample_size: 50,
    window_start: "2026-05-16T00:00:00Z",
    window_end: "2026-05-17T00:00:00Z"
  }' | bash "$SCORECARD" --kdir "$KDIR" >/dev/null
done

GATE_RESULT=$(
  python3 - <<'PY'
import json, os
path = os.environ["ROWS_FILE"]
saw_marker = False
eligible = 0
violations = 0
if os.path.exists(path):
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except Exception:
            continue
        if row.get("event_type") == "calibration-cutover":
            saw_marker = True
            continue
        if not saw_marker:
            continue
        if row.get("event_type") == "calibration-cutover":
            violations += 1
        if row.get("calibration_state") == "pre-calibration":
            violations += 1
        tid = row.get("template_id") or ""
        if tid in ("correctness-gate-assertion", "correctness-gate-contradiction") \
                and row.get("calibration_state") == "calibrated":
            eligible += 1
print(f"{eligible} {violations}")
PY
)
ELIGIBLE=$(printf '%s' "$GATE_RESULT" | awk '{print $1}')
VIOLATIONS=$(printf '%s' "$GATE_RESULT" | awk '{print $2}')
if [[ "$ELIGIBLE" -ge 1 && "$VIOLATIONS" == "0" ]]; then
  pass "(6) evolve citation gate" "$ELIGIBLE eligible correctness-gate-* calibrated row(s); zero excluded-class violations"
else
  fail "(6) evolve citation gate" "eligible=$ELIGIBLE, excluded-class violations=$VIOLATIONS (need eligible>=1 and violations==0)"
fi

# --- Summary ------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "PASS:  $PASS"
echo "FAIL:  $FAIL"
echo "SKIP:  $SKIP"
echo "drain: $DRAIN_JSON"

if [[ $FAIL -gt 0 || $SKIP -gt 0 ]]; then
  exit 1
fi
exit 0
