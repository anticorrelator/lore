---
name: pr-user-impact
description: "Focused lens review: evaluate user and developer impact of design decisions in a PR. Use /pr-review for integrated multi-lens coverage."
user_invocable: true
argument_description: "[PR_number_or_URL] — PR to analyze for user impact of design decisions"
---

# /pr-user-impact Skill

Focused variant. For holistic coverage, use `/pr-review`.

You are running the **user impact lens** — a focused review that evaluates whether PR changes degrade, break, or silently alter workflows for interactive users, integrators, and developers. This lens targets design decisions whose consequences are visible outside the codebase: CLI behavior changes, output format shifts, error message regressions, and behavioral contract violations.

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
- **Changed files** and which contain user-facing changes (CLI flags, config options, output formats, error messages, behavioral contracts, API response shapes)
- **PR intent** from the title, body, and commit messages
- **Existing reviews** — filter out `isOutdated: true` threads. Note any user impact concerns already raised to avoid duplication.

## Step 3: User Impact Analysis

This lens evaluates changes through the workflows of three actor classes:

| Actor class | Definition | Grounding pattern |
|---|---|---|
| **Interactive users** | Humans running CLI commands or navigating UI | "User runs X, sees Y, expected Z" |
| **Integrators** | Scripts, CI pipelines, programmatic consumers | "Script parsing `.items` breaks when schema changes to `.results`" |
| **Developers** | Contributors extending, configuring, or debugging | "Developer debugging X must now also understand Y" |

The "developers" class is scoped to workflow-level friction (debugging, configuring, extending), not code-level legibility — code legibility belongs to the interface-clarity lens.

**Lens boundary:** Report when the evidence is a human or script workflow consequence. Defer when the evidence is only a code-consumer consequence (blast-radius lens) or a code legibility issue (interface-clarity lens).

| Evidence type | Owner |
|---|---|
| Workflow friction for users/integrators/developers | **user-impact** |
| Code legibility or naming confusion | interface-clarity |
| Code consumer breakage (callers, importers) | blast-radius |

For each file with user-facing changes, apply this methodology:

**3a. Workflow impact analysis** — Evaluate capabilities added, removed, or degraded across all actor classes:
- Does this change remove or rename a CLI flag, subcommand, config key, or output field that users or scripts depend on?
- Does it change default behavior in a way that silently alters existing workflows?
- Is there a migration path for breaking changes (deprecation warning, version flag, documentation)?
- For new capabilities: are they discoverable through help text, error messages, or existing patterns?

**3b. Design trade-off evaluation** — Assess whether design choices balance competing concerns proportionately:
- Convenience vs. safety — does the change make a dangerous operation easier without adding guardrails?
- Flexibility vs. simplicity — does new configurability add cognitive load without clear benefit to the target audience?
- Discoverability vs. power-user efficiency — does the change bury common operations or expose advanced internals inappropriately?
- A proportionate trade-off is not a finding. Only report when the trade-off is clearly lopsided or when the losing side is not acknowledged.

**3c. Error and failure UX** — Check whether error paths are actionable and recoverable:
- Do new or changed error messages tell the user what went wrong AND what to do about it?
- Are internal implementation details (stack traces, internal state names, raw error codes) leaking into user-visible error output?
- Can the user recover from the error state, or does the failure leave them stuck without guidance?
- Are error messages consistent with the existing tone and format in the codebase?

**3d. Assumption surfacing** — Identify embedded assumptions about user behavior, mental models, or workflows:
- Does the change assume users will read documentation before using a new feature?
- Does it assume a specific invocation order, environment setup, or prior knowledge that isn't enforced or validated?
- Are there assumptions about workflow patterns that are contradicted by how the tool is actually used (check existing tests, scripts, CI configs for evidence)?

**3e. Finding grounding** — For each candidate finding, state the specific actor class, the workflow, and the concrete before/after degradation before writing it up:
- Which actor class is affected (interactive user, integrator, or developer)?
- What specific workflow is degraded, and what did it look like before vs. after?
- What is the user-visible consequence (broken script, confusing output, lost capability, silent behavior change)?

A finding without a concrete workflow degradation is not ready to report. Ground every finding before moving to Step 4.

**Finding placement rules:**
1. Exact contract change (flag renamed, output field removed) — inline with file and line
2. Primary contract change spanning several lines — inline at the main change
3. File-scoped concern (e.g., all error messages in a file lack guidance) — file-level, no line
4. Emergent cross-file concern (e.g., behavioral inconsistency across commands) — PR-level, no file or line

Preference order: inline > file-level > PR-level.

| | Example |
|---|---|
| **Ungrounded** | "this changes CLI behavior" |
| **Grounded** | "Interactive user running `lore search --json` gets results in a `results` array — this PR renames it to `items`, breaking any script parsing the previous `.results` field with no deprecation warning or migration path" |

**Scoping for large diffs:** If more than ~10 files have user-facing changes, prioritize: (1) files that define or modify CLI commands, flags, or output formats, (2) files that change error messages or validation logic, (3) files that alter behavioral contracts or defaults. Apply full methodology to priority files; do a lighter pass on the rest.

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

If a finding involves deep cross-boundary impact (workflow consequences spanning multiple user-facing surfaces where actor behavior is unclear) and the knowledge store has no relevant entries, escalate per the Investigation Escalation protocol in `claude-md/review-protocol/escalation.md`. Budget: maximum 2 escalations per lens run.

## Step 5: Write Findings

**5a. Build findings JSON** conforming to the Findings Output Format schema in `claude-md/review-protocol/findings-format.md`:
```json
{
  "lens": "user-impact",
  "pr": <PR_NUMBER>,
  "repo": "<OWNER>/<REPO>",
  "findings": [...]
}
```

Classify each finding using the Severity Classification definitions. Default to `suggestion` when uncertain between blocking and suggestion. Typical severity patterns for this lens:
- Breaking change removing or degrading a user workflow with no migration path: **blocking**
- Design imposing unnecessary friction, non-actionable errors, workflow that could be simplified: **suggestion**
- Unclear user population or whether users perform this workflow: **question**

**5b. Present findings** to the user grouped by severity (blocking first, then suggestions, then questions). For each finding show: severity, title, file:line, affected actor class, body, and knowledge context. Strip internal protocol headers (`**Grounding:**`, `**Severity:**`, etc.) from user-visible output — these are internal scaffolding. The grounding content (the concrete workflow degradation claim) must be preserved as the substance of the finding.

**5c. Write to work item.** Create or update the shared lens review work item:
```
/work create pr-lens-review-<PR_NUMBER>
```

If the work item already exists, load it instead of creating a duplicate. Append the findings JSON under a `## User Impact Lens` heading in `notes.md` as a fenced JSON code block.

**5d. Notify about posting.** After writing findings, remind the user:
> Findings written to work item. To post as a PR review, run:
> ```bash
> bash ~/.lore/scripts/post-review.sh <findings.json> --pr <PR_NUMBER> [--dry-run]
> ```

## Step 6: Capture

```
/remember PR user impact analysis from PR #<N> — capture: user-impact design trade-offs, workflow assumptions, UX patterns discovered in the codebase. Use confidence: medium for reviewer observations. Skip: findings specific to this PR that don't generalize, subjective preferences without concrete user impact.
```

## Error Handling

- **No gh CLI or not authenticated:** Tell user to run `gh auth login`
- **PR not found:** Confirm the PR number and repo access
- **Empty diff:** PR may have no changes — confirm with user
- **No findings:** Report "User impact lens: no findings" and write empty findings array to the work item

## Error Handling

- **No gh CLI or not authenticated:** Tell user to run `gh auth login`
- **PR not found:** Confirm the PR number and repo access
- **Empty diff:** PR may have no changes — confirm with user
- **No findings:** Report "User impact lens: no findings" and write empty findings array to the work item
