---
name: pr-self-review
description: "Reflective turn-based review of your own PR — explore aspects in dialog, land findings in a work item"
user_invocable: true
argument_description: "[PR_number_or_URL] [focus context] — PR to self-review (or auto-detect from branch). Optional focus context steers which areas to prioritize (e.g., '42 focus on the error handling in the new scripts')"
---

# /pr-self-review Skill

Reflective review of work you just completed on a PR. This is a turn-based dialog — you and the user explore the PR together, discussing aspects one at a time rather than producing a batch report. Self-review blindness is structural when reviewing agent-generated code, so the dialog format forces genuine re-examination rather than rubber-stamping.

Since this is your own work, the review can end with an implement-ready work item. This distinguishes it from `/pr-review` (reviewing someone else's code) and `/pr-revise` (addressing existing external feedback).

This skill does not modify source code.

## Step 1: Identify PR and Focus Context

Argument provided: `$ARGUMENTS`

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

## Step 3: Overview and Opening Observation

Read the review protocol reference:
```bash
cat claude-md/70-review-protocol.md
```

Present a concise PR overview:

```
## Self-Review: #<N> — <title>

**Branch:** <head> → <base>
**Scope:** <N files, brief characterization of what changed>

### Areas to explore:
- <area 1>: <one-line description of what's interesting or risky here>
- <area 2>: ...
- <area 3>: ...
```

The areas list is a menu, not a commitment — the user can steer elsewhere. Identify areas by scanning the diff for: risk concentration (shared interfaces, state management, cross-boundary changes), complexity (largest additions, most-modified files), and architectural decisions (new abstractions, changed contracts).

Then **open the first topic**. Pick the highest-priority area (architecture tier first per the review hierarchy) and present a focused observation about it. This is Beat 1 of the first dialog round.

### How to open a topic

Apply one of the three perspective lenses to generate the observation:

1. **External reviewer lens:** "What would a reviewer unfamiliar with this codebase question about this change?"
2. **Weakest assumption probe:** "What are the weakest assumptions in this change?"
3. **Cross-boundary invariant trace:** "What invariants in other files does this change depend on?"

Choose the lens most relevant to the area. Present the observation with:
- A Conventional Comments label (`suggestion`, `issue`, `question`, `thought`, `nitpick`, `praise`)
- Specific file:line references
- The perspective lens used (so the user knows the angle)

Then **enrich immediately** — query the knowledge store before presenting:
```bash
lore search "<topic>" --type knowledge --json --limit 3
```

Include 1-3 compact citations inline: `[knowledge: entry-title]` with a one-line relevance note. If a knowledge entry is STALE and the PR contradicts it, flag as "convention may need updating." Skip enrichment for nitpick/praise labels.

**Investigation escalation:** If knowledge results are insufficient AND the concern involves cross-boundary invariants or multi-file analysis, spawn an Explore agent per the Investigation Escalation procedure in `claude-md/70-review-protocol.md`. Maximum 2 escalations across the entire review.

End with an open question to the user — invite their perspective on this area.

## Step 4: Dialog Rounds

The review proceeds as a conversation. Each round explores one topic.

### Round structure

1. **Discuss** — The user responds to the current observation. They may agree, disagree, add context, ask to go deeper, or redirect to a different area.

2. **Resolve or continue** — Based on the user's response:
   - If the topic resolves, record the resolution and its disposition (see below)
   - If the user wants to go deeper, apply another perspective lens or drill into specifics
   - If the user redirects, close the current topic and open the new one

3. **Open next topic** — When the current topic resolves, offer the next area from the list (or a new observation that emerged during discussion). Apply a different perspective lens than the previous round when possible.

### Thread tracking

Track each discussed topic:
- **topic**: what was discussed
- **label**: Conventional Comments label
- **disposition**: `action` (needs a fix), `accepted` (fine as-is after discussion), `deferred` (valid but out of scope), `open` (unresolved)
- **summary**: one-line resolution from the discussion
- **file references**: specific locations in the diff

### User-steered flow

The user drives the conversation. They can:
- **Ask to explore a specific area** — "What about the error handling in fetch-pr-data.sh?"
- **Challenge an observation** — "I think that's fine because X" → discuss and resolve
- **Go deeper** — "Can you trace the invariant through the calling code?"
- **Skip** — "That's fine, what else?"
- **Wrap up** — "I think we've covered enough" or "Let's land this"

When the user says to wrap up, or when all identified areas have been discussed, proceed to Step 5.

### Applying the 8-point checklist

The checklist from `claude-md/70-review-protocol.md` is a tool to draw from during dialog, not a sequential procedure. When exploring an area, reference specific checklist items that apply — e.g., "This touches checklist item #2 (cross-boundary invariant trace)..." — rather than walking through all 8 items mechanically.

### Natural conversation, not protocol performance

Discuss findings like a thoughtful colleague reviewing code together. The perspective prompts and checklist items are thinking tools — use them to generate genuine observations, but present those observations naturally. Don't announce "applying external reviewer lens" as a protocol step.

## Step 5: Synthesize Work Item

After the dialog concludes, collect all topics with `action` disposition and create a work item:

```
/work create pr-self-review-<PR_NUMBER>
```

Write `plan.md` structured for `/implement`:

```markdown
# Self-Review: <PR Title>

## Goal
Address findings from self-review dialog before requesting external review.

## Design Decisions
<non-obvious choices surfaced during discussion, with rationale — only if any emerged>

## Phases

### Phase 1: Blocking / Correctness
**Objective:** Fix issues that affect correctness or violate cross-boundary invariants
**Files:** <affected files>
- [ ] <finding with file:line reference and knowledge citation>

### Phase 2: Convention Alignment
**Objective:** Align with project conventions
**Files:** <affected files>
- [ ] <finding with file:line reference and knowledge citation>

### Phase 3: Improvements
**Objective:** Address remaining suggestions from discussion
**Files:** <affected files>
- [ ] <finding with file:line reference and knowledge citation>
```

Omit empty phases. Include knowledge citations so `/implement` workers have context.

Generate tasks:
```
/work tasks pr-self-review-<PR_NUMBER>
```

**If no action items emerged** (all topics resolved as `accepted` or `deferred`), skip the work item and note that the review found no changes needed.

## Step 6: Present Summary

```
## Self-Review Complete

**PR:** #<number> — <title>
**Topics explored:** N
**Dispositions:** K action, J accepted, L deferred, M open

### Discussion highlights:
- <key insight or decision from the dialog>
- ...

### Work item: <slug if created, or "none — no action items">
```

## Step 7: Capture Insights

```
/remember Self-review dialog on PR #<N> — capture: convention drift patterns found, cross-boundary invariants identified, architectural concerns surfaced during discussion, design rationale clarified through dialog. Use confidence: medium (self-review blindness is structural). Skip: obvious fixes, style issues, findings specific to this PR that don't generalize, discussion points that resolved as accepted.
```

This step is automatic — do not ask whether to run it.

## Resuming

If re-invoked on the same PR, check for an existing work item (`pr-self-review-<PR_NUMBER>` in `/work list`). If found, load it and continue from where the previous dialog left off — review which areas were already discussed and pick up with unexplored ones.

## Error Handling

- **No gh CLI or authentication:** Tell user to run `gh auth login`
- **PR not found:** Confirm PR number and repo access
- **Empty PR (no changes):** Inform user, skip review
- **Knowledge store unavailable:** Continue review without enrichment, note degraded mode
