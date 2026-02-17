---
name: implement
description: "Execute a spec's plan with a knowledge-aware agent team — spawns workers, tracks progress, captures architectural findings"
user_invocable: true
argument_description: "[work item name] [--model opus|sonnet]"
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - Edit
  - Write
  - TaskCreate
  - TaskUpdate
  - TaskList
  - TaskGet
  - Task
  - TeamCreate
  - TeamDelete
  - SendMessage
  - AskUserQuestion
  - Skill
---

# /implement Skill

Executes a work item's `plan.md` with a team of knowledge-aware agents. Agents read existing knowledge before working, report architectural findings, and the lead captures reusable insights afterward.

## Resolve Work Path

```bash
lore resolve
```
Set `KNOWLEDGE_DIR` to the result and `WORK_DIR` to `$KNOWLEDGE_DIR/_work`.

## Step 1: Load work item and validate

1. Parse arguments: extract work item name and optional `--model` flag (default: `sonnet`, accept `opus`)
2. Resolve work item using the same fuzzy matching algorithm as `/work`:
   - Exact slug match → substring match on title → substring on slug → branch match → recency
3. Read `_meta.json`, `plan.md`, and last entry of `notes.md`
4. **If no `plan.md`:** Tell user "No structured plan found. Run `/spec` first to create phases and tasks."
5. **If `plan.md` has no `## Phases` or no unchecked `- [ ]` items:** Tell user "All plan tasks are already complete."
6. Present a brief summary and proceed immediately:
   ```
   [implement] <Title>
   Model: sonnet (override with --model opus)
   Phases: N with M unchecked tasks
   ```

## Step 2: Create team and generate tasks

**IMPORTANT: Create the team BEFORE creating tasks.** TaskCreate calls go into whichever task list is active. If you create tasks before TeamCreate, they land in the session's default list — invisible to workers who see the team's list. This produces orphaned stale tasks that persist for the rest of the session.

1. **Create team first:**
   ```
   TeamCreate: team_name="impl-<slug>", description="Implementing <work item title>"
   ```

2. **Read your team lead name** from `~/.claude/teams/impl-<slug>/config.json`.

3. **Check for pre-computed tasks:** Look for `tasks.json` in the work item directory (`$WORK_DIR/<slug>/tasks.json`).

4. **If `tasks.json` exists:**
   a. Compute the SHA256 checksum of `plan.md`:
      ```bash
      PLAN_CHECKSUM=$(shasum -a 256 "$WORK_DIR/<slug>/plan.md" | cut -d' ' -f1)
      ```
   b. Read `tasks.json` and compare `plan_checksum` against the computed checksum.
   c. **If checksums match:** Load tasks directly from the `phases[].tasks[]` arrays in the JSON. Each task has pre-computed `id`, `subject`, `description`, `activeForm`, and `blockedBy` fields. Execute a `TaskCreate` call for each task. Set up dependencies using the `blockedBy` arrays (these reference task IDs like `"task-1"`, `"task-2"` — map them to actual TaskCreate IDs).
   d. **If checksums differ:** Warn the user: "plan.md was edited after tasks.json was generated. Run `/work regen-tasks` to regenerate tasks, or proceed with current tasks.json." Wait for user confirmation before continuing with either the stale JSON or falling back to script generation.

5. **If `tasks.json` does not exist (fallback):** Run the task generation script:
   ```bash
   lore work tasks <slug>
   ```
   This outputs the full `tasks.json` schema (`{plan_checksum, generated_at, phases[]}`). Each task in `phases[].tasks[]` has pre-computed `id`, `subject`, `description`, `activeForm`, and `blockedBy` fields. Task descriptions include a `## Prior Knowledge` heading (4000-char budget) with resolved backlinks from phase-level `**Knowledge context:**` + cross-cutting `## Related`/`## Design Decisions` references. The script extracts unchecked `- [ ]` items from each phase (already-checked `- [x]` items are skipped, supports resume).
   Parse the JSON output and execute a `TaskCreate` call for each task in `phases[].tasks[]`. Set up dependencies using the pre-computed `blockedBy` arrays (these reference task IDs like `"task-1"`, `"task-2"` — map them to actual TaskCreate IDs).

6. **Set up phase dependencies:** Use the pre-computed `blockedBy` arrays from the JSON output. Both the pre-computed `tasks.json` path (item 4c) and the fallback `lore work tasks` path (item 5) produce the same schema with pre-computed dependencies — no manual phase grouping needed.

## Step 3: Spawn agents

**All tasks are executed by fresh worker agents.** The lead does not implement tasks directly — even if the task seems small or the lead already has relevant context. Fresh agents with injected knowledge context produce cleaner results than the lead's accumulated orchestration context. If a task is too small for a worker, it should have been consolidated at spec time.

1. **Pre-fetch knowledge for worker prompts** — determine whether prefetch is needed:

   **If tasks have pre-resolved knowledge** (task descriptions contain `## Prior Knowledge`): **skip prefetch entirely.** The generate-tasks pipeline already resolved backlinks into task descriptions. Prefetching would duplicate this content and waste prompt budget. This should be the common path — well-authored plans from `/spec` include `**Knowledge context:**` blocks in every phase, and `generate-tasks.py` resolves those backlinks into each task description automatically.

   **If tasks lack pre-resolved knowledge** (fallback path, e.g. manually created tasks or plans without `**Knowledge context:**` blocks): run complementary prefetch using the task's `**Files:**` paths and phase objective — not a generic topic string:
   ```bash
   # Use file paths + objective as query terms for targeted retrieval
   PRIOR_KNOWLEDGE=$(lore prefetch "<phase objective> <file paths from task>" --format prompt --limit 3)
   ```
   For example, if a task has `**Files:** scripts/pk_search.py` and `**Phase objective:** Fix hyphenated-term quoting`, the prefetch query would be `"Fix hyphenated-term quoting pk_search.py"`.

2. **Spawn worker agents** — launch `min(task_count, 4)` in a single message. Use the **worker** agent definition (`~/.claude/agents/worker.md`) as the base prompt, with these template injections:
   - `{{team_name}}` → `impl-<slug>`
   - `{{team_lead}}` → the lead name read from team config in Step 2
   - `{{prior_knowledge}}` → the `$PRIOR_KNOWLEDGE` block from Step 3.1 (or empty if tasks have pre-resolved knowledge)

   ```
   Task:
     subagent_type: "general-purpose"
     model: "<selected-model>"
     team_name: "impl-<slug>"
     name: "worker-N"
     mode: "bypassPermissions"
     prompt: |
       <contents of ~/.claude/agents/worker.md with {{template}} variables resolved>
   ```

3. If more tasks than workers, agents pick up additional tasks after completing their first.

## Step 4: Collect progress

As worker messages arrive (delivered automatically):

1. **Update plan.md** (best-effort) — check off completed items as they arrive:
   ```bash
   lore work check <slug> "<task-subject>"
   ```
   If this fails or is missed, Step 6 reconciles from the task system.
2. **Log architectural findings** — note interesting patterns reported by workers for Step 5
3. **Handle blockers** — if a worker reports blockers:
   - Read the relevant code/context
   - Send guidance via `SendMessage` to the blocked worker
   - If unresolvable, note in `notes.md` and move on

Do NOT gate on reviewing diffs — workers proceed autonomously. The user reviews at the end.

When all tasks are complete (or all remaining are blocked):
1. Send `shutdown_request` to all workers
2. Run `TeamDelete`

## Step 5: Post-implementation extraction

Invoke `/remember` with capture constraints scoped to the implementation:

```
/remember Implementation findings from <work item title> — Evaluate worker-reported **Observations:** from task completion reports against the capture gate (reusable, non-obvious, stable, high-confidence) using full project context. Also capture: cross-task patterns visible only from the lead's vantage, integration gotchas that emerged from combining worker changes, conventions confirmed or violated across multiple tasks.
```

## Step 6: Cleanup and report

1. Append a session entry to `notes.md`:
   ```markdown
   ## YYYY-MM-DDTHH:MM
   **Focus:** Implementation via /implement
   **Progress:** Completed N/M tasks across K phases
   **Findings:** <key architectural patterns captured>
   **Next:** <remaining tasks if partial, or "Implementation complete">
   ```
2. **Reconcile plan.md from task system** — the task system is the source of truth for completion. For each completed task, ensure the corresponding plan.md checkbox is checked:
   ```bash
   lore work check <slug> "<task-subject>"
   ```
   Run this for every completed task whose checkbox is still unchecked. This catches any checkboxes missed during Step 4.
3. **Archival decision** — based on the task system, not plan.md:
   - **All tasks completed:** Archive the work item: `lore work archive "<slug>"`
   - **Some tasks incomplete or blocked:** Leave the work item active for later `/implement` resumption
4. Run `lore work heal`
5. Report to user:
   ```
   [implement] Done.
   Completed: N/M tasks
   Knowledge captured: K entries to knowledge store
   Remaining: <list if any, or "none — work item archived">
   Consider `/retro <slug>` to evaluate knowledge system effectiveness for this work.
   ```

## Handling Partial Completion

If workers hit blockers or the team can't finish all tasks:
1. Capture progress to `notes.md` via the session entry above
2. Reconcile plan.md from the task system (Step 6.2) — completed tasks get checked, incomplete ones stay unchecked
3. Report what completed and what's left
4. The user can re-run `/implement` later to pick up remaining tasks (Step 2 skips checked items)

## Resuming Implementation

When `/implement` is called on a work item with partially-checked `plan.md`:
- Only generate tasks for unchecked `- [ ]` items
- Skip phases where all items are checked
- Report: "Resuming — N remaining tasks across M phases"
