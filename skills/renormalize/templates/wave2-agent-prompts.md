# Wave 2 — agent prompt templates

Read this file from `skills/renormalize/SKILL.md` Wave 2 when spawning the four general-purpose agents (Merger/Pruner, Demoter/Consolidator, Budget Rebalancer, Backlink Writer). Each prompt block below is the verbatim body to inject into the agent's Task call.

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
