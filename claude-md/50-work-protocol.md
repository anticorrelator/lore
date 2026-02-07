## Work Protocol

Work items persist at `~/.project-knowledge/repos/<repo>/_work/`. Use `/work` for lifecycle management.

### Default to /work

`/work` is the primary way to create and manage work items. It handles persistence, indexing, and cross-referencing automatically.

**Builtin plan mode (EnterPlanMode/ExitPlanMode) produces ephemeral plans** that live at `~/.claude/plans/` and are lost across sessions. Only use it for quick, small-scope planning that doesn't need to survive the current session. For anything that warrants persistence — multi-step work, design decisions, cross-session tasks — use `/work` instead.

### Every Work Item Gets Persisted

ALL planning work MUST create durable artifacts in `_work/` — whether triggered by `/work`, builtin `EnterPlanMode`, or inline design discussion. **No ephemeral plans.**

**If you used builtin plan mode:** A Stop hook will remind you to persist. Don't wait for it — persist immediately after the user approves the plan. Create the `_work/<slug>/` directory with `_meta.json` and `plan.md`.

### Auto-Create Work Items (Low Threshold)

Create a work item proactively when ANY apply:
- Design discussion with trade-offs or architecture choices
- Multi-file changes or multi-step implementation
- Ambiguous scope — goal is clear, path isn't
- System/meta changes — eat your own dog food
- Cross-session work — anything that might not finish now

**When in doubt, create it.** A `notes.md` costs nothing and provides cross-session continuity. Add `/spec` later if it grows.

### Session Continuity

Before compaction or at break points, capture progress to `notes.md` via `/work update`.

### Cross-References
- Work items -> knowledge: `[[knowledge:conventions#Pattern Name]]`
- Knowledge -> work items: `[[work:auth-refactor]]`
