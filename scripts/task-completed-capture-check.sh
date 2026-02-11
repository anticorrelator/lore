#!/usr/bin/env bash
# task-completed-capture-check.sh — TaskCompleted hook
# Ensures agents in impl-*/spec-* teams include required sections in
# their completion reports before marking tasks done.
# Agent type is read from team config to determine requirements.
#
# Input: JSON on stdin (TaskCompleted hook format)
# Output: exit 0 to allow, exit 2 + stderr to block

set -euo pipefail

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

# Enforce required sections based on agent type
# Explore → researcher: require **Assertions:** + **Observations:**
# general-purpose → worker: require **Observations:**
# Other types (team-lead, unknown) → no structural requirements

case "$AGENT_TYPE" in
  Explore)
    # Researcher agents must include both Assertions and Observations
    HAS_ASSERTIONS=false
    HAS_OBSERVATIONS=false
    if echo "$TASK_DESC" | grep -qE '\*\*Assertions:\*\*'; then
      HAS_ASSERTIONS=true
    fi
    if echo "$TASK_DESC" | grep -qE '\*\*Observations:\*\*|\*\*Architectural patterns:\*\*'; then
      HAS_OBSERVATIONS=true
    fi
    if $HAS_ASSERTIONS && $HAS_OBSERVATIONS; then
      exit 0
    fi
    MISSING=""
    if ! $HAS_ASSERTIONS; then MISSING="**Assertions:**"; fi
    if ! $HAS_OBSERVATIONS; then
      if [[ -n "$MISSING" ]]; then MISSING="$MISSING and "; fi
      MISSING="${MISSING}**Observations:**"
    fi
    echo "Update the task description with your full findings report (including $MISSING section(s)) before marking complete." >&2
    exit 2
    ;;
  general-purpose)
    # Worker agents must include Observations
    if echo "$TASK_DESC" | grep -qE '\*\*Observations:\*\*|\*\*Architectural patterns:\*\*'; then
      exit 0
    fi
    echo "Update the task description with your full completion report (including **Observations:** section) before marking complete." >&2
    exit 2
    ;;
  team-lead)
    # Team leads have no structural requirements
    exit 0
    ;;
  *)
    # Unknown or empty agent type — fall back to original behavior:
    # require **Observations:** for any agent in impl-*/spec-* teams
    if echo "$TASK_DESC" | grep -qE '\*\*Observations:\*\*|\*\*Architectural patterns:\*\*'; then
      exit 0
    fi
    echo "Update the task description with your full completion report (including **Observations:** section) before marking complete." >&2
    exit 2
    ;;
esac
