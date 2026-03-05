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

3. **Load tasks** — run a single command that validates the checksum and outputs all tasks as structured text:
   ```bash
   lore work load-tasks <slug>
   ```
   - **If `tasks.json` exists and checksum matches:** outputs a header line followed by `=== task-N ===` blocks, one per task, each with `subject`, `activeForm`, `blockedBy`, and `description`.
   - **If `tasks.json` exists but checksum mismatches:** exits with an error. Tell the user: "plan.md was edited after tasks.json was generated. Run `/work regen-tasks <slug>` to regenerate, or edit plan.md back." Wait for user decision.
   - **If `tasks.json` does not exist:** exits with an error. Run the fallback instead (item 4 below).

4. **Fallback — `tasks.json` missing:** Run the task generation script:
   ```bash
   lore work tasks <slug>
   ```
   This generates and prints the full `tasks.json` schema. Pipe through `lore work load-tasks <slug>` afterward (it will now find the file), or re-run `lore work load-tasks <slug>` directly.

5. **Create tasks from the output:** Read the `lore work load-tasks` output once. For each `=== task-N ===` block, execute one `TaskCreate` call using the `subject`, `activeForm`, and `description` fields. Track the mapping of `task-N` IDs to actual TaskCreate return IDs, then call `TaskUpdate(addBlockedBy=[...])` for any task with a non-empty `blockedBy` field.

## Step 3: Spawn agents

**All tasks are executed by fresh worker agents.** The lead does not implement tasks directly — even if the task seems small or the lead already has relevant context. Fresh agents with injected knowledge context produce cleaner results than the lead's accumulated orchestration context. If a task is too small for a worker, it should have been consolidated at spec time.

1. **Pre-fetch knowledge for worker prompts** — determine whether prefetch is needed:

   **If tasks lack knowledge context** (manually created tasks or plans without `**Knowledge context:**` blocks — no `## Prior Knowledge` section in task descriptions): run complementary prefetch using the task's file paths and phase objective:
   ```bash
   # Use file paths + objective as query terms for targeted retrieval
   PRIOR_KNOWLEDGE=$(lore prefetch "<phase objective> <file paths from task>" --format prompt --limit 3)
   ```
   For example, if a task has `**Files:** scripts/pk_search.py` and `**Phase objective:** Fix hyphenated-term quoting`, the prefetch query would be `"Fix hyphenated-term quoting pk_search.py"`.

   **If tasks have knowledge context** (task descriptions contain `## Prior Knowledge`): **skip prefetch.** This section contains either annotation-only summaries (default) or fully resolved content (when the phase specifies `**Knowledge delivery:** full`). In both cases, `generate-tasks.py` has already embedded the relevant knowledge — prefetching would duplicate or conflict with it.

2. **Prepare advisory mixin (if advisors present)** — scan all phases in `plan.md` for `**Advisors:**` blocks. If any phase declares advisors:

   a. **Collect advisor declarations** from all phases into a single list. Each entry has the format: `- advisor-name — domain scope. [must-consult|on-demand]`

   b. **Read the advisory mixin:** Read `scripts/agent-protocols/advisory-consultation.md`.

   c. **Build the `{{advisors}}` replacement block** from the collected declarations. Format as a markdown list with name, domain, and mode clearly separated:
      ```
      - **advisor-name** — domain scope. Mode: must-consult
      - **advisor-name** — domain scope. Mode: on-demand
      ```

   d. **Resolve `{{advisors}}`** in the mixin content by replacing the placeholder with the block from (c). Store the resolved mixin as `$ADVISORY_MIXIN`.

   If no phases declare advisors, set `$ADVISORY_MIXIN` to empty.

3. **Spawn advisor agents (if advisors present)** — if Step 3.2 found advisor declarations, spawn each unique advisor as a persistent team member before spawning workers.

   For each unique advisor name collected in Step 3.2a:

   a. **Build domain context** — find the `## Investigations` section(s) in `plan.md` whose topic relates to the advisor's domain scope. Extract the relevant investigation entry (findings, verified assertions, key files, implications) and format it as the advisor's domain baseline.

   b. **Spawn the advisor** using the **advisor** agent definition (`agents/advisor.md`) with these template injections:
      - `{{team_name}}` → `impl-<slug>`
      - `{{advisor_domain}}` → the advisor's domain scope from the plan annotation
      - `{{domain_context}}` → the investigation excerpt from Step 3.3a

      ```
      Task:
        subagent_type: "general-purpose"
        model: "<selected-model>"
        team_name: "impl-<slug>"
        name: "<advisor-name>"
        mode: "bypassPermissions"
        prompt: |
          <contents of agents/advisor.md with {{template}} variables resolved>
      ```

   Advisors are persistent — they remain active for the entire implementation session and are shut down alongside workers in Step 4.

   c. **Write execution log entries** — after all advisors are spawned, log each advisor's lifecycle event:
      ```bash
      printf 'Advisor spawned: %s\nDomain: %s\nMode: %s\n' \
        "<advisor-name>" "<domain scope>" "<must-consult|on-demand>" \
        | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead
      ```

4. **Spawn worker agents** — launch `min(task_count, 4)` in a single message. Use the **worker** agent definition (`agents/worker.md`) as the base prompt, with these template injections:
   - `{{team_name}}` → `impl-<slug>`
   - `{{team_lead}}` → the lead name read from team config in Step 2
   - `{{prior_knowledge}}` → the `$PRIOR_KNOWLEDGE` block from Step 3.1 (or empty if tasks have pre-resolved knowledge)

   **If `$ADVISORY_MIXIN` is non-empty:** append the resolved mixin content after the fully resolved `worker.md` content, separated by a blank line. The worker prompt becomes: `<resolved worker.md>\n\n<resolved advisory-consultation.md>`.

   ```
   Task:
     subagent_type: "general-purpose"
     model: "<selected-model>"
     team_name: "impl-<slug>"
     name: "worker-N"
     mode: "bypassPermissions"
     prompt: |
       <contents of agents/worker.md with {{template}} variables resolved>
       <if advisors: contents of advisory-consultation.md with {{advisors}} resolved>
   ```

5. If more tasks than workers, agents pick up additional tasks after completing their first.

## Step 4: Collect progress

As worker messages arrive (delivered automatically):

1. **Update plan.md** (best-effort) — check off completed items as they arrive:
   ```bash
   lore work check <slug> "<task-subject>"
   ```
   If this fails or is missed, Step 6 reconciles from the task system.

   **Write execution log entry** — immediately after `lore work check`, append to `execution-log.md`:
   ```bash
   printf 'Task: %s\nChanges: %s\nDiscoveries: %s\nTest result: %s\n' \
     "<task-subject>" "<worker Changes field>" "<worker Discoveries field>" "<passed|failed|skipped>" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead
   ```
   Use the worker's reported **Changes:** and **Discoveries:** fields verbatim. If the worker did not report a test result, use `skipped`. `execution-log.md` is created on first write.

2. **Log architectural findings** — note interesting patterns reported by workers for Step 5
3. **Handle blockers** — if a worker reports blockers:
   - Read the relevant code/context
   - Send guidance via `SendMessage` to the blocked worker
   - If unresolvable, note in `notes.md` and move on

Do NOT gate on reviewing diffs — workers proceed autonomously. The user reviews at the end.

When all tasks are complete (or all remaining are blocked):
1. Send `shutdown_request` to all workers and all advisor agents (if any were spawned in Step 3.3)
2. **Write advisor shutdown log entries** — for each advisor that was spawned, log the shutdown:
   ```bash
   printf 'Advisor shutdown: %s\nDomain: %s\n' \
     "<advisor-name>" "<domain scope>" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead
   ```
3. Run `TeamDelete`

## Step 5: Post-implementation extraction

Invoke `/remember` with capture constraints scoped to the implementation:

```
/remember Implementation findings from <work item title> — Read all **Discoveries:** entries from execution-log.md and evaluate each against the capture gate. Two valid capture targets: (1) mechanism-level patterns — how the system accomplishes X broadly, evaluate for novelty against existing knowledge; (2) structural footprint — module roles, integration points, what connects to/through a file, what constrains changes — evaluate against existing architectural knowledge for what isn't yet recorded. Function-level details do not qualify. Also capture: cross-task patterns visible only from the lead's vantage.
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
