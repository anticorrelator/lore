# Followup Template: Implementation Diagram Conventions

Shared diagram conventions for followup report generation across review skills.

## Diagram Type Selection

| PR character | Diagram type |
|---|---|
| Adds or modifies a feature with a clear invocation path | Call chain: entry point → handlers → outputs |
| Introduces new state or modifies state transitions | State machine: states as boxes, transitions as labeled arrows |
| Moves data between components or transforms it | Data flow: sources → transforms → sinks |
| Mixed (multiple types apply) | Use the dominant type; annotate secondary flows inline |

## ASCII Drawing Conventions

Use box-drawing characters only — no Mermaid:
`┌`, `─`, `┐`, `│`, `└`, `┘`, `├`, `┤`, `↓`, `→`, `←`, `↑`, `↔`

Label arrows with the key function name, event name, or data type that flows along the edge. Include only the components and paths that the PR actually changes or introduces; do not diagram unchanged surrounding infrastructure.

**Multi-module gate:** Include the diagram only when the PR touches 2 or more distinct modules (grouped by first directory component, or `(root)` for repo-root files). For single-module PRs, omit the diagram section. If directional relationships cannot be determined from available context, omit the diagram.

Wrap in a fenced code block:

````
```
┌─────────────────┐
│  entry point    │
│  (func/cmd/evt) │
└────────┬────────┘
         │ call / event
         ▼
┌─────────────────┐     ┌─────────────────┐
│  handler A      │────▶│  handler B      │
└─────────────────┘     └────────┬────────┘
                                 │ result
                                 ▼
                        ┌─────────────────┐
                        │  output / state │
                        └─────────────────┘
```
````

