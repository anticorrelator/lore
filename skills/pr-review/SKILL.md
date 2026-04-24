---
name: pr-review
description: "Holistic multi-lens PR review with adaptive lens selection, cross-lens synthesis, and structured findings. Use individual lens skills (/pr-correctness, /pr-security, etc.) for focused single-concern analysis."
user_invocable: true
argument_description: "[PR_number_or_URL] [--self] [--pair] [--thorough] — PR to review. Modes: --self (self-review with perspective lenses), --pair (pair review dialog), --thorough (all lenses)"
---

# /pr-review Skill

You are running a **holistic multi-lens PR review**. This skill orchestrates the full review pipeline: triage, adaptive lens selection, parallel lens execution, cross-lens synthesis, and structured presentation.

For focused single-concern analysis, use individual lens skills directly (`/pr-correctness`, `/pr-security`, etc.).

This skill does not modify source code. Findings are structured and can be posted to GitHub via `post-review.sh`.

## Independence Gate — Do Not Read Self-Review Findings Before Step 8

`/pr-review` is the **external** half of a tournament with `/pr-self-review`. The reconciliation in Step 8 treats this run as ground truth against which the self-review's `lens-findings.json` is scored (see `external_confirm_rate`, `external_contradict_rate`, `coverage_miss_rate` under Step 8's downstream notes).

For that scoring to be meaningful, this run must enumerate findings **independently** — without anchoring on what the self-review already flagged. Reading the self-review `lens-findings.json` sidecar before synthesis collapses the tournament: the external pass will disproportionately confirm what it already saw and under-surface omissions, and the reconciliation metrics lose their information value.

**Rule:** Do NOT read `$KDIR/_followups/*pr-self-review*/lens-findings.json` (or any self-review findings file for this PR) during Steps 1–5. That file is reserved for Step 8 tournament reconciliation, and `scripts/reconcile-reviews.sh` is the only sanctioned reader during a `/pr-review` run.

Permitted in Steps 1–5: existing GitHub review comments from `fetch-pr-data.sh` (these are human-authored threads, not self-review output) and prior `/pr-review` work items for the same PR (Step 1c / Resuming section).

The lens agents spawned in Step 3 inherit this rule. Do not include self-review findings — as prior knowledge, design signals, review-context notes, or hints — in any lens agent's task prompt.

## Step 1: Setup

Argument provided: `$ARGUMENTS`

### 1a. Parse PR identifier

Extract the PR number from the first token that matches digits or a GitHub PR URL. If no PR identifier is found, ask the user for the PR number.

Resolve the repo owner/name from the git remote:
```bash
REMOTE_URL=$(git remote get-url origin)
```
Extract `OWNER/REPO` from the remote URL.

### 1b. Detect mode

Parse remaining arguments for mode flags. Exactly one mode applies — if multiple are specified, the highest-priority one wins.

| Flag | Mode | Priority | Effect |
|------|------|----------|--------|
| `--self` | Self-review | 1 (highest) | Adds perspective-lens agents after the parallel lens phase. |
| `--pair` | Pair review | 2 | Enables turn-based dialog between findings. |
| `--thorough` | Thorough | 3 | Selects all lenses regardless of signal matching. |
| (none) | Default | 4 (lowest) | Standard holistic review with adaptive lens selection. |

### 1c. Fetch PR data

Run these in parallel:

```bash
bash ~/.lore/scripts/fetch-pr-data.sh <PR_NUMBER>
gh pr diff <PR_NUMBER>
gh pr view <PR_NUMBER> --json files,title,body,author,commits,headRefOid
```

From the fetched data, extract:
- **Changed files** — full list with additions/deletions per file
- **PR intent** — title, body, and commit messages
- **Existing reviews** — from `fetch-pr-data.sh` grouped output. Filter out outdated threads (`isOutdated: true`). Note existing review concerns to avoid duplicate findings. "Existing reviews" here means **GitHub review comments authored by humans** — it does NOT include any `/pr-self-review` sidecar `lens-findings.json` for this PR. See the Independence Gate above: that sidecar is off-limits until Step 8.
- **Diff stats** — total LOC changed (additions + deletions)

### 1d. Diff delivery for lens agents

- **Standard diff (<=400 LOC):** Pass inline in lens agent task descriptions.
- **Large diff (>400 LOC):** Write to `/tmp/pr-review-<PR_NUMBER>.diff` and pass the path.

### 1e. Load prior knowledge

```bash
lore prefetch "pr-review" --scale-context advisor
```

Read the `## Prior Knowledge` block this produces. Incorporate any surfaced preferences or conventions into the review — especially scope-matched preference entries whose `related_files` include this skill.

## Step 2: Triage

Load the triage protocol:
```bash
cat ~/.lore/claude-md/review-protocol/risk-triage.md
```

### 2a. Classify risk tier

**Size:** Count total LOC changed (additions + deletions).
- 1-200: Standard
- 201-400: Large
- >400: Oversized — flag prominently, recommend splitting

**Change type:** Classify by highest-risk type present:
- **High:** Auth/authz, cryptography, secrets, payment/billing, data migration, security config
- **Standard:** Business logic, API endpoints, data models, infrastructure, CI/CD
- **Low:** Documentation, comments, style/formatting, test-only, patch dependency bumps

### 2b. Select lenses

**If mode is `--thorough`:** Select all lenses. Skip signal matching.

**Otherwise:** Start with the default set (Correctness + Regressions + Test Quality + Interface Clarity + User Impact), then:
1. For each remaining lens (Security, Blast Radius), check trigger signals against the PR's changed files and diff content
2. If risk tier is High: force-add Security regardless of signals
3. Apply skip conditions — only skip a lens if ALL its skip conditions are true

**Ceremony config lookup:** After adaptive selection, check for ceremony-configured lenses:

```bash
lore ceremony get pr-review
```

If the result is non-empty (not `[]`), append each returned skill to the selected lens set. Ceremony lenses:
- Are tagged `[ceremony]` in the triage table with reason "Ceremony config"
- Are **not** subject to adaptive skip conditions — they always run when configured
- Can be removed by the user at the triage gate (Step 2c) like any other lens

### 2c. Present triage

```
## Triage: PR #<number> — <title>

Risk tier: [High/Standard/Low]
Size: [N LOC] — [Standard/Large/Oversized]
Change types detected: [list]

### Selected lenses

| Lens | Reason |
|------|--------|
| Correctness | Default selection |
| Interface Clarity | Default selection |
| Security | Auth changes detected |
| Regressions | Default selection |
| Test Quality | Default selection |
| User Impact | Default selection |
| [ceremony] insecure-defaults | Ceremony config |

Proceed with this lens set? You can add or remove lenses before we begin.
```

Present the triage summary and proceed immediately to Step 3. If the user interjects to adjust the lens set before agents launch, update the selection accordingly. Ceremony lenses appear in the table with the `[ceremony]` prefix and can be removed by name like any other lens.

If the diff is >400 LOC, include a note:
```
Note: This PR exceeds 400 LOC. Defect detection rate decreases significantly at this size.
Consider splitting the PR if feasible. Proceeding with full review.
```

## Step 3: Lens Review

This step builds context for lens agents, spawns them, and collects results.

**Independence reminder.** The review context (3a), lens prompts (3b), and ceremony dispatches (3b-ceremony) must be constructed from the diff, PR metadata, changed-file analysis, and knowledge store entries only. Do NOT include any content from `/pr-self-review` lens-findings sidecars in any lens agent's prompt — that data is tournament-reserved for Step 8. See the Independence Gate near the top of this skill.

### 3a. Build review brief

Walk each changed file and classify its relationship to the PR's purpose:
- **Directly supports** — necessary to achieve the PR's goal
- **Tangentially related** — related but not strictly required
- **Unrelated** — no connection to the PR's goal

For large diffs (>15 files), group by directory/module first, then classify groups.

Identify design signals for lens agents:
- Architectural patterns or conventions observed
- Cross-cutting concerns
- Areas of higher risk or complexity
- Missing pieces that lenses should verify

Structure as a context block for injection into each lens agent's prompt:

```
## Review Context

**Alignment map:**
| File | Classification | Notes |
|------|---------------|-------|
| path/to/file.ext | Directly supports | <brief rationale> |
| ... | ... | ... |

**Design signals:**
- <signal 1>
- <signal 2>
```

### 3b. Read lens methodologies and spawn agents

For each selected lens, read its Step 3 methodology:

| Lens | Source | Step 3 heading |
|------|--------|---------------|
| Correctness | `skills/pr-correctness/SKILL.md` | Correctness Analysis |
| Interface Clarity | `skills/pr-interface-clarity/SKILL.md` | Interface Clarity Analysis |
| Security | `~/.lore/claude-md/review-protocol/security-methodology.md` | Security Lens Methodology |
| Blast Radius | `skills/pr-blast-radius/SKILL.md` | Blast Radius Analysis |
| Regressions | `skills/pr-regressions/SKILL.md` | Regressions Analysis |
| Test Quality | `skills/pr-test-quality/SKILL.md` | Test Quality Analysis |
| User Impact | `skills/pr-user-impact/SKILL.md` | User Impact Analysis |

For each selected lens, create a task with this structure:

```
# <Lens Name> Lens — PR #<number>

You are a lens review agent analyzing PR #<number> in <owner>/<repo>.
Your sole focus is the <lens name> lens. Apply only this methodology.

## PR Context
- **Title:** <title>
- **Author:** @<author>
- **Files changed:** <count>
- **Existing review concerns:** <summary of relevant prior comments, or "None">

<review context block from 3a>

## Diff

<inline diff for <=400 LOC, or:>
Read the diff from: /tmp/pr-review-<PR_NUMBER>.diff

## Methodology

<verbatim Step 3 content from the lens's SKILL.md>

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

**Voice — hedge the inference, not the observed code fact.** Every finding is a hypothesis formed from incomplete information; frame it that way. A hedged observation that names the code precisely is more useful than a confident assertion that names nothing.

- **State observed code facts directly** — the reviewer can see the code.
  - Weak: "This might be storing the session token where it's readable."
  - Strong: "`logRequest` writes `session.token` to the access log."
- **Hedge impact claims with an explicit condition** — the reviewer cannot know whether the scenario applies.
  - Weak: "This will cause a nil dereference and crash the server."
  - Strong: "`session.user` is dereferenced here without a nil check — if this handler is reachable before authentication completes, the nil dereference panics."
- **Lead with the observation, not the hedge.** Put the code fact first, the uncertainty qualifier second.
- **Use impersonal constructions.** Describe the code, not the author ("The handler dereferences…", not "You forgot to check…").
- **Fix suggestions are secondary and optional.** The default posture is to surface the issue and stop — the author chooses between a small local fix, a broader refactor, or a deeper redesign. Include a fix only when non-obvious (non-local change, hard to characterize without showing a resolution, or unusual constraints). When included: place it **after** impact and evidence (never lead with it), frame it as one option ("One approach: …"), and keep the scope open so the finding can still motivate a broader change.
- **Vocabulary to avoid:**
  - Overstatement of reviewer confidence: "this will crash" / "this is wrong" / "this is a bug" / "definitely" → name the specific condition ("this panics if `x` is nil", "this deviates from the contract in…").
  - Hollow hedges on observations: "seems like" / "might be" / "I think" / "could potentially" → state the code fact; hedge the *impact*, not the observation.

Full voice guide (optional deeper reference): `~/.lore/claude-md/review-protocol/review-voice.md`.

Report back with your findings JSON when complete.
```

Spawn one agent per selected lens in parallel. Maximum 6 concurrent agents.

### 3b-ceremony. Dispatch ceremony lenses

After built-in lens agents are spawned, dispatch any ceremony lenses from the selected set. Ceremony lenses are identified by the `[ceremony]` tag assigned during Step 2b.

For each ceremony lens in the selected set, invoke it via the Skill tool with the PR number as the sole argument:

```
/<skill-name> <PR_NUMBER>
```

Ceremony lenses fetch their own PR data — do **not** pass diff content, review context, or metadata. Run all ceremony lens invocations in parallel.

Ceremony lens results are collected alongside built-in lens results in Step 3d. If a ceremony lens does not produce findings in the standard Findings Output Format, its output is handled as non-conforming (see Step 3d).

### 3c. Self-review perspective lenses (--self mode only)

If mode is `--self`, after standard lens agents complete, spawn perspective-lens agents:

**External reviewer perspective:** "Review these findings as if seeing this code for the first time. Flag any finding where the explanation relies on context not available in the diff."

**Weakest assumption probe:** "For each suggestion, ask: what is the weakest assumption? If wrong, does the severity change to blocking?"

**Cross-boundary invariant trace:** "For each file in the diff, identify what external code depends on it. Flag any dependency where the change could alter behavior without the dependent code being updated."

### 3d. Collect and finalize

As each lens agent reports findings JSON, verify it conforms to the Findings Output Format. If an agent fails or times out, proceed with available findings and note the coverage gap.

**Ceremony lens two-tier classification:** For each ceremony lens result, check whether the output conforms to the Findings Output Format (`lens`, `pr`, `repo`, `findings[]` with each finding having `severity`, `title`, `file`, `line`, `body`):

- **Conforming:** Include findings in the synthesis pipeline (Step 4) alongside built-in lens findings. These participate in compound detection, severity grouping, and deduplication.
- **Non-conforming:** Store the raw output separately as a supplementary report. Tag it with the ceremony lens name. Non-conforming output does **not** enter synthesis — it is presented verbatim in the Supplementary Reports section (Step 5b).
- **Malformed JSON:** Treat as non-conforming with an additional `[malformed]` tag. Store the raw text for supplementary presentation.
- **Failure/timeout:** Note the coverage gap in the verdict. The review continues with available findings.

Clean up the temp diff file if one was created:
```bash
rm -f /tmp/pr-review-<PR_NUMBER>.diff
```

## Step 4: Synthesis

Load synthesis rules:
```bash
cat ~/.lore/claude-md/review-protocol/cross-lens-synthesis.md
cat ~/.lore/claude-md/review-protocol/severity.md
```

### 4a. Identify compound findings

Group findings by `file`. Within each file, identify findings from different lenses whose `line` values are within 3 lines of each other. Two or more such findings form a compound finding.

Apply the severity elevation table from the Cross-Lens Synthesis protocol. Merge compound findings into a single finding with all contributing lens IDs and a merged body.

### 4b. Grounding quality evaluation

Apply the Grounding Quality Rubric from `severity.md` (already loaded above) to every `blocking` and `suggestion` finding. For each finding, evaluate the `**Grounding:**` content and classify it as **sound**, **weak**, or **unsound**.

**Outcomes by classification:**

- **Sound** — grounding traces from technical mechanism to observable human/operational consequence. Pass through unchanged.
- **Weak** — grounding stops at the technical mechanism without landing on a downstream consequence, or names an abstract benefit without a scenario where someone encounters the problem. Rewrite the `**Grounding:**` line to complete the chain: mechanism → who is affected → what they experience. Derive the consequence from the finding body, diff context, and review brief. Keep the finding's severity intact.
- **Unsound** — no realistic failure scenario (blocking) or no concrete benefit (suggestion). For `blocking` findings: downgrade to `suggestion` and rewrite the `**Grounding:**` line to match the weaker severity bar. For `suggestion` findings: drop the finding.

**Missing grounding line** — treat the same as unsound: downgrade `blocking` to `suggestion`, drop `suggestion`.

**Compound findings** — evaluate grounding across all contributing findings. If at least one contributing finding has sound or weak grounding, the compound finding qualifies (apply rewrite if the merged grounding is weak). If all contributing findings are unsound or ungrounded, drop the compound finding.

### 4c. Deduplicate

Same file, overlapping line (within 3 lines), same severity, same underlying concern — keep the more detailed body and add the other lens's ID to attribution. Do NOT deduplicate findings that address different concerns at the same location.

### 4d. Enrich compound and blocking findings

For compound findings and blocking findings with empty `knowledge_context`, query the knowledge store:

```bash
lore search "<finding topic>" --type knowledge --json --limit 3
```

Attach relevant citations. If any knowledge entry is STALE and the PR contradicts it, flag as "convention may need updating" — not "PR is wrong."

### 4e. Produce verdict

```
## Review Verdict: PR #<number>

**Blocking findings:** <count>
**Suggestions:** <count>
**Questions:** <count>
**Compound findings:** <count> (findings flagged by multiple lenses)

**Top concerns:**
1. <highest-severity finding title> — [<contributing lenses>]
2. <second finding> — [<contributing lenses>]
3. <third finding> — [<contributing lenses>]
```

Verdict logic:
- Any blocking findings -> `BLOCKING`
- Only suggestions/questions -> `SUGGESTIONS ONLY`
- No findings -> `CLEAN`

## Step 5: Present Findings

### 5a. Overall verdict header

```
## Review: PR #<number> — <title>

**Verdict:** <BLOCKING / CLEAN / SUGGESTIONS ONLY>
**Lenses applied:** <list of lenses that ran>
**Blocking:** <count> | **Suggestions:** <count> | **Questions:** <count>
**Compound findings:** <count>
```

### 5b. Findings by severity

Present findings grouped by severity. Compound findings appear first within each group.

```
### Findings requiring action

#### 1. [compound] <title>
**Lenses:** correctness, security
**File:** `path/to/file.ext:42`

<merged body from both lenses>

**Knowledge:** [knowledge: entry-title] — relevance summary

---

#### 2. <title>
**Lens:** correctness
**File:** `path/to/file.ext:87`

<body>

**Knowledge:** [knowledge: entry-title] — relevance summary

---

### Improvement opportunities
...

### Open questions
...
```

### 5b-supplementary. Supplementary Reports

This section appears **only** when one or more ceremony lenses produced non-conforming output (classified in Step 3d). Present each non-conforming ceremony lens result verbatim under its own header:

```
### Supplementary Reports

These reports are from ceremony-configured lenses that did not produce findings in the standard format. They are presented as-is and are not included in the synthesis verdict.

#### <skill-name> [ceremony]

<raw output from the ceremony lens>

---

#### <skill-name> [ceremony] [malformed]

<raw text from the ceremony lens that produced malformed JSON>
```

Supplementary reports are:
- **Excluded** from synthesis (Step 4) — they do not affect compound detection, severity counts, or the verdict
- **Excluded** from `post-review.sh` output — they are not posted as GitHub review comments
- **Included** in the followup report body (Step 6d) for record-keeping

### 5c. User interaction

After presenting findings, offer the user a chance to discuss or ask questions. Findings are captured in the followup report (Step 6) with proposed comments for downstream TUI posting. Proceed to Step 6.

## Step 6: Generate Followup Report

This step is mandatory and must not be skipped. It always runs after Step 5c resolves.

### 6a. PR Narrative

Using the review brief from Step 3a, synthesize a 1-2 paragraph narrative:
- What the PR does structurally (drawn from the alignment map)
- Design signals and cross-cutting concerns identified
- Notable alignment observations (unrelated files, missing pieces) — omit if the PR is coherent

```
## PR Narrative

<1-2 paragraphs>
```

### 6b. Implementation Diagram

Build an ASCII logical flow diagram showing how the PR's changes work mechanically.

Read diagram conventions:
```bash
cat ~/.lore/claude-md/review-protocol/followup-template.md
```

### 6c. Determine suggested actions

| Review outcome | --suggested-actions primary type |
|---|---|
| All clean / CLEAN verdict | approve |
| Suggestions only | comment_on_pr |
| Blocking findings exist | create_work_item |
| Deferred items exist (no blocking) | create_work_item |

### 6d. Verify grounding and prepare external bodies

This step is mandatory and must not be skipped. It has two parts:

**6d-i. Verify grounding survived synthesis.** Re-check that every `blocking` and `suggestion` finding has grounding — a concrete failure scenario (blocking) or specific improvement claim (suggestion) — per the bars defined in `severity.md`. Step 4b should have already enforced this, but findings can lose grounding during compound merging or deduplication. Any finding that lacks grounding at this point: downgrade blocking → suggestion, drop ungrounded suggestions.

The test: if the PR author asks "why does this matter?", the finding must answer with a specific scenario, not a vague assertion. A finding that cannot survive that question is not grounded.

**6d-ii. Strip internal protocol language for external output.** Remove `**Grounding:**`, `**Severity:**`, `**Knowledge:**`, lens attribution, and compound markers from finding bodies. These are internal analytical scaffolding — the author should see the grounding *content* (the concrete impact claim) woven into the finding body, not protocol headers.

**Voice — hedge the inference, not the observed code fact.** Reviewers cannot know the full system context; every external body should read as a grounded hypothesis, not a verdict.

- **State observed code facts directly.** Weak: "This might be storing the token insecurely." Strong: "`logRequest` writes `session.token` to the access log."
- **Hedge impact claims with an explicit condition.** Weak: "This will crash the server." Strong: "`session.user` is dereferenced without a nil check — if this handler is reachable before auth completes, it panics."
- **Lead with the observation**, not the hedge. Code fact first, uncertainty qualifier second.
- **Use impersonal constructions.** "The handler dereferences…", not "You forgot to check…".
- **Fix suggestions are secondary.** Default to surfacing the issue and stopping. When a fix is included (non-obvious only), place it **after** impact and evidence, frame it as one option ("One approach: …"), and keep the scope open so the finding can motivate a broader redesign if appropriate. Never lead a comment body with a fix.
- **Avoid overstated vocabulary** ("this will crash" / "this is wrong" / "this is a bug" / "definitely") — name the condition instead. **Avoid hollow hedges on observations** ("seems like" / "might be" / "I think" / "could potentially") — state the code fact; hedge the *impact*, not the observation.

Full voice guide (optional deeper reference): `~/.lore/claude-md/review-protocol/review-voice.md`.

After stripping and shaping, produce two variants of each finding body:

- **Section 3 variant** (used verbatim under `#### N. <title>` in `## Review Findings`): the stripped+shaped prose as-is. Do **not** prepend a bolded title — the `####` heading already carries the title, and duplicating it would produce a visual stutter.
- **Comment-body variant** (used in `## Proposed Comments` preview blocks and in the `body` field emitted by Step 6f): prepend `**<title>**\n\n` as the first line of the prose, where `<title>` is the finding's title text. This is a plain bolded title, not a labeled header like `**Impact:**`.

Step 6f is serialization-only — it emits the already-constructed comment-body variant without reformatting.

### 6e. Assemble the full report body

Assemble the `--content` value with **all** of the following sections. Every section is mandatory — do not abbreviate, summarize, or omit any section. The `--content` passed to `create-followup.sh` must contain the complete report, not a summary.

**First line:** One-line diagnostic summary (e.g., `ACTION NEEDED — 2 findings requiring action, 3 improvement opportunities`). This must be the first non-heading line — it appears as the excerpt in the TUI.

**Second line:** `**Author:** @<author>` — the PR author's GitHub handle from the `gh pr view` data fetched in Step 1c.

**Section 1 — PR Narrative** (from 6a):

```markdown
## PR Narrative

<1-2 paragraphs from 6a — include verbatim, do not re-summarize>
```

**Section 2 — Implementation Diagram** (from 6b):

```markdown
## Implementation Diagram

<ASCII box-drawing diagram from 6b — include verbatim>
```

**Section 3 — Review Findings:**

Include the full finding details from Step 5b with internal protocol headers stripped per Step 6d-ii. The report is an author-facing artifact. If ceremony lenses produced non-conforming output (Step 5b-supplementary), append the Supplementary Reports block after the structured findings. Supplementary reports are presentation-only — they do **not** generate review code blocks in Section 4 or entries in `proposed-comments.json`.

```markdown
## Review Findings

**Verdict:** <ACTION NEEDED / SUGGESTIONS / CLEAN>
**Findings requiring action:** <count> | **Improvement opportunities:** <count> | **Questions:** <count>

### Findings requiring action (<count>)
<findings with internal severity "blocking", headers stripped per 6d-ii>

### Improvement opportunities (<count>)
<findings with internal severity "suggestion", headers stripped per 6d-ii>

### Questions (<count>)
<findings with internal severity "question">

### Supplementary Reports

<Include only if non-conforming ceremony output exists — omit this heading entirely otherwise>

#### <skill-name> [ceremony]

<raw output from the ceremony lens>
```

**Section 4 — Proposed Comments:**

For each finding with `file` and `line` fields, render a review code block with internal headers stripped per Step 6d-ii:

````markdown
## Proposed Comments

```review
file: path/to/file.ext
line: <N>
<finding body, internal headers stripped>
```
````

### 6f. Persist the report

Build the proposed comments JSON array by walking findings in severity-group order (`blocking` → `suggestion` → `question`), matching the order they appear in the markdown report. Within each group, maintain a 1-based ordinal counter that increments for every finding encountered — including findings that lack `file` or `line`. For each finding that has both `file` and `line` fields, emit `{"path": "<file>", "line": <line>, "body": "<finding body>", "title": "<finding title>", "finding_ordinal": <N>}` where `<N>` is the current ordinal for that severity group and `<finding title>` is the title text from the finding's `#### N. <title>` header. If a finding lacks `file` or `line`, skip emission but still increment the ordinal so that later findings in the same group preserve their markdown `#### N.` position. The body must have internal protocol headers stripped per Step 6d-ii and grounding content preserved. The ordinal counter resets to 1 at the start of each severity group.

Pass the **complete report body from 6e** as `--content`:

```bash
bash ~/.lore/scripts/create-followup.sh \
  --source "pr-review" \
  --title "Review: <PR title> (#<N>)" \  # ≤70 chars; truncate PR title if needed
  --author "@<author>" \
  --attachments '[{"type":"pr","ref":"#<N>"}]' \
  --suggested-actions '[{"type": "<type>", "label": "<label>"}]' \
  --proposed-comments '<json array of {path, line, body, title, finding_ordinal} objects>' \
  --pr <N> \
  --owner <owner> \
  --repo <repo> \
  --head-sha <headRefOid> \
  --content "<complete report body from 6e — all 4 sections>" \
  --producer-role "pr-review" \
  --protocol-slot "Observations"
```

## Step 7: Capture Insights

**Gate:** Do not execute this step until Step 6 has completed and `create-followup.sh` has been called. If Step 6 was not executed, go back and execute it now before proceeding.

```
/remember Holistic review of PR #<N> — capture: mechanism-level patterns (how the system accomplishes things structurally), structural footprint observations (component roles, integration points, what constrains changes), design rationale discovered (why the architecture is this way, what constraints drove decisions), cross-lens convergence patterns (areas where multiple lenses flagged the same concern), convention patterns observed across the codebase. Use confidence: medium for reviewer observations. Skip: findings specific to this PR, style opinions, lens-specific methodology notes. For every `lore capture` call, pass `--producer-role pr-review --protocol-slot Synthesis --work-item <slug>` (when a work item matches the PR).
```

## Step 8: Tournament Reconciliation (automatic)

**This step runs unconditionally after Step 7. It is part of the `/pr-review` skill contract, not a manual follow-up.** Reconciliation is the Phase 6 settlement primitive — external review and self-review are the two halves of a tournament, and the reconciliation stage programmatically tags their agreement/disagreement so `/retro` and `/evolve` can score the self-review template against ground truth supplied by this external pass.

**Independence-gate release.** This is the first step in the skill where reading the `/pr-self-review` `lens-findings.json` sidecar is sanctioned. Steps 1–7 have deliberately avoided that file to preserve the tournament's independence — see the Independence Gate near the top of this skill. The `lore followup reconcile` / `reconcile-reviews.sh` scripts below are the only sanctioned reader during a `/pr-review` run; do not open the sidecar manually before they execute.

Every `/pr-review` invocation MUST execute this step. The step is self-gating: if no `/pr-self-review` sidecar exists for this PR, it exits cleanly with a one-line status and writes nothing. Skipping the invocation (rather than skipping internally) is a protocol violation — it means the tournament-completion health check (`/retro` Step 3.8) cannot distinguish "no self-review was run" from "the /pr-review agent forgot to reconcile".

**Invocation:**

```bash
lore followup reconcile --pr <PR_NUMBER>
```

Where `<PR_NUMBER>` is the `pr_number` resolved in Step 1a.

**Expected outcomes and how to read the exit:**

| Exit | Meaning | Action |
|---|---|---|
| 0 + `reconciliation.json` written | Both sidecars found, reconciliation produced | Include one-line summary in final report (see below) |
| 0 + "no self-review sidecar found" | Self-review was not run for this PR | Note in final report: `Tournament reconciliation: skipped — no self-review sidecar`. Do NOT treat as a failure. |
| Non-zero | Script error (missing files, malformed JSON, etc.) | Surface the stderr message to the user; do not block the rest of the review |

**Underlying script (for debugging only, not manual invocation):**

```bash
bash ~/.lore/scripts/reconcile-reviews.sh \
  --self-review <path-to-pr-self-review/lens-findings.json> \
  --external-review <path-to-pr-review/lens-findings.json>
```

The `lore followup reconcile --pr <number>` form auto-discovers both sidecars in `$KDIR/_followups/` by `pr_number`; prefer it.

**What the script produces:** `reconciliation.json` inside the self-review followup directory with fields: `generated_at`, `self_source`, `external_source`, `self_finding_count`, `external_finding_count`, `reconciled[]` (one entry per self-review finding with `tag`, `matched_external_index`, `match_score`, `match_reason`, per-side summaries), and `coverage_miss[]` (external findings with no matching self finding).

**Programmatic, no agent.** Matching is deterministic: `(file, line ±5)` + lens alignment + severity/body-length comparison. The strict `contradict` tag only fires when severity differs by ≥2 ranks AND textual opposite markers appear (e.g., "correctly handles" in one, "fails to handle" in the other). See `scripts/reconcile-reviews-compute.py` for the exact rules.

**Final-report inclusion.** Add one line to the operator-facing verdict summary:

- When a reconciliation was produced:
  `Tournament reconciliation: confirmed=<N> extended=<N> contradicted=<N> orthogonal=<N> coverage-misses=<N>`
- When skipped:
  `Tournament reconciliation: skipped — no /pr-self-review sidecar for PR #<number>`

**Downstream (task-33).** Reconciliation deltas feed scorecard rows for the `pr-self-review` template: `external_confirm_rate`, `external_contradict_rate`, `coverage_miss_rate`. These are the settlement metrics by which self-review template versions are evaluated. Run `reconciliation-rollup.sh` after `reconcile-reviews.sh` to append the three rows via `scorecard-append.sh`:

```bash
bash ~/.lore/scripts/reconciliation-rollup.sh \
  --reconciliation <path-to-reconciliation.json> \
  --artifact-id <pr-artifact-id> \
  --template-version <pr-self-review template hash> \
  --window-start <ISO> --window-end <ISO>
```

Denominators are asymmetric on purpose: confirm/contradict rates use `reconciled_total` (self findings) as denominator because they score the self-review's verdict accuracy; `coverage_miss_rate` uses `external_total` (external findings) because it measures what the self-review missed relative to what was actually there to find. If either denominator is zero, that metric is silently skipped (no row written) rather than recorded as `0.0` — a missing row is honest; a `0.0` would Goodhart to "perfect".

**Why unconditional invocation matters.** The Phase 7b tournament-completion health check (`skills/retro/SKILL.md` Step 3.8 "Tournament completion") counts PRs that produced BOTH reviews AND completed reconciliation. A `/pr-review` run that silently skips reconciliation (even when no self-review exists) is indistinguishable at telemetry time from a run that crashed at Step 8 — both show as "reconciliation missing" in the health check. Running `lore followup reconcile --pr <N>` on every invocation, and letting the script no-op cleanly when it's not applicable, keeps the invocation-count semantics intact for downstream observation.

## Error Handling

- **No gh CLI or not authenticated:** Tell user to run `gh auth login`
- **PR not found:** Confirm the PR number and repo access
- **Empty diff:** PR may have no changes — confirm with user
- **Agent failure:** If a lens agent fails, proceed with available findings and note the gap in the verdict
- **No findings:** Report "Holistic review: no findings across all lenses" — this is a valid outcome

## Resuming

If re-invoked on the same PR, check for existing work items (`pr-lens-review-<PR_NUMBER>` or `pr-review-<PR_NUMBER>` in `/work list`). If found:
- Load existing findings from the work item
- Offer to run additional lenses or re-run synthesis with new findings
- Append rather than overwrite
