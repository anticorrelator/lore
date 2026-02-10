---
name: remember
description: Capture insights to knowledge store and update conversational threads — invoke anytime to ensure nothing is lost
user_invocable: true
argument_description: "[optional: focus area or capture constraints]"
---

# /remember Skill

Pause and review the current session for uncaptured knowledge and unupdated threads. Combines knowledge capture with thread updates.

## Resolve Paths

```bash
lore resolve
```

Set `KNOWLEDGE_DIR` to the result. Set `THREADS_DIR` to `$KNOWLEDGE_DIR/_threads`.

## Step 0: Parse capture constraints

If an argument was provided, interpret it as **capture constraints** that adjust the 4-condition gate for this invocation. Constraints narrow what gets captured — they never expand it (the base gate always applies).

The argument can be:
- **A focus area** (e.g., "auth changes") — limits the scan to that topic
- **A capture filter** (e.g., "skip style preferences, capture architecture decisions") — tightens the gate criteria
- **Both** (e.g., "PR review feedback — capture architectural insights and gotchas, skip style nits and formatting preferences")

When called from another skill, the argument typically provides context about what kind of work just happened and what's worth persisting vs what's ephemeral. Apply these constraints throughout Steps 1-4.

**Examples of how constraints tighten the gate:**

| Calling context | Capture | Skip |
|----------------|---------|------|
| PR review | Architectural feedback, corrected misconceptions, non-obvious patterns the reviewer spotted | Style preferences, formatting nits, subjective code taste, naming bikeshedding |
| Debugging session | Root causes, misleading error messages, environment-specific gotchas | Dead-end hypotheses, one-off typos, transient state |
| Dependency upgrade | Breaking changes, migration patterns, compatibility gotchas | Version numbers, changelog summaries, routine deprecation warnings |
| Refactoring | Discovered coupling, extraction patterns, invariants that weren't obvious | Mechanical renames, import reordering, formatting changes |

The key question for each candidate: **would a future session benefit from knowing this, or is it noise?** Constraints from the caller help answer this by providing domain-specific signal about what's ephemeral.

## Step 1: Scan for uncaptured insights

Review the full conversation context (filtered by any Step 0 constraints) and identify moments that match capture triggers:

- A design decision was made with non-obvious rationale
- Something was discovered to work differently than expected
- A debugging session revealed a non-obvious root cause
- A pattern was found that repeats across the codebase
- A gotcha or pitfall was encountered
- The user corrected a misconception or shared domain knowledge
- A workaround was used (and the reason why matters)

For each candidate, assess against the 4-condition gate:
1. Reusable (beyond this task)?
2. Non-obvious (not in existing docs)?
3. Stable (won't change soon)?
4. High confidence (verified)?

If capture constraints were provided in Step 0, apply them as an additional filter: candidates that pass the base gate but fall into the "skip" category for the current context are dropped silently.

## Step 2: Scan for thread updates

Review the conversation for thread-worthy content:

1. Read the thread index at `$THREADS_DIR/_index.json`
2. For each existing thread, check if this session discussed the topic
3. If so, write a new entry file at `$THREADS_DIR/<slug>/<date>.md` (e.g., `how-we-work/2026-02-08.md`). If a file for today already exists, disambiguate with session suffix: `2026-02-08-s2.md`. Entry files do NOT contain the `## ` heading — it is reconstructed from the filename at load time. Entry content starts with `**Summary:**`:
   ```markdown
   **Summary:** One-sentence overview of what was discussed
   **Key points:**
   - Specific decisions, shifts, or ideas
   **Shifts:** Change from previous entries (optional)
   **Related:** [[work:name]], [[knowledge:file#heading]]
   ```
4. Check for new topics that don't match existing threads and had >2 substantive exchanges — these become new thread candidates. Create the directory `$THREADS_DIR/<slug>/` with a `_meta.json` file:
   ```json
   {
     "slug": "<slug>",
     "topic": "<topic description>",
     "tier": "active",
     "created": "<ISO timestamp>",
     "updated": "<ISO timestamp>",
     "sessions": 1
   }
   ```
   Then write the first entry file as in step 3. Update `$THREADS_DIR/_index.json` to include the new thread.

## Step 3: Check plan status

- Is there an active plan for the current work? Check `_work/` for branch match or recent activity.
- If no plan exists, check auto-trigger conditions:
  - Design discussion (choosing between approaches, trade-offs)?
  - Multi-step implementation (>2-3 files)?
  - Ambiguous scope (goal stated but path unclear)?
  - System/meta changes (tooling, config, process)?
  - Cross-session work (won't finish this conversation)?
- If a plan exists, does it need a session notes update?

## Step 4: Act

**Default behavior: auto-capture.** Everything that passes the gate gets captured immediately. The gate is the quality filter — no additional confirmation needed.

- Capture all insights that pass the gate — `lore capture` files directly to the correct category file:
  ```bash
  lore capture --insight "..." --context "..." --category "..." --confidence "..." --related-files "..."
  ```
  **Always populate `--related-files`** with concrete file paths the insight describes or depends on (e.g., `scripts/pk_search.py`, `skills/remember/SKILL.md`). This is the strongest staleness signal — when those files change, the entry gets flagged for review. Scan the conversation context for which files were involved. Err on the side of including files: a false positive (file changed but entry still valid) is cheap to dismiss; a missing reference means silent drift.
- Write all thread updates (new entry files to `_threads/<slug>/<date>.md`, update `_meta.json`)
- Create new threads if warranted (create directory, `_meta.json`, first entry file, update `_index.json`)
- Update plans as needed

### Post-capture conflict check

After all captures are filed, check each new entry for conflicts with existing entries:

1. For each entry just captured, search the same category with FTS5:
   ```bash
   lore search "<key terms from entry title>" --type knowledge --limit 5
   ```
2. For each match with an **older `learned` date** than the new entry, compare content. Look for:
   - **Direct contradiction** — the older entry says X, the new entry says not-X (or the code now does Y)
   - **Supersession** — the new entry covers the same ground with updated information
   - **Overlap** — substantially the same insight, different wording
3. **Act on conflicts:**
   - **Contradiction/supersession:** Update the older entry to reflect current reality, or drop it if the new entry fully replaces it. Briefly note: `[conflict] Updated "old title" — superseded by "new title"`
   - **Overlap:** Merge into the better-written entry, drop the other. Note: `[conflict] Merged "entry A" into "entry B"`
   - **No conflict:** Move on silently
4. When updating an older entry, also refresh its `related-files` metadata and `learned` date

**Exception: external feedback.** If an insight originates from external sources (PR review comments, code review suggestions, issue discussions, pair programming input), prompt the user before capturing — unless capture constraints from Step 0 already specify how to handle external input. External opinions may not align with the user's own mental models.

```
[external] PR reviewer suggested "use dependency injection for testability"
  → Capture to knowledge? [Their rationale: ...]
```

## Step 5: Report summary

After capturing, print a concise summary:

```
[remember] Done.
  [knowledge] Captured N entries: "insight 1", "insight 2"
  [thread: topic] Updated with today's discussion
  [thread: new] Created "topic-name"
  [plan: name] Updated session notes
```

The user can say "don't keep that" or "drop the X entry" after seeing the summary to remove anything.

## Step 6: Update metadata

After capturing:
- Update thread `_meta.json` (`updated` timestamp, increment `sessions` count)
- Run `lore heal`
- If a plan was updated, run `lore work heal`

### Renormalize check

After heal, check for renormalize flags:

```bash
cat "$KNOWLEDGE_DIR/_meta/renormalize-flags.json" 2>/dev/null
```

If the file exists, count the total flags across all arrays (`oversized_categories`, `stale_related_files`, `zero_access_entries`). If **2 or more total flags** exist, append to the Step 5 report:

```
  [renormalize] N flags detected (oversized: X, stale refs: Y, zero-access: Z) — run /memory renormalize
```

If 1 flag, note it but don't push:
```
  [renormalize] 1 flag (oversized: conventions at 41 entries) — /memory renormalize available when ready
```

## Step 7: Resume work

After the checkpoint, return to whatever was being worked on. The checkpoint is a pause, not a redirect.
