#!/usr/bin/env bash
# pre-compact.sh — PreCompact hook: remind Claude to capture unsaved insights
# Usage: bash pre-compact.sh
# Called by Claude Code PreCompact hook before context compaction

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
lore_agent_enabled || exit 0

cat << 'EOF'
[Knowledge Store — Pre-Compaction Reminder]
Before context is compacted, consider whether you've discovered any reusable insights during this session that should be preserved. If so, append them to `_inbox.md` now using the standard inbox entry format. Capture when the candidate passes the 4-condition gate OR the orientation gate.

4-condition gate (all four must be true — for facts, gotchas, rationale, conventions, directives):
- Reusable (applicable beyond the current task)
- Non-obvious — non-obvious to a future agent doing similar work; not already recoverable from sources a future agent loads before raw exploration (the harness instructions file, knowledge-store entries already loaded at session start, or in-tree documentation a sibling prefetch would surface)
- Stable (unlikely to change soon)
- High confidence (verified, not speculative)

Whose perspective: condition 2 is agent-centric, not reader-centric — ask "would a future agent re-derive this from sources they already read, or would they have to dig?" rather than treating the agent's knowledge state as identical to a reader skimming the repo. The commons is curated by agents for agents.

Orientation gate (all five must be true — for system maps, lifecycle overviews, cross-boundary assembly):
1. Reusable — likely needed by future agents on more than one task. (Recurrence is required, not "could be useful someday.")
2. Cross-boundary — reconstructing the understanding requires tracing behavior across at least 2 boundaries from this set: routing layer, persistence, lifecycle phase, state index, external command, shared helper, or protocol layer. (One-file orientation isn't orientation — it's either obvious or a gotcha.)
3. Canonical — states the system's intended shape, not one agent's casual paraphrase. Disagrees with code? Don't capture — fix the code or capture a gotcha.
4. Anchored — names the specific files, commands, tests, or directories that verify the claim (--related-files). Unanchored orientation goes stale invisibly.
5. Stable at architecture or subsystem altitude — tag the entry architecture, subsystem, or architecture,subsystem. Implementation-scale orientation is malformed — route to the 4-condition gate as a fact, or drop.

[Threads — Pre-Compaction Action]
Update any active threads with this session's discussion before compaction. For each thread touched this session:
1. Append a new `## YYYY-MM-DD` entry with Summary, Key points, and any Shifts
2. Update the `updated` and `sessions` fields in the YAML frontmatter

[Work — Pre-Compaction Reminder]
If you've been working on a work item this session, run `/work update` to capture session progress
(focus, decisions, progress, next steps) before context is compacted.

If you used builtin plan mode (EnterPlanMode/ExitPlanMode) this session, verify the plan was persisted
to `_work/`. Ephemeral plan files at `~/.claude/plans/` do not survive across sessions.
EOF
