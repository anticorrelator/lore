# lens-findings.json Payload Shape

Used by `/pr-self-review` Step 4. Build the `lens-findings.json` payload from the evaluated findings produced by Step 3 using the structure below.

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
      "body": "<finding body, may contain markdown>",
      "lens": "<lens id>",
      "grounding": "<grounding text — mechanism → consequence chain, no label prefix>",
      "selected": <true|false>
    }
  ]
}
```
