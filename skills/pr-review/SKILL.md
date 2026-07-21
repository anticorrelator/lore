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

**Otherwise:** Start with the default set (Correctness + Regressions + Test Quality + Interface Clarity + User Impact + Structural Read), then: 1. For each remaining lens (Security, Blast Radius), check trigger signals against the PR's changed files and diff content 2. If risk tier is High: force-add Security regardless of signals 3. Apply skip conditions — only skip a lens if ALL its skip conditions are true

**Structural Read is always in the default set and has no skip condition** — it is the one whole-PR lens (solution-shape, not changed lines) and runs on every non-`--thorough` review. Its substrate is the promoted Narrative + Diagram built in Step 3, so it reads the PR end to end rather than line by line; see `~/.lore/claude-md/review-protocol/structural-altitude.md` for the altitude boundary that keeps it from re-filing what interface-clarity (local) or thematic (scope) already own.

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
| Structural Read | Default selection (whole-PR) |
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

### 3a-knowledge. Prefetch domain knowledge for lens agents

Lens agents must start from the knowledge store, not raw exploration — and they are diff-scoped subagents, so knowledge is delivered **push-style** in their prompts rather than each agent re-deriving it.

1. Derive **at most 3** topic queries from the PR: the primary touched module(s) from the alignment map first, ordered by changed surface and centrality, then the PR's domain (from its title/intent) only if budget remains and no module query already covers it. Each query names a concrete module or domain — neither a single generic word nor a full sentence.
2. For **each** derived topic, run both prefetches — one per consumer altitude:
   ```bash
   lore prefetch "<topic>" --scale-set subsystem,implementation   # for diff-local lenses
   lore prefetch "<topic>" --scale-set architecture,subsystem     # for the Structural Read lens
   ```
3. Route the outputs into two exclusive blocks, concatenating across topics grouped by topic:
   - **Diff-local block** — the `subsystem,implementation` output. Append to the shared `## Review Context` block:

     ```
     **Prior Knowledge:**
     <subsystem/implementation prefetch output — conventions, gotchas, and decisions for the touched area>
     ```
   - **Architecture block** — the `architecture,subsystem` output. Hold it aside for the Structural Read prompt (Step 3b-structural).

   Route the two altitude blocks **exclusively**: implementation-scale content never reaches the structural prompt; architecture-scale content never reaches diff-local prompts. (`subsystem` is the deliberate overlap layer in both prefetches.) Do not mix altitudes — implementation detail in the structural prompt pushes it off its whole-PR altitude, and architectural philosophy in diff-local prompts invites over-thinking line-level findings.

**Empty vs. failed — distinguish, never collapse one into the other:**
- A prefetch that **exits zero with empty stdout** is treated as absence for prompt construction: omit the diff-local sub-block (Step 3b template), or use the explicit one-liner in the structural prompt (Step 3b-structural). Do not pad with filler — fabricated context is worse than none. But do not claim this proves the store is empty: the prefetch path can return clean-empty for silent query failures, so absence here means "nothing surfaced," not "nothing exists."
- A prefetch that **exits non-zero or emits errors** is a retrieval failure, not absence. Report the failed topic + scale in the same routed channel that block feeds (a one-line failure note in the diff-local Prior Knowledge sub-block or the structural Prior Knowledge section), so the lens knows that altitude went unqueried rather than came back empty.
- **Partial failure** keeps the successful topics' output and reports only the failed topic + scale alongside it — it never collapses the whole block into absence.

### 3a-narrative. Build the PR Narrative and Implementation Diagram

Build these now — before lens dispatch — so the Structural Read lens (Step 3b) can consume them as its substrate. They are also the same artifacts Step 6 reports, so building them here avoids double-authoring (Step 6a/6b reuse this output rather than re-deriving it).

- **PR Narrative.** From the alignment map, synthesize a 1-2 paragraph narrative covering what the PR does structurally, the design signals and cross-cutting concerns identified, and notable alignment observations (unrelated files, missing pieces) — omit the alignment-observation note if the PR is coherent.
- **Implementation Diagram.** An ASCII logical-flow diagram of how the changes work mechanically, per `~/.lore/claude-md/review-protocol/followup-template.md`. The multi-module gate still governs: draw it only when the PR touches 2+ distinct modules (grouped by first directory component, `(root)` for repo-root files). On a single-module PR, omit the diagram — the Structural Read lens then runs on narrative + diff alone.

Append both to the shared `## Review Context` block as **orienting context only**:

```
**PR Narrative:**
<1-2 paragraphs from above>

**Implementation Diagram:**
<ASCII diagram, or omit this sub-block on single-module PRs>
```

**Evidence precedence — the narrative and diagram are non-authoritative derived context.** The orchestrator generated them; they are not ground truth. Diff-local lenses receive this block to orient, not as a new finding surface: they continue to emit only `{file, line}` findings grounded in the diff/source, and the brief alone can never be the sole basis for a finding anchored to a changed line. Pass the following caveat verbatim inside every lens prompt's context block so no lens treats the generated brief as proof:

```
The PR Narrative and Implementation Diagram above are derived context the
orchestrator generated to orient you — not ground truth. Ground every finding
in the diff or source. The brief alone is never sufficient basis for a finding.
```

### 3b. Read lens methodologies and spawn agents

**Dispatch guidance gate:** For every built-in, Structural Read, ceremony, or perspective-agent launch or retry, run `lore dispatch guidance` immediately before assembling that launch's prompt. Prepend that launch attempt's complete output verbatim as the first block; never copy, summarize, cache, or reuse it for another launch. If any render fails while preparing the single parallel lens batch, issue none of that batch; a retry renders a fresh block independently for every member before launch. This changes neither model routing nor concurrency.

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
| Structural Read | `~/.lore/claude-md/review-protocol/structural-altitude.md` | Structural Read Lens |

For each selected lens, create a task with this structure:

```
<complete `lore dispatch guidance` output rendered for this launch attempt, verbatim>

# <Lens Name> Lens — PR #<number>

You are a lens review agent analyzing PR #<number> in <owner>/<repo>.
Your sole focus is the <lens name> lens. Apply only this methodology.

## PR Context
- **Title:** <title>
- **Author:** @<author>
- **Files changed:** <count>
- **Existing review concerns:** <summary of relevant prior comments, or "None">

<review context block from 3a>

## Prior Knowledge

<When the Review Context carries a **Prior Knowledge** sub-block (Step
3a-knowledge appended one), keep the next sentence; when the prefetch surfaced
nothing and the sub-block was omitted, replace it with:
"No prior knowledge surfaced at this altitude — query the store as below before
raw exploration.">

The Review Context above includes a **Prior Knowledge** sub-block prefetched
from the project knowledge store. Read it BEFORE analyzing the diff — it
documents conventions, gotchas, and past decisions for the touched area that
the diff alone cannot surface. Use it two ways:
- Before flagging a pattern as wrong, check whether Prior Knowledge documents
  it as an intentional convention or known trade-off.
- A finding that contradicts a documented convention cites that entry in its
  `knowledge_context`.
For topics it does not cover, query the store before raw code exploration:
```bash
lore search "<topic>" --type knowledge --scale-set subsystem,implementation --json --limit 3
```

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

Every `blocking`/`suggestion` finding needs a `**Grounding:**` line: the **path to the problem**, for a reviewer who's never seen this code — *what someone does to hit it → what they'd see*, in usage terms, not code terms:

> **Grounding:** If the agent renames a tool that's the forced choice, the next run is rejected by the provider for forcing a tool that no longer exists.

Writing that trigger is also the materiality test: if the trigger is contrived, or the outcome is just what the action asked for with nothing the code could do, drop the finding rather than dress up a bare code-state ("`X` may be orphaned"). Mechanism (function names, call chains) is an optional trailing clause for the author, never the substance.

Query the knowledge store for each finding:
```bash
lore search "<topic>" --type knowledge --scale-set subsystem,implementation --json --limit 3
```

**Voice — hedge the inference, not the observed code fact.** State observed code facts directly; hedge impact claims with an explicit condition. Lead with the observation, then the qualifier. Use impersonal constructions ("The handler dereferences…", not "You forgot to check…"). Fix suggestions are secondary and optional — surface the issue and stop unless the fix is non-obvious; never lead with a fix. Avoid overstated vocabulary ("this will crash", "this is a bug", "definitely") and hollow hedges on observations ("seems like", "might be", "I think") — name the specific condition. Full guidance: `~/.lore/claude-md/review-protocol/review-voice.md` (see also Step 6d-ii below for the externally-facing variant).

Report back with your findings JSON when complete.
```

The diff-local lens prompt above asks for `{file, line}` findings JSON. The Structural Read lens is the **deliberate whole-PR exception** — it carries observations, not diff-anchored findings — so it gets the distinct prompt in Step 3b-structural, not the generic template above.

Construct one Agent task per built-in lens (Structural Read included), but **do not dispatch yet** — ceremony lens tasks and the structural lens must launch together with the diff-local lens tasks in the same parallel batch (see Step 3b-structural and Step 3b-ceremony, then Step 3b-launch).

### 3b-structural. Construct the Structural Read lens task

The Structural Read lens is the one whole-PR lens. Construct it as an `Agent` task — *not* a `Skill` invocation (a `Skill` call would serialize it; see Step 3b-launch) — using the `general-purpose` subagent type. Read its methodology from `~/.lore/claude-md/review-protocol/structural-altitude.md` and embed it verbatim, the same way the Security lens embeds `security-methodology.md`.

Its substrate is **diagram (when present) + narrative + diff** — the promoted Narrative + Diagram from Step 3a-narrative, plus the diff. It never receives other lenses' raw findings; the cross-finding benefit is recovered later in synthesis (Step 4-structural). On a single-module PR no diagram was drawn — embed narrative + diff alone and say so, so the diagram-dependent checks are skipped rather than hallucinated. It also receives the **architecture-scale Prior Knowledge** held aside in Step 3a-knowledge — not the diff-local block — so its idiom-fit judgment is grounded in documented architecture and conventions rather than re-inferred from the diff.

```
<complete `lore dispatch guidance` output rendered for this launch attempt, verbatim>

# Structural Read Lens — PR #<number>

You are the Structural Read lens agent for PR #<number> in <owner>/<repo>.
You are the one WHOLE-PR lens: unlike the diff-local lenses, you do not scan
changed lines and emit {file, line} findings. You read the PR as a designed
solution — its logical flow, its fit to codebase idiom, and its PR-level
abstractions and contracts — and return a reviewer-facing assessment with
observations. Apply only the Structural Read methodology below.

## PR Context
- **Title:** <title>
- **Author:** @<author>
- **Files changed:** <count>

## Substrate

**PR Narrative:**
<narrative from Step 3a-narrative>

**Implementation Diagram:**
<ASCII diagram from Step 3a-narrative, OR:>
No diagram was drawn (single-module PR). Run on narrative + diff alone;
skip diagram-dependent checks rather than inferring a diagram.

## Prior Knowledge

<architecture/subsystem-scale prefetch output from Step 3a-knowledge, OR:>
No prior knowledge surfaced at this altitude.

Read this before assessing the PR: documented architecture, conventions, and
design rationale are the baseline for your idiom-fit judgment — prefer citing
a documented convention over re-inferring codebase idiom from the diff. For
topics it does not cover:
```bash
lore search "<topic>" --type knowledge --scale-set architecture,subsystem --json --limit 3
```

## Diff

<inline diff for <=400 LOC, or:>
Read the diff from: /tmp/pr-review-<PR_NUMBER>.diff

**Evidence precedence:** the Narrative and Diagram are derived context the
orchestrator generated to orient you — not ground truth. Ground every
observation in the diff or source; the brief alone is never sufficient basis.

## Methodology

<verbatim contents of structural-altitude.md>

## Output

Return one reviewer-facing assessment: a `verdict`, a brief rationale, and an
`observations[]` array. Zero observations is a valid result ("no structural
issue beyond the assessment"), not a failure. Each observation carries
`summary`, `evidence`, `scope`, and `downstream_cost` (present only when it
clears the structural materiality bar) per the Observation Schema in the
methodology. Set `scope` honestly — a `whole-PR` observation must not invent
fake line anchors to look correlatable.

Report back with your structural assessment when complete.
```

### 3b-ceremony. Construct ceremony lens tasks

**This step is mandatory and must not be skipped.** Ceremony lenses are identified by the `[ceremony]` tag assigned during Step 2b. For each ceremony lens in the selected set, construct an `Agent` task — *not* a `Skill` invocation — using the `general-purpose` subagent type with this prompt structure: read `skills/pr-review/templates/ceremony-lens-prompt.md`.

Immediately before each ceremony launch or retry, render a new complete dispatch-guidance block and prepend that launch's output verbatim before the ceremony template content. The template remains otherwise unchanged.

The `Agent`-wrapped invocation — rather than a direct `Skill` call from the main conversation — is what makes parallel execution with built-in lens agents possible. `Skill` invocations run synchronously in the main thread; `Agent` invocations issued in a single message run concurrently.

<!-- section-boundary -->

### 3b-launch. Spawn all lens agents in a single parallel batch

Issue every `Agent` tool call — one per selected lens (diff-local, the Structural Read lens, and ceremony) — in a **single message**. Spawning built-in lens agents first and then dispatching the structural or ceremony lens in a follow-up message serializes that work behind built-in completion and erases the latency gain the parallel design is meant to capture. The structural lens is dispatched in this same batch as the diff-local lenses — its whole-PR scope does not move it to a serial post-pass.

There is no fixed concurrent-agent cap; spawn the full selected set together. Typical batches run 6–9 agents (defaults including Structural Read, plus 0–3 ceremony lenses).

**Why unconditional parallel dispatch matters.** A downstream telemetry consumer — tournament reconciliation, coverage dashboards, session observability — cannot distinguish "ceremony not configured" from "agent chose not to run it" when the dispatch is silently skipped. Silent omission corrupts the signal: configured lenses appear as absent lenses, and the consumer has no way to recover the distinction after the fact.

Do NOT skip this step. Do NOT omit a ceremony lens because the PR is small. Do NOT omit because the run seems low-signal. Do NOT omit because the user did not explicitly re-request ceremony lenses this session. Do NOT omit because of perceived latency cost. Do NOT defer ceremony dispatch to a follow-up message under any of these rationales — deferral is functionally a skip from the parallelism perspective. None of these are valid rationales — the user configured the ceremony; only the user can remove it. If a ceremony lens is genuinely inapplicable, stop and ask the user whether to remove it at Step 2c rather than self-removing.

Ceremony lens results are collected in Step 3d alongside built-in results; output not in the standard Findings Output Format is handled as non-conforming there.

### 3c. Self-review perspective lenses (--self mode only)

If mode is `--self`, after standard lens agents complete, spawn perspective-lens agents:

Immediately before each perspective-lens launch or retry, render a new complete dispatch-guidance block and prepend that launch's output verbatim to its prompt below. Fail before that launch if rendering fails rather than dispatching a floorless prompt.

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

**Structural Read lens result:** the structural lens returns an assessment (`verdict` + rationale + `observations[]`), not the diff-local `{file, line}` findings format — by design, it is the whole-PR lens. Hold its observations aside; they do **not** join compound detection or the severity counts as ordinary findings. They feed two places: the cockpit-only correlation in Step 4d-structural and the altitude routing in Step 6d-structural. If the structural agent fails, times out, or returns malformed output, record that in the Structural Assessment section (Step 6d-structural) and propose no structural posted comment — never fabricate observations.

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
lore search "<finding topic>" --type knowledge --scale-set subsystem,implementation --json --limit 3
```

Attach relevant citations. If any knowledge entry is STALE and the PR contradicts it, flag as "convention may need updating" — not "PR is wrong."

### 4d-structural. Correlate structural observations with diff-local clusters (cockpit-only)

For each structural observation that carries a changed-line or file anchor (per its `scope`), check whether the diff-local findings synthesized above cluster in the region it names. Reuse the **existing** file/line proximity mechanics — the same within-3-lines, grouped-by-`file` test compound detection already uses (`cross-lens-synthesis.md`). Introduce no new thresholds, no new severity, no new routing.

A cluster is a strain signal: independent diff-local findings converging where the structural lens flagged the solution-shape raises the reviewer's confidence. When findings cluster in an observation's region, **annotate that observation's cockpit entry** with a corroboration note — e.g. "3 diff-local findings cluster here." That is the whole effect.

- An observation whose `scope` is `whole-PR` or module-only has no concrete anchor — it is simply **not correlated**. Absence of a cluster check means "no annotation," never lower confidence or a dropped observation.
- This correlation is **strictly cockpit-only**. It annotates the reviewer's triage view and **never changes what crosses the wall** to a posted comment. The structural materiality bar (Step 6d-structural), not the cluster, decides what gets posted — a corroboration note must not promote an observation past the bar, and its absence must not demote one.

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

After the severity groups, present the **Structural Assessment** (Step 3d's structural lens result): the structural verdict, rationale, and observations with any Step 4d-structural corroboration notes. This is the whole-PR read and is reviewer-facing — it does not enter the severity counts. The full section is assembled into the report body at Step 6d-structural; here, surface it so the reviewer sees the solution-shape read alongside the line-level findings.

### 5b-supplementary. Supplementary Reports

Supplementary reports are: - **Excluded** from synthesis (Step 4) — they do not affect compound detection, severity counts, or the verdict - **Excluded** from `post-review.sh` output — they are not posted as GitHub review comments - **Included** in the followup report body (Step 6d) for record-keeping

### 5c. User interaction

After presenting findings, offer the user a chance to discuss or ask questions, then proceed to Step 6. Findings are captured in the followup report with proposed comments for downstream TUI posting.

## Step 6: Generate Followup Report

This step is mandatory and must not be skipped. It always runs after Step 5c resolves.

### 6a. PR Narrative

Reuse the PR Narrative built in Step 3a-narrative — do not re-author it. Present it under a `## PR Narrative` heading, optionally enriched with where findings landed (e.g., which files drew the most findings). The 1-2 paragraphs already cover what the PR does structurally, the design signals and cross-cutting concerns, and notable alignment observations.

### 6b. Implementation Diagram

Reuse the Implementation Diagram built in Step 3a-narrative — do not re-draw it. The multi-module gate already governed whether one exists (`followup-template.md`, 2+ modules); on a single-module PR there is no diagram and this section is omitted, exactly as Step 3a-narrative decided.

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

**6d-ii. Produce two variants — the cockpit finding and its distilled translation.** These are different artifacts, not one body lightly edited. The posted comment is written *from the lens finding*, not copied from it.

- **Reviewer-cockpit variant** (Section 3, under `#### N. <title>`, grouped by severity tier): the full finding. The mechanism anchor, call-chains, lens attribution, "not a regression" caveats, and the severity tier all live here. This is never posted — it is your triage view in the TUI.

- **Posted-comment variant** (the `body` Step 6f emits to `proposed-comments.json`): a **distilled translation** of the finding into one human-scannable line, written from the reader's vantage. Translate the code facts you hold into the usage-level path the reader can map — *when* the issue bites and *what the author would observe* — then stop. Strip everything the cockpit already keeps:
  - **Internal scaffolding** — `**Grounding:**`, `**Severity:**`, `**Knowledge:**`, lens attribution, compound markers.
  - **Criticality** — no severity word, no verdict ("blocking", "critical", "must fix"). The conditional stake already delegates the criticality call to the reader.
  - **Mechanism** — function names, call-chains, type names. A symbol survives only if the comment is unintelligible without it, and never in the lead sentence.

  One sentence is the target — a human triaging a dozen-plus findings across several review passes cannot hold a paragraph per finding. A second sentence is earned only by a soft fix-as-question, never by more explanation. This is the production bar that prompt guidance alone has missed: do not let the lens's mechanism-first prose flow through unchanged. And mind the anchor — an inline comment's "this/these/here" must resolve to something on the commented line; for a multi-spot issue, anchor on the first and give a verifiable count ("9 other lines in this file"), never a vague plural (see `review-voice.md` → Anchored Deixis).

  If a finding genuinely can't compress this far without losing the path, it stays **cockpit-only** — keep it in Section 3 and omit it from `proposed-comments.json`. A material finding can be reviewer-facing without being posted; that is cleaner than shipping a paragraph inline.

  **Everything posted to GitHub is written for a colleague outside this project's process.** This covers inline comments and the top-level structural-notes block (the review's summary comment) alike. Use shared professional vocabulary; a term whose precise meaning was established inside this project (in its docs, plans, or working sessions) either gets replaced with a common-vocabulary equivalent or is defined in the comment itself. The reader has no access to this project's internal writing and no obligation to acquire its vocabulary — a comment they can only parse with that context is a comment that will be confidently misread.

  *Translate, don't copy* — the failure mode is shipping the cockpit prose verbatim:

  > **Bad (copied from cockpit — mechanism-led, do not post):** `applyModelNameDefaults` prefixes the name via `applyBedrockModelPrefix` when `provider === "AWS"`; no test sets `awsBedrockModelPrefix`, so if the `startsWith` idempotency guard regresses the agent sets an invalid model ID and `run_playground` fails.

  > **Good (distilled translation — post this):** **AWS Bedrock model-switch is untested.** For an AWS user with a Bedrock prefix configured, a regression here would set an invalid model and the next run fails at launch. Add a happy-path AWS case?

  *(Per-comment criticality opt-in — letting the reviewer re-add a criticality lead to a specific comment — is a Phase-2 TUI affordance; until it lands, posted comments are uniformly neutral.)*

**Voice:** hedge the inference, not the code fact — state what the code does, hedge what follows from it; impersonal, no overstatement, fixes only when non-obvious and framed as a question. Full guide: `~/.lore/claude-md/review-protocol/review-voice.md`.

### 6d-structural. Route the structural assessment to three altitude channels

The structural lens result (Step 3d) routes to three channels. The materiality bar and posted form are defined in `~/.lore/claude-md/review-protocol/structural-altitude.md` — apply it here; do not restate it.

**Channel 1 — Structural Assessment (cockpit, always).** Build a `## Structural Assessment` report section from the lens's `verdict`, rationale, and **every** observation — including the ones that drop the materiality bar and the corroboration notes from Step 4d-structural. This section renders on **every** run, even when zero observations cleared the bar and even when the lens found nothing (state "no structural concerns" then). It is never posted; it is the reviewer's whole-PR triage view, so it keeps the full reasoning. If the structural agent failed or returned malformed output (Step 3d), say so here and stop — propose no structural posted comment.

**Channel 2 — top-level PR comment (`review_body`, materiality-gated).** An observation crosses to the posted top-level comment only when it clears the structural materiality bar — i.e. it carries a concrete `downstream_cost`. For each such observation, write its **posted form** (per `structural-altitude.md`: names material impact in usage terms, neutral, no severity word, one line where possible; a non-obvious fix framed softly as a question). Wrap the collected posted forms in a sentinel block:

```
<!-- lore-structural -->
## Structural notes

<one neutral one-line posted form per crossed observation>
<!-- /lore-structural -->
```

The sentinel pair lets this block coexist in `review_body` with the generated summary and the `<!-- lore-additional-comments -->` block downstream tools splice — each owns its own delimiters, so write order does not matter and none clobbers another. Emit the block via the `create-followup.sh` review-body flags in Step 6f (`--review-body`, `--review-body-selected`, `--review-event COMMENT`).

**When nothing clears the bar, build no block** — leave `review_body` unset and do **not** pass `--review-body-selected`; no top-level comment is proposed. (`create-followup.sh` rejects `--review-body-selected` without `--review-body`, so the two move together.)

**Channel 3 — inline spill (route-priority).** An observation that clears the bar **and** carries an honest changed-line anchor (its `scope` is changed-line, not `whole-PR` or module-only) becomes a normal inline proposed comment instead — distilled to the same one-line posted form, added to the Step 6f `proposed-comments` array like any other material finding. **Route-priority — never the same ask in both:** a locally-anchored observation routes to the inline comment; a PR-level observation with no honest line anchor routes to the top-level `review_body` block. The same observation must not appear as both an inline comment and a top-level note. A `whole-PR` observation is top-level-only by construction; an honestly line-anchored one is inline-only.

### 6e. Assemble the full report body

Assemble the `--content` value with **all** of the following sections. Every section is mandatory — do not abbreviate, summarize, or omit any section. The `--content` passed to `create-followup.sh` must contain the complete report, not a summary.

**First line:** One-line diagnostic summary (e.g., `ACTION NEEDED — 2 findings requiring action, 3 improvement opportunities`). First non-heading line — it appears as the TUI excerpt.

**Second line:** `**Author:** @<author>` — PR author's GitHub handle from Step 1c.

**Section 1 — PR Narrative** (from 6a): include the 1-2 paragraphs verbatim under a `## PR Narrative` heading; do not re-summarize.

**Section 2 — Implementation Diagram** (from 6b): include the ASCII box-drawing diagram verbatim under a `## Implementation Diagram` heading.

**Section 3 — Review Findings:**

Render the **reviewer-cockpit variant** of each finding from Step 6d-ii (full mechanism and caveats kept; internal protocol labels stripped for readability). This report is **reviewer-facing** — it lives in your knowledge store and is read in the TUI to triage; it is never posted (only the curated comments in Section 4 reach the PR). So it **retains** the severity grouping, counts, and verdict line, using the same reviewer-facing labels as Step 5a (see `findings-format.md` → External Output Formatting → reviewer-facing surfaces). If ceremony lenses produced non-conforming output (Step 5b-supplementary), append the Supplementary Reports block after the structured findings. Supplementary reports are presentation-only — they do **not** generate review code blocks in Section 4 or entries in `proposed-comments.json`. Read `skills/pr-review/templates/review-findings-section.md` for the Section 3 markdown template.

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

**Section 5 — Structural Assessment** (from 6d-structural): include the cockpit `## Structural Assessment` section verbatim — the structural verdict, rationale, and every observation with its Step 4d-structural corroboration note. This section is **always present**: on a clean structural read state "no structural concerns"; on agent failure state the coverage gap. It is reviewer-facing (never posted); the posted structural notes live only in the `review_body` sentinel block (Channel 2), not here.

### 6f. Persist the report

Proposed comments are a **curated subset** — the posted artifact, not a projection of the Review Findings list. They need not be 1:1 with the Section 3 findings: immaterial findings (the `minor (N)` tally) are never posted, and where it reads better, several findings may collapse into one comment. Only material findings with both `file` and `line` become proposed comments.

Build the array by walking the proposed comments in severity-group order (`blocking` → `suggestion` → `question`). Within each group, number them with a fresh 1-based `finding_ordinal` over the proposed comments themselves — this counter is the comment's own identity, **not** tied to any Section 3 `#### N.` position (the two are allowed to diverge). For each proposed comment, emit `{"path": "<file>", "line": <line>, "body": "<finding body>", "title": "<finding title>", "finding_ordinal": <N>}`. Each `body` must be the **posted-comment variant** from Step 6d-ii — a distilled usage-terms translation, one line, with internal scaffolding, criticality, **and** mechanism stripped; not a copy of the Section 3 cockpit prose.

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
  --content "<complete report body from 6e — all sections>" \
  --producer-role "pr-review" \
  --protocol-slot "Observations"
```

**Structural top-level comment (Channel 2 of Step 6d-structural).** When — and only when — at least one structural observation cleared the materiality bar, append these flags to the call above so the `<!-- lore-structural -->` block lands in `review_body` and is pre-selected for posting:

```bash
  --review-body "<the <!-- lore-structural -->...<!-- /lore-structural --> block from 6d-structural>" \
  --review-body-selected \
  --review-event COMMENT
```

When nothing cleared the bar, omit all three — `--review-body-selected` without `--review-body` is rejected, so they move as a unit and no top-level comment is proposed. The inline-spill observations (Channel 3) are already in the `--proposed-comments` array above and need no extra flag.

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
