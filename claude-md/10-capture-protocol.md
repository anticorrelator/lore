## Capture Protocol (During Work)

When you discover a reusable, non-obvious, stable insight with high confidence, append it to the project's `_inbox.md`. This is a single Edit/Write tool call — do NOT try to file it into the correct category inline.

**Inbox entry format:**
```markdown
## [YYYY-MM-DDTHH:MM:SS]
- **Insight:** The concrete finding
- **Context:** How/where it was discovered
- **Suggested category:** architecture|conventions|abstractions|workflows|gotchas|team|domains/<topic>
- **Related files:** relevant source file paths
- **Confidence:** high|medium|low
```

**After capturing:** Briefly mention what you captured (e.g., "Noted to knowledge inbox: evaluators use template-method pattern"). The user can immediately say "don't keep that" to remove it.

**Target:** 2-5 captures per substantial session. Err on the side of capturing — it's cheap to drop an entry later, expensive to lose an insight.

**Capture triggers — actively look for these moments:**
- A design decision is made with a non-obvious rationale ("we chose X because Y")
- You discover how something actually works vs how you expected it to work
- A debugging session reveals a non-obvious root cause
- You find a pattern that repeats across the codebase
- A gotcha or pitfall is encountered that would bite someone again
- The user corrects a misconception or provides domain knowledge

**Capture gate — all four must be true:**
1. **Reusable** — applicable beyond the current task
2. **Non-obvious** — not already in README, CLAUDE.md, or docs
3. **Stable** — unlikely to change soon
4. **High confidence** — verified through code exploration, not speculative

**Do NOT capture:** task-specific details, info already in docs, speculation, transient state.

**Checkpoint cadence:** After completing any significant sub-task (implemented a feature, finished debugging, made a design decision, completed an investigation), briefly scan the capture triggers above. This takes 5 seconds and prevents the "forgot to capture" failure mode. If the user invokes `/memory-checkpoint`, do a thorough review of the entire conversation.
