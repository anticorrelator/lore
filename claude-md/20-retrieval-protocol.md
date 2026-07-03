## Retrieval Protocol

Every entry in the knowledge store carries provenance and a falsifier you can check against the code, so run `lore search "<topic>"` before Grep, Glob, or Explore agents — a verified hit is cheaper than re-deriving the same insight from source.

### Scale Declaration (lore search and prefetch)

`lore search` and `lore prefetch` require `--scale-set <bucket>` — one of `abstract`, `architecture`, `subsystem`, `implementation`. Missing it is an error, not a default. Four claims to guide declaration:

1. **Trust your declaration.** Once you've declared a scale set, the retrieved content matches it. You don't need to widen unless your declaration was wrong for the task.
2. **Off-altitude content is harmful, not just useless.** Implementation details when designing architecture push toward over-specification; architectural philosophy when fixing a bug makes you over-think a one-line change.
3. **Re-declare with intent, not habit.** Reaching to broaden a scale set means your initial declaration was wrong for the task. Articulate why. "Just in case" is recall-bias asking.
4. **Narrow results aren't a failure mode.** If your declared scope returns little, either no knowledge exists at this altitude, or your scale was mis-declared. Think about which before broadening.

The full scale rubric (4 definitions + boundary tests + ±1 query pattern) lives in `/spec`, `/implement`, and `/memory` SKILL.md files.

### Work Retrieval

Work items already track status, progress, and past decisions — invoke `/work` before manual exploration (git log, grep, branch inspection).
