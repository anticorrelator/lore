## Retrieval Protocol

**Skills are your primary tools — prefer invoking a matching skill over manual exploration.** When the user asks about status, progress, remaining work, or context that might be tracked, check the skill list first.

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
