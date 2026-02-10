## Review Protocol

Shared reference for all PR review skills (`/pr-review`, `/pr-self-review`, `/pr-pair-review`, `/pr-revise`). Skills reference this protocol rather than duplicating the checklist.

### Review Hierarchy

Reviews proceed top-down through three tiers. Higher tiers gate lower ones — an architectural problem makes logic-level comments premature.

1. **Architecture / Approach** — Is the overall design sound? Right abstraction boundaries? Proportional to the problem?
2. **Logic / Correctness** — Does it work? Edge cases handled? Invariants preserved across boundaries?
3. **Maintainability / Evolvability** — Will this be easy to change later? Conventions followed? No unnecessary coupling?

Style and formatting are automated (linters, formatters) and are never review topics.

### Review Selection

After fetching PR data, present reviews as batches grouped by reviewer. The user selects which batch to work through; other batches are deferred, not mixed in.

#### Presentation format

List each review submission as a selectable batch:

```
1. @reviewer-a (CHANGES_REQUESTED) — 5 inline comments, submitted 2025-06-10T14:32:00Z
2. @reviewer-b (APPROVED) — 2 inline comments, submitted 2025-06-10T16:05:00Z
3. Orphan comments — 3 comments (ungrouped, see below)
```

Each entry shows: reviewer login, review state, inline comment count, and submission timestamp. Order by submission time (earliest first).

#### Orphan comment grouping

Comments not attached to a review submission are grouped by time proximity. Comments posted within a ~5 minute window of each other are treated as a single batch. Comments outside that window are treated individually. Present orphan batches after named reviewer batches.

#### Selection behavior

- The user selects one or more batches by number (e.g., "1" or "1, 3").
- The selected batch becomes the working set for the current review pass.
- Unselected batches are noted as deferred — they can be revisited in a subsequent pass.
- If only one reviewer batch exists (plus any orphans), skip selection and work through it directly.

All consuming skills (`/pr-review`, `/pr-self-review`, `/pr-pair-review`, `/pr-revise`) reference this step after fetching PR data and before applying the review checklist or categorization logic.

### 8-Point Review Checklist

Each item targets a specific failure mode observed in agent-generated code. Apply every item to each changed file or logical unit.

#### 1. Semantic contract check
Does the code honor the *semantic* contract of the abstractions it uses, not just the syntactic interface?

**Failure mode:** Agent code frequently calls APIs correctly at the type level but violates implicit contracts — e.g., calling a function in the wrong lifecycle phase, passing technically-valid but semantically-wrong arguments, or misusing a data structure's intended access pattern.

#### 2. Cross-boundary invariant trace
What invariants does this change assume about code it does *not* modify? Are those assumptions still valid?

**Failure mode:** Changes that are locally correct but break because they depend on undocumented invariants in other modules — ordering assumptions, state preconditions, or implicit coupling that isn't visible in the diff.

#### 3. Convention match
Does this follow *this project's* patterns, or does it use generic/textbook patterns that diverge from established conventions?

**Failure mode:** Agent code gravitates toward common patterns from training data rather than matching the specific conventions of the codebase. This creates inconsistency even when the code is technically correct.

#### 4. Rationale probe
Can the "why" behind each design choice be articulated? If the rationale is "this is how it's usually done," that's a flag.

**Failure mode:** Cargo-culted patterns — code that exists because the agent reproduced a common pattern without understanding whether it applies here. Often manifests as unnecessary abstractions, premature generalization, or framework idioms in non-framework code.

#### 5. Adversarial path analysis
What happens with empty inputs, null values, out-of-order calls, duplicate invocations, or concurrent access?

**Failure mode:** Agent code tends to handle the happy path thoroughly but miss edge cases that a human developer would catch through experience — especially around empty collections, missing keys, and race conditions.

#### 6. Proportionality check
Is the solution proportional to the problem? Are there new abstractions with only one consumer? Layers that don't carry their weight?

**Failure mode:** Over-engineering. Agent code frequently introduces unnecessary indirection — wrapper classes, strategy patterns, factory methods — for problems that need a function and a conditional.

#### 7. Existing utility scan
Does this duplicate functionality that already exists in the codebase or its dependencies?

**Failure mode:** Agent code creates new helpers, utilities, or implementations for things that already exist. Limited codebase awareness means it doesn't find existing solutions, leading to redundant code and missed opportunities to reuse.

#### 8. Test assertion audit
Do tests verify the *requirements*, or do they just confirm the generated code's behavior?

**Failure mode:** Tautological tests — agent writes implementation then writes tests that pass by construction because they test what the code does rather than what it should do. These tests provide false confidence and don't catch regressions.

### Knowledge Enrichment Protocol

**This is mandatory, not optional.** When a checklist item surfaces a substantive finding (any finding labeled suggestion, issue, question, or thought), the reviewer MUST enrich it with knowledge store context before reporting. This is the primary defense against faster-path preference bypass — skipping enrichment is the most common way review quality degrades.

#### Enrichment procedure

For each substantive finding:

1. **Query the knowledge store:**
   ```bash
   lore search "<topic>" --type knowledge --json --limit 3
   ```
   Where `<topic>` is the specific concept, pattern, or component the finding concerns.

2. **Surface citations inline.** Include 1-3 compact knowledge citations with the finding. Format: `[knowledge: entry-title]` with a one-line summary of why it's relevant.

3. **Check for staleness.** If a knowledge entry is marked STALE and the PR contradicts it, flag as "convention may need updating" — not "PR is wrong." Stale entries reflect past understanding, not current truth.

#### Enrichment gate

- **Mandatory:** suggestion, issue, question, thought labels — any finding that asserts something about the codebase or proposes a change.
- **Skip:** nitpick, praise — findings that are purely stylistic or positive acknowledgment.

#### Output cap

Maximum 3 knowledge entries per enrichment beat. If more than 3 results are relevant, select the 3 most specific to the finding.

### Investigation Escalation

A conditional escalation path when knowledge enrichment alone is insufficient. Most enrichments resolve via the knowledge store — escalation is the exception, not the default.

#### Escalation gate (all three must be true)

1. **Substantive label** — the finding is labeled suggestion, issue, question, or thought.
2. **Insufficient knowledge results** — the knowledge store query returned no relevant entries, or returned entries that don't address the specific concern.
3. **Multi-file analysis needed** — the concern involves cross-boundary invariants, architectural patterns spanning multiple files, or dependencies that can't be verified from the diff alone.

#### Escalation procedure

When all three gate conditions are met:

1. **Prefetch knowledge for the agent prompt** — use the concern and scope files as query terms:
   ```bash
   PRIOR_KNOWLEDGE=$(lore prefetch "<concern> <scope files>" --format prompt --limit 3)
   ```
   For example, if the concern is "cross-boundary state mutation" and scope is `scripts/pk_search.py scripts/pk_cli.py`, the query would be `"cross-boundary state mutation pk_search.py pk_cli.py"`.

2. **Spawn an Explore agent** with the prefetched context embedded:
   ```
   Task: Investigate whether [specific concern] holds.
   Scope: [list of files/directories to examine]
   Question: [precise question to answer]

   ## Prior Knowledge
   <embed $PRIOR_KNOWLEDGE here — omit section if prefetch returned empty>

   If the above context doesn't cover your area, search:
   ```bash
   lore search "<query>" --type knowledge --json --limit 3
   ```

   Report: Return findings as structured observations — confirmed/refuted/uncertain with evidence.
   ```

The Explore agent traces invariants, reads related files, and scans for patterns that the knowledge store doesn't cover. The prefetched knowledge gives it project-specific context without requiring it to search voluntarily. Its findings are incorporated into the review finding before reporting.

#### Escalation budget

Maximum 2 investigation escalations per review. If more than 2 findings require escalation, prioritize by tier (architecture > logic > maintainability) and severity.
