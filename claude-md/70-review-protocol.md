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

### Severity Classification

Every review finding MUST be assigned exactly one severity level. These definitions are the single source of truth — individual lens and review skills reference this section rather than defining their own taxonomy.

#### Levels

- **blocking** — The PR must not merge with this issue unresolved. Use for: correctness bugs, security vulnerabilities, data loss risks, broken invariants, API contract violations. The bar is "this will cause a defect or incident if shipped."
- **suggestion** — The PR should address this but it is not a merge blocker. Use for: design improvements, convention violations, missing edge case handling, suboptimal patterns, maintainability concerns. The bar is "the code works but could be meaningfully better."
- **question** — The reviewer cannot assess correctness without additional information from the author. Use for: unclear intent, ambiguous behavior, missing context on why an approach was chosen. The bar is "I need to understand this before I can evaluate it."

#### Classification rules

1. **Default to suggestion.** When uncertain between blocking and suggestion, choose suggestion. Overcalling blocking erodes trust and slows velocity.
2. **Questions are not soft suggestions.** A question means the reviewer genuinely does not know the answer. If you know the answer and think the code should change, that is a suggestion or blocking finding, not a question.
3. **Severity is independent of effort.** A one-line fix can be blocking (security). A large refactor can be a suggestion (design improvement). Classify by impact, not by size of the required change.

#### Relationship to Conventional Comments labels

Existing review skills (`/pr-review`, `/pr-self-review`, `/pr-pair-review`, `/pr-revise`) use the full Conventional Comments label set (`suggestion`, `issue`, `question`, `thought`, `nitpick`, `praise`). The severity levels above are a simplified taxonomy for lens skills that produce structured findings. The mapping:

| Severity    | Conventional Comments equivalents        |
|-------------|------------------------------------------|
| blocking    | issue (when merge-blocking)              |
| suggestion  | suggestion, issue (non-blocking), thought |
| question    | question                                 |
| (not used)  | nitpick, praise                          |

Lens skills do not produce nitpick or praise findings — those are conversational labels suited to interactive review, not structured analysis output.

### Findings Output Format

Lens skills produce structured JSON findings that can be consumed by `post-review.sh`, written to work items, or presented to the user. This schema is the contract between lens skills and downstream consumers.

#### Schema

```json
{
  "lens": "<lens-name>",
  "pr": <pr-number>,
  "repo": "<owner>/<repo>",
  "findings": [
    {
      "severity": "blocking | suggestion | question",
      "title": "Short description of the finding",
      "file": "path/to/file.ext",
      "line": 42,
      "body": "Detailed explanation of the finding. May include markdown formatting.",
      "knowledge_context": [
        "entry-title — one-line relevance summary"
      ]
    }
  ]
}
```

#### Field definitions

- **lens** — Identifier for the lens that produced the findings. One of: `correctness`, `regressions`, `thematic`, `blast-radius`, `test-quality`.
- **pr** — The PR number (integer).
- **repo** — Repository in `owner/repo` format. Derived from the current git remote.
- **findings** — Array of finding objects. Empty array `[]` when the lens finds no issues.
- **severity** — One of the three levels defined in the Severity Classification section above. All severity levels are substantive and require knowledge enrichment.
- **title** — A concise summary (under 80 characters) suitable for use as a review comment heading.
- **file** — Path relative to repository root. Required for inline PR comments. Omit only for PR-level (non-file-specific) findings.
- **line** — Line number in the diff where the finding applies. Required for inline comments. Omit for file-level or PR-level findings.
- **body** — Full explanation. Should include: what the issue is, why it matters, and (for suggestions) what to do about it. Markdown formatting allowed.
- **knowledge_context** — Array of knowledge store entries cited during enrichment. Each entry is a string in the format `"entry-title — relevance summary"`. Empty array `[]` when no relevant knowledge was found.

#### Validation rules

1. **At least `lens`, `pr`, `repo`, and `findings` are required** at the top level.
2. **Each finding must have `severity`, `title`, and `body`.** The `file` and `line` fields are required for inline comments but may be omitted for PR-level findings.
3. **`knowledge_context` must always be present** (empty array if no knowledge was found). This makes enrichment compliance auditable — a missing field is distinguishable from an empty result.
4. **Severity values must be exactly one of `blocking`, `suggestion`, or `question`.** No other values are accepted.

#### Output location

Each lens writes its findings JSON to the shared work item at `pr-lens-review-<PR>/notes.md` under a heading for that lens. The JSON is embedded in a fenced code block:

````
## Correctness Lens

```json
{ "lens": "correctness", "pr": 42, ... }
```
````

This structure allows multiple lenses to append findings to the same work item, and allows `post-review.sh` to extract and merge findings from all lenses.

### Lens Review Workflow

The lens review system provides focused, single-concern analysis of PRs. Each lens skill examines the PR through one analytical perspective and produces structured findings. This complements the 8-point agent-code checklist in `/pr-review` — lenses are deeper and narrower, the checklist is broader and agent-specific.

#### Available lenses

| Skill | Lens ID | Focus |
|-------|---------|-------|
| `/pr-correctness` | `correctness` | Logic paths, boundary conditions, error handling, intent alignment |
| `/pr-regressions` | `regressions` | Deletions, removed capabilities, behavioral narrowing |
| `/pr-thematic` | `thematic` | Scope coherence, scope creep, missing pieces |
| `/pr-blast-radius` | `blast-radius` | Impact on code outside the diff — consumers, callers, dependents |
| `/pr-test-quality` | `test-quality` | Test coverage, tautological tests, assertion quality, edge cases |

#### Phase 1: Run lenses

Run one or more lens skills against a PR. Each lens can be invoked independently:

```
/pr-correctness 42
/pr-regressions 42
/pr-blast-radius 42
```

Each lens fetches the PR data, applies its methodology, enriches findings with the knowledge store, and writes structured JSON to a shared work item at `pr-lens-review-<PR_NUMBER>/notes.md`. Multiple lenses append to the same work item under separate headings (`## Correctness Lens`, `## Regressions Lens`, etc.).

Lenses can be run in any order and in separate sessions. The work item accumulates findings across runs.

#### Phase 2: Review and post

After running the desired lenses, review the accumulated findings in the work item:

```
/work show pr-lens-review-42
```

When ready to post findings to GitHub as a batched review submission:

```bash
bash ~/.lore/scripts/post-review.sh <findings.json> --pr 42 [--dry-run]
```

The `--dry-run` flag previews the review without posting. `post-review.sh` accepts either a single lens findings object or an array of multiple lens outputs. It determines the review state automatically:
- Any `blocking` finding: `REQUEST_CHANGES`
- Only `suggestion`/`question` findings: `COMMENT`
- No findings: `APPROVE`

Inline comments are placed at the specific file and line. PR-level findings (without file/line) are included in the review body.

#### When to use lenses vs. /pr-review

- **`/pr-review`** — Interactive, conversational review using the 8-point agent-code checklist. Best for: comprehensive review of agent-generated code, iterative review with the author, reviews that need the full breadth of the checklist.
- **Lens skills** — Structured, single-concern analysis producing machine-readable findings. Best for: deep-dive analysis of specific concerns, automated review pipelines, accumulating findings across sessions, posting batched reviews.

The two approaches can be combined: run lenses for targeted analysis, then use `/pr-review` for broader evaluation.

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
