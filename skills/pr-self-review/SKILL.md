---
name: pr-self-review
description: "Author-calibrated self-review: parallel lens pre-scan (Blast Radius, Security, Test Quality, Correctness, Regressions, Interface Clarity, User Impact) then grounding evaluation, persisting findings into a followup sidecar for TUI triage"
user_invocable: true
argument_description: "[PR_number_or_URL] [--skip-pre-scan] [focus context] — PR to self-review (or auto-detect from branch). --skip-pre-scan skips the lens team and uses heuristic findings instead. Optional focus context steers finding priority (e.g., '42 focus on error handling')"
---

# /pr-self-review Skill

Author-calibrated self-review combining structured lens analysis with grounding evaluation. A parallel lens team (Blast Radius, Security, Test Quality, Correctness, Regressions, Interface Clarity, User Impact) runs a pre-scan, then findings are evaluated for grounding quality and persisted as a followup sidecar (`lens-findings.json`) for interactive TUI triage.

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

- **Conforming:** Include findings in the synthesis pipeline below alongside built-in lens findings. These participate in compound detection, severity grouping, and deduplication. Conforming ceremony findings enter grounding evaluation (Step 3).
- **Non-conforming:** Store the raw output separately as a supplementary report. Tag it with the ceremony lens name. Non-conforming output does **not** enter synthesis or grounding evaluation — it is presented in the followup summary (Step 4).
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

## Step 3: Grounding Evaluation

Load the grounding rubric:
```bash
cat ~/.lore/claude-md/review-protocol/severity.md
```

### 3a. Evaluate grounding for all findings

Spawn one agent with:
- The PR's stated intent (title, body, and commit messages from Step 1b)
- All lens findings with their `**Grounding:**` lines from Step 2c
- The Sound/Weak/Unsound rubric from `severity.md`

Agent task:

```
# Grounding Evaluation — PR #<number>

You are a grounding evaluation agent. Apply the Grounding Quality Rubric from severity.md to every `blocking` and `suggestion` finding from the lens scan.

## PR Intent
**Title:** <title>
**Body:** <body>
**Commits:** <commit messages>

## severity.md Rubric (loaded above)

## Findings to Evaluate

<all lens findings with their Grounding lines>

## Instructions

For each finding with severity `blocking` or `suggestion`:
1. Classify the `**Grounding:**` line as Sound, Weak, or Unsound per the rubric.
2. Apply the outcome:
   - **Sound** → pass through unchanged, set `selected: true`
   - **Weak** → rewrite the `**Grounding:**` line to complete the mechanism → consequence chain; keep severity intact, set `selected: true`
   - **Unsound** → drop the finding (do not include it in output)
   - **Missing grounding** → treat as Unsound; drop the finding

For `question` findings: pass through unchanged, set `selected: false`.

Output the evaluated findings list. For each finding include: severity, title, file, line, body (with grounding rewritten if weak), lens, grounding (the final grounding text only, without the `**Grounding:**` label), selected.
```

### 3b. Present evaluation summary

Display the summary (no confirmation gate — proceed immediately to Step 4):

```
[pr-self-review] Grounding evaluation complete: <N> findings retained (<K> blocking, <J> suggestions, <Q> questions), <D> dropped (unsound/missing grounding)
→ Selected for TUI triage: <S> findings
```

**Heuristic fallback:** If the pre-scan produced zero findings or `--skip-pre-scan` was set, scan the diff for risk concentration, complexity, and architectural decisions. Generate findings using perspective lenses:
1. "What would a reviewer unfamiliar with this codebase question?"
2. "What are the weakest assumptions in this change?"
3. "What invariants in other files does this change depend on?"

Enrich heuristic observations via `lore search` before generating findings. For heuristic findings, set `selected: true` for all `blocking` and `suggestion` findings; set `selected: false` for `question` findings.

## Step 4: Create Followup

The followup is the sole artifact this skill produces. Work-item creation is deferred to TUI triage: the user promotes selected findings to a work item via the Triage tab's `p` action, which invokes `promote-followup.sh --findings-json <selected>`. This keeps pr-self-review a read-only review producer — the follow-up scope (what becomes actionable work) is chosen by a human after seeing the evaluated findings.

### Assemble lens-findings.json

Build the `lens-findings.json` payload from the evaluated findings produced by Step 3:

```json
{
  "pr": <PR_NUMBER>,
  "work_item": "",
  "findings": [
    {
      "severity": "<blocking|suggestion|question>",
      "title": "<finding title>",
      "file": "<relative path>",
      "line": <1-indexed, 0 for file-level>,
      "body": "<finding body, may contain markdown>",
      "lens": "<lens id>",
      "grounding": "<grounding text — mechanism → consequence chain, no label prefix>",
      "selected": <true|false>
    }
  ]
}
```

**Selection contract:** The grounding evaluation step (Step 3) owns `selected`. Set `selected: true` for every finding with sound or rewritten-weak grounding (`blocking` and `suggestion`). Set `selected: false` for `question` findings. Do not include findings with unsound or missing grounding — they are dropped during evaluation.

Include only findings that survived grounding evaluation. If `--skip-pre-scan` was set and no findings were generated, use an empty findings array `[]`.

`work_item` is always `""` at this stage — it gets populated by the TUI when the user promotes the followup.

### Build --content summary

Assemble the `--content` value with all sections below. Every section is mandatory — do not abbreviate, summarize, or omit any section. The `--content` passed to `create-followup.sh` must contain the complete report, not a summary.

**First line:** One-line diagnostic summary for TUI excerpt compatibility (FindingExcerpt skips `#` heading lines and blank lines, returning the first 3 non-heading non-empty lines — this summary must be first):

```
Self-review of PR #<N>: <N> findings retained (<K> blocking, <J> suggestions, <Q> questions) across <L> lenses
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

**Section 4 — Findings Summary:**

A table summarizing all retained findings with their selection state. Self-review replaces `## Proposed Comments` (which posts to GitHub) with this table — `create-followup.sh` does not post review comments.

```markdown
## Findings Summary

| # | Severity | Title | Lens | File:Line | Selected |
|---|----------|-------|------|-----------|----------|
| 1 | blocking | <title> | <lens> | <file:line> | true |
| 2 | suggestion | <title> | <lens> | <file:line> | true |
| 3 | question | <title> | <lens> | <file:line> | false |
...
```

Include all retained findings (those that survived grounding evaluation). If zero findings, emit `## Findings Summary` with `None.` as the body rather than omitting the section.

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

### Present summary

```
## Self-Review Complete

**PR:** #<number> — <title>
**Lens coverage:** <L> lenses, <N> findings retained (<K> blocking, <J> suggestions, <Q> questions)
**Selected for triage:** <S> findings

### Notable findings:
- <key insight or notable finding from the scan>

### Followup: <followup-id>
Open the TUI Triage tab to review findings. Press `p` on the followup to promote selected findings to a work item.
```

If ceremony lenses ran, include them in the lens coverage count: `**Lens coverage:** <L> lenses (<M> ceremony), <N> findings retained (<K> blocking, <J> suggestions, <Q> questions)`.

If lenses ran in degraded mode, show: `**Lens coverage:** <L>/<T> lenses (<degraded names> degraded), <N> findings retained`.

If non-conforming ceremony lens output exists, append a `### Supplementary Reports` section naming each skill. Omit when all ceremony lenses were conforming or none ran.

Omit zero counts.

## Step 5: Capture Insights

**Gate:** Do not execute this step until the followup has been created (`create-followup.sh` returned successfully).

```
/remember Self-review of PR #<N> (lens scan + grounding evaluation) — capture: mechanism-level patterns (how the system accomplishes things structurally), structural footprint observations (component roles, integration points, what constrains changes), design rationale discovered or clarified (why the architecture is this way, what constraints drove decisions), convention drift patterns found by lenses, cross-boundary invariants identified (especially from Blast Radius). Use confidence: medium. Skip: obvious fixes, style issues, findings specific to this PR that don't generalize.
```

This step is automatic — do not ask whether to run it.

## Re-invocation

Each invocation produces an independent followup — the skill does not resume or merge with prior runs. If the user re-runs pr-self-review on a PR that already has a followup, mention the existing followup and ask whether to proceed (creating a second followup) or stop. The prior followup is not modified.

## Error Handling

- **No gh CLI or authentication:** Tell user to run `gh auth login`
- **PR not found:** Confirm PR number and repo access
- **Empty PR (no changes):** Inform user, skip review
- **Knowledge store unavailable:** Continue without enrichment, note degraded mode
