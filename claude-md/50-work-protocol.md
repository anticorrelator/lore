## Work Protocol

Work items persist in the project's `_work/` directory (path resolved by `lore resolve`). Use `/work` for lifecycle management.

### Default to /work

`/work` is the primary way to create and manage work items. It handles persistence, indexing, and cross-referencing automatically.

**Never write work item files directly** (mkdir, Write `_meta.json`, etc.). Always use `lore work create --title "<name>"` — this handles slug generation, indexing, and metadata consistently. This applies to agents and subagents too: if a task requires creating a work item, invoke the CLI, not the filesystem.

**Builtin plan mode (where the harness exposes one — e.g., Claude Code's `EnterPlanMode`/`ExitPlanMode`) produces ephemeral plans** that live in the harness's transient plan storage (resolved via `resolve_harness_install_path ephemeral_plans`; `unsupported` on harnesses without one) and are lost across sessions. Only use it for quick, small-scope planning that doesn't need to survive the current session. For anything that warrants persistence — multi-step work, design decisions, cross-session tasks — use `/work` instead.

### Every Work Item Gets Persisted

ALL planning work MUST create durable artifacts in `_work/` — whether triggered by `/work`, a harness's builtin plan mode, or inline design discussion. **No ephemeral plans.**

**If you used builtin plan mode:** On harnesses where a Stop hook is wired (capability `stop_hook=full`), it will remind you to persist. Don't wait for it — persist immediately after the user approves the plan via `/work create`. Where `stop_hook` degrades, the reminder may not fire and persistence is your responsibility.

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
