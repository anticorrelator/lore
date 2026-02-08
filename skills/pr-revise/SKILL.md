---
name: pr-revise
description: "Read all PR review feedback and create an implement-ready work item to address it"
user_invocable: true
argument_description: "[PR_number_or_URL] — PR with feedback to address (or auto-detect from branch)"
---

# /pr-revise Skill

Read all comments and reviews on a GitHub Pull Request, categorize feedback with knowledge enrichment, and create an implement-ready work item. The knowledge store helps distinguish "reviewer bringing valid insight" from "reviewer imposing personal preference that contradicts project conventions."

This skill is analysis-only — it creates plans and tasks but does not modify source code.

## Step 1: Identify PR

Argument provided: `$ARGUMENTS`

**If argument provided:** Parse as PR number or URL.

**If no argument:** Detect from current branch:
```bash
gh pr list --head "$(git branch --show-current)" --json number --jq '.[0].number' 2>/dev/null
```

**If detection fails:** Ask the user for the PR number.

## Step 2: Fetch All Comments

Fetch all PR data using the shared script:

```bash
# Structured comment/review data (reviewThreads, reviews, general comments)
scripts/fetch-pr-data.sh <PR_NUMBER>

# Raw diff for context
gh pr diff <PR_NUMBER>

# File scope and metadata
gh pr view <PR_NUMBER> --json files,title,body,baseRefName,headRefName
```

CRITICAL: The GraphQL query fetches all comment types. The GitHub UI hides/folds comments — the API is the only reliable source.

## Step 3: Analyze and Categorize

Parse the response and categorize:

1. **Unresolved Review Threads** — These need action
2. **Review Bodies with CHANGES_REQUESTED** — High priority feedback
3. **General Comments** — May contain actionable items
4. **Resolved/Outdated** — Skip unless referenced

For each unresolved item, determine:
- **Clear fix**: Obvious what to do (typo, naming, style) -> Create task directly
- **Needs context**: Requires reading code to understand -> Read first, then decide
- **Ambiguous**: Multiple valid approaches or conflicts with codebase patterns -> May need user input
- **Disagreement**: Feedback conflicts with project conventions -> Flag for user

Assign a Conventional Comments label to each item: `suggestion`, `issue`, `question`, `thought`, `nitpick`, or `praise`.

**Apply the 8-point review checklist** from the review protocol reference (`claude-md/70-review-protocol.md`) as an additional analysis lens when categorizing. Read the checklist at invocation time — do not duplicate it here. The checklist helps distinguish substantive feedback from style preferences.

## Step 4: Knowledge Enrichment

**This step is mandatory.** Follow the Knowledge Enrichment Protocol defined in `claude-md/70-review-protocol.md`.

For each feedback item with a substantive label (suggestion, issue, question, thought):

1. Query the knowledge store:
   ```bash
   lore search "<feedback topic>" --json --limit 3
   ```

2. Surface 1-3 compact citations inline with the categorized item. Format: `[knowledge: entry-title]` with a one-line summary of relevance.

3. Check for staleness: if a knowledge entry is STALE and the PR contradicts it, flag as "convention may need updating" — not "PR is wrong."

**This enrichment is critical for /pr-revise specifically:** external reviewers bring fresh eyes but also stylistic baggage. Knowledge enrichment distinguishes project conventions from reviewer preferences. When a reviewer suggests something that contradicts a known convention, the enrichment surfaces the convention so the user can make an informed decision.

**Investigation escalation:** When all three gate conditions are met (substantive label + insufficient knowledge results + multi-file analysis needed), spawn an Explore agent to investigate cross-boundary concerns before finalizing the categorization. Follow the Investigation Escalation procedure in `claude-md/70-review-protocol.md`. Maximum 2 escalations per review.

Skip enrichment for nitpick and praise labels.

## Step 5: Create Plan and Generate Tasks

Create a work item from the categorized, enriched feedback:

```
/work create pr-<NUMBER>-<short-slug>
```

Where `<short-slug>` is 2-3 words from the PR title, slugified (e.g., `pr-42-fix-auth-flow`).

Write `plan.md` with feedback organized into phases by priority:

```markdown
# PR #<NUMBER>: <Title>

## Goal
Address reviewer feedback on PR #<NUMBER>.

## Phases

### Phase 1: Blocking / Correctness
**Objective:** Fix issues that affect correctness or block merge
**Files:** <affected files>
- [ ] <feedback item as actionable task with file:line reference and knowledge citation>
- [ ] ...

### Phase 2: Improvements
**Objective:** Address substantive suggestions
**Files:** <affected files>
- [ ] <feedback item with knowledge citation>
- [ ] ...

### Phase 3: Style / Minor
**Objective:** Address style and minor items
**Files:** <affected files>
- [ ] <feedback item>
- [ ] ...
```

Group related feedback into single items when they touch the same file/function. Include quoted feedback and file:line references in each item. Include knowledge citations so `/implement` workers have context. Omit empty phases.

Generate tasks from the plan:
```
/work tasks pr-<NUMBER>-<short-slug>
```

**Only ask the user when:**
- Feedback contradicts project conventions (knowledge enrichment will surface this)
- Multiple valid architectural approaches exist
- Feedback seems incorrect or based on misunderstanding
- The change would have broad implications

When asking, be specific: "The reviewer suggests X, but convention Y applies here [knowledge: entry-title]. Which should I follow?"

This step is automatic — do not ask whether to create the plan.

## Step 6: Present Summary

```
## PR Feedback Summary

**PR:** #<number> — <title>
**Unresolved items:** N
**Tasks created:** M
**Skipped (resolved/outdated):** K
**Knowledge enrichments:** X queries, Y citations surfaced

### Tasks:
1. [task subject] — file.py:123
2. [task subject] — component.tsx:45
...

### Items needing your input:
- [description with knowledge context — e.g., "Reviewer suggests X, but convention Y applies"]
```

If there are items needing input, ask about them in a single batched question.

## Step 7: Capture Insights

```
/remember PR review feedback from PR #<N> — capture: architectural insights, corrected misconceptions about how the codebase works, non-obvious patterns or invariants the reviewer identified, genuine bugs or correctness issues that reveal something about the system. Skip: style preferences, naming opinions, formatting nits, nitpicking, subjective code taste, "I would have done it differently" suggestions, anything that amounts to an outside contributor's personal conventions vs the project's own patterns. PR reviewers bring valuable fresh eyes but also stylistic baggage — be highly discerning. Use confidence: medium for reviewer-sourced insights (not verified against codebase internals).
```

This step is automatic — do not ask whether to run it.

## Error Handling

- **No gh CLI or token:** Tell user to run `gh auth login` or set `GITHUB_TOKEN`
- **PR not found:** Confirm the PR number and repo access
- **Empty response:** PR may have no comments — confirm with user
- **Rate limited:** Wait and retry, or ask user to try later
