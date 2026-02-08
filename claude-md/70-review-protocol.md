## Review Protocol

Shared reference for all PR review skills (`/pr-review`, `/pr-self-review`, `/pr-pair-review`, `/pr-revise`). Skills reference this protocol rather than duplicating the checklist.

### Review Hierarchy

Reviews proceed top-down through three tiers. Higher tiers gate lower ones — an architectural problem makes logic-level comments premature.

1. **Architecture / Approach** — Is the overall design sound? Right abstraction boundaries? Proportional to the problem?
2. **Logic / Correctness** — Does it work? Edge cases handled? Invariants preserved across boundaries?
3. **Maintainability / Evolvability** — Will this be easy to change later? Conventions followed? No unnecessary coupling?

Style and formatting are automated (linters, formatters) and are never review topics.

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

When all three gate conditions are met, spawn an Explore agent to investigate:

```
Task: Investigate whether [specific concern] holds.
Scope: [list of files/directories to examine]
Question: [precise question to answer]
Report: Return findings as structured observations — confirmed/refuted/uncertain with evidence.
```

The Explore agent traces invariants, reads related files, and scans for patterns that the knowledge store doesn't cover. Its findings are incorporated into the review finding before reporting.

#### Escalation budget

Maximum 2 investigation escalations per review. If more than 2 findings require escalation, prioritize by tier (architecture > logic > maintainability) and severity.
