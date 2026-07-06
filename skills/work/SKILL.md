---
name: work
description: "Check project status, remaining tasks, and session context — USE FIRST when asked 'what's left', 'what should I do', 'remaining work', or status questions. Also: create, update, archive, search work items."
user_invocable: true
argument_description: "[command] [name] — commands: create, list, update, set, archive, search, project, tasks, regen-tasks, heal"
---

# /work Skill

Manages per-project work items via script calls. Most subcommands are a single `bash` call — run the script and show the output.

## Route $ARGUMENTS

Match the first word of `$ARGUMENTS` to a command below. If no command matches but a name/slug is given, treat it as **load**. If `$ARGUMENTS` is empty, see **No arguments**.

---

### `create <name> [--issue <value>] [--pr <value>] [--project <name>] [--intent-anchor <text>]`
```bash
lore work create --title "<name>" [--intent-anchor "<interpreted capability statement>"] [--issue "<value>"] [--pr "<value>"] [--project "<name>"]
```
**Before running:** Titles must be ≤70 characters (same as git/PR title convention). Keep it concise — 3–6 words that identify the goal, not a sentence. The slug is generated from the title (stopwords stripped, kebab-cased, capped at 50 chars). Good: `"TUI Mouse Click Focus"`. Bad: `"Add Mouse Click To Focus Panel In TUI When User Clicks"`.

**Intent anchor:** Pass `--intent-anchor` with an **interpreted one-sentence capability statement** that names the user-visible outcome the work item must deliver. Then audit your candidate anchor for **looseness** — any property that would let `/spec` or `/implement` ship a narrower reading and call it done:

- **Alternatives** ("X or Y" lets a downstream cycle ship only X or only Y). Pick the load-bearing one, or fold both into a single requirement.
- **Comparatives without targets** ("better," "faster," "cleaner" with no acceptance bar). Name what counts as the bar.
- **Vague verbs** ("support," "improve," "handle" without naming the input or the bar). Name what specifically gets supported/improved/handled to what bar.
- **Meta-instruction degenerate case** — the user's input names *creating the work item* ("make a work item for that," "track this," "let's persist this") but no capability. Treat as 100% loose; the user has not stated the anchor yet.

When the candidate anchor is loose, **stop and ask** via `AskUserQuestion` to close the gap (which alternative is load-bearing? what's the acceptance bar? what specifically counts as "support"? in the meta-instruction case, what capability should this deliver?). Do NOT commit a loose anchor "for now" and plan to clarify in `/spec` — once stored, the anchor flows through downstream preservation gates unchanged, and a loose reading downstream will ship. Restate the final anchor in the create confirmation so the user can audit the translation.

Do not copy emotionally loaded or conversationally pressuring user text verbatim, and do not paraphrase away load-bearing intent. If the work item comes from an external issue, distill the issue's load-bearing request and run the same looseness audit. See `[[knowledge:conventions/protocol/work-item-intake-should-store-neutral-intent-ancho]]` for rationale and history of prior failed policies.

**Dedup:** The script rejects creation if the new slug overlaps with an existing slug (substring match). If this happens, use the existing item — do NOT retry with a different name for the same topic.

**Project grouping (create-time step):** Before running the script, check the existing workstreams: run `lore work list` — project labels render as section headers, and `_work/_projects/` records surface as sections even when they have no active members. Then decide:

- **Joins an existing effort** — the new item plausibly belongs to a workstream already on the list: pass `--project` with that existing label verbatim. Do not coin a near-variant; the script's near-match guard warns but never merges.
- **Starts a new multi-item effort** — the item is plausibly the first of several under one umbrella: coin a label and pass it. The value is slugified on write and the stored slug is also the display value — `--project "TUI Rework"` stores and renders as `tui-rework`.
- **Standalone** — no plausible workstream: omit the flag and leave the item ungrouped.

Ask the user only at a genuine fork — two existing labels are equally plausible, or joins-existing vs. starts-new genuinely cannot be resolved from the item's scope. Everything short of that is your call to make at create time; do not create ungrouped "for now" and defer assignment to later cleanup.

Pass `--issue` and `--pr` only when provided by the user; `--project` follows the grouping step above (a user-provided label always wins). Joining an **active** project is gate-free — that is the documented join. But naming a project whose identity is **archived** (a completed effort, surfaced only in `--all`/archive listings, not in the plain `lore work list`) is a hard error: either pass `--reuse-project` to knowingly continue it (which reactivates the project), or choose a different name. Show the script output. If it exits non-zero, show the error.

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
**Before calling the script**, resolve the name to an exact slug via `lore work resolve` (see "Resolving Names to Slugs" below). Show the script output, then add a brief summary: current phase, next steps, and whether `/spec` is available.

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
Resolve name to slug via `lore work resolve` (see "Resolving Names to Slugs" below), then confirm with user: "Archive '<title>'? This moves it to _archive/."

After confirmation:
```bash
lore work archive "<slug>"
```
Show the script output.

---

### `set <name> --issue <value> --pr <value> --project <name>`
Resolve name to slug via `lore work resolve` (see "Resolving Names to Slugs" below), then run:
```bash
lore work set "<slug>" --issue "<value>" --pr "<value>" --project "<name>"
```
All flags are optional — pass only what the user provided. Show the script output.

`--project` groups the item under a project label (slugified on write; the stored slug is the display value). Reassigning onto an **archived** project identity is a hard error — pass `--reuse-project` to knowingly continue it (which reactivates it), or choose a different name; reassigning onto an active label is gate-free. `--project ""` clears the item's project membership and bypasses the gate entirely.

---

### `project <show|describe|archive> <slug> [...]`
```bash
lore work project show "<slug>"
lore work project describe "<slug>" [--anchor "<text>"] [--status <active|done|archived>] [--description "<text>"] [--reuse]
lore work project archive "<slug>" [--yes]
```
A project record is a **directory home** at `_work/_projects/<slug>/`, mirroring the work-item substrate: `_meta.json` (slug, title, status, anchor, timestamps — the identity source of truth) + `overview.md` (the description body) + any freeform project-level documents you add.

Show the script output. `show` renders the home's `_meta` fields plus **every document in the home** (the same bag-of-files delivery as `lore work show`), followed by all members, active and archived. `describe` creates or updates the home — writing `_meta.json` + `overview.md`, omitted fields keeping their values; a legacy flat record migrates to the directory form on this touch. `archive` archives every active member and flips a pre-existing record's status to archived **in place** (the home does not move) — confirm with the user first, then pass `--yes`.

**Archived-name gate:** `describe` on a name whose identity is archived is a hard error unless you pass `--reuse`, which reactivates the project (status → active). The same gate guards `--project` on create/set, where the flag is `--reuse-project`. Both resolve two ways: reuse the archived identity knowingly, or choose a different name.

**Records are entity-on-demand:** run `describe` only when there is a real anchor or status worth declaring — typically when a spec reveals a workstream-level anchor, a project's status genuinely changes, or a multi-item arc opens and needs a home for its `/coordinate` ledger. Never run it automatically as a side effect of creating or grouping items: a project label works fine with no record behind it. And never put planning files in a project home — plans belong to work items. A project home holds **cross-item** documents (an overview, a coordination ledger spanning several items, design notes that outlive any single item); it never holds a work item's planning substrate (`plan.md`, `tasks.json`, `notes.md`). A project that needs a plan names an umbrella work item and plans there.

---

### `search <query>`
```bash
lore work search "<query>"
```
Show the script output. For the top matches, briefly summarize the relevant context.

**Scale rubric — declare explicitly at every retrieval surface:**

- **abstract** — portable principle, behavioral law, or design maxim. The claim survives generic-noun substitution: replace project-specific proper nouns with placeholders and the lesson still holds. Abstract entries make a *law*.
- **architecture** — project-level structure: decomposition, lifecycle, contracts, data model, invariants, cross-component flows, or major platform choices. Architecture entries make a *map*: "A does B, C does D, and E connects them."
- **subsystem** — local rule about one named area, feature, module, team, command family, integration, or workflow within a larger system. Concrete terms appear as participants in a local workflow rather than as the whole claim.
- **implementation** — concrete artifact fact: file, function, script, command, limit, field, test, line-level behavior. If removing the artifact name destroys the claim, classify here.

**Boundary tests:** abstract vs architecture — substitution test (does the claim survive replacing concrete proper nouns with generic placeholders, or does it become "A does B, C does D"?); architecture vs subsystem — whole-project structure or one bounded area?; subsystem vs implementation — can you state the rule without naming a specific function/file/line?

**±1 query pattern:** fixing a bug → `subsystem,implementation`; adding to a module → `subsystem,implementation`; modifying a component → `architecture,subsystem`; designing a feature → `abstract,architecture`.

---

### `tasks [name]`
Resolve name to slug via `lore work resolve` (see "Resolving Names to Slugs" below). If no `plan.md` exists, tell the user to run `/spec` first.

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
Resolve name to slug via `lore work resolve` (see "Resolving Names to Slugs" below). Regenerate `tasks.json` from the current `plan.md`.

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

## Workstream Stewardship

Grouping stays current because agents keep it current — the user should not have to assign items by hand. Whenever a listing or update puts the work map in front of you:

- **Ungrouped items forming a workstream** — when ungrouped items clearly belong with an existing grouped effort (or with each other), propose `lore work set <slug> --project <label>` for the items involved. Propose rather than silently apply — membership is visible state the user may have opinions about.
- **Scope moved between efforts** — when a work item's scope has migrated into a different effort, propose moving its membership the same way. `--project ""` clears membership entirely.

---

## Resolving Names to Slugs (for load, set, archive, tasks, regen-tasks)

When a subcommand needs a slug but the user provided a name, delegate to `lore work resolve`:

```bash
if RESULT=$(lore work resolve "$REF" --branch "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"); then
  SLUG=$(printf '%s' "$RESULT" | sed -n '1p')
  ARCHIVED=$(printf '%s' "$RESULT" | sed -n '2p')
else
  case $? in
    1) echo "No work item matches '$REF'." >&2; exit 1 ;;
    2) echo "Multiple work items match '$REF':" >&2
       # candidate list is already on stderr from the resolver
       # ask the user to pick via AskUserQuestion using those candidates
       exit 1 ;;
  esac
fi
```

`lore work resolve` exits 0 on a unique match (stdout: `<slug>\n<archived>\n`), 1 on no match, or 2 on ambiguity (candidates on stderr). For read-only loads, an `ARCHIVED=true` result can be surfaced silently with an `[archived]` tag in output; mutating subcommands (`archive`, `set`, `tasks`, `regen-tasks`) should treat archived items per their existing per-subcommand confirmation policy.

Scripts beyond `resolve` accept exact slugs only — always pass `$SLUG` after resolution.
