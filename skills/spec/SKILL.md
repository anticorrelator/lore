---
name: spec
description: "Create a technical specification — `/spec short` for single-pass plans, `/spec` for full team-based investigation"
user_invocable: true
argument_description: "[short] [--without-verification] [name or description] — existing work item name, or a freeform description to start from"
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

1. Parse arguments: if first arg after `/spec` is `short`, use **Short Flow**; otherwise **Full Flow**. If `--without-verification` is present, skip Step 4b (assertion verification). The remaining text is the **input**.
2. Try to resolve input as an existing work item (fuzzy match or branch inference, same algorithm as `/work`)
3. **If resolved** → load the work item:
   - If `plan.md` exists with `## Investigations` and completed findings, skip to synthesis (Step 5)
   - If it has investigations but `## Open Questions` needing follow-up, dispatch targeted follow-ups
   - If `plan.md` exists but is incomplete, present for discussion/editing
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

   Apply the task consolidation rule: each checkbox = one meaningful unit of work. Consolidate sequential same-file edits.

5. **Annotate phases with knowledge context** — after drafting phases with objectives and tasks, run a concordance query per phase to surface relevant knowledge entries beyond what you encountered in Step 2s:
   ```bash
   lore prefetch "<phase objective> <key file paths>" --type knowledge --limit 5
   ```
   Review the suggestions for each phase. Add relevant entries as `[[knowledge:file#heading]] — why relevant` lines in the phase's `**Knowledge context:**` block. Your direct findings from Step 2s are the primary source — concordance is a *widener*, not a replacement. Skip entries that don't add actionable context for a worker implementing that phase.

6. Present to user for review

### Step 3.5s: Confirm understanding

Same purpose as the full flow's Step 5.1 — surface assumptions before finalizing.

**Present 5-10 bullet points** from the Key Assertions and Design Decisions. Since short flow has no verification agents, all assertion-sourced bullets are tagged `[unverified]`. For each design decision, include both the decision and its key alternative to surface trade-offs:

```
Before finalizing this plan, here is my understanding of the key assumptions:

- [unverified] <claim from Key Assertions> → Context: Key Assertions
- <decision statement> (over <rejected alternative>) → Design Decision: D1: <title>
...

Does this match your understanding? Any corrections?
```

**Gate:** Do not proceed to Step 3.7s until the user explicitly confirms or provides corrections. If corrections are needed, revise the affected plan sections (same approach as the full flow's Step 5.2) and re-present the corrected bullets.

### Step 3.7s: Task review

Same purpose as the full flow's Step 5.3 — validate the implementation approach before finalizing. Use the same phase summary format (objective, mechanism, scope, task count) as described in Step 5.3.

1. **Synthesize phase summaries from plan.md** — for each phase, produce a summary block with objective, mechanism, scope, and task count. The mechanism descriptions come from the plan's task content — synthesize them from existing context without additional file reads.

2. **Present the phase summaries** to the user. End with:
   ```
   Review the phases above. Approve to proceed, or request changes.
   ```

3. **Wait for explicit approval.** Do not proceed to Step 4s until the user explicitly approves. This gate is not skippable.

4. **If the user requests changes** — revise the affected phases in `plan.md`, then re-present only the changed phase summaries. Repeat until the user approves.

5. **If the user needs new investigation** — suggest re-running `/spec` rather than patching the plan ad-hoc.

### Step 4s: Finalize

**Prerequisite:** The task review gate (Step 3.7s) must be explicitly approved before finalization proceeds.

1. Incorporate user feedback
2. Generate `tasks.json` — after `plan.md` is finalized, run:
   ```bash
   lore work regen-tasks <slug>
   ```
   This pre-computes TaskCreate payloads so `/work tasks` and `/implement` can load them directly without re-parsing `plan.md`.
3. Run `lore work heal`
4. Suggest retrospective: `Consider /retro <slug> to evaluate knowledge system effectiveness for this spec.`

---

## Full Flow (`/spec`)

Team-based divide-and-conquer for complex or uncertain-scope work.

### Step 2: Decompose into investigations

1. From the feature description, identify 3-7 focused investigation questions. Each should:
   - Target a specific part of the codebase or concern
   - Be answerable by exploring files (not by asking the user)
   - Be independent enough to run in parallel
2. Check the knowledge store index for file hints to include with each investigation
3. **Assess complexity** for each investigation using these heuristics:
   - **simple** — 1-2 key files, narrow question targeting a single function or module
   - **moderate** — 3-5 key files, or a multi-part question spanning related modules
   - **complex** — 6+ key files, or a cross-cutting concern (e.g., touches config, runtime, and tests)
4. Present the investigation plan to the user as a structured preview table:
   ```
   ## Investigation Plan

   | # | Area / Topic | Key Files | Complexity |
   |---|-------------|-----------|------------|
   | 1 | <topic>     | `file1`, `file2` | simple |
   | 2 | <topic>     | `file1`, `file2`, `file3` | moderate |
   | 3 | <topic>     | `file1`, ... `file6` | complex |
   ...

   Proceed, or adjust? (You can request changes — e.g., split a question, drop an area, add a new one, or change scope.)
   ```
5. Wait for user confirmation before dispatching. If the user requests adjustments (freeform text), revise the table and re-present it. Repeat until approved.

**Example** — for a "add rate limiting to the API" spec:
```
## Investigation Plan

| # | Area / Topic | Key Files | Complexity |
|---|-------------|-----------|------------|
| 1 | Current middleware chain | `src/middleware/index.ts`, `src/app.ts` | simple |
| 2 | Auth + session handling | `src/auth/session.ts`, `src/auth/middleware.ts`, `src/types/auth.ts` | moderate |
| 3 | Request lifecycle & error paths | `src/handlers/`, `src/errors/`, `src/middleware/`, `src/logging/`, `tests/integration/` | complex |
| 4 | Existing config & env patterns | `src/config.ts`, `src/env.ts` | simple |

Proceed, or adjust? (You can request changes — e.g., split a question, drop an area, add a new one, or change scope.)
```

### Step 3: Create investigation team

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

4. **Pre-fetch knowledge for each investigation** — before constructing prompts, run:
   ```bash
   PRIOR_KNOWLEDGE=$(lore prefetch "<investigation topic>" --format prompt --limit 5)
   ```
   This produces a "## Prior Knowledge" block with pre-resolved content from the knowledge store.

5. **Spawn researcher agents** — launch `min(investigation_count, 4)` in a single message. Use the **researcher** agent definition (`~/.claude/agents/researcher.md`) as the base prompt, with these template injections:
   - `{{team_name}}` → `spec-<slug>`
   - `{{team_lead}}` → the lead name read from team config in Step 3.2
   - `{{prior_knowledge}}` → the `$PRIOR_KNOWLEDGE` block from Step 3.4

   ```
   Task:
     subagent_type: "Explore"
     model: "sonnet"
     team_name: "spec-<slug>"
     name: "researcher-N"
     prompt: |
       <contents of ~/.claude/agents/researcher.md with {{template}} variables resolved>
   ```

   If more questions than researchers, agents pick up additional tasks after completing their first.

### Step 4: Collect and document findings

As researcher messages arrive (delivered automatically):
1. Write each finding to the `## Investigations` section of `plan.md`
2. Use the investigation entry format from the template below
3. **Preserve `**Assertions:**` verbatim** — copy researcher assertions exactly as reported. Do not rephrase, merge, or summarize them. These are falsifiable claims that downstream verification will test against the code.

When all investigation tasks are complete:
1. Send shutdown requests to all researchers via `SendMessage` (type: `shutdown_request`)
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

### Step 5: Synthesize

From the documented findings, draft the remaining plan sections:
1. **Goal** — what we're building/changing and why (1 paragraph)
2. **Design Decisions** — use the `### DN: Title` format from the template. Each decision requires `**Decision:**`, `**Rationale:**`, `**Alternatives considered:**`, and `**Applies to:**` fields. Number decisions sequentially (D1, D2, ...).
3. **Phases** — concrete implementation phases with tasks, file paths, objectives. For each phase, include a `**Knowledge context:**` block listing knowledge entries relevant to that phase — these flow directly to worker agents via task generation. For multi-worker phases or novel implementations without codebase precedent, add `**Knowledge delivery:** full` to deliver fully resolved knowledge content to workers instead of annotation-only summaries.

   **Advisor identification:** When investigations reveal domain complexity in a phase — unfamiliar invariants, cross-cutting constraints, or areas where uninformed changes risk breaking correctness — add an `**Advisors:**` block declaring domain-expert advisors for that phase. Use the format: `- advisor-name — domain scope. [must-consult|on-demand]`. Use `must-consult` when the domain has hard invariants that workers must respect (e.g., auth, data migration); use `on-demand` when the domain is complex but workers can start independently and ask questions as needed. `/implement` spawns declared advisors as persistent team members with investigation findings as their domain baseline.

   **Task consolidation rule:** Each `- [ ]` checkbox should be a meaningful unit of work, not a micro-edit. Multiple sequential edits to the same file should be one task (e.g., "Update worker prompt to add capture step and renumber" not three separate tasks for delete/insert/renumber). Aim for 2-5 tasks per phase. If a phase has >5 tasks, look for consolidation opportunities.

4. **Concordance-assisted annotation** — after drafting phases, widen each phase's `**Knowledge context:**` block beyond what investigations explicitly mentioned. For each phase, run:
   ```bash
   lore prefetch "<phase objective> <key file paths>" --type knowledge --limit 5
   ```
   Review the suggestions against what is already listed. Add relevant entries as `[[knowledge:...]]` backlinks with a brief "— why relevant" annotation. Skip entries that duplicate what investigations already covered. Investigation findings are the primary source of knowledge references — concordance is a *widener*, not a replacement.

5. **Open Questions** — anything investigations couldn't resolve

Present the synthesized plan to the user for review.

### Step 5.1: Confirm understanding

Before finalizing, present a concise understanding summary for the user to validate. This surfaces the assumptions and claims the plan is built on so the user can catch misunderstandings before they propagate to implementation.

**Present 5-10 bullet points covering:**
- Key assumptions about the codebase architecture
- Behavioral claims from verified assertions (mark with `[verified]`) or unverified researcher claims (mark with `[unverified]`)
- Design decisions with their key rejected alternative — surfacing what was chosen *over what* makes trade-offs explicit
- Scope boundaries — what is and is not included

**Traceability:** Each bullet must trace to a specific source. Use `→` to link the claim to its origin:
- Assertion-sourced bullets: trace to the investigation topic and verification verdict
- Design decision bullets: trace to the Design Decisions section entry by DN identifier (e.g., `D1: <title>`)
- Scope bullets: trace to the Goal or user input that established the boundary

**Format:**
```
Before finalizing this plan, here is my understanding of the key assumptions:

- [verified] <claim> → Investigation: <topic>, Assertion #N
- [unverified] <claim> → Investigation: <topic>, Assertion #N
- <decision statement> (over <rejected alternative>) → Design Decision: D1: <title>
- <scope boundary> → Goal / user input
...

Does this match your understanding? Any corrections?
```

**Gate:** Do not proceed to Step 5.3 until the user explicitly confirms or provides corrections. If the user identifies incorrect points, go to Step 5.2 (handle corrections) before continuing. The prompt "Does this match your understanding? Any corrections?" is not rhetorical — wait for a response.

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

3. **Wait for explicit approval.** Do not proceed to Step 5.4 until the user explicitly approves (e.g., "approved", "looks good", "proceed"). This gate is not skippable.

4. **If the user requests changes** — revise the affected phases in `plan.md`, then re-present only the changed phase summaries. Repeat steps 2-3 until the user approves.

5. **If the user needs new investigation** — the task review is bounded to what the existing findings support. If the user identifies gaps that require exploring new code or revisiting assumptions, suggest re-running `/spec` rather than patching the plan ad-hoc:
   ```
   This change requires new investigation beyond the current findings.
   Consider re-running `/spec <slug>` to explore this area.
   ```

### Step 5.4: Post-research extraction

Invoke `/remember` scoped to the spec investigation:

```
/remember Research findings from <work item title> — Evaluate researcher-reported **Observations:** from investigation reports against the capture gate (reusable, non-obvious, stable, high-confidence). Capture architectural insights and gotchas discovered during research. Skip: findings already documented in plan.md (they're persisted there).
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
**Knowledge delivery:** full  <!-- optional — omit for default annotation-only delivery (~50-200 tokens per backlink). Use `full` for: (1) multi-worker phases where cross-worker consistency matters (all workers need the same reference content), or (2) novel implementations without codebase precedent (no existing patterns to anchor against). Full resolution costs ~2k-4k tokens per task. -->
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
- Check if synthesis (Design/Phases) is complete; if not, synthesize from existing findings
- Check Open Questions — dispatch follow-up investigations for unresolved items
- Present current state and ask what needs refinement
