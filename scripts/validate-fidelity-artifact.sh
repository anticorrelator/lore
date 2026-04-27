#!/usr/bin/env bash
# validate-fidelity-artifact.sh — TaskCompleted hook sibling validator (W06 Phase 2)
#
# Reads the same TaskCompleted hook payload as task-completed-capture-check.sh
# (JSON on stdin: team_name, task_description, agent_name) and validates the
# corresponding fidelity artifact at $KDIR/_work/<slug>/_fidelity/<artifact_key>.json.
#
# Pipeline (per plan.md § Phase 2):
#   (a) derive_work_slug from team_name (impl-* / spec-* prefix strip)
#   (b) derive_artifact_key = sha256(slug + ':' + task_subject)[:12]
#   (c) feature-gate: warn-only until all three Phase 3 sentinels land
#   (d) read $KDIR/_work/<slug>/_fidelity/<artifact_key>.json
#   (e) validate against scripts/schemas/fidelity.json (jsonschema, no ad-hoc grep)
#   (f) branch-artifact gating per verdict
#
# Mode contract:
#   - Warn-only: any one of the three Phase 3 sentinels missing
#       → emit `[fidelity] warn: ...` to stderr, exit 0
#   - Blocking:  all three sentinels present
#       → exit 0 on pass, exit 2 + stderr diagnostic on fail
#
# Phase 3 sentinels checked:
#   1. agents/fidelity-judge.md contains W06_FIDELITY_JUDGE_TEMPLATE_READY
#   2. skills/implement/SKILL.md contains W06_FIDELITY_STEP4_INTEGRATED
#   3. agents/worker.md contains W06_FIDELITY_ACK_WAIT
#
# Applicability guard: only impl-* teams produce fidelity artifacts. spec-* and
# non-team payloads exit 0 silently. researcher (Explore) reports inside impl-*
# teams also pass-through (workers and team-leads alone produce fidelity-eligible
# artifacts in the W06 design).
#
# Input: JSON on stdin (TaskCompleted hook format)
# Output: exit 0 to allow, exit 2 + stderr to block (only in blocking mode)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
lore_agent_enabled || exit 0

INPUT=$(cat)

# ---------- Payload extraction ----------

extract_field() {
  local field="$1"
  printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('$field') or '')
except Exception:
    sys.exit(0)
"
}

TEAM_NAME=$(extract_field team_name)
TASK_DESC=$(extract_field task_description)
AGENT_NAME=$(extract_field agent_name)
[[ -z "$AGENT_NAME" ]] && AGENT_NAME=$(extract_field owner)

# Fast exit: not a team-driven task event
if [[ -z "$TEAM_NAME" ]]; then
  exit 0
fi

# Applicability guard — only impl-* teams produce fidelity artifacts.
case "$TEAM_NAME" in
  impl-*) ;;
  *) exit 0 ;;
esac

# Resolve agent type (Explore/general-purpose/team-lead). Researcher (Explore)
# reports inside impl-* teams pass-through — fidelity targets worker code output.
TEAM_CONFIG="$HOME/.claude/teams/$TEAM_NAME/config.json"
AGENT_TYPE=""
if [[ -f "$TEAM_CONFIG" && -n "$AGENT_NAME" ]]; then
  AGENT_TYPE=$(python3 -c "
import json, sys
try:
    with open('$TEAM_CONFIG') as f:
        config = json.load(f)
    for m in config.get('members', []):
        if m.get('name') == '$AGENT_NAME':
            print(m.get('agentType', ''))
            sys.exit(0)
    print('')
except Exception:
    print('')
" 2>/dev/null || true)
fi

case "$AGENT_TYPE" in
  Explore|team-lead) exit 0 ;;
esac

# ---------- (a) Slug derivation ----------

derive_work_slug() {
  case "$TEAM_NAME" in
    impl-*) printf '%s' "${TEAM_NAME#impl-}" ;;
    *)      printf '%s' "" ;;
  esac
}

SLUG=$(derive_work_slug)
if [[ -z "$SLUG" ]]; then
  # Should never reach here — applicability guard above filters non-impl-* teams.
  exit 0
fi

# ---------- (b) Artifact key derivation ----------

# Extract task_subject: first non-empty line of task_description, strip leading
# `- [ ]`/`- [x]`, collapse internal whitespace to single spaces, leave other
# punctuation/case unchanged. Schema enforces 12-hex-char output, so emit lowercase hex.
derive_task_subject() {
  printf '%s' "$TASK_DESC" | python3 -c '
import re, sys
text = sys.stdin.read()
for raw in text.splitlines():
    line = raw.strip()
    if not line:
        continue
    # Strip leading "- [ ]" or "- [x]" (case-insensitive on x/X)
    line = re.sub(r"^-\s*\[[ xX]\]\s*", "", line)
    # Collapse internal whitespace runs to single spaces
    line = re.sub(r"\s+", " ", line).strip()
    if line:
        print(line)
        sys.exit(0)
sys.exit(0)
'
}

TASK_SUBJECT=$(derive_task_subject)
if [[ -z "$TASK_SUBJECT" ]]; then
  echo "[fidelity] error: could not derive task_subject from task_description (no non-empty line)" >&2
  exit 2
fi

derive_artifact_key() {
  local slug="$1" subject="$2"
  printf '%s:%s' "$slug" "$subject" \
    | python3 -c "import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode('utf-8')).hexdigest()[:12])"
}

ARTIFACT_KEY=$(derive_artifact_key "$SLUG" "$TASK_SUBJECT")

# ---------- (c) Feature-gate / sentinel check ----------

# Repo root: scripts/ lives under the repo root, so up one level.
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Sentinels can be overridden by env (used by the fixture test to point at a
# scratch tree). Default to the canonical install paths.
: "${LORE_FIDELITY_JUDGE_TEMPLATE:=$REPO_ROOT/agents/fidelity-judge.md}"
: "${LORE_FIDELITY_IMPLEMENT_SKILL:=$REPO_ROOT/skills/implement/SKILL.md}"
: "${LORE_FIDELITY_WORKER_TEMPLATE:=$REPO_ROOT/agents/worker.md}"

check_sentinel() {
  local file="$1" needle="$2"
  [[ -f "$file" ]] && grep -qF -- "$needle" "$file"
}

BLOCKING_MODE=true
MISSING_SENTINELS=()

check_sentinel "$LORE_FIDELITY_JUDGE_TEMPLATE"  "W06_FIDELITY_JUDGE_TEMPLATE_READY" \
  || MISSING_SENTINELS+=("agents/fidelity-judge.md:W06_FIDELITY_JUDGE_TEMPLATE_READY")
check_sentinel "$LORE_FIDELITY_IMPLEMENT_SKILL" "W06_FIDELITY_STEP4_INTEGRATED" \
  || MISSING_SENTINELS+=("skills/implement/SKILL.md:W06_FIDELITY_STEP4_INTEGRATED")
check_sentinel "$LORE_FIDELITY_WORKER_TEMPLATE" "W06_FIDELITY_ACK_WAIT" \
  || MISSING_SENTINELS+=("agents/worker.md:W06_FIDELITY_ACK_WAIT")

if [[ ${#MISSING_SENTINELS[@]} -gt 0 ]]; then
  BLOCKING_MODE=false
fi

# emit_diag — write a diagnostic to stderr. In blocking mode this precedes
# exit 2; in warn mode it precedes exit 0 with a [fidelity] warn: prefix.
emit_diag() {
  local msg="$1"
  if $BLOCKING_MODE; then
    echo "[fidelity] block: $msg" >&2
  else
    echo "[fidelity] warn: $msg (warn-only — Phase 3 sentinels missing: ${MISSING_SENTINELS[*]})" >&2
  fi
}

# exit_with — exit 2 in blocking mode, exit 0 in warn mode.
exit_with() {
  if $BLOCKING_MODE; then
    exit 2
  else
    exit 0
  fi
}

# ---------- (d) Read fidelity artifact ----------

KDIR="$(resolve_knowledge_dir 2>/dev/null || true)"
if [[ -z "$KDIR" || ! -d "$KDIR" ]]; then
  emit_diag "could not resolve knowledge dir for slug=$SLUG"
  exit_with
fi

FIDELITY_DIR="$KDIR/_work/$SLUG/_fidelity"
ARTIFACT_PATH="$FIDELITY_DIR/$ARTIFACT_KEY.json"
AMENDMENT_PATH="$KDIR/_work/$SLUG/_amendments/$ARTIFACT_KEY.md"
ESCALATION_PATH="$FIDELITY_DIR/$ARTIFACT_KEY.escalation.md"

if [[ ! -f "$ARTIFACT_PATH" ]]; then
  emit_diag "no fidelity artifact at _work/$SLUG/_fidelity/$ARTIFACT_KEY.json (artifact_key derived from slug + task_subject hash; spawn the fidelity-judge or write a kind:exempt record)"
  exit_with
fi

# ---------- (e) JSON Schema validation ----------

SCHEMA_PATH="$REPO_ROOT/scripts/schemas/fidelity.json"
if [[ ! -f "$SCHEMA_PATH" ]]; then
  emit_diag "schema not found at scripts/schemas/fidelity.json (cannot validate $ARTIFACT_PATH)"
  exit_with
fi

# Validate via jsonschema (Python). Captures all error messages to stderr buffer
# and exits 0/1. We use Draft 2020-12 to match the schema's $schema declaration.
# Disable -e for the validator subshell so we can inspect SCHEMA_RC. Re-enable
# immediately after.
set +e
VALIDATION_ERRORS=$(
  ARTIFACT_PATH="$ARTIFACT_PATH" SCHEMA_PATH="$SCHEMA_PATH" python3 - <<'PY' 2>&1
import json, os, sys
try:
    import jsonschema
    from jsonschema import Draft202012Validator
except ImportError as e:
    print(f"jsonschema-unavailable: {e}")
    sys.exit(2)

schema_path = os.environ["SCHEMA_PATH"]
artifact_path = os.environ["ARTIFACT_PATH"]
try:
    with open(schema_path) as f:
        schema = json.load(f)
except Exception as e:
    print(f"schema-load-error: {e}")
    sys.exit(2)
try:
    with open(artifact_path) as f:
        instance = json.load(f)
except json.JSONDecodeError as e:
    print(f"artifact-not-json: {e}")
    sys.exit(2)
except Exception as e:
    print(f"artifact-read-error: {e}")
    sys.exit(2)

validator = Draft202012Validator(schema)
errors = sorted(validator.iter_errors(instance), key=lambda e: list(e.absolute_path))
if errors:
    for err in errors:
        path = "/".join(str(p) for p in err.absolute_path) or "<root>"
        msg = err.message.replace("\n", " ")
        print(f"schema-violation at {path}: {msg}")
    sys.exit(1)
sys.exit(0)
PY
)
SCHEMA_RC=$?
set -e

if [[ $SCHEMA_RC -ne 0 ]]; then
  if [[ $SCHEMA_RC -eq 2 ]]; then
    emit_diag "schema validation infra error: $VALIDATION_ERRORS"
  else
    emit_diag "schema validation failed for $ARTIFACT_PATH: $VALIDATION_ERRORS"
  fi
  exit_with
fi

# ---------- (f) Branch-artifact gating ----------

# Pull verdict / kind out of the validated artifact. Schema guarantees fields exist
# in the right shape, so this is a structural read, not a defensive parse.
ARTIFACT_FIELDS=$(
  ARTIFACT_PATH="$ARTIFACT_PATH" python3 - <<'PY'
import json, os
with open(os.environ["ARTIFACT_PATH"]) as f:
    a = json.load(f)
kind = a.get("kind", "")
verdict = a.get("verdict", "")
supersedes = a.get("supersedes") or []
# A "fresh non-blocking superseding verdict" is one where the current verdict is
# not in the blocking set AND supersedes is non-empty (this judgment was preceded
# by a prior verdict on the same artifact_key).
print(f"{kind}\t{verdict}\t{len(supersedes)}")
PY
)
KIND="${ARTIFACT_FIELDS%%$'\t'*}"
REST="${ARTIFACT_FIELDS#*$'\t'}"
VERDICT="${REST%%$'\t'*}"
SUPERSEDES_LEN="${REST#*$'\t'}"

# kind: exempt — schema already enforced exempt_reason + sampling_trigger fields;
# no further branch checks. Pass.
if [[ "$KIND" == "exempt" ]]; then
  exit 0
fi

# kind: verdict — branch-artifact gating per verdict value.
case "$VERDICT" in
  aligned)
    exit 0
    ;;
  drifted|contradicts)
    # Accept when ANY of: amendment file exists, escalation file exists, or
    # this artifact is itself a fresh non-blocking supersession (verdict was
    # already handled above when verdict=aligned, so reaching here means
    # verdict is still drifted/contradicts — supersedes presence does not
    # bypass the branch-artifact requirement on the CURRENT verdict).
    if [[ -f "$AMENDMENT_PATH" || -f "$ESCALATION_PATH" ]]; then
      exit 0
    fi
    emit_diag "$VERDICT verdict at $ARTIFACT_PATH requires a branch artifact: write _amendments/$ARTIFACT_KEY.md (D5 amendment) OR _fidelity/$ARTIFACT_KEY.escalation.md (D5 escalation), then re-run lore work check"
    exit_with
    ;;
  unjudgeable)
    # Amendment alone NOT sufficient — that would paper over the spec-quality problem.
    # Accept on escalation only (D5 branch artifact contract).
    if [[ -f "$ESCALATION_PATH" ]]; then
      exit 0
    fi
    if [[ -f "$AMENDMENT_PATH" ]]; then
      emit_diag "unjudgeable verdict at $ARTIFACT_PATH cannot be satisfied by an amendment alone (would paper over a spec-quality failure). Write _fidelity/$ARTIFACT_KEY.escalation.md or respawn the judge after clarifying the task spec"
    else
      emit_diag "unjudgeable verdict at $ARTIFACT_PATH requires _fidelity/$ARTIFACT_KEY.escalation.md (or a fresh non-unjudgeable superseding verdict via judge respawn)"
    fi
    exit_with
    ;;
  *)
    emit_diag "unrecognized verdict '$VERDICT' at $ARTIFACT_PATH (schema enum should have rejected this — schema/instance drift)"
    exit_with
    ;;
esac
