---
name: self-test
description: Evaluate the lore memory system — run structured tests across 9 dimensions, produce scored comparable results, and log protocol evolution suggestions
user_invocable: true
argument_description: "[optional: 'quick' for abbreviated run (Tests 1, 2, 7 only); 'judge-quality-regression' to run only Test 9 (live judge invocations — costs real tokens)]"
---

# /self-test Skill

This self-test evaluates any knowledge-store-backed memory system. It uses `lore` CLI when available but falls back to direct file operations.

Run a structured evaluation of the lore memory system from any codebase. Tests 9 dimensions of system health (Test 9, judge quality regression, is opt-in — it costs live judge tokens), produces scored results, and compares against previous runs to track regressions and improvements.

**The core question:** Does the memory system make you effective, or do you find yourself bypassing it?

**Design principle:** Tests should surface *actionable findings*, not confirm what's already working. If a test scores 5/5 for 2+ consecutive runs, it should either get harder or be replaced with something that produces signal.

## CLI Abstraction

Before running tests, detect whether the `lore` CLI is available. This allows the self-test to run against any knowledge-store-backed system, not just one with `lore` installed.

### CLI Detection

```bash
lore resolve
```

If `lore resolve` succeeds, set `HAS_CLI` = true and `KNOWLEDGE_DIR` to the result.

If it fails, fall back: 1. Check `$KNOWLEDGE_DIR` environment variable 2. If neither works, ask the agent for the knowledge store path

### Command Fallbacks

When `HAS_CLI` is false, use these fallbacks for CLI commands referenced throughout the test:

**Critical commands (used in multiple tests):**

| Command | Fallback |
|---------|----------|
| `lore search "<query>"` | Grep `.md` files in `$KNOWLEDGE_DIR` for the query term |
| `lore resolve "[[backlink]]"` | Parse the `[[type:file#heading]]` reference, read the file, and find the heading manually |
| `lore index` | Read `$KNOWLEDGE_DIR/_index.md` if it exists, otherwise glob category directories for `.md` files |
| `lore capture --insight "..." ...` | Skip with note: "Capture skipped — lore CLI not available" |

**Non-critical commands:**

| Command | Fallback |
|---------|----------|
| `lore stats` | Count `.md` files and directories in `$KNOWLEDGE_DIR` directly |
| `lore check-links` | Skip — score as N/A with note: "Link checker requires lore CLI" |
| `lore work list` / `lore work search` | Read `$WORK_DIR/_index.json` or glob `$WORK_DIR/*/_meta.json` directly |

Use the CLI command when `HAS_CLI` is true; otherwise the fallback.

### Step 1: Resolve Paths and Detect Infrastructure

### Path Resolution

Run CLI Detection (see **CLI Abstraction** above) to set `HAS_CLI` and `KNOWLEDGE_DIR`. Derive all other paths from `KNOWLEDGE_DIR`:

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
| FTS5 search | `lore search` and `lore stats` work (requires `HAS_CLI`) | `HAS_SEARCH` |
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

If `HAS_PREVIOUS` is true, read `$RESULTS_FILE` and extract: 1. **Scores table** — parse the `## Scores` markdown table. Store each test's score for comparison. 2. **Run number** — from the title line `# Self-Test Results — [date] (Run N)`. The current run is N+1. 3. **Previous recommendations** — parse the `## Recommendations` section. Store each bullet for resolution tracking. 4. **Previous bypass log** — parse `## Bypass Log` to compare bypass patterns.

If parsing fails (malformed results file), note this in the output and treat as first run.

### Quick Mode

If the argument is "quick", only run Tests 1, 2, and 7. Skip the rest and mark them as "Skipped (quick mode)" in results.

If the argument is "judge-quality-regression", run only Test 9 and skip the rest. Test 9 is otherwise opt-in: it invokes live judges (real token cost, minutes of wall time), so a default full run marks it "Skipped (opt-in — pass 'judge-quality-regression' or invoke via the post-settlement canary trigger)".

### Step 2: Initialize Tracking

Set up tracking counters for the entire run: - `TOOL_CALLS` = 0 (increment each time you use Read, Glob, Grep, Bash, or any tool) - `KNOWLEDGE_CALLS` = 0 (subset: tool calls that read from `$KNOWLEDGE_DIR`) - `RAW_SEARCH_CALLS` = 0 (subset: Grep/Glob/Explore calls outside `$KNOWLEDGE_DIR`) - `BYPASS_LOG` = [] (each entry: test number, what you bypassed, why)

Be honest about counting. Every tool invocation counts. The ratio of knowledge-system to raw-search calls is diagnostic.

## Test 1: Orientation

**Purpose:** Evaluate what the session-start hooks loaded into context — breadth (what exists) and depth (what it says). Without reading any files or running any searches, answer using only what was loaded at session start.

**Breadth questions (2):** 1. What knowledge categories exist and what does each hold? 2. What is the directory layout of the knowledge store?

**Synthesis question (1) — requires combining information across categories:** 3. Pick a principle from `principles.md` and trace its influence through the system: identify at least one convention it generates, one gotcha it addresses, and one workflow or script that implements it. Explain the causal chain. This tests whether you absorbed the relationships between categories, not just each category in isolation.

**Depth questions (2) — these test whether you internalized content, not just structure:** 4. Name a specific gotcha and describe its mitigation from memory. Then identify a convention or workflow entry that relates to it and explain the connection. If you can only name the heading but not the substance, that's partial credit. Full credit requires demonstrating the cross-reference — how two entries in different files connect. 5. Describe a specific convention and when it applies. Then identify a gotcha or architecture entry it was designed to address. Again — substance and cross-reference, not just the heading.

**Note (Run 6):** Test 1 scored 5/5 for 6 consecutive runs (Runs 1-6). The synthesis question (added Run 5) scored 5/5 on first attempt — answerable because principles are loaded at session start with See-also links that provide the traversal path. If 5/5 persists in Run 7, raise the bar: require tracing a principle to a specific code implementation line (function name, line number), not just naming the script.

**Scoring:** X/5 confidently with specific, accurate details. Breadth = listing; depth = absorbed content AND cross-reference to entries in other files, not just headings.

**Record:** For each depth question, note whether your answer included concrete details (mitigations, conditions, examples) AND a valid cross-reference. Vague = not confident = doesn't count. Missing cross-reference = partial credit only.

## Test 2: Retrieval Value

**Purpose:** Measure whether knowledge store entries provide accurate, useful answers to real questions about this codebase — faster and more completely than starting from scratch.

This test replaced the previous "Retrieval Race" (Runs 1-2) which compared knowledge reads vs Grep. That comparison was structurally decided by architecture (knowledge data is outside the logic repo), producing no diagnostic signal.

**Procedure:** 1. Run `lore index` to identify 3 diverse topics with knowledge entries. 2. For each, formulate a *practical implementation question* you'd actually ask while working on this codebase (e.g., "What happens if I archive a work item with active backlinks?"). 3. Answer using only the knowledge store (read the category file, follow backlinks). 4. Verify each answer against the actual source code or scripts referenced. Classify: **Accurate** (matched code), **Stale** (was true, code changed), **Incomplete** (correct but missed code-revealed details), **Wrong** (contradicts code).

**Scoring:** Accuracy X/3 verified, Completeness X/3 no significant gaps, Token efficiency = average code-reading elimination % across 3 questions mapped to 1-5 (5: >80% eliminated, 4: 60-80%, 3: 40-60%, 2: 20-40%, 1: <20%). Overall = average of all three (Accuracy and Completeness mapped to 1-5).

**Record:** For each question, estimate: how many file reads did the knowledge entry prevent? How many were still needed? What percentage of code consumption was eliminated? Also note the token economics: entry tokens consumed (~150-300) vs. file-read tokens prevented (~N x 500-3000). An entry that eliminates 3 of 5 file reads is valuable (60% elimination, ~1500-9000 tokens saved for ~150 consumed) even though the agent still reads 2 files — this is not "insufficient," it is a measurable efficiency gain. Entries are efficient when they replace reads, not supplement them.

## Test 3: Backlink Navigation

**Purpose:** Test cross-reference network quality — traversability and density.

**Requires:** `HAS_ENTRIES` = true. If false, score as N/A.

**Traversal test:** Run `lore index` to list all entries. Pick any entry and follow its `[[backlinks]]` to find related context across files. Try to traverse at least 3 hops. Attempt a cross-type chain (e.g., knowledge → work → thread, or gotchas → conventions → architecture).

**Connectivity audit:** While traversing, count: - Entries that have `See also:` backlinks (connected) - Entries with no outgoing references (isolated) - Entries where you expected a cross-reference but didn't find one (missing links)

**Scoring:** Hops X, dead ends X, connectivity X% with outgoing links, missing links X (become recommendations).

**Record:** Note any missing cross-references you'd expect to exist. These are actionable — they can be added.

## Test 4: Thread Awareness

**Purpose:** Evaluate whether conversational threads provide actionable session context — measured by concrete behavioral evidence, not self-assessment.

**Requires:** `HAS_THREADS` = true. If false, score as N/A with note: "No threads exist yet. Create threads to enable this test."

**Procedure:** 1. List `.md` files in `$THREADS_DIR` (exclude `_index.json` or other non-thread files). 2. For each thread, read frontmatter to identify `tier` (pinned/active/dormant) and `topic`. 3. Read the most recent entry of each pinned and active thread.

**Behavioral evidence test:** For each thread, identify: - A **specific behavior** you exhibited this session that was shaped by thread content. Not "I was aware of X" but "I did Y because the thread said Z." If you can't identify a specific behavior, that thread scored no impact. - A **shift or decision** recorded in the thread that you would have gotten wrong without it. E.g., a preference that contradicts what you'd assume by default.

**Scoring:** Actionability (1-5): - 5: multiple behaviors directly shaped, with one you'd have gotten wrong without it - 4: one clear behavior shaped plus general awareness - 3: useful context but no measurable action change - 2: threads loaded but no concrete impact - 1: no discernible effect.

**Record:** The specific behaviors and which thread entries produced them. This is the evidence.

**Note (Run 6):** Thread Awareness has been 3/5 for 3 consecutive runs (Runs 4-6). This reflects a structural ceiling when the self-test is the session's primary activity — threads are most impactful during implementation sessions where they can prevent wrong assumptions. If 3/5 persists for 2+ more runs, consider restructuring this test to evaluate thread quality directly (entry specificity, shift documentation accuracy, backlink density) rather than behavioral impact, which requires implementation context the self-test doesn't generate.

## Test 5: Plan Continuity

**Purpose:** Evaluate whether work items provide enough context for a fresh instance to pick up work — tested by actually attempting it, not hypothetically assessing.

**Requires:** `HAS_WORK` = true. If false, score as N/A with note: "No work items exist. Create work items to enable this test."

**Procedure:** 1. Read `$WORK_DIR/_index.json` to list work items with status. 2. Pick an active item (prefer one with unchecked plan tasks). 3. Read its `plan.md` and the last 2-3 entries of `notes.md`.

**Cold-start exercise:** Pretend you're a fresh instance with no prior conversation context. Using only the plan and notes: 1. Write out the **exact next 3 actions** you'd take to continue this work (specific file reads, commands, or edits — not vague descriptions). 2. Identify any **missing context** — questions you'd need answered that the plan doesn't address. 3. Check whether the design decisions in the plan are specific enough to prevent you from making a wrong choice.

**Backlink freshness check (added Run 4):** Pick 2-3 `[[knowledge:...]]` backlinks from the plan's Knowledge context or Related sections and resolve them with `lore resolve`. Are the referenced sections still accurate for this plan's purposes? A plan with stale backlinks gives implementers misleading context.

**Note (Run 4):** Test 5 scored 5/5 for 3 consecutive runs (Runs 2-4). The backlink freshness sub-dimension tests plan freshness alongside plan completeness — catching the failure mode where plans reference knowledge entries that have drifted since the plan was written.

**Scoring:** Actionability (1-5): - 5: all 3 next-actions concrete and correct, no missing context - 4: mostly concrete, 1 minor non-blocking question - 3: directionally right but vague, 1-2 real questions - 2: goal yes, next-steps no, multiple questions - 1: insufficient context to begin.

**Record:** The 3 next-actions and any missing context. The missing-context items become recommendations.

## Test 6: Knowledge Utilization and Capture

**Purpose:** Audit whether the knowledge system was actually used during real work this session — not in a test environment, but during the productive work that preceded this self-test. This is the core success metric from the how-we-work thread.

This test replaced the previous "Capture Protocol" test (Runs 1-2) which artificially tested capture by reading a script during the test itself. That test couldn't detect the real failure mode: knowledge being bypassed during actual work.

**Part A — Utilization audit:** Review what happened in this session *before* the self-test was invoked. Answer: 1. **Was the knowledge store consulted before raw exploration?** Identify moments you (or spawned agents) explored code — was the store checked first? If yes, which entries helped? If no, would an entry have been useful? (Check now.) 2. **Knowledge-search bypasses** — moments you defaulted to Grep/Glob/Read for info the store already had. Count them. 3. **Did spawned agents use the knowledge store?** For `/implement` or `/spec`, did workers resolve backlinks and search knowledge, or skip straight to code?

If this is the first action in the session (no real work preceded the self-test), note "No prior work to audit" and score based on the protocol's readiness: are the hooks, skill prompts, and agent instructions set up to make knowledge utilization likely?

**Note (Run 5):** Capture scoring should not give a free pass to "light" sessions. Conversational sessions where genuine insights emerge (e.g., identifying structural gaps, recognizing thread usage patterns, noting maintenance debt) still warrant captures. If the 4-condition gate is met, the session type is irrelevant. Score capture based on whether capturable insights were present, not on whether code was written.

**Part B — Capture audit:** Review the session for capture opportunities: 1. **What was captured?** Count inbox entries created this session (timestamps in `$INBOX_DIR` or session actions). 2. **What was missed?** Identify 1-3 moments where the 4-condition gate (Reusable, Non-obvious, Stable, High confidence) was met but no capture occurred. If you can't find missed opportunities, that's a good sign. 3. **Filed correctly?** Did `lore capture` write directly to category files, or are there unfiled inbox entries?

**Scoring:** Utilization X/5 (5=knowledge first every time, 1=never), Capture X/5 (5=all caught and filed, 1=many missed), Combined = average.
**Record:** Specific utilization moments and bypasses. These are the most actionable findings in the entire self-test — they reveal exactly where the system is failing to deliver value.

## Test 7: Search and Resolution

**Purpose:** Test the search and link resolution tooling.

### 7a: FTS5 Search

**Requires:** `HAS_SEARCH` = true. If false, score as N/A.

Run these searches:

```bash
lore search "backlinks" --scale-set abstract,architecture,subsystem,implementation
lore search "session start" --scale-set abstract,architecture,subsystem,implementation
lore stats
```

Were the top-3 results the right answers? Did snippets give enough context to decide relevance?

**Note (Run 6):** Known issue: archived work items (plans, investigation notes) are keyword-dense and consistently outrank knowledge entries in BM25 scoring. Test queries like "backlinks" and "session start" return archived plans as top results rather than the knowledge entries that summarize those patterns. This is a real system weakness — search should prioritize knowledge entries that represent distilled understanding over the verbose source material. Track whether `--type knowledge` or boost factors improve this.

### 7b: Backlink Resolution

Pick a `See also: [[...]]` reference from any knowledge file and resolve it (adapt to one that actually exists in the store):

```bash
lore resolve "[[knowledge:gotchas#Some Heading]]"
```

Did it return the exact section? Compare to manually reading the file.

### 7c: Link Integrity

```bash
lore check-links
```

How many broken links? Are they real breaks or false positives? Track the FP ratio (false positives / total reported) across runs — a rising ratio means the checker needs improvement.

**Scoring:** Search relevance X/5, resolution X/X correct, broken links X real / X FP (ratio X%).

## Test 8: Freshness and Trust

**Purpose:** Verify that knowledge entries are accurate against current code — not just trusted in the abstract, but spot-checked for staleness.

This test replaced the previous "Honest Assessment" (Runs 1-2) which asked hypothetical self-assessment questions. Those questions consistently scored 5/5 without surfacing any findings.

**Persistent staleness escalation (Run 5):** If the same entry is flagged as stale for 3+ consecutive runs, it's no longer a recommendation — it's a systemic maintenance failure. Flag it prominently in the results and recommend creating a dedicated work item to address the maintenance backlog. The self-test protocol shouldn't just observe staleness; it should escalate when repeated observation fails to produce action.

**Spot-check procedure:** 1. Pick 3 knowledge entries from different category files (prefer >7 days old, or entries referencing specific code paths/scripts). If an entry was stale in the previous run, re-check it — persistent staleness is a stronger signal than new staleness. 2. For each entry, verify against the actual code: read the referenced files/scripts; check whether the described behavior, paths/filenames, and `See also:` backlinks are still accurate.

**Scoring by entry:** - **Fresh:** All claims verified, references valid - **Aging:** Minor inaccuracies (renamed variable, changed default) but substance correct - **Stale:** Key claims no longer match code — entry needs updating - **Wrong:** Entry contradicts current behavior — dangerous if trusted

**Overall scoring:** Score the original state (before fix). The score records what was found, not what was left — this preserves trend tracking across runs even when Step 3 corrects entries inline. - Freshness: X/3 entries fully fresh - Trust: 1-5 scale based on findings: - 5: All spot-checked entries verified accurate - 4: Minor staleness found, substance still reliable - 3: 1 stale entry found — pattern may be broader - 2: Multiple stale entries — store needs maintenance pass - 1: Wrong entries found — store is actively misleading

**Record:** For each spot-checked entry, note what was verified, what was stale, and what was updated. Stale entries should be corrected as part of the test (fix-as-you-go), with the staleness still recorded in the score.

## Test 9: Judge Quality Regression (opt-in)

**Purpose:** Detect drift in the reverse-auditor judge's omission-emission capability by replaying the frozen quality-regression fixture suite against the current judge configuration and tracking per-fixture reproduction rate over time. This is the drift-canary read side for the strict omission-quality regression bar (`scripts/judge-quality-regression.sh`).

**Requires:** at least one fixture under `$KNOWLEDGE_DIR/_quality-fixtures/reverse-auditor/`. If none exist, score as N/A with note: "No quality fixtures captured. Capture one via scripts/capture-quality-fixture.sh."

**Cost warning:** each fixture replay is a live judge invocation (roughly $1-2 and 1-3 minutes per fixture). Never run this test implicitly — only when the argument targets it or the post-settlement canary trigger invoked the self-test.

**Procedure:**

1. Run the suite. Use `--mode canary` when this self-test was invoked by the post-settlement canary trigger; use `--mode self-test-manual` when a user invoked it directly (manual rows are recorded but excluded from the drift signal):

```bash
bash scripts/judge-quality-regression.sh reverse-auditor --mode self-test-manual
```

Each fixture prints a PASS line on stdout or a FAIL line (with the failing gate: schema-valid, omission-nonnull, file-match, line-range-overlap) on stderr, and appends one telemetry scorecard row.

2. Aggregate the rolling reproduction rate and surface drift suspects:

```bash
bash scripts/judge-quality-regression.sh reverse-auditor --rolling-report
```

The report computes each fixture's pass rate over its most recent post-settlement-canary runs (window 10, threshold 0.7 by default) and flags fixtures below threshold as DRIFT-SUSPECT.

3. For each drift-suspect fixture, note it in the results with its rolling rate and the failing gate(s) from this run's replay. Do NOT retire or refresh fixtures during the test — surface them; the user decides between refresh (capture a new fixture), retirement (`scripts/retire-quality-fixture.sh <id> --rationale "..."`), or a model-drift investigation.

**Scoring (1-5):**

- 5: all fixtures pass this run AND no drift suspects in the rolling report
- 4: all fixtures pass this run; 1 drift suspect in the rolling window (recovering or noisy)
- 3: 1 fixture fails this run OR 1 persistent drift suspect
- 2: multiple fixtures fail — likely model or template drift; check provenance (`template_version`, `model_variant`) against current values to attribute
- 1: suite-wide failure or the runner itself errors

**Record:** per-fixture pass/fail with failing gate, rolling rates, drift suspects, and the current `template_version` + `model_variant` vs each fixture's provenance (a divergence there is the drift attribution).

### Step 3: Apply Mechanical Fixes

**This step is mandatory.** For every entry scored as **aging** or **stale** in Test 8, attempt a mechanical fix before proceeding. The goal: leave the knowledge store more accurate than you found it, without blocking the self-test on rewrites that require deep investigation.

**Scope rules — what counts as mechanical:** broken file paths (renamed/moved); renamed references (function, variable, script); wrong counts or enumerations (e.g., "3 scripts" → 4); changed defaults or flag names; stale `See also:` backlinks to renamed/moved entries.

**Scope limit — when to defer:** If a fix requires reading **more than 2 source files** to verify correctness, or requires a **full content rewrite** (the entry's core claim is wrong, not just a detail), do NOT attempt the fix inline. Instead, log it as **"deferred to /renormalize"** in the results.

**Procedure:** For each aging/stale entry, classify mechanical (path/name/count/reference) vs substantive (core claim outdated). Mechanical: read the 1-2 relevant source files, Edit the entry in place, update its `learned` date to today. Substantive: log as `- <entry path>: <drift reason> — deferred to /renormalize`.

**Record:** Each fix applied (entry, what changed) and each deferral (entry, why). Feeds into Step 4 results.

### Step 4: Compile and Write Results

Compile all test scores into the structured results format. Write to `$RESULTS_FILE`.

When writing the results file, read `skills/self-test/templates/results.md` for the canonical output template — that sidecar holds the Infrastructure/Scores/Comparison/Test Results/Fixes Applied/Bypass Log/Recommendations/Work Items Created/Protocol Changes structure verbatim. Fill in every placeholder; the section headings and metadata layout are parsed literally by `/retro`, `/evolve`, and inter-run delta computation.

### Step 4b: Write Effectiveness Journal Entry

**This step is mandatory.** After writing the results file, record the run in the effectiveness journal so it appears in aggregated timeline views alongside retrieval and friction data.

```bash
lore journal write \
  --observation "Self-test Run N: Orientation X/5 | Retrieval X/5 | Backlinks X hops X% | Threads X/5 | Plans X/5 | Utilization X/5 | Search X/5 | Trust X/5. Key regressions: <list or 'none'>. Key improvements: <list or 'none'>. Most actionable finding: <1-2 sentences on the single most important thing to fix>." \
  --context "self-test run N" \
  --role "self-test" \
  --scores '{"t1_orientation": X, "t2_retrieval": X, "t3_backlinks": X, "t4_threads": X, "t5_plans": X, "t6_utilization": X, "t7_search": X, "t8_trust": X, "t9_judge_quality": X}'
```

Omit `t9_judge_quality` when Test 9 was skipped (opt-in not exercised).

The observation should be 3-5 sentences containing: all 8 scores, any regressions or improvements compared to the previous run, and the single most actionable finding from this run.

### Step 5: Report

After writing results, report to the user:

```
[self-test] Results written to _self_test_results.md (Run N)
  Orientation: X/5 | Retrieval: X/5 | Backlinks: X hops, X% connected
  Threads: X/5 | Plans: X/5 | Utilization: X/5 | Search: X/5 | Trust: X/5
  Tool calls: X (X knowledge, X search) | Bypasses: X
  [If previous: vs Run N-1: X improved, X regressed, X unchanged, X new]
```

### Step 6: Log Evolution Suggestions

**This step is mandatory.** Every run should produce at least one protocol improvement suggestion. A self-test that doesn't evolve calcifies — it starts confirming what's already known instead of surfacing what's actually wrong. Log suggestions to the journal — do **not** edit `skills/self-test/SKILL.md` directly. The `/evolve` skill applies batched journal suggestions on demand.

### 6a: Analyze patterns (if Run > 1)

If previous results exist, compare across runs:

1. **Ceiling tests:** Any test at maximum score for 2+ consecutive runs has stopped producing signal. For each: - Can the bar be raised? (Harder questions, stricter criteria, additional sub-dimensions) - Should it be replaced with a test that probes a current weakness? - At minimum, note it in findings so future runs are aware

2. **Recurring recommendations:** If the same issue appears in 2+ consecutive runs, flag it as a persistent problem. Suggest: "Persistent issue: [description]. Consider `/work create [slug]` to address this systematically."

3. **Bypass pattern analysis:** If the same test section is consistently bypassed across runs, either the test is poorly designed or the system has a chronic gap.

4. **Score trend analysis:** If a test has regressed for 2+ consecutive runs, flag prominently: "Test X has regressed N runs in a row."

### 6b: Log improvement suggestions

For each protocol improvement identified, write a journal entry:

```bash
lore journal write \
  --observation "Target: <file> | Change type: <ceiling-test/new-failure-mode/dead-test/evidence-gap> | Section: <section> | Suggestion: <specific change> | Evidence: <self-test finding that surfaced this>" \
  --context "self-test-evolution: run N" \
  --work-item "<slug if applicable>" \
  --role "self-test-evolution"
```

**Suggestion categories to consider:**

1. **Tests that hit ceiling:** Tighten scoring criteria, add harder sub-questions, or replace the test entirely. A test at ceiling is a test that's wasting time.

2. **New failure modes discovered:** If a test revealed a failure pattern not covered by any existing test, add a test dimension or sub-question that would catch it in future runs.

3. **Questions that produced no signal:** If a test question was trivially answered or didn't differentiate between good and bad system states, replace it with one that does.

4. **Scoring rubric adjustments:** If the rubric made it easy to justify a high score without real evidence, tighten it. Every score should require concrete demonstration, not self-assessment.

**One entry per suggestion.** Observation: 2-4 sentences — suggested change, target test/section, rationale, triggering pattern.
**Minimum bar:** At least one suggestion per run. If scoring went smoothly and no improvements are obvious, log why each test is still producing useful signal — the justification is the deliverable.

### 6c: Record in results file

Append a `## Protocol Changes` section to the results file noting what was logged (not what was applied):

```markdown
## Protocol Changes (Run N)
Evolution suggestions logged to journal this run:
- [Test X]: <what was suggested and why>
- [Test Y]: <what was suggested and why>

Rationale: <1-2 sentences on what this run taught about self-diagnosis>
```

### 6d: Report

```
[self-test] Evolution suggestions logged: N (run /evolve self-test to apply)
  Ceiling tests addressed: N | New failure modes: N | Dead tests: N | Evidence gaps: N
  Rationale: <one sentence>
```

### Step 7: Create Work Items from Findings

**This step is mandatory.** The self-test's purpose is to surface actionable findings — but findings without follow-through are just documentation. This step closes the loop by converting persistent or significant recommendations into tracked work items.

### 7a: Triage recommendations

Review all recommendations from the `## Recommendations` section. For each, decide:

1. **Create work item** — if the recommendation meets ANY of: **Persistent:** appeared in 2+ consecutive runs without resolution (passive observation isn't producing action); **Significant scope:** more than a quick inline fix (multiple files, investigation, design decisions); **Regression risk:** unfixed it will cause scores to drop or new problems to emerge.

2. **Skip** — if already tracked by an existing work item (check `lore work list`/`lore work search`), trivially fixable inline (and was), or low-impact and not persistent.

### 7b: Create work items

For each recommendation that warrants a work item:

```bash
lore work create --title "<slug>"
```

Then write a notes.md entry: **Origin** (which run/test surfaced this), **Problem** (what's wrong, with evidence), **Scope** (rough size + approach), **Related** (backlinks to relevant knowledge entries).

### 7c: Record in results

Append `## Work Items Created` to the results file listing what was created and why. If none were warranted, note the reason ("all recommendations already tracked" or "all findings fixed inline").

### 7d: Report

```
[self-test] Work items created: N
  - slug-1 — brief description
  - slug-2 — brief description
  [If none: "No new work items needed — all findings already tracked or fixed inline"]
```
