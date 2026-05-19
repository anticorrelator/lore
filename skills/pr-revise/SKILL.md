---
name: pr-revise
description: "Read all PR review feedback and create a work item with categorized findings and verification directives"
user_invocable: true
argument_description: "[PR_number_or_URL] [focus context] — PR with feedback to address (or auto-detect from branch). Optional focus context steers which feedback areas to prioritize (e.g., '42 concentrate on the reviewer comments about error handling')"
---

# /pr-revise Skill

Read all comments and reviews on a GitHub Pull Request, categorize feedback with knowledge enrichment, and create a work item with verification directives. Default readiness is `spec-needed` — review findings are hypotheses until verified against the full codebase. The knowledge store helps distinguish "reviewer bringing valid insight" from "reviewer imposing personal preference that contradicts project conventions."

This skill is analysis-only — it creates work items with notes and tasks but does not modify source code.

## Epistemic Stance

Reviewer findings are external hypotheses. The skill's job is to **substantiate or dismiss** each one against code behavior — not to dispatch it as "a comment to address." Three disciplines apply throughout:

- **Symmetric scrutiny.** Apply the same skepticism to the code's current behavior as to the reviewer's claim. If you find yourself writing a defense of the existing code, subject that defense to the same questions you'd ask the reviewer. Asymmetric scrutiny is how a verification item quietly becomes a confirmation of a conclusion you've already written.
- **Trivial reduction check.** Before writing a paragraph of analysis for any item, read the referenced code. If it reduces to a one-liner that makes the reviewer's point obvious, the item belongs in Agreed Changes — move it and stop. Length is not rigor. A correct one-sentence answer beats a thorough-looking audit that misses the structural point.
- **Don't pre-write conclusions.** Verification Needed items state the open question, not the expected outcome. If you already know the answer ("expected: fetch callbacks are stable"), the item is not a verification — it is Agreed or Disagreed. Pre-writing the conclusion turns downstream investigation into defense.

The failure mode this prevents: optimizing for closing the review rather than correctness. A thread is resolved by fixing the code, not only by defending it.

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
gh pr view <PR_NUMBER> --json files,title,body,baseRefName,headRefName,headRefOid
```

Resolve the repo owner/name from the git remote:
```bash
REMOTE_URL=$(git remote get-url origin)
```
Extract `OWNER/REPO` from the remote URL.

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

**Grounding contract:** see `skills/pr-review/SKILL.md` Step 3b. For each item labeled `issue` or `suggestion`, include a `**Grounding:**` line that traces from technical mechanism to observable human/operational consequence, using the hedged phrasing patterns from `~/.lore/claude-md/review-protocol/review-voice.md` — `issue` uses `<mechanism — what may break, for whom, when> → <consequence — what the user experiences>`; `suggestion` uses `<situation — when a real person encounters the problem> → <improvement — what changes for them>`.

For reviewer-sourced findings specifically, grounding comes from the **code's actual behavior**, not the reviewer's framing. Read the referenced function before writing the grounding line. If the code does not support the reviewer's implied consequence, that is a signal the finding is unsound — not a signal to rewrite the reviewer into something defensible.

**Grounding Quality Rubric:** see `skills/pr-review/SKILL.md` Step 4b (Sound / Weak / Unsound). Keep Sound items as-is; rewrite Weak grounding to complete the mechanism→consequence chain (label intact); demote Unsound `issue` to `thought` and drop Unsound `suggestion`.

Items without a grounding line are treated the same as unsound: demote `issue` to `thought`, drop `suggestion`. This prevents reviewer style preferences from being elevated to action items.

**Apply the 8-point review checklist** from `~/.lore/claude-md/review-protocol/checklist.md` as an additional analysis lens. Read it at invocation — do not duplicate it here. The checklist helps distinguish substantive feedback from style preferences.

**Scoping for large diffs:** For PRs touching more than ~10 files, prioritize: (1) files with blocking/CHANGES_REQUESTED feedback, (2) files with the most review threads, (3) files touching shared interfaces or public APIs. Apply detailed categorization to priority files; batch remaining items by category.

## Step 4: Knowledge Enrichment

**This step is mandatory.** Follow the Knowledge Enrichment Protocol defined in `~/.lore/claude-md/review-protocol/enrichment.md`.

For each feedback item with a substantive label (suggestion, issue, question, thought):

1. Query the knowledge store:
   ```bash
   lore search "<feedback topic>" --type knowledge --json --limit 3
   ```

2. Surface 1-3 compact citations inline with the categorized item. Format: `[knowledge: entry-title]` with a one-line summary of relevance.

3. Stale-knowledge flagging: see `skills/pr-review/SKILL.md` Step 4d. If a knowledge entry is STALE and the PR contradicts it, flag as 'convention may need updating' — not 'PR is wrong.'

**This enrichment is critical for /pr-revise specifically:** external reviewers bring fresh eyes but also stylistic baggage. Knowledge enrichment distinguishes project conventions from reviewer preferences. When a reviewer suggests something that contradicts a known convention, the enrichment surfaces the convention so the user can make an informed decision.

**Investigation escalation:** When all three gate conditions are met (substantive label + insufficient knowledge results + multi-file analysis needed), spawn an Explore agent to investigate cross-boundary concerns before finalizing the categorization. Follow the Investigation Escalation procedure in `~/.lore/claude-md/review-protocol/escalation.md`. Maximum 2 escalations per review.

Skip enrichment for nitpick and praise labels.

## Step 5: Create Work Item with Notes

Create a work item from the categorized, enriched feedback:

```
/work create pr-<NUMBER>-<short-slug>
```

Where `<short-slug>` is 2-3 words from the PR title, slugified (e.g., `pr-42-fix-auth-flow`).

Write `notes.md` (not `plan.md`) with feedback organized by actionability. Each item leads with the **substantiated impact claim** (mechanism → consequence derived from reading the code), not a restatement of the reviewer's phrasing. Reviewer quote goes second as evidence. When writing `notes.md`, read `skills/pr-revise/templates/notes-md-template.md` for the structure (Goal / Agreed Changes / Verification Needed / Deferred sections plus the downstream `/spec` pointer).

**Before finalizing each Verification Needed item, run the trivial reduction check:** re-read the referenced function. If it reduces to a one-liner that makes the reviewer's point obvious, move the item to Agreed Changes. This is where asymmetric scrutiny gets caught before it reaches the output — a verification item that you can already answer is not a verification item.

### Readiness assessment

Default readiness is `spec-needed`. Override to `implement-ready` only when ALL of these are true:
- Every item is in "Agreed Changes" (no "Verification Needed" items exist)
- All items are trivially obvious fixes verifiable from the diff alone
- No item touches cross-boundary invariants or shared interfaces

**Only ask the user when:** feedback contradicts project conventions, multiple valid architectural approaches exist, feedback seems incorrect or misunderstood, or the change would have broad implications.

When asking, be specific: "The reviewer suggests X, but convention Y applies here [knowledge: entry-title]. Which should I follow?"

This step is automatic — do not ask whether to create the work item.

## Step 6: Present Summary

When presenting the summary, read `skills/pr-revise/templates/feedback-summary.md` for the `## PR Feedback Summary` output template (header fields, Agreed Changes / Verification Directives / Items needing your input / Deferred batches sub-blocks, and the two follow-up prompts for input items and deferred batches).

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

Assembly preamble: see `skills/pr-review/SKILL.md` Step 6e. Assemble the `--content` value with **all** of the following sections. Every section is mandatory — do not abbreviate, summarize, or omit any section. The `--content` passed to `create-followup.sh` must contain the complete report, not a summary.

**Grounding re-check before assembly.** Re-verify that every `issue` and `suggestion` item still has a specific mechanism → consequence chain per the Sound/Weak/Unsound rubric applied in Step 3. The test: if the PR author asks "why does this matter?", the Summary column must answer with a specific scenario, not a vague assertion. Any item that lacks grounding at this point: demote `issue` to `thought`, drop `suggestion`. Grounding can be lost during grouping or categorization — this pass catches it before the external artifact is written.

**First line:** One-line diagnostic summary (e.g., "agreed 3, verification 2, deferred 1 findings from @reviewer's review"). This must be the first non-heading line — it appears as the excerpt in the TUI.

**Section 1 — PR Narrative**

Derive from three sources:
- **PR description and commit messages:** stated purpose and context from `gh pr view` (title, body, commits).
- **Reviewer feedback themes:** recurring concerns across the selected batch (e.g., "missing error handling in two places").
- **Knowledge enrichment context:** conventions or patterns surfaced by Step 4 that are relevant to the feedback.

```markdown
## PR Narrative

<1–3 sentences summarizing what the PR does>

**Reviewer themes:** <patterns across the feedback batch, or "None">

**Knowledge context:** <relevant conventions from Step 4, or "None">
```

Omit **Reviewer themes** if all feedback items are isolated. Omit **Knowledge context** if Step 4 produced no citations relevant to the PR's overall direction.

**Section 2 — Implementation Diagram**

Draw an ASCII box-drawing diagram showing the logical flow of the PR's changes as understood from the diff: which components were added or modified, how they connect, and the direction of data or control flow.

Diagram conventions: see `skills/pr-review/SKILL.md` Step 6b (reads `~/.lore/claude-md/review-protocol/followup-template.md`).

If directional relationships cannot be determined from the diff alone, omit the diagram.

**Section 3 — Review Findings**

List all categorized feedback items from Step 3. Include every item regardless of category — Agreed Changes, Verification Needed, and Deferred are all listed with their full context. Read `skills/pr-revise/templates/review-findings-table.md` for the table column structure and the per-column shaping rules (Label / Category / Knowledge / Reviewer Quote / Summary, hedged-voice forms by label, and the prohibition on internal protocol headers — per `skills/pr-review/SKILL.md` Step 6d-ii). Voice for the externally-facing Summary column follows `skills/pr-review/SKILL.md:475-484`.

### 7c. Persist the report

Pass the **complete report body from 7b** as `--content`:

```bash
bash ~/.lore/scripts/create-followup.sh \
  --title "PR #<NUMBER>: <short reviewer name> feedback" \  # ≤70 chars
  --source "pr-revise" \
  --attachments '[{"type":"pr","ref":"#<NUMBER>"}]' \
  --suggested-actions '<json array from 7a>' \
  --pr <NUMBER> \
  --owner <owner> \
  --repo <repo> \
  --head-sha <headRefOid> \
  --content '<complete report body from 7b — all 3 sections>' \
  --producer-role "pr-revise" \
  --protocol-slot "Observations"
```

## Step 8: Capture Insights

**Gate:** Do not execute this step until Step 7 (Generate Followup Report) has completed and `create-followup.sh` has been called. If Step 7 was not executed, go back and execute it now before proceeding.

```
/remember PR review feedback from PR #<N> — capture: architectural insights, corrected misconceptions about how the codebase works, non-obvious patterns or invariants the reviewer identified, genuine bugs or correctness issues that reveal something about the system. Skip: style preferences, naming opinions, formatting nits, nitpicking, subjective code taste, "I would have done it differently" suggestions, anything that amounts to an outside contributor's personal conventions vs the project's own patterns. PR reviewers bring valuable fresh eyes but also stylistic baggage — be highly discerning. Use confidence: medium for reviewer-sourced insights (not verified against codebase internals). For every `lore capture` call, pass `--producer-role pr-revise --protocol-slot Synthesis --work-item <slug>` (when a work item matches the PR).
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
