---
name: renormalize
description: Full knowledge store renormalization — prunes stale entries, merges redundancies, rebalances category structure via orchestrated multi-agent flow
user_invocable: true
argument_description: "(no arguments) — runs full renormalization pipeline with user approval"
---

# /renormalize Skill

Full knowledge store renormalization — prunes stale entries, merges redundancies, and rebalances category structure. This is an orchestrated multi-agent flow.

## Step 1: Pre-flight check

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

## Step 2: Analysis (parallel agents)

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

## Step 2b: Holistic Assessment (parallel agents)

Also run the merge-candidates analysis:
```bash
lore analyze merge-candidates
```

Spawn three Explore agents in parallel, each using a Tier 1 agent definition. This is advisory — agents do NOT modify knowledge files.

Template injections for all three agents:
- `{{team_name}}`: renorm-<timestamp>
- `{{team_lead}}`: <your name from team config>
- `{{kdir}}`: <resolved knowledge directory>

**Agent 3a — Classifier:** Use `~/.claude/agents/classifier.md`
```
Task tool params:
  subagent_type: "Explore"
  team_name: "renorm-<timestamp>"
  name: "classifier"
  prompt: <contents of ~/.claude/agents/classifier.md with {{template}} variables resolved>
```

**Agent 3b — Structure Analyst:** Use `~/.claude/agents/structure-analyst.md`
```
Task tool params:
  subagent_type: "Explore"
  team_name: "renorm-<timestamp>"
  name: "structure-analyst"
  prompt: <contents of ~/.claude/agents/structure-analyst.md with {{template}} variables resolved>
```

**Agent 3c — Cross-Reference Scout:** Use `~/.claude/agents/crossref-scout.md`
```
Task tool params:
  subagent_type: "Explore"
  team_name: "renorm-<timestamp>"
  name: "crossref-scout"
  prompt: <contents of ~/.claude/agents/crossref-scout.md with {{template}} variables resolved>
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

Step 3 consumes `assessment-report.json` — the schema is unchanged.

## Step 3: Planning (lead synthesizes)

Read the three reports:
- `$KDIR/_meta/staleness-report.json`
- `$KDIR/_meta/usage-report.json`
- `$KDIR/_meta/assessment-report.json`

Also read the merge-candidates data:
- `$KDIR/_meta/merge-candidates.json`

Synthesize a renormalization plan with these actions:

1. **Prune list:** Entries that are BOTH stale (from staleness report) AND cold (from usage report). Entries classified as *historical* by the assessment with low usage are strong prune candidates. These are safe to remove — they are outdated and unused.
2. **Fix list:** Entries that are stale (from staleness report) AND hot or warm (from usage report). These are actively used but drifted — they need content rewrite against current code, not removal. **Include stale entries that appear in consolidation clusters** — they must be fixed before consolidation so the parent entry inherits fresh content, not stale prose recombined.
3. **Merge list:** Entries flagged as highly similar by merge-candidates report (similarity >= 0.5) or identified as near-duplicates by the assessment. Group them into merge sets.
4. **Demote list:** Entries the assessment classified at a higher significance tier than their content warrants (e.g., top-level entry that is really an implementation detail). These get rewritten to reduce scope or moved to a subcategory/domain file. The information is correct, just overpromoted.
5. **Consolidate list:** Entry clusters identified by the assessment — multiple entries describing the same concept at different granularities. These get merged into a parent entry with subsections, preserving all unique insights. Different from merge (which is dedup of near-identical content).
6. **Restructure list:** Categories with structural imbalances flagged by the assessment (>20 flat entries, inconsistent nesting depth) that should be split into subcategories or promoted to domain files.
7. **Backlink list:** Cross-reference suggestions from the assessment's `suggested_backlinks` array. These are LLM-identified conceptual relationships not captured by existing backlinks or concordance edges. Present each with source, target, relationship type, and rationale for user review before writing.

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
    {"target": "category/kept.md", "sources": ["category/dup1.md", "category/dup2.md"], "reason": "overlapping content"}
  ],
  "demote": [
    {"path": "category/entry.md", "current_level": "top-level", "recommended_level": "subcategory", "reason": "assessment: implementation-detail, describes single-script behavior"}
  ],
  "consolidate": [
    {"parent_title": "Concept Name", "entries": ["category/entry1.md", "category/entry2.md", "category/entry3.md"], "reason": "3 entries describe same concept at different granularities", "proposed_structure": "Parent entry with subsections: overview, naming conventions, edge cases"}
  ],
  "restructure": [
    {"category": "conventions", "action": "split", "proposed": ["conventions/naming", "conventions/testing"], "reason": "32 entries, natural grouping exists"}
  ],
  "backlinks": [
    {"source": "category/source-entry.md", "target": "category/target-entry.md", "relationship_type": "cross-domain|hierarchical|causal|complementary", "rationale": "One sentence explaining the conceptual relationship."}
  ],
  "summary": {"prune_count": 5, "fix_count": 2, "merge_count": 3, "demote_count": 4, "consolidate_count": 2, "restructure_count": 1, "backlink_count": 3}
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
  Restructure: N categories
  Backlinks: N cross-references to write

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

Approve? (yes / yes with changes / no)
```

**Wait for user approval before proceeding.** If the user requests changes, update the plan and re-present. If rejected, delete `$KDIR/_meta/renormalize-plan.json` and stop.

## Step 4: Execution (sequenced + parallel agents)

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
Execute the "merge" actions: for each merge set, combine content from source entries into the target entry (preserve all unique insights, deduplicate, update backlinks), then delete the source files.
Report: files pruned, files merged, any issues encountered.
```

**Agent 6 — Demoter/Consolidator:**
```
Read $KDIR/_meta/renormalize-plan.json.
Execute the "demote" actions: for each demote candidate, read the entry and rewrite it to reduce scope/prominence appropriate to the recommended level. If recommended_level is "subcategory", move the file to the appropriate subcategory directory (create it if needed). If recommended_level is "domain", move to domains/. Update the HTML metadata comment: set source to "renormalize-demote". Update any inbound backlinks that reference the old path.
Execute the "consolidate" actions: for each consolidation cluster, create a new parent entry with the specified parent_title. Read all entries in the cluster and combine their unique insights into subsections of the parent entry (following the proposed_structure). Preserve all backlinks and metadata. Delete the original entries after consolidation. Update any inbound backlinks to point to the new parent entry.
Report: entries demoted (with old/new paths), clusters consolidated (with parent paths), any issues encountered.
```

**Agent 7 — Budget Rebalancer:**
```
Read $KDIR/_meta/renormalize-plan.json.
Execute the "restructure" actions: create new subdirectories, move entries into appropriate groupings, update any backlinks that reference moved entries.
Report: categories restructured, entries moved, backlinks updated.
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

## Step 5: Cleanup and verification

Run post-execution maintenance:

```bash
lore heal --fix
```

Generate concordance-based backlinks — writes `See also:` links for high-similarity pairs not already cross-referenced:
```bash
python3 ~/.lore/scripts/pk_cli.py generate-backlinks "$KDIR"
```

Rebuild FTS5 search index:
```bash
python3 ~/.lore/scripts/pk_cli.py incremental-index "$KDIR"
```

Update manifest:
```bash
bash ~/.lore/scripts/update-manifest.sh
```

Clean up intermediate reports from `$KDIR/_meta/` — delete:
- `staleness-report.json`
- `usage-report.json`
- `merge-candidates.json`
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
