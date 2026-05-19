# Step 2 — Analysis agent prompts

Read this file from `skills/renormalize/SKILL.md` Step 2 when spawning the two parallel Explore agents (Staleness scan + Usage analysis).

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
