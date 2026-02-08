# Skill Authoring Conventions

Canonical reference for writing and maintaining lore skills. All skills in `skills/` should follow these conventions.

## Metadata Block

YAML frontmatter between `---` delimiters at the top of `SKILL.md`.

**Required fields:**
- `name` — skill name (lowercase, hyphenated). Matches the directory name.
- `description` — one-line description, quoted string.
- `user_invocable` — `true` if the user can invoke it directly with `/<name>`.
- `argument_description` — describes accepted arguments. Use underscores, not hyphens.

**Optional fields (omit unless needed):**
- `allowed-tools` — whitelist of tools the skill can use. **Omit by default** — omission means all tools are available. Only declare when restricting tool access.
- `disable-model-invocation` — `true` to prevent the model from invoking this skill autonomously. Default is `false`.

**Example:**
```yaml
---
name: my-skill
description: "Short description of what this skill does"
user_invocable: true
argument_description: "[arg1] [--flag value] — description of arguments"
---
```

## Title Heading

First line after the metadata block: `# /<skill-name> Skill`

Matches the invocation syntax. Examples: `# /implement Skill`, `# /spec Skill`, `# /work Skill`.

## Skill Types

### Procedural Skills
Sequential numbered steps that execute a workflow. Used for skills that perform a multi-step process (implement, spec, remember, bootstrap, self-test, renormalize).

### Routing-Table Skills
Command dispatch: match the first argument to a subcommand, execute the corresponding section. Used for skills that expose multiple independent operations (work, memory).

Structure: `## Route $ARGUMENTS` followed by `### <command>` sections.

## Step Numbering

Applies to procedural skills only.

- **Always 1-indexed.** Step 1 is the first step, even if it's setup/parsing.
- **Sub-steps** use dot notation: Step 3.1, Step 3.2. Or letter suffixes for closely related sub-steps: Step 5a, Step 5b.
- **Non-sequential sections** (resume logic, error handling) go after the main flow with named headers, not step numbers:
  - `## Resuming` or `## Resuming a <Skill> across sessions`
  - `## Error Handling`
  - `## Handling Partial Completion`

**Internal cross-references:** When a step references another step by number (e.g., "apply constraints from Step 1"), update these references whenever renumbering.

## Agent Spawning Pattern

For skills that create teams and spawn worker agents (implement, spec, bootstrap, renormalize).

### Team Lifecycle
1. **Create team before TaskCreate.** Tasks go into whichever task list is active. Creating tasks before the team puts them in the wrong list.
2. **Read team lead name** from the config file after team creation.
3. **Spawn workers** — launch `min(task_count, 4)` in a single message.
4. **Self-service pickup** — workers claim additional tasks after completing their first.
5. **Shutdown** — send `shutdown_request` to all workers, then `TeamDelete`.

### Knowledge in Worker Prompts
Embed pre-fetched knowledge under a `## Prior Knowledge` header. This applies to both:
- **Prefetch-based** (spec, bootstrap): output of `lore prefetch` embedded in the Task prompt
- **Pre-resolved** (implement): backlinks resolved by `generate-tasks.py` into task descriptions

The header is `## Prior Knowledge` in both cases. Workers see a consistent section name regardless of how the knowledge was sourced.

### Worker Observation Field
Workers report non-obvious findings in their completion message using:
```
**Observations:** <anything surprising, non-obvious, or that contradicts expectations>
```

### Worker Task Lifecycle
Standard workflow embedded in every worker prompt:
1. `TaskList` — see available tasks
2. `TaskUpdate` — claim with owner + in_progress
3. `TaskGet` — read full task description
4. Work — implement/investigate/explore
5. `SendMessage` — report to lead
6. `TaskUpdate` — update task description with report
7. `TaskUpdate` — mark completed
8. `TaskList` — claim next if available

## Capture Convention

Procedural skills that produce insights delegate capture to `/remember` with scoped constraints as a final step. This keeps capture logic centralized and consistent.

```
/remember <context> — <constraints describing what to capture and skip>
```

**Documented exception:** `/bootstrap` uses direct `lore capture` calls because it produces structured domain entries from parallel exploration, not conversation-derived insights. The lead handles deduplication in the synthesis and spot-check steps.

## Resume Pattern

Skills with cross-session state include a named section after the main flow:

```markdown
## Resuming [a <Skill>]

When `/<skill>` is called on existing state:
1. Detect existing state (work item, partial progress)
2. Display current status to user
3. Confirm scope before proceeding
4. Resume from last incomplete step
```

Not all skills need resume. Single-session skills (remember, self-test) omit it.

## Review Skill Family

Four skills share the `pr-` prefix and a common structure for PR analysis: `/pr-self-review`, `/pr-review`, `/pr-pair-review`, `/pr-revise`.

### Naming

All review skills use the `pr-` prefix. The prefix groups them visually in skill listings and signals that they operate on pull requests.

### Shared PR Fetch

All review skills use `scripts/fetch-pr-data.sh` for GraphQL data retrieval — no inline queries. The script encapsulates the single-query approach (reviewThreads + reviews + general comments in one call) so query changes propagate to all skills automatically.

### Checklist Embedding

All review skills embed the 8-item review checklist defined in `claude-md/70-review-protocol.md`. The checklist is referenced (read at invocation time), not duplicated into each SKILL.md. This ensures checklist updates apply uniformly.

### Knowledge Enrichment

All review skills implement mandatory knowledge enrichment for substantive findings: when a checklist item surfaces a non-trivial concern, the skill enriches the finding with context from the knowledge store and codebase before reporting it. Cross-boundary concerns (findings that touch multiple subsystems or contradict known conventions) trigger conditional investigation escalation — deeper exploration before concluding. The enrichment protocol is defined in `claude-md/70-review-protocol.md`.

### Capture Convention

All review skills end with `/remember` using review-scoped constraints. The key difference from standard capture: insights from external reviewers use `confidence: medium` (not `high`) because reviewer observations haven't been verified against codebase internals. The `/remember` invocation includes explicit skip criteria for style preferences, naming opinions, and subjective taste.

### Output Convention

All review skills produce work items as their primary output, but the type varies by skill:

- `/pr-self-review` — implement-ready work item (author can act on findings immediately)
- `/pr-revise` — implement-ready work item (feedback is already scoped to specific changes)
- `/pr-pair-review` — implement-ready or spec-ready work item (depends on finding complexity)
- `/pr-review` — posts GitHub comments + creates a documentation work item summarizing the review

All four are analysis-only — they produce plans and findings but do not modify source code.

## Investigation Escalation Pattern

Skills that query the knowledge store may encounter gaps — topics where no relevant entries exist but the concern requires multi-file analysis to resolve. The investigation escalation pattern provides a structured way to handle this.

**Escalation gate (all three must be true):**
1. The finding has a substantive label (not purely stylistic)
2. The knowledge store returned no relevant entries or insufficient entries
3. The concern involves cross-boundary invariants or multi-file analysis

**When the gate is met:** Spawn an Explore agent with a precise question, scoped file list, and structured return format (confirmed/refuted/uncertain with evidence).

**Budget:** Cap escalations per invocation (review skills use max 2). This prevents runaway exploration.

This pattern currently applies to the review skill family but generalizes to any skill that combines knowledge store queries with code analysis. If a future skill needs conditional deep investigation, follow this gate + budget structure.

## Shared Protocol References

Skills that share behavioral rules (checklists, enrichment procedures, labeling schemes) define those rules in `claude-md/` files and reference them at invocation time. This ensures:
- Updates to the protocol apply to all skills automatically
- SKILL.md files stay focused on workflow, not rule definitions
- No duplication drift between skills

Reference the protocol file by its path (e.g., `claude-md/70-review-protocol.md`). The file is assembled into the agent's context by the claude-md assembly pipeline, so skills can reference it either way.

## Intentional Differences

These are deliberate design choices, not inconsistencies:

- **Routing-table vs procedural** — different skill types for different purposes.
- **Pre-resolved vs prefetched knowledge** — implement pre-resolves backlinks at task generation time (optimization for well-authored plans); spec/bootstrap prefetch at spawn time (appropriate for discovery-oriented work). Both use the `## Prior Knowledge` header.
- **Bootstrap direct capture** — documented exception to the `/remember` delegation rule.
- **Skill-specific agent types** — spec uses `Explore` agents (read-only research); implement uses `general-purpose` agents (need edit/write for implementation).
- **Review skill output types** — `/pr-review` posts GitHub comments (external-facing); the other three produce only local work items. This reflects the audience: `/pr-review` is for someone else's PR, the others are for your own.
- **Review skill label sets** — `/pr-review` uses blocking/suggestion/question (maps to GitHub review states: REQUEST_CHANGES/COMMENT/COMMENT). The other three use full Conventional Comments labels (suggestion/issue/question/thought/nitpick/praise) because their output is local work items, not GitHub API submissions.
