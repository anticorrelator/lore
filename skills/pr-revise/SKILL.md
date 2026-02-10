---
name: pr-revise
description: "Read all PR review feedback and create a work item with categorized findings and verification directives"
user_invocable: true
argument_description: "[PR_number_or_URL] [focus context] — PR with feedback to address (or auto-detect from branch). Optional focus context steers which feedback areas to prioritize (e.g., '42 concentrate on the reviewer comments about error handling')"
---

# /pr-revise Skill

Read all comments and reviews on a GitHub Pull Request, categorize feedback with knowledge enrichment, and create a work item with verification directives. Default readiness is `spec-needed` — review findings are hypotheses until verified against the full codebase. The knowledge store helps distinguish "reviewer bringing valid insight" from "reviewer imposing personal preference that contradicts project conventions."

This skill is analysis-only — it creates work items with notes and tasks but does not modify source code.

## Step 1: Identify PR and Focus Context

Argument provided: `$ARGUMENTS`

**Parse arguments:** The first token that looks like a PR number (digits) or GitHub URL is the PR identifier. Everything else is **focus context** — free-text guidance about which feedback areas to concentrate on.

Examples:
- `42` → PR #42, no focus context
- `42 concentrate on the reviewer comments about error handling` → PR #42, focus on error handling feedback
- `prioritize the architectural concerns` → no PR (auto-detect), focus context provided

**If no PR identifier:** Detect from current branch:
```bash
gh pr list --state open --head "$(git branch --show-current)" --json number,baseRefName --jq '.[] | "#\(.number) → \(.baseRefName)"' 2>/dev/null
```

**If multiple PRs found:** Present the list with base branches and ask the user which one to review.

**If no PRs found:** Ask the user for the PR number. If they provide a base branch instead, search by base: `gh pr list --state open --base <branch> --head "$(git branch --show-current)" ...`

**Carry focus context forward** — it influences categorization priority in Step 3 (focused feedback areas are analyzed first) and plan phase ordering in Step 5 (focused items are grouped into earlier phases).

## Step 2: Fetch All Comments

Fetch all PR data using the shared script:

```bash
# Grouped review data (grouped_reviews, unmatched_threads, orphan_comments)
bash ~/.lore/scripts/fetch-pr-data.sh <PR_NUMBER>

# Raw diff for context
gh pr diff <PR_NUMBER>

# File scope and metadata
gh pr view <PR_NUMBER> --json files,title,body,baseRefName,headRefName
```

CRITICAL: The fetch script groups comments by review submission. The GitHub UI hides/folds comments — the API is the only reliable source.

## Step 3: Select Review Batch and Categorize

**Review Selection:** Follow the Review Selection protocol defined in `claude-md/70-review-protocol.md`. Present fetched reviews as batches grouped by reviewer and let the user select which batch to work through. Only categorize and process comments from the selected batch — other batches are deferred to subsequent invocations.

If the PR has only one reviewer with feedback, skip the selection prompt and proceed with that batch automatically.

**Categorize the selected batch:**

1. **Unresolved Review Threads** — These need action
2. **Review Bodies with CHANGES_REQUESTED** — High priority feedback
3. **General Comments** — May contain actionable items (only those belonging to the selected batch)
4. **Outdated** (`isOutdated: true` in GraphQL response) — Filter out. These are on code that has been subsequently changed and are likely addressed by later commits. Only surface an outdated thread if the concern clearly still applies to the *current* state of the diff — verify against the current diff, not the outdated context. Do not count toward "unresolved items needing action."
5. **Resolved** — Skip unless referenced by an unresolved thread

For each unresolved item in the selected batch, determine:
- **Clear fix**: Obvious what to do (typo, naming, style) -> Create task directly
- **Needs context**: Requires reading code to understand -> Read first, then decide
- **Ambiguous**: Multiple valid approaches or conflicts with codebase patterns -> May need user input
- **Disagreement**: Feedback conflicts with project conventions -> Flag for user

Assign a Conventional Comments label to each item: `suggestion`, `issue`, `question`, `thought`, `nitpick`, or `praise`.

**Apply the 8-point review checklist** from the review protocol reference (`claude-md/70-review-protocol.md`) as an additional analysis lens when categorizing. Read the checklist at invocation time — do not duplicate it here. The checklist helps distinguish substantive feedback from style preferences.

**Scoping for large diffs:** For PRs touching more than ~10 files, prioritize analysis by: (1) files with blocking/CHANGES_REQUESTED feedback, (2) files with the most review threads, (3) files touching shared interfaces or public APIs. Apply detailed categorization to priority files; batch remaining items by category.

## Step 4: Knowledge Enrichment

**This step is mandatory.** Follow the Knowledge Enrichment Protocol defined in `claude-md/70-review-protocol.md`.

For each feedback item with a substantive label (suggestion, issue, question, thought):

1. Query the knowledge store:
   ```bash
   lore search "<feedback topic>" --type knowledge --json --limit 3
   ```

2. Surface 1-3 compact citations inline with the categorized item. Format: `[knowledge: entry-title]` with a one-line summary of relevance.

3. Check for staleness: if a knowledge entry is STALE and the PR contradicts it, flag as "convention may need updating" — not "PR is wrong."

**This enrichment is critical for /pr-revise specifically:** external reviewers bring fresh eyes but also stylistic baggage. Knowledge enrichment distinguishes project conventions from reviewer preferences. When a reviewer suggests something that contradicts a known convention, the enrichment surfaces the convention so the user can make an informed decision.

**Investigation escalation:** When all three gate conditions are met (substantive label + insufficient knowledge results + multi-file analysis needed), spawn an Explore agent to investigate cross-boundary concerns before finalizing the categorization. Follow the Investigation Escalation procedure in `claude-md/70-review-protocol.md`. Maximum 2 escalations per review.

Skip enrichment for nitpick and praise labels.

## Step 5: Create Work Item with Notes

Create a work item from the categorized, enriched feedback:

```
/work create pr-<NUMBER>-<short-slug>
```

Where `<short-slug>` is 2-3 words from the PR title, slugified (e.g., `pr-42-fix-auth-flow`).

Write `notes.md` (not `plan.md`) with feedback organized by actionability:

```markdown
# PR #<NUMBER>: <Title>

> **Review-level analysis.** These findings came from a code review (diff-level analysis). Investigation agents should verify assumptions against the full codebase, not accept them as validated.

## Goal
Address reviewer feedback from @<reviewer>'s review on PR #<NUMBER>.

## Agreed Changes
Trivially obvious fixes only — typos, naming corrections, clear style fixes. Each must be verifiable from the diff alone without reading surrounding code.
- [ ] <"Clear fix" item with file:line reference and quoted reviewer feedback>
- [ ] ...

## Verification Needed
Reviewer claims requiring `/spec` investigation before implementation. Each item includes an explicit verification directive.
- [ ] <"Needs context" item> — **Verify:** <what to check> in `<file:function>` [knowledge: <citation>]
- [ ] <"Ambiguous" item> — **Verify:** <which approach is correct> given <constraint> [knowledge: <citation>]
- [ ] ...

## Deferred
Out of scope for this revision pass, or blocked on user input.
- [ ] <item> — <reason deferred>
- [ ] ...
```

Group related feedback into single items when they touch the same file/function. Include quoted feedback and file:line references in each item. Include knowledge citations so `/spec` investigators have context. Omit empty sections.

Generate tasks from the notes:
```
/work tasks pr-<NUMBER>-<short-slug>
```

### Readiness assessment

Default readiness is `spec-needed`. Override to `implement-ready` only when ALL of these are true:
- Every item is in "Agreed Changes" (no "Verification Needed" items exist)
- All items are trivially obvious fixes verifiable from the diff alone
- No item touches cross-boundary invariants or shared interfaces

**Only ask the user when:**
- Feedback contradicts project conventions (knowledge enrichment will surface this)
- Multiple valid architectural approaches exist
- Feedback seems incorrect or based on misunderstanding
- The change would have broad implications

When asking, be specific: "The reviewer suggests X, but convention Y applies here [knowledge: entry-title]. Which should I follow?"

This step is automatic — do not ask whether to create the work item.

## Step 6: Present Summary

```
## PR Feedback Summary

**PR:** #<number> — <title>
**Reviewed batch:** @<reviewer> (<STATE>) — N inline comments
**Readiness:** spec-needed | implement-ready
**Agreed changes:** N (direct tasks)
**Verification needed:** M (requires /spec)
**Deferred:** K
**Skipped (resolved/outdated):** J
**Knowledge enrichments:** X queries, Y citations surfaced

### Agreed Changes:
1. [task subject] — file.py:123
2. ...

### Verification Directives:
1. [item] — Verify: [what to check] in `file:function`
2. ...

### Items needing your input:
- [description with knowledge context — e.g., "Reviewer suggests X, but convention Y applies"]

### Deferred batches:
- @<reviewer2> (<STATE>) — N inline comments
```

If there are items needing input, ask about them in a single batched question.

If there are deferred batches, note that the user can re-invoke `/pr-revise` on the same PR to process the next batch.

## Step 7: Capture Insights

```
/remember PR review feedback from PR #<N> — capture: architectural insights, corrected misconceptions about how the codebase works, non-obvious patterns or invariants the reviewer identified, genuine bugs or correctness issues that reveal something about the system. Skip: style preferences, naming opinions, formatting nits, nitpicking, subjective code taste, "I would have done it differently" suggestions, anything that amounts to an outside contributor's personal conventions vs the project's own patterns. PR reviewers bring valuable fresh eyes but also stylistic baggage — be highly discerning. Use confidence: medium for reviewer-sourced insights (not verified against codebase internals).
```

This step is automatic — do not ask whether to run it.

## Resuming

If re-invoked on the same PR, check for an existing work item (e.g., `pr-<NUMBER>-*` in `/work list`). If found, load `notes.md` and determine the context:

- **Processing a deferred batch:** Re-fetch PR data, present remaining unprocessed reviewer batches for selection, and append the new batch's categorized feedback to the existing notes — new fixes to Agreed Changes, new directives to Verification Needed, new deferrals to Deferred.
- **New feedback on an already-processed batch:** Update existing notes sections with any new comments rather than creating duplicates.

## Error Handling

- **No gh CLI or token:** Tell user to run `gh auth login` or set `GITHUB_TOKEN`
- **PR not found:** Confirm the PR number and repo access
- **Empty response:** PR may have no comments — confirm with user
- **Rate limited:** Wait and retry, or ask user to try later
