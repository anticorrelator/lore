---
name: renormalize
description: Full knowledge store renormalization — prunes stale entries, merges redundancies, rebalances category structure via orchestrated multi-agent flow
user_invocable: true
argument_description: "(no arguments) — runs full renormalization pipeline with user approval"
---

# /renormalize Skill

Full knowledge store renormalization — prunes stale entries, merges redundancies, and rebalances category structure. This is an orchestrated multi-agent flow.

### Step 1: Pre-flight check

```bash
KDIR=$(lore resolve)
```

Check `format_version` in `$KDIR/_manifest.json`. If version 1 (or missing), migrate first:
```bash
lore migrate format
```
If already version 2, continue.

Ensure `$KDIR/_meta/` exists:
```bash
mkdir -p "$KDIR/_meta"
```

### Step 2: Analysis (parallel agents)

Create a team named `renorm-<YYYYMMDD-HHMMSS>` with 2 Explore agents running in parallel:

**Agent 1 — Staleness scan:**
```
Run: lore analyze staleness --json
Report the summary back via SendMessage: total entries scanned, stale count, breakdown by reason (age, low-confidence, missing referenced files).
```

**Agent 2 — Usage analysis:**
```
Run: lore analyze usage --json --write
Report the summary back via SendMessage: total entries, hot/warm/cold counts, cold entries list, retrieval-log coverage.
```

Wait for both agents to complete and acknowledge their reports.

### Step 2b: Audit Union + Holistic Assessment

### Compute audit union

Before spawning assessment agents, compute the three-set audit union and store it for the classifier:

**Set A — Flagged entries (cheap pre-pass):** entries with broken/missing related_files from the staleness scan:
```bash
# Read $KDIR/_meta/staleness-report.json and extract entries flagged for missing referenced files
```

**Set B — Top-central entries:** highest backlink in-degree from `_manifest.json`. Collect top 20 entries by combined `parents` + `inferred_parents` reference count across all entries.

**Set C — Rotating hash bucket:** run the audit-bucket script to get this cycle's 1/16 of the store:
```bash
bash ~/.lore/scripts/renormalize-audit-bucket.sh --kdir "$KDIR"
```
This advances the bucket counter and writes `$KDIR/_renormalize/audit-bucket-state.json`. Every entry in the store appears in at least one bucket across 16 cycles.

**Union:** deduplicate A ∪ B ∪ C. Write the list to `$KDIR/_meta/audit-set.json`:
```json
{"generated": "<ISO timestamp>", "entries": ["category/entry.md", ...], "sources": {"flagged": N, "top_central": N, "bucket": N, "union": N}}
```

Also run the merge-candidates analysis:
```bash
lore analyze merge-candidates
```

Spawn three Explore agents in parallel, each using a Tier 1 agent definition. This is advisory — agents do NOT modify knowledge files.

Template injections for all three agents:
- `{{team_name}}`: renorm-<timestamp>
- `{{team_lead}}`: <your name from team config>
- `{{kdir}}`: <resolved knowledge directory>

**Agent 3a — Classifier:** Use the `classifier` agent template (resolve via `resolve_agent_template classifier`; on Claude Code that path is `~/.claude/agents/classifier.md`).

Inject additional variables before spawning:
- `{{audit_set}}`: the `entries` array from `$KDIR/_meta/audit-set.json` (JSON array of paths)

The classifier audits only entries in the audit set, not the full store.
```
Task tool params:
  subagent_type: "Explore"
  team_name: "renorm-<timestamp>"
  name: "classifier"
  prompt: <contents of the classifier agent template with {{template}} variables resolved, including {{audit_set}}>
```

**Agent 3b — Structure Analyst:** Use the `structure-analyst` agent template (resolve via `resolve_agent_template structure-analyst`).
```
Task tool params:
  subagent_type: "Explore"
  team_name: "renorm-<timestamp>"
  name: "structure-analyst"
  prompt: <contents of the structure-analyst agent template with {{template}} variables resolved>
```

**Agent 3c — Cross-Reference Scout:** Use the `crossref-scout` agent template (resolve via `resolve_agent_template crossref-scout`).
```
Task tool params:
  subagent_type: "Explore"
  team_name: "renorm-<timestamp>"
  name: "crossref-scout"
  prompt: <contents of the crossref-scout agent template with {{template}} variables resolved>
```

Wait for all three assessment agents to complete and acknowledge their reports.

### Merge assessment reports

Read the three partial reports:
- `$KDIR/_meta/classification-report.json`
- `$KDIR/_meta/structure-report.json`
- `$KDIR/_meta/crossref-report.json`

Assemble them into the final `$KDIR/_meta/assessment-report.json` — this is a mechanical merge, not re-analysis:

```json
{
  "generated": "<ISO timestamp>",
  "classifications": [from classification-report],
  "clusters": [from structure-report],
  "imbalances": [from structure-report],
  "demotions": [from classification-report],
  "suggested_backlinks": [from crossref-report],
  "summary": {
    "total_classified": [from classification-report],
    "architectural": [from classification-report],
    "subsystem": [from classification-report],
    "implementation_detail": [from classification-report],
    "historical": [from classification-report],
    "clusters_found": [from structure-report],
    "demotions_recommended": [from classification-report],
    "suggested_backlinks_count": [from crossref-report],
    "entries_read_in_full": [from classification-report]
  }
}
```

Step 3 consumes `assessment-report.json`.

### Step 3: Planning (lead synthesizes)

Read the three reports:
- `$KDIR/_meta/staleness-report.json`
- `$KDIR/_meta/usage-report.json`
- `$KDIR/_meta/assessment-report.json`

Also read the merge-candidates data:
- `$KDIR/_meta/merge-candidates.json`

Synthesize a renormalization plan with these actions:

1. **Prune list:** Entries that are BOTH stale (from staleness report) AND cold (from usage report). Entries classified as *historical* by the assessment with low usage are strong prune candidates. These are safe to remove — they are outdated and unused.
2. **Fix list:** Entries that are stale (from staleness report) AND hot or warm (from usage report). These are actively used but drifted — they need content rewrite against current code, not removal. **Include stale entries that appear in consolidation clusters** — they must be fixed before consolidation so the parent entry inherits fresh content, not stale prose recombined.
3. **Merge list:** Entries flagged as highly similar by merge-candidates report (similarity >= 0.5) or identified as near-duplicates by the assessment. Group them into merge sets. **Scale constraint:** only propose same-scale merges, OR cross-scale merges where the target is an explicit bridging entry (tagged `bridging: true` or path under `bridging-entries/`). Cross-scale near-duplicates without a bridging entry go to the consolidate list instead.
4. **Demote list:** Entries the assessment classified at a higher significance tier than their content warrants (e.g., top-level entry that is really an implementation detail). These get rewritten to reduce scope or moved to a subcategory/domain file. The information is correct, just overpromoted.
5. **Consolidate list:** Entry clusters identified by the assessment — multiple entries describing the same concept at different granularities. Different from merge (which is dedup of near-identical content). **Scale-aware:** same-scale clusters → standard consolidate (parent + delete originals). Cross-scale clusters → `consolidate-bridge` action (bridging parent at highest scale, lower-scale children preserved with `parent:` pointer, not deleted).
6. **Restructure list:** Categories with structural imbalances flagged by the assessment (>20 flat entries, inconsistent nesting depth, or scale-skew >80% at one scale). For scale-skew proposals, the `split_by_scale: true` flag drives Agent 7 to create scale-keyed subdirectories instead of topic-keyed ones.
7. **Backlink list:** Cross-reference suggestions from the assessment's `suggested_backlinks` array. These are LLM-identified conceptual relationships not captured by existing backlinks or concordance edges. Present each with source, target, relationship type, and rationale for user review before writing.
8. **Rescale list:** Entries whose `scale:` field in the META block disagrees with the classifier's current assignment. Change only the `scale:` field — path and content are unchanged. Schema per entry: `entry_id`, `from_scale`, `to_scale`, `reason`. The classifier may co-propose a batch rescale set when a relabel would leave outliers stranded at a now-misnamed scale.
9. **Status-update list:** Entries whose `status:` field should transition from `current` to `superseded` or `historical` — typically because a newer entry covers the same ground. Schema per entry: `entry_id`, `from_status`, `to_status`, optional `successor_entry_id`, `reason`.
10. **Relabel list:** Proposed renames of a scale's human-readable label in `scripts/scale-registry.json`. Does NOT touch any entry files — only edits the registry's `labels` map and bumps `version`. Schema per entry: `scale_id`, `current_label`, `new_label`, `reason`.

Write the plan to `$KDIR/_meta/renormalize-plan.json` with structure:
```json
{
  "generated": "<ISO timestamp>",
  "prune": [
    {"path": "category/entry.md", "reason": "stale (age: 180d) + cold (0 retrievals)"}
  ],
  "fix": [
    {"path": "category/entry.md", "reason": "stale (drift: 0.72) + warm (5 retrievals)", "signals": {"file_drift": {"commit_count": 8}, "backlink_drift": {"broken": 1, "total": 3}}, "related_files": ["scripts/some-script.sh", "skills/some-skill/SKILL.md"]}
  ],
  "merge": [
    {"target": "category/kept.md", "sources": ["category/dup1.md", "category/dup2.md"], "reason": "overlapping content", "scale_notes": "same-scale or bridging (optional — omit for same-scale merges; set to 'bridging' when target is a bridging entry merging cross-scale sources)"}
  ],
  "demote": [
    {"path": "category/entry.md", "current_level": "top-level", "recommended_level": "subcategory", "reason": "assessment: implementation-detail, describes single-script behavior"}
  ],
  "consolidate": [
    {"parent_title": "Concept Name", "entries": ["category/entry1.md", "category/entry2.md", "category/entry3.md"], "reason": "3 entries describe same concept at different granularities", "proposed_structure": "Parent entry with subsections: overview, naming conventions, edge cases"}
  ],
  "consolidate_bridge": [
    {
      "proposed_bridge_entry": {"title": "Bridge Concept Name", "path": "category/bridge-entry.md"},
      "parent_scale": "architectural",
      "cluster_members": ["category/entry1.md", "category/entry2.md", "category/entry3.md"],
      "children_by_scale": {
        "subsystem": ["category/entry2.md"],
        "implementation": ["category/entry3.md"]
      },
      "reason": "cross-scale cluster: same concept at 3 scales; bridge at architectural, preserve children"
    }
  ],
  "restructure": [
    {"category": "conventions", "action": "split", "proposed": ["conventions/naming", "conventions/testing"], "reason": "32 entries, natural grouping exists"}
  ],
  "backlinks": [
    {"source": "category/source-entry.md", "target": "category/target-entry.md", "relationship_type": "cross-domain|hierarchical|causal|complementary", "rationale": "One sentence explaining the conceptual relationship."}
  ],
  "rescale": [
    {"entry_id": "category/entry.md", "from_scale": "architectural", "to_scale": "subsystem", "reason": "classifier: entry describes single-script behavior, not system-wide pattern"}
  ],
  "status_updates": [
    {"entry_id": "category/entry.md", "from_status": "current", "to_status": "superseded", "successor_entry_id": "category/newer-entry.md", "reason": "newer entry covers same ground with updated code references"}
  ],
  "relabels": [
    {"scale_id": "implementation", "current_label": "implementation", "new_label": "detail", "reason": "classifier drift: 'implementation' label conflicts with scale-id usage in META blocks"}
  ],
  "summary": {"prune_count": 5, "fix_count": 2, "merge_count": 3, "demote_count": 4, "consolidate_count": 2, "consolidate_bridge_count": 1, "restructure_count": 1, "backlink_count": 3, "rescale_count": 2, "status_update_count": 1, "relabel_count": 1}
}
```

Present the plan to the user in a readable format:
```
[renormalize] Proposed plan:
  Fix: N entries (stale + actively used — content rewrite needed)
  Prune: N entries (stale + unused)
  Merge: N redundant entry sets
  Demote: N entries (wrong abstraction level — rewrite or move)
  Consolidate: N concept clusters (multiple entries → single parent)
  Consolidate-bridge: N cross-scale clusters (bridging parent + preserved children)
  Restructure: N categories
  Backlinks: N cross-references to write
  Rescale: N entries (scale field update only)
  Status updates: N entries (status field transition)
  Relabels: N scale label renames (registry only)

Fix candidates:
  - category/entry.md — drift: 0.72 (8 commits to related files, 1/3 backlinks broken)
  - category/other.md — drift: 0.65 (5 commits to related files)

Prune candidates:
  [list each with path and reason]

Merge sets:
  [list each with target, sources, and reason]

Demote candidates:
  [list each with path, current level, recommended level, and reason]

Consolidation clusters:
  [list each with parent title, entries, and proposed structure]

Restructure:
  [list each with category and proposed split]

Suggested backlinks:
  [list each with source → target, relationship type, and rationale]

Rescale candidates:
  [list each with entry_id, from_scale → to_scale, and reason]

Status update candidates:
  [list each with entry_id, from_status → to_status, successor if any, and reason]

Relabel candidates:
  [list each with scale_id, current_label → new_label, and reason]

Approve? (yes / yes with changes / no)
```

**Wait for user approval before proceeding.** If the user requests changes, update the plan and re-present. If rejected, delete `$KDIR/_meta/renormalize-plan.json` and stop.

### Step 4: Execution (sequenced + parallel agents)

After approval, execute in two waves. **Wave 1 MUST complete before Wave 2 starts** — this ensures consolidation and merge operate on freshly verified content, not stale prose recombined.

### Wave 1: Fix stale entries (including those in consolidation clusters)

**Agent 4 — Entry Fixer:**
```
Read $KDIR/_meta/renormalize-plan.json.
Execute the "fix" actions: for each fix-candidate entry, read the entry file and each of its related_files from the repo. Compare the entry's claims to current code. Rewrite the entry preserving format:
- Keep the H1 title (# heading)
- Rewrite prose to match current code behavior
- Preserve or update See also: backlinks
- Update the HTML metadata comment: set `learned` date to today, set `source: renormalize-fix`
If a related_file is missing from the repo, skip that entry and report it.

IMPORTANT: The fix list includes stale entries that are also members of consolidation clusters. These MUST be fixed now so that Wave 2 consolidation combines fresh content. Do not skip an entry because it will later be consolidated — fix it first.

Report: entries fixed, entries skipped (with reasons), any issues encountered.
```

Wait for Agent 4 to complete before proceeding to Wave 2.

### Wave 2: Prune, merge, demote, consolidate, restructure, and backlink (parallel)

Spawn 4 general-purpose agents:

**Agent 5 — Merger/Pruner:**
```
Read $KDIR/_meta/renormalize-plan.json.
Execute the "prune" actions: delete each listed file.
Execute the "merge" actions: for each merge set, apply the scale-check rule FIRST, then merge.

Scale-check rule (cross-scale merge guard):
1. Read the scale: field from the HTML metadata comment of each entry in the merge set (target + sources).
2. If all entries share the same scale: proceed with the merge.
3. If the entries span multiple scales AND the target entry is tagged `bridging: true` in its metadata
   OR the target entry's path is under `bridging-entries/`:
   - Proceed. The bridging entry becomes the parent. Add `supersedes: <source-path>` edges to the
     target entry's See also: section for each cross-scale source, with a comment:
     <!-- cross-scale child via renormalize-merge -->
   - Delete the source files as normal.
4. If the entries span multiple scales AND no bridging entry exists:
   - Do NOT execute the merge. Log a rejection:
     "REJECTED merge of [source paths] into [target]: spans scales [list]. Use consolidate action instead."
   - Continue to the next merge set. Do not abort the full run.

After the scale-check, for allowed merges: combine content from source entries into the target entry
(preserve all unique insights, deduplicate, update backlinks), then delete the source files.
Report: files pruned, files merged, merges rejected (with reason), any issues encountered.
```

**Agent 6 — Demoter/Consolidator:**
```
Read $KDIR/_meta/renormalize-plan.json.
Execute the "demote" actions: for each demote candidate, read the entry and rewrite it to reduce scope/prominence appropriate to the recommended level. If recommended_level is "subcategory", move the file to the appropriate subcategory directory (create it if needed). If recommended_level is "domain", move to domains/. Update the HTML metadata comment: set source to "renormalize-demote". Update any inbound backlinks that reference the old path.
Execute the "consolidate" actions with scale-aware logic:

Scale-aware consolidation:
1. For each consolidation cluster, read the scale: field from each member's HTML metadata comment.
2. If all members share the same scale (same-scale cluster):
   - Standard consolidate: create a new parent entry at that scale with the specified parent_title.
   - Combine unique insights into subsections (following proposed_structure).
   - Preserve all backlinks and metadata. Delete the original entries.
   - Update any inbound backlinks to point to the new parent entry.
3. If the cluster spans multiple scales (cross-scale cluster), check for a "consolidate-bridge" plan action:
   - Create the bridging parent entry at the scale specified in parent_scale (highest scale in cluster).
   - Set `bridging: true` in the bridging entry's HTML metadata comment.
   - For each lower-scale member: do NOT delete it. Instead add `parent: <bridge_entry_id>` to its
     HTML metadata comment. Update any inbound backlinks to reference both the child and the bridge.
   - Write a summary subsection in the bridge entry that links to each child entry.
   - Report the bridge entry path and all child paths with their preserved scales.

Report: entries demoted (with old/new paths), clusters consolidated (with parent paths, and whether same-scale or bridge), any issues encountered.
```

**Agent 7 — Budget Rebalancer:**
```
Read $KDIR/_meta/renormalize-plan.json.
Execute the "restructure" actions: for each restructure proposal, check the split_by_scale flag.

If split_by_scale is false (or absent): create new subdirectories by topic, move entries into appropriate groupings, update any backlinks that reference moved entries.

If split_by_scale is true: create scale-keyed subdirectories under the category (e.g., conventions/implementation/, conventions/subsystem/, conventions/architectural/). Move each entry into the subdirectory matching its scale: field from its HTML metadata comment. Update any backlinks that reference moved entries.

Report: categories restructured (with split_by_scale flag noted), entries moved (with destination paths), backlinks updated.
```

**Agent 8 — Backlink Writer:**
```
Read $KDIR/_meta/assessment-report.json.
Execute the "suggested_backlinks" actions: for each suggestion, read the source entry file and check whether a backlink to the target already exists. If not, append a `See also:` line with the backlink and a provenance comment:

See also: [[knowledge:target-entry]]
<!-- source: renormalize-backlinks -->

Rules:
- If the source file already has a "See also:" section, append the new link to it.
- If no "See also:" section exists, add one at the end of the file (after a blank line).
- Skip the link if [[knowledge:target-entry]] already appears anywhere in the source file.
- The `<!-- source: renormalize-backlinks -->` comment MUST appear on the line immediately after the backlink line. This provenance marker is used by the structural importance computation to weight LLM-suggested links at 0.8 (vs 1.0 for explicit backlinks).

Report: links written (with source → target pairs), links skipped (already present), any issues encountered.
```

Wait for all agents to complete and review their reports for any errors.

### Step 5: Cleanup and verification

### Emit scale_drift_rate guardrail rows

Before cleaning up intermediate reports, emit one `scale_drift_rate` telemetry scorecard row per `producer_role`. This must run while `$KDIR/_meta/classification-report.json` still exists:

```bash
bash ~/.lore/scripts/renormalize-emit-drift-guardrails.sh \
  --kdir "$KDIR" \
  --run-id "renorm-<timestamp>"
```

This reads the classifier's `disagreements` array, joins with `_manifest.json` for `producer_role`, and calls `scorecard-append.sh` once per role. Row shape:
```json
{"schema_version": "1", "kind": "telemetry", "metric": "scale_drift_rate",
 "calibration_state": "pre-calibration", "role": "<role>", "value": <float>,
 "disagreements": <int>, "entries_audited": <int>,
 "ts": "<ISO-8601>", "renormalize_run_id": "<run-id>"}
```

**Guardrail interpretation:** high `value` (disagreements / entries_audited) indicates the role is capturing entries at the wrong scale OR the scale matrix needs adjustment. This is diagnostic telemetry only — it must NOT feed `/evolve` citations or primary scoring.

### Emit retention_after_renormalize rows

Emit one `retention_after_renormalize` telemetry row per living entry, tracking how many prior renormalize cycles each entry survived without being pruned:

```bash
bash ~/.lore/scripts/renormalize-emit-retention.sh \
  --kdir "$KDIR" \
  --run-id "renorm-<timestamp>"
```

Reads `$KDIR/_renormalize/prune-history.jsonl` (one line per run: `{"run_id":"...","pruned":[...]}`) and `_manifest.json`. Emits one row per entry:
```json
{"schema_version": "1", "kind": "telemetry", "metric": "retention_after_renormalize",
 "calibration_state": "pre-calibration", "template_id": "<template_version or 'unknown'>",
 "entry_id": "<path>", "cycles_survived": <int>,
 "ts": "<ISO-8601>", "renormalize_run_id": "<run-id>"}
```

**First-run behavior:** if `prune-history.jsonl` does not exist, all entries emit `cycles_survived: 0` — expected; the metric becomes meaningful after multiple renormalize runs accumulate history.

**Interpretation:** entries with consistently low `cycles_survived` relative to their peers are candidates for pruning review. Stratify by `template_id` to detect whether specific producer templates generate less durable knowledge. Diagnostic telemetry only — must NOT feed `/evolve` citations or primary scoring.

### Emit downstream_adoption_rate rows

Emit one `downstream_adoption_rate` telemetry row per entry, measuring how often each entry was loaded to agents in the rolling window:

```bash
bash ~/.lore/scripts/emit-downstream-adoption.sh \
  --kdir "$KDIR" \
  --run-id "renorm-<timestamp>" \
  --window 30
```

Reads `$KDIR/_meta/retrieval-log.jsonl` (loaded_paths from prefetch + session-start events) and `_manifest.json`. Stratifies by entry status read from the entry file's META block (`current | superseded | historical`; defaults to `current` when absent). Emits one row per entry:
```json
{"schema_version": "1", "kind": "telemetry", "metric": "downstream_adoption_rate",
 "calibration_state": "pre-calibration", "entry_id": "<path>",
 "status": "current|superseded|historical", "citations": <int>, "opportunities": <int>,
 "value": <float>, "window_days": 30, "ts": "<ISO-8601>", "renormalize_run_id": "<run-id>"}
```

**Interpretation:** low `value` on `status: current` entries indicates knowledge that agents rarely retrieve — candidates for consolidation or better keyword tagging. Equal or higher `value` on `status: superseded` entries vs `current` peers indicates trust signals aren't influencing retrieval behavior — feeds the trust-stamping feedback loop (Pass 2 task-21). Diagnostic telemetry only — must NOT feed `/evolve` citations or primary scoring.

### Emit correction_rate and precedent_rate rows

Emit `correction_rate` (per scale) and `precedent_rate` (per registry group) telemetry rows:

```bash
bash ~/.lore/scripts/emit-correction-metrics.sh \
  --kdir "$KDIR" \
  --run-id "renorm-<timestamp>" \
  --window-days 30
```

Reads `_manifest.json` and `scripts/scale-registry.json`. Walks all entries, reading `corrections[]`, `precedent_note:`, and `scale:` from each entry's HTML META block. Emits one `correction_rate` row per scale and one `precedent_rate` row per registry group (scale_id):

```json
{"schema_version": "1", "kind": "telemetry", "metric": "correction_rate",
 "calibration_state": "pre-calibration", "scale": "<scale>",
 "corrections_in_window": <int>, "entries_at_scale": <int>, "value": <float>,
 "window_days": 30, "ts": "<ISO-8601>", "renormalize_run_id": "<run-id>"}

{"schema_version": "1", "kind": "telemetry", "metric": "precedent_rate",
 "calibration_state": "pre-calibration", "scale_id": "<id>",
 "l3_corrections_in_window": <int>, "corrections_in_window": <int>, "value": <float>,
 "window_days": 30, "ts": "<ISO-8601>", "renormalize_run_id": "<run-id>"}
```

`corrections_in_window` counts entries with ≥1 correction[] item dated within the window. L3 corrections (for `precedent_rate`) are entries that have both `corrections[]` AND `precedent_note:` in the META block — indicating the correction escalated to a supersedes edge. Diagnostic telemetry only — must NOT feed `/evolve` citations or primary scoring.

### Run post-execution maintenance

```bash
lore heal --fix
```

Generate concordance-based backlinks — writes `See also:` links for high-similarity pairs not already cross-referenced:
```bash
python3 ~/.lore/scripts/pk_cli.py generate-backlinks "$KDIR"
```

Rebuild FTS5 search index — **must be `--force`**, not incremental:
```bash
python3 ~/.lore/scripts/pk_cli.py index "$KDIR" --force
```

Renormalize mutates META blocks in place (rescale, relabel, status flips). The
incremental indexer keys on file create/delete/mtime, not META content
diffs, so in-place META mutations on existing files can leave the SQLite
index pointing at stale `scale` values. Any operation that rewrites META
across the corpus must follow the same protocol: corpus-wide META mutation →
`pk_cli.py index --force`.

Update manifest:
```bash
bash ~/.lore/scripts/update-manifest.sh
```

Mirror the post-renormalize source state to the Obsidian vault (no-op when
`~/.lore/config/obsidian.json` is absent; full re-export propagates file
moves, deletes, and inbound-link rewrites):
```bash
bash ~/.lore/scripts/export-obsidian.sh --full
```

Clean up intermediate reports from `$KDIR/_meta/` — delete:
- `staleness-report.json`
- `usage-report.json`
- `merge-candidates.json`
- `audit-set.json`
- `classification-report.json`
- `structure-report.json`
- `crossref-report.json`
- `assessment-report.json`
- `renormalize-plan.json`

**Keep** these logs (they have ongoing value):
- `retrieval-log.jsonl`
- `friction-log.jsonl`

Delete the team (`renorm-*`).

Report the final summary:
```
[renormalize] Complete.
  Fixed: N entries (stale content rewritten against current code)
  Pruned: N entries
  Merged: N entry sets (M source files consolidated)
  Demoted: N entries (rewritten or moved to appropriate level)
  Consolidated: N concept clusters (M entries → N parent entries)
  Restructured: N categories
  Backlinks (LLM-suggested): N cross-references written (M skipped, already present)
  Backlinks (concordance): N links written (M skipped, already present)
  Index rebuilt, manifest updated, heal passed.
```
