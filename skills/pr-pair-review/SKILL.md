---
name: pr-pair-review
description: "Interactive pair-review with knowledge-enriched turn protocol"
user_invocable: true
argument_description: "[PR_number_or_URL] [focus context] — PR to review (or auto-detect from branch). Optional focus context steers which areas to prioritize (e.g., '42 concentrate on the new turn protocol logic')"
---

# /pr-pair-review Skill

Interactive pair-review skill for GitHub PRs. Uses a structured 3-beat turn protocol (raise, enrich, respond) with mandatory knowledge enrichment. Analysis-only — produces a work item with findings and action items but does not modify source code.

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

Parse the JSON output. Identify:
- Unresolved review threads (actionable)
- Review bodies with state (CHANGES_REQUESTED, APPROVED, COMMENTED)
- General PR comments
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

## Step 4: Review rounds — 3-beat protocol

Read the review protocol reference for the checklist and enrichment rules:
```bash
cat claude-md/70-review-protocol.md
```

Apply the 8-point review checklist from the protocol to each changed file or logical unit. Review follows the hierarchy: architecture first, then logic/correctness, then maintainability.

**Scoping for large diffs:** For PRs touching more than ~10 files, prioritize analysis by: (1) files in identified risk areas from Step 3, (2) files with the most additions (new logic over modified logic), (3) files touching shared interfaces or public APIs. Apply the full checklist to priority files; do a lighter pass on the rest.

### Turn protocol

Each review topic proceeds through 3 beats:

**Beat 1 — Raise:** Either party (user or agent) raises a topic. The agent infers a Conventional Comments label:
- `suggestion` — proposes a specific change
- `issue` — identifies a problem that needs fixing
- `question` — asks for clarification or rationale
- `thought` — shares an observation or consideration
- `nitpick` — minor style or preference point
- `praise` — positive acknowledgment

**Beat 2 — Enrich (MANDATORY):** Before the responding party replies, the agent enriches the topic with knowledge store context. This is a protocol step, not a suggestion — skipping it degrades review quality.

For findings with substantive labels (suggestion, issue, question, thought):

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

**Beat 3 — Respond + Resolve:** The responding party replies, informed by the enrichment context. The thread resolves as one of:
- `agreed` — both parties align, action item created
- `action` — specific change identified and scoped
- `deferred` — valid concern but out of scope for this PR
- `open` — unresolved, needs further discussion or escalation

### Round limits

- Default 2 rounds per thread, extendable to 3 on request
- Hard cap at 3 rounds — if unresolved after 3, mark as escalation candidate (becomes an "open" thread → Phase 3: Unresolved in the work item)
- Each round focuses on one level of the review hierarchy

### Thread state tracking

Track each thread as:
```
{id, topic, status, label, blocking?, initiator, knowledge_checked, round_count, linked_task}
```

Where:
- `blocking?` — true if the finding would block merge
- `initiator` — "agent" or "reviewer" (who raised the topic in Beat 1)
- `knowledge_checked` — true after Beat 2 enrichment completes
- `linked_task` — reference to generated task (set in Step 5)

## Step 5: Synthesize into work item

After all review threads conclude, collect findings and create a work item:

```
/work create pr-pair-review-<PR_NUMBER>
```

Write `plan.md` with this structure:

```markdown
# PR Pair-Review: #<N> — <title>

## Goal
<What needs to change and why, derived from review dialogue>

## Design Decisions
<Rationale surfaced during discussion>

**Applies to:** <file or subsystem each decision affects>

## Phases

### Phase 1: Agreed Changes
**Objective:** Implementation-ready items from resolved threads
- [ ] <actionable item from agreed/action threads> — <file:line>
- [ ] ...

### Phase 2: Follow-up Investigations
**Objective:** Items that need `/spec` before implementation
- [ ] <item from threads requiring deeper analysis>
- [ ] ...

### Phase 3: Unresolved
**Objective:** Escalation candidates from open threads
- [ ] <unresolved item> — context: <why it couldn't be resolved>
- [ ] ...
```

Omit empty phases. Generate tasks:
```
/work tasks pr-pair-review-<PR_NUMBER>
```

Assess readiness:
- **implement-ready** — if dialogue resolved sufficient detail for all Phase 1 items
- **spec-ready** — if scope exceeds review coverage or Phase 2 has substantial items

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

If re-invoked on the same PR, check for an existing work item (e.g., `pr-pair-review-<PR_NUMBER>` in `/work list`). If found, load it and continue the review from where it left off — add new threads to the existing plan rather than creating a duplicate.

## Error Handling

- **No gh CLI or authentication:** Tell user to run `gh auth login`
- **PR not found:** Confirm PR number and repo access
- **Empty PR (no changes):** Inform user, skip review
- **No review threads from other party:** Proceed with agent-initiated review using checklist
- **Knowledge store unavailable:** Continue review without enrichment, note degraded mode in summary
