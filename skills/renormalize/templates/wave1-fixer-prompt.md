# Wave 1 — Entry Fixer prompt template

Read this file from `skills/renormalize/SKILL.md` Wave 1 when spawning Agent 4 (Entry Fixer). The block below is the verbatim agent prompt body.

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
