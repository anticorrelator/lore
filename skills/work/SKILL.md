---
name: work
description: "Check project status, remaining tasks, and session context — USE FIRST when asked 'what's left', 'what should I do', 'remaining work', or status questions. Also: create, update, archive, search work items."
user_invocable: true
argument_description: "[command] [name] — commands: create, list, update, archive, search, tasks, heal"
---

# /work Skill

Manages per-project work items at `~/.project-knowledge/repos/<repo>/_work/`.

## Resolve Work Path

First, resolve the knowledge and work directories:
```bash
bash ~/.project-knowledge/scripts/resolve-repo.sh
```
Set `KNOWLEDGE_DIR` to the result and `WORK_DIR` to `$KNOWLEDGE_DIR/_work`.

If `_work/` doesn't exist and the command is NOT `create`, tell the user: "No work items found for this project. Use `/work create <name>` to start one."

## Work Item Resolution (Fuzzy Matching)

Many commands accept a work item name. Resolve it with this algorithm, in order:

1. **Exact slug match** — user typed a slug that exists in `_work/`
2. **Substring match on title** — `auth` uniquely matches "Auth Service Refactor" (case-insensitive)
3. **Substring match on slug** — `auth` matches `auth-service-refactor`
4. **Tag match** — `auth` matches a work item tagged "authentication"
5. **Branch match** — no name given, current git branch matches a work item's `branches` array
6. **Recency** — no name, no branch match -> suggest most recently updated active work item
7. **Ambiguous** — multiple matches -> list candidates, ask user to pick

To check the current git branch:
```bash
git rev-parse --abbrev-ref HEAD 2>/dev/null
```

## Slugify Names

When creating work items, convert the name to a slug:
- Lowercase
- Replace spaces and special characters with hyphens
- Collapse multiple hyphens into one
- Strip leading/trailing hyphens

## Commands

Parse the user's arguments to determine which command to run.

### `/work create <name>`

Create a new work item:

1. Resolve knowledge dir; if `_work/` doesn't exist, run `bash ~/.project-knowledge/scripts/init-work.sh`
2. Slugify the name
3. Check that the slug doesn't already exist in `_work/`
4. Create the directory: `_work/<slug>/`
5. Get the current git branch (if in a git repo)
6. Write `_work/<slug>/_meta.json`:
   ```json
   {
     "slug": "<slug>",
     "title": "<Title Case Name>",
     "status": "active",
     "branches": ["<current-branch-if-available>"],
     "tags": [],
     "created": "<ISO-timestamp>",
     "updated": "<ISO-timestamp>",
     "related_knowledge": []
   }
   ```
   If no git branch is available, use an empty branches array.
7. Write `_work/<slug>/notes.md`:
   ```markdown
   # Session Notes: <Title>

   <!-- Append session entries below. Each entry records what happened in a session. -->
   ```
8. **Do NOT create plan.md** — it's created on demand via `/spec`
9. Run `bash ~/.project-knowledge/scripts/update-work-index.sh`
10. Report: "Created work item '<title>'. Use `/spec` when ready to add structured planning."

### `/work [name]` (load/resume — default when name given or no command matches)

Load a work item's context:

1. Resolve work item using the fuzzy matching algorithm above
2. Read `_meta.json` for status, branches, tags
3. If `plan.md` exists, read it (full content)
4. Read the last 2-3 session entries from `notes.md`:
   - Find the last 2-3 `## ` headings in the file
   - Read from the third-to-last `## ` heading to end of file
5. Present a summary:
   - Title, status, branches, tags
   - Last session progress and next steps (from notes)
   - If `plan.md` exists: overview, current phase, open questions
   - If `plan.md` doesn't exist: mention `/spec` is available
6. Update `_meta.json` `updated` timestamp

### `/work list`

List all work items:

1. Read `_work/_index.json`
2. If index is missing or stale, run `bash ~/.project-knowledge/scripts/update-work-index.sh` first
3. Show active work items in a table/list:
   - Slug, title, status, branches, last updated, has plan doc
4. Count archived work items in `_work/_archive/`:
   ```bash
   ls -d _work/_archive/*/ 2>/dev/null | wc -l
   ```
5. Show: "N archived work items (`/work search` covers archived)"

### `/work update`

Capture session progress to notes:

1. Determine current work item:
   - If a work item was loaded via `/work` earlier in this conversation, use that one
   - Otherwise, try to infer from current git branch
   - If no work item identified, ask the user which one or suggest creating one
2. Summarize the current session's work by reviewing the conversation context:
   - **Focus:** main topic of work this session
   - **Decisions:** key choices or decisions made
   - **Progress:** what was accomplished
   - **Next:** what to pick up next session
   - **Related:** links to knowledge store entries if relevant (`[[knowledge:file#heading]]`)
3. Present the summary to the user for review before writing
4. Append a new timestamped entry to `notes.md`:
   ```markdown
   ## YYYY-MM-DDTHH:MM
   **Focus:** <focus>
   **Decisions:** <decisions>
   **Progress:** <progress>
   **Next:** <next>
   **Related:** <related links>
   ```
5. Update `_meta.json` `updated` timestamp
6. If `plan.md` exists and task checkboxes were completed this session, update them (`- [ ]` -> `- [x]`)
7. Run `bash ~/.project-knowledge/scripts/update-work-index.sh`

### `/work archive [name]`

Archive a completed work item:

1. Resolve work item (fuzzy match)
2. Confirm with user: "Archive '<title>'? This moves it to _archive/."
3. Wait for user confirmation before proceeding
4. Read `_meta.json` and update `status` to `"completed"` and `updated` to now
5. Write the updated `_meta.json`
6. Move the work item directory:
   ```bash
   mv "$WORK_DIR/<slug>" "$WORK_DIR/_archive/<slug>"
   ```
7. Run `bash ~/.project-knowledge/scripts/update-work-index.sh`
8. Report: "Archived work item '<title>'"

### `/work search <query>`

Search across all work item documents:

1. Run `bash ~/.project-knowledge/scripts/search-work.sh "<query>"`
2. For the top matches, read the relevant sections and present a summary
3. Include both active and archived results (mark archived)

### `/work tasks [name]`

Generate TaskCreate calls from work item phases, using backlinks for context delivery.

1. Resolve work item, read `plan.md`
2. If no `plan.md` exists, tell the user: "No structured plan doc found. Run `/spec` first to add phases and tasks."
3. Resolve the knowledge directory path: `bash ~/.project-knowledge/scripts/resolve-repo.sh`
4. Scan the plan's `## Related` section and `## Design Decisions` for `[[...]]` backlinks relevant to each phase
5. For each `### Phase N:` section that contains `- [ ]` (unchecked) items:
   - For each unchecked `- [ ]` item, generate a TaskCreate call with:
     - `subject`: Imperative task title derived from the checkbox text
     - `description`: Detailed context including:
       - The phase objective from the `**Objective:**` line
       - Relevant file paths from the `**Files:**` line
       - **Context backlinks** — `[[knowledge:file#heading]]`, `[[work:slug]]`, or `[[thread:slug]]` references that provide implementation context. Include backlinks from the plan's Related section, Design Decisions, and any `See also:` references in relevant knowledge entries. Format as a "Context" section:
         ```
         ## Context (resolve before starting)
         Resolve these with: python3 ~/.project-knowledge/scripts/pk_search.py resolve <knowledge_dir> "<backlink>"

         - [[knowledge:architecture#Section Name]] — why this is relevant
         - [[work:work-slug]] — design decisions for this feature
         ```
       - Plan file reference: `[[work:<slug>]]` (agent can resolve for full design)
       - Acceptance criteria derived from the checkbox text and phase context
     - `activeForm`: Present continuous form of the task (e.g., "Implementing auth middleware")
   - Set up dependencies: tasks from Phase 2 should have `addBlockedBy` referencing Phase 1 task IDs
6. Skip already-checked `- [x]` items
7. Report: "Generated N tasks across M phases with dependencies"

**Why backlinks instead of inline context:** Backlinks are pointers — they resolve to fresh content at execution time. Inline context is a snapshot that goes stale. An agent resolving `[[knowledge:conventions#API Versioning]]` always gets the current version, not whatever was true when the task was created.

### `/work heal`

Repair work item structure:

1. Resolve work dir
2. Check for and repair these issues:
   - **Missing `_index.json`**: Run `bash ~/.project-knowledge/scripts/update-work-index.sh`
   - **Orphan directories** (subdirectory of `_work/` with no `_meta.json`): Create `_meta.json` from directory name as slug/title, status "active", current timestamp
   - **Stale index** (work item count in index doesn't match directories): Run `update-work-index.sh`
   - **Missing `notes.md`**: Create with header from `_meta.json` title
   - **Work items inactive >30 days**: Report them, suggest archiving
3. Run `bash ~/.project-knowledge/scripts/update-work-index.sh`
4. Report all findings and repairs

### No arguments

Infer action from context:

1. If on a git branch that matches an active work item -> load that work item (same as `/work <name>`)
2. If a work item was loaded earlier in this conversation -> show its current status
3. Otherwise -> run `/work list`
