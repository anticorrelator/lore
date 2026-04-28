---
name: remember
description: Capture insights to knowledge store and update conversational threads — invoke anytime to ensure nothing is lost
user_invocable: true
argument_description: "[optional: focus area or capture constraints]"
---

# /remember Skill

Pause and review the current session for uncaptured knowledge and unupdated threads. Combines knowledge capture with thread updates.

**Session-start first-turn handlers** (`_pending_captures/` review and `_pending_digest.md` intake) live in CLAUDE.md fragments and run automatically before any skill is invoked. This skill handles the **interactive invocation path** — the same 4-condition gate applied to conversation context rather than stop-hook candidate files.

## Resolve Paths

```bash
lore resolve
```

Set `KNOWLEDGE_DIR` to the result. Set `THREADS_DIR` to `$KNOWLEDGE_DIR/_threads`.

## Resolve Template Version

```bash
REMEMBER_TEMPLATE_VERSION=$(bash ~/.lore/scripts/template-version.sh ~/.claude/skills/remember/SKILL.md)
```

When `/remember` is invoked by another skill (e.g., `/implement` or `/spec` post-work extraction), the caller passes its own template-version context via the delegation prompt — see Step 5's provenance rules for the lead-synthesis path. For interactive invocations, use `$REMEMBER_TEMPLATE_VERSION` directly. If the hash command fails, fall through with an empty string; downstream scripts treat that as "no template version."

### Step 1: Parse capture constraints

If an argument was provided, interpret it as **capture constraints** that adjust the 4-condition gate for this invocation. Constraints narrow what gets captured — they never expand it (the base gate always applies).

The argument can be:
- **A focus area** (e.g., "auth changes") — limits the scan to that topic
- **A capture filter** (e.g., "skip style preferences, capture architecture decisions") — tightens the gate criteria
- **Both** (e.g., "PR review feedback — capture architectural insights and gotchas, skip style nits")

When called from another skill, the argument typically provides context about what kind of work just happened and what's worth persisting vs what's ephemeral. Apply these constraints throughout Steps 2-5.

**Examples of how constraints tighten the gate:**

| Calling context | Capture | Skip |
|----------------|---------|------|
| PR review | Architectural feedback, corrected misconceptions, non-obvious patterns | Style preferences, formatting nits, subjective code taste |
| Debugging session | Root causes, misleading error messages, environment-specific gotchas | Dead-end hypotheses, one-off typos, transient state |
| Dependency upgrade | Breaking changes, migration patterns, compatibility gotchas | Version numbers, changelog summaries, routine deprecation warnings |
| Refactoring | Discovered coupling, extraction patterns, invariants that weren't obvious | Mechanical renames, import reordering, formatting changes |

### Step 1b: Resolve active work item

Run work item resolution once; the result flows to Step 5 (execution-log write):

```bash
lore work list --json --all
```

Parse the JSON output and match the current git branch against each item's `branches` array:
- **Branch match found:** Set `RESOLVED_SLUG` to that item's slug.
- **No branch match:** Check if the invocation's capture-constraint string (from Step 1) contains a substring matching any active work item's title (case-insensitive). If matched, set `RESOLVED_SLUG`.
- **No match either way:** Leave `RESOLVED_SLUG` unset. Subsequent steps skip the execution-log write silently.

### Step 2: Scan for uncaptured insights

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

**Debugging narrative format:** When a debugging session surfaces a non-obvious root cause, structure the capture using this 5-field template:
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

**Staleness branch:** when the "non-obvious" check reveals a similar entry may already exist, run `lore search "<key terms>" --type knowledge --limit 3`, read the top match, and branch: (a) same claim — skip the candidate; (b) divergent (contradicts or supersedes) — edit the existing entry file in-place to reflect the new insight, update its `learned` date to today, then skip the new capture. Note: `[staleness] Updated "<existing title>" — superseded by new finding`.

**Synthesis as a loading signal:** After an entry qualifies, assess whether it required combining information from multiple files, sessions, or components. Synthesis entries load at startup; single-source entries are still captured — they provide real token savings when retrieved on demand — but rank lower in auto-loading naturally. Strong positive indicators of synthesis: architectural models, design rationale, cross-cutting conventions, behavioral directives, mental models, and directional intent.

**Anti-pattern — existence ≠ recoverability:** Information existing in a file is not the same as understanding being recoverable from that file. A rationale comment buried in code is not a captured insight — it will be missed in future sessions. When in doubt: could a future session reconstruct this understanding from the code alone, in the time available? If not, capture it.

**Why > what:** A statement explaining *why* a choice was made is more valuable than a statement describing *what* was chosen. When both a rationale statement and a factual observation pass the gate, prefer the rationale.

### Step 3: Scan for thread updates and preference signals

Review the conversation for thread-worthy content:

1. Read the thread index at `$THREADS_DIR/_index.json`
2. For each existing thread, check if this session discussed the topic
3. While scanning, also detect **preference signals** — patterns of user behavior or explicit statements that reveal reusable working-style preferences. Look for:
   - **User corrections:** "Don't do X, I prefer Y" or repeated pushback on a pattern
   - **Stated preferences:** "I like when...", "Always use...", "Skip the..."
   - **Reinforced patterns:** The same preference surfacing across multiple exchanges or sessions
   - **Demonstrated preferences:** Consistent choices the user makes without stating them explicitly

   **Not preferences:** One-off requests, task-specific instructions, or transient choices that won't apply next session.

   **Scoped vs. global routing:** For each detected preference signal, classify before acting:
   - **Scoped** — the preference names a skill (`/pr-review`, `/implement`), a specific file or directory, or only applies when a particular workflow or tool is active → route to `lore capture --category preferences --related-files <paths> --producer-role interactive --protocol-slot Reflection`. Use the skill's SKILL.md path or the relevant source file(s) as `related_files`. Do NOT also write it to thread `accumulated_preferences`.
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

### Step 4: Check plan status

- Is there an active plan for the current work? Check `_work/` for branch match or recent activity.
- If no plan exists, check auto-trigger conditions:
  - Design discussion (choosing between approaches, trade-offs)?
  - Multi-step implementation (>2-3 files)?
  - Ambiguous scope (goal stated but path unclear)?
  - System/meta changes (tooling, config, process)?
  - Cross-session work (won't finish this conversation)?
- If a plan exists, does it need a session notes update?

### Step 5: Act

Capture every qualifying candidate now. This step is mandatory and must not be skipped. /implement Step 5 and /spec Step 5.4 both delegate capture invocation to /remember — a missed capture here propagates silently to every upstream caller with no recovery path. Do NOT defer with "I'll capture later." Do NOT skip because the insight seems obvious. Do NOT skip because the session was short. None of these are valid rationales.

Before capturing, confirm all 4 gate conditions hold for each candidate: (1) Reusable — applicable beyond this task, (2) Non-obvious — not already in existing docs, (3) Stable — unlikely to change soon, (4) High confidence — verified through code or conversation, not speculative. All four must be true. If any condition fails, drop the candidate silently and move on.

#### Tier routing decision

Before invoking `lore capture`, evaluate whether each qualifying candidate is a **Tier 3 commons promotion** or a **Tier 1 work-scoped / interactive capture**:

**Use `lore promote` (Tier 3 path)** when ALL four predicates are true:
1. The candidate is backed by a Tier 2 evidence artifact (worker/researcher observation from `execution-log.md` or `plan.md` Observations)
2. It can be expressed as a `validate-tier3.sh`-accepted Tier 3 row (with `claim`, `why_future_agent_cares`, `falsifier`, `source_artifact_ids`)
3. `source_artifact_ids` is non-empty (traceability back to Tier 2 source is required)
4. The claim is reusable **outside** the current work item — future agents in different contexts should care

```bash
echo '<tier3-json-row>' | lore promote --work-item "$RESOLVED_SLUG" \
  --producer-role <role> --protocol-slot Synthesis \
  --source-artifact-ids "<artifact-ids>" \
  --template-version <hash>
```

**Use `lore capture` (Tier 1 path)** for everything else — interactive sessions, work-scoped insights, scoped preference captures, and any candidate that fails any of the four Tier 3 predicates:

```bash
lore capture --insight "..." --context "..." --category "..." --confidence "..." --related-files "..." \
  --producer-role <role> --protocol-slot <slot> --template-version <hash> [--work-item <slug>]
```

**Always populate `--related-files`** with concrete file paths the insight describes or depends on. This is the strongest staleness signal — when those files change, the entry gets flagged for review. Err on the side of including files.

**Always populate `--producer-role`, `--protocol-slot`, and `--template-version`** when values are known; **omit the flags entirely** (do not pass empty strings) when values are unavailable. `capture.sh` treats flag presence as a deliberate provenance marker.

- When `/remember` is invoked directly by the user: `--producer-role interactive --protocol-slot Reflection --template-version $REMEMBER_TEMPLATE_VERSION`
- When `/remember` is invoked by another skill: use the role passed in by that skill — typically `implement-lead` or `spec-lead` with `--protocol-slot Synthesis`, AND use the `--template-version` the caller passes

**Work item association:** When `RESOLVED_SLUG` is set, add `--work-item $RESOLVED_SLUG`. Absence of a work item never errors. Scale declaration (`--scale`) is always required — missing declaration is an error, not a default.

**Scale rubric — declare explicitly at every retrieval surface:**

- **application** — lore-the-product as a whole: philosophy, top-level constraints, decisions that shape how major components compose. Answers "what is lore?" or "what's true across the whole product?"
- **architectural** — a single major component (knowledge base, skills layer, CLI, work-item system) considered as a whole: internal organization, contract with other components, why it's shaped this way.
- **subsystem** — a specific named module within a major component (the capture pipeline, /implement, the work tab): how that named thing works, why it's built that way, what its quirks are.
- **implementation** — a specific function, fix, behavior, configuration value, or change. Below the level of "named module." Local gotchas, bug-fix rationale, constants whose values matter.

**Boundary tests:** application vs architectural — does it span multiple major components or just one? architectural vs subsystem — whole component or specific module? subsystem vs implementation — can you state it without naming a specific function/file/line?

**±1 query pattern:** fixing a bug → `subsystem,implementation`; adding to a module → `subsystem,implementation`; modifying a component → `architectural,subsystem`; designing a feature → `application,architectural`.

#### Lead-synthesis attribution

When `/remember` is delegated by `/implement` or `/spec` to promote a specific worker or researcher observation, preserve the **original producer's role** — not the lead's:

- `--producer-role <worker|researcher>` — the role of whoever produced the observation
- `--capturer-role <implement-lead|spec-lead>` — the lead doing the synthesis write
- `--source-artifact-ids "<task-id or report-id>[,<id2>,...]"` — IDs pointing back to the producer's artifact
- `--template-version <original-producer-template-hash>` — the template hash of the *original* producer, not the lead

**Split on multi-producer synthesis.** When a single synthesized claim draws on observations from multiple distinct producers, file **one capture call per distinct producer** — do NOT merge into a single call with a multi-role `--producer-role`. Each call keeps its own `--source-artifact-ids` pointing to that producer's artifact. Rationale: the scale matrix and downstream scorecard attribution both key on a single `producer_role`; merging erases the hierarchy the matrix exists to preserve.

#### Write execution-log entry

If `RESOLVED_SLUG` was set in Step 1b, append a session summary to `execution-log.md`:

```bash
printf 'Captures: %s\nThreads updated: %s\nSummary: %s\n' \
  "<N entries captured: title1, title2, ...>" \
  "<thread slugs updated or created>" \
  "<one-sentence summary of what was done this session>" \
  | bash ~/.lore/scripts/write-execution-log.sh --slug "$RESOLVED_SLUG" --source remember --template-version "$REMEMBER_TEMPLATE_VERSION"
```

If no captures were made and no threads updated, omit the write.

#### Thread updates and preference accumulation

- Write all thread updates (new entry files to `_threads/<slug>/<date>.md`, update `_meta.json`)
- Create new threads if warranted (create directory, `_meta.json`, first entry file, update `_index.json`)
- Update plans as needed

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
3. **Contradiction check:** If a new preference directly contradicts an existing accumulated preference, remove the old preference and add the new one. Note: `[thread: <slug>] Preference updated: "<old>" → "<new>"`
4. **Write** the updated `_meta.json`

#### Post-capture conflict check

After all captures are filed, check each new entry for conflicts with existing entries:

1. For each entry just captured, search the same category with FTS5:
   ```bash
   lore search "<key terms from entry title>" --type knowledge --limit 5
   ```
2. For each match with an **older `learned` date** than the new entry, compare content. Look for direct contradiction, supersession, or overlap.
3. **Act on conflicts:**
   - **Contradiction/supersession:** Update the older entry to reflect current reality, or drop it if the new entry fully replaces it. Note: `[conflict] Updated "old title" — superseded by "new title"`
   - **Overlap:** Merge into the better-written entry, drop the other. Note: `[conflict] Merged "entry A" into "entry B"`
4. When updating an older entry, refresh its `related-files` metadata and `learned` date

**Exception: external feedback.** If an insight originates from external sources (PR review comments, code review suggestions), prompt the user before capturing — unless capture constraints from Step 1 already specify how to handle external input.

```
[external] PR reviewer suggested "use dependency injection for testability"
  → Capture to knowledge? [Their rationale: ...]
```

### Step 6: Report summary

After capturing, print a concise summary:

```
[remember] Done.
  [knowledge] Captured N entries: "insight 1", "insight 2"
  [thread: topic] Updated with today's discussion
  [thread: new] Created "topic-name"
  [plan: name] Updated session notes
```

The user can say "don't keep that" or "drop the X entry" after seeing the summary to remove anything.

### Step 7: Update metadata

After capturing:
- Update each modified thread's `_meta.json`: set `updated` to now and increment `sessions`.
- Run `lore heal`.
- If a plan was updated, run `lore work heal`.

### Renormalize check

After running heal, check for renormalize flags:

```bash
cat "$KNOWLEDGE_DIR/_meta/renormalize-flags.json" 2>/dev/null
```

If the file exists, count the total flags across all arrays (`oversized_categories`, `stale_related_files`, `zero_access_entries`). If **2 or more total flags** exist, append to the Step 6 report:

```
  [renormalize] N flags detected (oversized: X, stale refs: Y, zero-access: Z) — run /memory renormalize
```

If 1 flag:
```
  [renormalize] 1 flag (oversized: conventions at 41 entries) — /memory renormalize available when ready
```

### Step 8: Resume work

After the checkpoint, return to whatever was being worked on. The checkpoint is a pause, not a redirect.
