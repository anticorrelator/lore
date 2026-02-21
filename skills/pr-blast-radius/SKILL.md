---
name: pr-blast-radius
description: "Focused lens review: trace the impact of PR changes on code outside the diff. Use /pr-review for integrated multi-lens coverage."
user_invocable: true
argument_description: "[PR_number_or_URL] — PR to analyze for impact on consumers and dependents outside the diff"
---

# /pr-blast-radius Skill

Focused variant. For holistic coverage, use `/pr-review`.

You are running the **blast radius lens** — a focused review that traces the impact of PR changes on code outside the diff. This lens identifies files, modules, and consumers NOT in the PR that are affected by the changes. It complements the 8-point agent-code checklist in `/pr-review`; it targets downstream impact, not correctness of the changed code itself.

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
- **Changed files** and which contain interface, type, or export changes
- **PR intent** from the title, body, and commit messages
- **Existing reviews** — filter out `isOutdated: true` threads. Note any impact concerns already raised to avoid duplication.

## Step 3: Blast Radius Analysis

This lens inherently requires multi-file exploration beyond the diff. Prioritize investigation based on the type of change.

**3a. Export and interface changes** — For each changed export, public function, class, or type definition:
- Search for all consumers using Grep: `rg "import.*<name>" --type <lang>` or equivalent patterns
- For each consumer NOT in the diff: does the change break the consumer's usage? Check argument counts, return types, removed fields, renamed exports.
- Flag any consumer that imports a changed interface but is not updated in this PR.

**3b. Function signature changes** — For each function whose signature changed (parameters added/removed/reordered, return type changed):
- Find all callers: `rg "<function_name>\(" --type <lang>`
- For each caller NOT in the diff: does the call site match the new signature?
- Pay special attention to optional-to-required parameter changes and narrowed return types.

**3c. Configuration and schema changes** — For each changed config file, schema definition, or environment variable:
- Trace downstream consumers: what code reads this config? `rg "<config_key>"` across the codebase.
- Check for: removed keys that code still reads, changed defaults, renamed fields.
- For schema changes: are migrations, validators, or serializers updated?

**3d. Behavioral contract changes** — For code where the observable behavior changes (different side effects, different error types, different ordering) even if the type signature is unchanged:
- Identify callers that may depend on the previous behavior.
- Flag implicit contract changes that type systems cannot catch: changed error messages that callers parse, changed event ordering, changed timing characteristics.

**Scoping for large diffs:** If more than ~10 files have interface or export changes, prioritize: (1) changes to shared libraries or utility modules, (2) changes to public APIs or external interfaces, (3) changes to types or schemas used across module boundaries. Apply full methodology to priority changes; do a lighter pass on the rest.

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

If a finding involves deep cross-boundary impact (invariants spanning multiple modules where consumer behavior is unclear) and the knowledge store has no relevant entries, escalate per the Investigation Escalation protocol in `70-review-protocol.md`. Budget: maximum 2 escalations per lens run.

## Step 5: Write Findings

Read the severity classification and findings output format from:
```bash
cat claude-md/70-review-protocol.md
```

**5a. Build findings JSON** conforming to the Findings Output Format schema:
```json
{
  "lens": "blast-radius",
  "pr": <PR_NUMBER>,
  "repo": "<OWNER>/<REPO>",
  "findings": [...]
}
```

Classify each finding using the Severity Classification definitions. Default to `suggestion` when uncertain between blocking and suggestion. Typical severity patterns for this lens:
- Consumers broken by interface changes: **blocking**
- Consumers that may need updating but still function: **suggestion**
- Unclear whether consumers depend on changed behavior: **question**

**5b. Present findings** to the user grouped by severity (blocking first, then suggestions, then questions). For each finding show: severity, title, file:line of the change in the diff, affected files outside the diff, body, and knowledge context.

**5c. Write to work item.** Create or update the shared lens review work item:
```
/work create pr-lens-review-<PR_NUMBER>
```

If the work item already exists, load it instead of creating a duplicate. Append the findings JSON under a `## Blast Radius Lens` heading in `notes.md` as a fenced JSON code block.

**5d. Notify about posting.** After writing findings, remind the user:
> Findings written to work item. To post as a PR review, run:
> ```bash
> bash ~/.lore/scripts/post-review.sh <findings.json> --pr <PR_NUMBER> [--dry-run]
> ```

## Step 6: Capture

```
/remember PR blast radius analysis from PR #<N> — capture: cross-module dependency patterns, interface contract conventions, consumer update requirements discovered in the codebase. Use confidence: medium for reviewer observations. Skip: findings specific to this PR that don't generalize, one-off consumer lists, repo-specific import topology.
```

## Error Handling

- **No gh CLI or not authenticated:** Tell user to run `gh auth login`
- **PR not found:** Confirm the PR number and repo access
- **Empty diff:** PR may have no changes — confirm with user
- **No findings:** Report "Blast radius lens: no findings" and write empty findings array to the work item
