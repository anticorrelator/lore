#!/usr/bin/env bash
# pre-compact.sh — PreCompact hook: remind Claude to capture unsaved insights
# Usage: bash pre-compact.sh
# Called by Claude Code PreCompact hook before context compaction

set -euo pipefail

cat << 'EOF'
[Knowledge Store — Pre-Compaction Reminder]
Before context is compacted, consider whether you've discovered any reusable insights during this session that should be preserved. If so, append them to `_inbox.md` now using the standard inbox entry format. Only capture insights that are:
- Reusable (applicable beyond the current task)
- Non-obvious (not in README/CLAUDE.md/docs)
- Stable (unlikely to change soon)
- High confidence (verified, not speculative)

[Threads — Pre-Compaction Action]
Update any active threads with this session's discussion before compaction. For each thread touched this session:
1. Append a new `## YYYY-MM-DD` entry with Summary, Key points, and any Shifts
2. Update the `updated` and `sessions` fields in the YAML frontmatter

[Planning — Pre-Compaction Reminder]
If you've been working on a plan this session, run `/explore-and-plan update` to capture session progress
(focus, decisions, progress, next steps) before context is compacted.
EOF
