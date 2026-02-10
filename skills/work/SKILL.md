---
name: work
description: "Check project status, remaining tasks, and session context — USE FIRST when asked 'what's left', 'what should I do', 'remaining work', or status questions. Also: create, update, archive, search work items."
user_invocable: true
argument_description: "[command] [name] — commands: create, list, update, archive, search, tasks, regen-tasks, heal"
---

# /work Skill

Manages per-project work items via script calls. Most subcommands are a single `bash` call — run the script and show the output.

## Route $ARGUMENTS

Match the first word of `$ARGUMENTS` to a command below. If no command matches but a name/slug is given, treat it as **load**. If `$ARGUMENTS` is empty, see **No arguments**.

---

### `create <name>`
```bash
lore work create "<name>"
```
Show the script output. If it exits non-zero, show the error.

---

### `list`
```bash
lore work list
```
Show the script output directly.

---

### `<name>` (load/resume — default when name given but no command matches)
```bash
lore work show "<slug>"
```
**Before calling the script**, resolve the name to an exact slug using fuzzy matching (see below). Show the script output, then add a brief summary: current phase, next steps, and whether `/spec` is available.

---

### `update`
Capture session progress — this requires judgment (session summarization).

1. Determine the work item: if one was loaded earlier in this conversation, use it. Otherwise, infer from git branch (`git rev-parse --abbrev-ref HEAD 2>/dev/null`). If ambiguous, ask the user.
2. Summarize the session — review conversation context for:
   - **Focus:** main topic
   - **Decisions:** key choices made
   - **Progress:** what was accomplished
   - **Next:** what to pick up next
   - **Related:** `[[knowledge:file#heading]]` links if relevant
3. Present the summary for user review before writing.
4. Append timestamped entry to `notes.md`:
   ```markdown
   ## YYYY-MM-DDTHH:MM
   **Focus:** ...
   **Decisions:** ...
   **Progress:** ...
   **Next:** ...
   **Related:** ...
   ```
5. Update `_meta.json` `updated` timestamp.
6. If `plan.md` exists and tasks were completed, check them off (`- [ ]` → `- [x]`).
7. Run `lore work heal`.

---

### `archive [name]`
Resolve name to slug (fuzzy match), then confirm with user: "Archive '<title>'? This moves it to _archive/."

After confirmation:
```bash
lore work archive "<slug>"
```
Show the script output.

---

### `search <query>`
```bash
lore work search "<query>"
```
Show the script output. For the top matches, briefly summarize the relevant context.

---

### `tasks [name]`
Resolve name to slug (fuzzy match). If no `plan.md` exists, tell the user to run `/spec` first.

**Check for pre-computed tasks first:**

1. Look for `tasks.json` in the work item directory (`$WORK_DIR/<slug>/tasks.json`)
2. **If `tasks.json` exists:**
   - Compute SHA256 of `plan.md`: `shasum -a 256 "$WORK_DIR/<slug>/plan.md" | cut -d' ' -f1`
   - Compare with `plan_checksum` field in `tasks.json`
   - **Checksum matches:** Load tasks directly from `tasks.json`. For each task in each phase, execute `TaskCreate` with the pre-computed `subject`, `description`, `activeForm`, and `blockedBy` fields. Report: "Loaded N tasks across M phases from tasks.json."
   - **Checksum mismatch:** Warn user: "plan.md was edited after tasks.json was generated (checksum mismatch). Run `/work regen-tasks <slug>` to regenerate tasks, or proceed with current tasks.json." Wait for user decision.
3. **If `tasks.json` does not exist** (backward compatibility): fall back to generating tasks from plan.md:
   ```bash
   lore work tasks "<slug>"
   ```
   Parse the JSON output. For each task object, execute `TaskCreate` with the `subject`, `description`, and `activeForm` fields. Set up phase dependencies: Phase N+1 tasks get `addBlockedBy` referencing Phase N task IDs.

Report: "Generated N tasks across M phases with dependencies."

---

### `regen-tasks [name]`
Resolve name to slug (fuzzy match). Regenerate `tasks.json` from the current `plan.md`.

```bash
lore work regen-tasks "<slug>"
```
This calls `generate-tasks.py` on the work item's `plan.md`, overwrites `tasks.json` with a fresh checksum and timestamp, then runs `lore work heal` to update the work index.

Show the script output. Report: "Regenerated N tasks across M phases. New checksum: [first 8 chars]"

---

### `heal`
```bash
lore work heal
```
Show the script output directly.

---

### No arguments
Infer from context:
1. Git branch matches an active work item → run **load** with that slug
2. A work item was loaded earlier in this conversation → show its current status
3. Otherwise → run **list**

---

## Fuzzy Matching (for load, archive, tasks, regen-tasks)

When a subcommand needs a slug but the user provided a name, resolve it:
1. **Exact slug** — exists in `_work/`
2. **Substring on title** — case-insensitive unique match
3. **Substring on slug** — unique match
4. **Tag match** — matches a tag value
5. **Branch match** — current git branch matches a work item's `branches`
6. **Recency** — most recently updated active item
7. **Ambiguous** — list candidates, ask user to pick

Read `_work/_index.json` for resolution. Scripts accept exact slugs only.
