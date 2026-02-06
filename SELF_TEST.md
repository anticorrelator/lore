# Memory System Self-Test

You are a new Claude instance testing the project-knowledge memory system. This file guides you through exercising every layer of the system and honestly evaluating whether it's faster and more useful than basic agent search (Glob, Grep, Explore subagents).

**The core question:** Does the memory system make you effective, or do you find yourself bypassing it?

Run these tests in order. For each one, note whether you used the memory system or fell back to raw search — and why. Write your results to `repos/local/.project-knowledge/_self_test_results.md` when done.

---

## Test 1: Orientation (No Tools)

Without reading any files or running any searches, answer these questions using only what was loaded at session start:

1. What are the six knowledge categories and what does each hold?
2. What's the directory layout of the knowledge store?
3. How does `resolve-repo.sh` determine the knowledge path?
4. What are the active plans and what state are they in?
5. What are the conversational threads about?

**What to note:** How much could you answer? Were the session-start hooks sufficient, or did you feel like you were guessing?

## Test 2: Retrieval Race

For each question below, try to answer it two ways: first using only the knowledge store (read the relevant category file or follow a backlink from the index), then using basic search (Grep/Glob). Compare which was faster and more precise.

1. "What's the known gotcha with resolve-repo.sh when a git remote is added?"
   - Knowledge path: `[[gotchas]]` → look for resolve-repo entry
   - Search path: `Grep` for "resolve-repo" or "orphan"

2. "How does the divide-and-conquer planning flow work?"
   - Knowledge path: `[[workflows#Divide-and-Conquer Planning Flow]]`
   - Search path: `Grep` for "divide-and-conquer" or "decompose"

3. "What did we learn from studying OpenClaw?"
   - Knowledge path: `[[domains/openclaw-reference]]`
   - Search path: `Grep` for "OpenClaw"

4. "What's the current state of the knowledge-retrieval-improvements plan?"
   - Knowledge path: Read `_plans/knowledge-retrieval-improvements/plan.md` phases section
   - Search path: `Grep` for "Phase 2" or "backlink resolution"

**What to note:** For each, which approach got you to the answer faster? Did the knowledge store's organization save you from scanning irrelevant results?

## Test 3: Backlink Navigation

Start at `_index.md`. Pick any entry and follow its `[[backlinks]]` to find related context across files. Try to traverse at least 3 hops:

Example chain: `_index.md` → `[[architecture]]` → `See also: [[workflows#load-knowledge.sh]]` → `See also: [[conventions#Domain Files Are Lazy-Loaded]]`

**What to note:** Did the backlinks take you somewhere useful, or did you hit dead ends? Were there places you expected a backlink but didn't find one?

## Test 4: Thread Awareness

Read the thread files at `_threads/how-we-work.md` and `_threads/memory-system-design.md`.

1. How should you format feedback about system operations (loading, capturing, updating)?
2. What's the user's preference for how you communicate?
3. How did the threads-vs-plans distinction evolve across sessions?

Now: Did knowing these things change how you'd write your test results? Would you format them differently than if you had no thread context?

**What to note:** Do threads feel like useful relationship memory, or do they feel like documentation you could have inferred from CLAUDE.md alone?

## Test 5: Plan Continuity

Load the knowledge-retrieval-improvements plan (`_plans/knowledge-retrieval-improvements/`). Read `plan.md` and `notes.md`.

1. Without any other context, can you describe what's been built, what's next, and why?
2. Could you pick up Phase 2 implementation right now? What would you need to know that the plan doesn't tell you?
3. Are the design decisions (D1-D11) clear enough to guide implementation without re-asking the user?

**What to note:** Does the plan give you enough context to act, or would you need to have the original conversation to understand the reasoning?

## Test 6: Capture Protocol

Do something that should trigger a capture. Read any script in `scripts/` and find a non-obvious implementation detail. Then:

1. Does the capture protocol in CLAUDE.md activate naturally, or does it feel like a chore?
2. Append a test entry to `_inbox.md` (you can note it's a test entry).
3. Did you think about whether it passes the 4-condition gate, or did you just capture it?

**What to note:** How high is the activation energy for capturing? Is the inbox format easy to produce from memory?

## Test 7: Search (if pk_search.py is working)

Run the FTS5 search tool:
```bash
python3 ~/.project-knowledge/scripts/pk_search.py search <knowledge_dir> "backlinks"
python3 ~/.project-knowledge/scripts/pk_search.py search <knowledge_dir> "session start"
python3 ~/.project-knowledge/scripts/pk_search.py stats <knowledge_dir>
```

(Resolve the knowledge directory first: `bash ~/.project-knowledge/scripts/resolve-repo.sh`)

**What to note:** Were results ranked usefully? Was this faster than Grep for finding the right section? Did the snippets give enough context to decide relevance without reading full files?

## Test 8: Honest Assessment

Write a short reflection:

1. **Where did the memory system save you time?** Be specific — which test, which question.
2. **Where did you bypass it?** What made you reach for Grep/Glob/Explore instead?
3. **What's missing?** What would have made the system more useful?
4. **Trust level:** On a scale of 1-5, how much did you trust the knowledge store to be accurate and complete? Did anything feel stale or wrong?
5. **Would you reach for this mid-task?** If you were implementing a feature in this codebase, would you check the knowledge store first, or just read the code?

---

## Writing Results

Create `repos/local/.project-knowledge/_self_test_results.md` with:

```markdown
# Self-Test Results — [date]

## Summary
[2-3 sentence overall assessment]

## Test Results
[For each test: what happened, what you noticed, knowledge-system vs raw-search comparison]

## Bypass Log
[Every time you used Grep/Glob/Explore instead of the knowledge system, note why]

## Recommendations
[Specific changes that would make the system more useful for a fresh instance]
```

After writing results, briefly mention them to the user: `[self-test] Results written to _self_test_results.md`
