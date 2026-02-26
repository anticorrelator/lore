---
name: pr-regressions
description: "Focused lens review: detect capability loss from deletions and modifications in a PR. Use /pr-review for integrated multi-lens coverage."
user_invocable: true
argument_description: "[PR_number_or_URL] — PR to analyze for regressions"
---

# /pr-regressions Skill

Focused variant. For holistic coverage, use `/pr-review`.

You are running the **regressions lens** — a focused review that examines deletions and modifications in a PR to detect lost capabilities, broken behavior paths, and unintended removals. This lens complements the 8-point agent-code checklist in `/pr-review`; it targets regression risks, not general correctness concerns.

Findings are structured JSON written to a shared work item. Posting to GitHub is a separate step via `post-review.sh`.

## Step 1: Identify PR

Argument provided: `$ARGUMENTS`

Parse the first token as a PR number (digits) or GitHub URL. Extract the numeric PR identifier.

If no PR identifier is found, ask the user for the PR number.

Resolve the repo owner/name from the git remote:
```bash
REMOTE_URL=$(git remote get-url origin)
```
Extract `OWNER/REPO` from the remote URL.

## Step 2: Fetch PR Data and Diff

```bash
bash ~/.lore/scripts/fetch-pr-data.sh <PR_NUMBER>
```

```bash
gh pr diff <PR_NUMBER>
```

```bash
gh pr view <PR_NUMBER> --json files,title,body,commits
```

From the fetched data, identify:
- **Changed files** and which contain deletions or significant modifications (not just additions, config, docs, or formatting)
- **PR intent** from the title, body, and commit messages
- **Existing reviews** — filter out `isOutdated: true` threads. Note any regression concerns already raised to avoid duplication.

## Step 3: Regression Analysis

Focus on the `-` lines in the diff (deletions) and modifications to existing code. For each file with deletions or significant modifications, apply this methodology:

**3a. Deletion inventory** — Catalog all significant deletions:
- Removed functions, methods, or classes
- Removed conditional branches (if/else arms, switch cases, catch blocks)
- Removed configuration entries, feature flags, or environment bindings
- Removed imports or dependency references

For each deletion, identify what capability it provided.

**3b. Preservation check** — For each significant deletion, determine:
- **Renamed/moved:** Does the same logic appear in the additions under a different name or location? Check for function renames, file moves, and refactored equivalents.
- **Inlined:** Was the deleted code absorbed into a caller or replaced by a simpler expression?
- **Truly removed:** The functionality is gone with no replacement.

Use `git log` on deleted file paths when the diff is ambiguous about whether something was moved:
```bash
git log --oneline --follow -5 -- <deleted-file-path>
```

**3c. Behavioral impact** — For each truly removed or significantly modified capability:
- What callers or dependents relied on it? Trace imports and references.
- Is there a test that exercised the deleted behavior? If that test was also removed, the deletion is intentional but the regression risk should still be flagged.
- Could the removal break downstream consumers or external integrations?

**3d. Modification regression** — For code that was modified (not deleted):
- Does the modified version handle all the cases the original handled?
- Were default values, fallback paths, or backward-compatibility shims removed?
- Did parameter changes narrow the accepted input range?

**Scoping for large diffs:** If more than ~10 files have deletions or modifications, prioritize: (1) files with the largest deletion count, (2) files touching shared interfaces or exports, (3) files modifying error handling or fallback logic. Apply full methodology to priority files; do a lighter pass on the rest.

## Step 4: Knowledge Enrichment

Read the enrichment protocol:
```bash
cat ~/.lore/claude-md/70-review-protocol.md
```

For each finding, query the knowledge store:
```bash
lore search "<finding topic>" --type knowledge --json --limit 3
```

Attach relevant citations as `knowledge_context` entries in the finding. Follow the enrichment gate and output cap from the shared protocol. If no relevant knowledge is found, set `knowledge_context` to an empty array.

### Investigation Escalation

If a finding involves cross-boundary regression concerns (deleted code that may be depended on by modules outside the diff) and the knowledge store has no relevant entries, escalate per the Investigation Escalation protocol in `70-review-protocol.md`. Budget: maximum 2 escalations per lens run.

## Step 5: Write Findings

Read the severity classification and findings output format from:
```bash
cat ~/.lore/claude-md/70-review-protocol.md
```

**5a. Build findings JSON** conforming to the Findings Output Format schema:
```json
{
  "lens": "regressions",
  "pr": <PR_NUMBER>,
  "repo": "<OWNER>/<REPO>",
  "findings": [...]
}
```

Classify each finding using the Severity Classification definitions. Default to `suggestion` when uncertain between blocking and suggestion.

**5b. Present findings** to the user grouped by severity (blocking first, then suggestions, then questions). For each finding show: severity, title, file:line, body, and knowledge context.

**5c. Write to work item.** Create or update the shared lens review work item:
```
/work create pr-lens-review-<PR_NUMBER>
```

If the work item already exists, load it instead of creating a duplicate. Append the findings JSON under a `## Regressions Lens` heading in `notes.md` as a fenced JSON code block.

**5d. Notify about posting.** After writing findings, remind the user:
> Findings written to work item. To post as a PR review, run:
> ```bash
> bash ~/.lore/scripts/post-review.sh <findings.json> --pr <PR_NUMBER> [--dry-run]
> ```

## Step 6: Capture

```
/remember PR regressions analysis from PR #<N> — capture: deletion safety patterns, refactoring preservation conventions, behavioral contract dependencies discovered in the codebase. Use confidence: medium for reviewer observations. Skip: findings specific to this PR that don't generalize, one-off deletion inventories, transient code structure.
```

## Error Handling

- **No gh CLI or not authenticated:** Tell user to run `gh auth login`
- **PR not found:** Confirm the PR number and repo access
- **Empty diff:** PR may have no changes — confirm with user
- **No findings:** Report "Regressions lens: no findings" and write empty findings array to the work item
