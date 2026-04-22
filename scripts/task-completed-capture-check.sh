#!/usr/bin/env bash
# task-completed-capture-check.sh — TaskCompleted hook
# Ensures agents in impl-*/spec-* teams include required sections in
# their completion reports before marking tasks done.
# Agent type is read from team config to determine requirements.
#
# Hard-validation contract (task #22):
#   Worker (general-purpose) and Researcher (Explore) reports must carry either
#     (a) ≥1 structured observation/assertion matching the shape
#         { claim: …, file: …, line_range: N-M, falsifier: …, significance: low|medium|high }
#     OR
#     (b) a well-formed escalation verdict of the shape
#         { escalation: "task-too-trivial-for-solo-decomposition", rationale: "<one-sentence reason>" }
#   Nothing else passes. Soft-matching on heading presence alone (the pre-Phase-2 behavior)
#   silently let empty observations through — the hard-check converts that failure mode into
#   an explicit blocked-exit with a lead-visible verdict path.
#
# Backwards-compat gate (task #23):
#   Hard-validation only FIRES when the report carries a `template_version` line —
#   a marker that the producing agent template has been rebuilt against F0 Phase 6 and
#   is expected to emit structured observations. Reports WITHOUT `template_version`
#   (legacy / pre-F0 templates) emit a single-line warning to the work item's
#   execution-log and exit 0 (allow). This preserves Exit Criterion #6 during the
#   transition window: operators can roll Phase 6 template updates without their
#   in-flight teams silently breaking.
#
#   The warning line is a migration signal. `/retro` reads execution-log and can
#   surface accumulated legacy-report counts as an evolution suggestion (raise the
#   gate to always-fire once legacy counts trend to zero).
#
# Input: JSON on stdin (TaskCompleted hook format)
# Output: exit 0 to allow, exit 2 + stderr to block

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
lore_agent_enabled || exit 0

INPUT=$(cat)

# Extract fields from hook input
TEAM_NAME=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('team_name') or '')")

# Fast exit: not a team task
if [[ -z "$TEAM_NAME" ]]; then
  exit 0
fi

# Only enforce for impl-*/spec-* teams
case "$TEAM_NAME" in
  impl-*|spec-*) ;;
  *) exit 0 ;;
esac

TASK_DESC=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('task_description') or '')")
AGENT_NAME=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('agent_name') or d.get('owner') or '')")

# Resolve agent type from team config
AGENT_TYPE=""
TEAM_CONFIG="$HOME/.claude/teams/$TEAM_NAME/config.json"
if [[ -f "$TEAM_CONFIG" && -n "$AGENT_NAME" ]]; then
  AGENT_TYPE=$(python3 -c "
import json, sys
with open('$TEAM_CONFIG') as f:
    config = json.load(f)
for m in config.get('members', []):
    if m.get('name') == '$AGENT_NAME':
        print(m.get('agentType', ''))
        sys.exit(0)
print('')
" 2>/dev/null || true)
fi

# report_has_template_version — look for a `Template-version:` line or a
# `template_version:` yaml-style field anywhere in $TASK_DESC.
# Returns 0 if present, 1 if absent.
report_has_template_version() {
  # Both the Template-version: execution-log header style and the yaml-style
  # template_version: field used in YAML front-matter / scorecard row bodies
  # are accepted. Case-insensitive on the key to tolerate minor authoring drift.
  printf '%s' "$TASK_DESC" | grep -qiE '^[[:space:]]*template[_-]version[[:space:]]*:[[:space:]]*[A-Za-z0-9_-]+'
}

# derive_work_slug — derive the work-item slug from the team name.
# team_name convention is "impl-<slug>" or "spec-<slug>"; strip the prefix.
derive_work_slug() {
  case "$TEAM_NAME" in
    impl-*) echo "${TEAM_NAME#impl-}" ;;
    spec-*) echo "${TEAM_NAME#spec-}" ;;
    *) echo "" ;;
  esac
}

# emit_legacy_warning — append a one-line migration-signal entry to the work
# item's execution-log. Best-effort: if write-execution-log.sh is not callable
# or the slug can't be derived, fall back to a stderr warning so the signal is
# still visible to the operator. Never blocks — this is the backwards-compat
# path, so returning a non-zero from here would defeat the gate's purpose.
emit_legacy_warning() {
  local slug reason
  slug=$(derive_work_slug)
  reason="$1"
  local warning="LEGACY REPORT: $AGENT_NAME ($AGENT_TYPE) completed task without template_version. Reason: $reason. Migration signal for /retro."

  if [[ -n "$slug" && -x "$SCRIPT_DIR/write-execution-log.sh" ]]; then
    printf '%s\n' "$warning" \
      | "$SCRIPT_DIR/write-execution-log.sh" \
          --slug "$slug" \
          --source "manual" \
          --phase "legacy-compat-warning" \
          >/dev/null 2>&1 \
      || echo "[task-completed] warning: $warning" >&2
  else
    echo "[task-completed] warning: $warning" >&2
  fi
}

# validate_structured_report — hard-validate that $TASK_DESC contains either
# ≥1 structured observation/assertion OR a well-formed escalation verdict.
# Prints a human-readable diagnostic to stderr when it fails.
# Accepts one arg: the heading name to look under ("Observations" or "Assertions").
#
# Returns 0 on pass, 1 on fail (sets FAIL_REASON in the caller for use in error message).
validate_structured_report() {
  local section_heading="$1"
  local verdict
  verdict=$(printf '%s' "$TASK_DESC" | python3 "$SCRIPT_DIR/validate-structured-report.py" "$section_heading" 2>&1) || true

  if [[ "${verdict}" == PASS_* ]]; then
    return 0
  fi
  # Strip leading "FAIL: " for the reason string
  FAIL_REASON="${verdict#FAIL: }"
  return 1
}

# Enforce required sections based on agent type
# Explore → researcher: require **Assertions:** with ≥1 structured entry OR escalation
# general-purpose → worker: require **Observations:** with ≥1 structured entry OR escalation
# Other types (team-lead, unknown) → no structural requirements

# Backwards-compat gate (task #23): only enforce for reports that carry a
# template_version marker. Legacy/pre-F0 reports emit a migration warning and
# pass. Team-leads always pass (no structural requirements); they do not need
# to trip the legacy-warning path, so we skip the gate for them below.
if [[ "$AGENT_TYPE" != "team-lead" ]]; then
  if ! report_has_template_version; then
    emit_legacy_warning "no template_version line in report; enforcement skipped"
    exit 0
  fi
fi

FAIL_REASON=""
case "$AGENT_TYPE" in
  Explore)
    # Researcher agents: hard-validate Assertions. Observations (prose) is no longer
    # separately required — the structured Assertions schema carries the primary signal.
    if validate_structured_report "Assertions"; then
      exit 0
    fi
    echo "Update the task description before marking complete." >&2
    echo "Required: ≥1 structured assertion under **Assertions:** with all of {claim, file, line_range, falsifier, significance} (significance ∈ {low, medium, high}), OR a well-formed escalation verdict {escalation: \"task-too-trivial-for-solo-decomposition\", rationale: \"<one-sentence reason>\"}." >&2
    echo "Validation failure: $FAIL_REASON" >&2
    exit 2
    ;;
  general-purpose)
    # Worker agents: hard-validate Observations.
    if validate_structured_report "Observations"; then
      exit 0
    fi
    echo "Update the task description before marking complete." >&2
    echo "Required: ≥1 structured observation under **Observations:** with all of {claim, file, line_range, falsifier, significance} (significance ∈ {low, medium, high}), OR a well-formed escalation verdict {escalation: \"task-too-trivial-for-solo-decomposition\", rationale: \"<one-sentence reason>\"}." >&2
    echo "Validation failure: $FAIL_REASON" >&2
    exit 2
    ;;
  team-lead)
    # Team leads have no structural requirements.
    exit 0
    ;;
  *)
    # Unknown or empty agent type — apply worker-style hard-validation as default.
    if validate_structured_report "Observations"; then
      exit 0
    fi
    echo "Update the task description before marking complete." >&2
    echo "Required: ≥1 structured observation under **Observations:** with all of {claim, file, line_range, falsifier, significance} (significance ∈ {low, medium, high}), OR a well-formed escalation verdict {escalation: \"task-too-trivial-for-solo-decomposition\", rationale: \"<one-sentence reason>\"}." >&2
    echo "Validation failure: $FAIL_REASON" >&2
    exit 2
    ;;
esac
