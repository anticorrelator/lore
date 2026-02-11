---
name: pr-test-quality
description: "Focused lens review: evaluate test coverage, quality, and assertion rigor in a PR"
user_invocable: true
argument_description: "[PR_number_or_URL] — PR to analyze for test coverage and test quality"
---

# /pr-test-quality Skill

You are running the **test quality lens** — a focused review that evaluates whether tests in a PR verify requirements rather than confirm implementation, and whether test coverage matches the scope of changes. This lens complements the 8-point agent-code checklist in `/pr-review`; it provides a more thorough and systematic analysis than checklist item 8 alone.

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
- **Changed files** split into production code and test code
- **PR intent** from the title, body, and commit messages
- **Existing reviews** — filter out `isOutdated: true` threads. Note any test concerns already raised to avoid duplication.

## Step 3: Test Quality Analysis

**3a. Test inventory** — Identify all test files in the diff, and map each test file to the production code it covers. For each production file with logic changes, determine whether a corresponding test file exists:
- In the diff (test was added or modified alongside the code)
- In the repo but not in the diff (existing tests not updated)
- Missing entirely (no test file exists for the changed code)

**3b. Tautological test detection** — For each test in the diff, evaluate whether it tests requirements or merely confirms the implementation:
- Does the test assert expected outcomes based on the feature's requirements, or does it mirror the implementation logic?
- Would the test catch a bug if the implementation were subtly wrong, or would it pass for any implementation that "does something"?
- Are expected values derived from requirements/specifications, or are they copied from what the code happens to produce?
- Flag tests where assertions are trivially derived from the code under test — these provide false confidence.

**3c. Edge case coverage** — For each test, evaluate coverage of non-happy-path scenarios:
- **Boundary conditions:** empty inputs, zero values, maximum values, off-by-one boundaries
- **Error paths:** invalid inputs, missing data, network failures, permission errors
- **State transitions:** initial state, concurrent access, duplicate operations, out-of-order calls
- Flag changed code paths that have no corresponding edge case test.

**3d. Missing test detection** — Identify changed production code without corresponding test changes:
- New functions or methods with no tests
- Changed function behavior with no test updates (tests may exist but still test the old behavior)
- New branches or conditional logic with no branch-specific tests
- Changed error handling with no error path tests

**3e. Assertion quality** — Evaluate the specificity and completeness of test assertions:
- Are assertions specific (checking exact values) or vague (checking truthiness, non-null)?
- Do tests assert on all relevant outputs, or do they check one field and ignore others?
- Are error messages and error types asserted, not just "throws"?
- Flag tests with a high code-to-assertion ratio (lots of setup, few meaningful assertions).

**Scoping for large diffs:** If more than ~10 test files are changed, prioritize: (1) tests for the most complex logic changes, (2) tests for public API changes, (3) newly created test files. Apply full methodology to priority tests; do a lighter pass on the rest.

## Step 4: Knowledge Enrichment

Read the enrichment protocol:
```bash
cat claude-md/70-review-protocol.md
```

For each finding, query the knowledge store:
```bash
lore search "<finding topic>" --type knowledge --json --limit 3
```

Attach relevant citations as `knowledge_context` entries in the finding. Follow the enrichment gate and output cap from the shared protocol. If no relevant knowledge is found, set `knowledge_context` to an empty array.

### Investigation Escalation

If a finding involves test coverage concerns that require understanding untested code paths across multiple files and the knowledge store has no relevant entries, escalate per the Investigation Escalation protocol in `70-review-protocol.md`. Budget: maximum 2 escalations per lens run.

## Step 5: Write Findings

Read the severity classification and findings output format from:
```bash
cat claude-md/70-review-protocol.md
```

**5a. Build findings JSON** conforming to the Findings Output Format schema:
```json
{
  "lens": "test-quality",
  "pr": <PR_NUMBER>,
  "repo": "<OWNER>/<REPO>",
  "findings": [...]
}
```

Classify each finding using the Severity Classification definitions. Default to `suggestion` when uncertain between blocking and suggestion. Typical severity patterns for this lens:
- Tautological tests that provide no regression protection: **suggestion**
- Missing tests for critical code paths (security, data integrity): **blocking**
- Missing tests for non-critical code: **suggestion**
- Missing edge case tests: **suggestion**
- Unclear what a test is verifying: **question**

**5b. Present findings** to the user grouped by severity (blocking first, then suggestions, then questions). For each finding show: severity, title, file:line, body, and knowledge context.

**5c. Write to work item.** Create or update the shared lens review work item:
```
/work create pr-lens-review-<PR_NUMBER>
```

If the work item already exists, load it instead of creating a duplicate. Append the findings JSON under a `## Test Quality Lens` heading in `notes.md` as a fenced JSON code block.

**5d. Notify about posting.** After writing findings, remind the user:
> Findings written to work item. To post as a PR review, run:
> ```bash
> bash ~/.lore/scripts/post-review.sh <findings.json> --pr <PR_NUMBER> [--dry-run]
> ```

## Error Handling

- **No gh CLI or not authenticated:** Tell user to run `gh auth login`
- **PR not found:** Confirm the PR number and repo access
- **Empty diff:** PR may have no changes — confirm with user
- **No findings:** Report "Test quality lens: no findings" and write empty findings array to the work item
