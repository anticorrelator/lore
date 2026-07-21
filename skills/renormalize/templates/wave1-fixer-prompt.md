# Wave 1 — entry fixer brief

Read this file from `skills/renormalize/SKILL.md` Step 5 Wave 1. The block below is the brief body: inject `$KDIR`, the work-item slug, and the assigned entry set; append the report contract; dispatch. Wave 1 reports must be accepted before any Wave 2 dispatch.

```
Read $KDIR/_meta/renormalize-plan.json and execute the "fix" actions for your assigned entries.

For each entry:
1. Read the entry file and each of its related_files in the repo. Compare every claim to
   current code.
2. Before rewriting, search the store at the entry's declared scale for newer coverage:
   lore search "<entry topic>" --scale-set <entry's declared scale> --caller renormalize-fix --limit 5
   If a current entry already covers the drifted ground, do not rewrite — report the pair as a
   status-update candidate (current → superseded, with the successor path) and move on.
3. Record each claim you check against code:
   lore verify <entry-path> held --source worker ...
   or `contradicted` (adding --work-item, --rationale, --claim-text, --falsifier). Both
   dispositions require the grounding file, line range, and exact snippet.
4. Rewrite the entry against current code, preserving format: keep the H1 title, rewrite prose
   to match current behavior, preserve or update See also: backlinks, and in the HTML metadata
   comment set `learned` to today and `source: renormalize-fix`.
5. Append one Tier-2 row per rewritten claim, grounded in the code you verified against
   (evidence-append.sh, per the report contract).

If a related_file is missing from the repo, skip that entry and report it.

The fix list includes stale members of consolidation clusters. Fix them now — Wave 2
consolidation must combine fresh content. Never skip an entry because it will later be
consolidated.
```
