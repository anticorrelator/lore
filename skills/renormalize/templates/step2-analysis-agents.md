# Assessment briefs — classifier, structure analyst, cross-reference scout

Read this file from `skills/renormalize/SKILL.md` Step 3. Three read-only judgment briefs, dispatched in parallel through the probed route. None modifies knowledge files.

For each role and each retry, run `lore dispatch guidance` immediately before launch; if it fails, do not launch that brief. Assemble the prompt in this order: that invocation's complete guidance output verbatim, the resolved agent template, then the SKILL.md report contract block. Do not share one rendered block across the three roles.

Resolve templates through `resolve_agent_template <name>` (sourced from `~/.lore/scripts/lib.sh`) and inject:

- `{{kdir}}` — the resolved knowledge directory
- `{{team_name}}` — the run id (`$RUN_ID`)
- `{{team_lead}}` — the lead's identity for this run
- `{{audit_set}}` — classifier only: the `entries` array from `$KDIR/_meta/audit-set.json`

| Role | Template | Findings artifact |
|---|---|---|
| classifier | `resolve_agent_template classifier` | `$KDIR/_meta/classification-report.json` |
| structure-analyst | `resolve_agent_template structure-analyst` | `$KDIR/_meta/structure-report.json` |
| crossref-scout | `resolve_agent_template crossref-scout` | `$KDIR/_meta/crossref-report.json` |

The classifier audits only the audit set. Each agent writes its own findings JSON; the contract report indexes that artifact. Acceptance additionally checks the findings file landed and parses as JSON.
