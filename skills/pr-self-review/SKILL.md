---
name: pr-self-review
description: "Prepare your PR for review with structured perspective-shifting analysis"
user_invocable: true
argument_description: "[PR_number_or_URL] — PR to self-review (or auto-detect from branch)"
---

# /pr-self-review Skill

Prepare your code for external review by running structured perspective-shifting analysis against the PR diff. Self-review blindness is structural when reviewing agent-generated code — the same model shares reasoning gaps with the code it generated. This skill counteracts that through explicit perspective shifts and mandatory knowledge enrichment.

Convention drift is the primary detection target: AI-generated code exhibits 3x+ higher convention divergence than human code. The knowledge store makes this tractable.

This skill is analysis-only — it produces an implement-ready work item but does not modify source code.

## Step 1: Identify PR

Argument provided: `$ARGUMENTS`

**If argument provided:** Parse as PR number or URL. If a URL is provided, extract the PR number from it. All subsequent steps use the numeric PR number.

**If no argument:** Detect from current branch:
```bash
gh pr list --state open --head "$(git branch --show-current)" --json number --jq '.[0].number' 2>/dev/null
```

**If detection fails:** Ask the user for the PR number.

## Step 2: Fetch PR Data

Fetch all PR data using the shared script and supplementary commands:

```bash
# Structured comment/review data
bash ~/.lore/scripts/fetch-pr-data.sh <PR_NUMBER>

# Raw diff for analysis
gh pr diff <PR_NUMBER>

# File scope and metadata
gh pr view <PR_NUMBER> --json files,title,body,baseRefName,headRefName
```

## Step 3: Perspective-Shifting Analysis

Apply structured prompts designed to counteract self-review bias. Process each changed file or logical unit through these lenses before applying the checklist.

**Scoping for large diffs:** For PRs touching more than ~10 files, prioritize analysis by: (1) files in identified risk areas from the diff, (2) files with the most additions (new logic over modified logic), (3) files touching shared interfaces or public APIs. Apply the full perspective prompts and checklist to priority files; do a lighter pass on the rest.

**Perspective prompts (apply in order):**

1. **External reviewer lens:** "What would a reviewer unfamiliar with this codebase question about this change?" — surfaces assumptions that feel obvious to the author but aren't documented or self-evident.

2. **Weakest assumption probe:** "What are the weakest assumptions in this change?" — targets the IKEA effect: authors overvalue their own design choices and underestimate fragility.

3. **Cross-boundary invariant trace:** "What invariants in other files does this change depend on? Are they documented or enforced?" — catches the most dangerous class of self-review blind spots: locally correct changes that break non-local contracts.

**Then apply the 8-point review checklist** from the review protocol reference (`claude-md/70-review-protocol.md`). Read the checklist at invocation time — do not duplicate it here.

**Follow the review hierarchy:** architecture > logic > maintainability. An architectural problem makes logic-level findings premature.

For each finding, assign a Conventional Comments label: `suggestion`, `issue`, `question`, `thought`, `nitpick`, or `praise`.

## Step 4: Knowledge Enrichment

**This step is mandatory.** Follow the Knowledge Enrichment Protocol defined in `claude-md/70-review-protocol.md`.

For each finding with a substantive label (suggestion, issue, question, thought):

1. Query the knowledge store:
   ```bash
   lore search "<finding topic>" --type knowledge --json --limit 3
   ```

2. Surface 1-3 compact citations inline with the finding. Format: `[knowledge: entry-title]` with a one-line summary of relevance.

3. Check for staleness: if a knowledge entry is STALE and the PR contradicts it, flag as "convention may need updating" — not "PR is wrong."

**Convention drift is the primary detection target.** Checklist item #3 (convention match) combined with knowledge enrichment catches the most tractable class of agent code defects.

**Investigation escalation:** When all three gate conditions are met (substantive label + insufficient knowledge results + multi-file analysis needed), spawn an Explore agent to investigate cross-boundary concerns before finalizing the finding. Follow the Investigation Escalation procedure in `claude-md/70-review-protocol.md`. Maximum 2 escalations per review.

Skip enrichment for nitpick and praise labels.

## Step 5: Create Work Item

Create an implement-ready work item with phased fix tasks:

```
/work create pr-self-review-<PR_NUMBER>
```

Write `plan.md` structured for direct handoff to `/implement`:

```markdown
# Self-Review: <PR Title>

## Goal
Fix issues identified during self-review before requesting external review.

## Design Decisions
<non-obvious choices surfaced during analysis, with rationale — only if any emerged>

## Phases

### Phase 1: Blocking / Correctness
**Objective:** Fix issues that affect correctness or violate cross-boundary invariants
**Files:** <affected files>
- [ ] <finding with file:line reference and knowledge citation>
- [ ] ...

### Phase 2: Convention Alignment
**Objective:** Align with project conventions (primary value-add of self-review)
**Files:** <affected files>
- [ ] <finding with file:line reference and knowledge citation>
- [ ] ...

### Phase 3: Improvements
**Objective:** Address remaining substantive suggestions
**Files:** <affected files>
- [ ] <finding with file:line reference and knowledge citation>
- [ ] ...
```

Omit empty phases. Group related findings that touch the same file/function. Include the knowledge citation with each finding so `/implement` workers have context.

Generate tasks from the plan:
```
/work tasks pr-self-review-<PR_NUMBER>
```

## Step 6: Present Summary

Present findings framed as reviewer preparation:

```
## Self-Review Summary

**PR:** #<number> — <title>
**Files analyzed:** N
**Findings:** M (K blocking, J convention, L improvement)
**Knowledge enrichments:** X queries, Y citations surfaced
**Investigation escalations:** Z (if any)

### What a reviewer will likely focus on:
- <top concern with brief rationale>
- <second concern>
- ...

### Suggested PR description annotations:
- <context that would help reviewers, surfaced by analysis>

### Work item created:
- `pr-self-review-<PR_NUMBER>` — implement-ready, N tasks
```

## Step 7: Capture Insights

```
/remember Self-review findings from PR #<N> on branch <branch> — capture: convention drift patterns found, cross-boundary invariants identified, architectural concerns surfaced by perspective-shifting prompts. Use confidence: medium (self-review blindness is structural — the reviewing model shares reasoning gaps with the authoring model). Skip: obvious fixes, style issues, findings specific to this PR that don't generalize.
```

This step is automatic — do not ask whether to run it.

## Resuming

If re-invoked on the same PR, check for an existing work item (e.g., `pr-self-review-<PR_NUMBER>` in `/work list`). If found, load it and append new findings to the plan rather than creating a duplicate.

## Error Handling

- **No gh CLI or authentication:** Tell user to run `gh auth login`
- **PR not found:** Confirm PR number and repo access
- **Empty PR (no changes):** Inform user, skip review
- **Knowledge store unavailable:** Continue review without enrichment, note degraded mode in summary
