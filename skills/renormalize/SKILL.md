---
name: renormalize
description: Full knowledge store renormalization — prunes stale entries, merges redundancies, rebalances category structure via orchestrated multi-agent flow
user_invocable: true
argument_description: "(no arguments) — runs full renormalization pipeline with user approval"
---

# /renormalize Skill

Renormalizes the knowledge store end to end: fixes drifted entries, prunes dead ones, merges duplicates, consolidates concept clusters, rebalances category structure, and repairs the cross-reference graph. The lead runs deterministic analysis and maintenance verbs directly, dispatches judgment work (classification, structural assessment, cross-references, approved mutations), and closes with telemetry and index maintenance.

**Renormalize is mutation-only.** It rewrites, moves, merges, retires, and relabels existing entries; no new knowledge enters the commons through this skill. Consolidation parents and bridge entries recombine existing content under existing provenance — reorganization, not new claims.

## Resolve Paths and Defaults

```bash
KDIR=$(lore resolve)
```

```bash
lore defaults
```

Binding, not advisory: role→model routes, harness selection, and standing preference directives come from this output. The skill takes no model arguments — every dispatch resolves its model through the role resolver, never a hardcoded alias.

Pre-flight:

1. `format_version` in `$KDIR/_manifest.json` must be 2. If 1 or missing, run `lore migrate knowledge` first.
2. `mkdir -p "$KDIR/_meta"`
3. Create the run's work item and stamp identities:
   ```bash
   SLUG=$(lore work create --title "Renormalize $(date +%Y-%m-%d)" --tags renormalize)
   RUN_ID="renorm-$(date +%Y%m%d-%H%M%S)"
   ```
   The work item hosts worker reports (`$KDIR/_work/$SLUG/worker-reports/`), Tier-2 evidence (`$KDIR/_work/$SLUG/task-claims.jsonl`), and session milestones. Archive it at close.

## Dispatch Route and Report Contract

**Route.** Probe the active agent adapter at operation level (`ADAPTER="$LORE_REPO_DIR/adapters/agents/$(resolve_active_framework).sh"`) — never a branch on a framework's name; capability overrides participate automatically. Dispatch needs four operations, probed separately: a spawn surface (spawn/wait/shutdown), direct result collection, completion enforcement (a worker's own word is never acceptance evidence), and report materialization (the lead can land each collected report at its canonical path).

- All four present → native subagent fan-out.
- Any missing → item-backed worker sessions (`lore session request --type worker …`; dispatch shape per `/coordinate` — the session lands its own report file before terminus).
- Neither route → the lead does the work inline and lands its own reports with `Dispatch-path: lead-inline`.

Every route produces the same durable artifacts.

**Report identities.** Assign each dispatch a fresh, attempt-specific report id `<role>-r<attempt>` with canonical path `$KDIR/_work/$SLUG/worker-reports/<report-id>.md` (create the directory on first landing). A re-dispatch gets a new id, never a reuse; accepted report files are immutable.

**Report contract** — append this block to every dispatched brief (a lead-inline pass follows it too):

```
Return a report that opens with the identity header:
  Report-schema: 1
  Report-id: <assigned id>
  Work-item: <slug>
  Task: <role — e.g. classifier, wave1-fixer, wave2-batch-1>
  Producer-role: worker
  Dispatch-path: <as dispatched>
  Harness: <active harness>
  Status: <completed | blocked | degraded>
  Template-version: <injected template hash>
Then:
  **Artifacts:** — one entry per durable file you wrote: path, kind, writer, identity.
  **Changes:** — entries touched, one line each.
  **Tier 2 evidence:** — the claim ids you appended to task-claims.jsonl via
    `echo '<row-json>' | bash ~/.lore/scripts/evidence-append.sh --work-item <slug>`,
    or `none`. One row per file-anchored claim, emitted when formed, never batched.
  **Blockers:** — none, or what stopped you.
```

Stamp each brief's `Template-version:` from its template file: `bash ~/.lore/scripts/template-version.sh <template path>`.

**Acceptance.** Land each collected report verbatim at its canonical path before checking it. Check: identity header complete and `Report-id:` matching the assignment; every artifact identity checkable; every Tier-2 claim id present in `$KDIR/_work/$SLUG/task-claims.jsonl`. Reject → re-dispatch under a fresh id.

### Step 1: Analyze (direct verbs)

Deterministic analysis is lead-run, never dispatched:

```bash
lore analyze staleness --json        # writes $KDIR/_meta/staleness-report.json
lore analyze usage --json --write    # writes $KDIR/_meta/usage-report.json
lore analyze merge-candidates        # writes $KDIR/_meta/merge-candidates.json
```

### Step 2: Audit Union

Bound the classification audit to the union of three sets:

- **A — flagged:** entries with broken or missing related_files, from the staleness report.
- **B — central:** top 20 entries by combined `parents` + `inferred_parents` in-degree from `_manifest.json`.
- **C — bucket:** this cycle's rotating 1/16 of the store:
  ```bash
  bash ~/.lore/scripts/renormalize-audit-bucket.sh --kdir "$KDIR"
  ```
  Stdout is the bucket's entry paths, one per line; the script advances the cycle counter in `$KDIR/_renormalize/audit-bucket-state.json`. Every entry appears in at least one bucket across 16 cycles.

Write the deduplicated union to `$KDIR/_meta/audit-set.json` as `{"generated": <ISO timestamp>, "entries": [<paths>], "sources": {<per-set and union counts>}}`. The classifier audits only this set, never the full store.

### Step 3: Assess (dispatched judgment)

Read `templates/step2-analysis-agents.md` and dispatch the three assessment briefs — classifier, structure analyst, cross-reference scout — in parallel through the probed route. Assessment is advisory and read-only: each agent writes its findings JSON to `$KDIR/_meta/` (paths in the template) and returns a contract report. Accept all three before proceeding.

Assemble `$KDIR/_meta/assessment-report.json` by mechanical union — no re-analysis: `classifications`, `demotions`, and the classification counts from the classification report; `clusters` and `imbalances` from the structure report; `suggested_backlinks` from the crossref report; a `summary` of counts.

### Step 4: Plan (lead synthesis)

Read the staleness, usage, assessment, and merge-candidates reports. Synthesize one action list per category below; every action names its target path(s) and a one-line reason. Write the plan to `$KDIR/_meta/renormalize-plan.json`, one array per list plus a count `summary`.

1. **Fix** — stale AND hot/warm: actively used but drifted. Rewrite against current code, never prune. Include every stale member of a consolidation cluster — it must be fixed before consolidation so the parent inherits fresh content. Carry each entry's drift signals and `related_files`.
2. **Prune** — stale AND cold. A *historical* classification with low usage strengthens the call. Safe to delete: outdated and unused.
3. **Merge** — near-duplicates (similarity ≥ 0.5 or assessment-flagged), grouped into sets with one target. Same-scale sets only, unless the target is a bridging entry (`bridging: true` in its metadata, or path under `bridging-entries/`); cross-scale sets without a bridging target go to consolidate instead.
4. **Demote** — correct content at an overpromoted tier. Rewrite to reduced scope and/or move down (subcategory, or `domains/`). Record current and recommended level.
5. **Consolidate** — clusters describing one concept at different granularities (distinct from merge, which is dedup of near-identical content). Same-scale cluster → new parent entry, originals deleted. Cross-scale cluster → `consolidate-bridge`: bridging parent at the cluster's highest scale, lower-scale children preserved with a `parent:` pointer, never deleted.
6. **Restructure** — categories with >20 flat entries, inconsistent nesting depth, or >80% scale-skew. Scale-skew proposals set `split_by_scale: true`, which drives scale-keyed subdirectories instead of topic-keyed ones.
7. **Backlinks** — the assessment's suggested cross-references: source, target, relationship type, rationale. User-reviewed before writing.
8. **Rescale** — entries whose META `scale:` field disagrees with the classifier. Change the field only; path and content untouched. Record entry, from/to scale, reason. A batch rescale set is acceptable when a lone relabel would strand outliers at a now-misnamed scale.
9. **Status updates** — `current` → `superseded` or `historical` transitions, typically because a newer entry covers the same ground. Record the successor entry when one exists.
10. **Relabels** — renames of a scale's human-readable label in `scripts/scale-registry.json` only (edit the `labels` map, bump `version`). No entry files touched.

Present the plan: counts per action list, then each candidate with its reason (fix candidates include their drift signals). End with:

```
Approve? (yes / yes with changes / no)
```

**Wait for user approval.** Changes requested → update the plan and re-present. Rejected → delete `$KDIR/_meta/renormalize-plan.json`, archive the work item, stop.

On approval, journal the milestone if hosted:

```bash
if [[ -n "${LORE_SESSION_INSTANCE:-}" && -n "${LORE_SESSION_SLUG:-}" && -n "${LORE_SESSION_TYPE:-}" ]]; then
  bash ~/.lore/scripts/session-step.sh --step-id "renormalize:plan-approved" \
    --step-label "Plan approved" \
    || echo "[renormalize] Warning: milestone not journaled; on-disk artifacts remain authoritative." >&2
fi
```

The env gate is the hosted-session test — an unhosted run skips silently. The same block journals each later milestone; a hosted run journals only after the milestone's artifacts have landed, and a failed append warns without unwinding anything.

### Step 5: Execute

**Wave 1 fixes before Wave 2 mutates.** Consolidation and merge must combine freshly verified content, not stale prose recombined — Wave 1 reports are accepted before any Wave 2 dispatch.

**Wave 1 — fix.** Read `templates/wave1-fixer-prompt.md`, inject the plan's fix list, and dispatch. Split into multiple fixers only along disjoint entry sets.

**Ownership batching.** Before Wave 2, compute each approved action's write set: entries deleted or rewritten, moved files (old and new paths), parent or bridge entries assembled from cluster content, backlink source files, and every entry whose inbound backlinks get rewritten because a target moves or dies. Partition actions into batches with pairwise-disjoint write sets — start from the four role briefs in the template (merger/pruner, demoter/consolidator, rebalancer, backlink writer) and merge or serialize any pair whose write sets overlap. Two concurrent workers never own the same file.

**Wave 2 — mutate.** Read `templates/wave2-agent-prompts.md`, compose one brief per batch, and dispatch: disjoint batches in parallel, overlapping ones serially. Invariants carried in the briefs:

- Every file move emits a trust-ledger provenance migration through `~/.lore/scripts/trust-event-migrate.sh` — the only sanctioned seam for trust history to follow a moved entry. Nothing in this flow writes trust records directly.
- The cross-scale merge guard and scale-aware consolidation rules run inside the workers, per the template.

Accept every report per the contract, then journal `renormalize:wave1` and `renormalize:wave2` milestones (env-gated block above).

### Step 6: Telemetry, Maintenance, Close

**Telemetry first** — the drift guardrail reads `classification-report.json`, so this runs before cleanup deletes it. Each script derives rows from on-disk state and appends through the sanctioned scorecard writer. All four metrics are diagnostic telemetry only — they must not feed `/evolve` citations or primary scoring.

```bash
bash ~/.lore/scripts/renormalize-emit-drift-guardrails.sh --kdir "$KDIR" --run-id "$RUN_ID"
bash ~/.lore/scripts/renormalize-emit-retention.sh --kdir "$KDIR" --run-id "$RUN_ID"
bash ~/.lore/scripts/emit-downstream-adoption.sh --kdir "$KDIR" --run-id "$RUN_ID" --window 30
bash ~/.lore/scripts/emit-correction-metrics.sh --kdir "$KDIR" --run-id "$RUN_ID" --window-days 30
```

(Scale drift per producer role; per-entry renormalize-cycle survival; per-entry retrieval adoption; correction and precedent rates.) A first run with no prune history emits zero-survival retention rows — expected; the metric matures as runs accumulate.

**Maintenance verbs:**

```bash
lore heal --fix
python3 ~/.lore/scripts/pk_cli.py generate-backlinks "$KDIR"
python3 ~/.lore/scripts/pk_cli.py index "$KDIR" --force
bash ~/.lore/scripts/update-manifest.sh
bash ~/.lore/scripts/export-obsidian.sh --full
```

The index rebuild must be `--force`: renormalize mutates META blocks in place, and the incremental indexer keys on file create/delete/mtime, so in-place META changes would leave the index pointing at stale scale values. Any corpus-wide META mutation ends with a forced rebuild. The Obsidian export is a no-op without `~/.lore/config/obsidian.json`; `--full` propagates moves, deletes, and inbound-link rewrites.

**Cleanup.** Delete from `$KDIR/_meta/`: `staleness-report.json`, `usage-report.json`, `merge-candidates.json`, `audit-set.json`, `classification-report.json`, `structure-report.json`, `crossref-report.json`, `assessment-report.json`, `renormalize-plan.json`. Keep `retrieval-log.jsonl` and `friction-log.jsonl` — they have ongoing value.

Append a run summary to the work item's `notes.md`, archive it (`lore work archive "$SLUG"`), and report:

```
[renormalize] Complete.
  Fixed: N   Pruned: N   Merged: N sets   Demoted: N
  Consolidated: N clusters (M bridged)   Restructured: N categories
  Backlinks: N suggested + M concordance written
  Rescaled: N   Status updates: N   Relabels: N
  Index rebuilt, manifest updated, heal passed.
```
