---
name: implement
description: "Execute a spec's plan with a knowledge-aware agent team — spawns workers, tracks progress, captures architectural findings"
user_invocable: true
argument_description: "[work item name] [--model sonnet|opus]"
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

Executes a work item's `plan.md` with a team of knowledge-aware agents. Agents produce Tier 2 task evidence during work and optionally surface Tier 3 candidates for commons promotion. The lead verifies, promotes accepted candidates via `lore promote`, and writes a retro-prep bundle for the next-step `/retro` ceremony.

## Approach

**Approach this work from confidence, not caution.** Mistakes are part of working; most are recoverable through normal review. The cost of constant deferral on settled steps exceeds the cost of occasional errors caught later. When the rubric or the protocol gives you a clear path, take it. Defer at genuine forks (multiple plausible directions where the protocol does not pre-decide) or at high-blast-radius operations (destructive, hard-to-reverse, or shared-state-affecting). Defer is a tool for forks, not a default for actions.

## Resolve Paths

```bash
lore resolve
```
Set `KNOWLEDGE_DIR` to the result and `WORK_DIR` to `$KNOWLEDGE_DIR/_work`.

Agent template files live at `~/.claude/agents/` (symlinked to the lore repo). Do NOT use `git rev-parse --show-toplevel` for agent paths — the current repo is the target project, not the lore repo.

**MANDATORY:** You MUST read the actual template files from `~/.claude/agents/worker.md` and `~/.claude/agents/advisor.md` when spawning agents. Do NOT skip this step. Do NOT generate inline agent prompts as a substitute. If the directory or files are missing, stop and report the error — never fall back to improvised prompts.

## Resolve Template Versions

Compute content-hashes of the agent templates you'll spawn and the skill template itself. These feed the `template_version` provenance field on every downstream emission site (`evidence-append.sh` via worker prompt, `lore promote`, `write-execution-log.sh`, scorecard rows), plus the `{{template_version}}` injection into each agent's resolved prompt:

```bash
LEAD_TEMPLATE_VERSION=$(bash ~/.lore/scripts/template-version.sh ~/.claude/skills/implement/SKILL.md)
WORKER_TEMPLATE_VERSION=$(bash ~/.lore/scripts/template-version.sh ~/.claude/agents/worker.md)
ADVISOR_TEMPLATE_VERSION=$(bash ~/.lore/scripts/template-version.sh ~/.claude/agents/advisor.md)
```

Use these variables throughout the rest of the skill. The three are NOT interchangeable — each tags emissions produced by its matching template. If `template-version.sh` fails for any template, log a warning and continue with an empty string; downstream scripts treat the omitted flag as "no template version" (CC-01 legacy warn+pass).

Registration into `$KDIR/_scorecards/template-registry.json` is handled automatically on first use by `scripts/scorecard-append.sh` — no separate registration step.

## Protocol-to-Skill Projection (10 → 7)

Proposal §9.2 describes the flow as ten logical steps. This SKILL.md presents them as seven top-level `### Step N` sections — a compatibility-preserving projection that keeps related concerns (load vs. verify vs. promote) on clean section boundaries. The mapping:

| §9.2 Logical Step | SKILL.md Step |
|---|---|
| 1 Load tasks.json + Tier 2 evidence + prefetched commons | Step 1 |
| 2 Dispatch workers with scope, files, acceptance checks, evidence requirements | Step 2 + Step 3 |
| 3 Workers produce code + tests + Tier 2 + optional Tier 3 | Step 3 |
| 4 Lead verifies work output + Tier 2 evidence | Step 4 |
| 5 Lead separates accepted work from remembered doctrine | Step 4 |
| 6 Lead writes/updates execution evidence | Step 4 |
| 7 Lead runs `lore promote` on accepted Tier 3 | Step 5 |
| 8 Stop hook lazily triggers audit; completion non-blocking | Step 6 (reference only; no explicit call) |
| 9 If PR exists or review requested, branch to `/pr-review` | Step 7 sub-step |
| 10 Prepare `/retro` inputs | Step 7 |

**Lead-inline route variant.** Step 3.0 introduces a pre-dispatch short-circuit. When the plan satisfies the lead-inline conditions (single prescriptive task, ≤3 files, no advisors), §9.2 steps 2–6 collapse into direct lead execution: the lead applies edits using its own tools, emits Tier 2 evidence with `LEAD_TEMPLATE_VERSION`, then jumps to Step 5 (promote) → Step 6 (followup gate) → Step 7 (cleanup). No team is created and no workers spawn.

### Step 1: Load work item and validate

1. Parse arguments: extract work item name and optional `--model` flag (default: `opus`, accept `sonnet`)
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
   If the command fails, log `[implement] Warning: branch cache write failed` and continue — non-fatal.
7. **Load prior Tier 2 evidence** — read `$KDIR/_work/<slug>/task-claims.jsonl` if it exists. This is the canonical log of Tier 2 claims written by prior workers on this work item (via `evidence-append.sh`). Parse each line as JSON and build an in-memory map keyed by `task_id` and by files touched (from the row's `files` field if present, or fall back to the row's claim text). This map feeds Step 3's worker `{{prior_knowledge}}` injection — each worker receives only the Tier 2 rows whose `task_id` matches its assigned task or whose files overlap with the task's `**Files:**` block. If the file is absent or empty, skip silently (first `/implement` run on this item).
8. Present a brief summary and proceed immediately:
   ```
   [implement] <Title>
   Model: opus (override with --model sonnet)
   Phases: N with M unchecked tasks
   Prior Tier 2 claims: K rows loaded from task-claims.jsonl (or "none — first run")
   ```

### Step 2: Create team and generate tasks

**IMPORTANT: Create the team BEFORE creating tasks.** TaskCreate calls go into whichever task list is active. If you create tasks before TeamCreate, they land in the session's default list — invisible to workers who see the team's list. This produces orphaned stale tasks that persist for the rest of the session.

1. **Create team first:**
   ```
   TeamCreate: team_name="impl-<slug>", description="Implementing <work item title>"
   ```

   **`team_name` MUST be exactly `impl-<work-item-slug>`** — the slug suffix has to match the work item directory name in `$KDIR/_work/` byte-for-byte. The TaskCompleted hook (`scripts/task-completed-capture-check.sh`) derives the work-item slug by stripping the `impl-` prefix from `team_name`. The `lore work check` and Tier 2 evidence reads are all affected by the same convention. Use the exact slug.

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

   **Per-task descriptions are lean by design** — each description begins with a `**Phase:** N` line (the authoritative phase-number source per D6) followed only by the task-specific assignment (objective, files, scope). Phase-level context (Design Decisions, Verification, Strategy, Reference files, Knowledge backlinks) lives in `tasks.json → phases[N-1].phase_context` and is fetched lazily by the worker via `lore work phase-context <slug> <phase-number>` after `TaskGet`. The lead does NOT need to embed phase context into `TaskCreate` description fields.

   **Backward-compatibility:** legacy `tasks.json` files (generated before this change) do not carry a `phase_context` field. `lore work phase-context` exits 0 with empty stdout for those files; workers that receive empty output proceed using the inline phase context already present in their description (the old behavior). No regen is required before resuming implementation on a legacy work item.

6. **Build phase map** — after `lore work load-tasks` succeeds, read `tasks.json` directly to build an in-memory phase map indexed by 1-based phase number:
   ```bash
   python3 -c "
   import json, sys
   with open('$WORK_DIR/<slug>/tasks.json') as f:
       data = json.load(f)
   for p in data['phases']:
       print(p['phase_number'], json.dumps(p.get('retrieval_directive')))
   "
   ```
   Store the result as `$PHASE_MAP`: a mapping of `phase_number → {objective, files, retrieval_directive}`. This map is the authoritative source for per-phase retrieval directives consumed by Step 3.1.

   If `tasks.json` is missing (fallback path from Step 2.4), run this step after the fallback generation completes.

### Step 3.0: Lead-inline gate (pre-dispatch short-circuit)

Before spawning anything, evaluate whether the plan qualifies for **lead-inline execution**. Worker dispatch's value is parallelism across independent tasks plus discretion-bearing context for intent+constraints work; both vanish when the plan reduces to a single fully-determined edit. The ~22KB context tax per spawn plus TeamCreate + TaskCreate + completion round-trip is then pure overhead.

The gate fires when **all four** conditions hold:

1. **Single task** — `tasks.json` contains exactly one task across all phases (count unchecked `- [ ]` entries on `plan.md`'s `**Tasks:**` blocks; cross-check against `tasks.json` task array length).
2. **Prescriptive format** — the task's containing phase declares `**Task format:** prescriptive` in `plan.md`. Intent+constraints tasks involve worker discretion shaping the outcome; lead-inline removes that discretion channel and is unsafe for them.
3. **Small surface** — the task's `**Files:**` block lists ≤3 files.
4. **No advisor declaration** — no phase declares an `**Advisors:**` block, and `lore ceremony get implement` returns `[]`. Advisors are persistent team members tied to the team lifecycle; lead-inline has no team.

**If any condition fails:** skip Step 3.0 entirely and proceed to Step 3 (worker dispatch). Do not log a skip — the worker pipeline is the default.

**If all conditions hold:** apply edits inline.

1. **Log the gate firing** — append one line to `execution-log.md` so retro can attribute the route taken:
   ```bash
   printf 'Lead-inline execution: gate fired\nConditions: single task, prescriptive, %d files, no advisors\nTask: %s\n' \
     "<file-count>" "<task-subject>" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"
   ```

2. **Apply the edits directly** using the lead's `Read` / `Edit` / `Write` / `Bash` tools, honoring the phase's `**Verification:**` objectives implicitly. The task description still loads via `lore work load-tasks <slug>` — read it the same way a worker would, then execute the prescriptive instructions yourself.

3. **Emit Tier 2 evidence** for any falsifiable claims the edits depend on. Use `LEAD_TEMPLATE_VERSION` — the lead is the producer in this route:
   ```bash
   echo '<tier2-row-json>' \
     | bash ~/.lore/scripts/evidence-append.sh --work-item <slug>
   ```

4. **Stash any Tier 3 candidates** the lead notices for Step 5 promotion. Promotion still goes through `lore promote` with `--producer-role implement-lead --template-version "$LEAD_TEMPLATE_VERSION"`.

5. **Mark the task complete** on the plan checkbox:
   ```bash
   lore work check <slug> "<task-subject>"
   ```

6. **Skip Steps 3, 4, and Step 7's TeamDelete** — there is no team to shut down. Proceed directly to **Step 5 (Promote accepted Tier 3 candidates)**, then **Step 6 (Followup creation gate)**, then **Step 7 (Cleanup and report)** with `Tier 2 claims written: <count>` reflecting the lead's emissions.

**Sanctioned pause:** if the lead is unsure whether the prescriptive task is fully determined enough to execute without discretion, fall through to Step 3 worker dispatch. Lead-inline is a short-circuit, not a forced route.

### Step 3: Spawn agents

**You MUST spawn workers immediately after Step 3.6 completes.** Do not pause to confirm scope. Do not echo plan-resolved open questions back to the user (the plan already encodes scope guards in task descriptions). Do not surface "this is large" or "this will take many rounds" as a decision request. Do not request approval to modify a skill because the skill being modified is the running skill (your prompt is loaded; file edits do not affect the current run). The only sanctioned pre-dispatch pauses are: (a) the work item resolved to an `[archived]` item without explicit confirmation (Step 1.2), (b) `tasks.json` checksum mismatch (Step 2.3), (c) `~/.claude/agents/worker.md` is missing (Step 1, MANDATORY clause), or (d) the Step 3.0 Lead-inline gate fired and execution already completed inline (skip Step 3 entirely). Pausing for any other reason is a faster-path bypass — the cost is borne by the user as session-spanning delay; the lead pays nothing. **Why immediate dispatch matters:** one bad spawn is caught in Step 4 review; pre-dispatch confirmation does not buy safety the system already provides.

1. **Pre-fetch knowledge for worker prompts** — build `$PRIOR_KNOWLEDGE` by iterating over each phase in `$PHASE_MAP`. For every phase, apply the three-branch gate in priority order:

   **(a) Directive branch — retrieval_directive is non-null for this phase:**
   Resolve the directive via `resolve-manifest.sh` before spawning any workers:
   ```bash
   PHASE_PK=$(bash ~/.lore/scripts/resolve-manifest.sh "<slug>" "<phase_number>" 2>/dev/null || true)
   ```
   Append non-empty output under a `### Phase N: <phase_name>` heading into `$PRIOR_KNOWLEDGE`. A retrieval directive is authoritative over the other branches for its phase — do not also run prefetch or skip-check for that phase.

   **Sectioned output for v2 directives.** When the phase's directive is `version: 2` (per-topic decomposition — see `/spec` Step 5b), `resolve-manifest.sh` emits a multi-section block under the phase heading: one `### Focal: <topic>` section followed by zero or more `### Adjacent: <topic>` sections. Each section is independently top-K-bounded (focal=8, adjacent=4 default; D3 budget) and dedup'd by file_path with focal precedence. The dispatcher passes this resolved block through to workers verbatim — no per-section re-ranking, no merge into a single ranking. Activity-vocab hits (when the focal topic carries `activity_vocab`) appear *inside* the focal section's served entries (no separate `### Activity:` section); the second BM25 OR query is logged as `query_kind=activity` for telemetry.
   
   **Legacy flat directives** (no `version` field, single `scale_set`, single seed list) continue to resolve to a single-section block at the declared scale via the same `resolve-manifest.sh` call — the dispatcher does not need to branch on directive shape. Notational change only at this step; the script handles the shape.

   **(b) Task-description branch — no directive, but task descriptions contain `## Prior Knowledge`:**
   **Skip prefetch for this phase.** The phase already embeds resolved knowledge from annotation. Appending would duplicate or conflict.

   **(c) Fallback branch — no directive AND no `## Prior Knowledge` in task descriptions:**
   Run complementary prefetch using the phase's file paths and objective:
   ```bash
   PHASE_PK=$(lore prefetch "<phase objective> <file paths from task>" --format prompt --limit 3 --scale-set=<bucket>)
   ```
   Append non-empty output under a `### Phase N: <phase_name>` heading into `$PRIOR_KNOWLEDGE`.

   **Concatenation rule:** accumulate the per-phase outputs (heading + content) into a single `$PRIOR_KNOWLEDGE` string separated by blank lines. Phases that produce no output (branch b skip, or branch a/c with zero results) contribute no heading. The final `$PRIOR_KNOWLEDGE` is injected into the `{{prior_knowledge}}` slot in `agents/worker.md` at spawn time (Step 3.6). Do not inject a partial-phase bundle — resolve all phases before spawning any worker. For v2 directives, the injected block is the multi-section shape (`### Focal:` / `### Adjacent:`) described above; workers consume it as candidates-to-curate per `agents/worker.md`'s `## Knowledge Context` directive, not as authoritative pre-resolved context.

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
      Use `on-demand` mode for late-declared advisors.

   d. **If no `**Related skills:**` block exists** or all matched skills are already declared, skip silently.

   e. **If new advisors were declared**, re-collect all advisor declarations and rebuild `$ADVISORY_MIXIN` before proceeding.

4. **Ceremony config injection** — read ceremony-level advisor overrides and merge them into the advisor pipeline:

   a. **Read configured advisors:**
      ```bash
      lore ceremony get implement
      ```
      Returns a JSON array of skill names, or `[]` if none. **If `[]`, skip to Step 3.5.**

   b. **Declare config-injected advisors** — for each skill not already declared in a phase `**Advisors:**` block, add an entry to the first uncompleted phase:
      ```
      **Advisors:**
      - <skill-name>-advisor — <skill-name> domain (ceremony config). on-demand
      ```

   c. **Rebuild advisory mixin** if any new advisors were declared.

   d. **Log config-injected advisors** — for each advisor added from ceremony config:
      ```bash
      printf 'Config-injected advisor: %s\nSource: ceremony config\nMode: on-demand\n' \
        "<skill-name>-advisor" \
        | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"
      ```

5. **Spawn advisor agents (if advisors present)** — for each unique advisor name collected from Steps 3.2a, 3.3c, and 3.4b:

   a. **Build domain context** — find the `## Investigations` section(s) in `plan.md` whose topic relates to the advisor's domain scope. Extract the relevant investigation entry (findings, verified assertions, key files, implications) and format it as the advisor's domain baseline.

   b. **Spawn the advisor** using the advisor agent definition at `~/.claude/agents/advisor.md` with these template injections:
      - `{{team_name}}` → `impl-<slug>`
      - `{{advisor_domain}}` → the advisor's domain scope
      - `{{domain_context}}` → the investigation excerpt from Step 3.5a
      - `{{template_version}}` → `$ADVISOR_TEMPLATE_VERSION`

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

   c. **Write execution log entries** — after all advisors are spawned, log each lifecycle event. Pass `--template-version "$ADVISOR_TEMPLATE_VERSION"` because the content logged is sourced from the advisor template:
      ```bash
      printf 'Advisor spawned: %s\nDomain: %s\nMode: %s\n' \
        "<advisor-name>" "<domain scope>" "<must-consult|on-demand>" \
        | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$ADVISOR_TEMPLATE_VERSION"
      ```

6. **Surface Tier 2 evidence per worker** — before spawning workers, assemble each worker's per-task Tier 2 extract from the map built in Step 1.7. For each assigned task, collect the matching rows (task_id or file overlap) and render them as a YAML block that will be appended to that worker's `{{prior_knowledge}}`:

   ```yaml
   Prior Tier 2 evidence (from task-claims.jsonl):
     - claim_id: <id>
       claim: <one-line claim text>
       task_id: <task-id>
       captured_at_sha: <sha>
   ```

   If no rows match, omit the block (do NOT emit an empty section).

7. **Spawn worker agents with tier-aware emission instructions** — launch `min(recommended_workers, 4)` workers in a single message. Use the worker agent definition at `~/.claude/agents/worker.md` as the base prompt, with these template injections:

   Workers declare `--scale-set` at every `lore prefetch` and `lore search` call. The rubric they apply:

   **Scale rubric — declare explicitly at every retrieval surface:**

   - **abstract** — portable principle, behavioral law, or design maxim. The claim survives generic-noun substitution: replace project-specific proper nouns with placeholders and the lesson still holds. Abstract entries make a *law*.
   - **architecture** — project-level structure: decomposition, lifecycle, contracts, data model, invariants, cross-component flows, or major platform choices. Architecture entries make a *map*: "A does B, C does D, and E connects them."
   - **subsystem** — local rule about one named area, feature, module, team, command family, integration, or workflow within a larger system. Concrete terms appear as participants in a local workflow rather than as the whole claim.
   - **implementation** — concrete artifact fact: file, function, script, command, limit, field, test, line-level behavior. If removing the artifact name destroys the claim, classify here.

   **Boundary tests:** abstract vs architecture — substitution test (does the claim survive replacing concrete proper nouns with generic placeholders, or does it become "A does B, C does D"?); architecture vs subsystem — whole-project structure or one bounded area?; subsystem vs implementation — can you state the rule without naming a specific function/file/line?

   **Multi-label encoding (retrieval implication):** entries may carry one label or an *adjacent* pair (`abstract,architecture`, `architecture,subsystem`, `subsystem,implementation`); a `--scale-set` query matches an entry if any requested label is in the entry's set. The full decision tree (four tier tests + substitution test + multi-label rules) lives in `~/.claude/agents/classifier.md`.

   **±1 query pattern:** fixing a bug → `subsystem,implementation`; adding to a module → `subsystem,implementation`; modifying a component → `architecture,subsystem`; designing a feature → `abstract,architecture`.

   - `{{team_name}}` → `impl-<slug>`
   - `{{team_lead}}` → the lead name read from team config in Step 2
   - `{{prior_knowledge}}` → the `$PRIOR_KNOWLEDGE` block from Step 3.1, followed by the per-worker Tier 2 evidence block from Step 3.6 (concatenated with a blank-line separator)
   - `{{template_version}}` → `$WORKER_TEMPLATE_VERSION`

   The worker template itself documents the tier-aware emission contract. In summary, workers are required to:

   - **During task:** write each structured Tier 2 claim by piping a JSON row through `echo '<json>' | bash ~/.lore/scripts/evidence-append.sh --work-item <slug>` before sending the completion report. One call per claim. `evidence-append.sh` is the sole-writer for `$KDIR/_work/<slug>/task-claims.jsonl`.
   - **Post task:** send a completion report to the lead that contains the traditional prose fields (**Task**, **Changes**, **Tests**, **Blockers**, **Surfaced concerns**, **Advisor consultations**), a new **Tier 2 evidence:** field listing the `claim_id` values written during the task, and an optional **Tier 3 candidates:** YAML block with one entry per reusable observation (producer_role + 13-field Tier 3 shape minus `confidence`).
   - **Naming standard:** the optional Tier 3 section MUST be labeled exactly **Tier 3 candidates:** — not "Tier 3 claims" or "Tier 3 observations". The TaskCompleted hook validates literal-prefix-match.

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

### Step 4: Collect progress

As worker messages arrive (delivered automatically):

1. **Verify Tier 2 evidence before accepting the task** — do NOT re-parse Tier 2 rows from the `SendMessage` body. Instead:

   a. Read the canonical `$KDIR/_work/<slug>/task-claims.jsonl` directly.

   b. Cross-reference against the worker's reported `Tier 2 evidence:` claim_id list. Every reported id MUST exist as a row in the file; any missing id means the worker misreported, and the task is rejected back to the worker for correction.

   c. Rows in the file have already been validated by `evidence-append.sh` against the Tier 2 schema — no additional per-row validation is performed at this step.

2. **Write execution log entry** — immediately after task acceptance, append to `execution-log.md`. Pass `--template-version "$WORKER_TEMPLATE_VERSION"` because the body logged is the worker's report:
   ```bash
   printf 'Task: %s\nChanges: %s\nSkills: %s\nTier2-claims: %s\nObservations: %s\nInvestigation: %s\nBlockers: %s\nAdvisor input: %s\nTest result: %s\n' \
     "<task-subject>" "<worker Changes field>" "<worker Skills used field>" \
     "<comma-separated claim_ids from Tier 2 evidence>" \
     "<worker Observations field or Tier 3 candidates summary>" \
     "<worker Investigation field>" "<worker Blockers field>" "<worker Advisor input field>" \
     "<passed|failed|skipped>" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$WORKER_TEMPLATE_VERSION"
   ```
   If the worker omitted a field, use `None`. `execution-log.md` is created on first write.

3. **Advisor-impact rollup** — if the worker's report includes a non-empty `Advisor consultations:` field, invoke the scorecard rollup immediately:
   ```bash
   bash ~/.lore/scripts/advisor-impact-rollup.sh \
     --work-item <slug> \
     --task-id <task-id> \
     --consultations "<Advisor consultations field verbatim>" \
     --template-version "$ADVISOR_TEMPLATE_VERSION"
   ```
   This emits `consultation_rate` and `advice_followed_rate` scorecard rows attributed to `template_id=advisor`. Skip the call when `Advisor consultations:` is empty or `none`.

4. **Set aside Tier 3 candidates for Step 5** — if the worker report contains a `Tier 3 candidates:` YAML block, stash each entry (preserving producer_role and source_artifact_ids) for Step 5 promotion. Do NOT promote here — Step 5 is the sole promotion site.

5. **Handle blockers** — if a worker reports blockers:
   - Read the relevant code/context
   - Send guidance via `SendMessage` to the blocked worker
   - If unresolvable, note in `notes.md` and move on

6. **Check off completed items in plan.md** (best-effort):
   ```bash
   lore work check <slug> "<task-subject>"
   ```
   If this fails or is missed, Step 7 reconciles from the task system.

Do NOT gate on reviewing diffs — workers proceed autonomously. The user reviews at the end.

When a batch of workers has all reported completion:

1. Call `TaskList` to count remaining tasks with status `pending` and no `blockedBy` dependencies (unblocked tasks).
2. **If unblocked tasks remain:** spawn `min(unblocked_count, max_workers)` fresh workers (same worker template and injections as Step 3.7, incrementing worker names as `worker-N`). Rebuild each worker's per-task Tier 2 extract from the latest `task-claims.jsonl` — prior batches may have added new rows. Continue collecting from the new batch.
   - `max_workers` is the same cap used in Step 3.7: `min(recommended_workers, 4)`.
   - Repeat until no unblocked tasks remain.
3. **If no unblocked tasks remain** (all tasks are complete or all remaining are blocked):
   a. Send `shutdown_request` to all active workers and all advisor agents (if any were spawned in Step 3.5).
   b. **Write advisor shutdown log entries** — for each advisor that was spawned, log the shutdown:
      ```bash
      printf 'Advisor shutdown: %s\nDomain: %s\n' \
        "<advisor-name>" "<domain scope>" \
        | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$ADVISOR_TEMPLATE_VERSION"
      ```
   c. Run `TeamDelete`.

### Step 5: Promote accepted Tier 3 candidates

Step 5 is the sole Tier 3 promotion site for `/implement`. Do NOT delegate to `/remember`. Do NOT call `lore capture` directly for work-item-scoped observations — `lore promote` is the canonical path because it forces `confidence=unaudited` and enforces Tier 3 schema via `validate-tier3.sh` before writing.

Inputs: the Tier 3 candidate list stashed in Step 4.4, plus any lead-originated cross-task candidates the lead produces by reading the complete `execution-log.md` after the last batch.

**Empty input is a valid input — Step 5 always runs through to the sub-step 4 summary log.** The terminal state when no candidates were stashed is `Tier 3 promotion summary: 0 accepted, 0 rejected` written to `execution-log.md`; that log line is the committed reasoning a later auditor reads. Skipping Step 5 on the rationalization "no candidates → no-op → nothing to do" is the bypass shape named in the commitment protocol — the commitment is to evaluate and emit the summary, not to produce non-zero promotions.

For each accepted Tier 3 candidate, emit one `lore promote` call. Multi-producer synthesis is NEVER merged — one call per distinct producer so that scorecard rows retain the role × template attribution.

1. **Source-artifact verification (reject candidates with missing or stale source_artifact_ids).** Before promotion, read `$KDIR/_work/<slug>/task-claims.jsonl` and confirm that EVERY id listed in the candidate's `source_artifact_ids` array exists as a `claim_id` of some row in that file. Scope is this work item only — cross-work-item references are always rejected. Candidates referencing missing or stale ids are rejected (not promoted). Note each rejection in `execution-log.md`:
   ```bash
   printf 'Rejected Tier 3 candidate: %s\nReason: source_artifact_ids refer to missing claim_ids: %s\n' \
     "<candidate-summary>" "<missing-ids>" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"
   ```

2. **Attribution rule (producer_role → template-version mapping).** Pick the `--template-version` based on the candidate's `producer_role` field so that commons-side scorecard rollups attribute to the correct producing template:
   - `producer_role: worker` → `--template-version "$WORKER_TEMPLATE_VERSION"`
   - `producer_role: advisor` → `--template-version "$ADVISOR_TEMPLATE_VERSION"`
   - `producer_role: implement-lead` → `--template-version "$LEAD_TEMPLATE_VERSION"`

   If `producer_role` is absent from the candidate, default to `implement-lead` and note the defaulting in the execution log.

3. **Invoke `lore promote` per candidate.** One call per accepted candidate; the row JSON is piped on stdin:
   ```bash
   echo '<tier3-row-json>' | lore promote \
     --work-item <slug> \
     --source-artifact-ids "<comma-separated tier2-claim-ids>" \
     --producer-role "<worker|advisor|implement-lead>" \
     --template-version "<TV-per-attribution-rule>"
   ```
   The script forces `confidence=unaudited`, validates via `validate-tier3.sh`, and delegates the actual commons write to `capture.sh`. A non-zero exit means the row was rejected — log the failure and move on to the next candidate.

4. **Log promotion summary to execution-log.md** after the batch completes:
   ```bash
   printf 'Tier 3 promotion summary: %d accepted, %d rejected\nAccepted ids: %s\nRejected reasons: %s\n' \
     "$ACCEPTED" "$REJECTED" "<accepted-claim-id-list>" "<rejection-reasons>" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"
   ```

### Step 6: Followup Creation Gate

Check for incomplete tasks or explicit blockers. Skip silently if everything completed cleanly.

**Signal detection** — check two sources:

1. **Incomplete tasks** — call `TaskList`. Flag if any tasks remain with status `pending` or `in_progress`.
2. **Explicit blockers** — read `execution-log.md` for worker report entries where `Blockers:` contains any text other than `none` (case-insensitive).

**If no signals found:** skip to Step 7.

**If signals found:** create a followup:

```bash
bash ~/.lore/scripts/create-followup.sh \
  --title "Deferred work: <work item title>" \
  --source "implement" \
  --attachments '[{"type":"work_item","slug":"<slug>"}]' \
  --suggested-actions '[{"type":"create_work_item"}]' \
  --content "<one-line summary of what didn't finish and why, followed by a checklist of remaining items>"
```

**Lazy audit note:** per §9.2 Step 8, the Stop hook lazily triggers audit of this session's promotions; `/implement` does not invoke the audit explicitly here. Completion of `/implement` is non-blocking — the audit runs opportunistically after session end.

### Step 7: Cleanup and report

1. **Append a session entry to `notes.md`:**
   ```markdown
   ## YYYY-MM-DDTHH:MM
   **Focus:** Implementation via /implement
   **Progress:** Completed N/M tasks across K phases
   **Tier 2 claims:** <count> written; **Tier 3 promoted:** <count> accepted, <count> rejected
   **Next:** <remaining tasks if partial, or "Implementation complete">
   ```

2. **Reconcile plan.md from task system** — the task system is the source of truth for completion:
   ```bash
   lore work check <slug> "<task-subject>"
   ```
   Run for every completed task whose checkbox is still unchecked.

3. **Archival decision** — based on the task system, not plan.md:
   - **All tasks completed:** `lore work archive "<slug>"`
   - **Some tasks incomplete or blocked:** leave the work item active for later `/implement` resumption

4. Run `lore work heal`.

5. **Optional `/pr-review` branch (per §9.2 Step 9, D7).** Query GitHub for a PR open against the current branch and route one of three ways:

   ```bash
   BRANCH=$(git rev-parse --abbrev-ref HEAD)
   PR_JSON=$(gh pr list --head "$BRANCH" --json number --limit 1 2>&1)
   PR_EXIT=$?
   ```

   - **PR exists** (`$PR_EXIT` is 0 AND `$PR_JSON` is a non-empty array, e.g. `[{"number":123}]`): extract the PR number and invoke `/pr-review` via the Skill tool. After invocation, report one line to the user: `[implement] Optional /pr-review invoked for PR #<num>`.
   - **No PR** (`$PR_EXIT` is 0 AND `$PR_JSON` is `[]`): skip silently. Do NOT write an execution-log entry. Do NOT write to `notes.md`.
   - **`gh` unavailable or errored** (`$PR_EXIT` is non-zero): skip the gate and append exactly one line to `$KDIR/_work/<slug>/notes.md`:
     ```
     - pr-review skipped: gh pr list failed (<exit-code>: <first 80 chars of stderr>)
     ```
     Do NOT write to `execution-log.md` — that file is reserved for task events, not environment skips.

   The gate is optional by design: any of the three outcomes lets Step 7 continue. `/pr-review` is purely diagnostic and never blocks `/implement` completion.

6. **Retro-prep bundle (per §9.2 Step 10, D8).** Write a snapshot of this run's producer facts to `$KDIR/_work/<slug>/retro-bundle.json` so `/retro` has a single, stable input artifact. One write per `/implement` run; overwrite on re-run (snapshot semantics — not append, not merge). `/implement` is the sole writer; `/retro` is a read-only consumer.

   The bundle has exactly these nine required fields:

   | Field | Type | Source |
   |---|---|---|
   | `work_item` | string | `<slug>` |
   | `tasks_completed` | integer | count of tasks in `TaskList` with `status: "completed"` for this work item |
   | `tier2_claim_ids` | array of strings | every `claim_id` in `$KDIR/_work/<slug>/task-claims.jsonl` produced this run |
   | `tier3_promoted_ids` | array of strings | commons entry ids emitted by the `lore promote` calls in Step 5 (accepted only; rejects excluded) |
   | `advisor_consultations_count` | integer | total `Advisor consultations:` entries counted across this run's `execution-log.md` worker-report bodies |
   | `blockers` | array of strings | verbatim `Blockers:` text from worker reports where the value was anything other than `none` (case-insensitive) |
   | `template_versions` | object `{lead, worker, advisor}` | `$LEAD_TEMPLATE_VERSION`, `$WORKER_TEMPLATE_VERSION`, `$ADVISOR_TEMPLATE_VERSION` from the "Resolve Template Versions" preamble |
   | `captured_at_sha` | string | `git rev-parse HEAD` at emission time |
   | `run_started_at` | string | ISO-8601 timestamp captured at Step 1 and carried through the run |

   Write the file with:
   ```bash
   python3 -c 'import json, sys; json.dump(<fields>, sys.stdout, indent=2)' \
     > "$KDIR/_work/<slug>/retro-bundle.json"
   ```

   **Scope:** producer-only. This rewrite ships the emitter; it does NOT ship a schema validator. `/retro` treats the bundle as a convenience summary — the canonical artifacts (`task-claims.jsonl`, `observations.jsonl`, `execution-log.md`, `notes.md`) remain the historical truth. If `retro-bundle.json` is missing or malformed, `/retro` falls back to the canonical artifacts rather than failing.

   **Overwrite semantics:** on re-run of `/implement` against the same work item, replace the file unconditionally. No append, no merge, no rotation — each run reflects only that run's producer facts. The canonical log files already carry historical data.

7. **Report to user:**
   ```
   [implement] Done.
   Completed: N/M tasks
   Tier 2 claims written: <count>
   Tier 3 promoted: <count> (rejected: <count>)
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
- Step 1.7 re-reads `task-claims.jsonl` so resumed workers still see prior Tier 2 evidence
- Report: "Resuming — N remaining tasks across M phases"
