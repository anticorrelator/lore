---
name: bootstrap
description: "Bootstrap a knowledge store by exploring codebase architecture — use when starting with a new or empty project, seeding knowledge, or running /bootstrap"
user_invocable: true
argument_description: "[--model opus|sonnet] [directory paths] — optional directory paths to scope (e.g., src/auth src/api); without paths, scopes entire repo"
---

# /bootstrap Skill

Seeds a knowledge store with the **map and seams** of a codebase: what subsystems exist, what each owns, and what crosses between them. The lead first builds a project sketch (kind, paradigm, vocabulary, candidate seams), then dispatches Explore agents per subsystem with a project-aware brief targeting architecture and subsystem scale — not implementation, not gotchas. Findings file via `lore batch-capture` at `confidence: medium`, `source: bootstrap`. Incremental: bootstrap some subsystems now, others later, tracked via `plan.md` checkboxes.

## Resolve Work Path

```bash
lore resolve
```
Set `KNOWLEDGE_DIR` to the result and `WORK_DIR` to `$KNOWLEDGE_DIR/_work`.

### Step 1: Scope

Identify candidate domains.

1. Parse arguments: extract optional `--model` flag (`opus` or `sonnet`, default `sonnet`) — use it as `<selected-model>` for every agent spawn below. If directory paths were provided (e.g., `/bootstrap src/auth src/api`), pass them through; otherwise scope the entire repo.
2. Run scoping:
   ```bash
   lore bootstrap scope [optional dir args...]
   ```
   Stdout: JSON array `[{"path": "src/auth", "description": "...", "languages": ["Python"]}]`. Stderr: tree output (context, not parsed).
3. Present the domain list:
   ```
   [bootstrap] Scoped N domains:
     1. src/auth — Authentication module (Python)
     2. src/api — API layer (Node.js)
     ...
   Add, remove, or merge? (Enter to proceed)
   ```
4. Wait for confirmation. The comprehension pass in Step 2 may reshape this list further.

### Step 2: Comprehend

Build a project sketch before fan-out. The sketch shapes every agent's brief.

1. **Find or create the work item.** Look for a `bootstrap-*` work item in `$WORK_DIR/`. If present, load for resume (see "Resuming"). Otherwise:
   ```bash
   lore work create --title "Bootstrap <repo-name>" --tags bootstrap
   ```
   Set `SLUG` to the result.

2. **Read the top-level shape** — pick from what exists, don't grep deep:
   - README and top-level docs (`README*`, `ARCHITECTURE*`, `docs/README*`)
   - Top-level entry points (`main.*`, `index.*`, `cmd/`, `bin/`)
   - Manifest (`package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, etc.)
   - Top-level interface definitions (proto files, OpenAPI specs, public type packages)

3. **Write the sketch** to `$WORK_DIR/<SLUG>/findings.md`:
   ```markdown
   ## Project Sketch
   **Kind:** <CLI tool / web service / library / framework / monorepo / data pipeline / ...>
   **Paradigm:** <event-driven / request-response / pipeline / state machine / plugin host / ...>
   **Stated purpose:** <one sentence, ideally from the README>
   **Project vocabulary:** <terms the project uses for its own concepts — agents should reuse these, not import generic terms>
   **Candidate seams:** <where subsystems meet — public APIs, schemas, message formats, hook/plugin registries, data stores>
   ```

4. **Reshape the domain list if the sketch suggests it.** Subsystems may cross or merge directory boundaries — e.g., an HTTP surface spanning `src/api` + `src/handlers`, a settings subsystem split across `config/` + `src/settings`. Present any reshape with rationale:
   ```
   [bootstrap] Sketch suggests subsystems differ from directory scoping:
     · "HTTP surface" merges src/api + src/handlers (shared route + middleware contracts)
     · "Auth" matches src/auth as-is
   Confirm? (Enter to proceed, or specify edits)
   ```
   The confirmed list defines the **subsystems** for the rest of the run.

### Step 3: Team Setup

Create the team and one task per subsystem.

1. **Create the team** (MUST precede TaskCreate):
   ```
   TeamCreate: team_name="bootstrap-<SLUG>", description="Bootstrapping knowledge for <repo-name>"
   ```

2. **Read your team lead name** from the active harness's teams install path (`resolve_harness_install_path teams`; typically `~/.claude/teams/bootstrap-<SLUG>/config.json`). This skill requires `team_messaging=full` per `adapters/capabilities.json.skills.bootstrap.requires`.

3. **Create one task per subsystem:**
   ```
   TaskCreate:
     subject: "Explore: <subsystem name>"
     description: |
       Investigate <subsystem name> (paths: <paths>, languages: <langs>) and report at
       architecture/subsystem scale per the worker brief in Step 4. Map boundaries,
       contracts, and shapes. Do NOT report gotchas, line-level behavior, or
       implementation details. Do NOT call `lore capture` — the lead files everything.
     activeForm: "Exploring <subsystem name>"
   ```

4. Subsystems are independent — all tasks run in parallel.

### Step 4: Explore

Spawn agents and collect findings.

1. **Per subsystem, prefetch knowledge:**
   ```bash
   PRIOR_KNOWLEDGE=$(lore prefetch "<subsystem name>" --format prompt --limit 5 --scale-set=architecture,subsystem)
   ```

2. **Per subsystem, get a directory tree:**
   ```bash
   DOMAIN_TREE=$(tree -L 3 --dirsfirst -I 'node_modules|.git|vendor|__pycache__|dist|build|.next|target|coverage' <paths>)
   ```

3. **Spawn `min(subsystem_count, 4)` agents in a single message:** read `skills/bootstrap/templates/explorer-prompt.md` for the Task spawn block and prompt scaffold (Project Sketch + Prior Knowledge + Subsystem Structure + Mission + Out-of-scope + Workflow). Embed `$PRIOR_KNOWLEDGE` and `$DOMAIN_TREE` into each spawn.

4. **As messages arrive, append to `$WORK_DIR/<SLUG>/findings.md`:**
   ```markdown
   ## <Subsystem name>
   **Explored by:** explorer-N  
   **Timestamp:** <ISO>

   <full report>

   ---
   ```
   `findings.md` is the durable record that survives compaction.

5. When all tasks complete: `shutdown_request` to all explorers, then `TeamDelete`. Proceed to Step 5.

### Step 5: Synthesize

Group findings by theme, flag contradictions, draft entries.

1. Read `findings.md` (including the sketch).

2. **Group by theme** — cross-cuts often emerge:
   - Subsystem-internal map → `domains/<area>` or `architecture/`
   - Cross-subsystem contracts (data shapes, message formats, error protocols shared across subsystems) → `architecture/` or `architectural-models/`
   - Project-wide conventions (layering pattern, dependency direction, naming of seams) → `cross-cutting-conventions/`

3. **Flag contradictions** between explorer reports. Resolve by reading the file at issue before filing.

4. **Draft entries** — bootstrap drafts eagerly; Step 6 prunes.

   **Gate (all must hold):**
   - **Reusable** — claim survives beyond a single task.
   - **Stable** — not mid-refactor.
   - **Scale-fit** — passes the architecture substitution test (drop concrete proper nouns and the claim still reads as "A does B, C does D"), OR names a bounded subsystem and describes its internal shape. If the claim dies when you remove a function/file/line name, it's implementation-scale and does NOT belong here.

   "Non-obvious" is **not** a bootstrap condition. Architectural facts that read as obvious-once-stated are still valuable — they compress many files into one claim, survive implementation rewrites, and prime search before code reading.

   Each entry:
   ```
   Title: <concise, scannable>
   Insight: <1-3 sentences>
   Category: <domains/<area> | architecture | architectural-models | cross-cutting-conventions>
   Related files: <entry points and contract definitions only>
   ```

5. **Deduplicate** — merge multi-explorer overlaps into single entries.

### Step 6: File

1. Present the entry list:
   ```
   [bootstrap] Synthesized N entries from M subsystems:
     1. [architecture] "<title>" → <files>
     ...
   Prune freely. (e.g., "drop 3, edit 2")
   ```

2. Apply user feedback. Write approved entries to `$WORK_DIR/<SLUG>/_batch_entries.json` — one object per entry, fields match `lore capture` flags:
   ```json
   [{"insight": "...", "context": "Discovered during bootstrap of <repo>", "category": "<cat>", "confidence": "medium", "related_files": "<csv>"}]
   ```

3. File:
   ```bash
   lore batch-capture --file "$WORK_DIR/<SLUG>/_batch_entries.json"
   ```
   On success delete `_batch_entries.json`. On failure retain the file; prompt the user to retry with the same command; do not proceed to heal until resolved.

4. Run `lore heal` regardless of partial failure.

### Step 7: Spot-Check

Verify the **map matches the territory** — sample architectural claims, not file/line claims.

1. Pick 3 random entries from the set just filed.
2. Read the related files. Verify the claimed boundaries hold, the claimed contracts exist, the claimed shapes flow as described.
3. Report:
   ```
   [bootstrap] Spot-check (3/N entries):
     "HTTP surface owns route + middleware contracts" — verified
     "Settings flow through SettingsRegistry" — INACCURATE: two paths bypass the registry
     ...
   ```
4. Offer to correct or remove inaccurate entries. Advisory — does not block completion.

### Step 8: Cleanup

1. Append to `notes.md`:
   ```markdown
   ## YYYY-MM-DDTHH:MM
   **Focus:** Bootstrap via /bootstrap
   **Subsystems explored:** <list>
   **Entries filed:** N across M categories
   **Contradictions:** <count or "none">
   **Spot-check:** <pass/fail summary>
   **Next:** <remaining subsystems, or "Bootstrap complete">
   ```

2. Check off completed phases in `plan.md`.

3. **All subsystems done** → `lore work archive "<SLUG>"`. **Partial completion** → leave active; run `lore work heal`.

4. Report:
   ```
   [bootstrap] Done.
   Subsystems explored: N
   Entries filed: M (confidence: medium, source: bootstrap)
   Spot-check: K/3 verified
   Remaining: <list, or "none">
   ```

## Resuming a Bootstrap

When `/bootstrap` is called and a `bootstrap-*` work item exists:

1. Read `findings.md` (including the project sketch) and `plan.md` to determine completed subsystems.
2. Re-run `lore bootstrap scope` to detect new directories.
3. Present current state:
   ```
   [bootstrap] Resuming.
   Sketch: <kind>, <paradigm>
   Already explored: <list>
   New/remaining: <list>
   Proceed? (or specify edits)
   ```
4. User confirms. Proceed from Step 3 (Team Setup) with remaining subsystems. New findings append to existing `findings.md`; the existing sketch is preserved unless the user explicitly updates it.
