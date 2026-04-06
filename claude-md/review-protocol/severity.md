### Severity Classification

Every review finding MUST be assigned exactly one severity level. These definitions are the single source of truth — individual lens and review skills reference this section rather than defining their own taxonomy.

#### Levels

- **blocking** — The PR must not merge with this issue unresolved. Use for: correctness bugs, security vulnerabilities, data loss risks, broken invariants, API contract violations. The bar is "this will cause a defect or incident if shipped." **Required grounding:** state the concrete failure scenario — what breaks, for whom, and under what conditions. A blocking finding without a described failure scenario is not actionable and must be downgraded to suggestion.
- **suggestion** — The PR should address this but it is not a merge blocker. Use for: design improvements, convention violations, missing edge case handling, suboptimal patterns, maintainability concerns. The bar is "the code works but could be meaningfully better." **Required grounding:** state the specific improvement and who benefits from it. A suggestion without a named improvement and beneficiary is a vague preference, not a review finding.
- **question** — The reviewer cannot assess correctness without additional information from the author. Use for: unclear intent, ambiguous behavior, missing context on why an approach was chosen. The bar is "I need to understand this before I can evaluate it." No grounding required beyond the question itself.

#### Classification rules

1. **Default to suggestion.** When uncertain between blocking and suggestion, choose suggestion. Overcalling blocking erodes trust and slows velocity.
2. **Questions are not soft suggestions.** A question means the reviewer genuinely does not know the answer. If you know the answer and think the code should change, that is a suggestion or blocking finding, not a question.
3. **Severity is independent of effort.** A one-line fix can be blocking (security). A large refactor can be a suggestion (design improvement). Classify by impact, not by size of the required change.

#### Grounding Quality Rubric

Evaluate each finding's `**Grounding:**` line against this rubric before finalizing severity. Three outcomes:

- **Sound** — grounding is concrete and proportionate. The finding can be acted on as written.
- **Weak** — grounding exists but lacks specificity. Rewrite with a concrete scenario before reporting.
- **Unsound** — no realistic failure scenario or benefit exists. Downgrade severity or drop the finding.

**Blocking findings:**

| Outcome | Criteria |
|---------|----------|
| Sound | Names what breaks, who is affected, and under what conditions |
| Weak | Names a concern but omits who is affected or when it triggers |
| Unsound | No realistic failure scenario — theoretical risk only, or finding is a style preference |

Examples:
- Sound: "If `session.user` is nil when the route is called without authentication, the nil dereference panics and crashes the server — affects all unauthenticated requests to `/api/admin`."
- Weak: "This could cause a nil pointer dereference in some cases." (missing: which cases, what request path, who hits it)
- Unsound: "Nil dereferences are bad practice." (no scenario where this code actually crashes)

**Suggestion findings:**

| Outcome | Criteria |
|---------|----------|
| Sound | Names the specific improvement and who benefits from it |
| Weak | Claims "better" or "cleaner" without naming what improves or for whom |
| Unsound | Subjective preference with no concrete benefit to maintainers, callers, or future readers |

Examples:
- Sound: "Extracting the retry loop into `withRetry()` lets callers test timeout behavior independently — reduces test setup from 40 lines to 5 in each caller."
- Weak: "This would be cleaner if extracted into a helper." (missing: what specifically improves, who benefits)
- Unsound: "I prefer early returns over nested conditionals." (personal style, no concrete maintainability benefit stated)

**Action by outcome:** Sound → report as-is. Weak → rewrite grounding with missing specifics, then report. Unsound → downgrade to question if the concern is worth raising, or drop entirely.

#### Relationship to Conventional Comments labels

Existing review skills (`/pr-review`, `/pr-self-review`, `/pr-pair-review`, `/pr-revise`) use the full Conventional Comments label set (`suggestion`, `issue`, `question`, `thought`, `nitpick`, `praise`). The severity levels above are a simplified taxonomy for lens skills that produce structured findings. The mapping:

| Severity    | Conventional Comments equivalents        |
|-------------|------------------------------------------|
| blocking    | issue (when merge-blocking)              |
| suggestion  | suggestion, issue (non-blocking), thought |
| question    | question                                 |
| (not used)  | nitpick, praise                          |

Lens skills do not produce nitpick or praise findings — those are conversational labels suited to interactive review, not structured analysis output.
