---
name: self-test
description: Evaluate the lore memory system — run structured tests across 8 dimensions and produce scored, comparable results
user_invocable: true
argument_description: "[optional: 'quick' for abbreviated run (Tests 1, 2, 7 only)]"
---

# /self-test Skill

Run a structured evaluation of the lore memory system from any codebase. Tests 8 dimensions of system health, produces scored results, and compares against previous runs to track regressions and improvements.

**The core question:** Does the memory system make you effective, or do you find yourself bypassing it?

**Design principle:** Tests should surface *actionable findings*, not confirm what's already working. If a test scores 5/5 for 2+ consecutive runs, it should either get harder or be replaced with something that produces signal.

## Step 0: Resolve Paths and Detect Infrastructure

### Path Resolution

```bash
lore resolve
```

Set `KNOWLEDGE_DIR` to the result. Derive all other paths from it:

- `MANIFEST_FILE` = `$KNOWLEDGE_DIR/_manifest.json`
- `THREADS_DIR` = `$KNOWLEDGE_DIR/_threads`
- `WORK_DIR` = `$KNOWLEDGE_DIR/_work`
- `INBOX_DIR` = `$KNOWLEDGE_DIR/_inbox`
- `RESULTS_FILE` = `$KNOWLEDGE_DIR/_self_test_results.md`

### Infrastructure Detection

Before running tests, detect what infrastructure exists. Read each path and record availability. This determines which tests can run and which score N/A.

| Layer | Check | Variable |
|-------|-------|----------|
| Knowledge store | Category directories exist with `.md` entries | `HAS_ENTRIES` |
| Manifest | `_manifest.json` exists | `HAS_MANIFEST` |
| Threads | `_threads/` has thread directories with `.md` entry files (v2) or monolithic `.md` files (v1) | `HAS_THREADS` |
| Work | `_work/` has subdirectories with `_meta.json` files | `HAS_WORK` |
| FTS5 search | `lore search` and `lore stats` work | `HAS_SEARCH` |
| Inbox | `_inbox/` directory exists | `HAS_INBOX` |
| Previous results | `_self_test_results.md` exists | `HAS_PREVIOUS` |

Report infrastructure status before proceeding:
```
[self-test] Infrastructure detected:
  Knowledge entries: yes/no (N entries across N categories)
  Threads: N found (N pinned, N active, N dormant)
  Work: N active, N archived
  FTS5 search: yes/no (N files, N entries)
  Previous results: yes/no (Run N)
```

If `HAS_ENTRIES` is false (no category directories with `.md` files), the knowledge store is empty. Report this and suggest running `/memory init`. Stop the test — there's nothing meaningful to evaluate.

### Load Previous Results

If `HAS_PREVIOUS` is true, read `$RESULTS_FILE` and extract:
1. **Scores table** — parse the `## Scores` markdown table. Store each test's score for comparison.
2. **Run number** — from the title line `# Self-Test Results — [date] (Run N)`. The current run is N+1.
3. **Previous recommendations** — parse the `## Recommendations` section. Store each bullet for resolution tracking.
4. **Previous bypass log** — parse `## Bypass Log` to compare bypass patterns.

If parsing fails (malformed results file), note this in the output and treat as first run.

### Quick Mode

If the argument is "quick", only run Tests 1, 2, and 7. Skip the rest and mark them as "Skipped (quick mode)" in results.

## Step 1: Initialize Tracking

Set up tracking counters for the entire run:
- `TOOL_CALLS` = 0 (increment each time you use Read, Glob, Grep, Bash, or any tool)
- `KNOWLEDGE_CALLS` = 0 (subset: tool calls that read from `$KNOWLEDGE_DIR`)
- `RAW_SEARCH_CALLS` = 0 (subset: Grep/Glob/Explore calls outside `$KNOWLEDGE_DIR`)
- `BYPASS_LOG` = [] (each entry: test number, what you bypassed, why)

Be honest about counting. Every tool invocation counts. The ratio of knowledge-system to raw-search calls is diagnostic.

## Test 1: Orientation

**Purpose:** Evaluate what the session-start hooks loaded into context — both breadth (what exists) and depth (what it says).

Without reading any files or running any searches, answer these questions using only what was loaded at session start.

**Breadth questions (2):**
1. What knowledge categories exist and what does each hold?
2. What is the directory layout of the knowledge store?

**Synthesis question (1) — requires combining information across categories:**
3. Pick a principle from `principles.md` and trace its influence through the system: identify at least one convention it generates, one gotcha it addresses, and one workflow or script that implements it. Explain the causal chain. This tests whether you absorbed the relationships between categories, not just each category in isolation.

**Depth questions (2) — these test whether you internalized content, not just structure:**
4. Name a specific gotcha and describe its mitigation from memory. Then identify a convention or workflow entry that relates to it and explain the connection. If you can only name the heading but not the substance, that's partial credit. Full credit requires demonstrating the cross-reference — how two entries in different files connect.
5. Describe a specific convention and when it applies. Then identify a gotcha or architecture entry it was designed to address. Again — substance and cross-reference, not just the heading.

**Note (Run 6):** Test 1 scored 5/5 for 6 consecutive runs (Runs 1-6). The synthesis question (added Run 5) scored 5/5 on first attempt — answerable because principles are loaded at session start with See-also links that provide the traversal path. If 5/5 persists in Run 7, raise the bar: require tracing a principle to a specific code implementation line (function name, line number), not just naming the script.

**Scoring:** X/5 questions answered confidently with specific, accurate details. Breadth questions that only require listing score normally. Depth questions require demonstrating you absorbed the actual content AND can connect it to related entries in other files, not just that you saw the heading in a summary.

**Record:** For each depth question, note whether your answer included concrete details (mitigations, conditions, examples) AND a valid cross-reference. Vague = not confident = doesn't count. Cross-reference missing = partial credit only.

## Test 2: Retrieval Value

**Purpose:** Measure whether knowledge store entries provide accurate, useful answers to real questions about this codebase — faster and more completely than starting from scratch.

This test replaced the previous "Retrieval Race" (Runs 1-2) which compared knowledge reads vs Grep. That comparison was structurally decided by architecture (knowledge data is outside the logic repo), producing no diagnostic signal.

**Procedure:**

1. Run `lore index` to identify 3 diverse topics that have knowledge entries.
2. For each topic, formulate a *practical implementation question* — the kind of question you'd actually ask while working on this codebase. Examples: "What happens if I archive a work item with active backlinks?" or "How should I add a new script to the hook system?"
3. Answer each question using only the knowledge store (read the relevant category file, follow backlinks).
4. Then verify each answer by reading the actual source code or scripts referenced. Note:
   - **Accurate:** Knowledge answer matched code reality
   - **Stale:** Knowledge answer was once true but code has changed
   - **Incomplete:** Knowledge was correct but missed important details the code reveals
   - **Wrong:** Knowledge contradicts what the code actually does

**Scoring:**
- Accuracy: X/3 answers fully accurate when verified against code
- Completeness: X/3 answers had no significant gaps
- Overall: (Accuracy + Completeness) / 6, mapped to a 1-5 scale

**Record:** For each question, note whether the knowledge entry alone would have been sufficient for someone implementing a feature, or whether they'd need to read code anyway. This is the real measure of knowledge value.

## Test 3: Backlink Navigation

**Purpose:** Test the cross-reference network quality — both traversability and density.

**Requires:** `HAS_ENTRIES` = true. If false, score as N/A.

**Traversal test:**
Run `lore index` to list all entries. Pick any entry and follow its `[[backlinks]]` to find related context across files. Try to traverse at least 3 hops. Attempt a cross-type chain (e.g., knowledge → work → thread, or gotchas → conventions → architecture).

**Connectivity audit:**
While traversing, count:
- Entries that have `See also:` backlinks (connected)
- Entries that have no outgoing references (isolated)
- Entries where you expected a cross-reference but didn't find one (missing links)

**Scoring:**
- Hops completed: X. Dead ends: X.
- Connectivity: X% of traversed entries have outgoing links
- Missing links identified: X (these become recommendations)

**Record:** Note any missing cross-references you'd expect to exist. These are actionable — they can be added.

## Test 4: Thread Awareness

**Purpose:** Evaluate whether conversational threads provide actionable session context — measured by concrete behavioral evidence, not self-assessment.

**Requires:** `HAS_THREADS` = true. If false, score as N/A with note: "No threads exist yet. Create threads to enable this test."

**Procedure:**
1. List `.md` files in `$THREADS_DIR` (exclude `_index.json` or other non-thread files).
2. For each thread, read frontmatter to identify `tier` (pinned/active/dormant) and `topic`.
3. Read the most recent entry of each pinned and active thread.

**Behavioral evidence test:**
For each thread, identify:
- A **specific behavior** you exhibited this session that was shaped by thread content. Not "I was aware of X" but "I did Y because the thread said Z." If you can't identify a specific behavior, that thread scored no impact.
- A **shift or decision** recorded in the thread that you would have gotten wrong without it. E.g., a preference that contradicts what you'd assume by default.

**Scoring:** Actionability (1-5):
- 5: Multiple specific behaviors directly shaped by thread content, with at least one you'd have gotten wrong without it
- 4: At least one clear behavior shaped, plus general awareness that improved approach
- 3: Thread content was useful context but didn't measurably change any specific action
- 2: Threads were loaded but you can't point to any concrete impact
- 1: Threads had no discernible effect on session behavior

**Record:** List the specific behaviors and which thread entries produced them. This is the evidence.

**Note (Run 6):** Thread Awareness has been 3/5 for 3 consecutive runs (Runs 4-6). This reflects a structural ceiling when the self-test is the session's primary activity — threads are most impactful during implementation sessions where they can prevent wrong assumptions. If 3/5 persists for 2+ more runs, consider restructuring this test to evaluate thread quality directly (entry specificity, shift documentation accuracy, backlink density) rather than behavioral impact, which requires implementation context the self-test doesn't generate.

## Test 5: Plan Continuity

**Purpose:** Evaluate whether work items provide enough context for a fresh instance to pick up work — tested by actually attempting it, not hypothetically assessing.

**Requires:** `HAS_WORK` = true. If false, score as N/A with note: "No work items exist. Create work items to enable this test."

**Procedure:**
1. Read `$WORK_DIR/_index.json` to list all work items with their status.
2. Pick an active work item (prefer one with unchecked plan tasks).
3. Read its `plan.md` and the last 2-3 entries of `notes.md`.

**Cold-start exercise:**
Pretend you're a fresh instance with no prior conversation context. Using only the plan and notes:
1. Write out the **exact next 3 actions** you'd take to continue this work (specific file reads, commands, or edits — not vague descriptions).
2. Identify any **missing context** — questions you'd need answered that the plan doesn't address.
3. Check whether the design decisions in the plan are specific enough to prevent you from making a wrong choice.

**Backlink freshness check (added Run 4):**
Pick 2-3 `[[knowledge:...]]` backlinks from the plan's Knowledge context or Related sections and resolve them with `lore resolve`. Are the referenced sections still accurate for this plan's purposes? A plan with stale backlinks gives implementers misleading context.

**Note (Run 4):** Test 5 scored 5/5 for 3 consecutive runs (Runs 2-4). The backlink freshness sub-dimension tests plan freshness alongside plan completeness — catching the failure mode where plans reference knowledge entries that have drifted since the plan was written.

**Scoring:** Actionability (1-5):
- 5: All 3 next-actions are concrete and correct; no missing context
- 4: Actions are mostly concrete; 1 minor question that doesn't block work
- 3: Actions are directionally right but vague; 1-2 real questions needed
- 2: Could describe the goal but not the next steps; multiple questions needed
- 1: Insufficient context to begin work

**Record:** The 3 next-actions and any missing context. The missing context items become recommendations for improving the plan.

## Test 6: Knowledge Utilization and Capture

**Purpose:** Audit whether the knowledge system was actually used during real work this session — not in a test environment, but during the productive work that preceded this self-test. This is the core success metric from the how-we-work thread.

This test replaced the previous "Capture Protocol" test (Runs 1-2) which artificially tested capture by reading a script during the test itself. That test couldn't detect the real failure mode: knowledge being bypassed during actual work.

**Part A — Utilization audit:**
Review what happened in this session *before* the self-test was invoked. Answer:

1. **Was the knowledge store consulted before raw exploration?** Identify moments where you (or spawned agents) explored code. For each, was the knowledge store checked first?
   - If yes: which entries helped?
   - If no: would an entry have been useful? (Check the store now to find out.)
2. **Were there knowledge-search bypasses?** Moments where you defaulted to Grep/Glob/Read for information the store already had. Count them.
3. **Did spawned agents use the knowledge store?** If `/implement` or `/spec` was used, did the worker agents actually resolve backlinks and search knowledge, or did they skip straight to code?

If this is the first action in the session (no real work preceded the self-test), note "No prior work to audit" and score based on the protocol's readiness: are the hooks, skill prompts, and agent instructions set up to make knowledge utilization likely?

**Note (Run 5):** Capture scoring should not give a free pass to "light" sessions. Conversational sessions where genuine insights emerge (e.g., identifying structural gaps, recognizing thread usage patterns, noting maintenance debt) still warrant captures. If the 4-condition gate is met, the session type is irrelevant. Score capture based on whether capturable insights were present, not on whether code was written.

**Part B — Capture audit:**
Review the session for capture opportunities:

1. **What was captured?** Count inbox entries created this session (check file timestamps in `$INBOX_DIR` or review session actions).
2. **What was missed?** Identify 1-3 moments where the 4-condition gate (Reusable, Non-obvious, Stable, High confidence) was met but no capture occurred. If you can't find missed opportunities, that's a good sign.
3. **Were captures filed correctly?** Did `lore capture` write entries directly to category files, or are there unfiled entries in the inbox?

**Scoring:**
- Utilization: X/5 (5=knowledge checked first every time, 1=never consulted)
- Capture: X/5 (5=all opportunities caught and correctly filed, 1=many missed)
- Combined: average of both, reported as X/5

**Record:** List specific utilization moments and bypasses. These are the most actionable findings in the entire self-test — they reveal exactly where the system is failing to deliver value.

## Test 7: Search and Resolution

**Purpose:** Test the search and link resolution tooling.

### 7a: FTS5 Search

**Requires:** `HAS_SEARCH` = true. If false, score as N/A.

Run these searches:

```bash
lore search "backlinks"
lore search "session start"
lore stats
```

Were the top-3 results the right answers? Did snippets give enough context to decide relevance?

**Note (Run 6):** Known issue: archived work items (plans, investigation notes) are keyword-dense and consistently outrank knowledge entries in BM25 scoring. Test queries like "backlinks" and "session start" return archived plans as top results rather than the knowledge entries that summarize those patterns. This is a real system weakness — search should prioritize knowledge entries that represent distilled understanding over the verbose source material. Track whether `--type knowledge` or boost factors improve this.

### 7b: Backlink Resolution

Pick a `See also: [[...]]` reference from any knowledge file and resolve it:

```bash
lore resolve "[[knowledge:gotchas#Some Heading]]"
```

(Adapt the backlink reference to one that actually exists in the store.)

Did it return the exact section? Compare to manually reading the file.

### 7c: Link Integrity

```bash
lore check-links
```

How many broken links? Are they real breaks or false positives? Track the FP ratio (false positives / total reported) across runs — a rising ratio means the checker needs improvement.

**Scoring:**
- Search relevance (1-5): Were top results the right answers?
- Resolution accuracy: X/X resolved correctly.
- Broken links: X real, X false positive (FP ratio: X%).

## Test 8: Freshness and Trust

**Purpose:** Verify that knowledge entries are accurate against current code — not just trusted in the abstract, but spot-checked for staleness.

This test replaced the previous "Honest Assessment" (Runs 1-2) which asked hypothetical self-assessment questions. Those questions consistently scored 5/5 without surfacing any findings.

**Persistent staleness escalation (Run 5):** If the same entry is flagged as stale for 3+ consecutive runs, it's no longer a recommendation — it's a systemic maintenance failure. Flag it prominently in the results and recommend creating a dedicated work item to address the maintenance backlog. The self-test protocol shouldn't just observe staleness; it should escalate when repeated observation fails to produce action.

**Spot-check procedure:**
1. Pick 3 knowledge entries from different category files (prefer entries >7 days old, or entries that reference specific code paths/scripts). If an entry was stale in the previous run, re-check it — persistent staleness is a stronger signal than new staleness.
2. For each entry, verify its claims against the actual code:
   - Read the referenced files/scripts
   - Check: is the described behavior still accurate?
   - Check: are referenced paths/filenames still correct?
   - Check: are the `See also:` backlinks still valid?

**Scoring by entry:**
- **Fresh:** All claims verified, references valid
- **Aging:** Minor inaccuracies (renamed variable, changed default) but substance correct
- **Stale:** Key claims no longer match code — entry needs updating
- **Wrong:** Entry contradicts current behavior — dangerous if trusted

**Overall scoring:**
- Freshness: X/3 entries fully fresh
- Trust: 1-5 scale based on findings:
  - 5: All spot-checked entries verified accurate
  - 4: Minor staleness found, substance still reliable
  - 3: 1 stale entry found — pattern may be broader
  - 2: Multiple stale entries — store needs maintenance pass
  - 1: Wrong entries found — store is actively misleading

**Record:** For each spot-checked entry, note what was verified, what was stale, and what was updated. Stale entries should be corrected as part of the test (fix-as-you-go), with the staleness still recorded in the score.

## Step 10: Compile and Write Results

Compile all test scores into the structured results format. Write to `$RESULTS_FILE`.

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
| 2. Retrieval Value | X/5 | accuracy: X/3 completeness: X/3 |
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
[If this is the first run: "Baseline run — no previous results to compare."

If previous results were loaded in Step 0, compute:

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
Changes made to `skills/self-test/SKILL.md` this run:
- [Test X]: <what changed and why>
- [New]: <any new test dimensions added>
- [Removed]: <any test dimensions removed and why>

Rationale: <1-2 sentences on what this run taught about self-diagnosis>
```

## Step 11: Report

After writing results, report to the user:

```
[self-test] Results written to _self_test_results.md (Run N)
  Orientation: X/5 | Retrieval: X/5 | Backlinks: X hops, X% connected
  Threads: X/5 | Plans: X/5 | Utilization: X/5 | Search: X/5 | Trust: X/5
  Tool calls: X (X knowledge, X search) | Bypasses: X
  [If previous: vs Run N-1: X improved, X regressed, X unchanged, X new]
```

## Step 12: Evolve the Self-Test

**This step is mandatory.** Every run should leave the self-test protocol better than it found it. A self-test that doesn't evolve calcifies — it starts confirming what's already known instead of surfacing what's actually wrong.

### 12a: Analyze patterns (if Run > 1)

If previous results exist, compare across runs:

1. **Ceiling tests:** Any test at maximum score for 2+ consecutive runs has stopped producing signal. For each:
   - Can the bar be raised? (Harder questions, stricter criteria, additional sub-dimensions)
   - Should it be replaced with a test that probes a current weakness?
   - At minimum, note it in findings so future runs are aware

2. **Recurring recommendations:** If the same issue appears in 2+ consecutive runs, flag it as a persistent problem. Suggest: "Persistent issue: [description]. Consider `/work create [slug]` to address this systematically."

3. **Bypass pattern analysis:** If the same test section is consistently bypassed across runs, either the test is poorly designed or the system has a chronic gap.

4. **Score trend analysis:** If a test has regressed for 2+ consecutive runs, flag prominently: "Test X has regressed N runs in a row."

### 12b: Apply improvements to the protocol

Based on this run's findings, **edit `skills/self-test/SKILL.md` directly**. Changes to make:

1. **Tests that hit ceiling:** Tighten scoring criteria, add harder sub-questions, or replace the test entirely. A test at ceiling is a test that's wasting time.

2. **New failure modes discovered:** If a test revealed a failure pattern not covered by any existing test, add a test dimension or sub-question that would catch it in future runs.

3. **Questions that produced no signal:** If a test question was trivially answered or didn't differentiate between good and bad system states, replace it with one that does.

4. **Scoring rubric adjustments:** If the rubric made it easy to justify a high score without real evidence, tighten it. Every score should require concrete demonstration, not self-assessment.

5. **Structural changes:** If the test missed something important about how the system is actually used (vs how it was designed to be used), restructure to test real usage patterns.

**Minimum bar:** At least one concrete improvement per run. If everything genuinely scored well and no improvements are obvious, document *why* each test is still producing useful signal — the justification itself is the deliverable.

### 12c: Record changes

Append a `## Protocol Changes` section to the results file:

```markdown
## Protocol Changes (Run N)
Changes made to `skills/self-test/SKILL.md` this run:
- [Test X]: <what changed and why>
- [Test Y]: <what changed and why>
- [New]: <any new test dimensions added>
- [Removed]: <any test dimensions removed and why>

Rationale: <1-2 sentences on what this run taught about self-diagnosis>
```

### 12d: Report

```
[self-test] Protocol evolved:
  Changes: N test(s) modified | Ceiling tests addressed: N | New dimensions: N
  Rationale: <one sentence>
```

## Step 13: Create Work Items from Findings

**This step is mandatory.** The self-test's purpose is to surface actionable findings — but findings without follow-through are just documentation. This step closes the loop by converting persistent or significant recommendations into tracked work items.

### 13a: Triage recommendations

Review all recommendations from the `## Recommendations` section. For each, decide:

1. **Create work item** — if the recommendation meets ANY of these criteria:
   - **Persistent:** Appeared in 2+ consecutive runs without resolution. The self-test has surfaced this repeatedly; passive observation isn't producing action.
   - **Significant scope:** Requires more than a quick inline fix (multiple files, investigation needed, design decisions involved).
   - **Regression risk:** If left unfixed, this will cause scores to drop or new problems to emerge.

2. **Skip** — if the recommendation is:
   - Already tracked by an existing work item (check with `lore work list` or `lore work search`)
   - Trivially fixable inline during the test itself (and was already fixed)
   - Low impact and not persistent

### 13b: Create work items

For each recommendation that warrants a work item:

```bash
lore work create "<slug>"
```

Then write a notes.md entry scoping the work:
- **Origin:** Which self-test run(s) surfaced this, which test(s) it came from
- **Problem:** What's wrong, with specific evidence from the test results
- **Scope:** Rough size estimate and approach
- **Related:** Backlinks to relevant knowledge entries

### 13c: Record in results

Append the `## Work Items Created` section to the results file listing what was created and why. If no work items were warranted, note the reason (e.g., "all recommendations are already tracked" or "all findings were fixed inline").

### 13d: Report

```
[self-test] Work items created: N
  - slug-1 — brief description
  - slug-2 — brief description
  [If none: "No new work items needed — all findings already tracked or fixed inline"]
```
