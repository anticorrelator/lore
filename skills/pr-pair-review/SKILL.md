---
name: pr-pair-review
description: "Interactive pair-review with knowledge-enriched turn protocol"
user_invocable: true
argument_description: "[PR_number_or_URL] [focus context] — PR to review (or auto-detect from branch). Optional focus context steers which areas to prioritize (e.g., '42 concentrate on the new turn protocol logic')"
---

# /pr-pair-review Skill

Interactive pair-review skill for GitHub PRs. Reviewer comments drive the agenda through a 3-beat turn protocol (present, enrich, discuss) with mandatory knowledge enrichment. Analysis-only — produces a work item with findings and action items but does not modify source code.

## Step 1: Identify PR and Focus Context

Argument provided: `$ARGUMENTS`

**Parse arguments:** The first token that looks like a PR number (digits) or GitHub URL is the PR identifier. Everything else is **focus context** — free-text guidance about which areas to concentrate on during the review.

Examples:
- `42` → PR #42, no focus context
- `42 focus on the new turn protocol logic` → PR #42, focus on turn protocol
- `concentrate on the knowledge enrichment pipeline` → no PR (auto-detect), focus context provided

**If no PR identifier:** Detect from current branch:
```bash
gh pr list --state open --head "$(git branch --show-current)" --json number,baseRefName --jq '.[] | "#\(.number) → \(.baseRefName)"' 2>/dev/null
```

**If multiple PRs found:** Present the list with base branches and ask the user which one to review.

**If no PRs found:** Ask the user for the PR number. If they provide a base branch instead, search by base: `gh pr list --state open --base <branch> --head "$(git branch --show-current)" ...`

**Carry focus context forward** — it influences risk area identification in Step 3 (focused areas are listed first and marked as priority) and topic selection in Step 4 (the first review round should address the focused area).

## Step 2: Fetch PR data

Fetch all PR data using the shared script:
```bash
bash ~/.lore/scripts/fetch-pr-data.sh <PR_NUMBER>
```

Also gather the diff and file scope:
```bash
gh pr diff <PR_NUMBER>
gh pr view <PR_NUMBER> --json files --jq '.files[].path'
```

Parse the grouped JSON output. The script returns `grouped_reviews` (reviews with inline comments attached), `unmatched_threads` (review threads not matched to any review), and `orphan_comments` (general PR comments).

**Review Selection:** Follow the Review Selection protocol defined in `claude-md/70-review-protocol.md`. Present fetched reviews as batches grouped by reviewer and let the user select which batch to work through. Only process comments from the selected batch — other batches are deferred to subsequent invocations.

If the PR has only one reviewer with feedback, skip the selection prompt and proceed with that batch automatically.

**Filter the selected batch:**
- Outdated threads (`isOutdated: true`) — filter out unless the concern clearly still applies to the current diff. Threads on subsequently-changed code are likely addressed by later commits; do not treat as needing action.
- Resolved threads — skip unless explicitly referenced by an unresolved thread

## Step 3: Generate structured PR summary

Before review begins, produce a shared-context summary for both parties:

```
## PR Summary: #<N> — <title>

**Intent:** <one-sentence description of what this PR accomplishes>
**Scope:** <files changed, lines added/removed, subsystems touched>
**Risk areas:**
- <area>: <why it's risky — e.g., touches shared state, modifies public API, changes invariant>
**File change summary:**
- <file>: <brief description of change>
```

Present this summary and proceed to review rounds.

## Step 4: Review rounds — reviewer comments drive the agenda

Read the review protocol reference for the enrichment and escalation rules:
```bash
cat claude-md/70-review-protocol.md
```

The reviewer's comments from the selected batch are the discussion agenda. Present them one at a time. The agent facilitates — it does not generate its own review topics. The 8-point checklist (from the protocol) is available as a secondary tool after reviewer comments are exhausted (see optional checklist pass below), not as the primary topic source.

### Comment ordering

Process reviewer comments in this order:
1. Comments on files in risk areas identified in Step 3
2. Comments on focus-context areas (if focus context was provided in Step 1)
3. Remaining comments, ordered by file path (group related comments on the same file)

### Conversation input

The default interaction mode is alternating messages — agent and user take turns. No explicit mode switching is needed.

When the user pastes a transcript (e.g., a Slack thread, meeting notes, or prior review discussion), detect it by indicators such as multiple speaker names, `Name: ...` prefixes, quoted blocks with attribution, or contextual speaker changes. Parse the transcript to identify speakers and attribute statements correctly, then process each distinct point through the turn protocol as if raised by the appropriate party.

If attribution is ambiguous, ask the user to clarify rather than guessing.

### Turn protocol

Each reviewer comment proceeds through 3 beats:

**Beat 1 — Present:** The agent presents the reviewer's comment with context:
- File path and line range from the review thread
- The relevant diff snippet (3-5 lines of surrounding context)
- The reviewer's comment text
- The agent infers a Conventional Comments label for the comment:
  - `suggestion` — proposes a specific change
  - `issue` — identifies a problem that needs fixing
  - `question` — asks for clarification or rationale
  - `thought` — shares an observation or consideration
  - `nitpick` — minor style or preference point
  - `praise` — positive acknowledgment

**Beat 2 — Enrich (MANDATORY):** Before the user responds, the agent enriches the comment with knowledge store context. This is a protocol step, not a suggestion — skipping it degrades review quality.

For comments with substantive labels (suggestion, issue, question, thought):

1. Query the knowledge store:
   ```bash
   lore search "<topic>" --type knowledge --json --limit 3
   ```
2. Surface 1-3 compact citations inline: `[knowledge: entry-title]` with a one-line summary of relevance.
3. If a knowledge entry is STALE and the PR contradicts it, flag as "convention may need updating" — not "PR is wrong."

**Conditional investigation escalation:** If knowledge results are insufficient AND the concern involves cross-boundary invariants or architectural patterns spanning multiple files, spawn an Explore agent:
```
Task: Investigate whether [specific concern] holds.
Scope: [files/directories to examine]
Question: [precise question to answer]
Report: Return structured observations — confirmed/refuted/uncertain with evidence.
```
Maximum 2 investigation escalations per review. Prioritize by tier (architecture > logic > maintainability).

For nitpick/praise labels: skip enrichment, proceed directly to Beat 3.

**Beat 3 — Discuss + Resolve:** The user responds, informed by the enrichment context. Discussion continues until the thread resolves as one of:
- `agreed` — both parties align, action item created
- `action` — specific change identified and scoped
- `deferred` — valid concern but out of scope for this PR
- `open` — unresolved, needs further discussion or escalation

### Progress tracking

At the start of each review topic, show progress through the selected batch:

```
[Point N of M from @<reviewer>'s review]
Topic: <brief description of the reviewer's comment>
File: <file path> (line <N>)
```

After resolving a topic (Beat 3 completes), show remaining topics:

```
Resolved: <resolution>. Remaining: <topic-2>, <topic-3>, ...
```

If the remaining list exceeds 5 items, show the next 3 and summarize: `...and N more`.

This gives both parties visibility into where they are in the review and what's coming next. Progress tracking continues through any agent-initiated checklist review topics if the user accepts that pass.

### Round limits

- Default 2 rounds per thread, extendable to 3 on request
- Hard cap at 3 rounds — if unresolved after 3, mark as escalation candidate (becomes an "open" thread → Phase 3: Unresolved in the work item)

### Thread state tracking

Track each thread as:
```
{id, topic, status, label, blocking?, knowledge_checked, round_count, linked_task}
```

Where:
- `blocking?` — true if the finding would block merge
- `knowledge_checked` — true after Beat 2 enrichment completes
- `linked_task` — reference to generated task (set in Step 5)

### Checklist review offer

After all reviewer comments have been discussed (all threads from the selected batch are resolved, deferred, or open), offer an optional agent-initiated checklist pass before proceeding to wrap-up:

```
All of @<reviewer>'s points discussed (<resolved> resolved, <deferred> deferred, <open> open).

Want me to do an additional pass using the 8-point review checklist? This checks for issues the reviewer may not have covered — semantic contract violations, cross-boundary invariants, proportionality, etc.
```

- **If the user accepts:** Apply the full 8-point checklist from `claude-md/70-review-protocol.md` to each changed file or logical unit, following the same 3-beat turn protocol (raise, enrich, respond) for any new findings. Findings from the checklist pass are tracked as agent-initiated threads (`initiator: "agent"`). Do not re-raise topics already covered in the reviewer's batch.
- **If the user declines:** Proceed directly to the wrap-up gate.

This offer is a single prompt — do not ask repeatedly or push back on a decline.

### Wrap-up gate

**Do not proceed to Step 5 (work item creation) until the user explicitly says to wrap up.** This is a hard gate — the agent never initiates wrap-up on its own.

After all review points are discussed (including any checklist review findings if the user accepted), present a summary and ask:

```
All <N> review points discussed. <resolved> resolved, <open> still open, <deferred> deferred.
Ready to wrap up and create the work item, or want to continue discussing?
```

- If the user wants to continue, stay in Step 4 — they may raise new topics or revisit resolved ones.
- If the user explicitly says to wrap up (e.g., "wrap up", "let's create the work item", "done"), proceed to Step 5.
- If the user hasn't addressed all points yet and says to wrap up, confirm: "There are still <N> undiscussed points. Wrap up anyway, or continue?"

## Step 5: Synthesize into work item

**Gate:** Only enter this step after the user explicitly triggered wrap-up in Step 4. If this step is reached without user confirmation, return to Step 4 and ask.

Collect findings and create a work item:

```
/work create pr-pair-review-<PR_NUMBER>
```

Write `notes.md` with this structure:

```markdown
# PR Pair-Review: #<N> — <title>

> **Review-level analysis.** These findings came from a code review (diff-level analysis). Investigation agents should verify assumptions against the full codebase, not accept them as validated.

## Discussion Summary
Per-point summaries of what was discussed, keyed by file and line:
- **<file>:<line>** — <reviewer's concern>. Resolution: <agreed/action/deferred/open>. <brief rationale>
- ...

## Agreed Changes
Trivially obvious fixes only — typos, naming corrections, clearly wrong values. These are safe to implement without further investigation.
- [ ] <fix description> — <file:line>
- ...

## Verification Needed
Reviewer claims or concerns that require `/spec` investigation before action. Each item includes an explicit verification directive.
- [ ] Verify whether <claim X> holds in `<file>:<function>` — <reviewer's concern and context>
- [ ] Verify whether <pattern Y> is consistent across `<subsystem>` — <what to check and why>
- ...

## Deferred
Valid concerns explicitly marked out of scope for this PR.
- <concern> — <why deferred, what would trigger revisiting>
- ...
```

Omit empty sections. Generate tasks:
```
/work tasks pr-pair-review-<PR_NUMBER>
```

Assess readiness:
- **spec-needed** (default) — if any items exist in "Verification Needed"
- **implement-ready** — only if "Verification Needed" is empty and all items are trivially obvious "Agreed Changes"

## Step 6: Present summary

```
## Pair-Review Summary: PR #<N>

**Threads:** <total> (<resolved>, <open>, <deferred>)
**Blocking findings:** <count>
**Knowledge enrichments:** <count> queries, <count> citations surfaced
**Investigation escalations:** <count>
**Work item:** <slug> (<readiness level>)

### Resolution breakdown:
- Agreed: <count>
- Action: <count>
- Deferred: <count>
- Open: <count>

### Tasks created: <count>
1. <task subject> — <file>
2. ...
```

## Step 7: Capture insights

```
/remember Pair-review findings from PR #<N> — capture: architectural insights surfaced during discussion, corrected misconceptions about codebase, cross-boundary invariants identified, convention violations found via knowledge enrichment. Skip: style preferences, subjective opinions, one-off discussion points, anything already captured in the work item plan. Confidence: medium for external reviewer insights (not yet verified against codebase internals).
```

This step is automatic — do not ask whether to run it.

## Resuming

If re-invoked on the same PR, check for an existing work item (e.g., `pr-pair-review-<PR_NUMBER>` in `/work list`). If found, load `notes.md` and continue the review from where it left off — append new discussion points to the Discussion Summary, new fixes to Agreed Changes, and new directives to Verification Needed rather than creating a duplicate work item.

## Error Handling

- **No gh CLI or authentication:** Tell user to run `gh auth login`
- **PR not found:** Confirm PR number and repo access
- **Empty PR (no changes):** Inform user, skip review
- **No review threads from other party:** Proceed with agent-initiated review using checklist
- **Knowledge store unavailable:** Continue review without enrichment, note degraded mode in summary
