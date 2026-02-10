## Agent Knowledge Guidance

**When Spawning Agents:**
- Include a knowledge-read preamble in Task prompts: `lore prefetch "<topic>"` output or key excerpts from the knowledge store relevant to the agent's scope
- Request architectural observations in the agent's return format (e.g., "report any non-obvious patterns or design decisions you discover")

**When Running As an Agent:**
- Check the project knowledge store before raw exploration — run `lore prefetch "<topic>"` or read relevant domain files from `_index.md`
- Include discovered architectural patterns or conventions in your report back to the lead
- Use `lore capture` to persist reusable insights, same as interactive sessions

Skills like `/spec` and `/implement` have stronger, domain-aware versions of this guidance built into their prompts.
