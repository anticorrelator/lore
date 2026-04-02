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
| `/pr-security` | `security` | Input validation, injection, auth/authz boundaries, cryptographic misuse, secrets exposure |
| `/pr-interface-clarity` | `interface-clarity` | Function signatures, naming, return types, parameter design, contract explicitness |
| (ceremony) | User-registered via `lore ceremony add pr-review` | Varies |

#### Ceremony Lens Registration

Users can register external skills as ceremony lenses that run alongside the built-in set during PR review.

**Registration:**

```bash
lore ceremony add pr-review <skill-name>
```

For example, `lore ceremony add pr-review insecure-defaults` registers the `/insecure-defaults` skill as a ceremony lens for PR reviews. To list registered lenses:

```bash
lore ceremony get pr-review
```

**Invocation contract:**

Ceremony lenses receive the PR number as their sole argument (e.g., `/<skill-name> <PR_NUMBER>`). They are responsible for fetching their own PR data — the orchestrator does not pass diff content, review context, or metadata.

**Two-tier output handling:**

Ceremony lens output is classified into one of two tiers based on format:

1. **Conforming** — Output matches the Findings Output Format (structured JSON with `lens`, `pr`, `repo`, `findings` fields). Conforming output participates fully in cross-lens synthesis: findings are grouped, deduplicated, severity-elevated, and merged alongside built-in lens results.
2. **Non-conforming** — Output does not match the Findings Output Format. Non-conforming output is preserved verbatim in a Supplementary Reports section appended after the synthesized findings. It is presented to the user but does not participate in synthesis.

This two-tier model allows ceremony lenses to provide value regardless of whether they implement the findings schema. Skills that want their findings to influence the review verdict and synthesis should emit conforming JSON; skills that produce prose reports or alternative formats are still included as supplementary context.

#### Adaptive Lens Selection

After the thematic pass, the lead agent selects lenses based on the criteria table below. This is a lookup — the agent matches PR signals against the table, not a reasoning task performed from scratch.

**Selection modes:**

- **Default** — Correctness + Regressions + Test Quality + Interface Clarity. Applied when no flags override.
- **`--thorough`** — All lenses. No signal matching; every lens runs.

**Criteria table:**

| Lens | Trigger signals (select when ANY present) | Skip conditions (skip when ALL true) |
|------|-------------------------------------------|---------------------------------------|
| Correctness | Logic changes, business rules, algorithm modifications, API interactions, new control flow | — (always selected in default mode) |
| Security | Auth/authz changes, input validation, external API calls, database queries, cryptographic code, secrets handling, user-facing endpoints | No auth/input/crypto/secrets code touched AND not high-risk tier |
| Blast Radius | Changes to exported interfaces, shared utilities, base classes, public APIs, configuration files | All changes are internal to a single module with no external consumers |
| Regressions | Modifications to existing behavior, deletions, refactoring of working code, signature changes | All changes are net-new additions with no modifications to existing code |
| Test Quality | Test files changed, new features without accompanying tests, modified behavior without test updates | No test files in diff AND all behavioral changes have existing test coverage |
| Interface Clarity | — (always selected in default mode) | — (always selected in default mode) |

**After selection, present the proposed lens set to the user for confirmation before any lens work begins.**

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

#### Integration: choosing your entry point

Two entry points serve different needs. Choose one — do not mix them in the same review pass.

**Holistic review — `/pr-review`**
Use when you want comprehensive, multi-lens coverage of a PR. `/pr-review` runs the full pipeline: triage, thematic anchor, adaptive lens selection, parallel lens execution, cross-lens synthesis, and presentation. This is the default for most PRs.

```
/pr-review 42              # standard holistic review
/pr-review 42 --thorough   # all lenses, no signal matching
/pr-review 42 --self       # self-review mode (adds perspective lenses)
```

**Focused single-concern — individual lens skill**
Use when you have a specific concern and want targeted analysis without the full pipeline. Invoke one lens directly. The lens fetches PR data, applies its methodology, enriches findings, and writes structured output to the work item.

```
/pr-correctness 42     # only logic/correctness analysis
/pr-security 42        # only security analysis
/pr-blast-radius 42    # only impact analysis
```

Focused lens runs are independent — they can be run in any order, across sessions, and their findings accumulate in the shared work item. Use `post-review.sh` to post accumulated findings when ready.

**When to use which:**

| Scenario | Entry point | Why |
|----------|------------|-----|
| General PR review | `/pr-review` | Full coverage with cross-lens synthesis |
| "Is this change safe to ship?" | `/pr-review` | Needs multiple perspectives + verdict |
| "Does this break callers?" | `/pr-blast-radius` | Single concern, no synthesis needed |
| Security-focused audit | `/pr-security` | Deep single-lens analysis |
| Incremental review (already ran some lenses) | Individual lens | Add missing lens to existing work item |
| CI/automated pipeline | Individual lens(es) | Predictable scope, machine-readable output |

