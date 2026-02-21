---
name: pr-correctness
description: "Focused lens review: trace logic paths for correctness bugs in a PR. Use /pr-review for integrated multi-lens coverage."
user_invocable: true
argument_description: "[PR_number_or_URL] — PR to analyze for correctness issues"
---

# /pr-correctness Skill

Focused variant. For holistic coverage, use `/pr-review`.

You are running the **correctness lens** — a focused review that traces logic paths through PR changes to find bugs, boundary errors, and incorrect behavior. This lens complements the 8-point agent-code checklist in `/pr-review`; it targets general correctness concerns, not agent-specific failure modes.

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
- **Changed files** and which contain logic changes (not just config, docs, or formatting)
- **PR intent** from the title, body, and commit messages
- **Existing reviews** — filter out `isOutdated: true` threads. Note any correctness concerns already raised to avoid duplication.

## Step 3: Correctness Analysis

Read the shared review protocol (severity classification, enrichment, findings format):
```bash
cat claude-md/70-review-protocol.md
```

For each file with logic changes, apply this methodology:

**3a. Logic path tracing** — For each changed function or code block, trace all execution paths through the additions. Map the happy path first, then identify branches, early returns, and error paths.

**3b. Boundary conditions** — Check for:
- Off-by-one errors in loops, slicing, indexing
- Null/undefined/empty handling at function entry points and return values
- Type mismatches between what is produced and what is consumed
- Integer overflow, division by zero, or precision loss where numeric operations change

**3c. Error path verification** — For every error that can occur in the changed code:
- Is it caught or propagated?
- Does the error handler match the error type?
- Are resources cleaned up on the error path (file handles, connections, locks)?

**3d. Intent alignment** — Compare the code's actual behavior against its stated intent:
- Does the implementation match what the PR description says it does?
- Do comments in the code match the code's behavior?
- Are commit messages accurate descriptions of what changed?

**Scoping for large diffs:** If more than ~10 files have logic changes, prioritize: (1) files with the most complex logic additions, (2) files touching shared interfaces or public APIs, (3) files handling user input or external data. Apply full methodology to priority files; do a lighter pass on the rest.

## Step 4: Knowledge Enrichment

**Mandatory for every finding.** For each finding, query the knowledge store:
```bash
lore search "<finding topic>" --type knowledge --json --limit 3
```

Attach relevant citations as `knowledge_context` entries in the finding. Follow the enrichment gate and output cap from the shared protocol. If no relevant knowledge is found, set `knowledge_context` to an empty array.

### Investigation Escalation

If a finding involves cross-boundary correctness concerns (invariants spanning multiple files) and the knowledge store has no relevant entries, escalate per the Investigation Escalation protocol in `70-review-protocol.md`. Budget: maximum 2 escalations per lens run.

## Step 5: Write Findings

**5a. Build findings JSON** conforming to the Findings Output Format schema in `claude-md/70-review-protocol.md`:
```json
{
  "lens": "correctness",
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

If the work item already exists, load it instead of creating a duplicate. Append the findings JSON under a `## Correctness Lens` heading in `notes.md` as a fenced JSON code block.

**5d. Notify about posting.** After writing findings, remind the user:
> Findings written to work item. To post as a PR review, run:
> ```bash
> bash ~/.lore/scripts/post-review.sh <findings.json> --pr <PR_NUMBER> [--dry-run]
> ```

## Step 6: Capture

```
/remember PR correctness analysis from PR #<N> — capture: non-obvious correctness patterns, error handling conventions, type safety gotchas discovered in the codebase. Use confidence: medium for reviewer observations. Skip: findings specific to this PR that don't generalize, style preferences, naming opinions.
```

## Error Handling

- **No gh CLI or not authenticated:** Tell user to run `gh auth login`
- **PR not found:** Confirm the PR number and repo access
- **Empty diff:** PR may have no changes — confirm with user
- **No findings:** Report "Correctness lens: no findings" and write empty findings array to the work item
