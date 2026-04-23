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

## Resolve Paths

```bash
lore resolve
```
Set `KNOWLEDGE_DIR` to the result and `WORK_DIR` to `$KNOWLEDGE_DIR/_work`.

Agent template files live at `~/.claude/agents/` (symlinked to the lore repo). Do NOT use `git rev-parse --show-toplevel` for agent paths — the current repo is the target project, not the lore repo.

**MANDATORY:** You MUST read the actual template files from `~/.claude/agents/` when spawning agents. Do NOT skip this step. Do NOT generate inline agent prompts as a substitute. If the directory or files are missing, stop and report the error — never fall back to improvised prompts.

## Resolve Template Versions

Compute content-hashes of the agent templates you'll spawn and the skill template itself. These feed the `template_version` provenance field on every `lore capture`, `create-followup.sh`, and `write-execution-log.sh` call downstream, plus the `{{template_version}}` injection into each agent's resolved prompt (enabling the backwards-compat gate in task #23):

```bash
LEAD_TEMPLATE_VERSION=$(bash ~/.lore/scripts/template-version.sh ~/.claude/skills/implement/SKILL.md)
WORKER_TEMPLATE_VERSION=$(bash ~/.lore/scripts/template-version.sh ~/.claude/agents/worker.md)
ADVISOR_TEMPLATE_VERSION=$(bash ~/.lore/scripts/template-version.sh ~/.claude/agents/advisor.md)
```

Use these variables throughout the rest of the skill. If `template-version.sh` fails for any template, log a warning and continue with an empty string — downstream scripts accept the omitted flag as "no template version", which the backwards-compat gate (task #23) treats as a legacy report and warns + passes.

Registration into `$KDIR/_scorecards/template-registry.json` is handled automatically on first use by `scripts/scorecard-append.sh` — you do not need a separate registration step here (task #34/#35).

## Step 1: Load work item and validate

1. Parse arguments: extract work item name and optional `--model` flag (default: `sonnet`, accept `opus`)
2. Resolve work item using the same fuzzy matching algorithm as `/work`:
   - Exact slug match → substring match on title → substring on slug → branch match → recency → archive fallback
   - **If resolved item is tagged `[archived]`:** Warn the user: "This work item is archived. Proceed anyway?" Wait for explicit confirmation before continuing. If the user confirms, load from `$WORK_DIR/_archive/<slug>/`.
3. Read `_meta.json`, `plan.md`, and last entry of `notes.md`
4. **If no `plan.md`:** Tell user "No structured plan found. Run `/spec` first to create phases and tasks."
5. **If `plan.md` has no `## Phases` or no unchecked `- [ ]` items:** Tell user "All plan tasks are already complete."
6. **Write branch cache** — associate the current branch with this work item for downstream lookup:
   ```bash
   lore work cache-branch --write <slug>
   ```
   If the command fails, log `[implement] Warning: branch cache write failed` and continue — this is non-fatal.
7. Present a brief summary and proceed immediately:
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
   PRIOR_KNOWLEDGE=$(lore prefetch "<phase objective> <file paths from task>" --format prompt --limit 3 --scale-context worker)
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

3. **Skill reconciliation** — before spawning advisors, check if plan.md's `**Related skills:**` block lists skills that weren't declared as advisors in any phase:

   a. **Read `**Related skills:**`** from plan.md's `## Context` or `## Investigations` section (if present). This is the discovery researcher's output from `/spec`.

   b. **For each matched skill**, check whether any phase in `plan.md` declares it as an advisor (in a `**Advisors:**` block). A skill that appears in `**Related skills:**` but not in any `**Advisors:**` block is a candidate for late advisor declaration.

   c. **Declare missing advisors** — for each candidate, assess whether the skill's domain overlaps with any uncompleted phase's scope. If so, add an `**Advisors:**` entry to that phase in plan.md:
      ```
      **Advisors:**
      - <skill-name>-advisor — <skill domain scope>. on-demand
      ```
      Use `on-demand` mode for late-declared advisors (workers have already started context accumulation; must-consult would block them unnecessarily).

   d. **If no `**Related skills:**` block exists** or all matched skills are already declared as advisors, skip silently — proceed to Step 3.4.

   e. **If new advisors were declared**, re-collect all advisor declarations from plan.md phases and rebuild `$ADVISORY_MIXIN` (repeat Steps 3.2a–3.2d) before proceeding.

4. **Ceremony config injection** — read ceremony-level advisor overrides and merge them into the advisor pipeline:

   a. **Read configured advisors:**
      ```bash
      lore ceremony get implement
      ```
      This returns a JSON array of skill names (e.g., `["my-custom-skill"]`), or `[]` if no ceremony overrides are configured. **If the result is `[]`, skip to Step 3.5.**

   b. **Declare config-injected advisors** — for each skill in the returned array, check whether it is already declared as an advisor in any phase's `**Advisors:**` block. For each skill not already declared, add an `**Advisors:**` entry to the first uncompleted phase in plan.md:
      ```
      **Advisors:**
      - <skill-name>-advisor — <skill-name> domain (ceremony config). on-demand
      ```
      Use `on-demand` mode for config-injected advisors. If the phase already has an `**Advisors:**` block, append to it rather than creating a duplicate block.

   c. **Rebuild advisory mixin** — if any new advisors were declared in (b), re-collect all advisor declarations from all plan.md phases and rebuild `$ADVISORY_MIXIN` (repeat Steps 3.2a–3.2d).

   d. **Log config-injected advisors** — for each advisor added from ceremony config, write an execution log entry:
      ```bash
      printf 'Config-injected advisor: %s\nSource: ceremony config\nMode: on-demand\n' \
        "<skill-name>-advisor" \
        | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"
      ```

5. **Spawn advisor agents (if advisors present)** — if Step 3.2, Step 3.3, or Step 3.4 found advisor declarations, spawn each unique advisor as a persistent team member before spawning workers.

   For each unique advisor name collected from Step 3.2a, Step 3.3c, and Step 3.4b:

   a. **Build domain context** — find the `## Investigations` section(s) in `plan.md` whose topic relates to the advisor's domain scope. Extract the relevant investigation entry (findings, verified assertions, key files, implications) and format it as the advisor's domain baseline.

   b. **Spawn the advisor** using the **advisor** agent definition (`~/.claude/agents/advisor.md`) with these template injections:
      - `{{team_name}}` → `impl-<slug>`
      - `{{advisor_domain}}` → the advisor's domain scope from the plan annotation
      - `{{domain_context}}` → the investigation excerpt from Step 3.5a

      ```
      Task:
        subagent_type: "general-purpose"
        model: "<selected-model>"
        team_name: "impl-<slug>"
        name: "<advisor-name>"
        mode: "bypassPermissions"
        prompt: |
          <contents of ~/.claude/agents/advisor.md with {{template}} variables resolved>
      ```

   Advisors are persistent — they remain active for the entire implementation session and are shut down alongside workers in Step 4.

   c. **Write execution log entries** — after all advisors are spawned, log each advisor's lifecycle event. Pass `--template-version "$ADVISOR_TEMPLATE_VERSION"` because the content we're logging is sourced from the advisor template that was just resolved:
      ```bash
      printf 'Advisor spawned: %s\nDomain: %s\nMode: %s\n' \
        "<advisor-name>" "<domain scope>" "<must-consult|on-demand>" \
        | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$ADVISOR_TEMPLATE_VERSION"
      ```

6. **Spawn worker agents** — launch `min(recommended_workers, 4)` workers in a single message, where `recommended_workers` is the top-level field from `tasks.json` (fallback: `min(task_count, 4)` if the field is absent, for backward compatibility with old `tasks.json` files). Use the **worker** agent definition (`~/.claude/agents/worker.md`) as the base prompt, with these template injections:
   - `{{team_name}}` → `impl-<slug>`
   - `{{team_lead}}` → the lead name read from team config in Step 2
   - `{{prior_knowledge}}` → the `$PRIOR_KNOWLEDGE` block from Step 3.1 (or empty if tasks have pre-resolved knowledge)
   - `{{template_version}}` → `$WORKER_TEMPLATE_VERSION` from the "Resolve Template Versions" preamble. The worker echoes this in the `Template-version:` header of its completion report so the TaskCompleted-hook validator (task #22) can apply the backwards-compat gate (task #23) — pre-F0 reports without this hash warn + pass; F0-version reports hard-validate structured observations.

   **If `$ADVISORY_MIXIN` is non-empty:** append the resolved mixin content after the fully resolved `worker.md` content, separated by a blank line. The worker prompt becomes: `<resolved worker.md>\n\n<resolved advisory-consultation.md>`.

   ```
   Task:
     subagent_type: "general-purpose"
     model: "<selected-model>"
     team_name: "impl-<slug>"
     name: "worker-N"
     mode: "bypassPermissions"
     prompt: |
       <contents of ~/.claude/agents/worker.md with {{template}} variables resolved>
       <if advisors: contents of advisory-consultation.md with {{advisors}} resolved>
   ```

## Step 4: Collect progress

As worker messages arrive (delivered automatically):

1. **Update plan.md** (best-effort) — check off completed items as they arrive:
   ```bash
   lore work check <slug> "<task-subject>"
   ```
   If this fails or is missed, Step 7 reconciles from the task system.

   **Write execution log entry** — immediately after `lore work check`, append to `execution-log.md`. Pass `--template-version "$WORKER_TEMPLATE_VERSION"` because the body we're logging is the worker's report — the template version on the entry should reflect the producing template, not the lead's:
   ```bash
   printf 'Task: %s\nChanges: %s\nSkills: %s\nObservations: %s\nInvestigation: %s\nBlockers: %s\nAdvisor input: %s\nTest result: %s\n' \
     "<task-subject>" "<worker Changes field>" "<worker Skills used field>" "<worker Observations field>" \
     "<worker Investigation field>" "<worker Blockers field>" "<worker Advisor input field>" "<passed|failed|skipped>" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$WORKER_TEMPLATE_VERSION"
   ```
   Use the worker's reported **Changes:**, **Skills used:**, **Observations:**, **Investigation:**, **Blockers:**, and **Advisor input:** fields verbatim. If the worker did not report a test result, use `skipped`. If the worker did not report a Skills used field, use `None`. If the worker omitted Investigation, Blockers, or Advisor input, use `None`. `execution-log.md` is created on first write.

2. **Log architectural findings** — note interesting patterns reported by workers for Step 5
3. **Handle blockers** — if a worker reports blockers:
   - Read the relevant code/context
   - Send guidance via `SendMessage` to the blocked worker
   - If unresolvable, note in `notes.md` and move on

Do NOT gate on reviewing diffs — workers proceed autonomously. The user reviews at the end.

When a batch of workers has all reported completion:
1. Call `TaskList` to count remaining tasks with status `pending` and no `blockedBy` dependencies (unblocked tasks).
2. **If unblocked tasks remain:** spawn `min(unblocked_count, max_workers)` fresh workers (same worker template and injections as Step 3.6, incrementing worker names as `worker-N` continuing from the last worker index used). Then continue collecting progress from the new batch.
   - `max_workers` is the same cap used in Step 3.6: `min(recommended_workers, 4)`
   - Repeat this respawn cycle after each batch completes until no unblocked tasks remain.
3. **If no unblocked tasks remain** (all tasks are complete or all remaining are blocked):
   a. Send `shutdown_request` to all active workers and all advisor agents (if any were spawned in Step 3.5)
   b. **Write advisor shutdown log entries** — for each advisor that was spawned, log the shutdown:
      ```bash
      printf 'Advisor shutdown: %s\nDomain: %s\n' \
        "<advisor-name>" "<domain scope>" \
        | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$ADVISOR_TEMPLATE_VERSION"
      ```
   c. Run `TeamDelete`

## Step 5: Post-implementation extraction

Invoke `/remember` with capture constraints scoped to the implementation. Every `lore capture` call must carry provenance flags; for captures promoted from specific worker observations, preserve the original producer's attribution instead of the lead's:

- **Lead-original insights** (cross-task patterns visible only from the lead's vantage): pass `--producer-role implement-lead --protocol-slot Synthesis --work-item <slug>`.
- **Worker-sourced observations** (promoted from `execution-log.md` **Observations:**/**Investigation:** entries): pass `--producer-role worker` (the original producer), `--capturer-role implement-lead` (the lead doing the synthesis write), and `--source-artifact-ids <worker-task-ids>` (comma-separated). Keep `--protocol-slot Synthesis --work-item <slug>`.
- **Multi-producer synthesis**: split into one capture call per distinct producer — never merge into a single call. Each call carries that producer's `--source-artifact-ids`. Merging would erase the role × slot hierarchy the scale matrix depends on.

```
/remember Implementation findings from <work item title> — Read all **Observations:** and **Investigation:** entries from execution-log.md and evaluate each against the capture gate. Two valid capture targets: (1) mechanism-level patterns — how the system accomplishes X broadly, evaluate for novelty against existing knowledge; (2) structural footprint — module roles, integration points, what connects to/through a file, what constrains changes — evaluate against existing architectural knowledge for what isn't yet recorded. Function-level details do not qualify. Also capture: cross-task patterns visible only from the lead's vantage. Investigation entries (debugging detours, design pivots) qualify when the root cause or resolution reveals something non-obvious about the system.

Provenance on every `lore capture`:
  - Lead-original insight: `--producer-role implement-lead --protocol-slot Synthesis --work-item <slug> --template-version $LEAD_TEMPLATE_VERSION`.
  - Promoted worker observation: `--producer-role worker --capturer-role implement-lead --source-artifact-ids <worker-task-id[,id2,...]> --protocol-slot Synthesis --work-item <slug> --template-version $WORKER_TEMPLATE_VERSION`. The `--template-version` reflects the original producer's template — promoted observations carry the worker template hash, not the lead's, so scorecard rollups attribute learning signal to the correct template (see `architecture/scorecards/row-schema.md`).
  - Multi-producer synthesis: split per distinct producer; one capture call per producer, each with its own --source-artifact-ids and its own producer's --template-version. Never merge.
```

## Step 6: Followup Creation Gate

Check for incomplete tasks or explicit blockers. Skip silently if everything completed cleanly.

**Signal detection** — check two sources:

1. **Incomplete tasks** — call `TaskList`. Flag if any tasks remain with status `pending` or `in_progress`.
2. **Explicit blockers** — read `execution-log.md` for worker report entries where `Blockers:` contains any text other than `none` (case-insensitive).

**If no signals found:** skip to Step 7.

**If signals found:** create a followup:

```bash
bash ~/.lore/scripts/create-followup.sh \
  --title "Deferred work: <work item title>" \  # ≤70 chars
  --source "implement" \
  --attachments '[{"type":"work_item","slug":"<slug>"}]' \
  --suggested-actions '[{"type":"create_work_item"}]' \
  --content "<one-line summary of what didn't finish and why, followed by a checklist of remaining items>"
```

## Step 7: Cleanup and report

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
   Followup: <"<title>" if created, omit line if not>
   Consider `/retro <slug>` to evaluate knowledge system effectiveness for this work.
   ```

## Handling Partial Completion

If workers hit blockers or the team can't finish all tasks:
1. Capture progress to `notes.md` via the session entry above
2. Reconcile plan.md from the task system (Step 7.2) — completed tasks get checked, incomplete ones stay unchecked
3. Report what completed and what's left
4. The user can re-run `/implement` later to pick up remaining tasks (Step 2 skips checked items)

## Resuming Implementation

When `/implement` is called on a work item with partially-checked `plan.md`:
- Only generate tasks for unchecked `- [ ]` items
- Skip phases where all items are checked
- Report: "Resuming — N remaining tasks across M phases"
