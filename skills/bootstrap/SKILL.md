---
name: bootstrap
description: "Bootstrap a knowledge store by exploring codebase architecture — use when starting with a new or empty project, seeding knowledge, or running /bootstrap"
user_invocable: true
argument_description: "Optional: directory paths to scope (e.g., src/auth src/api). Without args, scopes entire repo."
---

# /bootstrap Skill

Seeds a knowledge store by fan-out exploration of a codebase's architecture. Identifies domains (directories/modules), dispatches Explore agents to investigate each one in parallel, then synthesizes and files findings via `lore capture` at the lead level. All entries are filed at `confidence: medium` with `source: bootstrap`. Supports incremental execution — bootstrap specific directories now, others later — using plan.md checkboxes for progress tracking.

## Resolve Work Path

```bash
lore resolve
```
Set `KNOWLEDGE_DIR` to the result and `WORK_DIR` to `$KNOWLEDGE_DIR/_work`.

## Step 1: Scope

Run the scoping script to identify domains for exploration.

1. Parse arguments: if directory paths were provided (e.g., `/bootstrap src/auth src/api`), pass them to the script. Otherwise, scope the entire repo.
2. Run scoping:
   ```bash
   lore bootstrap scope [optional dir args...]
   ```
   Stdout: JSON array of domain objects `[{"path": "src/auth", "description": "...", "languages": ["Python"]}]`.
   Stderr: tree output for each scoped directory (useful context but not parsed).
3. Parse the JSON output. Present the domain list to the user:
   ```
   [bootstrap] Scoped N domains:
     1. src/auth — Authentication module (Python)
     2. src/api — API layer (Node.js)
     3. lib/ — Library modules
     ...
   Add, remove, or merge domains? (Enter to proceed)
   ```
4. Allow the user to adjust: add new paths, remove irrelevant ones (e.g., `vendor/`, `dist/`), or merge related directories into a single domain. Wait for confirmation before proceeding.

## Step 2: Team Setup

Create the agent team and one task per domain.

1. **Check for existing work item:** Look for a `bootstrap-*` work item in `$WORK_DIR/`. If found, load it for resume (see "Resuming a Bootstrap" below). If not found, create one:
   ```bash
   lore work create "Bootstrap <repo-name>" --tags bootstrap
   ```
   Set `SLUG` to the resulting slug.

2. **Create the team** (MUST precede TaskCreate):
   ```
   TeamCreate: team_name="bootstrap-<SLUG>", description="Bootstrapping knowledge for <repo-name>"
   ```

3. **Read your team lead name** from `~/.claude/teams/bootstrap-<SLUG>/config.json`.

4. **Create one task per domain** using the scoping JSON:
   ```
   TaskCreate:
     subject: "Explore: <domain path>"
     description: |
       Explore the <domain path> directory and report architectural findings.

       **Scope:** <domain path>
       **Languages:** <languages array from scoping, e.g., ["Python", "Node.js"]>
       **Description:** <description from scoping JSON>

       Investigate and report:
       - Architecture: how is this module/directory structured? What are the layers?
       - Key patterns: design patterns, conventions, idioms used
       - Entry points: main files, exports, public API surface
       - Data flow: how data moves through this module
       - Dependencies: internal (what other parts of the codebase does this depend on) and external (third-party packages)
       - Key files: the most important files with brief descriptions

       **Report format:** Send findings to "<team-lead-name>" via SendMessage with:
       **Domain:** <path>
       **Architecture:** (bullets)
       **Key patterns:** (bullets)
       **Entry points:** (bullets)
       **Data flow:** (1-2 sentences)
       **Dependencies:** internal: ..., external: ...
       **Key files:** (paths with descriptions)

       **IMPORTANT:** Do NOT call `lore capture`. Report findings only — the lead handles all filing.
     activeForm: "Exploring <domain path>"
   ```

5. **Set up phase dependencies:** Domains are independent — no cross-domain blocking. All tasks can run in parallel.

## Step 3: Explorer Prompts

Spawn Explore agents to investigate each domain in parallel.

1. **Pre-fetch knowledge per domain** — before constructing prompts:
   ```bash
   PRIOR_KNOWLEDGE=$(lore prefetch "<domain path>" --format prompt --limit 5)
   ```

2. **Get directory tree for each domain:**
   ```bash
   DOMAIN_TREE=$(tree -L 3 --dirsfirst -I 'node_modules|.git|vendor|__pycache__|dist|build|.next|target|coverage' <domain-path>)
   ```

3. **Spawn agents** — launch `min(domain_count, 4)` agents in a single message:
   ```
   Task:
     subagent_type: "general-purpose"
     model: "sonnet"
     team_name: "bootstrap-<SLUG>"
     name: "explorer-N"
     mode: "bypassPermissions"
     prompt: |
       You are explorer-N on the bootstrap-<SLUG> team.

       <embed $PRIOR_KNOWLEDGE here>

       ## Directory Structure
       <embed $DOMAIN_TREE here>

       ## Workflow
       1. Call TaskList to see available exploration tasks
       2. Claim one: TaskUpdate with owner=your name, status=in_progress
       3. Read the full task with TaskGet
       4. Explore the domain using Glob, Grep, Read:
          - Start with entry points and key files
          - Read enough code to understand architecture, not every line
          - Focus on: structure, patterns, conventions, data flow, dependencies
       5. Send findings to "<team-lead-name>" via SendMessage:
          summary: "Findings: <domain path>"
          content: |
            **Domain:** <path>
            **Architecture:**
            - <structural observations>
            **Key patterns:**
            - <design patterns, conventions, idioms>
            **Entry points:**
            - <main files, exports, public API>
            **Data flow:** <how data moves>
            **Dependencies:**
            - Internal: <other modules this depends on>
            - External: <third-party packages>
            **Key files:**
            - <path>: <description>
            **Observations:**
            - <patterns that span beyond this domain, anything surprising or non-obvious>

          **IMPORTANT:** Do NOT call `lore capture` — report findings only.
       6. Mark task completed: TaskUpdate with status=completed
       7. Call TaskList — claim next unclaimed task if available
       8. When no tasks remain, you're done

       Keep findings to 500-1500 characters. Facts over opinions.
       Focus on what a developer new to this codebase would need to know.
   ```

4. If more domains than agents, agents pick up additional tasks after completing their first (self-service model).

## Step 4: Collection

Persist findings as they arrive for synthesis.

1. As explorer messages arrive (delivered automatically), **write each to `findings.md`** in the work item directory (`$WORK_DIR/<SLUG>/findings.md`):
   ```markdown
   ## <Domain Path>
   **Explored by:** explorer-N
   **Timestamp:** <ISO timestamp>

   <paste the full findings report from the agent>

   ---
   ```
   Append each finding — `findings.md` is the durable record that survives compaction.

2. When all exploration tasks are complete:
   - Send `shutdown_request` to all explorer agents via SendMessage
   - Run `TeamDelete` to clean up the team
   - Proceed to Step 5

## Step 5: Synthesis

Group findings by theme, flag contradictions, and draft knowledge entries.

1. **Read `findings.md`** from the work item directory.

2. **Group by theme, not just domain.** Findings often reveal cross-cutting patterns:
   - Domain-specific architecture → files to `domains/<area>` category
   - Cross-cutting conventions (error handling, logging, testing patterns) → files to `conventions/` category
   - Architectural patterns (data flow, layering, service boundaries) → files to `architecture/` category
   - Gotchas and non-obvious behaviors → files to `gotchas/` category

3. **Flag contradictions:** Check for cases where two agents describe the same file, pattern, or module differently. List contradictions explicitly:
   ```
   [contradiction] explorer-1 says auth uses middleware pattern, explorer-3 says auth uses decorator pattern
   → Verify: read src/auth/index.ts to resolve
   ```
   Resolve contradictions by reading the relevant files before filing.

4. **Draft entry list.** For each finding that meets the (relaxed) bootstrap gate:
   - **Reusable** beyond a single task? (yes — bootstrap targets architectural knowledge)
   - **Non-obvious** to someone new? (the whole point of bootstrap)
   - **Stable** enough to be worth filing? (skip anything that looks mid-refactor)

   Draft each entry with:
   ```
   Title: <concise insight title>
   Insight: <1-3 sentence description>
   Category: <domains/<area> | conventions | architecture | gotchas>
   Related files: <key file paths>
   ```

5. **Deduplicate:** If multiple agents reported the same pattern, merge into a single entry with the best description. Do not create duplicate entries.

## Step 6: Filing

Present entries to the user and file approved ones.

1. **Present the entry list** to the user for review:
   ```
   [bootstrap] Synthesized N entries from M domains:

   1. [domains/auth] "Auth uses middleware chain pattern"
      → src/auth/middleware.ts, src/auth/index.ts
   2. [conventions] "All API routes follow controller-service-repo layering"
      → src/api/users/controller.ts, src/api/users/service.ts
   3. [gotchas] "Database migrations must run before seed scripts"
      → scripts/migrate.sh, scripts/seed.sh
   ...

   Accept all, or specify numbers to reject/edit? (e.g., "drop 3, edit 2")
   ```

2. **Process user feedback:** Remove rejected entries, apply edits.

3. **File approved entries** — serialize all `lore capture` calls (one at a time, not concurrent):
   ```bash
   lore capture --insight "<insight text>" --context "Discovered during bootstrap of <repo>" --category "<category>" --confidence "medium" --related-files "<comma-separated paths>"
   ```

4. **Run heal once** after all captures:
   ```bash
   lore heal
   ```

## Step 7: Spot-Check

Verify a random sample of filed entries against actual code.

1. Pick 3 random entries from the set just filed.
2. For each entry, read the `related_files` listed in the entry.
3. Verify the claims are accurate — does the code actually do what the entry says?
4. Report results:
   ```
   [bootstrap] Spot-check (3/N entries):
     "Auth middleware chain" — verified, src/auth/middleware.ts exports chain at L45
     "Controller-service layering" — verified, pattern holds in 4/4 sampled routes
     "DB migrations before seeds" — INACCURATE: seed.sh actually checks migration status first
   ```
5. If any entry is inaccurate, offer to correct or remove it. This step is advisory — it does not block completion.

## Step 8: Cleanup

Wrap up the bootstrap session.

1. **Update work item notes** with a session summary:
   ```bash
   # Append to notes.md
   ```
   ```markdown
   ## YYYY-MM-DDTHH:MM
   **Focus:** Bootstrap via /bootstrap
   **Domains explored:** <list>
   **Entries filed:** N entries across M categories
   **Contradictions found:** <count and brief descriptions, or "none">
   **Spot-check:** <pass/fail summary>
   **Next:** <remaining domains if partial, or "Bootstrap complete">
   ```

2. **Check off completed phases** in `plan.md` — each bootstrapped domain's scope task gets marked `[x]`.

3. **If all domains are bootstrapped:**
   - Archive the work item: `lore work archive "<SLUG>"`

4. **If partial completion** (some domains remain):
   - Leave the work item active for later `/bootstrap` resumption
   - Run `lore work heal`

5. **Report to user:**
   ```
   [bootstrap] Done.
   Domains explored: N
   Entries filed: M (confidence: medium, source: bootstrap)
   Spot-check: K/3 verified
   Remaining: <list if any, or "none — bootstrap complete">
   ```

## Resuming a Bootstrap

When `/bootstrap` is called and an existing `bootstrap-*` work item is found:

1. Read `findings.md` and `plan.md` to determine which domains are already bootstrapped (checked phases).
2. Re-run scoping (`bootstrap-scope.sh`) to detect any new directories since the last run.
3. Present the current state:
   ```
   [bootstrap] Resuming — found existing bootstrap work item.
   Already explored: src/auth, src/api, lib/
   New/remaining: src/workers, tests/
   Proceed with remaining domains? (or specify different scope)
   ```
4. User confirms scope. Proceed from Step 2 with only the unchecked/new domains.
5. New findings append to existing `findings.md`. New entries go through the same synthesis/filing/spot-check flow.
