---
name: pr-self-review
description: "Author-calibrated self-review: parallel lens pre-scan (Blast Radius, Security, Test Quality, Correctness, Regressions, Interface Clarity) then confirmatory dialog to disposition findings into a phased plan.md"
user_invocable: true
argument_description: "[PR_number_or_URL] [--skip-pre-scan] [focus context] — PR to self-review (or auto-detect from branch). --skip-pre-scan skips the lens team and uses heuristic dialog instead. Optional focus context steers finding priority (e.g., '42 focus on error handling')"
---

# /pr-self-review Skill

Author-calibrated self-review combining structured analysis with interactive dialog. A parallel lens team (Blast Radius, Security, Test Quality, Correctness, Regressions, Interface Clarity) runs a pre-scan, then you and the user discuss each finding in a confirmatory dialog — assigning dispositions (action/accepted/deferred/open) rather than generating observations from scratch.

Since this is your own work, locally-scoped action items can be implement-ready. Findings with cross-boundary implications (especially from Blast Radius) get verification directives instead.

This skill does not modify source code.

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
gh pr view <PR_NUMBER> --json files,title,body,baseRefName,headRefName,commits
```

Note any existing reviewer feedback to avoid duplicating observations.

### 1c. Triage summary

**Skip if `--skip-pre-scan` was set.**

Compute total LOC changed.

**Ceremony config lookup:** After assembling the built-in lens set, check for ceremony-configured lenses:

```bash
lore ceremony get pr-review
```

If the result is non-empty (not `[]`), append each returned skill to the lens set. Ceremony lenses are not subject to adaptive skip conditions — they always run when configured.

Display:

```
[pr-self-review] Triage
Size: <N> LOC across <M> files
Lenses: Blast Radius · Security · Test Quality · Correctness · Regressions · Interface Clarity · [ceremony] insecure-defaults
Add or remove lenses? (enter lens names, or press Enter to proceed)
```

If the diff exceeds 400 LOC, append: `Size: <N> LOC (large — consider --skip-pre-scan for targeted exploration)`

This is a soft gate — no explicit confirmation required. If the user names lenses to add or remove (including ceremony lenses by name), adjust. Otherwise proceed.

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

Every finding with severity `blocking` or `suggestion` MUST include a `**Grounding:**` line in the body stating the concrete basis for the severity claim:
- blocking: `**Grounding:** <what breaks> for <whom> when <conditions>.`
- suggestion: `**Grounding:** <specific improvement> benefits <beneficiary>.`

Findings without a `**Grounding:**` line will be downgraded or dropped during synthesis.

Query the knowledge store for each finding:
```bash
lore search "<topic>" --type knowledge --json --limit 3
```

Report back with your findings JSON when complete.
```

**Correctness lens modification:** Append: "Skip step 3d (intent alignment). The author already knows the intent."

Spawn one agent per lens in parallel. Maximum 6 concurrent agents. For diffs >400 LOC, write the diff to `/tmp/pr-self-review-<PR_NUMBER>.diff` before spawning.

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
/work create pr-self-review-<PR_NUMBER>
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

The `Disposition` column starts as `—` and is updated during Step 3.

## Step 3: Dialog

Read protocol sections:
```bash
cat ~/.lore/claude-md/review-protocol/cross-lens-synthesis.md
cat ~/.lore/claude-md/review-protocol/enrichment.md
cat ~/.lore/claude-md/review-protocol/checklist.md
```

### 3a. Overview and opening finding

Present a concise PR overview:

```
## Self-Review: #<N> — <title>

**Branch:** <head> → <base>
**Scope:** <N files, brief characterization>

### Findings to discuss:
1. [blocking] <finding title> — <lens> — <file:line>
2. [suggestion] <finding title> — <lens> — <file:line>
...
```

Sort: blocking first (compound before single-lens), then suggestions, then questions. If focus context was provided, reorder matching items first within each severity tier.

**Ceremony lens findings:** Conforming ceremony lens findings are included in the prioritized list above — they sort by severity alongside built-in lens findings and show their ceremony lens name (e.g., `[suggestion] Token rotation check — codex-pr-review — auth.go:42`). If any ceremony lenses produced non-conforming output, append a summary line after the findings list:

```
Supplementary reports: <skill-name>, <skill-name> (non-standard format — see below)
```

Then **open the first finding** for discussion with its label, lens, file:line, body, and knowledge citations. End with an open question. Strip internal protocol headers (`**Grounding:**`, `**Severity:**`, etc.) from dialog presentation — these are internal scaffolding. The grounding content itself must be preserved as the substance of the finding.

**Heuristic fallback:** If the pre-scan produced zero findings or `--skip-pre-scan` was set, scan the diff for risk concentration, complexity, and architectural decisions. Open topics using perspective lenses:
1. "What would a reviewer unfamiliar with this codebase question?"
2. "What are the weakest assumptions in this change?"
3. "What invariants in other files does this change depend on?"

Enrich heuristic observations via `lore search` before presenting.

### 3b. Dialog rounds

Each round follows this sequence:

1. **Present finding** with disposition prompt: `(a)ction / (ok) accepted / (d)efer / (?) open`
2. **Discuss** — user may assign a disposition directly, challenge, go deeper, or redirect
3. **Record disposition** and advance to the next undispositioned finding

**Dispositions:**
- **action** — needs a fix; becomes a task in the plan
- **accepted** — confirmed fine as-is
- **deferred** — valid but out of scope
- **open** — needs more investigation

**User-steered flow:** The user can jump to any finding, batch-accept, raise new topics, or wrap up at any time. Undispositioned findings at wrap-up are recorded as `open`.

**After all lens findings:** Offer to continue exploring areas not covered by lenses. If declined, proceed to Step 4.

**Perspective escalation:** When the user challenges a finding, offer:
- **perspective-external:** "Re-examine as if seeing this code for the first time."
- **perspective-assumption:** "What is the weakest assumption? Does the severity change?"

Discuss findings like a thoughtful colleague — the structured format is for tracking, not reading aloud verbatim.

## Step 4: Work Item and Summary

After the dialog concludes, collect all dispositioned findings.

### No action items path

If all findings were dispositioned as `accepted` or `deferred` (zero `action` items), skip work item creation. Report:

```
Reviewed and confirmed: <N> findings examined, no changes needed (<K> accepted, <L> deferred)
```

Proceed directly to Step 5.

### Create plan

```
/work create pr-self-review-<PR_NUMBER>
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
- [ ] <finding title> [<lens>] — <file:line> — <one-line action from dialog>

### Phase 2: Convention Alignment
**Objective:** Align with project conventions
**Files:** <affected files>
- [ ] <finding title> [<lens>] — <file:line> — <one-line action from dialog>

### Phase 3: Improvements
**Objective:** Address remaining suggestions
**Files:** <affected files>
- [ ] <finding title> [<lens>] — <file:line> — <one-line action from dialog>

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

### Discussion highlights:
- <key insight or decision from the dialog>

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

## Step 5: Capture Insights

**Gate:** When Step 4 creates a plan (action items exist), do not execute this step until Step 4 has completed and `plan.md` has been written. When Step 4's "No action items path" is taken (all findings dispositioned as `accepted` or `deferred`), the gate is met as soon as all findings are dispositioned.

```
/remember Self-review of PR #<N> (lens pre-scan + dialog) — capture: mechanism-level patterns (how the system accomplishes things structurally), structural footprint observations (component roles, integration points, what constrains changes), design rationale discovered or clarified (why the architecture is this way, what constraints drove decisions), convention drift patterns found by lenses, cross-boundary invariants identified (especially from Blast Radius), architectural concerns surfaced during disposition dialog. Use confidence: medium. Skip: obvious fixes, style issues, findings specific to this PR that don't generalize.
```

This step is automatic — do not ask whether to run it.

## Resuming

If re-invoked on the same PR, check for an existing work item (`pr-self-review-<PR_NUMBER>` in `/work list`). If found:

1. **Load lens scan findings** — read the `## Lens Scan` section from `notes.md`. Parse which findings are dispositioned vs `—`.
2. **Skip the lens team** — do not re-run Step 2. Display: `[pr-self-review] Resuming: <N> undispositioned findings from previous scan`
3. **Resume dialog** — skip to Step 3 and present findings with dispositioned items marked.
4. **If no lens scan section** — offer to re-run the lens team or continue with heuristic dialog.
5. **If `plan.md` already exists** — load the plan and check for new undispositioned findings.

Append new findings to existing phases rather than creating a duplicate work item.

## Error Handling

- **No gh CLI or authentication:** Tell user to run `gh auth login`
- **PR not found:** Confirm PR number and repo access
- **Empty PR (no changes):** Inform user, skip review
- **Knowledge store unavailable:** Continue without enrichment, note degraded mode
