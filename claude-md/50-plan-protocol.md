## Plan Protocol

Plans persist at `~/.project-knowledge/repos/<repo>/_plans/`. Use `/explore-and-plan` for lifecycle management.

### Every Plan Gets Persisted

ALL planning work MUST create durable artifacts in `_plans/` — whether triggered by `/explore-and-plan`, builtin `EnterPlanMode`, or inline design discussion. **No ephemeral plans.**

**After using builtin plan mode (EnterPlanMode/ExitPlanMode):** Immediately persist the plan to `_plans/`. Create the directory, `_meta.json`, and write plan content to `plan.md`. The builtin plan file is ephemeral — `_plans/` is durable.

### Auto-Create Plans (Low Threshold)

Create a plan proactively when ANY apply:
- Design discussion with trade-offs or architecture choices
- Multi-file changes or multi-step implementation
- Ambiguous scope — goal is clear, path isn't
- System/meta changes — eat your own dog food
- Cross-session work — anything that might not finish now

**When in doubt, create it.** A `notes.md` costs nothing and provides cross-session continuity. Add `/explore-and-plan design` later if it grows.

### Session Continuity

Before compaction or at break points, capture progress to `notes.md` via `/explore-and-plan update`.

### Cross-References
- Plans → knowledge: `[[knowledge:conventions#Pattern Name]]`
- Knowledge → plans: `[[plan:auth-refactor]]`
