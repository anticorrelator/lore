# Wave 2 — mutation batch briefs

Read this file from `skills/renormalize/SKILL.md` Step 5 Wave 2. Four role briefs follow. For each batch and retry, run `lore dispatch guidance` immediately before launch; if it fails, do not launch that brief. Assemble the prompt from that invocation's complete guidance output verbatim, the applicable role sections with `$KDIR`, the work-item slug, and the batch's action subset injected, then the report contract. When roles are merged into one batch, run their sections in the order listed here.

Shared rules for every batch:

- Write only files in your batch's ownership set. An action whose target you do not own is a report-and-skip, never a write.
- After every file move, emit the trust migration so the entry's trust history follows it (failure is a warning, not a stop):
  ```
  bash ~/.lore/scripts/trust-event-migrate.sh --from-entry-path <old-path> --to-entry-path <new-path> \
    --reason renormalize-restructure --source renormalize --kdir $KDIR
  ```
  Paths are KDIR-relative. This is the only trust surface in the flow — never write trust records directly.
- Update inbound backlinks for every path you move or delete.
- Report per the contract: actions executed, rejected, and skipped, with paths and reasons.

**Merger/Pruner:**
```
Read $KDIR/_meta/renormalize-plan.json.
Execute your "prune" actions: delete each listed file.
Execute your "merge" actions, applying the scale-check rule FIRST for each set:
1. Read the scale: field from the HTML metadata comment of every entry in the set (target + sources).
2. All same scale → merge.
3. Cross-scale AND the target is tagged `bridging: true` or lives under `bridging-entries/` →
   merge; the bridging entry becomes the parent. For each cross-scale source, add a
   `supersedes: <source-path>` edge to the target's See also: section followed by the comment
   <!-- cross-scale child via renormalize-merge -->, then delete the source files as normal.
4. Cross-scale with no bridging target → do NOT merge. Log:
   "REJECTED merge of [sources] into [target]: spans scales [list]. Use consolidate action instead."
   Continue with the next set; never abort the run.
For allowed merges: combine content from sources into the target (preserve all unique insights,
deduplicate, update backlinks), then delete the source files.
```

**Demoter/Consolidator:**
```
Read $KDIR/_meta/renormalize-plan.json.
Execute your "demote" actions: rewrite each entry to the scope of its recommended level. If the
level is "subcategory", move the file into the appropriate subcategory directory (create if
needed); if "domain", move to domains/. Set source: renormalize-demote in the HTML metadata
comment. Update inbound backlinks; emit the trust migration for each move.

Execute your "consolidate" actions, scale-aware:
1. Read the scale: field from each cluster member's HTML metadata comment.
2. Same-scale cluster → standard consolidate: create the parent entry at that scale with the
   plan's parent_title, combine unique insights into subsections per proposed_structure,
   preserve backlinks and metadata, delete the originals, and repoint inbound backlinks to
   the parent.
3. Cross-scale cluster → execute the matching "consolidate-bridge" action: create the bridging
   parent at the plan's parent_scale with `bridging: true` in its metadata; do NOT delete
   lower-scale members — add `parent: <bridge-entry>` to each child's metadata instead; update
   inbound backlinks to reference both child and bridge; write a summary subsection in the
   bridge linking each child. Report the bridge path and every child with its preserved scale.
```

**Budget Rebalancer:**
```
Read $KDIR/_meta/renormalize-plan.json.
Execute your "restructure" actions, checking split_by_scale on each:
- false or absent → create topic-keyed subdirectories and move entries into their groupings.
- true → create scale-keyed subdirectories under the category and move each entry into the
  subdirectory matching its scale: field.
Update inbound backlinks for every moved entry; emit the trust migration for each move.
```

**Backlink Writer:**
```
Read $KDIR/_meta/assessment-report.json.
For each suggested_backlinks item: skip if [[knowledge:<target>]] already appears anywhere in
the source file. Otherwise append to the source's See also: section (create one at the end of
the file, after a blank line, if absent):

See also: [[knowledge:<target-entry>]]
<!-- source: renormalize-backlinks -->

The provenance comment MUST sit on the line immediately after the backlink — structural
importance weights links carrying it at 0.8 versus 1.0 for explicit backlinks.
```
