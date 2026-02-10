## Capture Protocol (During Work)

Capture is enforced structurally: a Stop hook evaluates every session for uncaptured reactive discoveries, and worker templates in `/implement` and `/spec` include a capture step. You do not need to remember to capture — the system will prompt you.

**When capturing manually**, use the CLI:
```bash
lore capture --insight "..." --context "..." --category "..." --confidence "high" --related-files "..."
```

**After capturing:** Briefly mention what you captured (e.g., "Captured to knowledge store: evaluators use template-method pattern"). The user can immediately say "don't keep that" to remove it.

**Target:** 2-5 captures per substantial session. Err on the side of capturing — it's cheap to drop an entry later, expensive to lose an insight.

**Capture triggers (reference — enforcement is structural):**
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

## First-Turn Capture Review

When `_pending_captures/` directory exists in the knowledge store at session start:
1. Glob `_pending_captures/*.md` — each file contains one candidate segment extracted by the stop hook's novelty detection
2. For each file, read it and evaluate the candidate against the 4-condition capture gate (reusable, non-obvious, stable, high-confidence)
3. For qualifying insights, run `lore capture` with appropriate parameters
4. Delete each file after evaluation (regardless of whether the candidate qualified)
5. Remove the `_pending_captures/` directory once empty
6. Brief feedback: `[capture] Reviewed N candidates from previous session, captured M insights`

If no candidates qualify, delete all files, remove the directory, and note: `[capture] Reviewed N candidates, none met capture gate`

**Do NOT capture:** task-specific details, info already in docs, speculation, transient state.

If the user invokes `/remember`, do a thorough review of the entire conversation for uncaptured insights.
