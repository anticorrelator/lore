---
name: pr-thematic
description: "Focused lens review: evaluate thematic coherence and scope of a PR. Use /pr-review for integrated multi-lens coverage."
user_invocable: true
argument_description: "[PR_number_or_URL] — PR to analyze for thematic coherence and scope creep"
---

# /pr-thematic Skill

Focused variant. For holistic coverage, use `/pr-review`.

You are running the **thematic lens** — a focused review that evaluates whether all changes in a PR support a coherent theme and identifies scope creep or missing pieces. This lens complements the 8-point agent-code checklist in `/pr-review`; it targets thematic coherence and scope alignment, not correctness.

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
- **Changed files** and the nature of each change (new file, modified, deleted)
- **PR intent** from the title, body, and commit messages — this is the primary input for theme synthesis
- **Existing reviews** — filter out `isOutdated: true` threads. Note any scope concerns already raised to avoid duplication.

## Step 3: Thematic Analysis

**3a. Theme synthesis** — Read the PR description and commit messages to synthesize the stated theme/goal of the PR. Express it as a single clear statement: "This PR [verb] [what] [why]." If the PR description is vague or missing, infer the theme from the commit messages and changed files, but flag the missing description as a question finding.

**3b. Per-file alignment mapping** — Walk each changed file and classify its relationship to the theme:
- **Directly supports** — The change is necessary to achieve the stated theme. Without it, the theme would be incomplete.
- **Tangentially related** — The change is related to the theme's area but not strictly required. Examples: opportunistic cleanup in a touched file, related-but-separate improvements.
- **Unrelated** — The change does not connect to the stated theme. Examples: formatting changes in unrelated files, feature additions orthogonal to the PR's purpose, unrelated refactoring.

**3c. Scope creep detection** — Identify changes classified as "tangentially related" or "unrelated" and assess:
- Could these changes be a separate PR without affecting the theme?
- Do they increase review complexity disproportionately to their value?
- Do they introduce risk unrelated to the theme's purpose?

**3d. Missing piece detection** — Based on the stated theme, identify changes that are absent but expected:
- If the theme implies a new feature, are there missing tests?
- If the theme modifies an interface, are all consumers updated?
- If the theme changes behavior, is documentation or configuration updated?
- Missing pieces are findings only when their absence would leave the theme incomplete or broken.

**3e. Produce theme summary** — Output: the synthesized theme statement, a per-file alignment map (file path + classification + brief rationale), and any scope creep or missing piece findings.

**Scoping for large diffs:** If more than ~15 files are changed, group files by directory or module first, then classify groups rather than individual files. Apply per-file analysis only to groups that are tangentially related or unrelated.

## Step 4: Knowledge Enrichment

Read review protocol sections (enrichment, escalation, severity, findings format):
```bash
cat ~/.lore/claude-md/review-protocol/enrichment.md
cat ~/.lore/claude-md/review-protocol/escalation.md
cat ~/.lore/claude-md/review-protocol/severity.md
cat ~/.lore/claude-md/review-protocol/findings-format.md
cat ~/.lore/claude-md/review-protocol/review-voice.md
```

For each finding, query the knowledge store:
```bash
lore search "<finding topic>" --type knowledge --json --limit 3
```

Attach relevant citations as `knowledge_context` entries in the finding. Follow the enrichment gate and output cap from the shared protocol. If no relevant knowledge is found, set `knowledge_context` to an empty array.

### Investigation Escalation

If a finding involves cross-boundary scope concerns (changes that appear unrelated but may have hidden dependencies) and the knowledge store has no relevant entries, escalate per the Investigation Escalation protocol in `claude-md/review-protocol/escalation.md`. Budget: maximum 2 escalations per lens run.

## Step 5: Write Findings

**5a. Build findings JSON** conforming to the Findings Output Format schema:
```json
{
  "lens": "thematic",
  "pr": <PR_NUMBER>,
  "repo": "<OWNER>/<REPO>",
  "findings": [...]
}
```

Classify each finding using the Severity Classification definitions. Default to `suggestion` when uncertain between blocking and suggestion. Typical severity patterns for this lens:
- Unrelated changes that increase risk: **suggestion** (recommend splitting into separate PR)
- Missing pieces that leave the theme broken: **blocking**
- Missing pieces that are nice-to-have: **suggestion**
- Unclear PR description making theme assessment difficult: **question**

**5b. Present findings** to the user. Lead with the theme statement and per-file alignment map, then list findings grouped by severity (blocking first, then suggestions, then questions). For each finding show: severity, title, file:line (when applicable), body, and knowledge context. Strip internal protocol headers (`**Grounding:**`, `**Severity:**`, etc.) from user-visible output — these are internal scaffolding. The grounding content (the concrete scope or coherence concern) must be preserved as the substance of the finding.

**5c. Write to work item.** Create or update the shared lens review work item:
```
/work create pr-lens-review-<PR_NUMBER>
```

If the work item already exists, load it instead of creating a duplicate. Append the findings JSON under a `## Thematic Lens` heading in `notes.md` as a fenced JSON code block.

**5d. Notify about posting.** After writing findings, remind the user:
> Findings written to work item. To post as a PR review, run:
> ```bash
> bash ~/.lore/scripts/post-review.sh <findings.json> --pr <PR_NUMBER> [--dry-run]
> ```

## Step 6: Capture

```
/remember PR thematic analysis from PR #<N> — capture: scope management patterns, PR decomposition conventions, thematic coherence signals discovered in the codebase. Use confidence: medium for reviewer observations. Skip: findings specific to this PR that don't generalize, per-file alignment details, one-off scope decisions.
```

## Error Handling

- **No gh CLI or not authenticated:** Tell user to run `gh auth login`
- **PR not found:** Confirm the PR number and repo access
- **Empty diff:** PR may have no changes — confirm with user
- **No findings:** Report "Thematic lens: no findings" and write empty findings array to the work item
