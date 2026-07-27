# Self-Test Results Template

Write this template to `$RESULTS_FILE` in Step 4. Fill in every X, Y, N placeholder; preserve all section headings and the metadata layout — `/retro`, `/evolve`, and inter-run delta computation all parse this structure literally.

```markdown
# Self-Test Results — [YYYY-MM-DD] (Run N)

## Infrastructure
| Layer | Status |
|-------|--------|
| Knowledge index | yes/no (N core + N domain) |
| Threads | N found (N pinned, N active, N dormant) |
| Work | N active, N archived |
| FTS5 search | yes/no (N files, N entries, size) |
| Previous results | yes/no (Run N) |

## Scores
| Test | Score | Notes |
|------|-------|-------|
| 1. Orientation | X/5 | depth: X/2 breadth: X/3 |
| 2. Retrieval Value | X/5 | accuracy: X/3 completeness: X/3 efficiency: X% eliminated |
| 3. Backlinks | X hops, X dead ends, X% connected | |
| 4. Thread Awareness | X/5 actionability | N behaviors evidenced |
| 5. Plan Continuity | X/5 actionability | N missing-context items |
| 6. Knowledge Utilization | X/5 | utilization: X/5 capture: X/5 |
| 7a. Search Relevance | X/5 | |
| 7b. Resolution | X/X resolved | |
| 7c. Link Integrity | X real breaks, X FP (ratio: X%) | |
| 8. Freshness and Trust | X/5 | X/3 fresh, X/3 aging, X/3 stale |

**Run metadata:**
- Date: YYYY-MM-DD
- Run number: N (auto-incremented from previous results, or 1 if first run)
- Tool calls: X total (X knowledge-system, X raw-search, X infrastructure/utility)
- Bypasses: X (see bypass log)

## Comparison with Previous Results
[If first run: "Baseline run — no previous results to compare."

If previous results were loaded in Step 1, compute:

### Score Delta
| Test | Previous | Current | Change |
|------|----------|---------|--------|
For each test, show the previous score, current score, and a direction indicator:
- `+N` or `improved` for improvements
- `-N` or `regressed` for regressions
- `=` for unchanged
- `new` for tests that didn't exist in the previous run

### Regressions
List any tests where the score dropped. For each regression, note the likely cause from the test results.

### Improvements
List any tests where the score improved. Note what changed.

### Recommendation Resolution
For each recommendation from the previous run, check if it was addressed:
- `[resolved]` — the issue was fixed (cite evidence)
- `[open]` — still unresolved
- `[superseded]` — replaced by a different approach

### Infrastructure Changes
Note any layers that were added or removed since last run.]

## Test Results
[For each test: what happened, what you noticed, specific evidence and findings]

## Fixes Applied (Step 3)
[For each entry fixed or deferred during Step 3:

**Fixed:**
- `<entry path>`: <what was corrected> (e.g., updated file path from `old/path` to `new/path`)

**Deferred to /renormalize:**
- `<entry path>`: <drift reason> — <why deferred> (e.g., core claim outdated, requires full rewrite)

If no aging/stale entries were found in Test 8, note: "No fixes needed — all spot-checked entries were fresh."

## Bypass Log
[Every time you used Grep/Glob/Explore instead of the knowledge system, note why.
Format: Test X.Y — Bypassed because: reason]

## Recommendations
[Specific, actionable changes that would improve the system.]

## Work Items Created
[Work items created from this run's findings. Format:
- `work-item-slug` — brief description (from recommendation #N)
- ...
If no work items warranted, note why.]

## Protocol Changes (Run N)
Evolution suggestions logged to journal this run:
- [Test X]: <what was suggested and why>
- [New]: <any new test dimensions suggested>

Rationale: <1-2 sentences on what this run taught about self-diagnosis>
```
