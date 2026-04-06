### Risk-Tier Triage

Before applying lenses or the review checklist, classify the PR into a risk tier. This determines review depth and lens selection defaults. The triage is a lookup based on three signals — not a judgment call.

#### Size assessment

| Diff size (LOC changed) | Classification | Action |
|------------------------|----------------|--------|
| 1-200 | Standard | Normal review depth |
| 201-400 | Large | Note in triage output; review at normal depth but flag for attention |
| >400 | Oversized | Flag prominently; recommend splitting; if proceeding, note reduced defect detection rate |

LOC is counted from `gh pr diff --stat` (additions + deletions). The >400 threshold is based on the SmartBear/Cisco finding that defect discovery rates drop significantly beyond 400 LOC.

#### Change type classification

Classify the PR by the highest-risk change type present in the diff. A PR touching both docs and auth code is classified as high-risk.

| Risk tier | Change types | Effect on review |
|-----------|-------------|-----------------|
| High | Authentication, authorization, cryptography, secrets handling, payment/billing, data migration, security configuration | Security lens always selected; all lenses apply elevated scrutiny |
| Standard | Business logic, API endpoints, data models, infrastructure, CI/CD | Normal lens selection via criteria table |
| Low | Documentation, comments, style/formatting, test-only changes, dependency bumps (patch) | Expedited review; default lenses sufficient; skip Investigation Escalation |

#### Triage output

Present the triage summary to the user before proceeding:

```
Risk tier: [High/Standard/Low]
Size: [N LOC] — [Standard/Large/Oversized]
Change types detected: [list]
Proposed lenses: [list from adaptive selection]
```

The user confirms or adjusts before any lens work begins.

