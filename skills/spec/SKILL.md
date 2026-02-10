---
name: spec
description: "Create a technical specification — `/spec short` for single-pass plans, `/spec` for full team-based investigation"
user_invocable: true
argument_description: "[short] [name or description] — existing work item name, or a freeform description to start from"
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

1. Parse arguments: if first arg after `/spec` is `short`, use **Short Flow**; otherwise **Full Flow**. The remaining text is the **input**.
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

### Step 2s: Read key context

1. From conversation context and the work item, identify 3-8 key files to read
1b. Search the knowledge store: `lore search "<topic>" --type knowledge --json --limit 5`. Read any relevant entries to avoid re-discovering known patterns.
2. Check the knowledge store (`lore index`, `_manifest.json`) for relevant domain files
3. Read the files yourself — do NOT spawn subagents
4. Note key findings as you go

### Step 3s: Draft plan

1. Write `plan.md` using the **plan template** below
2. Use `## Context` instead of `## Investigations`: 3-6 bullet points summarizing key files read, constraints found, and relevant patterns
3. Fill in Goal, Design Decisions (with `**Applies to:**` fields mapping each decision to affected phases), Phases (with `**Knowledge context:**` blocks listing relevant knowledge entries per phase), Open Questions

   Apply the task consolidation rule: each checkbox = one meaningful unit of work. Consolidate sequential same-file edits.

4. Present to user for review

### Step 4s: Finalize

1. Incorporate user feedback
2. Generate `tasks.json` — after `plan.md` is finalized, run:
   ```bash
   lore work regen-tasks <slug>
   ```
   This pre-computes TaskCreate payloads so `/work tasks` and `/implement` can load them directly without re-parsing `plan.md`.
3. Run `lore work heal`

---

## Full Flow (`/spec`)

Team-based divide-and-conquer for complex or uncertain-scope work.

### Step 2: Decompose into investigations

1. From the feature description, identify 3-7 focused investigation questions. Each should:
   - Target a specific part of the codebase or concern
   - Be answerable by exploring files (not by asking the user)
   - Be independent enough to run in parallel
2. Check the knowledge store index for file hints to include with each investigation
3. Present the investigation plan to the user:
   ```
   I'll investigate these areas in parallel:
   1. <Question 1> — will look at <file hints>
   2. <Question 2> — will look at <file hints>
   ...
   Proceed, or adjust?
   ```
4. Wait for user confirmation before dispatching

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

5. **Spawn researcher agents** — launch `min(investigation_count, 4)` in a single message for parallelism:
   ```
   Task:
     subagent_type: "Explore"
     model: "sonnet"
     team_name: "spec-<slug>"
     name: "researcher-N"
     prompt: |
       You are a researcher on the spec-<slug> team.

       <embed $PRIOR_KNOWLEDGE here — the pre-fetched knowledge block>

       If the pre-loaded knowledge doesn't cover your specific area, also search:
       lore search "<query>" --type knowledge --json --limit 5

       1. Call TaskList to see available investigation tasks
       2. Claim one: TaskUpdate with owner=your name, status=in_progress
       3. Read the full task with TaskGet
       4. Investigate using Glob, Grep, Read, LSP
       5. Send findings to "<team-lead-name>" via SendMessage:
          summary: "Findings: <topic>"
          content: |
            **Question:** <the question>
            **Findings:**
            - <finding 1>
            - <finding 2>
            **Key files:** <paths>
            **Implications:** <1-2 sentences>
            **Architectural patterns:** <general observations about how the
              codebase works — type mappings, inheritance patterns,
              infrastructure conventions — even if not directly related to
              your investigation question. Always fill this section, even
              if "None observed.">
            **Unknowns:** <anything unresolved>
       6. **Update task description** with your full findings report:
          TaskUpdate with description set to the same content from step 5
          (including the **Architectural patterns:** section). This is required
          for the TaskCompleted hook to verify your report.
       7. **Capture findings:** Run `lore capture` for each architectural
          pattern you reported (skip only if "None observed"):
          ```
          lore capture --insight "<pattern>" --context "Discovered while investigating: <question summary>" --category "<best guess>" --confidence "medium" --source "worker"
          ```
       8. Mark task completed: TaskUpdate with status=completed
       9. Call TaskList — claim next unclaimed task if available
       10. When no tasks remain, you're done

       Keep findings to 500-1000 characters. Facts over opinions.
   ```

   If more questions than researchers, agents pick up additional tasks after completing their first.

### Step 4: Collect and document findings

As researcher messages arrive (delivered automatically):
1. Write each finding to the `## Investigations` section of `plan.md`
2. Use the investigation entry format from the template below

When all investigation tasks are complete:
1. Send shutdown requests to all researchers via `SendMessage` (type: `shutdown_request`)
2. Run `TeamDelete` to clean up the team

This is the critical persistence step — findings survive compaction, session boundaries, and context limits.

### Step 5: Synthesize

From the documented findings, draft the remaining plan sections:
1. **Goal** — what we're building/changing and why (1 paragraph)
2. **Design Decisions** — architectural choices with rationale from findings. Include an `**Applies to:**` field in each decision mapping it to affected phases (e.g., "Phase 1 (template update), Phase 3 (migration)")
3. **Phases** — concrete implementation phases with tasks, file paths, objectives. For each phase, include a `**Knowledge context:**` block listing knowledge entries relevant to that phase — these flow directly to worker agents via task generation

   **Task consolidation rule:** Each `- [ ]` checkbox should be a meaningful unit of work, not a micro-edit. Multiple sequential edits to the same file should be one task (e.g., "Update worker prompt to add capture step and renumber" not three separate tasks for delete/insert/renumber). Aim for 2-5 tasks per phase. If a phase has >5 tasks, look for consolidation opportunities.

4. **Open Questions** — anything investigations couldn't resolve

Present the synthesized plan to the user for review.

### Step 5b: Generate tasks.json

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

## Design Decisions
<!-- Key architectural choices with rationale. Each decision should include an **Applies to:** field mapping it to the affected phases/tasks. -->

## Phases

### Phase 1: <Name>
**Objective:** What this phase accomplishes
**Files:** relevant file paths
**Knowledge context:**
- [[knowledge:file#heading]] — why this is relevant to this phase
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
