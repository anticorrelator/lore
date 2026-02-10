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

## Step 3: Planning (lead synthesizes)

Read the two reports:
- `$KDIR/_meta/staleness-report.json`
- `$KDIR/_meta/usage-report.json`

Synthesize a renormalization plan with these actions:

1. **Prune list:** Entries that are BOTH stale (from staleness report) AND cold (from usage report). These are safe to remove — they are outdated and unused.
2. **Merge list:** Entries flagged as redundant or highly similar (same category, overlapping content). Group them into merge sets.
3. **Restructure list:** Categories with >20 entries that should be split into subcategories or promoted to domain files.

Write the plan to `$KDIR/_meta/renormalize-plan.json` with structure:
```json
{
  "generated": "<ISO timestamp>",
  "prune": [
    {"path": "category/entry.md", "reason": "stale (age: 180d) + cold (0 retrievals)"}
  ],
  "merge": [
    {"target": "category/kept.md", "sources": ["category/dup1.md", "category/dup2.md"], "reason": "overlapping content"}
  ],
  "restructure": [
    {"category": "conventions", "action": "split", "proposed": ["conventions/naming", "conventions/testing"], "reason": "32 entries, natural grouping exists"}
  ],
  "summary": {"prune_count": 5, "merge_count": 3, "restructure_count": 1}
}
```

Present the plan to the user in a readable format:
```
[renormalize] Proposed plan:
  Prune: N entries (stale + unused)
  Merge: N redundant entry sets
  Restructure: N categories

Details:
  [list each action with path and reason]

Approve? (yes / yes with changes / no)
```

**Wait for user approval before proceeding.** If the user requests changes, update the plan and re-present. If rejected, delete `$KDIR/_meta/renormalize-plan.json` and stop.

## Step 4: Execution (parallel agents)

After approval, spawn 2 general-purpose agents:

**Agent 1 — Merger/Pruner:**
```
Read $KDIR/_meta/renormalize-plan.json.
Execute the "prune" actions: delete each listed file.
Execute the "merge" actions: for each merge set, combine content from source entries into the target entry (preserve all unique insights, deduplicate, update backlinks), then delete the source files.
Report: files pruned, files merged, any issues encountered.
```

**Agent 2 — Budget Rebalancer:**
```
Read $KDIR/_meta/renormalize-plan.json.
Execute the "restructure" actions: create new subdirectories, move entries into appropriate groupings, update any backlinks that reference moved entries.
Report: categories restructured, entries moved, backlinks updated.
```

Wait for both agents to complete and review their reports for any errors.

## Step 5: Cleanup and verification

Run post-execution maintenance:

```bash
lore heal --fix
```

Rebuild FTS5 search index:
```bash
python3 ~/.lore/scripts/pk_cli.py incremental-index --knowledge-dir "$KDIR"
```

Update manifest:
```bash
bash ~/.lore/scripts/update-manifest.sh
```

Clean up intermediate reports from `$KDIR/_meta/` — delete:
- `staleness-report.json`
- `usage-report.json`
- `renormalize-plan.json`

**Keep** these logs (they have ongoing value):
- `retrieval-log.jsonl`
- `friction-log.jsonl`

Delete the team (`renorm-*`).

Report the final summary:
```
[renormalize] Complete.
  Pruned: N entries
  Merged: N entry sets (M source files consolidated)
  Restructured: N categories
  Index rebuilt, manifest updated, heal passed.
```
