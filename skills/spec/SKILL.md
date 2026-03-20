---
name: spec
description: "Create a technical specification — `/spec short` for single-pass plans, `/spec` for full team-based investigation"
user_invocable: true
argument_description: "[short] [--yes] [--without-verification] [name or description] — existing work item name, or a freeform description to start from"
---

# /spec Skill

Produces a `plan.md` inside a work item's `_work/<slug>/` directory.

**Two modes:**
- **`/spec short [input]`** — Single agent reads key files and drafts the plan directly. For well-understood, small-scope work.
- **`/spec [input]`** — Team of researcher agents investigate in parallel, then synthesize. For complex or uncertain-scope work.

**Input** can be an existing work item name (`/spec auth-refactor`) or a freeform description (`/spec add rate limiting to the API`). Freeform descriptions trigger goal refinement before investigation.

## Resolve Work Path

```bash
lore resolve
```
Set `KNOWLEDGE_DIR` to the result and `WORK_DIR` to `$KNOWLEDGE_DIR/_work`.

## Step 1: Parse and resolve (both modes)

1. Parse arguments: if first arg after `/spec` is `short`, use **Short Flow**; otherwise **Full Flow**. If `--yes` is present, skip all interactive confirmation gates (auto-proceed through investigation plan confirmation, strategy gates, confirm understanding, and task review). If `--without-verification` is present, skip Step 4b (assertion verification). The remaining text is the **input**.
2. Try to resolve input as an existing work item (fuzzy match or branch inference, same algorithm as `/work`)
3. **If resolved** → load the work item:
   - If `plan.md` exists with synthesis already complete (Design Decisions + Phases present), skip to Step 5.1 (Confirm understanding) — run the approval gates before finalizing. If a `## Strategy` section exists, load it silently as shaping context.
   - If `plan.md` exists with `## Investigations` and completed findings but no synthesis yet, skip to synthesis (Step 5). If a `## Strategy` section exists in plan.md, load it silently and use it as shaping context during synthesis — do not re-prompt.
   - If it has investigations but `## Open Questions` needing follow-up, dispatch targeted follow-ups
   - If `plan.md` exists but is incomplete, present for discussion/editing. If no `## Strategy` section exists and synthesis has not yet run, offer the strategy gate (Step 4d) before synthesizing.
   - If no `plan.md`, continue to Step 2 (the appropriate flow)
4. **If NOT resolved** → treat input as a freeform description, go to **Goal Refinement**
5. **If no input at all** → try branch inference; if no match, ask what they want to spec

## Step 1b: Goal Refinement (new work only)

When the input is a freeform description rather than an existing work item:

1. **Restate your understanding** of the goal in 1-2 sentences. Be specific about what you think they want.
2. **Ask 2-4 clarifying questions** using `AskUserQuestion`. Target the gaps that would most affect the spec:
   - Scope boundaries ("Should this cover X, or just Y?")
   - Key constraints ("Any existing patterns to follow? Performance requirements?")
   - Approach preferences ("Do you have a preferred approach, or should I evaluate options?")
   - Do NOT ask questions answerable by reading the codebase — save those for investigations
3. **Incorporate answers** into a refined goal statement
4. **Create the work item**: derive a slug from the description, run the `/work create` flow
5. Continue to Step 2 (Short Flow or Full Flow)

If the user's description is already specific enough (clear scope, stated constraints, obvious approach), skip to step 4 — don't ask questions for the sake of asking. Use judgment.

---

## Short Flow (`/spec short`)

For single-pass plans where the scope is clear and the agent can identify key files without parallel research.

**No verification agents.** The short flow is single-agent — assertions in `### Key Assertions` are self-generated and unverified. The user serves as the verifier via the understanding confirmation step (Step 3.5s). All assertion-sourced bullets are tagged `[unverified]` to reflect this.

### Step 2s: Read key context

1. From conversation context and the work item, identify 3-8 key files to read
1b. Search the knowledge store: `lore search "<topic>" --type knowledge --json --limit 5`. Read any relevant entries to avoid re-discovering known patterns.
2. Check the knowledge store (`lore index`, `_manifest.json`) for relevant domain files
3. Read the files yourself — do NOT spawn subagents
4. Note key findings as you go
5. **Skill and agent discovery** — after reading key files, scan for relevant skills and agents:
   a. Glob `~/.claude/skills/*/SKILL.md` — read the YAML frontmatter (`name`, `description`) and first section of each
   b. Glob `~/.claude/agents/*.md` — read each agent template name and opening description
   c. Match the work item title, description, and key findings against skill/agent names and descriptions using keyword overlap
   d. Deep-read any SKILL.md or agent template that shows strong overlap with the work item domain
   e. Record results for the `**Skill discovery:**` block emitted in Step 2.5s — this block is mandatory; do not skip it

### Step 2.5s: Strategy gate

Before drafting, offer the user a chance to shape the plan with high-level strategy.

1. **Check for existing strategy** — scan `plan.md` for a `## Strategy` section.
   - If found: read it silently. Do not re-prompt. Proceed to Step 3s with the strategy as additional shaping context.

2. **If no `## Strategy` exists**, present a lightweight context summary and prompt:

   **Compressed summary format:**
   ```
   ## Context Summary

   Files read: <list of key files>
   Top findings:
   - <key finding 1>
   - <key finding 2>
   - <key finding 3>

   **Skill discovery:**
   Considered: <comma-separated list of skills checked>
   Matched: <skill-name — rationale> (or "none")
   Agents reviewed: <comma-separated list of agent templates checked>
   ```

   Then prompt:
   ```
   Any strategy to apply to the plan? (Enter to skip)
   ```

3. **If the user skips (Enter with no input):** proceed directly to Step 3s with no changes — behavior is identical to the current flow.

4. **If the user supplies strategy:** append a `## Strategy` section to `plan.md` immediately (before drafting):
   ```markdown
   ## Strategy
   <user's strategy verbatim>
   ```
   Then proceed to Step 3s with the strategy as additional shaping context for design decisions and phase structure.

**Activation note:** Always present the context summary and prompt — do not skip this step because the scope seems clear. The user's Enter-to-skip response is the only gate. **Exception: if `--yes` was passed, skip this step entirely (no strategy).**

### Step 3s: Draft plan

1. Write `plan.md` using the **plan template** below
2. Use `## Context` instead of `## Investigations`: 3-6 bullet points summarizing key files read, constraints found, and relevant patterns
3. Under `## Context`, add a `### Key Assertions` subsection with 3-5 concrete, falsifiable claims about the codebase. These are the assumptions the plan is built on — the same format as researcher assertions but self-generated:
   ```
   ### Key Assertions
   - <claim about how the code works, referencing specific files/functions>
   - <claim about constraints or patterns discovered>
   - <claim about scope boundaries or dependencies>
   ```
   State each as fact ("X does Y"), not speculation. These assertions surface in the understanding confirmation step.
4. Fill in Goal, Design Decisions (using the `### DN: Title` structured format with `**Decision:**`, `**Rationale:**`, `**Alternatives considered:**`, and `**Applies to:**` fields), Phases, Open Questions

   Apply the task consolidation rule: each checkbox = one meaningful unit of work. Consolidate sequential same-file edits. Tasks sharing a file target within a phase are chained sequentially by generate-tasks.py and can only use 1 worker — splitting same-file work inflates recommended_workers without enabling parallelism. Cross-phase dependencies are also file-based: a task in a later phase is only blocked by earlier-phase tasks that share a file target; tasks with disjoint file targets run in parallel across phases. If you need strict sequential ordering between phases for tasks with non-overlapping files, include the shared file in both phases' `**Files:**` headers. After drafting phases, run `lore work regen-tasks <slug>` and review the `phase_cost_summary` in `tasks.json`. Tasks with `total_chars` above the phase median by >2x should be split; tasks below the phase median by >2x can be merged with adjacent tasks targeting the same files.

   **Task format (default — intent+constraints):** Task descriptions state *what the change accomplishes* (intent), *what not to do* (scope limits and anti-patterns), and *how to verify correctness* (verification criteria) — not exact code or line numbers. Opt a phase into prescriptive format with `**Task format:** prescriptive` for mechanical work where the implementation is fully determined.

   **Intent+constraints (default):**
   ```
   - [ ] Extract phase-level Scope and Verification fields from plan.md task blocks and inject them into task descriptions
   ```

   **Prescriptive (opt-in for mechanical work):**
   ```
   - [ ] In `generate-tasks.py` line 87, replace `context_block` with `build_context_block(task, phase, decisions)`
   ```

   **Discovery findings → Related skills:** If any skills were listed under `Matched:` in the `**Skill discovery:**` block from Step 2.5s, add a `**Related skills:**` block to the `## Context` section:
   ```
   **Related skills:**
   - /skill-name — why this skill is relevant to this work item
   ```
   If no skills matched, omit this block.

5. **Annotate phases with knowledge context** — after drafting phases with objectives and tasks, run a concordance query per phase to surface relevant knowledge entries beyond what you encountered in Step 2s:
   ```bash
   lore prefetch "<phase objective> <key file paths>" --type knowledge --limit 5
   ```
   Review the suggestions for each phase. Add relevant entries as `[[knowledge:file#heading]] — why relevant` lines in the phase's `**Knowledge context:**` block. Your direct findings from Step 2s are the primary source — concordance is a *widener*, not a replacement. Skip entries that don't add actionable context for a worker implementing that phase.

6. Present to user for review

### Step 3.3s: Review context cost estimates

After drafting phases, generate `tasks.json` and review the sizing output:

```bash
lore work regen-tasks <slug>
```

Read `tasks.json` and check the `phase_cost_summary` for each phase. For each phase, compare each task's `context_cost_estimate.total_chars` against the phase's `avg_per_task`:

- **Tasks >2x the phase `avg_per_task`:** Too large — split into separate tasks targeting different files or concerns
- **Tasks <0.5x the phase `avg_per_task`:** Too small — consider merging with an adjacent task that targets the same file

Update `plan.md` to reflect any splits or merges, then re-run `lore work regen-tasks <slug>` to confirm the revised estimates. Proceed once no phase has outlier tasks.

### Step 3.4s: Verify backlinks

After drafting plan.md, verify all `[[knowledge:...]]` and `[[work:...]]` backlinks are resolvable:

```bash
bash ~/.lore/scripts/verify-plan-backlinks.sh "$WORK_DIR/<slug>/plan.md" "$KNOWLEDGE_DIR" --fix
```

The script outputs JSON: `{verified: N, corrected: [...], unresolved: [...]}`.

- **If corrections were applied** (corrected is non-empty): briefly note the corrections made (e.g., "Corrected 2 backlinks: `[[knowledge:old-path]]` → `[[knowledge:new-path]]`").
- **If unresolved backlinks remain**: carry them forward into Step 3.5s as additional bullets (tagged `[broken backlink]`).
- **If all resolved**: proceed silently.

### Step 3.5s: Confirm understanding

Same purpose as the full flow's Step 5.1 — surface assumptions before finalizing.

**Present 5-10 bullet points** from the Key Assertions and Design Decisions. Since short flow has no verification agents, all assertion-sourced bullets are tagged `[unverified]`. For each design decision, include both the decision and its key alternative to surface trade-offs. If Step 3.4s reported unresolved backlinks, include them as additional bullets:

```
Before finalizing this plan, here is my understanding of the key assumptions:

- [unverified] <claim from Key Assertions> → Context: Key Assertions
- <decision statement> (over <rejected alternative>) → Design Decision: D1: <title>
- [broken backlink] [[knowledge:path]] could not be resolved — verify or remove → Step 3.4s backlink check
...

Does this match your understanding? Any corrections?
```

**Gate:** Do not proceed to Step 3.7s until the user explicitly confirms or provides corrections. If corrections are needed, revise the affected plan sections (same approach as the full flow's Step 5.2) and re-present the corrected bullets. **If `--yes` was passed, skip this step (auto-proceed).**

### Step 3.7s: Task review

Same purpose as the full flow's Step 5.3 — validate the implementation approach before finalizing. Use the same phase summary format (objective, mechanism, scope, task count) as described in Step 5.3.

1. **Synthesize phase summaries from plan.md** — for each phase, produce a summary block with objective, mechanism, scope, and task count. The mechanism descriptions come from the plan's task content — synthesize them from existing context without additional file reads.

2. **Present the phase summaries** to the user. End with:
   ```
   Review the phases above. Approve to proceed, or request changes.
   ```

3. **Wait for explicit approval.** Do not proceed to Step 4s until the user explicitly approves. **If `--yes` was passed, skip this step (auto-approve).**

4. **If the user requests changes** — revise the affected phases in `plan.md`, then re-present only the changed phase summaries. Repeat until the user approves.

5. **If the user needs new investigation** — suggest re-running `/spec` rather than patching the plan ad-hoc.

### Step 4s: Finalize

**Prerequisite:** The task review gate (Step 3.7s) must be explicitly approved before finalization proceeds.

1. Incorporate user feedback
2. **Post-research extraction** — invoke `/remember` scoped to the spec:
   ```
   /remember Research findings from <work item title> — Review the **Context** and **Key Assertions** sections in plan.md. Capture mechanism-level patterns (how the system accomplishes something broadly) and design rationale ("this was chosen because X"). Skip: implementation facts already expressed as Key Assertions (they're persisted in plan.md). Focus on cross-cutting patterns discovered during file exploration that would apply beyond this work item.
   ```
3. Generate `tasks.json` — after `plan.md` is finalized, run:
   ```bash
   lore work regen-tasks <slug>
   ```
   This pre-computes TaskCreate payloads so `/work tasks` and `/implement` can load them directly without re-parsing `plan.md`.
4. Run `lore work heal`
5. Suggest retrospective: `Consider /retro <slug> to evaluate knowledge system effectiveness for this spec.`

---

## Full Flow (`/spec`)

Team-based divide-and-conquer for complex or uncertain-scope work.

> **Sequencing constraint:** Do not dispatch research agents (Explore, Agent tool) before completing Step 2. The investigation plan is a completeness checklist and user approval gate, not just a dispatch list. Pre-existing research does not substitute for the formal investigation plan.

### Step 2: Decompose into investigations

1. From the feature description, identify 3-7 focused investigation questions. Each should:
   - Target a specific part of the codebase or concern
   - Be answerable by exploring files (not by asking the user)
   - Be independent enough to run in parallel
2. **Always include** one additional fixed investigation topic: **Skill and agent applicability** — which installed skills and agent templates should be invoked during **implementation** of this work item (i.e., when the plan is executed, not during this investigation step)? Key files: `~/.claude/skills/*/SKILL.md`, `~/.claude/agents/*.md`. This investigation is mandatory and counts toward the 3-7 total.
3. Check the knowledge store index for file hints to include with each investigation
4. **Assess complexity** for each investigation using these heuristics:
   - **simple** — 1-2 key files, narrow question targeting a single function or module
   - **moderate** — 3-5 key files, or a multi-part question spanning related modules
   - **complex** — 6+ key files, or a cross-cutting concern (e.g., touches config, runtime, and tests)
5. Present the investigation plan to the user as a structured preview table:
   ```
   ## Investigation Plan

   | # | Area / Topic | Key Files | Complexity |
   |---|-------------|-----------|------------|
   | 1 | Skill and agent applicability *(mandatory — do not remove)* | `~/.claude/skills/*/SKILL.md`, `~/.claude/agents/*.md` | simple |
   | 2 | <topic>     | `file1`, `file2` | simple |
   | 3 | <topic>     | `file1`, `file2`, `file3` | moderate |
   | 4 | <topic>     | `file1`, ... `file6` | complex |
   ...

   Proceed, or adjust? (You can request changes — e.g., split a question, drop an area, add a new one, or change scope.)
   ```
6. Wait for user confirmation before dispatching. If the user requests adjustments (freeform text), revise the table and re-present it. Repeat until approved. **If `--yes` was passed, skip this confirmation and dispatch immediately.**

**Example** — for a "add rate limiting to the API" spec:
```
## Investigation Plan

| # | Area / Topic | Key Files | Complexity |
|---|-------------|-----------|------------|
| 1 | Skill and agent applicability *(mandatory — do not remove)* | `~/.claude/skills/*/SKILL.md`, `~/.claude/agents/*.md` | simple |
| 2 | Current middleware chain | `src/middleware/index.ts`, `src/app.ts` | simple |
| 3 | Auth + session handling | `src/auth/session.ts`, `src/auth/middleware.ts`, `src/types/auth.ts` | moderate |
| 4 | Request lifecycle & error paths | `src/handlers/`, `src/errors/`, `src/middleware/`, `src/logging/`, `tests/integration/` | complex |
| 5 | Existing config & env patterns | `src/config.ts`, `src/env.ts` | simple |

Proceed, or adjust? (You can request changes — e.g., split a question, drop an area, add a new one, or change scope.)
```

### Step 3: Create investigation team

**Prerequisite:** Step 2 must be complete — an approved investigation plan table must exist in the conversation. Do NOT create teams, tasks, or spawn agents before Step 2 approval (or `--yes` auto-approval). This applies to initial dispatch only; follow-up investigations (Step 6) use existing findings as their scope.

**All investigations are executed by fresh researcher agents.** The lead decomposes questions and pre-fetches knowledge; researchers investigate. Exception: `/spec short` is explicitly single-agent for small-scope work.

1. **Create team:**
   ```
   TeamCreate: team_name="spec-<slug>", description="Investigating <work item title>"
   ```

2. **Read your team lead name** from `~/.claude/teams/spec-<slug>/config.json` — you'll embed this in researcher prompts so they know who to message.

3. **Create investigation tasks** — one `TaskCreate` per question:
   - `subject`: "Investigate: \<question summary\>"
   - `description`: The full question, context, file hints, and expected report format (see below)
   - `activeForm`: "Investigating \<short topic\>"

   **Discovery researcher spec** — for the mandatory "Skill and agent applicability" investigation, the task description must include these additional instructions:
   - **Context:** The purpose of this investigation is to identify skills and agents that would be useful during the **implementation phase** — i.e., when a developer or `/implement` agent team executes the plan produced by this spec. Do NOT evaluate applicability to the investigation/research step you are currently performing.
   - Glob `~/.claude/skills/*/SKILL.md` — read the YAML frontmatter (`name`, `description`) and first section of each to assess relevance to implementation
   - Deep-read any SKILL.md that overlaps with the work item title, description, or investigation topics (keyword match on `name`/`description` fields)
   - Glob `~/.claude/agents/*.md` — read each agent template to assess applicability to implementation
   - Report format adds two extra fields after `**Implications:**`:
     ```
     **Matched skills:**
     - /skill-name — why this skill would be invoked during implementation
     - (none) if no skills matched
     **Matched agents:**
     - agent-name — why this agent template would be used during implementation
     - (none) if no agents matched
     ```
   - Assertions for this investigation should be concrete claims about which skills/agents are relevant to implementation and why, not general codebase claims

4. **Pre-fetch knowledge for each investigation** — before constructing prompts, run:
   ```bash
   PRIOR_KNOWLEDGE=$(lore prefetch "<investigation topic>" --format prompt --limit 5)
   ```
   This produces a "## Prior Knowledge" block with pre-resolved content from the knowledge store.

5. **Skill-applicability scan and advisor provisioning** — before spawning researchers, scan and emit a discovery block:

   a. **Scan the skill list in your system prompt** — for each skill, check if its name, description, or trigger conditions overlap with the work item's domain. A skill is applicable if:
      - Its name or description contains keywords from the work item title or domain (e.g., a work item about "improving the spec flow" matches the `/spec` skill)
      - The work item is about modifying, extending, or interacting with that skill
      - Investigation topics overlap with the skill's described capabilities

      **Emit a skill discovery block** (mandatory — always output this, even if no matches):
      ```
      **Skill discovery:**
      Considered: <comma-separated list of all skills checked>
      Matched: <skill-name — rationale> (or "none")
      ```

      Note: The discovery researcher (from Step 2) reads actual SKILL.md files; this scan uses only system prompt summaries. Use this scan to provision advisors — the discovery researcher's findings provide the authoritative matched skills list for the plan's `**Related skills:**` block.

   b. **If applicable skills are found** — provision skill-backed advisors:

      i. For each applicable skill, read its SKILL.md file to obtain the full skill definition.

      ii. **Spawn an advisor** for each applicable skill using the **advisor** agent definition (`agents/advisor.md`) with these template injections:
         - `{{team_name}}` → `spec-<slug>`
         - `{{advisor_domain}}` → the skill name and a brief scope description (e.g., "implement skill — execution protocol and worker coordination")
         - `{{domain_context}}` → the SKILL.md content for the applicable skill

         ```
         Task:
           subagent_type: "general-purpose"
           model: "sonnet"
           team_name: "spec-<slug>"
           name: "<skill-name>-advisor"
           mode: "bypassPermissions"
           prompt: |
             <contents of agents/advisor.md with {{template}} variables resolved>
         ```

      iii. **Build the `$ADVISORY_MIXIN`** — read `scripts/agent-protocols/advisory-consultation.md`. Build the `{{advisors}}` replacement block from the spawned advisors:
         ```
         - **<skill-name>-advisor** — <skill domain scope>. Mode: on-demand
         ```
         Resolve `{{advisors}}` in the mixin content. Store the result as `$ADVISORY_MIXIN`.

         All skill-backed advisors use `on-demand` mode — must-consult would block researchers before they begin work, which is incompatible with parallel investigation.

   c. **If no applicable skills are found** — set `$ADVISORY_MIXIN` to empty. No advisors are spawned.

6. **Spawn researcher agents** — launch `min(investigation_count, 4)` in a single message. Use the **researcher** agent definition (`~/.claude/agents/researcher.md`) as the base prompt, with these template injections:
   - `{{team_name}}` → `spec-<slug>`
   - `{{team_lead}}` → the lead name read from team config in Step 3.2
   - `{{prior_knowledge}}` → the `$PRIOR_KNOWLEDGE` block from Step 3.4

   **If `$ADVISORY_MIXIN` is non-empty:** append the resolved mixin content after the fully resolved `researcher.md` content, separated by a blank line. The researcher prompt becomes: `<resolved researcher.md>\n\n<resolved advisory-consultation.md>`.

   ```
   Task:
     subagent_type: "Explore"
     model: "sonnet"
     team_name: "spec-<slug>"
     name: "researcher-N"
     prompt: |
       <contents of ~/.claude/agents/researcher.md with {{template}} variables resolved>
       <if advisors: contents of advisory-consultation.md with {{advisors}} resolved>
   ```

   If more questions than researchers, agents pick up additional tasks after completing their first.

### Step 4: Collect and document findings

As researcher messages arrive (delivered automatically):
1. Write each finding to the `## Investigations` section of `plan.md`
2. Use the investigation entry format from the template below
3. **Preserve `**Assertions:**` verbatim** — copy researcher assertions exactly as reported. Do not rephrase, merge, or summarize them. These are falsifiable claims that downstream verification will test against the code.

When all investigation tasks are complete:
1. Send shutdown requests to all researchers and all advisor agents (if any were spawned in Step 3.5) via `SendMessage` (type: `shutdown_request`)
2. Run `TeamDelete` to clean up the team

This is the critical persistence step — findings survive compaction, session boundaries, and context limits.

### Step 4b: Verify assertions

**Skip this step if `--without-verification` was passed.** All assertions proceed to synthesis as unverified researcher claims.

After all investigations are complete, verify the assertions researchers reported before using them in synthesis.

1. **Extract assertions** — collect all `**Assertions:**` entries from the `## Investigations` section of `plan.md`. Deduplicate assertions that make the same claim about the same code.

2. **Spawn verification agents** — launch 1-2 Explore agents with the verifier-verdict protocol mixin (`scripts/agent-protocols/verifier-verdict.md`). Split assertions across agents if there are more than 5.

   ```
   Task:
     subagent_type: "Explore"
     model: "sonnet"
     prompt: |
       <contents of scripts/agent-protocols/verifier-verdict.md>

       ## Assertions to Verify
       <list of assertions with their source investigation topic>
   ```

3. **Collect verdicts** — when verification agents report back, update each assertion in `plan.md` with its verdict:
   - **CONFIRMED** assertions remain as-is
   - **REFUTED** assertions get the correction appended: `~~original~~ REFUTED: <actual behavior>`
   - **UNVERIFIABLE** assertions are marked: `<original> (UNVERIFIABLE: <reason>)`

4. **Apply corrections** — for each REFUTED assertion, update the corresponding investigation entry in `plan.md`:
   - Add a `**Corrections:**` block to the investigation entry (after `**Assertions:**`)
   - Each correction includes the original assertion, the verifier's evidence, and the actual behavior
   - Format:
     ```
     **Corrections:**
     - "original assertion" — REFUTED. Actual behavior: <correction from verifier>. Evidence: <file:line>
     ```
   - If a correction contradicts a finding in the same investigation, update `**Findings:**` to reflect the corrected understanding
   - Do NOT delete the original assertion — the strikethrough markup preserves the audit trail

5. **Log summary** — add a brief verification summary after the `## Investigations` section:
   ```
   ### Verification Summary
   Confirmed: N | Refuted: N | Unverifiable: N
   ```
   If any assertions were refuted, synthesis (Step 5) must use the corrected information, not the original assertions.

**Graceful degradation:** If verification agents fail, timeout, or return malformed output:
- Mark all unverified assertions as `(UNVERIFIED — verification failed)` in `plan.md`
- Log the failure in the verification summary:
  ```
  ### Verification Summary
  Verification failed: <reason>. All assertions treated as unverified.
  ```
- **Proceed to synthesis.** Unverified assertions are treated as researcher claims without independent confirmation — usable but flagged. Do not block the spec on verification failure.

### Step 4c: Write investigation log entry

After verification (or after Step 4 if `--without-verification` was passed), append an investigation summary to `execution-log.md`. Resolve the slug from the current plan context (already loaded in Step 1).

```bash
printf 'Investigations: %d\nTopics: %s\nVerification: confirmed=%d, refuted=%d, unverifiable=%d\nRefuted assertions: %s\n' \
  "<N>" \
  "<comma-separated investigation topics>" \
  "<confirmed count>" "<refuted count>" "<unverifiable count>" \
  "<list of refuted assertions that shaped synthesis, or 'none'>" \
  | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source spec-lead
```

- **Investigation count:** number of researcher agents that reported back
- **Topics:** the investigation topics from Step 2 (not the full questions — short labels)
- **Verification fields:** from the `### Verification Summary` in `plan.md`; use `0` for all if `--without-verification` was passed
- **Refuted assertions:** only those that changed the synthesis direction — omit confirmed and unverifiable assertions

### Step 4d: Strategy gate

Before synthesizing, offer the user a chance to shape the plan with high-level strategy.

1. **Check for existing strategy** — scan `plan.md` for a `## Strategy` section.
   - If found: read it silently. Do not re-prompt. Proceed to Step 5 with the strategy as additional shaping context.

2. **If no `## Strategy` exists**, present a compressed investigation summary and prompt:

   **Compressed summary format:**
   ```
   ## Investigation Summary

   | Area | Key Finding | Assertions |
   |------|-------------|------------|
   | <topic> | <1-sentence finding> | <N confirmed, M refuted> |
   ...

   Refuted: <list refuted assertions briefly, or "none">
   ```

   Then prompt:
   ```
   Any strategy to apply to the plan? (Enter to skip)
   ```

3. **If the user skips (Enter with no input):** proceed directly to Step 5 with no changes — behavior is identical to the current flow.

4. **If the user supplies strategy:** append a `## Strategy` section to `plan.md` immediately (before synthesis):
   ```markdown
   ## Strategy
   <user's strategy verbatim>
   ```
   Then proceed to Step 5 with the strategy as additional shaping context for design decisions and phase structure.

**Activation note:** This step is a concrete prompt-and-respond interaction, not an evaluation condition. Always present the compressed summary and prompt — do not assess whether strategy "seems needed" and skip. The user's Enter-to-skip response is the only gate. **Exception: if `--yes` was passed, skip this step entirely (no strategy).**

### Step 5: Synthesize

From the documented findings, draft the remaining plan sections:
1. **Goal** — what we're building/changing and why (1 paragraph)
2. **Design Decisions** — use the `### DN: Title` format from the template. Each decision requires `**Decision:**`, `**Rationale:**`, `**Alternatives considered:**`, and `**Applies to:**` fields. Number decisions sequentially (D1, D2, ...).
3. **Phases** — concrete implementation phases with tasks, file paths, objectives. For each phase, include a `**Knowledge context:**` block listing knowledge entries relevant to that phase — these flow directly to worker agents via task generation. For multi-worker phases, novel implementations without codebase precedent, or phases using intent+constraints task format, add `**Knowledge delivery:** full` — workers interpreting intent and constraints need resolved knowledge content, not just backlink labels.

   **Advisor identification:** When investigations reveal domain complexity in a phase — unfamiliar invariants, cross-cutting constraints, or areas where uninformed changes risk breaking correctness — add an `**Advisors:**` block declaring domain-expert advisors for that phase. Use the format: `- advisor-name — domain scope. [must-consult|on-demand]`. Use `must-consult` when the domain has hard invariants that workers must respect (e.g., auth, data migration); use `on-demand` when the domain is complex but workers can start independently and ask questions as needed. `/implement` spawns declared advisors as persistent team members with investigation findings as their domain baseline.

   **Discovery findings integration** — after drafting phases, apply the discovery researcher's `**Matched skills:**` and `**Matched agents:**` findings:
   - **Related skills block:** If the discovery researcher reported matched skills, add a `**Related skills:**` block to the `## Context` or `## Investigations` section (under the discovery investigation entry):
     ```
     **Related skills:**
     - /skill-name — why this skill is relevant to this work item
     ```
   - **Advisor declarations:** For each matched skill whose domain overlaps with a phase's scope, consider adding an `**Advisors:**` entry for that phase. Use the skill name as the advisor name (e.g., `spec-advisor`) and scope it to the phase's domain. Set mode based on phase complexity — `must-consult` if the skill defines invariants workers must respect, `on-demand` otherwise.

   **Task consolidation rule:** Each `- [ ]` checkbox should be a meaningful unit of work, not a micro-edit. Multiple sequential edits to the same file should be one task (e.g., "Update worker prompt to add capture step and renumber" not three separate tasks for delete/insert/renumber). Tasks sharing a file target within a phase are chained sequentially by generate-tasks.py and can only use 1 worker — splitting same-file work inflates recommended_workers without enabling parallelism. Cross-phase dependencies are also file-based: a task in a later phase is only blocked by earlier-phase tasks that share a file target; tasks with disjoint file targets run in parallel across phases. If you need strict sequential ordering between phases for tasks with non-overlapping files, include the shared file in both phases' `**Files:**` headers. After drafting phases, run `lore work regen-tasks <slug>` and review the `phase_cost_summary` in `tasks.json`. Tasks with `total_chars` above the phase median by >2x should be split; tasks below the phase median by >2x can be merged with adjacent tasks targeting the same files.

   **Task format (default — intent+constraints):** Task descriptions state *what the change accomplishes* (intent), *what not to do* (scope limits and anti-patterns), and *how to verify correctness* (verification criteria) — not exact code or line numbers. Opt a phase into prescriptive format with `**Task format:** prescriptive` for mechanical work where the implementation is fully determined.

   **Intent+constraints (default):**
   ```
   - [ ] Extract phase-level Scope and Verification fields from plan.md task blocks and inject them into task descriptions
   ```

   **Prescriptive (opt-in for mechanical work):**
   ```
   - [ ] In `generate-tasks.py` line 87, replace `context_block` with `build_context_block(task, phase, decisions)`
   ```

4. **Concordance-assisted annotation** — after drafting phases, widen each phase's `**Knowledge context:**` block beyond what investigations explicitly mentioned. For each phase, run:
   ```bash
   lore prefetch "<phase objective> <key file paths>" --type knowledge --limit 5
   ```
   Review the suggestions against what is already listed. Add relevant entries as `[[knowledge:...]]` backlinks with a brief "— why relevant" annotation. Skip entries that duplicate what investigations already covered. Investigation findings are the primary source of knowledge references — concordance is a *widener*, not a replacement.

5. **Open Questions** — anything investigations couldn't resolve

Present the synthesized plan to the user for review.

### Step 5.0: Review context cost estimates

After completing synthesis, generate `tasks.json` and review the sizing output:

```bash
lore work regen-tasks <slug>
```

Read `tasks.json` and check the `phase_cost_summary` for each phase. For each phase, compare each task's `context_cost_estimate.total_chars` against the phase's `avg_per_task`:

- **Tasks >2x the phase `avg_per_task`:** Too large — split into separate tasks targeting different files or concerns
- **Tasks <0.5x the phase `avg_per_task`:** Too small — consider merging with an adjacent task that targets the same file

Update `plan.md` to reflect any splits or merges, then re-run `lore work regen-tasks <slug>` to confirm the revised estimates. Proceed once no phase has outlier tasks.

### Step 5.0.5: Verify backlinks

After completing synthesis, verify all `[[knowledge:...]]` and `[[work:...]]` backlinks in plan.md are resolvable:

```bash
bash ~/.lore/scripts/verify-plan-backlinks.sh "$WORK_DIR/<slug>/plan.md" "$KNOWLEDGE_DIR" --fix
```

The script outputs JSON: `{verified: N, corrected: [...], unresolved: [...]}`.

- **If corrections were applied** (corrected is non-empty): briefly note the corrections made (e.g., "Corrected 2 backlinks: `[[knowledge:old-path]]` → `[[knowledge:new-path]]`").
- **If unresolved backlinks remain**: carry them forward into Step 5.1 as additional bullets (tagged `[broken backlink]`).
- **If all resolved**: proceed silently.

### Step 5.1: Confirm understanding

Before finalizing, present a concise understanding summary for the user to validate. This surfaces the assumptions and claims the plan is built on so the user can catch misunderstandings before they propagate to implementation.

**Present 5-10 bullet points covering:**
- Key assumptions about the codebase architecture
- Behavioral claims from verified assertions (mark with `[verified]`) or unverified researcher claims (mark with `[unverified]`)
- Design decisions with their key rejected alternative — surfacing what was chosen *over what* makes trade-offs explicit
- Scope boundaries — what is and is not included
- Any unresolved backlinks reported by Step 5.0.5 (tagged `[broken backlink]`)

**Traceability:** Each bullet must trace to a specific source. Use `→` to link the claim to its origin:
- Assertion-sourced bullets: trace to the investigation topic and verification verdict
- Design decision bullets: trace to the Design Decisions section entry by DN identifier (e.g., `D1: <title>`)
- Scope bullets: trace to the Goal or user input that established the boundary
- Broken backlink bullets: trace to the backlink verification step

**Format:**
```
Before finalizing this plan, here is my understanding of the key assumptions:

- [verified] <claim> → Investigation: <topic>, Assertion #N
- [unverified] <claim> → Investigation: <topic>, Assertion #N
- <decision statement> (over <rejected alternative>) → Design Decision: D1: <title>
- <scope boundary> → Goal / user input
- [broken backlink] [[knowledge:path]] could not be resolved — verify or remove → Step 5.0.5 backlink check
...

Does this match your understanding? Any corrections?
```

**Gate:** Do not proceed to Step 5.3 until the user explicitly confirms or provides corrections. If the user identifies incorrect points, go to Step 5.2 (handle corrections) before continuing. The prompt "Does this match your understanding? Any corrections?" is not rhetorical — wait for a response. **If `--yes` was passed, skip this step (auto-proceed).**

### Step 5.2: Handle corrections (if needed)

When the user corrects one or more understanding bullets:

1. **Identify affected plan sections** — for each correction, trace the `→` link to determine what needs updating:
   - Corrected assertion → update the corresponding investigation entry and its assertions
   - Corrected design decision → update the Design Decisions section
   - Corrected scope → update the Goal section

2. **Revise affected sections** — update `plan.md` with the corrected understanding. If a correction invalidates a design decision, revise the decision and its rationale. If it changes scope, update the Goal and adjust phases accordingly.

3. **Re-check affected phases** — for each corrected bullet, check whether its `**Applies to:**` phases are still valid. If a phase's tasks depend on the corrected assumption, revise those tasks.

4. **Re-present understanding** — after applying corrections, return to Step 5.1 with an updated summary. Only re-list the corrected bullets (not the full set) for efficiency:
   ```
   Updated understanding after your corrections:

   - [corrected] <revised claim> → <source>
   ...

   Anything else to adjust?
   ```

5. If the user confirms, proceed to Step 5.3.

### Step 5.3: Task review

Before finalizing, present the plan's phases as a structured summary for the user to review the implementation approach. This is a separate gate from Step 5.1 — that step validates *understanding* (assumptions and decisions); this step validates the *work plan* (what will actually be built and how).

1. **Synthesize phase summaries** — for each phase in `plan.md`, produce a summary block with four fields:

   ```
   Phase N: <Name>
     Objective: <what this phase accomplishes>
     Mechanism: <HOW — the specific technical approach, 1-3 sentences>
     Scope:     <files and components touched>
     Tasks:     <N tasks>
   ```

   **Example:**
   ```
   Phase 1: Add rate limiter middleware
     Objective: Introduce per-endpoint rate limiting before auth checks
     Mechanism: Create a new Express middleware using a sliding-window counter backed by Redis.
                Register it in the middleware chain before the auth middleware in app.ts.
     Scope:     src/middleware/rate-limiter.ts (new), src/middleware/index.ts, src/app.ts
     Tasks:     3 tasks

   Phase 2: Configure rate limit policies
     Objective: Define per-route rate limit thresholds via config
     Mechanism: Extend the existing config schema to accept a rate_limits map keyed by route
                pattern. Load defaults from env with per-route overrides in config.yaml.
     Scope:     src/config.ts, src/config.schema.ts, config.yaml
     Tasks:     2 tasks
   ```

2. **Present the full set of phase summaries** to the user. End with:
   ```
   Review the phases above. Approve to proceed, or request changes.
   ```

3. **Wait for explicit approval.** Do not proceed to Step 5.4 until the user explicitly approves (e.g., "approved", "looks good", "proceed"). **If `--yes` was passed, skip this step (auto-approve).**

4. **If the user requests changes** — revise the affected phases in `plan.md`, then re-present only the changed phase summaries. Repeat steps 2-3 until the user approves.

5. **If the user needs new investigation** — the task review is bounded to what the existing findings support. If the user identifies gaps that require exploring new code or revisiting assumptions, suggest re-running `/spec` rather than patching the plan ad-hoc:
   ```
   This change requires new investigation beyond the current findings.
   Consider re-running `/spec <slug>` to explore this area.
   ```

### Step 5.4: Post-research extraction

Invoke `/remember` scoped to the spec investigation:

```
/remember Research findings from <work item title> — Read all **Observations:** entries from investigation reports in plan.md and evaluate each — mechanism-level patterns (how the system accomplishes X broadly) and design rationale ("this was chosen because X") both qualify; implementation facts already expressed in Assertions do not. Also capture: cross-investigation synthesis patterns not surfaced individually. Skip: findings already documented in plan.md Assertions (they're persisted there).
```

### Step 5.5: Generate tasks.json

After the user approves the plan (or after incorporating feedback), generate `tasks.json`:
```bash
lore work regen-tasks <slug>
```
This pre-computes TaskCreate payloads so `/work tasks` and `/implement` can load them directly without re-parsing `plan.md`.

### Step 6: Iterate (if needed)

If gaps are identified:
- Create a new investigation team (same pattern) for targeted follow-ups
- Append new findings to the Investigations section
- Update the synthesis

Run `lore work heal` after any changes.

After finalization or iteration is complete, suggest:
```
Consider `/retro <slug>` to evaluate knowledge system effectiveness for this spec.
```

---

## Plan.md Template

```markdown
# <Work Item Title>

## Goal
<!-- One paragraph: what we're building/changing and why -->

## Strategy
<!-- Optional. Written verbatim from user input at the strategy gate (Step 4d / Step 2.5s).
     Omit this section entirely if the user skips the strategy prompt — absence is the default.
     On continuation runs, this section is read silently and used to shape synthesis.

     Format: free-form text block written as a worker-facing directive.
     Write the user's input as-is — do not summarize, annotate, or interpret.
     If the user provides a list, preserve it as a list. If prose, preserve as prose.

     Examples of valid strategy content:
       "Prefer composition over inheritance throughout. No new abstract base classes."
       "Phase the rollout: core types first, then adapters, then update call sites."
       "Keep changes backward-compatible — the v1 API must still work after this."

     This content is injected into worker task descriptions alongside design decisions.
     Write it so a worker reading it for the first time understands what to do, not just
     what was discussed. -->

## Context
<!-- SHORT FLOW ONLY: 3-6 bullets summarizing key files, constraints, and patterns found -->
<!-- FULL FLOW: delete this section and use ## Investigations instead -->

## Investigations
<!-- FULL FLOW ONLY: findings from team-based exploration -->
<!-- SHORT FLOW: delete this section and use ## Context instead -->

### <Topic 1>
**Question:** <what was investigated>
**Findings:**
- Finding 1
- Finding 2
**Key files:** `path/to/file.ts`, `path/to/other.ts`
**Implications:** How this affects the design
**Assertions:**
- <falsifiable claim 1, preserved verbatim from researcher report>
- <falsifiable claim 2, preserved verbatim from researcher report>

## Design Decisions

### D1: <Decision Title>
**Decision:** What was decided — a concrete, actionable statement
**Rationale:** Why this choice over others — the reasoning, constraints, or evidence that led here
**Alternatives considered:** What other approaches were evaluated and why they were rejected
**Applies to:** Phase N (<name>), Phase M (<name>) — which phases/tasks this decision affects

## Phases

### Phase 1: <Name>
**Objective:** What this phase accomplishes
**Files:** relevant file paths
**Scope:**
<!-- Optional — list files/components workers must NOT modify in this phase, and any output contracts (e.g., "do not change public API signatures"). Omit if no scope fencing is needed. -->
- Do not modify: `path/to/file`
- Output contract: <what the phase must produce without changing>
**Task format:** prescriptive  <!-- optional — omit for default intent+constraints format. Use `prescriptive` only when the implementation is fully determined (e.g., mechanical substitutions, exact insertions). Default format: task descriptions state intent, scope constraints, and verification criteria — not code. -->
**Knowledge delivery:** full  <!-- optional — omit for default annotation-only delivery (~50-200 tokens per backlink). Use `full` for: (1) multi-worker phases where cross-worker consistency matters (all workers need the same reference content), (2) novel implementations without codebase precedent (no existing patterns to anchor against), or (3) phases using intent+constraints task format — workers interpret design patterns from knowledge content, not code; annotation-only leaves backlink labels with no resolved content for workers to act on. Full resolution costs ~2k-4k tokens per task. -->
**Knowledge context:**
<!-- Each entry MUST include a "— why relevant" annotation after the backlink.
     Good annotations are implementation-facing — they tell the worker what to DO with the knowledge entry, not what the entry is about.
     GOOD: "— understand the call graph before modifying resolve_backlinks()" / "— reuse this pattern for the new middleware"
     BAD:  "— explains the push-over-pull principle" (filing-facing: describes the entry, not how to use it)
     BAD:  "— provides context for this phase" (vague: could apply to anything)
     A worker who hasn't read the entry should understand from the annotation alone why it matters to their task. -->
- [[knowledge:file#heading]] — why this is relevant to this phase
**Advisors:**
<!-- Optional — declare domain-expert advisors for this phase. /implement spawns these as persistent team members that workers can consult. Omit this field if no advisors are needed. -->
- advisor-name — domain scope. [must-consult|on-demand]
**Verification:**
<!-- Optional — list concrete pass/fail criteria workers check after implementation. Each criterion should be independently verifiable. Use plain bullets (not checkboxes) so they are not parsed as tasks. Omit if verification is self-evident. -->
- <criterion 1 — e.g., "existing tests pass unchanged">
- <criterion 2 — e.g., "lore work regen-tasks produces no outlier tasks">
- [ ] Task 1
- [ ] Task 2

## Open Questions
- Unresolved decisions or items needing follow-up

## Related
<!-- Cross-cutting references that apply to the whole plan, not a specific phase. Phase-specific references belong in **Knowledge context:** blocks within each phase. -->
- [[knowledge:file#heading]] — cross-references to knowledge store
```

## Resuming a spec across sessions

When `/spec` is called on a work item that already has a plan:
- Read existing investigations/context — they are your memory (no need to re-explore)
- If a `## Strategy` section exists in plan.md, read it silently and use it as shaping context during synthesis — do not re-prompt. plan.md is the memory; strategy captured in a prior session carries forward automatically.
- Check if synthesis (Design/Phases) is complete; if not, synthesize from existing findings
- Check Open Questions — dispatch follow-up investigations for unresolved items
- **Always run the approval gates before finalizing:** whether synthesis was just completed or carried over from a prior session, proceed through Step 5.1 (Confirm understanding) and Step 5.3 (Task review). Do not skip these because the plan "already exists" — the structured understanding summary and phase review are the mechanism for catching misalignments regardless of when synthesis ran. Exception: if `--yes` was passed, these gates are auto-approved.
