---
name: bootstrap
description: "Bootstrap a knowledge store by exploring codebase architecture — use when starting with a new or empty project, seeding knowledge, or running /bootstrap"
user_invocable: true
argument_description: "[--domain <topic>] [directory paths] — directory paths scope the run (e.g., src/auth src/api); no arguments scopes the entire repo; --domain <topic> seeds one domain entry after a genuinely empty retrieval and is mutually exclusive with paths"
---

# /bootstrap Skill

Seeds a knowledge store with the **map and seams** of a codebase: what subsystems exist, what each owns, and what crosses between them. The lead builds a project sketch, dispatches explorers per subsystem at architecture/subsystem scale — not implementation, not gotchas — then synthesizes and files entries through the sanctioned capture writer with full provenance. Incremental: bootstrap some subsystems now, others later, via `plan.md` checkboxes.

Modes: **full repo** (no arguments) and **directory-scoped** (paths) run Steps 1–8; **`--domain <topic>`** runs the narrow-results track (§ Domain Track) and is mutually exclusive with paths — reject an invocation that passes both.

## Resolve Paths and Defaults

```bash
lore resolve
```

Set `KNOWLEDGE_DIR` to the result and `WORK_DIR` to `$KNOWLEDGE_DIR/_work`.

```bash
lore defaults
```

Binding, not advisory: role→model routes, harness selection, and standing preference directives come from this output. The skill takes no model arguments — every dispatch resolves its model through the role resolver, never a hardcoded alias.

Stamp provenance from content hashes:

```bash
LEAD_TV=$(bash ~/.lore/scripts/template-version.sh "$LORE_REPO_DIR/skills/bootstrap/SKILL.md")
EXPLORER_TV=$(bash ~/.lore/scripts/template-version.sh "$LORE_REPO_DIR/skills/bootstrap/templates/explorer-prompt.md")
```

### Step 1: Scope

1. Run `lore bootstrap scope [optional dir args...]`, passing through any directory arguments. Stdout: JSON array `[{"path": "src/auth", "description": "...", "languages": ["Python"]}]`. Stderr: tree output (context, not parsed).
2. Present the numbered domain list; invite add/remove/merge; wait for confirmation. Step 2 may reshape the list further.

### Step 2: Comprehend

Build a project sketch before fan-out — it shapes every explorer's brief.

1. **Find or create the work item.** Look for a `bootstrap-*` item in `$WORK_DIR/`; if present, load for resume (§ Resuming). Otherwise `lore work create --title "Bootstrap <repo-name>" --tags bootstrap`; set `SLUG`.

2. **Read the top-level shape** — pick from what exists, don't grep deep: README and top-level docs, entry points (`main.*`, `cmd/`, `bin/`), the manifest, and top-level interface definitions (protos, OpenAPI specs, public type packages).

3. **Write the sketch** to `$WORK_DIR/<SLUG>/findings.md`:
   ```markdown
   ## Project Sketch
   **Kind:** <CLI tool / web service / library / monorepo / data pipeline / ...>
   **Paradigm:** <event-driven / request-response / pipeline / state machine / plugin host / ...>
   **Stated purpose:** <one sentence, ideally from the README>
   **Project vocabulary:** <the project's own terms — explorers reuse these, not generic imports>
   **Candidate seams:** <where subsystems meet — public APIs, schemas, message formats, registries, data stores>
   ```

4. **Reshape the domain list if the sketch suggests it** — subsystems may cross or merge directory boundaries (an HTTP surface spanning `src/api` + `src/handlers`). Present any reshape with rationale and confirm. The confirmed list defines the **subsystems** for the run.

### Step 3: Dispatch

Exploration is read-only: no worktree lease, no messaging, self-contained briefs.

1. **Assign report identities before any dispatch.** Per subsystem: attempt-specific report id `explore-<subsystem-slug>-r<attempt>` and canonical path `$WORK_DIR/<SLUG>/worker-reports/<report-id>.md` (create the directory on first landing). A re-dispatch gets a fresh id, never a reuse; reports are immutable once accepted.

2. **Probe the route at operation level** through the active agent adapter (`ADAPTER="$LORE_REPO_DIR/adapters/agents/$(resolve_active_framework).sh"`) — never a branch on the framework's name. Four operations, probed separately: spawn surface (spawn/wait/shutdown), direct result collection (`collect_result` returns the full report body), completion enforcement (`native_blocking` or lead-validator — a worker's own word is never acceptance evidence), and report materialization (the lead can land each report at its canonical path).
   - All four present → native subagent fan-out, `min(subsystem_count, 4)` concurrent.
   - Any missing → item-backed worker sessions, one per subsystem (`lore session request --type worker …`; dispatch shape per `/coordinate` — the session lands its own report before terminus).
   - Neither route → the lead explores serially and lands its own reports with `Dispatch-path: lead-inline`. Every route produces the same durable artifacts.

3. **Prepare per-subsystem context:**
   ```bash
   PRIOR_KNOWLEDGE=$(lore prefetch "<subsystem name>" --format prompt --limit 5 --scale-set=architecture,subsystem)
   DOMAIN_TREE=$(tree -L 3 --dirsfirst -I 'node_modules|.git|vendor|__pycache__|dist|build|.next|target|coverage' <paths>)
   ```

4. **Render guidance at the exact brief seam.** Immediately before composing each subsystem's launch prompt, run `lore dispatch guidance`. If rendering fails, do not assemble or dispatch that explorer. The output is single-use: render again for every subsystem and retry.

5. **Compose one brief per subsystem** from `templates/explorer-prompt.md`, injecting the complete guidance output first and verbatim, then the sketch, `$PRIOR_KNOWLEDGE`, `$DOMAIN_TREE`, `SLUG`, the assigned report id, the dispatch path, the active harness name, and `$EXPLORER_TV`. Dispatch through the probed route; native adapters and worker-session enqueue validate the exact composed prompt without changing its knowledge or report contract.

### Step 4: Collect and Accept

1. **Land each report verbatim at its canonical path before checking it.** A subagent's direct return is copied to the assigned file by the lead; a worker session has already landed its own.

2. **Check each landed report:** identity header complete (`Report-schema: 1` through `Template-version:`) with `Report-id:` matching the assignment; `**Artifacts:**` manifest present; every claim id under **Tier 2 evidence:** exists in `$WORK_DIR/<SLUG>/task-claims.jsonl`; sections hold architecture/subsystem altitude. Any failure rejects the report — re-dispatch that subsystem under a fresh id.

3. **Journal the milestone after acceptance**, only once the report is landed and checked:
   ```bash
   if [[ -n "${LORE_SESSION_INSTANCE:-}" && -n "${LORE_SESSION_SLUG:-}" && -n "${LORE_SESSION_TYPE:-}" ]]; then
     bash ~/.lore/scripts/session-step.sh \
       --step-id "bootstrap:explore:<subsystem-slug>" --step-label "Accepted <subsystem name> exploration" \
       || echo "[bootstrap] Warning: milestone not journaled; the landed report remains authoritative." >&2
   fi
   ```
   The env gate is the hosted-session test — unhosted runs skip silently; a failed append warns without unwinding acceptance.

### Step 5: Synthesize

1. Read the sketch in `findings.md` and every accepted report in `worker-reports/`.

2. **Group by theme:** subsystem-internal map → `domains/<area>` or `architecture/`; cross-subsystem contracts → `architecture/` or `architectural-models/`; project-wide conventions → `cross-cutting-conventions/`.

3. **Flag contradictions** between explorer reports; resolve by reading the file at issue before filing. When the check lands on an existing knowledge entry, record it: `lore verify <entry-path> held|contradicted --source researcher` with the grounding file, line range, and exact snippet.

4. **Draft entries** — bootstrap drafts eagerly; Step 6 prunes.

   **Gate (all must hold):**
   - **Reusable** — claim survives beyond a single task.
   - **Stable** — not mid-refactor.
   - **Scale-fit** — passes the architecture substitution test (drop concrete proper nouns and the claim still reads as "A does B, C does D"), OR names a bounded subsystem and describes its internal shape. If the claim dies when you remove a function/file/line name, it's implementation-scale and does NOT belong here.

   "Non-obvious" is **not** a bootstrap condition — obvious-once-stated architectural facts still compress many files into one claim and prime search before code reading.

   Each draft: title, 1–3 sentence insight, category, declared scale (`architecture`, `subsystem`, or the adjacent pair), related files (entry points and contract definitions only), and the accepted Tier-2 claim ids that ground it.

5. **Deduplicate** — merge multi-explorer overlaps into single entries.

### Step 6: File

1. Present the entry list for pruning (e.g., "drop 3, edit 2").

2. Apply feedback, then file each approved entry through the sanctioned capture writer:
   ```bash
   lore capture \
     --insight "<1-3 sentence claim>" --context "Discovered during bootstrap of <repo>" \
     --category "<category>" --scale "<declared scale>" --confidence medium --source bootstrap \
     --related-files "<csv>" --producer-role worker --protocol-slot bootstrap-synthesize \
     --template-version "$LEAD_TV" --work-item "$SLUG" \
     --source-artifact-ids "<accepted Tier-2 claim ids grounding this entry>" \
     --captured-at-branch "$(git branch --show-current)" --captured-at-sha "$(git rev-parse HEAD)" \
     --captured-at-merge-base-sha "$(git merge-base HEAD origin/HEAD)"
   ```
   Every footer carries the full provenance set — `producer_role`, `protocol_slot`, `template_version`, `work_item`, `source_artifact_ids`, and the `captured_at_*` triple — alongside the declared scale and `confidence: medium`. An entry whose grounding claim ids were never accepted does not file.

3. On any failure, fix and re-run that entry. Then `lore heal`.

### Step 7: Spot-Check

Verify the **map matches the territory** — sample architectural claims, not file/line claims.

1. Pick 3 random entries from the set just filed. Read their related files; verify the claimed boundaries, contracts, and shapes hold. Record each outcome with `lore verify <entry-path> held|contradicted --source researcher` plus the grounding file, line range, and exact snippet.
2. Report held/contradicted per sampled entry; offer to correct or remove contradicted ones. Advisory — does not block completion.

### Step 8: Cleanup

1. Append a timestamped `notes.md` entry: focus, subsystems explored, entries filed, contradictions, spot-check summary, and next (remaining subsystems or "complete").
2. Check off completed phases in `plan.md`.
3. **All subsystems done** → `lore work archive "<SLUG>"`. **Partial** → leave active; run `lore work heal`.
4. Journal the filing milestone (same env-gated `session-step.sh` block, `--step-id "bootstrap:file"`), then report counts: subsystems explored, entries filed (confidence: medium, source: bootstrap), spot-check results, remaining subsystems.

## Domain Track (`--domain <topic>`)

Seeds exactly one lazy-loaded `domains/` entry for a named topic — the smallest durable artifact that improves the next retrieval. A narrow-results *action*, not a retrieval fallback.

**Gate — all must hold, else decline and say which failed:**

1. A retrieval with a correctly declared `--scale-set` came back genuinely empty. A wrong declaration is fixed by re-declaring, not by bootstrap.
2. Re-running `lore search "<topic>" --scale-set architecture,subsystem --limit 5` confirms no reusable orientation exists. Existing hits → point the requester at them and stop.
3. What's missing is reusable orientation — the map of a bounded area. A missing implementation fact never triggers this track.

**Then:**

1. `lore work create --title "Bootstrap domain: <topic>" --tags bootstrap`; set `SLUG`.
2. **Explore lead-inline, scoped to the topic** — one topic does not warrant fan-out. Read entry points and contract definitions for the named area only. As grounding claims form, append one Tier-2 row per claim via `echo '<row-json>' | bash ~/.lore/scripts/evidence-append.sh --work-item "$SLUG"` (`producer_role: "researcher"`, `task_id: "domain-<topic-slug>"`, `phase_id: "bootstrap-domain"`, explicit scale, snippet and hash per the Tier-2 contract). Record any existing entry checked against code with `lore verify`.
3. **Synthesize exactly one entry** mapping the topic's boundaries, contracts, and shapes. File it with the Step 6 capture command, changed to: `--category "domains/<topic-slug>"`, `--scale "architecture,subsystem"`, `--producer-role researcher`, `--protocol-slot bootstrap-domain`, `--context "Domain bootstrap for <topic>"`. The footer lands at `scale: architecture,subsystem` and `confidence: medium`, with `source_artifact_ids` naming the accepted Tier-2 claim ids.
4. **Leave unrelated discoveries uncaptured.** The contract is one seed, not a sweep — anything outside the named topic files later through organic growth, when it is actually consumed.
5. `lore heal`, append a `notes.md` entry, journal the env-gated milestone (`--step-id "bootstrap:domain:<topic-slug>"`), then `lore work archive "$SLUG"`.

## Resuming a Bootstrap

When `/bootstrap` is called and a `bootstrap-*` work item exists:

1. Read `findings.md` (the sketch), `plan.md`, and `worker-reports/` to determine completed subsystems.
2. Re-run `lore bootstrap scope` to detect new directories; present the sketch, already-explored, and new/remaining lists; confirm.
3. Proceed from Step 3 (Dispatch) with remaining subsystems and fresh attempt-specific report ids. The sketch is preserved unless the user explicitly updates it.
