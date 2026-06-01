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
- **Existing reviews** — from `fetch-pr-data.sh` grouped output. Filter out outdated threads (`isOutdated: true`). Note existing review concerns to avoid duplicate findings.
- **Diff stats** — total LOC changed (additions + deletions)

<!-- section-boundary -->

### 1d. Diff delivery for lens agents

- **Standard diff (<=400 LOC):** Pass inline in lens agent task descriptions.
- **Large diff (>400 LOC):** Write to `/tmp/pr-review-<PR_NUMBER>.diff` and pass the path.

### 1e. Load prior knowledge

```bash
lore prefetch "pr-review" --scale-set=<bucket>
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

**Otherwise:** Start with the default set (Correctness + Regressions + Test Quality + Interface Clarity + User Impact), then: 1. For each remaining lens (Security, Blast Radius), check trigger signals against the PR's changed files and diff content 2. If risk tier is High: force-add Security regardless of signals 3. Apply skip conditions — only skip a lens if ALL its skip conditions are true

**Ceremony config lookup:** After adaptive selection, check for ceremony-configured lenses:

```bash
lore ceremony get pr-review
```

If the result is non-empty (not `[]`), append each returned skill to the selected lens set. Ceremony lenses are tagged `[ceremony]` in the triage table with reason "Ceremony config" and are **not** subject to adaptive skip conditions — they always run when configured.

**Agency constraint:** The user — and only the user — can remove a ceremony lens at Step 2c. The agent MUST NOT self-remove a ceremony lens on the basis of latency, PR size, perceived low signal, or any other judgment call. Invalid skip rationales — do not act on any of these: the PR is small, the review is low-signal, the run will take too long, or the user did not explicitly ask for ceremony lenses this session. The user configured them; only the user can unconfigure them.

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

Present the triage summary and proceed immediately to Step 3. If the user interjects to adjust the lens set before agents launch, update the selection accordingly.

If the diff is >400 LOC, include a note:
```
Note: This PR exceeds 400 LOC. Defect detection rate decreases significantly at this size.
Consider splitting the PR if feasible. Proceeding with full review.
```

## Step 3: Lens Review

This step builds context for lens agents, spawns them, and collects results.

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

Structure as a context block for each lens agent's prompt:

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

Every finding with severity `blocking` or `suggestion` MUST include a `**Grounding:**` line stating the **material stake** in one line — the observed code fact plus the condition under which it matters. Write it as it should read to the author: short, conditional, no severity verdict.
- blocking: `**Grounding:** <observed code fact> — <what fails> if <condition>.`
- suggestion: `**Grounding:** <observed code fact> — <concrete cost felt in normal maintenance or use>.`

Do not pad the stake into a mechanism→consequence essay; when the impact is self-evident from the fact, the one line is enough. Findings without a `**Grounding:**` line — and findings whose stake does not clear the Materiality Gate in `severity.md` — are dropped during synthesis. They are **not** rewritten to sound material.

Query the knowledge store for each finding:
```bash
lore search "<topic>" --type knowledge --json --limit 3
```

**Voice — hedge the inference, not the observed code fact.** State observed code facts directly; hedge impact claims with an explicit condition. Lead with the observation, then the qualifier. Use impersonal constructions ("The handler dereferences…", not "You forgot to check…"). Fix suggestions are secondary and optional — surface the issue and stop unless the fix is non-obvious; never lead with a fix. Avoid overstated vocabulary ("this will crash", "this is a bug", "definitely") and hollow hedges on observations ("seems like", "might be", "I think") — name the specific condition. Full guidance: `~/.lore/claude-md/review-protocol/review-voice.md` (see also Step 6d-ii below for the externally-facing variant).

Report back with your findings JSON when complete.
```

Construct one Agent task per built-in lens, but **do not dispatch yet** — ceremony lens tasks must launch together with built-in lens tasks in the same parallel batch (see Step 3b-ceremony, then Step 3b-launch).

### 3b-ceremony. Construct ceremony lens tasks

**This step is mandatory and must not be skipped.** Ceremony lenses are identified by the `[ceremony]` tag assigned during Step 2b. For each ceremony lens in the selected set, construct an `Agent` task — *not* a `Skill` invocation — using the `general-purpose` subagent type with this prompt structure: read `skills/pr-review/templates/ceremony-lens-prompt.md`.

The `Agent`-wrapped invocation — rather than a direct `Skill` call from the main conversation — is what makes parallel execution with built-in lens agents possible. `Skill` invocations run synchronously in the main thread; `Agent` invocations issued in a single message run concurrently.

<!-- section-boundary -->

### 3b-launch. Spawn all lens agents in a single parallel batch

Issue every `Agent` tool call — one per selected lens, both built-in and ceremony — in a **single message**. Spawning built-in lens agents first and then dispatching ceremony lens agents in a follow-up message serializes ceremony work behind built-in completion and erases the latency gain the parallel design is meant to capture.

There is no fixed concurrent-agent cap; spawn the full selected set together. Typical batches run 5–8 agents (defaults plus 0–3 ceremony lenses).

**Why unconditional parallel dispatch matters.** A downstream telemetry consumer — tournament reconciliation, coverage dashboards, session observability — cannot distinguish "ceremony not configured" from "agent chose not to run it" when the dispatch is silently skipped. Silent omission corrupts the signal: configured lenses appear as absent lenses, and the consumer has no way to recover the distinction after the fact.

Do NOT skip this step. Do NOT omit a ceremony lens because the PR is small. Do NOT omit because the run seems low-signal. Do NOT omit because the user did not explicitly re-request ceremony lenses this session. Do NOT omit because of perceived latency cost. Do NOT defer ceremony dispatch to a follow-up message under any of these rationales — deferral is functionally a skip from the parallelism perspective. None of these are valid rationales — the user configured the ceremony; only the user can remove it. If a ceremony lens is genuinely inapplicable, stop and ask the user whether to remove it at Step 2c rather than self-removing.

Ceremony lens results are collected in Step 3d alongside built-in results; output not in the standard Findings Output Format is handled as non-conforming there.

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

### 4b. Materiality gate

Run every `blocking` and `suggestion` finding through the **Materiality Gate** from `severity.md` (already loaded above). This is a magnitude judgment — *would the author plausibly change the code, or want to verify something, because of this?* — not a check on whether the stake is well-written. The gate **drops or routes; it never pads.**

**Outcomes:**

- **Material** — a realistic, reachable path makes this matter (blocking), or the cost is felt in normal maintenance/use (suggestion). Keep it; it is a candidate posted comment.
- **Immaterial** — contrived/unreachable failure, or taste with no concrete cost. **Drop it** from the posted set and add it to the `minor (N)` tally (Step 5b). Do **not** rewrite it to sound material.
- **Question** — the concern turns on context the diff does not show (intent, reachability, an upstream guarantee). Reclassify as a `question` rather than asserting a defect or dropping it.

**Missing grounding line** — treat as immaterial: drop and add to the `minor (N)` tally.

**Compound findings** — apply the gate across all contributing findings. The compound qualifies if at least one contributing finding is material; otherwise drop it. The merged stake must remain a single material line, not a concatenation of every lens's reasoning.

<!-- section-boundary -->

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
**Minor (filtered):** <count> (dropped by the materiality gate — not posted; titles available on request)

**Top concerns:**
1. <highest-severity finding title> — [<contributing lenses>]
2. <second finding> — [<contributing lenses>]
3. <third finding> — [<contributing lenses>]
```

Verdict logic: - Any blocking findings -> `BLOCKING` - Only suggestions/questions -> `SUGGESTIONS ONLY` - No findings -> `CLEAN`

## Step 5: Present Findings

### 5a. Overall verdict header

```
## Review: PR #<number> — <title>

**Verdict:** <BLOCKING / CLEAN / SUGGESTIONS ONLY>
**Lenses applied:** <list of lenses that ran>
**Blocking:** <count> | **Suggestions:** <count> | **Questions:** <count>
**Compound findings:** <count> | **Minor (filtered):** <count>
```

The verdict, severity counts, and `minor (filtered)` tally are reviewer-facing — they orient *your* triage. None of them is posted to the PR. The `minor (filtered)` count is the materiality gate's paper trail; offer the dropped titles on request rather than listing them by default.

### 5b. Findings by severity

Present findings grouped by severity (compound findings first within each group). Read `skills/pr-review/templates/step5b-presentation.md` for the by-severity and supplementary-reports templates (supplementary block renders only when ceremony lenses produced non-conforming output per Step 3d).

### 5b-supplementary. Supplementary Reports

Supplementary reports are: - **Excluded** from synthesis (Step 4) — they do not affect compound detection, severity counts, or the verdict - **Excluded** from `post-review.sh` output — they are not posted as GitHub review comments - **Included** in the followup report body (Step 6d) for record-keeping

### 5c. User interaction

After presenting findings, offer the user a chance to discuss or ask questions, then proceed to Step 6. Findings are captured in the followup report with proposed comments for downstream TUI posting.

## Step 6: Generate Followup Report

This step is mandatory and must not be skipped. It always runs after Step 5c resolves.

### 6a. PR Narrative

Using the review brief from Step 3a, synthesize a 1-2 paragraph narrative under a `## PR Narrative` heading covering: what the PR does structurally (drawn from the alignment map); design signals and cross-cutting concerns identified; notable alignment observations (unrelated files, missing pieces) — omit if the PR is coherent.

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

**6d-i. Verify materiality survived synthesis.** Re-check that every `blocking` and `suggestion` finding still clears the Materiality Gate (`severity.md`). Step 4b enforced this, but findings can lose their stake during compound merging or deduplication. Any finding that no longer clears the bar: drop it to the `minor (N)` tally (Step 5b/4e); do not rewrite it to recover.

The test is decision-theoretic, not descriptive: not "can a scenario be described?" (one always can) but "would the author change the code — or want to verify something — because of this?" A finding that survives only as a describable-but-inert scenario is not material.

**6d-ii. Neutralize bodies for external output.** Posted comments are curated and neutral. Strip two things from every finding body:
- **Internal scaffolding** — `**Grounding:**`, `**Severity:**`, `**Knowledge:**`, lens attribution, compound markers. The stake *content* (the conditional fact) survives; the labels do not.
- **Criticality** — no severity word and no verdict ("blocking", "critical", "must fix") crosses to the author. The conditional stake already delegates the criticality call to the reader.

The author should see: observed fact → conditional stake → optional soft fix (a question or light suggestion, never a confident prescription). Default to one line. *(Per-comment criticality opt-in — letting the reviewer re-add a criticality lead to a specific comment — is a Phase-2 TUI affordance; until it lands, posted comments are uniformly neutral.)*

**Voice — hedge the inference, not the observed code fact.** Reviewers cannot know the full system context; every external body should read as a grounded hypothesis, not a verdict.

- **State observed code facts directly.** Weak: "This might be storing the token insecurely." Strong: "`logRequest` writes `session.token` to the access log."
- **Hedge impact claims with an explicit condition.** Weak: "This will crash the server." Strong: "`session.user` is dereferenced without a nil check — if this handler is reachable before auth completes, it panics."
- **Lead with the observation**, not the hedge. Code fact first, uncertainty qualifier second.
- **Use impersonal constructions.** "The handler dereferences…", not "You forgot to check…".
- **Fix suggestions are secondary.** Default to surfacing the issue and stopping. When a fix is included (non-obvious only), place it **after** impact and evidence, frame it **softly — as a question or light suggestion, not a confident prescription** ("Worth …?", "Could … here?"), and keep the scope open so the finding can motivate a broader redesign if appropriate. Never lead a comment body with a fix.
- **Avoid overstated vocabulary** ("this will crash" / "this is wrong" / "this is a bug" / "definitely") — name the condition instead. **Avoid hollow hedges on observations** ("seems like" / "might be" / "I think" / "could potentially") — state the code fact; hedge the *impact*, not the observation.

Full voice guide (optional deeper reference): `~/.lore/claude-md/review-protocol/review-voice.md`.

After stripping and shaping, produce two variants of each finding body:
- **Section 3 variant** (used verbatim under `#### N. <title>` in `## Review Findings`): the stripped+shaped prose as-is. Do **not** prepend a bolded title — the `####` heading already carries it; duplicating produces a visual stutter.
- **Comment-body variant** (used in `## Proposed Comments` previews and the `body` field emitted by Step 6f): prepend `**<title>**\n\n` as the first line, where `<title>` is the finding's title text. Plain bolded title, not a labeled header like `**Impact:**`. Step 6f is serialization-only — it emits this variant without reformatting.

### 6e. Assemble the full report body

Assemble the `--content` value with **all** of the following sections. Every section is mandatory — do not abbreviate, summarize, or omit any section. The `--content` passed to `create-followup.sh` must contain the complete report, not a summary.

**First line:** One-line diagnostic summary (e.g., `ACTION NEEDED — 2 findings requiring action, 3 improvement opportunities`). First non-heading line — it appears as the TUI excerpt.

**Second line:** `**Author:** @<author>` — PR author's GitHub handle from Step 1c.

**Section 1 — PR Narrative** (from 6a): include the 1-2 paragraphs verbatim under a `## PR Narrative` heading; do not re-summarize.

**Section 2 — Implementation Diagram** (from 6b): include the ASCII box-drawing diagram verbatim under a `## Implementation Diagram` heading.

**Section 3 — Review Findings:**

Include the full finding details from Step 5b with internal protocol headers stripped per Step 6d-ii. The report is an author-facing artifact. If ceremony lenses produced non-conforming output (Step 5b-supplementary), append the Supplementary Reports block after the structured findings. Supplementary reports are presentation-only — they do **not** generate review code blocks in Section 4 or entries in `proposed-comments.json`. Read `skills/pr-review/templates/review-findings-section.md` for the Section 3 markdown template.

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

Proposed comments are a **curated subset** — the posted artifact, not a projection of the Review Findings list. They need not be 1:1 with the Section 3 findings: immaterial findings (the `minor (N)` tally) are never posted, and where it reads better, several findings may collapse into one comment. Only material findings with both `file` and `line` become proposed comments.

Build the array by walking the proposed comments in severity-group order (`blocking` → `suggestion` → `question`). Within each group, number them with a fresh 1-based `finding_ordinal` over the proposed comments themselves — this counter is the comment's own identity, **not** tied to any Section 3 `#### N.` position (the two are allowed to diverge). For each proposed comment, emit `{"path": "<file>", "line": <line>, "body": "<finding body>", "title": "<finding title>", "finding_ordinal": <N>}`. Bodies must be neutralized per Step 6d-ii — internal scaffolding **and** criticality stripped, stake content preserved, default to one line.

Pass the **complete report body from 6e** as `--content`:

```bash
bash ~/.lore/scripts/create-followup.sh \
  --source "pr-review" \
  --title "Review: <PR title> (#<N>)" \
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

Read `skills/pr-review/templates/capture-invocation.md` for the full `/remember` invocation to dispatch.

## Error Handling

- **No gh CLI or not authenticated:** Tell user to run `gh auth login`
- **PR not found:** Confirm the PR number and repo access
- **Empty diff:** PR may have no changes — confirm with user
- **Agent failure:** If a lens agent fails, proceed with available findings and note the gap in the verdict
- **No findings:** Report "Holistic review: no findings across all lenses" — this is a valid outcome

## Resuming

If re-invoked on the same PR, check for existing work items (`pr-lens-review-<PR_NUMBER>` or `pr-review-<PR_NUMBER>` in `/work list`). If found: - Load existing findings from the work item - Offer to run additional lenses or re-run synthesis with new findings - Append rather than overwrite
