---
name: evolve
description: "Review and apply accumulated protocol evolution suggestions from retro and self-test"
user_invocable: true
argument_description: "[--since <date>]"
---

# /evolve Skill

Review evolution suggestions accumulated in the journal from `/retro` and `/self-test` runs. Present them grouped by target for human approval, apply approved suggestions as file edits, and record the outcome.

## Step 1: Resolve Knowledge Directory

```bash
lore resolve
```

Set `KNOWLEDGE_DIR` to the result.

## Step 2: Find the Last /evolve Run

Determine the cutoff date for suggestions to review. Only suggestions logged *after* the last `/evolve` run are shown — earlier suggestions have already been reviewed.

```bash
lore journal show --role evolve --limit 1
```

If an entry exists, extract its timestamp. Set `SINCE` to that timestamp.

If no `evolve` entry exists, set `SINCE` to the beginning of time (no cutoff — show all accumulated suggestions).

If the user passed `--since <date>`, override `SINCE` with that value.

Report:
```
[evolve] Checking for suggestions since: <SINCE or "all time">
```

## Step 3: Load Pending Suggestions

Read all staged evolution suggestions:

```bash
lore journal show --role retro-evolution --since "$SINCE"
lore journal show --role self-test-evolution --since "$SINCE"
```

Collect all entries returned by both commands. Each entry has the structured format:

```
Target: <file> | Change type: <type> | Section: <section> | Suggestion: <text> | Evidence: <retro finding>
```

If both commands return zero entries, report:
```
[evolve] No pending suggestions. Run /retro or /self-test to generate suggestions.
```
And stop.

Report the count:
```
[evolve] Found N suggestions (M from retro, K from self-test)
```

## Step 4: Parse and Group Suggestions

Parse each observation string using the structured fields:
- **Target** — the file to edit (e.g., `skills/retro/SKILL.md`, `skills/retro/failure-modes.md`, `skills/self-test/SKILL.md`)
- **Change type** — the category of change (e.g., `ceiling-raise`, `new-failure-mode`, `dead-dimension`, `scoring-criteria`, `new-test-dimension`)
- **Section** — the section or step being modified
- **Suggestion** — the proposed change in plain text
- **Evidence** — the retro or self-test finding that motivated this suggestion

Group suggestions by **Target**, then by **Change type** within each target.

Also extract metadata from the journal entry itself: timestamp, work-item (if any), source role.

## Step 5: Present for Review

For each target file, present all pending suggestions grouped by change type. One at a time, ask the user to approve or reject each suggestion.

Present each suggestion in this format:

```
─────────────────────────────────────────────
Target:      <file>
Change type: <type>
Section:     <section>
From:        <timestamp> (<source role>)
Evidence:    <evidence text>

Suggestion:
  <suggestion text>
─────────────────────────────────────────────
Apply this suggestion? [y/n/skip/quit]
```

- **y** — approved, will apply
- **n** — rejected, will record as rejected
- **skip** — deferred, not recorded (will appear in next `/evolve` run)
- **quit** — stop reviewing; apply what's been approved so far

Track: `approved = []`, `rejected = []`, `skipped = []`.

If the user approves multiple suggestions for the same section of the same file, note that they may conflict — present a brief warning before applying.

## Step 6: Apply Approved Suggestions

For each approved suggestion, apply the change as a direct file edit.

**Application order:** Process suggestions targeting the same file sequentially (not in parallel) to avoid conflicts.

**Per suggestion:**
1. Read the current content of the target file
2. Locate the section identified by the suggestion's **Section** field
3. Apply the change described in the **Suggestion** field
4. Confirm the edit was applied cleanly

If a suggestion cannot be applied cleanly (e.g., the target section no longer exists, conflicting prior edit in this session), report:
```
[evolve] Could not apply: <suggestion summary> — <reason>. Recording as skipped.
```
Move it to `skipped`.

## Step 7: Write Outcome Journal Entry

After all approved suggestions have been applied (or if the user quit early), write a summary entry to the journal:

```bash
lore journal write \
  --observation "Evolve run: N suggestions reviewed. Applied: <count> | Rejected: <count> | Skipped: <count>. Applied to: <comma-separated target files>. Summary: <1-2 sentences on what changed and why>." \
  --context "evolve" \
  --role "evolve"
```

This entry establishes the cutoff for the next `/evolve` run.

If zero suggestions were approved, still write the entry — it records that the review happened and advances the cutoff.

## Step 8: Report

```
[evolve] Done
  Reviewed: N suggestions
  Applied:  N (to: <files>)
  Rejected: N
  Skipped:  N (will appear in next run)
```

If suggestions were applied, list each change briefly:
```
  Changes:
    - skills/retro/SKILL.md: <one-line summary>
    - skills/retro/failure-modes.md: <one-line summary>
    ...
```
