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

## Step 2b: Holistic Assessment (single agent)

Also run the merge-candidates analysis:
```bash
lore analyze merge-candidates
```

Spawn one Explore agent that performs an LLM-based holistic assessment of the knowledge store. This is an advisory classification — it does NOT modify files.

**Agent 3 — Holistic Assessment:**
```
You are assessing a knowledge store for renormalization. You will receive structured context (not raw files) and produce a classification report.

## Input context

Read the following reports:
- Entry index: $KDIR/_manifest.json (full entry list with titles, categories, metadata)
- Staleness report: $KDIR/_meta/staleness-report.json
- Usage report: $KDIR/_meta/usage-report.json
- Merge candidates: $KDIR/_meta/merge-candidates.json

## Tasks

### 1. Entry-by-entry significance classification

Classify each entry into one of 4 tiers:
- **architectural**: System-level, cross-cutting pattern or principle. A new developer needs this to understand how the system works.
- **subsystem**: Important within a specific domain or component. Needed to work effectively in that area.
- **implementation-detail**: Specific to one file, function, or script. Only needed to debug that component.
- **historical**: Was relevant during a past phase (migration, early design), no longer applies to the current system state.

Provide a 1-sentence rationale for each entry.

**Calibration — decision boundaries:**
- **architectural** vs **subsystem**: Does it affect how multiple subsystems interact or how the whole system is designed? If yes → architectural. If it matters only within one component (e.g., only the search subsystem, only the scripting layer) → subsystem.
- **subsystem** vs **implementation-detail**: Does it describe a pattern or convention for a component, or a specific behavior of a single function/file? Pattern → subsystem. Single function → implementation-detail.
- **implementation-detail** vs **historical**: Is the described behavior still present in the codebase? If yes → implementation-detail. If the feature was removed, the migration completed, or the approach superseded → historical.
- Key question: "Would a new developer need this entry to understand the system's architecture, or only to debug a specific component?"

**Calibration — reference examples** (from this store):
- **architectural**: "Push Over Pull" (principles/push-over-pull.md) — system-wide design principle affecting knowledge delivery, agent prompts, and skill design
- **architectural**: "Four Integrated Components" (architecture/four-integrated-components.md) — defines the system's top-level structure
- **subsystem**: "Shell Script Conventions" (conventions/scripting/shell-script-conventions.md) — important for anyone writing scripts, but scoped to the scripting subsystem
- **subsystem**: "Budget-Based Context Loading" (architecture/knowledge-delivery/budget-based-context-loading.md) — critical for the knowledge delivery subsystem, not cross-cutting
- **implementation-detail**: "generate-tasks.py Calls pk_search.py via Subprocess" (architecture/generate-tasks-py-calls-pk-search-py-via-subprocess-not-pyth.md) — documents one function's implementation choice in one script
- **implementation-detail**: "Bash Functions That Need to Return Multiple Values" (conventions/bash-functions-that-need-to-return-multiple-values.md) — specific coding pattern in specific files
- **historical**: Entries referencing completed format migrations, removed CLI commands, or early-stage design patterns that were replaced

Use these examples to anchor your judgments. When uncertain between two adjacent tiers, lean toward the lower tier (subsystem over architectural, implementation-detail over subsystem) — it is cheaper to under-classify and revisit than to over-classify and pollute high-priority loading.

**Read-on-demand protocol:** Make classification decisions from metadata first — title, category, learned date, confidence, backlink count, staleness score, usage tier. These signals are usually sufficient:
- Entries in `principles/` are likely architectural (verify via title)
- Entries in `gotchas/` with narrow titles (referencing a single script or function) are likely implementation-detail
- Entries with many backlinks are more likely subsystem or architectural
- Entries with low confidence or old learned dates paired with cold usage are candidates for historical
Only read the full entry file when the title is ambiguous or could reasonably belong to two tiers. Keep token cost proportional to ambiguity, not store size. Target: read <20% of entries in full.

### 2. Cluster identification

Identify groups of 2+ entries that describe the same concept at different granularities or from different angles. For each cluster, propose a consolidation structure (which entry becomes the parent, what subsections would it have). Use the merge-candidates report as a starting signal, but also identify semantic clusters below the 0.5 threshold that share the same insight in different words.

### 3. Structural imbalance report

Flag categories or subcategories where depth or entry count suggests restructuring (e.g., flat category with 50+ entries, subcategory with only 1 entry, inconsistent nesting depth).

### 4. Demotion candidates

Identify entries whose significance has likely decreased as the system matured — entries that were architectural during early development but are now implementation details of settled subsystems.

## Output

Write the report to $KDIR/_meta/assessment-report.json. This report is consumed directly by the planning step (Step 3) — every field should be pre-summarized and actionable without further LLM processing.

```json
{
  "generated": "<ISO timestamp>",
  "classifications": [
    {"path": "category/entry.md", "tier": "architectural|subsystem|implementation-detail|historical", "rationale": "One sentence explaining the classification."}
  ],
  "clusters": [
    {
      "concept": "Short name for the shared concept",
      "entries": ["path1.md", "path2.md"],
      "proposed_structure": "Which entry becomes the parent and what subsections it would have",
      "source": "merge-candidates|semantic-analysis|both"
    }
  ],
  "imbalances": [
    {"category": "category/subcategory", "issue": "What's wrong (e.g., 54 flat entries, inconsistent nesting)", "recommendation": "Specific action (e.g., create subcategories X, Y, Z)"}
  ],
  "demotions": [
    {"path": "category/entry.md", "from_tier": "architectural", "to_tier": "implementation-detail", "rationale": "Why significance decreased."}
  ],
  "summary": {
    "total_classified": 0,
    "architectural": 0,
    "subsystem": 0,
    "implementation_detail": 0,
    "historical": 0,
    "clusters_found": 0,
    "demotions_recommended": 0,
    "entries_read_in_full": 0
  }
}
```

The `entries_read_in_full` count in the summary tracks how many entries you read beyond metadata — this helps calibrate the read-on-demand protocol over time.

Report the summary back via SendMessage when complete.
```

Wait for the assessment agent to complete and acknowledge its report.

## Step 3: Planning (lead synthesizes)

Read the three reports:
- `$KDIR/_meta/staleness-report.json`
- `$KDIR/_meta/usage-report.json`
- `$KDIR/_meta/assessment-report.json`

Also read the merge-candidates data:
- `$KDIR/_meta/merge-candidates.json`

Synthesize a renormalization plan with these actions:

1. **Prune list:** Entries that are BOTH stale (from staleness report) AND cold (from usage report). Entries classified as *historical* by the assessment with low usage are strong prune candidates. These are safe to remove — they are outdated and unused.
2. **Fix list:** Entries that are stale (from staleness report) AND hot or warm (from usage report). These are actively used but drifted — they need content rewrite against current code, not removal.
3. **Merge list:** Entries flagged as highly similar by merge-candidates report (similarity >= 0.5) or identified as near-duplicates by the assessment. Group them into merge sets.
4. **Demote list:** Entries the assessment classified at a higher significance tier than their content warrants (e.g., top-level entry that is really an implementation detail). These get rewritten to reduce scope or moved to a subcategory/domain file. The information is correct, just overpromoted.
5. **Consolidate list:** Entry clusters identified by the assessment — multiple entries describing the same concept at different granularities. These get merged into a parent entry with subsections, preserving all unique insights. Different from merge (which is dedup of near-identical content).
6. **Restructure list:** Categories with structural imbalances flagged by the assessment (>20 flat entries, inconsistent nesting depth) that should be split into subcategories or promoted to domain files.

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
  "summary": {"prune_count": 5, "fix_count": 2, "merge_count": 3, "demote_count": 4, "consolidate_count": 2, "restructure_count": 1}
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

Approve? (yes / yes with changes / no)
```

**Wait for user approval before proceeding.** If the user requests changes, update the plan and re-present. If rejected, delete `$KDIR/_meta/renormalize-plan.json` and stop.

## Step 4: Execution (sequenced + parallel agents)

After approval, execute in two waves. Agent 3 runs first so merge and restructure operate on fresh content.

### Wave 1: Fix stale entries

**Agent 3 — Entry Fixer:**
```
Read $KDIR/_meta/renormalize-plan.json.
Execute the "fix" actions: for each fix-candidate entry, read the entry file and each of its related_files from the repo. Compare the entry's claims to current code. Rewrite the entry preserving format:
- Keep the H1 title (# heading)
- Rewrite prose to match current code behavior
- Preserve or update See also: backlinks
- Update the HTML metadata comment: set `learned` date to today, set `source: renormalize-fix`
If a related_file is missing from the repo, skip that entry and report it.
Report: entries fixed, entries skipped (with reasons), any issues encountered.
```

Wait for Agent 3 to complete before proceeding to Wave 2.

### Wave 2: Prune, merge, demote, consolidate, and restructure (parallel)

Spawn 3 general-purpose agents:

**Agent 4 — Merger/Pruner:**
```
Read $KDIR/_meta/renormalize-plan.json.
Execute the "prune" actions: delete each listed file.
Execute the "merge" actions: for each merge set, combine content from source entries into the target entry (preserve all unique insights, deduplicate, update backlinks), then delete the source files.
Report: files pruned, files merged, any issues encountered.
```

**Agent 5 — Demoter/Consolidator:**
```
Read $KDIR/_meta/renormalize-plan.json.
Execute the "demote" actions: for each demote candidate, read the entry and rewrite it to reduce scope/prominence appropriate to the recommended level. If recommended_level is "subcategory", move the file to the appropriate subcategory directory (create it if needed). If recommended_level is "domain", move to domains/. Update the HTML metadata comment: set source to "renormalize-demote". Update any inbound backlinks that reference the old path.
Execute the "consolidate" actions: for each consolidation cluster, create a new parent entry with the specified parent_title. Read all entries in the cluster and combine their unique insights into subsections of the parent entry (following the proposed_structure). Preserve all backlinks and metadata. Delete the original entries after consolidation. Update any inbound backlinks to point to the new parent entry.
Report: entries demoted (with old/new paths), clusters consolidated (with parent paths), any issues encountered.
```

**Agent 6 — Budget Rebalancer:**
```
Read $KDIR/_meta/renormalize-plan.json.
Execute the "restructure" actions: create new subdirectories, move entries into appropriate groupings, update any backlinks that reference moved entries.
Report: categories restructured, entries moved, backlinks updated.
```

Wait for all agents to complete and review their reports for any errors.

## Step 5: Cleanup and verification

Run post-execution maintenance:

```bash
lore heal --fix
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
  Index rebuilt, manifest updated, heal passed.
```
