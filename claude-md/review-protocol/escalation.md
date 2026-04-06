### Investigation Escalation

A conditional escalation path when knowledge enrichment alone is insufficient. Most enrichments resolve via the knowledge store — escalation is the exception, not the default.

#### Escalation gate (all three must be true)

1. **Substantive label** — the finding is labeled suggestion, issue, question, or thought.
2. **Insufficient knowledge results** — the knowledge store query returned no relevant entries, or returned entries that don't address the specific concern.
3. **Multi-file analysis needed** — the concern involves cross-boundary invariants, architectural patterns spanning multiple files, or dependencies that can't be verified from the diff alone.

#### Escalation procedure

When all three gate conditions are met:

1. **Prefetch knowledge for the agent prompt** — use the concern and scope files as query terms:
   ```bash
   PRIOR_KNOWLEDGE=$(lore prefetch "<concern> <scope files>" --format prompt --limit 3)
   ```
   For example, if the concern is "cross-boundary state mutation" and scope is `scripts/pk_search.py scripts/pk_cli.py`, the query would be `"cross-boundary state mutation pk_search.py pk_cli.py"`.

2. **Spawn an Explore agent** with the prefetched context embedded:
   ```
   Task: Investigate whether [specific concern] holds.
   Scope: [list of files/directories to examine]
   Question: [precise question to answer]

   ## Prior Knowledge
   <embed $PRIOR_KNOWLEDGE here — omit section if prefetch returned empty>

   If the above context doesn't cover your area, search:
   ```bash
   lore search "<query>" --type knowledge --json --limit 3
   ```

   Report: Return findings as structured observations — confirmed/refuted/uncertain with evidence.
   ```

The Explore agent traces invariants, reads related files, and scans for patterns that the knowledge store doesn't cover. The prefetched knowledge gives it project-specific context without requiring it to search voluntarily. Its findings are incorporated into the review finding before reporting.

#### Escalation budget

Maximum 2 investigation escalations per review. If more than 2 findings require escalation, prioritize by tier (architecture > logic > maintainability) and severity.

