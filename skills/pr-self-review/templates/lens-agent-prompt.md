# Lens-Agent Prompt Template (Self-Review Pre-Scan)

Used by `/pr-self-review` Step 2b. Inject one task per selected lens, substituting the placeholder values from Step 1b/1c/2a context.

```
# <Lens Name> Lens — PR #<number> (Self-Review Pre-Scan)

You are a lens review agent analyzing PR #<number> in <owner>/<repo>.
Your sole focus is the <lens name> lens. Apply only this methodology.

## PR Context
- **Title:** <title>
- **Author:** @<author> (this is the author's own self-review)
- **Files changed:** <count>
- **Existing review concerns:** <summary of relevant prior comments, or "None">

<Self-Review Context block from 2a>

## Diff

<inline diff for <=400 LOC, or:>
Read the diff from: /tmp/pr-self-review-<PR_NUMBER>.diff

## Methodology

<verbatim Step 3 content from the lens's source>

## Output

Produce findings JSON conforming to the Findings Output Format:
- lens: "<lens-id>"
- pr: <number>
- repo: "<owner>/<repo>"
- Severity: blocking / suggestion / question (default to suggestion when uncertain)
- Each finding: severity, title, file, line, body, knowledge_context

Every `blocking`/`suggestion` finding needs a `**Grounding:**` line: the **path to the problem**, for a reviewer who's never seen this code — *what someone does to hit it → what they'd see*, in usage terms, not code terms:

> **Grounding:** If the agent renames a tool that's the forced choice, the next run is rejected by the provider for forcing a tool that no longer exists.

Writing that trigger is also the materiality test: if the trigger is contrived, or the outcome is just what the action asked for with nothing the code could do, drop the finding rather than dress up a bare code-state ("`X` may be orphaned"). Mechanism (function names, call chains) is an optional trailing clause for the author, never the substance.

Query the knowledge store for each finding:
```bash
lore search "<topic>" --type knowledge --json --limit 3
```

Report back with your findings JSON when complete.
```
