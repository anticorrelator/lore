---
name: pr-self-review
description: "Author-calibrated self-review: parallel lens pre-scan (Blast Radius, Security, Test Quality, Correctness, Regressions, Interface Clarity, User Impact) then auto-disposition findings into a followup sidecar for TUI triage"
user_invocable: true
argument_description: "[PR_number_or_URL] [--skip-pre-scan] [focus context] — PR to self-review (or auto-detect from branch). --skip-pre-scan skips the lens team and uses heuristic auto-disposition instead. Optional focus context steers finding priority (e.g., '42 focus on error handling')"
---

# /pr-self-review Skill

Author-calibrated self-review combining structured lens analysis with automatic disposition. A parallel lens team (Blast Radius, Security, Test Quality, Correctness, Regressions, Interface Clarity, User Impact) runs a pre-scan, then findings are auto-dispositioned and persisted as a followup sidecar (`lens-findings.json`) for interactive TUI triage via the per-finding action menu.

Since this is your own work, locally-scoped action items can be implement-ready. Findings with cross-boundary implications (especially from Blast Radius) get verification directives instead.

This skill does not modify source code. Interactive finding review happens in the TUI Triage tab, not in this skill's dialog.

## Step 1: Setup

Argument provided: `$ARGUMENTS`

### 1a. Parse arguments

**Parse flags:** If `--skip-pre-scan` is present, set a flag to skip the lens scan (Step 2). Strip the flag before further parsing.

**Parse arguments:** The first token that looks like a PR number (digits) or GitHub URL is the PR identifier. Everything else is **focus context** — free-text guidance about which areas to concentrate on.

**If no PR identifier:** Detect from current branch:
```bash
gh pr list --state open --head "$(git branch --show-current)" --json number,baseRefName --jq '.[] | "#\(.number) → \(.baseRefName)"' 2>/dev/null
```

**If multiple PRs found:** Present the list and ask the user which one to review.

**If no PRs found:** Ask for the PR number or the base branch to diff against. If only a base branch is provided, fall back to `git diff <base>...HEAD` and skip comment fetching.

### 1b. Fetch PR data

```bash
bash ~/.lore/scripts/fetch-pr-data.sh <PR_NUMBER>
gh pr diff <PR_NUMBER>
gh pr view <PR_NUMBER> --json files,title,body,baseRefName,headRefName,commits,headRefOid
```

Resolve the repo owner/name from the git remote:
```bash
REMOTE_URL=$(git remote get-url origin)
```
Extract `OWNER/REPO` from the remote URL.

Note any existing reviewer feedback to avoid duplicating observations.

### 1c. Triage summary

**Skip if `--skip-pre-scan` was set.**

Compute total LOC changed.

**Ceremony config lookup:** After assembling the built-in lens set, check for ceremony-configured lenses:

```bash
lore ceremony get pr-review
```

If the result is non-empty (not `[]`), append each returned skill to the lens set. Ceremony lenses are not subject to adaptive skip conditions — they always run when configured.

Display and proceed immediately (no confirmation gate):

```
[pr-self-review] Triage
Size: <N> LOC across <M> files
Lenses: Blast Radius · Security · Test Quality · Correctness · Regressions · Interface Clarity · User Impact · [ceremony] insecure-defaults
```

If the diff exceeds 400 LOC, append: `Size: <N> LOC (large — consider --skip-pre-scan for targeted exploration)`

## Step 2: Lens Scan

**Skip this entire step if `--skip-pre-scan` was set.**

### 2a. Build review context

Walk each changed file and classify its relationship to the PR's purpose:
- **Directly supports** — necessary to achieve the PR's goal
- **Tangentially related** — related but not strictly required
- **Unrelated** — no connection to the PR's goal

For large diffs (>15 files), group by directory/module first.

Identify design signals for lens agents (architectural patterns, cross-cutting concerns, risk areas, missing pieces).

Structure as a context block:

```
## Self-Review Context

**Alignment map:**
| File | Classification | Notes |
|------|---------------|-------|
| path/to/file.ext | Directly supports | <brief rationale> |

**Design signals:**
- <signal 1>
- <signal 2>
```

### 2b. Spawn lens agents

For each selected lens, read its Step 3 methodology:

| Lens | Source | Step 3 heading |
|------|--------|---------------|
| Blast Radius | `skills/pr-blast-radius/SKILL.md` | Blast Radius Analysis |
| Security | `claude-md/review-protocol/security-methodology.md` | Security Lens Methodology |
| Test Quality | `skills/pr-test-quality/SKILL.md` | Test Quality Analysis |
| Correctness | `skills/pr-correctness/SKILL.md` | Correctness Analysis |
| Regressions | `skills/pr-regressions/SKILL.md` | Regressions Analysis |
| Interface Clarity | `skills/pr-interface-clarity/SKILL.md` | Interface Clarity Analysis |
| User Impact | `skills/pr-user-impact/SKILL.md` | User Impact Analysis |

For each lens, create a task:

```
# <Lens Name> Lens — PR #<number> (Self-Review Pre-Scan)

You are a lens review agent analyzing PR #<number> in <owner>/<repo>.
Your sole focus is the <lens name> lens. Apply only this methodology.

## PR Context
- **Title:** <title>
- **Author:** @<author> (this is the author's own self-review)
- **Files changed:** <count>
- **Existing review concerns:** <summary of relevant prior comments, or "None">

<Self-Review Context block from 2a>

## Diff

<inline diff for <=400 LOC, or:>
Read the diff from: /tmp/pr-self-review-<PR_NUMBER>.diff

## Methodology

<verbatim Step 3 content from the lens's source>

## Output

Produce findings JSON conforming to the Findings Output Format:
- lens: "<lens-id>"
- pr: <number>
- repo: "<owner>/<repo>"
- Severity: blocking / suggestion / question (default to suggestion when uncertain)
- Each finding: severity, title, file, line, body, knowledge_context

Every finding with severity `blocking` or `suggestion` MUST include a `**Grounding:**` line in the body that traces from technical mechanism to observable human/operational consequence:
- blocking: `**Grounding:** <mechanism — what breaks, for whom, when> → <consequence — what the user experiences or what operational impact follows>.`
- suggestion: `**Grounding:** <situation — when a real person encounters the problem> → <improvement — what changes for them>.`

Grounding that stops at the technical mechanism without landing on a human/operational consequence is weak and will be rewritten during synthesis. Findings without a `**Grounding:**` line will be downgraded or dropped.

Query the knowledge store for each finding:
```bash
lore search "<topic>" --type knowledge --json --limit 3
```

Report back with your findings JSON when complete.
```

**Correctness lens modification:** Append: "Skip step 3d (intent alignment). The author already knows the intent."

Spawn one agent per lens in parallel. Maximum 7 concurrent agents. For diffs >400 LOC, write the diff to `/tmp/pr-self-review-<PR_NUMBER>.diff` before spawning.

### 2b-ceremony. Dispatch ceremony lenses

After built-in lens agents are spawned, dispatch any ceremony lenses from the selected set (those tagged `[ceremony]` in Step 1c).

**PR guard:** If running in base-branch-only mode (no PR number — the user provided only a base branch to diff against), skip ceremony lens dispatch entirely:
```
[ceremony] Skipped: no PR number available
```

When a PR number is available, invoke each ceremony lens via the Skill tool with the PR number as the sole argument:

```
/<skill-name> <PR_NUMBER>
```

Ceremony lenses fetch their own PR data — do **not** pass diff content, review context, or metadata. Run all ceremony lens invocations in parallel.

Ceremony lens results are collected alongside built-in lens results in Step 2c. If a ceremony lens does not produce findings in the standard Findings Output Format, its output is handled as non-conforming during synthesis.

### 2c. Collect and synthesize

Collect findings from lens agents as they complete. If a lens agent fails or times out, proceed with available findings and note the coverage gap.

**Ceremony lens two-tier classification:** For each ceremony lens result, check whether the output conforms to the Findings Output Format (`lens`, `pr`, `repo`, `findings[]` with each finding having `severity`, `title`, `file`, `line`, `body`):

- **Conforming:** Include findings in the synthesis pipeline below alongside built-in lens findings. These participate in compound detection, severity grouping, and deduplication. Conforming ceremony findings appear in the dialog findings list (Step 3).
- **Non-conforming:** Store the raw output separately as a supplementary report. Tag it with the ceremony lens name. Non-conforming output does **not** enter synthesis or the dialog — it is presented in the summary (Step 4).
- **Malformed JSON:** Treat as non-conforming with an additional `[malformed]` tag. Store the raw text for supplementary presentation.
- **Failure/timeout:** Note the coverage gap in the summary. The review continues with available findings.

Clean up the temp diff file:
```bash
rm -f /tmp/pr-self-review-<PR_NUMBER>.diff
```

**Compound findings:** Group by `file`. Within each file, findings from different lenses within 3 lines of each other form a compound finding. Apply severity elevation and merge.

**Grounding check:** For each `blocking` or `suggestion` finding, verify it has a `**Grounding:**` line. Ungrounded blocking → downgrade to suggestion. Ungrounded suggestion → drop.

**Deduplicate:** Same file, overlapping line, same severity, same concern — keep the more detailed body. Do NOT deduplicate different concerns at the same location.

Display summary:
```
[pr-self-review] Lens scan complete: <N> findings (<K> blocking, <J> suggestions, <Q> questions) across <L> lenses
```

### 2d. Persist findings for resume

```
/work create pr-self-review-<PR_NUMBER> --pr <PR_NUMBER>
```

Write the synthesized findings to `notes.md` under a `## Lens Scan` heading:

```markdown
## Lens Scan
<timestamp> | Lenses: <list> | Findings: <count>

| # | Severity | Title | Lens | File:Line | Disposition |
|---|----------|-------|------|-----------|-------------|
| 1 | blocking | <title> | <lens> | <file:line> | — |
| 2 | suggestion | <title> | <lens> | <file:line> | — |
```

The `Disposition` column starts as `—` and is filled during Step 3 auto-disposition.

## Step 3: Auto-Disposition

Read protocol sections:
```bash
cat ~/.lore/claude-md/review-protocol/cross-lens-synthesis.md
cat ~/.lore/claude-md/review-protocol/enrichment.md
cat ~/.lore/claude-md/review-protocol/checklist.md
```

### 3a. Disposition all findings automatically

Apply dispositions to every finding using your best judgment as the PR author:

**Disposition rules:**
- `blocking` findings → `action` (these need fixes)
- Compound findings (multiple lenses converging) → `action`
- Suggestions with cross-boundary implications (Blast Radius, public API changes) → `action`
- `question` findings where you can answer from diff and codebase context → `accepted`
- Locally scoped, low-risk suggestions with obvious answers:
  - Clear style/convention nits → `accepted`
  - Missing test coverage for trivial branches → `action`
  - Naming suggestions with no semantic impact → `accepted`
- Ambiguous findings where the correct call is genuinely uncertain → `open` (the user will triage these in the TUI)

**When in doubt, use `open`.** The TUI Triage tab's per-finding action menu lets the user change dispositions, launch scoped chats, and customize responses — uncertain findings are better left for interactive triage than auto-resolved incorrectly.

For each finding, record a one-line rationale explaining the disposition choice.

**Heuristic fallback:** If the pre-scan produced zero findings or `--skip-pre-scan` was set, scan the diff for risk concentration, complexity, and architectural decisions. Generate findings using perspective lenses:
1. "What would a reviewer unfamiliar with this codebase question?"
2. "What are the weakest assumptions in this change?"
3. "What invariants in other files does this change depend on?"

Enrich heuristic observations via `lore search` before generating findings.

### 3b. Present disposition summary

Display the full disposition table (no confirmation gate — proceed immediately to Step 4):

```
## Self-Review: #<N> — <title>

**Branch:** <head> → <base>
**Scope:** <N files, brief characterization>

| # | Severity | Title | Lens | File:Line | Disposition | Rationale |
|---|----------|-------|------|-----------|-------------|-----------|
| 1 | blocking | <title> | <lens> | <file:line> | action | <one-line reason> |
| 2 | suggestion | <title> | <lens> | <file:line> | accepted | <one-line reason> |
| 3 | suggestion | <title> | <lens> | <file:line> | open | <one-line reason> |
...

Dispositions: <A> action, <C> accepted, <D> deferred, <O> open
→ Creating followup for TUI triage
```

**Ceremony lens findings:** Conforming ceremony lens findings are included in the table above. If any ceremony lenses produced non-conforming output, append:

```
Supplementary reports: <skill-name>, <skill-name> (non-standard format — see Step 4 summary)
```

## Step 4: Work Item and Summary

Collect all auto-dispositioned findings from Step 3.

### No action items path

If all findings were dispositioned as `accepted` or `deferred` (zero `action` items), skip work item creation. Report:

```
Reviewed and confirmed: <N> findings examined, no changes needed (<K> accepted, <L> deferred)
```

Proceed to Step 4.5 (followup creation is unconditional — all review outcomes produce a followup record).

### Create plan

```
/work create pr-self-review-<PR_NUMBER> --pr <PR_NUMBER>
```

Write `plan.md` structured for `/implement`:

```markdown
# Self-Review: <PR Title>

> **Review-level analysis.** These findings came from a multi-lens pre-scan and confirmatory dialog. Investigation agents should verify assumptions against the full codebase.

## Goal
Address findings from self-review dialog before requesting external review.

## Design Decisions
<non-obvious choices surfaced during discussion — only if any emerged>

## Phases

### Phase 1: Blocking / Correctness
**Objective:** Fix issues that affect correctness or violate cross-boundary invariants
**Files:** <affected files>
- [ ] <finding title> [<lens>] — <file:line> — <one-line action>

### Phase 2: Convention Alignment
**Objective:** Align with project conventions
**Files:** <affected files>
- [ ] <finding title> [<lens>] — <file:line> — <one-line action>

### Phase 3: Improvements
**Objective:** Address remaining suggestions
**Files:** <affected files>
- [ ] <finding title> [<lens>] — <file:line> — <one-line action>

### Phase 4: Reviewed and Confirmed
- <finding title> [<lens>] — Confirmed fine because: <rationale>

### Deferred / Open
- <finding title> [<lens>] — Deferred: <reason> | Open: <what needs resolution>
```

**Phase mapping:**
- Phase 1: disposition=`action` AND (blocking OR compound)
- Phase 2: disposition=`action` AND suggestion AND convention signal
- Phase 3: disposition=`action` AND remaining
- Phase 4: disposition=`accepted`
- Deferred/Open: disposition=`deferred` or `open`

Omit empty phases.

**Verification directives** for cross-boundary items:
```
- [ ] **[verify]** <hypothesis> — Verify whether <assumption> holds in `<file:function>` before implementing
```

Assess readiness: `implement-ready` if all items are locally scoped, `spec-needed` if any have verification directives.

Generate tasks:
```
/work tasks pr-self-review-<PR_NUMBER>
```

### Present summary

```
## Self-Review Complete

**PR:** #<number> — <title>
**Lens coverage:** <L> lenses, <N> findings (<K> blocking, <J> suggestions, <Q> questions)
**Dispositions:** <A> action, <C> accepted, <D> deferred, <O> open

### Auto-disposition highlights:
- <key insight or notable finding from the scan>

### Supplementary Reports
<skill-name> [ceremony] — non-standard format, presented verbatim

### Work item: <slug if created, or "none — reviewed and confirmed"> (<readiness>)
  Phase 1 (Blocking): <count> tasks
  Phase 2 (Convention): <count> tasks
  Phase 3 (Improvements): <count> tasks
```

If ceremony lenses ran, include them in the lens coverage count. Show: `**Lens coverage:** <L> lenses (<M> ceremony), <N> findings (<K> blocking, <J> suggestions, <Q> questions)`

If lenses ran in degraded mode, show: `**Lens coverage:** <L>/<T> lenses (<degraded names> degraded), <N> findings`

The `### Supplementary Reports` section appears **only** when non-conforming ceremony lens output exists. Omit entirely when all ceremony lenses were conforming or no ceremony lenses ran.

Omit zero counts. Omit work item section if no-action-items path was taken.

## Step 4.5: Create Followup Record

**This step runs unconditionally** — both the action-items path and the no-action-items path produce a followup record. The followup persists the review outcome for TUI browsing regardless of whether a work item was created.

### Assemble lens-findings.json

Build the `lens-findings.json` payload from the in-memory dispositioned findings (do NOT re-parse notes.md):

```json
{
  "pr": <PR_NUMBER>,
  "work_item": "pr-self-review-<PR_NUMBER>",
  "findings": [
    {
      "severity": "<blocking|suggestion|question>",
      "title": "<finding title>",
      "file": "<relative path>",
      "line": <1-indexed, 0 for file-level>,
      "body": "<finding body, may contain markdown>",
      "lens": "<lens id>",
      "disposition": "<action|accepted|deferred|open>",
      "rationale": "<disposition rationale from dialog>"
    }
  ]
}
```

**Selection contract — producers omit `selected`:** The `selected` field is intentionally absent from the schema above. The TUI owns selection state: on first load it pre-seeds `selected = true` for `accepted` and `deferred` findings, leaving `action`, `open`, and unknown dispositions unselected. Do not set `selected` in the JSON you produce — the field uses `omitempty` and a pre-set value would suppress the TUI's first-load pre-seeding logic.

Include ALL findings (action, accepted, deferred, open). If `--skip-pre-scan` was set and no findings were generated, use an empty findings array `[]`.

If no work item was created (no-action-items path), set `"work_item": ""`.

### Build --content summary

Assemble the `--content` value with all sections below. Every section is mandatory — do not abbreviate, summarize, or omit any section. The `--content` passed to `create-followup.sh` must contain the complete report, not a summary.

**First line:** One-line diagnostic summary for TUI excerpt compatibility (FindingExcerpt skips `#` heading lines and blank lines, returning the first 3 non-heading non-empty lines — this summary must be first):

```
Self-review of PR #<N>: <A> action, <C> accepted, <D> deferred, <O> open across <L> lenses
```

**Section 1 — PR Narrative** (from Step 2a review context and PR metadata):

Using the review context built in Step 2a (alignment map and design signals) and the PR metadata (title, body, branch), synthesize a 1-2 paragraph narrative:
- What the PR does structurally (drawn from the alignment map)
- Design signals and cross-cutting concerns identified
- Notable alignment observations (unrelated files, missing pieces) — omit if the PR is coherent

```markdown
## PR Narrative

<1-2 paragraphs>
```

**Section 2 — Implementation Diagram** (conditional):

Include only when the PR touches 2 or more distinct modules (grouped by first directory component, or `(root)` for repo-root files). Read diagram conventions:

```bash
cat ~/.lore/claude-md/review-protocol/followup-template.md
```

Build an ASCII logical flow diagram showing how the PR's changes work mechanically. Omit this section entirely for single-module PRs or when directional relationships cannot be determined from available context.

```markdown
## Implementation Diagram

<ASCII box-drawing diagram per followup-template.md conventions>
```

**Section 3 — Review Findings:**

Include the full finding details, stripped of internal protocol headers per the pr-review Step 6d-ii pattern: remove `**Grounding:**`, `**Severity:**`, `**Knowledge:**`, lens attribution, and compound markers from finding bodies. Weave grounding content (the concrete scenario/consequence) into the body text without the protocol label.

Findings are grouped by severity with user-facing labels (blocking → "Findings requiring action", suggestion → "Improvement opportunities", question → "Questions"). Empty severity groups render `None.` — do not omit the subheading. If zero findings overall, still emit `## Review Findings` with an explicit no-findings statement.

```markdown
## Review Findings

**Verdict:** <ACTION NEEDED / SUGGESTIONS / CLEAN>
**Findings requiring action:** <count> | **Improvement opportunities:** <count> | **Questions:** <count>

### Findings requiring action (<count>)

#### 1. <title>
**Lens:** <lens>
**File:** `<file:line>`

<finding body, internal headers stripped, grounding woven inline>

---

### Improvement opportunities (<count>)

...

### Questions (<count>)

...
```

If non-conforming ceremony lens output exists, append after the structured findings:

```markdown
### Supplementary Reports

#### <skill-name> [ceremony]

<raw output from the ceremony lens>
```

Omit the `### Supplementary Reports` heading entirely when all ceremony lenses were conforming or no ceremony lenses ran.

**Section 4 — Disposition Summary:**

A table summarizing all findings with their dispositions. Self-review replaces `## Proposed Comments` (which posts to GitHub) with this table — `create-followup.sh` does not post review comments.

```markdown
## Disposition Summary

| # | Severity | Title | Lens | File:Line | Disposition | Rationale |
|---|----------|-------|------|-----------|-------------|-----------|
| 1 | blocking | <title> | <lens> | <file:line> | action | <one-line reason> |
| 2 | suggestion | <title> | <lens> | <file:line> | accepted | <one-line reason> |
| 3 | suggestion | <title> | <lens> | <file:line> | open | <one-line reason> |
...
```

Include all findings (action, accepted, deferred, open). If zero findings, emit `## Disposition Summary` with `None.` as the body rather than omitting the section.

### Create followup

```bash
bash ~/.lore/scripts/create-followup.sh \
  --source "pr-self-review" \
  --title "Self-Review: <PR Title>" \  # ≤70 chars; truncate PR title if needed
  --lens-findings '<lens-findings JSON>' \
  --content '<summary body>' \
  --attachments '[{"type":"pr","ref":"#<N>"}]' \
  --pr <N> \
  --owner <owner> \
  --repo <repo> \
  --head-sha <headRefOid>
```

## Step 5: Capture Insights

**Gate:** Do not execute this step until Step 4.5 (followup creation) has completed. When Step 4 creates a plan, `plan.md` must also be written before proceeding.

```
/remember Self-review of PR #<N> (lens pre-scan + auto-disposition) — capture: mechanism-level patterns (how the system accomplishes things structurally), structural footprint observations (component roles, integration points, what constrains changes), design rationale discovered or clarified (why the architecture is this way, what constraints drove decisions), convention drift patterns found by lenses, cross-boundary invariants identified (especially from Blast Radius). Use confidence: medium. Skip: obvious fixes, style issues, findings specific to this PR that don't generalize.
```

This step is automatic — do not ask whether to run it.

## Resuming

If re-invoked on the same PR, check for an existing work item (`pr-self-review-<PR_NUMBER>` in `/work list`). If found:

1. **Load lens scan findings** — read the `## Lens Scan` section from `notes.md`.
2. **Skip the lens team** — do not re-run Step 2. Display: `[pr-self-review] Resuming: using cached lens scan`
3. **Re-run auto-disposition** — skip to Step 3 with cached findings.
4. **If no lens scan section** — re-run the full lens team (Step 2).
5. **If `plan.md` already exists** — load the plan and check for new findings.

Append new findings to existing phases rather than creating a duplicate work item.

## Error Handling

- **No gh CLI or authentication:** Tell user to run `gh auth login`
- **PR not found:** Confirm PR number and repo access
- **Empty PR (no changes):** Inform user, skip review
- **Knowledge store unavailable:** Continue without enrichment, note degraded mode
