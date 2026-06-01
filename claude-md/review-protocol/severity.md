### Severity Classification

Every review finding MUST be assigned exactly one severity level. These definitions are the single source of truth — individual lens and review skills reference this section rather than defining their own taxonomy.

#### Levels

- **blocking** — The PR must not merge with this issue unresolved. Use for: correctness bugs, security vulnerabilities, data loss risks, broken invariants, API contract violations. The bar is "this will cause a defect or incident if shipped." **Stake — the path to manifestation, in usage terms:** state (1) the *trigger* — what someone does, in product/behavior terms a reviewer unfamiliar with the code can follow ("if the agent renames the forced-choice tool"), **not** a code path ("the update branch calls `patchDefinition`"); (2) the *manifestation* — what they would observe ("the next run is rejected by the provider, with no warning at write time"). Leave the block/no-block call to the reader: the realism of the trigger is exactly what they have the context to judge. Code mechanism is an optional trailing anchor for the author, never the substance.
- **suggestion** — The PR should address this but it is not a merge blocker. Use for: design improvements, convention violations, missing edge case handling, suboptimal patterns, maintainability concerns. The bar is "the code works but could be meaningfully better." **Stake — the path to manifestation, in usage terms:** name the situation in which a real person feels the cost — when it arises in ordinary maintenance or use, and what it costs them. If, once you spell out the realistic trigger, the cost only appears in a contrived scenario or is a matter of taste, the finding is immaterial — drop it (see the Materiality Gate); do not dress it up.
- **question** — The reviewer cannot assess correctness without additional information from the author. Use for: unclear intent, ambiguous behavior, missing context on why an approach was chosen. The bar is "I need context the diff does not give me before I can evaluate this." A question is the honest route when a finding turns on something the reviewer cannot see. No stake line required beyond the question itself.

**Severity is a reviewer-facing axis.** It orders the reviewer's own triage and signals how urgently *they* should verify — it is not a label the PR author sees. Posted comments carry no severity word by default; the conditional stake delegates the criticality call to the reader. See `findings-format.md` → External Output Formatting for what crosses the wall, and `review-voice.md` for how the stake is phrased.

#### Classification rules

1. **Default to suggestion.** When uncertain between blocking and suggestion, choose suggestion. Overcalling blocking erodes trust and slows velocity.
2. **Questions are not soft suggestions.** A question means the reviewer genuinely does not know the answer. If you know the answer and think the code should change, that is a suggestion or blocking finding, not a question.
3. **Severity is independent of effort.** A one-line fix can be blocking (security). A large refactor can be a suggestion (design improvement). Classify by impact, not by size of the required change.

#### Materiality Gate

Run every `blocking`/`suggestion` finding through the gate by **tracing the path to manifestation** — the trace is both the comment and the test, one act:
1. **Trigger** — what someone *does* to hit this, in usage terms a stranger to the code can follow ("the agent renames a tool that's the forced choice"), not a code path.
2. **Manifestation** — what they'd *observe* ("the next run is rejected by the provider; the write gave no warning").
3. **Judgment** — given how realistic that trigger is, and whether the outcome is a real defect or just what the action asked for, would the author change the code?

A bare code-state ("`toolChoice` may be orphaned") can't be judged — you can't see how you'd get there. Spelling out the trigger is what reveals materiality, and it often deflates the scare: "a user would have had to ask the agent to rename the forced-choice tool" lets you weigh whether that's common, or just inherent to the request.

- **Material** → keep: realistic trigger, genuine defect.
- **Immaterial** → drop to the `minor (N)` tally: contrived/unreachable trigger, outcome inherent to a deliberate action, or nothing the code could do. Don't restate it as a code-state to sound worse.
- **Question** → route: the trace turns on context the diff doesn't show (reachable? intended?).

The bar is comprehensibility, not mechanism rigor: *could a stranger to the code tell when this happens and what they'd see, well enough to judge it?* If not, it isn't grounded. The gate drops or routes — never pads. Mechanism detail is an optional anchor for the author, never the substance.

Examples:
- **Material:** "If the agent renames a tool set as the required choice, the next run is rejected by the provider for forcing a tool that no longer exists — delete already resets the choice; rename doesn't."
- **Immaterial (trace deflates it):** "`toolChoice` may reference a removed tool name." — no trigger, no symptom; can't be situated or judged.
- **Immaterial:** "Reads more cleanly with early returns." — taste; no cost once you try to say when anyone feels it.

#### Relationship to Conventional Comments labels

Existing review skills (`/pr-review`, `/pr-self-review`, `/pr-pair-review`, `/pr-revise`) use the full Conventional Comments label set (`suggestion`, `issue`, `question`, `thought`, `nitpick`, `praise`). The severity levels above are a simplified taxonomy for lens skills that produce structured findings. The mapping:

| Severity    | Conventional Comments equivalents        |
|-------------|------------------------------------------|
| blocking    | issue (when merge-blocking)              |
| suggestion  | suggestion, issue (non-blocking), thought |
| question    | question                                 |
| (not used)  | nitpick, praise                          |

Lens skills do not produce nitpick or praise findings — those are conversational labels suited to interactive review, not structured analysis output.
