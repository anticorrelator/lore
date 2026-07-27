---
name: pr-self-review
description: "Author-calibrated self-review: parallel lens pre-scan (Blast Radius, Security, Test Quality, Correctness, Regressions, Interface Clarity, User Impact) then a materiality gate, persisting findings into a followup sidecar for TUI triage"
user_invocable: true
argument_description: "[PR_number_or_URL] [--skip-pre-scan] [focus context] — PR to self-review (or auto-detect from branch). --skip-pre-scan skips the lens team and uses heuristic findings instead. Optional focus context steers finding priority (e.g., '42 focus on error handling')"
---

# /pr-self-review Skill

Author-calibrated self-review combining structured lens analysis with a materiality gate. A parallel lens team (Blast Radius, Security, Test Quality, Correctness, Regressions, Interface Clarity, User Impact) runs a pre-scan, then findings are run through the materiality gate and persisted as a followup sidecar (`lens-findings.json`) for interactive TUI triage.

## Resolve Template Version

Compute the skill's content-hash; this is the `template_version` for the `create-followup.sh` call in Step 4 and every `lore capture` call in Step 5:

```bash
source ~/.lore/scripts/lib.sh
SKILLS_DIR=$(resolve_harness_install_path skills)
SELF_REVIEW_TEMPLATE_VERSION=$(bash ~/.lore/scripts/template-version.sh "$SKILLS_DIR/pr-self-review/SKILL.md")
```

Per-lens methodology files (`claude-md/review-protocol/*-methodology.md`) are embedded verbatim into each lens agent's prompt — they are content-equivalent to the skill template from the scorecard's perspective, so the skill's hash is the canonical `template_version` for this skill's outputs. Individual lens findings carry their own `producer_role` of `lens-<name>` but inherit the skill's `template_version`.

If `template-version.sh` fails, fall through with an empty string — downstream scripts accept the omitted flag.

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

**If multiple PRs found:** Present the list and ask which one to review.

**If no PRs found:** Ask for the PR number or a base branch to diff against. If only a base branch is provided, fall back to `git diff <base>...HEAD` and skip comment fetching.

### 1b. Fetch PR data

```bash
bash ~/.lore/scripts/fetch-pr-data.sh <PR_NUMBER>
gh pr diff <PR_NUMBER>
gh pr view <PR_NUMBER> --json files,title,body,baseRefName,headRefName,commits,headRefOid
```

Resolve `OWNER/REPO` from the git remote:
```bash
REMOTE_URL=$(git remote get-url origin)
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

**Dispatch guidance gate:** For every built-in lens, ceremony, or materiality-gate launch or retry, run `lore dispatch guidance` immediately before assembling that launch's prompt. Prepend that launch attempt's complete output verbatim as the first block; never copy, summarize, cache, or reuse it for another launch. If any render fails while preparing a parallel batch, issue none of that batch; a retry renders a fresh block independently for every member. This changes neither selected models nor concurrency behavior.

For each selected lens, read its Step 3 methodology. Lens methodology source table: see `skills/pr-review/SKILL.md` Step 3b (the seven-row table mapping each lens to its source file and Step 3 heading is the canonical reference; Blast Radius row applies here unchanged).

For each lens, create a task using the lens-agent prompt template — read `skills/pr-self-review/templates/lens-agent-prompt.md` for the verbatim prompt scaffold (the self-review variant adds "Self-Review Pre-Scan" framing distinct from pr-review's lens-agent prompt). The template embeds the role-assignment opener "You are a lens review agent analyzing PR #<number>" and the grounding contract "Findings without a `**Grounding:**` line will be downgraded or dropped." verbatim.

Immediately before each lens launch or retry, render a new complete dispatch-guidance block and prepend that launch's output verbatim before the template scaffold. The scaffold remains otherwise unchanged.

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

Immediately before each ceremony Skill launch or retry, render a new complete dispatch-guidance block and prepend that launch's output verbatim before the task-specific `/<skill-name> <PR_NUMBER>` invocation. If rendering fails, do not launch that ceremony lens. The PR number remains the ceremony skill's sole task-specific argument.

Ceremony lens results are collected alongside built-in lens results in Step 2c. If a ceremony lens does not produce findings in the standard Findings Output Format, its output is handled as non-conforming during synthesis.

### 2c. Collect and synthesize

Collect findings from lens agents as they complete. If a lens agent fails or times out, proceed with available findings and note the coverage gap.

**Ceremony lens two-tier classification:** Apply the four-bullet classification rubric (Conforming / Non-conforming / Malformed JSON / Failure-timeout) from `skills/pr-review/SKILL.md` Step 3d to each ceremony lens result. Self-review variant: Conforming findings enter the synthesis pipeline below *and* the Step 3 materiality gate; Non-conforming output is presented in the followup summary (Step 4), not in a separate Supplementary Reports section yet.

Clean up the temp diff file:
```bash
rm -f /tmp/pr-self-review-<PR_NUMBER>.diff
```

**Compound findings:** Apply the compound-finding detection rule from `skills/pr-review/SKILL.md` Step 4a — group by `file`; findings from different lenses within 3 lines of each other form a compound finding; apply severity elevation and merge.

**Stake check:** For each `blocking` or `suggestion` finding, verify it has a `**Grounding:**` line stating a one-line material stake (observed fact + condition). A finding missing the line is dropped to the `minor` tally — the materiality gate (Step 3) makes the keep/drop call; this is only a presence check.

**Deduplicate:** Apply the deduplication rule from `skills/pr-review/SKILL.md` Step 4c — same file, overlapping line, same severity, same concern, keep the more detailed body; do NOT deduplicate different concerns at the same location.

Display summary:
```
[pr-self-review] Lens scan complete: <N> findings (<K> blocking, <J> suggestions, <Q> questions) across <L> lenses
```

## Step 3: Materiality Gate

Load the gate:
```bash
cat ~/.lore/claude-md/review-protocol/severity.md
```

### 3a. Run all findings through the materiality gate

For every materiality-gate launch or retry, run `lore dispatch guidance` immediately before assembling that launch's prompt. If rendering fails, stop before that launch. Prepend that launch attempt's complete output verbatim before the grounding-evaluation template; never reuse a lens or ceremony render.

Spawn one agent with:
- The PR's stated intent (title, body, and commit messages from Step 1b)
- All lens findings with their `**Grounding:**` lines from Step 2c
- The Materiality Gate from `severity.md`

Agent task: read `skills/pr-self-review/templates/grounding-eval-prompt.md` for the verbatim prompt scaffold. The template embeds the role-assignment opener "You are a materiality gate agent" and the full gate application (the same application is canonical at `skills/pr-review/SKILL.md` Step 4b). The gate drops or routes; it never rewrites a finding to sound material.

### 3b. Present evaluation summary

Display the summary (no confirmation gate — proceed immediately to Step 4):

```
[pr-self-review] Materiality gate complete: <N> findings retained (<K> blocking, <J> suggestions, <Q> questions), <D> dropped to minor (immaterial/missing stake)
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

Build the `lens-findings.json` payload from the evaluated findings produced by Step 3 — read `skills/pr-self-review/templates/lens-findings-json.md` for the JSON payload shape. Two fields, two surfaces (per `findings-format.md` → External Output Formatting): `body` carries the reviewer-cockpit detail (mechanism, caveats — what Section 3 renders), while `grounding` carries the distilled posted line — one usage-terms sentence, no code identifier in the lead — which is what reaches the PR when the reviewer posts. Translate `grounding` from the finding; do not copy a trimmed `body` into it.

**Selection contract:** The materiality gate (Step 3) owns `selected`. Set `selected: true` for every material `blocking` and `suggestion` finding. Set `selected: false` for `question` findings. Do not include immaterial or missing-stake findings — they are dropped to the `minor` tally during the gate.

Include only findings that survived the materiality gate. If `--skip-pre-scan` was set and no findings were generated, use an empty findings array `[]`.

`work_item` is always `""` at this stage — it gets populated by the TUI when the user promotes the followup.

### Build --content summary

Per-section assembly: see `skills/pr-review/SKILL.md` Step 6e — every section is mandatory, do not abbreviate, summarize, or omit any section; `--content` passed to `create-followup.sh` must contain the complete report, not a summary.

**First line:** One-line diagnostic summary for TUI excerpt compatibility (FindingExcerpt skips `#` heading lines and blank lines, returning the first 3 non-heading non-empty lines — this summary must be first):

```
Self-review of PR #<N>: <N> findings retained (<K> blocking, <J> suggestions, <Q> questions) across <L> lenses
```

**Section 1 — PR Narrative** (from Step 2a review context and PR metadata):

From the Step 2a review context (alignment map, design signals) and PR metadata (title, body, branch), synthesize a 1-2 paragraph narrative covering:
- What the PR does structurally (drawn from the alignment map)
- Design signals and cross-cutting concerns identified
- Notable alignment observations (unrelated files, missing pieces) — omit if the PR is coherent

```markdown
## PR Narrative

<1-2 paragraphs>
```

**Section 2 — Implementation Diagram** (conditional):

Include only when the PR touches 2 or more distinct modules (grouped by first directory component, or `(root)` for repo-root files). Read diagram conventions per `skills/pr-review/SKILL.md` Step 6b (`cat ~/.lore/claude-md/review-protocol/followup-template.md`).

Build an ASCII logical flow diagram showing how the PR's changes work mechanically. Omit this section entirely for single-module PRs or when directional relationships cannot be determined from available context.

```markdown
## Implementation Diagram

<ASCII box-drawing diagram per followup-template.md conventions>
```

**Section 3 — Review Findings:**

Include the full finding details with internal scaffolding labels stripped for readability (the label-stripping part of pr-review Step 6d-ii): remove `**Grounding:**`, `**Severity:**`, `**Knowledge:**`, lens attribution, and compound markers from finding bodies; weave the stake content (the conditional fact) into the body text without the label. This followup is **reviewer-facing** (the author's own triage in the TUI; it does not auto-post to the PR), so — unlike posted comments — it **retains** the severity grouping and verdict below. The criticality-stripping in 6d-ii applies only when comments are posted.

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

Include all retained findings (those that survived the materiality gate). If zero findings, emit `## Findings Summary` with `None.` as the body rather than omitting the section.

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
  --head-sha <headRefOid> \
  --producer-role "lens-<lens-name>" \
  --protocol-slot "Observations" \
  --template-version "$SELF_REVIEW_TEMPLATE_VERSION"
```

Per-finding provenance: `create-followup.sh` enriches each finding in `lens-findings.json` with any CLI-provided provenance field the finding does not already carry. If individual lens findings already carry their own `producer_role` (e.g., `lens-security`, `lens-correctness`), those are preserved; CLI defaults fill only unattributed findings. Leaving `--producer-role` as a generic `lens-<lens-name>` sentinel at the wrapper level is fine when per-finding attribution is already present.

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

Variants:
- If ceremony lenses ran: `**Lens coverage:** <L> lenses (<M> ceremony), <N> findings retained (<K> blocking, <J> suggestions, <Q> questions)`.
- If lenses ran in degraded mode: `**Lens coverage:** <L>/<T> lenses (<degraded names> degraded), <N> findings retained`.
- If non-conforming ceremony lens output exists, append a `### Supplementary Reports` section naming each skill. Omit when all ceremony lenses were conforming or none ran.
- Omit zero counts.

## Step 5: Capture Insights

**Gate:** Do not execute this step until the followup has been created (`create-followup.sh` returned successfully).

```
/remember Self-review of PR #<N> (lens scan + materiality gate) — capture: mechanism-level patterns (how the system accomplishes things structurally), structural footprint observations (component roles, integration points, what constrains changes), design rationale discovered or clarified (why the architecture is this way, what constraints drove decisions), convention drift patterns found by lenses, cross-boundary invariants identified (especially from Blast Radius). Use confidence: medium. Skip: obvious fixes, style issues, findings specific to this PR that don't generalize. For every `lore capture` call, pass `--producer-role pr-self-review --protocol-slot Synthesis --work-item <slug> --template-version $SELF_REVIEW_TEMPLATE_VERSION` (when a work item matches the PR).
```

This step is automatic — do not ask whether to run it.

## Re-invocation

Each invocation produces an independent followup — the skill does not resume or merge with prior runs. If the user re-runs pr-self-review on a PR that already has a followup, mention the existing followup and ask whether to proceed (creating a second followup) or stop. The prior followup is not modified.

## Error Handling

Per the canonical block at `skills/pr-review/SKILL.md` ## Error Handling: gh CLI/auth → `gh auth login`; PR not found → confirm PR number and repo access; empty PR → inform user, skip review; knowledge store unavailable → continue without enrichment, note degraded mode.
