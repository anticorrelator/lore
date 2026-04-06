### Severity Classification

Every review finding MUST be assigned exactly one severity level. These definitions are the single source of truth — individual lens and review skills reference this section rather than defining their own taxonomy.

#### Levels

- **blocking** — The PR must not merge with this issue unresolved. Use for: correctness bugs, security vulnerabilities, data loss risks, broken invariants, API contract violations. The bar is "this will cause a defect or incident if shipped." **Required grounding:** state the concrete failure scenario — what breaks, for whom, and under what conditions — then land on the observable human or operational consequence. A blocking finding that stops at the technical mechanism ("nil dereference panics") without stating the downstream impact ("users see a 500 and lose their in-progress work") is incomplete and must be rewritten.
- **suggestion** — The PR should address this but it is not a merge blocker. Use for: design improvements, convention violations, missing edge case handling, suboptimal patterns, maintainability concerns. The bar is "the code works but could be meaningfully better." **Required grounding:** state the specific improvement, who benefits, and the concrete situation where that benefit is felt. A suggestion that names an abstract quality ("reduces cognitive load") without a scenario where a real person encounters the problem ("the next engineer debugging a retry failure has to trace three identical copies") is a vague preference, not a review finding.
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
| Sound | Names the technical mechanism AND the downstream human/operational consequence — the chain from code state to observable impact is complete |
| Weak | Names the technical mechanism but stops there — the reader knows *what breaks* but not *why it matters*. Also weak: names a concern but omits who is affected or when it triggers |
| Unsound | No realistic failure scenario — theoretical risk only, or finding is a style preference |

Examples:
- Sound: "If `session.user` is nil when the route is called without authentication, the nil dereference panics and crashes the server — any user hitting `/api/admin` while unauthenticated sees a 500 error and loses their in-progress request."
- Weak (mechanism only): "If `session.user` is nil when the route is called without authentication, the nil dereference panics and crashes the server." (stops at the technical failure — missing: what the user experiences, what operational consequence follows)
- Weak (vague): "This could cause a nil pointer dereference in some cases." (missing: which cases, what request path, who hits it, what they experience)
- Unsound: "Nil dereferences are bad practice." (no scenario where this code actually crashes)

**Suggestion findings:**

| Outcome | Criteria |
|---------|----------|
| Sound | Names the specific improvement, who benefits, and a concrete situation where a real person encounters the problem or feels the benefit |
| Weak | Names an abstract quality improvement ("reduces cognitive load", "improves readability") without a scenario where someone actually encounters the friction |
| Unsound | Subjective preference with no concrete benefit to maintainers, callers, or future readers |

Examples:
- Sound: "The retry loop appears identically in three callsites. The next engineer debugging a retry failure has to trace all three to find the failing one — extracting into `withRetry()` makes the failing callsite immediately identifiable in stack traces and reduces test setup from 40 lines to 5 per caller."
- Weak (abstract benefit): "Extracting the retry loop into `withRetry()` lets callers test timeout behavior independently — reduces test setup from 40 lines to 5 in each caller." (names a technical benefit but not the situation where someone actually hits the problem)
- Weak (vaguer): "This would be cleaner if extracted into a helper." (missing: what specifically improves, who benefits, when they encounter it)
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
