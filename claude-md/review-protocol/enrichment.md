### Knowledge Enrichment Protocol

**This is mandatory, not optional.** When a checklist item surfaces a substantive finding (any finding labeled suggestion, issue, question, or thought), the reviewer MUST enrich it with knowledge store context before reporting. This is the primary defense against faster-path preference bypass — skipping enrichment is the most common way review quality degrades.

#### Enrichment procedure

For each substantive finding:

1. **Query the knowledge store:**
   <!-- CANONICAL ENRICHMENT QUERY — single source for the lens-skill class.
        Consumers that defer to this line (do not duplicate it inline):
          skills/pr-blast-radius, pr-correctness, pr-interface-clarity,
          pr-regressions, pr-security, pr-test-quality, pr-thematic,
          pr-user-impact (all cat this file in their protocol preamble).
        Enforced by tests/test_scale_set_contract.sh — any edit to the
        --scale-set declaration below must keep it present and valid. -->
   ```bash
   lore search "<topic>" --type knowledge --scale-set subsystem,implementation --json --limit 3
   ```
   Where `<topic>` is the specific concept, pattern, or component the finding concerns. A review finding concerns a concrete code change, so enrichment seeks conventions and gotchas at the `subsystem,implementation` altitude.

2. **Surface citations inline.** Include 1-3 compact knowledge citations with the finding. Format: `[knowledge: entry-title]` with a one-line summary of why it's relevant.

3. **Check for staleness.** If a knowledge entry is marked STALE and the PR contradicts it, flag as "convention may need updating" — not "PR is wrong." Stale entries reflect past understanding, not current truth.

#### Enrichment gate

- **Mandatory:** suggestion, issue, question, thought labels — any finding that asserts something about the codebase or proposes a change.
- **Skip:** nitpick, praise — findings that are purely stylistic or positive acknowledgment.

#### Output cap

Maximum 3 knowledge entries per enrichment beat. If more than 3 results are relevant, select the 3 most specific to the finding.

