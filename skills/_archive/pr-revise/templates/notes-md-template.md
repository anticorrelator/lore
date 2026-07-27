# pr-revise notes.md template

Used by `/pr-revise` Step 5 when writing the work item `notes.md`.

```markdown
# PR #<NUMBER>: <Title>

> **Review-level analysis.** Findings came from diff-level review; investigation agents must verify them against the full codebase. Verification items state open questions, not expected outcomes.

## Goal
Substantiate or dismiss reviewer feedback from @<reviewer>'s review on PR #<NUMBER> against code behavior.

## Agreed Changes
Items where reading the referenced code confirms the reviewer's point — typos, naming, style, or claims that reduce to a one-liner once the code is read.
- [ ] **<Impact claim — mechanism → consequence>** — `<file:line>`. Reviewer: "<quote>".

## Verification Needed
Reviewer claims where grounding is plausible but evidence requires multi-file or cross-boundary investigation. **State the open question, not the expected outcome.**
- [ ] **<Impact claim if the reviewer is correct>** — `<file:function>`. Reviewer: "<quote>". **Verify:** <open question> [knowledge: <citation>]

## Deferred
Out of scope for this revision pass, or blocked on user input.
- [ ] <item> — <reason deferred>
```

Group related feedback into single items when they touch the same file/function. Include knowledge citations so `/spec` investigators have context. Omit empty sections.

> **Next step:** To generate implementation tasks, run `/spec pr-<NUMBER>-<short-slug>` on this work item after investigation validates the findings. The pipeline is: review findings (notes.md) -> `/spec` investigation (plan.md) -> `/implement` execution. Do not skip the `/spec` step — review findings are diff-level hypotheses, not validated implementation plans.
