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
Sequential numbered steps that execute a workflow. Used for skills that perform a multi-step process (implement, spec, remember, bootstrap, renormalize).

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

### Dispatch Guidance Floor

Immediately before each ordinary agent launch attempt, run `lore dispatch guidance`. If rendering fails, stop before launch. Prepend that invocation's complete output verbatim to the prompt, ahead of prior knowledge and task-specific context, and render again for every retry. A canonical generated directive is the sole exception: when its publisher already rendered and validated the block, recorded its stable identity, and placed it in the directive payload, each launch consumes that payload block verbatim instead of rendering a second source. Never cache guidance ad hoc or batch-wide, and never copy its generated contents into skill prose. The block supplies standing guidance without changing the selected model, role, concurrency, or report contract.

The claude-code admission gate is a self-healing backstop for launches outside any protocol: when a launch prompt carries no trace of a guidance block, the hook renders a fresh block and injects it before the tool runs, so ad-hoc dispatch proceeds without ritual. This does not loosen the convention for protocol seats — a prompt that carries guidance markers is validated strictly, and a tampered, duplicated, truncated, or stale block still denies the launch. Protocols keep rendering at their own seams; the gate only supplies the floor where no seam exists.

The guidance block never names a model, but the gate supplies one. A launch that states no model inherits the tier of the session that spawned it, so a small fan-out dispatched from an expensive seat bills at that seat's rate and leaves nothing in the record to show the tier was never chosen. When a claude-code launch arrives without a model, the hook fills in the settings-resolved default for the harness before the tool runs; a launch that states a model keeps exactly what it stated. If no default resolves, the launch is denied rather than allowed to inherit — the same fail-closed posture the gate takes when guidance cannot be rendered. State the model you want at the launch and the gate stays out of the way.

### Knowledge in Worker Prompts
Embed pre-fetched knowledge under a `## Prior Knowledge` header. This applies to both:
- **Prefetch-based** (spec, bootstrap): output of `lore prefetch` embedded in the Task prompt
- **Pre-resolved** (implement): backlinks resolved by `generate-tasks.py` into task descriptions

The header is `## Prior Knowledge` in both cases. Workers see a consistent section name regardless of how the knowledge was sourced.

### Worker Observation Field
Workers report findings non-obvious to a future agent doing similar work in their completion message using:
```
**Observations:** <anything surprising, non-obvious to a future agent doing similar work, or that contradicts expectations from sources a future agent loads before raw exploration>
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

**Documented exception:** `/bootstrap` uses `lore batch-capture` with a JSON file instead of direct `lore capture` calls because it produces structured domain entries from parallel exploration, not conversation-derived insights. Workers write entries to a shared JSON file; the lead invokes `lore batch-capture` in the synthesis step to ingest all entries at once, skipping manifest updates until the final pass.

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

Not all skills need resume. Single-session skills (e.g., remember) omit it.

## Review Skill Family

Skills with the `pr-` prefix operate on pull requests. `/pr-review` is the integrated multi-lens review; its `--self` mode runs the same pipeline as an author's self-review of their own PR. The focused lens skills (`/pr-correctness`, `/pr-security`, `/pr-blast-radius`, `/pr-regressions`, `/pr-test-quality`, `/pr-interface-clarity`, `/pr-thematic`, `/pr-user-impact`) each apply a single concern and double as the methodology sources `/pr-review` embeds in its lens agents. `/pr-create` authors the PR itself. (`/pr-revise` and `/pr-pair-review` are archived; `/pr-self-review` was folded into `/pr-review` as its `--self` mode.)

### Naming

All review skills use the `pr-` prefix. The prefix groups them visually in skill listings and signals that they operate on pull requests.

### Shared PR Fetch

All review skills use `scripts/fetch-pr-data.sh` for GraphQL data retrieval — no inline queries. The script encapsulates the single-query approach (reviewThreads + reviews + general comments in one call) so query changes propagate to all skills automatically.

### Shared Protocol Files

Behavioral rules shared across the family — risk triage, severity and materiality, cross-lens synthesis, enrichment, escalation, findings format, review voice — live in `claude-md/review-protocol/` and are read at invocation time, not duplicated into SKILL.md files. Each skill `cat`s only the sections it needs.

### Knowledge Enrichment

All review skills enrich substantive findings with context from the knowledge store before reporting them, per `claude-md/review-protocol/enrichment.md`. Cross-boundary concerns (findings that touch multiple subsystems or contradict known conventions) trigger conditional investigation escalation — deeper exploration before concluding.

### Capture Convention

All review skills end with `/remember` using review-scoped constraints. The key difference from standard capture: insights from external reviewers use `confidence: medium` (not `high`) because reviewer observations haven't been verified against codebase internals. The `/remember` invocation includes explicit skip criteria for style preferences, naming opinions, and subjective taste.

### Output Convention

All review skills are analysis-only — they produce findings, not source changes. The output surface differs by audience:

- `/pr-review` (standard) — a followup report for the reviewer's TUI triage, plus a curated subset of findings proposed as GitHub review comments; the reviewer selects what posts.
- `/pr-review --self` — a followup with a `lens-findings.json` sidecar for TUI triage; nothing is proposed for posting, and work-item creation is deferred to the user's promote action.
- Focused lens skills — structured findings presented to the invoking context (a user session or a `/pr-review` lens agent).

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

Reference protocol files by their paths under `claude-md/review-protocol/` (e.g., `claude-md/review-protocol/checklist.md`). Each skill reads only the section files it needs via selective `cat` commands, reducing token footprint.

## Protocol Mutation Chains

Skill prose, the executable behavior it describes, and the contract tests that pin that behavior form one mutation chain: they change together. Style, compression, and reorganization ride with the semantic change they explain; a standalone prose pass restates a contract nobody re-verified, and that is where drift starts.

When a skill consumes a published reader, evolve that reader inside its existing command namespace and update its contract test in the same change. Add a sibling reader only when the substrate has no canonical read surface; replacing a reader requires retiring the old surface in the same change, so consumers never face two plausible authorities.

Enforce the chain mechanically only where the repository owns a narrow, mechanically classifiable seam — `scripts/check-retro-seam-drift.sh` does this for the retro readers and `skills/retro/SKILL.md`, rejecting unpaired reader changes and standalone prose passes. The checker and the reader contract suite run two ways: on demand as `lore test seams` (checker over `origin/main..HEAD` plus `tests/frameworks/retro_prepare.bats` and the checker's own tests), and mechanically on every push via the versioned `githooks/pre-push` hook — activate once per clone with `git config core.hooksPath githooks`. Skills outside such a seam keep their sanctioned prose-only channels (owner directives, seat calibrations); a local coupling rule is not a global ban on those channels.

## Intentional Differences

These are deliberate design choices, not inconsistencies:

- **Routing-table vs procedural** — different skill types for different purposes.
- **Pre-resolved vs prefetched knowledge** — implement pre-resolves backlinks at task generation time (optimization for well-authored plans); spec/bootstrap prefetch at spawn time (appropriate for discovery-oriented work). Both use the `## Prior Knowledge` header.
- **Bootstrap batch capture** — documented exception to the `/remember` delegation rule; uses `lore batch-capture` with a JSON file instead of per-entry `lore capture` calls.
- **Skill-specific agent types** — spec uses `Explore` agents (read-only research); implement uses `general-purpose` agents (need edit/write for implementation).
- **Review output surfaces** — standard `/pr-review` proposes GitHub comments because the PR is someone else's: findings must cross to its author. `--self` mode proposes none because author and reviewer are the same person; its findings land in TUI triage instead.
