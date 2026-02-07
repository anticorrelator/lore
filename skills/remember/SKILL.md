---
name: remember
description: Capture insights to knowledge inbox and update conversational threads — invoke anytime to ensure nothing is lost
user_invocable: true
argument_description: "[optional: focus area or capture constraints]"
---

# /remember Skill

Pause and review the current session for uncaptured knowledge and unupdated threads. Combines knowledge capture with thread updates.

## Resolve Paths

```bash
bash ~/.lore/scripts/resolve-repo.sh
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
3. If so, draft an entry:
   ```markdown
   ## YYYY-MM-DD
   **Summary:** One-sentence overview of what was discussed
   **Key points:**
   - Specific decisions, shifts, or ideas
   **Shifts:** Change from previous entries (optional)
   **Related:** [[work:name]], [[knowledge:file#heading]]
   ```
4. Check for new topics that don't match existing threads and had >2 substantive exchanges — these become new thread candidates

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

- Capture all insights that pass the gate (append to `_inbox.md`)
- Write all thread updates (append entries to thread files, update frontmatter)
- Create new threads if warranted
- Update plans as needed

**Exception: external feedback.** If an insight originates from external sources (PR review comments, code review suggestions, issue discussions, pair programming input), prompt the user before capturing — unless capture constraints from Step 0 already specify how to handle external input. External opinions may not align with the user's own mental models.

```
[external] PR reviewer suggested "use dependency injection for testability"
  → Capture to knowledge? [Their rationale: ...]
```

## Step 4b: Organize inbox (manual invocations only)

If this was a **manual invocation** (user typed `/remember` directly, no capture constraints from Step 0), check whether `_inbox.md` has pending entries — including any just captured in Step 4.

If there are entries, organize them inline: follow the `/memory organize` protocol (present 1-line summaries, file into category files, deduplicate, add backlinks, clear inbox, update manifest). This combines capture and organization into a single checkpoint while the context is fresh.

**Skip this step when:**
- Capture constraints were provided (called from another skill — don't detour into unrelated organization)
- The inbox is empty after Step 4 (nothing to organize)

## Step 5: Report summary

After capturing (and organizing if Step 4b ran), print a concise summary:

```
[remember] Done.
  [knowledge] Captured N entries: "insight 1", "insight 2"
  [knowledge] Organized M entries: N to gotchas, N to conventions, ...
  [thread: topic] Updated with today's discussion
  [thread: new] Created "topic-name"
  [plan: name] Updated session notes
```

The user can say "don't keep that" or "drop the X entry" after seeing the summary to remove anything.

## Step 6: Update metadata

After capturing:
- Update thread YAML frontmatter (`updated`, increment `sessions`)
- Run `bash ~/.lore/scripts/update-thread-index.sh`
- If a plan was updated, run `bash ~/.lore/scripts/update-work-index.sh`

## Step 7: Resume work

After the checkpoint, return to whatever was being worked on. The checkpoint is a pause, not a redirect.
