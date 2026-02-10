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

**High-value capture categories (all require synthesis across multiple sources):**
1. **Architectural models** — how components connect, what the layers are, where data flows. *Example: "Lore separates logic (repo) from data (~/.lore/). The symlink at ~/.lore/scripts/ is the portability layer."*
2. **Design rationale** — why the architecture is this way, what was rejected, what constraints drove decisions. *Example: "Script-first because mechanical subcommands are faster than improvisation."*
3. **Cross-cutting conventions** — patterns that span many files and can't be seen from one. *Example: "All scripts source lib.sh; defensive tr -d sanitization throughout."*
4. **Behavioral directives** — observed mistakes crystallized into rules. *Example: "Don't bypass /work for CRUD ops."*
5. **Mental models** — frameworks for recognizing categories of situations. *Example: "Bypass taxonomy: instruction fade, faster-path, abstract activation threshold."*
6. **Directional intent** — aspirations and implementer context not yet realized in code. *Example: "The knowledge store should eventually support multi-framework delivery, but the CLI and data format are the shared layer."*

**Capture gate — conditions 1-4 must all be true; condition 5 determines loading tier:**
1. **Reusable** — applicable beyond the current task
2. **Non-obvious** — not already in README, CLAUDE.md, or docs
3. **Stable** — unlikely to change soon
4. **High confidence** — verified through code exploration, not speculative
5. **Synthesis** — required combining information from multiple files, sessions, or components. If an entry could be read from a single source file, it belongs in the searchable tier (still captured, lower loading priority).

**Low-priority captures:** Entries that pass conditions 1-4 but not 5 are still captured — they provide real token savings when retrieved on demand. They rank lower in auto-loading naturally: single-source entries accumulate fewer backlinks, so backlink in-degree keeps them out of the limited startup budget without explicit tiering.

## First-Turn Capture Review

When `_pending_captures/` directory exists in the knowledge store at session start:
1. Glob `_pending_captures/*.md` — each file contains one candidate segment extracted by the stop hook's novelty detection
2. For each file, read it and evaluate the candidate against the capture gate (reusable, non-obvious, stable, high-confidence) and assess synthesis level for tier placement
3. For qualifying insights, run `lore capture` with appropriate parameters
4. Delete each file after evaluation (regardless of whether the candidate qualified)
5. Remove the `_pending_captures/` directory once empty
6. Brief feedback: `[capture] Reviewed N candidates from previous session, captured M insights`

If no candidates qualify, delete all files, remove the directory, and note: `[capture] Reviewed N candidates, none met capture gate`

**Do NOT capture:** task-specific details, info already in docs, speculation, transient state.

If the user invokes `/remember`, do a thorough review of the entire conversation for uncaptured insights.
