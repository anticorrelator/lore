---
name: explore-and-plan
description: Manage per-project plans — create, resume, update, archive, search, design with divide-and-conquer investigations, and generate tasks
user_invocable: true
argument_description: "[command] [args] — create <name> | list | update | archive [name] | search <query> | tasks [name] | design [name] | heal"
---

# /explore-and-plan Skill

Manages per-project plans at `~/.project-knowledge/repos/<repo>/_plans/`.

## Resolve Plan Path

First, resolve the knowledge and plans directories:
```bash
bash ~/.project-knowledge/scripts/resolve-repo.sh
```
Set `KNOWLEDGE_DIR` to the result and `PLANS_DIR` to `$KNOWLEDGE_DIR/_plans`.

If `_plans/` doesn't exist and the command is NOT `create`, tell the user: "No plans found for this project. Use `/explore-and-plan create <name>` to start one."

## Plan Resolution (Fuzzy Matching)

Many commands accept a plan name. Resolve it with this algorithm, in order:

1. **Exact slug match** — user typed a slug that exists in `_plans/`
2. **Substring match on title** — `auth` uniquely matches "Auth Service Refactor" (case-insensitive)
3. **Substring match on slug** — `auth` matches `auth-service-refactor`
4. **Tag match** — `auth` matches a plan tagged "authentication"
5. **Branch match** — no name given, current git branch matches a plan's `branches` array
6. **Recency** — no name, no branch match → suggest most recently updated active plan
7. **Ambiguous** — multiple matches → list candidates, ask user to pick

To check the current git branch:
```bash
git rev-parse --abbrev-ref HEAD 2>/dev/null
```

## Slugify Names

When creating plans, convert the name to a slug:
- Lowercase
- Replace spaces and special characters with hyphens
- Collapse multiple hyphens into one
- Strip leading/trailing hyphens

## Commands

Parse the user's arguments to determine which command to run.

### `/explore-and-plan create <name>`

Create a new plan:

1. Resolve knowledge dir; if `_plans/` doesn't exist, run `bash ~/.project-knowledge/scripts/init-plans.sh`
2. Slugify the name
3. Check that the slug doesn't already exist in `_plans/`
4. Create the directory: `_plans/<slug>/`
5. Get the current git branch (if in a git repo)
6. Write `_plans/<slug>/_meta.json`:
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
7. Write `_plans/<slug>/notes.md`:
   ```markdown
   # Session Notes: <Title>

   <!-- Append session entries below. Each entry records what happened in a session. -->
   ```
8. **Do NOT create plan.md** — it's created on demand via `/explore-and-plan design`
9. Run `bash ~/.project-knowledge/scripts/update-plan-index.sh`
10. Report: "Created plan '<title>'. Use `/explore-and-plan design` when ready to add structured planning."

### `/explore-and-plan design [name]`

Orchestrate divide-and-conquer planning using parallel subagent investigations.

#### Step 1: Resolve and prepare

1. Resolve plan (fuzzy match or branch inference)
2. If `plan.md` already exists, read it:
   - If it has an `## Investigations` section with completed findings, skip to **Step 4 (Synthesize)**
   - If it has investigations but `## Open Questions` list items needing follow-up, go to **Step 3** with targeted questions
   - Otherwise, present it for discussion/editing
3. If `plan.md` doesn't exist, create it with the initial scaffold (see template below)

#### Step 2: Decompose into investigations

1. From the feature description (user-provided or conversation context), identify 3-7 focused investigation questions. Each question should:
   - Target a specific part of the codebase or a specific concern
   - Be answerable by exploring files (not by asking the user)
   - Be independent enough to run in parallel
2. Check the knowledge store index (`_index.md`, `_manifest.json`) for file hints to include with each investigation
3. Present the investigation plan to the user:
   ```
   I'll investigate these areas in parallel:
   1. <Question 1> — will look at <file hints>
   2. <Question 2> — will look at <file hints>
   ...
   Proceed, or adjust?
   ```
4. Wait for user confirmation before dispatching

#### Step 3: Investigate in parallel

Dispatch one Explore subagent per investigation question using the Task tool. **Launch all subagents in a single message** for true parallelism.

Each subagent prompt should follow this structure:
```
Investigate: <question>

Context: <1-2 sentences about the broader feature being planned>
Start with: <file hints from knowledge index, glob patterns, or known entry points>

Return your findings in this exact format:
---
**Question:** <the question>
**Findings:**
- <key finding 1>
- <key finding 2>
- ...
**Key files:** <paths to the most relevant files>
**Implications:** <how this affects the design, 1-2 sentences>
**Unknowns:** <anything you couldn't determine>
---

Keep findings to 500-1000 characters. Focus on facts relevant to the design, not code details.
```

Important:
- Use `subagent_type: "Explore"` for each investigation
- Use `model: "sonnet"` for cost efficiency (investigations are research, not design)
- Do NOT perform the investigations yourself — the whole point is to keep raw code out of the orchestrator's context

#### Step 4: Document findings

As subagent results return, write them to the `## Investigations` section of `plan.md`:

```markdown
## Investigations

### <Topic 1>
**Question:** <what was investigated>
**Findings:**
- Finding 1
- Finding 2
**Key files:** `path/to/file.ts`, `path/to/other.ts`
**Implications:** How this affects the design

### <Topic 2>
...
```

This is the critical step — findings are persisted to the plan file as external memory. They survive compaction, session boundaries, and context limits.

#### Step 5: Synthesize

From the documented findings, draft the remaining plan sections:

1. **Overview** — Goal and high-level approach (1 paragraph)
2. **Design Decisions** — Key architectural choices with rationale, informed by investigation findings
3. **Phases** — Concrete implementation phases with tasks, file paths, and objectives
4. **Open Questions** — Anything the investigations couldn't resolve

Present the synthesized plan to the user for review.

#### Step 6: Iterate (if needed)

If the user (or you) identifies gaps:
- Dispatch targeted follow-up investigations (same subagent pattern, narrower scope)
- Append new findings to the Investigations section
- Update the synthesis

#### Plan.md template

```markdown
# <Plan Title>

## Goal
<!-- One paragraph: what we're building/changing and why -->

## Investigations
<!-- Findings from divide-and-conquer exploration — persisted for cross-session continuity -->
<!-- Each investigation answers a specific question about the codebase -->

## Design Decisions
<!-- Key architectural choices with rationale, informed by investigation findings -->

## Phases

### Phase 1: <Name>
**Objective:** What this phase accomplishes
**Files:** relevant file paths
- [ ] Task 1
- [ ] Task 2

## Open Questions
- Unresolved decisions or items needing follow-up investigation

## Related
- [[knowledge:file#heading]] — cross-references to knowledge store
```

#### Resuming a design across sessions

When `/explore-and-plan design` is called on a plan that already has investigations:
- Read the existing investigations — they are your context (no need to re-explore)
- Check if the synthesis (Design/Phases) is complete; if not, synthesize from existing findings
- Check Open Questions — dispatch follow-up investigations for unresolved items
- Present the current state to the user and ask what needs refinement

Run `bash ~/.project-knowledge/scripts/update-plan-index.sh` after any changes.

### `/explore-and-plan [name]` (load/resume — default when name given or no command matches)

Load a plan's context:

1. Resolve plan using the fuzzy matching algorithm above
2. Read `_meta.json` for status, branches, tags
3. If `plan.md` exists, read it (full content)
4. Read the last 2-3 session entries from `notes.md`:
   - Find the last 2-3 `## ` headings in the file
   - Read from the third-to-last `## ` heading to end of file
5. Present a summary:
   - Title, status, branches, tags
   - Last session progress and next steps (from notes)
   - If `plan.md` exists: overview, current phase, open questions
   - If `plan.md` doesn't exist: mention `/explore-and-plan design` is available
6. Update `_meta.json` `updated` timestamp

### `/explore-and-plan list`

List all plans:

1. Read `_plans/_index.json`
2. If index is missing or stale, run `bash ~/.project-knowledge/scripts/update-plan-index.sh` first
3. Show active plans in a table/list:
   - Slug, title, status, branches, last updated, has plan doc
4. Count archived plans in `_plans/_archive/`:
   ```bash
   ls -d _plans/_archive/*/ 2>/dev/null | wc -l
   ```
5. Show: "N archived plans (`/explore-and-plan search` covers archived)"

### `/explore-and-plan update`

Capture session progress to notes:

1. Determine current plan:
   - If a plan was loaded via `/explore-and-plan` earlier in this conversation, use that one
   - Otherwise, try to infer from current git branch
   - If no plan identified, ask the user which plan or suggest creating one
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
6. If `plan.md` exists and task checkboxes were completed this session, update them (`- [ ]` → `- [x]`)
7. Run `bash ~/.project-knowledge/scripts/update-plan-index.sh`

### `/explore-and-plan archive [name]`

Archive a completed plan:

1. Resolve plan (fuzzy match)
2. Confirm with user: "Archive '<title>'? This moves it to _archive/."
3. Wait for user confirmation before proceeding
4. Read `_meta.json` and update `status` to `"completed"` and `updated` to now
5. Write the updated `_meta.json`
6. Move the plan directory:
   ```bash
   mv "$PLANS_DIR/<slug>" "$PLANS_DIR/_archive/<slug>"
   ```
7. Run `bash ~/.project-knowledge/scripts/update-plan-index.sh`
8. Report: "Archived plan '<title>'"

### `/explore-and-plan search <query>`

Search across all plan documents:

1. Run `bash ~/.project-knowledge/scripts/search-plans.sh "<query>"`
2. For the top matches, read the relevant sections and present a summary
3. Include both active and archived results (mark archived)

### `/explore-and-plan tasks [name]`

Generate TaskCreate calls from plan phases:

1. Resolve plan, read `plan.md`
2. If no `plan.md` exists, tell the user: "No structured plan doc found. Run `/explore-and-plan design` first to add phases and tasks."
3. Read the knowledge directory path for cross-reference links
4. For each `### Phase N:` section that contains `- [ ]` (unchecked) items:
   - For each unchecked `- [ ]` item, generate a TaskCreate call with:
     - `subject`: Imperative task title derived from the checkbox text
     - `description`: Detailed context including:
       - The phase objective from the `**Objective:**` line
       - Relevant file paths from the `**Files:**` line
       - Knowledge store cross-references: "See `<knowledge-dir>/<file>.md` heading '### <heading>' for context"
       - Plan file reference: "Full design at `<plans-dir>/<slug>/plan.md` Phase N"
       - Acceptance criteria derived from the checkbox text and phase context
     - `activeForm`: Present continuous form of the task (e.g., "Implementing auth middleware")
   - Set up dependencies: tasks from Phase 2 should have `addBlockedBy` referencing Phase 1 task IDs
5. Skip already-checked `- [x]` items
6. Report: "Generated N tasks across M phases with dependencies"

### `/explore-and-plan heal`

Repair plan structure:

1. Resolve plans dir
2. Check for and repair these issues:
   - **Missing `_index.json`**: Run `bash ~/.project-knowledge/scripts/update-plan-index.sh`
   - **Orphan directories** (subdirectory of `_plans/` with no `_meta.json`): Create `_meta.json` from directory name as slug/title, status "active", current timestamp
   - **Stale index** (plan count in index doesn't match directories): Run `update-plan-index.sh`
   - **Missing `notes.md`**: Create with header from `_meta.json` title
   - **Plans inactive >30 days**: Report them, suggest archiving
3. Run `bash ~/.project-knowledge/scripts/update-plan-index.sh`
4. Report all findings and repairs

### No arguments

Infer action from context:

1. If on a git branch that matches an active plan → load that plan (same as `/explore-and-plan <name>`)
2. If a plan was loaded earlier in this conversation → show its current status
3. Otherwise → run `/explore-and-plan list`
