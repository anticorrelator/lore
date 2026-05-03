## Retrieval Protocol

**Skills are your primary tools — prefer invoking a matching skill over manual exploration.** When the user asks about status, progress, remaining work, or context that might be tracked, check the skill list first.

### Scale Declaration (lore search and prefetch)

`lore search` and `lore prefetch` require `--scale-set <bucket>` — one of `abstract`, `architecture`, `subsystem`, `implementation`. Missing it is an error, not a default. Four claims to guide declaration:

1. **Trust your declaration.** Once you've declared a scale set, the retrieved content matches it. You don't need to widen unless your declaration was wrong for the task.
2. **Off-altitude content is harmful, not just useless.** Implementation details when designing architecture push toward over-specification; architectural philosophy when fixing a bug makes you over-think a one-line change.
3. **Re-declare with intent, not habit.** Reaching to broaden a scale set means your initial declaration was wrong for the task. Articulate why. "Just in case" is recall-bias asking.
4. **Narrow results aren't a failure mode.** If your declared scope returns little, either no knowledge exists at this altitude, or your scale was mis-declared. Think about which before broadening.

The full scale rubric (4 definitions + boundary tests + ±1 query pattern) lives in `/spec`, `/implement`, and `/memory` SKILL.md files.

### Knowledge Retrieval (Before Grep/Glob/Explore)
Before searching the codebase with Grep, Glob, or Explore agents, run `lore search "<topic>"` first. The knowledge store documents conventions, architecture, past decisions, and gotchas that raw code exploration cannot surface. If the knowledge store has a relevant entry, use it — don't re-derive the same insight from source files.
- Knowledge is auto-loaded on session start (index + priority files within budget)
- Domain files (`domains/`) are NOT loaded at startup — read them on-demand via the index
- When starting work in a specific area, check the index for a relevant domain file and read it
- **The test:** if you're about to Grep for how something works, a convention, or why a decision was made — search knowledge first

### Work Retrieval (Before Manual Exploration)
Before exploring manually (git log, grep, branch inspection), check for tracked work:
- If the user asks about status, progress, remaining work, or "what's next" → invoke `/work` first
- If starting a new session on a feature branch → check if a work item matches the branch
- If the user references a past discussion or decision → `/work search` before raw search
- **The test:** if you're about to grep/explore for something the work system already tracks, you've skipped a step
