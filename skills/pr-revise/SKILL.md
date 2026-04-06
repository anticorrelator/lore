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

Load protocol sections for Steps 3-4:

```bash
cat ~/.lore/claude-md/review-protocol/review-selection.md
cat ~/.lore/claude-md/review-protocol/checklist.md
cat ~/.lore/claude-md/review-protocol/enrichment.md
cat ~/.lore/claude-md/review-protocol/escalation.md
```

## Step 3: Select Review Batch and Categorize

**Review Selection:** Follow the Review Selection protocol defined in `~/.lore/claude-md/review-protocol/review-selection.md`. Present fetched reviews as batches grouped by reviewer and let the user select which batch to work through. Only categorize and process comments from the selected batch — other batches are deferred to subsequent invocations.

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

**Grounding:** For each item labeled `issue` or `suggestion`, include a `**Grounding:**` line stating the impact-grounded basis using uncertain language. Use the hedged phrasing patterns from `~/.lore/claude-md/review-protocol/review-voice.md` — key forms:
- `issue`: `**Grounding:** This may cause <what breaks> for <whom> when <conditions>.`
- `suggestion`: `**Grounding:** This could benefit <beneficiary> by <specific improvement>.`

Items without grounding are demoted to `thought` (tracked but not actionable). This prevents reviewer style preferences from being elevated to action items.

**Apply the 8-point review checklist** from `~/.lore/claude-md/review-protocol/checklist.md` as an additional analysis lens when categorizing. Read the checklist at invocation time — do not duplicate it here. The checklist helps distinguish substantive feedback from style preferences.

**Scoping for large diffs:** For PRs touching more than ~10 files, prioritize analysis by: (1) files with blocking/CHANGES_REQUESTED feedback, (2) files with the most review threads, (3) files touching shared interfaces or public APIs. Apply detailed categorization to priority files; batch remaining items by category.

## Step 4: Knowledge Enrichment

**This step is mandatory.** Follow the Knowledge Enrichment Protocol defined in `~/.lore/claude-md/review-protocol/enrichment.md`.

For each feedback item with a substantive label (suggestion, issue, question, thought):

1. Query the knowledge store:
   ```bash
   lore search "<feedback topic>" --type knowledge --json --limit 3
   ```

2. Surface 1-3 compact citations inline with the categorized item. Format: `[knowledge: entry-title]` with a one-line summary of relevance.

3. Check for staleness: if a knowledge entry is STALE and the PR contradicts it, flag as "convention may need updating" — not "PR is wrong."

**This enrichment is critical for /pr-revise specifically:** external reviewers bring fresh eyes but also stylistic baggage. Knowledge enrichment distinguishes project conventions from reviewer preferences. When a reviewer suggests something that contradicts a known convention, the enrichment surfaces the convention so the user can make an informed decision.

**Investigation escalation:** When all three gate conditions are met (substantive label + insufficient knowledge results + multi-file analysis needed), spawn an Explore agent to investigate cross-boundary concerns before finalizing the categorization. Follow the Investigation Escalation procedure in `~/.lore/claude-md/review-protocol/escalation.md`. Maximum 2 escalations per review.

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

> **Next step:** To generate implementation tasks, run `/spec pr-<NUMBER>-<short-slug>` on this work item after investigation validates the findings. The pipeline is: review findings (notes.md) -> `/spec` investigation (plan.md) -> `/implement` execution. Do not skip the `/spec` step — review findings are diff-level hypotheses, not validated implementation plans.

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

## Step 7: Generate Followup Report

This step is mandatory and must not be skipped.

This step is automatic — runs after Step 6, before Step 8.

### 7a. Determine suggested actions

Map feedback categories to followup suggested actions:

| Feedback outcome | `--suggested-actions` primary type |
|-----------------|---|
| Verification Needed items exist | `create_work_item` (spec-needed) |
| Deferred items exist (no Verification Needed) | `create_work_item` (defer rationale) |
| All Agreed Changes only (no Verification Needed, no Deferred) | `create_work_item` (implement-ready) |
| All categories empty (nothing to action) | `approve` |

Produce a suggested-actions JSON array, omitting types for empty categories:

```json
[
  {"type": "create_work_item", "description": "implement-ready: <N> agreed changes"},
  {"type": "create_work_item", "description": "spec-needed: <M> verification items"},
  {"type": "create_work_item", "description": "deferred: <K> items — <defer rationale summary>"}
]
```

### 7b. Assemble the full report body

Assemble the `--content` value with **all** of the following sections. Every section is mandatory — do not abbreviate, summarize, or omit any section. The `--content` passed to `create-followup.sh` must contain the complete report, not a summary.

**First line:** One-line diagnostic summary (e.g., "agreed 3, verification 2, deferred 1 findings from @reviewer's review"). This must be the first non-heading line — it appears as the excerpt in the TUI.

**Section 1 — PR Narrative**

Derive from three sources:
- **PR description and commit messages:** the stated purpose and context of the change, drawn from `gh pr view` output (title, body, commits).
- **Reviewer feedback themes:** recurring concerns or patterns across the selected batch (e.g., "reviewer flagged missing error handling in two places", "two suggestions about naming consistency").
- **Knowledge enrichment context:** any conventions or architectural patterns surfaced by Step 4 enrichment that are relevant to understanding the feedback.

```markdown
## PR Narrative

<1–3 sentences summarizing what the PR does, drawn from its description and commits>

**Reviewer themes:** <patterns or recurring concerns across the feedback batch, or "None" if feedback is isolated>

**Knowledge context:** <relevant conventions or patterns from Step 4 enrichment, or "None" if no relevant citations>
```

Omit **Reviewer themes** if all feedback items are isolated (no recurring patterns). Omit **Knowledge context** if Step 4 produced no citations relevant to the PR's overall direction.

**Section 2 — Implementation Diagram**

Draw an ASCII box-drawing diagram showing the logical flow of the PR's changes as understood from the diff: which components were added or modified, how they connect, and the direction of data or control flow.

Read diagram conventions:
```bash
cat ~/.lore/claude-md/review-protocol/followup-template.md
```

If directional relationships cannot be determined from the diff alone, omit the diagram.

**Section 3 — Review Findings**

List all categorized feedback items from Step 3. Include every item regardless of category — Agreed Changes, Verification Needed, and Deferred are all listed with their full context.

```markdown
## Review Findings

| # | Label | Item | File:Line | Category | Knowledge | Reviewer Quote | Summary |
|---|-------|------|-----------|----------|-----------|----------------|---------|
| 1 | issue | <title> | <file:line> | Agreed Changes | <citation or —> | "<verbatim quote>" | <uncertain framing> |
| 2 | suggestion | <title> | <file:line> | Verification Needed | <citation or —> | "<verbatim quote>" | <uncertain framing> |
| 3 | question | <title> | <file:line> | Deferred | <citation or —> | "<verbatim quote>" | <uncertain framing> |
```

- **Label** column: the Conventional Comments label assigned in Step 3 (`suggestion`, `issue`, `question`, `thought`, `nitpick`, `praise`).
- **Category** column: `Agreed Changes`, `Verification Needed`, or `Deferred`.
- **Knowledge** column: the `[knowledge: entry-title]` citation from Step 4 enrichment, or `—` if no citation applies.
- **Reviewer Quote** column: the verbatim reviewer comment (truncated to ~80 chars if long; use `...` to indicate truncation).
- **Summary** column: impact-grounded uncertain framing derived from the analysis in Step 3. Follow the hedged phrasing patterns in `~/.lore/claude-md/review-protocol/review-voice.md` — key forms: "This may cause..." for issues, "This could benefit..." for suggestions, or the reviewer's open question for question-labeled items. Do not restate the observed code fact — summarize the inferred impact. Do not include internal analysis headers (`**Grounding:**`, `**Severity:**`, etc.) — these are internal protocol language and must not appear in the report.

### 7c. Persist the report

Pass the **complete report body from 7b** as `--content`:

```bash
bash ~/.lore/scripts/create-followup.sh \
  --title "PR #<NUMBER>: <short reviewer name> feedback" \
  --source "pr-revise" \
  --attachments '[{"type":"pr","ref":"#<NUMBER>"}]' \
  --suggested-actions '<json array from 7a>' \
  --content '<complete report body from 7b — all 3 sections>'
```

## Step 8: Capture Insights

**Gate:** Do not execute this step until Step 7 (Generate Followup Report) has completed and `create-followup.sh` has been called. If Step 7 was not executed, go back and execute it now before proceeding.

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
