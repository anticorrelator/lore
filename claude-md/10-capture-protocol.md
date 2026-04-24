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

**Debugging narrative format (optional template for gotcha captures):** When a debugging session surfaces a non-obvious root cause, structure the capture using this 5-field template — it teaches pattern recognition and improves retrieval utility beyond a bare symptom description. Aim for ~150 words total to fit context budgets.

- **Symptom:** what the error or failure looked like ("vt emulator tests hung indefinitely")
- **False starts:** approaches tried that didn't work and why ("suspected goroutine leak — heap profiling showed nothing; added timeouts — tests passed but root cause unknown")
- **Key diagnostic:** the observation or tool output that cracked it ("io.Pipe blocks until reader consumes — writer goroutine was blocked waiting for a reader that never ran")
- **Root cause:** the underlying mechanism ("io.Pipe is synchronous: Write blocks until Read is called. Using it for test output requires a goroutine consuming the reader.")
- **Fix:** what resolved it ("replaced io.Pipe with bytes.Buffer; reads never block")

**Why > what:** A statement explaining *why* a choice was made is more valuable than a statement describing *what* was chosen. The "what" is recoverable from code; the "why" is not. When both a rationale and a factual observation pass the capture gate, prefer the rationale.

**High-value capture categories (entries in these categories often involve synthesis and load at startup):**
1. **Design rationale** — why the architecture is this way, what was rejected, what constraints drove decisions. *Example: "Script-first because mechanical subcommands are faster than improvisation."*
2. **Architectural models** — how components connect, what the layers are, where data flows. *Example: "Lore separates logic (repo) from data (~/.lore/). The symlink at ~/.lore/scripts/ is the portability layer."*
3. **Cross-cutting conventions** — patterns that span many files and can't be seen from one. *Example: "All scripts source lib.sh; defensive tr -d sanitization throughout."*
4. **Behavioral directives** — observed mistakes crystallized into rules. *Example: "Don't bypass /work for CRUD ops."*
5. **Mental models** — frameworks for recognizing categories of situations. *Example: "Bypass taxonomy: instruction fade, faster-path, abstract activation threshold."*
6. **Directional intent** — aspirations and implementer context not yet realized in code. *Example: "The knowledge store should eventually support multi-framework delivery, but the CLI and data format are the shared layer."*
7. **Operational procedures** — when you encounter X in context Y, the effective path is steps 1→2→3. *Example: "To debug FTS5 query failures: (1) check if the search term contains hyphens or special chars — these need quoting, (2) verify the FTS index is fresh with `SELECT count(*) FROM fts_entries`, (3) check tokenizer config in the CREATE VIRTUAL TABLE statement."*
8. **Error signatures** — symptom: X / likely cause: Y / verify: Z. *Example: "Symptom: `lore search` returns 0 results for a term you know exists. Likely cause: hyphenated term not being quoted in FTS5 query. Verify: run the query manually in sqlite3 with explicit quoting."*
9. **Implicit constraints** — rules from external factors, not code. *Example: "The stop hook must complete in <500ms — it runs on every session exit and blocking the user is unacceptable."*

**Capture gate — all 4 conditions must be true:**
1. **Reusable** — applicable beyond the current task
2. **Non-obvious** — not already in README, CLAUDE.md, or docs
3. **Stable** — unlikely to change soon
4. **High confidence** — verified through code exploration, not speculative

**Synthesis as a loading signal:** After an entry qualifies, assess whether it required combining information from multiple files, sessions, or components. Synthesis entries load at startup; single-source entries are still captured — they provide real token savings when retrieved on demand — but rank lower in auto-loading naturally: single-source entries accumulate fewer backlinks, so backlink in-degree keeps them out of the limited startup budget without explicit tiering.

**Calibration examples:**
- ✓ *High-priority capture (synthesis):* "All scripts source lib.sh for slugify(), resolve_knowledge_dir(), get_git_branch(), and timestamp_iso() — this is the portability contract for the entire scripts layer." Requires reading multiple scripts across the directory to confirm the pattern; not visible from any single file.
- ✓ *Lower-priority capture (single-source, still valuable):* "The stop hook must complete in <500ms — enforced by the ceremony-config.sh timeout setting." Directly readable from one config file, but saves token cost for any agent that would otherwise re-read that file to confirm the constraint.
- ✗ *Anti-pattern — existence ≠ recoverability:* "lib.sh defines slugify() as tr + sed." This is a factual description of a function signature readable directly from lib.sh — it fails Non-obvious and fails the recoverability test: the "what" is in the code. Capture the *why* (slugify uses this approach because scripts must run in restricted shell environments without external tools) not the *what*.

**The existence ≠ recoverability anti-pattern:** Information existing in a file is not the same as understanding being recoverable from that file. An agent reading lib.sh can find what slugify does in seconds. What cannot be recovered from a single read is: why that approach was chosen, what alternatives were rejected, or how this function's behavior constrains callers across the codebase. Captures of the latter are reusable; captures of the former are not.

## First-Turn Capture Review

When `_pending_captures/` directory exists in the knowledge store at session start:
1. Glob `_pending_captures/*.md` — each file contains one candidate segment extracted by the stop hook's novelty detection
2. For each file, read it and evaluate the candidate against the capture gate (reusable, non-obvious, stable, high-confidence) and assess synthesis level for tier placement. **Trigger-type guidance:**
   - **`debug-root-cause` candidates:** apply the debugging narrative lens — the insight is most valuable when it captures what you expected → what you found → what it means for the system. Evaluate whether the root cause reveals something non-obvious about how the system works. Format the insight using that narrative structure if qualifying.
   - **`structural-*` candidates** (e.g., `structural-footprint`, `structural-signal`): evaluate as architectural observations — module roles, integration points, what constrains changes. These often qualify for the Architectural models or Cross-cutting conventions categories.
   - **`preference-signal` candidates:** evaluate as scoped working-style preferences. If `related_files` names a skill, file, or directory (non-`none`), route to `lore capture --category preferences --related-files <paths>` via `/remember` Step 3 branch. If `related_files: none`, route to thread `accumulated_preferences` instead — not to a knowledge entry.
   - **Other trigger types** (`design-decision`, `gotcha`, `self-correction`): evaluate normally against capture gate.

   **Low-context candidates:** If the candidate excerpt is too sparse to evaluate the gate confidently, read the **Related files:** field and skim those files before deciding. Do not reject a candidate solely because the excerpt is thin — the stop hook pre-filter has already established baseline relevance. Rejection requires a positive reason (fails Reusable, Non-obvious, Stable, or High confidence), not an absence of evidence.

   **Staleness branch:** when the "non-obvious" check reveals a similar entry may already exist, run `lore search "<key terms>" --type knowledge --limit 3`, read the top match, and branch: (a) same claim — skip the candidate, (b) divergent (contradicts or supersedes) — edit the existing entry file in-place to reflect the new insight, update its `learned` date to today, then skip the new capture. Note: `[staleness] Updated "<existing title>" — superseded by new finding`.
3. For qualifying insights, determine the emission path before running the capture command:
   - **Tier 3 path (`lore promote`):** use when ALL four predicates are true: (a) the candidate is backed by a Tier 2 evidence artifact (worker/researcher observation from `execution-log.md` or `plan.md`), (b) it can be expressed as a `validate-tier3.sh`-accepted row with `claim`, `why_future_agent_cares`, `falsifier`, and `source_artifact_ids`, (c) `source_artifact_ids` is non-empty, and (d) the claim is reusable outside the current work item.
   - **Tier 1 path (`lore capture`):** everything else — interactive candidates, candidates without Tier 2 backing, and any candidate that fails any of the four Tier 3 predicates.

   **Pass `--related-files`** using the `**Related files:**` field from the candidate file (skip if the field is `none`):
   ```bash
   lore capture --insight "..." --context "..." --category "..." --confidence "high" --related-files "<value from Related files field>"
   ```
4. Delete each file after evaluation (regardless of whether the candidate qualified)
5. Remove the `_pending_captures/` directory once empty
6. Brief feedback: `[capture] Reviewed N candidates from previous session, captured M insights`

If no candidates qualify, delete all files, remove the directory, and note: `[capture] Reviewed N candidates, none met capture gate`

**Do NOT capture:** task-specific details, info already in docs, speculation, transient state.

If the user invokes `/remember`, do a thorough review of the entire conversation for uncaptured insights.
