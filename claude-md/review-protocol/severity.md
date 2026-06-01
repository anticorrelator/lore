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

Run every `blocking` and `suggestion` finding through the materiality gate before finalizing. The gate is applied by **tracing the path to manifestation** — and that trace is both the communication and the test. They are the same act: writing the path *for* an unfamiliar reviewer is how you *judge* whether the finding matters.

**Trace the path, in usage terms:**
1. **Trigger** — what does someone *do* to reach this? State it in product/behavior terms a reviewer unfamiliar with the code can follow ("the agent renames a tool that's the forced choice"), not as a code path ("the update branch calls `patchDefinition`").
2. **Manifestation** — what would they *observe*? The visible symptom ("the next run is rejected by the provider; the write gave no warning").
3. **Judgment** — given how realistic that trigger is, and whether the outcome is a genuine defect or an inherent consequence of the action, would the author change the code?

**Why the trace IS the test.** A finding stated as a code-state ("`toolChoice` may be orphaned") *sounds* material but cannot actually be judged — you can't tell how you'd get there or whether it matters. Spelling out the realistic trigger is what surfaces the answer, and it frequently *deflates* a scary-sounding finding: once you write "a user would have had to ask the agent to rename the forced-choice tool," you can weigh whether that path is common, and whether the orphaning is a defect or an inherent result of the user's own request. "I can describe a code-state" is not the bar; "a reviewer can see the realistic path and judge it worth acting on" is.

Three outcomes:

- **Material** — the traced trigger is realistic and the outcome is a genuine defect (something the system should prevent or signal). Keep it.
- **Immaterial** — once traced, the trigger is contrived/unreachable, the outcome is an inherent and expected consequence of a deliberate action, or there is nothing the code could reasonably do. **Drop it** to the `minor (N)` tally. Do **not** restate it as a code-state to make it sound worse than the path supports.
- **Question** — the trace turns on context the diff does not show (is this trigger reachable? is this outcome intended?). Route to a `question`.

**Comprehensibility is required, not optional.** Test every kept finding: *could a reviewer who has never seen this code tell, from the stake, WHEN it happens and WHAT they would see — well enough to judge it themselves?* If not, it is not grounded yet, no matter how rigorous the mechanism. Code mechanism is an optional trailing anchor for the author who wants to verify — never the substance.

**The gate drops or routes; it never pads.** A finding clears the bar as a legible path, or it doesn't. (This replaces the former rule that rewrote weak grounding into a fuller chain — that rule dressed minutiae in impact prose and was the main source of verbose, reasoning-like comments.)

Examples — blocking:
- Material (legible, realistic path): "If the agent renames a tool that's set as the prompt's required tool choice, the write succeeds with no warning but the next run is rejected by the provider for forcing a tool that no longer exists — deleting the forced tool already resets the choice; renaming doesn't."
- Immaterial → drop (trace deflates it): "`toolChoice` may reference a removed tool name." (no trigger, no symptom — a code-state that sounds bad but can't be situated or judged)
- Question (trace turns on unseen context): "If the agent renames the forced-choice tool, the choice keeps the old name — is the rename path reachable in normal agent use, or is renaming always a delete-plus-create?"

Examples — suggestion:
- Material: "The retry loop is duplicated across 3 callsites — the next person tuning backoff changes one and silently misses the other two."
- Immaterial → `minor (N)`: "This reads more cleanly with early returns." (taste; no usage-level cost once you try to state when anyone actually feels it)

#### Relationship to Conventional Comments labels

Existing review skills (`/pr-review`, `/pr-self-review`, `/pr-pair-review`, `/pr-revise`) use the full Conventional Comments label set (`suggestion`, `issue`, `question`, `thought`, `nitpick`, `praise`). The severity levels above are a simplified taxonomy for lens skills that produce structured findings. The mapping:

| Severity    | Conventional Comments equivalents        |
|-------------|------------------------------------------|
| blocking    | issue (when merge-blocking)              |
| suggestion  | suggestion, issue (non-blocking), thought |
| question    | question                                 |
| (not used)  | nitpick, praise                          |

Lens skills do not produce nitpick or praise findings — those are conversational labels suited to interactive review, not structured analysis output.
