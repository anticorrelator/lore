---
name: pr-self-review
description: "Author-calibrated self-review: parallel lens pre-scan (Blast Radius, Security, Test Quality, Correctness, Regressions, Interface Clarity) then confirmatory dialog to disposition findings into a phased plan.md"
user_invocable: true
argument_description: "[PR_number_or_URL] [--skip-pre-scan] [focus context] — PR to self-review (or auto-detect from branch). --skip-pre-scan skips the lens team and uses heuristic dialog instead (useful for resuming, very small PRs, or targeted exploration). Optional focus context steers finding priority (e.g., '42 focus on error handling')"
---

# /pr-self-review Skill

Author-calibrated self-review combining structured analysis with interactive dialog. A parallel lens team (Blast Radius, Security, Test Quality, Correctness, Regressions, Interface Clarity) runs a pre-scan, then you and the user discuss each finding in a confirmatory dialog — assigning dispositions (action/accepted/deferred/open) rather than generating observations from scratch. Self-review blindness is structural when reviewing agent-generated code, so the lens team provides external analytical perspectives while the dialog forces genuine re-examination.

Since this is your own work, locally-scoped action items can be implement-ready. Findings with cross-boundary implications (especially from Blast Radius) get verification directives instead. This distinguishes it from `/pr-review` (reviewing someone else's code) and `/pr-revise` (addressing existing external feedback).

This skill does not modify source code.

## Step 1: Identify PR and Focus Context

Argument provided: `$ARGUMENTS`

**Parse flags:** If `--skip-pre-scan` is present, set a flag to skip the multi-lens pre-scan (Steps 2.5–3c). The review will proceed directly from PR data to heuristic area identification and dialog. Strip the flag before further parsing.

**Parse arguments:** The first token that looks like a PR number (digits) or GitHub URL is the PR identifier. Everything else is **focus context** — free-text guidance about which areas to concentrate on during the review.

Examples:
- `42` → PR #42, no focus context
- `42 focus on the error handling in the new scripts` → PR #42, focus on error handling
- `https://github.com/org/repo/pull/42 cross-boundary invariants` → PR #42, focus on invariants
- `concentrate on the knowledge enrichment pipeline` → no PR (auto-detect), focus context provided

**If no PR identifier:** Detect from current branch:
```bash
gh pr list --state open --head "$(git branch --show-current)" --json number,baseRefName --jq '.[] | "#\(.number) → \(.baseRefName)"' 2>/dev/null
```

**If multiple PRs found:** Present the list with base branches and ask the user which one to review.

**If no PRs found:** Ask the user for the PR number or the base branch to diff against. If only a base branch is provided (no PR exists yet), fall back to `git diff <base>...HEAD` for the diff and skip comment fetching — the review proceeds purely from the code diff.

**Carry focus context forward** — it influences area prioritization in Step 3 and topic selection in Step 4. If focus context is provided, the identified areas should lead with the user's focus, and the opening observation should address it directly.

## Step 2: Fetch PR Data

```bash
bash ~/.lore/scripts/fetch-pr-data.sh <PR_NUMBER>
gh pr diff <PR_NUMBER>
gh pr view <PR_NUMBER> --json files,title,body,baseRefName,headRefName,commits
```

The fetch script returns grouped JSON: `grouped_reviews` (reviews with inline comments attached), `unmatched_threads`, and `orphan_comments`. For self-review, note any existing reviewer feedback to avoid duplicating observations already raised.

## Step 2.5: Soft Triage

**Skip this step if `--skip-pre-scan` was set.**

Compute the total lines of code changed from the diff (additions + deletions). Display a triage summary:

```
[pr-self-review] Triage
Size: <N> LOC across <M> files
Lenses: Blast Radius · Security · Test Quality · Correctness · Regressions
Add or remove lenses? (enter lens names, or press Enter to proceed)
```

If the diff exceeds 400 LOC, append a size warning:

```
Size: <N> LOC (large — consider --skip-pre-scan for targeted exploration)
```

The default lens set for self-review is: **Blast Radius, Security, Test Quality, Correctness, Regressions, Interface Clarity**. Thematic is omitted — lens utility for self-review correlates inversely with reliance on inferring intent (the author already knows intent). Interface Clarity is included — self-review blindness for clarity is strong; authors routinely miss unclear names, implicit preconditions, and poor call-site ergonomics in their own code.

This is a soft gate — no explicit confirmation is required to proceed. If the user names lenses to add or remove, adjust the set. If they press Enter or continue the conversation, proceed with the displayed set.

## Step 3a: Abbreviated Thematic Anchor

**Skip this step if `--skip-pre-scan` was set.**

Run an abbreviated thematic pass inline (not as a spawned agent). This produces structural context for lens agents — specifically, which files are central vs. peripheral and what design patterns are in play. Unlike the full thematic anchor in `/pr-review`, this skips theme synthesis ("This PR does X") and scope verdict (coherent/mixed/scattered) — the author already knows the intent.

### Per-file alignment map

Walk each changed file and classify its relationship to the PR's purpose:

- **Directly supports** — necessary to achieve the PR's goal; without it, the change is incomplete
- **Tangentially related** — related to the goal's area but not strictly required (opportunistic cleanup, adjacent improvements)
- **Unrelated** — no connection to the PR's goal (formatting in untouched areas, orthogonal features)

For large diffs (>15 files), group by directory/module first, then classify groups. Apply per-file analysis only to tangential or unrelated groups.

### Design signals

Identify signals that downstream lens agents should know:
- Architectural patterns or conventions observed in the change set
- Cross-cutting concerns (e.g., "this PR modifies both the CLI and the underlying library")
- Areas of higher risk or complexity based on alignment classification
- Missing pieces that other lenses should verify (e.g., "new public API added but no tests observed")

### Structure as Self-Review Context block

Format the output as a reusable block for injection into lens agent prompts in Step 3b:

```
## Self-Review Context

**Alignment map:**
| File | Classification | Notes |
|------|---------------|-------|
| path/to/file.ext | Directly supports | <brief rationale> |
| ... | ... | ... |

**Design signals:**
- <signal 1>
- <signal 2>
```

This block gives each lens agent the structural context without requiring them to re-analyze scope. They can focus entirely on their specific analytical concern.

## Step 3b: Spawn Parallel Lens Agents

**Skip this step if `--skip-pre-scan` was set.**

Spawn parallel lens agents to execute the lens set confirmed in Step 2.5. Each agent receives everything it needs inline — no references to external files that agents would need to read.

### Read lens methodologies

For each selected lens, read its Step 3 methodology from the corresponding source:

| Lens | Source | Step 3 heading |
|------|--------|---------------|
| Blast Radius | `skills/pr-blast-radius/SKILL.md` | Blast Radius Analysis |
| Security | `claude-md/review-protocol/security-methodology.md` | Security Lens Methodology |
| Test Quality | `skills/pr-test-quality/SKILL.md` | Test Quality Analysis |
| Correctness | `skills/pr-correctness/SKILL.md` | Correctness Analysis |
| Regressions | `skills/pr-regressions/SKILL.md` | Regressions Analysis |
| Interface Clarity | `skills/pr-interface-clarity/SKILL.md` | Interface Clarity Analysis |

Read each selected lens's Step 3 content. You will embed this verbatim in the agent task description.

**Correctness lens modification:** When embedding the Correctness methodology, append this note after the verbatim content:

> **Self-review note:** Skip step 3d (intent alignment). The author already knows the intent — checking whether the code matches stated intent is redundant. Focus on the remaining correctness sub-steps.

### Assemble lens agent prompts

For each selected lens, create a task with this structure:

```
# <Lens Name> Lens — PR #<number> (Self-Review Pre-Scan)

You are a lens review agent analyzing PR #<number> in <owner>/<repo>.
Your sole focus is the <lens name> lens. Apply only this methodology.

## PR Context
- **Title:** <title>
- **Author:** @<author> (this is the author's own self-review)
- **Files changed:** <count>
- **Existing review concerns:** <summary of relevant prior comments, or "None">

<Self-Review Context block from Step 3a>

## Diff

<inline diff for <=400 LOC, or:>
Read the diff from: /tmp/pr-self-review-<PR_NUMBER>.diff

## Methodology

<verbatim Step 3 content from the lens's source, with correctness modification if applicable>

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

### Spawn agents

Spawn one agent per selected lens in parallel using the assembled prompts. Maximum 6 concurrent agents. For diffs >400 LOC, write the diff to `/tmp/pr-self-review-<PR_NUMBER>.diff` before spawning so agents can read it.

## Step 3c: Collect and Synthesize Lens Findings

**Skip this step if `--skip-pre-scan` was set.**

Collect findings from lens agents as they complete. Then apply cross-lens synthesis to transform independent lens outputs into a prioritized finding set for the dialog.

### Collect findings

As each lens agent reports its findings JSON, verify it conforms to the Findings Output Format (has `lens`, `pr`, `repo`, `findings` fields). Build a combined list of all findings across all lenses. Track which lenses completed successfully and which failed or timed out.

Clean up the temp diff file if one was created:
```bash
rm -f /tmp/pr-self-review-<PR_NUMBER>.diff
```

### Graceful degradation

If a lens agent fails, times out, or returns malformed output:

1. **Log the failure** — record which lens failed and the error type (timeout, malformed JSON, agent crash)
2. **Proceed with partial findings** — do not block the review on a failed lens. The dialog can operate on whatever findings were collected.
3. **Note coverage gaps** — in the pre-scan summary, list degraded lenses so the user knows which analytical perspectives are missing. During the dialog (Step 4), if the user explores an area that a failed lens would have covered, note the gap and offer to apply heuristic exploration for that specific area.

Do not retry failed lens agents. Do not attempt to re-run a failed lens inline — this would slow the review and the dialog already provides a fallback.

### Identify compound findings

Group findings by `file`. Within each file, identify findings from different lenses whose `line` values are within 3 lines of each other. Two or more such findings form a compound finding.

For each compound finding, apply the severity elevation table from the Cross-Lens Synthesis section (loaded in Step 3).

Merge compound findings into a single finding with all contributing lens IDs and a merged body preserving each lens's observation.

### Deduplicate

Same file, overlapping line (within 3 lines), same severity, and same underlying concern — keep the more detailed body and add the other lens's ID to attribution. Do NOT deduplicate findings that address different concerns at the same location — those are compound findings, not duplicates.

### Pre-scan summary

Display a summary before proceeding to the dialog:

```
[pr-self-review] Lens scan complete: <N> findings (<K> blocking, <J> suggestions, <Q> questions) across <L> lenses
```

If any lenses failed, append: `(<F> lens(es) degraded: <lens names>)`

Hold the synthesized findings in memory — they drive the dialog in Step 3 and Step 4. Do not write them to a work item yet; the work item is created in Step 5 after disposition assignment.

### Persist findings for resume

Write the synthesized findings to the work item's `notes.md` under a `## Lens Scan` heading so the dialog can be resumed across sessions without re-running the lens team:

```
/work create pr-self-review-<PR_NUMBER>
/work update pr-self-review-<PR_NUMBER>
```

In `notes.md`, write:
```markdown
## Lens Scan
<timestamp> | Lenses: <list> | Findings: <count>

| # | Severity | Title | Lens | File:Line | Disposition |
|---|----------|-------|------|-----------|-------------|
| 1 | blocking | <title> | <lens> | <file:line> | — |
| 2 | suggestion | <title> | <lens> | <file:line> | — |
```

The `Disposition` column starts as `—` (undispositioned) and is updated during Step 4 as the user assigns dispositions. This table is the source of truth for resume.

## Step 3: Overview and Opening Finding

Read protocol sections for synthesis and enrichment:
```bash
cat ~/.lore/claude-md/review-protocol/cross-lens-synthesis.md
cat ~/.lore/claude-md/review-protocol/enrichment.md
cat ~/.lore/claude-md/review-protocol/checklist.md
```

Present a concise PR overview with the areas list built from lens findings:

```
## Self-Review: #<N> — <title>

**Branch:** <head> → <base>
**Scope:** <N files, brief characterization of what changed>

### Findings to discuss:
1. [blocking] <finding title> — <lens> — <file:line>
2. [blocking] <finding title> — <lens> — <file:line>
3. [suggestion] <finding title> — <lens> — <file:line>
...
```

Sort findings: blocking first (compound findings before single-lens), then suggestions, then questions. If focus context was provided in Step 1, reorder findings so that items matching the focus area appear first within each severity tier.

The findings list is a menu, not a commitment — the user can steer to any finding or raise topics not covered by the lenses.

Then **open the first finding** for discussion. Present the highest-severity finding with:
- Its Conventional Comments label (`blocking` → `issue`, `suggestion` → `suggestion`, `question` → `question`)
- The contributing lens(es) and specific file:line references
- The finding body with the lens agent's analysis
- Knowledge citations from the lens agent's enrichment (already attached as `knowledge_context`)

End with an open question to the user — invite their perspective on this finding.

### Heuristic fallback

If the pre-scan produced zero findings (all lenses returned empty), or if `--skip-pre-scan` was set, fall back to heuristic area identification: scan the diff for risk concentration (shared interfaces, state management, cross-boundary changes), complexity (largest additions, most-modified files), and architectural decisions (new abstractions, changed contracts). Generate the areas list from this heuristic scan and open the first topic using the perspective lenses:

1. **External reviewer lens:** "What would a reviewer unfamiliar with this codebase question about this change?"
2. **Weakest assumption probe:** "What are the weakest assumptions in this change?"
3. **Cross-boundary invariant trace:** "What invariants in other files does this change depend on?"

In heuristic fallback mode, enrich each observation before presenting:
```bash
lore search "<topic>" --type knowledge --json --limit 3
```

Include 1-3 compact citations inline: `[knowledge: entry-title]` with a one-line relevance note.

## Step 4: Dialog Rounds

The review proceeds as a conversation. Each round dispositions one lens finding. The dialog is confirmatory — lens agents have already done the analytical work; the dialog's unique value is the user's judgment about each finding.

### Round structure

Each round follows this sequence:

1. **Present finding** — Show the next undispositioned finding:
   ```
   [<LENS> | <severity>] <finding title>
   <file:line reference>

   <finding body from lens agent>

   <knowledge citations if present>

   Disposition: (a)ction / (ok) accepted / (d)efer / (?) open
   ```

2. **Discuss** — The user responds. They may:
   - Assign a disposition directly ("ok", "action", "defer")
   - Challenge the finding — "I think that's fine because X" → discuss and resolve
   - Ask to go deeper — "Can you trace the invariant through the calling code?"
   - Redirect to a different finding — "Skip this, let's look at #5"

3. **Record disposition** — When the user resolves the finding, record the disposition and a one-line summary of the outcome. Then advance to the next undispositioned finding.

### Dispositions

- **action** — needs a fix; will become a task in the work item (Step 5)
- **accepted** — discussed and confirmed fine as-is; the user's reasoning is the record
- **deferred** — valid concern but out of scope for this PR
- **open** — unresolved; needs more investigation before a decision

### Thread tracking

Track each dispositioned finding:
- **finding**: original finding title
- **lens**: source lens (or "compound" with contributing lenses)
- **severity**: original severity (note if elevated during synthesis)
- **disposition**: action / accepted / deferred / open
- **summary**: one-line resolution from the discussion
- **file references**: specific locations in the diff

### User-steered flow

The user drives the conversation. They can:
- **Jump to any finding** — "Let's look at finding #5"
- **Challenge a finding** — "I think that's fine because X" → discuss and resolve
- **Go deeper** — "Can you trace the invariant through the calling code?"
- **Batch-accept** — "The remaining suggestions are all fine" → mark all undispositioned suggestions as accepted
- **Raise new topics** — topics not covered by lens findings; treat as heuristic observations and disposition them the same way
- **Wrap up** — "I think we've covered enough" or "Let's land this"

When the user says to wrap up, proceed to Step 5. Findings left undispositioned at wrap-up are recorded as `open`.

### Continuing after lens findings

When all lens findings have been dispositioned, offer to continue:

```
All lens findings reviewed. Continue exploring areas not covered by lenses? (y/n)
```

If the user declines, proceed to Step 5. If the user continues, switch to heuristic exploration: scan the diff for areas not already covered by lens findings (risk concentration, complexity, architectural decisions) and open topics using the perspective lenses:

1. **External reviewer lens:** "What would a reviewer unfamiliar with this codebase question about this change?"
2. **Weakest assumption probe:** "What are the weakest assumptions in this change?"

Enrich heuristic observations before presenting:
```bash
lore search "<topic>" --type knowledge --json --limit 3
```

Disposition heuristic-round findings the same way as lens findings. When the user wraps up or no more areas remain, proceed to Step 5. This fallback is also used when degraded lenses left coverage gaps (per Step 3c graceful degradation).

### Perspective lens escalation

When the user challenges a finding, asks "why does this matter?", or requests deeper analysis, offer one of two perspective lenses as on-demand escalation within the current round:

- **perspective-external:** "Re-examine this finding as if seeing the code for the first time, with no knowledge of the author's intent beyond what the PR description states. What context did the author assume that isn't visible in the diff?"
- **perspective-assumption:** "Identify the weakest assumption behind this finding. If that assumption is wrong, does the severity change from suggestion to blocking?"

Present the perspective analysis as an additional beat in the same round — not a new finding. After the perspective analysis, re-prompt for disposition. The user may change their initial reaction based on the new angle.

Cross-boundary invariant tracing is not offered as a perspective escalation because it is already covered by the Blast Radius lens in the default set.

### Natural conversation, not protocol performance

Discuss findings like a thoughtful colleague reviewing code together. Present findings conversationally — the structured format is for tracking, not for reading aloud verbatim. The 8-point checklist from `claude-md/review-protocol/checklist.md` remains available as a reference tool during discussion but is not a sequential procedure.

## Step 5: Synthesize Work Item

After the dialog concludes, collect all dispositioned findings and create a work item:

```
/work create pr-self-review-<PR_NUMBER>
```

Write `plan.md` structured for `/implement`. Map dispositions to phases:

```markdown
# Self-Review: <PR Title>

> **Review-level analysis.** These findings came from a multi-lens pre-scan and confirmatory dialog. Investigation agents should verify assumptions against the full codebase, not accept them as validated.

## Goal
Address findings from self-review dialog before requesting external review.

## Design Decisions
<non-obvious choices surfaced during discussion, with rationale — only if any emerged>

## Phases

### Phase 1: Blocking / Correctness
**Objective:** Fix issues that affect correctness or violate cross-boundary invariants
**Files:** <affected files>
- [ ] <finding title> [<source lens(es)>] — <file:line> — <one-line action from dialog>

### Phase 2: Convention Alignment
**Objective:** Align with project conventions
**Files:** <affected files>
- [ ] <finding title> [<source lens(es)>] — <file:line> — <one-line action from dialog>

### Phase 3: Improvements
**Objective:** Address remaining suggestions from discussion
**Files:** <affected files>
- [ ] <finding title> [<source lens(es)>] — <file:line> — <one-line action from dialog>

### Phase 4: Reviewed and Confirmed
<items with `accepted` disposition — not tasks, but confirmation records>
- <finding title> [<source lens(es)>] — Confirmed fine because: <one-line user rationale from dialog>

### Deferred / Open
<items with `deferred` or `open` disposition — for reference, not action>
- <finding title> [<source lens(es)>] — Deferred: <reason> | Open: <what needs resolution>
```

### Phase mapping from dispositions

- **Phase 1 (Blocking):** disposition=`action` AND (severity=blocking OR compound finding)
- **Phase 2 (Convention alignment):** disposition=`action` AND suggestion AND convention signal (naming, formatting, pattern adherence)
- **Phase 3 (Improvements):** disposition=`action` AND remaining suggestions/questions
- **Phase 4 (Reviewed and confirmed):** disposition=`accepted` — list with one-line confirmation rationale
- **Deferred / Open:** disposition=`deferred` or `open` — for reference, not action

Omit empty phases. Include knowledge citations and source lens attribution so `/implement` workers have context.

### Verification directives for cross-boundary items

Not all action items are implement-ready. Classify each item:

- **Implement-ready:** The fix is locally scoped — contained within the file(s) in the diff, with no assumptions about code outside the diff. These go into the plan as standard implementation tasks.
- **Spec-needed:** The fix involves cross-boundary implications — depends on invariants in other modules, changes a shared interface, or makes assumptions about code not visible in the diff. These get a verification directive instead of an implementation instruction.

Blast Radius lens findings are strong candidates for `[verify]` — they identify cross-boundary impacts by design.

Format verification directives as:
```
- [ ] **[verify]** <hypothesis about what needs to change> — Verify whether <specific invariant or assumption> holds in `<file:function>` before implementing
```

The `[verify]` prefix signals to `/implement` that the item needs investigation (via `/spec`) before coding, not that it should be implemented directly.

Assess overall work item readiness:
- **implement-ready** — all action items are locally scoped
- **spec-needed** — one or more items have verification directives

Generate tasks:
```
/work tasks pr-self-review-<PR_NUMBER>
```

### No action items path

If all findings were dispositioned as `accepted` or `deferred` (zero `action` items), skip work item creation entirely. This is a success state — the review confirmed the PR is ready. Report:

```
Reviewed and confirmed: <N> findings examined, no changes needed (<K> accepted, <L> deferred)
```

Proceed directly to Step 6.

## Step 6: Present Summary

```
## Self-Review Complete

**PR:** #<number> — <title>
**Lens coverage:** <L> lenses, <N> findings (<K> blocking, <J> suggestions, <Q> questions)
**Dispositions:** <A> action, <C> accepted, <D> deferred, <O> open

### Discussion highlights:
- <key insight or decision from the dialog>
- ...

### Work item: <slug if created, or "none — reviewed and confirmed"> (<readiness: implement-ready or spec-needed>)
  Phase 1 (Blocking): <count> tasks
  Phase 2 (Convention): <count> tasks
  Phase 3 (Improvements): <count> tasks
  Phase 4 (Reviewed and confirmed): <count> items
```

If lenses ran in degraded mode, show: `**Lens coverage:** <L>/<T> lenses (<degraded lens names> degraded), <N> findings`

Omit phase counts that are zero. Omit the work item section entirely if the no-action-items path was taken.

## Step 7: Generate Followup Report

This step is mandatory and must not be skipped.

This step always runs after Step 6. It is automatic — no user confirmation required.

### 7a. Determine severity and suggested actions

Map the review outcome to followup severity and suggested actions:

| Review outcome | `--severity` | `--suggested-actions` primary type |
|---|---|---|
| Blocking findings with `action` disposition | `high` | `create_work_item` |
| `deferred` items present (no blocking) | `medium` | `create_work_item` (with defer rationale) |
| Suggestions only with `action` disposition | `medium` | `create_work_item` |
| `open` items (no `action` or `deferred`) | `medium` | `create_work_item` (with investigation directive) |
| All `accepted` / "no action items" path | `low` | `approve` |

**Base-branch-only case:** If there is no PR number (review ran against a base branch diff), omit `approve` from the suggested action types.

### 7b. Assemble the three-section report body

Assemble the `finding.md` body with the following structure:

**First line:** One-line diagnostic summary synthesized from the disposition totals (e.g., "3 action items, 2 accepted, 1 deferred — blocking findings present"). This must be the first non-heading line — it appears as the excerpt in the TUI.

**Section 1 — PR Narrative**

Derive from two sources:
- **Structural context:** the per-file alignment map and design signals from Step 3a (abbreviated thematic anchor). Summarize which modules the PR touches, how files are classified (directly supports / tangentially related / unrelated), and any design signals the lenses were given.
- **Discussion highlights:** key decisions, rationale, or insights that emerged during the Step 4 dialog. Include any points where the author's intent clarified a finding, or where discussion changed a disposition's basis.

```markdown
## PR Narrative

<1–3 sentences summarizing what the PR does structurally, drawn from the alignment map>

**Design signals:** <signals from Step 3a, or "None" if --skip-pre-scan was set>

**Discussion highlights:**
- <key insight or decision from dialog>
- <key insight or decision from dialog>
```

Omit **Discussion highlights** if the dialog produced no notable insights.

**Section 2 — Implementation Diagram**

Draw an ASCII box-drawing diagram showing the logical flow of the PR's changes: which components were added or modified, how they connect, and the direction of data or control flow.

Read diagram conventions:
```bash
cat ~/.lore/claude-md/review-protocol/followup-template.md
```

If directional relationships cannot be determined from the alignment map and design signals alone, omit the diagram.

**Section 3 — Review Findings**

List all dispositioned findings from the Step 4 dialog. Include every finding regardless of disposition — accepted findings are confirmation records, deferred/open findings are for reference.

```markdown
## Review Findings

| # | Severity | Title | Lens | File:Line | Disposition | Summary |
|---|----------|-------|------|-----------|-------------|---------|
| 1 | blocking | <title> | <lens> | <file:line> | action | <one-line outcome from dialog> |
| 2 | suggestion | <title> | <lens> | <file:line> | accepted | <one-line rationale> |
| 3 | suggestion | <title> | <lens> | <file:line> | deferred | <defer rationale> |
| 4 | question | <title> | <lens> | <file:line> | open | <what needs resolution> |
```

For `--skip-pre-scan` runs where findings came from heuristic dialog rather than lenses, set the Lens column to `heuristic`.

For compound findings (multiple lenses), list all contributing lenses separated by `+` (e.g., `blast-radius+correctness`).

### 7c. Create followup

```bash
bash ~/.lore/scripts/create-followup.sh \
  --title "Self-Review: <PR title>" \
  --source "pr-self-review" \
  --severity "<severity from 7a>" \
  --attachments '[{"type":"pr","ref":"#<N>"}]' \
  --suggested-actions '<json-array>' \
  --content "<report body from 7b>"
```

For base-branch-only runs (no PR number), omit the `--attachments` flag entirely.

The `--suggested-actions` JSON array contains one object per action type with `type` and `description` fields:

```json
[{"type": "create_work_item", "description": "<N> action items from self-review dispositions"}, ...]
```

For the "no action items" path: `[{"type": "approve", "description": "All findings accepted or deferred — PR ready for external review"}]`

For base-branch-only runs (no PR number): omit `approve` entries even if they would otherwise apply.

## Step 8: Capture Insights

```
/remember Self-review of PR #<N> (lens pre-scan + dialog) — capture: mechanism-level patterns (how the system accomplishes things structurally), structural footprint observations (component roles, integration points, what constrains changes), design rationale discovered or clarified (why the architecture is this way, what constraints drove decisions), convention drift patterns found by lenses, cross-boundary invariants identified (especially from Blast Radius), architectural concerns surfaced during disposition dialog. Use confidence: medium (self-review blindness is structural — lens agents mitigate but don't eliminate confirmation bias in disposition decisions). Skip: obvious fixes, style issues, findings specific to this PR that don't generalize, findings dispositioned as accepted without novel reasoning.
```

This step is automatic — do not ask whether to run it.

## Resuming

If re-invoked on the same PR, check for an existing work item (`pr-self-review-<PR_NUMBER>` in `/work list`). If found:

1. **Load lens scan findings** — read the `## Lens Scan` section from `notes.md`. Parse the findings table to identify which findings have been dispositioned and which are still `—` (undispositioned).
2. **Skip the lens team** — do not re-run Steps 2.5–3c. The lens scan findings are already persisted. Display: `[pr-self-review] Resuming: <N> undispositioned findings from previous scan`
3. **Resume dialog** — skip to Step 3 and present the findings list with dispositioned items marked. Begin the dialog from the first undispositioned finding.
4. **If no lens scan section** — the previous session may have run without the lens team (e.g., `--skip-pre-scan`) or predates the redesign. Offer: re-run the lens team, or continue with heuristic dialog.
5. **If `plan.md` already exists** — a previous dialog already completed. Load the plan to see which action items were created, then check for new undispositioned findings or offer to extend the review.

Append new findings to existing phases rather than creating a duplicate work item.

## Error Handling

- **No gh CLI or authentication:** Tell user to run `gh auth login`
- **PR not found:** Confirm PR number and repo access
- **Empty PR (no changes):** Inform user, skip review
- **Knowledge store unavailable:** Continue review without enrichment, note degraded mode
