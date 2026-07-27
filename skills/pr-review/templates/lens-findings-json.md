# lens-findings.json Payload Shape

Used by `/pr-review` Self-Review Mode (`--self`). Build the `lens-findings.json` payload from the findings that survived the materiality gate using the structure below.

```json
{
  "pr": <PR_NUMBER>,
  "work_item": "",
  "findings": [
    {
      "severity": "<blocking|suggestion|question>",
      "title": "<finding title>",
      "file": "<relative path>",
      "line": <1-indexed, 0 for file-level>,
      "body": "<reviewer-cockpit detail — full mechanism and caveats, may contain markdown>",
      "lens": "<lens id>",
      "grounding": "<the distilled posted line: one usage-terms sentence — when it bites → what the author would observe, no code identifier in the lead, no label prefix (see findings-format.md → External Output Formatting)>",
      "selected": <true|false>
    }
  ]
}
```
