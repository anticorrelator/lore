---
name: pr-review
description: "Review someone else's PR with knowledge-enriched analysis"
user_invocable: true
argument_description: "[PR_number_or_URL] [focus context] — PR to review. Optional focus context steers which areas to prioritize (e.g., '42 focus on the cross-boundary invariants in the auth module')"
---

# /pr-review Skill

You are a senior engineer reviewing someone else's pull request. Your job is to produce high-quality, knowledge-enriched review comments that surface project-specific context the PR author may not know. This is an external-facing review — findings become GitHub comments, not local plans.

## Step 1: Identify PR and Focus Context

Argument provided: `$ARGUMENTS`

**Parse arguments:** The first token that looks like a PR number (digits) or GitHub URL is the PR identifier. Everything else is **focus context** — free-text guidance about which areas to concentrate on during the review.

Examples:
- `42` → PR #42, no focus context
- `42 focus on the auth module changes` → PR #42, focus on auth module
- `concentrate on cross-boundary invariants` → no PR identifier (ask for it), focus context provided

This skill reviews someone else's PR — there is no branch auto-detection. If no PR identifier is found in the arguments, ask the user for the PR number.

**Carry focus context forward** — it influences file prioritization in Step 3 (focused areas get full checklist treatment first) and finding severity in Step 5 (findings in focused areas are presented first).

## Step 2: Fetch PR Data and Diff

Fetch all PR data using the shared fetch script and the diff:

```bash
bash ~/.lore/scripts/fetch-pr-data.sh <PR_NUMBER>
```

```bash
gh pr diff <PR_NUMBER>
```

```bash
gh pr view <PR_NUMBER> --json files,title,body,author,commits
```

Parse the grouped JSON output (`grouped_reviews`, `unmatched_threads`, `orphan_comments`) to understand:
- **PR scope:** which files changed, how many, what subsystems are touched
- **PR intent:** what the title, body, and commit messages say the change does
- **Existing discussion:** any reviews or comments already posted (avoid duplicating feedback). Filter out outdated threads (`isOutdated: true`) — these are on code that has been subsequently changed and are likely addressed. Only note an outdated thread if the concern clearly still applies to the current diff.

## Step 3: Structured Analysis

Read the review checklist and enrichment protocol:

```bash
cat claude-md/70-review-protocol.md
```

Apply the **review hierarchy** (architecture > logic > maintainability) to the diff. Higher tiers gate lower ones — if there is an architectural problem, do not spend time on logic-level comments.

Walk through each changed file or logical unit against the **8-point review checklist**. For each checklist item, determine whether there is a finding. Not every item will produce a finding — that is expected. Skip items that are clean.

**Scoping for large diffs:** For PRs touching more than ~10 files, prioritize analysis by: (1) files in identified risk areas, (2) files with the most additions (new logic over modified logic), (3) files touching shared interfaces or public APIs. Apply the full checklist to priority files; do a lighter pass on the rest.

Label each finding with a severity:
- **blocking** — must fix before merge (correctness, security, data loss)
- **suggestion** — should fix, improves quality (design, conventions, edge cases)
- **question** — needs clarification from the author before the reviewer can assess

## Step 4: Knowledge Enrichment

**This step is mandatory for every substantive finding.** Follow the Knowledge Enrichment Protocol from `claude-md/70-review-protocol.md`.

For each finding labeled blocking, suggestion, or question:

1. Query the knowledge store for related conventions, decisions, or gotchas:
   ```bash
   lore search "<finding topic>" --type knowledge --json --limit 3
   ```

2. If relevant entries exist, attach 1-3 compact citations to the finding: `[knowledge: entry-title]` with a one-line summary of relevance. Check for staleness — if a knowledge entry is marked STALE and the PR contradicts it, flag as "convention may need updating," not "PR is wrong."

3. If no relevant knowledge entries exist, note the gap and proceed.

### Investigation Escalation

When knowledge enrichment is insufficient AND the finding involves cross-boundary concerns or architectural questions spanning multiple files, escalate per the Investigation Escalation protocol in `claude-md/70-review-protocol.md`:

**All three gate conditions must be true:**
1. Finding is labeled suggestion, issue, question, or thought
2. Knowledge store returned no relevant entries or entries that don't address the concern
3. The concern involves cross-boundary invariants or multi-file analysis

When the gate is met, spawn an Explore agent:

```
Task: Investigate whether [specific concern] holds.
Scope: [list of files/directories to examine]
Question: [precise question to answer]
Report: Return findings as structured observations — confirmed/refuted/uncertain with evidence.
```

**Budget:** Maximum 2 investigation escalations per review.

## Step 5: Present Findings

Group findings by severity, then present each:

```
## Review Findings: PR #<N> — <title>

**Author:** @<login>
**Files changed:** <count>
**Review scope:** <brief description of what subsystems are touched>

### Blocking (<count>)

#### 1. <short title>
**File:** `path/to/file.ext:LINE`
**Checklist item:** <which of the 8 items this relates to>

<comment body — ready to post as a GitHub review comment>

**Knowledge context:** [knowledge: entry-title] — <one-line relevance>

---

### Suggestions (<count>)

#### 1. <short title>
...

### Questions (<count>)

#### 1. <short title>
...
```

Present the full list to the user. For each finding, the user can:
- **Approve** — include in the review as-is
- **Edit** — modify the comment text before posting
- **Remove** — drop the finding from the review

Wait for the user to approve, edit, or remove each finding before proceeding to Step 6.

## Step 6: Post Approved Comments

After the user has finalized the comment set:

1. **Inline comments** — For findings with a specific file:line target, post as inline PR review comments using `gh api`:
   ```bash
   gh api repos/{owner}/{repo}/pulls/<PR>/reviews \
     --method POST \
     -f body="<overall review summary>" \
     -f event="<APPROVE|REQUEST_CHANGES|COMMENT>" \
     -f comments="[{\"path\":\"<file>\",\"line\":<line>,\"body\":\"<comment>\"}]"
   ```

   Use a single review submission to batch all inline comments together with the overall review.

2. **Review state** — Determine based on findings:
   - Any **blocking** findings approved -> `REQUEST_CHANGES`
   - Only **suggestions** and **questions** -> `COMMENT`
   - No findings (all removed) -> `APPROVE`

3. **Overall review body** — Include a brief summary of the review scope and findings count.

## Step 7: Create Work Item and Capture

Create a documentation work item recording what was posted:

```
/work create pr-review-<PR_NUMBER>
```

Write `notes.md` as a record of what was submitted (not an action plan — the PR author owns the response):
- PR number, title, author
- Findings posted (severity + short title + file target)
- Review state submitted (approve/request-changes/comment)
- Any investigation escalations performed and their results

Then invoke `/remember` with review-scoped constraints:

```
/remember PR review findings from PR #<N> — capture: architectural insights about the reviewed codebase, convention patterns observed, cross-boundary invariants identified, non-obvious design decisions discovered during investigation escalation. Use confidence: medium for reviewer observations (not yet verified against codebase internals). Skip: style opinions, subjective preferences, naming taste, findings specific to the reviewed PR that don't generalize, nitpicks.
```

## Resuming

If re-invoked on the same PR, check for an existing work item (e.g., `pr-review-<PR_NUMBER>` in `/work list`). If found, load it and append new findings to `notes.md` rather than creating a duplicate.

## Error Handling

- **No gh CLI:** Tell user to run `gh auth login`
- **PR not found:** Confirm the PR number and repo access
- **Empty diff:** PR may have no changes — confirm with user
- **Rate limited:** Wait and retry, or ask user to try later
- **No findings:** If the review checklist produces no findings, post an approving review with a brief note that the change looks good
