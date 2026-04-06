---
name: work
description: "Check project status, remaining tasks, and session context — USE FIRST when asked 'what's left', 'what should I do', 'remaining work', or status questions. Also: create, update, archive, search work items."
user_invocable: true
argument_description: "[command] [name] — commands: create, list, update, set, archive, search, tasks, regen-tasks, heal"
---

# /work Skill

Manages per-project work items via script calls. Most subcommands are a single `bash` call — run the script and show the output.

## Route $ARGUMENTS

Match the first word of `$ARGUMENTS` to a command below. If no command matches but a name/slug is given, treat it as **load**. If `$ARGUMENTS` is empty, see **No arguments**.

---

### `create <name> [--issue <value>] [--pr <value>]`
```bash
lore work create --title "<name>" [--issue "<value>"] [--pr "<value>"]
```
**Before running:** Titles must be ≤70 characters (same as git/PR title convention). Keep it concise — 3–6 words that identify the goal, not a sentence. The slug is generated from the title (stopwords stripped, kebab-cased, capped at 50 chars). Good: `"TUI Mouse Click Focus"`. Bad: `"Add Mouse Click To Focus Panel In TUI When User Clicks"`.

**Dedup:** The script rejects creation if the new slug overlaps with an existing slug (substring match). If this happens, use the existing item — do NOT retry with a different name for the same topic.

Pass `--issue` and `--pr` only when provided by the user. Show the script output. If it exits non-zero, show the error.

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

### `set <name> --issue <value> --pr <value>`
Resolve name to slug (fuzzy match), then run:
```bash
lore work set "<slug>" --issue "<value>" --pr "<value>"
```
Both flags are optional — pass only what the user provided. Show the script output.

---

### `search <query>`
```bash
lore work search "<query>"
```
Show the script output. For the top matches, briefly summarize the relevant context.

---

### `tasks [name]`
Resolve name to slug (fuzzy match). If no `plan.md` exists, tell the user to run `/spec` first.

Run:
```bash
lore work load-tasks "<slug>"
```

This validates the checksum and outputs tasks as structured text blocks (`=== task-N ===`), one per task, each with `subject`, `activeForm`, `blockedBy`, and `description`. Read the output once and fire `TaskCreate` for each task. Track the `task-N` → actual TaskCreate ID mapping, then set up dependencies via `TaskUpdate(addBlockedBy=[...])`.

- **Checksum mismatch:** the script exits with an error. Warn user: "plan.md was edited after tasks.json was generated. Run `/work regen-tasks <slug>` to regenerate, or revert plan.md." Wait for decision.
- **`tasks.json` missing:** the script exits with an error. Run `lore work tasks "<slug>"` (generates the file), then re-run `lore work load-tasks`.

Report: "Loaded N tasks across M phases."

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
Run **list**. Show the script output directly — no additional processing or summarization.

---

## Fuzzy Matching (for load, set, archive, tasks, regen-tasks)

When a subcommand needs a slug but the user provided a name, resolve it:
1. **Exact slug** — exists in `_work/`
2. **Substring on title** — case-insensitive unique match
3. **Substring on slug** — unique match
4. **Tag match** — matches a tag value
5. **Branch match** — current git branch matches a work item's `branches`
6. **Recency** — most recently updated active item
7. **Archive fallback** — if all active steps above fail, check the `"archived"` array from `lore work list --json --all` and retry steps 1–3 against archived items; tag result as `[archived]` in output
8. **Ambiguous** — list candidates, ask user to pick

Read `_work/_index.json` for active resolution. Scripts accept exact slugs only.
