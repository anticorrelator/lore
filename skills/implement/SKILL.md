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

Executes a work item's `plan.md` with a team of knowledge-aware agents. Agents produce Tier 2 task evidence during work and optionally surface Tier 3 candidates for commons promotion. The lead verifies, promotes accepted candidates via `lore promote`, and writes a retro-prep bundle for the next-step `/retro` ceremony.

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

### Step 1: Load work item and validate

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
   If the command fails, log `[implement] Warning: branch cache write failed` and continue — non-fatal.
7. **Load prior Tier 2 evidence** — read `$KDIR/_work/<slug>/task-claims.jsonl` if it exists. This is the canonical log of Tier 2 claims written by prior workers on this work item (via `evidence-append.sh`). Parse each line as JSON and build an in-memory map keyed by `task_id` and by files touched (from the row's `files` field if present, or fall back to the row's claim text). This map feeds Step 3's worker `{{prior_knowledge}}` injection — each worker receives only the Tier 2 rows whose `task_id` matches its assigned task or whose files overlap with the task's `**Files:**` block. If the file is absent or empty, skip silently (first `/implement` run on this item).
8. Present a brief summary and proceed immediately:
   ```
   [implement] <Title>
   Model: sonnet (override with --model opus)
   Phases: N with M unchecked tasks
   Prior Tier 2 claims: K rows loaded from task-claims.jsonl (or "none — first run")
   ```

### Step 2: Create team and generate tasks

**IMPORTANT: Create the team BEFORE creating tasks.** TaskCreate calls go into whichever task list is active. If you create tasks before TeamCreate, they land in the session's default list — invisible to workers who see the team's list. This produces orphaned stale tasks that persist for the rest of the session.

1. **Create team first:**
   ```
   TeamCreate: team_name="impl-<slug>", description="Implementing <work item title>"
   ```

   **`team_name` MUST be exactly `impl-<work-item-slug>`** — the slug suffix has to match the work item directory name in `$KDIR/_work/` byte-for-byte. The TaskCompleted hook (`scripts/task-completed-capture-check.sh`) and the W06 fidelity validator (`scripts/validate-fidelity-artifact.sh`) both derive the work-item slug by stripping the `impl-` prefix from `team_name`. If `team_name` is shortened or aliased (e.g., `impl-06-worker-fidelity` for a work item named `06-worker-output-fidelity-attestation`), the validator looks up `$KDIR/_work/06-worker-fidelity/_fidelity/<key>.json` instead of the real path and silently fails to find the fidelity artifact. The `lore work check`, Tier 2 evidence reads, and W06 fidelity gate are all affected by the same convention. Use the exact slug.

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

### Step 3: Spawn agents

**All tasks are executed by fresh worker agents.** The lead does not implement tasks directly — even if the task seems small or the lead already has relevant context. Fresh agents with injected knowledge context produce cleaner results than the lead's accumulated orchestration context.

1. **Pre-fetch knowledge for worker prompts** — build `$PRIOR_KNOWLEDGE` by iterating over each phase in `$PHASE_MAP`. For every phase, apply the three-branch gate in priority order:

   **(a) Directive branch — retrieval_directive is non-null for this phase:**
   Resolve the directive via `resolve-manifest.sh` before spawning any workers:
   ```bash
   PHASE_PK=$(bash ~/.lore/scripts/resolve-manifest.sh "<slug>" "<phase_number>" 2>/dev/null || true)
   ```
   Append non-empty output under a `### Phase N: <phase_name>` heading into `$PRIOR_KNOWLEDGE`. A retrieval directive is authoritative over the other branches for its phase — do not also run prefetch or skip-check for that phase.

   **(b) Task-description branch — no directive, but task descriptions contain `## Prior Knowledge`:**
   **Skip prefetch for this phase.** The phase already embeds resolved knowledge from annotation. Appending would duplicate or conflict.

   **(c) Fallback branch — no directive AND no `## Prior Knowledge` in task descriptions:**
   Run complementary prefetch using the phase's file paths and objective:
   ```bash
   PHASE_PK=$(lore prefetch "<phase objective> <file paths from task>" --format prompt --limit 3 --scale-context worker)
   ```
   Append non-empty output under a `### Phase N: <phase_name>` heading into `$PRIOR_KNOWLEDGE`.

   **Concatenation rule:** accumulate the per-phase outputs (heading + content) into a single `$PRIOR_KNOWLEDGE` string separated by blank lines. Phases that produce no output (branch b skip, or branch a/c with zero results) contribute no heading. The final `$PRIOR_KNOWLEDGE` is injected into the `{{prior_knowledge}}` slot in `agents/worker.md` at spawn time (Step 3.6). Do not inject a partial-phase bundle — resolve all phases before spawning any worker.

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

3. **Fidelity gate — sampling decision** (W06 Phase 3).
   <!-- W06_FIDELITY_STEP4_INTEGRATED -->

   Every worker task must produce a fidelity artifact at `$KDIR/_work/<slug>/_fidelity/<artifact_key>.json` before the worker is allowed to mark the task `status=completed` (the worker's Step 7.5 ack-wait blocks until the lead writes the artifact and replies `fidelity: ack`). The artifact is one of two `kind`s defined by `scripts/schemas/fidelity.json`:

   - `kind: "verdict"` — written by the fidelity-judge agent (spawned by substep 3.b for sampled tasks; substep 3.b ships the spawn flow in task #9, four-branch handling lands in task #10, override-budget tracking lands in task #11)
   - `kind: "exempt"` — written directly by the lead for unsampled tasks (substep 3.c below)

   `artifact_key = sha256(slug + ':' + task_subject)[:12]` — must match the derivation in `scripts/validate-fidelity-artifact.sh` (Phase 2). The shared extraction rule for `task_subject`: take the first non-empty line of the task description after trimming whitespace, strip a leading `- [ ]` / `- [x]` checkbox marker if present, collapse internal whitespace runs to a single space, and leave punctuation/case unchanged.

   **3.a. Evaluate sampling triggers (D7).** A task is **mandatorily sampled** if ANY of the five triggers below fires; otherwise it falls back to **p=0.2 random sampling**:

   1. **`mandatory:phase_deliverable`** — the task is the last task in its phase OR the task's `**Files:**` block in plan.md lists production files referenced by multiple tasks in the same phase (i.e., the task touches a phase-shared deliverable).
   2. **`mandatory:architectural`** — any of the task's files appears in the architectural/shared-code list at `_work/06-worker-output-fidelity-attestation/_research/shared-code-paths.md` (authoritative source — do NOT inline that list here; re-read it on each evaluation so updates by future curation propagate immediately).
   3. **`mandatory:retried`** — the task's retry count is ≥2 (worker has been respawned at least twice on the same task; tracked in the task system).
   4. **`mandatory:risk_keyword`** — `grep -F` the worker's execution-log entry text for ANY of the literal phrases: `"I also"`, `"instead of"`, `"refactored"`, `"simplified"`, `"changed approach"`, `"took a different"`, `"didn't end up"`, `"ended up"`. Any match fires the trigger. Phrases are detected case-insensitively.
   5. **`mandatory:overlapping_file`** — any of the task's files intersects with the file set of a prior completed task in the same phase. Use `execution-log.md` to enumerate prior phase tasks and their file sets.

   If none of the five mandatory triggers fires, draw a uniform random value `r ∈ [0.0, 1.0]`; if `r < 0.20` the task is sampled with `trigger = "sampled:within_phase_random"`, otherwise it is unsampled (proceed to substep 3.c).

   **3.b. Sampled task — spawn fidelity-judge.** When sampling fires, pre-resolve the five judge inputs, spawn `agents/fidelity-judge.md` via `claude -p`, parse the returned JSON verdict, write it to `_fidelity/<artifact_key>.json`, and reply to the worker.

   **Step 1 — Pre-resolve the five core inputs (lead does this before spawn; the judge reads inputs only, does not fetch repo state):**

   1. `task_spec` — the full task description from `tasks.json` (includes phase objective, files, scope, task statement, design decisions, verification, Prior Knowledge block — verbatim as `/spec` rendered it).
   2. `worker_report` — the rendered execution-log entry written in substep 2 above (`Task:`/`Changes:`/`Tests:`/`Skills:`/`Tier2-claims:`/`Observations:`/`Investigation:`/`Blockers:`/`Advisor input:`/`Test result:`).
   3. `task_claims` — array of Tier-2 rows from `$KDIR/_work/<slug>/task-claims.jsonl` whose `claim_id` field appears in the worker's lead-verified `Tier 2 evidence:` list. Filter the file with `jq` against the verified id list — do NOT include unrelated rows from the same file.
   4. `diff` — `git diff -- <files>` output for the union of files named in the task's `**Files:**` block plus any additional files surfaced in the worker's `Changes:` field. Use `--no-color` and capture stdout. If the task touches no tracked files (rare; pure-config tasks), pass an empty string.
   5. `prior_knowledge` — the `## Prior Knowledge` block the worker received at spawn time. This is the same content the lead injected via `{{prior_knowledge}}` in Step 3.6 (Channel 1 from `tasks.json` task descriptions, or Channel 2 from `prefetch-knowledge.sh` / `resolve-manifest.sh` per Step 3.1's three-branch dispatch). Re-read from the task description if not retained from spawn.

   Wrap these into the JSON envelope the judge expects (see `agents/fidelity-judge.md` § Inputs for the full required-field list — `artifact_key`, `phase`, `worker_template_version`, `judge_template_version`, `trigger`, `task_spec`, `phase_objective`, `worker_report`, `task_claims`, `diff`, `prior_knowledge`):

   ```bash
   ARTIFACT_KEY=$(printf '%s' "<slug>:<task_subject>" | shasum -a 256 | cut -c1-12)
   JUDGE_TEMPLATE_VERSION=$(shasum -a 256 ~/.lore/agents/fidelity-judge.md | cut -c1-12)
   # WORKER_TEMPLATE_VERSION already in scope from Step 1 preamble.
   JUDGE_INPUT=$(jq -nc \
     --arg artifact_key "$ARTIFACT_KEY" \
     --arg phase "<phase-id from plan.md, e.g. phase-3>" \
     --arg wtv "$WORKER_TEMPLATE_VERSION" \
     --arg jtv "$JUDGE_TEMPLATE_VERSION" \
     --arg trigger "<sampling trigger from substep 3.a, e.g. mandatory:risk_keyword>" \
     --arg task_spec "<full task description>" \
     --arg phase_objective "<phase objective from plan.md>" \
     --arg worker_report "<rendered execution-log entry from substep 2>" \
     --argjson task_claims "$(jq -c --argjson ids '<JSON array of verified claim_ids>' '. as $row | $ids | index($row.claim_id) | if . then $row else empty end' "$KDIR/_work/<slug>/task-claims.jsonl" | jq -s .)" \
     --arg diff "$(git diff --no-color -- <files>)" \
     --arg prior_knowledge "<Prior Knowledge block worker saw>" \
     '{artifact_key: $artifact_key, phase: $phase, worker_template_version: $wtv, judge_template_version: $jtv, trigger: $trigger, task_spec: $task_spec, phase_objective: $phase_objective, worker_report: $worker_report, task_claims: $task_claims, diff: $diff, prior_knowledge: $prior_knowledge}')
   ```

   **Step 2 — Spawn the judge via `claude -p`:**

   ```bash
   FIDELITY_DIR="$KDIR/_work/<slug>/_fidelity"
   mkdir -p "$FIDELITY_DIR"
   RAW_OUT="$FIDELITY_DIR/$ARTIFACT_KEY.raw"
   claude -p "Resolved-input JSON follows. Emit exactly one JSON verdict object per the Output Shape contract. No markdown, no commentary, just the JSON.

INPUT:
$JUDGE_INPUT" \
     --append-system-prompt "$(cat ~/.lore/agents/fidelity-judge.md)" \
     --output-format text \
     --max-turns 1 \
     > "$RAW_OUT" 2>&1
   ```

   Use `--output-format text` (not `--output-format json` — the latter wraps the response in a session envelope). The judge emits a bare JSON object on stdout per its Output Shape contract; the harness pattern in `_work/06-worker-output-fidelity-attestation/_eval/run-eval.sh` is the reference implementation, including the brace-counted greedy JSON extraction that tolerates judges who emit a JSON object inside Markdown commentary. Per D11, do NOT call `scripts/audit-artifact.sh` — fidelity-judge is orthogonal to the `lore audit` pipeline.

   **Step 3 — Extract and persist the verdict:**

   ```bash
   VERDICT_JSON=$(python3 - <<'PY' "$RAW_OUT"
   import json, re, sys
   txt = open(sys.argv[1]).read()
   txt = re.sub(r"^```(?:json)?\s*", "", txt.strip(), flags=re.MULTILINE)
   txt = re.sub(r"\s*```$", "", txt.strip(), flags=re.MULTILINE)
   depth = 0; start = -1; found = None
   for i, ch in enumerate(txt):
       if ch == "{":
           if depth == 0: start = i
           depth += 1
       elif ch == "}":
           depth -= 1
           if depth == 0 and start >= 0:
               try:
                   json.loads(txt[start:i+1]); found = txt[start:i+1]; break
               except Exception:
                   start = -1
   print(found if found else "")
   PY
   )
   if [[ -z "$VERDICT_JSON" ]]; then
     echo "[fidelity] judge returned no parseable JSON; raw at $RAW_OUT" >&2
     # Treat as transient infrastructure failure: send respawn so worker retries.
     # (Persistent failures should be reported to the user — do not silently skip.)
     SendMessage to=<worker> "fidelity: respawn: judge returned no parseable JSON; see $RAW_OUT"
     return
   fi
   printf '%s\n' "$VERDICT_JSON" > "$FIDELITY_DIR/$ARTIFACT_KEY.json"
   ```

   The verdict file is the canonical artifact the TaskCompleted hook (`scripts/validate-fidelity-artifact.sh`) will read. The `.raw` file is retained for post-mortem; do not delete it.

   **Step 3.5 — Capture scorecard rows.** Immediately after writing the verdict file (and after the respawn-merge from Step 6 on respawned verdicts), shell to `scripts/fidelity-verdict-capture.sh` to emit the four `kind: scored` scorecard rows (one per `fidelity_verdict_{aligned|drifted|contradicts|unjudgeable}` dimension, `value: 1.0` on the artifact's verdict dimension and `0.0` on the other three) attributed to the **worker** template per D12. The wrapper is the sole writer to `_scorecards/rows.jsonl` for this row family — do NOT append rows directly from SKILL.md.

   ```bash
   bash ~/.lore/scripts/fidelity-verdict-capture.sh \
     --work-slug <slug> \
     --artifact-key "$ARTIFACT_KEY" \
     < "$FIDELITY_DIR/$ARTIFACT_KEY.json"
   ```

   Invocation rules:

   - Run only on `kind: "verdict"` artifacts. Skip the call entirely when the artifact is `kind: "exempt"` (substep 3.c emits no scorecard rows; the wrapper would no-op anyway, but skipping avoids the fork).
   - Run before Step 4 (branch handler) so the scored rows are recorded regardless of which branch the lead/user takes — drifted that gets respawned still emits the drifted row at first judgment; the respawn writes a fresh row when its merged verdict is captured by re-running this Step 3.5 on the merged file.
   - `--work-slug` resolves to the active /implement work slug from the Step 1 preamble; `--artifact-key` is the same `$ARTIFACT_KEY` derived in substep 3.b Step 1. The artifact JSON is piped on stdin from the canonical verdict file.
   - The wrapper sets `template_id: "worker"`, `template_version` from the artifact's `worker_template_version`, `verdict_source: "fidelity-judge"`, `judge_template_version` from the artifact's `judge_template_version`, `granularity: "portfolio-level"`, `tier: "template"`, `calibration_state: "pre-calibration"`, and `source_artifact_ids: ["_work/<slug>/_fidelity/<artifact-key>.json", <evidence.claim_ids_used...>]`. The lead does not need to pass these — they come from the artifact. Per D8/D12, this attribution is load-bearing: judge quality is measured separately by Phase 5 fixtures, not by production drift distribution.
   - Failure handling: if the wrapper exits non-zero, the lead emits a stderr diagnostic `[fidelity] scorecard capture failed for $ARTIFACT_KEY (rc=$rc); see wrapper output` but continues to Step 4 — scorecard emission is best-effort observability and must not block worker acceptance. The wrapper is built to validate strictly against `scripts/schemas/fidelity.json` before append, so a non-zero exit indicates a malformed artifact (which is a Step 3 bug, not a wrapper bug).

   **Step 4 — Forced-branch verdict routing.** Read the `verdict` field and route per the D1 four-branch contract. The lead never silently accepts a non-aligned verdict — every blocking verdict (`drifted`, `contradicts`, `unjudgeable`) routes to one of three paths (respawn / amend / escalate) with a durable artifact justifying the choice. `aligned` is the only verdict that auto-accepts.

   ```bash
   VERDICT=$(jq -r '.verdict' "$FIDELITY_DIR/$ARTIFACT_KEY.json")
   AMEND_FILE="$KDIR/_work/<slug>/_amendments/$ARTIFACT_KEY.md"
   ESCALATE_FILE="$FIDELITY_DIR/$ARTIFACT_KEY.escalation.md"
   ```

   **4.a. `aligned` — accept the worker's output.** Reply `fidelity: ack` so the worker proceeds past Step 7.5. Then run `lore work check` (substep 7 below). No additional artifact is required.

   ```bash
   if [[ "$VERDICT" == "aligned" ]]; then
     SendMessage to=<worker> "fidelity: ack"
     # Continue to substep 4 (Advisor-impact rollup) — no further branch action.
   fi
   ```

   **4.b. `drifted` — present the user with three options and act on their choice.** The fidelity artifact's `correction` field carries the realigning instruction. Surface the verdict to the user (lead summarizes verdict + correction.summary in chat), then route on user choice:

   1. **Respawn-with-correction.** Send `fidelity: respawn: <correction.summary>` to the worker. The worker re-enters its Step 4 (read task description) with the correction text in scope, re-implements, and reports again. When the judge fires on the respawn, the new verdict file MUST populate `supersedes: [{timestamp: <prior verdict's timestamp>, verdict: "drifted"}]` and increment `respawn_count` (starts at 0; first respawn → 1). Reuse the same `artifact_key` — the verdict file at `_fidelity/$ARTIFACT_KEY.json` is overwritten, with the old verdict captured in `supersedes`.
   2. **Document override.** Lead writes `_amendments/<artifact-key>.md` containing the five required sections per D5: (i) quoted plan passage superseded, (ii) quoted diff/report evidence, (iii) new intended behavior, (iv) why override beats respawn, (v) affected downstream tasks. The current verdict file stays in place; the amendment file is what the hook reads to allow acceptance. Reply `fidelity: ack` to the worker after the amendment lands.
   3. **Escalate to user.** Lead writes `_fidelity/<artifact-key>.escalation.md` documenting the user's decision (or the fact that the user has not yet responded). The task is suspended in Step 7.5 ack-wait — DO NOT send `fidelity: ack` until the escalation resolves. Reply `fidelity: respawn: escalated — await further direction` if the user wants the worker to stop, or `fidelity: ack` once the escalation file documents user acceptance.

   **4.c. `contradicts` — present the user with three options.** Differs from `drifted` only in option (1):

   1'. **Respawn-after-restatement.** Because `contradicts` means the worker's diff directly violates an explicit requirement, restate the task spec FIRST: edit `plan.md` and/or `tasks.json` (the latter regenerated via `python3 scripts/generate-tasks.py --slug <slug>` if plan.md changed), then send `fidelity: respawn: <correction.summary> — task spec restated; re-read tasks.json` to the worker. The respawned worker reads the updated task description before re-implementing. As in 4.b.1, the respawn verdict populates `supersedes` and increments `respawn_count`.
   2'. **Document override.** Same as 4.b.2 — write `_amendments/<artifact-key>.md`. The amendment must explicitly cite the contradicted requirement and explain why the override is preferred over plan correction.
   3'. **Escalate to user.** Same as 4.b.3.

   **4.d. `unjudgeable` — block until spec is clarified or escalation resolves.** Per D5's branch-artifact contract, `_amendments/<artifact-key>.md` does NOT clear an `unjudgeable` verdict — amendment papers over the spec-quality problem `unjudgeable` is meant to surface. The two valid resolutions are:

   1. **Spec clarification + judge rerun.** Lead edits `plan.md` and/or `tasks.json` to add the missing scope, verification criteria, or design-decision boundaries. Sends `fidelity: respawn: spec clarified — re-read tasks.json` to the worker (worker re-implements against the clearer spec). The judge spawns again on the respawned worker's report; the new verdict overwrites the file with `supersedes: [{timestamp: <prior unjudgeable's timestamp>, verdict: "unjudgeable"}]` and `respawn_count` incremented. The fresh verdict must be one of `aligned | drifted | contradicts` — if it is again `unjudgeable`, the lead must escalate (Resolution 2) on this iteration. Two consecutive `unjudgeable` verdicts on the same artifact_key indicate a structural spec gap, not a judge calibration issue.
   2. **User escalation.** Lead writes `_fidelity/<artifact-key>.escalation.md` documenting the spec-quality issue and the user's decision (e.g., "scope is intentionally open-ended; accept worker's interpretation"). The escalation file is the only branch artifact that may satisfy `unjudgeable`. Reply `fidelity: ack` only after the escalation file documents user acceptance.

   ```bash
   case "$VERDICT" in
     aligned)
       SendMessage to=<worker> "fidelity: ack"
       ;;
     drifted)
       CORRECTION=$(jq -r '.correction.summary // "(no correction provided)"' "$FIDELITY_DIR/$ARTIFACT_KEY.json")
       # Surface to user; record their choice. The lead pseudocode below names the three branches:
       #   read user_choice in {respawn, amend, escalate}
       #   case $user_choice in
       #     respawn)  SendMessage to=<worker> "fidelity: respawn: $CORRECTION" ;;
       #     amend)    consult Override Budget Gate (Step 5 below) BEFORE writing the amendment;
       #               write_amendment_file "$AMEND_FILE"; SendMessage to=<worker> "fidelity: ack" ;;
       #     escalate) write_escalation_file "$ESCALATE_FILE"; SendMessage to=<worker> "fidelity: respawn: escalated — await further direction" ;;
       #   esac
       ;;
     contradicts)
       CORRECTION=$(jq -r '.correction.summary // "(no correction provided)"' "$FIDELITY_DIR/$ARTIFACT_KEY.json")
       # Same three branches as drifted, but option (1') first restates the spec via plan.md/tasks.json edit
       # and the worker re-reads the updated task description before re-implementing. The amend branch
       # MUST consult the Override Budget Gate (Step 5 below) before writing the amendment.
       ;;
     unjudgeable)
       UJ_REASON=$(jq -r '.unjudgeable_reason // "(no reason provided)"' "$FIDELITY_DIR/$ARTIFACT_KEY.json")
       MISSING=$(jq -r '(.missing_inputs // []) | join(",")' "$FIDELITY_DIR/$ARTIFACT_KEY.json")
       # Two valid resolutions:
       #   1. Spec clarification + respawn (lead edits plan.md/tasks.json, then SendMessage "fidelity: respawn: spec clarified ...")
       #   2. User escalation (write $ESCALATE_FILE, then SendMessage "fidelity: ack" only after user acceptance documented)
       # An _amendments/<artifact-key>.md alone does NOT satisfy unjudgeable per D5.
       ;;
     *)
       SendMessage to=<worker> "fidelity: respawn: unexpected verdict '$VERDICT' — see $FIDELITY_DIR/$ARTIFACT_KEY.raw"
       ;;
   esac
   ```

   **Step 5 — Override budget gate (D6, anti-rubber-stamping).** Before honoring the user's amend-branch choice (4.b.2 or 4.c.2), count the existing `_amendments/*.md` files attributed to the **current phase** and, on the third and subsequent override within that phase, require either a second-opinion judge spawn (Resolution A) or explicit user escalation (Resolution B) before writing the new amendment. Within a phase's first 2 overrides, the amendment proceeds without the gate; the cost is paid by D5's amendment-content requirement alone.

   **Phase attribution.** `_amendments/<artifact-key>.md` files do NOT carry phase metadata in their name. The lead derives the phase by looking up each `<artifact-key>` in the corresponding `_fidelity/<artifact-key>.json` verdict file's `phase` field — which the judge always echoes from the input envelope. Aggregate the count for the current phase only:

   ```bash
   AMENDMENTS_DIR="$KDIR/_work/<slug>/_amendments"
   CURRENT_PHASE="<phase identifier from plan.md, e.g. phase-3>"
   PHASE_OVERRIDE_COUNT=0
   if [[ -d "$AMENDMENTS_DIR" ]]; then
     for amend_file in "$AMENDMENTS_DIR"/*.md; do
       [[ -f "$amend_file" ]] || continue
       a_key=$(basename "$amend_file" .md)
       v_file="$FIDELITY_DIR/$a_key.json"
       [[ -f "$v_file" ]] || continue  # orphan amendment — skip and warn
       a_phase=$(jq -r '.phase // empty' "$v_file")
       if [[ "$a_phase" == "$CURRENT_PHASE" ]]; then
         PHASE_OVERRIDE_COUNT=$((PHASE_OVERRIDE_COUNT + 1))
       fi
     done
   fi
   ```

   **Threshold logic.**

   - `PHASE_OVERRIDE_COUNT` is the count of *prior* amendments in the current phase. If the lead is about to write the 3rd amendment, `PHASE_OVERRIDE_COUNT == 2` at the time of the check.
   - Gate trips when `PHASE_OVERRIDE_COUNT >= 2` (i.e., the amendment about to be written would be the 3rd or later). On any earlier amendment (`< 2`), proceed directly to write.

   **When the gate trips, exactly one of the following two resolutions must complete before `_amendments/<artifact-key>.md` is written:**

   **Resolution A — Second-opinion judge spawn.** Re-spawn `agents/fidelity-judge.md` against the same five inputs the first spawn received (same `task_spec`, `worker_report`, `task_claims`, `diff`, `prior_knowledge`), with the same `template_version` (do NOT switch judge versions for second-opinion — that defeats producer-judge independence by introducing a different prompt). The second-opinion verdict goes to a separate file `_fidelity/<artifact-key>.second-opinion.json` (NOT the canonical `_fidelity/<artifact-key>.json` — the first-opinion verdict remains the artifact-of-record). Then:

   - If the second-opinion verdict is also non-aligned (`drifted`, `contradicts`, or `unjudgeable`), the override does NOT proceed automatically — the lead must escalate (Resolution B) on this iteration.
   - If the second-opinion verdict flips to `aligned`, the lead may proceed with the amendment, citing the second-opinion file in the amendment's "why override beats respawn" section.

   ```bash
   if [[ "$PHASE_OVERRIDE_COUNT" -ge 2 ]]; then
     SECOND_OPINION_FILE="$FIDELITY_DIR/$ARTIFACT_KEY.second-opinion.json"
     # Re-spawn the judge with the same JUDGE_INPUT envelope from substep 3.b Step 1.
     # Use the same fidelity-judge template-version (same content hash); fresh claude session.
     claude -p "Resolved-input JSON follows. Emit exactly one JSON verdict object per the Output Shape contract.

INPUT:
$JUDGE_INPUT" \
       --append-system-prompt "$(cat ~/.lore/agents/fidelity-judge.md)" \
       --output-format text \
       --max-turns 1 \
       > "$SECOND_OPINION_FILE.raw" 2>&1
     # Re-use the same brace-counted greedy JSON extractor from substep 3.b Step 3.
     # Write the parsed verdict to "$SECOND_OPINION_FILE".
     SECOND_OPINION_VERDICT=$(jq -r '.verdict' "$SECOND_OPINION_FILE")
     if [[ "$SECOND_OPINION_VERDICT" != "aligned" ]]; then
       # Second opinion confirms non-alignment — gate forces Resolution B.
       echo "[fidelity] Override budget gate: 2 second-opinion still non-aligned; escalation required." >&2
       # Do NOT write _amendments/<artifact-key>.md. Surface to user; await escalation file.
     fi
   fi
   ```

   **Resolution B — Explicit user escalation.** The user explicitly confirms the override before acceptance. The lead writes `_fidelity/<artifact-key>.escalation.md` documenting (i) the verdict and the prior in-phase amendment count, (ii) the override-budget threshold trip, (iii) the user's explicit confirmation language. Only after this file lands does the lead write `_amendments/<artifact-key>.md` and reply `fidelity: ack`. The amendment file's "why override beats respawn" section MUST cite the escalation file path.

   The two resolutions are not interchangeable on the third+ override. If the user requests amendment without escalation, the lead must run Resolution A first; only when Resolution A returns `aligned` (or after the user explicitly invokes Resolution B) does the amendment proceed.

   **Sequencing.** The override-budget gate sits between the verdict branch handler (Step 4) and the Respawn-path verdict file invariant (Step 6 below). On the respawn branch (4.b.1, 4.c.1', 4.d.1) the gate does not apply — only the amend branch (4.b.2, 4.c.2) consults it.

   **Step 6 — Respawn-path verdict file invariant.** When a respawn produces a fresh verdict (any of 4.b.1, 4.c.1', 4.d.1), the new judge invocation in substep 3.b Step 2 MUST be parameterized so the resulting verdict carries:

   - `supersedes: [{timestamp: <prior verdict's timestamp>, verdict: <prior verdict's verdict value>}, ...]` — append, don't replace; preserve prior supersedes entries from earlier respawns on the same artifact_key.
   - `respawn_count: <prior count + 1>` — read the prior verdict file before overwriting, increment.

   The fidelity-judge agent itself does NOT set these fields (per its Output Shape "set by the orchestration layer"). The lead reads the prior verdict file before the respawn spawn, and after the new judge JSON returns, merges those two fields onto it before writing `_fidelity/$ARTIFACT_KEY.json`:

   ```bash
   PRIOR_FILE="$FIDELITY_DIR/$ARTIFACT_KEY.json"
   if [[ -f "$PRIOR_FILE" ]]; then
     PRIOR_TS=$(jq -r '.timestamp' "$PRIOR_FILE")
     PRIOR_V=$(jq -r '.verdict' "$PRIOR_FILE")
     PRIOR_SUPERSEDES=$(jq -c '.supersedes // []' "$PRIOR_FILE")
     PRIOR_COUNT=$(jq -r '.respawn_count // 0' "$PRIOR_FILE")
     # After judge emits NEW_VERDICT_JSON via Step 3 extraction:
     MERGED=$(jq --argjson sup "$PRIOR_SUPERSEDES" --arg pts "$PRIOR_TS" --arg pv "$PRIOR_V" --argjson pc "$PRIOR_COUNT" \
       '. + {supersedes: ($sup + [{timestamp: $pts, verdict: $pv}]), respawn_count: ($pc + 1)}' \
       <<< "$NEW_VERDICT_JSON")
     printf '%s\n' "$MERGED" > "$PRIOR_FILE"
   else
     printf '%s\n' "$NEW_VERDICT_JSON" > "$PRIOR_FILE"
   fi
   ```

   This merge step runs only on respawns; first-judgment writes (the common path) skip the merge and go directly to `printf '%s\n' "$VERDICT_JSON" > "$FIDELITY_DIR/$ARTIFACT_KEY.json"` per substep 3.b Step 3.

   Scorecard rows for this artifact have already been emitted by substep 3.b Step 3.5; do not append a second time from this respawn-merge step. When a respawn produces a fresh verdict, re-run Step 3.5 on the merged verdict file (NOT on the prior verdict file) so the scored row family reflects the latest verdict — the wrapper's append-only contract means the prior rows remain in `_scorecards/rows.jsonl` as historical record. Telemetry-row emission for the respawn outcome (event B in Step 7 below) fires after this merge step.

   **Step 7 — Telemetry emission (Phase 6 / D10 response observability).** Four branch-handler events emit `kind: telemetry` rows via `scripts/fidelity-verdict-capture.sh --telemetry` so `/retro` Step 3.6's "Fidelity Response Behavior" reader can render branch-choice distributions, respawn effectiveness, override-budget activations, and unjudgeable resolutions. Telemetry rows are observability-only — they do NOT feed `/evolve` (the wrapper sets `kind: telemetry` / `tier: telemetry`, both of which are filtered out by `/evolve`'s `kind == scored` predicate).

   Each emission uses the same wrapper invocation pattern (note: stdin is the JSON payload, NOT the verdict file):

   ```bash
   echo '<telemetry-payload-json>' | bash ~/.lore/scripts/fidelity-verdict-capture.sh --telemetry
   ```

   The payload schema (per the wrapper's documented telemetry-mode shape): `{metric, value, telemetry_label, source_artifact_ids, template_version}`. The lead reuses `$JUDGE_TEMPLATE_VERSION` (computed in substep 3.b Step 1) for the `template_version` field — telemetry rows are attributed to the fidelity-judge template. Emit one row per category in the family; the chosen category gets `value: 1.0`, the others `0.0`.

   **Event A — Branch choice on non-aligned verdict.** Fires at the end of substep 4.b, 4.c, or 4.d once the lead/user has picked a branch. Skip on aligned verdicts (no branch was chosen).

   - Family: `fidelity_branch_choice_respawn | fidelity_branch_choice_amend | fidelity_branch_choice_escalate | fidelity_branch_choice_clarify_rerun`
   - `telemetry_label` ∈ `{"respawn", "amend", "escalate", "clarify_rerun"}` matching the metric.
   - Map: 4.b.1 / 4.c.1' → `respawn`; 4.b.2 / 4.c.2 → `amend`; 4.b.3 / 4.c.3' → `escalate`; 4.d.1 (spec-clarify + respawn) → `clarify_rerun`; 4.d.2 (escalation only) → `escalate`.
   - `source_artifact_ids`: `["_work/<slug>/_fidelity/<artifact-key>.json"]` (single — the verdict file the branch was chosen against).

   ```bash
   for cat in respawn amend escalate clarify_rerun; do
     val=$(if [[ "$cat" == "$BRANCH_CHOICE" ]]; then echo "1.0"; else echo "0.0"; fi)
     jq -nc --arg metric "fidelity_branch_choice_$cat" --argjson value "$val" \
        --arg label "$cat" --arg artifact "_work/<slug>/_fidelity/$ARTIFACT_KEY.json" \
        --arg jtv "$JUDGE_TEMPLATE_VERSION" \
        '{metric: $metric, value: $value, telemetry_label: $label, source_artifact_ids: [$artifact], template_version: $jtv}' \
       | bash ~/.lore/scripts/fidelity-verdict-capture.sh --telemetry
   done
   ```

   **Event B — Respawn outcome.** Fires after Step 6 produces a merged respawn verdict (i.e., after a respawn from 4.b.1, 4.c.1', or 4.d.1). The lead reads the merged verdict's `verdict` field to classify the outcome:

   - Family: `fidelity_respawn_outcome_resolved_aligned | fidelity_respawn_outcome_persistent_drift | fidelity_respawn_outcome_respawn_failed`
   - Outcome map: merged verdict `aligned` → `resolved_aligned`; merged verdict `drifted | contradicts | unjudgeable` → `persistent_drift`; respawn never produced a parseable verdict (Step 3 extraction failure on the second pass) → `respawn_failed`.
   - `source_artifact_ids`: `[<first verdict path>, <follow-up verdict path>]` — both reference the same `_fidelity/<artifact-key>.json` file by path because the merge overwrites in place; the lead may include the `.raw` file of the latest invocation as a second entry to disambiguate (e.g., `["_work/<slug>/_fidelity/<key>.json", "_work/<slug>/_fidelity/<key>.raw"]`).

   ```bash
   case "$MERGED_VERDICT" in
     aligned)                outcome="resolved_aligned" ;;
     drifted|contradicts|unjudgeable)  outcome="persistent_drift" ;;
     *)                      outcome="respawn_failed" ;;
   esac
   for cat in resolved_aligned persistent_drift respawn_failed; do
     val=$(if [[ "$cat" == "$outcome" ]]; then echo "1.0"; else echo "0.0"; fi)
     jq -nc --arg metric "fidelity_respawn_outcome_$cat" --argjson value "$val" \
        --arg label "$cat" --arg jtv "$JUDGE_TEMPLATE_VERSION" \
        --arg artifact "_work/<slug>/_fidelity/$ARTIFACT_KEY.json" \
        --arg raw "_work/<slug>/_fidelity/$ARTIFACT_KEY.raw" \
        '{metric: $metric, value: $value, telemetry_label: $label, source_artifact_ids: [$artifact, $raw], template_version: $jtv}' \
       | bash ~/.lore/scripts/fidelity-verdict-capture.sh --telemetry
   done
   ```

   **Event C — Override budget threshold trip.** Fires inside Step 5 when `PHASE_OVERRIDE_COUNT >= 2` AND a resolution path is taken (Resolution A or Resolution B). Skip when the override count is below threshold (no telemetry signal needed).

   - Family: `fidelity_override_count_second_opinion | fidelity_override_count_user_escalation`
   - Resolution map: Resolution A (second-opinion judge spawn) → `second_opinion`; Resolution B (user escalation) → `user_escalation`. If Resolution A returned non-aligned and forced Resolution B, emit BOTH — first second_opinion=1.0/user_escalation=0.0 (recording the second-opinion attempt), then second_opinion=0.0/user_escalation=1.0 (recording the eventual escalation).
   - `source_artifact_ids`: array of all `_amendments/*.md` paths in the current phase that contributed to the gate trip — built by re-running the phase-attribution loop from Step 5 and collecting the matching `$amend_file` paths.

   ```bash
   PHASE_AMEND_PATHS=()
   for amend_file in "$AMENDMENTS_DIR"/*.md; do
     [[ -f "$amend_file" ]] || continue
     a_key=$(basename "$amend_file" .md)
     v_file="$FIDELITY_DIR/$a_key.json"
     [[ -f "$v_file" ]] || continue
     a_phase=$(jq -r '.phase // empty' "$v_file")
     [[ "$a_phase" == "$CURRENT_PHASE" ]] && PHASE_AMEND_PATHS+=("$amend_file")
   done
   AMEND_PATHS_JSON=$(printf '%s\n' "${PHASE_AMEND_PATHS[@]}" | jq -R . | jq -sc .)
   for cat in second_opinion user_escalation; do
     val=$(if [[ "$cat" == "$RESOLUTION_TAKEN" ]]; then echo "1.0"; else echo "0.0"; fi)
     jq -nc --arg metric "fidelity_override_count_$cat" --argjson value "$val" \
        --arg label "$cat" --argjson sources "$AMEND_PATHS_JSON" \
        --arg jtv "$JUDGE_TEMPLATE_VERSION" \
        '{metric: $metric, value: $value, telemetry_label: $label, source_artifact_ids: $sources, template_version: $jtv}' \
       | bash ~/.lore/scripts/fidelity-verdict-capture.sh --telemetry
   done
   ```

   **Event D — Unjudgeable resolution.** Fires after substep 4.d completes — either when a clarify-rerun respawn produces a merged non-unjudgeable verdict, or when an escalation file is written and the user accepts. Skip when the unjudgeable verdict is still active (no resolution yet).

   - Family: `fidelity_unjudgeable_resolution_spec_clarified_resolved | fidelity_unjudgeable_resolution_spec_clarified_persistent | fidelity_unjudgeable_resolution_user_escalated`
   - Resolution map: 4.d.1 spec-clarify-respawn whose merged verdict is `aligned | drifted | contradicts` → `spec_clarified_resolved`; 4.d.1 whose merged verdict is again `unjudgeable` (forces 4.d.2) → `spec_clarified_persistent`; 4.d.2 user escalation (regardless of preceding 4.d.1) → `user_escalated`.
   - `source_artifact_ids`: `[<original unjudgeable verdict path>, <follow-up resolution artifact>]` — second entry is the merged verdict file for `*_resolved`/`*_persistent`, or the `_fidelity/<artifact-key>.escalation.md` path for `user_escalated`.

   ```bash
   case "$UJ_RESOLUTION" in
     spec_clarified_resolved)
       sources=("_work/<slug>/_fidelity/$ARTIFACT_KEY.json" "_work/<slug>/_fidelity/$ARTIFACT_KEY.json")  # merged file overwrites in place
       ;;
     spec_clarified_persistent)
       sources=("_work/<slug>/_fidelity/$ARTIFACT_KEY.json" "_work/<slug>/_fidelity/$ARTIFACT_KEY.json")
       ;;
     user_escalated)
       sources=("_work/<slug>/_fidelity/$ARTIFACT_KEY.json" "_work/<slug>/_fidelity/$ARTIFACT_KEY.escalation.md")
       ;;
   esac
   SOURCES_JSON=$(printf '%s\n' "${sources[@]}" | jq -R . | jq -sc .)
   for cat in spec_clarified_resolved spec_clarified_persistent user_escalated; do
     val=$(if [[ "$cat" == "$UJ_RESOLUTION" ]]; then echo "1.0"; else echo "0.0"; fi)
     jq -nc --arg metric "fidelity_unjudgeable_resolution_$cat" --argjson value "$val" \
        --arg label "$cat" --argjson sources "$SOURCES_JSON" \
        --arg jtv "$JUDGE_TEMPLATE_VERSION" \
        '{metric: $metric, value: $value, telemetry_label: $label, source_artifact_ids: $sources, template_version: $jtv}' \
       | bash ~/.lore/scripts/fidelity-verdict-capture.sh --telemetry
   done
   ```

   **Failure-handling note.** As with Step 3.5, telemetry-emission failures are best-effort — non-zero wrapper exit emits a stderr diagnostic but does NOT block worker acceptance or branch-handler completion. Telemetry is observability for `/retro`; missing rows degrade reader fidelity but cannot corrupt the gate.

   **3.c. Unsampled task — emit `kind: "exempt"` artifact directly.** When the task is unsampled (no mandatory trigger fired AND p=0.2 random did not select it), the lead writes the exempt artifact itself (no judge spawn) and immediately replies `fidelity: ack` so the worker can proceed:

   ```bash
   ARTIFACT_KEY=$(printf '%s' "<slug>:<task_subject>" | shasum -a 256 | cut -c1-12)
   FIDELITY_DIR="$KDIR/_work/<slug>/_fidelity"
   mkdir -p "$FIDELITY_DIR"
   cat > "$FIDELITY_DIR/$ARTIFACT_KEY.json" <<EOF
   {
     "kind": "exempt",
     "artifact_key": "$ARTIFACT_KEY",
     "phase": <phase-number>,
     "exempt_reason": "within_phase_unsampled",
     "sampling_trigger": "none",
     "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   }
   EOF
   ```

   Then send `fidelity: ack` to the worker via `SendMessage` so the worker proceeds past Step 7.5 and emits its own `TaskUpdate status: completed` (which fires the TaskCompleted hook; the hook reads the exempt artifact and accepts).

   **3.d. Bootstrap guard.** While `scripts/validate-fidelity-artifact.sh` is in warn-only mode (Phase 2 feature gate not yet flipped to blocking), the lead MAY skip emission of the exempt artifact for now. Once all three sentinels (`W06_FIDELITY_JUDGE_TEMPLATE_READY`, `W06_FIDELITY_STEP4_INTEGRATED`, `W06_FIDELITY_ACK_WAIT`) are present in the codebase, the validator switches to blocking mode and exempt-artifact emission becomes mandatory for unsampled tasks. After the gate flips, this bootstrap-guard paragraph should be removed.

4. **Advisor-impact rollup** — if the worker's report includes a non-empty `Advisor consultations:` field, invoke the scorecard rollup immediately:
   ```bash
   bash ~/.lore/scripts/advisor-impact-rollup.sh \
     --work-item <slug> \
     --task-id <task-id> \
     --consultations "<Advisor consultations field verbatim>" \
     --template-version "$ADVISOR_TEMPLATE_VERSION"
   ```
   This emits `consultation_rate` and `advice_followed_rate` scorecard rows attributed to `template_id=advisor`. Skip the call when `Advisor consultations:` is empty or `none`.

5. **Set aside Tier 3 candidates for Step 5** — if the worker report contains a `Tier 3 candidates:` YAML block, stash each entry (preserving producer_role and source_artifact_ids) for Step 5 promotion. Do NOT promote here — Step 5 is the sole promotion site.

6. **Handle blockers** — if a worker reports blockers:
   - Read the relevant code/context
   - Send guidance via `SendMessage` to the blocked worker
   - If unresolvable, note in `notes.md` and move on

7. **Check off completed items in plan.md** (best-effort):
   ```bash
   lore work check <slug> "<task-subject>"
   ```
   If this fails or is missed, Step 7 reconciles from the task system. This is the final substep — by the time it runs, the fidelity artifact already exists on disk (substep 3) so the TaskCompleted hook (which fires when the worker emits its own `TaskUpdate status: completed` after receiving `fidelity: ack`) will accept.

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

Inputs: the Tier 3 candidate list stashed in Step 4.5, plus any lead-originated cross-task candidates the lead produces by reading the complete `execution-log.md` after the last batch.

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
