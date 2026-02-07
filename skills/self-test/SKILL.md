---
name: self-test
description: Evaluate the project-knowledge memory system — run structured tests across 8 dimensions and produce scored, comparable results
user_invocable: true
argument_description: "[optional: 'quick' for abbreviated run (Tests 1, 2, 7 only)]"
---

# /self-test Skill

Run a structured evaluation of the project-knowledge memory system from any codebase. Tests 8 dimensions of system health, produces scored results, and compares against previous runs to track regressions and improvements.

**The core question:** Does the memory system make you effective, or do you find yourself bypassing it?

## Step 0: Resolve Paths and Detect Infrastructure

### Path Resolution

```bash
bash ~/.project-knowledge/scripts/resolve-repo.sh
```

Set `KNOWLEDGE_DIR` to the result. Derive all other paths from it:

- `INDEX_FILE` = `$KNOWLEDGE_DIR/_index.md`
- `MANIFEST_FILE` = `$KNOWLEDGE_DIR/_manifest.json`
- `INBOX_FILE` = `$KNOWLEDGE_DIR/_inbox.md`
- `THREADS_DIR` = `$KNOWLEDGE_DIR/_threads`
- `WORK_DIR` = `$KNOWLEDGE_DIR/_work`
- `RESULTS_FILE` = `$KNOWLEDGE_DIR/_self_test_results.md`

### Infrastructure Detection

Before running tests, detect what infrastructure exists. Read each path and record availability. This determines which tests can run and which score N/A.

| Layer | Check | Variable |
|-------|-------|----------|
| Knowledge store | `_index.md` exists and has entries | `HAS_INDEX` |
| Manifest | `_manifest.json` exists | `HAS_MANIFEST` |
| Threads | `_threads/` has `.md` files (not just `_index.json`) | `HAS_THREADS` |
| Work | `_work/` has subdirectories with `plan.md` files | `HAS_WORK` |
| FTS5 search | `pk_search.py` exists and `search-knowledge.sh` works | `HAS_SEARCH` |
| Inbox | `_inbox.md` exists | `HAS_INBOX` |
| Previous results | `_self_test_results.md` exists | `HAS_PREVIOUS` |

Report infrastructure status before proceeding:
```
[self-test] Infrastructure detected:
  Knowledge index: yes/no
  Threads: N found
  Work: N found (N active, N archived)
  FTS5 search: yes/no
  Previous results: yes/no
```

If `HAS_INDEX` is false, the knowledge store is uninitialized. Report this and suggest running `/memory init`. Stop the test — there's nothing meaningful to evaluate.

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

## Test 1: Orientation (No Tools)

**Purpose:** Evaluate what the session-start hooks loaded into context.

Without reading any files or running any searches, answer these questions using only what was loaded at session start.

**Core questions (always asked):**
1. What knowledge categories exist and what does each hold?
2. What is the directory layout of the knowledge store?
3. How does `resolve-repo.sh` determine the knowledge path?

**Adaptive questions (select based on infrastructure):**
4. If `HAS_WORK`: What plans exist and what state are they in?
   If not: What scripts exist in the system and what does each do?
5. If `HAS_THREADS`: What conversational threads exist and what are they about?
   If not: What is the capture protocol and its 4-condition gate?

**Scoring:** X/5 questions answered confidently (not guessing). If you have to say "I think" or "probably", that's not confident. All 5 questions should be answerable regardless of infrastructure — the adaptive selection ensures this.

**Record:** For each question, note whether the answer came from session-start context or if you felt like you were guessing.

## Test 2: Retrieval Race

**Purpose:** Compare knowledge store retrieval vs raw search (Grep/Glob) for speed and precision.

For each question below, attempt to answer it two ways:
1. **Knowledge path:** Read the relevant category file from the index, or follow a backlink
2. **Search path:** Use Grep or Glob to find the answer via raw search

**Question generation procedure:**

1. Read `$INDEX_FILE`. List all `###` headings — these are the candidate topics.
2. Read `$MANIFEST_FILE` if it exists. Note entries with keywords.
3. From the available headings and manifest entries, construct 4 race questions (or fewer if the store has fewer than 4 topics). Each question should target a *specific* entry — not a vague "tell me about X."

**Question selection rules:**
- Q1: Pick a gotcha or pitfall entry (from gotchas.md section of index). If none, pick any entry.
- Q2: Pick a workflow or process entry (from workflows.md section). If none, pick any entry.
- Q3: If a `domains/` file exists in the index, pick an entry from it. If no domains, pick from any other category.
- Q4: If `HAS_WORK`, pick an active plan and find its status. If not, pick a conventions or abstractions entry.

If no index exists, score the entire test as N/A.

**Scoring:** Knowledge wins X/N, Search wins X/N, Tie X/N.

**Important:** Note *why* each approach won or lost. If a search path fails silently (e.g., `.gitignore` blocks search in `repos/`), investigate and record why — this is a critical diagnostic signal.

## Test 3: Backlink Navigation

**Purpose:** Test the cross-reference network quality.

**Requires:** `HAS_INDEX` = true. If false, score as N/A.

Start at `$INDEX_FILE`. Pick any entry and follow its `[[backlinks]]` to find related context across files. Try to traverse at least 3 hops.

**Bonus:** Try a cross-type chain that moves between knowledge, plans, and threads (e.g., knowledge -> plan -> knowledge, or knowledge -> thread -> plan).

**Scoring:** Hops completed: X. Dead ends: X. Stale references found: X.

**Record:** Did the backlinks take you somewhere useful, or did you hit dead ends? Were there places you expected a backlink but didn't find one?

## Test 4: Thread Awareness

**Purpose:** Evaluate whether conversational threads provide actionable session context.

**Requires:** `HAS_THREADS` = true. If false, score as N/A with note: "No threads exist yet. Create threads to enable this test."

**Question generation procedure:**
1. List `.md` files in `$THREADS_DIR` (exclude `_index.json` or other non-thread files).
2. For each thread, read frontmatter to identify `tier` (pinned/active/dormant) and `topic`.
3. Prioritize pinned threads, then active, then dormant.
4. Generate questions from the actual thread topics:

Using the threads you found, answer:
1. Can you identify user preferences or communication style from the threads?
2. Do the threads record decisions or shifts in thinking that would be useful context?
3. Did knowing thread content change how you approach this session (formatting, tone, priorities)?

**Scoring:** Actionability (1-5): How much did thread context change your actual behavior? 1 = no impact, 5 = significantly shaped approach.

**Record:** Do threads feel like useful relationship memory, or like documentation you could have inferred from CLAUDE.md alone?

## Test 5: Plan Continuity

**Purpose:** Evaluate whether plans provide enough context for a fresh instance to pick up work.

**Requires:** `HAS_WORK` = true. If false, score as N/A with note: "No plans exist yet. Create plans to enable this test."

**Plan selection procedure:**
1. Read `$WORK_DIR/_index.json` to list all plans with their status and update timestamps.
2. Pick the most recently updated active plan. If no active plans exist, check `$WORK_DIR/_archive/` for completed plans.
3. Read its `plan.md` and `notes.md` (if present).

1. Without any other context, can you describe what's been built, what's next, and why?
2. Could you pick up the next unfinished phase right now? What would you need to know that the plan doesn't tell you?
3. Are the design decisions clear enough to guide implementation without re-asking the user?

**Scoring:** Actionability (1-5): Could you act on this plan without the original conversation? 1 = completely lost, 5 = ready to implement.

**Record:** What's missing from the plan? What questions would you need answered?

## Test 6: Capture Protocol

**Purpose:** Test whether the capture protocol activates naturally during work.

**Script selection procedure:**
1. List all `.sh` and `.py` files in `~/.project-knowledge/scripts/`.
2. Exclude `resolve-repo.sh` (well-documented, likely already familiar).
3. Pick one you haven't examined before in this session. Prefer less obvious utility scripts over main hook scripts.

Read the selected script and find a non-obvious implementation detail. Then:

1. Does the capture protocol from CLAUDE.md activate naturally, or does it feel forced?
2. Append a test entry to `$INBOX_FILE` — mark it as a test entry so it can be identified later.
3. Did you consciously evaluate the 4-condition gate (Reusable, Non-obvious, Stable, High confidence)?

**Scoring:** Activation energy (1-5, where 1=effortless, 5=forced): How natural did capturing feel?

**Record:** Was the inbox format easy to produce from memory? Did you remember the required fields?

## Test 7: Search and Resolution

**Purpose:** Test the search and link resolution tooling.

### 7a: FTS5 Search

**Requires:** `HAS_SEARCH` = true. If false, score as N/A.

Run these searches (replace `$KNOWLEDGE_DIR` with the resolved path):

```bash
python3 ~/.project-knowledge/scripts/pk_search.py search "$KNOWLEDGE_DIR" "backlinks"
python3 ~/.project-knowledge/scripts/pk_search.py search "$KNOWLEDGE_DIR" "session start"
python3 ~/.project-knowledge/scripts/pk_search.py stats "$KNOWLEDGE_DIR"
```

Were the top-3 results the right answers? Did snippets give enough context to decide relevance?

### 7b: Backlink Resolution

Pick a `See also: [[...]]` reference from any knowledge file and resolve it:

```bash
python3 ~/.project-knowledge/scripts/pk_search.py resolve "$KNOWLEDGE_DIR" "[[knowledge:gotchas#Some Heading]]"
```

(Adapt the backlink reference to one that actually exists in the store.)

Did it return the exact section? Compare to manually reading the file.

### 7c: Link Integrity

```bash
python3 ~/.project-knowledge/scripts/pk_search.py check-links "$KNOWLEDGE_DIR"
```

How many broken links? Are they real breaks or false positives?

**Scoring:**
- Search relevance (1-5): Were top results the right answers?
- Resolution accuracy: X/X resolved correctly.
- Broken links: X real, X false positive.

## Test 8: Honest Assessment

**Purpose:** Synthesize findings into an honest evaluation.

Write a short reflection:

1. **Where did the memory system save you time?** Be specific — which test, which question.
2. **Where did you bypass it?** What made you reach for Grep/Glob/Explore instead?
3. **What's missing?** What would have made the system more useful?
4. **Trust level:** On a scale of 1-5, how much did you trust the knowledge store to be accurate and complete? Did anything feel stale or wrong?
5. **Would you reach for this mid-task?** If you were implementing a feature in this codebase, would you check the knowledge store first, or just read the code?

**Scoring:** Trust level (1-5).

## Step 10: Compile and Write Results

Compile all test scores into the structured results format. Write to `$RESULTS_FILE`.

```markdown
# Self-Test Results — [YYYY-MM-DD] (Run N)

## Infrastructure
| Layer | Status |
|-------|--------|
| Knowledge index | yes/no (N entries) |
| Threads | N found |
| Work | N found (N active, N archived) |
| FTS5 search | yes/no |
| Previous results | yes/no |

## Scores
| Test | Score | Notes |
|------|-------|-------|
| 1. Orientation | X/5 | |
| 2. Retrieval Race | Knowledge X / Search X / Tie X | |
| 3. Backlinks | X hops, X dead ends | |
| 4. Thread Awareness | X/5 actionability | |
| 5. Plan Continuity | X/5 actionability | |
| 6. Capture Protocol | X/5 activation energy | |
| 7a. Search Relevance | X/5 | |
| 7b. Resolution | X/X resolved | |
| 7c. Link Integrity | X real breaks, X false positives | |
| 8. Trust Level | X/5 | |

**Run metadata:**
- Date: YYYY-MM-DD
- Run number: N (auto-incremented from previous results, or 1 if first run)
- Tool calls: X total (X knowledge-system, X raw-search)
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
[For each test: what happened, what you noticed, knowledge-system vs raw-search comparison]

## Bypass Log
[Every time you used Grep/Glob/Explore instead of the knowledge system, note why.
Format: Test X.Y — Bypassed because: reason]

## Recommendations
[Specific, actionable changes that would improve the system. For significant findings, suggest /work create.]
```

## Step 11: Report

After writing results, report to the user:

```
[self-test] Results written to _self_test_results.md
  Orientation: X/5 | Retrieval: K:X S:X T:X | Backlinks: X hops
  Threads: X/5 | Plans: X/5 | Capture: X/5 | Search: X/5 | Trust: X/5
  Tool calls: X (X knowledge, X search) | Bypasses: X
  [If previous: vs last run: X improved, X regressed, X unchanged]
```

## Step 12: Self-Improvement Review (if Run > 2)

Skip this step if fewer than 3 runs exist (not enough data for pattern detection).

If 3+ runs exist, review the recommendation history across all previous results files:

1. **Recurring recommendations:** If the same issue appears in 2+ consecutive runs, flag it as a persistent problem. Suggest creating a plan: "Persistent issue: [description]. Consider `/work create [slug]` to address this systematically."

2. **Bypass pattern analysis:** Compare bypass logs across runs. If the same test section is consistently bypassed, the test may be poorly designed or the system has a chronic gap. Suggest either:
   - A system fix (if the bypass reveals a real deficiency)
   - A protocol change (if the test expectations don't match how the system is actually used)

3. **Score trend analysis:** If a test has regressed for 2+ consecutive runs, flag it prominently: "Test X has regressed N runs in a row. Root cause investigation recommended."

4. **Protocol suggestions:** Based on patterns, suggest specific SKILL.md changes:
   - New test categories for recurring gaps not covered by existing tests
   - Adjusted scoring rubrics if a dimension is consistently at ceiling (5/5) or floor
   - Question refinements for tests that don't produce useful diagnostic signal

Report any findings:
```
[self-test] Self-improvement review (Run N, 3+ runs analyzed):
  Persistent issues: N | Score trends: N declining | Protocol suggestions: N
```

If no patterns are found, report nothing — silence means the system is healthy.
