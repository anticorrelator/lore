---
name: remember
description: Capture insights to knowledge inbox and update conversational threads — invoke anytime to ensure nothing is lost
user_invocable: true
argument_description: "[optional: focus area to review]"
---

# /remember Skill

Pause and review the current session for uncaptured knowledge and unupdated threads. Combines knowledge capture with thread updates.

## Resolve Paths

```bash
bash ~/.project-knowledge/scripts/resolve-repo.sh
```

Set `KNOWLEDGE_DIR` to the result. Set `THREADS_DIR` to `$KNOWLEDGE_DIR/_threads`.

## Step 1: Scan for uncaptured insights

Review the full conversation context and identify moments that match capture triggers:

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
   **Related:** [[plan:name]], [[knowledge:file#heading]]
   ```
4. Check for new topics that don't match existing threads and had >2 substantive exchanges — these become new thread candidates

## Step 3: Check plan status

- Is there an active plan for the current work? Check `_plans/` for branch match or recent activity.
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

**Exception: external feedback.** If an insight originates from external sources (PR review comments, code review suggestions, issue discussions, pair programming input), prompt the user before capturing. External opinions may not align with the user's own mental models.

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
- Update thread YAML frontmatter (`updated`, increment `sessions`)
- Run `bash ~/.project-knowledge/scripts/update-thread-index.sh`
- If a plan was updated, run `bash ~/.project-knowledge/scripts/update-plan-index.sh`

## Step 7: Resume work

After the checkpoint, return to whatever was being worked on. The checkpoint is a pause, not a redirect.
