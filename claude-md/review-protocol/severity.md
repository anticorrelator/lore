### Severity Classification

Every review finding MUST be assigned exactly one severity level. These definitions are the single source of truth — individual lens and review skills reference this section rather than defining their own taxonomy.

#### Levels

- **blocking** — The PR must not merge with this issue unresolved. Use for: correctness bugs, security vulnerabilities, data loss risks, broken invariants, API contract violations. The bar is "this will cause a defect or incident if shipped." **Stake:** name the observed code fact and the *condition* under which it fails — `X happens if Y`. The conditional is deliberate: the reviewer often cannot know whether `Y` holds, so stating it as a condition hands the block/no-block call to the reader, who has the context the reviewer lacks. Do not assert "this blocks"; state the fact and the condition and let the reader weigh it.
- **suggestion** — The PR should address this but it is not a merge blocker. Use for: design improvements, convention violations, missing edge case handling, suboptimal patterns, maintainability concerns. The bar is "the code works but could be meaningfully better." **Stake:** name what is observed and the concrete situation in which the cost is actually felt. If that cost only appears in a contrived scenario, or the change is a matter of taste, the finding is immaterial — drop it (see the Materiality Gate); do not dress it up as impact.
- **question** — The reviewer cannot assess correctness without additional information from the author. Use for: unclear intent, ambiguous behavior, missing context on why an approach was chosen. The bar is "I need context the diff does not give me before I can evaluate this." A question is the honest route when a finding turns on something the reviewer cannot see. No stake line required beyond the question itself.

**Severity is a reviewer-facing axis.** It orders the reviewer's own triage and signals how urgently *they* should verify — it is not a label the PR author sees. Posted comments carry no severity word by default; the conditional stake delegates the criticality call to the reader. See `findings-format.md` → External Output Formatting for what crosses the wall, and `review-voice.md` for how the stake is phrased.

#### Classification rules

1. **Default to suggestion.** When uncertain between blocking and suggestion, choose suggestion. Overcalling blocking erodes trust and slows velocity.
2. **Questions are not soft suggestions.** A question means the reviewer genuinely does not know the answer. If you know the answer and think the code should change, that is a suggestion or blocking finding, not a question.
3. **Severity is independent of effort.** A one-line fix can be blocking (security). A large refactor can be a suggestion (design improvement). Classify by impact, not by size of the required change.

#### Materiality Gate

Run every `blocking` and `suggestion` finding through the materiality gate before finalizing. This is a judgment about **magnitude**, not about whether the stake is well-written. The two are independent: a finding can have a perfectly articulated consequence and still not be worth the author's attention. The gate exists because *any* finding's impact can be written up as a complete cause-and-effect chain — so "I can describe a scenario where this matters" cannot be the bar. The bar is whether it matters.

**The test:** *Would the author plausibly change the code — or want to verify something — because of this?* Answer from the author's seat, not the reviewer's. If the honest answer is "only in a scenario that can't actually occur here" or "it's a matter of taste," the finding is below the bar.

Three outcomes:

- **Material** — keep it; it becomes a candidate posted comment. For blocking: a *realistic, reachable* path produces the failure. For suggestion: the cost is felt in normal maintenance or use, not only in a contrived case.
- **Immaterial** — **drop it.** The failure path is contrived or unreachable, or the improvement is taste with no concrete cost. Do **not** rewrite it into something that sounds material — that manufactures impact and inflates the comment. Immaterial findings collapse into a `minor (N)` count in the reviewer view; they are never posted.
- **Question** — the concern turns on context the reviewer cannot see (intent, reachability, an upstream guarantee). Route it to a `question` rather than asserting a defect or dropping it. This is the honest move when the reviewer lacks the context to judge.

**The gate drops or routes; it never pads.** A finding clears the bar as written, or it doesn't. (This replaces the former rule that rewrote weak grounding into a fuller chain — that rule dressed minutiae in impact prose and was the main source of verbose, reasoning-like comments.)

Examples — blocking:
- Material: "`session.user` is dereferenced without a nil check — panics if this route is reachable before auth completes." (the reader judges reachability and decides whether it blocks)
- Question: "`session.user` is dereferenced without a nil check — is a non-nil `user` guaranteed on this path by the middleware chain?" (reviewer can't see the middleware; asking is honest)
- Immaterial → drop: "Nil dereferences are bad practice." (no reachable path shown — taste dressed as risk)

Examples — suggestion:
- Material: "Retry loop is duplicated across 3 callsites — a fix to one (e.g. backoff) won't reach the others." (drift cost felt in ordinary maintenance)
- Immaterial → `minor (N)`: "This would read more cleanly with early returns." (taste, no concrete cost named)

#### Relationship to Conventional Comments labels

Existing review skills (`/pr-review`, `/pr-self-review`, `/pr-pair-review`, `/pr-revise`) use the full Conventional Comments label set (`suggestion`, `issue`, `question`, `thought`, `nitpick`, `praise`). The severity levels above are a simplified taxonomy for lens skills that produce structured findings. The mapping:

| Severity    | Conventional Comments equivalents        |
|-------------|------------------------------------------|
| blocking    | issue (when merge-blocking)              |
| suggestion  | suggestion, issue (non-blocking), thought |
| question    | question                                 |
| (not used)  | nitpick, praise                          |

Lens skills do not produce nitpick or praise findings — those are conversational labels suited to interactive review, not structured analysis output.
