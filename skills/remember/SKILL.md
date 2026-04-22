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

## Resolve Template Version

Compute the content-hash of the `/remember` skill template itself. This is the `template_version` that accompanies every `lore capture` call in Step 5 and every `write-execution-log.sh` call:

```bash
REMEMBER_TEMPLATE_VERSION=$(bash ~/.lore/scripts/template-version.sh ~/.claude/skills/remember/SKILL.md)
```

When `/remember` is invoked by another skill (e.g., `/implement` or `/spec` post-work extraction), that caller passes its own template-version context via the delegation prompt — see Step 5's provenance rules for the lead-synthesis path. For interactive invocations, use `$REMEMBER_TEMPLATE_VERSION` directly. If the hash command fails, fall through with an empty string; downstream scripts treat that as "no template version" and the task #23 gate warns + passes.

## Step 1: Parse capture constraints

If an argument was provided, interpret it as **capture constraints** that adjust the 4-condition gate for this invocation. Constraints narrow what gets captured — they never expand it (the base gate always applies).

The argument can be:
- **A focus area** (e.g., "auth changes") — limits the scan to that topic
- **A capture filter** (e.g., "skip style preferences, capture architecture decisions") — tightens the gate criteria
- **Both** (e.g., "PR review feedback — capture architectural insights and gotchas, skip style nits and formatting preferences")

When called from another skill, the argument typically provides context about what kind of work just happened and what's worth persisting vs what's ephemeral. Apply these constraints throughout Steps 2-5.

**Examples of how constraints tighten the gate:**

| Calling context | Capture | Skip |
|----------------|---------|------|
| PR review | Architectural feedback, corrected misconceptions, non-obvious patterns the reviewer spotted | Style preferences, formatting nits, subjective code taste, naming bikeshedding |
| Debugging session | Root causes, misleading error messages, environment-specific gotchas | Dead-end hypotheses, one-off typos, transient state |
| Dependency upgrade | Breaking changes, migration patterns, compatibility gotchas | Version numbers, changelog summaries, routine deprecation warnings |
| Refactoring | Discovered coupling, extraction patterns, invariants that weren't obvious | Mechanical renames, import reordering, formatting changes |

The key question for each candidate: **would a future session benefit from knowing this, or is it noise?** Constraints from the caller help answer this by providing domain-specific signal about what's ephemeral.

## Step 1b: Resolve active work item

Run work item resolution once; the result flows to Step 5 (execution-log write):

```bash
lore work list --json --all
```

Parse the JSON output and match the current git branch against each item's `branches` array:
- **Branch match found:** Set `RESOLVED_SLUG` to that item's slug.
- **No branch match:** Check if the invocation's capture-constraint string (from Step 1) contains a substring matching any active work item's title (case-insensitive). If matched, set `RESOLVED_SLUG`.
- **No match either way:** Leave `RESOLVED_SLUG` unset. Subsequent steps skip the execution-log write silently.

## Step 2: Scan for uncaptured insights

Review the full conversation context (filtered by any Step 1 constraints) and identify moments that match capture triggers:

- A design decision was made with non-obvious rationale
- Something was discovered to work differently than expected
- A debugging session revealed a non-obvious root cause
- A pattern was found that repeats across the codebase
- A gotcha or pitfall was encountered
- The user corrected a misconception or shared domain knowledge
- A workaround was used (and the reason why matters)
- An investigation or usage workflow was discovered ("to debug X, do Y then Z") — **operational procedure**
- A symptom-to-cause mapping was encountered ("error X means Y, verify with Z") — **error signature**
- A non-code-visible rule was discovered ("can't do X because of Y constraint") — **implicit constraint**

**Debugging narrative format:** When a debugging session surfaces a non-obvious root cause, structure the capture using this 5-field template — it teaches pattern recognition and improves retrieval utility beyond a bare symptom description:
- **Symptom:** what the error or failure looked like
- **False starts:** approaches tried that didn't work and why
- **Key diagnostic:** the observation or tool output that cracked it
- **Root cause:** the actual underlying reason
- **Fix:** what resolved it

For each candidate, assess against the capture gate — all 4 conditions must be true:
1. Reusable (beyond this task)?
2. Non-obvious (not in existing docs)?
3. Stable (won't change soon)?
4. High confidence (verified)?

If capture constraints were provided in Step 1, apply them as an additional filter: candidates that pass the base gate but fall into the "skip" category for the current context are dropped silently.

**Staleness branch:** when the "non-obvious" check reveals a similar entry may already exist, run `lore search "<key terms>" --type knowledge --limit 3`, read the top match, and branch: (a) same claim — skip the candidate, (b) divergent (contradicts or supersedes) — edit the existing entry file in-place to reflect the new insight, update its `learned` date to today, then skip the new capture. Note: `[staleness] Updated "<existing title>" — superseded by new finding`.

**Synthesis as a loading signal:** After an entry qualifies, assess whether it required combining information from multiple files, sessions, or components. Synthesis entries load at startup; single-source entries are still captured — they provide real token savings when retrieved on demand — but rank lower in auto-loading naturally. The following categories are strong positive indicators of synthesis: architectural models, design rationale, cross-cutting conventions, behavioral directives, mental models, and directional intent. Operational procedures, error signatures, and implicit constraints often qualify too — they typically combine runtime behavior with code structure.

**Anti-pattern — existence ≠ recoverability:** Information existing in a file is not the same as understanding being recoverable from that file. A rationale comment buried in code is not a captured insight — it will be missed in future sessions. The presence of a pattern in source does not make it "obvious." When in doubt, the question is: could a future session reconstruct this understanding from the code alone, in the time available? If not, capture it.

**Why > what:** A statement explaining *why* a choice was made is more valuable than a statement describing *what* was chosen. When both a rationale statement and a factual observation pass the gate, prefer the rationale. For example, "we use script-first skill design because it prevents instruction fade in SKILL.md" outranks "skills delegate to bash scripts" — the second is recoverable from code; the first is not.

## Step 3: Scan for thread updates and preference signals

Review the conversation for thread-worthy content:

1. Read the thread index at `$THREADS_DIR/_index.json`
2. For each existing thread, check if this session discussed the topic
3. While scanning, also detect **preference signals** — patterns of user behavior or explicit statements that reveal reusable working-style preferences. Look for:
   - **User corrections:** "Don't do X, I prefer Y" or repeated pushback on a pattern
   - **Stated preferences:** "I like when...", "Always use...", "Skip the..."
   - **Reinforced patterns:** The same preference surfacing across multiple exchanges or sessions
   - **Demonstrated preferences:** Consistent choices the user makes without stating them explicitly (e.g., always choosing concise output, preferring certain file organizations)

   **Not preferences:** One-off requests ("make this function shorter"), task-specific instructions, or transient choices that won't apply next session.

   **Scoped vs. global routing:** For each detected preference signal, classify before acting:
   - **Scoped** — the preference names a skill (`/pr-review`, `/implement`), a specific file or directory (`tui/model.go`, `scripts/`), or only applies when a particular workflow or tool is active → route to `lore capture --category preferences --related-files <paths> --producer-role interactive --protocol-slot Reflection`. Use the skill's SKILL.md path (e.g., `skills/pr-review/SKILL.md`) or the relevant source file(s) as `related_files`. Do NOT also write it to thread `accumulated_preferences`.
   - **Global** — the preference has no detectable scope and applies regardless of context ("be terse", "use active voice") → skip `lore capture` and continue to Step 5 thread accumulation as usual.

   When scope is ambiguous, ask: "would this preference be irrelevant or wrong in a different skill or file context?" If yes → scoped. If it applies equally everywhere → global.

4. If the thread was discussed, write a new entry file at `$THREADS_DIR/<slug>/<date>.md` (e.g., `how-we-work/2026-02-08.md`). If a file for today already exists, disambiguate with session suffix: `2026-02-08-s2.md`. Entry files do NOT contain the `## ` heading — it is reconstructed from the filename at load time. Entry content starts with `**Summary:**`:
   ```markdown
   **Summary:** One-sentence overview of what was discussed
   **Key points:**
   - Specific decisions, shifts, or ideas
   **Shifts:** Change from previous entries (optional)
   **Preferences:** User preferences or working-style signals observed this session (optional — **include only global preferences here**; scoped preferences were already routed to `lore capture` in step 3 above)
   **Related:** [[work:name]], [[knowledge:file#heading]]
   ```
5. Check for new topics that don't match existing threads and had >2 substantive exchanges — these become new thread candidates. Create the directory `$THREADS_DIR/<slug>/` with a `_meta.json` file:
   ```json
   {
     "slug": "<slug>",
     "topic": "<topic description>",
     "tier": "active",
     "created": "<ISO timestamp>",
     "updated": "<ISO timestamp>",
     "sessions": 1,
     "accumulated_preferences": []
   }
   ```
   Then write the first entry file as in step 4. Update `$THREADS_DIR/_index.json` to include the new thread.

## Step 4: Check plan status

- Is there an active plan for the current work? Check `_work/` for branch match or recent activity.
- If no plan exists, check auto-trigger conditions:
  - Design discussion (choosing between approaches, trade-offs)?
  - Multi-step implementation (>2-3 files)?
  - Ambiguous scope (goal stated but path unclear)?
  - System/meta changes (tooling, config, process)?
  - Cross-session work (won't finish this conversation)?
- If a plan exists, does it need a session notes update?

## Step 5: Act

**Default behavior: auto-capture.** Everything that passes the gate gets captured immediately. The gate is the quality filter — no additional confirmation needed.

- Capture all insights that pass the gate — `lore capture` files directly to the correct category file:
  ```bash
  lore capture --insight "..." --context "..." --category "..." --confidence "..." --related-files "..." \
    --producer-role <role> --protocol-slot <slot> --template-version <hash> [--work-item <slug>]
  ```
  **Always populate `--related-files`** with concrete file paths the insight describes or depends on (e.g., `scripts/pk_search.py`, `skills/remember/SKILL.md`). This is the strongest staleness signal — when those files change, the entry gets flagged for review. Scan the conversation context for which files were involved. Err on the side of including files: a false positive (file changed but entry still valid) is cheap to dismiss; a missing reference means silent drift.

  **Always populate `--producer-role`, `--protocol-slot`, and `--template-version`**:
  - When `/remember` is invoked directly by the user (interactive session), use `--producer-role interactive --protocol-slot Reflection --template-version $REMEMBER_TEMPLATE_VERSION`.
  - When `/remember` is invoked by another skill (e.g., `/implement` post-implementation extraction, `/spec` research synthesis), use the role passed in by that skill — typically `implement-lead` or `spec-lead` with `--protocol-slot Synthesis`, AND use the `--template-version` the caller passes (the lead's `$LEAD_TEMPLATE_VERSION` for lead-original insights, or the original producer's hash for promoted observations). The invoking skill should include both the role/slot context AND the template-version hash in its delegation prompt.
  - When a work item is active (branch matches an item in `_work/`, or the caller passes one), also add `--work-item <slug>`. The capture script resolves the work item's scope + the role × slot matrix offset into an absolute `scale` field; missing work-item or off-scale role×slot pairs simply omit the scale with no error.

  **Lead-synthesis attribution (promoting worker/researcher observations into the commons):** when `/remember` is delegated by `/implement` or `/spec` to promote a specific worker or researcher observation from `execution-log.md` or `plan.md` **Observations:**/**Investigation:** entries, the capture must preserve the **original producer's role** — not the lead's. Emit:
  - `--producer-role <worker|researcher>` — the role of whoever produced the observation.
  - `--capturer-role <implement-lead|spec-lead>` — the lead doing the synthesis write.
  - `--source-artifact-ids "<task-id or report-id>[,<id2>,...]"` — IDs pointing back to the producer's task or report artifact so the claim is auditable.
  - `--template-version <original-producer-template-hash>` — the template hash of the *original* producer, not the lead. This is how scorecard rollups attribute learning signal to the correct template version. The caller is responsible for resolving the right hash when it computes `$WORKER_TEMPLATE_VERSION` / `$RESEARCHER_TEMPLATE_VERSION` in its own preamble and passing that value through.

  **Split on multi-producer synthesis.** When a single synthesized claim draws on observations from multiple distinct producers, file **one capture call per distinct producer** — do NOT merge into a single call with a multi-role `--producer-role`. Each call keeps its own `--source-artifact-ids` pointing to that producer's artifact. Rationale: the scale matrix and downstream scorecard attribution both key on a single `producer_role`; merging would erase the hierarchy the matrix exists to preserve. This closes the attribution-erasure risk surfaced in the 2026-04-21 audit.
- Write all thread updates (new entry files to `_threads/<slug>/<date>.md`, update `_meta.json`)
- Create new threads if warranted (create directory, `_meta.json`, first entry file, update `_index.json`)
- Update plans as needed

**Write execution-log entry** — if `RESOLVED_SLUG` was set in Step 1b, append a session summary to `execution-log.md`:
```bash
printf 'Captures: %s\nThreads updated: %s\nSummary: %s\n' \
  "<N entries captured: title1, title2, ...>" \
  "<thread slugs updated or created>" \
  "<one-sentence summary of what was done this session>" \
  | bash ~/.lore/scripts/write-execution-log.sh --slug "$RESOLVED_SLUG" --source remember --template-version "$REMEMBER_TEMPLATE_VERSION"
```
Derive the summary from the captures and thread updates just made. If no captures were made and no threads updated, omit the write.

### Preference accumulation

**Scope gate:** Only accumulate preferences that were NOT routed to `lore capture` in Step 3. Scoped preferences are stored in the knowledge store (`preferences/` category) and must not also be written to `accumulated_preferences` — that is the double-capture scenario to avoid.

After writing thread entries that contain a `**Preferences:**` field, update the thread's `_meta.json` `accumulated_preferences` array:

1. **Read** the thread's current `_meta.json` and its `accumulated_preferences` array
2. **For each preference** in the new entry's `**Preferences:**` field:
   - **Match check:** Does it match an existing accumulated preference? (semantic match — same intent, possibly different wording)
   - **If match found:** Update `last_reinforced` to today's date and append the entry filename to `source_entries`
   - **If no match:** Add a new entry:
     ```json
     {
       "preference": "Short description of the preference",
       "first_seen": "YYYY-MM-DD",
       "last_reinforced": "YYYY-MM-DD",
       "source_entries": ["<entry-filename>.md"]
     }
     ```
3. **Contradiction check:** If a new preference directly contradicts an existing accumulated preference (e.g., "prefer verbose output" vs existing "prefer concise output"), remove the old preference and add the new one. Briefly note: `[thread: <slug>] Preference updated: "<old>" → "<new>"`
4. **Write** the updated `_meta.json`

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

**Exception: external feedback.** If an insight originates from external sources (PR review comments, code review suggestions, issue discussions, pair programming input), prompt the user before capturing — unless capture constraints from Step 1 already specify how to handle external input. External opinions may not align with the user's own mental models.

```
[external] PR reviewer suggested "use dependency injection for testability"
  → Capture to knowledge? [Their rationale: ...]
```

## Step 6: Report summary

After capturing, print a concise summary:

```
[remember] Done.
  [knowledge] Captured N entries: "insight 1", "insight 2"
  [thread: topic] Updated with today's discussion
  [thread: new] Created "topic-name"
  [plan: name] Updated session notes
```

The user can say "don't keep that" or "drop the X entry" after seeing the summary to remove anything.

## Step 7: Update metadata

After capturing:
- Update thread `_meta.json` (`updated` timestamp, increment `sessions` count)
- Run `lore heal`
- If a plan was updated, run `lore work heal`

### Renormalize check

After running heal, check for renormalize flags:

```bash
cat "$KNOWLEDGE_DIR/_meta/renormalize-flags.json" 2>/dev/null
```

If the file exists, count the total flags across all arrays (`oversized_categories`, `stale_related_files`, `zero_access_entries`). If **2 or more total flags** exist, append to the Step 6 report:

```
  [renormalize] N flags detected (oversized: X, stale refs: Y, zero-access: Z) — run /memory renormalize
```

If 1 flag, note it but don't push:
```
  [renormalize] 1 flag (oversized: conventions at 41 entries) — /memory renormalize available when ready
```

## Step 8: Resume work

After the checkpoint, return to whatever was being worked on. The checkpoint is a pause, not a redirect.
