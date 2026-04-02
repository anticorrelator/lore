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

#### Relationship to Conventional Comments labels

Existing review skills (`/pr-review`, `/pr-self-review`, `/pr-pair-review`, `/pr-revise`) use the full Conventional Comments label set (`suggestion`, `issue`, `question`, `thought`, `nitpick`, `praise`). The severity levels above are a simplified taxonomy for lens skills that produce structured findings. The mapping:

| Severity    | Conventional Comments equivalents        |
|-------------|------------------------------------------|
| blocking    | issue (when merge-blocking)              |
| suggestion  | suggestion, issue (non-blocking), thought |
| question    | question                                 |
| (not used)  | nitpick, praise                          |

Lens skills do not produce nitpick or praise findings — those are conversational labels suited to interactive review, not structured analysis output.

#### User-Facing Framing

Internal severity values (`blocking`, `suggestion`, `question`) remain in JSON for routing and aggregation. User-visible output — section headers, verdict lines, and finding descriptions — uses impact-grounded language that presents evidence without issuing a severity verdict.

**Rule: hedge the inference, not the observed code fact.**

The observed code fact is stated plainly. The impact claim — what will break, who is affected, under what conditions — is framed as a grounded scenario, not a certainty.

- Do not write: "This is a security vulnerability."
- Write instead: "If `input` is user-controlled, this reaches `exec()` unsanitized — a path that could allow command injection."

**Section header format (user-facing output):**

| Internal label | User-facing section header |
|----------------|----------------------------|
| blocking findings | `### Findings requiring action (<count>)` |
| suggestion findings | `### Improvement opportunities (<count>)` |
| question findings | `### Questions (<count>)` |

Do not use `### Blocking (<count>)` or `### Suggestions (<count>)` in user-visible output.

**Verdict line format (user-facing output):**

| Outcome | Verdict line |
|---------|--------------|
| Has blocking findings | `ACTION NEEDED` |
| Clean, no findings | `CLEAN` |
| Has suggestions only | `SUGGESTIONS` |

Do not use `BLOCKING` or `SUGGESTIONS ONLY` as verdict tokens in user-visible output.

